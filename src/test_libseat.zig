//! src/test_libseat.zig -- hermetic tests for the libseat backend.
//!
//! `src/seat/libseat.zig` imports `../seat.zig`, so its module root must be
//! `src/`; run this root instead of the backend file:
//!
//!     zig test src/test_libseat.zig
//!
//! No seatd socket, no logind, no `-lseat`: the backend reaches libseat only
//! through `LibseatOps`, and every test in this file installs the fake
//! implementation below. `LibseatOps.real` is lazily analyzed and never
//! referenced here, so the test binary has no undefined C symbols.
//!
//! The fake mirrors the 0.9.3 protocol facts the backend must honor: the
//! first `enable_seat` arrives on a dispatch *after* `open_seat`, device ids
//! are opaque (not fds), `disable_seat` is a blocking ack on seatd, and
//! callbacks are delivered synchronously from inside dispatch.
test {
    _ = @import("seat/libseat.zig");
}

const std = @import("std");
const seat = @import("seat.zig");
const libseat = @import("seat/libseat.zig");

const LibseatSeat = libseat.LibseatSeat;
const LibseatOps = libseat.LibseatOps;
const SeatListener = libseat.SeatListener;
const Libseat = libseat.Libseat;

/// Stand-in for `struct libseat *`. Never dereferenced.
fn fakeHandle() *Libseat {
    return @ptrFromInt(0x1000);
}

const Call = enum {
    open_seat,
    close_seat,
    disable_seat,
    open_device,
    close_device,
    close_fd,
    get_fd,
    dispatch,
    activated,
    deactivated,
    pause_cb,
    resume_cb,
};

const Fake = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(Call) = .empty,
    closed_ids: std.ArrayListUnmanaged(c_int) = .empty,
    closed_fds: std.ArrayListUnmanaged(c_int) = .empty,
    dispatch_timeouts: std.ArrayListUnmanaged(c_int) = .empty,
    listener: ?*const SeatListener = null,
    listener_userdata: ?*anyopaque = null,
    next_id: c_int = 1,
    next_fd: c_int = 100,
    dispatch_rc: c_int = 0,
    disable_rc: c_int = 0,
    poll_fd: c_int = 42,
    open_seat_fails: bool = false,
    enable_on_dispatch: bool = false,
    close_device_failures: usize = 0,
    last_path: []const u8 = "",

    fn deinit(self: *Fake) void {
        self.calls.deinit(self.allocator);
        self.closed_ids.deinit(self.allocator);
        self.closed_fds.deinit(self.allocator);
        self.dispatch_timeouts.deinit(self.allocator);
    }

    fn record(self: *Fake, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake: out of memory");
    }

    fn reset(self: *Fake) void {
        self.calls.clearRetainingCapacity();
        self.closed_ids.clearRetainingCapacity();
        self.closed_fds.clearRetainingCapacity();
    }

    /// Simulate the seat provider delivering `enable_seat`.
    fn enable(self: *Fake) void {
        self.listener.?.enable_seat(fakeHandle(), self.listener_userdata);
    }

    /// Simulate the seat provider delivering `disable_seat`.
    fn disable(self: *Fake) void {
        self.listener.?.disable_seat(fakeHandle(), self.listener_userdata);
    }

    fn ops(self: *Fake) LibseatOps {
        _ = self;
        return .{
            .open_seat = fakeOpenSeat,
            .close_seat = fakeCloseSeat,
            .disable_seat = fakeDisableSeat,
            .open_device = fakeOpenDevice,
            .close_device = fakeCloseDevice,
            .get_fd = fakeGetFd,
            .dispatch = fakeDispatch,
            .close_fd = fakeCloseFd,
        };
    }
};

/// Function pointers carry no context, so the fake state is a file-scope
/// pointer. Zig's test runner executes tests sequentially, and every test
/// installs its own state before calling into the backend.
var current_fake: ?*Fake = null;

fn fake() *Fake {
    return current_fake orelse @panic("fake ops used before installation");
}

fn fakeOpenSeat(listener: *const SeatListener, userdata: ?*anyopaque) callconv(.c) ?*Libseat {
    const f = fake();
    f.record(.open_seat);
    if (f.open_seat_fails) return null;
    f.listener = listener;
    f.listener_userdata = userdata;
    return fakeHandle();
}

fn fakeCloseSeat(handle: *Libseat) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.close_seat);
    return 0;
}

fn fakeDisableSeat(handle: *Libseat) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.disable_seat);
    return f.disable_rc;
}

fn fakeOpenDevice(handle: *Libseat, path: [*:0]const u8, fd: *c_int) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.open_device);
    f.last_path = std.mem.span(path);

    const device_id = f.next_id;
    const device_fd = f.next_fd;
    f.next_id += 1;
    f.next_fd += 1;
    fd.* = device_fd;
    return device_id;
}

