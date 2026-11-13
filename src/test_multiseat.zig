//! src/test_multiseat.zig -- hermetic tests for the sd-login seat monitor
//! (`src/seat/multiseat.zig`, ROADMAP M6.2).
//!
//! `src/seat/multiseat.zig` is a subdirectory module, so its module root
//! must be `src/`; run this root instead of the module file:
//!
//!     nix run nixpkgs#zig -- test src/test_multiseat.zig
//!     # or, with a zig 0.17.1 on PATH:
//!     zig test src/test_multiseat.zig
//!
//! No logind, no `/run/systemd/seats`, no `-lsystemd`: every C call goes
//! through `SdLoginOps`, and each test installs the fake below.
//! `SdLoginOps.real` is the only declaration that references the
//! translate-c module `sd-login-c` and libc `free`; it is analyzed lazily
//! and never referenced here, so the test binary has no undefined symbols.
//!
//! The fake mirrors the sd-login 262 semantics the monitor must honor:
//! errors are negative errno, the seat array is `NULL`-terminated and
//! libc-malloc'd (here: allocator-allocated and released through the fake
//! `free`, whose bookkeeping proves the monitor released everything),
//! `-ENXIO`/`-ENODATA` mean "no active session", and an empty seat set may
//! be reported as `NULL`.
//!
//! # Optional real-logind probe (not part of the hermetic suite)
//!
//! On a host with logind (this workstation reports one seat, `seat0`), the
//! real ops can be exercised end to end. Build the translate-c module,
//! write a throwaway root in /tmp, and run it:
//!
//!     SYS=$(nix build nixpkgs#systemd.dev --print-out-paths --no-link)
//!     LIB=$(nix eval --raw nixpkgs#systemd.outPath)
//!     GLIBC=$(nix build nixpkgs#glibc.dev --print-out-paths --no-link)
//!     printf '#include <systemd/sd-login.h>\n' > /tmp/sd-login-c.h
//!     nix run nixpkgs#zig -- translate-c -I "$GLIBC/include" \
//!         -I "$SYS/include" /tmp/sd-login-c.h > /tmp/sd-login-c.zig
//!
//! /tmp/multiseat_probe_root.zig (only the interesting calls shown):
//!
//!     const std = @import("std");
//!     const ms = @import("multiseat");
//!     pub fn main() !void {
//!         var mon = try ms.SeatMonitor.init(std.heap.page_allocator, ms.SdLoginOps.real);
//!         defer mon.deinit();
//!         std.debug.print("fd={} events=0x{x} timeout={} seats={}\n",
//!             .{ try mon.fd(), try mon.events(), try mon.timeoutUsec(), mon.seats().len });
//!         for (try mon.process()) |change| switch (change) {
//!             .added => |s| std.debug.print(
//!                 "added seat={s} session={?s} has_vt={} fake_vt={}\n",
//!                 .{ s.name, s.active_session, s.has_vt, s.needsFakeVt() }),
//!             .removed => |s| std.debug.print("removed seat={s}\n", .{s.name}),
//!         };
//!     }
//!
//! `--dep X` applies to the module that follows, so `sd-login-c` is
//! declared before the `multiseat` module (the same shape `build.zig` will
//! use with `addImport`):
//!
//!     LD_LIBRARY_PATH="$LIB/lib" nix run nixpkgs#zig -- run -lc \
//!         --dep multiseat -Mroot=/tmp/multiseat_probe_root.zig \
//!         --dep sd-login-c -Mmultiseat=src/seat/multiseat.zig \
//!         -Msd-login-c=/tmp/sd-login-c.zig \
//!         -L"$LIB/lib" -lsystemd
//!
//! Verified output on this host (2026-11-13, systemd 262):
//!
//!     fd=3 events=0x1 timeout=18446744073709551615 seats=0
//!     added seat=seat0 session=1 has_vt=true fake_vt=false
//!
//! (The session name is logind's; the VT number is not part of the seat
//! API. `has_vt=true` means `/dev/tty0` exists and the seat is `seat0`.)

test {
    _ = @import("seat/multiseat.zig");
}

const std = @import("std");
const multiseat = @import("seat/multiseat.zig");

