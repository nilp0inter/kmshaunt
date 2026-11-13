//! src/render/cpu.zig -- CPU renderer (ROADMAP M1.5, M3.3/M3.4/M3.5,
//! M4.3/M4.4 kitty images).
//!
//! Draws the dirty rows of a `vt.RenderState` into a `Framebuffer`.
//! Implements the `render.Renderer` vtable so the session can swap in the
//! M5 GL renderer without changes.
//!
//! # Caller contract
//!
//! * The caller owns the `vt.RenderState` and calls `state.update(&vt)`
//!   before `renderFrame`; the renderer only reads the snapshot and calls
//!   `state.clean()` after the whole frame rendered successfully. On error
//!   nothing is cleaned, so the next frame redraws the same rows.
//! * The caller's `discovery.Discovery` must outlive the renderer: the face
//!   table holds `Face` handles owned by it, and fallback/style lookups go
//!   through it. The renderer never destroys a face.
//! * Kitty images (M4): the console binds the active session's terminal
//!   through the `vt` field before `renderFrame` (the render state alone
//!   cannot reach the pixel storage). Null keeps the renderer text-only.
//! * `resize` must run before the first `renderFrame` (it establishes the
//!   grid). The framebuffer is cleared/presented by the caller; the
//!   renderer paints dirty rows only and appends one full-width damage
//!   rectangle per drawn row.
//! * Blinking (M2.4): `RenderOpts.cursor_blink_on` is the session-wide
//!   blink phase (null = blinking disabled). The renderer tracks it across
//!   frames: a phase flip repaints the cursor row and every row holding
//!   SGR-blink cells even when the render state is clean. SGR-blink glyphs
//!   hide on the off-phase; only a cursor that requests blinking hides.
//! * The grid is anchored at the framebuffer's top-left corner; centering
//!   padding is the session/video-layout's job, not the renderer's.
//!
//! # Text pipeline (M3)
//!
//! The redraw set is collected ONCE per frame into a row-major snapshot
//! (a single render-state cell walk): the FULL grapheme cluster from
//! `GRAPHEMES_UTF8` is decoded into codepoints, colors are resolved once,
//! and each base codepoint is assigned a face-table slot (style variant
//! first, then the per-codepoint fontconfig fallback). Backgrounds paint
//! from the snapshot and the text pass reuses it, so the per-cell C API
//! is walked once per frame, not twice (M8.1).
//! `shaper.groupRuns` splits the row into same-face/same-style runs with
//! the cursor isolated; each run is shaped with HarfBuzz and the glyphs
//! are mapped back to cells through their cluster values:
//!
//! * Simple cells (one codepoint) shape together in spans, so kerning and
//!   (optionally) ligatures work across cells. A glyph is drawn at its
//!   cell's origin plus the shaped x/y offsets; a ligature glyph covers
//!   the cells up to the next glyph's cluster.
//! * Complex clusters (combining marks, ZWJ sequences, flags, skin tones,
//!   variation selectors) shape as a unit: every codepoint of the cluster
//!   goes into one HarfBuzz buffer and the glyphs are laid out with a pen
//!   walk (LTR or RTL) inside the cell.
//! * Cell width ALWAYS comes from libghostty (`Cell.wide`), never from the
//!   font (R1): a wide base owns 2 cells, its continuation owns none. A
//!   glyph raster wider than its cell span is box-filtered down to fit.
//! * Color glyphs (CBDT/sbix via FT_LOAD_COLOR, COLRv0/v1 via hb-raster,
//!   both through font/color.zig) land on the atlas bgra8 page as
//!   premultiplied BGRA and composite source-over onto the cell
//!   background. Sprites (font/sprite.zig) take precedence over shaping.
//!
//! Font features: `Options.font_features` carries the session's
//! font-features strings, parsed with `shaper.Feature.parse` on top of the
//! shaper defaults (kern ON, liga OFF -- ligatures are opt-in).
//!
//! # Kitty image pipeline (M4)
//!
//! Each frame builds the drawing list from `RenderState.images()` (the
//! render-state placement iterator, NOT the storage iterator), converts
//! it to `image.Placement` geometry (cell offsets folded into dst,
//! viewport clipping mapped back onto the source crop) and fetches the
//! decoded pixels from `vt.KittyGraphics.image(id)` into an `ImageCache`
//! keyed by (protocol, id, generation). The frame then draws in the
//! ghostty layer order, interleaved with the row passes:
//!
//!     below_background images -> cell backgrounds -> below_text images
//!     -> text -> above_text images
//!
//! Alpha blending is not idempotent, so any row a placement touches is
//! rebuilt from its background before the images are composited again:
//! the redraw set is the dirty rows plus the rows covered by this
//! frame's AND the previous frame's placements (moved/deleted images
//! leave no residue). A frame with a clean render state and an unchanged
//! placement list draws nothing. Animation frames arrive as generation
//! bumps on the placement list; the console drives `animationTick` and
//! the redraw timer (main.zig, M4.4).
//!
//! Standalone tests: src/test_cpu.zig (exact command in that file's
//! header; needs the vt-c, fontconfig_c, freetype_c, hb-c, freetype-c and
//! harfbuzz-c translate-c modules plus libghostty-vt, libfontconfig,
//! libfreetype, libharfbuzz and libharfbuzz-raster).

const std = @import("std");
const fb = @import("../framebuffer.zig");
const render = @import("../render.zig");
const vt = @import("../vt.zig");
const discovery = @import("../font/discovery.zig");
const atlas = @import("../font/atlas.zig");
const sprite = @import("../font/sprite.zig");
const shaper = @import("../font/shaper.zig");
const color = @import("../font/color.zig");
const deco = @import("decorations.zig");
const layout = @import("../video/layout.zig");
const image = @import("image.zig");
const presets = @import("../misc/palette.zig");

const log = std.log.scoped(.cpu);

pub const Framebuffer = fb.Framebuffer;
pub const Damage = fb.Damage;
pub const DamageList = render.DamageList;
pub const RenderOpts = render.RenderOpts;

/// Renderer-side kitty cache budget: the terminal stores at most
/// `vt.default_kitty_storage_limit` bytes of originals per screen; scaled
/// copies share the cache, so double the budget for headroom. CacheFull
/// degrades to skipping a layer, never to a failed frame.
const image_cache_limit_bytes: usize = @intCast(2 * vt.default_kitty_storage_limit);

/// Init-time configuration.
pub const Options = struct {
    /// Pixel size set on the face; part of every atlas key.
    size_px: u16,
    /// Atlas page dimensions (shared by the a8 and bgra8 pages).
    atlas_width: u16 = 1024,
    atlas_height: u16 = 1024,
    /// HarfBuzz feature strings from the session's font-features option
    /// ("+liga", "kern=0", ...), parsed with shaper.Feature.parse. They
    /// are applied on top of the shaper defaults (kern ON, liga OFF), so
    /// ligatures stay off unless explicitly requested. An invalid string
    /// fails init with error.InvalidFeature.
    font_features: []const []const u8 = &.{},
};

