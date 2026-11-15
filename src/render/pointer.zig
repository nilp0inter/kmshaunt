//! src/render/pointer.zig -- software mouse-pointer model (canvas space).
//!
//! Backend-agnostic: imports only std + framebuffer.zig (contract file).
//! The pointer lives in CANVAS pixel space; mapping canvas coordinates to
//! physical connectors is the wiring's job (video/layout.zig Plan), not
//! this module's. Time is passed in as now_ns on every call: the module
//! owns no loop, timer or fd, matching the repo seam convention.
//!
//! Sprite: a classic 12x19 arrow (white fill, black outline, transparent
//! background), hotspot at the tip (sprite pixel 0,0), optionally scaled
//! by an integer factor. Pixels are deterministic; drawing is a plain
//! blit of one small ARGB8888 buffer.
//!
//! Drawing invariant: the pointer is composited into the BACK BUFFER
//! only, never into the shadow canvas. The shadow holds terminal content
//! and must stay pointer-free so damaged regions can be restored from it.
//! With double-buffered page flips the previous pointer pixels may sit in
//! either buffer, so BOTH the old and the new rect must be damaged every
//! frame or ghosts survive the flip. Per composited frame:
//!
//!     const d = pointer.takeDamage(); // old = erase rect, new = draw rect
//!     damage(d.old);                  // restore from the shadow canvas
//!     damage(d.new);                  // alpha-blit sprite() into here
//!     pointer.markDrawn();            // commit, after the blit happened
//!
//! takeDamage() is a pure query (safe to call while scheduling frames);
//! markDrawn() advances the tracked rect only when the frame was really
//! drawn. hide() (seat deactivate / DPMS off) forces hidden but keeps the
//! tracked rect, so the next takeDamage() still reports the erase rect.
//!
//! Visibility: hidden until the first motion()/button(); both record
//! activity; tick() autohides after idle_timeout_ns and returns true
//! exactly once per visible->hidden transition.

const std = @import("std");
const framebuffer = @import("../framebuffer.zig");

pub const Framebuffer = framebuffer.Framebuffer;
pub const Damage = framebuffer.Damage;

const testing = std.testing;

/// Default autohide idle timeout: 4 s without motion or buttons.
pub const default_idle_timeout_ns: i64 = 4 * std.time.ns_per_s;

/// Base arrow geometry: 12x19 pixels, hotspot at the tip (0,0).
const base_w: u32 = 12;
const base_h: u32 = 19;

/// The arrow bitmap: 'X' = black outline, '#' = white fill, '.' =
/// transparent. Fixed literal, so the sprite is byte-deterministic.
const arrow_rows = [_][]const u8{
    "X...........",
    "XX..........",
    "X#X.........",
    "X##X........",
    "X###X.......",
    "X####X......",
    "X#####X.....",
    "X######X....",
    "X#######X...",
    "X########X..",
    "X#########X.",
    "X#####XXXXX.",
    "X##X##X.....",
    "X#X.X##X....",
    "XX...X##X...",
    "X....X##X...",
    "......X##X..",
    "......X##X..",
    ".......XX...",
};

comptime {
    if (arrow_rows.len != base_h) @compileError("arrow: row count mismatch");
    for (arrow_rows) |row| {
        if (row.len != base_w) @compileError("arrow: row width mismatch");
        for (row) |c| switch (c) {
            'X', '#', '.' => {},
            else => @compileError("arrow: unknown pixel char"),
        };
    }
}

const outline_color: u32 = 0xFF000000;
const fill_color: u32 = 0xFFFFFFFF;
const transparent: u32 = 0x00000000;

