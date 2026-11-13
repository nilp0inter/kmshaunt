//! src/session/manager.zig -- the session manager (ROADMAP M6.3):
//! `session-max`, `session-control`, `grab-terminal-new`,
//! `grab-session-next`, `grab-session-prev`, `grab-session-close`, and the
//! dummy session.
//!
//! The manager owns the ordered list of sessions (src/session.zig Session
//! handles), the focused ("active") index, and the grab actions. The input
//! layer (src/input/libinput.zig) emits `InputEvent.grab{id}` and does NO
//! session gating: "Session-control gating (`session_max`, real-VT check)
//! is the session manager's concern" (libinput.zig header). `onInput`
//! resolves the four session grab ids itself and forwards everything else
//! to the active session.
//!
//! kmscon semantics (verified against kmscon 10.1.0 src/seat.c; option
//! defaults per docs/reference/kmscon-options.md §1/§5.1)
//! ----------------------------------------------------------------------
//! * `session-max` (default 50, 0 = unlimited): the cap is checked when a
//!   session is created; when full, kmscon logs "maximum number of sessions
//!   reached (%d), dropping new session" and drops the request -- it is NOT
//!   a fatal error (seat.c:1085-1089). `newSession` does the same: warn and
//!   return, active session unchanged.
//! * `session-control` (default off) gates ALL FOUR session grabs
//!   (seat.c:537-571). With it off, `newSession`/`nextSession`/
//!   `prevSession`/`closeSession` are no-ops.
//! * next/prev/close additionally require at least 2 sessions
//!   (`seat->session_count < 2` returns early, seat.c:539-556). In
//!   particular the LAST session can never be closed through the grab:
//!   kmscon keeps it alive until the seat shuts down. The manager mirrors
//!   this: `closeSession` with fewer than 2 sessions is a no-op, and
//!   `deinit` (seat shutdown) is the only path that tears down the last
//!   session. Closing never exits the process by itself.
//! * A new session is registered NEXT TO the current one and then switched
//!   to (seat.c:1113-1117 `dlist_link`, then `seat_switch`); with an empty
//!   list it is appended. Closing the current session switches to the NEXT
//!   neighbor, wrapping to the first (kmscon_session_unregister,
//!   seat.c:1125-1146: deactivate, `seat_next`, unlink, destroy).
//! * next/prev cycle with wraparound (seat_next/seat_prev, seat.c:595-621).
//! * The initial session is created WITHOUT the session-control gate
//!   (kmscon_seat_create calls kmscon_seat_new_session directly,
//!   seat.c:1043): use `openInitial` at startup, `newSession` for the grab.
//! * On real VTs kmscon force-disables session-control with a warning
//!   (seat.c:780-784). That is seat knowledge the manager does not have:
//!   main.zig's setupSeat clears `cfg.session_control` before
//!   `Manager.init` when the seat is a real VT (not libseat).
//!
//! Focus is not running: switching sessions only moves the active index;
//! every session stays started (session.zig: `isActive` means "running",
//! focus is the manager's concern). Only close/deinit stop a session.
//!
//! Integration contract for main.zig
//! ---------------------------------
//! * `var mgr = try Manager.init(alloc, &cfg);` then inject the factory:
//!   `mgr.createSession = myFactory;` -- a plain fn pointer returning a
//!   `sess.Session`. For TerminalSession the factory heap-allocates the
//!   struct (it must not move after init, see terminal.zig header), wires
//!   renderer/hooks, and returns `ts.session()`. Until terminals are wired
//!   (or as a fallback) use `createDummySession` below.
//! * `try mgr.resize(cols, rows);` sets the grid for future sessions and
//!   resizes every live one (kmscon resizes all sessions on display
//!   changes). Defaults to 80x24 until then.
//! * `try mgr.openInitial();` creates and starts the first session.
//! * Loop: `try mgr.render(&ctx);` draws the active session (no-op when
//!   empty); `try mgr.onInput(event);` routes input, resolving session
//!   grabs. Terminal `hooks.grab` can call `mgr.handleGrab(id)` directly.
//! * Shutdown: `mgr.deinit();` stops and destroys every session.
//!
//! Tests: src/test_manager.zig (hermetic; no C dependencies). Run from the
//! repo root:
//!
//!   nix run nixpkgs#zig -- test src/test_manager.zig

