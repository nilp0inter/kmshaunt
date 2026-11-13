//! src/font/bitmap.zig -- built-in bitmap font engines (ROADMAP M3.9).
//!
//! These engines are the last resort when fontconfig finds nothing: the
//! `8x16` engine (a built-in cell ROM font plus code-drawn box drawing and
//! block elements) and the `unifont` engine (GNU Unifont `.hex` data loaded at
//! runtime, 8x16 narrow and 16x16 wide glyphs). Both share one cell metric:
//! 8 pixels wide, 16 pixels tall, so a narrow glyph always occupies one cell
//! and a wide glyph exactly two.
//!
//! Glyph data for ASCII and Latin-1 comes verbatim from the UNSCII-16 font by
//! Viznut (<https://github.com/viznut/unscii>, `fontfiles/unscii-16.hex`).
//! Its README places the font in the public domain / CC0, except for the
//! `unscii-16-full.*` files, which merge GPL Unifont data; `unscii-16.hex` is
//! not one of those. UNSCII-16 reproduces the classic 8x16 system ROM shapes,
//! so `A`, `0`, the accented Latin letters and the rest are the familiar
//! terminal bitmaps rather than something drawn here. The table below stores
//! one glyph per line: 32 hex digits = 16 rows of one byte, rows top to
//! bottom, bit 7 of each byte the leftmost pixel, after the CP437-style
//! enumeration `0x20..0x7E, 0xA0..0xFF`.
//!
//! Box drawing (U+2500..U+257F) and block elements (U+2580..U+259F) are drawn
//! in code, not taken from the ROM table, so stems always land on the same
//! pixel row/column and join exactly across cell boundaries (the same
//! requirement that drives `sprite.zig`). Light horizontals are one pixel on
//! row `height / 2`, heavy ones three pixels, double ones two one-pixel lines;
//! the edge tables below are derived from the Unicode character names (for
//! example `BOX DRAWINGS DOWN LIGHT AND RIGHT HEAVY`) and only carry the four
//! edge weights. Dash patterns, arcs, diagonals and the half-lines have their
//! own small renderers.
//!
//! U+FFFD is a code-drawn boxed question mark. Codepoints with no glyph in any
//! of the above sources render as a procedural "hex box": a bordered tofu
//! cell with the codepoint in hexadecimal (four digits for a narrow cell, six
//! for a wide one) drawn from a 3x5 micro font. Wide codepoints are those in
//! the East Asian Width W/F ranges approximated by `isWide`; their fallback
//! box is two cells wide, matching what libghostty reports as the cell width.
//!
//! Unifont hex format (`loadUnifontHex`): one `CODEPOINT:HEX` line per glyph,
//! codepoint in hex, bitmap either 32 hex digits (8x16) or 64 hex digits
//! (16x16), rows top to bottom. Lines starting with `#` and blank lines are
//! ignored. Loading the file is optional: the engine works with just the
//! built-in table and hex boxes.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Width of one font cell in pixels.
pub const cell_width: u8 = 8;
/// Height of one font cell in pixels.
pub const cell_height: u8 = 16;
/// Coverage bytes of one narrow cell.
const cell_pixels: usize = @as(usize, cell_width) * cell_height;

/// Number of built-in glyph bitmaps: 95 ASCII + 96 Latin-1.
pub const rom_glyph_count: usize = 191;

