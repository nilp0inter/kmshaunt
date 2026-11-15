//! src/render/decorations.zig -- text decorations and the software cursor,
//! ported from ghostty v1.4.0 (src/font/sprite/draw/special.zig) and its z2d
//! vector backend (vancluever/z2d @ 40af3e8, the pinned ghostty dependency).
//!
//! Geometry is expressed in *absolute framebuffer pixels* but every shape is
//! computed PER CELL, exactly like ghostty's sprite face: one underline sprite
//! per cell (width = cell width, doubled for wide cells), one curly wave cycle
//! peaking at the cell center, dots/dashes laid out from the cell's left edge.
//! Adjacent cells therefore repeat the pattern instead of continuing a global
//! phase -- that is ghostty's behavior.
//!
//! Like ghostty's sprite canvas, drawing may extend beyond the cell rectangle
//! by a quarter cell on every side (padding_x = cell_w/4, padding_y = cell_h/4,
//! see sprite/Face.zig). The position clamps in special.zig keep shapes inside
//! that extended canvas; everything is then clipped to the framebuffer.
//!
//! Positions (`underline_pos`, `strike_pos`, ...) are pixel offsets from the
//! *top of the cell*, matching ghostty's Metrics (underline_position is the
//! distance from the cell top to the TOP of the underline stroke). Font
//! metrics give positions relative to the glyph baseline with +Y up, so
//! `rowFromBaseline` converts them (FreeType reports `underline_position` as
//! a negative value below the baseline).
//!
//! Curly and dotted underlines are anti-aliased vector shapes. The rasterizer
//! below is a direct port of z2d's pipeline: cubic flattening (Cairo-style
//! spline decomposition, tolerance 0.1), stroke offsetting with round joins
//! and a circular pen, and the 4x multisample scanline coverage rasterizer
//! (coverage 0..16, alpha = coverage*16-1). Coverage is composited with the
//! ghostty linear-corrected source-over blend (alpha-blending=linear-corrected
//! is the Linux default), identical to render/cpu.zig's glyph blend.
//!
//! Out-of-range cells (negative origin, zero size, far past the right/bottom
//! edge) are no-ops instead of panics. Every pixel goes through
//! `Framebuffer.set`, so the row pitch (stride padding) is honored and the
//! padding bytes are never touched.
//!
//! Imports: framebuffer.zig only (the shared contract). `CursorStyle` mirrors
//! `render.CursorStyle` because this file must stay independent of the
//! renderer contract file.

const std = @import("std");
const fb = @import("../framebuffer.zig");

pub const Framebuffer = fb.Framebuffer;

const Allocator = std.mem.Allocator;

/// Underline styles as selected by SGR 4:0 .. 4:5.
/// `.none` is SGR 4:0 / SGR 24 (decoration off) and never draws.
pub const UnderlineStyle = enum {
    none,
    single,
    double,
    curly,
    dotted,
    dashed,
};

/// Cursor presentation styles. Mirrors `render.CursorStyle` (plus ghostty's
/// hollow block, which the renderer contract does not expose yet); kept local
/// so this file imports framebuffer.zig only.
pub const CursorStyle = enum {
    block,
    hollow,
    bar,
    underline,
};

/// A foreground/background pair, e.g. the result of `applyInverse`.
pub const Colors = struct {
    fg: u32,
    bg: u32,
};

// ---------------------------------------------------------------------------
// Cursor geometry constants (ghostty defaults)
// ---------------------------------------------------------------------------

/// ghostty Metrics.cursor_thickness default: 1px (font/Metrics.zig:34),
/// adjusted by adjust-cursor-thickness and clamped >= 1 (Minimums :65).
/// The console sets this from config (main.applyDecoConfig); the default
/// reproduces the unconfigured renderer.
pub var cursor_thickness: u16 = 1;

/// Cell-relative row of the underline-style cursor, i.e. ghostty's
/// metrics.underline_position. The fixed drawCursor signature cannot carry
/// font metrics, so the console sets this when adjust-underline-position
/// is configured (main.applyDecoConfig). Null falls back to the bottom
/// cell row (the unconfigured default).
pub var cursor_underline_pos: ?i16 = null;

/// ghostty metrics.cursor_height for block/hollow/bar cursors
/// (sprite/Face.zig:211-217): the cursor sprite height, re-centered in
/// the cell (Face.zig:242-250). Null = full cell height (the ghostty
/// default, Metrics.zig:320). Set per font/resize because the base value
/// is the cell height; the underline cursor keeps the full cell height.
pub var cursor_height: ?u16 = null;

/// ghostty metrics.underline_position with adjust-underline-position
/// applied (font/Metrics.zig:408-410), set by the console when the knob
/// is configured. Null = unadjusted: drawUnderline uses the row the
/// renderer computed from the face metrics. When set, it replaces that
/// row for every underline style, like ghostty's shared adjusted metric.
pub var adjusted_underline_pos: ?i16 = null;

// ---------------------------------------------------------------------------
// Attribute helpers (pure, no framebuffer)
// ---------------------------------------------------------------------------

/// Renderer policy for SGR 8 (invisible / concealed): an invisible cell is
/// skipped entirely -- no glyph, no decoration -- but its background is
/// still painted by the caller. `shouldDraw` is the one place that policy
/// is encoded.
pub fn shouldDraw(invisible: bool) bool {
    return !invisible;
}

/// SGR 2 (faint): ghostty applies faint-opacity (default 0.5) as a LINEAR-light
/// blend of the foreground toward the background (generic.zig sets the glyph
/// alpha to faint-opacity and the color is linearized before the source-over).
/// Blending in sRGB space ((c+b)/2) darkens light text too much; ghostty's
/// linear blend keeps it brighter. Both inputs are packed 0xRRGGBB.
pub fn applyFaint(color: u32, background: u32) u32 {
    const r = faintChannel((color >> 16) & 0xff, (background >> 16) & 0xff);
    const g = faintChannel((color >> 8) & 0xff, (background >> 8) & 0xff);
    const b = faintChannel(color & 0xff, background & 0xff);
    return (r << 16) | (g << 8) | b;
}

/// 50% linear-light blend of one channel (ghostty faint-opacity = 0.5).
fn faintChannel(c: u32, b: u32) u32 {
    const out = s2l[c] * 0.5 + s2l[b] * 0.5;
    return l2s[linIdx(out)];
}

/// SGR 7 (inverse): swap the foreground and background using the cell's
/// effective colors (after palette lookup / default-color resolution).
pub fn applyInverse(fg: u32, bg: u32) Colors {
    return .{ .fg = bg, .bg = fg };
}

/// Row of a color the renderer paints a glyph with when it sits on top of a
/// filled block cursor. Normally that is the cell's own background; when the
/// background and the cursor fill are nearly the same color the glyph would
/// vanish, so a black or white contrast color is picked from the cursor
/// fill's luminance instead. Pure; the renderer calls it once per cursor
/// cell before compositing the glyph.
pub fn cursorOverlayColor(cell_bg: u32, cursor_color: u32) u32 {
    if (colorDistance(cell_bg, cursor_color) >= 32) return cell_bg;
    return if (luma(cursor_color) >= 128) 0x000000 else 0xFFFFFF;
}

fn colorDistance(a: u32, b: u32) u32 {
    return @max(
        channelDistance(a, b, 16),
        @max(channelDistance(a, b, 8), channelDistance(a, b, 0)),
    );
}

fn channelDistance(a: u32, b: u32, shift: u5) u32 {
    const ca = (a >> shift) & 0xff;
    const cb = (b >> shift) & 0xff;
    return if (ca > cb) ca - cb else cb - ca;
}

fn luma(color: u32) u32 {
    const r = (color >> 16) & 0xff;
    const g = (color >> 8) & 0xff;
    const b = color & 0xff;
    return (r * 299 + g * 587 + b * 114) / 1000;
}

// ---------------------------------------------------------------------------
// Metric conversion
// ---------------------------------------------------------------------------

/// Convert a font metric expressed relative to the glyph baseline with +Y up
/// (FreeType's `underline_position` is negative below the baseline) into the
/// cell-relative row offset the drawing functions take (+Y down). This is
/// ghostty's `top_to_baseline - face_position` conversion.
pub fn rowFromBaseline(baseline: i16, pos: i16) i16 {
    return baseline -| pos;
}

/// Strikethrough row, ghostty's fallback when the face has no OS/2 strikeout
/// metrics: the stroke top sits (ex_height + thickness) / 2 above the
/// baseline, rounded (Metrics.calc + FaceMetrics.strikethroughPosition).
/// The caller draws a 1px stroke, so thickness = 1 is baked in. `x_height`
/// is the face's x-height in pixels; pass 0 when unknown.
pub fn strikeRow(baseline: i16, x_height: i16) i16 {
    return baseline -| @divTrunc(x_height +| 2, 2);
}

// ---------------------------------------------------------------------------
// Drawing: ghostty special.zig geometry
// ---------------------------------------------------------------------------

/// Draw an underline for one cell (ghostty special.zig underline*).
///
/// * `underline_pos` -- ghostty metrics.underline_position: cell-relative row
///   of the TOP of the single underline stroke (see `rowFromBaseline`).
/// * `thickness` -- ghostty metrics.underline_thickness: stroke height in
///   pixels (>= 1). For `double` it sizes both lines and their offset from
///   `underline_pos`; for `curly` it is the stroke line width; for `dotted`
///   the dot radius is sqrt(1/2) * thickness.
///
/// Shapes may extend up to a quarter cell past the cell edges (the ghostty
/// sprite canvas padding) and clip to the framebuffer.
pub fn drawUnderline(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    style: UnderlineStyle,
    color: u32,
    underline_pos: i16,
    thickness: u16,
) void {
    if (style == .none) return;
    if (cell_w == 0 or cell_h == 0) return;

    const w: u32 = cell_w;
    const h: u32 = cell_h;
    const pad_y: u32 = h / 4;
    const t: u32 = @max(@as(u32, thickness), 1);
    const pos: i32 = adjusted_underline_pos orelse @as(i32, underline_pos);

    switch (style) {
        .none => {},
        .single => {
            // special.zig underline: y = min(pos, height + padding_y -| thickness)
            const y = @min(pos, @as(i32, @intCast(h +| pad_y -| t)));
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y, w, t, color);
        },
        .double => {
            // special.zig underline_double: one line a thickness above the
            // underline position, one a thickness below ("negative" underline).
            const y = @min(pos, @as(i32, @intCast(h +| pad_y -| (2 *| t))));
            const ti: i32 = @intCast(t);
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y -| ti, w, t, color);
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y +| ti, w, t, color);
        },
        .dashed => {
            // special.zig underline_dashed: dash_width = width/3 + 1, every
            // other dash drawn, starting at the cell's left edge.
            const y = @min(pos, @as(i32, @intCast(h +| pad_y -| t)));
            const dash_width = w / 3 + 1;
            const dash_count = w / dash_width + 1;
            var i: u32 = 0;
            while (i < dash_count) : (i += 2) {
                solidRect(f, cell_x, cell_y, cell_w, cell_h, @intCast(i * dash_width), y, dash_width, t, color);
            }
        },
        .dotted => drawDotted(f, cell_x, cell_y, cell_w, cell_h, color, pos, t),
        .curly => drawCurly(f, cell_x, cell_y, cell_w, cell_h, color, pos, t),
    }
}

