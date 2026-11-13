//! src/seat.zig -- seat contract (ROADMAP §3, M1.2 real VT, M6 libseat /
//! multi-seat).
//!
//! A seat owns the right to drive one console: the VT mode (KD_TEXT vs
//! KD_GRAPHICS), DRM master and the input devices attached to it. The real
//! VT backend (src/seat/vt_real.zig), the libseat backend and the fake VT
//! backend all implement the `Seat` vtable so the session manager and the
//! video backends can be written against one interface.
//!
//! Activation model (M1.2): `activate` switches the VT to KD_GRAPHICS and
//! takes DRM master; `deactivate` drops DRM master and returns the VT to
//! KD_TEXT so the next owner (getty, another console) can use it. The video
//! backend performs the actual master take/drop; the seat coordinates the
//! ordering and notifies its owner through `Callbacks`.
//!
//! `pause`/`resume_` model the libseat device handoff: when a device is
//! revoked (another process takes over, e.g. a GUI launch through kmscon's
//! private OSC) the owner must close its fd (`pause`); when the device comes
//! back, a fresh fd is handed over (`resume_`). `resume` is a Zig keyword,
//! so the operation is spelled `resume_` (repo convention: video.suspend_,
//! loop.ev.in_).
//!
//! Re-entrancy: seat events can be delivered synchronously from inside
//! activate/deactivate/pause/resume (VT switch dispatch, libseat's event
//! queue). Implementations MUST deliver callbacks through `CallbackGuard`
//! (or an equivalent guard) so a callback that re-enters the seat cannot
//! trigger unbounded recursion.
//!
//! This file imports only std: it is a contract; the backends land later.

const std = @import("std");

/// KD modes from <linux/kd.h>, the argument values of KDSETMODE.
pub const kd_mode = struct {
    /// Text mode: the kernel console owns the screen.
    pub const text: u8 = 0x00;
    /// Graphics mode: userspace owns the screen (DRM master required).
    pub const graphics: u8 = 0x01;
};

/// Re-entrancy guard for seat callback delivery. Embed one in every seat
/// implementation and deliver every callback through `dispatch`: while a
/// callback is running, further callback deliveries are dropped (the seat
/// operations themselves still execute). This breaks cycles such as
/// activated -> activate -> activated without losing later events.
pub const CallbackGuard = struct {
    depth: usize = 0,

    /// Try to enter a callback. Returns false when one is already running.
    pub fn enter(self: *CallbackGuard) bool {
        if (self.depth != 0) return false;
        self.depth += 1;
        return true;
    }

    /// Leave the running callback. Must pair a successful `enter`.
    pub fn leave(self: *CallbackGuard) void {
        std.debug.assert(self.depth != 0);
        self.depth -= 1;
    }

    /// Deliver `callback(userdata)` unless a callback is already running or
    /// the callback is null. Null callbacks are a no-op.
    pub fn dispatch(self: *CallbackGuard, callback: ?*const fn (userdata: usize) void, userdata: usize) void {
        const cb = callback orelse return;
        if (!self.enter()) return;
        defer self.leave();
        cb(userdata);
    }
};