/// One 8x16 glyph per line, 32 hex digits, rows top to bottom, MSB leftmost.
/// See the module comment for the source (UNSCII-16, public domain).
const rom_hex =
    \\00000000000000000000000000000000
    \\00181818181818181800001818000000
    \\00666666000000000000000000000000
    \\00006C6C6CFE6C6C6CFE6C6C6C000000
    \\0018183C666030180C06663C18180000
    \\000006C6CCCC181830306666C6C00000
    \\0000386C6C38307ADECCCCCC76000000
    \\00181818300000000000000000000000
    \\000C18183030303030303018180C0000
    \\003018180C0C0C0C0C0C0C1818300000
    \\0000000066663CFF3C66660000000000
    \\000000001818187E1818180000000000
    \\00000000000000000000381818306000
    \\000000000000007E0000000000000000
    \\00000000000000000000181818000000
    \\030306060C0C181830306060C0C00000
    \\0000386CC6C6CED6E6C6C66C38000000
    \\0000183878181818181818187E000000
    \\00003C666606060C183060607E000000
    \\00003C666606061C060666663C000000
    \\00000C1C3C6CCCCCFE0C0C0C0C000000
    \\00007E6060607C06060666663C000000
    \\00001C3060607C66666666663C000000
    \\00007E0606060C0C1818181818000000
    \\00003C666666763C6E6666663C000000
    \\00003C666666663E0606060C38000000
    \\00000018181800000000181818000000
    \\00000018181800000000381818306000
    \\000000060C18306030180C0600000000
    \\00000000007E0000007E000000000000
    \\0000006030180C060C18306000000000
    \\003C6666060C18181800001818000000
    \\00007CC6C6C6DEDEDEDCC0C07C000000
    \\0000183C6666667E6666666666000000
    \\00007C6666666C786C6666667C000000
    \\00003C6666606060606066663C000000
    \\0000786C666666666666666C78000000
    \\00007E606060607C606060607E000000
    \\00007E6060607C606060606060000000
    \\00003C666660606E666666663E000000
    \\000066666666667E6666666666000000
    \\00007E1818181818181818187E000000
    \\0000060606060606060666663C000000
    \\0000C6C6CCCCD8F0D8CCCCC6C6000000
    \\0000606060606060606060607E000000
    \\0000C6EEEEFED6D6C6C6C6C6C6000000
    \\0000C6C6E6E6F6FEDECECEC6C6000000
    \\00003C6666666666666666663C000000
    \\00007C666666667C6060606060000000
    \\00003C6666666666666666663C0C0600
    \\00007C666666667C6C66666666000000
    \\00003C66666030180C0666663C000000
    \\00007E18181818181818181818000000
    \\0000666666666666666666663C000000
    \\0000666666666666663C3C1818000000
    \\0000C6C6C6C6C6D6D6FEEEEEC6000000
    \\0000C3C3663C1818183C66C3C3000000
    \\0000C3C366663C181818181818000000
    \\00007E06060C0C18303060607E000000
    \\003C30303030303030303030303C0000
    \\C0C06060303018180C0C060603030000
    \\003C0C0C0C0C0C0C0C0C0C0C0C3C0000
    \\0010386C6CC6C6000000000000000000
    \\000000000000000000000000000000FF
    \\0018180C060000000000000000000000
    \\0000000000003C063E6666663E000000
    \\0000606060607C66666666667C000000
    \\0000000000003C66606060663C000000
    \\0000060606063E66666666663E000000
    \\0000000000003C66667E60603C000000
    \\00001E3030307E303030303030000000
    \\0000000000003E66666666663E06067C
    \\0000606060607C666666666666000000
    \\0000181800007818181818181E000000
    \\00000C0C00000C0C0C0C0C0C0C0C0C78
    \\00006060606066666C786C6666000000
    \\0000781818181818181818181E000000
    \\000000000000CCFED6D6D6D6C6000000
    \\0000000000007C666666666666000000
    \\0000000000003C66666666663C000000
    \\0000000000007C66666666667C606060
    \\0000000000003E66666666663E060606
    \\0000000000007C666660606060000000
    \\0000000000003E60603C06067C000000
    \\0000003030307E30303030301E000000
    \\0000000000006666666666663E000000
    \\00000000000066666666663C18000000
    \\000000000000C6C6D6D6D67C6C000000
    \\000000000000C6C66C386CC6C6000000
    \\0000000000006666666666663E06063C
    \\0000000000007E060C1830607E000000
    \\000E1818181818F018181818180E0000
    \\18181818181818181818181818180000
    \\00E030303030301E3030303030E00000
    \\0072D69C000000000000000000000000
    \\00000000000000000000000000000000
    \\00181800001818181818181818000000
    \\001818183C666060663C181818000000
    \\0000386C6C6060F060606666FC000000
    \\0000663C6666663C6600000000000000
    \\0000C3C366663C187E187E1818000000
    \\18181818181800001818181818180000
    \\003C666030386C66361C0C06663C0000
    \\66660000000000000000000000000000
    \\00003C42819DB1B1B19D81423C000000
    \\003C06063E66663E007E000000000000
    \\00000000003366CC6633000000000000
    \\000000000000FE060606060000000000
    \\000000000000003C0000000000000000
    \\00003C4281B9A5B9A5A581423C000000
    \\7E000000000000000000000000000000
    \\003C66663C0000000000000000000000
    \\000000001818187E181818007E000000
    \\00386C0C1830607C0000000000000000
    \\00386C0C380C6C380000000000000000
    \\0C0C1818303000000000000000000000
    \\0000000000006666666666667C6060C0
    \\00003E7A7A7A7A3A1A1A1A1A1A000000
    \\00000000000000180000000000000000
    \\000000000000000000000000000C061C
    \\00307030303030300000000000000000
    \\0000003C6666663C007E000000000000
    \\0000000000CC663366CC000000000000
    \\0040C6464C4C181830306266CACF0200
    \\0040C6464C4C181830306C62C4C80E00
    \\00C026662CCC181830306266CACF0200
    \\0018180000183030606066663C000000
    \\301800183C6666667E66666666000000
    \\0C1800183C6666667E66666666000000
    \\186600183C6666667E66666666000000
    \\76DC00183C6666667E66666666000000
    \\666600183C6666667E66666666000000
    \\3C663C00183C66667E66666666000000
    \\00003F7CFCCCCCFECCCCCCCCCF000000
    \\00003C6666606060606066663C0C061C
    \\3018007E6060607C606060607E000000
    \\0C18007E6060607C606060607E000000
    \\1866007E6060607C606060607E000000
    \\6666007E6060607C606060607E000000
    \\3018007E18181818181818187E000000
    \\0C18007E18181818181818187E000000
    \\1866007E18181818181818187E000000
    \\6666007E18181818181818187E000000
    \\0000786C666666F66666666C78000000
    \\76DC00C6C6E6F6DECEC6C6C6C6000000
    \\3018003C66666666666666663C000000
    \\0C18003C66666666666666663C000000
    \\1866003C66666666666666663C000000
    \\76DC003C66666666666666663C000000
    \\6666003C66666666666666663C000000
    \\0000000082C66C386CC6820000000000
    \\00003E666E6E6E7E767676667C000000
    \\3018006666666666666666663C000000
    \\0C18006666666666666666663C000000
    \\1866006666666666666666663C000000
    \\6666006666666666666666663C000000
    \\0C1800666666663C1818181818000000
    \\0000C0C0FCC6C6C6C6C6FCC0C0000000
    \\000078CCCCCCD8CCC6C6C6C6CC000000
    \\0000301800003C063E6666663E000000
    \\00000C1800003C063E6666663E000000
    \\00183C6600003C063E6666663E000000
    \\000076DC00003C063E6666663E000000
    \\0000666600003C063E6666663E000000
    \\00003C663C003C063E6666663E000000
    \\0000000000007E1B1B7FD8D877000000
    \\0000000000003C66606060663C0C061C
    \\0000301800003C66667E60603C000000
    \\00000C1800003C66667E60603C000000
    \\00183C6600003C66667E60603C000000
    \\0000666600003C66667E60603C000000
    \\0000301800003818181818183C000000
    \\00000C1800003818181818183C000000
    \\00183C6600003818181818183C000000
    \\0000666600003818181818183C000000
    \\00361C1C36063E66666666663C000000
    \\000076DC00007C666666666666000000
    \\0000301800003C66666666663C000000
    \\00000C1800003C66666666663C000000
    \\00183C6600003C66666666663C000000
    \\000076DC00003C66666666663C000000
    \\0000666600003C66666666663C000000
    \\000000001818007E0018180000000000
    \\0000000000003D666E7E7666BC000000
    \\0000301800006666666666663E000000
    \\00000C1800006666666666663E000000
    \\00183C6600006666666666663E000000
    \\0000666600006666666666663E000000
    \\00000C1800006666666666663E06063C
    \\0000006060607C66666666667C606060
    \\0000666600006666666666663E06063C
;

fn comptimeHexDigit(c: u8) u8 {
    return std.fmt.charToDigit(c, 16) catch
        @compileError("bitmap.zig: bad hex digit in the embedded glyph table");
}

/// Decode one byte from two hex digits, for the runtime Unifont parser.
fn parseHexByte(text: []const u8, at: usize) !u8 {
    const hi = std.fmt.charToDigit(text[at], 16) catch return error.InvalidGlyphData;
    const lo = std.fmt.charToDigit(text[at + 1], 16) catch return error.InvalidGlyphData;
    return (hi << 4) | lo;
}

const rom_glyphs: [rom_glyph_count][16]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var glyphs: [rom_glyph_count][16]u8 = undefined;
    var lines = std.mem.splitScalar(u8, rom_hex, '\n');
    var index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (index == rom_glyph_count) @compileError("bitmap.zig: too many glyph lines");
        if (line.len != 32) @compileError("bitmap.zig: glyph line must be 32 hex digits");
        for (0..16) |row| {
            glyphs[index][row] =
                (comptimeHexDigit(line[2 * row]) << 4) | comptimeHexDigit(line[2 * row + 1]);
        }
        index += 1;
    }
    if (index != rom_glyph_count) @compileError("bitmap.zig: missing glyph lines");
    break :blk glyphs;
};

/// Glyph index in `rom_glyphs`, or null when the codepoint is not covered by
/// the built-in table (box drawing, blocks and U+FFFD are code-drawn).
fn builtinGlyphIndex(cp: u21) ?usize {
    if (cp >= 0x20 and cp <= 0x7E) return @intCast(cp - 0x20);
    if (cp >= 0xA0 and cp <= 0xFF) return @intCast(95 + (cp - 0xA0));
    return null;
}

// ---------------------------------------------------------------------------
// Box drawing (U+2500..U+257F)
// ---------------------------------------------------------------------------

const EdgeStyle = enum(u2) {
    none = 0,
    light = 1,
    heavy = 2,
    double = 3,
};

