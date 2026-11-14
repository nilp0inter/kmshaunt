//! src/font/sprite.zig -- code-drawn cell sprites (ROADMAP M3.6, solves R1
//! pixel-exact box drawing).
//!
//! Sprites are rasterized here instead of being taken from a font so that
//! lines join EXACTLY across cell boundaries:
//!
//!   * Every edge-touching stroke is drawn all the way to the boundary
//!     pixel (x = 0 / x = w-1, y = 0 / y = h-1).
//!   * Stems are centered with integer math: a stroke of thickness t spans
//!     [(size - t) / 2, (size - t) / 2 + t). Light thickness is
//!     max(1, round(w/8)), heavy is 2x light, double lines are two parallel
//!     light stems separated by a light-width gap. Because the placement
//!     depends only on the cell size, adjacent cells produce identical
//!     active rows/columns at the shared edge.
//!   * Fractional sub-rects (sextants, octants, block fractions) use
//!     complementary rounding: a boundary at fraction f is placed at
//!     size - round((1-f)*size) when it is a min coordinate and at
//!     round(f*size) when it is a max coordinate. Sub-rects therefore
//!     partition the cell with no gap and no overlap.
//!   * Diagonals, triangles, arcs and circles are antialiased by 4x4
//!     supersampling of a coverage function.
//!
//! No allocation: `renderSprite` writes row-major 8-bit coverage (0..255)
//! into a caller-provided buffer of exactly w*h bytes.
//!
//! Bit orders (documented per family, all verified against Unicode 16
//! character names):
//!
//!   * Sextants U+1FB00..U+1FB3B: 2 columns x 3 rows, numbered row-major
//!     1..6 (1 top-left, 2 top-right, 3 mid-left, 4 mid-right, 5
//!     bottom-left, 6 bottom-right). Bit i of the mask lights sextant
//!     i+1. The mask is idx + idx/20 + 1 with idx = cp - 0x1FB00: the
//!     block enumerates masks 1..62 in ascending order, skipping 21 and
//!     42 (full left/right columns, already in Block Elements).
//!     U+1FB00 = top-left sextant.
//!   * Octants U+1CD00..U+1CDE5: 2 columns x 4 rows, numbered row-major
//!     1..8. Bit i lights octant i+1. The block enumerates the remaining
//!     masks in ascending order; the lookup table below is taken from the
//!     Unicode 16 names (BLOCK OCTANT-<digits>).
//!   * Braille U+2800..U+28FF: mask = cp - 0x2800. Bits 0..2 are the left
//!     column top to bottom, bits 3..5 the right column top to bottom,
//!     bit 6 bottom-left, bit 7 bottom-right.
//!   * Smooth mosaics U+1FB3C..U+1FB67: each codepoint is one outline from
//!     the reference "block diagonal" designs, stored as a small polygon on
//!     a lattice of thirds plus the centre lines (x,y in sixths of the
//!     cell). The diagonal is a straight edge, not a staircase. The block
//!     pairs up: every shape in U+1FB3C..U+1FB51 and its complement
//!     U+16 further up partition the cell.

const std = @import("std");

/// Supersampling factor per axis for antialiased shapes (4x4 = 16 samples).
const ss: u32 = 4;

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// True if `cp` is drawn by this module instead of a font face.
pub fn isSprite(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => true, // Box Drawing
        0x2580...0x259F => true, // Block Elements
        0x2800...0x28FF => true, // Braille Patterns
        0xE0A0...0xE0A3 => true, // Powerline branch/lock/column symbols
        0xE0B0...0xE0BF => true, // Powerline separators + extra diagonals
        0x1FB00...0x1FB3B => true, // sextants
        0x1FB3C...0x1FB6F => true, // smooth mosaics + edge triangles
        0x1FB70...0x1FB8B => true, // eighth/quarter blocks
        0x1FB8C...0x1FB9F => true, // half shades + checkerboards
        0x1CD00...0x1CDE5 => true, // octants (Unicode 16 supplement)
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/// Cell geometry shared by all draw functions. Coordinates are pixels;
/// `cx`/`cy` are the (float) cell centers used by antialiased shapes.
const Cell = struct {
    w: u32,
    h: u32,
    fw: f64,
    fh: f64,
    cx: f64,
    cy: f64,
    light: u32,
    heavy: u32,

    fn init(w: u32, h: u32) Cell {
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        const light = @max(1, @as(u32, @intFromFloat(@round(fw / 8.0))));
        return .{
            .w = w,
            .h = h,
            .fw = fw,
            .fh = fh,
            .cx = fw / 2.0,
            .cy = fh / 2.0,
            .light = light,
            .heavy = 2 * light,
        };
    }
};

/// Min coordinate of a fractional boundary; complementary to `fracMax`
/// so that adjacent sub-rects share the exact same boundary pixel column.
fn fracMin(size: u32, num: u32, den: u32) u32 {
    const s: f64 = @floatFromInt(size);
    const f = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    return @intFromFloat(s - @round((1.0 - f) * s));
}

/// Max coordinate of a fractional boundary.
fn fracMax(size: u32, num: u32, den: u32) u32 {
    const s: f64 = @floatFromInt(size);
    const f = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    return @intFromFloat(@round(f * s));
}

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

/// Fill the sub-rect between fractional boundaries (nx0/den .. nx1/den
/// horizontally, ny0/den .. ny1/den vertically).
fn fillFrac(out: []u8, c: Cell, nx0: u32, nx1: u32, ny0: u32, ny1: u32, den: u32, alpha: u8) void {
    fillFracXY(out, c, nx0, nx1, ny0, ny1, den, den, alpha);
}

/// `fillFrac` with independent horizontal and vertical denominators. The
/// 2x3 sextant and 2x4 octant grids partition x and y differently, so a
/// single shared denominator would place their shared edges in the wrong
/// column (gaps between sub-rects).
fn fillFracXY(out: []u8, c: Cell, nx0: u32, nx1: u32, ny0: u32, ny1: u32, denx: u32, deny: u32, alpha: u8) void {
    fillRect(
        out,
        c,
        fracMin(c.w, nx0, denx),
        fracMin(c.h, ny0, deny),
        fracMax(c.w, nx1, denx),
        fracMax(c.h, ny1, deny),
        alpha,
    );
}

/// Rasterize a coverage function with 4x4 supersampling. `inside` is
/// evaluated at sample centers in pixel coordinates.
fn raster(out: []u8, c: Cell, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f64, f64) bool) void {
    rasterShaded(out, c, ctx, inside, 255);
}

/// `raster` with the resulting coverage scaled by `alpha` (shaded shapes:
/// the triangular medium-shade blocks are 50% coverage, not a dither).
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
                const a: u8 = @intCast(n * 255 / (ss * ss));
                const p = &out[y * c.w + x];
                p.* = @max(p.*, a);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Antialiased shape contexts
// ---------------------------------------------------------------------------

