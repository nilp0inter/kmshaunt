//! src/font/atlas.zig -- glyph atlas with LRU eviction and font-size math
//! (ROADMAP M3.8).
//!
//! The atlas owns two backing buffers (pages) of the same nominal size:
//! one `a8` (1 byte/pixel coverage for monochrome glyphs) and one `bgra8`
//! (4 bytes/pixel BGRA for color glyphs, e.g. CBDT/COLR rasters; bytes are
//! copied verbatim, so premultiplication is the caller's choice). Both
//! pages share one packer space: each entry is a `Rect` in *pixel*
//! coordinates shared by both pages, so a dirty rect tells a GL uploader
//! exactly which region to copy from which page (`AtlasEntry.page` selects
//! a8=0 / bgra8=1).
//!
//! Packing is shelf-based (rows are appended top-down, each row grows to the
//! tallest item placed in it) with guillotine-style reuse of rects freed by
//! eviction. When no free rect and no shelf space can hold a new glyph, the
//! least-recently-used node is evicted (its rect joins the free list) and the
//! insert is retried. Eviction never touches a node that was used since the
//! last `beginFrame()`: the renderer calls `beginFrame()` once per rendered
//! frame, so the glyphs it just rasterized for the current frame cannot be
//! evicted underneath it. Anything else falls back to AtlasFull.
//!
//! LRU bookkeeping is an intrusive doubly-linked list threaded through a
//! stable node pool (`nodes`); the pool is indexed by `u32`, never by
//! pointer, so `ArrayList` growth and hash-map resizing cannot dangle links.
//! `HashMap(GlyphKey, u32)` maps a key to its node index.
//!
//! `generation` counts every change of page contents (inserts and in-place
//! rewrites; evictions only free space and do not alter pixels, so they do
//! not bump it). `dirtyRects()` lists the regions changed since the last
//! `clearDirty()`; together they drive the GL upload pass in drm3d.
//!
//! `computeAutoFontSize`/`applyZoom` implement the `font-size=auto` and the
//! `grab-zoom-in`/`grab-zoom-out` behaviors: auto size scales the configured
//! default size by the connector's diagonal DPI relative to a 96 DPI
//! baseline, and zoom steps one point per grab press, clamped to the
//! caller's bounds. Both are pure functions; the caller owns the point size.
//!
//! Parity note: kmscon 10.1.0 derives its automatic size from the text grid
//! (`terminal.c:terminal_get_auto_font_size`: 120 columns wide, at least 40
//! rows, floor 16 px) and zooms by `font->increase_step` pixels
//! (`terminal.c:zoom_in/zoom_out`). kmshaunt keeps the DPI/point model
//! instead so one font size means the same physical size on every output.

const std = @import("std");

/// `GlyphKey.flags` bit: glyph is synthesized bold (oblique enlarged stroke).
pub const flag_synthetic_bold: u8 = 0x01;
/// `GlyphKey.flags` bit: glyph is synthesized italic (sheared).
pub const flag_synthetic_italic: u8 = 0x02;
/// `GlyphKey.flags` bit: glyph is a code-drawn sprite (box drawing, block
/// elements, braille, ...), not a font outline. Sprite metrics live in
/// `AtlasEntry` like any other glyph.
pub const flag_sprite: u8 = 0x04;

/// Identifies one rasterized glyph in the cache. `face_id` is the owning
/// face's slot in the font manager's face table; `glyph_index` is the
/// FreeType glyph index; `size_px` is the requested pixel size (auto size
/// rounds to an integer; HiDPI sizes are simply larger integers).
/// `subpixel_x` is the LCD subpixel phase (0 = none) and `flags` carries the
/// `flag_*` bits above; both are part of the key so that synthetic-bold and
/// horizontally-subpixel-shifted copies of the same glyph index cache side
/// by side.
pub const GlyphKey = struct {
    face_id: u16,
    glyph_index: u32,
    size_px: u16,
    subpixel_x: u8 = 0,
    flags: u8 = 0,
};

/// Pixel layout of a cached bitmap.
pub const PixelFormat = enum {
    /// 1 byte per pixel coverage value, row-major.
    a8,
    /// 4 bytes per pixel BGRA order, row-major.
    bgra8,
};

/// Where a glyph landed in the atlas and how to draw it.
///
/// `x/y/width/height` are the packed region in *pixel* coordinates, shared
/// by both pages ("page 0" a8 and "page 1" bgra8 are the same size); the
/// glyph's pixels live on `page`. The `bearing*`/`advance_x` values are the
/// FreeType metrics captured at rasterization time so the renderer can
/// position the glyph without reconsulting the face.
pub const AtlasEntry = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    bearing_x: i16 = 0,
    bearing_y: i16 = 0,
    advance_x: i16 = 0,
    format: PixelFormat,
    page: u8,
};

/// Axis-aligned rectangle in atlas pixel coordinates, used for dirty
/// regions and free-list holes. `dirtyRects()` never reports an empty one:
/// blank glyphs touch no page bytes.
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

/// Read-only view of one cached glyph's pixels.
///
/// `data` spans the region's rows in the page buffer, starting at the
/// region's top-left pixel and running to the end of its last row; `stride`
/// is the byte distance between consecutive rows (i.e. the page width, or 4x
/// it for the bgra8 page). Copy `width*bytes_per_pixel` bytes per row from
/// `data[row*stride ..]` when uploading.
pub const Region = struct {
    data: []const u8,
    stride: usize,
};

/// Metrics recorded by `insert`; passes through to `AtlasEntry`.
pub const InsertMetrics = struct {
    bearing_x: i16 = 0,
    bearing_y: i16 = 0,
    advance_x: i16 = 0,
};

/// Source bitmap handed to `insert`. `data` must hold at least
/// `(height-1)*stride + width*bpp` bytes (`bpp` = 1 for a8, 4 for bgra8).
/// `stride` defaults to tight packing; pass it explicitly when the raster
/// (e.g. a FreeType `FT_Bitmap`) has padding at the end of rows.
pub const Bitmap = struct {
    format: PixelFormat,
    width: u16,
    height: u16,
    data: []const u8,
    stride: ?usize = null,
};

/// DPI baseline for `computeAutoFontSize`: the CSS reference pixel density,
/// at which the configured point size is used unchanged.
pub const baseline_dpi: f32 = 96.0;

/// Inches per millimeter, for the DPI conversion.
const mm_per_inch: f32 = 25.4;