pub const CpuRenderer = struct {
    allocator: std.mem.Allocator,
    /// Fontconfig/FreeType owner of every face handle below; borrowed,
    /// must outlive the renderer (module comment).
    discovery: *discovery.Discovery,
    /// The primary face (face-table slot 0), owned by the caller's
    /// Discovery. Cell geometry and decorations use its metrics.
    face: discovery.Face,
    size_px: u16,
    /// The init configuration, kept so setFontSize can re-initialize at a
    /// new pixel size. `font_features` borrows the caller's strings (they
    /// must outlive the renderer, like `discovery`).
    opts: Options,
    /// Cell geometry from discovery.cellMetrics; resize updates the cell
    /// size, the baseline stays the face's ascender.
    metrics: discovery.CellMetrics,
    cols: u16 = 0,
    rows: u16 = 0,
    atlas: atlas.GlyphAtlas,
    /// Scratch for sprite rasters and bottom-up glyph flips; grown on
    /// demand, kept across frames.
    scratch: []u8 = &.{},
    /// Sprite codepoints cached at the current cell size. Sprites are
    /// cell-sized rasters, so a cell-size change invalidates them (font
    /// glyph rasters do not depend on the cell size and stay cached).
    sprite_cps: std.ArrayListUnmanaged(u21) = .empty,

    // ---- M3 text pipeline state ----

    shaper: shaper.Shaper,
    /// Shaper defaults + the parsed Options.font_features, in order.
    features: std.ArrayListUnmanaged(shaper.Feature) = .empty,
    /// Face table indexed by `face_id` (atlas keys, CellDesc, Run). Slot 0
    /// is the primary face; style variants and fallback faces are appended
    /// on demand and deduplicated by (FT_Face, synthetic flags, lcd).
    faces: std.ArrayListUnmanaged(FaceSlot) = .empty,
    /// Style variants of the primary face, indexed by bold | italic<<1.
    /// Slot 0 (regular) is the primary face itself.
    style_faces: [4]?discovery.Face = .{ null, null, null, null },
    /// Per-codepoint fallback handles (sized, unsynthesized), including
    /// negative results. Discovery caches the fontconfig query itself;
    /// this cache avoids re-sizing and re-wrapping the handle per cell.
    fallback_faces: std.AutoHashMapUnmanaged(u21, ?discovery.Face) = .{},
    /// Per-row collection scratch, sized to `cols` by resize. During the
    /// text pass `row_cells`/`descs` point at the frame snapshot instead.
    row_scratch: []RowCell = &.{},
    desc_scratch: []shaper.CellDesc = &.{},
    /// Current row view: the scratch while collecting, a `grid_cells` /
    /// `grid_descs` row while drawing text. Never freed directly.
    row_cells: []RowCell = &.{},
    descs: []shaper.CellDesc = &.{},
    runs_buf: []shaper.Run = &.{},
    /// M8.1 frame snapshot: every redraw row collected once per frame,
    /// row-major rows×cols; row_lens[y] is the collected cell count.
    grid_cells: []RowCell = &.{},
    grid_descs: []shaper.CellDesc = &.{},
    row_lens: []u16 = &.{},
    /// Flat codepoint storage for the whole frame's clusters (cleared once
    /// per frame; RowCell.cps_start indexes into it).
    row_cps: std.ArrayListUnmanaged(u21) = .empty,
    /// Scratch CellDesc buffer for shaping one complex cluster.
    cluster_descs: std.ArrayListUnmanaged(shaper.CellDesc) = .empty,
    /// M8.1: shaped complex clusters, reused across cells/frames.
    cluster_cache: ClusterCache,

    // ---- M4 kitty image state ----

    /// Terminal owning the RenderState passed to renderFrame; borrowed,
    /// bound by the console to the active session before rendering.
    /// Null = text-only (no kitty pixel source).
    vt: ?*vt.Vt = null,
    /// Decoded originals + scaled copies, keyed by (protocol, id,
    /// generation); frame-pinned like the glyph atlas.
    image_cache: image.ImageCache,
    /// This frame's drawing list, built from RenderState.images().
    /// After a successful frame the lists swap: `prev_placements` holds
    /// the rendered list and this becomes scratch for the next frame.
    placements: std.ArrayListUnmanaged(image.Placement) = .empty,
    /// The last successfully rendered frame's drawing list: its rects
    /// join the redraw set so moved/deleted images are erased.
    prev_placements: std.ArrayListUnmanaged(image.Placement) = .empty,
    /// Per-row redraw flags for the current frame, sized to `rows`.
    redraw_rows: []bool = &.{},
    /// Per-row flags: the row holds SGR-blink cells. collectRow refreshes
    /// the flag of every drawn row; a blink-phase flip repaints the marked
    /// rows even when the render state is clean (M2.4).
    blink_rows: []bool = &.{},
    /// Blink phase of the last successfully rendered frame (null =
    /// blinking disabled). Compared against RenderOpts.cursor_blink_on to
    /// detect phase flips, which change no terminal data and so leave the
    /// render state clean.
    prev_blink_phase: ?bool = null,
    /// Viewport row of the cursor drawn in the last successful frame;
    /// repainted on a blink-phase flip together with the blink rows.
    prev_cursor_row: ?u16 = null,

    const FaceSlot = struct {
        face: discovery.Face,
        /// Face carries color glyphs (CBDT/sbix strikes or a COLR table).
        has_color: bool,
    };

    /// One collected cell of the current row. `text` is not borrowed from
    /// the render state: the cluster's codepoints live in `row_cps`.
    const RowCell = struct {
        style: vt.Style,
        fg: u32,
        bg: u32,
        /// Offset of the cluster's codepoints in `row_cps`.
        cps_start: u32,
        /// Number of codepoints in the cluster (0 = empty cell).
        n_cps: u32,
        face_id: u16,
        /// libghostty width: 1 narrow, 2 wide base, 0 continuation (R1).
        width: u8,
        is_cursor: bool,
        sprite: bool,
        invisible: bool,
    };

    pub fn init(allocator: std.mem.Allocator, d: *discovery.Discovery, face: *discovery.Face, opts: Options) !CpuRenderer {
        try face.setPixelSize(opts.size_px);
        const metrics = try discovery.cellMetrics(face.*);
        var self = CpuRenderer{
            .allocator = allocator,
            .discovery = d,
            .face = face.*,
            .size_px = opts.size_px,
            .opts = opts,
            .metrics = metrics,
            .atlas = try atlas.GlyphAtlas.init(allocator, opts.atlas_width, opts.atlas_height),
            .image_cache = image.ImageCache.init(allocator, image_cache_limit_bytes),
            .shaper = shaper.Shaper.init(allocator),
            .cluster_cache = ClusterCache.init(allocator),
            .style_faces = .{ face.*, null, null, null },
        };
        errdefer self.deinit();
        try self.faces.append(allocator, .{
            .face = face.*,
            .has_color = color.hasColorGlyphs(@ptrCast(&face.ft_face)),
        });
        try self.features.appendSlice(allocator, &shaper.default_features);
        for (opts.font_features) |s| {
            try self.features.append(allocator, try shaper.Feature.parse(s));
        }
        return self;
    }

    pub fn deinit(self: *CpuRenderer) void {
        self.atlas.deinit();
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.sprite_cps.deinit(self.allocator);
        self.shaper.deinit();
        self.cluster_cache.deinit();
        self.features.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.fallback_faces.deinit(self.allocator);
        if (self.row_scratch.len > 0) self.allocator.free(self.row_scratch);
        if (self.desc_scratch.len > 0) self.allocator.free(self.desc_scratch);
        if (self.runs_buf.len > 0) self.allocator.free(self.runs_buf);
        if (self.grid_cells.len > 0) self.allocator.free(self.grid_cells);
        if (self.grid_descs.len > 0) self.allocator.free(self.grid_descs);
        if (self.row_lens.len > 0) self.allocator.free(self.row_lens);
        self.row_cps.deinit(self.allocator);
        self.cluster_descs.deinit(self.allocator);
        self.image_cache.deinit();
        self.placements.deinit(self.allocator);
        self.prev_placements.deinit(self.allocator);
        if (self.redraw_rows.len > 0) self.allocator.free(self.redraw_rows);
        if (self.blink_rows.len > 0) self.allocator.free(self.blink_rows);
    }

    pub fn renderer(self: *CpuRenderer) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Reconfigure for a new grid. The atlas survives; only cell-sized
    /// sprite rasters are dropped when the cell size changes.
    pub fn resize(self: *CpuRenderer, cols: u16, rows: u16, cell_w: u16, cell_h: u16) !void {
        if (cell_w != self.metrics.cell_w or cell_h != self.metrics.cell_h) {
            for (self.sprite_cps.items) |cp| try self.atlas.remove(self.spriteKey(cp));
            self.sprite_cps.clearRetainingCapacity();
            self.metrics.cell_w = cell_w;
            self.metrics.cell_h = cell_h;
        }
        if (cols != self.row_scratch.len) {
            self.row_scratch = try self.allocator.realloc(self.row_scratch, cols);
            self.desc_scratch = try self.allocator.realloc(self.desc_scratch, cols);
            self.runs_buf = try self.allocator.realloc(self.runs_buf, cols);
        }
        const grid_n = @as(usize, cols) * rows;
        if (grid_n != self.grid_cells.len) {
            self.grid_cells = try self.allocator.realloc(self.grid_cells, grid_n);
            self.grid_descs = try self.allocator.realloc(self.grid_descs, grid_n);
        }
        if (rows != self.row_lens.len) {
            self.row_lens = try self.allocator.realloc(self.row_lens, rows);
        }
        self.row_cells = self.row_scratch;
        self.descs = self.desc_scratch;
        if (rows != self.redraw_rows.len) {
            self.redraw_rows = try self.allocator.realloc(self.redraw_rows, rows);
            self.blink_rows = try self.allocator.realloc(self.blink_rows, rows);
            // Row indices shift with the grid; the next redraw rebuilds
            // the flags from the cells.
            @memset(self.blink_rows, false);
        }
        self.cols = cols;
        self.rows = rows;
    }

    /// Change the font pixel size (grab-zoom-in / grab-zoom-out, M3.8).
    /// All size-dependent state (atlas, face table, caches) is rebuilt in
    /// place at the new size; the renderer's address is unchanged, so
    /// borrowed vtable pointers stay valid. The grid is preserved at the
    /// new cell size; the caller recomputes cols/rows from the returned
    /// metrics and calls resize() again. Returns the new cell metrics.
    pub fn setFontSize(self: *CpuRenderer, new_size_px: u16) !discovery.CellMetrics {
        if (new_size_px == self.size_px) return self.metrics;
        var opts = self.opts;
        opts.size_px = new_size_px;
        var fresh = try init(self.allocator, self.discovery, &self.face, opts);
        errdefer fresh.deinit();
        try fresh.resize(self.cols, self.rows, fresh.metrics.cell_w, fresh.metrics.cell_h);
        fresh.vt = self.vt;
        const metrics = fresh.metrics;
        self.deinit();
        self.* = fresh;
        return metrics;
    }

    /// Draw the current snapshot. `state` must already be update()d by
    /// the caller (see the module comment).
    pub fn renderFrame(
        self: *CpuRenderer,
        state: *vt.RenderState,
        f: *Framebuffer,
        damage: *DamageList,
        opts: RenderOpts,
    ) !void {
        if (self.cols == 0 or self.rows == 0 or
            self.metrics.cell_w == 0 or self.metrics.cell_h == 0) return;

        // Kitty drawing list + pixel cache (M4). beginFrame before the
        // first cache touch: everything fetched below is pinned for this
        // frame, so scaling cannot evict an image still being drawn.
        self.image_cache.beginFrame();
        try self.collectPlacements(state);

        const dirty = try state.dirty();
        const images_changed = !placementsEqual(self.placements.items, self.prev_placements.items);
        // The blink timer flips the phase without touching terminal data,
        // so a phase change must repaint even a clean state (M2.4).
        const blink_changed = opts.cursor_blink_on != self.prev_blink_phase;
        if (dirty == .clean and !images_changed and !blink_changed) return;

        self.atlas.beginFrame();
        const colors = try state.colors();
        const cursor = try self.cursorDraw(state, opts, colors);

        // Redraw set: dirty rows plus every row touched by this frame's
        // or the previous frame's placements. Blending is not idempotent,
        // so a repainted row is rebuilt from its background before the
        // images are composited again; the previous rects erase images
        // that moved or were deleted.
        if (dirty == .full) {
            @memset(self.redraw_rows, true);
        } else {
            @memset(self.redraw_rows, false);
            var dirty_rows = try state.rowsIter();
            while (try dirty_rows.nextDirty()) |row| {
                const vy = try row.viewportY();
                if (vy >= 0 and vy < self.rows) self.redraw_rows[@intCast(vy)] = true;
            }
        }
        for (self.placements.items) |p| self.markImageRows(p.dst);
        for (self.prev_placements.items) |p| self.markImageRows(p.dst);
        if (blink_changed) {
            // Blink rows and the cursor row come from the previous frame:
            // their contents cannot have changed without a dirty row.
            for (self.blink_rows, 0..) |has_blink, y| {
                if (has_blink) self.redraw_rows[y] = true;
            }
            if (self.prev_cursor_row) |y| {
                if (y < self.rows) self.redraw_rows[y] = true;
            }
            if (cursor.active) self.redraw_rows[cursor.y] = true;
        }

        // Layer interleaving (ghostty-vt-api.md §9.6): below_background
        // -> cell backgrounds -> below_text -> text -> above_text. All
        // backgrounds land before any text, so a wide glyph can overflow
        // into its continuation cell without being overpainted. The
        // background pass collects the whole redraw set into the frame
        // snapshot; the text pass draws from it (one cell walk, M8.1).
        try self.compositeImages(f, .below_background);
        try self.collectAndDrawBackgrounds(f, state, opts, cursor);
        try self.compositeImages(f, .below_text);
        try self.drawRowsText(f, opts, cursor);
        try self.compositeImages(f, .above_text);

        // Damage: one full-width band per redrawn row. Placements are
        // clipped to the grid, so the bands cover every image pixel.
        for (self.redraw_rows, 0..) |redraw, y| {
            if (!redraw) continue;
            const y0: u32 = @as(u32, @intCast(y)) * self.metrics.cell_h;
            if (y0 < f.height) {
                const y1 = @min(y0 + self.metrics.cell_h, f.height);
                try damage.append(self.allocator, Damage.fromRows(y0, y1, f.width));
            }
        }

        // The CPU reads the pages directly; drop the GL upload bookkeeping
        // so the dirty list stays bounded.
        self.atlas.clearDirty();
        std.mem.swap(
            std.ArrayListUnmanaged(image.Placement),
            &self.placements,
            &self.prev_placements,
        );
        try state.clean();
        self.prev_blink_phase = opts.cursor_blink_on;
        self.prev_cursor_row = if (cursor.active) cursor.y else null;
    }

    // ------------------------------------------------------------------
    // Row walk
    // ------------------------------------------------------------------

    /// Collect every redraw row into the frame snapshot and paint its
    /// backgrounds + block cursors. This is the frame's ONLY render-state
    /// cell walk: the text pass reads the snapshot, halving the per-cell
    /// C API cost (M8.1). `next` visits clean rows too: rows under kitty
    /// placements repaint even when the terminal state is clean.
    fn collectAndDrawBackgrounds(
        self: *CpuRenderer,
        f: *Framebuffer,
        state: *vt.RenderState,
        opts: RenderOpts,
        cursor: CursorDraw,
    ) !void {
        // Collection writes into the per-row scratch; the text pass
        // re-points row_cells/descs at the snapshot rows.
        self.row_cells = self.row_scratch;
        self.descs = self.desc_scratch;
        self.row_cps.clearRetainingCapacity();
        @memset(self.row_lens, 0);
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        var rows = try state.rowsIter();
        while (try rows.next()) |row| {
            const vy = try row.viewportY();
            if (vy < 0 or vy >= self.rows) continue; // overscan row
            const y: u16 = @intCast(vy);
            if (!self.redraw_rows[y]) continue;
            const n = try self.collectRow(&row, y, opts, cursor);
            self.row_lens[y] = @intCast(n);
            const base = @as(usize, y) * self.cols;
            @memcpy(self.grid_cells[base..][0..n], self.row_scratch[0..n]);
            @memcpy(self.grid_descs[base..][0..n], self.desc_scratch[0..n]);
            const y_px: i32 = @as(i32, y) * ch;
            for (self.grid_cells[base..][0..n], 0..) |*rc, x| {
                const x_px: i32 = @as(i32, @intCast(x)) * cw;
                fillCell(f, x_px, y_px, cw, ch, rc.bg);
                if (rc.is_cursor and cursor.style == .block)
                    deco.drawCursor(f.*, x_px, y_px, cw, ch, .block, cursor.color, true);
            }
        }
    }

    /// Draw shaped text, decorations and bar/underline cursors for every
    /// redraw row from the frame snapshot (no render-state access).
    fn drawRowsText(
        self: *CpuRenderer,
        f: *Framebuffer,
        opts: RenderOpts,
        cursor: CursorDraw,
    ) !void {
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        for (self.redraw_rows, 0..) |redraw, yi| {
            if (!redraw) continue;
            const y: u16 = @intCast(yi);
            const n = self.row_lens[y];
            const base = @as(usize, y) * self.cols;
            self.row_cells = self.grid_cells[base..][0..self.cols];
            self.descs = self.grid_descs[base..][0..self.cols];
            const y_px: i32 = @as(i32, y) * ch;
            try self.drawRowText(f, y_px, n);
            for (self.row_cells[0..n], 0..) |*rc, x| {
                const x_px: i32 = @as(i32, @intCast(x)) * cw;
                if (!rc.invisible)
                    self.drawDecorations(f, x_px, y_px, rc.style, rc.fg, opts);
                if (rc.is_cursor and cursor.style != .block)
                    deco.drawCursor(f.*, x_px, y_px, cw, ch, cursorStyle(cursor.style), cursor.color, true);
            }
        }
    }

    // ------------------------------------------------------------------
    // Kitty images (M4): drawing list, pixel cache, layer passes
    // ------------------------------------------------------------------

    /// Build this frame's drawing list from the render-state placement
    /// iterator and make sure every referenced image is cached, fetching
    /// decoded pixels from kitty storage on demand. Placements whose
    /// image is deleted, still transmitting or outside the grid drop out.
    fn collectPlacements(self: *CpuRenderer, state: *vt.RenderState) !void {
        self.placements.clearRetainingCapacity();
        const v = self.vt orelse return; // text-only: no pixel source
        var imgs = try state.images();
        const kg = try v.kittyGraphics();
        while (try imgs.next()) |raw| {
            if (raw.protocol != .kitty) continue;
            const key = image.ImageKey{
                .protocol = .kitty,
                .id = raw.image_id,
                // The cache key is u32; generations are per-image
                // counters, so wraparound needs 2^32 pixel changes on
                // one id before a collision is possible.
                .generation = @truncate(raw.image_generation),
            };
            const img = (try self.ensureImage(kg, key, raw.image_id, raw.image_generation)) orelse continue;
            const p = self.buildPlacement(raw, key, img.width, img.height) orelse continue;
            try self.placements.append(self.allocator, p);
        }
    }

    /// Cache lookup for one placement's image; on a miss fetch the
    /// decoded pixels from kitty storage, convert to RGBA8 and store.
    /// Null when the image is gone, not fully transmitted yet, or the
    /// cache is full (the placement is skipped this frame).
    fn ensureImage(
        self: *CpuRenderer,
        kg: vt.KittyGraphics,
        key: image.ImageKey,
        id: u32,
        generation: u64,
    ) !?*image.Image {
        if (self.image_cache.get(key)) |img| return img;
        const ki = kg.image(id) orelse return null;
        if (try ki.generation() != generation) return null;
        const w = try ki.width();
        const h = try ki.height();
        const pixels = (try ki.pixels()) orelse return null;
        const area = @as(usize, w) * h;
        const fmt = try ki.format();
        switch (fmt) {
            .rgba => {
                if (pixels.len != area * 4) return null;
                self.image_cache.put(key, .{ .width = w, .height = h, .pixels = pixels }) catch |err| switch (err) {
                    error.CacheFull => return null,
                    else => return err,
                };
            },
            .rgb, .gray, .gray_alpha => {
                const bpp: usize = switch (fmt) {
                    .rgb => 3,
                    .gray => 1,
                    .gray_alpha => 2,
                    else => unreachable,
                };
                if (pixels.len != area * bpp) return null;
                try self.ensureScratch(area * 4);
                const out = self.scratch[0 .. area * 4];
                switch (fmt) {
                    .rgb => for (0..area) |i| {
                        out[i * 4 + 0] = pixels[i * 3 + 0];
                        out[i * 4 + 1] = pixels[i * 3 + 1];
                        out[i * 4 + 2] = pixels[i * 3 + 2];
                        out[i * 4 + 3] = 255;
                    },
                    .gray => for (0..area) |i| {
                        out[i * 4 + 0] = pixels[i];
                        out[i * 4 + 1] = pixels[i];
                        out[i * 4 + 2] = pixels[i];
                        out[i * 4 + 3] = 255;
                    },
                    .gray_alpha => for (0..area) |i| {
                        out[i * 4 + 0] = pixels[i * 2];
                        out[i * 4 + 1] = pixels[i * 2];
                        out[i * 4 + 2] = pixels[i * 2];
                        out[i * 4 + 3] = pixels[i * 2 + 1];
                    },
                    else => unreachable,
                }
                self.image_cache.put(key, .{ .width = w, .height = h, .pixels = out }) catch |err| switch (err) {
                    error.CacheFull => return null,
                    else => return err,
                };
            },
            // Stored images are fully decoded; PNG never reaches here.
            .png => return null,
        }
        return self.image_cache.get(key);
    }

    /// Convert one render-state placement into compositor geometry: fold
    /// the cell offset into dst (the compositor treats dst as
    /// authoritative), clip to the grid -- viewport positions may be
    /// negative or overflow it -- and map the clipped dst back onto the
    /// source crop so scaling stays correct. Null when nothing shows.
    fn buildPlacement(
        self: *const CpuRenderer,
        raw: vt.ImagePlacement,
        key: image.ImageKey,
        img_w: u32,
        img_h: u32,
    ) ?image.Placement {
        const cw: i64 = self.metrics.cell_w;
        const ch: i64 = self.metrics.cell_h;
        const x: i64 = @as(i64, raw.viewport_col) * cw + raw.cell_offset_x;
        const y: i64 = @as(i64, raw.viewport_row) * ch + raw.cell_offset_y;
        const w: i64 = raw.pixel_width;
        const h: i64 = raw.pixel_height;
        if (w <= 0 or h <= 0) return null;
        const gw: i64 = @as(i64, self.cols) * cw;
        const gh: i64 = @as(i64, self.rows) * ch;
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, gw);
        const y1 = @min(y + h, gh);
        if (x1 <= x0 or y1 <= y0) return null;

        var src = image.Damage{
            .x = raw.source_x,
            .y = raw.source_y,
            .w = raw.source_width,
            .h = raw.source_height,
        };
        if (src.isEmpty()) src = .{ .x = 0, .y = 0, .w = img_w, .h = img_h };
        if (x0 != x or y0 != y or x1 != x + w or y1 != y + h) {
            // Viewport clip: take the matching sub-rect of the source
            // crop (floor division, like image.zig's mapRect). u64 math
            // so u32 extents cannot overflow.
            const sw: u64 = src.w;
            const sh: u64 = src.h;
            const uw: u64 = @intCast(w);
            const uh: u64 = @intCast(h);
            src = .{
                .x = src.x + @as(u32, @intCast(@as(u64, @intCast(x0 - x)) * sw / uw)),
                .y = src.y + @as(u32, @intCast(@as(u64, @intCast(y0 - y)) * sh / uh)),
                .w = @intCast(@as(u64, @intCast(x1 - x0)) * sw / uw),
                .h = @intCast(@as(u64, @intCast(y1 - y0)) * sh / uh),
            };
            if (src.isEmpty()) return null;
        }
        return .{
            .key = key,
            .layer = switch (raw.layer) {
                .below_background => .below_background,
                .below_text => .below_text,
                .above_text => .above_text,
            },
            .z = raw.z,
            .dst = .{
                .x = @intCast(x0),
                .y = @intCast(y0),
                .w = @intCast(x1 - x0),
                .h = @intCast(y1 - y0),
            },
            .src = src,
            // The 1.0.1 render state exposes no per-placement opacity.
            .opacity = 255,
        };
    }

    /// Mark every grid row a (grid-clipped) placement rect touches.
    fn markImageRows(self: *CpuRenderer, dst: image.Damage) void {
        if (dst.isEmpty()) return;
        const ch: u32 = self.metrics.cell_h;
        const y0 = dst.y / ch;
        if (y0 >= self.rows) return; // stale rect from a larger grid
        const y1 = @min((dst.y + dst.h - 1) / ch, self.rows - 1);
        var y = y0;
        while (y <= y1) : (y += 1) self.redraw_rows[y] = true;
    }

    /// One interleaving pass over the drawing list. CacheFull degrades
    /// to skipping the layer (the frame still completes and is cleaned);
    /// the next frame retries with fresh pins.
    fn compositeImages(self: *CpuRenderer, f: *Framebuffer, layer: image.Layer) !void {
        if (self.placements.items.len == 0) return;
        image.compositeLayer(f, self.placements.items, &self.image_cache, layer) catch |err| switch (err) {
            error.CacheFull => log.warn("kitty image cache full; {s} layer skipped", .{@tagName(layer)}),
            else => return err,
        };
    }

    /// Drawing-list equality: same placements in the same order with the
    /// same keys and geometry. std.meta.eql walks the optional source
    /// rect (Placement has no derived ==).
    fn placementsEqual(a: []const image.Placement, b: []const image.Placement) bool {
        if (a.len != b.len) return false;
        for (a, b) |pa, pb| {
            if (!std.meta.eql(pa, pb)) return false;
        }
        return true;
    }

    /// Snapshot the row's cells into `row_cells`/`descs`, appending every
    /// full grapheme cluster's codepoints to the frame-global `row_cps`
    /// (the render state's borrowed text dies on the next `cells.next`;
    /// the caller clears `row_cps` once per frame). Colors resolve once
    /// per cell; the block-cursor overlay applies to the glyph foreground.
    fn collectRow(
        self: *CpuRenderer,
        row: *const vt.Row,
        y: u16,
        opts: RenderOpts,
        cursor: CursorDraw,
    ) !usize {
        const blink_off = if (opts.cursor_blink_on) |on| !on else false;
        var row_blink = false;
        var cells = try row.cells();
        var x: u16 = 0;
        while (try cells.next()) |cell| {
            if (x >= self.cols) break;
            const cc = resolveColors(&cell, opts);
            const is_cursor = cursor.active and x == cursor.x and y == cursor.y;
            var fg = cc.fg;
            if (is_cursor and cursor.style == .block)
                fg = deco.cursorOverlayColor(cc.bg, cursor.color);

            const cps_start: u32 = @intCast(self.row_cps.items.len);
            var n_cps: u32 = 0;
            if (cell.text.len > 0) {
                if (std.unicode.Utf8View.init(cell.text)) |view| {
                    var it = view.iterator();
                    while (it.nextCodepoint()) |cp| {
                        try self.row_cps.append(self.allocator, cp);
                        n_cps += 1;
                    }
                } else |_| {} // malformed UTF-8: draw nothing (M1 behavior)
            }
            const base_cp: u21 = if (n_cps > 0) self.row_cps.items[cps_start] else 0;
            const width: u8 = switch (cell.wide) {
                .narrow => 1,
                .wide => 2,
                .spacer_tail, .spacer_head => 0,
            };
            // SGR blink hides the glyph on the off-phase, like invisible
            // (the background still paints; M2.4).
            if (cell.style.flags.blink) row_blink = true;
            const invisible = !deco.shouldDraw(cell.style.flags.invisible) or
                (blink_off and cell.style.flags.blink);
            const is_sprite = n_cps > 0 and sprite.isSprite(base_cp);
            const bold = cell.style.flags.bold;
            const italic = cell.style.flags.italic;
            var face_id: u16 = 0;
            if (base_cp != 0 and !is_sprite and !invisible and width != 0)
                face_id = try self.faceForCell(base_cp, bold, italic);

            self.row_cells[x] = .{
                .style = cell.style,
                .fg = fg,
                .bg = cc.bg,
                .cps_start = cps_start,
                .n_cps = n_cps,
                .face_id = face_id,
                .width = width,
                .is_cursor = is_cursor,
                .sprite = is_sprite,
                .invisible = invisible,
            };
            self.descs[x] = .{
                .face_id = face_id,
                .style_flags = @as(u8, @intFromBool(bold)) | (@as(u8, @intFromBool(italic)) << 1),
                .codepoint = base_cp,
                .is_cursor = is_cursor,
                .width = width,
            };
            x += 1;
        }
        self.blink_rows[y] = row_blink;
        return x;
    }

    // ------------------------------------------------------------------
    // Face table: style variants + per-codepoint fallback
    // ------------------------------------------------------------------

    /// Face-table slot for one cell's base codepoint: the style variant
    /// when it covers the codepoint, otherwise the fontconfig fallback
    /// face (with the cell's style synthesized on it). With no fallback
    /// the style face stays selected and shaping yields .notdef (tofu).
    fn faceForCell(self: *CpuRenderer, cp: u21, bold: bool, italic: bool) !u16 {
        const style_idx: usize = @as(usize, @intFromBool(bold)) | (@as(usize, @intFromBool(italic)) << 1);
        const style_face = try self.styleFace(style_idx);
        if (style_face.glyphIndex(cp) != null) return self.faceSlot(style_face);

        const fallback = blk: {
            if (self.fallback_faces.get(cp)) |entry| break :blk entry;
            const face = try self.discovery.fallbackFace(cp);
            if (face) |f| try f.setPixelSize(self.size_px);
            try self.fallback_faces.put(self.allocator, cp, face);
            break :blk face;
        };
        if (fallback) |f| {
            var styled = f;
            styled.synthetic_bold = bold;
            styled.synthetic_italic = italic;
            return self.faceSlot(styled);
        }
        return self.faceSlot(style_face);
    }

    /// Bold/italic variant of the primary face, matched once per style
    /// combination through discovery.faceForStyle (real variant when one
    /// exists, synthetic flags on the base otherwise).
    fn styleFace(self: *CpuRenderer, idx: usize) !discovery.Face {
        if (self.style_faces[idx]) |f| return f;
        const f = try self.discovery.faceForStyle(self.face, idx & 1 != 0, idx & 2 != 0);
        self.style_faces[idx] = f;
        return f;
    }

    /// Intern a face handle into the table, deduplicating by the underlying
    /// FT_Face plus the synthesis/lcd flags (handles sharing an FT_Face
    /// rasterize differently when their flags differ).
    fn faceSlot(self: *CpuRenderer, face: discovery.Face) !u16 {
        for (self.faces.items, 0..) |slot, i| {
            if (slot.face.ft_face == face.ft_face and
                slot.face.synthetic_bold == face.synthetic_bold and
                slot.face.synthetic_italic == face.synthetic_italic and
                slot.face.lcd == face.lcd) return @intCast(i);
        }
        var probe = face; // parameters are const; hasColorGlyphs wants *FT_Face
        try self.faces.append(self.allocator, .{
            .face = face,
            .has_color = color.hasColorGlyphs(@ptrCast(&probe.ft_face)),
        });
        return @intCast(self.faces.items.len - 1);
    }

    // ------------------------------------------------------------------
    // Shaped text draw (M3.3/M3.4/M3.5)
    // ------------------------------------------------------------------

    /// Shape and draw the collected row. Runs come from shaper.groupRuns
    /// (same face/style, cursor isolated, wide continuations attached).
    /// Within a run, contiguous simple cells shape together as one span;
    /// complex clusters shape alone; sprites bypass shaping entirely.
    fn drawRowText(self: *CpuRenderer, f: *Framebuffer, y_px: i32, n: usize) !void {
        const cw = self.metrics.cell_w;
        const runs = try shaper.groupRuns(self.descs[0..n], self.runs_buf[0..n]);
        for (runs) |run| {
            var span_start: ?usize = null;
            var i = run.start;
            const end = run.start + run.len;
            while (i < end) : (i += 1) {
                const rc = &self.row_cells[i];
                if (rc.sprite and !rc.invisible) {
                    if (span_start) |s| {
                        try self.drawSpan(f, y_px, s, i, run.face_id);
                        span_start = null;
                    }
                    const cp = self.row_cps.items[rc.cps_start];
                    try self.drawSprite(f, @as(i32, @intCast(i)) * cw, y_px, cp, rc.fg);
                    continue;
                }
                // Wide continuations carry no glyph of their own (the
                // shaper skips width==0 cells), so they extend the span
                // instead of breaking it: a CJK row would otherwise shape
                // one cell per HarfBuzz call (M8.1 unicode).
                const shapeable = rc.width == 0 or (!rc.invisible and
                    rc.n_cps == 1 and self.row_cps.items[rc.cps_start] != 0);
                if (shapeable) {
                    if (span_start == null) span_start = i;
                    continue;
                }
                if (span_start) |s| {
                    try self.drawSpan(f, y_px, s, i, run.face_id);
                    span_start = null;
                }
                if (rc.width != 0 and !rc.invisible and rc.n_cps > 1)
                    try self.drawCluster(f, @as(i32, @intCast(i)) * cw, y_px, rc);
            }
            if (span_start) |s| try self.drawSpan(f, y_px, s, end, run.face_id);
        }
    }

    /// Shape one span of simple cells and draw its glyphs. Each glyph sits
    /// at its cluster cell's origin plus the shaped offsets; the cell span
    /// it may fill runs to the next glyph's cluster (ligatures cover
    /// several cells). Grid placement never uses the font advance: cell
    /// width comes from libghostty (R1).
    fn drawSpan(
        self: *CpuRenderer,
        f: *Framebuffer,
        y_px: i32,
        start: usize,
        end: usize,
        face_id: u16,
    ) !void {
        const span = self.descs[start..end];
        const slot = &self.faces.items[face_id];
        const shaped = try self.shaper.shape(@ptrCast(slot.face.ft_face), span, self.features.items);
        defer self.allocator.free(shaped.glyphs);
        const cw = self.metrics.cell_w;
        for (shaped.glyphs, 0..) |g, gi| {
            if (g.cell >= span.len) continue; // defensive: cluster out of range
            const cell_idx = start + g.cell;
            const bound = if (gi + 1 < shaped.glyphs.len) shaped.glyphs[gi + 1].cell else span.len;
            const lo = @min(g.cell, bound);
            const hi = @max(g.cell + 1, bound);
            var cells_w: u32 = 0;
            for (span[lo..hi]) |cd| cells_w += @as(u32, cd.width);
            const max_w = @max(cells_w, 1) * cw;
            const x_px: i32 = @as(i32, @intCast(cell_idx)) * cw;
            try self.drawGlyph(f, x_px, y_px, face_id, g, max_w, self.row_cells[cell_idx].fg);
        }
    }

    /// Shape one cell's FULL grapheme cluster (base + combining marks, ZWJ
    /// sequences, flags, skin tones, variation selectors) as a single
    /// HarfBuzz buffer and lay the glyphs out with a pen walk inside the
    /// cell. HarfBuzz resolves marks/VS/ZWJ/flags through the font's GSUB;
    /// the cluster's width stays the libghostty cell span (R1).
    fn drawCluster(
        self: *CpuRenderer,
        f: *Framebuffer,
        x_px: i32,
        y_px: i32,
        rc: *const RowCell,
    ) !void {
        const cps = self.row_cps.items[rc.cps_start..][0..rc.n_cps];
        const style_flags = @as(u8, @intFromBool(rc.style.flags.bold)) |
            (@as(u8, @intFromBool(rc.style.flags.italic)) << 1);
        const max_w = @as(u32, rc.width) * self.metrics.cell_w;
        // M8.1: complex clusters repeat heavily (emoji, flags, marks);
        // reuse the shaped glyphs instead of re-shaping per cell.
        if (self.cluster_cache.get(rc.face_id, style_flags, cps)) |e| {
            try self.drawClusterGlyphs(f, x_px, y_px, rc, e.glyphs, e.direction, max_w);
            return;
        }
        self.cluster_descs.clearRetainingCapacity();
        for (cps) |cp| {
            try self.cluster_descs.append(self.allocator, .{
                .face_id = rc.face_id,
                .style_flags = style_flags,
                .codepoint = cp,
                .width = 1,
            });
        }
        const slot = &self.faces.items[rc.face_id];
        const shaped = try self.shaper.shape(@ptrCast(slot.face.ft_face), self.cluster_descs.items, self.features.items);
        defer self.allocator.free(shaped.glyphs);
        self.cluster_cache.put(rc.face_id, style_flags, cps, shaped.glyphs, shaped.direction) catch |err|
            log.warn("cluster cache: {t}", .{err});
        try self.drawClusterGlyphs(f, x_px, y_px, rc, shaped.glyphs, shaped.direction, max_w);
    }

    /// Pen-walk a shaped cluster's glyphs inside the cell (LTR or RTL).
    fn drawClusterGlyphs(
        self: *CpuRenderer,
        f: *Framebuffer,
        x_px: i32,
        y_px: i32,
        rc: *const RowCell,
        glyphs: []const shaper.ShapedGlyph,
        direction: shaper.Direction,
        max_w: u32,
    ) !void {
        var pen: f32 = if (direction == .rtl) @floatFromInt(max_w) else 0;
        for (glyphs) |g| {
            if (direction == .rtl) pen -= g.x_advance;
            const gx = x_px + roundI32(pen);
            try self.drawGlyph(f, gx, y_px, rc.face_id, g, max_w, rc.fg);
            if (direction != .rtl) pen += g.x_advance;
        }
    }

    /// Rasterize (or fetch from the atlas) one shaped glyph and blit it at
    /// the pen position `x_px`/`y_px` plus bearings and shaped offsets.
    /// Color faces route through color.renderColor (premultiplied BGRA on
    /// the bgra8 page); a glyph without a color representation falls back
    /// to the gray/FT_LOAD_COLOR raster. `max_w` is the glyph's cell span
    /// in pixels; wider rasters are scaled down to fit (R1).
    fn drawGlyph(
        self: *CpuRenderer,
        f: *Framebuffer,
        x_px: i32,
        y_px: i32,
        face_id: u16,
        g: shaper.ShapedGlyph,
        max_w: u32,
        fg: u32,
    ) !void {
        const slot = &self.faces.items[face_id];
        const key = atlas.GlyphKey{
            .face_id = face_id,
            .glyph_index = g.glyph_index,
            .size_px = self.size_px,
            .flags = faceFlags(slot.face),
        };
        const entry = self.atlas.get(key) orelse blk: {
            if (slot.has_color) {
                var cg: ?color.ColorGlyph = color.renderColor(
                    self.allocator,
                    @ptrCast(&slot.face.ft_face),
                    g.glyph_index,
                    self.size_px,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null, // color paint failed: try the gray path
                };
                // renderColor may have selected a bitmap strike; restore
                // the text size for later shaping/loads on this face.
                try slot.face.setPixelSize(self.size_px);
                if (cg) |*c| {
                    defer c.deinit(self.allocator);
                    break :blk try self.atlas.insert(key, .{
                        .bearing_x = clampI16(c.bearing_x),
                        .bearing_y = clampI16(c.bearing_y),
                        .advance_x = clampI16(roundI32(g.x_advance)),
                    }, .{
                        .format = .bgra8,
                        .width = @intCast(c.width),
                        .height = @intCast(c.height),
                        .data = c.pixels,
                        .stride = c.pitch,
                    });
                }
            }
            const bmp = slot.face.loadGlyph(g.glyph_index, slot.has_color) catch |err| switch (err) {
                // No raster for this glyph (e.g. color bitmap without a
                // gray strike, broken .notdef): skip it, keep the frame.
                error.UnsupportedPixelMode, error.InvalidGlyphIndex, error.CannotRenderGlyph => return,
                else => return err,
            };
            break :blk try self.cacheGlyph(key, bmp);
        };
        const dst_x = x_px + @as(i32, entry.bearing_x) + roundI32(g.x_offset);
        const dst_y = y_px + @as(i32, self.metrics.baseline) - @as(i32, entry.bearing_y) - roundI32(g.y_offset);
        self.blitFit(f, dst_x, dst_y, entry, fg, max_w);
    }

    /// Rasterize a code-drawn sprite into the atlas and blit it. Sprites
    /// fill the whole cell (bearing 0), so adjacent cells join exactly.
    fn drawSprite(self: *CpuRenderer, f: *Framebuffer, x_px: i32, y_px: i32, cp: u21, fg: u32) !void {
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        const key = self.spriteKey(cp);
        const entry = self.atlas.get(key) orelse blk: {
            const n = @as(usize, cw) * ch;
            try self.ensureScratch(n);
            if (!sprite.renderSprite(cp, cw, ch, self.scratch[0..n])) return;
            try self.sprite_cps.append(self.allocator, cp);
            break :blk try self.atlas.insert(key, .{ .advance_x = @intCast(cw) }, .{
                .format = .a8,
                .width = cw,
                .height = ch,
                .data = self.scratch[0..n],
            });
        };
        self.blitEntry(f, x_px, y_px, entry, fg);
    }

    /// Copy a freshly rasterized glyph into the atlas. The borrowed
    /// FreeType buffer is consumed here, before any further face load.
    fn cacheGlyph(self: *CpuRenderer, key: atlas.GlyphKey, bmp: discovery.GlyphBitmap) !atlas.AtlasEntry {
        const metrics = atlas.InsertMetrics{
            .bearing_x = clampI16(bmp.bearing_x),
            .bearing_y = clampI16(bmp.bearing_y),
            .advance_x = clampI16(bmp.advance_x),
        };
        const stride: usize = @intCast(@abs(bmp.pitch));
        var data = bmp.buffer;
        if (bmp.pitch < 0 and bmp.height > 0) {
            // Bottom-up rows: flip into scratch (atlas strides are positive).
            const h: usize = bmp.height;
            try self.ensureScratch(stride * h);
            for (0..h) |r| {
                const src = bmp.buffer[(h - 1 - r) * stride ..][0..stride];
                @memcpy(self.scratch[r * stride ..][0..stride], src);
            }
            data = self.scratch[0 .. stride * h];
        }
        const format: atlas.PixelFormat = switch (bmp.format) {
            .gray => .a8,
            .bgra => .bgra8,
        };
        return self.atlas.insert(key, metrics, .{
            .format = format,
            .width = @intCast(bmp.width),
            .height = @intCast(bmp.height),
            .data = data,
            .stride = stride,
        });
    }

    fn faceFlags(face: discovery.Face) u8 {
        var flags: u8 = 0;
        if (face.synthetic_bold) flags |= atlas.flag_synthetic_bold;
        if (face.synthetic_italic) flags |= atlas.flag_synthetic_italic;
        return flags;
    }

    fn spriteKey(self: *const CpuRenderer, cp: u21) atlas.GlyphKey {
        return .{
            .face_id = 0,
            .glyph_index = cp,
            .size_px = self.size_px,
            .flags = atlas.flag_sprite,
        };
    }

    fn ensureScratch(self: *CpuRenderer, n: usize) !void {
        if (self.scratch.len >= n) return;
        self.scratch = try self.allocator.realloc(self.scratch, n);
    }

    // ------------------------------------------------------------------
    // Decorations and cursor
    // ------------------------------------------------------------------

    fn drawDecorations(
        self: *const CpuRenderer,
        f: *Framebuffer,
        x_px: i32,
        y_px: i32,
        style: vt.Style,
        fg: u32,
        opts: RenderOpts,
    ) void {
        const flags = style.flags;
        if (flags.underline == .none and !flags.strikethrough and !flags.overline) return;
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        const baseline: i16 = @intCast(self.metrics.baseline);
        const fm = self.face.metrics();

        if (flags.underline != .none) {
            const underline_color = resolveStyleColor(style.underlineColor(), null, opts.palette, fg);
            const pos = deco.rowFromBaseline(baseline, clampI16(fm.underline_position));
            const thickness: u16 = @intCast(@max(1, fm.underline_thickness));
            deco.drawUnderline(f.*, x_px, y_px, cw, ch, underlineStyle(flags.underline), underline_color, pos, thickness);
        }
        if (flags.strikethrough) {
            // x-height is not in Face.metrics yet; half the cell height is
            // the usual monospace approximation (M3 reads OS/2 sxHeight).
            const pos = deco.strikeRow(baseline, @intCast(ch / 2));
            deco.drawStrikethrough(f.*, x_px, y_px, cw, ch, fg, pos, 1);
        }
        if (flags.overline) {
            deco.drawOverline(f.*, x_px, y_px, cw, ch, fg, 1);
        }
    }

    const CursorDraw = struct {
        active: bool = false,
        x: u16 = 0,
        y: u16 = 0,
        style: render.CursorStyle = .block,
        color: u32 = 0,
    };

    /// Resolve this frame's cursor presentation. The cursor is drawn
    /// inside the row walk; renderFrame repaints the cursor row when the
    /// blink phase flips, so a clean render state still blinks (M2.4).
    /// Only a cursor that requests blinking hides on the off-phase; a
    /// steady cursor stays visible in both phases.
    fn cursorDraw(
        self: *const CpuRenderer,
        state: *vt.RenderState,
        opts: RenderOpts,
        colors: vt.Colors,
    ) !CursorDraw {
        if (!opts.cursor_visible) return .{};
        const cur = try state.cursor();
        if (!cur.visible) return .{};
        const vp = cur.viewport orelse return .{};
        if (vp.x >= self.cols or vp.y >= self.rows) return .{};
        const blink_on = opts.cursor_blink_on orelse true;
        if (cur.blinking and !blink_on) return .{};
        return .{
            .active = true,
            .x = vp.x,
            .y = vp.y,
            .style = opts.cursor_style,
            .color = if (colors.cursor) |c| packRgb(c) else opts.default_fg,
        };
    }

    // ------------------------------------------------------------------
    // Pixel plumbing
    // ------------------------------------------------------------------

    /// Blit a cached glyph at (dst_x, dst_y), clipped to the framebuffer.
    /// a8 entries blend `color` by coverage; bgra8 entries carry their own
    /// PREMULTIPLIED BGRA pixels (color.zig and FT_LOAD_COLOR both emit
    /// premultiplied alpha), composited source-over: out = src + dst*(1-a).
    fn blitEntry(
        self: *const CpuRenderer,
        f: *Framebuffer,
        dst_x: i32,
        dst_y: i32,
        entry: atlas.AtlasEntry,
        color_word: u32,
    ) void {
        if (entry.width == 0 or entry.height == 0) return;
        const c = clipToFb(f, dst_x, dst_y, entry.width, entry.height) orelse return;
        switch (entry.format) {
            .a8 => {
                const region = self.atlas.a8Region(entry);
                var r: u32 = 0;
                while (r < c.h) : (r += 1) {
                    const src = region.data[(@as(usize, c.src_y) + r) * region.stride + c.src_x ..][0..c.w];
                    const dst = fbRow(f, c.x, c.y + r, c.w);
                    blendA8Row(dst, src, color_word);
                }
            },
            .bgra8 => {
                const region = self.atlas.bgra8Region(entry);
                var r: u32 = 0;
                while (r < c.h) : (r += 1) {
                    const src = region.data[(@as(usize, c.src_y) + r) * region.stride + @as(usize, c.src_x) * 4 ..][0 .. @as(usize, c.w) * 4];
                    const dst = fbRow(f, c.x, c.y + r, c.w);
                    var i: usize = 0;
                    while (i < c.w) : (i += 1) {
                        const off = i * 4;
                        const a = src[off + 3];
                        if (a == 0) continue;
                        const d = std.mem.readInt(u32, dst[off..][0..4], .little);
                        const out = if (a == 255)
                            (@as(u32, src[off + 2]) << 16) | (@as(u32, src[off + 1]) << 8) | src[off]
                        else
                            blendPremul(src[off + 2], (d >> 16) & 0xff, a) << 16 |
                                blendPremul(src[off + 1], (d >> 8) & 0xff, a) << 8 |
                                blendPremul(src[off], d & 0xff, a);
                        std.mem.writeInt(u32, dst[off..][0..4], out, .little);
                    }
                }
            },
        }
    }

    /// Blit with downscale-to-fit: a glyph wider than its cell span (1 or 2
    /// cells -- the width always comes from libghostty, R1) is box-filtered
    /// down, aspect preserved. Native-size glyphs take the fast path.
    fn blitFit(
        self: *const CpuRenderer,
        f: *Framebuffer,
        dst_x: i32,
        dst_y: i32,
        entry: atlas.AtlasEntry,
        fg: u32,
        max_w: u32,
    ) void {
        if (entry.width == 0 or entry.height == 0) return;
        if (max_w == 0 or entry.width <= max_w) return self.blitEntry(f, dst_x, dst_y, entry, fg);
        const dw = max_w;
        const scale = @as(f32, @floatFromInt(dw)) / @as(f32, @floatFromInt(entry.width));
        const dh = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(entry.height)) * scale))));
        const c = clipToFb(f, dst_x, dst_y, dw, dh) orelse return;
        const sw: u64 = entry.width;
        const sh: u64 = entry.height;
        const region = switch (entry.format) {
            .a8 => self.atlas.a8Region(entry),
            .bgra8 => self.atlas.bgra8Region(entry),
        };
        const bpp: usize = if (entry.format == .a8) 1 else 4;
        var r: u32 = 0;
        while (r < c.h) : (r += 1) {
            const dy: u64 = c.src_y + r;
            const sy0 = dy * sh / dh;
            const sy1 = @max((dy + 1) * sh / dh, sy0 + 1);
            const dst = fbRow(f, c.x, c.y + r, c.w);
            var i: u32 = 0;
            while (i < c.w) : (i += 1) {
                const dx: u64 = c.src_x + i;
                const sx0 = dx * sw / dw;
                const sx1 = @max((dx + 1) * sw / dw, sx0 + 1);
                var sum = [4]u64{ 0, 0, 0, 0 };
                var count: u64 = 0;
                var sy = sy0;
                while (sy < sy1) : (sy += 1) {
                    const src_row = region.data[@as(usize, sy) * region.stride ..];
                    var sx = sx0;
                    while (sx < sx1) : (sx += 1) {
                        const off = @as(usize, sx) * bpp;
                        if (bpp == 1) {
                            sum[0] += src_row[off];
                        } else {
                            sum[0] += src_row[off];
                            sum[1] += src_row[off + 1];
                            sum[2] += src_row[off + 2];
                            sum[3] += src_row[off + 3];
                        }
                        count += 1;
                    }
                }
                const off = @as(usize, i) * 4;
                const d = std.mem.readInt(u32, dst[off..][0..4], .little);
                const out: u32 = switch (entry.format) {
                    .a8 => blendPixel(fg, d, @intCast((sum[0] + count / 2) / count)),
                    .bgra8 => blk: {
                        const a: u8 = @intCast((sum[3] + count / 2) / count);
                        if (a == 0) break :blk d;
                        const b: u32 = @intCast((sum[0] + count / 2) / count);
                        const g: u32 = @intCast((sum[1] + count / 2) / count);
                        const rr: u32 = @intCast((sum[2] + count / 2) / count);
                        break :blk blendPremul(rr, (d >> 16) & 0xff, a) << 16 |
                            blendPremul(g, (d >> 8) & 0xff, a) << 8 |
                            blendPremul(b, d & 0xff, a);
                    },
                };
                std.mem.writeInt(u32, dst[off..][0..4], out, .little);
            }
        }
    }

    // ------------------------------------------------------------------
    // vtable wiring
    // ------------------------------------------------------------------

    const vtable = render.Renderer.VTable{
        .deinit = vtDeinit,
        .resize = vtResize,
        .renderFrame = vtRenderFrame,
    };

    fn cast(ptr: *anyopaque) *CpuRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn vtResize(ptr: *anyopaque, new_cols: u16, new_rows: u16, cell_w: u16, cell_h: u16) anyerror!void {
        return cast(ptr).resize(new_cols, new_rows, cell_w, cell_h);
    }

    fn vtRenderFrame(
        ptr: *anyopaque,
        state: *const anyopaque,
        f: *Framebuffer,
        damage: *DamageList,
        opts: RenderOpts,
    ) anyerror!void {
        // The vt accessors mutate iterator handles, so the opaque pointer
        // is cast to a mutable RenderState. The caller passes a live state
        // it has already update()d (module comment).
        const rs: *vt.RenderState = @ptrCast(@alignCast(@constCast(state)));
        return cast(ptr).renderFrame(rs, f, damage, opts);
    }
};