/// Thick line segment with butt caps; endpoints may overshoot the cell so
/// corner-touching diagonals reach the boundary pixels.
const Segment = struct {
    x0: f64,
    y0: f64,
    dx: f64,
    dy: f64,
    len2: f64,
    half: f64,

    fn init(x0: f64, y0: f64, x1: f64, y1: f64, thick: f64) Segment {
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

    fn inside(self: Segment, px: f64, py: f64) bool {
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

/// Filled circle.
const Disk = struct {
    cx: f64,
    cy: f64,
    r: f64,

    fn inside(self: Disk, px: f64, py: f64) bool {
        const dx = px - self.cx;
        const dy = py - self.cy;
        return dx * dx + dy * dy <= self.r * self.r;
    }
};

/// Annulus (circle outline).
const Ring = struct {
    cx: f64,
    cy: f64,
    r: f64,
    half: f64,

    fn inside(self: Ring, px: f64, py: f64) bool {
        const dx = px - self.cx;
        const dy = py - self.cy;
        const d = @sqrt(dx * dx + dy * dy);
        return @abs(d - self.r) <= self.half;
    }
};

/// Filled Powerline round separator (U+E0B4 family): the cell filled from
/// the left edge up to a half-ellipse whose semi-axes are the cell width
/// and half its height, so the bulge touches the right edge at mid height
/// and tapers away towards the top and bottom edges. `flip` mirrors it
/// horizontally (U+E0B6).
const RoundCap = struct {
    fw: f64,
    fh: f64,
    flip: bool,

    /// Half-width of the bulge at `py`, shrunk by `inset`.
    fn bulge(self: RoundCap, inset: f64, py: f64) f64 {
        const ry = self.fh / 2.0;
        const dy = (py - ry) / ry;
        if (@abs(dy) >= 1.0) return 0;
        return @max(0.0, self.fw - inset) * @sqrt(1.0 - dy * dy);
    }

    fn inside(self: RoundCap, px_in: f64, py: f64) bool {
        const px = if (self.flip) self.fw - px_in else px_in;
        return px <= self.bulge(0, py);
    }
};

/// Outline of the round separator (U+E0B5/U+E0B7): the stroke that follows
/// the bulge, i.e. the region between the outer half-ellipse and the same
/// ellipse inset by `thickness`.
const RoundCapOutline = struct {
    cap: RoundCap,
    thickness: f64,

    fn inside(self: RoundCapOutline, px_in: f64, py: f64) bool {
        const px = if (self.cap.flip) self.cap.fw - px_in else px_in;
        return px <= self.cap.bulge(0, py) and px > self.cap.bulge(self.thickness, py);
    }
};

/// Rounded box-drawing corner (U+256D..U+2570): a quarter-arc of radius
/// r centered on the cell center, joined to the two edge midpoints.
/// `corner` selects which quadrant the arc bulges into: 0 = top-left
/// (U+256D), 1 = top-right (U+256E), 2 = bottom-left (U+2570),
/// 3 = bottom-right (U+256F).
const CornerArc = struct {
    cx: f64,
    cy: f64,
    r: f64,
    half: f64,
    corner: u2,
    fw: f64,
    fh: f64,

    fn inside(self: CornerArc, px: f64, py: f64) bool {
        const left = self.corner == 0 or self.corner == 2;
        const top = self.corner == 0 or self.corner == 1;
        // Straight stems: vertical from the top/bottom edge to the arc,
        // horizontal from the left/right edge to the arc.
        if (top) {
            if (@abs(px - self.cx) <= self.half and py <= self.cy - self.r) return true;
        } else {
            if (@abs(px - self.cx) <= self.half and py >= self.cy + self.r) return true;
        }
        if (left) {
            if (@abs(py - self.cy) <= self.half and px <= self.cx - self.r) return true;
        } else {
            if (@abs(py - self.cy) <= self.half and px >= self.cx + self.r) return true;
        }
        // Quarter arc.
        const in_quadrant = (if (left) px <= self.cx else px >= self.cx) and
            (if (top) py <= self.cy else py >= self.cy);
        if (!in_quadrant) return false;
        const dx = px - self.cx;
        const dy = py - self.cy;
        return @abs(@sqrt(dx * dx + dy * dy) - self.r) <= self.half;
    }
};

// ---------------------------------------------------------------------------
// Box Drawing U+2500..U+257F
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
/// dashes, rounded corners and diagonals, handled separately.
/// Table derived from the Unicode 16 Box Drawing block.
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

/// Draw an intersection-style box character. Geometry follows the
/// reference terminal sprite implementation: light/heavy stems centered,
/// double stems straddling the light stem positions with a light-width
/// gap, and arm termination rules that keep mixed tees/crosses joined.
fn drawLines(out: []u8, c: Cell, lines: Lines) void {
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

/// Dashed line. `count` dashes with half-sized gaps at both ends so that
/// tiling horizontally/vertically yields one consistent dashed line.
fn drawDash(out: []u8, c: Cell, horizontal: bool, count: u32, thick: u32, desired_gap: u32) void {
    const size = if (horizontal) c.w else c.h;
    if (size < count * 2) {
        // Too small for dashes: solid centered line.
        if (horizontal) {
            fillRect(out, c, 0, (c.h -| thick) / 2, c.w, (c.h -| thick) / 2 + thick, 255);
        } else {
            fillRect(out, c, (c.w -| thick) / 2, 0, (c.w -| thick) / 2 + thick, c.h, 255);
        }
        return;
    }
    const gap = @min(desired_gap, size / (2 * count));
    const total_dash = size - count * gap;
    const dash = total_dash / count;
    var extra = total_dash % count;
    // Half gap at the start; for vertical dashes the reference starts at
    // the top edge instead (better joining to solid characters).
    var pos: u32 = if (horizontal) gap / 2 else 0;
    const cross = if (horizontal) (c.h -| thick) / 2 else (c.w -| thick) / 2;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var len = dash;
        if (extra > 0) {
            extra -= 1;
            len += 1;
        }
        if (horizontal) {
            fillRect(out, c, pos, cross, pos + len, cross + thick, 255);
        } else {
            fillRect(out, c, cross, pos, cross + thick, pos + len, 255);
        }
        pos += len + gap;
    }
}

/// Diagonal stroke across the whole cell, overshooting the corners
/// slightly (keeping the slope) so the boundary pixels are covered.
fn drawDiagonal(out: []u8, c: Cell, upper_left_to_lower_right: bool, thick: u32) void {
    const slope_x = @min(1.0, c.fw / c.fh);
    const slope_y = @min(1.0, c.fh / c.fw);
    const seg = if (upper_left_to_lower_right)
        Segment.init(-0.5 * slope_x, -0.5 * slope_y, c.fw + 0.5 * slope_x, c.fh + 0.5 * slope_y, @floatFromInt(thick))
    else
        Segment.init(c.fw + 0.5 * slope_x, -0.5 * slope_y, -0.5 * slope_x, c.fh + 0.5 * slope_y, @floatFromInt(thick));
    rasterMax(out, c, seg, Segment.inside);
}

fn drawBox(out: []u8, c: Cell, cp: u21) void {
    const enc = box_lines[cp - 0x2500];
    if (enc != 0) {
        drawLines(out, c, decodeLines(enc));
        return;
    }
    switch (cp) {
        0x2504 => drawDash(out, c, true, 3, c.light, @max(4, c.light)),
        0x2505 => drawDash(out, c, true, 3, c.heavy, @max(4, c.light)),
        0x2506 => drawDash(out, c, false, 3, c.light, @max(4, c.light)),
        0x2507 => drawDash(out, c, false, 3, c.heavy, @max(4, c.light)),
        0x2508 => drawDash(out, c, true, 4, c.light, @max(4, c.light)),
        0x2509 => drawDash(out, c, true, 4, c.heavy, @max(4, c.light)),
        0x250A => drawDash(out, c, false, 4, c.light, @max(4, c.light)),
        0x250B => drawDash(out, c, false, 4, c.heavy, @max(4, c.light)),
        0x254C => drawDash(out, c, true, 2, c.light, c.light),
        0x254D => drawDash(out, c, true, 2, c.heavy, c.heavy),
        0x254E => drawDash(out, c, false, 2, c.light, c.heavy),
        0x254F => drawDash(out, c, false, 2, c.heavy, c.heavy),
        0x256D => drawCornerArc(out, c, 0),
        0x256E => drawCornerArc(out, c, 1),
        0x256F => drawCornerArc(out, c, 3),
        0x2570 => drawCornerArc(out, c, 2),
        0x2571 => drawDiagonal(out, c, false, c.light),
        0x2572 => drawDiagonal(out, c, true, c.light),
        0x2573 => {
            drawDiagonal(out, c, false, c.light);
            drawDiagonal(out, c, true, c.light);
        },
        else => unreachable,
    }
}

fn drawCornerArc(out: []u8, c: Cell, corner: u2) void {
    const arc = CornerArc{
        .cx = c.cx,
        .cy = c.cy,
        .r = @min(c.fw, c.fh) / 2.0,
        .half = @as(f64, @floatFromInt(c.light)) / 2.0,
        .corner = corner,
        .fw = c.fw,
        .fh = c.fh,
    };
    raster(out, c, arc, CornerArc.inside);
}

// ---------------------------------------------------------------------------
// Block Elements U+2580..U+259F
// ---------------------------------------------------------------------------

/// Fractional block anchored to one edge. `side`: 0 top, 1 bottom,
/// 2 left, 3 right. `num/8` of the cell is filled.
fn drawBlockFrac(out: []u8, c: Cell, side: u2, num: u32, alpha: u8) void {
    switch (side) {
        0 => fillFrac(out, c, 0, 8, 0, num, 8, alpha),
        1 => fillFrac(out, c, 0, 8, 8 - num, 8, 8, alpha),
        2 => fillFrac(out, c, 0, num, 0, 8, 8, alpha),
        3 => fillFrac(out, c, 8 - num, 8, 0, 8, 8, alpha),
    }
}

fn drawQuadrants(out: []u8, c: Cell, tl: bool, tr: bool, bl: bool, br: bool) void {
    if (tl) fillFrac(out, c, 0, 1, 0, 1, 2, 255);
    if (tr) fillFrac(out, c, 1, 2, 0, 1, 2, 255);
    if (bl) fillFrac(out, c, 0, 1, 1, 2, 2, 255);
    if (br) fillFrac(out, c, 1, 2, 1, 2, 2, 255);
}

fn drawBlock(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x2580 => drawBlockFrac(out, c, 0, 4, 255), // upper half
        0x2581 => drawBlockFrac(out, c, 1, 1, 255),
        0x2582 => drawBlockFrac(out, c, 1, 2, 255),
        0x2583 => drawBlockFrac(out, c, 1, 3, 255),
        0x2584 => drawBlockFrac(out, c, 1, 4, 255),
        0x2585 => drawBlockFrac(out, c, 1, 5, 255),
        0x2586 => drawBlockFrac(out, c, 1, 6, 255),
        0x2587 => drawBlockFrac(out, c, 1, 7, 255),
        0x2588 => fillRect(out, c, 0, 0, c.w, c.h, 255),
        0x2589 => drawBlockFrac(out, c, 2, 7, 255),
        0x258A => drawBlockFrac(out, c, 2, 6, 255),
        0x258B => drawBlockFrac(out, c, 2, 5, 255),
        0x258C => drawBlockFrac(out, c, 2, 4, 255),
        0x258D => drawBlockFrac(out, c, 2, 3, 255),
        0x258E => drawBlockFrac(out, c, 2, 2, 255),
        0x258F => drawBlockFrac(out, c, 2, 1, 255),
        0x2590 => drawBlockFrac(out, c, 3, 4, 255), // right half
        0x2591 => fillRect(out, c, 0, 0, c.w, c.h, 64), // light shade 25%
        0x2592 => fillRect(out, c, 0, 0, c.w, c.h, 128), // medium shade 50%
        0x2593 => fillRect(out, c, 0, 0, c.w, c.h, 192), // dark shade 75%
        0x2594 => drawBlockFrac(out, c, 0, 1, 255), // upper one eighth
        0x2595 => drawBlockFrac(out, c, 3, 1, 255), // right one eighth
        0x2596 => drawQuadrants(out, c, false, false, true, false),
        0x2597 => drawQuadrants(out, c, false, false, false, true),
        0x2598 => drawQuadrants(out, c, true, false, false, false),
        0x2599 => drawQuadrants(out, c, true, false, true, true),
        0x259A => drawQuadrants(out, c, true, false, false, true),
        0x259B => drawQuadrants(out, c, true, true, true, false),
        0x259C => drawQuadrants(out, c, true, true, false, true),
        0x259D => drawQuadrants(out, c, false, true, false, false),
        0x259E => drawQuadrants(out, c, false, true, true, false),
        0x259F => drawQuadrants(out, c, false, true, true, true),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Braille U+2800..U+28FF
// ---------------------------------------------------------------------------

fn drawBraille(out: []u8, c: Cell, cp: u21) void {
    const mask: u8 = @truncate(cp - 0x2800);
    if (mask == 0) return;

    // Dot grid: 2 columns x 4 rows. Size the dots and spacing so the
    // pattern fills the cell, preferring non-zero dot size first.
    var dot: u32 = @min(c.w / 4, c.h / 8);
    var x_spacing: u32 = c.w / 4;
    var y_spacing: u32 = c.h / 8;
    var x_margin: u32 = x_spacing / 2;
    var y_margin: u32 = y_spacing / 2;
    var x_left: i64 = @as(i64, c.w) - 2 * @as(i64, x_margin) - @as(i64, x_spacing) - 2 * @as(i64, dot);
    var y_left: i64 = @as(i64, c.h) - 2 * @as(i64, y_margin) - 3 * @as(i64, y_spacing) - 4 * @as(i64, dot);

    if (x_left >= 2 and y_left >= 4 and dot == 0) {
        dot += 1;
        x_left -= 2;
        y_left -= 4;
    }
    if (x_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_left -= 2;
    }
    if (y_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_left -= 2;
    }
    if (x_left >= 1) {
        x_spacing += 1;
        x_left -= 1;
    }
    if (y_left >= 3) {
        y_spacing += 1;
        y_left -= 3;
    }
    if (x_left >= 2) {
        x_margin += 1;
        x_left -= 2;
    }
    if (y_left >= 2) {
        y_margin += 1;
        y_left -= 2;
    }
    if (x_left >= 2 and y_left >= 4) {
        dot += 1;
    }
    if (dot == 0) dot = 1; // tiny cells: still show something

    const xs = [2]u32{ x_margin, x_margin + dot + x_spacing };
    var ys: [4]u32 = undefined;
    ys[0] = y_margin;
    ys[1] = ys[0] + dot + y_spacing;
    ys[2] = ys[1] + dot + y_spacing;
    ys[3] = ys[2] + dot + y_spacing;

    // Bit order: 0..2 left column top->bottom, 3..5 right column
    // top->bottom, 6 bottom-left, 7 bottom-right.
    const pos = [8][2]u32{
        .{ xs[0], ys[0] }, .{ xs[0], ys[1] }, .{ xs[0], ys[2] },
        .{ xs[1], ys[0] }, .{ xs[1], ys[1] }, .{ xs[1], ys[2] },
        .{ xs[0], ys[3] }, .{ xs[1], ys[3] },
    };
    for (pos, 0..) |p, i| {
        if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
            fillRect(out, c, p[0], p[1], p[0] + dot, p[1] + dot, 255);
        }
    }
}

// ---------------------------------------------------------------------------
// Powerline U+E0A0..U+E0A3, U+E0B0..U+E0BF
// ---------------------------------------------------------------------------

fn drawPowerline(out: []u8, c: Cell, cp: u21) void {
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
        0xE0B0 => {
            // Right-pointing filled triangle: full left edge, tip at the
            // right edge mid height.
            const tri = Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.cy, .cx = 0, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0B1 => {
            // Right-pointing chevron outline.
            const t = @as(f64, @floatFromInt(c.light));
            const a = Segment.init(0, 0, c.fw, c.cy, t);
            const b = Segment.init(c.fw, c.cy, 0, c.fh, t);
            rasterMax(out, c, a, Segment.inside);
            rasterMax(out, c, b, Segment.inside);
        },
        0xE0B2 => {
            // Left-pointing filled triangle.
            const tri = Tri{ .ax = c.fw, .ay = 0, .bx = 0, .by = c.cy, .cx = c.fw, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0B3 => {
            // Left-pointing chevron outline.
            const t = @as(f64, @floatFromInt(c.light));
            const a = Segment.init(c.fw, 0, 0, c.cy, t);
            const b = Segment.init(0, c.cy, c.fw, c.fh, t);
            rasterMax(out, c, a, Segment.inside);
            rasterMax(out, c, b, Segment.inside);
        },
        0xE0B4 => {
            const cap = RoundCap{ .fw = c.fw, .fh = c.fh, .flip = false };
            raster(out, c, cap, RoundCap.inside);
        },
        0xE0B5 => {
            const cap = RoundCapOutline{
                .cap = .{ .fw = c.fw, .fh = c.fh, .flip = false },
                .thickness = @floatFromInt(c.light),
            };
            raster(out, c, cap, RoundCapOutline.inside);
        },
        0xE0B6 => {
            const cap = RoundCap{ .fw = c.fw, .fh = c.fh, .flip = true };
            raster(out, c, cap, RoundCap.inside);
        },
        0xE0B7 => {
            const cap = RoundCapOutline{
                .cap = .{ .fw = c.fw, .fh = c.fh, .flip = true },
                .thickness = @floatFromInt(c.light),
            };
            raster(out, c, cap, RoundCapOutline.inside);
        },
        0xE0B8 => {
            // Lower-left triangle.
            const tri = Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.fh, .cx = 0, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0B9 => drawDiagonal(out, c, true, c.light),
        0xE0BA => {
            // Lower-right triangle.
            const tri = Tri{ .ax = c.fw, .ay = 0, .bx = c.fw, .by = c.fh, .cx = 0, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0BB => drawDiagonal(out, c, false, c.light),
        0xE0BC => {
            // Upper-left triangle.
            const tri = Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = 0, .cx = 0, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0BD => drawDiagonal(out, c, false, c.light),
        0xE0BE => {
            // Upper-right triangle.
            const tri = Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = 0, .cx = c.fw, .cy = c.fh };
            raster(out, c, tri, Tri.inside);
        },
        0xE0BF => drawDiagonal(out, c, true, c.light),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Symbols for Legacy Computing U+1FB00..U+1FB9F
// ---------------------------------------------------------------------------

/// Sextant mask: masks 1..62 ascending, skipping 21 and 42 (full columns).
fn sextantMask(cp: u21) u6 {
    const idx: u32 = cp - 0x1FB00;
    return @intCast(idx + idx / 20 + 1);
}

fn drawSextants(out: []u8, c: Cell, cp: u21) void {
    const mask = sextantMask(cp);
    // Bit i lights sextant i+1: row = i/2, col = i%2 (2x3 grid).
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        if (mask & (@as(u6, 1) << @intCast(i)) != 0) {
            const col = i % 2;
            const row = i / 2;
            fillFracXY(out, c, col, col + 1, row, row + 1, 2, 3, 255);
        }
    }
}

/// Smooth mosaic shapes U+1FB3C..U+1FB67 ("block diagonal" characters).
/// Each entry is the glyph outline as x,y pairs in sixths of the cell, so a
/// coordinate of 0, 2, 3, 4 or 6 means 0, 1/3, 1/2, 2/3 or 1 (the 1/3
/// lattice plus the centre lines named by the character names). The
/// outlines are the reference designs, so the diagonals are straight lines
/// rather than sextant staircases. Vertices are clockwise and start at any
/// corner; winding does not matter.
const mosaic_shapes = [44][]const u8{
    &.{ 0, 6, 3, 6, 0, 4 }, // U+1FB3C
    &.{ 0, 6, 6, 6, 0, 4 }, // U+1FB3D
    &.{ 0, 6, 3, 6, 0, 2 }, // U+1FB3E
    &.{ 0, 6, 6, 6, 0, 2 }, // U+1FB3F
    &.{ 0, 6, 3, 6, 0, 0 }, // U+1FB40
    &.{ 0, 6, 6, 6, 6, 0, 3, 0, 0, 2 }, // U+1FB41
    &.{ 0, 6, 6, 6, 6, 0, 0, 2 }, // U+1FB42
    &.{ 0, 6, 6, 6, 6, 0, 3, 0, 0, 4 }, // U+1FB43
    &.{ 0, 6, 6, 6, 6, 0, 0, 4 }, // U+1FB44
    &.{ 0, 6, 6, 6, 6, 0, 3, 0 }, // U+1FB45
    &.{ 0, 6, 6, 6, 6, 2, 0, 4 }, // U+1FB46
    &.{ 3, 6, 6, 6, 6, 4 }, // U+1FB47
    &.{ 0, 6, 6, 6, 6, 4 }, // U+1FB48
    &.{ 3, 6, 6, 6, 6, 2 }, // U+1FB49
    &.{ 0, 6, 6, 6, 6, 2 }, // U+1FB4A
    &.{ 3, 6, 6, 6, 6, 0 }, // U+1FB4B
    &.{ 0, 6, 6, 6, 6, 2, 3, 0, 0, 0 }, // U+1FB4C
    &.{ 0, 6, 6, 6, 6, 2, 0, 0 }, // U+1FB4D
    &.{ 0, 6, 6, 6, 6, 4, 3, 0, 0, 0 }, // U+1FB4E
    &.{ 0, 6, 6, 6, 6, 4, 0, 0 }, // U+1FB4F
    &.{ 0, 6, 6, 6, 3, 0, 0, 0 }, // U+1FB50
    &.{ 0, 6, 6, 6, 6, 4, 0, 2 }, // U+1FB51
    &.{ 3, 6, 6, 6, 6, 0, 0, 0, 0, 4 }, // U+1FB52
    &.{ 6, 6, 6, 0, 0, 0, 0, 4 }, // U+1FB53
    &.{ 3, 6, 6, 6, 6, 0, 0, 0, 0, 2 }, // U+1FB54
    &.{ 6, 6, 6, 0, 0, 0, 0, 2 }, // U+1FB55
    &.{ 3, 6, 6, 6, 6, 0, 0, 0 }, // U+1FB56
    &.{ 0, 2, 3, 0, 0, 0 }, // U+1FB57
    &.{ 0, 2, 6, 0, 0, 0 }, // U+1FB58
    &.{ 0, 4, 3, 0, 0, 0 }, // U+1FB59
    &.{ 0, 4, 6, 0, 0, 0 }, // U+1FB5A
    &.{ 0, 6, 3, 0, 0, 0 }, // U+1FB5B
    &.{ 0, 4, 6, 2, 6, 0, 0, 0 }, // U+1FB5C
    &.{ 0, 6, 3, 6, 6, 4, 6, 0, 0, 0 }, // U+1FB5D
    &.{ 0, 6, 6, 4, 6, 0, 0, 0 }, // U+1FB5E
    &.{ 0, 6, 3, 6, 6, 2, 6, 0, 0, 0 }, // U+1FB5F
    &.{ 0, 6, 6, 2, 6, 0, 0, 0 }, // U+1FB60
    &.{ 0, 6, 3, 6, 6, 0, 0, 0 }, // U+1FB61
    &.{ 6, 2, 6, 0, 3, 0 }, // U+1FB62
    &.{ 6, 2, 6, 0, 0, 0 }, // U+1FB63
    &.{ 6, 4, 6, 0, 3, 0 }, // U+1FB64
    &.{ 6, 4, 6, 0, 0, 0 }, // U+1FB65
    &.{ 6, 6, 6, 0, 3, 0 }, // U+1FB66
    &.{ 6, 4, 6, 0, 0, 0, 0, 2 }, // U+1FB67
};

/// Point-in-polygon context for a mosaic outline (vertices in sixths).
const Mosaic = struct {
    fw: f64,
    fh: f64,
    verts: []const u8,

    fn inside(self: Mosaic, px: f64, py: f64) bool {
        // Cell-relative coordinates in sixths: x, y in [0, 6].
        const x = px * 6.0 / self.fw;
        const y = py * 6.0 / self.fh;
        const n = self.verts.len / 2;
        var result = false;
        var j = n - 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const xi: f64 = @floatFromInt(self.verts[2 * i]);
            const yi: f64 = @floatFromInt(self.verts[2 * i + 1]);
            const xj: f64 = @floatFromInt(self.verts[2 * j]);
            const yj: f64 = @floatFromInt(self.verts[2 * j + 1]);
            if ((yi > y) != (yj > y)) {
                const x_cross = xj + (y - yj) * (xi - xj) / (yi - yj);
                if (x < x_cross) result = !result;
            }
            j = i;
        }
        return result;
    }
};

fn drawMosaic(out: []u8, c: Cell, cp: u21) void {
    const ctx = Mosaic{ .fw = c.fw, .fh = c.fh, .verts = mosaic_shapes[cp - 0x1FB3C] };
    raster(out, c, ctx, Mosaic.inside);
}

/// Edge triangles U+1FB68..U+1FB6F. For 1FB6C..1FB6F the triangle points
/// from the cell center to one full edge; 1FB68..1FB6B are the inverted
/// (complement) versions.
fn drawEdgeTriangles(out: []u8, c: Cell, cp: u21) void {
    const idx = cp - 0x1FB68;
    const edge: u2 = @intCast(idx % 4); // 0 left, 1 top, 2 right, 3 bottom
    const invert = idx < 4;
    const tri = switch (edge) {
        0 => Tri{ .ax = c.cx, .ay = c.cy, .bx = 0, .by = 0, .cx = 0, .cy = c.fh },
        1 => Tri{ .ax = c.cx, .ay = c.cy, .bx = c.fw, .by = 0, .cx = 0, .cy = 0 },
        2 => Tri{ .ax = c.cx, .ay = c.cy, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
        3 => Tri{ .ax = c.cx, .ay = c.cy, .bx = 0, .by = c.fh, .cx = c.fw, .cy = c.fh },
    };
    if (invert) {
        const inv = struct {
            fn f(t: Tri, px: f64, py: f64) bool {
                return !t.inside(px, py);
            }
        };
        raster(out, c, tri, inv.f);
    } else {
        raster(out, c, tri, Tri.inside);
    }
}

fn drawLegacyBlocks(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FB70...0x1FB75 => {
            // Vertical one eighth blocks 2..7, left to right (1 and 8 are
            // U+258F and U+2595, so this block starts at the second eighth).
            const n = cp - 0x1FB70 + 1;
            fillFrac(out, c, n, n + 1, 0, 8, 8, 255);
        },
        0x1FB76...0x1FB7B => {
            // Horizontal one eighth blocks 2..7, top to bottom (1 and 8 are
            // U+2594 and U+2581).
            const n = cp - 0x1FB76 + 1;
            fillFrac(out, c, 0, 8, n, n + 1, 8, 255);
        },
        0x1FB7C => {
            drawBlockFrac(out, c, 2, 1, 255);
            drawBlockFrac(out, c, 1, 1, 255);
        },
        0x1FB7D => {
            drawBlockFrac(out, c, 2, 1, 255);
            drawBlockFrac(out, c, 0, 1, 255);
        },
        0x1FB7E => {
            drawBlockFrac(out, c, 3, 1, 255);
            drawBlockFrac(out, c, 0, 1, 255);
        },
        0x1FB7F => {
            drawBlockFrac(out, c, 3, 1, 255);
            drawBlockFrac(out, c, 1, 1, 255);
        },
        0x1FB80 => {
            drawBlockFrac(out, c, 0, 1, 255);
            drawBlockFrac(out, c, 1, 1, 255);
        },
        0x1FB81 => {
            // Horizontal one eighth blocks 1, 3, 5, 8.
            fillFrac(out, c, 0, 8, 0, 1, 8, 255);
            fillFrac(out, c, 0, 8, 2, 3, 8, 255);
            fillFrac(out, c, 0, 8, 4, 5, 8, 255);
            fillFrac(out, c, 0, 8, 7, 8, 8, 255);
        },
        0x1FB82 => drawBlockFrac(out, c, 0, 2, 255),
        0x1FB83 => drawBlockFrac(out, c, 0, 3, 255),
        0x1FB84 => drawBlockFrac(out, c, 0, 5, 255),
        0x1FB85 => drawBlockFrac(out, c, 0, 6, 255),
        0x1FB86 => drawBlockFrac(out, c, 0, 7, 255),
        0x1FB87 => drawBlockFrac(out, c, 3, 2, 255),
        0x1FB88 => drawBlockFrac(out, c, 3, 3, 255),
        0x1FB89 => drawBlockFrac(out, c, 3, 5, 255),
        0x1FB8A => drawBlockFrac(out, c, 3, 6, 255),
        0x1FB8B => drawBlockFrac(out, c, 3, 7, 255),
        else => unreachable,
    }
}

fn drawLegacyShades(out: []u8, c: Cell, cp: u21) void {
    switch (cp) {
        0x1FB8C => drawBlockFrac(out, c, 2, 4, 128), // left half medium
        0x1FB8D => drawBlockFrac(out, c, 3, 4, 128), // right half medium
        0x1FB8E => drawBlockFrac(out, c, 0, 4, 128), // upper half medium
        0x1FB8F => drawBlockFrac(out, c, 1, 4, 128), // lower half medium
        0x1FB90 => fillRect(out, c, 0, 0, c.w, c.h, 128), // medium shade
        0x1FB91 => {
            fillRect(out, c, 0, 0, c.w, c.h, 128);
            drawBlockFrac(out, c, 0, 4, 255);
        },
        0x1FB92 => {
            fillRect(out, c, 0, 0, c.w, c.h, 128);
            drawBlockFrac(out, c, 1, 4, 255);
        },
        0x1FB93 => {}, // unassigned hole in the block
        0x1FB94 => {
            fillRect(out, c, 0, 0, c.w, c.h, 128);
            drawBlockFrac(out, c, 3, 4, 255);
        },
        0x1FB95 => drawCheckerboard(out, c, 0),
        0x1FB96 => drawCheckerboard(out, c, 1),
        0x1FB97 => {
            // Heavy horizontal fill: horizontal eighths 2 and 4 of 4 rows.
            fillFrac(out, c, 0, 4, 1, 2, 4, 255);
            fillFrac(out, c, 0, 4, 3, 4, 4, 255);
        },
        0x1FB98 => drawDiagonalFill(out, c, true),
        0x1FB99 => drawDiagonalFill(out, c, false),
        0x1FB9A => {
            drawEdgeTriangle(out, c, 1);
            drawEdgeTriangle(out, c, 3);
        },
        0x1FB9B => {
            drawEdgeTriangle(out, c, 0);
            drawEdgeTriangle(out, c, 2);
        },
        0x1FB9C => drawCornerTriangle(out, c, 0, 128),
        0x1FB9D => drawCornerTriangle(out, c, 1, 128),
        0x1FB9E => drawCornerTriangle(out, c, 3, 128),
        0x1FB9F => drawCornerTriangle(out, c, 2, 128),
        else => unreachable,
    }
}

fn drawEdgeTriangle(out: []u8, c: Cell, edge: u2) void {
    const tri = switch (edge) {
        0 => Tri{ .ax = c.cx, .ay = c.cy, .bx = 0, .by = 0, .cx = 0, .cy = c.fh },
        1 => Tri{ .ax = c.cx, .ay = c.cy, .bx = c.fw, .by = 0, .cx = 0, .cy = 0 },
        2 => Tri{ .ax = c.cx, .ay = c.cy, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
        3 => Tri{ .ax = c.cx, .ay = c.cy, .bx = 0, .by = c.fh, .cx = c.fw, .cy = c.fh },
    };
    rasterMax(out, c, tri, Tri.inside);
}

/// Checkerboard fill: four columns and four rows of squares (the reference
/// glyph keeps the 4x4 lattice even when the squares are not square).
fn drawCheckerboard(out: []u8, c: Cell, parity: u1) void {
    const n: u32 = 4;
    var x: u32 = 0;
    while (x < n) : (x += 1) {
        const x0 = c.w * x / n;
        const x1 = c.w * (x + 1) / n;
        var y: u32 = 0;
        while (y < n) : (y += 1) {
            const y0 = c.h * y / n;
            const y1 = c.h * (y + 1) / n;
            if ((x + y) % 2 == parity) fillRect(out, c, x0, y0, x1, y1, 255);
        }
    }
}

/// Diagonal hatch fill (U+1FB98/1FB99).
fn drawDiagonalFill(out: []u8, c: Cell, upper_left_to_lower_right: bool) void {
    const thick = c.light;
    const line_count = @max(1, c.w / (2 * thick));
    const stride = @round(c.fw / @as(f64, @floatFromInt(line_count)));
    var i: i64 = -@as(i64, @intCast(line_count));
    const end: i64 = @intCast(line_count + 1);
    while (i < end) : (i += 1) {
        const off = @as(f64, @floatFromInt(i)) * stride;
        const seg = if (upper_left_to_lower_right)
            Segment.init(off, 0, c.fw + off, c.fh, @floatFromInt(thick))
        else
            Segment.init(c.fw + off, 0, off, c.fh, @floatFromInt(thick));
        rasterMax(out, c, seg, Segment.inside);
    }
}

/// Half-cell corner triangle with shade. corner: 0 tl, 1 tr, 2 bl, 3 br.
fn drawCornerTriangle(out: []u8, c: Cell, corner: u2, alpha: u8) void {
    const tri = switch (corner) {
        0 => Tri{ .ax = 0, .ay = 0, .bx = 0, .by = c.fh, .cx = c.fw, .cy = 0 },
        1 => Tri{ .ax = 0, .ay = 0, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
        2 => Tri{ .ax = 0, .ay = 0, .bx = 0, .by = c.fh, .cx = c.fw, .cy = c.fh },
        3 => Tri{ .ax = 0, .ay = c.fh, .bx = c.fw, .by = c.fh, .cx = c.fw, .cy = 0 },
    };
    rasterShaded(out, c, tri, Tri.inside, alpha);
}

// ---------------------------------------------------------------------------
// Octants U+1CD00..U+1CDE5 (Symbols for Legacy Computing Supplement)
// ---------------------------------------------------------------------------

/// Octant masks in codepoint order, from the Unicode 16 names
/// (BLOCK OCTANT-<digits>): bit i lights octant i+1 of a 2x4 row-major
/// grid. The block lists all masks except those already representable by
/// Block Elements / sextants, in ascending order.
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

fn drawOctants(out: []u8, c: Cell, cp: u21) void {
    const mask = octants[cp - 0x1CD00];
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
            const col = i % 2;
            const row = i / 2;
            fillFracXY(out, c, col, col + 1, row, row + 1, 2, 4, 255);
        }
    }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Render the sprite for `cp` into `out_alpha` (row-major 8-bit coverage,
/// exactly width*height bytes). Returns false if `cp` is not a sprite or
/// the buffer has the wrong size; the buffer is zeroed before drawing.
pub fn renderSprite(cp: u21, width: u32, height: u32, out_alpha: []u8) bool {
    if (!isSprite(cp)) return false;
    if (width == 0 or height == 0) return false;
    if (out_alpha.len != @as(usize, width) * @as(usize, height)) return false;
    @memset(out_alpha, 0);

    const c = Cell.init(width, height);
    switch (cp) {
        0x2500...0x257F => drawBox(out_alpha, c, cp),
        0x2580...0x259F => drawBlock(out_alpha, c, cp),
        0x2800...0x28FF => drawBraille(out_alpha, c, cp),
        0xE0A0...0xE0A3, 0xE0B0...0xE0BF => drawPowerline(out_alpha, c, cp),
        0x1FB00...0x1FB3B => drawSextants(out_alpha, c, cp),
        0x1FB3C...0x1FB67 => drawMosaic(out_alpha, c, cp),
        0x1FB68...0x1FB6F => drawEdgeTriangles(out_alpha, c, cp),
        0x1FB70...0x1FB8B => drawLegacyBlocks(out_alpha, c, cp),
        0x1FB8C...0x1FB9F => drawLegacyShades(out_alpha, c, cp),
        0x1CD00...0x1CDE5 => drawOctants(out_alpha, c, cp),
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Render into a fixed buffer; panics on failure (test helper).
fn render(cp: u21, w: u32, h: u32, buf: []u8) void {
    if (!renderSprite(cp, w, h, buf)) unreachable;
}

fn activeRows(buf: []const u8, w: u32, h: u32, x: u32) [64]bool {
    var rows: [64]bool = @splat(false);
    var y: u32 = 0;
    while (y < h and y < 64) : (y += 1) rows[y] = buf[y * w + x] > 0;
    return rows;
}

fn activeCols(buf: []const u8, w: u32, h: u32, y: u32) [64]bool {
    // `h` is accepted for symmetry with `activeRows` and bounds the row
    // index; the scan itself only walks columns.
    std.debug.assert(y < h);
    var cols: [64]bool = @splat(false);
    var x: u32 = 0;
    while (x < w and x < 64) : (x += 1) cols[x] = buf[y * w + x] > 0;
    return cols;
}

test "isSprite covers exactly the sprite ranges" {
    const yes = [_]u21{
        0x2500, 0x257F, 0x2580, 0x259F, 0x2800, 0x28FF,
        0xE0A0, 0xE0A3, 0xE0B0, 0xE0B7, 0xE0B8, 0xE0BF,
        0x1FB00, 0x1FB3B, 0x1FB3C, 0x1FB6F, 0x1FB70, 0x1FB8B,
        0x1FB8C, 0x1FB9F, 0x1CD00, 0x1CDE5,
    };
    for (yes) |cp| try testing.expect(isSprite(cp));
    const no = [_]u21{
        'A', 0x24FF, 0x25A0, 0x27FF, 0x2900, 0xE0A4, 0xE0C0,
        0x1FAFF, 0x1FB93 + 0x100, 0x1CDE6, 0x1CCFF, 0x1FBFF,
    };
    for (no) |cp| try testing.expect(!isSprite(cp));
}

test "renderSprite rejects non-sprites and wrong buffer sizes" {
    var buf: [16 * 16]u8 = undefined;
    try testing.expect(!renderSprite('A', 16, 16, &buf));
    try testing.expect(!renderSprite(0x2500, 16, 16, buf[0 .. 16 * 16 - 1]));
    try testing.expect(!renderSprite(0x2500, 0, 16, &buf));
    try testing.expect(renderSprite(0x2500, 16, 16, &buf));
}

test "(a) horizontal join: U+2500 U+253C U+2500 share active rows at the shared edges" {
    const w = 16;
    const h = 24;
    var left: [w * h]u8 = undefined;
    var mid: [w * h]u8 = undefined;
    var right: [w * h]u8 = undefined;
    render(0x2500, w, h, &left);
    render(0x253C, w, h, &mid);
    render(0x2500, w, h, &right);

    // Left cell's right edge must equal the cross's left edge, and the
    // cross's right edge must equal the right cell's left edge.
    try testing.expectEqualSlices(bool, &activeRows(&left, w, h, w - 1), &activeRows(&mid, w, h, 0));
    try testing.expectEqualSlices(bool, &activeRows(&mid, w, h, w - 1), &activeRows(&right, w, h, 0));
    // And coverage values match exactly (no seam shading).
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(left[y * w + (w - 1)], mid[y * w]);
        try testing.expectEqual(mid[y * w + (w - 1)], right[y * w]);
    }
}

test "joins hold for every cell size in a range" {
    const sizes = [_][2]u32{
        .{ 5, 8 },  .{ 6, 12 }, .{ 7, 13 }, .{ 9, 17 },
        .{ 11, 20 }, .{ 13, 21 }, .{ 16, 24 }, .{ 20, 30 },
    };
    var a: [32 * 32]u8 = undefined;
    var b: [32 * 32]u8 = undefined;
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        const sa = a[0 .. w * h];
        const sb = b[0 .. w * h];

        // Light lines: the horizontal line's edges match the cross's.
        try testing.expect(renderSprite(0x2500, w, h, sa));
        try testing.expect(renderSprite(0x253C, w, h, sb));
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            try testing.expectEqual(sa[y * w + (w - 1)], sb[y * w]);
            try testing.expectEqual(sb[y * w + (w - 1)], sa[y * w]);
        }

        // Vertical: the vertical line's edges match the cross's.
        try testing.expect(renderSprite(0x2502, w, h, sa));
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(sa[(h - 1) * w + x], sb[x]);
            try testing.expectEqual(sb[(h - 1) * w + x], sa[x]);
        }

        // Heavy and heavy/light tees join as well.
        try testing.expect(renderSprite(0x2501, w, h, sa));
        try testing.expect(renderSprite(0x254B, w, h, sb));
        y = 0;
        while (y < h) : (y += 1) {
            try testing.expectEqual(sa[y * w + (w - 1)], sb[y * w]);
        }
    }
}

test "(b) vertical join: U+2502 U+253C share active cols at the shared edges" {
    const w = 16;
    const h = 24;
    var top: [w * h]u8 = undefined;
    var mid: [w * h]u8 = undefined;
    var bottom: [w * h]u8 = undefined;
    render(0x2502, w, h, &top);
    render(0x253C, w, h, &mid);
    render(0x2502, w, h, &bottom);

    try testing.expectEqualSlices(bool, &activeCols(&top, w, h, h - 1), &activeCols(&mid, w, h, 0));
    try testing.expectEqualSlices(bool, &activeCols(&mid, w, h, h - 1), &activeCols(&bottom, w, h, 0));
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        try testing.expectEqual(top[(h - 1) * w + x], mid[x]);
        try testing.expectEqual(mid[(h - 1) * w + x], bottom[x]);
    }
}

test "(c) double lines join on all four edges" {
    const w = 16;
    const h = 24;
    var hline: [w * h]u8 = undefined;
    var vline: [w * h]u8 = undefined;
    var cross: [w * h]u8 = undefined;
    render(0x2550, w, h, &hline); // ═
    render(0x2551, w, h, &vline); // ║
    render(0x256C, w, h, &cross); // ╬

    // Horizontal: ═ right edge == ╬ left edge, ╬ right edge == ═ left edge.
    try testing.expectEqualSlices(bool, &activeRows(&hline, w, h, w - 1), &activeRows(&cross, w, h, 0));
    try testing.expectEqualSlices(bool, &activeRows(&cross, w, h, w - 1), &activeRows(&hline, w, h, 0));
    // Vertical: ║ bottom edge == ╬ top edge, ╬ bottom edge == ║ top edge.
    try testing.expectEqualSlices(bool, &activeCols(&vline, w, h, h - 1), &activeCols(&cross, w, h, 0));
    try testing.expectEqualSlices(bool, &activeCols(&cross, w, h, h - 1), &activeCols(&vline, w, h, 0));

    // Double lines really are two stems with a gap between them.
    var lit_rows: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        if (hline[y * w] > 0) lit_rows += 1;
    }
    try testing.expect(lit_rows >= 2); // at least two separate stems
    // The center row of a double horizontal line is empty (the gap).
    try testing.expectEqual(@as(u8, 0), hline[(h / 2) * w]);
}

test "joins hold for odd cell sizes too" {
    const w = 13;
    const h = 21;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;
    render(0x2500, w, h, &a);
    render(0x253C, w, h, &b);
    try testing.expectEqualSlices(bool, &activeRows(&a, w, h, w - 1), &activeRows(&b, w, h, 0));
    render(0x2502, w, h, &a);
    render(0x253C, w, h, &b);
    try testing.expectEqualSlices(bool, &activeCols(&a, w, h, h - 1), &activeCols(&b, w, h, 0));
    // Heavy and mixed tees join as well.
    render(0x2501, w, h, &a);
    render(0x254B, w, h, &b);
    try testing.expectEqualSlices(bool, &activeRows(&a, w, h, w - 1), &activeRows(&b, w, h, 0));
}

test "stems are centered and light/heavy thicknesses follow the cell" {
    const sizes = [_][2]u32{ .{ 8, 16 }, .{ 13, 21 }, .{ 16, 24 }, .{ 20, 30 } };
    var buf: [32 * 32]u8 = undefined;
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        const s = buf[0 .. w * h];
        const light = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) / 8.0))));
        const heavy = 2 * light;

        // Light horizontal line: `light` full rows centered on h/2.
        try testing.expect(renderSprite(0x2500, w, h, s));
        const y0 = (h -| light) / 2;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const want = y >= y0 and y < y0 + light;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                try testing.expectEqual(want, s[y * w + x] == 255);
            }
        }

        // Heavy is exactly twice as thick and just as centered.
        try testing.expect(renderSprite(0x2501, w, h, s));
        var lit: u32 = 0;
        y = 0;
        while (y < h) : (y += 1) {
            if (s[y * w] == 255) lit += 1;
        }
        try testing.expectEqual(heavy, lit);
        try testing.expectEqual(@as(u8, 255), s[((h -| heavy) / 2) * w]);

        // Light vertical line: `light` full columns centered on w/2.
        try testing.expect(renderSprite(0x2502, w, h, s));
        const x0 = (w -| light) / 2;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(x >= x0 and x < x0 + light, s[(h / 2) * w + x] == 255);
        }
    }
}

