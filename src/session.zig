//! src/session.zig -- session contract (ROADMAP §3, M1 terminal session,
//! M6 session manager / dummy session).
//!
//! A session is one screen of content: the terminal session (pty +
//! libghostty-vt Terminal + effects) or the dummy session. The session
//! manager starts/stops sessions, routes input to the focused one and asks
//! it to render into the video backend's back buffer.
//!
//! Rendering follows the libghostty-vt host loop (ghostty-vt-api.md §11):
//! the session draws its current state into `RenderContext.fb` and appends
//! the rectangles it touched to `RenderContext.damage`; the caller presents
//! the damage through video.Backend.endFrame and clears the list between
//! frames. Sessions never present or flip themselves.
//!
//! Imports: std + framebuffer.zig only. `DamageList` below is the SAME type
//! as render.DamageList (both are std.ArrayListUnmanaged(framebuffer.Damage));
//! it is re-declared here so this contract does not import render.zig.

const std = @import("std");
const framebuffer = @import("framebuffer.zig");

pub const Framebuffer = framebuffer.Framebuffer;
pub const Damage = framebuffer.Damage;

/// Accumulated damage rectangles for one frame. Unmanaged: the caller owns
/// the allocator and passes it to every mutating call. Same type as
/// render.DamageList.
pub const DamageList = std.ArrayListUnmanaged(Damage);

/// Everything a session needs to draw one frame. Borrowed for the duration
/// of the `render` call only.
pub const RenderContext = struct {
    /// Back buffer to draw into (owned by the video backend; honor pitch
    /// through the framebuffer.zig accessors).
    fb: *Framebuffer,
    /// Append touched rectangles here; the caller clears the list between
    /// frames (clearRetainingCapacity) and presents it to the backend.
    damage: *DamageList,
    /// Cell size in pixels.
    cell_w: u16,
    cell_h: u16,
    /// Grid size in cells.
    cols: u16,
    rows: u16,
};

/// One input event, in raw ghostty/libinput vocabulary. The input layer
/// (src/input/) translates xkb keysyms into these physical key codes before
/// handing them to the session; this contract deliberately imports no
/// keymap_table.
///
/// The whole union is at most 64 bytes so events can be queued and passed
/// by value without allocation.
pub const InputEvent = union(enum) {
    key: Key,
    pointer_motion: PointerMotion,
    pointer_button: PointerButton,
    pointer_axis: PointerAxis,
    grab: Grab,

    pub const Key = struct {
        /// Physical W3C KeyboardEvent.code value, as libghostty-vt defines
        /// it (key/event.h: GHOSTTY_KEY_A = 20 ... GHOSTTY_KEY_F24 = 144,
        /// arrows, numpad, media). Not an xkb keysym.
        ghostty_key: u32,
        /// Kitty modifier bitmask (GhosttyMods): SHIFT 1<<0, CTRL 1<<1,
        /// ALT 1<<2, SUPER 1<<3, CAPS_LOCK 1<<4, NUM_LOCK 1<<5, plus
        /// right-side bits 1<<6..1<<9 (meaningful only with the base bit).
        mods: u16,
        /// GhosttyKeyAction: 0 = release, 1 = press, 2 = repeat.
        action: u8,
        /// Layout-produced UNMODIFIED UTF-8 text (never C0 controls),
        /// borrowed; null when the key produces no text. Bytes must outlive
        /// the event's delivery.
        utf8: ?[]const u8,
        /// Unshifted codepoint for the kitty protocol's alternate reporting;
        /// null when unknown.
        unshifted_codepoint: ?u21,
    };

    pub const PointerMotion = struct {
        /// Relative deltas since the last motion event.
        dx: f64,
        dy: f64,
        /// true: (x, y) is an absolute position (e.g. QEMU USB tablet);
        /// false: relative device, (x, y) is the accumulated position.
        absolute: bool,
        x: f64,
        y: f64,
    };

    pub const PointerButton = struct {
        /// Linux input event code (BTN_LEFT = 0x110, BTN_RIGHT = 0x111,
        /// BTN_MIDDLE = 0x112, ...).
        button: u32,
        pressed: bool,
        x: f64,
        y: f64,
        /// Click count: 1 single, 2 double, 3 triple (double-click word
        /// selection, ROADMAP M2.3).
        click_count: u8,
    };

    pub const PointerAxis = struct {
        /// Scroll deltas; positive dy scrolls down (natural-scrolling is
        /// applied by the input layer, not here).
        dx: f64,
        dy: f64,
    };

    pub const Grab = struct {
        /// Configured grab id (kmscon grab-* options); the session manager
        /// resolves it, sessions receive it verbatim.
        id: u16,
    };
};

