//! Multi-monitor layout (ROADMAP M5.3/M5.4): connector rotation, the kmscon
//! 3-tier `mode=`/`screen=` rule matching, and the shared terminal grid plus
//! per-connector viewports for the clone / largest / scaled multi-monitor
//! modes, including dirty-row → physical damage mapping under rotation and
//! scaling.
//!
//! Coordinate spaces used throughout:
//!   - canvas (logical): the shared terminal pixel space
//!     (`Canvas.width x Canvas.height`), origin top-left, y grows down.
//!   - content: one connector's effective (post-rotation) display area,
//!     `eff_w x eff_h`, origin top-left.
//!   - physical: one connector's native framebuffer, `width_px x height_px`.
//!
//! A `Rotation` is the clockwise turn of the terminal content onto the
//! framebuffer: `Rotation.logicalToPhysical` moves content coordinates into
//! the native framebuffer and `physicalToLogical` is its exact inverse. The
//! rotation unit maps corners to corners and interiors to interiors (tested
//! below), so axis-aligned content rects become axis-aligned physical rects.
//!
//! kmscon parity notes (docs/reference/kmscon-options.md §5.3/§5.4/§5.8):
//!   - `--mode` lookup is "first match wins" with precedence (1) exact
//!     gpu+connector, (2) connector only, (3) global; `--screen` shares the
//!     rule (`config_get_mode` / `config_get_screen`).
//!   - `--multi-monitor` defaults to `scaled` when the option is absent; any
//!     value that is not exactly `scaled` or `largest` — including `clone`
//!     and unknown strings — behaves as `clone` (`terminal.c:752-757`).
//!   - `screen=` orientations map: `normal`→0°, `right`→90° clockwise,
//!     `upside-down`→180°, `left`→90° counter-clockwise; `disabled` is a
//!     screen disposition, not a rotation, so `Rotation.fromConfigString`
//!     returns null for it (and any other token, which is `-EINVAL` upstream).
//!   - One deliberate divergence from kmscon: its `largest` mode disables the
//!     non-largest outputs, while the kmshaunt spec shows them a centered,
//!     clipped viewport of the largest canvas.
//!
//! The module is allocation-free: `computeLayout` fills caller-provided
//! `Plan` slots (one per connector) and every string it exposes borrows the
//! caller's `Connector` input.

const std = @import("std");
const testing = std.testing;

/// An integer point in canvas/content/physical space.
pub const Point = struct { x: i32, y: i32 };

/// A size with a width and a height.
pub const Size = struct { w: u32, h: u32 };

/// Rotation of the terminal content as displayed on the framebuffer. The tag
/// value is the clockwise angle in degrees (kmscon `screen=` orientations;
/// `right` = content rotated 90° clockwise, `left` = 90° counter-clockwise).
pub const Rotation = enum(u16) {
    normal = 0,
    right = 90,
    inverted = 180,
    left = 270,

    /// Rotate one step further clockwise (grab-rotate-cw).
    pub fn rotateCw(self: Rotation) Rotation {
        return switch (self) {
            .normal => .right,
            .right => .inverted,
            .inverted => .left,
            .left => .normal,
        };
    }

    /// Rotate one step counter-clockwise (grab-rotate-ccw).
    pub fn rotateCcw(self: Rotation) Rotation {
        return switch (self) {
            .normal => .left,
            .left => .inverted,
            .inverted => .right,
            .right => .normal,
        };
    }

    /// Parse the `screen=` orientation token. Returns null for anything that
    /// is not one of the four rotations — including `disabled`, which is a
    /// screen disposition, not a rotation (and unknown tokens, which are an
    /// error upstream).
    pub fn fromConfigString(s: []const u8) ?Rotation {
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "upside-down")) return .inverted;
        return null;
    }

    /// Resolution of a `w x h` framebuffer after this rotation: the content
    /// (logical) dimensions for a native frame of `w x h`.
    pub fn effectiveDimensions(self: Rotation, w: u32, h: u32) Size {
        return switch (self) {
            .normal, .inverted => .{ .w = w, .h = h },
            .right, .left => .{ .w = h, .h = w },
        };
    }

    /// Rotate a content-space point into the native framebuffer of size
    /// `phys_w x phys_h`. `x`/`y` must lie within the content space, i.e.
    /// `0 <= x < effectiveDimensions(phys_w, phys_h).w` and likewise for `y`.
    pub fn logicalToPhysical(self: Rotation, x: i32, y: i32, phys_w: u32, phys_h: u32) Point {
        const pw: i32 = @intCast(phys_w);
        const ph: i32 = @intCast(phys_h);
        const m = rotmap(i32, self, x, y, pw, ph);
        return .{ .x = m.x, .y = m.y };
    }

    /// Inverse of `logicalToPhysical`, mapping a native framebuffer point
    /// back into content space.
    pub fn physicalToLogical(self: Rotation, x: i32, y: i32, phys_w: u32, phys_h: u32) Point {
        const pw: i32 = @intCast(phys_w);
        const ph: i32 = @intCast(phys_h);
        const m = rotmapInv(i32, self, x, y, pw, ph);
        return .{ .x = m.x, .y = m.y };
    }
};