/// M8.1 shaped-cluster cache: complex grapheme clusters (emoji ZWJ
/// sequences, flags, combining marks) repeat heavily in terminal output;
/// shaping each occurrence with HarfBuzz dominated unicode frame cost.
/// Entries own copies of the codepoints and shaped glyphs, keyed by a
/// (face, style, codepoints) content hash with full verification on hit.
/// Bounded: cleared wholesale when full — a terminal's distinct-cluster
/// working set is small. Valid for the renderer's lifetime (face table
/// and features are stable; setFontSize re-initializes the renderer).
const ClusterCache = struct {
    const Entry = struct {
        face_id: u16,
        style_flags: u8,
        cps: []u21,
        glyphs: []shaper.ShapedGlyph,
        direction: shaper.Direction,
    };
    const cap = 1024;

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, u32),
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    fn init(allocator: std.mem.Allocator) ClusterCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u64, u32).init(allocator),
        };
    }

    fn deinit(self: *ClusterCache) void {
        self.clear();
        self.map.deinit();
        self.entries.deinit(self.allocator);
    }

    fn clear(self: *ClusterCache) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.cps);
            self.allocator.free(e.glyphs);
        }
        self.entries.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
    }

    fn get(self: *const ClusterCache, face_id: u16, style_flags: u8, cps: []const u21) ?*const Entry {
        const idx = self.map.get(hash(face_id, style_flags, cps)) orelse return null;
        const e = &self.entries.items[idx];
        if (e.face_id != face_id or e.style_flags != style_flags or
            !std.mem.eql(u21, e.cps, cps)) return null;
        return e;
    }

    fn put(
        self: *ClusterCache,
        face_id: u16,
        style_flags: u8,
        cps: []const u21,
        glyphs: []const shaper.ShapedGlyph,
        direction: shaper.Direction,
    ) !void {
        if (self.entries.items.len >= cap) self.clear();
        const cps_copy = try self.allocator.dupe(u21, cps);
        errdefer self.allocator.free(cps_copy);
        const glyphs_copy = try self.allocator.dupe(shaper.ShapedGlyph, glyphs);
        errdefer self.allocator.free(glyphs_copy);
        try self.entries.append(self.allocator, .{
            .face_id = face_id,
            .style_flags = style_flags,
            .cps = cps_copy,
            .glyphs = glyphs_copy,
            .direction = direction,
        });
        try self.map.put(hash(face_id, style_flags, cps), @intCast(self.entries.items.len - 1));
    }

    fn hash(face_id: u16, style_flags: u8, cps: []const u21) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&face_id));
        h.update(std.mem.asBytes(&style_flags));
        h.update(std.mem.sliceAsBytes(cps));
        return h.final();
    }
};