/// The session interface, as a vtable + opaque pointer. Implementations
/// (terminal now, dummy in M6) hold their own state behind `ptr`; callers
/// hold a `Session`.
///
/// All methods run on the single loop thread (D2). Errors are returned, not
/// panicked.
pub const Session = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Release all session resources. Implies stop when active.
        deinit: *const fn (ptr: *anyopaque) void,

        /// Bring the session up (terminal: open pty, spawn the child).
        /// No-op when already active.
        start: *const fn (ptr: *anyopaque) anyerror!void,

        /// Tear the session down (terminal: signal/reap the child, close
        /// the pty). No-op when already inactive.
        stop: *const fn (ptr: *anyopaque) anyerror!void,

        /// True between start and stop. This means "running", not "focused":
        /// focus is the session manager's concern.
        isActive: *const fn (ptr: *anyopaque) bool,

        /// Reconfigure the grid (terminal: TIOCSWINSZ + ghostty resize with
        /// reflow, ROADMAP M2.5).
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,

        /// Draw the current state into ctx.fb, appending touched rectangles
        /// to ctx.damage. Does not present or flip (video.Backend's job).
        render: *const fn (ptr: *anyopaque, ctx: *const RenderContext) anyerror!void,

        /// Deliver one input event. Sessions may ignore events they do not
        /// handle (the dummy session ignores everything).
        onInput: *const fn (ptr: *anyopaque, event: InputEvent) anyerror!void,

        /// Human-readable session name ("terminal", "dummy", ...). Borrowed
        /// and stable until deinit.
        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn deinit(self: Session) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn start(self: Session) anyerror!void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Session) anyerror!void {
        return self.vtable.stop(self.ptr);
    }

    pub fn isActive(self: Session) bool {
        return self.vtable.isActive(self.ptr);
    }

    pub fn resize(self: Session, cols: u16, rows: u16) anyerror!void {
        return self.vtable.resize(self.ptr, cols, rows);
    }

    pub fn render(self: Session, ctx: *const RenderContext) anyerror!void {
        return self.vtable.render(self.ptr, ctx);
    }

    pub fn onInput(self: Session, event: InputEvent) anyerror!void {
        return self.vtable.onInput(self.ptr, event);
    }

    pub fn name(self: Session) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Tests: mock lifecycle order, DamageList accumulation across frames, and
// the InputEvent size bound + round-trip through onInput.
// ---------------------------------------------------------------------------

/// In-file mock session recording every call. render paints one recognizable
/// pixel and appends one damage rect per call so accumulation is observable.
const MockSession = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    active: bool = false,
    grid: ?struct { cols: u16, rows: u16 } = null,
    geometry: ?struct { cell_w: u16, cell_h: u16, cols: u16, rows: u16 } = null,
    last_event: ?InputEvent = null,

    const Call = enum {
        deinit,
        start,
        stop,
        is_active,
        resize,
        render,
        on_input,
        name,
    };

    fn init(allocator: std.mem.Allocator) MockSession {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MockSession) void {
        self.calls.deinit(self.allocator);
    }

    fn session(self: *MockSession) Session {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *MockSession, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("mock: oom recording call");
    }

    const vtable = Session.VTable{
        .deinit = vtDeinit,
        .start = vtStart,
        .stop = vtStop,
        .isActive = vtIsActive,
        .resize = vtResize,
        .render = vtRender,
        .onInput = vtOnInput,
        .name = vtName,
    };

    fn cast(ptr: *anyopaque) *MockSession {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).record(.deinit);
    }

    fn vtStart(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.start);
        m.active = true;
    }

    fn vtStop(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.stop);
        m.active = false;
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        const m = cast(ptr);
        m.record(.is_active);
        return m.active;
    }

    fn vtResize(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const m = cast(ptr);
        m.record(.resize);
        m.grid = .{ .cols = cols, .rows = rows };
    }

    fn vtRender(ptr: *anyopaque, ctx: *const RenderContext) anyerror!void {
        const m = cast(ptr);
        m.record(.render);
        m.geometry = .{
            .cell_w = ctx.cell_w,
            .cell_h = ctx.cell_h,
            .cols = ctx.cols,
            .rows = ctx.rows,
        };
        // Paint the top-left pixel and record the first cell row as damage.
        ctx.fb.set(0, 0, 0xFF00FF);
        try ctx.damage.append(m.allocator, .{
            .x = 0,
            .y = 0,
            .w = @as(u32, ctx.cols) * @as(u32, ctx.cell_w),
            .h = ctx.cell_h,
        });
    }

    fn vtOnInput(ptr: *anyopaque, event: InputEvent) anyerror!void {
        const m = cast(ptr);
        m.record(.on_input);
        m.last_event = event;
    }

    fn vtName(ptr: *anyopaque) []const u8 {
        const m = cast(ptr);
        m.record(.name);
        return "mock";
    }
};