/// Four two-bit edge weights, packed as `up | down << 2 | left << 4 | right << 6`.
/// Derived from the Unicode character names; `0` marks a codepoint that has a
/// dedicated renderer (dashes, arcs, diagonals, half-lines) rather than plain
/// edge strokes.
const box_specs: [128]u8 = .{
    0x50, 0xa0, 0x05, 0x0a, 0x00, 0x00, 0x00, 0x00, // U+2500..U+2507
    0x00, 0x00, 0x00, 0x00, 0x44, 0x84, 0x48, 0x88, // U+2508..U+250F
    0x14, 0x24, 0x18, 0x28, 0x41, 0x81, 0x42, 0x82, // U+2510..U+2517
    0x11, 0x21, 0x12, 0x22, 0x45, 0x85, 0x46, 0x49, // U+2518..U+251F
    0x4a, 0x86, 0x89, 0x8a, 0x15, 0x25, 0x16, 0x19, // U+2520..U+2527
    0x1a, 0x26, 0x29, 0x2a, 0x54, 0x64, 0x94, 0xa4, // U+2528..U+252F
    0x58, 0x68, 0x98, 0xa8, 0x51, 0x61, 0x91, 0xa1, // U+2530..U+2537
    0x52, 0x62, 0x92, 0xa2, 0x55, 0x65, 0x95, 0xa5, // U+2538..U+253F
    0x56, 0x59, 0x5a, 0x66, 0x96, 0x69, 0x99, 0xa6, // U+2540..U+2547
    0xa9, 0x6a, 0x9a, 0xaa, 0x00, 0x00, 0x00, 0x00, // U+2548..U+254F
    0xf0, 0x0f, 0xc4, 0x4c, 0xcc, 0x34, 0x1c, 0x3c, // U+2550..U+2557
    0xc1, 0x43, 0xc3, 0x31, 0x13, 0x33, 0xc5, 0x4f, // U+2558..U+255F
    0xcf, 0x35, 0x1f, 0x3f, 0xf4, 0x5c, 0xfc, 0xf1, // U+2560..U+2567
    0x53, 0xf3, 0xf5, 0x5f, 0xff, 0x00, 0x00, 0x00, // U+2568..U+256F
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // U+2570..U+2577
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // U+2578..U+257F
};

const Side = enum { up, down, left, right };

fn edgeStyle(spec: u8, comptime shift: u3) EdgeStyle {
    return @enumFromInt((spec >> shift) & 0x03);
}

fn hTop(style: EdgeStyle) usize {
    return switch (style) {
        .none => 0,
        .light => 8,
        .heavy => 7,
        .double => 6,
    };
}

fn hBottom(style: EdgeStyle) usize {
    return switch (style) {
        .none => 0,
        .light => 8,
        .heavy => 9,
        .double => 9,
    };
}

fn vLeft(style: EdgeStyle) usize {
    return switch (style) {
        .none => 0,
        .light => 4,
        .heavy => 3,
        .double => 2,
    };
}

fn vRight(style: EdgeStyle) usize {
    return switch (style) {
        .none => 0,
        .light => 4,
        .heavy => 5,
        .double => 5,
    };
}

fn topOfHorizontals(left: EdgeStyle, right: EdgeStyle) usize {
    var top: usize = cell_height - 1;
    if (left != .none) top = @min(top, hTop(left));
    if (right != .none) top = @min(top, hTop(right));
    return top;
}

fn bottomOfHorizontals(left: EdgeStyle, right: EdgeStyle) usize {
    var bottom: usize = 0;
    if (left != .none) bottom = @max(bottom, hBottom(left));
    if (right != .none) bottom = @max(bottom, hBottom(right));
    return bottom;
}

fn leftOfVerticals(up: EdgeStyle, down: EdgeStyle) usize {
    var left: usize = cell_width - 1;
    if (up != .none) left = @min(left, vLeft(up));
    if (down != .none) left = @min(left, vLeft(down));
    return left;
}

fn rightOfVerticals(up: EdgeStyle, down: EdgeStyle) usize {
    var right: usize = 0;
    if (up != .none) right = @max(right, vRight(up));
    if (down != .none) right = @max(right, vRight(down));
    return right;
}

fn putRow(out: []u8, stride: usize, y: usize, x0: usize, x1: usize) void {
    var x = x0;
    while (x <= x1) : (x += 1) out[y * stride + x] = 255;
}

fn putColumn(out: []u8, stride: usize, x: usize, y0: usize, y1: usize) void {
    var y = y0;
    while (y <= y1) : (y += 1) out[y * stride + x] = 255;
}

fn fillRow(out: []u8, y: usize, x0: usize, x1: usize) void {
    putRow(out, cell_width, y, x0, x1);
}

fn fillRowBand(out: []u8, y0: usize, y1: usize, x0: usize, x1: usize) void {
    var y = y0;
    while (y <= y1) : (y += 1) fillRow(out, y, x0, x1);
}

fn fillColumn(out: []u8, x: usize, y0: usize, y1: usize) void {
    putColumn(out, cell_width, x, y0, y1);
}

fn fillColumnBand(out: []u8, x0: usize, x1: usize, y0: usize, y1: usize) void {
    var x = x0;
    while (x <= x1) : (x += 1) fillColumn(out, x, y0, y1);
}

fn fillRect(out: []u8, x0: usize, x1: usize, y0: usize, y1: usize) void {
    fillRowBand(out, y0, y1, x0, x1);
}

fn renderVerticalStroke(
    side: Side,
    style: EdgeStyle,
    other: EdgeStyle,
    left: EdgeStyle,
    right: EdgeStyle,
    h_top: usize,
    h_bottom: usize,
    out: []u8,
) void {
    const has_h = left != .none or right != .none;

    // Double strokes are two parallel one-pixel lines. Where only one half of
    // the cell is drawn, the outer line turns the corner one gap earlier than
    // the inner one, which is what makes ╔/╗/╚/╝ and the double tees join.
    if (style == .double and other == .none and (left == .double or right == .double)) {
        if (side == .down) {
            fillColumn(out, 2, 6, cell_height - 1);
            fillColumn(out, 5, 9, cell_height - 1);
        } else {
            fillColumn(out, 2, 0, 9);
            fillColumn(out, 5, 0, 6);
        }
        return;
    }

    var y0: usize = 0;
    var y1: usize = cell_height - 1;
    if (!has_h) {
        // A free-standing vertical spans the whole cell.
    } else if (other == .none) {
        if (side == .up) y1 = h_bottom else y0 = h_top;
    } else if (other != style) {
        // Two different weights meeting at the horizontal band: each stops at
        // the far side of that band so both are visible on their half.
        if (side == .up) y1 = h_bottom else y0 = h_top;
    }

    if (style == .double) {
        fillColumn(out, 2, y0, y1);
        fillColumn(out, 5, y0, y1);
    } else {
        fillColumnBand(out, vLeft(style), vRight(style), y0, y1);
    }
}

fn renderHorizontalStroke(
    side: Side,
    style: EdgeStyle,
    other: EdgeStyle,
    up: EdgeStyle,
    down: EdgeStyle,
    v_left: usize,
    v_right: usize,
    out: []u8,
) void {
    const has_v = up != .none or down != .none;

    if (style == .double and other == .none and (up == .double or down == .double)) {
        if (side == .right) {
            fillRow(out, 6, 2, cell_width - 1);
            fillRow(out, 9, 5, cell_width - 1);
        } else {
            fillRow(out, 6, 0, 5);
            fillRow(out, 9, 0, 2);
        }
        return;
    }

    var x0: usize = 0;
    var x1: usize = cell_width - 1;
    if (!has_v) {
        // A free-standing horizontal spans the whole cell.
    } else if (other == .none) {
        if (side == .left) x1 = v_right else x0 = v_left;
    } else if (other != style) {
        if (side == .left) x1 = v_right else x0 = v_left;
    }

    if (style == .double) {
        fillRow(out, 6, x0, x1);
        fillRow(out, 9, x0, x1);
    } else {
        fillRowBand(out, hTop(style), hBottom(style), x0, x1);
    }
}

