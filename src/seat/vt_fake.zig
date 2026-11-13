//! src/seat/vt_fake.zig -- fake VT for seats that have no kernel VT
//! (ROADMAP M6.2 fake VT, docs/reference/libseat-sdlogin.md §6.7).
//!
//! Why this backend exists. A VT is a seat0 concept and a CONFIG_VT feature,
//! so a VT-bound backend cannot represent every seat kmshaunt runs on. Two
//! physical facts, both from kmscon's header comment
//! (src/uterm/vt_fake.c:26-49):
//!
//! 1. `CONFIG_VT` may be absent. Then there is no /dev/ttyN, no
//!    VT_ACTIVATE/VT_RELDISP/VT_SETMODE and no KD* ioctl family at all, so
//!    the real VT backend cannot open anything.
//! 2. Non-seat0 seats have no VTs by definition: a second seat (USB GPU +
//!    keyboard) has no /dev/ttyN bound to it, and seatd only serves seat0
//!    anyway (seatd/server.c:42-45).
//!
//! Such a seat still needs a seat object. logind tracks the session, the
//! video backend still needs activate/deactivate ordering around DRM master
//! and DPMS, and pause/resume still has to reach the session when logind
//! revokes device fds. kmscon's answer is a fake VT that synthesizes the
//! activation state in userspace because there is no kernel object to talk
//! to: activate/deactivate are plain callbacks (vt_fake.c:56-67), a
//! Ctrl+Logo+F12 hotkey in the input layer toggles the state
//! (vt_fake.c:69-91), and the fake ops have no `get_num`, so
//! `uterm_vt_get_num()` reports 0 (vt.c:191-197).
//!
//! kmscon calls this "for debugging only" and recommends activating the fake
//! VT once at startup and never using the hotkey, i.e. treating the seat as
//! always foreground (vt_fake.c:39-41). kmshaunt takes that recommendation
//! literally: `FakeVt` starts active, the hotkey would live in the input
//! layer and is not part of this backend, and `vtNum()` returns 0 to mark
//! "no kernel VT" (0 is outside the kernel's valid VT range 1..63, so no
//! caller can mistake it for a real VT). kmscon's struct starts inactive and
//! is activated during seat startup precisely because get_num() == 0
//! (src/seat.c:1060-1061); starting active is that same post-startup state.
//!
//! Consequences of being fake, all deliberate: no fd, no ioctl, no VT mode,
//! no allocation. Every operation is a state transition plus one guarded
//! callback, so nothing here can fail. Switching between two fake VTs on one
//! seat is not coordinated (kmscon: "a very fragile infrastructure",
//! vt_fake.c:32-46) -- kmshaunt runs one instance per seat and keeps it
//! foreground, so the ambiguity cannot arise.

const std = @import("std");
const contract = @import("../seat.zig");

pub const Seat = contract.Seat;
const CallbackGuard = contract.CallbackGuard;