/// Draw a strikethrough (ghostty special.zig strikethrough: a solid rect at
/// metrics.strikethrough_position, metrics.strikethrough_thickness tall).
/// `strike_pos` is a cell-relative row; use `strikeRow(baseline, x_height)`
/// for the conventional position.
pub fn drawStrikethrough(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    color: u32,
    strike_pos: i16,
    thickness: u16,
) void {
    if (cell_w == 0 or cell_h == 0) return;
    solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, @as(i32, strike_pos), cell_w, @max(@as(u32, thickness), 1), color);
}

/// Draw an overline (SGR 53). ghostty special.zig overline: y =
/// max(overline_position, -padding_y); metrics.overline_position is 0, so the
/// stroke sits on the top cell rows, overline_thickness (= underline
/// thickness) tall.
pub fn drawOverline(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    color: u32,
    thickness: u16,
) void {
    if (cell_w == 0 or cell_h == 0) return;
    solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, 0, cell_w, @max(@as(u32, thickness), 1), color);
}

/// Draw the software cursor for one cell (ghostty special.zig cursor_*).
/// `blink_on == false` draws nothing (the off phase of the blink timer).
/// Shapes, all `cursor_thickness` (1px) unless noted:
/// * `block` -- cursor_height tall (default: the whole cell), centered
///   vertically; the renderer then paints the glyph with
///   `cursorOverlayColor`.
/// * `hollow` -- the cursor_height border ring, cursor_thickness wide
///   (cursor_hollow_rect).
/// * `bar` -- cursor_thickness wide, centered on the cell's LEFT edge:
///   x = -((thickness+1)/2), cursor_height tall (cursor_bar).
/// * `underline` -- full cell width, cursor_thickness tall, at
///   `cursor_underline_pos` (cursor_underline; falls back to the bottom row).
///
/// Shapes clip to the extended sprite canvas and the framebuffer.
pub fn drawCursor(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    style: CursorStyle,
    color: u32,
    blink_on: bool,
) void {
    if (!blink_on) return;
    if (cell_w == 0 or cell_h == 0) return;

    const w: u32 = cell_w;
    const h: u32 = cell_h;
    const ct: u32 = cursor_thickness;
    // ghostty sprite/Face.zig:211-217,242-250: block/hollow/bar use
    // metrics.cursor_height, re-centered in the cell; the underline
    // cursor keeps the full cell height. Null = full height (default).
    const ch_eff: u32 = cursor_height orelse h;
    const y_off: i32 = @divTrunc(@as(i32, @intCast(h)) - @as(i32, @intCast(ch_eff)), 2);

    switch (style) {
        .block => solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y_off, w, ch_eff, color),
        .hollow => {
            // cursor_hollow_rect fills the cell then clears the inside; the
            // net result is the border ring (drawn here directly).
            const cti: i32 = @intCast(ct);
            const chi: i32 = @intCast(ch_eff);
            const wi: i32 = @intCast(w);
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y_off, w, ct, color);
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y_off + chi -| cti, w, ct, color);
            const mid_h = ch_eff -| (2 *| ct);
            if (mid_h > 0) {
                solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y_off + cti, ct, mid_h, color);
                solidRect(f, cell_x, cell_y, cell_w, cell_h, wi -| cti, y_off + cti, ct, mid_h, color);
            }
        },
        .bar => {
            // cursor_bar: half the thickness over the left edge, rounded up.
            const x = -@as(i32, @intCast((ct + 1) / 2));
            solidRect(f, cell_x, cell_y, cell_w, cell_h, x, y_off, ct, ch_eff, color);
        },
        .underline => {
            // cursor_underline: at the underline position, cursor_thickness
            // tall. The clamp uses the underline thickness in ghostty; with
            // no metrics in the signature, cursor_thickness bounds it here.
            const pos: i32 = cursor_underline_pos orelse @as(i32, @intCast(h -| ct));
            const pad_y: u32 = h / 4;
            const y = @min(pos, @as(i32, @intCast(h +| pad_y -| ct)));
            solidRect(f, cell_x, cell_y, cell_w, cell_h, 0, y, w, ct, color);
        },
    }
}

/// Vertical pixel extent [y0, y1) of the cursor shape relative to the cell
/// top, clipped to the extended sprite canvas (quarter-cell padding) exactly
/// like drawCursor. The renderer sizes its redraw/damage row set from this:
/// a cursor taller than the cell (cursor_height > cell_h) re-centers into
/// neighboring rows, and those rows must repaint when the cursor moves.
pub fn cursorExtentY(cell_h: u16, style: CursorStyle) struct { y0: i32, y1: i32 } {
    if (cell_h == 0) return .{ .y0 = 0, .y1 = 0 };
    const h: i32 = cell_h;
    const ct: i32 = cursor_thickness;
    const pad_y: i32 = @divTrunc(h, 4);
    var y0: i32 = 0;
    var y1: i32 = 0;
    switch (style) {
        .block, .hollow, .bar => {
            const ch_eff: i32 = if (cursor_height) |ch| @as(i32, ch) else h;
            y0 = @divTrunc(h - ch_eff, 2);
            y1 = y0 + ch_eff;
        },
        .underline => {
            const pos: i32 = if (cursor_underline_pos) |p| @as(i32, p) else h -| ct;
            y0 = @min(pos, h + pad_y -| ct);
            y1 = y0 + ct;
        },
    }
    return .{ .y0 = @max(y0, -pad_y), .y1 = @min(y1, h + pad_y) };
}

// ---------------------------------------------------------------------------
// Solid rectangles (canvas.rect port)
// ---------------------------------------------------------------------------

/// One solid rectangle in cell-relative coordinates, clipped to the extended
/// sprite canvas (quarter-cell padding on every side, like ghostty's
/// Canvas.pixel -> Surface.putPixel) and to the framebuffer.
fn solidRect(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    color: u32,
) void {
    const pad_x: i64 = @intCast(cell_w / 4);
    const pad_y: i64 = @intCast(cell_h / 4);
    const x0 = @max(@as(i64, x), -pad_x);
    const y0 = @max(@as(i64, y), -pad_y);
    const x1 = @min(@as(i64, x) + @as(i64, w), @as(i64, cell_w) + pad_x);
    const y1 = @min(@as(i64, y) + @as(i64, h), @as(i64, cell_h) + pad_y);
    if (x1 <= x0 or y1 <= y0) return;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const fy = @as(i64, cell_y) + yy;
        if (fy < 0 or fy >= @as(i64, f.height)) continue;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const fx = @as(i64, cell_x) + xx;
            if (fx < 0 or fx >= @as(i64, f.width)) continue;
            f.set(@intCast(fx), @intCast(fy), color);
        }
    }
}

// ---------------------------------------------------------------------------
// Vector decorations (dotted / curly): z2d pipeline port
// ---------------------------------------------------------------------------

/// z2d options.default_tolerance.
const tolerance: f64 = 0.1;
/// z2d multisample_rasterizer.scale.
const msaa_scale: f64 = 4;

const Pt = struct {
    x: f64,
    y: f64,

    fn equal(self: Pt, other: Pt) bool {
        return self.x == other.x and self.y == other.y;
    }
};

const Node = union(enum) {
    move_to: Pt,
    line_to: Pt,
    curve_to: struct { p1: Pt, p2: Pt, p3: Pt },
    close_path,
};