fn renderEdges(spec: u8, out: []u8) void {
    const up = edgeStyle(spec, 0);
    const down = edgeStyle(spec, 2);
    const left = edgeStyle(spec, 4);
    const right = edgeStyle(spec, 6);

    const h_top = topOfHorizontals(left, right);
    const h_bottom = bottomOfHorizontals(left, right);
    const v_left = leftOfVerticals(up, down);
    const v_right = rightOfVerticals(up, down);

    if (up != .none) {
        renderVerticalStroke(.up, up, down, left, right, h_top, h_bottom, out);
    }
    if (down != .none) {
        renderVerticalStroke(.down, down, up, left, right, h_top, h_bottom, out);
    }
    if (left != .none) {
        renderHorizontalStroke(.left, left, right, up, down, v_left, v_right, out);
    }
    if (right != .none) {
        renderHorizontalStroke(.right, right, left, up, down, v_left, v_right, out);
    }
}

fn renderDash(offset: usize, out: []u8) void {
    switch (offset) {
        0x04 => { // light triple dash horizontal
            fillRow(out, 8, 0, 1);
            fillRow(out, 8, 3, 4);
            fillRow(out, 8, 6, 7);
        },
        0x05 => { // heavy triple dash horizontal
            fillRowBand(out, 7, 9, 0, 1);
            fillRowBand(out, 7, 9, 3, 4);
            fillRowBand(out, 7, 9, 6, 7);
        },
        0x06 => { // light triple dash vertical
            fillColumn(out, 4, 0, 3);
            fillColumn(out, 4, 6, 9);
            fillColumn(out, 4, 12, 15);
        },
        0x07 => { // heavy triple dash vertical
            fillColumnBand(out, 3, 5, 0, 3);
            fillColumnBand(out, 3, 5, 6, 9);
            fillColumnBand(out, 3, 5, 12, 15);
        },
        0x08 => { // light quadruple dash horizontal
            fillRow(out, 8, 0, 0);
            fillRow(out, 8, 2, 2);
            fillRow(out, 8, 4, 4);
            fillRow(out, 8, 6, 6);
        },
        0x09 => { // heavy quadruple dash horizontal
            fillRowBand(out, 7, 9, 0, 0);
            fillRowBand(out, 7, 9, 2, 2);
            fillRowBand(out, 7, 9, 4, 4);
            fillRowBand(out, 7, 9, 6, 6);
        },
        0x0A => { // light quadruple dash vertical
            fillColumn(out, 4, 0, 2);
            fillColumn(out, 4, 4, 6);
            fillColumn(out, 4, 8, 10);
            fillColumn(out, 4, 12, 14);
        },
        0x0B => { // heavy quadruple dash vertical
            fillColumnBand(out, 3, 5, 0, 2);
            fillColumnBand(out, 3, 5, 4, 6);
            fillColumnBand(out, 3, 5, 8, 10);
            fillColumnBand(out, 3, 5, 12, 14);
        },
        else => unreachable,
    }
}

fn renderDoubleDash(offset: usize, out: []u8) void {
    switch (offset) {
        0x4C => { // light double dash horizontal
            fillRow(out, 8, 0, 2);
            fillRow(out, 8, 5, 7);
        },
        0x4D => { // heavy double dash horizontal
            fillRowBand(out, 7, 9, 0, 2);
            fillRowBand(out, 7, 9, 5, 7);
        },
        0x4E => { // light double dash vertical
            fillColumn(out, 4, 0, 6);
            fillColumn(out, 4, 9, 15);
        },
        0x4F => { // heavy double dash vertical
            fillColumnBand(out, 3, 5, 0, 6);
            fillColumnBand(out, 3, 5, 9, 15);
        },
        else => unreachable,
    }
}

fn renderArc(offset: usize, out: []u8) void {
    switch (offset) {
        0x6D => { // down and right
            fillRow(out, 8, 5, 7);
            fillColumn(out, 4, 9, 15);
        },
        0x6E => { // down and left
            fillRow(out, 8, 0, 3);
            fillColumn(out, 4, 9, 15);
        },
        0x6F => { // up and left
            fillRow(out, 8, 0, 3);
            fillColumn(out, 4, 0, 7);
        },
        0x70 => { // up and right
            fillRow(out, 8, 5, 7);
            fillColumn(out, 4, 0, 7);
        },
        else => unreachable,
    }
}

fn renderDiagonal(offset: usize, out: []u8) void {
    const draw_slash = offset == 0x71 or offset == 0x73;
    const draw_backslash = offset == 0x72 or offset == 0x73;
    var y: usize = 0;
    while (y < cell_height) : (y += 1) {
        // Corner-to-corner 45-degree walk: row 0 at one edge, row 15 at the
        // other, with integer rounding so every row has exactly one pixel.
        const dx = (y * (cell_width - 1) + (cell_height - 1) / 2) / (cell_height - 1);
        if (draw_slash) out[y * cell_width + (cell_width - 1 - dx)] = 255;
        if (draw_backslash) out[y * cell_width + dx] = 255;
    }
}

fn renderHalfLine(offset: usize, out: []u8) void {
    switch (offset) {
        0x74 => fillRow(out, 8, 0, 3), // light left
        0x75 => fillColumn(out, 4, 0, 7), // light up
        0x76 => fillRow(out, 8, 4, 7), // light right
        0x77 => fillColumn(out, 4, 8, 15), // light down
        0x78 => fillRowBand(out, 7, 9, 0, 3), // heavy left
        0x79 => fillColumnBand(out, 3, 5, 0, 7), // heavy up
        0x7A => fillRowBand(out, 7, 9, 4, 7), // heavy right
        0x7B => fillColumnBand(out, 3, 5, 8, 15), // heavy down
        0x7C => { // light left and heavy right
            fillRow(out, 8, 0, 3);
            fillRowBand(out, 7, 9, 4, 7);
        },
        0x7D => { // light up and heavy down
            fillColumn(out, 4, 0, 7);
            fillColumnBand(out, 3, 5, 8, 15);
        },
        0x7E => { // heavy left and light right
            fillRowBand(out, 7, 9, 0, 3);
            fillRow(out, 8, 4, 7);
        },
        0x7F => { // heavy up and light down
            fillColumnBand(out, 3, 5, 0, 7);
            fillColumn(out, 4, 8, 15);
        },
        else => unreachable,
    }
}

fn renderBoxDrawing(cp: u21, out: []u8) bool {
    if (cp < 0x2500 or cp > 0x257F) return false;
    @memset(out[0..cell_pixels], 0);
    const offset: usize = @intCast(cp - 0x2500);
    switch (offset) {
        0x04...0x0B => renderDash(offset, out),
        0x4C...0x4F => renderDoubleDash(offset, out),
        0x6D...0x70 => renderArc(offset, out),
        0x71...0x73 => renderDiagonal(offset, out),
        0x74...0x7F => renderHalfLine(offset, out),
        else => renderEdges(box_specs[offset], out),
    }
    return true;
}

// ---------------------------------------------------------------------------
// Block elements (U+2580..U+259F)
// ---------------------------------------------------------------------------

fn renderShade(level: u2, out: []u8) void {
    var y: usize = 0;
    while (y < cell_height) : (y += 1) {
        var x: usize = 0;
        while (x < cell_width) : (x += 1) {
            const lit = switch (level) {
                1 => (x + 2 * y) % 4 == 0, // 25 %
                2 => (x + y) % 2 == 0, // 50 %
                3 => (x + 2 * y) % 4 != 0, // 75 %
                else => unreachable,
            };
            out[y * cell_width + x] = if (lit) 255 else 0;
        }
    }
}

fn renderQuadrants(mask: u4, out: []u8) void {
    // bit 0 upper left, bit 1 upper right, bit 2 lower left, bit 3 lower right.
    if (mask & 0x01 != 0) fillRect(out, 0, 3, 0, 7);
    if (mask & 0x02 != 0) fillRect(out, 4, 7, 0, 7);
    if (mask & 0x04 != 0) fillRect(out, 0, 3, 8, 15);
    if (mask & 0x08 != 0) fillRect(out, 4, 7, 8, 15);
}

