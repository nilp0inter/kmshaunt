//! src/render/image.zig -- Kitty image cache and CPU compositor (ROADMAP
//! M4.2/M4.3).
//!
//! Placements arrive as plain Zig structs from the vt layer: this file has
//! no libghostty dependency (decision D1), only std + framebuffer.zig. The
//! placement model mirrors ghostty's render-state image data
//! (docs/reference/ghostty-vt-api.md §9.6): iteration order is not draw
//! order, so placements are sorted by layer, then z ascending (stable),
//! and drawn in three explicit passes so the render loop can interleave
//! the cell background fill and the text pass:
//!
//!     compositeLayer(fb, ps, cache, .below_background);
//!     fb.fill(bg);                    // caller
//!     compositeLayer(fb, ps, cache, .below_text);
//!     drawText(...);                  // caller
//!     compositeLayer(fb, ps, cache, .above_text);
//!
//! `composite` is the all-in-one convenience for callers without text
//! (it cannot draw text, so above_text follows below_text directly).
//!
//! Cache: originals are keyed by (protocol, image id, generation); scaled
//! copies by (key, dst width, dst height). Both kinds share one byte limit
//! and one intrusive LRU list, with the frame-pinning idiom of
//! src/font/atlas.zig: `beginFrame()` bumps a frame counter, every
//! get/put/scaled stamps the node, and eviction skips nodes stamped with
//! the current frame. Unlike the atlas (which returns entries by value),
//! this API hands out `*Image`, so nodes are individually heap-allocated
//! and their addresses stay valid while the cache grows. Explicit deletes
//! (`remove`, `clear`) are unconditional, like atlas.remove; only
//! eviction respects pins. Scaled copies own their pixels and survive
//! eviction of their original; regenerating a new size afterwards fails
//! with ImageNotFound.
//!
//! Blending is Porter-Duff src-over in integer math, round-to-nearest:
//! a_eff = (a*opacity + 127)/255, then per RGB channel
//! out = (s*a_eff + d*(255-a_eff) + 127)/255. The framebuffer is xrgb8888:
//! only RGB is written, the high byte of each word is preserved. Scaling
//! is center-aligned bilinear ((x+0.5)*scale-0.5, edge-clamped); 1:1
//! placements copy verbatim (nearest). The per-pixel blend loop never
//! allocates: the scaled image is produced once, before blending.

const std = @import("std");
const framebuffer = @import("../framebuffer.zig");

pub const Framebuffer = framebuffer.Framebuffer;
pub const Damage = framebuffer.Damage;

/// Identifies one stored image. `generation` changes whenever the pixels
/// may change (send/replace/animation frame), so (protocol, id,
/// generation) is a safe cache key (ghostty-vt-api.md §9.2).
pub const ImageKey = struct {
    protocol: enum { kitty },
    id: u32,
    generation: u32,
};

/// A decoded image. `pixels` is RGBA8, tightly packed row-major:
/// exactly width*height*4 bytes. Decoding happens in the vt layer; the
/// cache owns a copy of whatever it is given.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

/// Draw layers, in draw order (ghostty-vt-api.md §9.6): below_background
/// under the cell backgrounds, below_text under the text, above_text on
/// top of everything.
pub const Layer = enum { below_background, below_text, above_text };

/// One image placement, mirroring ghostty's render-state placement fields
/// as plain data. `dst` is the final destination rectangle in framebuffer
/// pixels; `src` is the crop in image pixels (null = whole image).
/// `cell_offset_x/y` mirror CELL_OFFSET_* (pixel offset within the
/// top-left cell): the vt adapter folds them into `dst` when it builds
/// the placement, so the compositor treats `dst` as authoritative and
/// does not apply them again. `opacity` is 0 (transparent) .. 255
/// (opaque), multiplied into the source alpha.
pub const Placement = struct {
    key: ImageKey,
    layer: Layer,
    z: i32,
    dst: Damage,
    src: ?Damage = null,
    cell_offset_x: i16 = 0,
    cell_offset_y: i16 = 0,
    opacity: u8 = 255,
};

pub const PutError = std.mem.Allocator.Error || error{
    /// Zero dimension, or pixels.len != width*height*4.
    InvalidImage,
    /// Over the byte limit with nothing unpinned left to evict. Usually
    /// transient: retry after the next `beginFrame()`.
    CacheFull,
};

pub const ScaleError = std.mem.Allocator.Error || error{
    /// Zero dimension, or pixels.len != width*height*4.
    InvalidImage,
    /// Zero destination size, or an empty/out-of-bounds source crop.
    InvalidSize,
};

pub const ScaledError = ScaleError || error{
    /// The original image is not cached (evicted or deleted).
    ImageNotFound,
    /// Over the byte limit with nothing unpinned left to evict.
    CacheFull,
};