test "block element eighths anchor and complement" {
    const w = 16;
    const h = 24;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;

    // U+2589 (left seven eighths) and U+2595 (right one eighth) partition.
    render(0x2589, w, h, &a);
    render(0x2595, w, h, &b);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        try testing.expect((a[i] == 255) != (b[i] == 255));
    }

    // U+258F (left one eighth) and U+2594 (upper one eighth) anchor at the
    // left and top edges.
    render(0x258F, w, h, &a);
    const x1 = fracMax(w, 1, 8);
    render(0x2594, w, h, &b);
    const y1 = fracMax(h, 1, 8);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(x < x1, a[y * w + x] == 255);
            try testing.expectEqual(y < y1, b[y * w + x] == 255);
        }
    }
}

test "(d) full block is all 255; shades are monotonic 25 < 50 < 75 < 100" {
    const w = 12;
    const h = 18;
    var full: [w * h]u8 = undefined;
    render(0x2588, w, h, &full);
    for (full) |v| try testing.expectEqual(@as(u8, 255), v);

    var s25: [w * h]u8 = undefined;
    var s50: [w * h]u8 = undefined;
    var s75: [w * h]u8 = undefined;
    render(0x2591, w, h, &s25);
    render(0x2592, w, h, &s50);
    render(0x2593, w, h, &s75);
    try testing.expect(s25[0] < s50[0]);
    try testing.expect(s50[0] < s75[0]);
    try testing.expect(s75[0] < full[0]);
    // Uniform coverage across the whole cell.
    for (s25) |v| try testing.expectEqual(s25[0], v);
    for (s50) |v| try testing.expectEqual(s50[0], v);
    for (s75) |v| try testing.expectEqual(s75[0], v);
}