/// Compute the automatic font size for a connector.
///
/// `default_pt` is the configured size that applies when the connector
/// reports no physical size. The returned value is
/// `default_pt * dpi / baseline_dpi`, where `dpi` is the connector diagonal
/// in pixels over its diagonal in inches:
/// `hypot(width_px, height_px) / (hypot(width_mm, height_mm) / 25.4)`.
/// Monitors above the 96 DPI baseline (HiDPI, >140 DPI is the usual
/// threshold) yield sizes above `default_pt`, keeping the glyph grid
/// readable; sub-96 DPI yields proportionally smaller sizes. The scale is
/// linear and uncapped, so callers must clamp for their own UI limits.
///
/// Missing or implausible inputs (any mm/px argument <= 0, non-finite mm/px,
/// or a non-finite/non-positive `default_pt`) return `default_pt` unchanged.
pub fn computeAutoFontSize(
    width_px: f32,
    height_px: f32,
    width_mm: f32,
    height_mm: f32,
    default_pt: f32,
) f32 {
    if (!std.math.isFinite(default_pt) or default_pt <= 0) return default_pt;
    if (!std.math.isFinite(width_mm) or !std.math.isFinite(height_mm) or width_mm <= 0 or height_mm <= 0)
        return default_pt;
    if (!std.math.isFinite(width_px) or !std.math.isFinite(height_px) or width_px <= 0 or height_px <= 0)
        return default_pt;

    const dpi = std.math.hypot(width_px, height_px) / (std.math.hypot(width_mm, height_mm) / mm_per_inch);
    const size = default_pt * (dpi / baseline_dpi);
    if (!std.math.isFinite(size) or size <= 0) return default_pt;
    return size;
}

/// Apply a zoom grab (`grab-zoom-in` / `grab-zoom-out`) to a font size.
///
/// `delta_steps` is the signed number of zoom steps (+1 per
/// `grab-zoom-in` press, -1 per `grab-zoom-out`), applied linearly to
/// `current_pt`; the result is clamped to `[min_pt, max_pt]`. Bounds given
/// inverted are exchanged rather than asserted, so a zero-width interval
/// pins the size. A one-point-per-press floor is reproduced by passing
/// `min_pt = 1`.
pub fn applyZoom(current_pt: f32, delta_steps: i32, min_pt: f32, max_pt: f32) f32 {
    const lo = @min(min_pt, max_pt);
    const hi = @max(min_pt, max_pt);
    const candidate = current_pt + @as(f32, @floatFromInt(delta_steps));
    return std.math.clamp(candidate, lo, hi);
}

