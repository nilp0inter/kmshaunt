//! src/test_libseat_real.zig -- real-ops integration tests for the libseat
//! backend (ROADMAP M6.7 startup-segfault regression).
//!
//! Unlike src/test_libseat.zig (fake ops, no C symbols referenced), this
//! root exercises `LibseatOps.real`: the actual libseat C library runs
//! `open_seat`, stores the listener pointer and userdata, and delivers
//! `enable_seat` through the C ABI into the Zig trampolines. It links
//! libseat; standalone run:
//!
//!     zig test src/test_libseat_real.zig -lc $(pkg-config --cflags --libs libseat)
//!
//! Hermetic nonetheless: every test pins `LIBSEAT_BACKEND=noop`, the one
//! backend that needs no seatd socket, no logind session and no privileges
//! (libseat/backend/noop.c). Its first dispatch fires `enable_seat` exactly
//! once -- the same init-time enable the seatd/logind backends deliver, so
//! the startup ordering regression is covered without a daemon.
//!
//! Wired into `zig build test` through src/tests.zig (that module already
//! links libseat). The module root must be `src/`: seat/libseat.zig imports
//! `../seat.zig`.

const std = @import("std");
const seat = @import("seat.zig");
const libseat = @import("seat/libseat.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Pin the backend for one test; the environment is restored afterwards so
/// test order never matters.
fn pinBackend(value: [*:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), setenv("LIBSEAT_BACKEND", value, 1));
}

fn unpinBackend() void {
    _ = unsetenv("LIBSEAT_BACKEND");
}

const Counters = struct {
    activated: usize = 0,
    deactivated: usize = 0,
    last_userdata: usize = 0,

    fn callbacks(self: *Counters) seat.Seat.Callbacks {
        _ = self;
        return .{
            .activated = onActivated,
            .deactivated = onDeactivated,
        };
    }

    fn onActivated(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.activated += 1;
        self.last_userdata = userdata;
    }

    fn onDeactivated(userdata: usize) void {
        const self: *Counters = @ptrFromInt(userdata);
        self.deactivated += 1;
    }
};

test "real libseat: startup ordering -- setCallbacks is silent, activate delivers once" {
    try pinBackend("noop");
    defer unpinBackend();
    const a = std.testing.allocator;

    // The exact main.zig setupSeat sequence against the real C library:
    // init drains the first enable_seat, then callbacks are installed.
    const s = try libseat.LibseatSeat.init(a, libseat.LibseatOps.real);
    defer s.deinit();
    try std.testing.expect(s.isActive());

    // Regression (M6.7): installing callbacks must not fire the enable the
    // drain observed. The owner's activated callback runs against state
    // that does not exist yet at this point (undefined video backend ->
    // NULL vtable -> "segfault at 28" in flipPending).
    var counters = Counters{};
    const cbs = counters.callbacks();
    const view = s.seat();
    view.setCallbacks(&cbs, @intFromPtr(&counters));
    try std.testing.expectEqual(@as(usize, 0), counters.activated);

    // The owner activates once ready: the queued enable arrives exactly
    // once, through the real C listener -> userdata round trip.
    try view.activate();
    try std.testing.expectEqual(@as(usize, 1), counters.activated);
    try std.testing.expectEqual(@intFromPtr(&counters), counters.last_userdata);
    try view.activate();
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    // The pollable fd is live and stable (event-loop registration).
    const fd = s.seatFd() orelse return error.TestUnexpectedResult;
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(fd, s.seatFd().?);
    try std.testing.expectEqual(@as(usize, 0), try s.dispatch(0));
}

test "real libseat: device open/close through the C path" {
    try pinBackend("noop");
    defer unpinBackend();
    const a = std.testing.allocator;

    const s = try libseat.LibseatSeat.init(a, libseat.LibseatOps.real);
    defer s.deinit();

    // noop open_device is a plain open(2); /dev/null needs no privileges.
    const d = try s.openDevice("/dev/null");
    try std.testing.expect(d.fd >= 0);
    // On noop the id is the fd (never assume this on seatd/logind).
    try std.testing.expectEqual(d.fd, d.device_id);
    try std.testing.expectEqual(@as(usize, 1), s.deviceCount());

    try s.closeDevice(d.device_id);
    try std.testing.expectEqual(@as(usize, 0), s.deviceCount());
    try std.testing.expectEqual(@as(usize, 0), s.close_failures);
}

test "real libseat: unknown backend returns OpenSeatFailed, not a crash" {
    try pinBackend("kmshaunt-no-such-backend");
    defer unpinBackend();
    const a = std.testing.allocator;

    // libseat_open_seat returns NULL with EINVAL; the wrapper must surface
    // the error instead of dereferencing the handle.
    try std.testing.expectError(
        error.OpenSeatFailed,
        libseat.LibseatSeat.init(a, libseat.LibseatOps.real),
    );
}