test "block fractions partition: lower + upper half fill the cell exactly" {
    const w = 12;
    const h = 18;
    var lower: [w * h]u8 = undefined;
    var upper: [w * h]u8 = undefined;
    render(0x2584, w, h, &lower);
    render(0x2580, w, h, &upper);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        // Exactly one of the two halves covers each pixel, fully.
        try testing.expect((lower[i] == 255) != (upper[i] == 255));
    }
    // Left/right halves too.
    render(0x258C, w, h, &lower);
    render(0x2590, w, h, &upper);
    i = 0;
    while (i < w * h) : (i += 1) {
        try testing.expect((lower[i] == 255) != (upper[i] == 255));
    }
}

test "(e) braille: U+2800 empty, U+28FF lights all 8 dots" {
    const w = 16;
    const h = 32;
    var empty: [w * h]u8 = undefined;
    render(0x2800, w, h, &empty);
    for (empty) |v| try testing.expectEqual(@as(u8, 0), v);

    var full: [w * h]u8 = undefined;
    render(0x28FF, w, h, &full);
    // Count connected dot regions by scanning for lit pixel clusters:
    // simpler: each single-dot codepoint must light a subset of U+28FF,
    // and the 8 single dots must be pairwise disjoint and non-empty.
    var dots: [8][w * h]u8 = undefined;
    for (&dots, 0..) |*d, i| {
        render(0x2800 + (@as(u21, 1) << @intCast(i)), w, h, d);
        var lit: usize = 0;
        for (d, 0..) |v, k| {
            if (v > 0) lit += 1;
            if (v > 0) try testing.expect(full[k] > 0);
        }
        try testing.expect(lit > 0);
    }
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var j: usize = i + 1;
        while (j < 8) : (j += 1) {
            for (dots[i], dots[j]) |a, b| try testing.expect(!(a > 0 and b > 0));
        }
    }
    // Union of the 8 dots equals U+28FF coverage.
    var k: usize = 0;
    while (k < w * h) : (k += 1) {
        var any = false;
        for (dots) |d| any = any or d[k] > 0;
        try testing.expectEqual(full[k] > 0, any);
    }
}

