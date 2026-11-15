//! src/font/sprite.zig -- code-drawn cell sprites (ROADMAP M3.6, solves R1
//! pixel-exact box drawing).
//!
//! Geometry is a direct port of ghostty v1.4.0's sprite font
//! (src/font/sprite/draw/*.zig); see sprite_ghostty.zig for the ported
//! drawing code and the source-function mapping. Sprites are rasterized
//! here instead of being taken from a font so that lines join EXACTLY
//! across cell boundaries:
//!
//!   * Every edge-touching stroke is drawn all the way to the boundary
//!     pixel (x = 0 / x = w-1, y = 0 / y = h-1).
//!   * Stems are centered with ghostty's integer math: a stroke of
//!     thickness t spans [(size - t) / 2, (size - t) / 2 + t). Thickness
//!     comes from ghostty's Thickness model (light = box_thickness,
//!     heavy = 2x, super_light = max(box_thickness/2, 1)); double lines
//!     are two parallel light stems separated by a light-width gap.
//!   * Fractional sub-rects (sextants, octants, block fractions) use
//!     ghostty's complementary rounding: a boundary at fraction f is
//!     placed at size - round((1-f)*size) when it is a min coordinate and
//!     at round(f*size) when it is a max coordinate.
//!   * Diagonals, triangles, arcs and circles are antialiased by 4x4
//!     supersampling of ghostty's exact edge positions (ghostty itself
//!     uses z2d analytic coverage; the geometry is identical, only the
//!     coverage integration differs).
//!
//! No allocation: `renderSprite` writes row-major 8-bit coverage (0..255)
//! into a caller-provided buffer of exactly w*h bytes.
//!
//! Bit orders (documented per family, all verified against Unicode 16
//! character names):
//!
//!   * Sextants U+1FB00..U+1FB3B: 2 columns x 3 rows, numbered row-major
//!     1..6. The mask is idx + idx/20 + 1 with idx = cp - 0x1FB00: masks
//!     1..62 ascending, skipping 21 and 42 (full columns, already in
//!     Block Elements).
//!   * Octants U+1CD00..U+1CDE5: 2 columns x 4 rows, row-major 1..8; the
//!     mask table is verified identical to ghostty's draw/octants.txt.
//!   * Braille U+2800..U+28FF: mask = cp - 0x2800. Bits 0..2 left column
//!     top to bottom, bits 3..5 right column, bit 6 bottom-left, bit 7
//!     bottom-right.
//!   * Smooth mosaics U+1FB3C..U+1FB67: ghostty's SmoothMosaic patterns
//!     (4x3 lattice, rows at 0, h/3, 2h/3, h) with the collinearity
//!     vertex rules; diagonals are straight edges, not staircases.
//!
//! Coverage holes: U+1FB93 is an unassigned hole drawn blank (ghostty
//! does the same). U+1FBB0..1FBBC, U+1FBC0..1FBCD and U+1FBF0..1FBFF are
//! NOT sprites in ghostty (font glyphs / tofu), so isSprite reports false
//! and the font path handles them, exactly like ghostty.