// ---------------------------------------------------------------------------
// Color resolution (pure)
// ---------------------------------------------------------------------------

const CellColors = struct { fg: u32, bg: u32 };

/// Effective cell colors: style color first (so the session's palette
/// wins over the library-resolved RGB), then the cell-level resolved
/// override, then the frame default. Inverse swaps the pair, opacity
/// blends the background toward the default background, faint blends the
/// foreground toward the painted background. Selected cells (M2.3 mouse
/// selection) invert last, like libtsm's selection rendering -- so SGR
/// inverse cells invert back.
fn resolveColors(cell: *const vt.Cell, opts: RenderOpts) CellColors {
    var fg = resolveStyleColor(cell.style.fg(), cell.fg, opts.palette, opts.default_fg);
    var bg = resolveStyleColor(cell.style.bg(), cell.bg, opts.palette, opts.default_bg);
    if (cell.style.flags.inverse) {
        const c = deco.applyInverse(fg, bg);
        fg = c.fg;
        bg = c.bg;
    }
    bg = blendOpacity(bg, opts.default_bg, opts.bg_opacity);
    if (cell.style.flags.faint) fg = deco.applyFaint(fg, bg);
    if (cell.selected) {
        const c = deco.applyInverse(fg, bg);
        fg = c.fg;
        bg = c.bg;
    }
    return .{ .fg = fg, .bg = bg };
}