test "(f) sextants partition the cell: each bit lights exactly its sub-rect" {
    const w = 12;
    const h = 18;
    // Single-sextant codepoints: masks 1, 2, 4, 8, 16, 32. The block lists
    // masks in ascending order while skipping 21 and 42, so mask 32 is the
    // 31st mask in the sequence (index 30, U+1FB1E), not index 31.
    const single = [_]u21{ 0x1FB00, 0x1FB01, 0x1FB03, 0x1FB07, 0x1FB0F, 0x1FB1E };
    var parts: [6][w * h]u8 = undefined;
    for (&parts, single) |*p, cp| render(cp, w, h, p);

    // Each part must equal exactly its 2x3 sub-rect.
    for (parts, 0..) |p, i| {
        const col: u32 = @intCast(i % 2);
        const row: u32 = @intCast(i / 2);
        const x0 = fracMin(w, col, 2);
        const x1 = fracMax(w, col + 1, 2);
        const y0 = fracMin(h, row, 3);
        const y1 = fracMax(h, row + 1, 3);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const in_rect = x >= x0 and x < x1 and y >= y0 and y < y1;
                try testing.expectEqual(in_rect, p[y * w + x] == 255);
            }
        }
    }
    // Pairwise disjoint, union covers the whole cell.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var count: u32 = 0;
            for (parts) |p| {
                if (p[y * w + x] > 0) count += 1;
            }
            try testing.expectEqual(@as(u32, 1), count);
        }
    }
}