/// z2d Path, restricted to the operations special.zig uses. Nodes are stored
/// in device space: the canvas CTM is a pure translation by (padding_x,
/// padding_y), applied at node-creation time exactly like z2d.
const Path = struct {
    alloc: Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    current: ?Pt = null,
    initial: ?Pt = null,
    pad_x: f64,
    pad_y: f64,

    fn init(alloc: Allocator, pad_x: f64, pad_y: f64) Path {
        return .{ .alloc = alloc, .pad_x = pad_x, .pad_y = pad_y };
    }

    fn deinit(self: *Path) void {
        self.nodes.deinit(self.alloc);
    }

    fn device(self: *const Path, x: f64, y: f64) Pt {
        // clampI24 + applyTransform (translation only).
        const cx = std.math.clamp(x, @as(f64, @floatFromInt(std.math.minInt(i24))), @as(f64, @floatFromInt(std.math.maxInt(i24))));
        const cy = std.math.clamp(y, @as(f64, @floatFromInt(std.math.minInt(i24))), @as(f64, @floatFromInt(std.math.maxInt(i24))));
        return .{ .x = cx + self.pad_x, .y = cy + self.pad_y };
    }

    fn moveTo(self: *Path, x: f64, y: f64) Allocator.Error!void {
        const p = self.device(x, y);
        // A move_to to the same point as the last move_to is a no-op.
        if (self.nodes.items.len > 0) {
            switch (self.nodes.items[self.nodes.items.len - 1]) {
                .move_to => |m| if (m.equal(p)) return,
                else => {},
            }
        }
        try self.nodes.append(self.alloc, .{ .move_to = p });
        self.initial = p;
        self.current = p;
    }

    fn lineTo(self: *Path, x: f64, y: f64) Allocator.Error!void {
        if (self.current == null) return self.moveTo(x, y);
        const p = self.device(x, y);
        try self.nodes.append(self.alloc, .{ .line_to = p });
        self.current = p;
    }

    fn curveTo(self: *Path, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) Allocator.Error!void {
        const p1 = self.device(x1, y1);
        const p2 = self.device(x2, y2);
        const p3 = self.device(x3, y3);
        try self.nodes.append(self.alloc, .{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
        self.current = p3;
    }

    fn closePath(self: *Path) Allocator.Error!void {
        if (self.current == null) return;
        try self.nodes.append(self.alloc, .close_path);
        try self.nodes.append(self.alloc, .{ .move_to = self.initial.? });
        self.current = self.initial;
    }

    fn arc(self: *Path, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) Allocator.Error!void {
        var eff2 = angle2;
        while (eff2 < angle1) eff2 += std.math.pi * 2;
        try arcInDirection(self, xc, yc, radius, angle1, eff2, tolerance);
    }
};

/// z2d internal/arc.zig (Cairo-derived). The CTM is a pure translation, so
/// the transformed circle major axis is the radius itself.
fn arcInDirection(path: *Path, xc: f64, yc: f64, radius: f64, amin: f64, amax: f64, tol: f64) Allocator.Error!void {
    if (amax - amin > std.math.pi) {
        const amid = amin + (amax - amin) / 2.0;
        try arcInDirection(path, xc, yc, radius, amin, amid, tol);
        try arcInDirection(path, xc, yc, radius, amid, amax, tol);
    } else if (amax != amin) {
        const max_angle = arcMaxAngleForTolerance(tol / radius);
        var segments: i32 = @intFromFloat(@ceil(@abs(amax - amin) / max_angle));
        const step = (amax - amin) / @as(f64, @floatFromInt(segments));
        segments -= 1;
        var a = amin;
        try path.lineTo(xc + radius * @cos(a), yc + radius * @sin(a));
        var i: i32 = 0;
        while (i < @max(0, segments)) : (i += 1) {
            try arcSegment(path, xc, yc, radius, a, a + step);
            a += step;
        }
        try arcSegment(path, xc, yc, radius, a, amax);
    } else {
        try path.lineTo(xc + radius * @cos(amin), yc + radius * @sin(amin));
    }
}

fn arcSegment(path: *Path, xc: f64, yc: f64, radius: f64, angle_a: f64, angle_b: f64) Allocator.Error!void {
    const r_sin_a = radius * @sin(angle_a);
    const r_cos_a = radius * @cos(angle_a);
    const r_sin_b = radius * @sin(angle_b);
    const r_cos_b = radius * @cos(angle_b);
    const h = 4.0 / 3.0 * @tan((angle_b - angle_a) / 4.0);
    try path.curveTo(
        xc + r_cos_a - h * r_sin_a,
        yc + r_sin_a + h * r_cos_a,
        xc + r_cos_b + h * r_sin_b,
        yc + r_sin_b - h * r_cos_b,
        xc + r_cos_b,
        yc + r_sin_b,
    );
}

fn arcErrorNormalized(angle: f64) f64 {
    return 2.0 / 27.0 * std.math.pow(f64, @sin(angle / 4), 6) / std.math.pow(f64, @cos(angle / 4), 2);
}

fn arcMaxAngleForTolerance(tol: f64) f64 {
    const table = [_]struct { angle: f64, err: f64 }{
        .{ .angle = std.math.pi / 1.0, .err = 0.0185185185185185036127 },
        .{ .angle = std.math.pi / 2.0, .err = 0.000272567143730179811158 },
        .{ .angle = std.math.pi / 3.0, .err = 2.38647043651461047433e-05 },
        .{ .angle = std.math.pi / 4.0, .err = 4.2455377443222443279e-06 },
        .{ .angle = std.math.pi / 5.0, .err = 1.11281001494389081528e-06 },
        .{ .angle = std.math.pi / 6.0, .err = 3.72662000942734705475e-07 },
        .{ .angle = std.math.pi / 7.0, .err = 1.47783685574284411325e-07 },
        .{ .angle = std.math.pi / 8.0, .err = 6.63240432022601149057e-08 },
        .{ .angle = std.math.pi / 9.0, .err = 3.2715520137536980553e-08 },
        .{ .angle = std.math.pi / 10.0, .err = 1.73863223499021216974e-08 },
        .{ .angle = std.math.pi / 11.0, .err = 9.81410988043554039085e-09 },
    };
    for (table) |entry| {
        if (entry.err < tol) return entry.angle;
    }
    var angle: f64 = undefined;
    for (table.len..1000) |i| {
        angle = std.math.pi / @as(f64, @floatFromInt(i));
        if (arcErrorNormalized(angle) <= tol) break;
    }
    return angle;
}

/// z2d internal/tess/Spline.zig (Cairo-derived): recursive De Casteljau
/// flattening of a cubic. Emits the line_to targets into `out` (the curve
/// start is not emitted; the end point is).
const Knots = struct {
    a: Pt,
    b: Pt,
    c: Pt,
    d: Pt,

    fn errorSq(self: Knots) f64 {
        var b_x_delta = self.b.x - self.a.x;
        var b_y_delta = self.b.y - self.a.y;
        var c_x_delta = self.c.x - self.a.x;
        var c_y_delta = self.c.y - self.a.y;

        if (self.a.x != self.d.x or self.a.y != self.d.y) {
            const d_x_delta = self.d.x - self.a.x;
            const d_y_delta = self.d.y - self.a.y;
            const d_dot_sq = d_x_delta * d_x_delta + d_y_delta * d_y_delta;

            const b_d_dot = b_x_delta * d_x_delta + b_y_delta * d_y_delta;
            if (b_d_dot >= d_dot_sq) {
                b_x_delta -= d_x_delta;
                b_y_delta -= d_y_delta;
            } else {
                b_x_delta -= b_d_dot / d_dot_sq * d_x_delta;
                b_y_delta -= b_d_dot / d_dot_sq * d_y_delta;
            }

            const c_d_dot = c_x_delta * d_x_delta + c_y_delta * d_y_delta;
            if (c_d_dot >= d_dot_sq) {
                c_x_delta -= d_x_delta;
                c_y_delta -= d_y_delta;
            } else {
                c_x_delta -= c_d_dot / d_dot_sq * d_x_delta;
                c_y_delta -= c_d_dot / d_dot_sq * d_y_delta;
            }
        }

        const b_err = b_x_delta * b_x_delta + b_y_delta * b_y_delta;
        const c_err = c_x_delta * c_x_delta + c_y_delta * c_y_delta;
        return @max(b_err, c_err);
    }

    fn deCasteljau(self: *Knots) Knots {
        const ab = lerpHalf(self.a, self.b);
        const bc = lerpHalf(self.b, self.c);
        const cd = lerpHalf(self.c, self.d);
        const abbc = lerpHalf(ab, bc);
        const bccd = lerpHalf(bc, cd);
        const final = lerpHalf(abbc, bccd);
        const result: Knots = .{ .a = final, .b = bccd, .c = cd, .d = self.d };
        self.b = ab;
        self.c = abbc;
        self.d = final;
        return result;
    }
};

fn lerpHalf(a: Pt, b: Pt) Pt {
    return .{ .x = a.x + ((b.x - a.x) / 2), .y = a.y + ((b.y - a.y) / 2) };
}

fn flattenCubic(alloc: Allocator, a: Pt, b: Pt, c: Pt, d: Pt, out: *std.ArrayListUnmanaged(Pt)) Allocator.Error!void {
    if (a.equal(b) and c.equal(d)) {
        try out.append(alloc, d);
        return;
    }
    var s1: Knots = .{ .a = a, .b = b, .c = c, .d = d };
    try decomposeInto(alloc, &s1, a, tolerance * tolerance, out);
    try out.append(alloc, d);
}

fn decomposeInto(alloc: Allocator, s1: *Knots, start: Pt, tol_sq: f64, out: *std.ArrayListUnmanaged(Pt)) Allocator.Error!void {
    if (s1.errorSq() < tol_sq) {
        if (!s1.a.equal(start)) try out.append(alloc, s1.a);
        return;
    }
    var s2 = s1.deCasteljau();
    try decomposeInto(alloc, s1, start, tol_sq, out);
    try decomposeInto(alloc, &s2, start, tol_sq, out);
}

/// z2d internal/tess/Polygon.zig Edge + Polygon.
const Edge = struct {
    y0: f64,
    y1: f64,
    x_start: f64,
    x_inc: f64,

    fn dir(self: *const Edge) i2 {
        return if (self.y0 < self.y1) -1 else 1;
    }

    fn top(self: *const Edge) f64 {
        return @min(self.y0, self.y1);
    }

    fn bottom(self: *const Edge) f64 {
        return @max(self.y0, self.y1);
    }
};

const Polygon = struct {
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    scale: f64 = 1,
    extent_top: f64 = 0,
    extent_bottom: f64 = 0,
    extent_left: f64 = 0,
    extent_right: f64 = 0,

    fn addEdge(self: *Polygon, alloc: Allocator, p0: Pt, p1: Pt) Allocator.Error!void {
        const p0s: Pt = .{ .x = p0.x * self.scale, .y = p0.y * self.scale };
        const p1s: Pt = .{ .x = p1.x * self.scale, .y = p1.y * self.scale };
        const edge: Edge = if (p0s.y < p1s.y) .{
            .y0 = p0s.y,
            .y1 = p1s.y,
            .x_start = p0s.x,
            .x_inc = (p1s.x - p0s.x) / (p1s.y - p0s.y),
        } else if (p0s.y > p1s.y) .{
            .y0 = p0s.y,
            .y1 = p1s.y,
            .x_start = p1s.x,
            .x_inc = (p0s.x - p1s.x) / (p0s.y - p1s.y),
        } else {
            return; // horizontal edges contribute nothing
        };

        const et = edge.top();
        const eb = edge.bottom();
        const el = @min(p0s.x, p1s.x);
        const er = @max(p0s.x, p1s.x);
        if (self.edges.items.len == 0) {
            self.extent_top = et;
            self.extent_bottom = eb;
            self.extent_left = el;
            self.extent_right = er;
        } else {
            self.extent_top = @min(self.extent_top, et);
            self.extent_bottom = @max(self.extent_bottom, eb);
            self.extent_left = @min(self.extent_left, el);
            self.extent_right = @max(self.extent_right, er);
        }
        try self.edges.append(alloc, edge);
    }

    fn addEdgesFromContour(self: *Polygon, alloc: Allocator, contour: *const Contour) Allocator.Error!void {
        const pts = contour.pts.items;
        if (pts.len == 0) return;
        for (1..pts.len) |i| try self.addEdge(alloc, pts[i - 1], pts[i]);
        try self.addEdge(alloc, pts[pts.len - 1], pts[0]);
    }

    fn inBox(self: *const Polygon, scale: f64, box_w: i32, box_h: i32) bool {
        if (self.extent_right <= 0 or self.extent_bottom <= 0) return false;
        const sx: i32 = @intFromFloat(@floor(self.extent_left / scale));
        const sy: i32 = @intFromFloat(@floor(self.extent_top / scale));
        const ex: i32 = @intFromFloat(@ceil(self.extent_right / scale));
        const ey: i32 = @intFromFloat(@ceil(self.extent_bottom / scale));
        const pw = ex - sx;
        const ph = ey - sy;
        if (pw <= 0 or ph <= 0) return false;
        if (sx + pw < 0 or sy + ph < 0) return false;
        if (sx >= box_w or sy >= box_h) return false;
        return true;
    }
};

/// z2d Polygon.WorkingEdgeSet: the active edge table for one sub-scanline.
const WorkingEdgeSet = struct {
    poly: *Polygon,
    edges: []Edge,
    x_values: []i32,
    x_full: []i32,

    fn init(alloc: Allocator, poly: *Polygon) Allocator.Error!WorkingEdgeSet {
        const xv = try alloc.alloc(i32, poly.edges.items.len);
        return .{
            .poly = poly,
            .edges = poly.edges.items[0..0],
            .x_values = xv[0..0],
            .x_full = xv,
        };
    }

    fn breakpoints(self: *const WorkingEdgeSet, alloc: Allocator) Allocator.Error![]i32 {
        var list: std.ArrayListUnmanaged(i32) = .empty;
        for (self.poly.edges.items) |e| {
            try list.append(alloc, @intFromFloat(@round(e.top())));
            try list.append(alloc, @intFromFloat(@round(e.bottom())));
        }
        std.sort.pdq(i32, list.items, {}, std.sort.asc(i32));
        // dedup in place
        var n: usize = 0;
        for (list.items) |v| {
            if (n == 0 or list.items[n - 1] != v) {
                list.items[n] = v;
                n += 1;
            }
        }
        return list.items[0..n];
    }

    fn rescan(self: *WorkingEdgeSet, line_y: i32) void {
        const mid = @as(f64, @floatFromInt(line_y)) + 0.5;
        const items = self.poly.edges.items;
        var to: usize = 0;
        for (0..items.len) |from| {
            if (items[from].top() < mid and items[from].bottom() >= mid) {
                if (from != to) std.mem.swap(Edge, &items[to], &items[from]);
                to += 1;
            }
        }
        self.edges = items[0..to];
        self.x_values = self.x_full[0..to];
    }

    fn inc(self: *WorkingEdgeSet, y: i32) void {
        const mid = @as(f64, @floatFromInt(y)) + 0.5;
        for (self.edges, 0..) |e, i| {
            self.x_values[i] = @intFromFloat(@round(e.x_start + e.x_inc * (mid - e.top())));
        }
    }

    fn sort(self: *WorkingEdgeSet) void {
        const Ctx = struct {
            s: *WorkingEdgeSet,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.s.x_values[a] < ctx.s.x_values[b];
            }
            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                std.mem.swap(Edge, &ctx.s.edges[a], &ctx.s.edges[b]);
                std.mem.swap(i32, &ctx.s.x_values[a], &ctx.s.x_values[b]);
            }
        };
        std.sort.pdqContext(0, self.x_values.len, Ctx{ .s = self });
    }

    fn filterNonZero(self: *WorkingEdgeSet) []i32 {
        var winding: i32 = 0;
        var to: usize = 0;
        for (0..self.x_values.len) |from| {
            self.x_values[to] = self.x_values[from];
            if (winding == 0) {
                winding += self.edges[from].dir();
                to += 1;
            } else {
                winding += self.edges[from].dir();
                if (winding == 0) to += 1;
            }
        }
        return self.x_values[0..to];
    }
};

