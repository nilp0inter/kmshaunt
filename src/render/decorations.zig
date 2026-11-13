//! src/render/decorations.zig -- text decorations and the software cursor
//! (ROADMAP M3.7: underline styles, underline/strikethrough/overline rows,
//! faint/inverse/invisible attributes, cursor styles).
//!
//! Geometry is expressed in *absolute framebuffer pixels*. Every patterned
//! stroke (curly, dotted, dashed) derives its phase from the absolute x
//! coordinate -- never from the offset inside the cell -- so adjacent cells
//! join seamlessly and drawing cells 0..N one by one produces exactly the
//! pixels of one wide draw. The periods are pixel constants (not cell-width
//! derived) precisely because a wide draw has a different cell width than
//! the per-cell draws it must match.
//!
//! Positions (`underline_pos`, `strike_pos`, ...) are pixel offsets from the
//! *top of the cell*, because that is the coordinate space the pixel loop
//! lives in. Font metrics give positions relative to the glyph baseline, so
//! `rowFromBaseline` and `strikeRow` convert them (FreeType reports
//! `underline_position` as a negative value below the baseline).
//!
//! All drawing clips twice: to the cell rectangle and to the framebuffer
//! bounds. Out-of-range cells (negative origin, zero size, far past the
//! right/bottom edge) are no-ops instead of panics. Every pixel goes through
//! `Framebuffer.set`, so the row pitch (stride padding) is honored and the
//! padding bytes are never touched.
//!
//! Imports: framebuffer.zig only (the shared contract). `CursorStyle`
//! mirrors `render.CursorStyle` because this file must stay independent of
//! the renderer contract file.

const std = @import("std");
const fb = @import("../framebuffer.zig");

pub const Framebuffer = fb.Framebuffer;

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

/// Cursor presentation styles (ROADMAP M3.7 "cursor styles"). Mirrors
/// `render.CursorStyle`; kept local so this file imports framebuffer.zig
/// only.
pub const CursorStyle = enum {
    block,
    bar,
    underline,
};

/// A foreground/background pair, e.g. the result of `applyInverse`.
pub const Colors = struct {
    fg: u32,
    bg: u32,
};

// ---------------------------------------------------------------------------
// Pattern geometry (absolute pixels)
// ---------------------------------------------------------------------------

/// Width in pixels of one curly scallop. Constant across cells so the wave
/// is a pure function of the absolute pixel x.
pub const curly_period: u32 = 8;
/// Peak height above the decoration row of one curly scallop.
pub const curly_amplitude: i32 = 2;
/// Dotted pattern: one 1-px dot every `dotted_period` pixels.
pub const dotted_period: u32 = 3;
/// Dashed pattern: `dash_on` painted pixels then `dash_period - dash_on`
/// empty pixels.
pub const dash_on: u32 = 3;
pub const dash_period: u32 = 6;
/// Cursor bar width in pixels (left edge of the cell).
pub const bar_width: u16 = 2;
/// Cursor underline height in pixels (bottom edge of the cell).
pub const cursor_underline_height: u16 = 2;

/// Empty rows between the two lines of a double underline, on top of the
/// requested `thickness` (which still sizes the gap, see drawUnderline).
pub const double_gap: u16 = 1;

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

/// SGR 2 (faint): 50% blend of `color` toward `background`, per channel,
/// rounding half up (the half-LSB rounding direction is toward the brighter
/// channel, i.e. toward the background whenever the background is brighter).
/// Both inputs are packed 0xRRGGBB; the top byte is ignored.
pub fn applyFaint(color: u32, background: u32) u32 {
    const r = blendChannel((color >> 16) & 0xff, (background >> 16) & 0xff);
    const g = blendChannel((color >> 8) & 0xff, (background >> 8) & 0xff);
    const b = blendChannel(color & 0xff, background & 0xff);
    return (r << 16) | (g << 8) | b;
}