const std = @import("std");
const sess = @import("../session.zig");
const config = @import("../config/config.zig");

const log = std.log.scoped(.manager);

/// Session grab ids owned by the manager, from src/input/libinput.zig
/// `GrabId` (kept as raw constants so this module imports no input code).
const grab_session_next: u16 = 7;
const grab_session_prev: u16 = 8;
const grab_session_close: u16 = 9;
const grab_terminal_new: u16 = 10;

/// Injected session factory. `cols`/`rows` are the manager's current grid
/// (see `resize`). The returned Session must stay valid until its vtable
/// `deinit` is called; the manager never copies the backing storage.
pub const CreateSessionFn = *const fn (
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    cols: u16,
    rows: u16,
) anyerror!sess.Session;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,

    /// Injected by main.zig before the first session is created (same
    /// pattern as TerminalSession.renderer). Null -> error.NoSessionFactory.
    createSession: ?CreateSessionFn = null,

    sessions: std.ArrayListUnmanaged(sess.Session) = .empty,
    /// Index into `sessions`; meaningful only when count() > 0.
    active: usize = 0,
    /// Current grid, handed to the factory and pushed by `resize`.
    cols: u16 = 80,
    rows: u16 = 24,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !Manager {
        return .{ .allocator = allocator, .cfg = cfg };
    }

    /// Seat shutdown: stop and destroy every session, then free the list.
    /// This is the only path that tears down the last session (kmscon
    /// keeps it alive until the seat exits; see the module header).
    pub fn deinit(self: *Manager) void {
        for (self.sessions.items) |s| {
            // deinit implies stop (session.zig VTable); the explicit stop
            // mirrors closeSession. A failing stop must not leak the
            // session: deinit still releases everything.
            s.stop() catch |err| log.warn("session stop failed during shutdown: {t}", .{err});
            s.deinit();
        }
        self.sessions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Manager) usize {
        return self.sessions.items.len;
    }

    /// The focused session, or null when the list is empty.
    pub fn activeSession(self: *const Manager) ?sess.Session {
        if (self.count() == 0) return null;
        return self.sessions.items[self.active];
    }

    /// The focused index, or null when the list is empty.
    pub fn activeIndex(self: *const Manager) ?usize {
        if (self.count() == 0) return null;
        return self.active;
    }

    /// Bootstrap: create, start and activate the first session regardless
    /// of session-control (kmscon_seat_create, seat.c:1043). Idempotent:
    /// a no-op once any session exists. Still honors session-max.
    pub fn openInitial(self: *Manager) !void {
        if (self.count() != 0) return;
        try self.createAndActivate();
    }

    /// grab-terminal-new. Gated by session-control (seat.c:565-571);
    /// when session-max is reached the request is dropped with a warning,
    /// not an error (seat.c:1085-1089). The new session is inserted next
    /// to the current one and becomes active.
    pub fn newSession(self: *Manager) !void {
        if (!self.cfg.session_control) return;
        try self.createAndActivate();
    }

    /// grab-session-next. Gated by session-control and >= 2 sessions
    /// (seat.c:537-543); cycles forward with wraparound.
    pub fn nextSession(self: *Manager) void {
        if (!self.cfg.session_control or self.count() < 2) return;
        self.active = (self.active + 1) % self.count();
    }

    /// grab-session-prev. Gated by session-control and >= 2 sessions
    /// (seat.c:544-549); cycles backward with wraparound.
    pub fn prevSession(self: *Manager) void {
        if (!self.cfg.session_control or self.count() < 2) return;
        self.active = (self.active + self.count() - 1) % self.count();
    }

    /// grab-session-close. Gated by session-control and >= 2 sessions
    /// (seat.c:552-561): the last session is never closed through the
    /// grab. Stops and destroys the active session, then switches to the
    /// next neighbor, wrapping to the first (kmscon_session_unregister,
    /// seat.c:1125-1146).
    pub fn closeSession(self: *Manager) void {
        if (!self.cfg.session_control or self.count() < 2) return;
        const i = self.active;
        const s = self.sessions.items[i];
        // deinit implies stop (session.zig VTable); a failing stop must
        // not keep the session alive, so teardown continues regardless.
        s.stop() catch |err| log.warn("session stop failed during close: {t}", .{err});
        s.deinit();
        _ = self.sessions.orderedRemove(i);
        // The element now at i is the old next neighbor; past the end
        // wraps to the first. count() >= 1 is guaranteed by the gate.
        self.active = i % self.count();
    }

    /// Resolve one grab id (src/input/libinput.zig GrabId). Handles the
    /// four session grabs; every other id is ignored here -- the caller
    /// forwards it to the active session / video backend / seat. Grab
    /// failures are logged: the input layer cannot propagate errors.
    pub fn handleGrab(self: *Manager, id: u16) void {
        switch (id) {
            grab_terminal_new => self.newSession() catch |err|
                log.err("cannot create session: {t}", .{err}),
            grab_session_next => self.nextSession(),
            grab_session_prev => self.prevSession(),
            grab_session_close => self.closeSession(),
            else => {},
        }
    }

    /// Set the grid for future sessions and resize every live one
    /// (kmscon resizes all sessions when the display changes).
    pub fn resize(self: *Manager, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        for (self.sessions.items) |s| try s.resize(cols, rows);
    }

    /// Draw the active session. No-op when there is none (the caller
    /// keeps or clears the back buffer itself).
    pub fn render(self: *Manager, ctx: *const sess.RenderContext) !void {
        if (self.activeSession()) |s| try s.render(ctx);
    }

    /// Route one input event. Session grabs are resolved by the manager
    /// and never reach a session; everything else goes to the active
    /// session (no-op when there is none).
    pub fn onInput(self: *Manager, event: sess.InputEvent) !void {
        if (event == .grab) {
            switch (event.grab.id) {
                grab_session_next, grab_session_prev, grab_session_close, grab_terminal_new => {
                    self.handleGrab(event.grab.id);
                    return;
                },
                else => {},
            }
        }
        if (self.activeSession()) |s| try s.onInput(event);
    }

    /// Shared creation path (kmscon_seat_new_session + seat_switch):
    /// session-max check, factory, start, insert next to the current
    /// session, activate. On any failure the half-built session is
    /// destroyed and the list is left untouched.
    fn createAndActivate(self: *Manager) !void {
        if (self.cfg.session_max != 0 and self.count() >= self.cfg.session_max) {
            log.warn("maximum number of sessions reached ({d}), dropping new session", .{self.cfg.session_max});
            return;
        }
        const factory = self.createSession orelse return error.NoSessionFactory;
        const s = try factory(self.allocator, self.cfg, self.cols, self.rows);
        errdefer s.deinit();
        try s.start();
        const idx = if (self.count() == 0) 0 else self.active + 1;
        try self.sessions.insert(self.allocator, idx, s);
        self.active = idx;
    }
};