/// Composites coverage onto the framebuffer: canvas pixel (x, y) lands at
/// (dst_x + x, dst_y + y); alpha 255 writes the color, partial coverage uses
/// the ghostty linear-corrected blend.
const Writer = struct {
    f: Framebuffer,
    color: u32,
    dst_x: i32,
    dst_y: i32,

    fn write(self: Writer, x: i32, y: i32, alpha: u8) void {
        const fx = @as(i64, self.dst_x) + @as(i64, x);
        const fy = @as(i64, self.dst_y) + @as(i64, y);
        if (fx < 0 or fy < 0 or fx >= @as(i64, self.f.width) or fy >= @as(i64, self.f.height)) return;
        const xx: u32 = @intCast(fx);
        const yy: u32 = @intCast(fy);
        if (alpha == 255) {
            self.f.set(xx, yy, self.color);
        } else {
            self.f.set(xx, yy, blendPixel(self.color, self.f.get(xx, yy), alpha));
        }
    }
};

/// z2d internal/raster/multisample.zig: 4 sub-scanlines per pixel row, edge
/// intersections rounded to the 4x grid, non-zero winding spans, coverage
/// 0..16 per pixel, alpha = coverage*16-1 (255 at full coverage).
fn rasterize(alloc: Allocator, poly: *Polygon, canvas_w: i32, canvas_h: i32, writer: Writer) Allocator.Error!void {
    const scale: i32 = 4;
    const coverage_full: i32 = 16;
    const alpha_scale: i32 = 16;

    if (!poly.inBox(msaa_scale, canvas_w, canvas_h)) return;

    const start_scanline = std.math.clamp(@as(i32, @intFromFloat(@floor(poly.extent_top / msaa_scale))), 0, canvas_h - 1);
    const end_scanline = std.math.clamp(@as(i32, @intFromFloat(@ceil(poly.extent_bottom / msaa_scale))), start_scanline, canvas_h - 1);
    const scanline_start_x = std.math.clamp(@as(i32, @intFromFloat(@floor(poly.extent_left / msaa_scale))), 0, canvas_w - 1);
    const scanline_end_x = std.math.clamp(@as(i32, @intFromFloat(@ceil(poly.extent_right / msaa_scale))), scanline_start_x, canvas_w);
    const draw_w = scanline_end_x - scanline_start_x;
    if (draw_w < 1) return;

    // All allocation happens before any pixel is written, so an OutOfMemory
    // retry (page allocator fallback) never double-composites.
    const coverage = try alloc.alloc(u8, @intCast(draw_w));
    var wes = try WorkingEdgeSet.init(alloc, poly);
    const bps = try wes.breakpoints(alloc);
    var bp_idx: usize = blk: {
        for (bps, 0..) |bp, i| {
            if (bp >= start_scanline) break :blk i -| 1;
        }
        return; // no breakpoint crosses the start scanline: nothing to draw
    };

    const start_x_scaled = scanline_start_x * scale;
    const draw_w_scaled = draw_w * scale;

    var y = start_scanline;
    while (y <= end_scanline) : (y += 1) {
        @memset(coverage, 0);
        const y_scaled = y * scale;
        for (0..4) |off| {
            const ys = y_scaled + @as(i32, @intCast(off));
            if (ys >= bps[bp_idx]) {
                wes.rescan(ys);
                if (bp_idx < bps.len - 1) bp_idx += 1;
            }
            wes.inc(ys);
            wes.sort();
            const filtered = wes.filterNonZero();

            var x_min: i32 = 0;
            var p: usize = 0;
            while (p + 1 < filtered.len) : (p += 2) {
                const sx = @max(x_min, filtered[p] - start_x_scaled);
                if (sx >= draw_w_scaled) break;
                const ex = std.math.clamp(filtered[p + 1] - start_x_scaled, sx, draw_w_scaled);
                const fill_len = ex - sx;
                if (fill_len > 0) addSpan(coverage, @intCast(@max(0, sx)), @intCast(@max(0, fill_len)));
                x_min = ex;
            }
        }

        for (coverage, 0..) |cov, xu| {
            if (cov == 0) continue;
            const x = @as(i32, @intCast(xu)) + scanline_start_x;
            const v: i32 = @intCast(cov);
            const alpha: u8 = if (v == coverage_full) 255 else @intCast(std.math.clamp(v * alpha_scale - 1, 0, 255));
            writer.write(x, y, alpha);
        }
    }
}

/// Per-pixel accumulation of one 4x-grid span (the run-length coverage
/// buffer in z2d has the same per-pixel effect).
fn addSpan(coverage: []u8, x: u32, len: u32) void {
    var sx = x;
    var rem = len;
    while (rem > 0) {
        const px = sx / 4;
        const off = sx % 4;
        const take = @min(rem, 4 - off);
        coverage[px] += @intCast(take);
        sx += take;
        rem -= take;
    }
}

/// z2d internal/tess/fill_plotter.zig: flatten the closed path set into an
/// edge polygon. PointBuffer(1, 3): keep the initial point + last two.
fn fillPlot(alloc: Allocator, nodes: []const Node, scale: f64) VectorError!Polygon {
    var result: Polygon = .{ .scale = scale };
    var points: [3]Pt = undefined;
    var plen: usize = 0;

    for (nodes, 0..) |node, i| {
        switch (node) {
            .move_to => |p| {
                if (i == nodes.len - 1) break; // trailing auto move_to
                plen = 0;
                points[0] = p;
                plen = 1;
            },
            .line_to => |p| {
                if (plen == 0) return error.InvalidState;
                if (!points[plen - 1].equal(p)) {
                    try result.addEdge(alloc, points[plen - 1], p);
                    bufAdd13(&points, &plen, p);
                }
            },
            .curve_to => |c| {
                if (plen == 0) return error.InvalidState;
                var flat: std.ArrayListUnmanaged(Pt) = .empty;
                defer flat.deinit(alloc);
                try flattenCubic(alloc, points[plen - 1], c.p1, c.p2, c.p3, &flat);
                for (flat.items) |p| {
                    if (!points[plen - 1].equal(p)) {
                        try result.addEdge(alloc, points[plen - 1], p);
                        bufAdd13(&points, &plen, p);
                    }
                }
            },
            .close_path => {
                if (plen >= 3 and !points[plen - 1].equal(points[0])) {
                    try result.addEdge(alloc, points[plen - 1], points[0]);
                    bufAdd13(&points, &plen, points[0]);
                }
            },
        }
    }
    return result;
}

fn bufAdd13(points: *[3]Pt, plen: *usize, p: Pt) void {
    if (plen.* < 3) {
        points[plen.*] = p;
        plen.* += 1;
    } else {
        points[1] = points[2];
        points[2] = p;
    }
}

const VectorError = Allocator.Error || error{InvalidState};

// ---------------------------------------------------------------------------
// Stroke pipeline (z2d stroke_plotter / Face / Pen / Slope / Contour)
// ---------------------------------------------------------------------------

const CapMode = enum { butt, round };
const JoinMode = enum { miter, round };

fn signF(x: f64) i32 {
    return if (x > 0) 1 else if (x < 0) -1 else 0;
}

/// z2d internal/tess/Slope.zig.
const Slope = struct {
    dx: f64,
    dy: f64,

    fn init(a: Pt, b: Pt) Slope {
        return .{ .dx = b.x - a.x, .dy = b.y - a.y };
    }

    fn normalize(self: *Slope) void {
        if (self.dx == 0) {
            self.dy = if (self.dy > 0) 1.0 else -1.0;
        } else if (self.dy == 0) {
            self.dx = if (self.dx > 0) 1.0 else -1.0;
        } else {
            const mag = std.math.hypot(self.dx, self.dy);
            self.dx /= mag;
            self.dy /= mag;
        }
    }

    fn compare(a: Slope, b: Slope) i32 {
        const bdy = if (@abs(b.dy - a.dy) > std.math.floatEps(f64)) b.dy else a.dy;
        const bdx = if (@abs(b.dx - a.dx) > std.math.floatEps(f64)) b.dx else a.dx;
        const cmp = signF(a.dy * bdx - bdy * a.dx);
        if (cmp != 0) return cmp;
        if (a.dx == 0 and a.dy == 0 and bdx == 0 and bdy == 0) return 0;
        if (a.dx == 0 and a.dy == 0) return 1;
        if (bdx == 0 and bdy == 0) return -1;
        if (signF(a.dx) != signF(bdx) or signF(a.dy) != signF(bdy)) {
            return if (a.dx > 0 or (a.dx == 0 and a.dy > 0)) -1 else 1;
        }
        return 0;
    }

    fn compareForMiterLimit(in_slope: Slope, out_slope: Slope, miter_limit: f64) bool {
        var a = in_slope;
        a.normalize();
        var b = out_slope;
        b.normalize();
        const dot = a.dx * b.dx + a.dy * b.dy;
        return 2 <= miter_limit * miter_limit * (1 + dot);
    }
};