const empty_damage = Damage{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Construction options. No config-file knob here: the wiring passes
/// whatever it resolved.
pub const Options = struct {
    /// Integer nearest-neighbor scale of the 12x19 base arrow. Must be
    /// >= 1 (0 is rejected with error.InvalidScale).
    scale: u32 = 1,
    /// Idle time after the last motion/button before tick() hides the
    /// pointer. <= 0 disables autohide.
    idle_timeout_ns: i64 = default_idle_timeout_ns,
};

pub const InitError = std.mem.Allocator.Error || error{
    /// canvas_w or canvas_h is zero.
    InvalidCanvas,
    /// scale is zero, or the scaled sprite dimensions overflow u32.
    InvalidScale,
};

/// Canvas-space position of the hotspot, in pixels.
pub const Position = struct {
    x: i32,
    y: i32,
};

/// One frame's pointer damage. `old` is where the pointer was drawn last
/// committed frame (erase it by restoring the shadow canvas); `new` is
/// where it must be drawn now (empty while hidden). Both rects are
/// clipped to the canvas and must be damaged on the back buffer.
pub const FrameDamage = struct {
    old: Damage,
    new: Damage,
};

/// Software mouse pointer: position, visibility, autohide and erase/draw
/// damage tracking over a canvas of fixed size. Single-threaded, owned by
/// the console; all timestamps are caller-supplied monotonic nanoseconds.
pub const Pointer = struct {
    allocator: std.mem.Allocator,
    canvas_w: u32,
    canvas_h: u32,
    sprite_fb: Framebuffer,
    /// Hotspot offset within the sprite (the tip, 0,0 at every scale).
    hotspot_x: u32,
    hotspot_y: u32,
    /// Hotspot position in canvas pixels, clamped to the canvas.
    x: i32,
    y: i32,
    visible: bool,
    last_activity_ns: i64,
    idle_timeout_ns: i64,
    /// Rect committed by the last markDrawn(); empty = nothing on screen.
    drawn: Damage,

    /// Build the arrow sprite and a hidden pointer at the origin.
    pub fn init(
        allocator: std.mem.Allocator,
        canvas_w: u32,
        canvas_h: u32,
        opts: Options,
    ) InitError!Pointer {
        if (canvas_w == 0 or canvas_h == 0) return error.InvalidCanvas;
        if (opts.scale == 0) return error.InvalidScale;
        const sprite_w = std.math.mul(u32, base_w, opts.scale) catch
            return error.InvalidScale;
        const sprite_h = std.math.mul(u32, base_h, opts.scale) catch
            return error.InvalidScale;

        var sprite_fb = try Framebuffer.create(
            allocator,
            sprite_w,
            sprite_h,
            .argb8888,
            null,
        );
        var y: u32 = 0;
        while (y < sprite_h) : (y += 1) {
            const row = arrow_rows[y / opts.scale];
            var x: u32 = 0;
            while (x < sprite_w) : (x += 1) {
                const color: u32 = switch (row[x / opts.scale]) {
                    'X' => outline_color,
                    '#' => fill_color,
                    '.' => transparent,
                    else => unreachable,
                };
                sprite_fb.set(x, y, color);
            }
        }

        return .{
            .allocator = allocator,
            .canvas_w = canvas_w,
            .canvas_h = canvas_h,
            .sprite_fb = sprite_fb,
            .hotspot_x = 0,
            .hotspot_y = 0,
            .x = 0,
            .y = 0,
            .visible = false,
            .last_activity_ns = 0,
            .idle_timeout_ns = opts.idle_timeout_ns,
            .drawn = empty_damage,
        };
    }

    pub fn deinit(self: *Pointer) void {
        self.sprite_fb.destroy(self.allocator);
        self.* = undefined;
    }

    /// The ARGB8888 arrow sprite, valid until deinit.
    pub fn sprite(self: *const Pointer) *const Framebuffer {
        return &self.sprite_fb;
    }

    /// Current hotspot position in canvas pixels.
    pub fn position(self: *const Pointer) Position {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn isVisible(self: *const Pointer) bool {
        return self.visible;
    }

    /// Absolute canvas-space motion: clamp to the canvas, show, record
    /// activity. Fractional coordinates truncate toward zero; NaN parks
    /// at the origin so a poisoned event cannot move the pointer wildly.
    pub fn motion(self: *Pointer, x: f64, y: f64, now_ns: i64) void {
        self.x = clampCoord(x, self.canvas_w);
        self.y = clampCoord(y, self.canvas_h);
        self.visible = true;
        self.last_activity_ns = now_ns;
    }

    /// Button press: show and record activity without moving.
    pub fn button(self: *Pointer, now_ns: i64) void {
        self.visible = true;
        self.last_activity_ns = now_ns;
    }

    /// Autohide poll. Returns true exactly when the pointer transitions
    /// visible->hidden because idle_timeout_ns elapsed since the last
    /// activity; false otherwise (including every later tick). A
    /// non-positive timeout disables autohide.
    pub fn tick(self: *Pointer, now_ns: i64) bool {
        if (!self.visible) return false;
        if (self.idle_timeout_ns <= 0) return false;
        if (now_ns - self.last_activity_ns < self.idle_timeout_ns) return false;
        self.visible = false;
        return true;
    }

    /// Force hidden (seat deactivate / DPMS off). Keeps the tracked
    /// drawn rect: the next takeDamage() still reports the erase rect.
    pub fn hide(self: *Pointer) void {
        self.visible = false;
    }

    /// Sprite bounding rect at the current position, clipped to the
    /// canvas; empty when it does not intersect. Pure query.
    pub fn bounds(self: *const Pointer) Damage {
        const x0: i64 = @as(i64, self.x) - self.hotspot_x;
        const y0: i64 = @as(i64, self.y) - self.hotspot_y;
        const x1 = x0 + @as(i64, self.sprite_fb.width);
        const y1 = y0 + @as(i64, self.sprite_fb.height);
        const cx0 = @max(x0, 0);
        const cy0 = @max(y0, 0);
        const cx1 = @min(x1, @as(i64, self.canvas_w));
        const cy1 = @min(y1, @as(i64, self.canvas_h));
        if (cx1 <= cx0 or cy1 <= cy0) return empty_damage;
        return .{
            .x = @intCast(cx0),
            .y = @intCast(cy0),
            .w = @intCast(cx1 - cx0),
            .h = @intCast(cy1 - cy0),
        };
    }

    /// This frame's erase+draw rects. Pure query: repeating it before
    /// markDrawn() returns the same result, so frame scheduling may peek
    /// without committing. See the module header for the draw protocol.
    pub fn takeDamage(self: *const Pointer) FrameDamage {
        return .{
            .old = self.drawn,
            .new = if (self.visible) self.bounds() else empty_damage,
        };
    }

    /// Commit the current rect as drawn. Call only after the pointer was
    /// actually composited into the back buffer (or its erase applied).
    pub fn markDrawn(self: *Pointer) void {
        self.drawn = if (self.visible) self.bounds() else empty_damage;
    }
};

/// Clamp one coordinate to [0, extent - 1]; extent >= 1 (init rejects
/// zero canvases). Truncates toward zero after clamping.
fn clampCoord(v: f64, extent: u32) i32 {
    const max: f64 = @floatFromInt(extent - 1);
    const clamped = if (std.math.isNan(v)) 0.0 else @max(0.0, @min(v, max));
    return @intFromFloat(clamped);
}

test "pointer: sprite is a deterministic ARGB arrow" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 640, 480, .{});
    defer p.deinit();

    const s = p.sprite();
    try testing.expectEqual(@as(u32, 12), s.width);
    try testing.expectEqual(@as(u32, 19), s.height);
    try testing.expectEqual(@as(u32, 48), s.pitch);
    try testing.expectEqual(framebuffer.PixelFormat.argb8888, s.format);

    // Tip is black outline, interior is white fill.
    try testing.expectEqual(outline_color, s.get(0, 0));
    try testing.expectEqual(fill_color, s.get(1, 2));
    // Transparent corners (the tip corner is opaque by design).
    try testing.expectEqual(transparent, s.get(11, 0));
    try testing.expectEqual(transparent, s.get(0, 18));
    try testing.expectEqual(transparent, s.get(11, 18));

    var opaque_count: u32 = 0;
    var white_count: u32 = 0;
    for (0..s.height) |y| {
        for (0..s.width) |x| {
            const px = s.get(@intCast(x), @intCast(y));
            if (px != transparent) opaque_count += 1;
            if (px == fill_color) white_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 112), opaque_count);
    try testing.expectEqual(@as(u32, 65), white_count);
}