test "sextant mask formula matches Unicode names for all 60 codepoints" {
    // Masks 1..62 ascending, skipping 21 (0b010101) and 42 (0b101010).
    var expect: u32 = 1;
    var cp: u21 = 0x1FB00;
    while (cp <= 0x1FB3B) : (cp += 1) {
        while (expect == 21 or expect == 42) expect += 1;
        try testing.expectEqual(@as(u6, @intCast(expect)), sextantMask(cp));
        expect += 1;
    }
    try testing.expectEqual(@as(u32, 63), expect);
}

test "octants partition the cell: each bit lights exactly its 2x4 sub-rect" {
    const w = 12;
    const h = 20;
    // Render every octant codepoint; verify each lit sub-rect matches the
    // mask and that sub-rect boundaries are shared (no gaps/overlaps).
    var cp: u21 = 0x1CD00;
    while (cp <= 0x1CDE5) : (cp += 1) {
        var buf: [w * h]u8 = undefined;
        render(cp, w, h, &buf);
        const mask = octants[cp - 0x1CD00];
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const col = i % 2;
            const row = i / 2;
            const x0 = fracMin(w, col, 2);
            const x1 = fracMax(w, col + 1, 2);
            const y0 = fracMin(h, row, 4);
            const y1 = fracMax(h, row + 1, 4);
            const lit = mask & (@as(u8, 1) << @intCast(i)) != 0;
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    try testing.expectEqual(lit, buf[y * w + x] == 255);
                }
            }
        }
    }
}

