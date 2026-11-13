//! src/seat/libseat.zig -- libseat 0.9.3 seat backend (ROADMAP M6.1).
//!
//! Thin, typed wrapper over `<libseat.h>` implementing the `Seat` vtable
//! from `src/seat.zig`. The C surface below is the output of translate-c
//! over libseat 0.9.3 (seatd 0.9.3, nixpkgs `seatd.dev`):
//!
//!     zig translate-c -I <seatd-dev>/include libseat_shim.c
//!
//! with `libseat_shim.c` containing only `#include <libseat.h>`. The
//! declarations below are typed to match that output (same ABI), with one
//! deliberate narrowing: pointers libseat documents as mandatory (the
//! listener, its two members, the seat handle) are non-optional in Zig, so
//! the happy path needs no unwrapping. Nullable C pointers (`void
//! *userdata`, the out-fd) stay optional. Using embedded declarations
//! instead of `@cImport` means this module compiles and its tests run with
//! `zig test src/test_libseat.zig` alone: no `-I`, no `-lseat`, no running
//! seat daemon. `LibseatOps.real` is the only declaration that references
//! the C symbols, and Zig analyzes it lazily -- the hermetic tests never
//! touch it.
//!
//! All libseat calls are reached through the `LibseatOps` function-pointer
//! seam, so tests substitute a fake backend and assert the protocol ordering
//! without a seatd socket or logind session.
//!
//! # Backend selection
//!
//! libseat reads `LIBSEAT_BACKEND` with `getenv` at `libseat_open_seat`
//! time; the value must be one of `seatd`, `logind`, `builtin`, `noop`
//! exactly (`libseat/libseat.c:45-53`). Without it the order is seatd ->
//! logind -> builtin, and `noop` is *never* auto-selected. Selection cannot
//! be changed after the seat is open.
//!
//! For tests and daemon-less development use the noop backend:
//!
//!     LIBSEAT_BACKEND=noop zig build run
//!
//! noop needs no socket and no privileges: `seat_name()` is `"seat0"`,
//! `open_device()` is a plain `open(path, O_RDWR|O_NOCTTY|O_NOFOLLOW|
//! O_CLOEXEC|O_NONBLOCK)`, `device_id` is the fd, `close_device()` does
//! nothing, `disable_seat()` does nothing, and `dispatch()` calls
//! `enable_seat` once on its first invocation (`libseat/backend/noop.c`).
//! It is reachable only explicitly: an unknown `LIBSEAT_BACKEND` value is a
//! hard `EINVAL` error, not a fallback.
//!
//! # Protocol implemented here (libseat 0.9.3)
//!
//! `enable_seat` means "the seat is yours again; existing fds may have been
//! blocked or revoked". We set `active = true` and fire the `activated`
//! user callback. Device re-opening is the owner's job: every device we
//! tracked was closed on disable, so the owner calls `openDevice` again.
//!
//! `disable_seat` means "you are about to lose the seat, and the event must
//! be acknowledged with `libseat_disable_seat`". In one synchronous
//! callback we:
//!
//!   1. close every tracked device: `libseat_close_device(id)` then
//!      `close(fd)`. The fd close is mandatory even when the id close
//!      fails: `EVIOCREVOKE` kills the file description permanently and
//!      seatd cannot re-activate evdev/hidraw. Doing both also releases the
//!      server refcount (otherwise the seatd entry leaks until exit).
//!   2. set `active = false` (`isActive()` now false);
//!   3. fire the user `deactivated` callback;
//!   4. acknowledge with `libseat_disable_seat`.
//!
//! The ack is a blocking round trip on seatd (`SERVER_SEAT_DISABLED` is
//! awaited) and a no-op returning 0 on logind; both are success. A second
//! `disable_seat` event before the next `enable_seat` is ignored: the
//! devices are already gone and the obligation was already met.
//!
//! The first `enable_seat` arrives on the *next* `libseat_dispatch` after
//! `libseat_open_seat` on seatd (the server writes `SERVER_SEAT_OPENED`
//! before `SERVER_ENABLE_SEAT`, and libseat stops reading at the former),
//! and on the first dispatch ever on logind. `init` therefore drains once
//! with `dispatch(0)` before returning, exactly like kmscon's
//! `vt_libseat.c:226-233`.
//!
//! # Event-loop integration
//!
//! `libseat_get_fd` exists in 0.9.3 (`libseat.h:127`; confirmed in the
//! installed header) and returns a pollable fd that is stable after
//! `libseat_open_seat` for both seatd and logind. `seatFd()` exposes it:
//! register it `EPOLLIN` and call `dispatch(0)` when it is readable.
//! `dispatch(-1)` blocks, `dispatch(0)` never blocks.
//!
//! seatd sends a `CLIENT_PING` when a background event becomes pending
//! during a blocking request; it is there only to wake the app's poll, and
//! the following `dispatch` can legitimately return 0. Keep the fd
//! registered and tolerate 0.
//!
//! Re-entrancy: libseat can deliver `enable_seat`/`disable_seat`
//! synchronously from inside `dispatch`. A callback that calls `dispatch`
//! again gets 0 back (the outer dispatch is still executing and owns the
//! event queue), and user callbacks are delivered through
//! `seat.CallbackGuard` so a callback cannot recurse into another callback.
//! libseat's blocking requests (`open_device`, `close_device`,
//! `disable_seat`) only *queue* pending events, they never execute them, so
//! the ack path cannot re-enter itself.
//!
//! # Device ids
//!
//! NEVER assume `device_id == fd`. On seatd/builtin the id is an opaque
//! server-allocated number sent alongside the fd over `SCM_RIGHTS`; the fd
//! is a dup. On logind the id *is* the fd the backend dup'ed from
//! `TakeDevice`. Both are stored in `Device`; `libseat_close_device` gets
//! the id, `close(2)` gets the fd.
//!
//! Module path: this file imports `../seat.zig`, so its module root must be
//! `src/` (`zig test src/test_libseat.zig`), not `src/seat/`.