// ---------------------------------------------------------------------------
// DummySession (ROADMAP M6.3)
// ---------------------------------------------------------------------------

/// A placeholder session that renders a static blank screen in the
/// configured background color and ignores every input event
/// (session.zig: "the dummy session ignores everything"). Use it when no
/// real session is available -- before the first terminal is opened, or
/// as a fallback when terminal creation fails -- so the console always
/// has something to present.
///
/// kmscon 10.1.0 itself ships no dummy session (its src/ has only terminals;
/// verified against the v10.1.0 source); this is kmshaunt's ROADMAP M6.3
/// placeholder, in the spirit of older kmscon's dummy session that kept a
/// seat displayable without a terminal.
///
/// Allocation-free rendering: `render` fills the caller's back buffer and
/// appends one full-surface damage rect. The struct itself is heap-owned
/// (`init`/vtable deinit) so its address stays stable behind the Session
/// pointer.
pub const DummySession = struct {
    allocator: std.mem.Allocator,
    /// xrgb8888 background pixel, from the effective palette's slot 17.
    background: u32,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !*DummySession {
        const self = try allocator.create(DummySession);
        self.* = .{
            .allocator = allocator,
            .background = cfg.effectivePalette()[17].xrgb(),
        };
        return self;
    }

    pub fn session(self: *DummySession) sess.Session {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = sess.Session.VTable{
        .deinit = vtDeinit,
        .start = vtStart,
        .stop = vtStop,
        .isActive = vtIsActive,
        .resize = vtResize,
        .render = vtRender,
        .onInput = vtOnInput,
        .name = vtName,
    };

    fn cast(ptr: *anyopaque) *DummySession {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn vtStart(ptr: *anyopaque) anyerror!void {
        cast(ptr).active = true;
    }

    fn vtStop(ptr: *anyopaque) anyerror!void {
        cast(ptr).active = false;
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).active;
    }

    fn vtResize(_: *anyopaque, _: u16, _: u16) anyerror!void {
        // No grid state: the blank screen covers any geometry.
    }

    fn vtRender(ptr: *anyopaque, ctx: *const sess.RenderContext) anyerror!void {
        const self = cast(ptr);
        ctx.fb.fill(self.background);
        try ctx.damage.append(self.allocator, .{
            .x = 0,
            .y = 0,
            .w = ctx.fb.width,
            .h = ctx.fb.height,
        });
    }

    fn vtOnInput(_: *anyopaque, _: sess.InputEvent) anyerror!void {
        // The dummy ignores everything (session.zig contract).
    }

    fn vtName(_: *anyopaque) []const u8 {
        return "dummy";
    }
};

/// Ready-made `Manager.createSession` factory producing dummy sessions.
pub fn createDummySession(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    _: u16,
    _: u16,
) anyerror!sess.Session {
    const d = try DummySession.init(alloc, cfg);
    return d.session();
}

// ---------------------------------------------------------------------------
// Tests (pulled in by src/test_manager.zig). Mock sessions record every
// vtable call; the harness owns their memory so closed sessions stay
// inspectable after deinit.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Grid = struct { cols: u16, rows: u16 };

const Mock = struct {
    id: u32,
    created: Grid,
    fail_start: bool = false,
    active: bool = false,
    start_calls: u32 = 0,
    stop_calls: u32 = 0,
    deinit_calls: u32 = 0,
    resize_calls: u32 = 0,
    render_calls: u32 = 0,
    input_calls: u32 = 0,
    grid: ?Grid = null,
    last_event: ?sess.InputEvent = null,

    fn session(self: *Mock) sess.Session {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = sess.Session.VTable{
        .deinit = vtDeinit,
        .start = vtStart,
        .stop = vtStop,
        .isActive = vtIsActive,
        .resize = vtResize,
        .render = vtRender,
        .onInput = vtOnInput,
        .name = vtName,
    };

    fn cast(ptr: *anyopaque) *Mock {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        const m = cast(ptr);
        m.deinit_calls += 1;
        m.active = false;
        // Memory is owned by the test harness (mockFree), not freed here,
        // so assertions can inspect closed sessions.
    }

    fn vtStart(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.start_calls += 1;
        if (m.fail_start) return error.MockStartFailure;
        m.active = true;
    }

    fn vtStop(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.stop_calls += 1;
        m.active = false;
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).active;
    }

    fn vtResize(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const m = cast(ptr);
        m.resize_calls += 1;
        m.grid = .{ .cols = cols, .rows = rows };
    }

    fn vtRender(ptr: *anyopaque, ctx: *const sess.RenderContext) anyerror!void {
        const m = cast(ptr);
        m.render_calls += 1;
        // Recognizable pixel + one damage rect, like session.zig's mock.
        ctx.fb.set(0, 0, 0xFF00FF);
        try ctx.damage.append(testing.allocator, .{
            .x = 0,
            .y = 0,
            .w = @as(u32, ctx.cols) * @as(u32, ctx.cell_w),
            .h = ctx.cell_h,
        });
    }

    fn vtOnInput(ptr: *anyopaque, event: sess.InputEvent) anyerror!void {
        const m = cast(ptr);
        m.input_calls += 1;
        m.last_event = event;
    }

    fn vtName(_: *anyopaque) []const u8 {
        return "mock";
    }
};

/// Test-global factory state (the factory is a plain fn pointer, so it
/// cannot capture). Reset before and freed after every test.
var mock_list: std.ArrayListUnmanaged(*Mock) = .empty;
var mock_next_id: u32 = 0;
var mock_fail_start: bool = false;

fn mockFactory(
    alloc: std.mem.Allocator,
    _: *const config.Config,
    cols: u16,
    rows: u16,
) anyerror!sess.Session {
    const m = try alloc.create(Mock);
    m.* = .{
        .id = mock_next_id,
        .created = .{ .cols = cols, .rows = rows },
        .fail_start = mock_fail_start,
    };
    mock_next_id += 1;
    try mock_list.append(alloc, m);
    return m.session();
}

fn failFactory(
    _: std.mem.Allocator,
    _: *const config.Config,
    _: u16,
    _: u16,
) anyerror!sess.Session {
    return error.MockFactoryFailure;
}

fn mockReset() void {
    mock_list = .empty;
    mock_next_id = 0;
    mock_fail_start = false;
}

fn mockFree() void {
    for (mock_list.items) |m| testing.allocator.destroy(m);
    mock_list.deinit(testing.allocator);
    mock_list = .empty;
}

fn mockById(id: u32) *Mock {
    for (mock_list.items) |m| {
        if (m.id == id) return m;
    }
    @panic("mock id not found");
}

/// Manager wired to the mock factory; caller sets cfg fields first.
fn mockManager(cfg: *const config.Config) !Manager {
    var m = try Manager.init(testing.allocator, cfg);
    m.createSession = mockFactory;
    return m;
}

fn testCtx(fb: *sess.Framebuffer, damage: *sess.DamageList) sess.RenderContext {
    return .{
        .fb = fb,
        .damage = damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 8,
        .rows = 3,
    };
}

test "manager: newSession creates, starts and activates" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.newSession();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    const s = m.activeSession().?;
    try testing.expectEqualStrings("mock", s.name());
    try testing.expect(s.isActive());
    const m0 = mockById(0);
    try testing.expectEqual(@as(u32, 1), m0.start_calls);
    try testing.expectEqual(@as(*Mock, m0), @as(*Mock, @ptrCast(@alignCast(s.ptr))));

    // Second session: created, started, active; the first keeps running.
    try m.newSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqual(@as(?usize, 1), m.activeIndex());
    try testing.expect(mockById(0).active);
    try testing.expect(mockById(1).active);
    try testing.expectEqual(@as(u32, 1), mockById(1).start_calls);
}