/// Glyph cache with LRU eviction (ROADMAP M3.8).
///
/// Threading model: single-threaded, consumed by the renderer between
/// `beginFrame()` calls. `get`/`insert` are O(1) amortized; insert that
/// requires eviction is O(nodes) worst case.
///
/// Frame pinning: `beginFrame()` bumps the frame counter; a node's
/// `used_frame` is stamped on every `get` and `insert`. Eviction refuses
/// nodes stamped with the current frame. Call `beginFrame()` once per
/// rendered frame *before* the first `get`/`insert` of that frame.
pub const GlyphAtlas = struct {
    pub const InitError = std.mem.Allocator.Error || error{InvalidSize};
    pub const InsertError = std.mem.Allocator.Error || error{
        /// No packable space and nothing unpinned left to evict. Usually
        /// transient: retry after the next `beginFrame()`.
        AtlasFull,
        /// The glyph is wider or taller than the whole atlas.
        GlyphTooLarge,
        /// `bitmap.data` is too short for its `width`/`height`/`stride`.
        InvalidBitmap,
    };

    /// Allocator used for every dynamic structure; buffers too.
    allocator: std.mem.Allocator,
    /// Page width/height in pixels (both pages share one size).
    width: u16,
    height: u16,
    /// Number of pixel-content changes since construction. Bumped by every
    /// insert or in-place rewrite that writes pixels, and by nothing else:
    /// blank-glyph entries and evictions leave the pages untouched, so they
    /// do not bump it. A renderer that caches `generation` can skip the
    /// upload pass entirely while it is unchanged.
    generation: u64 = 0,

    // ---- internal state ----

    /// Coverage page: 1 byte per pixel, row-major, `width*height` bytes.
    a8: []u8 = &.{},
    /// Color page: 4 bytes per pixel BGRA, row-major, `width*height*4`.
    bgra8: []u8 = &.{},
    /// GlyphKey -> node index in `nodes`.
    map: std.AutoHashMap(GlyphKey, u32) = undefined,
    /// Stable node pool. Indices, not pointers, form the LRU list below, so
    /// reallocation of this array is harmless.
    nodes: std.ArrayList(Node) = .empty,
    /// Reusable indices of evicted nodes.
    free_nodes: std.ArrayList(u32) = .empty,
    /// MRU end of the LRU list, or null when the atlas is empty.
    head: ?u32 = null,
    /// LRU end of the LRU list, or null when the atlas is empty.
    tail: ?u32 = null,
    /// Shelf rows, top-down; `shelves[0].y == 0`.
    shelves: std.ArrayList(Shelf) = .empty,
    /// Rectangles freed by eviction, available for reuse.
    free_rects: std.ArrayList(Rect) = .empty,
    /// Regions whose page pixels changed since the last `clearDirty()`.
    dirty: std.ArrayList(Rect) = .empty,
    /// Current frame counter (see `beginFrame`).
    frame: u64 = 0,

    const Node = struct {
        key: GlyphKey,
        entry: AtlasEntry,
        prev: ?u32,
        next: ?u32,
        /// Frame during which this node was last used; pinned while equal to
        /// `frame`.
        used_frame: u64,
    };

    const Shelf = struct {
        y: u16,
        /// Tallest item placed in this shelf so far.
        height: u16,
        /// Next free x in this shelf.
        cursor_x: u16,
    };

    /// Create an atlas with `width`x`height` pixel pages. A typical console
    /// atlas is 4096x4096 (~16 MiB a8 + 64 MiB bgra8). Both pages start
    /// zeroed, so uploading a page before its first glyph cannot expose
    /// stale heap contents.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) InitError!GlyphAtlas {
        if (width == 0 or height == 0) return error.InvalidSize;
        const a8 = try allocator.alloc(u8, @as(usize, width) * height);
        errdefer allocator.free(a8);
        const bgra8 = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(bgra8);
        @memset(a8, 0);
        @memset(bgra8, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .a8 = a8,
            .bgra8 = bgra8,
            .map = std.AutoHashMap(GlyphKey, u32).init(allocator),
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.allocator.free(self.a8);
        self.allocator.free(self.bgra8);
        self.map.deinit();
        self.nodes.deinit(self.allocator);
        self.free_nodes.deinit(self.allocator);
        self.shelves.deinit(self.allocator);
        self.free_rects.deinit(self.allocator);
        self.dirty.deinit(self.allocator);
    }

    /// Start a new rendered frame. Nodes touched since the previous
    /// `beginFrame()` become evictable; nodes touched after this call are
    /// pinned until the next `beginFrame()`.
    pub fn beginFrame(self: *GlyphAtlas) void {
        self.frame +%= 1;
    }

    /// Look up a glyph, promoting it to MRU and pinning it for the current
    /// frame. Returns the null entry set when absent; use `insert` to make
    /// it present.
    pub fn get(self: *GlyphAtlas, key: GlyphKey) ?AtlasEntry {
        const idx = self.map.get(key) orelse return null;
        self.touch(idx);
        return self.nodes.items[idx].entry;
    }

    /// Whether `key` is cached. Unlike `get`, does not touch the LRU order.
    pub fn contains(self: *const GlyphAtlas, key: GlyphKey) bool {
        return self.map.contains(key);
    }

    /// Number of live cached glyphs.
    pub fn count(self: *const GlyphAtlas) usize {
        return self.map.count();
    }

    /// Rasterize `bitmap` into the atlas under `key`, recording `metrics`.
    ///
    /// If `key` is already cached with the same pixel size and format, the page
    /// region is rewritten in place and its metrics updated; if the size or
    /// format differs, the old copy is dropped and a fresh region packed.
    /// Otherwise a fresh region is packed: first-fit into a free (evicted)
    /// rect, else into a shelf row, else a new shelf row;
    /// when no space remains, LRU nodes are evicted (never ones used since
    /// the last `beginFrame`) until the bitmap fits. Blank glyphs (0 width
    /// or height) occupy no page space: the entry is recorded for its
    /// metrics only, with no dirty rect and no generation bump.
    pub fn insert(self: *GlyphAtlas, key: GlyphKey, metrics: InsertMetrics, bitmap: Bitmap) InsertError!AtlasEntry {
        try checkBitmap(bitmap);

        if (self.map.get(key)) |idx| {
            const node = &self.nodes.items[idx];
            if (node.entry.width == bitmap.width and
                node.entry.height == bitmap.height and
                node.entry.format == bitmap.format)
            {
                // In-place rewrite: same size and format, just new pixels.
                try self.dirty.ensureTotalCapacity(self.allocator, self.dirty.items.len + 1);
                self.blit(node.entry, bitmap);
                node.entry.bearing_x = metrics.bearing_x;
                node.entry.bearing_y = metrics.bearing_y;
                node.entry.advance_x = metrics.advance_x;
                self.touch(idx);
                if (node.entry.width > 0 and node.entry.height > 0) {
                    self.dirty.appendAssumeCapacity(.{
                        .x = node.entry.x, .y = node.entry.y,
                        .width = node.entry.width, .height = node.entry.height,
                    });
                    self.generation +%= 1;
                }
                return node.entry;
            }
            // Size/format changed: drop the old copy and pack fresh below.
            try self.removeNode(idx);
        }

        if (bitmap.width == 0 or bitmap.height == 0)
            return self.insertBlank(key, metrics, bitmap);

        if (bitmap.width > self.width or bitmap.height > self.height)
            return error.GlyphTooLarge;

        var rect: Rect = undefined;
        while (true) {
            if (try self.packRect(bitmap.width, bitmap.height)) |r| {
                rect = r;
                break;
            }
            if (!try self.evictOne())
                return error.AtlasFull;
        }

        const entry = AtlasEntry{
            .x = rect.x,
            .y = rect.y,
            .width = bitmap.width,
            .height = bitmap.height,
            .bearing_x = metrics.bearing_x,
            .bearing_y = metrics.bearing_y,
            .advance_x = metrics.advance_x,
            .format = bitmap.format,
            .page = pageFor(bitmap.format),
        };
        // All fallible allocations first; the tail below cannot fail, so no
        // partial states need rolling back.
        try self.dirty.ensureTotalCapacity(self.allocator, self.dirty.items.len + 1);
        try self.addNode(key, entry);
        self.blit(entry, bitmap);
        self.dirty.appendAssumeCapacity(.{
            .x = entry.x, .y = entry.y,
            .width = entry.width, .height = entry.height,
        });
        self.generation +%= 1;
        return entry;
    }

    /// Drop a cached glyph (e.g. its face was unloaded). The freed page
    /// rect becomes reusable; its pixels stay in the page buffers until
    /// overwritten, which is harmless because no key references them. May
    /// fail with OOM, in which case the rect is simply not reclaimed.
    pub fn remove(self: *GlyphAtlas, key: GlyphKey) std.mem.Allocator.Error!void {
        const idx = self.map.get(key) orelse return;
        try self.removeNode(idx);
    }

    /// Forget all recorded dirty rects. The GL uploader calls this after
    /// uploading; `generation` keeps counting regardless.
    pub fn clearDirty(self: *GlyphAtlas) void {
        self.dirty.clearRetainingCapacity();
    }

    /// Rectangles of page pixels changed since the last `clearDirty()`, in
    /// no particular order. Combine with `generation` to decide whether an
    /// upload pass is needed at all.
    pub fn dirtyRects(self: *const GlyphAtlas) []const Rect {
        return self.dirty.items;
    }

    /// Read-only view of an entry's pixels on the a8 page.
    pub fn a8Region(self: *const GlyphAtlas, entry: AtlasEntry) Region {
        return self.region(entry, .a8);
    }

    /// Read-only view of an entry's pixels on the bgra8 page.
    pub fn bgra8Region(self: *const GlyphAtlas, entry: AtlasEntry) Region {
        return self.region(entry, .bgra8);
    }

    // ---- packing ----

    fn packRect(self: *GlyphAtlas, w: u16, h: u16) std.mem.Allocator.Error!?Rect {
        if (try self.placeInFreeRect(w, h)) |r| return r;
        return self.placeInShelf(w, h);
    }

    /// First-fit into a free (evicted) rect; guillotine-split the remainder
    /// into a right slab and a bottom slab.
    fn placeInFreeRect(self: *GlyphAtlas, w: u16, h: u16) std.mem.Allocator.Error!?Rect {
        for (self.free_rects.items, 0..) |r, i| {
            if (r.width < w or r.height < h) continue;
            const right_w = r.width - w;
            const bottom_h = r.height - h;
            if (right_w > 0 or bottom_h > 0)
                try self.free_rects.ensureTotalCapacity(self.allocator, self.free_rects.items.len + 2);
            _ = self.free_rects.swapRemove(i);
            if (right_w > 0)
                self.free_rects.appendAssumeCapacity(.{ .x = r.x + w, .y = r.y, .width = right_w, .height = h });
            if (bottom_h > 0)
                self.free_rects.appendAssumeCapacity(.{ .x = r.x, .y = r.y + h, .width = r.width, .height = bottom_h });
            return .{ .x = r.x, .y = r.y, .width = w, .height = h };
        }
        return null;
    }

    /// Shelf packing: items fill a row left to right (top-aligned); the row
    /// grows to the tallest item. A row may only grow while it does not
    /// overlap the next row; otherwise the next row is tried, then a fresh
    /// row below the current bottom.
    fn placeInShelf(self: *GlyphAtlas, w: u16, h: u16) std.mem.Allocator.Error!?Rect {
        const items = self.shelves.items;
        for (items, 0..) |*shelf, i| {
            if (@as(u32, shelf.cursor_x) + w > self.width) continue;
            const next_y: u32 = if (i + 1 < items.len) items[i + 1].y else self.height;
            if (@as(u32, shelf.y) + @max(shelf.height, h) > next_y) continue;
            const rect = Rect{ .x = shelf.cursor_x, .y = shelf.y, .width = w, .height = h };
            shelf.cursor_x +%= w;
            shelf.height = @max(shelf.height, h);
            return rect;
        }
        const bottom: u32 = if (items.len == 0) 0 else @as(u32, items[items.len - 1].y) + items[items.len - 1].height;
        if (bottom + h > self.height) return null;
        try self.shelves.ensureTotalCapacity(self.allocator, self.shelves.items.len + 1);
        const y: u16 = @intCast(bottom);
        self.shelves.appendAssumeCapacity(.{ .y = y, .height = h, .cursor_x = w });
        return Rect{ .x = 0, .y = y, .width = w, .height = h };
    }

    // ---- eviction / free rects ----

    /// Evict the least-recently-used node that was not used since the last
    /// `beginFrame()`. Returns false when every live node is pinned.
    fn evictOne(self: *GlyphAtlas) std.mem.Allocator.Error!bool {
        var idx = self.tail;
        while (idx) |i| {
            const prev = self.nodes.items[i].prev;
            if (self.nodes.items[i].used_frame == self.frame) {
                idx = prev;
                continue;
            }
            try self.removeNode(i);
            return true;
        }
        return false;
    }

    fn removeNode(self: *GlyphAtlas, idx: u32) std.mem.Allocator.Error!void {
        const node = &self.nodes.items[idx];
        const key = node.key;
        const entry = node.entry;
        self.unlink(idx);
        _ = self.map.remove(key);
        if (entry.width > 0 and entry.height > 0)
            try self.addFreeRect(.{ .x = entry.x, .y = entry.y, .width = entry.width, .height = entry.height });
        try self.free_nodes.append(self.allocator, idx);
    }

    /// Put a freed rect on the free list, coalescing it with any existing
    /// rect it touches edge-to-edge, so repeated eviction of neighbouring
    /// glyphs does not fragment the list. A merge restarts the scan: the
    /// union may touch a third neighbour that neither input touched alone
    /// (e.g. left-free + middle-freed + right-free).
    fn addFreeRect(self: *GlyphAtlas, rect: Rect) std.mem.Allocator.Error!void {
        var pending = rect;
        var i: usize = 0;
        while (i < self.free_rects.items.len) {
            if (tryMerge(&self.free_rects.items[i], pending)) {
                // `items[i]` now holds the union; take it out of the list
                // and rescan so it can merge again.
                pending = self.free_rects.swapRemove(i);
                i = 0;
            } else {
                i += 1;
            }
        }
        try self.free_rects.append(self.allocator, pending);
    }

    fn tryMerge(a: *Rect, b: Rect) bool {
        if (a.y == b.y and a.height == b.height) {
            if (a.x + a.width == b.x) {
                a.width +|= b.width;
                return true;
            }
            if (b.x + b.width == a.x) {
                a.x = b.x;
                a.width +|= b.width;
                return true;
            }
        }
        if (a.x == b.x and a.width == b.width) {
            if (a.y + a.height == b.y) {
                a.height +|= b.height;
                return true;
            }
            if (b.y + b.height == a.y) {
                a.y = b.y;
                a.height +|= b.height;
                return true;
            }
        }
        return false;
    }

    // ---- node pool / LRU list ----

    /// Allocate a node (from the free pool, else freshly appended) and link
    /// it as MRU. All fallible work happens before any mutation.
    fn addNode(self: *GlyphAtlas, key: GlyphKey, entry: AtlasEntry) std.mem.Allocator.Error!void {
        try self.map.ensureTotalCapacity(self.map.count() + 1);
        const idx: u32 = if (self.free_nodes.pop()) |free_idx| blk: {
            self.nodes.items[free_idx] = .{ .key = key, .entry = entry, .prev = null, .next = null, .used_frame = 0 };
            break :blk free_idx;
        } else blk: {
            try self.nodes.ensureTotalCapacity(self.allocator, self.nodes.items.len + 1);
            const n: u32 = @intCast(self.nodes.items.len);
            self.nodes.appendAssumeCapacity(.{ .key = key, .entry = entry, .prev = null, .next = null, .used_frame = 0 });
            break :blk n;
        };
        self.map.putAssumeCapacity(key, idx);
        self.pushFront(idx);
    }

    /// Mark a node as used this frame and move it to the MRU end.
    fn touch(self: *GlyphAtlas, idx: u32) void {
        if (self.head != idx) {
            self.unlink(idx);
            self.pushFront(idx);
        } else {
            self.nodes.items[idx].used_frame = self.frame;
        }
    }

    /// Link a node at the MRU end, stamping its frame.
    fn pushFront(self: *GlyphAtlas, idx: u32) void {
        const node = &self.nodes.items[idx];
        node.used_frame = self.frame;
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| self.nodes.items[h].prev = idx;
        self.head = idx;
        if (self.tail == null) self.tail = idx;
    }

    /// Detach a node from the LRU list (head/tail/links updated).
    fn unlink(self: *GlyphAtlas, idx: u32) void {
        const node = &self.nodes.items[idx];
        if (node.prev) |p| self.nodes.items[p].next = node.next else self.head = node.next;
        if (node.next) |n| self.nodes.items[n].prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }

    // ---- pixels ----

    fn region(self: *const GlyphAtlas, entry: AtlasEntry, format: PixelFormat) Region {
        const bpp: usize = switch (format) {
            .a8 => 1,
            .bgra8 => 4,
        };
        const stride: usize = switch (format) {
            .a8 => self.width,
            .bgra8 => @as(usize, self.width) * 4,
        };
        const buf: []const u8 = switch (format) {
            .a8 => self.a8,
            .bgra8 => self.bgra8,
        };
        if (entry.width == 0 or entry.height == 0)
            return .{ .data = buf[0..0], .stride = stride };
        const off = @as(usize, entry.y) * stride + @as(usize, entry.x) * bpp;
        const len = (@as(usize, entry.height) - 1) * stride + @as(usize, entry.width) * bpp;
        return .{ .data = buf[off .. off + len], .stride = stride };
    }

    /// Copy `bitmap` rows (with their own stride) into the page at `entry`.
    fn blit(self: *GlyphAtlas, entry: AtlasEntry, bitmap: Bitmap) void {
        const bpp: usize = switch (bitmap.format) {
            .a8 => 1,
            .bgra8 => 4,
        };
        const w = @as(usize, bitmap.width) * bpp;
        const src_stride = bitmap.stride orelse w;
        const dst_stride: usize = switch (bitmap.format) {
            .a8 => self.width,
            .bgra8 => @as(usize, self.width) * 4,
        };
        const base = @as(usize, entry.y) * dst_stride + @as(usize, entry.x) * bpp;
        const dst: []u8 = switch (bitmap.format) {
            .a8 => self.a8,
            .bgra8 => self.bgra8,
        };
        for (0..bitmap.height) |row| {
            @memcpy(
                dst[base + row * dst_stride .. base + row * dst_stride + w],
                bitmap.data[row * src_stride .. row * src_stride + w],
            );
        }
    }

    /// Validate `bitmap` before any state is touched: enough payload bytes
    /// and a sane stride. Blank glyphs are always valid.
    fn checkBitmap(bitmap: Bitmap) error{InvalidBitmap}!void {
        const bpp: usize = switch (bitmap.format) {
            .a8 => 1,
            .bgra8 => 4,
        };
        const w = @as(usize, bitmap.width) * bpp;
        const stride = bitmap.stride orelse w;
        if (stride < w) return error.InvalidBitmap;
        if (bitmap.width == 0 or bitmap.height == 0) return;
        const needed = (@as(usize, bitmap.height) - 1) * stride + w;
        if (bitmap.data.len < needed) return error.InvalidBitmap;
    }

    /// Record a metrics-only entry for a blank (0x0) glyph: no page space,
    /// no dirty rect, no generation bump (nothing changed on the pages).
    fn insertBlank(self: *GlyphAtlas, key: GlyphKey, metrics: InsertMetrics, bitmap: Bitmap) InsertError!AtlasEntry {
        const entry = AtlasEntry{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .bearing_x = metrics.bearing_x,
            .bearing_y = metrics.bearing_y,
            .advance_x = metrics.advance_x,
            .format = bitmap.format,
            .page = pageFor(bitmap.format),
        };
        try self.addNode(key, entry);
        return entry;
    }

    fn pageFor(format: PixelFormat) u8 {
        return switch (format) {
            .a8 => 0,
            .bgra8 => 1,
        };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn makeKey(face: u16, glyph: u32, size: u16) GlyphKey {
    return .{ .face_id = face, .glyph_index = glyph, .size_px = size };
}

fn copyRegionRow(region: Region, row: usize, out: []u8) void {
    @memcpy(out, region.data[row * region.stride .. row * region.stride + out.len]);
}

const empty_8x8 = @as([64]u8, @splat(0));
/// Zeroed 16x8 a8 bitmap (one evicted pair of shelf neighbours).
const empty_16x8 = @as([128]u8, @splat(0));
/// Zeroed 12x4 a8 bitmap (48 bytes).
const empty_12x4 = @as([48]u8, @splat(0));
/// Zeroed 12x4 bgra8 bitmap (48 pixels x 4 bytes).
const empty_bgra_12x4 = @as([192]u8, @splat(0));
/// 1024 zero bytes, for the oversized-glyph payload check.
const zeros_1024 = @as([1024]u8, @splat(0));
/// Deliberately one byte short of what an 8x8 a8 glyph needs.
const short_63 = @as([63]u8, @splat(0));

test "(a) insert+get round-trips exact bitmap pixels for a8 and bgra8" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 64, 32);
    defer atlas.deinit();
    atlas.beginFrame();

    // a8, tight stride, non-square to catch row-major mistakes.
    const w: u16 = 5;
    const h: u16 = 3;
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 10, 20, 30, 40, 50, 250, 251, 252, 253, 254 };
    const k1 = makeKey(1, 0x100, 16);
    const e1 = try atlas.insert(k1, .{
        .bearing_x = 1,
        .bearing_y = -2,
        .advance_x = 7,
    }, .{ .format = .a8, .width = w, .height = h, .data = &pixels });

    try std.testing.expectEqual(w, e1.width);
    try std.testing.expectEqual(h, e1.height);
    try std.testing.expectEqual(@as(i16, 1), e1.bearing_x);
    try std.testing.expectEqual(@as(i16, -2), e1.bearing_y);
    try std.testing.expectEqual(@as(i16, 7), e1.advance_x);
    try std.testing.expectEqual(PixelFormat.a8, e1.format);
    try std.testing.expectEqual(@as(u8, 0), e1.page);

    const got1 = atlas.get(k1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(e1, got1);
    const region1 = atlas.a8Region(got1);
    try std.testing.expectEqual(@as(usize, 64), region1.stride);
    var tight: [15]u8 = undefined;
    copyRegionRow(region1, 0, tight[0..5]);
    copyRegionRow(region1, 1, tight[5..10]);
    copyRegionRow(region1, 2, tight[10..15]);
    try std.testing.expectEqualSlices(u8, &pixels, &tight);

    // bgra8, 3x2.
    const bgra_pixels = [_]u8{
        0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88,
        0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
    };
    const k2 = makeKey(2, 0x200, 20);
    const e2 = try atlas.insert(k2, .{}, .{ .format = .bgra8, .width = 3, .height = 2, .data = &bgra_pixels });
    const got2 = atlas.get(k2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(PixelFormat.bgra8, got2.format);
    try std.testing.expectEqual(@as(u8, 1), got2.page);
    const region2 = atlas.bgra8Region(got2);
    try std.testing.expectEqual(@as(usize, 64 * 4), region2.stride);
    var bgra_out: [24]u8 = undefined;
    copyRegionRow(region2, 0, bgra_out[0..12]);
    copyRegionRow(region2, 1, bgra_out[12..24]);
    try std.testing.expectEqualSlices(u8, &bgra_pixels, &bgra_out);
    try std.testing.expectEqual(e2, got2);

    // Custom source stride: 5-wide a8 rows padded to 8 bytes.
    const padded = [_]u8{
        1, 2, 3, 4, 5, 0, 0, 0,
        6, 7, 8, 9, 10, 0, 0, 0,
        11, 12, 13, 14, 15, 0, 0, 0,
    };
    const k3 = makeKey(3, 0x300, 16);
    _ = try atlas.insert(k3, .{}, .{ .format = .a8, .width = 5, .height = 3, .data = &padded, .stride = 8 });
    const got3 = atlas.get(k3) orelse return error.TestUnexpectedResult;
    const region3 = atlas.a8Region(got3);
    var strided_out: [15]u8 = undefined;
    copyRegionRow(region3, 0, strided_out[0..5]);
    copyRegionRow(region3, 1, strided_out[5..10]);
    copyRegionRow(region3, 2, strided_out[10..15]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &strided_out);

    // Blank glyph: recorded metrics, consumes no page space.
    const k4 = makeKey(4, 0x400, 16);
    const e4 = try atlas.insert(k4, .{ .advance_x = 8 }, .{ .format = .a8, .width = 0, .height = 0, .data = &[_]u8{} });
    try std.testing.expectEqual(@as(u16, 0), e4.width);
    try std.testing.expectEqual(@as(u16, 0), e4.height);
    try std.testing.expectEqual(@as(i16, 8), e4.advance_x);
    try std.testing.expect(atlas.contains(k4));
    try std.testing.expect(atlas.contains(k1));

    // Oversized glyph and corrupt bitmap are rejected without state changes.
    try std.testing.expectError(error.GlyphTooLarge, atlas.insert(makeKey(9, 1, 16), .{}, .{
        .format = .a8, .width = 128, .height = 8, .data = &zeros_1024,
    }));
    try std.testing.expectError(error.InvalidBitmap, atlas.insert(makeKey(9, 2, 16), .{}, .{
        .format = .a8, .width = 8, .height = 8, .data = &short_63,
    }));
    try std.testing.expectEqual(@as(usize, 4), atlas.count());
}

test "(b) LRU: recently-got glyph survives eviction, stale one is evicted" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 48, 16);
    defer atlas.deinit();
    // 8x8 a8 glyphs pack 6 per shelf row x 2 rows = 12 slots.
    const metrics = InsertMetrics{};

    atlas.beginFrame(); // frame 1: fill the atlas.
    var i: u16 = 0;
    while (i < 12) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
    try std.testing.expectEqual(@as(usize, 12), atlas.count());

    // Frame 2: pin k1 by getting it (promotes it to MRU too), the rest are
    // stale now. Overflow with 6 more glyphs; each insert must evict one.
    atlas.beginFrame();
    try std.testing.expect(atlas.get(makeKey(0, 1, 8)) != null);
    i = 12;
    while (i < 18) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
    try std.testing.expectEqual(@as(usize, 12), atlas.count());

    // k1 was recently got -> survived. k0, k2..k6 (stale, in LRU order) were
    // evicted; k7..k11 were simply never reached by the eviction walk.
    try std.testing.expect(atlas.get(makeKey(0, 1, 8)) != null);
    try std.testing.expect(atlas.get(makeKey(0, 7, 8)) != null);
    try std.testing.expect(atlas.get(makeKey(0, 13, 8)) != null);
    try std.testing.expect(atlas.get(makeKey(0, 17, 8)) != null);
    try std.testing.expect(atlas.get(makeKey(0, 0, 8)) == null);
    try std.testing.expect(atlas.get(makeKey(0, 2, 8)) == null);
    try std.testing.expect(atlas.get(makeKey(0, 6, 8)) == null);

    // Explicit removal frees the slot and the key.
    try atlas.remove(makeKey(0, 17, 8));
    try std.testing.expectEqual(@as(usize, 11), atlas.count());
    try std.testing.expect(atlas.get(makeKey(0, 17, 8)) == null);
    _ = try atlas.insert(makeKey(0, 17, 8), metrics, .{
        .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
    });
    try std.testing.expectEqual(@as(usize, 12), atlas.count());
}