/// Forward rotational map, generic over the coordinate type so the damage
/// path can reuse the exact same math in floating point after scaling.
fn rotmap(comptime T: type, rot: Rotation, x: T, y: T, pw: T, ph: T) struct { x: T, y: T } {
    return switch (rot) {
        .normal => .{ .x = x, .y = y },
        .right => .{ .x = pw - 1 - y, .y = x },
        .inverted => .{ .x = pw - 1 - x, .y = ph - 1 - y },
        .left => .{ .x = y, .y = ph - 1 - x },
    };
}

/// Inverse rotational map (see `rotmap`).
fn rotmapInv(comptime T: type, rot: Rotation, x: T, y: T, pw: T, ph: T) struct { x: T, y: T } {
    return switch (rot) {
        .normal => .{ .x = x, .y = y },
        .right => .{ .x = y, .y = pw - 1 - x },
        .inverted => .{ .x = pw - 1 - x, .y = ph - 1 - y },
        .left => .{ .x = ph - 1 - y, .y = x },
    };
}

/// Multi-monitor arrangement (`--multi-monitor`). `default` is the kmscon
/// value used when the option is absent; `fromConfigString` maps any string
/// that is not exactly `scaled` or `largest` (including `clone` and unknown
/// values) to `clone` — a kmscon quirk (`terminal.c:752-757`).
pub const MultiMonitorMode = enum {
    clone,
    largest,
    scaled,

    pub const default: MultiMonitorMode = .scaled;

    pub fn fromConfigString(s: []const u8) MultiMonitorMode {
        if (std.mem.eql(u8, s, "scaled")) return .scaled;
        if (std.mem.eql(u8, s, "largest")) return .largest;
        return .clone;
    }
};

/// Terminal cell size in pixels.
pub const Cell = struct { w: u32, h: u32 };

/// An enabled display output. `gpu`/`connector` are kmscon names, e.g.
/// `"card0"` and `"HDMI-A-1"`; `width_px x height_px` is the native
/// framebuffer resolution the connector is driven at; `width_mm x height_mm`
/// is the physical panel size (used downstream for DPI/font sizing, ignored
/// by the layout math). `rotation` is applied to the content before scanout.
pub const Connector = struct {
    gpu: []const u8 = "",
    connector: []const u8 = "",
    width_px: u32 = 0,
    height_px: u32 = 0,
    width_mm: u32 = 0,
    height_mm: u32 = 0,
    rotation: Rotation = .normal,
    enabled: bool = true,

    /// Post-rotation resolution of the framebuffer (content space).
    pub fn effectiveSize(self: Connector) Size {
        return self.rotation.effectiveDimensions(self.width_px, self.height_px);
    }
};

/// Axis-aligned rectangle with integer origin and unsigned extent,
/// half-open: it covers `[x, x + w) x [y, y + h)`.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn endX(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.w));
    }

    pub fn endY(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.h));
    }

    /// Axis-aligned intersection of two rects; null when disjoint.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.endX(), b.endX());
        const y1 = @min(a.endY(), b.endY());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{
            .x = x0,
            .y = y0,
            .w = @intCast(x1 - x0),
            .h = @intCast(y1 - y0),
        };
    }
};

/// Floating-point rectangle, used for scaled content-space destinations.
pub const FRect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn endX(self: FRect) f64 {
        return self.x + self.w;
    }

    pub fn endY(self: FRect) f64 {
        return self.y + self.h;
    }
};