test "manager: new sessions are inserted next to the current one" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.openInitial(); // A (id 0)
    try m.newSession(); // B (id 1), active
    m.prevSession(); // back to A
    try m.newSession(); // C (id 2) next to A -> [A, C, B]

    try testing.expectEqual(@as(usize, 3), m.count());
    try testing.expectEqual(@as(?usize, 1), m.activeIndex());
    const ids = [_]u32{ 0, 2, 1 };
    for (m.sessions.items, ids) |s, id| {
        try testing.expectEqual(@as(*Mock, mockById(id)), @as(*Mock, @ptrCast(@alignCast(s.ptr))));
    }
}

test "manager: session-max drops new sessions when full (0 = unlimited)" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    cfg.session_max = 2;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.newSession();
    try m.newSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    const active_before = m.activeIndex();

    // Full: dropped without error, no factory call, active unchanged.
    try m.newSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqual(active_before, m.activeIndex());
    try testing.expectEqual(@as(u32, 2), mock_next_id);

    // 0 means unlimited (kmscon seat.c:1085).
    cfg.session_max = 0;
    try m.newSession();
    try m.newSession();
    try m.newSession();
    try testing.expectEqual(@as(usize, 5), m.count());
}

test "manager: next/prev cycle with wraparound" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.openInitial();
    try m.newSession();
    try m.newSession(); // [0, 1, 2], active 2

    m.nextSession(); // wrap -> 0
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    m.nextSession();
    try testing.expectEqual(@as(?usize, 1), m.activeIndex());
    m.prevSession();
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    m.prevSession(); // wrap -> 2
    try testing.expectEqual(@as(?usize, 2), m.activeIndex());

    // Cycling never stops or starts anything.
    for (mock_list.items) |mock| {
        try testing.expectEqual(@as(u32, 1), mock.start_calls);
        try testing.expectEqual(@as(u32, 0), mock.stop_calls);
        try testing.expect(mock.active);
    }
}