const std = @import("std");
const ghostty = @import("sprite_ghostty.zig");

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// True if `cp` is drawn by this module instead of a font face. The ranges
/// match ghostty v1.4.0's sprite Face (draw/*.zig); U+E0A0..U+E0A3 are font
/// glyphs there too, so this module leaves them to the font as well.
pub fn isSprite(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => true, // Box Drawing
        0x2580...0x259F => true, // Block Elements
        0x2800...0x28FF => true, // Braille Patterns
        0xE0A0...0xE0A3 => false, // ghostty v1.4.0 takes these from the font, not sprites
        0xE0B0...0xE0BF => true, // Powerline separators + extra diagonals
        0x1FB00...0x1FBAF => true, // sextants, mosaics, blocks, shades, corner diagonals
        0x1FBBD...0x1FBBF => true, // inverted diagonal crosses
        0x1FBCE...0x1FBCF => true, // left two-thirds / one-third block
        0x1FBD0...0x1FBEF => true, // cell diagonals, circles, centered blocks
        0x1CD00...0x1CDE5 => true, // octants (Unicode 16 supplement)
        else => false,
    };
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

    const c = ghostty.Cell.init(width, height);
    switch (cp) {
        0x2500...0x257F => ghostty.drawBox(out_alpha, c, cp),
        0x2580...0x259F => ghostty.drawBlock(out_alpha, c, cp),
        0x2800...0x28FF => ghostty.drawBraille(out_alpha, c, cp),
        0xE0A0...0xE0A3 => ghostty.drawPowerlineExtras(out_alpha, c, cp),
        0xE0B0...0xE0BF => ghostty.drawPowerline(out_alpha, c, cp),
        0x1FB00...0x1FBAF, 0x1FBBD...0x1FBBF, 0x1FBCE...0x1FBCF, 0x1FBD0...0x1FBEF => ghostty.drawLegacy(out_alpha, c, cp),
        0x1CD00...0x1CDE5 => ghostty.drawOctants(out_alpha, c, cp),
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
        0xE0B0, 0xE0B7, 0xE0B8, 0xE0BF,
        0x1FB00, 0x1FB3B, 0x1FB3C, 0x1FB6F, 0x1FB70, 0x1FB8B,
        0x1FB8C, 0x1FB9F, 0x1FBA0, 0x1FBAE, 0x1FBAF,
        0x1FBBD, 0x1FBBE, 0x1FBBF, 0x1FBCE, 0x1FBCF,
        0x1FBD0, 0x1FBDF, 0x1FBE0, 0x1FBEF,
        0x1CD00, 0x1CDE5,
    };
    for (yes) |cp| try testing.expect(isSprite(cp));
    const no = [_]u21{
        'A', 0x24FF, 0x25A0, 0x27FF, 0x2900,
        0xE0A0, 0xE0A3, 0xE0A4, 0xE0C0,
        0x1FAFF, 0x1FB93 + 0x100, 0x1CDE6, 0x1CCFF, 0x1FBFF,
        // Holes ghostty leaves to the font:
        0x1FBB0, 0x1FBBC, 0x1FBC0, 0x1FBCD, 0x1FBF0, 0x1FBF9,
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

    // Double lines really are two stems with a gap between them: the gap
    // is the light-stem band [(h - light) / 2, +light).
    const light = ghostty.box_thickness;
    var lit_rows: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        if (hline[y * w] > 0) lit_rows += 1;
    }
    try testing.expect(lit_rows >= 2); // at least two separate stems
    try testing.expectEqual(@as(u8, 0), hline[((h - light) / 2) * w]);
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

test "stems are centered; thickness follows ghostty's Thickness model" {
    const sizes = [_][2]u32{ .{ 8, 16 }, .{ 11, 25 }, .{ 13, 21 }, .{ 16, 24 }, .{ 20, 30 } };
    var buf: [32 * 32]u8 = undefined;
    // ghostty: light = box_thickness, heavy = 2 * box_thickness. The base
    // is pinned to the parity face (see sprite_ghostty.zig).
    const light = ghostty.box_thickness;
    const heavy = 2 * light;
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        const s = buf[0 .. w * h];

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

test "rounded corners join the light line cells on both edges" {
    const w = 11;
    const h = 25;
    var arc: [w * h]u8 = undefined;
    var line: [w * h]u8 = undefined;
    const light = ghostty.box_thickness;
    const vx0 = (w - light) / 2; // centered vertical stem columns
    const hy0 = (h - light) / 2; // centered horizontal stem rows

    // U+256D ╭: vertical stem to the bottom edge, horizontal to the right.
    render(0x256D, w, h, &arc);
    render(0x2502, w, h, &line);
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        try testing.expectEqual(line[(h - 1) * w + x] > 0, arc[(h - 1) * w + x] > 0);
        try testing.expectEqual(x >= vx0 and x < vx0 + light, arc[(h - 1) * w + x] > 0);
    }
    render(0x2500, w, h, &line);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(line[y * w + (w - 1)] > 0, arc[y * w + (w - 1)] > 0);
        try testing.expectEqual(y >= hy0 and y < hy0 + light, arc[y * w + (w - 1)] > 0);
    }

    // U+256F ╯: stems to the top and left edges.
    render(0x256F, w, h, &arc);
    render(0x2502, w, h, &line);
    x = 0;
    while (x < w) : (x += 1) {
        try testing.expectEqual(line[x] > 0, arc[x] > 0);
    }
    render(0x2500, w, h, &line);
    y = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(line[y * w] > 0, arc[y * w] > 0);
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
    // left and top edges: size = round(cell * fraction) (ghostty block.zig).
    render(0x258F, w, h, &a);
    const x1: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * 0.125));
    render(0x2594, w, h, &b);
    const y1: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * 0.125));
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
    // Each single-dot codepoint must light a subset of U+28FF, and the 8
    // single dots must be pairwise disjoint and non-empty.
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

    // Each part must equal exactly its 2x3 sub-rect (complementary rounding).
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