/// The shared terminal grid and its pixel-space canvas.
pub const Canvas = struct {
    cols: u32 = 0,
    rows: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Per-connector viewport into the shared canvas, produced by
/// `computeLayout`.
pub const Plan = struct {
    /// False when the connector is disabled or nothing was assigned.
    active: bool = false,
    /// Index of the connector inside the slice passed to `computeLayout`.
    index: usize = 0,
    /// Copy of the connector (string slices borrow the caller's input).
    conn: Connector = .{},
    /// Logical canvas rect this connector displays (the viewport; the full
    /// canvas in clone/scaled modes, a centered clipped window in largest).
    src: Rect = .{},
    /// Uniform scale of the viewport into the connector's content space;
    /// 1.0 for clone and largest, >= 1.0 for scaled mode.
    scale: f64 = 1,
    /// Content-space rect (within the connector's effective area) where the
    /// scaled viewport lands, centered.
    dst: FRect = .{},

    /// Map dirty terminal grid rows `[row0, row1)` to the physical damage
    /// rect on this connector's native framebuffer, or null when the rows lie
    /// outside the connector's viewport (largest-mode clipping) or the
    /// connector is inactive. The result is half-open `[x, x+w) x [y, y+h)`,
    /// floored/ceiled from the exact rotated geometry, so damage may over-
    /// cover but never under-covers, and is clamped to the framebuffer.
    pub fn damage(self: *const Plan, canvas: Canvas, row0: u32, row1: u32, cell: Cell) ?Rect {
        if (!self.active or row1 <= row0) return null;
        // Full-width band of the dirty grid rows, in canvas pixel space.
        const dirty = Rect{
            .x = 0,
            .y = @intCast(row0 * cell.h),
            .w = canvas.width,
            .h = (row1 - row0) * cell.h,
        };
        const vis = Rect.intersect(dirty, self.src) orelse return null;

        // Map the visible part of the viewport into content space.
        const sx: f64 = @floatFromInt(self.src.x);
        const sy: f64 = @floatFromInt(self.src.y);
        const c0x = self.dst.x + (@as(f64, @floatFromInt(vis.x)) - sx) * self.scale;
        const c0y = self.dst.y + (@as(f64, @floatFromInt(vis.y)) - sy) * self.scale;
        const c1x = self.dst.x + (@as(f64, @floatFromInt(vis.endX())) - sx) * self.scale;
        const c1y = self.dst.y + (@as(f64, @floatFromInt(vis.endY())) - sy) * self.scale;

        // Rotate the four corners into the native framebuffer. Because the
        // scale is uniform and rotations are multiples of 90°, the image of
        // an axis-aligned rect is axis-aligned: the corner bounding box is
        // the exact rect.
        const wn: f64 = @floatFromInt(self.conn.width_px);
        const hn: f64 = @floatFromInt(self.conn.height_px);
        const rot = self.conn.rotation;
        const p00 = rotmap(f64, rot, c0x, c0y, wn, hn);
        const p10 = rotmap(f64, rot, c1x, c0y, wn, hn);
        const p01 = rotmap(f64, rot, c0x, c1y, wn, hn);
        const p11 = rotmap(f64, rot, c1x, c1y, wn, hn);
        const lo_x = @min(@min(p00.x, p10.x), @min(p01.x, p11.x));
        const hi_x = @max(@max(p00.x, p10.x), @max(p01.x, p11.x));
        const lo_y = @min(@min(p00.y, p10.y), @min(p01.y, p11.y));
        const hi_y = @max(@max(p00.y, p10.y), @max(p01.y, p11.y));

        // Floor/ceil + clamp: rounding error can only enlarge the rect.
        const x0: f64 = std.math.clamp(@floor(lo_x), 0, wn);
        const y0: f64 = std.math.clamp(@floor(lo_y), 0, hn);
        const x1: f64 = std.math.clamp(@ceil(hi_x), 0, wn);
        const y1: f64 = std.math.clamp(@ceil(hi_y), 0, hn);
        return .{
            .x = @intFromFloat(x0),
            .y = @intFromFloat(y0),
            .w = @intFromFloat(x1 - x0),
            .h = @intFromFloat(y1 - y0),
        };
    }
};

/// Compute the shared terminal grid and per-connector viewport plans.
///
/// `plans` must have at least as many entries as `connectors`; entry `i`
/// describes `connectors[i]`. Disabled connectors get an inactive plan and
/// take no part in the shared canvas.
///
/// Grid semantics per mode:
///   - clone: all connectors show the full canvas at 1:1; the canvas is the
///     smallest effective resolution common to the enabled connectors.
///   - largest: the canvas is the biggest effective resolution; every
///     connector shows a centered viewport the size of its own effective
///     area, clipped to the canvas.
///   - scaled: canvas as in clone; every connector scales the full canvas up
///     uniformly to fit its effective area (larger monitors scale the font
///     up), centered.
pub fn computeLayout(connectors: []const Connector, cell: Cell, mode: MultiMonitorMode, plans: []Plan) Canvas {
    std.debug.assert(cell.w > 0 and cell.h > 0);

    const count = @min(connectors.len, plans.len);
    for (plans) |*p| p.* = .{};

    // Extents of the enabled connectors' effective resolutions.
    var eff_w_min: u32 = std.math.maxInt(u32);
    var eff_h_min: u32 = std.math.maxInt(u32);
    var eff_w_max: u32 = 0;
    var eff_h_max: u32 = 0;
    var enabled: usize = 0;
    for (connectors[0..count], 0..) |c, i| {
        if (!c.enabled) continue;
        const eff = c.effectiveSize();
        eff_w_min = @min(eff_w_min, eff.w);
        eff_h_min = @min(eff_h_min, eff.h);
        eff_w_max = @max(eff_w_max, eff.w);
        eff_h_max = @max(eff_h_max, eff.h);
        enabled += 1;
        plans[i].active = true;
        plans[i].index = i;
        plans[i].conn = c;
    }
    if (enabled == 0) return .{};

    const extent = switch (mode) {
        .clone, .scaled => Size{ .w = eff_w_min, .h = eff_h_min },
        .largest => Size{ .w = eff_w_max, .h = eff_h_max },
    };
    const cols = @max(extent.w / cell.w, 1);
    const rows = @max(extent.h / cell.h, 1);
    const canvas = Canvas{
        .cols = cols,
        .rows = rows,
        .width = cols * cell.w,
        .height = rows * cell.h,
    };

    for (connectors[0..count], 0..) |c, i| {
        if (!c.enabled) continue;
        const eff = c.effectiveSize();
        const p = &plans[i];
        switch (mode) {
            .clone, .scaled => p.src = .{ .w = canvas.width, .h = canvas.height },
            .largest => {
                // Centered viewport of the connector's effective size,
                // clipped to the canvas.
                const vw = @min(eff.w, canvas.width);
                const vh = @min(eff.h, canvas.height);
                p.src = .{
                    .x = @intCast((canvas.width - vw) / 2),
                    .y = @intCast((canvas.height - vh) / 2),
                    .w = vw,
                    .h = vh,
                };
            },
        }
        if (mode == .scaled) {
            p.scale = @min(
                @as(f64, @floatFromInt(eff.w)) / @as(f64, @floatFromInt(canvas.width)),
                @as(f64, @floatFromInt(eff.h)) / @as(f64, @floatFromInt(canvas.height)),
            );
        }
        // Destination: the scaled viewport, centered in the effective area.
        const dw = @as(f64, @floatFromInt(p.src.w)) * p.scale;
        const dh = @as(f64, @floatFromInt(p.src.h)) * p.scale;
        p.dst = .{
            .x = (@as(f64, @floatFromInt(eff.w)) - dw) / 2,
            .y = (@as(f64, @floatFromInt(eff.h)) - dh) / 2,
            .w = dw,
            .h = dh,
        };
    }

    return canvas;
}

/// The `[gpu][connector]` prefix of a `mode=` / `screen=` entry. Matching
/// implements the kmscon 3-tier rule: exact gpu+connector beats
/// connector-only beats global; within a tier the first spec in list order
/// wins ("first match wins", `config_get_mode` / `config_get_screen`).
pub const DisplayPattern = struct {
    gpu: ?[]const u8 = null,
    connector: ?[]const u8 = null,

    /// Match strength: 2 = exact gpu+connector, 1 = connector only,
    /// 0 = global (no gpu, no connector; also gpu-only, which the mode=
    /// grammar cannot produce).
    pub fn tier(self: DisplayPattern) u2 {
        if (self.connector != null) return if (self.gpu != null) 2 else 1;
        return 0;
    }

    /// Whether this pattern applies to a display with the given gpu and
    /// connector names.
    pub fn matches(self: DisplayPattern, gpu: []const u8, conn: []const u8) bool {
        if (self.connector) |want| {
            if (!std.mem.eql(u8, want, conn)) return false;
        }
        if (self.gpu) |want| {
            if (!std.mem.eql(u8, want, gpu)) return false;
        }
        return true;
    }
};

/// A `--mode` entry: `[gpu][connector]WxH@R`. The rate is optional; a null
/// rate means "not specified" (kmscon keeps the connector's current rate).
pub const ModeSpec = struct {
    pattern: DisplayPattern = .{},
    width: u32 = 0,
    height: u32 = 0,
    rate: ?u16 = null,
};

/// A `--screen` entry: `[gpu][connector]orientation`, where `disabled` is
/// represented by the `disabled` flag (any rotation value is then ignored).
pub const ScreenSpec = struct {
    pattern: DisplayPattern = .{},
    rotation: Rotation = .normal,
    disabled: bool = false,
};

/// 3-pass lookup implementing "first match wins" precedence: exact
/// gpu+connector, then connector-only, then global. Returns null when no spec
/// matches the display.
fn lookupSpec(comptime Spec: type, specs: []const Spec, gpu: []const u8, conn: []const u8) ?Spec {
    for ([_]u2{ 2, 1, 0 }) |tier| {
        for (specs) |s| {
            if (s.pattern.tier() == tier and s.pattern.matches(gpu, conn)) return s;
        }
    }
    return null;
}

/// Highest-precedence `--mode` spec matching the display, or null (caller
/// falls back to the default mode).
pub fn lookupMode(specs: []const ModeSpec, gpu: []const u8, conn: []const u8) ?ModeSpec {
    return lookupSpec(ModeSpec, specs, gpu, conn);
}

/// Highest-precedence `--screen` spec matching the display, or null (caller
/// falls back to normal, enabled).
pub fn lookupScreen(specs: []const ScreenSpec, gpu: []const u8, conn: []const u8) ?ScreenSpec {
    return lookupSpec(ScreenSpec, specs, gpu, conn);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn assertPoint(exp: Point, act: Point) !void {
    try testing.expectEqual(exp.x, act.x);
    try testing.expectEqual(exp.y, act.y);
}

fn assertRect(exp: Rect, act: Rect) !void {
    try testing.expectEqual(exp.x, act.x);
    try testing.expectEqual(exp.y, act.y);
    try testing.expectEqual(exp.w, act.w);
    try testing.expectEqual(exp.h, act.h);
}

fn assertFRect(exp: FRect, act: FRect) !void {
    try testing.expect(std.math.approxEqAbs(f64, exp.x, act.x, 1e-6));
    try testing.expect(std.math.approxEqAbs(f64, exp.y, act.y, 1e-6));
    try testing.expect(std.math.approxEqAbs(f64, exp.w, act.w, 1e-6));
    try testing.expect(std.math.approxEqAbs(f64, exp.h, act.h, 1e-6));
}

fn expectScale(exp: f64, act: f64) !void {
    try testing.expect(std.math.approxEqAbs(f64, exp, act, 1e-9));
}

test "rotation: fromConfigString parses the four screen= orientations" {
    try testing.expectEqual(Rotation.normal, Rotation.fromConfigString("normal").?);
    try testing.expectEqual(Rotation.right, Rotation.fromConfigString("right").?);
    try testing.expectEqual(Rotation.left, Rotation.fromConfigString("left").?);
    try testing.expectEqual(Rotation.inverted, Rotation.fromConfigString("upside-down").?);
    // disabled is a disposition, not a rotation; unknown tokens are invalid.
    try testing.expect(Rotation.fromConfigString("disabled") == null);
    try testing.expect(Rotation.fromConfigString("inverted") == null);
    try testing.expect(Rotation.fromConfigString("") == null);
}

test "rotation: rotateCw/rotateCcw step through all four states" {
    try testing.expectEqual(Rotation.right, Rotation.normal.rotateCw());
    try testing.expectEqual(Rotation.inverted, Rotation.right.rotateCw());
    try testing.expectEqual(Rotation.left, Rotation.inverted.rotateCw());
    try testing.expectEqual(Rotation.normal, Rotation.left.rotateCw());

    try testing.expectEqual(Rotation.left, Rotation.normal.rotateCcw());
    try testing.expectEqual(Rotation.inverted, Rotation.left.rotateCcw());
    try testing.expectEqual(Rotation.right, Rotation.inverted.rotateCcw());
    try testing.expectEqual(Rotation.normal, Rotation.right.rotateCcw());
}

test "rotation: effectiveDimensions swaps axes for 90-degree rotations" {
    try testing.expectEqual(Size{ .w = 1920, .h = 1080 }, Rotation.normal.effectiveDimensions(1920, 1080));
    try testing.expectEqual(Size{ .w = 1920, .h = 1080 }, Rotation.inverted.effectiveDimensions(1920, 1080));
    try testing.expectEqual(Size{ .w = 1080, .h = 1920 }, Rotation.right.effectiveDimensions(1920, 1080));
    try testing.expectEqual(Size{ .w = 1080, .h = 1920 }, Rotation.left.effectiveDimensions(1920, 1080));
    // Square panels are unaffected.
    try testing.expectEqual(Size{ .w = 800, .h = 800 }, Rotation.right.effectiveDimensions(800, 800));
}

test "rotation: corner/interior bijection for all four rotations" {
    // Non-square frame so axis mix-ups cannot hide.
    const pw: u32 = 1600;
    const ph: u32 = 900;
    for (std.meta.tags(Rotation)) |rot| {
        const eff = rot.effectiveDimensions(pw, ph);
        const cw: i32 = @intCast(pw - 1);
        const ch: i32 = @intCast(ph - 1);
        const ew: i32 = @intCast(eff.w - 1);
        const eh: i32 = @intCast(eff.h - 1);

        // Corners of the logical (content) area map exactly onto corners of
        // the physical frame, and the inverse round-trips.
        const corners = [_]Point{
            .{ .x = 0, .y = 0 },
            .{ .x = ew, .y = 0 },
            .{ .x = 0, .y = eh },
            .{ .x = ew, .y = eh },
        };
        for (corners) |lc| {
            const pc = rot.logicalToPhysical(lc.x, lc.y, pw, ph);
            try testing.expect((pc.x == 0 or pc.x == cw) and (pc.y == 0 or pc.y == ch));
            const back = rot.physicalToLogical(pc.x, pc.y, pw, ph);
            try assertPoint(lc, back);
        }

        // Interior points stay strictly interior and round-trip exactly.
        const interior = [_]Point{
            .{ .x = 1, .y = 1 },
            .{ .x = @divTrunc(ew, 2), .y = @divTrunc(eh, 2) },
            .{ .x = ew - 2, .y = eh - 3 },
            .{ .x = 7, .y = eh - 1 }, // edge, not a corner
        };
        for (interior) |lp| {
            const pc = rot.logicalToPhysical(lp.x, lp.y, pw, ph);
            try testing.expect(pc.x > 0 and pc.x < cw and pc.y > 0 and pc.y < ch);
            const back = rot.physicalToLogical(pc.x, pc.y, pw, ph);
            try assertPoint(lp, back);
        }

        // Boundary (non-corner) points stay on the boundary: at least one
        // coordinate becomes an extreme of the physical frame.
        const boundary = [_]Point{
            .{ .x = @divTrunc(ew, 2), .y = 0 },
            .{ .x = 0, .y = @divTrunc(eh, 2) },
            .{ .x = ew, .y = @divTrunc(eh, 2) },
            .{ .x = @divTrunc(ew, 2), .y = eh },
        };
        for (boundary) |bp| {
            const pc = rot.logicalToPhysical(bp.x, bp.y, pw, ph);
            try testing.expect((pc.x == 0 or pc.x == cw) or (pc.y == 0 or pc.y == ch));
        }
    }
}

test "rotation: exact expected corner moves on a non-square frame" {
    // Sanity-pin the formulas: 1280x1024 native, content rotated 90° cw.
    const rot = Rotation.right;
    try assertPoint(.{ .x = 1279, .y = 0 }, rot.logicalToPhysical(0, 0, 1280, 1024));
    try assertPoint(.{ .x = 1279, .y = 1023 }, rot.logicalToPhysical(1023, 0, 1280, 1024));
    try assertPoint(.{ .x = 0, .y = 0 }, rot.logicalToPhysical(0, 1279, 1280, 1024));
    try assertPoint(.{ .x = 0, .y = 1023 }, rot.logicalToPhysical(1023, 1279, 1280, 1024));
    try assertPoint(.{ .x = 0, .y = 1279 }, rot.physicalToLogical(0, 0, 1280, 1024));
    try assertPoint(.{ .x = 0, .y = 0 }, rot.physicalToLogical(1279, 0, 1280, 1024));
}

test "multi-monitor mode: kmscon clones on any unknown string" {
    try testing.expectEqual(MultiMonitorMode.scaled, MultiMonitorMode.fromConfigString("scaled"));
    try testing.expectEqual(MultiMonitorMode.largest, MultiMonitorMode.fromConfigString("largest"));
    try testing.expectEqual(MultiMonitorMode.clone, MultiMonitorMode.fromConfigString("clone"));
    try testing.expectEqual(MultiMonitorMode.clone, MultiMonitorMode.fromConfigString("bogus"));
    try testing.expectEqual(MultiMonitorMode.clone, MultiMonitorMode.fromConfigString(""));
    try testing.expectEqual(MultiMonitorMode.clone, MultiMonitorMode.fromConfigString("SCALED"));
    try testing.expectEqual(MultiMonitorMode.scaled, MultiMonitorMode.default);
}

test "display pattern: tier ordering and matches" {
    var g = DisplayPattern{};
    try testing.expectEqual(@as(u2, 0), g.tier());
    try testing.expect(g.matches("card0", "HDMI-A-1"));

    g = .{ .connector = "HDMI-A-1" };
    try testing.expectEqual(@as(u2, 1), g.tier());
    try testing.expect(g.matches("card0", "HDMI-A-1"));
    try testing.expect(!g.matches("card0", "DP-1"));

    g = .{ .gpu = "card0", .connector = "HDMI-A-1" };
    try testing.expectEqual(@as(u2, 2), g.tier());
    try testing.expect(g.matches("card0", "HDMI-A-1"));
    try testing.expect(!g.matches("card1", "HDMI-A-1"));
    try testing.expect(!g.matches("card0", "DP-1"));
}

test "lookupMode: card0-HDMI-A-1 beats HDMI-A-1 beats *" {
    const specs = [_]ModeSpec{
        .{ .pattern = .{}, .width = 1920, .height = 1080, .rate = 60 },
        .{ .pattern = .{ .connector = "HDMI-A-1" }, .width = 1024, .height = 768 },
        .{ .pattern = .{ .gpu = "card0", .connector = "HDMI-A-1" }, .width = 800, .height = 600 },
    };

    // Exact gpu+connector wins over the connector-only and global specs.
    const m0 = lookupMode(&specs, "card0", "HDMI-A-1").?;
    try testing.expectEqual(@as(u32, 800), m0.width);
    try testing.expectEqual(@as(u32, 600), m0.height);

    // Same connector on another GPU: connector-only spec wins.
    const m1 = lookupMode(&specs, "card1", "HDMI-A-1").?;
    try testing.expectEqual(@as(u32, 1024), m1.width);

    // Unmatched connector: the global spec wins.
    const m2 = lookupMode(&specs, "card1", "DP-1").?;
    try testing.expectEqual(@as(u32, 1920), m2.width);
    try testing.expectEqual(@as(?u16, 60), m2.rate);

    // No global spec and no match: null.
    const only_exact = [_]ModeSpec{.{
        .pattern = .{ .gpu = "card0", .connector = "HDMI-A-1" },
        .width = 800,
        .height = 600,
    }};
    try testing.expect(lookupMode(&only_exact, "card1", "DP-1") == null);

    // Within a tier the first spec in list order wins.
    const tier_tie = [_]ModeSpec{
        .{ .pattern = .{ .connector = "HDMI-A-1" }, .width = 1024, .height = 768 },
        .{ .pattern = .{ .connector = "HDMI-A-1" }, .width = 640, .height = 480 },
    };
    try testing.expectEqual(@as(u32, 1024), lookupMode(&tier_tie, "card2", "HDMI-A-1").?.width);
}

test "lookupScreen: 3-tier matching with orientation and disabled" {
    const specs = [_]ScreenSpec{
        .{ .pattern = .{}, .rotation = .inverted },
        .{ .pattern = .{ .connector = "DP-1" }, .rotation = .right },
        .{ .pattern = .{ .gpu = "card1", .connector = "DP-1" }, .disabled = true },
    };

    // Exact spec wins: that display is disabled.
    const s0 = lookupScreen(&specs, "card1", "DP-1").?;
    try testing.expect(s0.disabled);

    // DP-1 on another GPU: connector-only tier, rotation right.
    const s1 = lookupScreen(&specs, "card9", "DP-1").?;
    try testing.expect(!s1.disabled);
    try testing.expectEqual(Rotation.right, s1.rotation);

    // Anything else: global tier, upside-down.
    const s2 = lookupScreen(&specs, "card9", "VGA-1").?;
    try testing.expectEqual(Rotation.inverted, s2.rotation);

    // No match at all: null (caller falls back to normal, enabled).
    const only_dp = [_]ScreenSpec{.{
        .pattern = .{ .connector = "DP-1" },
        .rotation = .left,
    }};
    try testing.expect(lookupScreen(&only_dp, "card0", "HDMI-A-1") == null);
}

test "layout clone: grid and viewports for dual 1920x1080 + 1280x1024 rotated" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .clone, &plans);

    // Smallest common effective res: min(1920, 1024) x min(1080, 1280).
    try testing.expectEqual(@as(u32, 128), canvas.cols); // 1024 / 8
    try testing.expectEqual(@as(u32, 67), canvas.rows); // 1072 / 16 (floor)
    try testing.expectEqual(@as(u32, 1024), canvas.width);
    try testing.expectEqual(@as(u32, 1072), canvas.height);

    // HDMI-A-1 (1920x1080, normal): full canvas centered, 1:1.
    try testing.expect(plans[0].active);
    try testing.expectEqual(@as(usize, 0), plans[0].index);
    try assertRect(.{ .x = 0, .y = 0, .w = 1024, .h = 1072 }, plans[0].src);
    try expectScale(1, plans[0].scale);
    try assertFRect(.{ .x = 448, .y = 4, .w = 1024, .h = 1072 }, plans[0].dst);

    // DP-1 (1280x1024 rotated right, effective 1024x1280): canvas centered.
    try testing.expect(plans[1].active);
    try assertRect(.{ .x = 0, .y = 0, .w = 1024, .h = 1072 }, plans[1].src);
    try expectScale(1, plans[1].scale);
    try assertFRect(.{ .x = 0, .y = 104, .w = 1024, .h = 1072 }, plans[1].dst);
}