test "manager: close removes the active session and switches to the next neighbor" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.openInitial(); // A
    try m.newSession(); // B
    try m.newSession(); // C, active index 2
    m.prevSession(); // active B (index 1)

    m.closeSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    // B stopped and destroyed exactly once; A and C untouched.
    const b = mockById(1);
    try testing.expectEqual(@as(u32, 1), b.stop_calls);
    try testing.expectEqual(@as(u32, 1), b.deinit_calls);
    try testing.expect(!b.active);
    try testing.expectEqual(@as(u32, 0), mockById(0).deinit_calls);
    try testing.expectEqual(@as(u32, 0), mockById(2).deinit_calls);
    // Order [A, C]; the next neighbor C is now active at index 1.
    try testing.expectEqual(@as(?usize, 1), m.activeIndex());
    try testing.expectEqual(@as(*Mock, mockById(2)), @as(*Mock, @ptrCast(@alignCast(m.activeSession().?.ptr))));

    // Closing the tail wraps to the first.
    m.closeSession();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    try testing.expectEqual(@as(*Mock, mockById(0)), @as(*Mock, @ptrCast(@alignCast(m.activeSession().?.ptr))));
    try testing.expectEqual(@as(u32, 1), mockById(2).stop_calls);
    try testing.expectEqual(@as(u32, 1), mockById(2).deinit_calls);
}