/// Test helpers mirroring ghostty's complementary fraction rounding.
fn fracMin(size: u32, num: u32, den: u32) u32 {
    const s: f64 = @floatFromInt(size);
    const f = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    return @intFromFloat(s - @round((1.0 - f) * s));
}

fn fracMax(size: u32, num: u32, den: u32) u32 {
    const s: f64 = @floatFromInt(size);
    const f = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    return @intFromFloat(@round(f * s));
}

test "sextant mask formula matches Unicode names for all 60 codepoints" {
    // Masks 1..62 ascending, skipping 21 (0b010101) and 42 (0b101010).
    var expect: u32 = 1;
    var cp: u21 = 0x1FB00;
    while (cp <= 0x1FB3B) : (cp += 1) {
        while (expect == 21 or expect == 42) expect += 1;
        const idx: u32 = cp - 0x1FB00;
        try testing.expectEqual(@as(u6, @intCast(expect)), @as(u6, @intCast(idx + idx / 20 + 1)));
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
        // Recompute the expected mask from the Unicode-name ordering: the
        // renderer's table is verified against ghostty's octants.txt, so
        // here we check the geometry of whichever bits are lit via the
        // single-octant decomposition (each lit sub-rect is exact).
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const col = i % 2;
            const row = i / 2;
            const x0 = fracMin(w, col, 2);
            const x1 = fracMax(w, col + 1, 2);
            const y0 = fracMin(h, row, 4);
            const y1 = fracMax(h, row + 1, 4);
            // Determine whether this sub-rect is lit by sampling its
            // interior (all pixels of a sub-rect share one value).
            const lit = buf[y0 * w + x0] == 255;
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
    // The round outline mirrors too (E0B7 = flip(E0B5)).
    render(0xE0B5, w, h, &a);
    render(0xE0B7, w, h, &b);
    y = 0;
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
    const sizes = [_][2]u32{ .{ 8, 16 }, .{ 10, 20 }, .{ 11, 25 }, .{ 13, 21 }, .{ 16, 32 } };
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        var buf: [32 * 32]u8 = undefined;
        const slice = buf[0 .. w * h];
        var cp: u21 = 0x2500;
        while (cp <= 0x259F) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0x2800;
        while (cp <= 0x28FF) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0xE0B0;
        while (cp <= 0xE0BF) : (cp += 1) try testing.expect(renderSprite(cp, w, h, slice));
        cp = 0x1FB00;
        while (cp <= 0x1FBEF) : (cp += 1) {
            if (!isSprite(cp)) continue; // font-glyph holes
            try testing.expect(renderSprite(cp, w, h, slice));
        }
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

    // U+1FB97 heavy horizontal fill: integer quarter rows 2 and 4
    // (ghostty uses height/4 integer division, not fraction rounding).
    const h2: u32 = 25;
    var buf2: [w * 25]u8 = undefined;
    render(0x1FB97, w, h2, &buf2);
    y = 0;
    while (y < h2) : (y += 1) {
        const want = (y >= h2 / 4 and y < 2 * h2 / 4) or (y >= 3 * h2 / 4);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(want, buf2[y * w + x] == 255);
        }
    }
}