/// Kitty image cache with LRU eviction and frame pinning (ROADMAP M4.2).
///
/// Threading model: single-threaded, consumed by the renderer between
/// `beginFrame()` calls. Originals and scaled copies share `limit_bytes`
/// (pixel bytes only, not struct overhead) and one LRU list.
///
/// Frame pinning: `beginFrame()` bumps the frame counter; a node's
/// `used_frame` is stamped on every get/put/scaled. Eviction refuses
/// nodes stamped with the current frame, so an image the renderer is
/// using cannot be freed underneath it. Call `beginFrame()` once per
/// rendered frame *before* the first get of that frame. Returned
/// `*Image` pointers stay valid until the entry is removed, cleared, or
/// evicted (which never happens while pinned).
pub const ImageCache = struct {
    allocator: std.mem.Allocator,
    limit_bytes: usize,
    /// Sum of pixel bytes over all live entries (originals + scaled).
    total_bytes: usize = 0,
    /// ImageKey -> original node.
    originals: std.AutoHashMap(ImageKey, *Node),
    /// (ImageKey, dst size) -> scaled-copy node.
    scaled_copies: std.AutoHashMap(ScaledKey, *Node),
    /// MRU end of the LRU list, or null when the cache is empty.
    head: ?*Node = null,
    /// LRU end of the LRU list, or null when the cache is empty.
    tail: ?*Node = null,
    /// Current frame counter (see `beginFrame`).
    frame: u64 = 0,

    const Size = struct { w: u32, h: u32 };

    const ScaledKey = struct {
        key: ImageKey,
        w: u32,
        h: u32,
    };

    /// Individually allocated so `*Image` results survive cache growth
    /// (the atlas uses an index pool because it returns entries by
    /// value; this API returns pointers).
    const Node = struct {
        key: ImageKey,
        /// null = original image; otherwise the scaled copy's dst size.
        scaled_size: ?Size,
        image: Image,
        prev: ?*Node,
        next: ?*Node,
        /// Frame during which this node was last used; pinned while
        /// equal to `frame`.
        used_frame: u64,
    };

    pub fn init(allocator: std.mem.Allocator, limit_bytes: usize) ImageCache {
        return .{
            .allocator = allocator,
            .limit_bytes = limit_bytes,
            .originals = std.AutoHashMap(ImageKey, *Node).init(allocator),
            .scaled_copies = std.AutoHashMap(ScaledKey, *Node).init(allocator),
        };
    }

    pub fn deinit(self: *ImageCache) void {
        self.clear();
        self.originals.deinit();
        self.scaled_copies.deinit();
        self.* = undefined;
    }

    /// Start a new rendered frame. Nodes touched since the previous
    /// `beginFrame()` become evictable; nodes touched after this call are
    /// pinned until the next `beginFrame()`.
    pub fn beginFrame(self: *ImageCache) void {
        self.frame +%= 1;
    }

    /// Store an image under `key`, owning a copy of its pixels. A repeat
    /// put of the same key replaces the pixels (in place when the byte
    /// length matches). Evicts LRU entries when over the limit; fails
    /// with CacheFull when everything left is pinned. The new entry is
    /// pinned for the current frame.
    pub fn put(self: *ImageCache, key: ImageKey, image: Image) PutError!void {
        try checkImage(image);
        const bytes = image.pixels.len;

        if (self.originals.get(key)) |node| {
            // Pin first so makeRoom cannot evict the node being replaced.
            self.touch(node);
            if (node.image.pixels.len == bytes) {
                // The cache owns this buffer (allocator.dupe); Image types
                // it const for readers, so cast for the in-place rewrite.
                @memcpy(@constCast(node.image.pixels), image.pixels);
                node.image.width = image.width;
                node.image.height = image.height;
                return;
            }
            try self.makeRoom(bytes, node.image.pixels.len);
            const copy = try self.allocator.dupe(u8, image.pixels);
            self.total_bytes -= node.image.pixels.len;
            self.allocator.free(node.image.pixels);
            node.image = .{ .width = image.width, .height = image.height, .pixels = copy };
            self.total_bytes += bytes;
            return;
        }

        try self.makeRoom(bytes, 0);
        const copy = try self.allocator.dupe(u8, image.pixels);
        errdefer self.allocator.free(copy);
        _ = try self.addNode(key, null, .{
            .width = image.width,
            .height = image.height,
            .pixels = copy,
        });
        self.total_bytes += bytes;
    }

    /// Look up an original image, promoting it to MRU and pinning it for
    /// the current frame. Null when absent.
    pub fn get(self: *ImageCache, key: ImageKey) ?*Image {
        const node = self.originals.get(key) orelse return null;
        self.touch(node);
        return &node.image;
    }

    /// Bilinear-scaled copy of `key` at `dst_w` x `dst_h`, cached by
    /// (key, dst_w, dst_h) and counted against the same limit. A repeat
    /// call with the same key and size returns the same pointer. The
    /// original must be cached (ImageNotFound otherwise); it is pinned
    /// while its pixels are read. Scaled copies survive eviction of the
    /// original, but new sizes cannot be regenerated afterwards.
    pub fn scaled(self: *ImageCache, key: ImageKey, dst_w: u32, dst_h: u32) ScaledError!*Image {
        if (dst_w == 0 or dst_h == 0) return error.InvalidSize;
        const skey = ScaledKey{ .key = key, .w = dst_w, .h = dst_h };
        if (self.scaled_copies.get(skey)) |node| {
            self.touch(node);
            return &node.image;
        }
        const orig = self.originals.get(key) orelse return error.ImageNotFound;
        self.touch(orig);
        const pixels = try scaleBilinear(self.allocator, orig.image, null, dst_w, dst_h);
        errdefer self.allocator.free(pixels);
        try self.makeRoom(pixels.len, 0);
        const node = try self.addNode(key, .{ .w = dst_w, .h = dst_h }, .{
            .width = dst_w,
            .height = dst_h,
            .pixels = pixels,
        });
        self.total_bytes += pixels.len;
        return &node.image;
    }

    /// Drop every entry (original and scaled) for image `id`, across all
    /// generations: the cache side of kitty's delete commands. Like
    /// atlas.remove this is unconditional -- pins protect against
    /// eviction, not against explicit deletes. The vt layer stops
    /// emitting placements for deleted images, so the current frame's
    /// placement list no longer references them.
    pub fn remove(self: *ImageCache, id: u32) void {
        var cur = self.head;
        while (cur) |node| {
            const next = node.next;
            if (node.key.id == id) self.removeNode(node);
            cur = next;
        }
    }

    /// Drop every entry. The cache stays usable afterwards.
    pub fn clear(self: *ImageCache) void {
        var cur = self.head;
        while (cur) |node| {
            const next = node.next;
            self.allocator.free(node.image.pixels);
            self.allocator.destroy(node);
            cur = next;
        }
        self.head = null;
        self.tail = null;
        self.total_bytes = 0;
        self.originals.clearRetainingCapacity();
        self.scaled_copies.clearRetainingCapacity();
    }

    /// Total pixel bytes held (originals + scaled copies). Struct and
    /// list overhead is not counted.
    pub fn byteSize(self: *const ImageCache) usize {
        return self.total_bytes;
    }

    // ---- eviction ----

    /// Evict LRU entries until `incoming` bytes fit, given `outgoing`
    /// bytes that will be freed by the caller (0 for fresh inserts).
    /// Never evicts a node pinned for the current frame.
    fn makeRoom(self: *ImageCache, incoming: usize, outgoing: usize) error{CacheFull}!void {
        while (self.total_bytes - outgoing + incoming > self.limit_bytes) {
            if (!self.evictOne()) return error.CacheFull;
        }
    }

    /// Evict the least-recently-used node that was not used since the
    /// last `beginFrame()`. Returns false when every live node is pinned.
    fn evictOne(self: *ImageCache) bool {
        var cur = self.tail;
        while (cur) |node| {
            const prev = node.prev;
            if (node.used_frame != self.frame) {
                self.removeNode(node);
                return true;
            }
            cur = prev;
        }
        return false;
    }

    fn removeNode(self: *ImageCache, node: *Node) void {
        self.unlink(node);
        if (node.scaled_size) |sz| {
            _ = self.scaled_copies.remove(.{ .key = node.key, .w = sz.w, .h = sz.h });
        } else {
            _ = self.originals.remove(node.key);
        }
        self.total_bytes -= node.image.pixels.len;
        self.allocator.free(node.image.pixels);
        self.allocator.destroy(node);
    }

    // ---- node pool / LRU list ----

    /// Allocate a node and link it as MRU. All fallible work happens
    /// before any mutation; the caller owns `image.pixels` from here on.
    fn addNode(self: *ImageCache, key: ImageKey, scaled_size: ?Size, image: Image) std.mem.Allocator.Error!*Node {
        if (scaled_size) |sz| {
            try self.scaled_copies.ensureTotalCapacity(self.scaled_copies.count() + 1);
            _ = sz;
        } else {
            try self.originals.ensureTotalCapacity(self.originals.count() + 1);
        }
        const node = try self.allocator.create(Node);
        node.* = .{
            .key = key,
            .scaled_size = scaled_size,
            .image = image,
            .prev = null,
            .next = null,
            .used_frame = self.frame,
        };
        if (scaled_size) |sz| {
            self.scaled_copies.putAssumeCapacity(.{ .key = key, .w = sz.w, .h = sz.h }, node);
        } else {
            self.originals.putAssumeCapacity(key, node);
        }
        self.pushFront(node);
        return node;
    }

    /// Mark a node as used this frame and move it to the MRU end.
    fn touch(self: *ImageCache, node: *Node) void {
        if (self.head != node) {
            self.unlink(node);
            self.pushFront(node);
        } else {
            node.used_frame = self.frame;
        }
    }

    /// Link a node at the MRU end, stamping its frame.
    fn pushFront(self: *ImageCache, node: *Node) void {
        node.used_frame = self.frame;
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| h.prev = node;
        self.head = node;
        if (self.tail == null) self.tail = node;
    }

    /// Detach a node from the LRU list (head/tail/links updated).
    fn unlink(self: *ImageCache, node: *Node) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }
};