/// The seat interface, as a vtable + opaque pointer. Implementations
/// (vt_real now, libseat and vt_fake in M6) hold their own state behind
/// `ptr`; callers hold a `Seat`.
///
/// All methods run on the single loop thread (D2). Errors are returned, not
/// panicked, so the caller can degrade (e.g. keep running on a fake VT when
/// the real one cannot be opened).
pub const Seat = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Seat event callbacks. Every field is optional; null fields are never
    /// invoked. Fields are function pointers (`?*const fn`): bare `fn`
    /// types are comptime-only in Zig and cannot be dispatched at runtime
    /// (same convention as loop.Handler / loop.Timer.Callback).
    /// All callbacks run on the loop thread, synchronously from the seat
    /// operation or event dispatch that caused them, and MUST be delivered
    /// through a `CallbackGuard`.
    pub const Callbacks = struct {
        /// The seat became active (VT switched to us / libseat enable_seat).
        activated: ?*const fn (userdata: usize) void = null,
        /// The seat lost activation (VT switch away / libseat disable_seat).
        deactivated: ?*const fn (userdata: usize) void = null,
        /// A device fd was revoked: close it (libseat pause_device).
        pause: ?*const fn (userdata: usize) void = null,
        /// A device fd is available again (libseat resume_device).
        /// Trailing underscore: `resume` is a Zig keyword (see file header).
        resume_: ?*const fn (userdata: usize) void = null,
    };

    pub const VTable = struct {
        /// Release all seat resources (fds, VT mode restored to KD_TEXT).
        deinit: *const fn (ptr: *anyopaque) void,

        /// Take the console: KDSETMODE(KD_GRAPHICS) and take DRM master.
        /// No-op when already active. Fires `activated` on the transition.
        activate: *const fn (ptr: *anyopaque) anyerror!void,

        /// Give the console back: drop DRM master and KDSETMODE(KD_TEXT).
        /// No-op when already inactive. Fires `deactivated` on the
        /// transition.
        deactivate: *const fn (ptr: *anyopaque) anyerror!void,

        /// Whether the seat currently owns the console.
        isActive: *const fn (ptr: *anyopaque) bool,

        /// Hand a device fd back to the seat (libseat pause_device): the
        /// owner must stop using and close it. Fires `pause`.
        pause: *const fn (ptr: *anyopaque) anyerror!void,

        /// Re-take a device after a pause (libseat resume_device): a fresh
        /// fd is available. Fires `resume_`.
        resume_: *const fn (ptr: *anyopaque) anyerror!void,

        /// Install the event callbacks. `callbacks` is borrowed and must
        /// stay valid until the next setCallbacks call or deinit;
        /// `userdata` is passed back to every callback unchanged.
        setCallbacks: *const fn (ptr: *anyopaque, callbacks: *const Callbacks, userdata: usize) void,
    };

    pub fn deinit(self: Seat) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn activate(self: Seat) anyerror!void {
        return self.vtable.activate(self.ptr);
    }

    pub fn deactivate(self: Seat) anyerror!void {
        return self.vtable.deactivate(self.ptr);
    }

    pub fn isActive(self: Seat) bool {
        return self.vtable.isActive(self.ptr);
    }

    pub fn pause(self: Seat) anyerror!void {
        return self.vtable.pause(self.ptr);
    }

    pub fn resume_(self: Seat) anyerror!void {
        return self.vtable.resume_(self.ptr);
    }

    pub fn setCallbacks(self: Seat, callbacks: *const Callbacks, userdata: usize) void {
        self.vtable.setCallbacks(self.ptr, callbacks, userdata);
    }
};

/// One virtual terminal. `path` (e.g. "/dev/tty2") is borrowed from the
/// backend and stays valid until the next `openVt` call, matching the
/// borrowed-string convention of video.ConnectorInfo.
pub const VtInfo = struct {
    /// VT number, 1..63 (kernel MAX_NR_CONSOLES - 1).
    vt_num: u8,
    /// Device path of the VT, borrowed (see above).
    path: []const u8,
};

pub const OpenVtError = error{
    /// Requested VT number is 0 or greater than 63.
    InvalidVt,
    /// The VT device could not be opened.
    OpenFailed,
    /// A VT ioctl (VT_GETSTATE / VT_ACTIVATE / VT_SETMODE) failed.
    IoctlFailed,
    /// VT_WAITACED did not complete the switch.
    WaitFailed,
};

/// DECLARATION ONLY: the implementation lands in src/seat/vt_real.zig
/// (ROADMAP M1.2) and replaces this body at integration. Contract:
///
/// - `requested == null`: use the current VT, read with VT_GETSTATE on
///   /dev/tty0 (`vt_stat.v_active`).
/// - `requested == N`: open /dev/ttyN; when it is not the active VT, switch
///   to it with VT_ACTIVATE and block in VT_WAITACED until the switch
///   completes (the `switchvt` behavior).
/// - The opened VT is put into VT_PROCESS mode (VT_SETMODE) so switch
///   away/back is negotiated through release/acquire signals instead of
///   happening behind our back.
/// - Returns the VT number and its borrowed device path; the fd itself is
///   owned by the seat implementation.
pub fn openVt(requested: ?u8) OpenVtError!VtInfo {
    _ = requested;
    @compileError("openVt: implementation lands in src/seat/vt_real.zig (M1.2)");
}

// ---------------------------------------------------------------------------
// Tests: a mock seat exercising activate/deactivate/pause/resume ordering,
// callback delivery and the re-entrancy guard.
// ---------------------------------------------------------------------------