/// A seat with no kernel VT and no device fds.
///
/// Lifecycle: `init` returns an active seat; `deinit` releases it. Both are
/// allocation-free and cannot fail. Holding a `Seat` handle obtained from
/// `seat()` keeps the `FakeVt` alive: the handle stores `self`.
pub const FakeVt = struct {
    /// The seat owns the console. Starts true; see the file comment.
    active: bool = true,
    /// A device fd is revoked (logind/seatd pause_device). `resume_` clears
    /// it. Independent of `active`: logind can pause a session while it is
    /// being switched away.
    paused: bool = false,
    /// Borrowed; valid until the next setCallbacks call or deinit.
    callbacks: ?*const Seat.Callbacks = null,
    /// Passed back to every callback unchanged.
    userdata: usize = 0,
    /// Re-entrancy guard: a callback that re-enters the seat still performs
    /// its state change, but its own callback delivery is dropped.
    guard: CallbackGuard = .{},

    /// Create an active fake VT.
    ///
    /// The allocator is accepted for constructor uniformity with the real
    /// VT and libseat backends (the session manager builds every backend the
    /// same way) and is deliberately not retained: the fake VT owns no heap
    /// state.
    pub fn init(allocator: std.mem.Allocator) FakeVt {
        _ = allocator;
        return .{};
    }

    /// Release the seat: drop the callbacks and park the state inactive.
    ///
    /// No fd to close and no VT mode to restore, so there is nothing else to
    /// do. `deinit` does NOT fire `deactivated`: the contract treats deinit
    /// as teardown by the owner (which has already stopped using the seat),
    /// and a callback during teardown would run against half-destroyed
    /// state. kmscon's fake_destroy() force-deactivates (vt_fake.c:89-93)
    /// because its teardown order depends on the callback; here the session
    /// manager calls `deactivate` before `deinit`. Idempotent, and the seat
    /// handle stays memory-safe (silently inert) if used afterwards.
    pub fn deinit(self: *FakeVt) void {
        self.callbacks = null;
        self.userdata = 0;
        self.active = false;
        self.paused = false;
    }

    /// The `Seat` handle for this fake VT. Borrows `self`.
    pub fn seat(self: *FakeVt) Seat {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// 0: this seat has no kernel VT. kmscon's fake ops leave `get_num`
    /// null, so uterm_vt_get_num() returns 0 (vt.c:191-197), and seat.c uses
    /// exactly that as the "no VT, activate the fake one" signal
    /// (src/seat.c:1060-1061). 0 is not a valid VT number (1..63).
    pub fn vtNum(_: *const FakeVt) u8 {
        return 0;
    }

    /// Deliver one callback through the contract's re-entrancy guard. Null
    /// callbacks and nested deliveries are dropped; the state change that
    /// caused the delivery has already been applied either way.
    fn fire(self: *FakeVt, comptime field: []const u8) void {
        const cbs = self.callbacks orelse return;
        self.guard.dispatch(@field(cbs, field), self.userdata);
    }

    fn cast(ptr: *anyopaque) *FakeVt {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn vtActivate(ptr: *anyopaque) anyerror!void {
        const self = cast(ptr);
        if (self.active) return;
        self.active = true;
        self.fire("activated");
    }

    fn vtDeactivate(ptr: *anyopaque) anyerror!void {
        const self = cast(ptr);
        if (!self.active) return;
        self.active = false;
        self.fire("deactivated");
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).active;
    }

    fn vtPause(ptr: *anyopaque) anyerror!void {
        const self = cast(ptr);
        if (self.paused) return;
        self.paused = true;
        self.fire("pause");
    }

    fn vtResume(ptr: *anyopaque) anyerror!void {
        const self = cast(ptr);
        if (!self.paused) return;
        self.paused = false;
        self.fire("resume_");
    }

    fn vtSetCallbacks(ptr: *anyopaque, callbacks: *const Seat.Callbacks, userdata: usize) void {
        const self = cast(ptr);
        self.callbacks = callbacks;
        self.userdata = userdata;
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
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Records every callback in delivery order. `userdata` is the pointer to
/// this struct, so the tests also prove the value survives unchanged.
const Recorder = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,

    const Event = enum { activated, deactivated, pause, resume_ };

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Recorder) void {
        self.events.deinit(self.allocator);
    }

    fn push(self: *Recorder, ev: Event) void {
        self.events.append(self.allocator, ev) catch @panic("vt_fake test: oom");
    }

    fn of(userdata: usize) *Recorder {
        return @ptrFromInt(userdata);
    }

    fn onActivated(userdata: usize) void {
        of(userdata).push(.activated);
    }
    fn onDeactivated(userdata: usize) void {
        of(userdata).push(.deactivated);
    }
    fn onPause(userdata: usize) void {
        of(userdata).push(.pause);
    }
    fn onResume(userdata: usize) void {
        of(userdata).push(.resume_);
    }

    const callbacks = Seat.Callbacks{
        .activated = onActivated,
        .deactivated = onDeactivated,
        .pause = onPause,
        .resume_ = onResume,
    };
};

test "vt_fake: starts active with no VT number" {
    var fake = FakeVt.init(std.testing.allocator);
    defer fake.deinit();
    const s = fake.seat();

    // kmscon's fake VT is the "activate once at startup" backend
    // (vt_fake.c:39-41, seat.c:1060-1061): kmshaunt constructs it active.
    try std.testing.expect(s.isActive());
    try std.testing.expect(!fake.paused);
    try std.testing.expectEqual(@as(u8, 0), fake.vtNum());
}

test "vt_fake: activate/deactivate/pause/resume lifecycle ordering" {
    const a = std.testing.allocator;
    var fake = FakeVt.init(a);
    defer fake.deinit();
    const s = fake.seat();

    var rec = Recorder.init(a);
    defer rec.deinit();
    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&rec));

    // Starts active, so deactivate is the first observable transition.
    try s.deactivate(); // -> deactivated
    try s.activate(); // -> activated
    try s.pause(); // -> pause
    try s.resume_(); // -> resume_
    try s.deactivate(); // -> deactivated

    const expected = [_]Recorder.Event{ .deactivated, .activated, .pause, .resume_, .deactivated };
    try std.testing.expectEqualSlices(Recorder.Event, &expected, rec.events.items);
    try std.testing.expect(!s.isActive());
    try std.testing.expect(!fake.paused);
    try std.testing.expectEqual(@as(usize, 0), fake.guard.depth);
}