test "pointer: motion clamps to canvas bounds and shows" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{});
    defer p.deinit();

    try testing.expect(!p.isVisible());
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, p.position());

    p.motion(500.9, -20.0, 0);
    try testing.expect(p.isVisible());
    try testing.expectEqual(Position{ .x = 99, .y = 0 }, p.position());

    p.motion(-5.5, 900.0, 10);
    try testing.expectEqual(Position{ .x = 0, .y = 79 }, p.position());

    p.motion(10.7, 20.2, 20);
    try testing.expectEqual(Position{ .x = 10, .y = 20 }, p.position());
    try testing.expectEqual(
        Damage{ .x = 10, .y = 20, .w = 12, .h = 19 },
        p.bounds(),
    );

    // Infinities clamp; NaN parks at the origin deterministically.
    p.motion(std.math.inf(f64), -std.math.inf(f64), 30);
    try testing.expectEqual(Position{ .x = 99, .y = 0 }, p.position());
    p.motion(std.math.nan(f64), std.math.nan(f64), 40);
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, p.position());
}

test "pointer: tick autohides once, only after the idle timeout" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{ .idle_timeout_ns = 1000 });
    defer p.deinit();

    // Never shown: nothing to hide.
    try testing.expect(!p.tick(0));

    p.motion(5, 5, 100);
    try testing.expect(!p.tick(1099));
    try testing.expect(p.isVisible());
    try testing.expect(p.tick(1100));
    try testing.expect(!p.isVisible());
    // Exactly once: later ticks stay false.
    try testing.expect(!p.tick(99999));

    // A button press shows again and restarts the idle clock.
    p.button(6000);
    try testing.expect(p.isVisible());
    try testing.expectEqual(Position{ .x = 5, .y = 5 }, p.position());
    try testing.expect(!p.tick(6999));
    try testing.expect(p.tick(7000));
    try testing.expect(!p.isVisible());
}