/// Validate an image before any state is touched: non-zero dimensions
/// and exactly width*height*4 tightly packed RGBA bytes.
fn checkImage(image: Image) error{InvalidImage}!void {
    if (image.width == 0 or image.height == 0) return error.InvalidImage;
    const area = std.math.mul(usize, image.width, image.height) catch return error.InvalidImage;
    const needed = std.math.mul(usize, area, 4) catch return error.InvalidImage;
    if (image.pixels.len != needed) return error.InvalidImage;
}

/// Bilinearly scale `src` (or its `src_rect` crop, clamped to the image
/// bounds like ghostty's source rects) to `dst_w` x `dst_h`. Returns a
/// freshly allocated tightly packed RGBA8 buffer; the caller frees it.
///
/// Sampling is center-aligned: destination pixel x maps to source
/// coordinate (x+0.5)*src_w/dst_w - 0.5, clamped to [0, src_w-1] (edge
/// clamp, no wrap), then bilinearly interpolated over the four neighbors
/// in all four channels. The column sample table is computed once; the
/// pixel loop itself does not allocate.
pub fn scaleBilinear(
    alloc: std.mem.Allocator,
    src: Image,
    src_rect: ?Damage,
    dst_w: u32,
    dst_h: u32,
) ScaleError![]u8 {
    try checkImage(src);
    if (dst_w == 0 or dst_h == 0) return error.InvalidSize;
    const full = Damage{ .x = 0, .y = 0, .w = src.width, .h = src.height };
    const rect = (src_rect orelse full).clipTo(src.width, src.height) orelse return error.InvalidSize;

    const out_len = std.math.mul(usize, dst_w, dst_h) catch return error.InvalidSize;
    const out_bytes = std.math.mul(usize, out_len, 4) catch return error.InvalidSize;
    const out = try alloc.alloc(u8, out_bytes);
    errdefer alloc.free(out);

    const sw: f32 = @floatFromInt(rect.w);
    const sh: f32 = @floatFromInt(rect.h);
    const x_scale = sw / @as(f32, @floatFromInt(dst_w));
    const y_scale = sh / @as(f32, @floatFromInt(dst_h));

    const Col = struct { x0: u32, x1: u32, fx: f32 };
    const cols = try alloc.alloc(Col, dst_w);
    defer alloc.free(cols);
    for (cols, 0..) |*c, x| {
        const sx = (@as(f32, @floatFromInt(x)) + 0.5) * x_scale - 0.5;
        const cx = std.math.clamp(sx, 0.0, sw - 1.0);
        const x0: u32 = @intFromFloat(cx);
        c.* = .{
            .x0 = x0,
            .x1 = @min(x0 + 1, rect.w - 1),
            .fx = cx - @as(f32, @floatFromInt(x0)),
        };
    }

    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        const sy = (@as(f32, @floatFromInt(y)) + 0.5) * y_scale - 0.5;
        const cy = std.math.clamp(sy, 0.0, sh - 1.0);
        const y0: u32 = @intFromFloat(cy);
        const y1 = @min(y0 + 1, rect.h - 1);
        const fy = cy - @as(f32, @floatFromInt(y0));
        const row0 = src.pixels[pixelOffset(rect.x, rect.y + y0, src.width)..];
        const row1 = src.pixels[pixelOffset(rect.x, rect.y + y1, src.width)..];
        const dst_row = out[pixelOffset(0, y, dst_w)..][0 .. @as(usize, dst_w) * 4];
        for (cols, 0..) |c, x| {
            const p00 = row0[@as(usize, c.x0) * 4 ..][0..4];
            const p10 = row0[@as(usize, c.x1) * 4 ..][0..4];
            const p01 = row1[@as(usize, c.x0) * 4 ..][0..4];
            const p11 = row1[@as(usize, c.x1) * 4 ..][0..4];
            const dp = dst_row[x * 4 ..][0..4];
            inline for (0..4) |ch| {
                const top = lerp(@floatFromInt(p00[ch]), @floatFromInt(p10[ch]), c.fx);
                const bot = lerp(@floatFromInt(p01[ch]), @floatFromInt(p11[ch]), c.fx);
                const v = lerp(top, bot, fy);
                dp[ch] = @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
            }
        }
    }
    return out;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn pixelOffset(x: u32, y: u32, width: u32) usize {
    return (@as(usize, y) * width + x) * 4;
}

/// Draw every placement of `layer` into `fb`, sorted by z ascending
/// (stable: equal z keeps input order). The render loop calls this three
/// times per frame, interleaving its background fill and text pass:
/// below_background -> bg fill -> below_text -> text -> above_text.
///
/// Images missing from the cache are skipped (deleted or evicted);
/// dst is clipped to the framebuffer. Scratch for the sort uses the
/// cache's allocator; the per-pixel blend loop does not allocate.
pub fn compositeLayer(
    fb: *Framebuffer,
    placements: []const Placement,
    cache: *ImageCache,
    layer: Layer,
) !void {
    var idxs: std.ArrayList(usize) = .empty;
    defer idxs.deinit(cache.allocator);
    for (placements, 0..) |p, i| {
        if (p.layer == layer) try idxs.append(cache.allocator, i);
    }
    if (idxs.items.len == 0) return;
    std.mem.sort(usize, idxs.items, placements, struct {
        fn lessThan(ps: []const Placement, a: usize, b: usize) bool {
            return ps[a].z < ps[b].z;
        }
    }.lessThan);
    // Pin every image this pass will draw before any scaling can evict:
    // the placement list is the frame's reference set (see beginFrame).
    for (idxs.items) |i| _ = cache.get(placements[i].key);
    for (idxs.items) |i| try drawPlacement(fb, placements[i], cache);
}

/// All-in-one convenience: below_background, then the `bg_color` fill,
/// then below_text, then above_text. Callers that draw text use
/// `compositeLayer` directly so the text pass lands between below_text
/// and above_text.
pub fn composite(
    fb: *Framebuffer,
    placements: []const Placement,
    cache: *ImageCache,
    bg_color: u32,
) !void {
    try compositeLayer(fb, placements, cache, .below_background);
    fb.fill(bg_color);
    try compositeLayer(fb, placements, cache, .below_text);
    try compositeLayer(fb, placements, cache, .above_text);
}