test "manager: close-last is a no-op (session-control keeps the last session)" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.openInitial();
    // kmscon seat.c:552-556: the close grab requires session_count >= 2.
    // The last session lives until seat shutdown (Manager.deinit).
    m.closeSession();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(@as(u32, 0), mockById(0).stop_calls);
    try testing.expectEqual(@as(u32, 0), mockById(0).deinit_calls);
    try testing.expect(mockById(0).active);

    // Same with zero sessions.
    var empty = try Manager.init(a, &cfg);
    defer empty.deinit();
    empty.closeSession();
    try testing.expectEqual(@as(usize, 0), empty.count());
}

test "manager: session-control off gates all four grabs; openInitial still works" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = false;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    // Bootstrap is not gated (kmscon_seat_create, seat.c:1043).
    try m.openInitial();
    try testing.expectEqual(@as(usize, 1), m.count());
    // openInitial is idempotent.
    try m.openInitial();
    try testing.expectEqual(@as(usize, 1), m.count());

    try m.newSession();
    m.nextSession();
    m.prevSession();
    m.closeSession();
    m.handleGrab(grab_terminal_new);
    m.handleGrab(grab_session_next);
    m.handleGrab(grab_session_prev);
    m.handleGrab(grab_session_close);
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    try testing.expectEqual(@as(u32, 0), mockById(0).stop_calls);

    // Enabling session-control un-gates the grabs live.
    cfg.session_control = true;
    try m.newSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    m.closeSession();
    try testing.expectEqual(@as(usize, 1), m.count());
}

test "manager: next/prev with a single session are no-ops" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try m.openInitial();
    m.nextSession();
    m.prevSession();
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    try testing.expectEqual(@as(usize, 1), m.count());
}

test "manager: render and onInput delegate to the active session only" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();
    try m.openInitial(); // A
    try m.newSession(); // B active

    var fb = try sess.Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb.destroy(a);
    var damage: sess.DamageList = .empty;
    defer damage.deinit(a);
    const ctx = testCtx(&fb, &damage);

    try m.render(&ctx);
    try testing.expectEqual(@as(u32, 0), mockById(0).render_calls);
    try testing.expectEqual(@as(u32, 1), mockById(1).render_calls);
    try testing.expectEqual(@as(u32, 0xFF00FF), fb.get(0, 0));
    try testing.expectEqual(@as(usize, 1), damage.items.len);

    const key = sess.InputEvent{ .key = .{
        .ghostty_key = 20,
        .mods = 0,
        .action = 1,
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    } };
    try m.onInput(key);
    try testing.expectEqual(@as(u32, 0), mockById(0).input_calls);
    try testing.expectEqual(@as(u32, 1), mockById(1).input_calls);
    try testing.expectEqual(key, mockById(1).last_event.?);

    // After a switch the other session receives everything.
    m.prevSession();
    damage.clearRetainingCapacity();
    try m.render(&ctx);
    try m.onInput(key);
    try testing.expectEqual(@as(u32, 1), mockById(0).render_calls);
    try testing.expectEqual(@as(u32, 1), mockById(0).input_calls);
    try testing.expectEqual(@as(u32, 1), mockById(1).render_calls);
    try testing.expectEqual(@as(u32, 1), mockById(1).input_calls);
}