fn renderBlockElement(cp: u21, out: []u8) bool {
    if (cp < 0x2580 or cp > 0x259F) return false;
    @memset(out[0..cell_pixels], 0);
    const offset: usize = @intCast(cp - 0x2580);
    switch (offset) {
        0 => fillRect(out, 0, 7, 0, 7), // upper half block
        1...8 => { // lower one-eighth .. full block
            const eighths = offset;
            fillRect(out, 0, 7, cell_height - eighths * 2, cell_height - 1);
        },
        9...15 => { // left seven-eighths .. left one-eighth
            const width = 16 - offset;
            fillRect(out, 0, width - 1, 0, cell_height - 1);
        },
        16 => fillRect(out, 4, 7, 0, cell_height - 1), // right half block
        17 => renderShade(1, out),
        18 => renderShade(2, out),
        19 => renderShade(3, out),
        20 => fillRect(out, 0, 7, 0, 1), // upper one-eighth
        21 => fillRect(out, 7, 7, 0, cell_height - 1), // right one-eighth
        22...31 => { // quadrant blocks
            const masks = [_]u4{
                0x04, // U+2596 lower left
                0x08, // U+2597 lower right
                0x01, // U+2598 upper left
                0x0D, // U+2599 not upper right
                0x09, // U+259A upper left and lower right
                0x07, // U+259B not lower right
                0x0B, // U+259C not lower left
                0x02, // U+259D upper right
                0x06, // U+259E upper right and lower left
                0x0E, // U+259F not upper left
            };
            renderQuadrants(masks[offset - 22], out);
        },
        else => unreachable,
    }
    return true;
}

// ---------------------------------------------------------------------------
// Replacement character and procedural hex boxes
// ---------------------------------------------------------------------------

/// 3x5 micro font for the hex-box fallback and the U+FFFD question mark.
/// Each row is three bits, MSB the left pixel.
const micro_font: [17][5]u8 = .{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 }, // 3
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
    .{ 0b111, 0b001, 0b010, 0b010, 0b010 }, // 7
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
    .{ 0b010, 0b101, 0b111, 0b101, 0b101 }, // A
    .{ 0b110, 0b101, 0b110, 0b101, 0b110 }, // B
    .{ 0b011, 0b100, 0b100, 0b100, 0b011 }, // C
    .{ 0b110, 0b101, 0b101, 0b101, 0b110 }, // D
    .{ 0b111, 0b100, 0b110, 0b100, 0b111 }, // E
    .{ 0b111, 0b100, 0b110, 0b100, 0b100 }, // F
    .{ 0b111, 0b001, 0b011, 0b000, 0b010 }, // '?'
};

const micro_question: usize = 16;

fn drawMicroGlyph(out: []u8, width: usize, glyph: usize, x0: usize, y0: usize) void {
    var row: usize = 0;
    while (row < 5) : (row += 1) {
        const bits = micro_font[glyph][row];
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const shift: u3 = @intCast(2 - col);
            if ((bits >> shift) & 1 != 0) {
                out[(y0 + row) * width + x0 + col] = 255;
            }
        }
    }
}

/// U+FFFD: a bordered cell with a question mark, the conventional "not
/// representable" shape, drawn here so it exists even without Unifont data.
fn renderReplacement(out: []u8) void {
    @memset(out[0..cell_pixels], 0);
    fillRow(out, 2, 0, 7);
    fillRow(out, 13, 0, 7);
    fillColumn(out, 0, 2, 13);
    fillColumn(out, 7, 2, 13);
    drawMicroGlyph(out, cell_width, micro_question, 2, 5);
}

/// Procedural tofu: a bordered cell containing the codepoint in hexadecimal.
/// Narrow cells show the low 16 bits as four digits; wide cells show the full
/// codepoint as six digits in a 16x16 box.
fn renderHexBox(cp: u21, cells: u8, out: []u8) void {
    const width: usize = if (cells == 2) 16 else cell_width;
    const value: u32 = cp;

    if (cells == 2) {
        // The two-cell box is 16 pixels wide.
        putRow(out, width, 1, 0, width - 1);
        putRow(out, width, 14, 0, width - 1);
        putColumn(out, width, 0, 1, 14);
        putColumn(out, width, width - 1, 1, 14);

        // Six digits, two rows of three, centred in the 14-pixel interior.
        const digits = [6]usize{
            @intCast(value >> 20 & 0xF),
            @intCast(value >> 16 & 0xF),
            @intCast(value >> 12 & 0xF),
            @intCast(value >> 8 & 0xF),
            @intCast(value >> 4 & 0xF),
            @intCast(value & 0xF),
        };
        for (0..3) |i| {
            drawMicroGlyph(out, width, digits[i], 3 + i * 3, 3);
            drawMicroGlyph(out, width, digits[3 + i], 3 + i * 3, 8);
        }
    } else {
        fillRow(out, 1, 0, cell_width - 1);
        fillRow(out, 14, 0, cell_width - 1);
        fillColumn(out, 0, 1, 14);
        fillColumn(out, cell_width - 1, 1, 14);

        const digits = [4]usize{
            @intCast(value >> 12 & 0xF),
            @intCast(value >> 8 & 0xF),
            @intCast(value >> 4 & 0xF),
            @intCast(value & 0xF),
        };
        for (0..2) |i| {
            drawMicroGlyph(out, width, digits[i], 1 + i * 3, 3);
            drawMicroGlyph(out, width, digits[2 + i], 1 + i * 3, 8);
        }
    }
}

