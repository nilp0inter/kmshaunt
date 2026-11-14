//! src/font/sprite_ghostty.zig -- direct port of ghostty v1.4.0's sprite
//! drawing (src/font/sprite/draw/*.zig, tag v1.4.0) into kmshaunt's
//! coverage model.
//!
//! ghostty draws sprites onto an alpha8 canvas with z2d (analytic
//! antialiasing). Here the SAME geometry is rasterized with kmshaunt's
//! 4x4 supersampling: edge positions, thicknesses, joins and dash layout
//! follow ghostty exactly; only the coverage integration differs.
//!
//! Ported sources (function names kept where practical):
//!   * common.zig   -- Thickness.height, Fraction.min/max/float, fill,
//!                     hline/vline/hlineMiddle/vlineMiddle, Shade values.
//!   * box.zig      -- linesChar, dashHorizontal/dashVertical, the light
//!                     diagonals (corner overshoot), arc (cubic Bezier
//!                     rounded corners, s = 0.25).
//!   * block.zig    -- block/blockShade (round + edge anchor),
//!                     fullBlockShade, quadrant.
//!   * braille.zig  -- draw2800_28FF dot grid sizing.
//!   * powerline.zig -- drawE0B0..drawE0BF (triangles, chevrons, Bezier
//!                     round separators incl. the inner-stroke outline).
//!   * symbols_for_legacy_computing.zig -- sextants, smooth mosaics
//!                     (SmoothMosaic patterns), edge triangles, eighth
//!                     blocks, shades, checkerboardFill, diagonal fills,
//!                     cornerTriangleShade, cornerDiagonalLines,
//!                     cellDiagonal, circle, 1FBAF/1FBBD..1FBCF.
//!   * symbols_for_legacy_computing_supplement.zig -- octants (mask table
//!                     verified identical to draw/octants.txt).
//!   * geometric_shapes.zig -- cornerTriangleShade vertex layout.
//!
//! NOT ported: U+E0A0..U+E0A3. ghostty v1.4.0 has no sprite drawing for
//! these (they come from the font); kmshaunt keeps its own code-drawn
//! versions below so the ranges stay sprite-covered.
//!
//! Thickness model: ghostty uses metrics.box_thickness =
//! max(1, ceil(underline_thickness_px)) (src/font/Metrics.zig `calc`).
//! renderSprite only receives the cell size, so the base is pinned to the
//! parity face's value: ComicCode Ligatures Nerd Font at 14pt @ 96dpi has
//! underline = 50/1000 em = 0.933px -> ceil = 1. light = base,
//! heavy = 2*base, super_light = max(base/2, 1), exactly common.Thickness.
//!
//! Blending: ghostty's canvas.rect/putPixel overwrites; every multi-shape
//! glyph here draws later shapes at equal or higher alpha (medium shade
//! then solid), so kmshaunt's max-blend produces identical coverage.

const std = @import("std");

/// Supersampling factor per axis for antialiased shapes (4x4 = 16 samples).
const ss: u32 = 4;

/// ghostty metrics.box_thickness for the parity face (see module comment).
pub const box_thickness: u32 = 1;

// Utility names for common fractions (common.zig).
const one_eighth: f64 = 0.125;
const one_quarter: f64 = 0.25;
const one_third: f64 = 1.0 / 3.0;
const three_eighths: f64 = 0.375;
const half: f64 = 0.5;
const five_eighths: f64 = 0.625;
const two_thirds: f64 = 2.0 / 3.0;
const three_quarters: f64 = 0.75;
const seven_eighths: f64 = 0.875;

/// The thickness of a line (port of common.Thickness).
const Thickness = enum {
    super_light,
    light,
    heavy,

    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

/// Shades (port of common.Shade).
const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,
};

/// Cell geometry shared by all draw functions. Coordinates are pixels;
/// `cx`/`cy` are the (float) cell centers used by antialiased shapes.
pub const Cell = struct {
    w: u32,
    h: u32,
    fw: f64,
    fh: f64,
    cx: f64,
    cy: f64,
    light: u32,
    heavy: u32,
    super_light: u32,

    pub fn init(w: u32, h: u32) Cell {
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        return .{
            .w = w,
            .h = h,
            .fw = fw,
            .fh = fh,
            .cx = fw / 2.0,
            .cy = fh / 2.0,
            .light = Thickness.height(.light, box_thickness),
            .heavy = Thickness.height(.heavy, box_thickness),
            .super_light = Thickness.height(.super_light, box_thickness),
        };
    }
};

// ---------------------------------------------------------------------------
// Coverage primitives
// ---------------------------------------------------------------------------

/// Fill [x0,x1) x [y0,y1) with `alpha` (max-blend), clipped to the cell.
fn fillRect(out: []u8, c: Cell, x0: u32, y0: u32, x1: u32, y1: u32, alpha: u8) void {
    const xa = @min(x0, c.w);
    const xb = @min(x1, c.w);
    const ya = @min(y0, c.h);
    const yb = @min(y1, c.h);
    if (xa >= xb or ya >= yb) return;
    var y = ya;
    while (y < yb) : (y += 1) {
        const row = out[y * c.w ..][xa..xb];
        for (row) |*p| p.* = @max(p.*, alpha);
    }
}

/// Invert coverage (port of Canvas.invert, clipped to the cell).
fn invert(out: []u8) void {
    for (out) |*v| v.* = 255 - v.*;
}

/// Rasterize a coverage function with 4x4 supersampling. `inside` is
/// evaluated at sample centers in pixel coordinates.
fn raster(out: []u8, c: Cell, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f64, f64) bool) void {
    rasterShaded(out, c, ctx, inside, 255);
}

/// `raster` with the resulting coverage scaled by `alpha` (shaded shapes).
fn rasterShaded(out: []u8, c: Cell, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f64, f64) bool, alpha: u8) void {
    var y: u32 = 0;
    while (y < c.h) : (y += 1) {
        var x: u32 = 0;
        while (x < c.w) : (x += 1) {
            var n: u32 = 0;
            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / @as(f64, @floatFromInt(ss));
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / @as(f64, @floatFromInt(ss));
                    if (inside(ctx, px, py)) n += 1;
                }
            }
            if (n > 0) {
                const a: u8 = @intCast(n * alpha / (ss * ss));
                const p = &out[y * c.w + x];
                p.* = @max(p.*, a);
            }
        }
    }
}

/// Rasterize with max-blend (for drawing several shapes into one cell).
fn rasterMax(out: []u8, c: Cell, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f64, f64) bool) void {
    rasterShaded(out, c, ctx, inside, 255);
}

/// Horizontal mirror wrapper (port of Canvas.flipHorizontal; mirroring the
/// coverage function is equivalent since the cell is the whole canvas).
fn Flip(comptime Inner: type) type {
    return struct {
        inner: Inner,
        fw: f64,

        const Self = @This();
        fn inside(self: Self, px: f64, py: f64) bool {
            return self.inner.inside(self.fw - px, py);
        }
    };
}

// ---------------------------------------------------------------------------
// Fractions and line helpers (port of common.zig)
// ---------------------------------------------------------------------------

/// Min coordinate of a fractional boundary (common.Fraction.min):
/// complementary rounding so adjacent sub-rects share the boundary pixel.
fn fracMin(size: u32, f: f64) u32 {
    const s: f64 = @floatFromInt(size);
    return @intFromFloat(s - @round((1.0 - f) * s));
}

/// Max coordinate of a fractional boundary (common.Fraction.max).
fn fracMax(size: u32, f: f64) u32 {
    const s: f64 = @floatFromInt(size);
    return @intFromFloat(@round(f * s));
}

/// Fill a section of the cell between fraction lines (common.fill).
fn fill(out: []u8, c: Cell, x0: f64, x1: f64, y0: f64, y1: f64) void {
    fillRect(
        out,
        c,
        fracMin(c.w, x0),
        fracMin(c.h, y0),
        fracMax(c.w, x1),
        fracMax(c.h, y1),
        255,
    );
}

/// Horizontal line with the top edge at `y`, between `x1` and `x2`
/// (common.hline).
fn hline(out: []u8, c: Cell, x1: u32, x2: u32, y: u32, thickness_px: u32) void {
    fillRect(out, c, x1, y, x2, y +| thickness_px, 255);
}

/// Vertical line with the left edge at `x`, between `y1` and `y2`
/// (common.vline).
fn vline(out: []u8, c: Cell, y1: u32, y2: u32, x: u32, thickness_px: u32) void {
    fillRect(out, c, x, y1, x +| thickness_px, y2, 255);
}