test "(c) frame pinning: LRU entries used since beginFrame are never evicted" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 32, 16);
    defer atlas.deinit();
    // 8x8 glyphs: 4 per row x 2 rows = 8 slots.
    const metrics = InsertMetrics{};

    atlas.beginFrame(); // frame 1
    var i: u16 = 0;
    while (i < 8) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });

    // Frame 2: pin k5 by getting it, then evict everything else.
    atlas.beginFrame();
    try std.testing.expect(atlas.get(makeKey(0, 5, 8)) != null);
    i = 8;
    while (i < 15) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
    try std.testing.expectEqual(@as(usize, 8), atlas.count());

    // k5 (used since beginFrame) survived; k0 (stale) did not; k14 (fresh)
    // did. Check survival with `contains`, which does not refresh the LRU
    // order: k5 is the tail after the frame-2 inserts, so the frame-3
    // eviction must pick it. The remaining slots are held only by pinned
    // nodes: k15 cannot land during frame 2.
    try std.testing.expect(atlas.contains(makeKey(0, 5, 8)));
    try std.testing.expect(atlas.contains(makeKey(0, 14, 8)));
    try std.testing.expect(atlas.get(makeKey(0, 0, 8)) == null);
    try std.testing.expectError(error.AtlasFull, atlas.insert(makeKey(0, 15, 8), metrics, .{
        .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
    }));
    try std.testing.expect(atlas.contains(makeKey(0, 5, 8)));

    // Next frame the pin lapses: k15 lands by evicting k5.
    atlas.beginFrame(); // frame 3
    _ = try atlas.insert(makeKey(0, 15, 8), metrics, .{
        .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
    });
    try std.testing.expectEqual(@as(usize, 8), atlas.count());
    try std.testing.expect(atlas.get(makeKey(0, 5, 8)) == null);
    try std.testing.expect(atlas.get(makeKey(0, 15, 8)) != null);
}

