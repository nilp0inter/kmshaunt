//! src/render/cpu.zig -- CPU renderer (ROADMAP M1.5, M3.3/M3.4/M3.5).
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
//! * `resize` must run before the first `renderFrame` (it establishes the
//!   grid). The framebuffer is cleared/presented by the caller; the
//!   renderer paints dirty rows only and appends one full-width damage
//!   rectangle per drawn row.
//! * The grid is anchored at the framebuffer's top-left corner; centering
//!   padding is the session/video-layout's job, not the renderer's.
//!
//! # Text pipeline (M3)
//!
//! Per dirty row, pass 1 paints backgrounds (and block cursors) exactly as
//! in M1. Pass 2 collects the row into `RowCell`s: the FULL grapheme
//! cluster from `GRAPHEMES_UTF8` is decoded into codepoints, colors are
//! resolved once, and each base codepoint is assigned a face-table slot
//! (style variant first, then the per-codepoint fontconfig fallback).
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

pub const Framebuffer = fb.Framebuffer;
pub const Damage = fb.Damage;
pub const DamageList = render.DamageList;
pub const RenderOpts = render.RenderOpts;

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
    /// Per-row scratch, sized to `cols` by resize.
    row_cells: []RowCell = &.{},
    descs: []shaper.CellDesc = &.{},
    runs_buf: []shaper.Run = &.{},
    /// Flat codepoint storage for the current row's clusters.
    row_cps: std.ArrayListUnmanaged(u21) = .empty,
    /// Scratch CellDesc buffer for shaping one complex cluster.
    cluster_descs: std.ArrayListUnmanaged(shaper.CellDesc) = .empty,

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
            .metrics = metrics,
            .atlas = try atlas.GlyphAtlas.init(allocator, opts.atlas_width, opts.atlas_height),
            .shaper = shaper.Shaper.init(allocator),
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
        self.features.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.fallback_faces.deinit(self.allocator);
        if (self.row_cells.len > 0) self.allocator.free(self.row_cells);
        if (self.descs.len > 0) self.allocator.free(self.descs);
        if (self.runs_buf.len > 0) self.allocator.free(self.runs_buf);
        self.row_cps.deinit(self.allocator);
        self.cluster_descs.deinit(self.allocator);
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
        if (cols != self.row_cells.len) {
            self.row_cells = try self.allocator.realloc(self.row_cells, cols);
            self.descs = try self.allocator.realloc(self.descs, cols);
            self.runs_buf = try self.allocator.realloc(self.runs_buf, cols);
        }
        self.cols = cols;
        self.rows = rows;
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
        const dirty = try state.dirty();
        if (dirty == .clean) return;

        self.atlas.beginFrame();
        const colors = try state.colors();
        const cursor = try self.cursorDraw(state, opts, colors);

        var rows = try state.rowsIter();
        while (try rows.nextDirty()) |row| {
            const vy = try row.viewportY();
            if (vy < 0 or vy >= self.rows) continue; // overscan row
            const y: u16 = @intCast(vy);
            try self.drawRow(&row, y, f, opts, cursor);
            const y0: u32 = @as(u32, y) * self.metrics.cell_h;
            if (y0 < f.height) {
                const y1 = @min(y0 + self.metrics.cell_h, f.height);
                try damage.append(self.allocator, Damage.fromRows(y0, y1, f.width));
            }
        }

        // The CPU reads the pages directly; drop the GL upload bookkeeping
        // so the dirty list stays bounded.
        self.atlas.clearDirty();
        try state.clean();
    }

    // ------------------------------------------------------------------
    // Row walk
    // ------------------------------------------------------------------

    /// Two passes over the row's cells: backgrounds first (a block cursor
    /// sits under the glyph), then text/decorations. The split lets a wide
    /// glyph overflow into its continuation cell without being overpainted
    /// by that cell's background.
    fn drawRow(
        self: *CpuRenderer,
        row: *const vt.Row,
        y: u16,
        f: *Framebuffer,
        opts: RenderOpts,
        cursor: CursorDraw,
    ) !void {
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        const y_px: i32 = @as(i32, y) * ch;

        // Pass 1: backgrounds + block cursors.
        {
            var cells = try row.cells();
            var x: u16 = 0;
            while (try cells.next()) |cell| {
                if (x >= self.cols) break;
                const x_px: i32 = @as(i32, x) * cw;
                const cc = resolveColors(&cell, opts);
                fillCell(f, x_px, y_px, cw, ch, cc.bg);
                if (cursor.active and cursor.style == .block and
                    x == cursor.x and y == cursor.y)
                {
                    deco.drawCursor(f.*, x_px, y_px, cw, ch, .block, cursor.color, true);
                }
                x += 1;
            }
        }

        // Pass 2: collect the row, draw shaped text, then decorations and
        // bar/underline cursors (per cell, text first, as in M1).
        const n = try self.collectRow(row, y, opts, cursor);
        try self.drawRowText(f, y_px, n);
        for (self.row_cells[0..n], 0..) |*rc, x| {
            const x_px: i32 = @as(i32, @intCast(x)) * cw;
            if (deco.shouldDraw(rc.style.flags.invisible))
                self.drawDecorations(f, x_px, y_px, rc.style, rc.fg, opts);
            if (rc.is_cursor and cursor.style != .block)
                deco.drawCursor(f.*, x_px, y_px, cw, ch, cursorStyle(cursor.style), cursor.color, true);
        }
    }

    /// Snapshot the row's cells into `row_cells`/`descs`, decoding every
    /// full grapheme cluster into `row_cps` (the render state's borrowed
    /// text dies on the next `cells.next`). Colors resolve once per cell;
    /// the block-cursor overlay applies to the glyph foreground.
    fn collectRow(
        self: *CpuRenderer,
        row: *const vt.Row,
        y: u16,
        opts: RenderOpts,
        cursor: CursorDraw,
    ) !usize {
        self.row_cps.clearRetainingCapacity();
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
            const invisible = !deco.shouldDraw(cell.style.flags.invisible);
            const is_sprite = n_cps > 0 and sprite.isSprite(base_cp);
            const bold = cell.style.flags.bold;
            const italic = cell.style.flags.italic;
            var face_id: u16 = 0;
            if (base_cp != 0 and !is_sprite and !invisible and width != 0)
                face_id = try self.faceForCell(base_cp, bold, italic);

            self.row_cells[x] = .{
                .style = cell.style,
                .fg = fg,
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
                if (rc.sprite) {
                    if (span_start) |s| {
                        try self.drawSpan(f, y_px, s, i, run.face_id);
                        span_start = null;
                    }
                    const cp = self.row_cps.items[rc.cps_start];
                    try self.drawSprite(f, @as(i32, @intCast(i)) * cw, y_px, cp, rc.fg);
                    continue;
                }
                const shapeable = rc.width != 0 and !rc.invisible and
                    rc.n_cps == 1 and self.row_cps.items[rc.cps_start] != 0;
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
        const max_w = @as(u32, rc.width) * self.metrics.cell_w;
        // RTL clusters arrive in visual order: the pen starts at the right
        // edge and each advance moves it left before the glyph is drawn.
        var pen: f32 = if (shaped.direction == .rtl) @floatFromInt(max_w) else 0;
        for (shaped.glyphs) |g| {
            if (shaped.direction == .rtl) pen -= g.x_advance;
            const gx = x_px + roundI32(pen);
            try self.drawGlyph(f, gx, y_px, rc.face_id, g, max_w, rc.fg);
            if (shaped.direction != .rtl) pen += g.x_advance;
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
    /// inside the row walk, so the caller must keep the cursor row dirty
    /// whenever the cursor moves or the blink phase flips (libghostty
    /// marks cursor rows dirty on movement; the session's blink tick
    /// forces an update).
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
        if (!blink_on) return .{};
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
                    for (src, 0..) |a, i| {
                        if (a == 0) continue;
                        const off = i * 4;
                        if (a == 255) {
                            std.mem.writeInt(u32, dst[off..][0..4], color_word, .little);
                            continue;
                        }
                        const d = std.mem.readInt(u32, dst[off..][0..4], .little);
                        std.mem.writeInt(u32, dst[off..][0..4], blendPixel(color_word, d, a), .little);
                    }
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

// ---------------------------------------------------------------------------
// Color resolution (pure)
// ---------------------------------------------------------------------------

const CellColors = struct { fg: u32, bg: u32 };

/// Effective cell colors: style color first (so the session's palette
/// wins over the library-resolved RGB), then the cell-level resolved
/// override, then the frame default. Inverse swaps the pair, opacity
/// blends the background toward the default background, faint blends the
/// foreground toward the painted background.
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
/// Indices 16..255 use the standard xterm 256-color cube and grayscale.
fn paletteColor(palette: *const [18]u32, idx: u8) u32 {
    if (idx < 16) return palette[idx];
    if (idx < 232) {
        const v: u32 = idx - 16;
        const r = cubeChannel(v / 36);
        const g = cubeChannel((v / 6) % 6);
        const b = cubeChannel(v % 6);
        return (r << 16) | (g << 8) | b;
    }
    const gray: u32 = 8 + @as(u32, idx - 232) * 10;
    return (gray << 16) | (gray << 8) | gray;
}

fn cubeChannel(c: u32) u32 {
    return if (c == 0) 0 else 55 + c * 40;
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

// ---------------------------------------------------------------------------
// Tests: real libghostty-vt terminal + real host fonts. Run via
// src/test_cpu.zig (command in that file's header).
// ---------------------------------------------------------------------------

const testing = std.testing;
const presets = @import("../misc/palette.zig");

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
    const rc1 = env.cpu.row_cells[0]; // row scratch now holds row 1
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