/// z2d internal/tess/Face.zig. The canvas CTM is a pure translation, so the
/// device/user slope and offset transforms are identities (verified against
/// Face._init's transform branch: determinant 1, distance transforms exact).
const Face = struct {
    p0: Pt,
    p1: Pt,
    width: f64,
    dev_slope: Slope,
    half_width: f64,
    p0_cw: Pt,
    p0_ccw: Pt,
    p1_cw: Pt,
    p1_ccw: Pt,

    fn init(p0: Pt, p1: Pt, thickness: f64) Face {
        var s = Slope.init(p0, p1);
        s.normalize();
        const hw = thickness / 2;
        const ox = -s.dy * hw;
        const oy = s.dx * hw;
        return .{
            .p0 = p0,
            .p1 = p1,
            .width = thickness,
            .dev_slope = s,
            .half_width = hw,
            .p0_cw = .{ .x = p0.x + ox, .y = p0.y + oy },
            .p0_ccw = .{ .x = p0.x - ox, .y = p0.y - oy },
            .p1_cw = .{ .x = p1.x + ox, .y = p1.y + oy },
            .p1_ccw = .{ .x = p1.x - ox, .y = p1.y - oy },
        };
    }

    fn intersect(in: Face, out: Face, clockwise: bool) Pt {
        const in_point = if (clockwise) in.p1_ccw else in.p1_cw;
        const out_point = if (clockwise) out.p0_ccw else out.p0_cw;
        var in_slope = in.dev_slope;
        in_slope.normalize();
        var out_slope = out.dev_slope;
        out_slope.normalize();
        const result_y = ((out_point.x - in_point.x) * in_slope.dy * out_slope.dy - out_point.y * out_slope.dx * in_slope.dy + in_point.y * in_slope.dx * out_slope.dy) / (in_slope.dx * out_slope.dy - out_slope.dx * in_slope.dy);
        const result_x = if (@abs(in_slope.dy) >= @abs(out_slope.dy))
            (result_y - in_point.y) * in_slope.dx / in_slope.dy + in_point.x
        else
            (result_y - out_point.y) * out_slope.dx / out_slope.dy + out_point.x;
        return .{ .x = result_x, .y = result_y };
    }

    fn capP0(self: Face, alloc: Allocator, contour: *Contour, prepend: bool, mode: CapMode, clockwise: bool, pen: ?*const Pen) Allocator.Error!void {
        const reversed = Face.init(self.p1, self.p0, self.width);
        try reversed.cap(alloc, contour, prepend, mode, clockwise, pen);
    }

    fn capP1(self: Face, alloc: Allocator, contour: *Contour, prepend: bool, mode: CapMode, clockwise: bool, pen: ?*const Pen) Allocator.Error!void {
        try self.cap(alloc, contour, prepend, mode, clockwise, pen);
    }

    fn cap(self: Face, alloc: Allocator, contour: *Contour, prepend: bool, mode: CapMode, clockwise: bool, pen: ?*const Pen) Allocator.Error!void {
        switch (mode) {
            .butt => {
                if (clockwise) {
                    try contour.plot(alloc, self.p1_ccw, prepend);
                    try contour.plot(alloc, self.p1_cw, prepend);
                } else {
                    try contour.plot(alloc, self.p1_cw, prepend);
                    try contour.plot(alloc, self.p1_ccw, prepend);
                }
            },
            .round => {
                var vit = pen.?.vertexIteratorFor(
                    self.dev_slope,
                    .{ .dx = -self.dev_slope.dx, .dy = -self.dev_slope.dy },
                    clockwise,
                );
                if (clockwise) {
                    try contour.plot(alloc, self.p1_ccw, prepend);
                } else {
                    try contour.plot(alloc, self.p1_cw, prepend);
                }
                while (vit.next()) |v| {
                    try contour.plot(alloc, .{ .x = self.p1.x + v.point.x, .y = self.p1.y + v.point.y }, prepend);
                }
                if (clockwise) {
                    try contour.plot(alloc, self.p1_cw, prepend);
                } else {
                    try contour.plot(alloc, self.p1_ccw, prepend);
                }
            },
        }
    }
};

/// z2d internal/tess/Pen.zig: circular pen for round joins/caps.
const PenVertex = struct {
    point: Pt,
    slope_cw: Slope,
    slope_ccw: Slope,
};

const Pen = struct {
    vertices: []PenVertex,

    fn init(alloc: Allocator, thickness: f64, tol: f64) Allocator.Error!Pen {
        const radius = thickness / 2;
        // Translation CTM: major axis = radius.
        const num_vertices: i32 = verts: {
            if (tol >= radius * 4) break :verts 1;
            if (tol >= radius) break :verts 4;
            const delta = std.math.acos(1 - tol / radius);
            if (delta == 0) break :verts 4;
            const n: i32 = @intFromFloat(@ceil(2 * std.math.pi / delta));
            if (n < 4) break :verts 4;
            if (@rem(n, 2) != 0) break :verts n + 1;
            break :verts n;
        };
        const nv: usize = @intCast(@max(0, num_vertices));
        const vertices = try alloc.alloc(PenVertex, nv);
        for (0..nv) |i| {
            const theta = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_vertices));
            vertices[i] = .{
                .point = .{ .x = radius * @cos(theta), .y = radius * @sin(theta) },
                .slope_cw = undefined,
                .slope_ccw = undefined,
            };
        }
        for (0..nv) |i| {
            const next = if (i >= nv - 1) 0 else i + 1;
            const prev = if (i == 0) nv - 1 else i - 1;
            vertices[i].slope_cw = Slope.init(vertices[prev].point, vertices[i].point);
            vertices[i].slope_ccw = Slope.init(vertices[i].point, vertices[next].point);
        }
        return .{ .vertices = vertices };
    }

    fn vertexIteratorFor(self: *const Pen, from_slope: Slope, to_slope: Slope, clockwise: bool) VertexIterator {
        var start: i32 = 0;
        var end: i32 = 0;
        const len: i32 = @intCast(self.vertices.len);
        if (clockwise) {
            var low: i32 = 0;
            var high: i32 = len;
            var i: i32 = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                if (self.vertices[@intCast(i)].slope_cw.compare(from_slope) < 0)
                    low = i
                else
                    high = i;
            }
            if (self.vertices[@intCast(i)].slope_cw.compare(from_slope) < 0) {
                i += 1;
                if (i == len) i = 0;
            }
            start = i;
            if (to_slope.compare(self.vertices[@intCast(i)].slope_ccw) >= 0) {
                low = i;
                high = i + len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= len) i - len else i;
                    if (self.vertices[@intCast(j)].slope_cw.compare(to_slope) > 0)
                        high = i
                    else
                        low = i;
                }
                if (i >= len) i -= len;
            }
            end = i;
        } else {
            var low: i32 = 0;
            var high: i32 = len;
            var i: i32 = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                if (from_slope.compare(self.vertices[@intCast(i)].slope_ccw) < 0)
                    low = i
                else
                    high = i;
            }
            if (from_slope.compare(self.vertices[@intCast(i)].slope_ccw) < 0) {
                i += 1;
                if (i == len) i = 0;
            }
            start = i;
            if (self.vertices[@intCast(i)].slope_cw.compare(to_slope) <= 0) {
                low = i;
                high = i + len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= len) i - len else i;
                    if (to_slope.compare(self.vertices[@intCast(j)].slope_ccw) > 0)
                        high = i
                    else
                        low = i;
                }
                if (i >= len) i -= len;
            }
            end = i;
        }
        return .{ .pen = self, .end = @intCast(@max(0, end)), .idx = @intCast(@max(0, start)), .clockwise = clockwise };
    }
};

const VertexIterator = struct {
    pen: *const Pen,
    end: usize,
    idx: usize,
    clockwise: bool,

    fn next(self: *VertexIterator) ?PenVertex {
        if (self.idx == self.end) return null;
        const result = self.pen.vertices[self.idx];
        if (self.clockwise) {
            self.idx += 1;
            if (self.idx == self.pen.vertices.len) self.idx = 0;
        } else {
            if (self.idx == 0) self.idx = self.pen.vertices.len;
            self.idx -= 1;
        }
        return result;
    }
};

/// z2d Polygon.Contour: a polyline whose points are scaled at plot time.
/// `prepend` models plotReverse / insertBefore(first).
const Contour = struct {
    pts: std.ArrayListUnmanaged(Pt) = .empty,
    scale: f64,

    fn plot(self: *Contour, alloc: Allocator, p: Pt, prepend: bool) Allocator.Error!void {
        const s: Pt = .{ .x = p.x * self.scale, .y = p.y * self.scale };
        if (prepend) try self.pts.insert(alloc, 0, s) else try self.pts.append(alloc, s);
    }

    fn plotReverse(self: *Contour, alloc: Allocator, p: Pt) Allocator.Error!void {
        try self.plot(alloc, p, true);
    }

    fn concat(self: *Contour, alloc: Allocator, other: *Contour) Allocator.Error!void {
        try self.pts.appendSlice(alloc, other.pts.items);
        other.pts.clearRetainingCapacity();
    }

    fn reset(self: *Contour) void {
        self.pts.clearRetainingCapacity();
    }
};