fn resolveStyleColor(sc: ?vt.StyleColor, resolved: ?vt.Rgb, palette: *const [18]u32, default: u32) u32 {
    if (sc) |c| switch (c) {
        .palette => |idx| return paletteColor(palette, idx),
        .rgb => |rgb| return packRgb(rgb),
    };
    if (resolved) |rgb| return packRgb(rgb);
    return default;
}

fn packRgb(c: vt.Rgb) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// Palette lookup. Slots 0..15 come from the session table (slots 16/17
/// are the default fg/bg, reached through RenderOpts, not indices).
/// Indices 16..255 use the standard xterm 256-color cube and grayscale
/// (palette.xterm256, shared with the terminal's color_palette option).
fn paletteColor(palette: *const [18]u32, idx: u8) u32 {
    if (idx < 16) return palette[idx];
    return presets.xterm256(idx).xrgb();
}

/// Blend `color` toward `base` with `opacity` (0 = base, 255 = color).
fn blendOpacity(color_word: u32, base: u32, opacity: u8) u32 {
    if (opacity == 255) return color_word;
    if (opacity == 0) return base;
    const a: u32 = opacity;
    const r = blendChannel((color_word >> 16) & 0xff, (base >> 16) & 0xff, @intCast(a));
    const g = blendChannel((color_word >> 8) & 0xff, (base >> 8) & 0xff, @intCast(a));
    const b = blendChannel(color_word & 0xff, base & 0xff, @intCast(a));
    return (r << 16) | (g << 8) | b;
}

/// Source-over blend of one channel: `fg` at coverage `a` over `bg`.
fn blendChannel(fg: u32, bg: u32, a: u8) u32 {
    const aa: u32 = a;
    return (fg * aa + bg * (255 - aa) + 127) / 255;
}

fn blendPixel(fg: u32, bg: u32, a: u8) u32 {
    const r = blendChannel((fg >> 16) & 0xff, (bg >> 16) & 0xff, a);
    const g = blendChannel((fg >> 8) & 0xff, (bg >> 8) & 0xff, a);
    const b = blendChannel(fg & 0xff, bg & 0xff, a);
    return (r << 16) | (g << 8) | b;
}

/// Vectorized a8 coverage blend for one glyph row: `src` holds one coverage
/// byte per pixel, `dst` the xrgb pixels. Blends `fg` over the existing dst
/// (a==0 leaves dst, a==255 writes fg), 4 pixels per SIMD step; the result
/// is bit-identical to blendPixel. The scalar tail handles the remainder.
/// M8.1: the unicode benchmark blits the same .notdef raster into thousands
/// of CJK cells per frame, so the per-pixel blend is the frame bottleneck.
fn blendA8Row(dst: []u8, src: []const u8, fg: u32) void {
    const V = @Vector(4, u32);
    const n = src.len;
    const fgr: V = @splat((fg >> 16) & 0xff);
    const fgg: V = @splat((fg >> 8) & 0xff);
    const fgb: V = @splat(fg & 0xff);
    const mask: V = @splat(0xff);
    const round: V = @splat(127);
    const k255: V = @splat(255);
    const s16: V = @splat(16);
    const s8: V = @splat(8);
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const av: V = .{ src[i], src[i + 1], src[i + 2], src[i + 3] };
        const dv = @as(*align(1) const V, @ptrCast(dst[i * 4 ..].ptr)).*;
        const inv = k255 - av;
        const rr = (fgr * av + ((dv >> s16) & mask) * inv + round) / k255;
        const gg = (fgg * av + ((dv >> s8) & mask) * inv + round) / k255;
        const bb = (fgb * av + (dv & mask) * inv + round) / k255;
        @as(*align(1) V, @ptrCast(dst[i * 4 ..].ptr)).* = (rr << s16) | (gg << s8) | bb;
    }
    while (i < n) : (i += 1) {
        const a = src[i];
        if (a == 0) continue;
        const off = i * 4;
        const d = std.mem.readInt(u32, dst[off..][0..4], .little);
        std.mem.writeInt(u32, dst[off..][0..4], if (a == 255) fg else blendPixel(fg, d, a), .little);
    }
}

/// Source-over of one PREMULTIPLIED source channel over an opaque dst
/// channel: out = src + dst * (1 - a).
fn blendPremul(sc: u32, dc: u32, a: u8) u32 {
    const inv: u32 = 255 - @as(u32, a);
    return @min(255, sc + (dc * inv + 127) / 255);
}

fn clampI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn roundI32(v: f32) i32 {
    return @intFromFloat(@round(v));
}

fn cursorStyle(s: render.CursorStyle) deco.CursorStyle {
    return switch (s) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    };
}