fn drawPlacement(fb: *Framebuffer, p: Placement, cache: *ImageCache) !void {
    if (p.opacity == 0 or p.dst.isEmpty()) return;
    const img = cache.get(p.key) orelse return;
    const full = Damage{ .x = 0, .y = 0, .w = img.width, .h = img.height };
    const src_req = p.src orelse full;
    if (src_req.isEmpty()) return;
    const crop = src_req.clipTo(img.width, img.height) orelse return;

    // A crop clamped at the image edge keeps its geometry: shrink dst by
    // the same fraction (ghostty clamps source rects before reporting).
    const unclamped = crop.x == src_req.x and crop.y == src_req.y and
        crop.w == src_req.w and crop.h == src_req.h;
    const dst_eff = if (unclamped) p.dst else mapRect(crop, src_req, p.dst);
    const vis = dst_eff.clipTo(fb.width, fb.height) orelse return;
    const ox = vis.x - dst_eff.x;
    const oy = vis.y - dst_eff.y;

    if (crop.w == dst_eff.w and crop.h == dst_eff.h) {
        // 1:1: nearest, verbatim pixels, no resampling.
        blendOver(fb, vis, img.pixels, img.width, crop.x + ox, crop.y + oy, p.opacity);
        return;
    }
    if (crop.x == 0 and crop.y == 0 and crop.w == img.width and crop.h == img.height) {
        // Whole image: the scaled copy is cacheable by (key, dst size).
        // Scale the full dst once, then blend only the visible part, so
        // center-aligned samples stay correct at the clip edges.
        const scaled_img = try cache.scaled(p.key, dst_eff.w, dst_eff.h);
        blendOver(fb, vis, scaled_img.pixels, scaled_img.width, ox, oy, p.opacity);
        return;
    }
    // Cropped: the scaled-cache key has no crop dimension, so scale this
    // placement's crop into scratch and free it after blending.
    const pixels = try scaleBilinear(cache.allocator, img.*, crop, dst_eff.w, dst_eff.h);
    defer cache.allocator.free(pixels);
    blendOver(fb, vis, pixels, dst_eff.w, ox, oy, p.opacity);
}

/// Map `r` (a sub-rect of `from`) proportionally into `to`. All operands
/// non-empty; u64 math so u32 extents cannot overflow. The result stays
/// inside `to` (floor division), possibly empty when the fraction rounds
/// down to zero.
fn mapRect(r: Damage, from: Damage, to: Damage) Damage {
    const x: u64 = to.x + @as(u64, r.x - from.x) * to.w / from.w;
    const y: u64 = to.y + @as(u64, r.y - from.y) * to.h / from.h;
    const w: u64 = @as(u64, r.w) * to.w / from.w;
    const h: u64 = @as(u64, r.h) * to.h / from.h;
    return .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) };
}

/// Porter-Duff src-over of RGBA source pixels onto the framebuffer, with
/// `opacity` multiplied into the source alpha. `vis` is the destination
/// rect (already clipped); source pixel (sx, sy) lands on its top-left.
/// Integer round-to-nearest math:
///   a_eff = (a*opacity + 127) / 255
///   out   = (s*a_eff + d*(255 - a_eff) + 127) / 255   per RGB channel
/// Only RGB is written (xrgb8888); the high byte of each destination
/// word is preserved. No allocation.
fn blendOver(
    fb: *Framebuffer,
    vis: Damage,
    src: []const u8,
    src_width: u32,
    sx: u32,
    sy: u32,
    opacity: u8,
) void {
    if (opacity == 0) return;
    var row: u32 = 0;
    while (row < vis.h) : (row += 1) {
        const src_row = src[pixelOffset(sx, sy + row, src_width)..][0 .. @as(usize, vis.w) * 4];
        const dst_off = @as(usize, vis.y + row) * fb.pitch + @as(usize, vis.x) * 4;
        const dst_row = fb.mem[dst_off..][0 .. @as(usize, vis.w) * 4];
        var i: usize = 0;
        while (i < vis.w) : (i += 1) {
            const sp = src_row[i * 4 ..][0..4];
            const a_eff = (@as(u32, sp[3]) * opacity + 127) / 255;
            if (a_eff == 0) continue;
            const dp = dst_row[i * 4 ..][0..4];
            if (a_eff == 255) {
                // Opaque: copy RGB, leave the high byte alone.
                dp[0] = sp[2]; // B
                dp[1] = sp[1]; // G
                dp[2] = sp[0]; // R
                continue;
            }
            // Little-endian xrgb8888 word: bytes are [B, G, R, X].
            const dw = std.mem.readInt(u32, dp, .little);
            const inv = 255 - a_eff;
            const r = blendChannel(sp[0], (dw >> 16) & 0xFF, a_eff, inv);
            const g = blendChannel(sp[1], (dw >> 8) & 0xFF, a_eff, inv);
            const b = blendChannel(sp[2], dw & 0xFF, a_eff, inv);
            const out = (dw & 0xFF000000) | (r << 16) | (g << 8) | b;
            std.mem.writeInt(u32, dp, out, .little);
        }
    }
}

fn blendChannel(s: u8, d: u32, a: u32, inv: u32) u32 {
    return (@as(u32, s) * a + d * inv + 127) / 255;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn imgKey(id: u32, generation: u32) ImageKey {
    return .{ .protocol = .kitty, .id = id, .generation = generation };
}

fn makePixels(comptime w: usize, comptime h: usize, color: [4]u8) [w * h * 4]u8 {
    var buf: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        @memcpy(buf[i * 4 ..][0 .. 4], &color);
    }
    return buf;
}

fn expectPixel(pixels: []const u8, width: u32, x: u32, y: u32, rgba: [4]u8) !void {
    const off = (@as(usize, y) * width + x) * 4;
    try testing.expectEqualSlices(u8, &rgba, pixels[off..][0..4]);
}

/// 2x2 RGBA: A red, B green / C blue, D yellow.
const gradient2x2 = [_]u8{
    255, 0,   0,   255,
    0,   255, 0,   255,
    0,   0,   255, 255,
    255, 255, 0,   255,
};

test "image cache: put/get round-trip, owned copy, byte accounting" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 1024);
    defer cache.deinit();

    const px = makePixels(2, 2, .{ 1, 2, 3, 4 });
    try cache.put(imgKey(7, 1), .{ .width = 2, .height = 2, .pixels = &px });
    try testing.expectEqual(@as(usize, 16), cache.byteSize());

    const got = cache.get(imgKey(7, 1)).?;
    try testing.expectEqual(@as(u32, 2), got.width);
    try testing.expectEqual(@as(u32, 2), got.height);
    try testing.expectEqualSlices(u8, &px, got.pixels);
    try testing.expect(cache.get(imgKey(8, 1)) == null);

    // The cache owns a copy: mutating the caller's buffer changes nothing.
    var mutable = makePixels(1, 1, .{ 9, 9, 9, 9 });
    try cache.put(imgKey(9, 1), .{ .width = 1, .height = 1, .pixels = &mutable });
    mutable[0] = 0;
    try testing.expectEqual(@as(u8, 9), cache.get(imgKey(9, 1)).?.pixels[0]);
    try testing.expectEqual(@as(usize, 20), cache.byteSize());

    // Bad images are rejected without touching the cache.
    try testing.expectError(error.InvalidImage, cache.put(imgKey(10, 1), .{ .width = 2, .height = 2, .pixels = px[0..15] }));
    try testing.expectError(error.InvalidImage, cache.put(imgKey(10, 1), .{ .width = 0, .height = 2, .pixels = &.{} }));
    try testing.expectEqual(@as(usize, 20), cache.byteSize());
}

