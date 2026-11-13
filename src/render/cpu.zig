//! src/render/cpu.zig -- CPU renderer (ROADMAP M1.5).
//!
//! Draws the dirty rows of a `vt.RenderState` into a `Framebuffer` with a
//! single FreeType face, one codepoint per cell. Implements the
//! `render.Renderer` vtable so the session can swap in the M5 GL renderer
//! without changes.
//!
//! # Caller contract
//!
//! * The caller owns the `vt.RenderState` and calls `state.update(&vt)`
//!   before `renderFrame`; the renderer only reads the snapshot and calls
//!   `state.clean()` after the whole frame rendered successfully. On error
//!   nothing is cleaned, so the next frame redraws the same rows.
//! * `resize` must run before the first `renderFrame` (it establishes the
//!   grid). The framebuffer is cleared/presented by the caller; the
//!   renderer paints dirty rows only and appends one full-width damage
//!   rectangle per drawn row.
//! * The grid is anchored at the framebuffer's top-left corner; centering
//!   padding is the session/video-layout's job, not the renderer's.
//!
//! # M1 scope and M3 seams
//!
//! * One codepoint per cell: the first codepoint of `Cell.text`. Wide
//!   cells draw their base codepoint in the first cell; continuation
//!   cells (spacer tail/head) get background only. M3 shapes the full
//!   grapheme cluster and fits it into 1 or 2 cells.
//! * One face, gray rasters. The per-cell text draw is factored into
//!   `drawCellText` -- M3 replaces that helper with shaped runs (full
//!   clusters, fallback faces, color glyphs) without touching the row
//!   walk, color resolution or damage tracking. Atlas keys already carry
//!   `face_id` and the synthetic-style flags for the M3 face table.
//! * Sprites (box drawing, blocks, braille, ...) are rasterized by
//!   font/sprite.zig and cached in the atlas like font glyphs.
//!
//! Standalone tests: src/test_cpu.zig (exact command in that file's
//! header; needs the vt-c, fontconfig_c and freetype_c translate-c
//! modules plus libghostty-vt, libfontconfig and libfreetype).

const std = @import("std");
const fb = @import("../framebuffer.zig");
const render = @import("../render.zig");
const vt = @import("../vt.zig");
const discovery = @import("../font/discovery.zig");
const atlas = @import("../font/atlas.zig");
const sprite = @import("../font/sprite.zig");
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
};