const std = @import("std");
const builtin = @import("builtin");
const seat_contract = @import("../seat.zig");

/// `struct libseat;` -- opaque instance owned by libseat.
pub const Libseat = opaque {};

/// `struct libseat_seat_listener` (`libseat.h:15-36`). `extern struct`:
/// two C function pointers, no padding. Both members are mandatory; libseat
/// rejects a NULL listener or member with `EINVAL`. The instance stores the
/// listener by pointer for the whole seat lifetime, so it lives in
/// `LibseatSeat` (heap-allocated, stable address).
pub const SeatListener = extern struct {
    /// "The seat has been enabled, and is now valid for use. Re-open all
    /// seat devices ... existing fds may have had their functionality
    /// blocked or revoked."
    enable_seat: *const fn (libseat_ptr: ?*Libseat, userdata: ?*anyopaque) callconv(.c) void,
    /// "The seat has been disabled ... must be acknowledged with
    /// libseat_disable_seat shortly after receiving this event."
    disable_seat: *const fn (libseat_ptr: ?*Libseat, userdata: ?*anyopaque) callconv(.c) void,
};

// ---------------------------------------------------------------------------
// translate-c surface (libseat 0.9.3)
// ---------------------------------------------------------------------------

extern fn libseat_open_seat(listener: *const SeatListener, userdata: ?*anyopaque) ?*Libseat;
extern fn libseat_disable_seat(libseat_ptr: *Libseat) c_int;
extern fn libseat_close_seat(libseat_ptr: *Libseat) c_int;
extern fn libseat_open_device(libseat_ptr: *Libseat, path: [*:0]const u8, fd: *c_int) c_int;
extern fn libseat_close_device(libseat_ptr: *Libseat, device_id: c_int) c_int;
extern fn libseat_get_fd(libseat_ptr: *Libseat) c_int;
extern fn libseat_dispatch(libseat_ptr: *Libseat, timeout: c_int) c_int;