test "(g) Powerline U+E0B0 fills the left edge fully and tapers to the right tip" {
    const w = 16;
    const h = 24;
    var buf: [w * h]u8 = undefined;
    render(0xE0B0, w, h, &buf);
    // Left edge fully covered.
    var y: u32 = 0;
    while (y < h) : (y += 1) try testing.expect(buf[y * w] > 0);
    // Coverage decreases monotonically left -> right (triangle taper).
    var prev: u32 = h;
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        var count: u32 = 0;
        y = 0;
        while (y < h) : (y += 1) {
            if (buf[y * w + x] > 0) count += 1;
        }
        try testing.expect(count <= prev);
        prev = count;
    }
    // The rightmost column is (at most) the tip: far smaller than the left.
    try testing.expect(prev < h / 2);
    // Symmetric about the horizontal midline.
    y = 0;
    while (y < h / 2) : (y += 1) {
        var xx: u32 = 0;
        while (xx < w) : (xx += 1) {
            try testing.expectEqual(buf[y * w + xx], buf[(h - 1 - y) * w + xx]);
        }
    }
}

test "Powerline mirrored separators are horizontal mirrors" {
    const w = 16;
    const h = 24;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;
    render(0xE0B0, w, h, &a);
    render(0xE0B2, w, h, &b);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(a[y * w + x], b[y * w + (w - 1 - x)]);
        }
    }
}

test "diagonals reach all four corners" {
    const w = 16;
    const h = 24;
    var buf: [w * h]u8 = undefined;
    render(0x2571, w, h, &buf); // upper right -> lower left
    try testing.expect(buf[0 * w + (w - 1)] > 0);
    try testing.expect(buf[(h - 1) * w + 0] > 0);
    render(0x2572, w, h, &buf); // upper left -> lower right
    try testing.expect(buf[0] > 0);
    try testing.expect(buf[(h - 1) * w + (w - 1)] > 0);
    render(0x2573, w, h, &buf); // cross: all four corners
    try testing.expect(buf[0] > 0);
    try testing.expect(buf[w - 1] > 0);
    try testing.expect(buf[(h - 1) * w] > 0);
    try testing.expect(buf[(h - 1) * w + (w - 1)] > 0);
}

test "every sprite renders without panic at several cell sizes" {
    const sizes = [_][2]u32{ .{ 8, 16 }, .{ 10, 20 }, .{ 13, 21 }, .{ 16, 32 } };
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        var buf: [32 * 32]u8 = undefined;
        const slice = buf[0 .. w * h];
        var cp: u21 = 0x2500;
        while (cp <= 0x259F) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0x2800;
        while (cp <= 0x28FF) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0xE0A0;
        while (cp <= 0xE0A3) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0xE0B0;
        while (cp <= 0xE0BF) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0x1FB00;
        while (cp <= 0x1FB9F) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0x1CD00;
        while (cp <= 0x1CDE5) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
    }
}

test "smooth mosaics stay within the cell and are non-empty" {
    const w = 12;
    const h = 18;
    var buf: [w * h]u8 = undefined;
    var cp: u21 = 0x1FB3C;
    while (cp <= 0x1FB67) : (cp += 1) {
        render(cp, w, h, &buf);
        var lit: usize = 0;
        for (buf) |v| {
            if (v > 0) lit += 1;
        }
        try testing.expect(lit > 0);
        try testing.expect(lit < w * h);
    }
}

test "mosaics match the reference block-diagonal outlines" {
    const w = 16;
    const h = 24;
    var buf: [w * h]u8 = undefined;

    // Small bottom-left triangles: (0,1) (1/2,1) (0,2/3) and (0,1) (1,1) (0,2/3).
    render(0x1FB3C, w, h, &buf);
    try testing.expectEqual(@as(u8, 255), buf[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 0), buf[(h - 1) * w + (w - 1)]);
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(u8, 0), buf[w - 1]);

    // (0,1) (1,1) (0,2/3): the whole bottom edge is filled; the diagonal
    // runs into the bottom-right corner, so the last pixel is only partial.
    render(0x1FB3D, w, h, &buf);
    try testing.expectEqual(@as(u8, 255), buf[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 255), buf[(h - 1) * w + w / 2]);
    try testing.expect(buf[(h - 1) * w + (w - 1)] > 0);
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(u8, 0), buf[w - 1]);

    // Upper-left triangle (0,1/3) (1/2,0) (0,0): the left edge is covered
    // top to bottom, narrowing to the apex at the bottom-left corner.
    render(0x1FB5B, w, h, &buf);
    try testing.expectEqual(@as(u8, 255), buf[0]);
    try testing.expect(buf[(h - 1) * w] > 0);
    try testing.expectEqual(@as(u8, 0), buf[w - 1]);
    try testing.expectEqual(@as(u8, 0), buf[(h - 1) * w + (w - 1)]);

    // Full block with a diagonal cut: every corner but the top left.
    render(0x1FB41, w, h, &buf);
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(u8, 255), buf[w - 1]);
    try testing.expectEqual(@as(u8, 255), buf[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 255), buf[(h - 1) * w + (w - 1)]);

    // Upper wedge (0,2/3) (1,1/3) (1,0) (0,0): full top row, empty bottom.
    render(0x1FB5C, w, h, &buf);
    try testing.expectEqual(@as(u8, 255), buf[0]);
    try testing.expectEqual(@as(u8, 255), buf[w - 1]);
    try testing.expectEqual(@as(u8, 0), buf[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 0), buf[(h - 1) * w + (w - 1)]);
}