fn underlineStyle(u: vt.Underline) deco.UnderlineStyle {
    return switch (u) {
        .none => .none,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

// ---------------------------------------------------------------------------
// Pixel plumbing (pure)
// ---------------------------------------------------------------------------

/// Visible part of a `w`x`h` rect placed at (dx, dy) on the framebuffer,
/// with the matching source offset. Null when nothing is visible.
const Clip = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    src_x: u32,
    src_y: u32,
};

fn clipToFb(f: *const Framebuffer, dx: i32, dy: i32, w: u32, h: u32) ?Clip {
    const x0: i64 = @max(@as(i64, dx), 0);
    const y0: i64 = @max(@as(i64, dy), 0);
    const x1: i64 = @min(@as(i64, dx) + w, f.width);
    const y1: i64 = @min(@as(i64, dy) + h, f.height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
        .src_x = @intCast(x0 - dx),
        .src_y = @intCast(y0 - dy),
    };
}

/// One framebuffer row's pixel bytes, `w` pixels wide starting at (x, y).
fn fbRow(f: *const Framebuffer, x: u32, y: u32, w: u32) []u8 {
    const start = @as(usize, y) * f.pitch + @as(usize, x) * 4;
    return f.mem[start..][0 .. @as(usize, w) * 4];
}

/// Paint one cell rectangle, clipped to the framebuffer.
fn fillCell(f: *Framebuffer, x: i32, y: i32, w: u16, h: u16, color_word: u32) void {
    const c = clipToFb(f, x, y, w, h) orelse return;
    var r: u32 = 0;
    while (r < c.h) : (r += 1) {
        const row = fbRow(f, c.x, c.y + r, c.w);
        var i: usize = 0;
        while (i < row.len) : (i += 4) {
            std.mem.writeInt(u32, row[i..][0..4], color_word, .little);
        }
    }
}

/// Rotate-blit the logical (content-space) framebuffer `src` into the
/// physical framebuffer `dst` (ROADMAP M5.4). `rotation` is the clockwise
/// turn of the content onto the panel, using the same convention as
/// video/layout.zig: each physical pixel takes the source pixel at
/// `rotation.physicalToLogical`. `src` must have the effective (logical)
/// dimensions of `dst` under `rotation` (the axes swap at 90/270 degrees).
/// Formats must match; words are copied verbatim (no blending). This is
/// the renderer-side rotation path used when the DRM backend exposes no
/// plane rotation (drm2d does not).
pub fn blitRotated(dst: Framebuffer, src: Framebuffer, rotation: layout.Rotation) void {
    std.debug.assert(dst.format == src.format);
    const pw: usize = dst.width;
    const ph: usize = dst.height;
    const sw: usize = src.width;
    const sh: usize = src.height;
    const dpitch: usize = dst.pitch;
    const spitch: usize = src.pitch;
    switch (rotation) {
        .normal => {
            std.debug.assert(sw == pw and sh == ph);
            dst.blitFrom(src, 0, 0, .{ .x = 0, .y = 0, .w = dst.width, .h = dst.height });
        },
        .inverted => {
            std.debug.assert(sw == pw and sh == ph);
            var y: usize = 0;
            while (y < ph) : (y += 1) {
                const drow = dst.mem[y * dpitch ..][0 .. pw * 4];
                const srow = src.mem[(sh - 1 - y) * spitch ..][0 .. sw * 4];
                var x: usize = 0;
                while (x < pw) : (x += 1) {
                    const word = std.mem.readInt(u32, srow[(sw - 1 - x) * 4 ..][0..4], .little);
                    std.mem.writeInt(u32, drow[x * 4 ..][0..4], word, .little);
                }
            }
        },
        .right => {
            std.debug.assert(sw == ph and sh == pw);
            var y: usize = 0;
            while (y < ph) : (y += 1) {
                const drow = dst.mem[y * dpitch ..][0 .. pw * 4];
                var x: usize = 0;
                while (x < pw) : (x += 1) {
                    // physical (x, y) <- logical (y, pw - 1 - x)
                    const off = (pw - 1 - x) * spitch + y * 4;
                    const word = std.mem.readInt(u32, src.mem[off..][0..4], .little);
                    std.mem.writeInt(u32, drow[x * 4 ..][0..4], word, .little);
                }
            }
        },
        .left => {
            std.debug.assert(sw == ph and sh == pw);
            var y: usize = 0;
            while (y < ph) : (y += 1) {
                const drow = dst.mem[y * dpitch ..][0 .. pw * 4];
                var x: usize = 0;
                while (x < pw) : (x += 1) {
                    // physical (x, y) <- logical (ph - 1 - y, x)
                    const off = x * spitch + (ph - 1 - y) * 4;
                    const word = std.mem.readInt(u32, src.mem[off..][0..4], .little);
                    std.mem.writeInt(u32, drow[x * 4 ..][0..4], word, .little);
                }
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests: real libghostty-vt terminal + real host fonts. Run via
// src/test_cpu.zig (command in that file's header).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// One test seat: discovery + face + renderer + terminal + render state +
/// framebuffer, all real. The legacy preset supplies the palette. The
/// Discovery is heap-allocated so the renderer's borrowed pointer stays
/// valid when the Env is moved.
const Env = struct {
    d: *discovery.Discovery,
    cpu: CpuRenderer,
    t: vt.Vt,
    state: vt.RenderState,
    f: Framebuffer,
    palette: [18]u32,

    fn init(a: std.mem.Allocator, cols: u16, rows: u16) !Env {
        return initWithFont(a, cols, rows, null, &.{});
    }

    fn initWithFont(
        a: std.mem.Allocator,
        cols: u16,
        rows: u16,
        font_name: ?[]const u8,
        font_features: []const []const u8,
    ) !Env {
        const d = try a.create(discovery.Discovery);
        errdefer a.destroy(d);
        d.* = try discovery.Discovery.init(a);
        errdefer d.deinit();
        var face = try d.primaryFace(font_name, 16);
        var cpu = try CpuRenderer.init(a, d, &face, .{ .size_px = 16, .font_features = font_features });
        errdefer cpu.deinit();
        try cpu.resize(cols, rows, cpu.metrics.cell_w, cpu.metrics.cell_h);
        var t = try vt.Vt.init(cols, rows);
        errdefer t.deinit();
        var state = try vt.RenderState.new();
        errdefer state.deinit();
        var f = try Framebuffer.create(
            a,
            @as(u32, cols) * cpu.metrics.cell_w,
            @as(u32, rows) * cpu.metrics.cell_h,
            .xrgb8888,
            null,
        );
        errdefer f.destroy(a);
        var palette: [18]u32 = undefined;
        for (&palette, presets.Preset.legacy.get()) |*dst, c| dst.* = c.xrgb();
        return .{ .d = d, .cpu = cpu, .t = t, .state = state, .f = f, .palette = palette };
    }

    fn deinit(self: *Env, a: std.mem.Allocator) void {
        self.f.destroy(a);
        self.state.deinit();
        self.t.deinit();
        self.cpu.deinit();
        self.d.deinit();
        a.destroy(self.d);
    }

    fn opts(self: *Env) RenderOpts {
        return .{
            .cursor_visible = true,
            .cursor_style = .block,
            .cursor_blink_on = null,
            .palette = &self.palette,
            .default_fg = self.palette[16],
            .default_bg = self.palette[17],
            .bg_opacity = 255,
        };
    }

    fn render(self: *Env, damage: *DamageList) !void {
        try self.renderOpts(damage, self.opts());
    }

    fn renderOpts(self: *Env, damage: *DamageList, o: RenderOpts) !void {
        try self.state.update(&self.t);
        try self.cpu.renderer().renderFrame(&self.state, &self.f, damage, o);
    }

    /// Render with the cursor hidden (glyph-only assertions).
    fn renderNoCursor(self: *Env, damage: *DamageList) !void {
        var o = self.opts();
        o.cursor_visible = false;
        try self.renderOpts(damage, o);
    }

    fn cellHasInk(self: *const Env, col: u16, row: u16) bool {
        return self.cellInkCount(col, row) > 0;
    }

    fn cellInkCount(self: *const Env, col: u16, row: u16) u32 {
        const cw = self.cpu.metrics.cell_w;
        const ch = self.cpu.metrics.cell_h;
        const bg = self.palette[17];
        var count: u32 = 0;
        var y: u32 = @as(u32, row) * ch;
        while (y < (@as(u32, row) + 1) * ch) : (y += 1) {
            var x: u32 = @as(u32, col) * cw;
            while (x < (@as(u32, col) + 1) * cw) : (x += 1) {
                if (self.f.get(x, y) != bg) count += 1;
            }
        }
        return count;
    }
};

test "cpu: text, SGR color, block cursor, dirty-row tracking" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];

    env.f.fill(bg); // the session clears to the default background
    env.t.write("\x1b[?25hhello\r\n\x1b[31mRED\x1b[0m");

    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.render(&damage);
    try testing.expect(damage.items.len >= 2);

    // Row 0 carries "hello": non-background pixels exist.
    try testing.expect(env.cellHasInk(0, 0));
    try testing.expect(env.cellHasInk(4, 0));
    try testing.expect(!env.cellHasInk(10, 0));

    // "RED" on row 1 with SGR 31: red-ish pixels in columns 0..2.
    var found_red = false;
    var y: u32 = ch;
    while (y < 2 * ch and !found_red) : (y += 1) {
        var x: u32 = 0;
        while (x < 3 * cw) : (x += 1) {
            const p = env.f.get(x, y);
            if ((p >> 16) & 0xff > 150 and (p >> 8) & 0xff < 100 and p & 0xff < 100) {
                found_red = true;
                break;
            }
        }
    }
    try testing.expect(found_red);

    // Block cursor at row 1, column 3 (after "RED"): the empty cell is
    // filled with the cursor color (default fg).
    try testing.expectEqual(env.palette[16], env.f.get(3 * cw + cw / 2, ch + ch / 2));

    // Damage covers both drawn rows.
    var covers_row0 = false;
    var covers_row1 = false;
    for (damage.items) |d| {
        if (d.y <= 0 and d.y + d.h >= ch) covers_row0 = true;
        if (d.y <= ch and d.y + d.h >= 2 * ch) covers_row1 = true;
    }
    try testing.expect(covers_row0 and covers_row1);

    // Second frame with no terminal changes: clean state, no damage, no
    // pixel changes.
    const snapshot = try a.dupe(u8, env.f.mem);
    defer a.free(snapshot);
    var damage2: DamageList = .empty;
    defer damage2.deinit(a);
    try env.render(&damage2);
    try testing.expectEqual(@as(usize, 0), damage2.items.len);
    try testing.expectEqualSlices(u8, snapshot, env.f.mem);
}

test "cpu: selection highlight inverts cells and dirties the row" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    const fg = env.palette[16];

    env.f.fill(bg);
    env.t.write("\x1b[?25hhello");
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);
    // The bottom-right corner of a cell is background (no descender ink).
    try testing.expectEqual(bg, env.f.get(cw - 1, ch - 1));

    // Install a selection over cells 0..4: the row must repaint (damage)
    // and selected cells get the inverted background.
    const start = try env.t.gridRef(.viewport, .{ .x = 0, .y = 0 });
    const end = try env.t.gridRef(.viewport, .{ .x = 4, .y = 0 });
    const sel: vt.Selection = .{ .start = start, .end = end };
    try env.t.setSelection(&sel);
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(fg, env.f.get(cw - 1, ch - 1));
    // Cell 5 is outside the selection: default background.
    try testing.expectEqual(bg, env.f.get(5 * cw + cw - 1, ch - 1));

    // Clearing the selection restores the background and repaints.
    try env.t.setSelection(null);
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(bg, env.f.get(cw - 1, ch - 1));
}

test "cpu: wide cell draws base, skips continuation, no panic" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    env.f.fill(env.palette[17]);

    // U+4E2D (wide) followed by a narrow cell, then a wide char forced
    // against the right edge (spacer_head path).
    env.t.write("\x1b[?25h\xe4\xb8\xadA");
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.render(&damage);
    try testing.expect(damage.items.len > 0);
    // The host monospace face may lack CJK; assert ink only when covered.
    if (env.cpu.face.glyphIndex(0x4E2D) != null) {
        try testing.expect(env.cellHasInk(0, 0));
    }
    try testing.expect(env.cellHasInk(2, 0)); // the 'A' after the wide cell

    env.t.write("\r");
    for (0..79) |_| env.t.write(" ");
    env.t.write("\xe4\xb8\xad");
    var damage2: DamageList = .empty;
    defer damage2.deinit(a);
    try env.render(&damage2);
    try testing.expect(damage2.items.len > 0);
}

test "cpu: U+2500 renders via the sprite path; atlas survives resize" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    env.f.fill(bg);

    env.t.write("\x1b[?25h\xe2\x94\x80"); // U+2500 BOX DRAWINGS LIGHT HORIZONTAL
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.render(&damage);

    // Cached as a sprite, and no font glyph was loaded for it.
    const key = env.cpu.spriteKey(0x2500);
    try testing.expect(env.cpu.atlas.contains(key));
    try testing.expectEqual(@as(usize, 1), env.cpu.atlas.count());

    // A full-width horizontal stroke in the middle band; top row empty.
    var lit_row: ?u32 = null;
    var y: u32 = ch / 4;
    while (y < (3 * ch) / 4) : (y += 1) {
        var full = true;
        for (0..cw) |x| {
            if (env.f.get(@intCast(x), y) == bg) {
                full = false;
                break;
            }
        }
        if (full) {
            lit_row = y;
            break;
        }
    }
    try testing.expect(lit_row != null);
    for (0..cw) |x| try testing.expectEqual(bg, env.f.get(@intCast(x), 0));

    // Same cell size: the atlas survives resize untouched.
    try env.cpu.resize(40, 12, cw, ch);
    try testing.expect(env.cpu.atlas.contains(key));
    try testing.expectEqual(@as(usize, 1), env.cpu.atlas.count());

    // Cell size change: the cell-sized sprite is invalidated.
    try env.cpu.resize(40, 12, cw + 1, ch);
    try testing.expect(!env.cpu.atlas.contains(key));
}

test "cpu: bg_opacity, invisible and inverse" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    env.f.fill(bg);

    // Cell 0: space with red background. Cell 1: invisible 'X'.
    // Cell 2: inverse 'I'.
    env.t.write("\x1b[?25h\x1b[41m \x1b[0m\x1b[8mX\x1b[0m\x1b[7mI\x1b[0m");
    var o = env.opts();
    o.bg_opacity = 128;
    try env.state.update(&env.t);
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.cpu.renderer().renderFrame(&env.state, &env.f, &damage, o);

    // Red background blended ~50% toward the default background.
    const p = env.f.get(cw / 2, ch / 2);
    const r = (p >> 16) & 0xff;
    try testing.expect(r >= 90 and r <= 140);
    try testing.expectEqual(@as(u32, 0), (p >> 8) & 0xff);
    try testing.expectEqual(@as(u32, 0), p & 0xff);

    // Invisible: background painted, no glyph.
    try testing.expect(!env.cellHasInk(1, 0));

    // Inverse: the cell background becomes the default foreground,
    // blended toward the default background by bg_opacity like any bg.
    try testing.expectEqual(blendOpacity(env.palette[16], env.palette[17], 128), env.f.get(2 * cw, 0));
    try testing.expect(env.cellHasInk(2, 0));
}

test "cpu: SGR blink hides text on the off-phase, repaints clean rows (M2.4)" {
    const a = testing.allocator;
    var env = try Env.init(a, 40, 8);
    defer env.deinit(a);
    const bg = env.palette[17];
    env.f.fill(bg);

    // "BLINK" carries SGR 5, "plain" does not. Cursor hidden: isolate text.
    env.t.write("\x1b[?25l\x1b[5mBLINK\x1b[0m plain");
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    var o = env.opts();
    o.cursor_blink_on = true;
    try env.renderOpts(&damage, o);
    try testing.expect(env.cellHasInk(0, 0));
    try testing.expect(env.cellHasInk(4, 0));
    try testing.expect(env.cellHasInk(6, 0));

    // Off-phase on a CLEAN render state: the blink row must repaint, the
    // blink glyphs vanish (background stays), the plain text survives.
    try env.state.update(&env.t);
    try testing.expectEqual(vt.Dirty.clean, try env.state.dirty());
    damage.clearRetainingCapacity();
    o.cursor_blink_on = false;
    try env.cpu.renderer().renderFrame(&env.state, &env.f, &damage, o);
    try testing.expect(damage.items.len > 0);
    for (0..5) |x| try testing.expect(!env.cellHasInk(@intCast(x), 0));
    try testing.expect(env.cellHasInk(6, 0));
    try testing.expectEqual(bg, env.f.get(0, 0));

    // Same phase again: clean state, no repaint.
    const snapshot = try a.dupe(u8, env.f.mem);
    defer a.free(snapshot);
    damage.clearRetainingCapacity();
    try env.renderOpts(&damage, o);
    try testing.expectEqual(@as(usize, 0), damage.items.len);
    try testing.expectEqualSlices(u8, snapshot, env.f.mem);

    // Back on: the glyphs return.
    damage.clearRetainingCapacity();
    o.cursor_blink_on = true;
    try env.renderOpts(&damage, o);
    try testing.expect(damage.items.len > 0);
    try testing.expect(env.cellHasInk(0, 0));
    try testing.expect(env.cellHasInk(4, 0));
}