fn renderProcedural(cp: u21, out: []u8) bool {
    if (renderBoxDrawing(cp, out)) return true;
    if (renderBlockElement(cp, out)) return true;
    if (cp == 0xFFFD) {
        renderReplacement(out);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Unifont engine
// ---------------------------------------------------------------------------

/// One Unifont glyph: 8 or 16 pixels wide, 16 tall, MSB leftmost.
pub const UnifontGlyph = struct {
    width: u8,
    rows: [16][2]u8,
};

/// Parsed Unifont `.hex` data. Owned; `deinit` releases the map.
pub const Unifont = struct {
    allocator: Allocator,
    glyphs: std.AutoHashMapUnmanaged(u21, UnifontGlyph) = .empty,

    pub fn init(allocator: Allocator) Unifont {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Unifont) void {
        self.glyphs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Unifont) usize {
        return self.glyphs.count();
    }

    pub fn get(self: *const Unifont, cp: u21) ?UnifontGlyph {
        return self.glyphs.get(cp);
    }

    /// Parse GNU Unifont hex text. Each glyph line is `CODEPOINT:HEX` with 32
    /// hex digits (8x16) or 64 hex digits (16x16). Blank lines and lines
    /// starting with `#` are ignored.
    pub fn parseHex(allocator: Allocator, text: []const u8) !Unifont {
        var font = Unifont.init(allocator);
        errdefer font.deinit();

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                return error.InvalidLine;
            if (colon == 0 or colon > 6) return error.InvalidLine;
            const cp32 = std.fmt.parseInt(u32, line[0..colon], 16) catch
                return error.InvalidLine;
            if (cp32 > 0x10FFFF) return error.InvalidLine;

            const bitmap = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
            const width: u8 = switch (bitmap.len) {
                32 => 8,
                64 => 16,
                else => return error.InvalidGlyphData,
            };
            const bytes_per_row: usize = width / 8;
            var glyph: UnifontGlyph = .{
                .width = width,
                .rows = @splat(@splat(0)),
            };
            for (0..16) |row| {
                for (0..bytes_per_row) |byte| {
                    const at = row * bytes_per_row * 2 + byte * 2;
                    glyph.rows[row][byte] = try parseHexByte(bitmap, at);
                }
            }
            try font.glyphs.put(allocator, @intCast(cp32), glyph);
        }
        return font;
    }

    /// Read and parse a `.hex` file relative to `dir`.
    pub fn loadHexFromDir(
        dir: std.Io.Dir,
        io: std.Io,
        allocator: Allocator,
        sub_path: []const u8,
    ) !Unifont {
        const text = try dir.readFileAlloc(io, sub_path, allocator, .limited(128 * 1024 * 1024));
        defer allocator.free(text);
        return parseHex(allocator, text);
    }

    /// Read and parse a `.hex` file relative to the current directory.
    pub fn loadHex(io: std.Io, allocator: Allocator, path: []const u8) !Unifont {
        return loadHexFromDir(std.Io.Dir.cwd(), io, allocator, path);
    }
};

/// Convenience wrapper matching the engine wiring: load a Unifont hex file
/// from `path` (relative to the current directory). Zig 0.17 file I/O takes an
/// `std.Io` value; callers pass the process io from `std.process.Init`.
pub fn loadUnifontHex(io: std.Io, allocator: Allocator, path: []const u8) !Unifont {
    return Unifont.loadHex(io, allocator, path);
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// The two built-in bitmap engines share renderers; `kind` only selects
/// whether loaded Unifont glyphs are consulted before the built-in table.
pub const BitmapFontEngine = struct {
    pub const Kind = enum {
        /// Built-in 8x16 table plus code-drawn sprites and hex boxes.
        builtin_8x16,
        /// Unifont data (when loaded) plus the same sprites/hex boxes.
        unifont,
    };

    allocator: Allocator,
    kind: Kind,
    unifont: Unifont,

    /// Built-in 8x16 engine (the `font-engine=8x16` backend).
    pub fn initBuiltin(allocator: Allocator) BitmapFontEngine {
        return .{
            .allocator = allocator,
            .kind = .builtin_8x16,
            .unifont = Unifont.init(allocator),
        };
    }

    /// Unifont engine without data loaded yet: unmapped codepoints fall back
    /// to the built-in table and then to hex boxes until `loadUnifontHex`
    /// succeeds.
    pub fn initUnifont(allocator: Allocator) BitmapFontEngine {
        return .{
            .allocator = allocator,
            .kind = .unifont,
            .unifont = Unifont.init(allocator),
        };
    }

    pub fn deinit(self: *BitmapFontEngine) void {
        self.unifont.deinit();
        self.* = undefined;
    }

    /// Width of one cell in pixels (8). Wide glyphs span two of these.
    pub fn cellWidth(self: *const BitmapFontEngine) u8 {
        _ = self;
        return cell_width;
    }

    /// Height of one cell in pixels (16).
    pub fn cellHeight(self: *const BitmapFontEngine) u8 {
        _ = self;
        return cell_height;
    }

    /// Load `path` (relative to the current directory) into the engine.
    /// Replaces any previously loaded Unifont data and returns the glyph
    /// count; the engine's `kind` becomes `.unifont`.
    pub fn loadUnifontHex(self: *BitmapFontEngine, io: std.Io, path: []const u8) !usize {
        return self.loadUnifontHexFromDir(std.Io.Dir.cwd(), io, path);
    }

    /// Same as `loadUnifontHex`, but relative to `dir` (used by tests and by
    /// callers that already hold the font directory open).
    pub fn loadUnifontHexFromDir(
        self: *BitmapFontEngine,
        dir: std.Io.Dir,
        io: std.Io,
        sub_path: []const u8,
    ) !usize {
        const loaded = try Unifont.loadHexFromDir(dir, io, self.allocator, sub_path);
        self.unifont.deinit();
        self.unifont = loaded;
        self.kind = .unifont;
        return self.unifont.count();
    }

    /// Rasterize `cp` into `out_alpha` and return the number of cells used
    /// (1 or 2). Exactly `cells * cellWidth() * cellHeight()` bytes are
    /// written; the buffer must be at least that large (`out_alpha.len >= 2 *
    /// 8 * 16` is always safe).
    ///
    /// Resolution order: code-drawn box drawing / block elements / U+FFFD,
    /// then Unifont data (unifont engine only), then the built-in ASCII and
    /// Latin-1 table, then the procedural hex box.
    pub fn renderCodepoint(self: *const BitmapFontEngine, cp: u21, out_alpha: []u8) u8 {
        std.debug.assert(out_alpha.len >= cell_pixels);
        if (renderProcedural(cp, out_alpha)) return 1;

        if (self.kind == .unifont) {
            if (self.unifont.get(cp)) |glyph| return renderUnifontGlyph(glyph, out_alpha);
        }

        if (builtinGlyphIndex(cp)) |index| {
            renderRomGlyph(&rom_glyphs[index], out_alpha);
            return 1;
        }

        const cells = cellCount(cp);
        const pixels = @as(usize, cells) * cell_pixels;
        std.debug.assert(out_alpha.len >= pixels);
        @memset(out_alpha[0..pixels], 0);
        renderHexBox(cp, cells, out_alpha);
        return cells;
    }
};

fn renderRomGlyph(glyph: *const [16]u8, out: []u8) void {
    var y: usize = 0;
    while (y < cell_height) : (y += 1) {
        const byte = glyph[y];
        var x: usize = 0;
        while (x < cell_width) : (x += 1) {
            const shift: u3 = @intCast(7 - x);
            out[y * cell_width + x] = if ((byte >> shift) & 1 != 0) 255 else 0;
        }
    }
}

fn renderUnifontGlyph(glyph: UnifontGlyph, out: []u8) u8 {
    const width: usize = glyph.width;
    std.debug.assert(out.len >= width * cell_height);
    var y: usize = 0;
    while (y < cell_height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const byte = glyph.rows[y][x / 8];
            const shift: u3 = @intCast(7 - (x % 8));
            out[y * width + x] = if ((byte >> shift) & 1 != 0) 255 else 0;
        }
    }
    return if (glyph.width == 16) 2 else 1;
}

/// Wide codepoint ranges (East Asian Width W/F, approximated from the
/// Unicode 15 tables). Used for fallback width and hex-box layout.
const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115F }, // Hangul Jamo initial consonants
    .{ 0x231A, 0x231B }, // watch, hourglass
    .{ 0x2329, 0x232A }, // angle brackets
    .{ 0x23E9, 0x23EC },
    .{ 0x23F0, 0x23F0 },
    .{ 0x23F3, 0x23F3 },
    .{ 0x25FD, 0x25FE },
    .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },
    .{ 0x267F, 0x267F },
    .{ 0x2693, 0x2693 },
    .{ 0x26A1, 0x26A1 },
    .{ 0x26AA, 0x26AB },
    .{ 0x26BD, 0x26BE },
    .{ 0x26C4, 0x26C5 },
    .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 },
    .{ 0x26EA, 0x26EA },
    .{ 0x26F2, 0x26F3 },
    .{ 0x26F5, 0x26F5 },
    .{ 0x26FA, 0x26FA },
    .{ 0x26FD, 0x26FD },
    .{ 0x2705, 0x2705 },
    .{ 0x270A, 0x270B },
    .{ 0x2728, 0x2728 },
    .{ 0x274C, 0x274C },
    .{ 0x274E, 0x274E },
    .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },
    .{ 0x2795, 0x2797 },
    .{ 0x27B0, 0x27B0 },
    .{ 0x27BF, 0x27BF },
    .{ 0x2B1B, 0x2B1C },
    .{ 0x2B50, 0x2B50 },
    .{ 0x2B55, 0x2B55 },
    .{ 0x2E80, 0x303E }, // CJK radicals .. CJK symbols
    .{ 0x3041, 0x33FF }, // kana .. CJK compatibility
    .{ 0x3400, 0x4DBF }, // CJK extension A
    .{ 0x4E00, 0x9FFF }, // CJK unified ideographs
    .{ 0xA000, 0xA4CF }, // Yi
    .{ 0xA960, 0xA97F }, // Hangul Jamo extended-A
    .{ 0xAC00, 0xD7A3 }, // Hangul syllables
    .{ 0xF900, 0xFAFF }, // CJK compatibility ideographs
    .{ 0xFE10, 0xFE19 }, // vertical forms
    .{ 0xFE30, 0xFE6F }, // CJK compatibility forms
    .{ 0xFF00, 0xFF60 }, // fullwidth forms
    .{ 0xFFE0, 0xFFE6 },
    .{ 0x16FE0, 0x16FE4 },
    .{ 0x1B000, 0x1B2FF },
    .{ 0x1F004, 0x1F004 },
    .{ 0x1F0CF, 0x1F0CF },
    .{ 0x1F18E, 0x1F18E },
    .{ 0x1F191, 0x1F19A },
    .{ 0x1F200, 0x1F320 },
    .{ 0x1F32D, 0x1F335 },
    .{ 0x1F337, 0x1F37C },
    .{ 0x1F37E, 0x1F393 },
    .{ 0x1F3A0, 0x1F3CA },
    .{ 0x1F3CF, 0x1F3D3 },
    .{ 0x1F3E0, 0x1F3F0 },
    .{ 0x1F3F4, 0x1F3F4 },
    .{ 0x1F3F8, 0x1F43E },
    .{ 0x1F440, 0x1F440 },
    .{ 0x1F442, 0x1F4FC },
    .{ 0x1F4FF, 0x1F53D },
    .{ 0x1F54B, 0x1F54E },
    .{ 0x1F550, 0x1F567 },
    .{ 0x1F57A, 0x1F57A },
    .{ 0x1F595, 0x1F596 },
    .{ 0x1F5A4, 0x1F5A4 },
    .{ 0x1F5FB, 0x1F64F },
    .{ 0x1F680, 0x1F6C5 },
    .{ 0x1F6CC, 0x1F6CC },
    .{ 0x1F6D0, 0x1F6D2 },
    .{ 0x1F6D5, 0x1F6D7 },
    .{ 0x1F6EB, 0x1F6EC },
    .{ 0x1F6F4, 0x1F6FC },
    .{ 0x1F7E0, 0x1F7EB },
    .{ 0x1F90C, 0x1F93A },
    .{ 0x1F93C, 0x1F945 },
    .{ 0x1F947, 0x1F9FF },
    .{ 0x1FA70, 0x1FAFF },
    .{ 0x20000, 0x3FFFD }, // CJK extensions B..F
};