pub const CpuRenderer = struct {
    allocator: std.mem.Allocator,
    /// M1: the single primary face, owned by the caller's Discovery.
    /// M3 replaces this with a face table (style variants + per-codepoint
    /// fallback); `face_id` in the atlas keys is that table's slot.
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

    pub fn init(allocator: std.mem.Allocator, face: *discovery.Face, opts: Options) !CpuRenderer {
        try face.setPixelSize(opts.size_px);
        const metrics = try discovery.cellMetrics(face.*);
        return .{
            .allocator = allocator,
            .face = face.*,
            .size_px = opts.size_px,
            .metrics = metrics,
            .atlas = try atlas.GlyphAtlas.init(allocator, opts.atlas_width, opts.atlas_height),
        };
    }

    pub fn deinit(self: *CpuRenderer) void {
        self.atlas.deinit();
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.sprite_cps.deinit(self.allocator);
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

        // Pass 2: glyphs, decorations, bar/underline cursors.
        {
            var cells = try row.cells();
            var x: u16 = 0;
            while (try cells.next()) |cell| {
                if (x >= self.cols) break;
                const x_px: i32 = @as(i32, x) * cw;
                const is_cursor = cursor.active and x == cursor.x and y == cursor.y;
                const cc = resolveColors(&cell, opts);
                var fg = cc.fg;
                if (is_cursor and cursor.style == .block)
                    fg = deco.cursorOverlayColor(cc.bg, cursor.color);

                if (deco.shouldDraw(cell.style.flags.invisible)) {
                    switch (cell.wide) {
                        // Continuation of a wide char: background only in
                        // M1; M3 shapes the whole cluster from the base.
                        .spacer_tail, .spacer_head => {},
                        .narrow, .wide => try self.drawCellText(f, x_px, y_px, &cell, fg),
                    }
                    self.drawDecorations(f, x_px, y_px, &cell, fg, opts);
                }
                if (is_cursor and cursor.style != .block) {
                    deco.drawCursor(f.*, x_px, y_px, cw, ch, cursorStyle(cursor.style), cursor.color, true);
                }
                x += 1;
            }
        }
    }

    // ------------------------------------------------------------------
    // Per-cell text draw -- the M3 seam
    // ------------------------------------------------------------------

    /// Draw one cell's text. M1: the first codepoint of the cluster, one
    /// face, gray raster, atlas-cached. M3 replaces this helper with
    /// shaped runs (full grapheme clusters, fallback faces, color glyphs);
    /// the row walk, color resolution and damage tracking stay unchanged.
    fn drawCellText(
        self: *CpuRenderer,
        f: *Framebuffer,
        x_px: i32,
        y_px: i32,
        cell: *const vt.Cell,
        fg: u32,
    ) !void {
        if (cell.text.len == 0) return;
        var it = std.unicode.Utf8Iterator{ .bytes = cell.text, .i = 0 };
        const cp = it.nextCodepoint() orelse return; // malformed UTF-8: skip
        if (cp == 0) return;

        if (sprite.isSprite(cp)) return self.drawSprite(f, x_px, y_px, cp, fg);

        // M1: no fallback chain (M3.2); a missing glyph draws nothing.
        const idx = self.face.glyphIndex(cp) orelse return;
        const key = atlas.GlyphKey{
            .face_id = 0,
            .glyph_index = idx,
            .size_px = self.size_px,
            .flags = self.faceFlags(),
        };
        const entry = self.atlas.get(key) orelse blk: {
            const bmp = self.face.loadGlyph(idx, false) catch |err| switch (err) {
                // Color bitmap without FT_LOAD_COLOR: M3.5 paints these.
                error.UnsupportedPixelMode => return,
                else => return err,
            };
            break :blk try self.cacheGlyph(key, bmp);
        };
        const dst_x = x_px + @as(i32, entry.bearing_x);
        const dst_y = y_px + @as(i32, self.metrics.baseline) - @as(i32, entry.bearing_y);
        self.blitEntry(f, dst_x, dst_y, entry, fg);
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

    fn faceFlags(self: *const CpuRenderer) u8 {
        var flags: u8 = 0;
        if (self.face.synthetic_bold) flags |= atlas.flag_synthetic_bold;
        if (self.face.synthetic_italic) flags |= atlas.flag_synthetic_italic;
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
        cell: *const vt.Cell,
        fg: u32,
        opts: RenderOpts,
    ) void {
        const flags = cell.style.flags;
        if (flags.underline == .none and !flags.strikethrough and !flags.overline) return;
        const cw = self.metrics.cell_w;
        const ch = self.metrics.cell_h;
        const baseline: i16 = @intCast(self.metrics.baseline);
        const fm = self.face.metrics();

        if (flags.underline != .none) {
            const color = resolveStyleColor(cell.style.underlineColor(), null, opts.palette, fg);
            const pos = deco.rowFromBaseline(baseline, clampI16(fm.underline_position));
            const thickness: u16 = @intCast(@max(1, fm.underline_thickness));
            deco.drawUnderline(f.*, x_px, y_px, cw, ch, underlineStyle(flags.underline), color, pos, thickness);
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
    /// straight-alpha BGRA pixels (M3.5 color glyphs).
    fn blitEntry(
        self: *const CpuRenderer,
        f: *Framebuffer,
        dst_x: i32,
        dst_y: i32,
        entry: atlas.AtlasEntry,
        color: u32,
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
                            std.mem.writeInt(u32, dst[off..][0..4], color, .little);
                            continue;
                        }
                        const d = std.mem.readInt(u32, dst[off..][0..4], .little);
                        std.mem.writeInt(u32, dst[off..][0..4], blendPixel(color, d, a), .little);
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
                        const out = blendChannel(src[off + 2], (d >> 16) & 0xff, a) << 16 |
                            blendChannel(src[off + 1], (d >> 8) & 0xff, a) << 8 |
                            blendChannel(src[off], d & 0xff, a);
                        std.mem.writeInt(u32, dst[off..][0..4], out, .little);
                    }
                }
            },
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
fn blendOpacity(color: u32, base: u32, opacity: u8) u32 {
    if (opacity == 255) return color;
    if (opacity == 0) return base;
    const a: u32 = opacity;
    const r = blendChannel((color >> 16) & 0xff, (base >> 16) & 0xff, @intCast(a));
    const g = blendChannel((color >> 8) & 0xff, (base >> 8) & 0xff, @intCast(a));
    const b = blendChannel(color & 0xff, base & 0xff, @intCast(a));
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

fn clampI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
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
fn fillCell(f: *Framebuffer, x: i32, y: i32, w: u16, h: u16, color: u32) void {
    const c = clipToFb(f, x, y, w, h) orelse return;
    var r: u32 = 0;
    while (r < c.h) : (r += 1) {
        const row = fbRow(f, c.x, c.y + r, c.w);
        var i: usize = 0;
        while (i < row.len) : (i += 4) {
            std.mem.writeInt(u32, row[i..][0..4], color, .little);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests: real libghostty-vt terminal + real host monospace face. Run via
// src/test_cpu.zig (command in that file's header).
// ---------------------------------------------------------------------------

const testing = std.testing;
const presets = @import("../misc/palette.zig");

/// One test seat: discovery + face + renderer + terminal + render state +
/// framebuffer, all real. The legacy preset supplies the palette.
const Env = struct {
    d: discovery.Discovery,
    cpu: CpuRenderer,
    t: vt.Vt,
    state: vt.RenderState,
    f: Framebuffer,
    palette: [18]u32,

    fn init(a: std.mem.Allocator, cols: u16, rows: u16) !Env {
        var d = try discovery.Discovery.init(a);
        errdefer d.deinit();
        var face = try d.primaryFace(null, 16);
        var cpu = try CpuRenderer.init(a, &face, .{ .size_px = 16 });
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
        try self.state.update(&self.t);
        try self.cpu.renderer().renderFrame(&self.state, &self.f, damage, self.opts());
    }

    fn cellHasInk(self: *const Env, col: u16, row: u16) bool {
        const cw = self.cpu.metrics.cell_w;
        const ch = self.cpu.metrics.cell_h;
        const bg = self.palette[17];
        var y: u32 = @as(u32, row) * ch;
        while (y < (@as(u32, row) + 1) * ch) : (y += 1) {
            var x: u32 = @as(u32, col) * cw;
            while (x < (@as(u32, col) + 1) * cw) : (x += 1) {
                if (self.f.get(x, y) != bg) return true;
            }
        }
        return false;
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