test "cpu: cursor blink phase repaints the cursor row on a clean state (M2.4)" {
    const a = testing.allocator;
    var env = try Env.init(a, 40, 8);
    defer env.deinit(a);
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    const cursor_color = env.palette[16]; // no explicit cursor color: default fg
    env.f.fill(bg);

    const blink_default = true;
    try env.t.setOption(.default_cursor_blink, &blink_default);
    env.t.write("\x1b[?25hhi"); // block cursor at (2, 0)
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    var o = env.opts();
    o.cursor_blink_on = true;
    try env.renderOpts(&damage, o);
    try testing.expectEqual(cursor_color, env.f.get(2 * cw + cw / 2, ch / 2));

    // Off-phase: the render state is clean (no terminal change), yet the
    // cursor row must repaint and the block cursor disappear.
    try env.state.update(&env.t);
    try testing.expectEqual(vt.Dirty.clean, try env.state.dirty());
    damage.clearRetainingCapacity();
    o.cursor_blink_on = false;
    try env.cpu.renderer().renderFrame(&env.state, &env.f, &damage, o);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(bg, env.f.get(2 * cw + cw / 2, ch / 2));
    try testing.expect(env.cellHasInk(0, 0)); // the text stays

    // On-phase again: the cursor returns.
    damage.clearRetainingCapacity();
    o.cursor_blink_on = true;
    try env.renderOpts(&damage, o);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(cursor_color, env.f.get(2 * cw + cw / 2, ch / 2));

    // A steady cursor (blinking off) stays visible in the off-phase.
    const steady_default = false;
    try env.t.setOption(.default_cursor_blink, &steady_default);
    damage.clearRetainingCapacity();
    o.cursor_blink_on = false;
    try env.renderOpts(&damage, o);
    try testing.expectEqual(cursor_color, env.f.get(2 * cw + cw / 2, ch / 2));
}

test "cpu: palette indices beyond 16 use the xterm cube" {
    const palette: [18]u32 = @splat(0);
    // 196 = pure red in the 6x6x6 cube; 232 = first grayscale step.
    try testing.expectEqual(@as(u32, 0xFF0000), paletteColor(&palette, 196));
    try testing.expectEqual(@as(u32, 0x080808), paletteColor(&palette, 232));
    try testing.expectEqual(@as(u32, 0xEEEEEE), paletteColor(&palette, 255));
    // Slots 0..15 come from the table.
    const p2: [18]u32 = .{ 0x123456, 0 } ++ @as([16]u32, @splat(0));
    try testing.expectEqual(@as(u32, 0x123456), paletteColor(&p2, 0));
}

test "cpu: combining cluster shapes into one cell (M3.4)" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    env.f.fill(env.palette[17]);
    // Consume the initial full-dirty frame so the next render's row
    // scratch holds exactly the row we write.
    var d0: DamageList = .empty;
    defer d0.deinit(a);
    try env.renderNoCursor(&d0);

    // e + U+0301 COMBINING ACUTE ACCENT is ONE grapheme cluster, then 'x'.
    env.t.write("\x1b[?25he\u{0301}x");
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);

    // Both codepoints live in cell 0; cell 1 is the 'x', not the accent.
    const rc0 = env.cpu.row_cells[0];
    try testing.expectEqual(@as(u32, 2), rc0.n_cps);
    try testing.expectEqual(@as(u8, 1), rc0.width);
    try testing.expectEqual(@as(u21, 'e'), env.cpu.row_cps.items[rc0.cps_start]);
    try testing.expectEqual(@as(u21, 0x0301), env.cpu.row_cps.items[rc0.cps_start + 1]);
    try testing.expectEqual(@as(u32, 1), env.cpu.row_cells[1].n_cps);
    try testing.expectEqual(@as(u21, 'x'), env.cpu.row_cps.items[env.cpu.row_cells[1].cps_start]);
    try testing.expect(env.cellHasInk(0, 0));
    try testing.expect(env.cellHasInk(1, 0));
    const ink_with_mark = env.cellInkCount(0, 0);

    // Plain 'e' on row 1: the accent must have added ink above the base.
    env.t.write("\r\ne");
    var damage2: DamageList = .empty;
    defer damage2.deinit(a);
    try env.renderNoCursor(&damage2);
    try testing.expect(env.cellHasInk(0, 1));
    try testing.expect(ink_with_mark > env.cellInkCount(0, 1));
}

test "cpu: wide CJK spans two cells through the fallback face (M3.4)" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    env.f.fill(env.palette[17]);
    var d0: DamageList = .empty;
    defer d0.deinit(a);
    try env.renderNoCursor(&d0); // consume the initial full-dirty frame

    env.t.write("\x1b[?25h\xe4\xb8\xadA"); // U+4E2D (wide) + 'A'
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);

    // Width comes from libghostty: base owns 2 cells, continuation 0.
    try testing.expectEqual(@as(u8, 2), env.cpu.row_cells[0].width);
    try testing.expectEqual(@as(u8, 0), env.cpu.row_cells[1].width);
    try testing.expectEqual(@as(u32, 0), env.cpu.row_cells[1].n_cps);
    try testing.expectEqual(@as(u8, 1), env.cpu.row_cells[2].width);

    // Ink in BOTH cells of the wide span when a face covers the glyph
    // (primary or fallback); the host may have neither.
    const covered = env.cpu.face.glyphIndex(0x4E2D) != null or env.cpu.row_cells[0].face_id != 0;
    if (covered) {
        try testing.expect(env.cellHasInk(0, 0));
        try testing.expect(env.cellHasInk(1, 0));
    }
    try testing.expect(env.cellHasInk(2, 0)); // the 'A'
}

test "cpu: color emoji renders premultiplied BGRA (M3.5)" {
    const a = testing.allocator;
    // The host fallback ranking may prefer a monochrome face for emoji
    // (DejaVu Sans covers U+1F600 with outlines), so pin the CBDT color
    // face as primary through discovery. Its bitmap strike makes cells
    // large: keep the grid tiny.
    var env = Env.initWithFont(a, 4, 2, "Noto Color Emoji", &.{}) catch |err| switch (err) {
        error.NoFontMatch, error.BadFontName => return error.SkipZigTest, // no color face installed
        else => return err,
    };
    defer env.deinit(a);
    env.f.fill(env.palette[17]);

    var d0: DamageList = .empty;
    defer d0.deinit(a);
    try env.renderNoCursor(&d0); // consume the initial full-dirty frame

    // U+1F600 GRINNING FACE on row 0.
    env.t.write("\x1b[?25h\xf0\x9f\x98\x80");
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);

    const rc = env.cpu.row_cells[0];
    try testing.expectEqual(@as(u8, 2), rc.width); // emoji is wide
    const slot = env.cpu.faces.items[rc.face_id];
    try testing.expect(slot.has_color);

    // The shaped glyph is cached on the bgra8 page.
    const idx = slot.face.glyphIndex(0x1F600) orelse return error.TestUnexpectedResult;
    const key = atlas.GlyphKey{
        .face_id = rc.face_id,
        .glyph_index = idx,
        .size_px = env.cpu.size_px,
        .flags = CpuRenderer.faceFlags(slot.face),
    };
    const entry = env.cpu.atlas.get(key) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(atlas.PixelFormat.bgra8, entry.format);

    // Color pixels: the grinning face is yellow, impossible for the
    // monochrome foreground. Scan the wide span on row 0.
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    var found_color = false;
    var y: u32 = 0;
    while (y < ch and !found_color) : (y += 1) {
        var x: u32 = 0;
        while (x < 2 * cw) : (x += 1) {
            const p = env.f.get(x, y);
            const r = (p >> 16) & 0xff;
            const b = p & 0xff;
            if (r > 150 and b < 100) {
                found_color = true;
                break;
            }
        }
    }
    try testing.expect(found_color);

    // Regional-indicator flag pair on row 1. libghostty 1.0.1 segments
    // each regional indicator as its own WIDE cell (R1: segmentation and
    // width always come from the library); the two adjacent cells shape
    // as one run so HarfBuzz can ligate them into a flag.
    env.t.write("\r\n\xf0\x9f\x87\xaa\xf0\x9f\x87\xb8");
    var damage2: DamageList = .empty;
    defer damage2.deinit(a);
    try env.renderNoCursor(&damage2);
    const rc1 = env.cpu.row_cells[0]; // row view now holds row 1
    try testing.expectEqual(@as(u32, 1), rc1.n_cps);
    try testing.expectEqual(@as(u8, 2), rc1.width);
    try testing.expectEqual(@as(u21, 0x1F1EA), env.cpu.row_cps.items[rc1.cps_start]);
    try testing.expectEqual(@as(u21, 0x1F1F8), env.cpu.row_cps.items[env.cpu.row_cells[2].cps_start]);
    try testing.expect(env.cellHasInk(0, 1));
}

test "cpu: fallback face for codepoints missing from the primary (M3.2)" {
    const a = testing.allocator;
    var env = try Env.init(a, 80, 24);
    defer env.deinit(a);
    env.f.fill(env.palette[17]);
    var d0: DamageList = .empty;
    defer d0.deinit(a);
    try env.renderNoCursor(&d0); // consume the initial full-dirty frame

    // Find a codepoint the primary face lacks.
    const candidates = [_]u21{ 0x4E2D, 0x2603, 0x0301, 0x1F600 };
    var target: ?u21 = null;
    for (candidates) |cp| {
        if (env.cpu.face.glyphIndex(cp) == null) {
            target = cp;
            break;
        }
    }
    const cp = target orelse return error.SkipZigTest; // primary covers everything

    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    env.t.write("\x1b[?25h");
    env.t.write(buf[0..len]);
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);

    const rc = env.cpu.row_cells[0];
    const fallback = try env.d.fallbackFace(cp);
    if (fallback) |fb_face| {
        // The cell was assigned the fallback face's table slot.
        try testing.expect(rc.face_id != 0);
        try testing.expectEqual(fb_face.ft_face, env.cpu.faces.items[rc.face_id].face.ft_face);
        try testing.expect(env.cellHasInk(0, 0));
        // The sized handle is cached per codepoint.
        try testing.expect(env.cpu.fallback_faces.get(cp) != null);
    } else {
        // No installed font covers it: the primary face stays selected
        // and shaping draws .notdef (tofu).
        try testing.expectEqual(@as(u16, 0), rc.face_id);
    }
}

test "cpu: ligatures off by default, on with +liga (M3.3)" {
    const a = testing.allocator;
    // DejaVu Sans carries an 'fi' ligature under the liga feature (the
    // Mono sibling has none; the probe below skips if the match lacks it).
    var env_off = try Env.initWithFont(a, 80, 24, "DejaVu Sans", &.{});
    defer env_off.deinit(a);
    var env_on = try Env.initWithFont(a, 80, 24, "DejaVu Sans", &.{"+liga"});
    defer env_on.deinit(a);

    // Skip when the matched face has no fi ligature at all.
    const cells = [_]shaper.CellDesc{
        .{ .face_id = 0, .codepoint = 'f' },
        .{ .face_id = 0, .codepoint = 'i' },
    };
    const liga_on = [_]shaper.Feature{.{ .tag = shaper.tag("liga"), .value = 1 }};
    const probe = try env_on.cpu.shaper.shape(@ptrCast(env_on.cpu.face.ft_face), &cells, &liga_on);
    defer a.free(probe.glyphs);
    if (probe.glyphs.len != 1) return error.SkipZigTest;

    env_off.f.fill(env_off.palette[17]);
    env_on.f.fill(env_on.palette[17]);
    env_off.t.write("\x1b[?25hfi");
    env_on.t.write("\x1b[?25hfi");
    var d1: DamageList = .empty;
    defer d1.deinit(a);
    var d2: DamageList = .empty;
    defer d2.deinit(a);
    try env_off.renderNoCursor(&d1);
    try env_on.renderNoCursor(&d2);

    // Default: two glyphs (f + i). +liga: one ligature glyph mapped to the
    // first cell. Only "fi" was drawn, so the atlas count is the glyph
    // count. The ligature raster's width is the font's design (DejaVu Sans
    // is proportional: about one cell), so only cell 0 is guaranteed ink.
    try testing.expectEqual(@as(usize, 2), env_off.cpu.atlas.count());
    try testing.expectEqual(@as(usize, 1), env_on.cpu.atlas.count());
    try testing.expect(env_off.cellHasInk(0, 0));
    try testing.expect(env_off.cellHasInk(1, 0));
    try testing.expect(env_on.cellHasInk(0, 0));
}

test "cpu: invalid font-feature string fails init" {
    const a = testing.allocator;
    const d = try a.create(discovery.Discovery);
    defer a.destroy(d);
    d.* = try discovery.Discovery.init(a);
    defer d.deinit();
    var face = try d.primaryFace(null, 16);
    try testing.expectError(error.InvalidFeature, CpuRenderer.init(a, d, &face, .{
        .size_px = 16,
        .font_features = &.{"liga=abc"},
    }));
}