test "manager: empty manager render/onInput are no-ops" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    mockReset();
    defer mockFree();

    var m = try Manager.init(a, &cfg);
    defer m.deinit();

    var fb = try sess.Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb.destroy(a);
    var damage: sess.DamageList = .empty;
    defer damage.deinit(a);
    const ctx = testCtx(&fb, &damage);

    try testing.expectEqual(@as(?sess.Session, null), m.activeSession());
    try testing.expectEqual(@as(?usize, null), m.activeIndex());
    try m.render(&ctx);
    try m.onInput(.{ .key = .{
        .ghostty_key = 20,
        .mods = 0,
        .action = 1,
        .utf8 = null,
        .unshifted_codepoint = null,
    } });
    try testing.expectEqual(@as(usize, 0), damage.items.len);
    try testing.expectEqual(@as(u32, 0), fb.get(0, 0));
}

test "manager: session grabs are resolved by the manager, other grabs forwarded" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();
    try m.openInitial();

    // terminal_new through onInput creates a session, never reaches one.
    try m.onInput(.{ .grab = .{ .id = grab_terminal_new } });
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqual(@as(u32, 0), mockById(0).input_calls);
    try testing.expectEqual(@as(u32, 0), mockById(1).input_calls);

    // next/prev/close through onInput.
    try m.onInput(.{ .grab = .{ .id = grab_session_prev } });
    try testing.expectEqual(@as(?usize, 0), m.activeIndex());
    try m.onInput(.{ .grab = .{ .id = grab_session_next } });
    try testing.expectEqual(@as(?usize, 1), m.activeIndex());
    try m.onInput(.{ .grab = .{ .id = grab_session_close } });
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqual(@as(u32, 0), mockById(0).input_calls);

    // Non-session grabs (scroll_up = 1) and unknown ids reach the session
    // verbatim; handleGrab ignores them.
    try m.onInput(.{ .grab = .{ .id = 1 } });
    try testing.expectEqual(@as(u32, 1), mockById(0).input_calls);
    try testing.expectEqual(sess.InputEvent{ .grab = .{ .id = 1 } }, mockById(0).last_event.?);
    m.handleGrab(99);
    try testing.expectEqual(@as(u32, 1), mockById(0).input_calls);
    try testing.expectEqual(@as(usize, 1), m.count());
}

test "manager: resize pushes the grid to every session and to new ones" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();
    try m.openInitial();
    try m.newSession();
    try testing.expectEqual(Grid{ .cols = 80, .rows = 24 }, mockById(0).created);

    try m.resize(100, 40);
    for (mock_list.items) |mock| {
        try testing.expectEqual(@as(u32, 1), mock.resize_calls);
        try testing.expectEqual(Grid{ .cols = 100, .rows = 40 }, mock.grid.?);
    }
    try m.newSession();
    try testing.expectEqual(Grid{ .cols = 100, .rows = 40 }, mockById(2).created);
}

test "manager: repeated geometry changes resize every live session (mode change)" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();
    try m.openInitial();
    try m.newSession();

    // Two mode changes: every live session follows each new grid, and the
    // manager grid tracks the last one for future sessions.
    try m.resize(100, 40);
    try m.resize(64, 20);
    for (mock_list.items) |mock| {
        try testing.expectEqual(@as(u32, 2), mock.resize_calls);
        try testing.expectEqual(Grid{ .cols = 64, .rows = 20 }, mock.grid.?);
    }
    try testing.expectEqual(@as(u16, 64), m.cols);
    try testing.expectEqual(@as(u16, 20), m.rows);
    try m.newSession();
    try testing.expectEqual(Grid{ .cols = 64, .rows = 20 }, mockById(2).created);
}

test "manager: deinit stops and destroys every session" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    try m.openInitial();
    try m.newSession();
    try m.newSession();

    m.deinit();
    for (mock_list.items) |mock| {
        try testing.expectEqual(@as(u32, 1), mock.stop_calls);
        try testing.expectEqual(@as(u32, 1), mock.deinit_calls);
        try testing.expect(!mock.active);
    }
}