/// True when `cp` occupies two cells in a terminal (East Asian Width W/F).
pub fn isWide(cp: u21) bool {
    for (wide_ranges) |range| {
        if (cp >= range[0] and cp <= range[1]) return true;
    }
    return false;
}

/// Number of cells a codepoint occupies: 1 for narrow, 2 for wide.
pub fn cellCount(cp: u21) u8 {
    return if (isWide(cp)) 2 else 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn countLit(pixels: []const u8) usize {
    var count: usize = 0;
    for (pixels) |value| {
        if (value != 0) count += 1;
    }
    return count;
}

test "builtin: cell metrics and engine defaults" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    try testing.expectEqual(@as(u8, 8), engine.cellWidth());
    try testing.expectEqual(@as(u8, 16), engine.cellHeight());
    try testing.expectEqual(BitmapFontEngine.Kind.builtin_8x16, engine.kind);
    try testing.expectEqual(@as(usize, 0), engine.unifont.count());
    try testing.expectEqual(@as(usize, 191), rom_glyph_count);
}

test "builtin: 'A' and '0' are distinct, readable ROM glyphs" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var a: [128]u8 = undefined;
    var zero: [128]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint('A', &a));
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint('0', &zero));

    try testing.expect(countLit(&a) > 20);
    try testing.expect(countLit(&zero) > 20);
    try testing.expect(!std.mem.eql(u8, &a, &zero));

    // The well-known 8x16 'A' has a two-pixel apex gap on row 3 (0x3C).
    try testing.expectEqual(@as(u8, 0), a[3 * 8 + 0]);
    try testing.expectEqual(@as(u8, 0), a[3 * 8 + 1]);
    try testing.expectEqual(@as(u8, 255), a[3 * 8 + 2]);
    try testing.expectEqual(@as(u8, 255), a[3 * 8 + 5]);
    try testing.expectEqual(@as(u8, 0), a[3 * 8 + 7]);
    // Every pixel is fully on or fully off.
    for (a) |value| try testing.expect(value == 0 or value == 255);
}

test "builtin: Latin-1 coverage differs per letter" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var e: [128]u8 = undefined;
    var e_acute: [128]u8 = undefined;
    var y_diaeresis: [128]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint('e', &e));
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0x00E9, &e_acute));
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0x00FF, &y_diaeresis));

    try testing.expect(countLit(&e_acute) > 0);
    try testing.expect(!std.mem.eql(u8, &e, &e_acute));
    try testing.expect(countLit(&y_diaeresis) > 0);
}

test "builtin: U+FFFD renders a replacement glyph" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0xFFFD, &buffer));
    try testing.expect(countLit(&buffer) > 20);
    // The box border is present on row 2 and row 13.
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), buffer[2 * 8 + x]);
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), buffer[13 * 8 + x]);
}

test "box drawing: U+2500 lights the whole centre row edge to edge" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0x2500, &buffer));
    const centre: usize = cell_height / 2;
    for (0..cell_width) |x| {
        try testing.expectEqual(@as(u8, 255), buffer[centre * cell_width + x]);
    }
    // Light is exactly one pixel tall.
    for (0..cell_width) |x| {
        try testing.expectEqual(@as(u8, 0), buffer[(centre - 1) * cell_width + x]);
        try testing.expectEqual(@as(u8, 0), buffer[(centre + 1) * cell_width + x]);
    }

    // Heavy horizontal covers rows centre-1..centre+1.
    _ = engine.renderCodepoint(0x2501, &buffer);
    for (0..cell_width) |x| {
        for (centre - 1..centre + 2) |y| {
            try testing.expectEqual(@as(u8, 255), buffer[y * cell_width + x]);
        }
    }
}