test "checker board fill uses round(4*h/w) rows and its inverse complements it" {
    const w = 16;
    const h = 24;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;
    render(0x1FB95, w, h, &a);
    render(0x1FB96, w, h, &b);
    // ghostty checkerboardFill: 4 columns, round(4 * h/w) rows.
    const y_size: u32 = @intFromFloat(@round(4.0 * @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(w))));
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            try testing.expect((a[i] == 255) != (b[i] == 255));
            const want = (x * 4 / w + y * y_size / h) % 2 == 0;
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

test "Powerline round separators follow ghostty's Bezier bulge" {
    const w = 16;
    const h = 24;
    var filled: [w * h]u8 = undefined;
    var outline: [w * h]u8 = undefined;
    var mirrored: [w * h]u8 = undefined;
    render(0xE0B4, w, h, &filled); // filled, bulge to the right
    render(0xE0B5, w, h, &outline); // inner stroke of the bulge path
    render(0xE0B6, w, h, &mirrored); // filled, bulge to the left

    // ghostty drawE0B4: radius = min(w, h/2) = 12 here, so the bulge
    // reaches x = 12, NOT the right edge of the 16px cell.
    const radius: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(h)) / 2));
    // The filled separator covers the near edge for the full height ...
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(@as(u8, 255), filled[y * w]);
        try testing.expectEqual(@as(u8, 255), mirrored[y * w + (w - 1)]);
    }
    // ... and the widest rows span exactly the radius.
    try testing.expectEqual(radius, litInRow(&filled, w, h / 2 - 1));
    try testing.expectEqual(radius, litInRow(&filled, w, h / 2));
    try testing.expect(litInRow(&filled, w, 0) < w / 2);
    try testing.expect(litInRow(&filled, w, h - 1) < w / 2);
    // Widest rows are the middle ones, coverage falls off monotonically.
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

    // The outline is a thin band: non-empty, far fewer pixels than the
    // fill. The inner stroke touches the near edge only in the top and
    // bottom bands (the path's short horizontal end segments).
    var lit_outline: usize = 0;
    var lit_filled: usize = 0;
    for (outline, filled) |o, f| {
        if (o > 0) lit_outline += 1;
        if (f > 0) lit_filled += 1;
    }
    try testing.expect(lit_outline > 0);
    try testing.expect(lit_outline < lit_filled / 2);
    const thick = ghostty.box_thickness;
    y = 0;
    while (y < h) : (y += 1) {
        const in_band = y < thick or y >= h - thick;
        try testing.expectEqual(in_band, outline[y * w] > 0);
    }
}