test "image cache: LRU eviction over the limit" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 32);
    defer cache.deinit();
    const px = makePixels(2, 2, .{ 1, 1, 1, 255 });
    const img = Image{ .width = 2, .height = 2, .pixels = &px };

    try cache.put(imgKey(1, 1), img);
    try cache.put(imgKey(2, 1), img);
    try testing.expectEqual(@as(usize, 32), cache.byteSize());

    // puts pin entries; a new frame makes them evictable, and touching
    // A then makes B the LRU victim.
    cache.beginFrame();
    try testing.expect(cache.get(imgKey(1, 1)) != null);
    try cache.put(imgKey(3, 1), img);
    try testing.expect(cache.get(imgKey(2, 1)) == null);
    try testing.expect(cache.get(imgKey(1, 1)) != null);
    try testing.expect(cache.get(imgKey(3, 1)) != null);
    try testing.expectEqual(@as(usize, 32), cache.byteSize());

    // Without a touch, insertion order decides: A goes first.
    var cache2 = ImageCache.init(a, 32);
    defer cache2.deinit();
    try cache2.put(imgKey(1, 1), img);
    try cache2.put(imgKey(2, 1), img);
    cache2.beginFrame();
    try cache2.put(imgKey(3, 1), img);
    try testing.expect(cache2.get(imgKey(1, 1)) == null);
    try testing.expect(cache2.get(imgKey(2, 1)) != null);
    try testing.expect(cache2.get(imgKey(3, 1)) != null);
}

test "image cache: oversized image and zero limit are rejected" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 16);
    defer cache.deinit();
    const px = makePixels(4, 4, .{ 0, 0, 0, 255 });
    try testing.expectError(error.CacheFull, cache.put(imgKey(1, 1), .{ .width = 4, .height = 4, .pixels = &px }));
    try testing.expectEqual(@as(usize, 0), cache.byteSize());

    var zero = ImageCache.init(a, 0);
    defer zero.deinit();
    const one = makePixels(1, 1, .{ 0, 0, 0, 255 });
    try testing.expectError(error.CacheFull, zero.put(imgKey(1, 1), .{ .width = 1, .height = 1, .pixels = &one }));
}

test "image cache: frame pinning protects the current frame" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 16);
    defer cache.deinit();
    const px = makePixels(2, 2, .{ 1, 2, 3, 255 });
    const img = Image{ .width = 2, .height = 2, .pixels = &px };

    // put stamps the frame too: A is pinned until beginFrame.
    try cache.put(imgKey(1, 1), img);
    try testing.expectError(error.CacheFull, cache.put(imgKey(2, 1), img));

    cache.beginFrame();
    try testing.expect(cache.get(imgKey(1, 1)) != null); // pins A for this frame
    try testing.expectError(error.CacheFull, cache.put(imgKey(2, 1), img));
    try testing.expectEqual(@as(usize, 16), cache.byteSize());

    // Next frame: A becomes evictable.
    cache.beginFrame();
    try cache.put(imgKey(2, 1), img);
    try testing.expect(cache.get(imgKey(1, 1)) == null);
    try testing.expect(cache.get(imgKey(2, 1)) != null);
    try testing.expectEqual(@as(usize, 16), cache.byteSize());
}

test "image cache: put replaces an existing key" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 1024);
    defer cache.deinit();
    const red = makePixels(2, 2, .{ 255, 0, 0, 255 });
    const blue = makePixels(2, 2, .{ 0, 0, 255, 255 });
    const big = makePixels(4, 4, .{ 0, 255, 0, 255 });

    try cache.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &red });
    const p1 = cache.get(imgKey(1, 1)).?;
    try cache.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &blue });
    try testing.expectEqual(p1, cache.get(imgKey(1, 1)).?); // same node, new pixels
    try testing.expectEqualSlices(u8, &blue, cache.get(imgKey(1, 1)).?.pixels);
    try testing.expectEqual(@as(usize, 16), cache.byteSize());

    // Different size: buffer swapped, accounting adjusted, node kept.
    try cache.put(imgKey(1, 1), .{ .width = 4, .height = 4, .pixels = &big });
    try testing.expectEqual(p1, cache.get(imgKey(1, 1)).?);
    try testing.expectEqual(@as(u32, 4), cache.get(imgKey(1, 1)).?.width);
    try testing.expectEqual(@as(usize, 64), cache.byteSize());

    // A replacement that cannot fit leaves the old entry intact.
    var tight = ImageCache.init(a, 16);
    defer tight.deinit();
    try tight.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &red });
    tight.beginFrame();
    try testing.expectError(error.CacheFull, tight.put(imgKey(1, 1), .{ .width = 4, .height = 4, .pixels = &big }));
    try testing.expectEqual(@as(usize, 16), tight.byteSize());
    try testing.expectEqualSlices(u8, &red, tight.get(imgKey(1, 1)).?.pixels);
}

test "image cache: scaled copies hit by key+size and count against the limit" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 1024);
    defer cache.deinit();
    const img = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    try cache.put(imgKey(1, 1), img);

    const s1 = try cache.scaled(imgKey(1, 1), 4, 4);
    try testing.expectEqual(@as(usize, 16 + 64), cache.byteSize());
    const s2 = try cache.scaled(imgKey(1, 1), 4, 4);
    try testing.expectEqual(s1, s2); // cache hit: same pointer
    try testing.expectEqual(@as(usize, 16 + 64), cache.byteSize());

    // Contents match a direct bilinear scale.
    const direct = try scaleBilinear(a, img, null, 4, 4);
    defer a.free(direct);
    try testing.expectEqualSlices(u8, direct, s1.pixels);

    // A different size is a different entry.
    const s3 = try cache.scaled(imgKey(1, 1), 8, 8);
    try testing.expect(s3 != s1);
    try testing.expectEqual(@as(usize, 16 + 64 + 256), cache.byteSize());

    try testing.expectError(error.ImageNotFound, cache.scaled(imgKey(99, 1), 4, 4));
    try testing.expectError(error.InvalidSize, cache.scaled(imgKey(1, 1), 0, 4));
    try testing.expectError(error.InvalidSize, cache.scaled(imgKey(1, 1), 4, 0));
}

test "image cache: scaled eviction respects limit and pins" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 80);
    defer cache.deinit();
    const img = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    try cache.put(imgKey(1, 1), img);
    _ = try cache.scaled(imgKey(1, 1), 4, 4); // 16 + 64 = 80, at the limit

    cache.beginFrame();
    // 256 bytes cannot fit: the unpinned scaled copy is evicted, the
    // original is pinned by scaled() itself, so the insert fails cleanly.
    try testing.expectError(error.CacheFull, cache.scaled(imgKey(1, 1), 8, 8));
    try testing.expectEqual(@as(usize, 16), cache.byteSize());
    try testing.expect(cache.get(imgKey(1, 1)) != null);

    // Pins also block plain puts while both entries are hot.
    var cache2 = ImageCache.init(a, 80);
    defer cache2.deinit();
    try cache2.put(imgKey(1, 1), img);
    _ = try cache2.scaled(imgKey(1, 1), 4, 4);
    const px = makePixels(2, 2, .{ 0, 0, 0, 255 });
    try testing.expectError(error.CacheFull, cache2.put(imgKey(2, 1), .{ .width = 2, .height = 2, .pixels = &px }));
    try testing.expectEqual(@as(usize, 80), cache2.byteSize());
    cache2.beginFrame();
    try cache2.put(imgKey(2, 1), .{ .width = 2, .height = 2, .pixels = &px });
    try testing.expectEqual(@as(usize, 80), cache2.byteSize());
}