/// Centered horizontal line of the provided thickness (common.hlineMiddle).
fn hlineMiddle(out: []u8, c: Cell, thickness: Thickness) void {
    const thick_px = thickness.height(box_thickness);
    hline(out, c, 0, c.w, (c.h -| thick_px) / 2, thick_px);
}

/// Centered vertical line of the provided thickness (common.vlineMiddle).
fn vlineMiddle(out: []u8, c: Cell, thickness: Thickness) void {
    const thick_px = thickness.height(box_thickness);
    vline(out, c, 0, c.h, (c.w -| thick_px) / 2, thick_px);
}

// ---------------------------------------------------------------------------
// Antialiased shape contexts
// ---------------------------------------------------------------------------

/// Thick line segment with butt caps; endpoints may overshoot the cell so
/// corner-touching diagonals reach the boundary pixels. Equivalent to
/// Canvas.line (z2d stroke, .butt caps, line_width = thickness).
const Segment = struct {
    x0: f64,
    y0: f64,
    dx: f64,
    dy: f64,
    len2: f64,
    half: f64,

    pub fn init(x0: f64, y0: f64, x1: f64, y1: f64, thick: f64) Segment {
        const dx = x1 - x0;
        const dy = y1 - y0;
        return .{
            .x0 = x0,
            .y0 = y0,
            .dx = dx,
            .dy = dy,
            .len2 = dx * dx + dy * dy,
            .half = thick / 2.0,
        };
    }

    pub fn inside(self: Segment, px: f64, py: f64) bool {
        if (self.len2 == 0) return false;
        const t = ((px - self.x0) * self.dx + (py - self.y0) * self.dy) / self.len2;
        if (t < 0 or t > 1) return false;
        const qx = px - (self.x0 + t * self.dx);
        const qy = py - (self.y0 + t * self.dy);
        return qx * qx + qy * qy <= self.half * self.half;
    }
};

/// Triangle with vertices a, b, cc (any winding).
const Tri = struct {
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    cx: f64,
    cy: f64,

    fn inside(self: Tri, px: f64, py: f64) bool {
        const d1 = (px - self.bx) * (self.ay - self.by) - (self.ax - self.bx) * (py - self.by);
        const d2 = (px - self.cx) * (self.by - self.cy) - (self.bx - self.cx) * (py - self.cy);
        const d3 = (px - self.ax) * (self.cy - self.ay) - (self.cx - self.ax) * (py - self.ay);
        const neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
        const pos = (d1 > 0) or (d2 > 0) or (d3 > 0);
        return !(neg and pos);
    }
};

/// Simple polygon fill (even-odd ray cast; all ported outlines are simple).
const Poly = struct {
    verts: []const [2]f64,

    fn inside(self: Poly, px: f64, py: f64) bool {
        const n = self.verts.len;
        var result = false;
        var j = n - 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const xi = self.verts[i][0];
            const yi = self.verts[i][1];
            const xj = self.verts[j][0];
            const yj = self.verts[j][1];
            if ((yi > py) != (yj > py)) {
                const x_cross = xj + (py - yj) * (xi - xj) / (yi - yj);
                if (px < x_cross) result = !result;
            }
            j = i;
        }
        return result;
    }
};

/// Filled circle.
const Disk = struct {
    cx: f64,
    cy: f64,
    r: f64,

    pub fn inside(self: Disk, px: f64, py: f64) bool {
        const dx = px - self.cx;
        const dy = py - self.cy;
        return dx * dx + dy * dy <= self.r * self.r;
    }
};

/// Annulus (circle outline): radii [r - half, r + half].
const Ring = struct {
    cx: f64,
    cy: f64,
    r: f64,
    half: f64,

    pub fn inside(self: Ring, px: f64, py: f64) bool {
        const dx = px - self.cx;
        const dy = py - self.cy;
        const d = @sqrt(dx * dx + dy * dy);
        return @abs(d - self.r) <= self.half;
    }
};

/// Cubic Bezier evaluation.
fn cubic(p0: [2]f64, p1: [2]f64, p2: [2]f64, p3: [2]f64, t: f64) [2]f64 {
    const u = 1.0 - t;
    return .{
        u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    };
}

/// Flatten a cubic into `pts` (t = 1/len .. 1; the start point is assumed
/// to already be in the polyline). 64 steps keep the deviation from the
/// true curve far below the supersampling grid (< 0.005px at cell sizes).
const bezier_steps = 64;
fn flattenCubic(pts: [][2]f64, p0: [2]f64, p1: [2]f64, p2: [2]f64, p3: [2]f64) void {
    for (pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(pts.len));
        p.* = cubic(p0, p1, p2, p3, t);
    }
}

/// Squared distance from a point to a polyline segment.
fn segDist2(a: [2]f64, b: [2]f64, px: f64, py: f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    var t: f64 = 0;
    if (len2 > 0) t = ((px - a[0]) * dx + (py - a[1]) * dy) / len2;
    t = @max(0.0, @min(1.0, t));
    const qx = px - (a[0] + t * dx);
    const qy = py - (a[1] + t * dy);
    return qx * qx + qy * qy;
}

/// Stroked polyline with butt caps at the ends (round joins between the
/// flattened pieces; the flattening error is sub-sample). Used for the
/// Bezier arcs and round separators, matching z2d's stroke geometry.
const PolyStroke = struct {
    pts: []const [2]f64,
    half: f64,

    fn inside(self: PolyStroke, px: f64, py: f64) bool {
        var best: f64 = std.math.inf(f64);
        var i: usize = 0;
        while (i + 1 < self.pts.len) : (i += 1) {
            const d2 = segDist2(self.pts[i], self.pts[i + 1], px, py);
            if (d2 < best) best = d2;
        }
        return best <= self.half * self.half;
    }
};

/// Inner stroke of a polyline (Canvas.innerStrokePath): the band of width
/// `thick` on the interior side of the path. The interior is the left side
/// of the travel direction (cross product >= 0), which for all ported
/// outline paths faces the inside of the glyph.
const PolyInnerStroke = struct {
    pts: []const [2]f64,
    thick: f64,

    fn inside(self: PolyInnerStroke, px: f64, py: f64) bool {
        var best: f64 = std.math.inf(f64);
        var best_cross: f64 = 0;
        var i: usize = 0;
        while (i + 1 < self.pts.len) : (i += 1) {
            const a = self.pts[i];
            const b = self.pts[i + 1];
            const d2 = segDist2(a, b, px, py);
            if (d2 < best) {
                best = d2;
                best_cross = (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
            }
        }
        return best <= self.thick * self.thick and best_cross >= 0;
    }
};

// ---------------------------------------------------------------------------
// Box Drawing U+2500..U+257F (port of box.zig)
// ---------------------------------------------------------------------------

const Style = enum(u2) { none = 0, light = 1, heavy = 2, double = 3 };

const Lines = struct {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,
};

/// Per-codepoint arm styles for the intersection-style box characters.
/// Encoding: up = bits 0-1, right = bits 2-3, down = bits 4-5,
/// left = bits 6-7 (0 none, 1 light, 2 heavy, 3 double). Zero entries are
/// dashes, rounded corners and diagonals, handled separately. Verified
/// identical to the linesChar calls in ghostty box.zig for all 128 cells.
const box_lines = [128]u8{
    68, 136, 17, 34, 0, 0, 0, 0, 0, 0, 0, 0, 20, 24, 36, 40,
    80, 144, 96, 160, 5, 9, 6, 10, 65, 129, 66, 130, 21, 25, 22, 37,
    38, 26, 41, 42, 81, 145, 82, 97, 98, 146, 161, 162, 84, 148, 88, 152,
    100, 164, 104, 168, 69, 133, 73, 137, 70, 134, 74, 138, 85, 149, 89, 153,
    86, 101, 102, 150, 90, 165, 105, 154, 169, 166, 106, 170, 0, 0, 0, 0,
    204, 51, 28, 52, 60, 208, 112, 240, 13, 7, 15, 193, 67, 195, 29, 55,
    63, 209, 115, 243, 220, 116, 252, 205, 71, 207, 221, 119, 255, 0, 0, 0,
    0, 0, 0, 0, 64, 1, 4, 16, 128, 2, 8, 32, 72, 33, 132, 18,
};

fn decodeLines(enc: u8) Lines {
    return .{
        .up = @enumFromInt(enc & 3),
        .right = @enumFromInt((enc >> 2) & 3),
        .down = @enumFromInt((enc >> 4) & 3),
        .left = @enumFromInt((enc >> 6) & 3),
    };
}

/// Port of box.linesChar: light/heavy stems centered, double stems
/// straddling the light stem positions with a light-width gap, and arm
/// termination rules that keep mixed tees/crosses joined.
fn linesChar(out: []u8, c: Cell, lines: Lines) void {
    const light = c.light;
    const heavy = c.heavy;
    const w = c.w;
    const h = c.h;

    const h_light_top = (h -| light) / 2;
    const h_light_bottom = h_light_top +| light;
    const h_heavy_top = (h -| heavy) / 2;
    const h_heavy_bottom = h_heavy_top +| heavy;
    const h_double_top = h_light_top -| light;
    const h_double_bottom = h_light_bottom +| light;

    const v_light_left = (w -| light) / 2;
    const v_light_right = v_light_left +| light;
    const v_heavy_left = (w -| heavy) / 2;
    const v_heavy_right = v_heavy_left +| heavy;
    const v_double_left = v_light_left -| light;
    const v_double_right = v_light_right +| light;

    const up_bottom: u32 = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        (if (lines.left == .double or lines.right == .double) h_double_bottom else h_light_bottom)
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    const down_top: u32 = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        (if (lines.left == .double or lines.right == .double) h_double_top else h_light_top)
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    const left_right: u32 = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        (if (lines.up == .double or lines.down == .double) v_double_right else v_light_right)
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    const right_left: u32 = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        (if (lines.up == .double or lines.down == .double) v_double_left else v_light_left)
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    switch (lines.up) {
        .none => {},
        .light => fillRect(out, c, v_light_left, 0, v_light_right, up_bottom, 255),
        .heavy => fillRect(out, c, v_heavy_left, 0, v_heavy_right, up_bottom, 255),
        .double => {
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;
            fillRect(out, c, v_double_left, 0, v_light_left, left_bottom, 255);
            fillRect(out, c, v_light_right, 0, v_double_right, right_bottom, 255);
        },
    }
    switch (lines.right) {
        .none => {},
        .light => fillRect(out, c, right_left, h_light_top, w, h_light_bottom, 255),
        .heavy => fillRect(out, c, right_left, h_heavy_top, w, h_heavy_bottom, 255),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;
            fillRect(out, c, top_left, h_double_top, w, h_light_top, 255);
            fillRect(out, c, bottom_left, h_light_bottom, w, h_double_bottom, 255);
        },
    }
    switch (lines.down) {
        .none => {},
        .light => fillRect(out, c, v_light_left, down_top, v_light_right, h, 255),
        .heavy => fillRect(out, c, v_heavy_left, down_top, v_heavy_right, h, 255),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;
            fillRect(out, c, v_double_left, left_top, v_light_left, h, 255);
            fillRect(out, c, v_light_right, right_top, v_double_right, h, 255);
        },
    }
    switch (lines.left) {
        .none => {},
        .light => fillRect(out, c, 0, h_light_top, left_right, h_light_bottom, 255),
        .heavy => fillRect(out, c, 0, h_heavy_top, left_right, h_heavy_bottom, 255),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;
            fillRect(out, c, 0, h_double_top, top_right, h_light_top, 255);
            fillRect(out, c, 0, h_light_bottom, bottom_right, h_double_bottom, 255);
        },
    }
}