test "layout largest: grid and centered/clipped viewports" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .largest, &plans);

    // Biggest effective res: max(1920, 1024) x max(1080, 1280).
    try testing.expectEqual(@as(u32, 240), canvas.cols); // 1920 / 8
    try testing.expectEqual(@as(u32, 80), canvas.rows); // 1280 / 16
    try testing.expectEqual(@as(u32, 1920), canvas.width);
    try testing.expectEqual(@as(u32, 1280), canvas.height);

    // The biggest connector sees the whole canvas, vertically centered
    // (1080 of 1280 rows) at 1:1.
    try assertRect(.{ .x = 0, .y = 100, .w = 1920, .h = 1080 }, plans[0].src);
    try expectScale(1, plans[0].scale);
    try assertFRect(.{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, plans[0].dst);

    // The rotated 1280x1024 (effective 1024x1280) shows a centered window
    // of the canvas.
    try assertRect(.{ .x = 448, .y = 0, .w = 1024, .h = 1280 }, plans[1].src);
    try expectScale(1, plans[1].scale);
    try assertFRect(.{ .x = 0, .y = 0, .w = 1024, .h = 1280 }, plans[1].dst);
}

test "layout scaled: smallest sets the grid, larger outputs scale up" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .scaled, &plans);

    // Grid from the smallest effective res, like clone.
    try testing.expectEqual(@as(u32, 128), canvas.cols);
    try testing.expectEqual(@as(u32, 67), canvas.rows);
    try testing.expectEqual(@as(u32, 1024), canvas.width);
    try testing.expectEqual(@as(u32, 1072), canvas.height);

    // HDMI-A-1 scales the 1024x1072 canvas up to fit 1920x1080: the height
    // ratio (1080/1072, the smaller of the two) wins, leaving horizontal
    // margins.
    try expectScale(1080.0 / 1072.0, plans[0].scale);
    try assertFRect(.{
        .x = (1920.0 - 1024.0 * (1080.0 / 1072.0)) / 2.0,
        .y = 0,
        .w = 1024.0 * (1080.0 / 1072.0),
        .h = 1072.0 * (1080.0 / 1072.0),
    }, plans[0].dst);

    // DP-1 (effective 1024x1280) is the width minimum: scale 1, centered.
    try expectScale(1, plans[1].scale);
    try assertFRect(.{ .x = 0, .y = 104, .w = 1024, .h = 1072 }, plans[1].dst);
}