test "(d) generation and dirty rects update on insert, cleared by clearDirty" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 64, 32);
    defer atlas.deinit();
    atlas.beginFrame();

    try std.testing.expectEqual(@as(u64, 0), atlas.generation);
    try std.testing.expectEqual(@as(usize, 0), atlas.dirtyRects().len);

    const k1 = makeKey(0, 1, 12);
    const data_a = @as([48]u8, @splat(1));
    const e1 = try atlas.insert(k1, .{}, .{ .format = .a8, .width = 8, .height = 6, .data = &data_a });
    try std.testing.expectEqual(@as(u64, 1), atlas.generation);
    try std.testing.expectEqual(@as(usize, 1), atlas.dirtyRects().len);
    const r1 = atlas.dirtyRects()[0];
    try std.testing.expectEqual(e1.x, r1.x);
    try std.testing.expectEqual(e1.y, r1.y);
    try std.testing.expectEqual(e1.width, r1.width);
    try std.testing.expectEqual(e1.height, r1.height);

    atlas.clearDirty();
    try std.testing.expectEqual(@as(usize, 0), atlas.dirtyRects().len);
    // clearDirty forgets rects but not the generation count.
    try std.testing.expectEqual(@as(u64, 1), atlas.generation);

    const k2 = makeKey(0, 2, 12);
    const data_two = @as([48]u8, @splat(2));
    _ = try atlas.insert(k2, .{}, .{ .format = .a8, .width = 12, .height = 4, .data = &data_two });
    try std.testing.expectEqual(@as(u64, 2), atlas.generation);
    try std.testing.expectEqual(@as(usize, 1), atlas.dirtyRects().len);

    // In-place rewrite of k1 (same size) bumps generation and re-dirties.
    const data_b = @as([48]u8, @splat(9));
    const e1b = try atlas.insert(k1, .{}, .{ .format = .a8, .width = 8, .height = 6, .data = &data_b });
    try std.testing.expectEqual(@as(u64, 3), atlas.generation);
    try std.testing.expectEqual(@as(usize, 2), atlas.dirtyRects().len);
    try std.testing.expectEqual(e1, e1b); // same region, rewritten in place
    const got = atlas.get(k1) orelse return error.TestUnexpectedResult;
    const region = atlas.a8Region(got);
    var out: [8]u8 = undefined;
    copyRegionRow(region, 0, &out);
    try std.testing.expectEqualSlices(u8, data_b[0..8], &out);

    // Lookups and frame boundaries neither dirty nor bump.
    const gen_before = atlas.generation;
    _ = atlas.get(k2);
    atlas.beginFrame();
    try std.testing.expectEqual(gen_before, atlas.generation);
    try std.testing.expectEqual(@as(usize, 2), atlas.dirtyRects().len);

    // A blank glyph only records metrics: no page space, no dirty rect, no
    // generation bump.
    const blank = try atlas.insert(makeKey(0, 3, 12), .{ .advance_x = 4 }, .{
        .format = .a8, .width = 0, .height = 0, .data = &[_]u8{},
    });
    try std.testing.expectEqual(@as(usize, 0), atlas.a8Region(blank).data.len);
    try std.testing.expectEqual(gen_before, atlas.generation);
    try std.testing.expectEqual(@as(usize, 2), atlas.dirtyRects().len);
}