test "vt_fake: repeated operations are idempotent and silent" {
    const a = std.testing.allocator;
    var fake = FakeVt.init(a);
    defer fake.deinit();
    const s = fake.seat();

    var rec = Recorder.init(a);
    defer rec.deinit();
    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&rec));

    try s.activate(); // already active: no transition, no callback
    try s.activate();
    try std.testing.expect(s.isActive());
    try s.deactivate(); // -> deactivated
    try s.deactivate(); // already inactive: silent
    try std.testing.expect(!s.isActive());

    try s.resume_(); // never paused: silent
    try std.testing.expect(!fake.paused);
    try s.pause(); // -> pause
    try s.pause(); // already paused: silent
    try s.resume_(); // -> resume_
    try s.resume_(); // already resumed: silent

    const expected = [_]Recorder.Event{ .deactivated, .pause, .resume_ };
    try std.testing.expectEqualSlices(Recorder.Event, &expected, rec.events.items);
}

test "vt_fake: callbacks fire with userdata intact and can be replaced" {
    const a = std.testing.allocator;
    var fake = FakeVt.init(a);
    defer fake.deinit();
    const s = fake.seat();

    var first = Recorder.init(a);
    defer first.deinit();
    var second = Recorder.init(a);
    defer second.deinit();

    // No callbacks installed yet: operations still apply silently.
    try s.deactivate();
    try std.testing.expect(!s.isActive());

    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&first));
    try s.activate();
    try s.pause();
    try s.resume_();
    try std.testing.expectEqual(@as(usize, 3), first.events.items.len);
    try std.testing.expectEqual(Recorder.Event.activated, first.events.items[0]);

    // Replacing the callbacks retargets delivery: the old recorder sees
    // nothing more, the new one does, and userdata is the new pointer.
    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&second));
    try s.deactivate();
    try std.testing.expectEqual(@as(usize, 3), first.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.events.items.len);
    try std.testing.expectEqual(Recorder.Event.deactivated, second.events.items[0]);

    // A null callback set is a no-op delivery path, not a crash.
    const none = Seat.Callbacks{};
    s.setCallbacks(&none, 0);
    try s.activate();
    try s.pause();
    try std.testing.expect(s.isActive());
    try std.testing.expect(fake.paused);
}

/// Re-entrant activated callback: deactivates the seat from inside the
/// delivery. The state change must apply, the nested deactivated delivery
/// must be dropped by the guard.
const Reenter = struct {
    fake: *FakeVt,
    activated: usize = 0,
    deactivated: usize = 0,
    userdata_seen: usize = 0,
};

fn reenterActivated(userdata: usize) void {
    const r: *Reenter = @ptrFromInt(userdata);
    r.activated += 1;
    r.userdata_seen = userdata;
    r.fake.seat().deactivate() catch @panic("vt_fake test: reentrant deactivate failed");
}