const SdLoginOps = multiseat.SdLoginOps;
const Monitor = multiseat.Monitor;
const SeatMonitor = multiseat.SeatMonitor;
const SeatInfo = multiseat.SeatInfo;
const SeatChange = multiseat.SeatChange;

// ---------------------------------------------------------------------------
// Fake sd-login
// ---------------------------------------------------------------------------

/// Stand-in for `sd_login_monitor *`. Never dereferenced.
fn fakeMonitor() *Monitor {
    return @ptrFromInt(0x2000);
}

const Call = enum {
    monitor_new,
    monitor_unref,
    flush,
    get_seats,
    seat_get_active,
    get_fd,
    get_events,
    get_timeout,
};

/// One seat as the fake logind reports it. `session` is the active session
/// (`null` -> `-ENODATA`); `err` overrides with the negated errno to
/// return instead (0 = normal path).
const SeatSpec = struct {
    name: []const u8,
    session: ?[]const u8 = null,
    err: c_int = 0,
};

/// Fake allocations that must come back through the fake `free`.
const Owned = union(enum) {
    bytes: [:0]u8,
    array: [:null]?[*:0]u8,
};

const Fake = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(Call) = .empty,
    categories: std.ArrayListUnmanaged([]const u8) = .empty,
    seats: std.ArrayListUnmanaged(SeatSpec) = .empty,
    owned: std.ArrayListUnmanaged(Owned) = .empty,
    freed: usize = 0,

    monitor_rc: c_int = 0,
    flush_rc: c_int = 0,
    get_seats_rc: c_int = 0,
    /// Simulate "no /run/systemd/seats": count 0 and a NULL array.
    null_seat_array: bool = false,
    get_fd_rc: c_int = 64,
    get_events_rc: c_int = multiseat.poll_in,
    get_timeout_rc: c_int = 0,
    timeout_usec: u64 = multiseat.infinite_timeout,

    fn init(allocator: std.mem.Allocator) Fake {
        return .{ .allocator = allocator };
    }

    /// Frees the bookkeeping only. Fake allocations in `owned` are
    /// deliberately left to `std.testing.allocator`: a string the monitor
    /// forgot to free must show up as a test leak, not be papered over.
    fn deinit(self: *Fake) void {
        self.calls.deinit(self.allocator);
        self.categories.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.owned.deinit(self.allocator);
    }

    fn record(self: *Fake, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake sd-login: oom");
    }

    fn setSeats(self: *Fake, specs: []const SeatSpec) void {
        self.seats.clearRetainingCapacity();
        self.seats.appendSlice(self.allocator, specs) catch @panic("fake sd-login: oom");
    }

    fn count(self: *const Fake, call: Call) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c == call) n += 1;
        }
        return n;
    }

    fn ops(self: *Fake) SdLoginOps {
        _ = self;
        return .{
            .get_seats = fakeGetSeats,
            .seat_get_active = fakeSeatGetActive,
            .monitor_new = fakeMonitorNew,
            .monitor_unref = fakeMonitorUnref,
            .monitor_flush = fakeMonitorFlush,
            .monitor_get_fd = fakeMonitorGetFd,
            .monitor_get_events = fakeMonitorGetEvents,
            .monitor_get_timeout = fakeMonitorGetTimeout,
            .free = fakeFree,
        };
    }

    fn dupeC(self: *Fake, s: []const u8) [*:0]u8 {
        const buf = self.allocator.allocSentinel(u8, s.len, 0) catch @panic("fake sd-login: oom");
        @memcpy(buf, s);
        self.owned.append(self.allocator, .{ .bytes = buf }) catch @panic("fake sd-login: oom");
        return buf.ptr;
    }
};

/// Function pointers carry no context, so the fake state is a file-scope
/// pointer. Zig's test runner executes tests sequentially and every test
/// installs its state before calling into the monitor.
var current_fake: ?*Fake = null;

fn fake() *Fake {
    return current_fake orelse @panic("fake sd-login: ops used before installation");
}

fn errnoValue(comptime e: anytype) c_int {
    return @intFromEnum(e);
}