fn fakeCloseDevice(handle: *Libseat, device_id: c_int) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.close_device);
    f.closed_ids.append(f.allocator, device_id) catch @panic("fake: out of memory");
    if (f.close_device_failures > 0) {
        f.close_device_failures -= 1;
        return -1;
    }
    return 0;
}

fn fakeCloseFd(fd: c_int) callconv(.c) void {
    const f = fake();
    f.record(.close_fd);
    f.closed_fds.append(f.allocator, fd) catch @panic("fake: out of memory");
}

fn fakeGetFd(handle: *Libseat) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.get_fd);
    return f.poll_fd;
}

fn fakeDispatch(handle: *Libseat, timeout: c_int) callconv(.c) c_int {
    std.debug.assert(handle == fakeHandle());
    const f = fake();
    f.record(.dispatch);
    f.dispatch_timeouts.append(f.allocator, timeout) catch @panic("fake: out of memory");

    var processed: c_int = 0;
    if (f.enable_on_dispatch) {
        f.enable_on_dispatch = false;
        f.enable();
        processed = 1;
    }
    return if (f.dispatch_rc != 0) f.dispatch_rc else processed;
}

/// Callback counters plus ordering records. `userdata` is `@intFromPtr(self)`.
const Counters = struct {
    activated: usize = 0,
    deactivated: usize = 0,
    paused: usize = 0,
    resumed: usize = 0,
    last_userdata: usize = 0,
    fake: ?*Fake = null,

    fn callbacks(self: *Counters) seat.Seat.Callbacks {
        _ = self;
        return .{
            .activated = onActivated,
            .deactivated = onDeactivated,
            .pause = onPause,
            .resume_ = onResume,
        };
    }

    fn note(self: *Counters, call: Call) void {
        if (self.fake) |f| f.record(call);
    }

    fn onActivated(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.activated += 1;
        self.last_userdata = userdata;
        self.note(.activated);
    }

    fn onDeactivated(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.deactivated += 1;
        self.note(.deactivated);
    }

    fn onPause(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.paused += 1;
        self.note(.pause_cb);
    }

    fn onResume(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.resumed += 1;
        self.note(.resume_cb);
    }
};

fn setup(allocator: std.mem.Allocator, f: *Fake) libseat.Error!*LibseatSeat {
    current_fake = f;
    return LibseatSeat.init(allocator, f.ops());
}

fn expectCalls(f: *Fake, expected: []const Call) !void {
    try std.testing.expectEqualSlices(Call, expected, f.calls.items);
}

test "libseat: init opens, drains dispatch(0) and replays the queued enable" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    // seatd: SERVER_ENABLE_SEAT is written right after SERVER_SEAT_OPENED,
    // so it is only visible to the first dispatch after open.
    f.enable_on_dispatch = true;
    const s = try setup(a, &f);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 1), f.dispatch_timeouts.items.len);
    try std.testing.expectEqual(@as(c_int, 0), f.dispatch_timeouts.items[0]);
    try std.testing.expect(s.isActive());
    try expectCalls(&f, &.{ .open_seat, .dispatch });

    // Callbacks could only be installed after init: the activation that the
    // drain observed must be replayed exactly once.
    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));
    try std.testing.expectEqual(@as(usize, 1), counters.activated);
    try std.testing.expectEqual(@intFromPtr(&counters), counters.last_userdata);

    s.setCallbacks(&cbs, @intFromPtr(&counters));
    try std.testing.expectEqual(@as(usize, 1), counters.activated);
}

test "libseat: enable fires activated once and isActive tracks it" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));
    try std.testing.expect(!s.isActive());

    // A disabled seat gates device operations locally.
    try std.testing.expectError(error.SeatNotEnabled, s.openDevice("/dev/dri/card0"));

    f.enable();
    try std.testing.expect(s.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    f.enable(); // duplicate enable: no transition, no callback
    try std.testing.expectEqual(@as(usize, 1), counters.activated);
}

test "libseat: disable closes every device before the ack and fires deactivated" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));
    f.enable();

    const d1 = try s.openDevice("/dev/dri/card0");
    const d2 = try s.openDevice("/dev/input/event0");
    try std.testing.expectEqual(@as(c_int, 1), d1.device_id);
    try std.testing.expectEqual(@as(c_int, 100), d1.fd);
    try std.testing.expectEqual(@as(c_int, 2), d2.device_id);
    try std.testing.expectEqual(@as(c_int, 101), d2.fd);
    try std.testing.expectEqual(@as(usize, 2), s.deviceCount());

    f.reset();
    f.disable();

    // Devices are popped in reverse open order. close_device(id) comes
    // before close(fd) for each, then deactivated, then the seatd ack.
    const expected = [_]Call{
        .close_device,
        .close_fd,
        .close_device,
        .close_fd,
        .deactivated,
        .disable_seat,
    };
    try expectCalls(&f, &expected);
    try std.testing.expectEqualSlices(c_int, &[_]c_int{ 2, 1 }, f.closed_ids.items);
    try std.testing.expectEqualSlices(c_int, &[_]c_int{ 101, 100 }, f.closed_fds.items);
    try std.testing.expectEqual(@as(usize, 0), s.deviceCount());
    try std.testing.expect(!s.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 1), s.ack_count);
    try std.testing.expectEqual(@as(usize, 0), s.disable_failures);
}