test "session: mock lifecycle order through the vtable" {
    const a = std.testing.allocator;
    var mock = MockSession.init(a);
    defer mock.deinit();
    const s = mock.session();

    var fb_buf = try Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb_buf.destroy(a);
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    const ctx = RenderContext{
        .fb = &fb_buf,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 8,
        .rows = 3,
    };

    try std.testing.expect(!s.isActive());
    try s.start();
    try std.testing.expect(s.isActive());
    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u16, 80), mock.grid.?.cols);
    try std.testing.expectEqual(@as(u16, 24), mock.grid.?.rows);
    try s.render(&ctx);
    try s.onInput(.{ .grab = .{ .id = 3 } });
    try s.stop();
    try std.testing.expect(!s.isActive());
    try std.testing.expectEqualStrings("mock", s.name());
    s.deinit();

    const expected = [_]MockSession.Call{
        .is_active,
        .start,
        .is_active,
        .resize,
        .render,
        .on_input,
        .stop,
        .is_active,
        .name,
        .deinit,
    };
    try std.testing.expectEqualSlices(MockSession.Call, &expected, mock.calls.items);
}

test "session: start and stop are idempotent" {
    const a = std.testing.allocator;
    var mock = MockSession.init(a);
    defer mock.deinit();
    const s = mock.session();

    try s.start();
    try s.start();
    try std.testing.expect(s.isActive());
    try s.stop();
    try s.stop();
    try std.testing.expect(!s.isActive());

    const expected = [_]MockSession.Call{
        .start,
        .start,
        .is_active,
        .stop,
        .stop,
        .is_active,
    };
    try std.testing.expectEqualSlices(MockSession.Call, &expected, mock.calls.items);
}

test "session: render accumulates damage across frames" {
    const a = std.testing.allocator;
    var mock = MockSession.init(a);
    defer mock.deinit();
    const s = mock.session();

    var fb_buf = try Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb_buf.destroy(a);
    var damage: DamageList = .empty;
    defer damage.deinit(a);
    const ctx = RenderContext{
        .fb = &fb_buf,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 8,
        .rows = 3,
    };

    try s.render(&ctx);
    try s.render(&ctx);

    // Accumulation, not replacement: one rect per frame.
    try std.testing.expectEqual(@as(usize, 2), damage.items.len);
    const expected_rect = Damage{ .x = 0, .y = 0, .w = 64, .h = 16 };
    try std.testing.expectEqual(expected_rect, damage.items[0]);
    try std.testing.expectEqual(expected_rect, damage.items[1]);

    // The geometry arrived intact and the framebuffer was drawn.
    try std.testing.expectEqual(@as(u16, 8), mock.geometry.?.cell_w);
    try std.testing.expectEqual(@as(u16, 16), mock.geometry.?.cell_h);
    try std.testing.expectEqual(@as(u16, 8), mock.geometry.?.cols);
    try std.testing.expectEqual(@as(u16, 3), mock.geometry.?.rows);
    try std.testing.expectEqual(@as(u32, 0xFF00FF), fb_buf.get(0, 0));

    // Frame boundary: the caller clears, reusing the allocation.
    const cap = damage.capacity;
    damage.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), damage.items.len);
    try std.testing.expectEqual(cap, damage.capacity);
    try s.render(&ctx);
    try std.testing.expectEqual(@as(usize, 1), damage.items.len);
}

test "session: InputEvent fits in 64 bytes and round-trips through onInput" {
    try std.testing.expect(@sizeOf(InputEvent) <= 64);

    const a = std.testing.allocator;
    var mock = MockSession.init(a);
    defer mock.deinit();
    const s = mock.session();

    const events = [_]InputEvent{
        .{ .key = .{
            .ghostty_key = 20, // GHOSTTY_KEY_A
            .mods = 0x01, // SHIFT
            .action = 1, // press
            .utf8 = "A",
            .unshifted_codepoint = 'a',
        } },
        .{ .key = .{
            .ghostty_key = 144, // GHOSTTY_KEY_F24
            .mods = 0,
            .action = 0, // release
            .utf8 = null,
            .unshifted_codepoint = null,
        } },
        .{ .pointer_motion = .{ .dx = 1.5, .dy = -2.5, .absolute = true, .x = 100.0, .y = 200.0 } },
        .{ .pointer_button = .{ .button = 0x110, .pressed = true, .x = 10.0, .y = 20.0, .click_count = 2 } },
        .{ .pointer_axis = .{ .dx = 0.0, .dy = -1.0 } },
        .{ .grab = .{ .id = 7 } },
    };
    for (events) |ev| {
        try s.onInput(ev);
        try std.testing.expectEqual(ev, mock.last_event.?);
    }
    try std.testing.expectEqual(@as(usize, events.len), mock.calls.items.len);
}