/// Port of box.dashHorizontal: N dashes with half-sized gaps at both ends
/// so horizontal tiling yields one consistent dashed line. The too-small
/// fallback is a LIGHT line regardless of the dash thickness (ghostty
/// calls hlineMiddle(.light)).
fn dashHorizontal(out: []u8, c: Cell, count: u32, thick_px: u32, desired_gap: u32) void {
    if (c.w < count * 2) {
        hlineMiddle(out, c, .light);
        return;
    }
    const gap_width = @min(desired_gap, c.w / (2 * count));
    const total_dash_width = c.w - count * gap_width;
    const dash_width = total_dash_width / count;
    var extra = total_dash_width % count;
    const y = (c.h -| thick_px) / 2;
    var x: u32 = gap_width / 2;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var x1 = x + dash_width;
        if (extra > 0) {
            extra -= 1;
            x1 += 1;
        }
        hline(out, c, x, x1, y, thick_px);
        x = x1 + gap_width;
    }
}

/// Port of box.dashVertical: a full extra gap at the bottom (start at the
/// top edge) for better joining to solid characters. Fallback is a LIGHT
/// centered line (ghostty calls vlineMiddle(.light)).
fn dashVertical(out: []u8, c: Cell, count: u32, thick_px: u32, desired_gap: u32) void {
    if (c.h < count * 2) {
        vlineMiddle(out, c, .light);
        return;
    }
    const gap_height = @min(desired_gap, c.h / (2 * count));
    const total_dash_height = c.h - count * gap_height;
    const dash_height = total_dash_height / count;
    var extra = total_dash_height % count;
    const x = (c.w -| thick_px) / 2;
    var y: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var y1 = y + dash_height;
        if (extra > 0) {
            extra -= 1;
            y1 += 1;
        }
        vline(out, c, y, y1, x, thick_px);
        y = y1 + gap_height;
    }
}

/// Port of box.lightDiagonalUpperLeftToLowerRight: overshoot the corners
/// by 0.5px along the slope so the boundary pixels are covered.
fn lightDiagonalUpperLeftToLowerRight(out: []u8, c: Cell) void {
    const slope_x = @min(1.0, c.fw / c.fh);
    const slope_y = @min(1.0, c.fh / c.fw);
    const seg = Segment.init(
        -0.5 * slope_x,
        -0.5 * slope_y,
        c.fw + 0.5 * slope_x,
        c.fh + 0.5 * slope_y,
        @floatFromInt(c.light),
    );
    rasterMax(out, c, seg, Segment.inside);
}

/// Port of box.lightDiagonalUpperRightToLowerLeft.
fn lightDiagonalUpperRightToLowerLeft(out: []u8, c: Cell) void {
    const slope_x = @min(1.0, c.fw / c.fh);
    const slope_y = @min(1.0, c.fh / c.fw);
    const seg = Segment.init(
        c.fw + 0.5 * slope_x,
        -0.5 * slope_y,
        -0.5 * slope_x,
        c.fh + 0.5 * slope_y,
        @floatFromInt(c.light),
    );
    rasterMax(out, c, seg, Segment.inside);
}

/// Port of box.lightDiagonalCross.
fn lightDiagonalCross(out: []u8, c: Cell) void {
    lightDiagonalUpperRightToLowerLeft(out, c);
    lightDiagonalUpperLeftToLowerRight(out, c);
}

/// A corner of a cell (common.Corner).
const Corner = enum(u2) { tl, tr, bl, br };

/// Port of box.arc: rounded box-drawing corner as a cubic Bezier (NOT a
/// circular arc). The stroke runs from one edge midpoint to the other,
/// with the curve's middle control points at s = 0.25 of the radius from
/// the arc center. Centering uses the integer light-stem position:
/// center = (size -| thick) / 2 + thick / 2.
const Arc = struct {
    pts: [2 + bezier_steps + 1][2]f64,
    half: f64,

    fn init(c: Cell, corner: Corner) Arc {
        const thick_px = c.light;
        const float_thick: f64 = @floatFromInt(thick_px);
        const center_x: f64 = @as(f64, @floatFromInt((c.w -| thick_px) / 2)) + float_thick / 2;
        const center_y: f64 = @as(f64, @floatFromInt((c.h -| thick_px) / 2)) + float_thick / 2;
        const r = @min(c.fw, c.fh) / 2;
        const s: f64 = 0.25;

        // Path: moveTo(a), lineTo(b), curveTo(c1, c2, d), lineTo(e).
        var a: [2]f64 = undefined;
        var b: [2]f64 = undefined;
        var c1: [2]f64 = undefined;
        var c2: [2]f64 = undefined;
        var d: [2]f64 = undefined;
        var e: [2]f64 = undefined;
        switch (corner) {
            .tl => {
                a = .{ center_x, 0 };
                b = .{ center_x, center_y - r };
                c1 = .{ center_x, center_y - s * r };
                c2 = .{ center_x - s * r, center_y };
                d = .{ center_x - r, center_y };
                e = .{ 0, center_y };
            },
            .tr => {
                a = .{ center_x, 0 };
                b = .{ center_x, center_y - r };
                c1 = .{ center_x, center_y - s * r };
                c2 = .{ center_x + s * r, center_y };
                d = .{ center_x + r, center_y };
                e = .{ c.fw, center_y };
            },
            .bl => {
                a = .{ center_x, c.fh };
                b = .{ center_x, center_y + r };
                c1 = .{ center_x, center_y + s * r };
                c2 = .{ center_x - s * r, center_y };
                d = .{ center_x - r, center_y };
                e = .{ 0, center_y };
            },
            .br => {
                a = .{ center_x, c.fh };
                b = .{ center_x, center_y + r };
                c1 = .{ center_x, center_y + s * r };
                c2 = .{ center_x + s * r, center_y };
                d = .{ center_x + r, center_y };
                e = .{ c.fw, center_y };
            },
        }

        var self: Arc = .{ .pts = undefined, .half = float_thick / 2 };
        self.pts[0] = a;
        self.pts[1] = b;
        flattenCubic(self.pts[2 .. 2 + bezier_steps], b, c1, c2, d);
        self.pts[2 + bezier_steps] = e;
        return self;
    }

    fn inside(self: Arc, px: f64, py: f64) bool {
        const stroke = PolyStroke{ .pts = &self.pts, .half = self.half };
        return stroke.inside(px, py);
    }
};