test "(e) auto font size: mm fallback and DPI-based (HiDPI) scaling" {
    // Missing / implausible physical size -> the default, unchanged.
    try std.testing.expectEqual(@as(f32, 12.0), computeAutoFontSize(1920, 1080, 0, 0, 12));
    try std.testing.expectEqual(@as(f32, 12.0), computeAutoFontSize(1920, 1080, 520, 0, 12));
    try std.testing.expectEqual(@as(f32, 12.0), computeAutoFontSize(1920, 1080, 0, 290, 12));
    try std.testing.expectEqual(@as(f32, 12.0), computeAutoFontSize(1920, 1080, -5, -3, 12));
    try std.testing.expectEqual(@as(f32, 12.0), computeAutoFontSize(1920, 1080, std.math.nan(f32), 290, 12));

    // 1920x1080 @ 520x290 mm is ~94 DPI: size ~ default * 94/96.
    const s_94 = computeAutoFontSize(1920, 1080, 520, 290, 10);
    const dpi_94 = s_94 / 10 * baseline_dpi;
    try std.testing.expectApproxEqAbs(@as(f32, 9.7893), s_94, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 93.977), dpi_94, 0.05);
    try std.testing.expect(s_94 < 10); // sub-96 DPI -> slightly below default

    // 3840x2160 @ 344x194 mm is ~283 DPI: strong HiDPI scale-up.
    const s_283 = computeAutoFontSize(3840, 2160, 344, 194, 10);
    const dpi_283 = s_283 / 10 * baseline_dpi;
    try std.testing.expectApproxEqAbs(@as(f32, 29.5165), s_283, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 283.359), dpi_283, 0.1);

    // Monotonic sanity: higher DPI -> larger size; HiDPI (dpi > 140) lands
    // clearly above the default.
    try std.testing.expect(dpi_283 > 140);
    try std.testing.expect(s_283 > s_94);
    try std.testing.expect(s_283 > 2 * s_94);

    // Colossal-but-finite DPI stays linear (no clamping in the formula).
    try std.testing.expect(computeAutoFontSize(7680, 4320, 300, 170, 10) > s_283);
}