fn fakeMonitorNew(category: [*:0]const u8, ret: *?*Monitor) callconv(.c) c_int {
    const f = fake();
    f.record(.monitor_new);
    f.categories.append(f.allocator, std.mem.span(category)) catch @panic("fake sd-login: oom");
    if (f.monitor_rc != 0) {
        ret.* = null;
        return f.monitor_rc;
    }
    ret.* = fakeMonitor();
    return 0;
}

fn fakeMonitorUnref(m: *Monitor) callconv(.c) void {
    std.debug.assert(m == fakeMonitor());
    fake().record(.monitor_unref);
}

fn fakeMonitorFlush(m: *Monitor) callconv(.c) c_int {
    std.debug.assert(m == fakeMonitor());
    const f = fake();
    f.record(.flush);
    return f.flush_rc;
}

fn fakeMonitorGetFd(m: *Monitor) callconv(.c) c_int {
    std.debug.assert(m == fakeMonitor());
    const f = fake();
    f.record(.get_fd);
    return f.get_fd_rc;
}

fn fakeMonitorGetEvents(m: *Monitor) callconv(.c) c_int {
    std.debug.assert(m == fakeMonitor());
    const f = fake();
    f.record(.get_events);
    return f.get_events_rc;
}

fn fakeMonitorGetTimeout(m: *Monitor, ret_usec: *u64) callconv(.c) c_int {
    std.debug.assert(m == fakeMonitor());
    const f = fake();
    f.record(.get_timeout);
    ret_usec.* = f.timeout_usec;
    return f.get_timeout_rc;
}

fn fakeGetSeats(ret: *?[*:null]?[*:0]u8) callconv(.c) c_int {
    const f = fake();
    f.record(.get_seats);
    if (f.get_seats_rc != 0) {
        ret.* = null;
        return f.get_seats_rc;
    }
    if (f.null_seat_array) {
        // sd_get_seats' documented "no /run/systemd/seats" shape.
        ret.* = null;
        return 0;
    }

    const array = f.allocator.allocSentinel(?[*:0]u8, f.seats.items.len, null) catch
        return -errnoValue(std.posix.E.NOMEM);
    f.owned.append(f.allocator, .{ .array = array }) catch return -errnoValue(std.posix.E.NOMEM);
    for (f.seats.items, 0..) |spec, i| array[i] = f.dupeC(spec.name);
    ret.* = array.ptr;
    return @intCast(f.seats.items.len);
}

fn fakeSeatGetActive(seat: [*:0]const u8, ret_session: *?[*:0]u8) callconv(.c) c_int {
    const f = fake();
    f.record(.seat_get_active);
    const name = std.mem.span(seat);
    ret_session.* = null;
    for (f.seats.items) |spec| {
        if (!std.mem.eql(u8, spec.name, name)) continue;
        if (spec.err != 0) return spec.err;
        if (spec.session) |session| {
            ret_session.* = f.dupeC(session);
            return 0;
        }
        return -errnoValue(std.posix.E.NODATA);
    }
    // sd_seat_get_active on a seat without a state file.
    return -errnoValue(std.posix.E.NXIO);
}