fn countDeactivated(userdata: usize) void {
    const r: *Reenter = @ptrFromInt(userdata);
    r.deactivated += 1;
}

test "vt_fake: re-entrant callback delivery is guarded" {
    var fake = FakeVt.init(std.testing.allocator);
    defer fake.deinit();
    const s = fake.seat();

    var r = Reenter{ .fake = &fake };
    const cbs = Seat.Callbacks{
        .activated = reenterActivated,
        .deactivated = countDeactivated,
    };
    s.setCallbacks(&cbs, @intFromPtr(&r));

    try s.deactivate(); // reach the inactive state first
    r.activated = 0;
    r.deactivated = 0; // discard the setup call's callback
    // activate -> activated -> callback deactivates re-entrantly: the state
    // flips back, the nested deactivated delivery is dropped.
    try s.activate();
    try std.testing.expect(!s.isActive());
    try std.testing.expectEqual(@as(usize, 1), r.activated);
    try std.testing.expectEqual(@as(usize, 0), r.deactivated);
    try std.testing.expectEqual(@as(usize, 0), fake.guard.depth);
    try std.testing.expectEqual(@intFromPtr(&r), r.userdata_seen);

    // The guard did not latch: a second round behaves identically.
    try s.activate();
    try std.testing.expect(!s.isActive());
    try std.testing.expectEqual(@as(usize, 2), r.activated);
    try std.testing.expectEqual(@as(usize, 0), r.deactivated);

    // With non-re-entrant callbacks, delivery works again.
    const plain = Seat.Callbacks{
        .activated = countDeactivated, // counts into deactivated
        .deactivated = countDeactivated,
    };
    s.setCallbacks(&plain, @intFromPtr(&r));
    try s.activate();
    try std.testing.expect(s.isActive());
    try s.deactivate();
    try std.testing.expect(!s.isActive());
    try std.testing.expectEqual(@as(usize, 2), r.deactivated);
}

test "vt_fake: deinit drops callbacks without firing and is idempotent" {
    var fake = FakeVt.init(std.testing.allocator);
    const s = fake.seat();

    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&rec));

    try s.deactivate(); // -> deactivated
    try s.pause(); // -> pause
    fake.deinit(); // teardown: no callback
    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try std.testing.expect(!s.isActive());
    try std.testing.expect(!fake.paused);
    try std.testing.expect(fake.callbacks == null);

    // Second deinit and any post-deinit use stay memory-safe and inert.
    fake.deinit();
    try s.activate();
    try s.resume_();
    try std.testing.expect(s.isActive());
    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
}

/// Count of the file descriptors the test process has open. Both calls
/// include this directory's own fd, so the comparison is meaningful.
fn fdCount() !usize {
    const io = std.testing.io;
    var dir = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "vt_fake: pure state -- no kernel handle, no fd, no retained allocator" {
    // Structural: no field can hold a kernel handle or an allocator, so the
    // backend cannot have opened anything or own heap state.
    const info = @typeInfo(FakeVt).@"struct";
    inline for (info.field_types) |FieldType| {
        try std.testing.expect(FieldType != std.posix.fd_t);
        try std.testing.expect(FieldType != std.Io.File);
        try std.testing.expect(FieldType != std.Io.Dir);
        try std.testing.expect(FieldType != std.mem.Allocator);
    }

    // Runtime: a full lifecycle opens and closes nothing.
    var fake = FakeVt.init(std.testing.allocator);
    defer fake.deinit();
    const s = fake.seat();
    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    s.setCallbacks(&Recorder.callbacks, @intFromPtr(&rec));

    const before = try fdCount();
    try s.activate();
    try s.deactivate();
    try s.pause();
    try s.resume_();
    try s.activate();
    try s.deactivate();
    const after = try fdCount();
    try std.testing.expectEqual(before, after);

    // No error path exists: anything other than full, in-order delivery
    // would mean a hidden side channel. The first activate is a no-op
    // because the seat starts active.
    const expected = [_]Recorder.Event{
        .deactivated, .pause, .resume_, .activated, .deactivated,
    };
    try std.testing.expectEqualSlices(Recorder.Event, &expected, rec.events.items);
}