test "libseat: double disable is a no-op and the next cycle acks again" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));

    f.enable();
    _ = try s.openDevice("/dev/dri/card0");
    f.reset();
    f.disable();
    try std.testing.expectEqual(@as(usize, 1), s.ack_count);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);

    // Second event before enable: already disabled, nothing to close, the
    // obligation was already met, no extra callback.
    f.reset();
    f.disable();
    try std.testing.expectEqual(@as(usize, 0), f.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.ack_count);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);

    // New enable/disable cycle works and acks exactly once more.
    f.enable();
    try std.testing.expect(s.isActive());
    try std.testing.expectEqual(@as(usize, 2), counters.activated);
    _ = try s.openDevice("/dev/input/event0");
    f.reset();
    f.disable();
    try std.testing.expectEqual(@as(usize, 2), s.ack_count);
    try std.testing.expectEqual(@as(usize, 0), s.deviceCount());
    try expectCalls(&f, &.{
        .close_device,
        .close_fd,
        .deactivated,
        .disable_seat,
    });
}

test "libseat: disable without a preceding enable is ignored" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));

    f.reset();
    f.disable(); // e.g. logind reporting an inactive initial session
    try std.testing.expectEqual(@as(usize, 0), f.calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 0), s.ack_count);
    try std.testing.expect(!s.isActive());
}

test "libseat: pause/resume fire their callbacks once per transition" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));

    try s.pause();
    try s.pause();
    try std.testing.expect(s.isPaused());
    try std.testing.expectEqual(@as(usize, 1), counters.paused);

    try s.resume_();
    try s.resume_();
    try std.testing.expect(!s.isPaused());
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);
    try std.testing.expectEqual(@as(usize, 0), counters.activated);
}

test "libseat: openDevice/closeDevice track the {fd, id} pair" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));
    f.enable();

    f.reset();
    const d1 = try s.openDevice("/dev/dri/card0");
    try std.testing.expectEqual(@as(c_int, 1), d1.device_id);
    try std.testing.expectEqual(@as(c_int, 100), d1.fd);
    try std.testing.expectEqualStrings("/dev/dri/card0", f.last_path);

    const d2 = try s.openDevice("/dev/input/event0");
    try std.testing.expectEqual(@as(c_int, 2), d2.device_id);
    try std.testing.expectEqual(@as(c_int, 101), d2.fd);
    try std.testing.expectEqual(@as(usize, 2), s.deviceCount());

    try s.closeDevice(d1.device_id);
    try std.testing.expectEqualSlices(c_int, &[_]c_int{1}, f.closed_ids.items);
    try std.testing.expectEqualSlices(c_int, &[_]c_int{100}, f.closed_fds.items);
    try std.testing.expectEqual(@as(usize, 1), s.deviceCount());

    // Closing an unknown id never touches libseat.
    f.reset();
    try std.testing.expectError(error.UnknownDevice, s.closeDevice(d1.device_id));
    try std.testing.expectEqual(@as(usize, 0), f.calls.items.len);

    // A failing libseat_close_device still closes the fd (revoke is
    // irreversible) and surfaces the error.
    f.close_device_failures = 1;
    try std.testing.expectError(error.CloseDeviceFailed, s.closeDevice(d2.device_id));
    try std.testing.expectEqualSlices(c_int, &[_]c_int{101}, f.closed_fds.items);
    try std.testing.expectEqual(@as(usize, 0), s.deviceCount());
    try std.testing.expectEqual(@as(usize, 1), s.close_failures);

    // The same is true on the disable path.
    const d3 = try s.openDevice("/dev/hidraw0");
    f.reset();
    f.close_device_failures = 1;
    f.disable();
    try std.testing.expectEqual(@as(usize, 0), s.deviceCount());
    try std.testing.expectEqualSlices(c_int, &[_]c_int{d3.fd}, f.closed_fds.items);
    try std.testing.expectEqual(@as(usize, 1), s.ack_count);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);
}