fn fakeFree(ptr: ?*anyopaque) callconv(.c) void {
    const f = fake();
    const address = @intFromPtr(ptr orelse return);
    for (f.owned.items, 0..) |item, i| {
        const matches = switch (item) {
            .bytes => |b| @intFromPtr(b.ptr) == address,
            .array => |a| @intFromPtr(a.ptr) == address,
        };
        if (!matches) continue;
        switch (item) {
            .bytes => |b| f.allocator.free(b),
            .array => |a| f.allocator.free(a),
        }
        _ = f.owned.orderedRemove(i);
        f.freed += 1;
        return;
    }
    @panic("fake sd-login: free() of a pointer this fake did not allocate");
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn alwaysVts() bool {
    return true;
}

fn neverVts() bool {
    return false;
}

/// Install `f` and build a monitor with a kernel that has VTs.
fn setup(a: std.mem.Allocator, f: *Fake) multiseat.Error!SeatMonitor {
    current_fake = f;
    return SeatMonitor.initWithVtProbe(a, f.ops(), alwaysVts);
}

fn addedInfo(change: SeatChange) !SeatInfo {
    return switch (change) {
        .added => |s| s,
        .removed => error.ExpectedAdded,
    };
}

fn removedInfo(change: SeatChange) !SeatInfo {
    return switch (change) {
        .removed => |s| s,
        .added => error.ExpectedRemoved,
    };
}

fn expectSession(expected: ?[]const u8, info: SeatInfo) !void {
    try std.testing.expectEqualSlices(u8, expected orelse "", info.active_session orelse "");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "multiseat: init creates the seat monitor" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;

    var mon = try setup(a, &f);

    // Exactly one monitor creation, in the "seat" category, and no
    // enumeration yet: the first process reports every seat as added.
    try std.testing.expectEqualSlices(Call, &.{.monitor_new}, f.calls.items);
    try std.testing.expectEqualSlices([]const u8, &.{"seat"}, f.categories.items);
    try std.testing.expectEqual(@as(usize, 0), mon.seats().len);

    // sd-login's poll triple: one fd, POLLIN only, no deadline.
    try std.testing.expectEqual(@as(c_int, 64), try mon.fd());
    try std.testing.expectEqual(multiseat.poll_in, try mon.events());
    try std.testing.expectEqual(multiseat.infinite_timeout, try mon.timeoutUsec());

    mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.count(.monitor_unref));
    try std.testing.expectEqual(@as(usize, 0), f.owned.items.len);

    // deinit is idempotent: nothing is unref'd twice.
    mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.count(.monitor_unref));
}

test "multiseat: first process reports every seat as added" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{
        .{ .name = "seat0", .session = "1" }, // active session
        .{ .name = "seat1" }, // existing seat, nobody logged in
    });

    var mon = try setup(a, &f);
    defer mon.deinit();

    const changes = try mon.process();

    // Flush happens before the re-enumerate, and there is one
    // sd_seat_get_active per seat, in the order sd_get_seats returned.
    try std.testing.expectEqualSlices(
        Call,
        &.{ .monitor_new, .flush, .get_seats, .seat_get_active, .seat_get_active },
        f.calls.items,
    );

    try std.testing.expectEqual(@as(usize, 2), changes.len);
    const first = try addedInfo(changes[0]);
    try std.testing.expectEqualStrings("seat0", first.name);
    try expectSession("1", first);
    try std.testing.expect(first.has_vt);
    try std.testing.expect(!first.needsFakeVt());

    const second = try addedInfo(changes[1]);
    try std.testing.expectEqualStrings("seat1", second.name);
    try expectSession(null, second);
    try std.testing.expect(!second.has_vt);
    try std.testing.expect(second.needsFakeVt());

    // The stored enumeration is name-sorted and matches the changes.
    try std.testing.expectEqual(@as(usize, 2), mon.seats().len);
    try std.testing.expectEqualStrings("seat0", mon.seats()[0].name);
    try std.testing.expectEqualStrings("seat1", mon.seats()[1].name);
    try std.testing.expectEqual(@as(?SeatInfo, mon.seats()[1]), mon.seat("seat1"));
    try std.testing.expectEqual(@as(?SeatInfo, null), mon.seat("seat2"));

    // A wake-up without a visible difference changes nothing.
    f.calls.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), (try mon.process()).len);
    try std.testing.expectEqual(@as(usize, 1), f.count(.get_seats));
}

test "multiseat: seat add and remove are diffed" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{.{ .name = "seat0", .session = "1" }});

    var mon = try setup(a, &f);
    defer mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try mon.process()).len);

    // seat2 appears, seat0 stays.
    f.setSeats(&.{
        .{ .name = "seat0", .session = "1" },
        .{ .name = "seat2", .session = "7" },
    });
    const added_changes = try mon.process();
    try std.testing.expectEqual(@as(usize, 1), added_changes.len);
    const fresh = try addedInfo(added_changes[0]);
    try std.testing.expectEqualStrings("seat2", fresh.name);
    try expectSession("7", fresh);

    // seat0 disappears; its active session is part of the removal event
    // and stays readable after process returns.
    f.setSeats(&.{.{ .name = "seat2", .session = "7" }});
    const removed_changes = try mon.process();
    try std.testing.expectEqual(@as(usize, 1), removed_changes.len);
    const gone = try removedInfo(removed_changes[0]);
    try std.testing.expectEqualStrings("seat0", gone.name);
    try expectSession("1", gone);

    try std.testing.expectEqual(@as(usize, 1), mon.seats().len);
    try std.testing.expectEqual(@as(?SeatInfo, null), mon.seat("seat0"));

    // The removal strings live until the next process; that call also
    // releases them (the leak check proves it).
    try std.testing.expectEqual(@as(usize, 0), (try mon.process()).len);
    try std.testing.expectEqual(@as(usize, 1), mon.seats().len);
}