fn blendChannel(c: u32, b: u32) u32 {
    return (c + b + 1) >> 1;
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

/// Convert a font metric expressed relative to the glyph baseline (FreeType's
/// `underline_position` is negative below the baseline) into the
/// cell-relative row offset the drawing functions take.
pub fn rowFromBaseline(baseline: i16, pos: i16) i16 {
    return baseline +| pos;
}

/// Conventional strikethrough row: half the x-height above the baseline.
/// `x_height` is the face's x-height in pixels; pass 0 when unknown.
pub fn strikeRow(baseline: i16, x_height: i16) i16 {
    return baseline -| @divTrunc(x_height, 2);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// Draw an underline for one cell.
///
/// * `underline_pos` -- top row of the decoration relative to the cell top,
///   normally `rowFromBaseline(cell_baseline, face.underline_position)`.
/// * `thickness` -- stroke height in pixels for `single`; for `double` it
///   sizes the gap between the two 1-px lines (`second = first + 1 +
///   max(thickness, 1)`), so the two lines are always distinct rows.
/// * `curly`, `dotted`, `dashed` are 1-px strokes whose horizontal phase is
///   a function of the absolute pixel x (see the pattern constants).
///
/// Every row is clipped to the cell and to the framebuffer.
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
    const rect = clippedCell(f, cell_x, cell_y, cell_w, cell_h) orelse return;
    const base = cell_y +| @as(i32, underline_pos);

    switch (style) {
        .none => {},
        .single => solidRows(f, rect, cell_y, cell_h, base, @max(thickness, 1), color),
        .double => {
            solidRows(f, rect, cell_y, cell_h, base, 1, color);
            const gap: u32 = @as(u32, @max(thickness, 1)) + double_gap;
            solidRows(f, rect, cell_y, cell_h, base +| @as(i32, @intCast(gap)), 1, color);
        },
        .curly, .dotted, .dashed => patternRows(f, rect, cell_y, cell_h, base, style, color),
    }
}

/// Draw a strikethrough. `strike_pos` is a cell-relative row; use
/// `strikeRow(baseline, x_height)` for the conventional position.
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
    const rect = clippedCell(f, cell_x, cell_y, cell_w, cell_h) orelse return;
    solidRows(f, rect, cell_y, cell_h, cell_y +| @as(i32, strike_pos), @max(thickness, 1), color);
}

/// Draw an overline (SGR 53) along the top edge of the cell.
pub fn drawOverline(
    f: Framebuffer,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
    color: u32,
    thickness: u16,
) void {
    const rect = clippedCell(f, cell_x, cell_y, cell_w, cell_h) orelse return;
    solidRows(f, rect, cell_y, cell_h, cell_y, @max(thickness, 1), color);
}

/// Draw the software cursor for one cell. `blink_on == false` draws nothing
/// (the off phase of the blink timer). Shapes:
/// * `block` -- the whole cell (the renderer then paints the glyph with
///   `cursorOverlayColor`).
/// * `bar` -- `bar_width` pixels on the left edge, full cell height.
/// * `underline` -- `cursor_underline_height` pixels on the bottom edge,
///   full cell width.
///
/// Shapes shrink when the cell is narrower/shorter than the nominal size and
/// clip to the framebuffer.
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
    const rect = clippedCell(f, cell_x, cell_y, cell_w, cell_h) orelse return;

    switch (style) {
        .block => fillRows(f, rect.x0, rect.x1, rect.y0, rect.y1, color),
        .bar => {
            const w: i64 = @min(@as(i64, bar_width), @as(i64, cell_w));
            const bar_x1: i32 = @intCast(@min(@as(i64, cell_x) + w, @as(i64, rect.x1)));
            fillRows(f, rect.x0, bar_x1, rect.y0, rect.y1, color);
        },
        .underline => {
            const h: i64 = @min(@as(i64, cursor_underline_height), @as(i64, cell_h));
            const top: i32 = @intCast(@max(
                @as(i64, cell_y) + @as(i64, cell_h) - h,
                @as(i64, rect.y0),
            ));
            fillRows(f, rect.x0, rect.x1, top, rect.y1, color);
        },
    }
}

// ---------------------------------------------------------------------------
// Pixel plumbing
// ---------------------------------------------------------------------------

/// Cell rectangle in absolute pixels, clipped to the framebuffer on all four
/// sides. `x1`/`y1` are exclusive. Null when nothing is visible.
const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