/// In-file mock seat recording every call. State transitions fire the
/// matching callback through a CallbackGuard; repeated operations that do
/// not change state fire nothing.
const MockSeat = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    active: bool = false,
    paused: bool = false,
    callbacks: ?*const Seat.Callbacks = null,
    userdata: usize = 0,
    guard: CallbackGuard = .{},
    activated_count: usize = 0,
    deactivated_count: usize = 0,

    const Call = enum {
        deinit,
        activate,
        deactivate,
        is_active,
        pause,
        resume_,
        set_callbacks,
    };

    fn init(allocator: std.mem.Allocator) MockSeat {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MockSeat) void {
        self.calls.deinit(self.allocator);
    }

    fn seat(self: *MockSeat) Seat {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *MockSeat, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("mock: oom recording call");
    }

    fn fire(self: *MockSeat, comptime field: []const u8) void {
        const cbs = self.callbacks orelse return;
        self.guard.dispatch(@field(cbs, field), self.userdata);
    }

    const vtable = Seat.VTable{
        .deinit = vtDeinit,
        .activate = vtActivate,
        .deactivate = vtDeactivate,
        .isActive = vtIsActive,
        .pause = vtPause,
        .resume_ = vtResume,
        .setCallbacks = vtSetCallbacks,
    };

    fn cast(ptr: *anyopaque) *MockSeat {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).record(.deinit);
    }

    fn vtActivate(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.activate);
        if (!m.active) {
            m.active = true;
            m.fire("activated");
        }
    }

    fn vtDeactivate(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.deactivate);
        if (m.active) {
            m.active = false;
            m.fire("deactivated");
        }
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        const m = cast(ptr);
        m.record(.is_active);
        return m.active;
    }

    fn vtPause(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.pause);
        if (!m.paused) {
            m.paused = true;
            m.fire("pause");
        }
    }

    fn vtResume(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.resume_);
        if (m.paused) {
            m.paused = false;
            m.fire("resume_");
        }
    }

    fn vtSetCallbacks(ptr: *anyopaque, callbacks: *const Seat.Callbacks, userdata: usize) void {
        const m = cast(ptr);
        m.record(.set_callbacks);
        m.callbacks = callbacks;
        m.userdata = userdata;
    }
};

test "seat: mock activate/deactivate/pause/resume ordering" {
    const a = std.testing.allocator;
    var mock = MockSeat.init(a);
    defer mock.deinit();
    const s = mock.seat();

    try std.testing.expect(!s.isActive());
    try s.activate();
    try std.testing.expect(s.isActive());
    try s.pause();
    try std.testing.expect(mock.paused);
    try s.resume_();
    try std.testing.expect(!mock.paused);
    try s.deactivate();
    try std.testing.expect(!s.isActive());
    s.deinit();

    const expected = [_]MockSeat.Call{
        .is_active,
        .activate,
        .is_active,
        .pause,
        .resume_,
        .deactivate,
        .is_active,
        .deinit,
    };
    try std.testing.expectEqualSlices(MockSeat.Call, &expected, mock.calls.items);
}

test "seat: repeated operations are idempotent" {
    const a = std.testing.allocator;
    var mock = MockSeat.init(a);
    defer mock.deinit();
    const s = mock.seat();

    try s.activate();
    try s.activate();
    try std.testing.expect(s.isActive());
    try s.deactivate();
    try s.deactivate();
    try std.testing.expect(!s.isActive());
    try s.resume_(); // resume without a prior pause: no transition
    try std.testing.expect(!mock.paused);

    const expected = [_]MockSeat.Call{
        .activate,
        .activate,
        .is_active,
        .deactivate,
        .deactivate,
        .is_active,
        .resume_,
    };
    try std.testing.expectEqualSlices(MockSeat.Call, &expected, mock.calls.items);
}

/// Callback counters for the delivery test; userdata points at this struct.
const Counters = struct {
    activated: usize = 0,
    deactivated: usize = 0,
    paused: usize = 0,
    resumed: usize = 0,
    last_userdata: usize = 0,

    fn onActivated(userdata: usize) void {
        const c: *Counters = @ptrFromInt(userdata);
        c.activated += 1;
        c.last_userdata = userdata;
    }
    fn onDeactivated(userdata: usize) void {
        const c: *Counters = @ptrFromInt(userdata);
        c.deactivated += 1;
    }
    fn onPause(userdata: usize) void {
        const c: *Counters = @ptrFromInt(userdata);
        c.paused += 1;
    }
    fn onResume(userdata: usize) void {
        const c: *Counters = @ptrFromInt(userdata);
        c.resumed += 1;
    }
};