/// z2d internal/tess/stroke_plotter.zig, restricted to open/closed paths of
/// lines and cubics (no dashes: special.zig never strokes dashed paths).
const StrokePlotter = struct {
    alloc: Allocator,
    nodes: []const Node,
    thickness: f64,
    cap_mode: CapMode,
    join_mode: JoinMode,
    miter_limit: f64 = 10.0,
    scale: f64,

    pen: ?Pen = null,
    points: [5]Pt = undefined,
    plen: usize = 0,
    clockwise_: ?bool = null,
    result: Polygon = .{ .scale = 1 },
    outer: Contour,
    inner: Contour,

    fn init(alloc: Allocator, nodes: []const Node, thickness: f64, cap_mode: CapMode, join_mode: JoinMode, scale: f64) StrokePlotter {
        return .{
            .alloc = alloc,
            .nodes = nodes,
            .thickness = thickness,
            .cap_mode = cap_mode,
            .join_mode = join_mode,
            .scale = scale,
            .outer = .{ .scale = scale },
            .inner = .{ .scale = scale },
        };
    }

    fn run(self: *StrokePlotter) VectorError!Polygon {
        if (self.join_mode == .round or self.cap_mode == .round) {
            self.pen = try Pen.init(self.alloc, self.thickness, tolerance);
        }
        for (self.nodes) |node| {
            switch (node) {
                .move_to => |p| {
                    if (self.plen > 0) try self.finish();
                    self.plen = 0;
                    self.points[0] = p;
                    self.plen = 1;
                },
                .line_to => |p| try self.runLineTo(self.join_mode, p),
                .curve_to => |c| {
                    if (self.pen == null) self.pen = try Pen.init(self.alloc, self.thickness, tolerance);
                    var flat: std.ArrayListUnmanaged(Pt) = .empty;
                    defer flat.deinit(self.alloc);
                    try flattenCubic(self.alloc, self.points[self.plen - 1], c.p1, c.p2, c.p3, &flat);
                    for (flat.items) |p| try self.runLineTo(.round, p);
                },
                .close_path => {
                    switch (self.plen) {
                        0 => {},
                        1 => try self.plotDotted(self.points[0]),
                        2 => try self.plotSingle(self.points[0], self.points[1]),
                        else => try self.plotClosedJoined(self.points[0], self.points[1], self.points[self.plen - 2], self.points[self.plen - 1]),
                    }
                    self.plen = 0;
                },
            }
        }
        try self.finish();
        return self.result;
    }

    fn bufAdd(self: *StrokePlotter, p: Pt) void {
        if (self.plen < 5) {
            self.points[self.plen] = p;
            self.plen += 1;
        } else {
            self.points[2] = self.points[3];
            self.points[3] = self.points[4];
            self.points[4] = p;
        }
    }

    fn runLineTo(self: *StrokePlotter, join_mode: JoinMode, p: Pt) VectorError!void {
        if (self.plen == 0) return error.InvalidState;
        if (p.equal(self.points[self.plen - 1])) return;
        self.bufAdd(p);
        if (self.plen > 2) {
            try self.join(join_mode, self.points[self.plen - 3], self.points[self.plen - 2], self.points[self.plen - 1]);
        }
    }

    fn finish(self: *StrokePlotter) Allocator.Error!void {
        switch (self.plen) {
            0, 1 => {},
            2 => try self.plotSingle(self.points[0], self.points[1]),
            else => try self.plotOpenJoined(self.points[0], self.points[1], self.points[self.plen - 2], self.points[self.plen - 1]),
        }
    }

    fn plotDotted(self: *StrokePlotter, point: Pt) Allocator.Error!void {
        if (self.cap_mode == .round) {
            for (self.pen.?.vertices) |v| {
                try self.outer.plot(self.alloc, .{ .x = point.x + v.point.x, .y = point.y + v.point.y }, false);
            }
            try self.result.addEdgesFromContour(self.alloc, &self.outer);
            self.outer.reset();
            self.clockwise_ = null;
        }
    }

    fn plotSingle(self: *StrokePlotter, start: Pt, end: Pt) Allocator.Error!void {
        const face = Face.init(start, end, self.thickness);
        try face.capP0(self.alloc, &self.outer, false, self.cap_mode, true, self.penPtr());
        try face.capP1(self.alloc, &self.outer, false, self.cap_mode, true, self.penPtr());
        try self.result.addEdgesFromContour(self.alloc, &self.outer);
        self.outer.reset();
        self.clockwise_ = null;
    }

    fn plotOpenJoined(self: *StrokePlotter, start0: Pt, end0: Pt, start1: Pt, end1: Pt) Allocator.Error!void {
        const cap_start = Face.init(start0, end0, self.thickness);
        const cap_end = Face.init(start1, end1, self.thickness);
        const clockwise = self.clockwise_ orelse true;
        // Start cap points are inserted before the existing outer points.
        try cap_start.capP0(self.alloc, &self.outer, true, self.cap_mode, clockwise, self.penPtr());
        try cap_end.capP1(self.alloc, &self.outer, false, self.cap_mode, clockwise, self.penPtr());
        try self.outer.concat(self.alloc, &self.inner);
        try self.result.addEdgesFromContour(self.alloc, &self.outer);
        self.outer.reset();
        self.inner.reset();
        self.clockwise_ = null;
    }

    fn plotClosedJoined(self: *StrokePlotter, initial0: Pt, initial1: Pt, p1: Pt, p2: Pt) Allocator.Error!void {
        if (!p2.equal(initial0)) {
            try self.join(self.join_mode, p1, p2, initial0);
            try self.join(self.join_mode, p2, initial0, initial1);
        } else {
            try self.join(self.join_mode, p1, initial0, initial1);
        }
        try self.result.addEdgesFromContour(self.alloc, &self.outer);
        try self.result.addEdgesFromContour(self.alloc, &self.inner);
        self.outer.reset();
        self.inner.reset();
        self.clockwise_ = null;
    }

    fn penPtr(self: *StrokePlotter) ?*const Pen {
        if (self.pen == null) return null;
        return &self.pen.?;
    }

    /// `to_inner` selects the joiner: the outer joiner plots to the inner
    /// contour when the join direction switches against the polygon winding.
    fn plotJoinPoint(self: *StrokePlotter, p: Pt, to_inner: bool) Allocator.Error!void {
        if (to_inner) try self.inner.plotReverse(self.alloc, p) else try self.outer.plot(self.alloc, p, false);
    }

    fn join(self: *StrokePlotter, join_mode: JoinMode, p0: Pt, p1: Pt, p2: Pt) Allocator.Error!void {
        if (p0.equal(p1) or p1.equal(p2)) {
            if (self.clockwise_ == null) self.clockwise_ = false;
            return;
        }
        const in = Face.init(p0, p1, self.thickness);
        const out = Face.init(p1, p2, self.thickness);
        const join_clockwise = in.dev_slope.compare(out.dev_slope) < 0;
        const poly_clockwise = self.clockwise_ orelse join_clockwise;
        const switched = join_clockwise != poly_clockwise;

        if (in.dev_slope.compare(out.dev_slope) == 0) {
            try self.plotJoinPoint(if (join_clockwise) in.p1_ccw else in.p1_cw, switched);
            try self.plotJoinPoint(if (join_clockwise) in.p1_cw else in.p1_ccw, !switched);
            if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
            return;
        }

        switch (join_mode) {
            .miter => {
                if (Slope.compareForMiterLimit(in.dev_slope, out.dev_slope, self.miter_limit)) {
                    try self.plotJoinPoint(in.intersect(out, join_clockwise), switched);
                } else {
                    try self.plotJoinPoint(if (join_clockwise) in.p1_ccw else in.p1_cw, switched);
                    try self.plotJoinPoint(if (join_clockwise) out.p0_ccw else out.p0_cw, switched);
                }
            },
            .round => {
                var vit = self.pen.?.vertexIteratorFor(in.dev_slope, out.dev_slope, join_clockwise);
                try self.plotJoinPoint(if (join_clockwise) in.p1_ccw else in.p1_cw, switched);
                while (vit.next()) |v| {
                    try self.plotJoinPoint(.{ .x = p1.x + v.point.x, .y = p1.y + v.point.y }, switched);
                }
                try self.plotJoinPoint(if (join_clockwise) out.p0_ccw else out.p0_cw, switched);
            },
        }

        try self.plotJoinPoint(if (join_clockwise) in.p1_cw else in.p1_ccw, !switched);
        try self.plotJoinPoint(p1, !switched);
        try self.plotJoinPoint(if (join_clockwise) out.p0_cw else out.p0_ccw, !switched);
        if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
    }
};

// ---------------------------------------------------------------------------
// Dotted / curly drivers
// ---------------------------------------------------------------------------

/// Stack arena for one vector decoration; falls back to the page allocator
/// for pathologically large cells. Nothing is drawn until all allocation
/// succeeded, so the fallback never double-composites.
fn drawDotted(f: Framebuffer, cell_x: i32, cell_y: i32, cell_w: u16, cell_h: u16, color: u32, pos: i32, t: u32) void {
    var buf: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();
    dottedImpl(arena.allocator(), f, cell_x, cell_y, cell_w, cell_h, color, pos, t) catch |err| {
        if (err != error.OutOfMemory) return;
        var big = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer big.deinit();
        dottedImpl(big.allocator(), f, cell_x, cell_y, cell_w, cell_h, color, pos, t) catch {};
    };
}

/// special.zig underline_dotted: circles of radius sqrt(1/2)*thickness,
/// centered on the stem, dot count bounded by the spacing rules.
fn dottedImpl(alloc: Allocator, f: Framebuffer, cell_x: i32, cell_y: i32, cell_w: u16, cell_h: u16, color: u32, pos: i32, t: u32) VectorError!void {
    const float_width: f64 = @floatFromInt(cell_w);
    const float_height: f64 = @floatFromInt(cell_h);
    const float_pos: f64 = @floatFromInt(pos);
    const float_thick: f64 = @floatFromInt(t);

    const radius = std.math.sqrt1_2 * float_thick;
    const padding: f64 = @floatFromInt(cell_h / 4);
    const y = @min(
        float_pos + 0.5 * float_thick,
        float_height + padding - @ceil(radius),
    );

    const dot_count: f64 = @max(
        @min(
            @min(@ceil(float_width / (4 * radius)), @floor(float_width / (3 * radius))),
            @floor(float_width / (2 * radius + 1)),
        ),
        1.0,
    );

    const pad_x: f64 = @floatFromInt(cell_w / 4);
    const pad_y: f64 = @floatFromInt(cell_h / 4);
    var path = Path.init(alloc, pad_x, pad_y);
    defer path.deinit();

    var x: f64 = (float_width / dot_count) / 2;
    const n: usize = @intFromFloat(dot_count);
    for (0..n) |_| {
        try path.arc(x, y, radius, 0.0, std.math.tau);
        try path.closePath();
        x += float_width / dot_count;
    }

    var poly = try fillPlot(alloc, path.nodes.items, msaa_scale);
    const canvas_w: i32 = @intCast(@as(u32, cell_w) + 2 * (cell_w / 4));
    const canvas_h: i32 = @intCast(@as(u32, cell_h) + 2 * (cell_h / 4));
    const writer: Writer = .{
        .f = f,
        .color = color,
        .dst_x = cell_x -| @as(i32, @intCast(cell_w / 4)),
        .dst_y = cell_y -| @as(i32, @intCast(cell_h / 4)),
    };
    try rasterize(alloc, &poly, canvas_w, canvas_h, writer);
}

fn drawCurly(f: Framebuffer, cell_x: i32, cell_y: i32, cell_w: u16, cell_h: u16, color: u32, pos: i32, t: u32) void {
    var buf: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();
    curlyImpl(arena.allocator(), f, cell_x, cell_y, cell_w, cell_h, color, pos, t) catch |err| {
        if (err != error.OutOfMemory) return;
        var big = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer big.deinit();
        curlyImpl(big.allocator(), f, cell_x, cell_y, cell_w, cell_h, color, pos, t) catch {};
    };
}

/// special.zig underline_curly: one wave cycle per cell, amplitude = width/pi,
/// cubic control points at 0.4 of the half-width, stroked at the underline
/// thickness with round caps (butt below 2px, z2d painter.stroke rule) and
/// round joins between the flattened curve segments.
fn curlyImpl(alloc: Allocator, f: Framebuffer, cell_x: i32, cell_y: i32, cell_w: u16, cell_h: u16, color: u32, pos: i32, t: u32) VectorError!void {
    const float_width: f64 = @floatFromInt(cell_w);
    const float_height: f64 = @floatFromInt(cell_h);
    const float_pos: f64 = @floatFromInt(pos);
    const line_width: f64 = @floatFromInt(t);

    const amplitude = float_width / std.math.pi;
    const padding: f64 = @floatFromInt(cell_h / 4);
    const top = @min(
        float_pos,
        float_height + padding - amplitude - line_width,
    );
    const bottom = top + amplitude;
    const r = 0.4;
    const center = 0.5 * float_width;

    const pad_x: f64 = @floatFromInt(cell_w / 4);
    const pad_y: f64 = @floatFromInt(cell_h / 4);
    var path = Path.init(alloc, pad_x, pad_y);
    defer path.deinit();

    try path.moveTo(0, bottom);
    try path.curveTo(center * r, bottom, center - center * r, top, center, top);
    try path.curveTo(center + center * r, top, float_width - center * r, bottom, float_width, bottom);

    // painter.stroke: caps/joins forced to butt/miter below 2px width;
    // curve-segment joins are always round (CurveToCtx). Minimum width 1/256.
    const cap_mode: CapMode = if (line_width >= 2) .round else .butt;
    const join_mode: JoinMode = if (line_width >= 2) .round else .miter;
    const thickness = @max(line_width, 0.00390625);
    var plotter = StrokePlotter.init(alloc, path.nodes.items, thickness, cap_mode, join_mode, msaa_scale);
    var poly = try plotter.run();

    const canvas_w: i32 = @intCast(@as(u32, cell_w) + 2 * (cell_w / 4));
    const canvas_h: i32 = @intCast(@as(u32, cell_h) + 2 * (cell_h / 4));
    const writer: Writer = .{
        .f = f,
        .color = color,
        .dst_x = cell_x -| @as(i32, @intCast(cell_w / 4)),
        .dst_y = cell_y -| @as(i32, @intCast(cell_h / 4)),
    };
    try rasterize(alloc, &poly, canvas_w, canvas_h, writer);
}

// ---------------------------------------------------------------------------
// ghostty linear-corrected blend (identical to render/cpu.zig blendPixel)
// ---------------------------------------------------------------------------

const s2l: [256]f32 = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const x = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};
const l2s: [1024]u8 = blk: {
    @setEvalBranchQuota(100000);
    var t: [1024]u8 = undefined;
    for (&t, 0..) |*v, i| {
        const x = @as(f32, @floatFromInt(i)) / 1023.0;
        const vf = if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
        v.* = @intFromFloat(@max(0.0, @min(255.0, @round(vf * 255.0))));
    }
    break :blk t;
};
fn linF(x: f32) f32 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}
fn unlinF(x: f32) f32 {
    return if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}
fn linIdx(l: f32) usize {
    return @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(l * 1023.0))), 0, 1023));
}