test "box drawing: vertical, corners, tees and doubles join" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    const centre_col: usize = cell_width / 2;
    var buffer: [128]u8 = undefined;

    // U+2502 vertical: one pixel column, all sixteen rows.
    _ = engine.renderCodepoint(0x2502, &buffer);
    for (0..cell_height) |y| {
        try testing.expectEqual(@as(u8, 255), buffer[y * cell_width + centre_col]);
        try testing.expectEqual(@as(u8, 0), buffer[y * cell_width + centre_col - 1]);
    }

    // U+251C tee: vertical plus the centre row from the stem to the right edge.
    _ = engine.renderCodepoint(0x251C, &buffer);
    try testing.expectEqual(@as(u8, 0), buffer[0]);
    try testing.expectEqual(@as(u8, 255), buffer[8 * cell_width + centre_col]);
    try testing.expectEqual(@as(u8, 0), buffer[8 * cell_width + centre_col - 1]);
    try testing.expectEqual(@as(u8, 255), buffer[8 * cell_width + 7]);

    // U+2554 double corner: outer top line reaches x=2, inner line starts x=5.
    _ = engine.renderCodepoint(0x2554, &buffer);
    try testing.expectEqual(@as(u8, 255), buffer[6 * cell_width + 2]);
    try testing.expectEqual(@as(u8, 255), buffer[6 * cell_width + 7]);
    try testing.expectEqual(@as(u8, 0), buffer[6 * cell_width + 0]);
    try testing.expectEqual(@as(u8, 255), buffer[9 * cell_width + 5]);
    try testing.expectEqual(@as(u8, 0), buffer[9 * cell_width + 4]);

    // U+256C double cross has both vertical lines full height.
    _ = engine.renderCodepoint(0x256C, &buffer);
    for (0..cell_height) |y| {
        try testing.expectEqual(@as(u8, 255), buffer[y * cell_width + 2]);
        try testing.expectEqual(@as(u8, 255), buffer[y * cell_width + 5]);
    }

    // Every box-drawing codepoint produces a non-empty cell.
    var cp: u21 = 0x2500;
    while (cp <= 0x257F) : (cp += 1) {
        _ = engine.renderCodepoint(cp, &buffer);
        try testing.expect(countLit(&buffer) > 0);
    }
}

test "block elements: full block, halves, shades and quadrants" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var buffer: [128]u8 = undefined;

    _ = engine.renderCodepoint(0x2588, &buffer); // full block
    try testing.expectEqual(@as(usize, 128), countLit(&buffer));

    _ = engine.renderCodepoint(0x2580, &buffer); // upper half
    try testing.expectEqual(@as(usize, 64), countLit(&buffer));
    try testing.expectEqual(@as(u8, 255), buffer[7 * 8 + 7]);
    try testing.expectEqual(@as(u8, 0), buffer[8 * 8 + 0]);

    _ = engine.renderCodepoint(0x2584, &buffer); // lower half
    try testing.expectEqual(@as(u8, 0), buffer[7 * 8 + 0]);
    try testing.expectEqual(@as(u8, 255), buffer[8 * 8 + 0]);

    _ = engine.renderCodepoint(0x2592, &buffer); // 50 % shade
    try testing.expectEqual(@as(usize, 64), countLit(&buffer));

    _ = engine.renderCodepoint(0x2596, &buffer); // lower left quadrant
    try testing.expectEqual(@as(usize, 32), countLit(&buffer));
    try testing.expectEqual(@as(u8, 255), buffer[15 * 8 + 0]);
    try testing.expectEqual(@as(u8, 0), buffer[15 * 8 + 4]);

    // Every block element produces a non-empty cell.
    var cp: u21 = 0x2580;
    while (cp <= 0x259F) : (cp += 1) {
        _ = engine.renderCodepoint(cp, &buffer);
        try testing.expect(countLit(&buffer) > 0);
    }
}

test "fallback: unmapped narrow codepoint renders a hex box" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var buffer: [256]u8 = undefined;
    // U+0378 is unassigned (narrow) and absent from the built-in table.
    try testing.expectEqual(@as(u8, 1), cellCount(0x0378));
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0x0378, &buffer));
    try testing.expect(countLit(buffer[0..128]) > 10);
    // Border rows are lit edge to edge.
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), buffer[1 * 8 + x]);
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), buffer[14 * 8 + x]);
}

test "fallback: wide codepoint uses two cells" {
    var engine = BitmapFontEngine.initBuiltin(testing.allocator);
    defer engine.deinit();

    var buffer: [256]u8 = undefined;
    try testing.expectEqual(@as(u8, 2), cellCount(0x4E2D));
    try testing.expectEqual(@as(u8, 2), engine.renderCodepoint(0x4E2D, &buffer));
    try testing.expect(countLit(buffer[0..256]) > 10);
    // The wide box is 16 pixels wide: top border spans the full width.
    for (0..16) |x| try testing.expectEqual(@as(u8, 255), buffer[1 * 16 + x]);

    // An emoji outside the built-in table is treated the same way.
    try testing.expectEqual(@as(u8, 2), engine.renderCodepoint(0x1F600, &buffer));
    try testing.expect(countLit(buffer[0..256]) > 10);
}

test "unifont: parse hex data with narrow and wide glyphs" {
    const allocator = testing.allocator;
    const text =
        \\# comment line
        \\0041:01010101010101010101010101010101
        \\4E2D:FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00
        \\
    ;
    var font = try Unifont.parseHex(allocator, text);
    defer font.deinit();

    try testing.expectEqual(@as(usize, 2), font.count());

    const a = font.get('A') orelse return error.TestFailed;
    try testing.expectEqual(@as(u8, 8), a.width);
    try testing.expectEqual(@as(u8, 0x01), a.rows[0][0]);
    try testing.expectEqual(@as(u8, 0x01), a.rows[15][0]);

    const wide = font.get(0x4E2D) orelse return error.TestFailed;
    try testing.expectEqual(@as(u8, 16), wide.width);
    try testing.expectEqual(@as(u8, 0xFF), wide.rows[0][0]);
    try testing.expectEqual(@as(u8, 0x00), wide.rows[0][1]);

    try testing.expectEqual(@as(?UnifontGlyph, null), font.get('Z'));
}

test "unifont: engine loads a file and prefers its glyphs" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const text =
        \\0041:80808080808080808080808080808080
        \\4E2D:FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unifont.hex", .data = text });

    var engine = BitmapFontEngine.initUnifont(allocator);
    defer engine.deinit();

    const loaded = try engine.loadUnifontHexFromDir(tmp.dir, std.testing.io, "unifont.hex");
    try testing.expectEqual(@as(usize, 2), loaded);
    try testing.expectEqual(BitmapFontEngine.Kind.unifont, engine.kind);

    // 'A' now comes from the file (a single lit left column), not the ROM.
    var a: [128]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint('A', &a));
    try testing.expectEqual(@as(u8, 255), a[0]);
    try testing.expectEqual(@as(u8, 0), a[1]);
    try testing.expectEqual(@as(u8, 255), a[16]);
    try testing.expectEqual(@as(u8, 0), a[17]);

    // The wide glyph is two cells and covers the left eight pixels per row.
    var wide: [256]u8 = undefined;
    try testing.expectEqual(@as(u8, 2), engine.renderCodepoint(0x4E2D, &wide));
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), wide[x]);
    for (8..16) |x| try testing.expectEqual(@as(u8, 0), wide[x]);
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), wide[16 + x]);

    // A codepoint absent from the file still falls back to a hex box.
    var missing: [256]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), engine.renderCodepoint(0x0378, &missing));
    try testing.expect(countLit(missing[0..128]) > 0);
}

test "unifont: missing file surfaces the filesystem error" {
    const result = loadUnifontHex(
        std.testing.io,
        testing.allocator,
        "definitely-not-a-font-file.hex",
    );
    try testing.expectError(error.FileNotFound, result);
}

test "unifont hex parser rejects malformed lines" {
    const allocator = testing.allocator;

    try testing.expectError(
        error.InvalidLine,
        Unifont.parseHex(allocator, "no colon here"),
    );
    try testing.expectError(
        error.InvalidGlyphData,
        Unifont.parseHex(allocator, "0041:00"),
    );
    try testing.expectError(
        error.InvalidLine,
        Unifont.parseHex(allocator, "110000:00000000000000000000000000000000"),
    );
}