/// Port of box.draw2500_257F dispatch.
pub fn drawBox(out: []u8, c: Cell, cp: u21) void {
    const enc = box_lines[cp - 0x2500];
    if (enc != 0) {
        linesChar(out, c, decodeLines(enc));
        return;
    }
    switch (cp) {
        0x2504 => dashHorizontal(out, c, 3, c.light, @max(4, c.light)),
        0x2505 => dashHorizontal(out, c, 3, c.heavy, @max(4, c.light)),
        0x2506 => dashVertical(out, c, 3, c.light, @max(4, c.light)),
        0x2507 => dashVertical(out, c, 3, c.heavy, @max(4, c.light)),
        0x2508 => dashHorizontal(out, c, 4, c.light, @max(4, c.light)),
        0x2509 => dashHorizontal(out, c, 4, c.heavy, @max(4, c.light)),
        0x250A => dashVertical(out, c, 4, c.light, @max(4, c.light)),
        0x250B => dashVertical(out, c, 4, c.heavy, @max(4, c.light)),
        0x254C => dashHorizontal(out, c, 2, c.light, c.light),
        0x254D => dashHorizontal(out, c, 2, c.heavy, c.heavy),
        0x254E => dashVertical(out, c, 2, c.light, c.heavy),
        0x254F => dashVertical(out, c, 2, c.heavy, c.heavy),
        0x256D => raster(out, c, Arc.init(c, .br), Arc.inside),
        0x256E => raster(out, c, Arc.init(c, .bl), Arc.inside),
        0x256F => raster(out, c, Arc.init(c, .tl), Arc.inside),
        0x2570 => raster(out, c, Arc.init(c, .tr), Arc.inside),
        0x2571 => lightDiagonalUpperRightToLowerLeft(out, c),
        0x2572 => lightDiagonalUpperLeftToLowerRight(out, c),
        0x2573 => lightDiagonalCross(out, c),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Block Elements U+2580..U+259F (port of block.zig)
// ---------------------------------------------------------------------------

const HAlign = enum { left, right, center };
const VAlign = enum { top, bottom, middle };

/// Port of block.blockShade: size = round(cell * fraction), anchored to the
/// named edge (center uses integer division).
fn blockShade(out: []u8, c: Cell, ha: HAlign, va: VAlign, wf: f64, hf: f64, shade: Shade) void {
    const w: u32 = @intFromFloat(@round(c.fw * wf));
    const h: u32 = @intFromFloat(@round(c.fh * hf));
    const x: u32 = switch (ha) {
        .left => 0,
        .right => c.w -| w,
        .center => (c.w -| w) / 2,
    };
    const y: u32 = switch (va) {
        .top => 0,
        .bottom => c.h -| h,
        .middle => (c.h -| h) / 2,
    };
    fillRect(out, c, x, y, x +| w, y +| h, @intFromEnum(shade));
}

fn block(out: []u8, c: Cell, ha: HAlign, va: VAlign, wf: f64, hf: f64) void {
    blockShade(out, c, ha, va, wf, hf, .on);
}

/// Port of block.fullBlockShade.
fn fullBlockShade(out: []u8, c: Cell, shade: Shade) void {
    fillRect(out, c, 0, 0, c.w, c.h, @intFromEnum(shade));
}

/// Port of block.quadrant (common.fill with half fractions).
fn quadrant(out: []u8, c: Cell, tl: bool, tr: bool, bl: bool, br: bool) void {
    if (tl) fill(out, c, 0, half, 0, half);
    if (tr) fill(out, c, half, 1, 0, half);
    if (bl) fill(out, c, 0, half, half, 1);
    if (br) fill(out, c, half, 1, half, 1);
}

/// Port of block.draw2580_259F.
pub fn drawBlock(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x2580 => block(out, c, .center, .top, 1, half),
        0x2581 => block(out, c, .center, .bottom, 1, one_eighth),
        0x2582 => block(out, c, .center, .bottom, 1, one_quarter),
        0x2583 => block(out, c, .center, .bottom, 1, three_eighths),
        0x2584 => block(out, c, .center, .bottom, 1, half),
        0x2585 => block(out, c, .center, .bottom, 1, five_eighths),
        0x2586 => block(out, c, .center, .bottom, 1, three_quarters),
        0x2587 => block(out, c, .center, .bottom, 1, seven_eighths),
        0x2588 => fullBlockShade(out, c, .on),
        0x2589 => block(out, c, .left, .middle, seven_eighths, 1),
        0x258A => block(out, c, .left, .middle, three_quarters, 1),
        0x258B => block(out, c, .left, .middle, five_eighths, 1),
        0x258C => block(out, c, .left, .middle, half, 1),
        0x258D => block(out, c, .left, .middle, three_eighths, 1),
        0x258E => block(out, c, .left, .middle, one_quarter, 1),
        0x258F => block(out, c, .left, .middle, one_eighth, 1),
        0x2590 => block(out, c, .right, .middle, half, 1),
        0x2591 => fullBlockShade(out, c, .light),
        0x2592 => fullBlockShade(out, c, .medium),
        0x2593 => fullBlockShade(out, c, .dark),
        0x2594 => block(out, c, .center, .top, 1, one_eighth),
        0x2595 => block(out, c, .right, .middle, one_eighth, 1),
        0x2596 => quadrant(out, c, false, false, true, false),
        0x2597 => quadrant(out, c, false, false, false, true),
        0x2598 => quadrant(out, c, true, false, false, false),
        0x2599 => quadrant(out, c, true, false, true, true),
        0x259A => quadrant(out, c, true, false, false, true),
        0x259B => quadrant(out, c, true, true, true, false),
        0x259C => quadrant(out, c, true, true, false, true),
        0x259D => quadrant(out, c, false, true, false, false),
        0x259E => quadrant(out, c, false, true, true, false),
        0x259F => quadrant(out, c, false, true, true, true),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Braille U+2800..U+28FF (port of braille.zig)
// ---------------------------------------------------------------------------

/// Port of braille.draw2800_28FF: 2x4 dot grid, sized by the same
/// leftover-pixel priority rules (dot size first, then margins, spacing,
/// margins again, dot size again).
pub fn drawBraille(out: []u8, c: Cell, cp: u21) void {
    const mask: u8 = @truncate(cp - 0x2800);
    if (mask == 0) return;

    var w: i32 = @intCast(@min(c.w / 4, c.h / 8));
    var x_spacing: i32 = @intCast(c.w / 4);
    var y_spacing: i32 = @intCast(c.h / 8);
    var x_margin: i32 = @divFloor(x_spacing, 2);
    var y_margin: i32 = @divFloor(y_spacing, 2);

    var x_px_left: i32 = @as(i32, @intCast(c.w)) - 2 * x_margin - x_spacing - 2 * w;
    var y_px_left: i32 = @as(i32, @intCast(c.h)) - 2 * y_margin - 3 * y_spacing - 4 * w;

    // First, try hard to ensure the DOT width is non-zero.
    if (x_px_left >= 2 and y_px_left >= 4 and w == 0) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }
    // Second, prefer a non-zero margin.
    if (x_px_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_px_left -= 2;
    }
    // Third, increase spacing.
    if (x_px_left >= 1) {
        x_spacing += 1;
        x_px_left -= 1;
    }
    if (y_px_left >= 3) {
        y_spacing += 1;
        y_px_left -= 3;
    }
    // Fourth, margins ("spacing", but on the sides).
    if (x_px_left >= 2) {
        x_margin += 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2) {
        y_margin += 1;
        y_px_left -= 2;
    }
    // Last - increase dot width.
    if (x_px_left >= 2 and y_px_left >= 4) {
        w += 1;
    }
    if (w == 0) w = 1; // tiny cells: still show something

    const xs = [2]i32{ x_margin, x_margin + w + x_spacing };
    var ys: [4]i32 = undefined;
    ys[0] = y_margin;
    ys[1] = ys[0] + w + y_spacing;
    ys[2] = ys[1] + w + y_spacing;
    ys[3] = ys[2] + w + y_spacing;

    // Bit order (Pattern struct): 0..2 left column top->bottom, 3..5 right
    // column top->bottom, 6 bottom-left, 7 bottom-right.
    const pos = [8][2]i32{
        .{ xs[0], ys[0] }, .{ xs[0], ys[1] }, .{ xs[0], ys[2] },
        .{ xs[1], ys[0] }, .{ xs[1], ys[1] }, .{ xs[1], ys[2] },
        .{ xs[0], ys[3] }, .{ xs[1], ys[3] },
    };
    for (pos, 0..) |p, i| {
        if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
            fillRect(
                out,
                c,
                @intCast(@max(0, p[0])),
                @intCast(@max(0, p[1])),
                @intCast(@max(0, p[0] + w)),
                @intCast(@max(0, p[1] + w)),
                255,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Powerline U+E0B0..U+E0BF (port of powerline.zig)
// ---------------------------------------------------------------------------

/// Port of drawE0B4: filled round separator. The bulge is two cubic
/// Beziers approximating quarter circles of radius min(w, h/2) (kappa
/// coefficient c = (sqrt(2)-1)*4/3), joined by a vertical segment; the
/// left edge is the flat side. NOTE: the bulge reaches the right edge
/// only when w <= h/2.
const RoundCap = struct {
    pts: [1 + bezier_steps + 1 + bezier_steps][2]f64,

    fn init(c: Cell) RoundCap {
        const kappa: f64 = (std.math.sqrt2 - 1.0) * 4.0 / 3.0;
        const radius = @min(c.fw, c.fh / 2);
        var self: RoundCap = .{ .pts = undefined };
        self.pts[0] = .{ 0, 0 };
        flattenCubic(
            self.pts[1 .. 1 + bezier_steps],
            .{ 0, 0 },
            .{ radius * kappa, 0 },
            .{ radius, radius - radius * kappa },
            .{ radius, radius },
        );
        self.pts[1 + bezier_steps] = .{ radius, c.fh - radius };
        flattenCubic(
            self.pts[2 + bezier_steps .. 2 + 2 * bezier_steps],
            .{ radius, c.fh - radius },
            .{ radius, c.fh - radius + radius * kappa },
            .{ radius * kappa, c.fh },
            .{ 0, c.fh },
        );
        return self;
    }

    fn inside(self: RoundCap, px: f64, py: f64) bool {
        const poly = Poly{ .verts = &self.pts };
        return poly.inside(px, py);
    }
};

/// Port of drawE0B5: outline of the round separator as an INNER stroke of
/// the open path (0,0) -> (1,0) -> bulge -> (1,h) -> (0,h), stroke width
/// box_thickness. The band lies on the interior side of the path.
const RoundCapOutline = struct {
    pts: [2 + bezier_steps + 1 + bezier_steps + 1][2]f64,
    thick: f64,

    fn init(c: Cell) RoundCapOutline {
        const kappa: f64 = (std.math.sqrt2 - 1.0) * 4.0 / 3.0;
        const radius = @min(c.fw, c.fh / 2);
        var self: RoundCapOutline = .{ .pts = undefined, .thick = @floatFromInt(box_thickness) };
        self.pts[0] = .{ 0, 0 };
        self.pts[1] = .{ 1, 0 };
        flattenCubic(
            self.pts[2 .. 2 + bezier_steps],
            .{ 1, 0 },
            .{ radius * kappa, 0 },
            .{ radius, radius - radius * kappa },
            .{ radius, radius },
        );
        self.pts[2 + bezier_steps] = .{ radius, c.fh - radius };
        flattenCubic(
            self.pts[3 + bezier_steps .. 3 + 2 * bezier_steps],
            .{ radius, c.fh - radius },
            .{ radius, c.fh - radius + radius * kappa },
            .{ radius * kappa, c.fh },
            .{ 1, c.fh },
        );
        self.pts[3 + 2 * bezier_steps] = .{ 0, c.fh };
        return self;
    }

    fn inside(self: RoundCapOutline, px: f64, py: f64) bool {
        const stroke = PolyInnerStroke{ .pts = &self.pts, .thick = self.thick };
        return stroke.inside(px, py);
    }
};

/// Port of powerline.drawE0B0..drawE0BF.
pub fn drawPowerline(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0xE0B0 => raster(out, c, Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.cy, .cx = 0, .cy = c.fh }, Tri.inside),
        0xE0B1 => {
            // Chevron outline: stroked path (0,0) -> (w,h/2) -> (0,h),
            // butt caps. The miter join at the tip lies outside the cell.
            const t: f64 = @floatFromInt(c.light);
            rasterMax(out, c, Segment.init(0, 0, c.fw, c.cy, t), Segment.inside);
            rasterMax(out, c, Segment.init(c.fw, c.cy, 0, c.fh, t), Segment.inside);
        },
        0xE0B2 => raster(out, c, Tri{ .ax = c.fw, .ay = 0, .bx = 0, .by = c.cy, .cx = c.fw, .cy = c.fh }, Tri.inside),
        0xE0B3 => {
            const t: f64 = @floatFromInt(c.light);
            rasterMax(out, c, Segment.init(c.fw, 0, 0, c.cy, t), Segment.inside);
            rasterMax(out, c, Segment.init(0, c.cy, c.fw, c.fh, t), Segment.inside);
        },
        0xE0B4 => raster(out, c, RoundCap.init(c), RoundCap.inside),
        0xE0B5 => raster(out, c, RoundCapOutline.init(c), RoundCapOutline.inside),
        0xE0B6 => raster(out, c, Flip(RoundCap){ .inner = RoundCap.init(c), .fw = c.fw }, Flip(RoundCap).inside),
        0xE0B7 => raster(out, c, Flip(RoundCapOutline){ .inner = RoundCapOutline.init(c), .fw = c.fw }, Flip(RoundCapOutline).inside),
        0xE0B8 => raster(out, c, Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.fh, .cx = 0, .cy = c.fh }, Tri.inside),
        0xE0B9 => lightDiagonalUpperLeftToLowerRight(out, c),
        0xE0BA => raster(out, c, Tri{ .ax = c.fw, .ay = 0, .bx = c.fw, .by = c.fh, .cx = 0, .cy = c.fh }, Tri.inside),
        0xE0BB => lightDiagonalUpperRightToLowerLeft(out, c),
        0xE0BC => raster(out, c, Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = 0, .cx = 0, .cy = c.fh }, Tri.inside),
        0xE0BD => lightDiagonalUpperRightToLowerLeft(out, c),
        0xE0BE => raster(out, c, Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = 0, .cx = c.fw, .cy = c.fh }, Tri.inside),
        0xE0BF => lightDiagonalUpperLeftToLowerRight(out, c),
        else => unreachable,
    }
}