test "pointer: default idle timeout is 4 s" {
    try testing.expectEqual(
        @as(i64, 4 * std.time.ns_per_s),
        (Options{}).idle_timeout_ns,
    );
}

test "pointer: hide forces hidden without moving; activity shows again" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{});
    defer p.deinit();

    p.motion(10, 10, 0);
    p.hide();
    try testing.expect(!p.isVisible());
    try testing.expectEqual(Position{ .x = 10, .y = 10 }, p.position());
    try testing.expect(!p.tick(1_000_000_000_000));
    p.hide(); // idempotent
    try testing.expect(!p.isVisible());

    p.motion(11, 12, 5);
    try testing.expect(p.isVisible());
}

test "pointer: damage tracks old+new rects, clipped to the canvas" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{});
    defer p.deinit();

    // Fresh and hidden: nothing drawn, nothing to draw.
    var d = p.takeDamage();
    try testing.expect(d.old.isEmpty());
    try testing.expect(d.new.isEmpty());

    p.motion(10, 10, 0);
    d = p.takeDamage();
    try testing.expect(d.old.isEmpty());
    try testing.expectEqual(Damage{ .x = 10, .y = 10, .w = 12, .h = 19 }, d.new);
    // Pure query: repeating it before markDrawn changes nothing.
    try testing.expectEqual(d, p.takeDamage());
    p.markDrawn();

    p.motion(50, 40, 1);
    d = p.takeDamage();
    try testing.expectEqual(Damage{ .x = 10, .y = 10, .w = 12, .h = 19 }, d.old);
    try testing.expectEqual(Damage{ .x = 50, .y = 40, .w = 12, .h = 19 }, d.new);
    p.markDrawn();

    // Bottom-right corner: the sprite hangs off, the rect clips.
    p.motion(99, 79, 2);
    d = p.takeDamage();
    try testing.expectEqual(Damage{ .x = 50, .y = 40, .w = 12, .h = 19 }, d.old);
    try testing.expectEqual(Damage{ .x = 99, .y = 79, .w = 1, .h = 1 }, d.new);
    try testing.expect(d.new.x + d.new.w <= 100);
    try testing.expect(d.new.y + d.new.h <= 80);
    p.markDrawn();

    // hide() keeps the erase rect so the compositor can clean up.
    p.hide();
    d = p.takeDamage();
    try testing.expectEqual(Damage{ .x = 99, .y = 79, .w = 1, .h = 1 }, d.old);
    try testing.expect(d.new.isEmpty());
    p.markDrawn();
    d = p.takeDamage();
    try testing.expect(d.old.isEmpty());
    try testing.expect(d.new.isEmpty());

    // Showing again after a committed erase starts from an empty old.
    p.motion(0, 0, 3);
    d = p.takeDamage();
    try testing.expect(d.old.isEmpty());
    try testing.expectEqual(Damage{ .x = 0, .y = 0, .w = 12, .h = 19 }, d.new);
}

test "pointer: integer scale magnifies sprite and damage geometry" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{ .scale = 2 });
    defer p.deinit();

    const s = p.sprite();
    try testing.expectEqual(@as(u32, 24), s.width);
    try testing.expectEqual(@as(u32, 38), s.height);
    // Nearest-neighbor: each base pixel becomes a 2x2 block.
    try testing.expectEqual(outline_color, s.get(0, 0));
    try testing.expectEqual(outline_color, s.get(1, 1));
    try testing.expectEqual(fill_color, s.get(2, 4));
    try testing.expectEqual(fill_color, s.get(3, 5));
    try testing.expectEqual(transparent, s.get(23, 0));
    try testing.expectEqual(transparent, s.get(0, 37));

    p.motion(10, 10, 0);
    try testing.expectEqual(
        Damage{ .x = 10, .y = 10, .w = 24, .h = 38 },
        p.bounds(),
    );
    p.motion(99, 79, 1);
    try testing.expectEqual(Damage{ .x = 99, .y = 79, .w = 1, .h = 1 }, p.bounds());
}

test "pointer: rejects zero canvas and zero scale" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidCanvas, Pointer.init(a, 0, 80, .{}));
    try testing.expectError(error.InvalidCanvas, Pointer.init(a, 100, 0, .{}));
    try testing.expectError(
        error.InvalidScale,
        Pointer.init(a, 100, 80, .{ .scale = 0 }),
    );
}

test "pointer: non-positive idle timeout disables autohide" {
    const a = testing.allocator;
    var p = try Pointer.init(a, 100, 80, .{ .idle_timeout_ns = 0 });
    defer p.deinit();

    p.motion(1, 1, 0);
    try testing.expect(!p.tick(std.time.ns_per_s * 1_000_000));
    try testing.expect(p.isVisible());
}