test "image cache: scaled copies outlive their original" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 80);
    defer cache.deinit();
    const img = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    try cache.put(imgKey(1, 1), img);
    const s1 = try cache.scaled(imgKey(1, 1), 4, 4);

    cache.beginFrame();
    // A new original evicts the LRU original; the scaled copy stays.
    const px = makePixels(2, 2, .{ 0, 0, 0, 255 });
    try cache.put(imgKey(2, 1), .{ .width = 2, .height = 2, .pixels = &px });
    try testing.expect(cache.get(imgKey(1, 1)) == null);
    try testing.expectEqual(s1, try cache.scaled(imgKey(1, 1), 4, 4));
    try testing.expectEqual(@as(usize, 80), cache.byteSize());
    // New sizes can no longer be regenerated.
    try testing.expectError(error.ImageNotFound, cache.scaled(imgKey(1, 1), 8, 8));
}

test "image cache: remove(id) drops originals and scaled copies" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 1024);
    defer cache.deinit();
    const px = makePixels(2, 2, .{ 1, 2, 3, 255 });
    const img = Image{ .width = 2, .height = 2, .pixels = &px };
    try cache.put(imgKey(1, 1), img);
    try cache.put(imgKey(1, 2), img);
    try cache.put(imgKey(2, 1), img);
    _ = try cache.scaled(imgKey(1, 1), 4, 4);
    try testing.expectEqual(@as(usize, 16 * 3 + 64), cache.byteSize());

    cache.remove(1);
    try testing.expect(cache.get(imgKey(1, 1)) == null);
    try testing.expect(cache.get(imgKey(1, 2)) == null);
    try testing.expectError(error.ImageNotFound, cache.scaled(imgKey(1, 1), 4, 4));
    try testing.expect(cache.get(imgKey(2, 1)) != null);
    try testing.expectEqual(@as(usize, 16), cache.byteSize());

    cache.remove(999); // unknown id: no-op
    try testing.expectEqual(@as(usize, 16), cache.byteSize());
}

test "image cache: clear drops everything and stays usable" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 1024);
    defer cache.deinit();
    const img = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    try cache.put(imgKey(1, 1), img);
    try cache.put(imgKey(2, 1), img);
    _ = try cache.scaled(imgKey(1, 1), 4, 4);

    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.byteSize());
    try testing.expect(cache.get(imgKey(1, 1)) == null);
    try testing.expect(cache.get(imgKey(2, 1)) == null);
    try testing.expectError(error.ImageNotFound, cache.scaled(imgKey(1, 1), 4, 4));

    try cache.put(imgKey(3, 1), img);
    try testing.expectEqual(@as(usize, 16), cache.byteSize());
    try testing.expect(cache.get(imgKey(3, 1)) != null);
}

test "scaleBilinear: 2x2 -> 4x4 center samples match hand-computed values" {
    const a = testing.allocator;
    const src = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    const out = try scaleBilinear(a, src, null, 4, 4);
    defer a.free(out);

    // scale = 0.5; sample coords per axis: [-0.25, 0.25, 0.75, 1.25]
    // clamped to [0, 0.25, 0.75, 1]. Corners are the source pixels.
    try expectPixel(out, 4, 0, 0, .{ 255, 0, 0, 255 }); // A
    try expectPixel(out, 4, 3, 0, .{ 0, 255, 0, 255 }); // B
    try expectPixel(out, 4, 0, 3, .{ 0, 0, 255, 255 }); // C
    try expectPixel(out, 4, 3, 3, .{ 255, 255, 0, 255 }); // D
    // Edge midpoints: 0.75*A + 0.25*B = (191.25, 63.75, 0) -> (191, 64, 0).
    try expectPixel(out, 4, 1, 0, .{ 191, 64, 0, 255 });
    try expectPixel(out, 4, 2, 0, .{ 64, 191, 0, 255 });
    try expectPixel(out, 4, 0, 1, .{ 191, 0, 64, 255 });
    try expectPixel(out, 4, 3, 1, .{ 64, 255, 0, 255 }); // lerp(B, D, 0.25)
    try expectPixel(out, 4, 1, 3, .{ 64, 64, 191, 255 }); // lerp(C, D, 0.25)
    // Interior samples, weights w00/w10/w01/w11 = (1-fx)(1-fy)/fx(1-fy)/
    // (1-fx)fy/fx*fy over A/B/C/D:
    // (1,1) fx=fy=0.25: (159.375, 63.75, 47.8125) -> (159, 64, 48)
    try expectPixel(out, 4, 1, 1, .{ 159, 64, 48, 255 });
    // (2,1) fx=0.75, fy=0.25: (95.625, 191.25, 15.9375) -> (96, 191, 16)
    try expectPixel(out, 4, 2, 1, .{ 96, 191, 16, 255 });
    // (2,2) fx=fy=0.75: (159.375, 191.25, 47.8125) -> (159, 191, 48)
    try expectPixel(out, 4, 2, 2, .{ 159, 191, 48, 255 });
}

test "scaleBilinear: solid color stays solid" {
    const a = testing.allocator;
    const px = makePixels(3, 2, .{ 10, 20, 30, 40 });
    const src = Image{ .width = 3, .height = 2, .pixels = &px };
    const out = try scaleBilinear(a, src, null, 7, 5);
    defer a.free(out);
    for (0..5) |y| {
        for (0..7) |x| {
            try expectPixel(out, 7, @intCast(x), @intCast(y), .{ 10, 20, 30, 40 });
        }
    }
}

test "scaleBilinear: crop rect respected and clamped" {
    const a = testing.allocator;
    // 4x4 gradient: pixel (x, y) = (x*10, y*10, 0, 255).
    var grad: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            @memcpy(grad[(y * 4 + x) * 4 ..][0 .. 4], &[_]u8{ @intCast(x * 10), @intCast(y * 10), 0, 255 });
        }
    }
    const src = Image{ .width = 4, .height = 4, .pixels = &grad };
    const crop = Damage{ .x = 1, .y = 1, .w = 2, .h = 2 };

    // 1:1 crop: verbatim pixels.
    const same = try scaleBilinear(a, src, crop, 2, 2);
    defer a.free(same);
    try expectPixel(same, 2, 0, 0, .{ 10, 10, 0, 255 });
    try expectPixel(same, 2, 1, 0, .{ 20, 10, 0, 255 });
    try expectPixel(same, 2, 0, 1, .{ 10, 20, 0, 255 });
    try expectPixel(same, 2, 1, 1, .{ 20, 20, 0, 255 });

    // Upscaled crop: corners are the crop's corners (edge clamping).
    const up = try scaleBilinear(a, src, crop, 4, 4);
    defer a.free(up);
    try expectPixel(up, 4, 0, 0, .{ 10, 10, 0, 255 });
    try expectPixel(up, 4, 3, 0, .{ 20, 10, 0, 255 });
    try expectPixel(up, 4, 0, 3, .{ 10, 20, 0, 255 });
    try expectPixel(up, 4, 3, 3, .{ 20, 20, 0, 255 });

    // Out-of-bounds crop is clamped to the image, not an error.
    const clamped = try scaleBilinear(a, src, .{ .x = 1, .y = 1, .w = 9, .h = 9 }, 3, 3);
    defer a.free(clamped);
    try expectPixel(clamped, 3, 0, 0, .{ 10, 10, 0, 255 });
    try expectPixel(clamped, 3, 2, 2, .{ 30, 30, 0, 255 });
}