/// Injectable seam over every C call the backend makes. Tests install a
/// fake implementation; production uses `LibseatOps.real`.
///
/// Signatures follow the libseat 0.9.3 prototypes, including the `-1 +
/// errno` return convention; pointers libseat requires to be non-NULL are
/// non-optional. `close_fd` is the second half of the two-step device close
/// (`libseat_close_device` + `close(fd)`) and is a seam only so tests can
/// observe it without touching real descriptors.
pub const LibseatOps = struct {
    open_seat: *const fn (listener: *const SeatListener, userdata: ?*anyopaque) callconv(.c) ?*Libseat,
    close_seat: *const fn (libseat_ptr: *Libseat) callconv(.c) c_int,
    disable_seat: *const fn (libseat_ptr: *Libseat) callconv(.c) c_int,
    open_device: *const fn (libseat_ptr: *Libseat, path: [*:0]const u8, fd: *c_int) callconv(.c) c_int,
    close_device: *const fn (libseat_ptr: *Libseat, device_id: c_int) callconv(.c) c_int,
    get_fd: *const fn (libseat_ptr: *Libseat) callconv(.c) c_int,
    dispatch: *const fn (libseat_ptr: *Libseat, timeout: c_int) callconv(.c) c_int,
    close_fd: *const fn (fd: c_int) callconv(.c) void,

    /// The real libseat backend. Linking this (directly or transitively)
    /// requires `-lseat`; the hermetic tests never reference it.
    pub const real: LibseatOps = .{
        .open_seat = libseat_open_seat,
        .close_seat = libseat_close_seat,
        .disable_seat = libseat_disable_seat,
        .open_device = libseat_open_device,
        .close_device = libseat_close_device,
        .get_fd = libseat_get_fd,
        .dispatch = libseat_dispatch,
        .close_fd = closeFdReal,
    };

    fn closeFdReal(fd: c_int) callconv(.c) void {
        // Zig 0.17 removed std.posix.close (fds moved to std.Io.File).
        // kmshaunt is Linux-only; the raw syscall releases the fd even on
        // EINTR, so the result needs no retry handling.
        _ = std.os.linux.close(fd);
    }
};

/// Errors returned by the Zig wrapper. libseat itself reports `-1` with
/// `errno`; the wrapper maps that to a tag and keeps the raw errno in
/// `last_errno` (only readable when linking libc, see `captureErrno`).
pub const Error = error{
    OutOfMemory,
    /// `deinit` was already called (no libseat handle).
    SeatClosed,
    /// A seat request was made while the seat is disabled. libseat would
    /// fail it too; failing locally keeps the state machine honest.
    SeatNotEnabled,
    /// `libseat_open_seat` returned NULL (unknown `LIBSEAT_BACKEND`, no
    /// backend available, `EBUSY` while another client is mid-disable, ...).
    OpenSeatFailed,
    /// `libseat_dispatch` returned -1.
    DispatchFailed,
    /// `libseat_open_device` returned -1.
    OpenDeviceFailed,
    /// `libseat_close_device` returned -1. The fd was still closed.
    CloseDeviceFailed,
    /// The device id is not in the tracked table.
    UnknownDevice,
    /// libseat offers no way to *request* a seat handoff; the provider
    /// issues `disable_seat`. See `deactivate`.
    NotSupported,
};

/// One device returned by `openDevice` and tracked until `closeDevice` or
/// the disable/deinit path.
pub const Device = struct {
    /// Owned copy of the caller's path, NUL-terminated for libseat.
    path: [:0]u8,
    /// The descriptor the caller may use; closed by the seat on disable.
    fd: c_int,
    /// Opaque libseat id, NOT the fd (they are equal only on logind/noop).
    id: c_int,
};

/// The pair handed to the owner by `openDevice`. The seat owns `fd`:
/// `closeDevice` or the disable/deinit path closes it. After a
/// `disable_seat` both values are stale (they are never reused).
pub const OpenedDevice = struct {
    fd: c_int,
    device_id: c_int,
};