test "manager: creation failures leave the list untouched" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try Manager.init(a, &cfg);
    defer m.deinit();

    // No factory injected.
    try testing.expectError(error.NoSessionFactory, m.newSession());
    try testing.expectEqual(@as(usize, 0), m.count());

    // Factory failure.
    m.createSession = failFactory;
    try testing.expectError(error.MockFactoryFailure, m.newSession());
    try testing.expectEqual(@as(usize, 0), m.count());

    // Start failure: the half-built session is destroyed.
    m.createSession = mockFactory;
    mock_fail_start = true;
    try testing.expectError(error.MockStartFailure, m.newSession());
    try testing.expectEqual(@as(usize, 0), m.count());
    try testing.expectEqual(@as(u32, 1), mockById(0).start_calls);
    try testing.expectEqual(@as(u32, 1), mockById(0).deinit_calls);

    // Recovery: the next attempt succeeds.
    mock_fail_start = false;
    try m.newSession();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expect(mockById(1).active);
}

test "manager: count tracks the full lifecycle" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.session_control = true;
    mockReset();
    defer mockFree();

    var m = try mockManager(&cfg);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 0), m.count());
    try m.openInitial();
    try testing.expectEqual(@as(usize, 1), m.count());
    try m.newSession();
    try m.newSession();
    try testing.expectEqual(@as(usize, 3), m.count());
    m.closeSession();
    try testing.expectEqual(@as(usize, 2), m.count());
    m.closeSession();
    try testing.expectEqual(@as(usize, 1), m.count());
    m.closeSession(); // last one: gated, stays
    try testing.expectEqual(@as(usize, 1), m.count());
}

test "dummy: renders a static blank screen in the configured background" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.palette = .custom;
    cfg.custom_palette[17] = .{ .r = 1, .g = 2, .b = 3 };

    var m = try Manager.init(a, &cfg);
    defer m.deinit();
    m.createSession = createDummySession;

    // Placeholder before any real session: nothing to draw, no error.
    var fb = try sess.Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb.destroy(a);
    var damage: sess.DamageList = .empty;
    defer damage.deinit(a);
    const ctx = testCtx(&fb, &damage);
    try m.render(&ctx);
    try testing.expectEqual(@as(usize, 0), damage.items.len);

    try m.openInitial();
    try testing.expectEqual(@as(usize, 1), m.count());
    const s = m.activeSession().?;
    try testing.expectEqualStrings("dummy", s.name());
    try testing.expect(s.isActive());

    try m.render(&ctx);
    // Every pixel is the background color 0x010203 (xrgb8888).
    for ([_]u32{ 0, 31, 63 }) |x| {
        for ([_]u32{ 0, 23, 47 }) |y| {
            try testing.expectEqual(@as(u32, 0x010203), fb.get(x, y));
        }
    }
    // One full-surface damage rect per frame; static across frames.
    try testing.expectEqual(@as(usize, 1), damage.items.len);
    try testing.expectEqual(sess.Damage{ .x = 0, .y = 0, .w = 64, .h = 48 }, damage.items[0]);
    damage.clearRetainingCapacity();
    try m.render(&ctx);
    try testing.expectEqual(@as(usize, 1), damage.items.len);
    try testing.expectEqual(@as(u32, 0x010203), fb.get(10, 10));

    // Input is ignored without error; resize is a no-op.
    try m.onInput(.{ .key = .{
        .ghostty_key = 20,
        .mods = 0,
        .action = 1,
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    } });
    try m.onInput(.{ .grab = .{ .id = 1 } });
    try m.resize(100, 40);
    try testing.expect(s.isActive());
}

test "dummy: lifecycle through the vtable is idempotent" {
    const a = testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();

    const d = try DummySession.init(a, &cfg);
    const s = d.session();
    try testing.expect(!s.isActive());
    try s.start();
    try s.start();
    try testing.expect(s.isActive());
    try s.stop();
    try s.stop();
    try testing.expect(!s.isActive());
    // Default background: legacy palette slot 17 is black.
    try testing.expectEqual(cfg.effectivePalette()[17].xrgb(), d.background);
    s.deinit();
}