fn clippedCell(f: Framebuffer, cell_x: i32, cell_y: i32, cell_w: u16, cell_h: u16) ?Rect {
    if (cell_w == 0 or cell_h == 0) return null;
    const i32_max: i64 = std.math.maxInt(i32);
    const x0: i64 = @max(@as(i64, cell_x), 0);
    const y0: i64 = @max(@as(i64, cell_y), 0);
    const x1: i64 = @min(@min(@as(i64, cell_x) + @as(i64, cell_w), @as(i64, f.width)), i32_max);
    const y1: i64 = @min(@min(@as(i64, cell_y) + @as(i64, cell_h), @as(i64, f.height)), i32_max);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x0 = @intCast(x0),
        .y0 = @intCast(y0),
        .x1 = @intCast(x1),
        .y1 = @intCast(y1),
    };
}

/// True when `y` lies inside the cell's vertical extent (not the clipped
/// one), so a decoration never bleeds into the neighbouring text row.
fn inCellY(y: i32, cell_y: i32, cell_h: u16) bool {
    return y >= cell_y and @as(i64, y) < @as(i64, cell_y) + @as(i64, cell_h);
}

/// One solid horizontal span, clipped to the framebuffer.
fn hline(f: Framebuffer, x0: i32, x1: i32, y: i32, color: u32) void {
    if (y < 0) return;
    const yy: u32 = @intCast(y);
    if (yy >= f.height) return;
    const lo64: i64 = @max(@as(i64, x0), 0);
    const hi64: i64 = @min(@as(i64, x1), @as(i64, f.width));
    if (hi64 <= lo64) return;
    var x: u32 = @intCast(lo64);
    const hi: u32 = @intCast(hi64);
    while (x < hi) : (x += 1) f.set(x, yy, color);
}

/// `count` solid 1-px rows starting at `base` (absolute y), each clipped to
/// the cell and the framebuffer.
fn solidRows(
    f: Framebuffer,
    rect: Rect,
    cell_y: i32,
    cell_h: u16,
    base: i32,
    count: u32,
    color: u32,
) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const y64 = @as(i64, base) + @as(i64, i);
        if (y64 < std.math.minInt(i32) or y64 > std.math.maxInt(i32)) continue;
        const y: i32 = @intCast(y64);
        if (!inCellY(y, cell_y, cell_h)) continue;
        hline(f, rect.x0, rect.x1, y, color);
    }
}

/// Fill a rectangle of the framebuffer, clipped by `hline`.
fn fillRows(f: Framebuffer, x0: i32, x1: i32, y0: i32, y1: i32, color: u32) void {
    var y = y0;
    while (y < y1) : (y += 1) hline(f, x0, x1, y, color);
}

/// Patterned strokes: one pixel per column where the pattern is "on", at
/// `base` plus the pattern's vertical offset. Phase is evaluated on the
/// absolute x, which is what makes cells join.
fn patternRows(
    f: Framebuffer,
    rect: Rect,
    cell_y: i32,
    cell_h: u16,
    base: i32,
    style: UnderlineStyle,
    color: u32,
) void {
    var x: i32 = rect.x0;
    while (x < rect.x1) : (x += 1) {
        if (style == .dotted and !dottedOn(x)) continue;
        if (style == .dashed and !dashOn(x)) continue;
        const off: i32 = if (style == .curly) curlyOffset(x) else 0;
        const y = base +| off;
        if (!inCellY(y, cell_y, cell_h)) continue;
        if (y < 0) continue;
        const yy: u32 = @intCast(y);
        if (yy >= f.height) continue;
        const xx: u32 = @intCast(x);
        if (xx >= f.width) continue;
        f.set(xx, yy, color);
    }
}

/// Curly scallop height at absolute pixel x: a parabolic arch that is 0 at
/// each period boundary and `curly_amplitude` in the middle. Integer only,
/// so goldens are bit-exact on every target.
fn curlyOffset(abs_x: i32) i32 {
    const period: i32 = @intCast(curly_period);
    const p: i32 = @mod(abs_x, period);
    const num = curly_amplitude * 4 * p * (period - p);
    const den = period * period;
    return @divTrunc(num + @divTrunc(den, 2), den);
}

fn dottedOn(abs_x: i32) bool {
    return @mod(abs_x, @as(i32, @intCast(dotted_period))) == 0;
}