/// ghostty linear-corrected source-over: derive a corrected coverage so the
/// linear blend reproduces the sRGB-blend luminance, then blend in linear.
/// Matches ghostty alpha-blending=linear-corrected (Linux default).
fn blendPixel(fg: u32, bg: u32, a: u8) u32 {
    if (a == 0) return bg;
    if (a == 255) return fg;
    const fr = s2l[(fg >> 16) & 0xff];
    const fg2 = s2l[(fg >> 8) & 0xff];
    const fbl = s2l[fg & 0xff];
    const br = s2l[(bg >> 16) & 0xff];
    const bg2 = s2l[(bg >> 8) & 0xff];
    const bb = s2l[bg & 0xff];
    const fg_l = 0.2126 * fr + 0.7152 * fg2 + 0.0722 * fbl;
    const bg_l = 0.2126 * br + 0.7152 * bg2 + 0.0722 * bb;
    var af = @as(f32, @floatFromInt(a)) / 255.0;
    if (@abs(fg_l - bg_l) > 0.001) {
        const blend_l = linF(unlinF(fg_l) * af + unlinF(bg_l) * (1.0 - af));
        af = std.math.clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
    }
    const r = l2s[linIdx(fr * af + br * (1.0 - af))];
    const g = l2s[linIdx(fg2 * af + bg2 * (1.0 - af))];
    const b = l2s[linIdx(fbl * af + bb * (1.0 - af))];
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn countColor(f: Framebuffer, color: u32) usize {
    var n: usize = 0;
    var y: u32 = 0;
    while (y < f.height) : (y += 1) {
        var x: u32 = 0;
        while (x < f.width) : (x += 1) {
            if (f.get(x, y) == color) n += 1;
        }
    }
    return n;
}

fn countInk(f: Framebuffer) usize {
    var n: usize = 0;
    var y: u32 = 0;
    while (y < f.height) : (y += 1) {
        var x: u32 = 0;
        while (x < f.width) : (x += 1) {
            if (f.get(x, y) != 0) n += 1;
        }
    }
    return n;
}

fn expectRows(f: Framebuffer, x_start: u32, x_end: u32, row: u32, color: u32) !void {
    var x = x_start;
    while (x < x_end) : (x += 1) {
        try testing.expectEqual(color, f.get(x, row));
    }
}

test "rowFromBaseline converts FreeType's +Y-up offset to a cell row" {
    // Baseline 13, FreeType underline_position -2 (2px BELOW the baseline)
    // -> row 15 from the cell top (ghostty top_to_baseline - position).
    try testing.expectEqual(@as(i16, 15), rowFromBaseline(13, -2));
    try testing.expectEqual(@as(i16, 11), rowFromBaseline(13, 2));
}

test "underline single: rows at the underline position, thickness tall" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 32, 20, .xrgb8888, null);
    defer f.destroy(a);

    // 10x16 cell at (4,2), underline top at cell row 11 -> absolute row 13.
    drawUnderline(f, 4, 2, 10, 16, .single, 0x00FF00, 11, 2);
    try expectRows(f, 4, 14, 13, 0x00FF00);
    try expectRows(f, 4, 14, 14, 0x00FF00);
    try expectRows(f, 4, 14, 12, 0);
    try expectRows(f, 4, 14, 15, 0);
    // Clipped to the cell horizontally.
    try testing.expectEqual(@as(u32, 0), f.get(3, 13));
    try testing.expectEqual(@as(u32, 0), f.get(14, 13));

    // Thickness 0 is treated as a 1-px stroke.
    f.fill(0);
    drawUnderline(f, 4, 2, 10, 16, .single, 0x123456, 11, 0);
    try expectRows(f, 4, 14, 13, 0x123456);
    try expectRows(f, 4, 14, 14, 0);
}

test "underline none draws nothing" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 16, .xrgb8888, null);
    defer f.destroy(a);
    drawUnderline(f, 2, 2, 8, 8, .none, 0xFF0000, 6, 3);
    try testing.expectEqual(@as(usize, 0), countColor(f, 0xFF0000));
}

test "underline double: one thickness above and below the position" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 24, .xrgb8888, null);
    defer f.destroy(a);

    // ghostty underline_double, thickness 1: rows pos-1 and pos+1.
    drawUnderline(f, 0, 0, 8, 16, .double, 0x123456, 10, 1);
    try expectRows(f, 0, 8, 9, 0x123456);
    try expectRows(f, 0, 8, 11, 0x123456);
    try expectRows(f, 0, 8, 10, 0);
    try testing.expectEqual(@as(usize, 16), countColor(f, 0x123456));

    // Thickness 2: rows pos-2..pos-1 and pos+2..pos+3.
    drawUnderline(f, 8, 0, 8, 16, .double, 0xABCDEF, 10, 2);
    try expectRows(f, 8, 16, 8, 0xABCDEF);
    try expectRows(f, 8, 16, 9, 0xABCDEF);
    try expectRows(f, 8, 16, 12, 0xABCDEF);
    try expectRows(f, 8, 16, 13, 0xABCDEF);
    try expectRows(f, 8, 16, 10, 0);
    try expectRows(f, 8, 16, 11, 0);
}

test "underline dashed: width/3+1 dashes from the cell edge, per cell" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 24, 16, .xrgb8888, null);
    defer f.destroy(a);

    // width 10: dash_width = 4, dash_count = 3 -> dashes at x=0 and x=8.
    drawUnderline(f, 0, 0, 10, 16, .dashed, 0x00FF00, 13, 1);
    try expectRows(f, 0, 4, 13, 0x00FF00);
    try expectRows(f, 4, 8, 13, 0);
    try expectRows(f, 8, 10, 13, 0x00FF00);

    // The pattern restarts in the next cell (ghostty draws one sprite/cell).
    drawUnderline(f, 10, 0, 10, 16, .dashed, 0x00FF00, 13, 1);
    try expectRows(f, 10, 14, 13, 0x00FF00);
    try expectRows(f, 14, 18, 13, 0);
    try expectRows(f, 18, 20, 13, 0x00FF00);
}

test "underline dotted: anti-aliased dots centered per cell" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 20, 16, .xrgb8888, null);
    defer f.destroy(a);

    // width 10, thickness 1: radius sqrt(1/2), 4 dots at x = 1.25 + 2.5*i,
    // centered on row 13.5. Ink must cover the dot centers.
    drawUnderline(f, 0, 0, 10, 16, .dotted, 0x00FF00, 13, 1);
    try testing.expect(f.get(1, 13) != 0);
    try testing.expect(f.get(3, 13) != 0);
    try testing.expect(f.get(6, 13) != 0);
    try testing.expect(f.get(8, 13) != 0);
    try testing.expect(countInk(f) > 0);
    // Between the dots (x=2.5 boundary) the row stays mostly empty.
    try testing.expectEqual(@as(u32, 0), f.get(2, 12));

    // Same pattern in the next cell (per-cell sprite geometry).
    drawUnderline(f, 10, 0, 10, 16, .dotted, 0x00FF00, 13, 1);
    var y: u32 = 0;
    while (y < 16) : (y += 1) {
        var x: u32 = 0;
        while (x < 10) : (x += 1) {
            try testing.expectEqual(f.get(x, y), f.get(10 + x, y));
        }
    }
}

test "underline curly: one wave cycle per cell, peak at the center" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 20, .xrgb8888, null);
    defer f.destroy(a);

    // width 8, thickness 1: amplitude 8/pi ~ 2.55, top row 13, bottom ~15.55.
    drawUnderline(f, 0, 0, 8, 20, .curly, 0x00FF00, 13, 1);
    try testing.expect(f.get(4, 13) != 0); // peak at the cell center
    try testing.expect(f.get(0, 15) != 0); // start at the bottom
    try testing.expect(f.get(7, 15) != 0); // end at the bottom
    try testing.expect(countInk(f) > 0);

    // Per-cell repetition: the next cell draws the identical wave. Compare
    // interior columns only: round-join pens may bleed a fraction of a pixel
    // past the cell edge, where the neighbouring sprite overlaps (ghostty
    // behaves the same way).
    drawUnderline(f, 8, 0, 8, 20, .curly, 0x00FF00, 13, 1);
    var y: u32 = 0;
    while (y < 20) : (y += 1) {
        var x: u32 = 2;
        while (x < 6) : (x += 1) {
            try testing.expectEqual(f.get(x, y), f.get(8 + x, y));
        }
    }
}

test "vector underlines are deterministic and blend over existing pixels" {
    const a = testing.allocator;
    var f1 = try Framebuffer.create(a, 12, 16, .xrgb8888, null);
    defer f1.destroy(a);
    var f2 = try Framebuffer.create(a, 12, 16, .xrgb8888, null);
    defer f2.destroy(a);

    f1.fill(0x202020);
    f2.fill(0x202020);
    drawUnderline(f1, 0, 0, 12, 16, .curly, 0xFF8000, 12, 2);
    drawUnderline(f2, 0, 0, 12, 16, .curly, 0xFF8000, 12, 2);
    try testing.expectEqualSlices(u8, f1.mem, f2.mem);

    // Partial coverage must blend, not overwrite: some pixel differs from
    // both the background and the pure stroke color.
    var blended = false;
    var y: u32 = 0;
    while (y < 16) : (y += 1) {
        var x: u32 = 0;
        while (x < 12) : (x += 1) {
            const p = f1.get(x, y);
            if (p != 0x202020 and p != 0xFF8000) blended = true;
        }
    }
    try testing.expect(blended);
}

test "strikethrough and overline rows" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 20, .xrgb8888, null);
    defer f.destroy(a);

    // ghostty fallback: (x_height + 1) / 2 above the baseline, rounded.
    // x-height 8, baseline 13 -> row 13 - 5 = 8 (absolute 10 with cell_y 2).
    try testing.expectEqual(@as(i16, 8), strikeRow(13, 8));
    drawStrikethrough(f, 2, 2, 8, 16, 0x0000FF, strikeRow(13, 8), 1);
    try expectRows(f, 2, 10, 10, 0x0000FF);
    try expectRows(f, 2, 10, 9, 0);
    try expectRows(f, 2, 10, 11, 0);

    // Overline sits on the first cell rows.
    drawOverline(f, 2, 2, 8, 16, 0xFF00FF, 2);
    try expectRows(f, 2, 10, 2, 0xFF00FF);
    try expectRows(f, 2, 10, 3, 0xFF00FF);
    try expectRows(f, 2, 10, 4, 0);
}

test "applyFaint: 50% linear-light blend toward the background (ghostty)" {
    // Linear-light half-blend, not sRGB (c+b)/2: white over black is 0xBC, not 0x80.
    try testing.expectEqual(@as(u32, 0xBCBCBC), applyFaint(0xFFFFFF, 0x000000));
    try testing.expectEqual(@as(u32, 0xBCBCBC), applyFaint(0x000000, 0xFFFFFF));
    try testing.expectEqual(@as(u32, 0x2F3D4D), applyFaint(0x102030, 0x405060));
    try testing.expectEqual(@as(u32, 0x123456), applyFaint(0x123456, 0x123456));
    try testing.expectEqual(@as(u32, 0xFFFFFF), applyFaint(0xFFFFFF, 0xFFFFFF));
    // Alpha bits are ignored, never blended into the channels.
    try testing.expectEqual(@as(u32, 0xBCBCBC), applyFaint(0xFFFFFFFF, 0xFF000000));
}

test "applyInverse swaps, shouldDraw encodes the invisible policy" {
    const swapped = applyInverse(0x112233, 0x445566);
    try testing.expectEqual(@as(u32, 0x445566), swapped.fg);
    try testing.expectEqual(@as(u32, 0x112233), swapped.bg);

    try testing.expect(shouldDraw(false));
    try testing.expect(!shouldDraw(true));
}