/// The libseat-backed seat. Heap-allocated by `init` because the C listener
/// stores `self` as its userdata and a copy would dangle.
pub const LibseatSeat = struct {
    allocator: std.mem.Allocator,
    ops: LibseatOps,
    handle: ?*Libseat = null,
    listener: SeatListener = undefined,
    callbacks: seat_contract.Seat.Callbacks = .{},
    userdata: usize = 0,
    guard: seat_contract.CallbackGuard = .{},
    devices: std.ArrayListUnmanaged(Device) = .empty,
    /// Mirrors the seat provider's enable/disable state; also what
    /// `Seat.isActive` reports.
    active: bool = false,
    /// True when an enable arrived before the owner installed an
    /// `activated` callback (typically during `init`'s drain). The first
    /// `setCallbacks`/`activate` that sees the callback delivers it, so
    /// the initial enable is never lost.
    activation_pending: bool = false,
    paused: bool = false,
    /// True while an outer `ops.dispatch` is on the stack; nested dispatches
    /// return 0 instead of re-entering libseat's event queue.
    dispatching: bool = false,
    closed: bool = false,
    /// Raw C errno of the last failed call. libseat writes the C `errno`, so
    /// this is only meaningful when the process links libc (as it must to use
    /// libseat); without libc the field stays 0.
    last_errno: i32 = 0,
    /// Failed `libseat_close_device` calls across disable/deinit/closeDevice.
    close_failures: usize = 0,
    /// Failed `libseat_disable_seat` acknowledgements.
    disable_failures: usize = 0,
    /// Successful (attempted) acks; each disable event acks exactly once.
    ack_count: usize = 0,

    /// Open the seat through `ops`, install the listener and drain the
    /// queued `enable_seat`.
    ///
    /// The returned pointer owns the libseat handle; release it with
    /// `deinit`. `LIBSEAT_BACKEND` is read by libseat here (see the file
    /// header; use `noop` for daemon-less tests).
    ///
    /// The post-open `dispatch(0)` is required, not cosmetic: on seatd the
    /// server sends `SERVER_ENABLE_SEAT` right after the
    /// `SERVER_SEAT_OPENED` reply that libseat stops reading at, so the
    /// event is only delivered by the next dispatch. On logind it is the
    /// first dispatch that reports `Active=true/false`.
    pub fn init(allocator: std.mem.Allocator, ops: LibseatOps) Error!*LibseatSeat {
        const self = try allocator.create(LibseatSeat);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ops = ops };
        self.listener = .{
            .enable_seat = onEnableSeat,
            .disable_seat = onDisableSeat,
        };

        const handle = ops.open_seat(&self.listener, self) orelse return error.OpenSeatFailed;
        self.handle = handle;
        errdefer {
            _ = ops.close_seat(handle);
            self.handle = null;
        }

        _ = try self.dispatch(0);
        return self;
    }

    /// Close every tracked device, close the libseat seat and free the
    /// instance. Safe to call only when no callback is on the stack.
    pub fn deinit(self: *LibseatSeat) void {
        self.closed = true;
        self.closeAllDevices();
        if (self.handle) |handle| {
            if (self.ops.close_seat(handle) < 0) self.captureErrno();
            self.handle = null;
        }
        self.active = false;
        self.devices.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// The `seat_contract.Seat` view of this backend.
    pub fn seat(self: *LibseatSeat) seat_contract.Seat {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Borrowed libseat handle, null after `deinit`.
    pub fn handleOf(self: *LibseatSeat) ?*Libseat {
        return self.handle;
    }

    pub fn isActive(self: *LibseatSeat) bool {
        return self.active;
    }

    pub fn isPaused(self: *LibseatSeat) bool {
        return self.paused;
    }

    /// Number of tracked devices (all closed by disable/deinit).
    pub fn deviceCount(self: *LibseatSeat) usize {
        return self.devices.items.len;
    }

    /// Pollable libseat fd for the event loop, or null when `get_fd` fails.
    /// Stable after open for both seatd and logind; register it `EPOLLIN`
    /// and call `dispatch(0)` when readable.
    pub fn seatFd(self: *LibseatSeat) ?c_int {
        const handle = self.handle orelse return null;
        const fd = self.ops.get_fd(handle);
        if (fd < 0) {
            self.captureErrno();
            return null;
        }
        return fd;
    }

    /// `libseat_dispatch` wrapper. `timeout_ms`: 0 never blocks, -1 may
    /// block indefinitely, >0 is the maximum wait in milliseconds.
    /// Returns the number of processed internal messages (>= 0).
    ///
    /// A wake-up caused by `CLIENT_PING` can yield 0: the ping exists only
    /// to make poll return when a background event is queued during a
    /// blocking request, so callers must not treat 0 as an error.
    ///
    /// Nested calls (from inside a listener callback) return 0 without
    /// touching libseat: the outer dispatch still owns its event queue.
    pub fn dispatch(self: *LibseatSeat, timeout_ms: c_int) Error!usize {
        const handle = self.handle orelse return error.SeatClosed;
        if (self.dispatching) return 0;
        self.dispatching = true;
        defer self.dispatching = false;

        const rc = self.ops.dispatch(handle, timeout_ms);
        if (rc < 0) {
            self.captureErrno();
            return error.DispatchFailed;
        }
        return @intCast(rc);
    }

    /// Take the console. libseat is provider-driven: activation happens
    /// when the seat provider delivers `enable_seat`, not on request. This
    /// pumps pending events once (so a queued enable is delivered) and is
    /// otherwise a no-op.
    pub fn activate(self: *LibseatSeat) Error!void {
        _ = try self.dispatch(0);
        self.flushActivation();
    }

    /// Voluntary hand-off is not part of libseat 0.9.3: only the provider
    /// can initiate it, by sending `disable_seat` (which is acked by
    /// `onDisableSeat`). Returning the seat means closing it (`deinit`) or
    /// switching VT (`libseat_switch_session`). No-op when already
    /// inactive; `error.NotSupported` otherwise so callers do not believe a
    /// hand-off happened.
    pub fn deactivate(self: *LibseatSeat) Error!void {
        _ = self.handle orelse return error.SeatClosed;
        if (!self.active) return;
        return error.NotSupported;
    }

    /// Device-level pause: fire the `pause` user callback so the owner
    /// closes/stops using its device fds. libseat 0.9.3's listener has only
    /// enable/disable (logind's `PauseDevice` is handled inside libseat),
    /// so this does not call into libseat. Idempotent.
    pub fn pause(self: *LibseatSeat) Error!void {
        _ = self.handle orelse return error.SeatClosed;
        if (self.paused) return;
        self.paused = true;
        self.guard.dispatch(self.callbacks.pause, self.userdata);
    }

    /// Counterpart of `pause`: fire the `resume_` user callback. Idempotent.
    pub fn resume_(self: *LibseatSeat) Error!void {
        _ = self.handle orelse return error.SeatClosed;
        if (!self.paused) return;
        self.paused = false;
        self.guard.dispatch(self.callbacks.resume_, self.userdata);
    }

    /// Install callbacks (copied; see `seat_contract.Seat.Callbacks`). If the seat
    /// was already enabled before any `activated` callback existed --
    /// typical when `init`'s post-open drain delivers the seatd enable --
    /// the callback is delivered here so the owner cannot miss the initial
    /// activation. Re-installing callbacks does not re-fire it.
    pub fn setCallbacks(self: *LibseatSeat, callbacks: *const seat_contract.Seat.Callbacks, userdata: usize) void {
        self.callbacks = callbacks.*;
        self.userdata = userdata;
        self.flushActivation();
    }

    /// Open a seat device (`libseat_open_device`) while the seat is
    /// enabled, and track it for the disable path.
    ///
    /// The seat layer only permits devices the backend permits (evdev, DRM,
    /// hidraw, wscons for seatd). `device_id` is NOT necessarily the fd;
    /// see the file header.
    pub fn openDevice(self: *LibseatSeat, path: []const u8) Error!OpenedDevice {
        const handle = try self.requireEnabled();

        const path_z = try self.allocator.allocSentinel(u8, path.len, 0);
        errdefer self.allocator.free(path_z);
        @memcpy(path_z, path);

        var fd: c_int = -1;
        const rc = self.ops.open_device(handle, path_z, &fd);
        if (rc < 0) {
            self.captureErrno();
            return error.OpenDeviceFailed;
        }

        self.devices.append(self.allocator, .{ .path = path_z, .fd = fd, .id = rc }) catch |err| {
            // Roll the seat-side refcount back before unwinding.
            if (self.ops.close_device(handle, rc) < 0) self.captureErrno();
            self.ops.close_fd(fd);
            return err;
        };
        return .{ .fd = fd, .device_id = rc };
    }

    /// Close one tracked device: `libseat_close_device(id)` followed by
    /// `close(fd)`. The fd is closed even if libseat reports an error (of
    /// which `close_failures` keeps the count), because revoking a
    /// file description is irreversible and the fd must not leak.
    pub fn closeDevice(self: *LibseatSeat, device_id: c_int) Error!void {
        const handle = try self.requireEnabled();
        const index = self.findDevice(device_id) orelse return error.UnknownDevice;
        const device = self.devices.orderedRemove(index);

        var failed = false;
        if (self.ops.close_device(handle, device.id) < 0) {
            self.captureErrno();
            self.close_failures += 1;
            failed = true;
        }
        self.ops.close_fd(device.fd);
        self.allocator.free(device.path);

        if (failed) return error.CloseDeviceFailed;
    }

    fn requireEnabled(self: *LibseatSeat) Error!*Libseat {
        if (self.closed) return error.SeatClosed;
        const handle = self.handle orelse return error.SeatClosed;
        if (!self.active) return error.SeatNotEnabled;
        return handle;
    }

    fn findDevice(self: *LibseatSeat, device_id: c_int) ?usize {
        for (self.devices.items, 0..) |device, i| {
            if (device.id == device_id) return i;
        }
        return null;
    }

    /// Close every tracked device in reverse open order, ignoring the
    /// enabled gate: this is the teardown path used by `disable_seat` and
    /// `deinit`, where libseat may already consider the seat unusable.
    fn closeAllDevices(self: *LibseatSeat) void {
        const handle = self.handle orelse {
            // No libseat handle can only happen for an empty table.
            std.debug.assert(self.devices.items.len == 0);
            return;
        };
        while (self.devices.pop()) |device| {
            if (self.ops.close_device(handle, device.id) < 0) {
                self.captureErrno();
                self.close_failures += 1;
            }
            self.ops.close_fd(device.fd);
            self.allocator.free(device.path);
        }
    }

    fn captureErrno(self: *LibseatSeat) void {
        // libseat sets the C errno; std.posix.errno() cannot be used because
        // without libc it interprets a raw -1 as a syscall errno instead.
        self.last_errno = if (builtin.link_libc) std.c._errno().* else 0;
    }

    // -- listener trampolines ------------------------------------------------

    fn castUserdata(userdata: ?*anyopaque) ?*LibseatSeat {
        const ptr = userdata orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn onEnableSeat(libseat_ptr: ?*Libseat, userdata: ?*anyopaque) callconv(.c) void {
        _ = libseat_ptr;
        const self = castUserdata(userdata) orelse return;
        self.handleEnable();
    }

    fn onDisableSeat(libseat_ptr: ?*Libseat, userdata: ?*anyopaque) callconv(.c) void {
        _ = libseat_ptr;
        const self = castUserdata(userdata) orelse return;
        self.handleDisable();
    }

    fn handleEnable(self: *LibseatSeat) void {
        if (self.closed or self.active) return;
        self.active = true;
        self.paused = false;
        self.activation_pending = true;
        self.flushActivation();
    }

    /// Deliver a queued activation once an `activated` callback exists.
    /// State (`active`) is already true; only notification is deferred.
    fn flushActivation(self: *LibseatSeat) void {
        if (!self.active or !self.activation_pending) return;
        const callback = self.callbacks.activated orelse return;
        if (!self.guard.enter()) return;
        self.activation_pending = false;
        defer self.guard.leave();
        callback(self.userdata);
    }

    fn handleDisable(self: *LibseatSeat) void {
        // Already disabled: the devices were closed and the event acked by
        // the first delivery. Nothing to do (double-disable safe).
        if (self.closed or !self.active) return;

        // 1. Stop using the seat. EVIOCREVOKE is irreversible: both the
        //    libseat id and the fd must go.
        self.closeAllDevices();
        // 2. isActive() == false from here on.
        self.active = false;
        self.paused = false;
        // 3. Tell the owner it lost the console (before the ack, so the
        //    owner has stopped touching devices when the provider proceeds).
        self.guard.dispatch(self.callbacks.deactivated, self.userdata);
        // 4. Acknowledge: blocking round trip on seatd, no-op on logind.
        if (self.handle) |handle| {
            self.ack_count += 1;
            if (self.ops.disable_seat(handle) < 0) {
                self.captureErrno();
                self.disable_failures += 1;
            }
        }
    }

    // -- vtable --------------------------------------------------------------

    const vtable = seat_contract.Seat.VTable{
        .deinit = vtDeinit,
        .activate = vtActivate,
        .deactivate = vtDeactivate,
        .isActive = vtIsActive,
        .pause = vtPause,
        .resume_ = vtResume,
        .setCallbacks = vtSetCallbacks,
    };

    fn cast(ptr: *anyopaque) *LibseatSeat {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn vtActivate(ptr: *anyopaque) anyerror!void {
        return cast(ptr).activate();
    }

    fn vtDeactivate(ptr: *anyopaque) anyerror!void {
        return cast(ptr).deactivate();
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).isActive();
    }

    fn vtPause(ptr: *anyopaque) anyerror!void {
        return cast(ptr).pause();
    }

    fn vtResume(ptr: *anyopaque) anyerror!void {
        return cast(ptr).resume_();
    }

    fn vtSetCallbacks(ptr: *anyopaque, callbacks: *const seat_contract.Seat.Callbacks, userdata: usize) void {
        cast(ptr).setCallbacks(callbacks, userdata);
    }
};