test "cpu: setFontSize re-initializes at the new pixel size (M3.8)" {
    const a = testing.allocator;
    var d = try discovery.Discovery.init(a);
    defer d.deinit();
    var face = try d.primaryFace(null, 16);
    var cpu = try CpuRenderer.init(a, &d, &face, .{ .size_px = 16 });
    defer cpu.deinit();
    try cpu.resize(20, 5, cpu.metrics.cell_w, cpu.metrics.cell_h);
    const m16 = cpu.metrics;
    try testing.expectEqual(@as(u16, 16), cpu.size_px);

    const m32 = try cpu.setFontSize(32);
    try testing.expectEqual(@as(u16, 32), cpu.size_px);
    try testing.expectEqual(m32.cell_w, cpu.metrics.cell_w);
    try testing.expectEqual(m32.cell_h, cpu.metrics.cell_h);
    // Grid preserved; reconfigure to the new cell size and render.
    try cpu.resize(20, 5, m32.cell_w, m32.cell_h);

    var t = try vt.Vt.init(20, 5);
    defer t.deinit();
    var state = try vt.RenderState.new();
    defer state.deinit();
    var f = try Framebuffer.create(a, 20 * @as(u32, m32.cell_w), 5 * @as(u32, m32.cell_h), .xrgb8888, null);
    defer f.destroy(a);
    t.write("zoom");
    try state.update(&t);
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    var palette: [18]u32 = undefined;
    for (&palette, presets.Preset.legacy.get()) |*dst, cc| dst.* = cc.xrgb();
    const opts: RenderOpts = .{
        .cursor_visible = true,
        .cursor_style = .block,
        .cursor_blink_on = null,
        .palette = &palette,
        .default_fg = palette[16],
        .default_bg = palette[17],
        .bg_opacity = 255,
    };
    try cpu.renderFrame(&state, &f, &damage, opts);
    try testing.expect(damage.items.len > 0);

    // Round-trip back to 16 reproduces the original metrics.
    const m16b = try cpu.setFontSize(16);
    try testing.expectEqual(@as(u16, 16), cpu.size_px);
    try testing.expectEqual(m16.cell_w, m16b.cell_w);
    try testing.expectEqual(m16.cell_h, m16b.cell_h);

    // No-op when the size is unchanged.
    const same = try cpu.setFontSize(16);
    try testing.expectEqual(m16b.cell_w, same.cell_w);
}

test "cpu: blitRotated matches layout.physicalToLogical for all rotations (M5.4)" {
    const a = testing.allocator;
    const lw: u32 = 6;
    const lh: u32 = 4;
    var src = try Framebuffer.create(a, lw, lh, .xrgb8888, null);
    defer src.destroy(a);
    for (0..lh) |y| {
        for (0..lw) |x| {
            const idx: u32 = @intCast(y * @as(usize, lw) + x);
            src.set(@intCast(x), @intCast(y), idx + 1);
        }
    }
    for (std.meta.tags(layout.Rotation)) |rot| {
        // effectiveDimensions swaps the axes at 90/270 and is its own
        // inverse, so it maps logical -> physical here as well.
        const phys = rot.effectiveDimensions(lw, lh);
        var dst = try Framebuffer.create(a, phys.w, phys.h, .xrgb8888, null);
        defer dst.destroy(a);
        blitRotated(dst, src, rot);
        for (0..phys.h) |py| {
            for (0..phys.w) |px| {
                const lp = rot.physicalToLogical(@intCast(px), @intCast(py), phys.w, phys.h);
                const want = src.get(@intCast(lp.x), @intCast(lp.y));
                try testing.expectEqual(want, dst.get(@intCast(px), @intCast(py)));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Kitty image tests (M4): real libghostty-vt storage + real compositor.
// ---------------------------------------------------------------------------

/// An Env whose terminal has pixel cell sizes (kitty placements need
/// them). The caller binds `env.cpu.vt = &env.t` AFTER the returned Env
/// lands in its final location (the pointer must not dangle across the
/// return-by-value move).
fn kittyEnv(a: std.mem.Allocator, cols: u16, rows: u16) !Env {
    var env = try Env.init(a, cols, rows);
    errdefer env.deinit(a);
    try env.t.resize(cols, rows, env.cpu.metrics.cell_w, env.cpu.metrics.cell_h);
    env.f.fill(env.palette[17]);
    return env;
}

/// Transmit + display raw RGBA pixels (kitty f=32) with the top-left at
/// zero-based cell (col, row), scaled over w_cells x h_cells cells, at
/// z-index z. Kitty places images at the CURSOR and c/r are the display
/// span in cells (not coordinates), so move the cursor first; C=1 keeps
/// it put afterwards, q=2 suppresses the reply.
fn sendKittyImage(
    a: std.mem.Allocator,
    env: *Env,
    id: u32,
    col: u16,
    row: u16,
    z: i32,
    w_cells: u16,
    h_cells: u16,
    w: u32,
    h: u32,
    pixels: []const u8,
) !void {
    var csi_buf: [24]u8 = undefined;
    const csi = try std.fmt.bufPrint(&csi_buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
    env.t.write(csi);
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(pixels.len));
    defer a.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, pixels);
    const apc = try std.fmt.allocPrint(
        a,
        "\x1b_Gf=32,s={d},v={d},i={d},a=T,c={d},r={d},z={d},C=1,q=2;{s}\x1b\\",
        .{ w, h, id, w_cells, h_cells, z, encoded },
    );
    defer a.free(apc);
    env.t.write(apc);
}

/// A solid-color image spanning w_cells x h_cells cells: scaling a
/// constant image reproduces the color exactly at every pixel.
fn sendKittySolid(
    a: std.mem.Allocator,
    env: *Env,
    id: u32,
    col: u16,
    row: u16,
    w_cells: u16,
    h_cells: u16,
    z: i32,
    rgba: [4]u8,
) !void {
    const w: u32 = @as(u32, w_cells) * env.cpu.metrics.cell_w;
    const h: u32 = @as(u32, h_cells) * env.cpu.metrics.cell_h;
    const px = try a.alloc(u8, @as(usize, w) * h * 4);
    defer a.free(px);
    for (0..@as(usize, w) * h) |i| @memcpy(px[i * 4 ..][0..4], &rgba);
    try sendKittyImage(a, env, id, col, row, z, w_cells, h_cells, w, h, px);
}

test "cpu: kitty image composites at cell geometry, caches, deletes (M4)" {
    const a = testing.allocator;
    var env = try kittyEnv(a, 20, 6);
    defer env.deinit(a);
    env.cpu.vt = &env.t;
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];

    // 2x2 RGBA: red/green over blue/yellow, displayed across 2x2 cells
    // at cell (2, 1), above_text (z=0).
    const pixels = [_]u8{
        255, 0,   0,   255, 0, 255, 0,   255,
        0,   0,   255, 255, 255, 255, 0,   255,
    };
    try sendKittyImage(a, &env, 1, 2, 1, 0, 2, 2, 2, 2, &pixels);

    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(@as(usize, 1), env.cpu.prev_placements.items.len);

    // Bilinear edge clamp: the dst corners sample the src corners
    // exactly, and opaque src-over copies the RGB verbatim.
    try testing.expectEqual(@as(u32, 0xFF0000), env.f.get(2 * cw, ch));
    try testing.expectEqual(@as(u32, 0xFFFF00), env.f.get(4 * cw - 1, 3 * ch - 1));
    // Outside the placement: untouched background.
    try testing.expectEqual(bg, env.f.get(0, 0));
    try testing.expectEqual(bg, env.f.get(4 * cw, 3 * ch));
    // The decoded original is cached (16 pixel bytes) and pinned.
    try testing.expect(env.cpu.image_cache.byteSize() >= 16);

    // A second frame with no changes draws nothing: clean state and an
    // unchanged placement list short-circuit before any pass.
    const snapshot = try a.dupe(u8, env.f.mem);
    defer a.free(snapshot);
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expectEqual(@as(usize, 0), damage.items.len);
    try testing.expectEqualSlices(u8, snapshot, env.f.mem);

    // Delete by id: the placement disappears and the previous frame's
    // rects force the rows back to the background.
    env.t.write("\x1b_Ga=d,d=i,i=1,q=2\x1b\\");
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(@as(usize, 0), env.cpu.prev_placements.items.len);
    try testing.expectEqual(bg, env.f.get(2 * cw, ch));
    try testing.expectEqual(bg, env.f.get(4 * cw - 1, 3 * ch - 1));
}

test "cpu: kitty layers interleave with backgrounds and text (M4)" {
    const a = testing.allocator;
    var env = try kittyEnv(a, 20, 6);
    defer env.deinit(a);
    env.cpu.vt = &env.t;
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    const fg = env.palette[16];
    const blue: u32 = 0x0000FF;
    const red: u32 = 0xFF0000;

    env.t.write("\x1b[?25hABCD");
    // below_text (z=-1) under 'AB', above_text (z=1) over 'CD',
    // below_background (z < INT32_MIN/2) under the empty cells 4..5.
    try sendKittySolid(a, &env, 1, 0, 0, 2, 1, -1, .{ 0, 0, 255, 255 });
    try sendKittySolid(a, &env, 2, 2, 0, 2, 1, 1, .{ 255, 0, 0, 255 });
    try sendKittySolid(a, &env, 3, 4, 0, 2, 1, -1073741825, .{ 0, 255, 0, 255 });

    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);

    // below_text: the image shows, and the glyph draws on top of it.
    try testing.expectEqual(blue, env.f.get(0, ch - 1));
    var has_glyph = false;
    for (0..ch) |y| {
        for (0..2 * cw) |x| {
            if (env.f.get(@intCast(x), @intCast(y)) == fg) has_glyph = true;
        }
    }
    try testing.expect(has_glyph);

    // above_text: the image covers the glyphs completely.
    for (0..ch) |y| {
        for (2 * cw..4 * cw) |x| {
            try testing.expectEqual(red, env.f.get(@intCast(x), @intCast(y)));
        }
    }

    // below_background: the opaque cell background wins.
    for (0..ch) |y| {
        for (4 * cw..6 * cw) |x| {
            try testing.expectEqual(bg, env.f.get(@intCast(x), @intCast(y)));
        }
    }
}

test "cpu: kitty pixel replacement repaints clean rows (M4.4 mechanism)" {
    const a = testing.allocator;
    var env = try kittyEnv(a, 20, 6);
    defer env.deinit(a);
    env.cpu.vt = &env.t;
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const red: u32 = 0xFF0000;
    const blue: u32 = 0x0000FF;

    try sendKittySolid(a, &env, 1, 1, 1, 2, 2, 0, .{ 255, 0, 0, 255 });
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);
    try testing.expectEqual(red, env.f.get(cw + cw / 2, ch + ch / 2));

    // Retransmit the same id with new pixels: the generation bumps but
    // no cell changes, so the render state stays clean. The placement
    // list comparison must still repaint the image's rows.
    try sendKittySolid(a, &env, 1, 1, 1, 2, 2, 0, .{ 0, 0, 255, 255 });
    try env.state.update(&env.t);
    try testing.expectEqual(vt.Dirty.clean, try env.state.dirty());
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(blue, env.f.get(cw + cw / 2, ch + ch / 2));
}

test "cpu: kitty animation tick advances frames through the cache (M4.4)" {
    const a = testing.allocator;
    var env = try kittyEnv(a, 20, 6);
    defer env.deinit(a);
    env.cpu.vt = &env.t;
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const red: u32 = 0xFF0000;
    const blue: u32 = 0x0000FF;
    const w: u32 = cw;
    const h: u32 = ch;

    // Root frame (red), then a second frame (blue) with a 40 ms gap,
    // then run the animation looping (kitty a=f / a=a).
    try sendKittySolid(a, &env, 1, 0, 0, 1, 1, 0, .{ 255, 0, 0, 255 });
    const px = try a.alloc(u8, @as(usize, w) * h * 4);
    defer a.free(px);
    for (0..@as(usize, w) * h) |i| @memcpy(px[i * 4 ..][0..4], &[_]u8{ 0, 0, 255, 255 });
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(px.len));
    defer a.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, px);
    const frame = try std.fmt.allocPrint(
        a,
        "\x1b_Ga=f,i=1,f=32,s={d},v={d},r=2,z=40,q=2;{s}\x1b\\",
        .{ w, h, encoded },
    );
    defer a.free(frame);
    env.t.write(frame);
    env.t.write("\x1b_Ga=a,i=1,r=1,z=40,q=2\x1b\\"); // root frame gap
    env.t.write("\x1b_Ga=a,i=1,s=3,q=2\x1b\\"); // run, loop

    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);
    try testing.expectEqual(red, env.f.get(cw / 2, ch / 2));

    var kg = try env.t.kittyGraphics();
    const gen1 = try kg.image(1).?.generation();
    const next = (try kg.animationTick(0)) orelse return error.TestUnexpectedResult;
    // The tick at the due time advances to frame 2 and bumps the
    // generation; the storage handle stays valid across the tick.
    _ = try kg.animationTick(next);
    const gen2 = try kg.image(1).?.generation();
    try testing.expect(gen2 != gen1);

    // No cell changed: the renderer must pick the new frame up through
    // the placement list's generation and repaint the clean row.
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expect(damage.items.len > 0);
    try testing.expectEqual(blue, env.f.get(cw / 2, ch / 2));
}

test "cpu: kitty placement clips at viewport edges (M4)" {
    const a = testing.allocator;
    var env = try kittyEnv(a, 20, 6);
    defer env.deinit(a);
    env.cpu.vt = &env.t;
    const cw = env.cpu.metrics.cell_w;
    const ch = env.cpu.metrics.cell_h;
    const bg = env.palette[17];
    const magenta: u32 = 0xFF00FF;
    const cyan: u32 = 0x00FFFF;

    // 4x4-cell image at the top-left, then scroll it up three rows: the
    // top three quarters leave the viewport (negative viewport_row).
    try sendKittySolid(a, &env, 1, 0, 0, 4, 4, 0, .{ 255, 0, 255, 255 });
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    try env.renderNoCursor(&damage);
    try testing.expectEqual(magenta, env.f.get(0, 0));
    try testing.expectEqual(magenta, env.f.get(0, 3 * ch));

    env.t.write("\x1b[1;1H"); // cursor home, independent of C=1
    env.t.write("\n\n\n\n\n\n\n\n"); // 8 newlines on 6 rows: scroll 3
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    // Only the image's bottom cell-row remains, at viewport row 0.
    try testing.expectEqual(magenta, env.f.get(0, 0));
    try testing.expectEqual(magenta, env.f.get(3 * cw, ch - 1));
    try testing.expectEqual(bg, env.f.get(0, ch));

    // Right-edge overflow: a 4-cell-wide image at column 18 shows 2
    // columns; the dst is clipped, the source crop mapped to match.
    try sendKittySolid(a, &env, 2, 18, 2, 4, 1, 0, .{ 0, 255, 255, 255 });
    damage.clearRetainingCapacity();
    try env.renderNoCursor(&damage);
    try testing.expectEqual(cyan, env.f.get(18 * cw, 2 * ch + ch / 2));
    try testing.expectEqual(cyan, env.f.get(20 * cw - 1, 2 * ch + ch / 2));
    var clipped_w: u32 = 0;
    for (env.cpu.prev_placements.items) |p| {
        if (p.key.id == 2) clipped_w = p.dst.w;
    }
    try testing.expectEqual(@as(u32, 2) * cw, clipped_w);
}