test "scaleBilinear: invalid inputs" {
    const a = testing.allocator;
    const src = Image{ .width = 2, .height = 2, .pixels = &gradient2x2 };
    try testing.expectError(error.InvalidSize, scaleBilinear(a, src, null, 0, 4));
    try testing.expectError(error.InvalidSize, scaleBilinear(a, src, null, 4, 0));
    try testing.expectError(error.InvalidSize, scaleBilinear(a, src, .{ .x = 0, .y = 0, .w = 0, .h = 2 }, 4, 4));
    try testing.expectError(error.InvalidSize, scaleBilinear(a, src, .{ .x = 2, .y = 0, .w = 1, .h = 1 }, 4, 4));
    try testing.expectError(error.InvalidImage, scaleBilinear(a, .{ .width = 2, .height = 2, .pixels = gradient2x2[0..15] }, null, 4, 4));
}

test "composite: layer passes interleave with the caller background fill" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const red = makePixels(2, 2, .{ 255, 0, 0, 255 });
    const green = makePixels(2, 2, .{ 0, 255, 0, 255 });
    const blue = makePixels(2, 2, .{ 0, 0, 255, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &red });
    try cache.put(imgKey(2, 1), .{ .width = 2, .height = 2, .pixels = &green });
    try cache.put(imgKey(3, 1), .{ .width = 2, .height = 2, .pixels = &blue });

    var fb = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb.destroy(a);
    const dst = Damage{ .x = 0, .y = 0, .w = 2, .h = 2 };
    const ps = [_]Placement{
        .{ .key = imgKey(2, 1), .layer = .below_text, .z = 0, .dst = dst },
        .{ .key = imgKey(3, 1), .layer = .above_text, .z = 0, .dst = dst },
        .{ .key = imgKey(1, 1), .layer = .below_background, .z = 0, .dst = dst },
    };

    try compositeLayer(&fb, &ps, &cache, .below_background);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(0, 0));
    fb.fill(0x0000FF); // caller's background covers below_background
    try testing.expectEqual(@as(u32, 0x0000FF), fb.get(0, 0));
    try compositeLayer(&fb, &ps, &cache, .below_text);
    try testing.expectEqual(@as(u32, 0x00FF00), fb.get(0, 0));
    // (caller draws text here)
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x0000FF), fb.get(0, 0));
    try testing.expectEqual(@as(u32, 0x0000FF), fb.get(3, 3)); // untouched bg

    // All-in-one composite: bb -> bg fill -> bt -> at.
    var fb2 = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb2.destroy(a);
    const ps2 = [_]Placement{
        .{ .key = imgKey(1, 1), .layer = .below_background, .z = 0, .dst = dst },
        .{ .key = imgKey(2, 1), .layer = .below_text, .z = 0, .dst = dst },
    };
    try composite(&fb2, &ps2, &cache, 0x123456);
    try testing.expectEqual(@as(u32, 0x00FF00), fb2.get(0, 0));
    try testing.expectEqual(@as(u32, 0x123456), fb2.get(3, 3));

    // below_background alone ends up under the background fill.
    var fb3 = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb3.destroy(a);
    const ps3 = [_]Placement{ps[2]};
    try composite(&fb3, &ps3, &cache, 0xABCDEF);
    try testing.expectEqual(@as(u32, 0xABCDEF), fb3.get(0, 0));
}

test "composite: z order within a layer, stable for equal z" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const red = makePixels(1, 1, .{ 255, 0, 0, 255 });
    const green = makePixels(1, 1, .{ 0, 255, 0, 255 });
    const blue = makePixels(1, 1, .{ 0, 0, 255, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 1, .height = 1, .pixels = &red });
    try cache.put(imgKey(2, 1), .{ .width = 1, .height = 1, .pixels = &green });
    try cache.put(imgKey(3, 1), .{ .width = 1, .height = 1, .pixels = &blue });

    var fb = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer fb.destroy(a);
    const dst = Damage{ .x = 0, .y = 0, .w = 1, .h = 1 };

    // Input order z2, z1, z1: ascending z draws red, blue, green.
    const ps = [_]Placement{
        .{ .key = imgKey(2, 1), .layer = .above_text, .z = 2, .dst = dst },
        .{ .key = imgKey(1, 1), .layer = .above_text, .z = 1, .dst = dst },
        .{ .key = imgKey(3, 1), .layer = .above_text, .z = 1, .dst = dst },
    };
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x00FF00), fb.get(0, 0));

    // Equal z keeps input order: blue (later) over red.
    fb.fill(0);
    const eq = [_]Placement{
        .{ .key = imgKey(1, 1), .layer = .above_text, .z = 5, .dst = dst },
        .{ .key = imgKey(3, 1), .layer = .above_text, .z = 5, .dst = dst },
    };
    try compositeLayer(&fb, &eq, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x0000FF), fb.get(0, 0));

    // Layer dominates z: above_text z=-5 draws over below_background z=100.
    fb.fill(0);
    const cross = [_]Placement{
        .{ .key = imgKey(1, 1), .layer = .below_background, .z = 100, .dst = dst },
        .{ .key = imgKey(2, 1), .layer = .above_text, .z = -5, .dst = dst },
    };
    try compositeLayer(&fb, &cross, &cache, .below_background);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(0, 0));
    try compositeLayer(&fb, &cross, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x00FF00), fb.get(0, 0));
}

test "composite: opacity 50% blends the exact midpoint" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const white = makePixels(1, 1, .{ 255, 255, 255, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 1, .height = 1, .pixels = &white });

    var fb = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer fb.destroy(a); // zeroed = black
    const dst = Damage{ .x = 0, .y = 0, .w = 1, .h = 1 };

    const half = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = dst, .opacity = 128 }};
    try compositeLayer(&fb, &half, &cache, .above_text);
    // a_eff = 128: (255*128 + 0*127 + 127)/255 = 128 exactly.
    try testing.expectEqual(@as(u32, 0x808080), fb.get(0, 0));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(1, 1));

    const full = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = dst, .opacity = 255 }};
    try compositeLayer(&fb, &full, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFFFFFF), fb.get(0, 0));

    fb.fill(0x123456);
    const none = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = dst, .opacity = 0 }};
    try compositeLayer(&fb, &none, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x123456), fb.get(0, 0));
}

test "composite: src-over alpha math is exact" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const px = [_]u8{ 200, 100, 50, 128 };
    try cache.put(imgKey(1, 1), .{ .width = 1, .height = 1, .pixels = &px });

    var fb = try Framebuffer.create(a, 1, 1, .xrgb8888, null);
    defer fb.destroy(a);
    fb.set(0, 0, 0x102030); // r=16, g=32, b=48
    const ps = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 } }};
    try compositeLayer(&fb, &ps, &cache, .above_text);
    // a_eff = (128*255+127)/255 = 128, inv = 127:
    // r = (200*128 + 16*127 + 127)/255 = 108
    // g = (100*128 + 32*127 + 127)/255 = 66
    // b = ( 50*128 + 48*127 + 127)/255 = 49
    try testing.expectEqual(@as(u32, 0x6C4231), fb.get(0, 0));

    // Alpha 0 leaves the destination untouched; alpha 255 copies RGB.
    const clear_px = [_]u8{ 1, 2, 3, 0 };
    try cache.put(imgKey(2, 1), .{ .width = 1, .height = 1, .pixels = &clear_px });
    fb.set(0, 0, 0x102030);
    const ps2 = [_]Placement{.{ .key = imgKey(2, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 } }};
    try compositeLayer(&fb, &ps2, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x102030), fb.get(0, 0));

    const solid = [_]u8{ 200, 100, 50, 255 };
    try cache.put(imgKey(3, 1), .{ .width = 1, .height = 1, .pixels = &solid });
    const ps3 = [_]Placement{.{ .key = imgKey(3, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 } }};
    try compositeLayer(&fb, &ps3, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xC86432), fb.get(0, 0));

    // Partial alpha times partial opacity: a_eff = (100*100+127)/255 = 39.
    const mixed = [_]u8{ 100, 150, 200, 100 };
    try cache.put(imgKey(4, 1), .{ .width = 1, .height = 1, .pixels = &mixed });
    fb.set(0, 0, 0x000000);
    const ps4 = [_]Placement{.{ .key = imgKey(4, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .opacity = 100 }};
    try compositeLayer(&fb, &ps4, &cache, .above_text);
    // r = (100*39+127)/255 = 15, g = (150*39+127)/255 = 23, b = (200*39+127)/255 = 31.
    try testing.expectEqual(@as(u32, 0x0F171F), fb.get(0, 0));
}