/// U+E0A0..U+E0A3: NOT sprite-drawn by ghostty v1.4.0 (font glyphs there).
/// kmshaunt keeps its own code-drawn versions so these ranges stay
/// sprite-covered; geometry is unchanged from the previous kmshaunt
/// implementation.
pub fn drawPowerlineExtras(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0xE0A0 => {
            // Branch: vertical stem at 1/4 width with a diagonal branch
            // to the right edge at mid height, plus a small node circle.
            const x = c.fw / 4.0;
            const stem = Segment.init(x, 0, x, c.fh, @floatFromInt(c.light));
            rasterMax(out, c, stem, Segment.inside);
            const branch = Segment.init(x, c.fh / 2.0, c.fw, c.fh / 4.0, @floatFromInt(c.light));
            rasterMax(out, c, branch, Segment.inside);
            const node = Disk{ .cx = x, .cy = c.fh / 4.0, .r = @max(1.0, c.fw / 8.0) };
            rasterMax(out, c, node, Disk.inside);
        },
        0xE0A1 => {
            // Lock: shackle ring over a filled body.
            const bw = c.fw * 0.6;
            const bh = c.fh * 0.4;
            const bx = (c.fw - bw) / 2.0;
            const by = c.fh * 0.55;
            fillRect(out, c, @intFromFloat(bx), @intFromFloat(by), @intFromFloat(bx + bw), @intFromFloat(@min(c.fh, by + bh)), 255);
            const ring = Ring{
                .cx = c.cx,
                .cy = by,
                .r = bw / 2.5,
                .half = @as(f64, @floatFromInt(c.light)) / 2.0,
            };
            rasterMax(out, c, ring, Ring.inside);
        },
        0xE0A2 => {
            // Column number: two vertical bars.
            const t = @as(f64, @floatFromInt(c.light));
            const x0 = c.fw / 4.0 - t / 2.0;
            const x1 = 3.0 * c.fw / 4.0 - t / 2.0;
            fillRect(out, c, @intFromFloat(@max(0, x0)), 0, @intFromFloat(@min(c.fw, x0 + t)), c.h, 255);
            fillRect(out, c, @intFromFloat(@max(0, x1)), 0, @intFromFloat(@min(c.fw, x1 + t)), c.h, 255);
        },
        0xE0A3 => {
            // Current line: horizontal bar with a vertical tick.
            const t = @as(f64, @floatFromInt(c.light));
            const y = c.cy - t / 2.0;
            fillRect(out, c, 0, @intFromFloat(@max(0, y)), c.w, @intFromFloat(@min(c.fh, y + t)), 255);
            const x = c.fw * 0.75 - t / 2.0;
            fillRect(out, c, @intFromFloat(@max(0, x)), 0, @intFromFloat(@min(c.fw, x + t)), c.h, 255);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Symbols for Legacy Computing U+1FB00..U+1FBEF
// (port of symbols_for_legacy_computing.zig)
// ---------------------------------------------------------------------------

/// Port of draw1FB00_1FB3B: sextants, masks 1..62 ascending skipping 21
/// and 42; bit i lights row i/2, column i%2 of the 2x3 grid.
fn drawSextants(out: []u8, c: Cell, cp: u21) void {
    const idx: u32 = cp - 0x1FB00;
    const mask: u6 = @intCast(idx + idx / 0x14 + 1);
    if (mask & 0b000001 != 0) fill(out, c, 0, half, 0, one_third);
    if (mask & 0b000010 != 0) fill(out, c, half, 1, 0, one_third);
    if (mask & 0b000100 != 0) fill(out, c, 0, half, one_third, two_thirds);
    if (mask & 0b001000 != 0) fill(out, c, half, 1, one_third, two_thirds);
    if (mask & 0b010000 != 0) fill(out, c, 0, half, two_thirds, 1);
    if (mask & 0b100000 != 0) fill(out, c, half, 1, two_thirds, 1);
}

/// Smooth mosaic patterns (port of the SmoothMosaic.from lookup table).
/// Each pattern is 4 rows x 3 columns joined with '\n' (15 chars); only
/// '#' marks a filled lattice site. Rows sit at y = 0, h/3, 2h/3, h.
const mosaic_patterns = [44]*const [15:0]u8{
    "...\n...\n#..\n##.", // U+1FB3C
    "...\n...\n#\\.\n###", // U+1FB3D
    "...\n#..\n#\\.\n##.", // U+1FB3E
    "...\n#..\n##.\n###", // U+1FB3F
    "#..\n#..\n##.\n##.", // U+1FB40
    "/##\n###\n###\n###", // U+1FB41
    "./#\n###\n###\n###", // U+1FB42
    ".##\n.##\n###\n###", // U+1FB43
    "..#\n.##\n###\n###", // U+1FB44
    ".##\n.##\n.##\n###", // U+1FB45
    "...\n./#\n###\n###", // U+1FB46
    "...\n...\n..#\n.##", // U+1FB47
    "...\n...\n./#\n###", // U+1FB48
    "...\n..#\n./#\n.##", // U+1FB49
    "...\n..#\n.##\n###", // U+1FB4A
    "..#\n..#\n.##\n.##", // U+1FB4B
    "##\\\n###\n###\n###", // U+1FB4C
    "#\\.\n###\n###\n###", // U+1FB4D
    "##.\n##.\n###\n###", // U+1FB4E
    "#..\n##.\n###\n###", // U+1FB4F
    "##.\n##.\n##.\n###", // U+1FB50
    "...\n#\\.\n###\n###", // U+1FB51
    "###\n###\n###\n\\##", // U+1FB52
    "###\n###\n###\n.\\#", // U+1FB53
    "###\n###\n.##\n.##", // U+1FB54
    "###\n###\n.##\n..#", // U+1FB55
    "###\n.##\n.##\n.##", // U+1FB56
    "##.\n#..\n...\n...", // U+1FB57
    "###\n#/.\n...\n...", // U+1FB58
    "##.\n#/.\n#..\n...", // U+1FB59
    "###\n##.\n#..\n...", // U+1FB5A
    "##.\n##.\n#..\n#..", // U+1FB5B
    "###\n###\n#/.\n...", // U+1FB5C
    "###\n###\n###\n##/", // U+1FB5D
    "###\n###\n###\n#/.", // U+1FB5E
    "###\n###\n##.\n##.", // U+1FB5F
    "###\n###\n##.\n#..", // U+1FB60
    "###\n##.\n##.\n##.", // U+1FB61
    ".##\n..#\n...\n...", // U+1FB62
    "###\n.\\#\n...\n...", // U+1FB63
    ".##\n.\\#\n..#\n...", // U+1FB64
    "###\n.##\n..#\n...", // U+1FB65
    ".##\n.##\n..#\n..#", // U+1FB66
    "###\n###\n.\\#\n...", // U+1FB67
};

/// Port of draw1FB3C_1FB67: build the outline from the pattern's lattice
/// sites. Corner/edge sites are always included when filled; the middle
/// sites (ul/ll/bc/lr/ur/tc) are included only when the outline actually
/// bends there (the collinearity conditions in SmoothMosaic.from).
fn drawMosaic(out: []u8, c: Cell, cp: u21) void {
    const p = mosaic_patterns[cp - 0x1FB3C];
    const tl = p[0] == '#';
    const ul = p[4] == '#' and (p[0] != '#' or p[8] != '#');
    const ll = p[8] == '#' and (p[4] != '#' or p[12] != '#');
    const bl = p[12] == '#';
    const bc = p[13] == '#' and (p[12] != '#' or p[14] != '#');
    const br = p[14] == '#';
    const lr = p[10] == '#' and (p[14] != '#' or p[6] != '#');
    const ur = p[6] == '#' and (p[10] != '#' or p[2] != '#');
    const tr = p[2] == '#';
    const tc = p[1] == '#' and (p[2] != '#' or p[0] != '#');

    const upper = one_third * c.fh;
    const lower = two_thirds * c.fh;
    const center = half * c.fw;

    var verts: [10][2]f64 = undefined;
    var n: usize = 0;
    if (tl) {
        verts[n] = .{ 0, 0 };
        n += 1;
    }
    if (ul) {
        verts[n] = .{ 0, upper };
        n += 1;
    }
    if (ll) {
        verts[n] = .{ 0, lower };
        n += 1;
    }
    if (bl) {
        verts[n] = .{ 0, c.fh };
        n += 1;
    }
    if (bc) {
        verts[n] = .{ center, c.fh };
        n += 1;
    }
    if (br) {
        verts[n] = .{ c.fw, c.fh };
        n += 1;
    }
    if (lr) {
        verts[n] = .{ c.fw, lower };
        n += 1;
    }
    if (ur) {
        verts[n] = .{ c.fw, upper };
        n += 1;
    }
    if (tr) {
        verts[n] = .{ c.fw, 0 };
        n += 1;
    }
    if (tc) {
        verts[n] = .{ center, 0 };
        n += 1;
    }
    raster(out, c, Poly{ .verts = verts[0..n] }, Poly.inside);
}

/// An edge of a cell (common.Edge).
const Edge = enum(u2) { top, left, bottom, right };

/// Port of edgeTriangle: apex at the ROUNDED cell center, base on the
/// named edge.
fn edgeTriangle(out: []u8, c: Cell, edge: Edge) void {
    const middle = @round(c.fh / 2);
    const center = @round(c.fw / 2);
    const tri = switch (edge) {
        .top => Tri{ .ax = center, .ay = middle, .bx = c.fw, .by = 0, .cx = 0, .cy = 0 },
        .left => Tri{ .ax = center, .ay = middle, .bx = 0, .by = 0, .cx = 0, .cy = c.fh },
        .bottom => Tri{ .ax = center, .ay = middle, .bx = 0, .by = c.fh, .cx = c.fw, .cy = c.fh },
        .right => Tri{ .ax = center, .ay = middle, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
    };
    raster(out, c, tri, Tri.inside);
}

/// Port of draw1FB68_1FB6F: edge triangles, first four inverted.
fn drawEdgeTriangles(out: []u8, c: Cell, cp: u21) void {
    const idx = cp - 0x1FB68;
    const edge: Edge = switch (idx % 4) {
        0 => .left,
        1 => .top,
        2 => .right,
        3 => .bottom,
        else => unreachable,
    };
    edgeTriangle(out, c, edge);
    if (idx < 4) invert(out);
}

/// Port of draw1FB70_1FB75 / draw1FB76_1FB7B / draw1FB7C_1FB97.
fn drawLegacyBlocks(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FB70...0x1FB75 => {
            const n = cp + 1 - 0x1FB70;
            const e = [9]f64{ 0, one_eighth, one_quarter, three_eighths, half, five_eighths, three_quarters, seven_eighths, 1 };
            fill(out, c, e[n], e[n + 1], 0, 1);
        },
        0x1FB76...0x1FB7B => {
            const n = cp + 1 - 0x1FB76;
            const e = [9]f64{ 0, one_eighth, one_quarter, three_eighths, half, five_eighths, three_quarters, seven_eighths, 1 };
            fill(out, c, 0, 1, e[n], e[n + 1]);
        },
        0x1FB7C => {
            block(out, c, .left, .middle, one_eighth, 1);
            block(out, c, .center, .bottom, 1, one_eighth);
        },
        0x1FB7D => {
            block(out, c, .left, .middle, one_eighth, 1);
            block(out, c, .center, .top, 1, one_eighth);
        },
        0x1FB7E => {
            block(out, c, .right, .middle, one_eighth, 1);
            block(out, c, .center, .top, 1, one_eighth);
        },
        0x1FB7F => {
            block(out, c, .right, .middle, one_eighth, 1);
            block(out, c, .center, .bottom, 1, one_eighth);
        },
        0x1FB80 => {
            block(out, c, .center, .top, 1, one_eighth);
            block(out, c, .center, .bottom, 1, one_eighth);
        },
        0x1FB81 => {
            // Horizontal one eighth blocks 1, 3, 5, 8.
            const e = [9]f64{ 0, one_eighth, one_quarter, three_eighths, half, five_eighths, three_quarters, seven_eighths, 1 };
            fill(out, c, 0, 1, e[0], e[1]);
            fill(out, c, 0, 1, e[2], e[3]);
            fill(out, c, 0, 1, e[4], e[5]);
            fill(out, c, 0, 1, e[7], e[8]);
        },
        0x1FB82 => block(out, c, .center, .top, 1, one_quarter),
        0x1FB83 => block(out, c, .center, .top, 1, three_eighths),
        0x1FB84 => block(out, c, .center, .top, 1, five_eighths),
        0x1FB85 => block(out, c, .center, .top, 1, three_quarters),
        0x1FB86 => block(out, c, .center, .top, 1, seven_eighths),
        0x1FB87 => block(out, c, .right, .middle, one_quarter, 1),
        0x1FB88 => block(out, c, .right, .middle, three_eighths, 1),
        0x1FB89 => block(out, c, .right, .middle, five_eighths, 1),
        0x1FB8A => block(out, c, .right, .middle, three_quarters, 1),
        0x1FB8B => block(out, c, .right, .middle, seven_eighths, 1),
        0x1FB8C => blockShade(out, c, .left, .middle, half, 1, .medium),
        0x1FB8D => blockShade(out, c, .right, .middle, half, 1, .medium),
        0x1FB8E => blockShade(out, c, .center, .top, 1, half, .medium),
        0x1FB8F => blockShade(out, c, .center, .bottom, 1, half, .medium),
        0x1FB90 => fullBlockShade(out, c, .medium),
        0x1FB91 => {
            fullBlockShade(out, c, .medium);
            block(out, c, .center, .top, 1, half);
        },
        0x1FB92 => {
            fullBlockShade(out, c, .medium);
            block(out, c, .center, .bottom, 1, half);
        },
        0x1FB93 => {}, // unassigned hole in the block: blank
        0x1FB94 => {
            fullBlockShade(out, c, .medium);
            block(out, c, .right, .middle, half, 1);
        },
        0x1FB95 => checkerboardFill(out, c, 0),
        0x1FB96 => checkerboardFill(out, c, 1),
        0x1FB97 => {
            // Integer quarter rows (ghostty uses height / 4 directly).
            fillRect(out, c, 0, c.h / 4, c.w, 2 * c.h / 4, 255);
            fillRect(out, c, 0, 3 * c.h / 4, c.w, c.h, 255);
        },
        else => unreachable,
    }
}

/// Port of checkerboardFill: 4 columns, round(4 * h/w) rows so the squares
/// stay approximately square.
fn checkerboardFill(out: []u8, c: Cell, parity: u1) void {
    const x_size: u32 = 4;
    var y_size: u32 = @intFromFloat(@round(4 * (c.fh / c.fw)));
    if (y_size == 0) y_size = 1; // degenerate cell (ghostty would divide by 0)
    var x: u32 = 0;
    while (x < x_size) : (x += 1) {
        const x0 = c.w * x / x_size;
        const x1 = c.w * (x + 1) / x_size;
        var y: u32 = 0;
        while (y < y_size) : (y += 1) {
            const y0 = c.h * y / y_size;
            const y1 = c.h * (y + 1) / y_size;
            if ((x + y) % 2 == parity) fillRect(out, c, x0, y0, x1, y1, 255);
        }
    }
}

/// Port of draw1FB98 / draw1FB99: diagonal hatch fill.
fn drawDiagonalFill(out: []u8, c: Cell, upper_left_to_lower_right: bool) void {
    const thick_px = c.light;
    // ghostty divides by zero when the cell is narrower than 2*thick;
    // keep one line there instead of crashing.
    const line_count = @max(1, c.w / (2 * thick_px));
    const stride = @round(c.fw / @as(f64, @floatFromInt(line_count)));
    var i: i64 = -@as(i64, @intCast(line_count));
    const end: i64 = @intCast(line_count + 1);
    while (i < end) : (i += 1) {
        const off = @as(f64, @floatFromInt(i)) * stride;
        const seg = if (upper_left_to_lower_right)
            Segment.init(off, 0, c.fw + off, c.fh, @floatFromInt(thick_px))
        else
            Segment.init(c.fw + off, 0, off, c.fh, @floatFromInt(thick_px));
        rasterMax(out, c, seg, Segment.inside);
    }
}

/// Port of geo.cornerTriangleShade (geometric_shapes.zig vertex layout).
fn cornerTriangleShade(out: []u8, c: Cell, corner: Corner, shade: Shade) void {
    const tri = switch (corner) {
        .tl => Tri{ .ax = 0, .ay = 0, .bx = 0, .by = c.fh, .cx = c.fw, .cy = 0 },
        .tr => Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
        .bl => Tri{ .ax = 0, .ay = 0, .bx = 0, .by = c.fh, .cx = c.fw, .cy = c.fh },
        .br => Tri{ .ax = 0, .ay = c.fh, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
    };
    rasterShaded(out, c, tri, Tri.inside, @intFromEnum(shade));
}

/// Port of draw1FB9A_1FB9F.
fn drawLegacyShades(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FB9A => {
            edgeTriangle(out, c, .top);
            edgeTriangle(out, c, .bottom);
        },
        0x1FB9B => {
            edgeTriangle(out, c, .left);
            edgeTriangle(out, c, .right);
        },
        0x1FB9C => cornerTriangleShade(out, c, .tl, .medium),
        0x1FB9D => cornerTriangleShade(out, c, .tr, .medium),
        0x1FB9E => cornerTriangleShade(out, c, .br, .medium),
        0x1FB9F => cornerTriangleShade(out, c, .bl, .medium),
        else => unreachable,
    }
}

/// Port of cornerDiagonalLines: lines from the (integer, rounded-up) edge
/// midpoints to the cell corners, light thickness.
fn cornerDiagonalLines(out: []u8, c: Cell, tl: bool, tr: bool, bl: bool, br: bool) void {
    const t: f64 = @floatFromInt(c.light);
    const center_x: f64 = @floatFromInt(c.w / 2 + c.w % 2);
    const center_y: f64 = @floatFromInt(c.h / 2 + c.h % 2);
    if (tl) rasterMax(out, c, Segment.init(center_x, 0, 0, center_y, t), Segment.inside);
    if (tr) rasterMax(out, c, Segment.init(center_x, 0, c.fw, center_y, t), Segment.inside);
    if (bl) rasterMax(out, c, Segment.init(center_x, c.fh, 0, center_y, t), Segment.inside);
    if (br) rasterMax(out, c, Segment.init(center_x, c.fh, c.fw, center_y, t), Segment.inside);
}

/// Port of draw1FBA0_1FBAE: corner diagonal combinations, bit order
/// tl=1, tr=2, bl=4, br=8.
fn drawCornerDiagonals(out: []u8, c: Cell, cp: u21) void {
    const quads = [15]u4{ 1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15 };
    const q = quads[cp - 0x1FBA0];
    cornerDiagonalLines(out, c, q & 1 != 0, q & 2 != 0, q & 4 != 0, q & 8 != 0);
}

/// Alignment of a figure within a cell (common.Alignment subset used by
/// cellDiagonal).
const Alignment = enum {
    upper_left,
    upper_center,
    upper_right,
    middle_left,
    middle_center,
    middle_right,
    lower_left,
    lower_center,
    lower_right,

    fn xy(self: Alignment, c: Cell) [2]f64 {
        const x: f64 = switch (self) {
            .upper_left, .middle_left, .lower_left => 0,
            .upper_center, .middle_center, .lower_center => c.fw / 2,
            .upper_right, .middle_right, .lower_right => c.fw,
        };
        const y: f64 = switch (self) {
            .upper_left, .upper_center, .upper_right => 0,
            .middle_left, .middle_center, .middle_right => c.fh / 2,
            .lower_left, .lower_center, .lower_right => c.fh,
        };
        return .{ x, y };
    }
};

/// Port of cellDiagonal: light line between two aligned points.
fn cellDiagonal(out: []u8, c: Cell, from: Alignment, to: Alignment) void {
    const p0 = from.xy(c);
    const p1 = to.xy(c);
    rasterMax(out, c, Segment.init(p0[0], p0[1], p1[0], p1[1], @floatFromInt(c.light)), Segment.inside);
}

/// Port of draw1FBD0_1FBDF.
fn drawCellDiagonals(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FBD0 => cellDiagonal(out, c, .middle_right, .lower_left),
        0x1FBD1 => cellDiagonal(out, c, .upper_right, .middle_left),
        0x1FBD2 => cellDiagonal(out, c, .upper_left, .middle_right),
        0x1FBD3 => cellDiagonal(out, c, .middle_left, .lower_right),
        0x1FBD4 => cellDiagonal(out, c, .upper_left, .lower_center),
        0x1FBD5 => cellDiagonal(out, c, .upper_center, .lower_right),
        0x1FBD6 => cellDiagonal(out, c, .upper_right, .lower_center),
        0x1FBD7 => cellDiagonal(out, c, .upper_center, .lower_left),
        0x1FBD8 => {
            cellDiagonal(out, c, .upper_left, .middle_center);
            cellDiagonal(out, c, .middle_center, .upper_right);
        },
        0x1FBD9 => {
            cellDiagonal(out, c, .upper_right, .middle_center);
            cellDiagonal(out, c, .middle_center, .lower_right);
        },
        0x1FBDA => {
            cellDiagonal(out, c, .lower_left, .middle_center);
            cellDiagonal(out, c, .middle_center, .lower_right);
        },
        0x1FBDB => {
            cellDiagonal(out, c, .upper_left, .middle_center);
            cellDiagonal(out, c, .middle_center, .lower_left);
        },
        0x1FBDC => {
            cellDiagonal(out, c, .upper_left, .lower_center);
            cellDiagonal(out, c, .lower_center, .upper_right);
        },
        0x1FBDD => {
            cellDiagonal(out, c, .upper_right, .middle_left);
            cellDiagonal(out, c, .middle_left, .lower_right);
        },
        0x1FBDE => {
            cellDiagonal(out, c, .lower_left, .upper_center);
            cellDiagonal(out, c, .upper_center, .lower_right);
        },
        0x1FBDF => {
            cellDiagonal(out, c, .upper_left, .middle_right);
            cellDiagonal(out, c, .middle_right, .lower_left);
        },
        else => unreachable,
    }
}

/// Port of circle: radius min(w,h)/2 at an edge midpoint or corner;
/// outline strokes the arc at r - line_width/2 (so the outer edge of the
/// stroke sits at r), filled draws the full disk.
fn circle(out: []u8, c: Cell, x: f64, y: f64, filled: bool) void {
    const r = 0.5 * @min(c.fw, c.fh);
    const t: f64 = @floatFromInt(c.light);
    if (filled) {
        raster(out, c, Disk{ .cx = x, .cy = y, .r = r }, Disk.inside);
    } else {
        raster(out, c, Ring{ .cx = x, .cy = y, .r = r - t / 2, .half = t / 2 }, Ring.inside);
    }
}

/// Port of draw1FBE0_1FBEF.
fn drawCirclesAndBlocks(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FBE0 => circle(out, c, c.fw / 2, 0, false),
        0x1FBE1 => circle(out, c, c.fw, c.fh / 2, false),
        0x1FBE2 => circle(out, c, c.fw / 2, c.fh, false),
        0x1FBE3 => circle(out, c, 0, c.fh / 2, false),
        0x1FBE4 => block(out, c, .center, .top, 0.5, 0.5),
        0x1FBE5 => block(out, c, .center, .bottom, 0.5, 0.5),
        0x1FBE6 => block(out, c, .left, .middle, 0.5, 0.5),
        0x1FBE7 => block(out, c, .right, .middle, 0.5, 0.5),
        0x1FBE8 => circle(out, c, c.fw / 2, 0, true),
        0x1FBE9 => circle(out, c, c.fw, c.fh / 2, true),
        0x1FBEA => circle(out, c, c.fw / 2, c.fh, true),
        0x1FBEB => circle(out, c, 0, c.fh / 2, true),
        0x1FBEC => circle(out, c, c.fw, 0, true),
        0x1FBED => circle(out, c, 0, c.fh, true),
        0x1FBEE => circle(out, c, c.fw, c.fh, true),
        0x1FBEF => circle(out, c, 0, 0, true),
        else => unreachable,
    }
}