test "multiseat: active session is read, -ENXIO/-ENODATA mean idle" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{
        .{ .name = "seat0", .session = "2" },
        .{ .name = "seat1", .err = -errnoValue(std.posix.E.NODATA) },
        .{ .name = "seat2", .err = -errnoValue(std.posix.E.NXIO) },
        // Any other error is also "idle", but recorded in last_errno.
        .{ .name = "seat3", .err = -errnoValue(std.posix.E.IO) },
    });

    var mon = try setup(a, &f);
    defer mon.deinit();
    _ = try mon.process();

    try expectSession("2", mon.seat("seat0").?);
    try expectSession(null, mon.seat("seat1").?);
    try expectSession(null, mon.seat("seat2").?);
    try expectSession(null, mon.seat("seat3").?);

    // -ENXIO/-ENODATA are expected, not failures; -EIO is kept for logging.
    try std.testing.expectEqual(-errnoValue(std.posix.E.IO), mon.last_errno);
}

test "multiseat: session change updates the seat without an add/remove event" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{.{ .name = "seat0", .session = "1" }});

    var mon = try setup(a, &f);
    defer mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try mon.process()).len);
    try expectSession("1", mon.seat("seat0").?);

    // Same seat, new active session: the worker must not be restarted.
    f.setSeats(&.{.{ .name = "seat0", .session = "2" }});
    try std.testing.expectEqual(@as(usize, 0), (try mon.process()).len);
    try expectSession("2", mon.seat("seat0").?);

    // ... and back to no session.
    f.setSeats(&.{.{ .name = "seat0" }});
    try std.testing.expectEqual(@as(usize, 0), (try mon.process()).len);
    try expectSession(null, mon.seat("seat0").?);
}

test "multiseat: has_vt is seat0-only and gated on kernel VTs" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{
        .{ .name = "seat0" },
        .{ .name = "seat1" },
        .{ .name = "seat10" }, // string compare, not a numeric suffix
    });
    current_fake = &f;

    // Kernel VTs present: seat0 can use the real VT, others cannot.
    var with_vts = try SeatMonitor.initWithVtProbe(a, f.ops(), alwaysVts);
    defer with_vts.deinit();
    _ = try with_vts.process();
    try std.testing.expect(with_vts.seat("seat0").?.has_vt);
    try std.testing.expect(!with_vts.seat("seat1").?.has_vt);
    try std.testing.expect(!with_vts.seat("seat10").?.has_vt);
    try std.testing.expect(with_vts.seat("seat1").?.needsFakeVt());

    // CONFIG_VT=n: not even seat0 has a VT, so every seat needs FakeVt.
    var without_vts = try SeatMonitor.initWithVtProbe(a, f.ops(), neverVts);
    defer without_vts.deinit();
    _ = try without_vts.process();
    try std.testing.expect(!without_vts.seat("seat0").?.has_vt);
    try std.testing.expect(without_vts.seat("seat0").?.needsFakeVt());
    try std.testing.expect(!without_vts.seat("seat1").?.has_vt);

    // The name predicate itself.
    try std.testing.expect(multiseat.hasVt("seat0"));
    try std.testing.expect(!multiseat.hasVt("seat1"));
    try std.testing.expect(!multiseat.hasVt(""));
}