fn dashOn(abs_x: i32) bool {
    const p = @mod(abs_x, @as(i32, @intCast(dash_period)));
    return p < @as(i32, @intCast(dash_on));
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

fn expectRows(
    f: Framebuffer,
    x_start: u32,
    x_end: u32,
    row: u32,
    color: u32,
) !void {
    var x = x_start;
    while (x < x_end) : (x += 1) {
        try testing.expectEqual(color, f.get(x, row));
    }
}

test "underline single: row comes from font metrics and thickness" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 32, 20, .xrgb8888, null);
    defer f.destroy(a);

    // A 10x16 cell at (4,2). Baseline 13, FreeType underline_position -2
    // (below the baseline) -> row 11 inside the cell -> absolute row 13.
    const pos = rowFromBaseline(13, -2);
    try testing.expectEqual(@as(i16, 11), pos);
    drawUnderline(f, 4, 2, 10, 16, .single, 0x00FF00, pos, 2);

    try expectRows(f, 4, 14, 13, 0x00FF00);
    try expectRows(f, 4, 14, 14, 0x00FF00);
    try expectRows(f, 4, 14, 12, 0);
    try expectRows(f, 4, 14, 15, 0);
    // Clipped to the cell horizontally.
    try testing.expectEqual(@as(u32, 0), f.get(3, 13));
    try testing.expectEqual(@as(u32, 0), f.get(14, 13));

    // A thickness that runs past the cell bottom is clipped to the cell,
    // never into the next text row: pos 15, thickness 4 -> only row 17.
    drawUnderline(f, 4, 2, 10, 16, .single, 0x00FFFF, 15, 4);
    try expectRows(f, 4, 14, 17, 0x00FFFF);
    try testing.expectEqual(@as(u32, 0), f.get(4, 18));
    try testing.expectEqual(@as(u32, 0), f.get(4, 19));

    // Thickness 0 is treated as a 1-px stroke, not as "draw nothing".
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

test "underline double: two distinct parallel rows" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 20, .xrgb8888, null);
    defer f.destroy(a);

    drawUnderline(f, 0, 0, 8, 16, .double, 0x123456, 10, 1);
    try expectRows(f, 0, 8, 10, 0x123456);
    try expectRows(f, 0, 8, 12, 0x123456);
    try expectRows(f, 0, 8, 11, 0);
    try testing.expectEqual(@as(usize, 16), countColor(f, 0x123456));

    // Thickness widens the gap but never merges the two lines.
    drawUnderline(f, 8, 0, 8, 16, .double, 0xABCDEF, 10, 2);
    try expectRows(f, 8, 16, 10, 0xABCDEF);
    try expectRows(f, 8, 16, 13, 0xABCDEF);
    try expectRows(f, 8, 16, 11, 0);
    try expectRows(f, 8, 16, 12, 0);
}

test "patterned underlines: phase continuous across cells" {
    const a = testing.allocator;
    const color = 0x00FF00;
    const cell_w: u16 = 5; // not a multiple of any pattern period
    const cell_h: u16 = 16;

    inline for (.{
        UnderlineStyle.single,
        UnderlineStyle.double,
        UnderlineStyle.curly,
        UnderlineStyle.dotted,
        UnderlineStyle.dashed,
    }) |style| {
        var split = try Framebuffer.create(a, 20, 16, .xrgb8888, null);
        defer split.destroy(a);
        var wide = try Framebuffer.create(a, 20, 16, .xrgb8888, null);
        defer wide.destroy(a);

        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            drawUnderline(split, @intCast(i * cell_w), 0, cell_w, cell_h, style, color, 13, 1);
        }
        drawUnderline(wide, 0, 0, 3 * cell_w, cell_h, style, color, 13, 1);

        // The three per-cell draws must equal one wide draw bit for bit,
        // including the boundary columns.
        var y: u32 = 0;
        while (y < 16) : (y += 1) {
            var x: u32 = 0;
            while (x < 3 * cell_w) : (x += 1) {
                try testing.expectEqual(wide.get(x, y), split.get(x, y));
            }
        }

        // Phase keeps advancing instead of restarting per cell: cell 0 and
        // cell 1 use different pattern offsets for the patterned styles.
        if (style == .curly or style == .dotted or style == .dashed) {
            var differs = false;
            y = 0;
            while (y < 16) : (y += 1) {
                var dx: u32 = 0;
                while (dx < cell_w) : (dx += 1) {
                    if (split.get(dx, y) != split.get(cell_w + dx, y)) differs = true;
                }
            }
            try testing.expect(differs);
        }
    }
}