test "seat: callbacks fire on transitions with userdata intact" {
    const a = std.testing.allocator;
    var mock = MockSeat.init(a);
    defer mock.deinit();
    const s = mock.seat();

    var counters = Counters{};
    const cbs = Seat.Callbacks{
        .activated = Counters.onActivated,
        .deactivated = Counters.onDeactivated,
        .pause = Counters.onPause,
        .resume_ = Counters.onResume,
    };
    s.setCallbacks(&cbs, @intFromPtr(&counters));

    try s.activate();
    try s.activate(); // no transition, no second callback
    try s.pause();
    try s.resume_();
    try s.deactivate();

    try std.testing.expectEqual(@as(usize, 1), counters.activated);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 1), counters.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);
    try std.testing.expectEqual(@intFromPtr(&counters), counters.last_userdata);
}

/// Re-entrant activated callback: deactivates the seat from inside the
/// activated delivery. The nested deactivated delivery must be dropped by
/// the guard, while the state change itself still happens.
fn activatedReenter(userdata: usize) void {
    const m: *MockSeat = @ptrFromInt(userdata);
    m.activated_count += 1;
    m.seat().deactivate() catch @panic("mock: reentrant deactivate failed");
}

fn deactivatedCount(userdata: usize) void {
    const m: *MockSeat = @ptrFromInt(userdata);
    m.deactivated_count += 1;
}

test "seat: re-entrant callback delivery is guarded" {
    const a = std.testing.allocator;
    var mock = MockSeat.init(a);
    defer mock.deinit();
    const s = mock.seat();

    const cbs = Seat.Callbacks{
        .activated = activatedReenter,
        .deactivated = deactivatedCount,
    };
    s.setCallbacks(&cbs, @intFromPtr(&mock));

    // activate -> activated fires -> callback deactivates re-entrantly.
    // The state change applies, the nested deactivated delivery is dropped.
    try s.activate();
    try std.testing.expect(!mock.active);
    try std.testing.expectEqual(@as(usize, 1), mock.activated_count);
    try std.testing.expectEqual(@as(usize, 0), mock.deactivated_count);
    try std.testing.expectEqual(@as(usize, 0), mock.guard.depth);

    // A second round behaves identically: the guard did not latch.
    try s.activate();
    try std.testing.expect(!mock.active);
    try std.testing.expectEqual(@as(usize, 2), mock.activated_count);
    try std.testing.expectEqual(@as(usize, 0), mock.deactivated_count);

    // With non-reentrant callbacks installed, delivery works again.
    const plain = Seat.Callbacks{
        .activated = deactivatedCount, // counts into deactivated_count
        .deactivated = deactivatedCount,
    };
    s.setCallbacks(&plain, @intFromPtr(&mock));
    try s.activate();
    try std.testing.expect(mock.active);
    try s.deactivate();
    try std.testing.expect(!mock.active);
    try std.testing.expectEqual(@as(usize, 2), mock.deactivated_count);

    const expected = [_]MockSeat.Call{
        .set_callbacks,
        .activate,
        .deactivate, // re-entrant, from inside activated
        .activate,
        .deactivate, // re-entrant, from inside activated
        .set_callbacks,
        .activate,
        .deactivate,
    };
    try std.testing.expectEqualSlices(MockSeat.Call, &expected, mock.calls.items);
}

test "seat: CallbackGuard enter/leave and null dispatch" {
    var guard = CallbackGuard{};
    var hits: usize = 0;

    const cb = struct {
        fn f(userdata: usize) void {
            const h: *usize = @ptrFromInt(userdata);
            h.* += 1;
        }
    }.f;

    // Null callback is a no-op and does not take the guard.
    guard.dispatch(null, @intFromPtr(&hits));
    try std.testing.expectEqual(@as(usize, 0), hits);
    try std.testing.expectEqual(@as(usize, 0), guard.depth);

    try std.testing.expect(guard.enter());
    try std.testing.expect(!guard.enter()); // nested enter refused
    guard.dispatch(cb, @intFromPtr(&hits)); // dropped while entered
    try std.testing.expectEqual(@as(usize, 0), hits);
    guard.leave();
    try std.testing.expectEqual(@as(usize, 0), guard.depth);

    guard.dispatch(cb, @intFromPtr(&hits));
    try std.testing.expectEqual(@as(usize, 1), hits);
    try std.testing.expectEqual(@as(usize, 0), guard.depth);
}