test "libseat: deinit closes devices, then the seat" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    s.setCallbacks(&cbs, @intFromPtr(&counters));
    f.enable();
    _ = try s.openDevice("/dev/dri/card0");
    _ = try s.openDevice("/dev/input/event0");

    f.reset();
    s.deinit();

    try expectCalls(&f, &.{
        .close_device,
        .close_fd,
        .close_device,
        .close_fd,
        .close_seat,
    });
    try std.testing.expectEqualSlices(c_int, &[_]c_int{ 2, 1 }, f.closed_ids.items);
    try std.testing.expectEqualSlices(c_int, &[_]c_int{ 101, 100 }, f.closed_fds.items);
}

test "libseat: dispatch wrapper passes timeouts, tolerates 0 and reports errors" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    defer s.deinit();

    try std.testing.expectEqual(@as(?c_int, 42), s.seatFd());
    f.poll_fd = -1;
    try std.testing.expect(s.seatFd() == null);

    f.dispatch_rc = 3;
    try std.testing.expectEqual(@as(usize, 3), try s.dispatch(250));
    f.dispatch_rc = 0; // CLIENT_PING wake-up: legitimately nothing to do
    try std.testing.expectEqual(@as(usize, 0), try s.dispatch(0));

    f.dispatch_rc = -1;
    try std.testing.expectError(error.DispatchFailed, s.dispatch(-1));

    try std.testing.expectEqualSlices(
        c_int,
        &[_]c_int{ 0, 250, 0, -1 },
        f.dispatch_timeouts.items,
    );
}

test "libseat: nested dispatch from a callback is suppressed" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const Reenter = struct {
        s: *LibseatSeat,
        inner: usize = 99,
        activations: usize = 0,
        pause_callbacks: usize = 0,

        fn onActivated(userdata: usize) void {
            const self: *@This() = @ptrFromInt(userdata);
            self.activations += 1;
            self.inner = self.s.dispatch(0) catch 1000;
            self.s.pause() catch {};
        }

        fn onPause(userdata: usize) void {
            const self: *@This() = @ptrFromInt(userdata);
            self.pause_callbacks += 1;
        }
    };

    const s = try setup(a, &f);
    defer s.deinit();

    var reenter = Reenter{ .s = s };
    const cbs = seat.Seat.Callbacks{
        .activated = Reenter.onActivated,
        .pause = Reenter.onPause,
    };
    s.setCallbacks(&cbs, @intFromPtr(&reenter));

    // Outer dispatch delivers enable synchronously; the activated callback
    // tries to dispatch again and fire another callback.
    f.enable_on_dispatch = true;
    try std.testing.expectEqual(@as(usize, 1), try s.dispatch(0));

    try std.testing.expectEqual(@as(usize, 1), reenter.activations);
    try std.testing.expectEqual(@as(usize, 0), reenter.inner);
    try std.testing.expectEqual(@as(usize, 0), reenter.pause_callbacks);
    try std.testing.expect(s.isPaused()); // state applied, delivery guarded
    // init dispatch + outer dispatch; the nested one never reached libseat.
    try std.testing.expectEqual(@as(usize, 2), f.dispatch_timeouts.items.len);
}

test "libseat: Seat vtable maps to the backend" {
    const a = std.testing.allocator;
    var f = Fake{ .allocator = a };
    defer f.deinit();

    const s = try setup(a, &f);
    const view = s.seat();

    var counters = Counters{ .fake = &f };
    const cbs = counters.callbacks();
    view.setCallbacks(&cbs, @intFromPtr(&counters));

    try std.testing.expect(!view.isActive());
    try view.activate(); // pumps dispatch(0); seat is still disabled
    try std.testing.expect(!view.isActive());

    f.enable();
    try std.testing.expect(view.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    // libseat has no voluntary hand-off call (the provider initiates it).
    try std.testing.expectError(error.NotSupported, view.deactivate());

    try view.pause();
    try view.resume_();
    try std.testing.expectEqual(@as(usize, 1), counters.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);

    f.disable();
    try std.testing.expect(!view.isActive());
    try view.deactivate(); // already inactive: no-op

    view.deinit();
}

test "libseat: init failures close what was opened" {
    const a = std.testing.allocator;

    {
        var f = Fake{ .allocator = a };
        defer f.deinit();
        current_fake = &f;
        f.open_seat_fails = true;
        try std.testing.expectError(error.OpenSeatFailed, LibseatSeat.init(a, f.ops()));
        try expectCalls(&f, &.{.open_seat});
    }

    {
        var f = Fake{ .allocator = a };
        defer f.deinit();
        current_fake = &f;
        f.dispatch_rc = -1;
        try std.testing.expectError(error.DispatchFailed, LibseatSeat.init(a, f.ops()));
        try expectCalls(&f, &.{ .open_seat, .dispatch, .close_seat });
    }
}

test "libseat: SeatListener has C layout" {
    try std.testing.expectEqual(
        @sizeOf(usize) * 2,
        @sizeOf(SeatListener),
    );
    try std.testing.expectEqual(@alignOf(usize), @alignOf(SeatListener));
}