test "multiseat: deinit releases the monitor and every seat string" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{
        .{ .name = "seat0", .session = "1" },
        .{ .name = "seat1", .session = "42" },
    });

    var mon = try setup(a, &f);
    _ = try mon.process();

    // The fake's own allocations (array + one name per seat) all went back
    // through the fake `free`; what remains is the monitor's private copies.
    try std.testing.expect(f.freed > 0);
    try std.testing.expectEqual(@as(usize, 0), f.owned.items.len);

    const freed = f.freed;
    mon.deinit();

    // The monitor's own strings are checked by the testing allocator: the
    // test leaks if `deinit` missed one.
    try std.testing.expectEqual(@as(usize, 0), f.owned.items.len);
    try std.testing.expectEqual(freed, f.freed);
    try std.testing.expectEqual(@as(usize, 1), f.count(.monitor_unref));

    // A deinit'd monitor is inert, and a second deinit is harmless.
    mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.count(.monitor_unref));
    try std.testing.expectEqual(@as(usize, 0), mon.seats().len);
    try std.testing.expectError(error.MonitorUnavailable, mon.fd());
    try std.testing.expectError(error.MonitorUnavailable, mon.process());
}

test "multiseat: empty seat set is not an error and removes everything" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{.{ .name = "seat0", .session = "1" }});

    var mon = try setup(a, &f);
    defer mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try mon.process()).len);

    // No /run/systemd/seats at all: count 0, NULL array.
    f.null_seat_array = true;
    const changes = try mon.process();
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("seat0", (try removedInfo(changes[0])).name);
    try std.testing.expectEqual(@as(usize, 0), mon.seats().len);

    // An empty array (0 seats, non-NULL) behaves the same.
    f.null_seat_array = false;
    f.setSeats(&.{});
    try std.testing.expectEqual(@as(usize, 0), (try mon.process()).len);
    try std.testing.expectEqual(@as(usize, 0), mon.seats().len);
}

test "multiseat: sd-login failures propagate and keep the previous set" {
    const a = std.testing.allocator;
    var f = Fake.init(a);
    defer f.deinit();
    current_fake = &f;
    f.setSeats(&.{.{ .name = "seat0", .session = "1" }});

    // Monitor creation failure (no logind seat state).
    f.monitor_rc = -errnoValue(std.posix.E.NOENT);
    try std.testing.expectError(
        error.MonitorCreateFailed,
        SeatMonitor.initWithVtProbe(a, f.ops(), alwaysVts),
    );
    f.monitor_rc = 0;

    var mon = try setup(a, &f);
    defer mon.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try mon.process()).len);

    // Flush failure: no re-enumeration, previous state intact.
    f.calls.clearRetainingCapacity();
    f.flush_rc = -errnoValue(std.posix.E.IO);
    try std.testing.expectError(error.FlushFailed, mon.process());
    try std.testing.expectEqual(@as(usize, 0), f.count(.get_seats));
    try std.testing.expectEqualStrings("seat0", mon.seats()[0].name);
    try std.testing.expectEqual(-errnoValue(std.posix.E.IO), mon.last_errno);

    // Enumeration failure: previous state intact again.
    f.flush_rc = 0;
    f.get_seats_rc = -errnoValue(std.posix.E.NOMEM);
    try std.testing.expectError(error.EnumerateFailed, mon.process());
    try std.testing.expectEqualStrings("seat0", mon.seats()[0].name);
    try std.testing.expectEqual(-errnoValue(std.posix.E.NOMEM), mon.last_errno);
    f.get_seats_rc = 0;

    // fd/events/timeout failures.
    f.get_fd_rc = -errnoValue(std.posix.E.BADF);
    try std.testing.expectError(error.MonitorGetFdFailed, mon.fd());
    f.get_events_rc = -errnoValue(std.posix.E.IO);
    try std.testing.expectError(error.MonitorGetEventsFailed, mon.events());
    f.get_timeout_rc = -errnoValue(std.posix.E.IO);
    try std.testing.expectError(error.MonitorGetTimeoutFailed, mon.timeoutUsec());

    // Recovery: the monitor still works after all of that.
    f.get_fd_rc = 9;
    try std.testing.expectEqual(@as(c_int, 9), try mon.fd());
}

test "multiseat: seatConfigName matches config.loadSeat naming" {
    const a = std.testing.allocator;

    const seat0 = try multiseat.seatConfigName(a, "seat0");
    defer a.free(seat0);
    try std.testing.expectEqualStrings("seat0.seat.conf", seat0);

    const seat12 = try multiseat.seatConfigName(a, "seat12");
    defer a.free(seat12);
    try std.testing.expectEqualStrings("seat12.seat.conf", seat12);
}