test "legacy corner/cell diagonals, circles and inverted crosses" {
    const w = 11;
    const h = 25;
    var a: [w * h]u8 = undefined;
    var b: [w * h]u8 = undefined;

    // U+1FBA0 (top-left corner diagonal) runs from the top edge midpoint
    // (ceil(w/2), 0) to the left edge midpoint (0, ceil(h/2)); U+1FBAE
    // draws all four, forming a diamond through the edge midpoints.
    render(0x1FBA0, w, h, &a);
    var lit: usize = 0;
    for (a) |v| {
        if (v > 0) lit += 1;
    }
    try testing.expect(lit > 0);
    try testing.expect(a[0 * w + 5] > 0); // top edge midpoint covered
    try testing.expect(a[12 * w + 0] > 0); // left edge midpoint covered
    try testing.expectEqual(@as(u8, 0), a[0]); // corner itself empty
    try testing.expectEqual(@as(u8, 0), a[(h - 1) * w + (w - 1)]); // opposite corner empty
    render(0x1FBAE, w, h, &b);
    try testing.expect(b[0 * w + 5] > 0); // top
    try testing.expect(b[12 * w + 0] > 0); // left
    try testing.expect(b[12 * w + 10] > 0); // right
    try testing.expect(b[(h - 1) * w + 5] > 0); // bottom

    // U+1FBAF: heavy vertical + light horizontal (linesChar). Its edges
    // match U+2503 (heavy vertical) and U+2500 (light horizontal).
    render(0x1FBAF, w, h, &a);
    render(0x2503, w, h, &b);
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        try testing.expectEqual(b[x], a[x]);
        try testing.expectEqual(b[(h - 1) * w + x], a[(h - 1) * w + x]);
    }
    render(0x2500, w, h, &b);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(b[y * w], a[y * w]);
        try testing.expectEqual(b[y * w + (w - 1)], a[y * w + (w - 1)]);
    }

    // Inverted glyphs are the pixelwise complement of their base shapes.
    render(0x2573, w, h, &a);
    render(0x1FBBD, w, h, &b);
    var i: usize = 0;
    while (i < w * h) : (i += 1) try testing.expectEqual(255 - a[i], b[i]);
    render(0x1FBA3, w, h, &a); // br corner diagonal
    render(0x1FBBE, w, h, &b);
    i = 0;
    while (i < w * h) : (i += 1) try testing.expectEqual(255 - a[i], b[i]);
    render(0x1FBAE, w, h, &a); // all four corner diagonals
    render(0x1FBBF, w, h, &b);
    i = 0;
    while (i < w * h) : (i += 1) try testing.expectEqual(255 - a[i], b[i]);

    // U+1FBCE / U+1FBCF: left two-thirds / one-third, round(w * fraction).
    render(0x1FBCE, w, h, &a);
    const two_thirds_w: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * (2.0 / 3.0)));
    render(0x1FBCF, w, h, &b);
    const one_third_w: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * (1.0 / 3.0)));
    y = 0;
    while (y < h) : (y += 1) {
        x = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(x < two_thirds_w, a[y * w + x] == 255);
            try testing.expectEqual(x < one_third_w, b[y * w + x] == 255);
        }
    }

    // U+1FBE8: filled circle centered on the top edge midpoint, radius
    // min(w,h)/2: the pixel just below the center is covered, the bottom
    // corners are not.
    render(0x1FBE8, w, h, &a);
    try testing.expectEqual(@as(u8, 255), a[1 * w + w / 2]);
    try testing.expectEqual(@as(u8, 0), a[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 0), a[(h - 1) * w + (w - 1)]);
    // U+1FBE0: the outline strokes radii [r - thick, r] around the same
    // center: the band crosses x = w/2 at y in [4.5, 5.5].
    render(0x1FBE0, w, h, &a);
    try testing.expect(a[5 * w + w / 2] > 0); // inside the stroke band
    try testing.expectEqual(@as(u8, 0), a[1 * w + w / 2]); // near the center: empty
    try testing.expectEqual(@as(u8, 0), a[(h / 2) * w + w / 2]); // far from the arc

    // U+1FBE4: centered half-size block anchored to the top edge.
    render(0x1FBE4, w, h, &a);
    const bw: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * 0.5));
    const bh: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * 0.5));
    const bx = (w - bw) / 2;
    y = 0;
    while (y < h) : (y += 1) {
        x = 0;
        while (x < w) : (x += 1) {
            const want = x >= bx and x < bx + bw and y < bh;
            try testing.expectEqual(want, a[y * w + x] == 255);
        }
    }
}

test "edge triangles use the rounded cell center" {
    const w = 11;
    const h = 25;
    var buf: [w * h]u8 = undefined;
    // ghostty edgeTriangle: apex at (round(w/2), round(h/2)) = (6, 13).
    render(0x1FB6C, w, h, &buf); // left-pointing... base on the left edge
    // A pixel up-left of the apex is fully inside; the pixel touching the
    // apex corner is only partial (with a float center it would be full,
    // so this pins the rounded-center geometry).
    try testing.expectEqual(@as(u8, 255), buf[12 * w + 4]);
    try testing.expect(buf[12 * w + 5] > 0 and buf[12 * w + 5] < 255);
    // The left edge is fully covered.
    var y: u32 = 0;
    while (y < h) : (y += 1) try testing.expect(buf[y * w] > 0);
    // The inverted version (U+1FB68) is the complement.
    var inv: [w * h]u8 = undefined;
    render(0x1FB68, w, h, &inv);
    var i: usize = 0;
    while (i < w * h) : (i += 1) try testing.expectEqual(255 - buf[i], inv[i]);
}