test "mosaic codepoints pair up as complements (both halves fill the cell)" {
    const w = 13;
    const h = 21;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;
    // Every shape in 0x1FB3C..0x1FB51 has its complement 0x16 further up:
    // one half is the filled region, the other the region cut away.
    var cp: u21 = 0x1FB3C;
    while (cp <= 0x1FB51) : (cp += 1) {
        render(cp, w, h, &a);
        render(cp + 0x16, w, h, &b);
        var i: usize = 0;
        while (i < w * h) : (i += 1) {
            // Together they cover every pixel ...
            try testing.expect(a[i] > 0 or b[i] > 0);
            // ... and the cut never lands on top of the filled region.
            try testing.expect(!(a[i] == 255 and b[i] == 255));
        }
    }
}

/// Eighth index (0..7) of `pos` inside `size`, using the same complementary
/// rounding as the renderer.
fn eighthBand(pos: u32, size: u32) u32 {
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        if (pos >= fracMin(size, k, 8) and pos < fracMax(size, k + 1, 8)) return k;
    }
    return 7;
}

test "legacy one-eighth blocks are the second..seventh eighth" {
    const w = 16;
    const h = 24;
    var buf: [w * h]u8 = undefined;

    // Vertical eighths (U+1FB70..U+1FB75): full height, bands 1..6.
    var cp: u21 = 0x1FB70;
    while (cp <= 0x1FB75) : (cp += 1) {
        const want: u32 = 1 + (cp - 0x1FB70);
        render(cp, w, h, &buf);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                try testing.expectEqual(eighthBand(x, w) == want, buf[y * w + x] == 255);
            }
        }
    }

    // Horizontal eighths (U+1FB76..U+1FB7B): full width, bands 1..6.
    cp = 0x1FB76;
    while (cp <= 0x1FB7B) : (cp += 1) {
        const want: u32 = 1 + (cp - 0x1FB76);
        render(cp, w, h, &buf);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                try testing.expectEqual(eighthBand(y, h) == want, buf[y * w + x] == 255);
            }
        }
    }

    // The first and last eighths stay empty: those glyphs are U+258F/U+2595
    // and U+2594/U+2581, so the block spans the middle six eighths only.
    cp = 0x1FB70;
    while (cp <= 0x1FB75) : (cp += 1) {
        render(cp, w, h, &buf);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            try testing.expectEqual(@as(u8, 0), buf[y * w]);
            try testing.expectEqual(@as(u8, 0), buf[y * w + (w - 1)]);
        }
    }
    cp = 0x1FB76;
    while (cp <= 0x1FB7B) : (cp += 1) {
        render(cp, w, h, &buf);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(@as(u8, 0), buf[x]);
            try testing.expectEqual(@as(u8, 0), buf[(h - 1) * w + x]);
        }
    }
}

test "legacy partial blocks anchor to the named edges" {
    const w = 16;
    const h = 24;
    var buf: [w * h]u8 = undefined;

    // U+1FB81: horizontal eighths 1, 3, 5 and 8.
    render(0x1FB81, w, h, &buf);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const band = eighthBand(y, h);
        const want = band == 0 or band == 2 or band == 4 or band == 7;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(want, buf[y * w + x] == 255);
        }
    }

    // U+1FB82: upper two eighths; U+1FB87: right two eighths.
    render(0x1FB82, w, h, &buf);
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(eighthBand(y, h) < 2, buf[y * w + x] == 255);
        }
    }
    render(0x1FB87, w, h, &buf);
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(eighthBand(x, w) >= 6, buf[y * w + x] == 255);
        }
    }

    // U+1FB7C: left eighth and lower eighth; U+1FB80: upper and lower eighth.
    render(0x1FB7C, w, h, &buf);
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const want = eighthBand(x, w) == 0 or eighthBand(y, h) == 7;
            try testing.expectEqual(want, buf[y * w + x] == 255);
        }
    }
    render(0x1FB80, w, h, &buf);
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const band = eighthBand(y, h);
            const want = band == 0 or band == 7;
            try testing.expectEqual(want, buf[y * w + x] == 255);
        }
    }

    // U+1FB97 heavy horizontal fill: quarter rows 2 and 4, full width.
    render(0x1FB97, w, h, &buf);
    y = 0;
    while (y < h) : (y += 1) {
        const band = y * 4 / h;
        const want = band == 1 or band == 3;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(want, buf[y * w + x] == 255);
        }
    }
}

test "checker board fill is a 4x4 lattice and its inverse complements it" {
    const w = 16;
    const h = 24;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;
    render(0x1FB95, w, h, &a);
    render(0x1FB96, w, h, &b);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            try testing.expect((a[i] == 255) != (b[i] == 255));
            const want = (x * 4 / w + y * 4 / h) % 2 == 0;
            try testing.expectEqual(want, a[i] == 255);
        }
    }
}

test "triangular medium shades are half-coverage corner triangles" {
    const w = 16;
    const h = 24;
    var ul: [w * h]u8 = undefined;
    var ur: [w * h]u8 = undefined;
    var lr: [w * h]u8 = undefined;
    var ll: [w * h]u8 = undefined;
    render(0x1FB9C, w, h, &ul); // upper left
    render(0x1FB9D, w, h, &ur); // upper right
    render(0x1FB9E, w, h, &lr); // lower right
    render(0x1FB9F, w, h, &ll); // lower left

    // Medium shade only: never a solid fill.
    for (ul) |v| try testing.expect(v <= 128);
    for (ur) |v| try testing.expect(v <= 128);
    for (lr) |v| try testing.expect(v <= 128);
    for (ll) |v| try testing.expect(v <= 128);

    // Opposite triangles partition the cell (the two halves of a diagonal).
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        try testing.expect(ul[i] > 0 or lr[i] > 0);
        try testing.expect(ur[i] > 0 or ll[i] > 0);
    }

    // The named corner is shaded, the opposite corner is empty.
    try testing.expectEqual(@as(u8, 128), ul[0]);
    try testing.expectEqual(@as(u8, 0), ul[(h - 1) * w + (w - 1)]);
    try testing.expectEqual(@as(u8, 0), lr[0]);
    try testing.expectEqual(@as(u8, 128), lr[(h - 1) * w + (w - 1)]);
    try testing.expectEqual(@as(u8, 128), ur[w - 1]);
    try testing.expectEqual(@as(u8, 128), ll[(h - 1) * w]);
}

test "renderSprite zeroes the buffer, including for the unassigned hole" {
    const w = 12;
    const h = 18;
    var buf: [w * h]u8 = undefined;
    @memset(&buf, 0xAA);
    try testing.expect(renderSprite(0x1FB93, w, h, &buf)); // unassigned: blank
    for (buf) |v| try testing.expectEqual(@as(u8, 0), v);
}

/// Number of covered pixels in one row.
fn litInRow(buf: []const u8, w: u32, y: u32) u32 {
    var n: u32 = 0;
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        if (buf[y * w + x] > 0) n += 1;
    }
    return n;
}

test "Powerline round separators bulge to the far edge at mid height" {
    const w = 16;
    const h = 24;
    var filled: [w * h]u8 = undefined;
    var outline: [w * h]u8 = undefined;
    var mirrored: [w * h]u8 = undefined;
    render(0xE0B4, w, h, &filled); // filled, bulge to the right
    render(0xE0B5, w, h, &outline); // the same bulge as a stroke
    render(0xE0B6, w, h, &mirrored); // filled, bulge to the left

    // The filled separator covers the near edge for the full height ...
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(@as(u8, 255), filled[y * w]);
        try testing.expectEqual(@as(u8, 255), mirrored[y * w + (w - 1)]);
    }
    // ... and reaches the far edge only at mid height.
    try testing.expectEqual(@as(u32, w), litInRow(&filled, w, h / 2 - 1));
    try testing.expect(litInRow(&filled, w, 0) < w / 2);
    try testing.expect(litInRow(&filled, w, h - 1) < w / 2);
    // Widest rows are the two middle ones, coverage falls off monotonically.
    var prev: u32 = 0;
    y = 0;
    while (y <= h / 2) : (y += 1) {
        const n = litInRow(&filled, w, y);
        try testing.expect(n >= prev);
        prev = n;
    }
    prev = 0;
    y = h;
    while (y > h / 2) : (y -= 1) {
        const n = litInRow(&filled, w, y - 1);
        try testing.expect(n >= prev);
        prev = n;
    }

    // U+E0B6 is the horizontal mirror of U+E0B4.
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(filled[y * w + x], mirrored[y * w + (w - 1 - x)]);
        }
    }

    // The stroke follows the same bulge: every lit pixel is inside the
    // filled shape, and it never fills the near edge.
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        try testing.expect(outline[i] == 0 or filled[i] > 0);
    }
    y = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(@as(u8, 0), outline[y * w]);
    }
}