test "(f) zoom clamps to bounds (grab-zoom-in / grab-zoom-out)" {
    try std.testing.expectEqual(@as(f32, 10.0), applyZoom(10, 0, 6, 32));
    try std.testing.expectEqual(@as(f32, 12.0), applyZoom(10, 2, 6, 32));
    try std.testing.expectEqual(@as(f32, 8.0), applyZoom(10, -2, 6, 32));
    try std.testing.expectEqual(@as(f32, 32.0), applyZoom(10, 100, 6, 32));
    try std.testing.expectEqual(@as(f32, 6.0), applyZoom(10, -100, 6, 32));
    // kmscon's floor: zoom-out stops at min.
    try std.testing.expectEqual(@as(f32, 1.0), applyZoom(1, -1, 1, 100));
    // Out-of-range current size is clamped into the interval.
    try std.testing.expectEqual(@as(f32, 32.0), applyZoom(99, 0, 6, 32));
    try std.testing.expectEqual(@as(f32, 6.0), applyZoom(-5, 0, 6, 32));
    // More steps, monotonically bigger (until clamped).
    try std.testing.expect(applyZoom(10, 5, 0, 100) > applyZoom(10, 3, 0, 100));
    // Inverted bounds degrade gracefully instead of trapping.
    try std.testing.expectEqual(@as(f32, 8.0), applyZoom(10, -2, 32, 6));
}

test "(g) LRU eviction walks strictly oldest-first and get() reorders" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 32, 16);
    defer atlas.deinit();
    const metrics = InsertMetrics{};

    atlas.beginFrame(); // frame 1: fill all 8 slots; every node is pinned.
    var i: u16 = 0;
    while (i < 8) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
    try std.testing.expectEqual(@as(usize, 8), atlas.count());

    // Frame 2: refresh k2 -> LRU order becomes k0,k1,k3,k4,k5,k6,k7,k2.
    atlas.beginFrame();
    try std.testing.expect(atlas.get(makeKey(0, 2, 8)) != null);

    // Four inserts must evict exactly the four oldest nodes, one per insert,
    // in order: k0, k1, k3, k4 (k2 was refreshed, so it moved behind k7).
    const expected_evictions = [_]u16{ 0, 1, 3, 4 };
    for (expected_evictions, 0..) |glyph, n| {
        const fresh: u16 = 8 + @as(u16, @intCast(n));
        _ = try atlas.insert(makeKey(0, fresh, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
        try std.testing.expectEqual(@as(usize, 8), atlas.count());
        try std.testing.expect(atlas.get(makeKey(0, glyph, 8)) == null);
        try std.testing.expect(atlas.contains(makeKey(0, fresh, 8)));
    }

    // The refreshed node and the never-reached tail of the LRU list survive,
    // together with the four fresh glyphs.
    try std.testing.expect(atlas.contains(makeKey(0, 2, 8)));
    var g: u16 = 5;
    while (g < 12) : (g += 1)
        try std.testing.expect(atlas.contains(makeKey(0, g, 8)));
    try std.testing.expectEqual(@as(usize, 8), atlas.count());
}

test "(h) evicted space coalesces and is reused without new shelf rows" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 16, 16);
    defer atlas.deinit();
    const metrics = InsertMetrics{};

    atlas.beginFrame();
    var i: u16 = 0;
    while (i < 4) : (i += 1)
        _ = try atlas.insert(makeKey(0, i, 8), metrics, .{
            .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
        });
    try std.testing.expectEqual(@as(usize, 4), atlas.count());
    const gen_full = atlas.generation;
    try std.testing.expectEqual(@as(u64, 4), gen_full);
    try std.testing.expectEqual(@as(usize, 4), atlas.dirtyRects().len);

    // Dropping the two top-row neighbours keeps their pixels in the page, so
    // neither generation nor dirty rects may change; only the free list does.
    try atlas.remove(makeKey(0, 0, 8));
    try atlas.remove(makeKey(0, 1, 8));
    try std.testing.expectEqual(gen_full, atlas.generation);
    try std.testing.expectEqual(@as(usize, 4), atlas.dirtyRects().len);

    // The two 8x8 holes coalesce into one 16x8 strip, which is exactly what
    // a 16x8 glyph needs: no shelf row can host it (both rows are full).
    atlas.beginFrame();
    const wide = try atlas.insert(makeKey(1, 0, 16), metrics, .{
        .format = .a8, .width = 16, .height = 8, .data = &empty_16x8,
    });
    try std.testing.expectEqual(@as(u16, 0), wide.x);
    try std.testing.expectEqual(@as(u16, 0), wide.y);
    try std.testing.expectEqual(@as(u16, 16), wide.width);
    try std.testing.expectEqual(@as(u16, 8), wide.height);
    try std.testing.expectEqual(@as(u64, gen_full + 1), atlas.generation);
    try std.testing.expectEqual(@as(usize, 5), atlas.dirtyRects().len);
    // The newest dirty rect is exactly the reused strip.
    const last = atlas.dirtyRects()[atlas.dirtyRects().len - 1];
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 16, .height = 8 }, last);
    try std.testing.expectEqual(@as(usize, 3), atlas.count());

    // The next 8x8 glyph has no shelf space either: it lands only by
    // evicting the LRU node and reusing its rect.
    const bottom = try atlas.insert(makeKey(1, 1, 16), metrics, .{
        .format = .a8, .width = 8, .height = 8, .data = &empty_8x8,
    });
    try std.testing.expectEqual(@as(u16, 0), bottom.x);
    try std.testing.expectEqual(@as(u16, 8), bottom.y);
    try std.testing.expectEqual(@as(usize, 3), atlas.count());
    try std.testing.expect(atlas.get(makeKey(0, 2, 8)) == null);
    try std.testing.expect(atlas.contains(makeKey(0, 3, 8)));
}