test "composite: dst clipping at framebuffer edges" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const red = makePixels(2, 2, .{ 255, 0, 0, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &red });
    try cache.put(imgKey(2, 1), .{ .width = 2, .height = 2, .pixels = &gradient2x2 });

    var fb = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb.destroy(a);

    // Nearest path, mostly off-screen: only (3,3) is drawn.
    const ps = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 3, .y = 3, .w = 4, .h = 4 } }};
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(3, 3));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(2, 3));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(3, 2));

    // Scaled path, clipped: dst {2,2,4,4} on a 4x4 fb shows the TOP-LEFT
    // quadrant of the full 4x4 bilinear scale (the origin is on-screen;
    // only the extent is clipped). Center-aligned samples are preserved:
    // a naive sub-rect rescale would give different interior pixels.
    const ps2 = [_]Placement{.{ .key = imgKey(2, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 2, .y = 2, .w = 4, .h = 4 } }};
    try compositeLayer(&fb, &ps2, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(2, 2)); // scaled(0,0) = A
    try testing.expectEqual(@as(u32, 0xBF4000), fb.get(3, 2)); // scaled(1,0) = (191, 64, 0)
    try testing.expectEqual(@as(u32, 0xBF0040), fb.get(2, 3)); // scaled(0,1) = (191, 0, 64)
    try testing.expectEqual(@as(u32, 0x9F4030), fb.get(3, 3)); // scaled(1,1) = (159, 64, 48)
    try testing.expectEqual(@as(u32, 0x000000), fb.get(1, 1));

    // Fully off-screen: no-op, no error.
    const before = fb.get(0, 0);
    const ps3 = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 4, .y = 0, .w = 2, .h = 2 } }};
    try compositeLayer(&fb, &ps3, &cache, .above_text);
    try testing.expectEqual(before, fb.get(0, 0));
}

test "composite: source crop respected, clamped crop keeps geometry" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    var grad: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            @memcpy(grad[(y * 4 + x) * 4 ..][0 .. 4], &[_]u8{ @intCast(x * 10), @intCast(y * 10), 0, 255 });
        }
    }
    try cache.put(imgKey(1, 1), .{ .width = 4, .height = 4, .pixels = &grad });
    const crop = Damage{ .x = 1, .y = 1, .w = 2, .h = 2 };

    // 1:1 crop: nearest copy of the crop pixels.
    var fb = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb.destroy(a);
    const ps = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .src = crop }};
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x0A0A00), fb.get(0, 0));
    try testing.expectEqual(@as(u32, 0x140A00), fb.get(1, 0));
    try testing.expectEqual(@as(u32, 0x0A1400), fb.get(0, 1));
    try testing.expectEqual(@as(u32, 0x141400), fb.get(1, 1));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(2, 2));

    // Upscaled crop: corners are the crop's corners.
    var fb2 = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb2.destroy(a);
    const ps2 = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .src = crop }};
    try compositeLayer(&fb2, &ps2, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x0A0A00), fb2.get(0, 0));
    try testing.expectEqual(@as(u32, 0x140A00), fb2.get(3, 0));
    try testing.expectEqual(@as(u32, 0x0A1400), fb2.get(0, 3));
    try testing.expectEqual(@as(u32, 0x141400), fb2.get(3, 3));

    // Crop clamped at the image edge: dst shrinks by the same fraction.
    // src {2,2,4,4} clamps to {2,2,2,2}; dst {0,0,4,4} becomes {0,0,2,2}.
    var fb3 = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer fb3.destroy(a);
    const ps3 = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .src = .{ .x = 2, .y = 2, .w = 4, .h = 4 } }};
    try compositeLayer(&fb3, &ps3, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x141400), fb3.get(0, 0)); // (20, 20, 0)
    try testing.expectEqual(@as(u32, 0x1E1E00), fb3.get(1, 1)); // (30, 30, 0)
    try testing.expectEqual(@as(u32, 0x000000), fb3.get(2, 2));
}

test "composite: missing image, empty list, zero opacity are no-ops" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    var fb = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer fb.destroy(a);
    fb.fill(0xABCDEF);

    const missing = [_]Placement{.{ .key = imgKey(42, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 2, .h = 2 } }};
    try compositeLayer(&fb, &missing, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xABCDEF), fb.get(0, 0));

    try compositeLayer(&fb, &.{}, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xABCDEF), fb.get(1, 1));

    const red = makePixels(1, 1, .{ 255, 0, 0, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 1, .height = 1, .pixels = &red });
    const transparent = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .opacity = 0 }};
    try compositeLayer(&fb, &transparent, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xABCDEF), fb.get(0, 0));
}

test "composite: remove and clear stop drawing" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const red = makePixels(1, 1, .{ 255, 0, 0, 255 });
    try cache.put(imgKey(5, 1), .{ .width = 1, .height = 1, .pixels = &red });
    var fb = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer fb.destroy(a);
    const ps = [_]Placement{.{ .key = imgKey(5, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 0, .y = 0, .w = 1, .h = 1 } }};

    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(0, 0));

    cache.remove(5);
    fb.fill(0);
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x000000), fb.get(0, 0));

    try cache.put(imgKey(5, 1), .{ .width = 1, .height = 1, .pixels = &red });
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(0, 0));

    cache.clear();
    fb.fill(0);
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0x000000), fb.get(0, 0));
}

test "composite: honors framebuffer pitch padding" {
    const a = testing.allocator;
    var cache = ImageCache.init(a, 4096);
    defer cache.deinit();
    const red = makePixels(2, 2, .{ 255, 0, 0, 255 });
    try cache.put(imgKey(1, 1), .{ .width = 2, .height = 2, .pixels = &red });

    // pitch 48 > width*4 = 16: rows carry 32 bytes of padding.
    var fb = try Framebuffer.create(a, 4, 4, .xrgb8888, 48);
    defer fb.destroy(a);
    const ps = [_]Placement{.{ .key = imgKey(1, 1), .layer = .above_text, .z = 0, .dst = .{ .x = 1, .y = 1, .w = 2, .h = 2 } }};
    try compositeLayer(&fb, &ps, &cache, .above_text);
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(1, 1));
    try testing.expectEqual(@as(u32, 0xFF0000), fb.get(2, 2));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(0, 0));
    try testing.expectEqual(@as(u32, 0x000000), fb.get(3, 3));
    // Padding bytes of row 0 are untouched.
    for (fb.mem[16..48]) |byte| try testing.expectEqual(@as(u8, 0), byte);
}