test "cursor block fills the cell" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 10, .xrgb8888, null);
    defer f.destroy(a);

    drawCursor(f, 2, 3, 4, 5, .block, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 20), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(2, 3));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(5, 7));
    try testing.expectEqual(@as(u32, 0), f.get(6, 3));
    try testing.expectEqual(@as(u32, 0), f.get(2, 8));
}

test "cursor hollow draws only the 1px border" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 10, .xrgb8888, null);
    defer f.destroy(a);

    drawCursor(f, 2, 3, 6, 5, .hollow, 0x00FF00, true);
    // Border: 2*6 + 2*3 = 18 pixels.
    try testing.expectEqual(@as(usize, 18), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(2, 3));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(7, 7));
    try testing.expectEqual(@as(u32, 0), f.get(4, 5)); // interior untouched
}

test "cursor bar sits half over the left cell edge" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 10, .xrgb8888, null);
    defer f.destroy(a);

    // ghostty cursor_bar, thickness 1: x = -1 -> the column LEFT of the cell.
    drawCursor(f, 4, 3, 6, 4, .bar, 0x0000FF, true);
    try testing.expectEqual(@as(usize, 4), countColor(f, 0x0000FF));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(3, 3));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(3, 6));
    try testing.expectEqual(@as(u32, 0), f.get(4, 3));
}

test "cursor underline uses the configured row, 1px tall" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 12, .xrgb8888, null);
    defer f.destroy(a);

    const saved = cursor_underline_pos;
    defer cursor_underline_pos = saved;

    cursor_underline_pos = 9;
    drawCursor(f, 2, 2, 6, 8, .underline, 0xFF0000, true);
    try expectRows(f, 2, 8, 11, 0xFF0000); // cell_y 2 + row 9
    try testing.expectEqual(@as(usize, 6), countColor(f, 0xFF0000));

    // Fallback: bottom cell row.
    f.fill(0);
    cursor_underline_pos = null;
    drawCursor(f, 2, 2, 6, 8, .underline, 0xFF0000, true);
    try expectRows(f, 2, 8, 9, 0xFF0000); // cell_y 2 + (8 - 1)
    try testing.expectEqual(@as(usize, 6), countColor(f, 0xFF0000));
}

test "cursor thickness knob widens bar and underline strokes" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 12, .xrgb8888, null);
    defer f.destroy(a);

    const saved = cursor_thickness;
    defer cursor_thickness = saved;

    // bar, thickness 2: x = -((2+1)/2) = -1 -> the two columns at and
    // left of the cell edge, full height.
    cursor_thickness = 2;
    drawCursor(f, 4, 2, 6, 8, .bar, 0x0000FF, true);
    try testing.expectEqual(@as(usize, 16), countColor(f, 0x0000FF));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(3, 2));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(4, 9));
    try testing.expectEqual(@as(u32, 0), f.get(5, 2));

    // underline cursor, thickness 2: two rows at the fallback position.
    f.fill(0);
    drawCursor(f, 2, 2, 6, 8, .underline, 0xFF0000, true);
    try expectRows(f, 2, 8, 8, 0xFF0000); // h -| ct = 6 -> cell_y 2 + 6
    try expectRows(f, 2, 8, 9, 0xFF0000);
    try testing.expectEqual(@as(usize, 12), countColor(f, 0xFF0000));
}

test "cursor height knob centers block/bar/hollow; underline keeps cell height" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 16, .xrgb8888, null);
    defer f.destroy(a);

    const saved = cursor_height;
    defer cursor_height = saved;

    // Cell 8x10 at (2,2), cursor height 6 -> y_off = (10-6)/2 = 2.
    cursor_height = 6;
    drawCursor(f, 2, 2, 8, 10, .block, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 48), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(2, 4));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(9, 9));
    try testing.expectEqual(@as(u32, 0), f.get(2, 3));
    try testing.expectEqual(@as(u32, 0), f.get(2, 10));

    // hollow: 8x6 ring, 1px border = 2*8 + 2*4 = 24 px.
    f.fill(0);
    drawCursor(f, 2, 2, 8, 10, .hollow, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 24), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(2, 4));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(9, 9));
    try testing.expectEqual(@as(u32, 0), f.get(4, 6)); // interior

    // Odd difference truncates toward the top: height 5 -> y_off 2.
    f.fill(0);
    cursor_height = 5;
    drawCursor(f, 2, 2, 8, 10, .bar, 0x0000FF, true);
    try testing.expectEqual(@as(usize, 5), countColor(f, 0x0000FF));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(1, 4));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(1, 8));
    try testing.expectEqual(@as(u32, 0), f.get(1, 9));

    // underline ignores cursor_height (sprite/Face.zig:216): bottom row.
    f.fill(0);
    drawCursor(f, 2, 2, 8, 10, .underline, 0xFF0000, true);
    try expectRows(f, 2, 10, 11, 0xFF0000);
    try testing.expectEqual(@as(usize, 8), countColor(f, 0xFF0000));
}

test "cursorExtentY matches the drawn pixels for every style and height" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 40, 40, .xrgb8888, null);
    defer f.destroy(a);
    const saved_h = cursor_height;
    const saved_pos = cursor_underline_pos;
    defer cursor_height = saved_h;
    defer cursor_underline_pos = saved_pos;
    const color: u32 = 0x00FF00;
    const cell_x: i32 = 8;
    const cell_y: i32 = 12;
    const cw: u16 = 8;
    const ch: u16 = 10;
    const styles = [_]CursorStyle{ .block, .hollow, .bar, .underline };
    const heights = [_]?u16{ null, 6, 10, 14, 30 };
    for (styles) |style| {
        for (heights) |mh| {
            cursor_height = mh;
            cursor_underline_pos = null;
            f.fill(0);
            drawCursor(f, cell_x, cell_y, cw, ch, style, color, true);
            const ext = cursorExtentY(ch, style);
            var min_y: ?u32 = null;
            var max_y: ?u32 = null;
            for (0..f.height) |y| {
                for (0..f.width) |x| {
                    if (f.get(@intCast(x), @intCast(y)) == color) {
                        if (min_y == null) min_y = @intCast(y);
                        max_y = @intCast(y);
                    }
                }
            }
            if (ext.y1 <= ext.y0) {
                try testing.expect(min_y == null);
            } else {
                try testing.expectEqual(@as(u32, @intCast(cell_y + ext.y0)), min_y.?);
                try testing.expectEqual(@as(u32, @intCast(cell_y + ext.y1 - 1)), max_y.?);
            }
        }
    }
    // Underline position beyond the cell clamps to the extended canvas.
    cursor_height = null;
    cursor_underline_pos = 14; // ch 10 + pad 2 - thickness 1 = 11
    const ext = cursorExtentY(ch, .underline);
    try testing.expectEqual(@as(i32, 11), ext.y0);
    try testing.expectEqual(@as(i32, 12), ext.y1);
    f.fill(0);
    drawCursor(f, cell_x, cell_y, cw, ch, .underline, color, true);
    try testing.expectEqual(color, f.get(@intCast(cell_x), @intCast(cell_y + 11)));
    try testing.expectEqual(@as(u32, 0), f.get(@intCast(cell_x), @intCast(cell_y + 12)));
}

test "adjusted underline position overrides the renderer-computed row" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 16, .xrgb8888, null);
    defer f.destroy(a);

    const saved = adjusted_underline_pos;
    defer adjusted_underline_pos = saved;

    // Null (ghostty default): the passed row is used unchanged.
    adjusted_underline_pos = null;
    drawUnderline(f, 2, 2, 8, 12, .single, 0x00FF00, 9, 1);
    try expectRows(f, 2, 10, 11, 0x00FF00);

    // Set: the adjusted shared metric replaces the passed row.
    f.fill(0);
    adjusted_underline_pos = 5;
    drawUnderline(f, 2, 2, 8, 12, .single, 0x00FF00, 9, 1);
    try expectRows(f, 2, 10, 7, 0x00FF00);
    try testing.expectEqual(@as(usize, 8), countColor(f, 0x00FF00));
}

test "cursor blink off draws nothing" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 12, .xrgb8888, null);
    defer f.destroy(a);
    inline for (.{ CursorStyle.block, CursorStyle.hollow, CursorStyle.bar, CursorStyle.underline }) |style| {
        drawCursor(f, 2, 2, 6, 6, style, 0xFF00FF, false);
        try testing.expectEqual(@as(usize, 0), countColor(f, 0xFF00FF));
    }
}

test "cursorOverlayColor stays legible" {
    // Distinct backgrounds are used as the glyph color.
    try testing.expectEqual(@as(u32, 0x101010), cursorOverlayColor(0x101010, 0xFFFFFF));
    // Near-identical pair: contrast color picked from the cursor luminance.
    try testing.expectEqual(@as(u32, 0x000000), cursorOverlayColor(0xFFFFFF, 0xF0F0F0));
    try testing.expectEqual(@as(u32, 0xFFFFFF), cursorOverlayColor(0x000000, 0x101010));
}

test "out-of-bounds cells clip without panic" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 10, 10, .xrgb8888, null);
    defer f.destroy(a);

    // Partially above/left: only the visible 5x5 corner is painted.
    drawCursor(f, -3, -3, 8, 8, .block, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 25), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(4, 4));
    try testing.expectEqual(@as(u32, 0), f.get(5, 5));

    // Fully outside on every edge, plus zero-sized cells: nothing happens.
    drawUnderline(f, 12, 12, 8, 8, .single, 0x00FF00, 2, 1);
    drawUnderline(f, -20, -20, 8, 8, .curly, 0x00FF00, 2, 1);
    drawUnderline(f, 0, 10, 8, 8, .dashed, 0x00FF00, 2, 1);
    drawUnderline(f, 0, 0, 0, 8, .single, 0x00FF00, 2, 1);
    drawUnderline(f, 0, 0, 8, 0, .single, 0x00FF00, 2, 1);
    drawCursor(f, 20, 20, 5, 5, .block, 0x00FF00, true);
    drawCursor(f, -8, -8, 4, 4, .underline, 0x00FF00, true);
    drawCursor(f, 12, 0, 4, 4, .bar, 0x00FF00, true);
    drawStrikethrough(f, 0, 0, 0, 0, 0x00FF00, 1, 1);
    drawOverline(f, -10, -10, 10, 10, 0x00FF00, 1);
    try testing.expectEqual(@as(usize, 25), countColor(f, 0x00FF00));

    // Huge coordinates and saturating metric offsets must not wrap.
    drawUnderline(f, 0, 0, 8, 8, .single, 0x00FF00, -30000, 4);
    drawUnderline(f, std.math.maxInt(i32) - 2, 0, 8, 8, .dotted, 0x00FF00, 30000, 2);
    try testing.expectEqual(@as(usize, 25), countColor(f, 0x00FF00));
}

test "drawing honors row pitch and leaves padding untouched" {
    const a = testing.allocator;
    const width: u32 = 6;
    const height: u32 = 3;
    var f = try Framebuffer.create(a, width, height, .xrgb8888, width * 4 + 12);
    defer f.destroy(a);

    drawCursor(f, 0, 0, 6, 3, .block, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 18), countColor(f, 0x00FF00));

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const off = y * @as(usize, f.pitch) + @as(usize, width) * 4;
        const pad = f.mem[off..][0..12];
        for (pad) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
}