test "layout: disabled connectors are excluded from the canvas" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .enabled = false },
        .{ .gpu = "card1", .connector = "DP-1", .width_px = 640, .height_px = 480 },
    };
    var plans: [3]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .clone, &plans);

    try testing.expect(!plans[1].active);
    try testing.expect(plans[0].active);
    try testing.expect(plans[2].active);
    try testing.expectEqual(@as(u32, 80), canvas.cols); // 640 / 8
    try testing.expectEqual(@as(u32, 30), canvas.rows); // 480 / 16
    try testing.expectEqual(@as(u32, 640), canvas.width);
    try testing.expectEqual(@as(u32, 480), canvas.height);
}

test "damage: dirty rows map per connector, rotated included" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .clone, &plans);
    const cell = Cell{ .w = 8, .h = 16 };

    // Rows [0, 2) = a 1024x32 full-width band at the top of the canvas.
    // Unrotated output: the band, offset by the centered destination.
    const d0 = plans[0].damage(canvas, 0, 2, cell).?;
    try assertRect(.{ .x = 448, .y = 4, .w = 1024, .h = 32 }, d0);

    // Right-rotated 1280x1024: the horizontal band becomes a 32px-wide
    // vertical band on the right edge (rows are columns after rotation).
    const d1 = plans[1].damage(canvas, 0, 2, cell).?;
    try assertRect(.{ .x = 1143, .y = 0, .w = 32, .h = 1024 }, d1);

    // A single row maps likewise (16px tall -> 16px wide band).
    const d1a = plans[1].damage(canvas, 0, 1, cell).?;
    try assertRect(.{ .x = 1159, .y = 0, .w = 16, .h = 1024 }, d1a);

    // Empty row ranges produce no damage.
    try testing.expect(plans[0].damage(canvas, 3, 3, cell) == null);
    // Inactive connectors never damage.
    plans[0].active = false;
    try testing.expect(plans[0].damage(canvas, 0, 2, cell) == null);
}