test "(i) auto font size: 96 DPI identity, degenerate fallbacks, monotone DPI" {
    // Physical size matching the 96 DPI baseline returns the configured size.
    const mm_w = 1920.0 / baseline_dpi * mm_per_inch;
    const mm_h = 1080.0 / baseline_dpi * mm_per_inch;
    try std.testing.expectApproxEqAbs(
        @as(f32, 12.0),
        computeAutoFontSize(1920, 1080, mm_w, mm_h, 12),
        0.0005,
    );

    // Doubling the DPI doubles the size: the formula is linear, uncapped.
    const hidpi_w = 1920.0 / 192.0 * mm_per_inch;
    const hidpi_h = 1080.0 / 192.0 * mm_per_inch;
    try std.testing.expectApproxEqAbs(
        @as(f32, 24.0),
        computeAutoFontSize(1920, 1080, hidpi_w, hidpi_h, 12),
        0.001,
    );

    // Strictly monotone across 96 -> 110 -> 140 -> 192 DPI.
    var previous: f32 = 0;
    inline for (.{ 96.0, 110.0, 140.0, 192.0 }) |dpi| {
        const w_mm = 1920.0 / dpi * mm_per_inch;
        const h_mm = 1080.0 / dpi * mm_per_inch;
        const size = computeAutoFontSize(1920, 1080, w_mm, h_mm, 10);
        try std.testing.expect(size > previous);
        previous = size;
    }

    // Missing (0 mm) or degenerate geometry falls back to the default.
    try std.testing.expectEqual(@as(f32, 10.0), computeAutoFontSize(1920, 1080, 0, 0, 10));
    try std.testing.expectEqual(@as(f32, 10.0), computeAutoFontSize(0, 1080, 520, 290, 10));
    try std.testing.expectEqual(@as(f32, 10.0), computeAutoFontSize(1920, -1, 520, 290, 10));
    try std.testing.expectEqual(@as(f32, 10.0), computeAutoFontSize(1920, 1080, std.math.inf(f32), 290, 10));
}

test "(j) zoom: fractional steps, degenerate interval, cumulative saturation" {
    // One point per step keeps a fractional current size fractional.
    try std.testing.expectEqual(@as(f32, 11.5), applyZoom(10.5, 1, 6, 32));
    try std.testing.expectEqual(@as(f32, 9.5), applyZoom(10.5, -1, 6, 32));
    // A degenerate interval pins the size regardless of the step.
    try std.testing.expectEqual(@as(f32, 20.0), applyZoom(10, 5, 20, 20));
    try std.testing.expectEqual(@as(f32, 20.0), applyZoom(10, -5, 20, 20));
    // Repeated presses saturate at the bounds instead of overshooting.
    var size: f32 = 31.5;
    var press: u8 = 0;
    while (press < 4) : (press += 1) size = applyZoom(size, 1, 6, 32);
    try std.testing.expectEqual(@as(f32, 32.0), size);
    press = 0;
    while (press < 64) : (press += 1) size = applyZoom(size, -1, 6, 32);
    try std.testing.expectEqual(@as(f32, 6.0), size);
}

test "(k) re-insert with a different size or format repacks under the same key" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 64, 32);
    defer atlas.deinit();
    atlas.beginFrame();

    const key = makeKey(0, 7, 16);
    const first = try atlas.insert(key, .{}, .{ .format = .a8, .width = 8, .height = 8, .data = &empty_8x8 });
    try std.testing.expectEqual(@as(u16, 8), first.width);
    try std.testing.expectEqual(@as(u64, 1), atlas.generation);
    try std.testing.expectEqual(@as(usize, 1), atlas.count());

    // Same key, different size: the old region is dropped without a dirty
    // rect for the hole and a fresh region is packed.
    const second = try atlas.insert(key, .{ .advance_x = 5 }, .{
        .format = .a8, .width = 12, .height = 4, .data = &empty_12x4,
    });
    try std.testing.expectEqual(@as(usize, 1), atlas.count());
    try std.testing.expectEqual(@as(u16, 12), second.width);
    try std.testing.expectEqual(@as(u16, 4), second.height);
    try std.testing.expectEqual(@as(i16, 5), second.advance_x);
    try std.testing.expectEqual(@as(u64, 2), atlas.generation);
    try std.testing.expectEqual(@as(usize, 2), atlas.dirtyRects().len);
    try std.testing.expectEqual(second, atlas.get(key) orelse return error.TestUnexpectedResult);

    // Same key, different format: repacked onto the colour page.
    const third = try atlas.insert(key, .{}, .{
        .format = .bgra8, .width = 12, .height = 4, .data = &empty_bgra_12x4,
    });
    try std.testing.expectEqual(@as(usize, 1), atlas.count());
    try std.testing.expectEqual(PixelFormat.bgra8, third.format);
    try std.testing.expectEqual(@as(u8, 1), third.page);
    try std.testing.expectEqual(@as(u64, 3), atlas.generation);
    try std.testing.expectEqual(@as(usize, 3), atlas.dirtyRects().len);
    try std.testing.expectEqual(third, atlas.get(key) orelse return error.TestUnexpectedResult);
}