test "strikethrough and overline rows" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 16, 20, .xrgb8888, null);
    defer f.destroy(a);

    // x-height 8 above baseline 13 -> row 9 (absolute row 11 with cell_y 2).
    try testing.expectEqual(@as(i16, 9), strikeRow(13, 8));
    drawStrikethrough(f, 2, 2, 8, 16, 0x0000FF, strikeRow(13, 8), 1);
    try expectRows(f, 2, 10, 11, 0x0000FF);
    try expectRows(f, 2, 10, 10, 0);
    try expectRows(f, 2, 10, 12, 0);

    // Overline sits on the first cell rows.
    drawOverline(f, 2, 2, 8, 16, 0xFF00FF, 2);
    try expectRows(f, 2, 10, 2, 0xFF00FF);
    try expectRows(f, 2, 10, 3, 0xFF00FF);
    try expectRows(f, 2, 10, 4, 0);
}

test "applyFaint: exact 50% blend toward the background" {
    try testing.expectEqual(@as(u32, 0x808080), applyFaint(0xFFFFFF, 0x000000));
    try testing.expectEqual(@as(u32, 0x808080), applyFaint(0x000000, 0xFFFFFF));
    // 0x405060 is R=0x40 G=0x50 B=0x60.
    try testing.expectEqual(@as(u32, 0x283848), applyFaint(0x102030, 0x405060));
    try testing.expectEqual(@as(u32, 0x123456), applyFaint(0x123456, 0x123456));
    try testing.expectEqual(@as(u32, 0xFFFFFF), applyFaint(0xFFFFFF, 0xFFFFFF));
    // Alpha bits are ignored, never blended into the channels.
    try testing.expectEqual(@as(u32, 0x808080), applyFaint(0xFFFFFFFF, 0xFF000000));
}

test "applyInverse swaps, shouldDraw encodes the invisible policy" {
    const swapped = applyInverse(0x112233, 0x445566);
    try testing.expectEqual(@as(u32, 0x445566), swapped.fg);
    try testing.expectEqual(@as(u32, 0x112233), swapped.bg);

    try testing.expect(shouldDraw(false));
    try testing.expect(!shouldDraw(true));
}

test "cursor block fills the cell; bar and underline are 2 px edges" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 10, .xrgb8888, null);
    defer f.destroy(a);

    drawCursor(f, 2, 3, 4, 5, .block, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 20), countColor(f, 0x00FF00));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(2, 3));
    try testing.expectEqual(@as(u32, 0x00FF00), f.get(5, 7));
    try testing.expectEqual(@as(u32, 0), f.get(6, 3));
    try testing.expectEqual(@as(u32, 0), f.get(2, 8));

    f.fill(0);
    drawCursor(f, 4, 3, 6, 4, .bar, 0x0000FF, true);
    try testing.expectEqual(@as(usize, 8), countColor(f, 0x0000FF));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(4, 3));
    try testing.expectEqual(@as(u32, 0x0000FF), f.get(5, 6));
    try testing.expectEqual(@as(u32, 0), f.get(6, 3));

    f.fill(0);
    drawCursor(f, 4, 3, 6, 4, .underline, 0xFF0000, true);
    try testing.expectEqual(@as(usize, 12), countColor(f, 0xFF0000));
    try testing.expectEqual(@as(u32, 0xFF0000), f.get(4, 5));
    try testing.expectEqual(@as(u32, 0xFF0000), f.get(9, 6));
    try testing.expectEqual(@as(u32, 0), f.get(9, 4));
}

test "cursor shapes shrink for tiny cells" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 8, 8, .xrgb8888, null);
    defer f.destroy(a);

    drawCursor(f, 0, 0, 1, 4, .bar, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 4), countColor(f, 0x00FF00));

    f.fill(0);
    drawCursor(f, 0, 0, 4, 1, .underline, 0x00FF00, true);
    try testing.expectEqual(@as(usize, 4), countColor(f, 0x00FF00));
}

test "cursor blink off draws nothing" {
    const a = testing.allocator;
    var f = try Framebuffer.create(a, 12, 12, .xrgb8888, null);
    defer f.destroy(a);
    inline for (.{ CursorStyle.block, CursorStyle.bar, CursorStyle.underline }) |style| {
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
    drawCursor(f, 10, 0, 4, 4, .bar, 0x00FF00, true);
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