test "damage: rows outside a largest-mode viewport are skipped" {
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080 },
        .{ .gpu = "card0", .connector = "DP-1", .width_px = 1280, .height_px = 1024, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .largest, &plans);
    const cell = Cell{ .w = 8, .h = 16 };

    // HDMI-A-1's viewport covers canvas y in [100, 1180) (6.25 to 73.75
    // rows): rows 0..5 lie entirely above it, rows 74+ entirely below.
    try testing.expect(plans[0].damage(canvas, 0, 6, cell) == null);
    try testing.expect(plans[0].damage(canvas, 74, 76, cell) == null);

    // Rows [0, 7) reach canvas y 112, so the overlap with the viewport
    // (starting at y 100) is clipped to its top 12 pixels.
    const dclip = plans[0].damage(canvas, 0, 7, cell).?;
    try assertRect(.{ .x = 0, .y = 0, .w = 1920, .h = 12 }, dclip);

    // Rows [7, 8) -> logical y [112, 128) is inside the viewport
    // [100, 1180): canvas row 7 shows on HDMI-A-1 at content y 12.
    const d0 = plans[0].damage(canvas, 7, 8, cell).?;
    try assertRect(.{ .x = 0, .y = 12, .w = 1920, .h = 16 }, d0);
}

test "damage: rotated output with non-integer scale" {
    // S (1024x768) sets the grid; L is 1920x1080 rotated 90°, effective
    // 1080x1920 — strictly larger than the canvas in both axes, so it gets a
    // non-integer scale factor (1080/1024 = 135/128, exact).
    const conns = [_]Connector{
        .{ .gpu = "card0", .connector = "VGA-1", .width_px = 1024, .height_px = 768 },
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width_px = 1920, .height_px = 1080, .rotation = .right },
    };
    var plans: [2]Plan = undefined;
    const canvas = computeLayout(&conns, .{ .w = 8, .h = 16 }, .scaled, &plans);
    const cell = Cell{ .w = 8, .h = 16 };

    try testing.expectEqual(@as(u32, 128), canvas.cols); // 1024 / 8
    try testing.expectEqual(@as(u32, 48), canvas.rows); // 768 / 16

    // L: scale 135/128; dst is exactly (0, 555, 1080, 810) in content space.
    try expectScale(1080.0 / 1024.0, plans[1].scale);
    try assertFRect(.{ .x = 0, .y = 555, .w = 1080, .h = 810 }, plans[1].dst);

    // Unrotated S: plain 1:1 band.
    const d0 = plans[0].damage(canvas, 0, 1, cell).?;
    try assertRect(.{ .x = 0, .y = 0, .w = 1024, .h = 16 }, d0);

    // Rotated + scaled: row band [0,1) -> content y [555, 571.875), rotated
    // 90° cw onto a 1920x1080 frame -> a 17px-wide vertical band on the
    // right edge (x 1347..1364).
    const d1 = plans[1].damage(canvas, 0, 1, cell).?;
    try assertRect(.{ .x = 1347, .y = 0, .w = 17, .h = 1080 }, d1);
}