/// Dispatch for U+1FB00..U+1FBEF (the codepoints ghostty sprite-draws in
/// this block; the holes 1FBB0-1FBBC / 1FBC0-1FBCD / 1FBF0+ are font
/// glyphs, see isSprite).
pub fn drawLegacy(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FB00...0x1FB3B => drawSextants(out, c, cp),
        0x1FB3C...0x1FB67 => drawMosaic(out, c, cp),
        0x1FB68...0x1FB6F => drawEdgeTriangles(out, c, cp),
        0x1FB70...0x1FB97 => drawLegacyBlocks(out, c, cp),
        0x1FB98 => drawDiagonalFill(out, c, true),
        0x1FB99 => drawDiagonalFill(out, c, false),
        0x1FB9A...0x1FB9F => drawLegacyShades(out, c, cp),
        0x1FBA0...0x1FBAE => drawCornerDiagonals(out, c, cp),
        0x1FBAF => linesChar(out, c, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),
        0x1FBBD => {
            lightDiagonalCross(out, c);
            invert(out);
        },
        0x1FBBE => {
            cornerDiagonalLines(out, c, false, false, false, true);
            invert(out);
        },
        0x1FBBF => {
            cornerDiagonalLines(out, c, true, true, true, true);
            invert(out);
        },
        0x1FBCE => block(out, c, .left, .middle, two_thirds, 1),
        0x1FBCF => block(out, c, .left, .middle, one_third, 1),
        0x1FBD0...0x1FBDF => drawCellDiagonals(out, c, cp),
        0x1FBE0...0x1FBEF => drawCirclesAndBlocks(out, c, cp),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Octants U+1CD00..U+1CDE5 (port of symbols_for_legacy_computing_supplement.zig)
// ---------------------------------------------------------------------------

/// Octant masks in codepoint order, from the Unicode 16 names
/// (BLOCK OCTANT-<digits>): bit i lights octant i+1 of a 2x4 row-major
/// grid. Verified identical to ghostty's draw/octants.txt.
const octants = [230]u8{
    4, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18, 19, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
    57, 58, 59, 60, 61, 62, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
    75, 76, 77, 78, 79, 81, 82, 83, 84, 86, 87, 88, 89, 91, 92, 93,
    94, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126,
    127, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    161, 162, 163, 164, 166, 167, 168, 169, 171, 172, 173, 174, 176, 177, 178, 179,
    180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 193, 194, 195, 196,
    197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
    213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228,
    229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 241, 242, 243, 244, 246,
    247, 248, 249, 251, 253, 254,
};

/// Port of draw1CD00_1CDE5.
pub fn drawOctants(out: []u8, c: Cell, cp: u21) void {
    const mask = octants[cp - 0x1CD00];
    if (mask & 0b00000001 != 0) fill(out, c, 0, half, 0, one_quarter);
    if (mask & 0b00000010 != 0) fill(out, c, half, 1, 0, one_quarter);
    if (mask & 0b00000100 != 0) fill(out, c, 0, half, one_quarter, half);
    if (mask & 0b00001000 != 0) fill(out, c, half, 1, one_quarter, half);
    if (mask & 0b00010000 != 0) fill(out, c, 0, half, half, three_quarters);
    if (mask & 0b00100000 != 0) fill(out, c, half, 1, half, three_quarters);
    if (mask & 0b01000000 != 0) fill(out, c, 0, half, three_quarters, 1);
    if (mask & 0b10000000 != 0) fill(out, c, half, 1, three_quarters, 1);
}
