//! src/seat/multiseat.zig -- sd-login seat enumeration, monitor and diff
//! (ROADMAP M6.2, docs/reference/libseat-sdlogin.md §4 and §6).
//!
//! The `kmshaunt.service` daemon supervises one kmshaunt process per seat
//! (kmscon's model: "one process = one seat", reference §6.1). This module is
//! the daemon's eyes on the seat list: it enumerates the seats logind knows
//! about with `sd_get_seats`, asks each seat for its active session with
//! `sd_seat_get_active`, and wakes the event loop when the seat set may have
//! changed through an `sd_login_monitor` watching the `"seat"` category.
//!
//! It does NOT spawn, configure or talk to the per-seat instances. It only
//! reports:
//!
//!   * which seats exist (`SeatMonitor.seats()`),
//!   * which session is active on each (`SeatInfo.active_session`),
//!   * whether the seat can be driven by the real VT backend
//!     (`SeatInfo.has_vt`; `false` means "needs `src/seat/vt_fake.zig`"),
//!   * what appeared or disappeared since the previous `process`
//!     (`SeatChange`).
//!
//! # sd-login facts this module rests on (systemd 262)
//!
//! * `sd_get_seats()` returns the seat **count** or a negative errno; a
//!   missing `/run/systemd/seats` is *not* an error, it returns 0 and sets
//!   the out-array to `NULL` (`libsystemd/sd-login/sd-login.c:988-1010`).
//!   Both the array and every string in it are libc-malloc'd and
//!   `NULL`-terminated (`sd-login.h:22-35`), so they are released with
//!   `free(3)` -- reached through `SdLoginOps.free`.
//! * `sd_seat_get_active()` returns `-ENXIO` when the seat has no state file
//!   and `-ENODATA` when it has one but no active session
//!   (`sd-login.c:854-886`). Both mean "no active session", never an error.
//! * `sd_login_monitor_new("seat")` is an inotify watch on
//!   `/run/systemd/seats/` for `IN_MOVED_TO|IN_DELETE`
//!   (`sd-login.c:1183-1218`). logind writes seat state with an atomic
//!   replace, so the watch fires both when a seat appears/disappears and
//!   when its active session changes.
//!
//! # The monitor is coarse: every wake-up is a full re-enumerate
//!
//! The monitor tells us *that* something under `/run/systemd/seats` moved,
//! never *what*. `sd_login_monitor_get_events()` is always `POLLIN` and
//! `sd_login_monitor_get_timeout()` is always `UINT64_MAX`
//! (`sd-login.c:1246-1267`): there is no timer to integrate, and there is
//! no delta to consume. `process()` therefore
//!
//!   1. `sd_login_monitor_flush` -- mandatory, or epoll stays hot on the
//!      inotify fd (`sd-login.c:1227-1236`),
//!   2. `sd_get_seats` once,
//!   3. `sd_seat_get_active` once per seat,
//!   4. sorts the result by name (the kernel's `getdents` order is not
//!      stable, so the API must not leak it),
//!   5. diffs it against the previous enumeration by seat name.
//!
//! A wake-up with no visible difference is normal (logind rewrites seat
//! files on session churn) and yields an empty change list. The cost is a
//! directory read plus one small file read per seat, which is why the
//! reference explicitly endorses this shape (§4.4).
//!
//! # `has_vt`: which seats need the fake VT
//!
//! VTs are a seat0 concept and a `CONFIG_VT` feature (`vt_fake.c:26-49`,
//! reference §6.7):
//!
//! 1. Without `CONFIG_VT` the kernel has no `/dev/ttyN`, no `VT_*` and no
//!    `KD*` ioctl family at all, so the real VT backend cannot open
//!    anything -- not even on seat0.
//! 2. A non-seat0 seat has no VTs by definition: a second seat (USB GPU +
//!    keyboard) has no `/dev/ttyN` bound to it, and seatd only ever serves
//!    seat0 anyway (`seatd/server.c:42-45`).
//!
//! `SeatInfo.has_vt` is therefore
//!
//!     has_vt = kernel provides VTs  &&  seat is "seat0"
//!
//! The kernel half is probed once, at `init`: `/dev/tty0` must exist
//! (`faccessat(F_OK)`, no permission needed). That is exactly the node the
//! real VT backend opens, so the probe answers the question the daemon
//! actually asks: "can the real-VT path work on this machine at all?".
//! A `false` result on either half means: construct `FakeVt`
//! (`src/seat/vt_fake.zig`) instead of `src/seat/vt_real.zig` -- start it
//! active and never switch it (kmscon's own recommendation,
//! `vt_fake.c:39-41`).
//!
//! # Per-seat configuration file
//!
//! `config.loadSeat` layers `<configdir>/<seat>.seat.conf` over the main
//! config (kmscon `kmscon_conf_load_seat`, `config.c:1167-1185`).
//! `seatConfigName` produces the same `<seat>.seat.conf` basename so the
//! daemon can log it, test for it, or pass it to `configdir` joining
//! without duplicating the naming rule.
//!
//! # Daemon wiring contract (main.zig runDaemon)
//!
//! ```zig
//! var mon = try multiseat.SeatMonitor.init(alloc, multiseat.SdLoginOps.real);
//! defer mon.deinit();
//!
//! // epoll: register mon.fd() for mon.events() (always POLLIN).
//! // There is no timer: mon.timeoutUsec() is UINT64_MAX (infinite).
//! loop.add(mon.fd(), .in, .seat_monitor);
//!
//! // on EPOLLIN (and once at startup):
//! for (try mon.process()) |change| switch (change) {
//!     .added => |seat| {
//!         // One worker process per seat. The seat name travels in the
//!         // worker environment (worker_seat_env / workerEnviron below);
//!         // a worker never re-enters the daemon.
//!         //   seat.needsFakeVt(): spawn WITHOUT --vt; the worker's
//!         //     setupSeat selects src/seat/vt_fake.zig (start active,
//!         //     never switch). config.loadSeat(main, alloc, io,
//!         //     seat.name) layers <seat>.seat.conf for the worker.
//!         //   else: spawn with --vt N --no-libseat as before.
//!         // The worker filters udev devices by ID_SEAT == seat.name
//!         // (reference §6.4) and reports the name as XDG_SEAT.
//!         _ = spawnSeatWorker(seat);
//!     },
//!     .removed => |seat| stopSeatWorker(seat.name),
//! };
//! ```
//!
//! `added`/`removed` are supervision events, not session events: an
//! existing seat whose active session changes keeps its slot and only
//! `SeatInfo.active_session` changes (`mon.seat(name)`), so the worker is
//! never restarted for a login/logout. The daemon should use
//! `active_session == null` to mean "seat is idle" (DPMS/foreground is the
//! worker's own decision).
//!
//! `init` fails with `error.MonitorCreateFailed` when logind/sd-login is
//! unavailable (no `/run/systemd/seats`, e.g. containers); the daemon may
//! then fall back to a single static seat (`"seat0"` or the instance name
//! from `kmshaunt-vt@.service`) and skip multi-seat supervision. Failure is
//! not fatal to the console itself.
//!
//! # C interop
//!
//! Every C call goes through the `SdLoginOps` function-pointer seam so the
//! tests are hermetic (no logind, no `/run/systemd/seats`, no `-lsystemd`).
//! `SdLoginOps.real` is the only user of the translate-c module
//! `sd-login-c` and of libc `free`; both are analyzed lazily, so the
//! hermetic tests never reference them.
//!
//! The module is produced by translating a one-line shim header:
//!
//!     SYS=$(nix build nixpkgs#systemd.dev --print-out-paths --no-link)
//!     GLIBC=$(nix build nixpkgs#glibc.dev --print-out-paths --no-link)
//!     printf '#include <systemd/sd-login.h>\n' > /tmp/sd-login-c.h
//!     zig translate-c -I "$GLIBC/include" -I "$SYS/include" \
//!         /tmp/sd-login-c.h > /tmp/sd-login-c.zig
//!
//! `build.zig` (when the daemon is wired) replaces the shim path with a
//! checked-in header via `b.addTranslateC` and imports the result as
//! `sd-login-c`:
//!
//!     const sd_login_c = b.addTranslateC(.{ .root_source_file = b.path("src/sd-login-c.h"), ... });
//!     exe.root_module.addImport("sd-login-c", sd_login_c.createModule());
//!
//! One import is enough: `seat/multiseat.zig` is part of the same module as
//! `main.zig`, so it resolves `sd-login-c` through the root module. (The
//! /tmp probe in `src/test_multiseat.zig` needs a separate `-Mmultiseat`
//! module only because that root file lives outside `src/`.)
//! `sd-login.h` includes `<errno.h>` through `_sd-common.h`, so
//! translate-c needs the libc headers above.
//!
//! Module path: for a src-rooted module root this file is
//! `@import("seat/multiseat.zig")`; the canonical test command is
//!
//!     nix run nixpkgs#zig -- test src/test_multiseat.zig
//!
//! (Zig 0.17.1.) The optional real-logind probe is documented in
//! `src/test_multiseat.zig`.

const std = @import("std");

// ---------------------------------------------------------------------------
// sd-login types and the injectable seam
// ---------------------------------------------------------------------------

/// `sd_login_monitor *`. The object is really the inotify fd encoded as
/// `fd + 1` (`sd-login.c:1175-1181`); `sd_login_monitor_get_fd` undoes
/// that. Opaque here: nothing outside the seam dereferences it.
pub const Monitor = opaque {};

/// `"seat"` -- the only monitor category this module needs
/// (`sd_login.c:1190-1195`). `NULL` would watch seats, sessions, users and
/// machines at once; kmshaunt only supervises seats.
pub const category = "seat";

/// `POLLIN` from `<poll.h>`. `sd_login_monitor_get_events` always returns
/// this value (`sd-login.c:1246-1255`), so the loop can register
/// `EPOLLIN` unconditionally.
pub const poll_in: c_int = 0x001;

/// "No deadline" as reported by `sd_login_monitor_get_timeout`
/// (`sd-login.c:1257-1267`).
pub const infinite_timeout: u64 = std.math.maxInt(u64);

/// Injectable seam over every sd-login call the monitor makes. Tests
/// install a fake implementation; production uses `real`.
///
/// Signatures follow the `<systemd/sd-login.h>` prototypes (systemd 262)
/// with the pointer shapes made explicit:
///
/// * Errors are **negative errno**, success is 0 or positive; there is no
///   `errno` side channel (unlike libseat).
/// * `get_seats` writes a `NULL`-terminated array of `NULL`-terminated
///   strings, all libc-malloc'd; release the strings and then the array
///   with `free`.
/// * `seat_get_active` writes one malloc'd session name on success and
///   returns `-ENXIO`/`-ENODATA` when the seat has no active session. The
///   uid out-parameter of the C API is not needed and is passed `NULL`.
/// * `monitor_get_timeout` writes microseconds and always returns 0; the
///   value is `UINT64_MAX` (infinite), never a real deadline.
pub const SdLoginOps = struct {
    get_seats: *const fn (ret: *?[*:null]?[*:0]u8) callconv(.c) c_int,
    seat_get_active: *const fn (seat: [*:0]const u8, ret_session: *?[*:0]u8) callconv(.c) c_int,
    monitor_new: *const fn (category_z: [*:0]const u8, ret: *?*Monitor) callconv(.c) c_int,
    monitor_unref: *const fn (m: *Monitor) callconv(.c) void,
    monitor_flush: *const fn (m: *Monitor) callconv(.c) c_int,
    monitor_get_fd: *const fn (m: *Monitor) callconv(.c) c_int,
    monitor_get_events: *const fn (m: *Monitor) callconv(.c) c_int,
    monitor_get_timeout: *const fn (m: *Monitor, ret_usec: *u64) callconv(.c) c_int,
    /// `free(3)` from libc. sd-login allocates every returned string and
    /// array with `malloc`, so they must leave through the C allocator.
    free: *const fn (ptr: ?*anyopaque) callconv(.c) void,

    /// Production implementation. Every function lazily imports the
    /// translate-c output of `#include <systemd/sd-login.h>` (module
    /// `sd-login-c`); the hermetic tests never reference this table, so
    /// they need no systemd module and no `-lsystemd`. `free` is libc's.
    ///
    /// Translations against systemd 262:
    ///
    ///     int sd_get_seats(char ***ret_seats);
    ///     int sd_seat_get_active(const char *seat, char **ret_session, uid_t *ret_uid);
    ///     int sd_login_monitor_new(const char *category, sd_login_monitor **ret);
    ///     sd_login_monitor* sd_login_monitor_unref(sd_login_monitor *m);
    ///     int sd_login_monitor_flush(sd_login_monitor *m);
    ///     int sd_login_monitor_get_fd(sd_login_monitor *m);
    ///     int sd_login_monitor_get_events(sd_login_monitor *m);
    ///     int sd_login_monitor_get_timeout(sd_login_monitor *m, uint64_t *ret_timeout_usec);
    pub const real: SdLoginOps = .{
        .get_seats = c_api.getSeats,
        .seat_get_active = c_api.seatGetActive,
        .monitor_new = c_api.monitorNew,
        .monitor_unref = c_api.monitorUnref,
        .monitor_flush = c_api.monitorFlush,
        .monitor_get_fd = c_api.monitorGetFd,
        .monitor_get_events = c_api.monitorGetEvents,
        .monitor_get_timeout = c_api.monitorGetTimeout,
        .free = c_api.free,
    };
};

// ---------------------------------------------------------------------------
// Public data
// ---------------------------------------------------------------------------

/// One seat as reported by the last successful `process`.
///
/// Every slice is owned by the `SeatMonitor`; it stays valid until the next
/// `process` (for `removed` entries) or `deinit`. Callers must not free
/// them.
pub const SeatInfo = struct {
    /// Seat name as logind spells it, e.g. `"seat0"`, `"seat1"`.
    name: []const u8,
    /// The seat's active session, or `null` when nobody is logged in on it
    /// (`-ENXIO`/`-ENODATA` and erroring seats all map to `null`).
    active_session: ?[]const u8,
    /// True when the real VT backend can drive this seat: the kernel has
    /// VTs and the seat is `seat0`. See the file comment.
    has_vt: bool,

    /// The daemon's decision input: a seat without a real VT must be driven
    /// by `src/seat/vt_fake.zig` (activated once, never switched).
    pub fn needsFakeVt(self: SeatInfo) bool {
        return !self.has_vt;
    }
};

/// One entry of `SeatMonitor.process`'s result: a seat that appeared or
/// disappeared since the previous enumeration.
///
/// Both variants borrow the monitor's storage (see `SeatInfo`); a
/// `removed` entry stays readable until the next `process`/`deinit`.
pub const SeatChange = union(enum) {
    /// New since the previous enumeration. Reported in seat-name order.
    added: SeatInfo,
    /// Gone since the previous enumeration. Reported in the previous
    /// enumeration's (name-sorted) order.
    removed: SeatInfo,
};

/// Errors returned by the wrapper. sd-login reports negative errno values;
/// the wrapper maps them to tags and keeps the last raw value in
/// `SeatMonitor.last_errno` for logging.
pub const Error = error{
    OutOfMemory,
    /// `sd_login_monitor_new("seat")` failed (no `/run/systemd/seats`,
    /// no logind in this environment, `-EINVAL`, ...).
    MonitorCreateFailed,
    /// `deinit` was already called (no monitor object left).
    MonitorUnavailable,
    /// `sd_login_monitor_flush` failed.
    FlushFailed,
    /// `sd_get_seats` failed.
    EnumerateFailed,
    /// `sd_login_monitor_get_fd` failed.
    MonitorGetFdFailed,
    /// `sd_login_monitor_get_events` failed.
    MonitorGetEventsFailed,
    /// `sd_login_monitor_get_timeout` failed.
    MonitorGetTimeoutFailed,
};

/// Probe answering "does the kernel provide virtual terminals at all?".
/// A function pointer so tests are hermetic: `/dev/tty0` may or may not
/// exist on the machine running the test suite.
pub const VtProbe = *const fn () bool;

/// Default probe: the kernel VT layer is present iff `/dev/tty0` exists.
/// `F_OK` needs no permission, and `/dev/tty0` is exactly the node the real
/// VT backend opens, so this answers "could the real path work here?".
/// `false` on weird `/dev` setups degrades to the fake VT, which is safe.
pub fn probeKernelVts() bool {
    const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, "/dev/tty0", std.os.linux.F_OK, 0);
    return std.os.linux.errno(rc) == .SUCCESS;
}

/// Seats with a kernel VT: VTs are a seat0 concept (`vt_fake.c:26-49`).
/// The monitor ANDs this with the kernel-VT probe; call it directly only
/// when the machine half is already known.
pub fn hasVt(seat_name: []const u8) bool {
    return std.mem.eql(u8, seat_name, "seat0");
}

/// Basename of the per-seat configuration file: `<seat>.seat.conf`.
/// Matches `config.loadSeat` exactly (`config.c:1167-1185`); the caller
/// joins it with its `configdir`. Caller owns the result.
pub fn seatConfigName(allocator: std.mem.Allocator, seat_name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.seat.conf", .{seat_name});
}

// ---------------------------------------------------------------------------
// Per-seat workers (ROADMAP M6.7): the daemon -> worker contract
// ---------------------------------------------------------------------------

/// Environment variable carrying the seat name from the daemon to the
/// worker process it spawns (one process per seat, kmscon's model).
///
/// A kmshaunt process started with this variable set is a seat worker:
/// main.zig runs the single-seat console for it -- never the daemon,
/// whatever `libseat`/`vt` the inherited config says -- and the console
/// takes its seat identity from the value, not from the VT backend
/// (reference G20: real and fake VT backends cannot report a seat name).
///
/// The daemon sets it on EVERY worker it spawns:
///   * seats with a real VT (seat0): the worker keeps `--vt N`; the name
///     feeds the per-seat config layer and XDG_SEAT.
///   * seats without a kernel VT (`SeatInfo.needsFakeVt`): the worker is
///     spawned WITHOUT `--vt`, and the console selects
///     `src/seat/vt_fake.zig` -- activated once at startup, never
///     switched (kmscon vt_fake.c:39-41).
pub const worker_seat_env = "KMSHAUNT_SEAT";

/// argv[0] for a spawned seat worker: the daemon's own executable. A
/// systemd service's PATH does not reliably contain the kmshaunt binary,
/// so a bare `"kmshaunt"` fails to resolve (`std.process.spawn` ->
/// FileNotFound). `/proc/self/exe` is an absolute path to the running
/// daemon image, which is exactly the program a worker runs (one process
/// per seat, same binary); `.detect` execs it directly, no PATH lookup.
pub const worker_exe = "/proc/self/exe";

/// Worker side: the seat this process serves, or null when it was not
/// spawned by the daemon (the daemon itself, or an ordinary single-seat
/// console). `environ` is `init.minimal.environ` from main. An empty
/// value counts as unset: a nameless worker could neither load its
/// per-seat config nor filter devices by ID_SEAT.
pub fn workerSeat(environ: std.process.Environ) ?[:0]const u8 {
    const value = std.process.Environ.getPosix(environ, worker_seat_env) orelse return null;
    return if (value.len == 0) null else value;
}

/// Daemon side: the environment for one seat worker -- a copy of the
/// daemon's own environment plus `KMSHAUNT_SEAT=<seat_name>`. The caller
/// owns the returned map (`deinit`) and passes it to `std.process.spawn`
/// as `.environ_map`. Inheriting the daemon environment keeps PATH,
/// XKB_CONFIG_ROOT and the locale intact for the worker and its login
/// child; only the seat identity is added.
pub fn workerEnviron(
    base: std.process.Environ,
    allocator: std.mem.Allocator,
    seat_name: []const u8,
) std.process.Environ.CreateMapError!std.process.Environ.Map {
    var map = try std.process.Environ.createMap(base, allocator);
    errdefer map.deinit();
    try map.put(worker_seat_env, seat_name);
    return map;
}

// ---------------------------------------------------------------------------
// The monitor
// ---------------------------------------------------------------------------

/// sd-login seat enumeration + change monitor.
///
/// Lifecycle: `init` creates the inotify-backed monitor; the first
/// `process` reports every existing seat as `added`. `deinit` unrefs the
/// monitor and releases every string. `deinit` is idempotent.
///
/// All calls run on the loop thread (D2); no state is shared with the
/// per-seat workers.
pub const SeatMonitor = struct {
    allocator: std.mem.Allocator,
    ops: SdLoginOps,
    /// `null` only after `deinit`.
    monitor: ?*Monitor,
    /// Current enumeration, sorted by seat name. Owns every string.
    seat_list: std.ArrayListUnmanaged(SeatInfo) = .empty,
    /// Seats removed by the last successful `process`. Their strings are
    /// kept alive because the returned `removed` changes borrow them; they
    /// are freed at the next successful `process` or in `deinit`.
    retired: std.ArrayListUnmanaged(SeatInfo) = .empty,
    /// Result of the last successful `process`; reused storage.
    changes: std.ArrayListUnmanaged(SeatChange) = .empty,
    /// See `has_vt` in the file comment; probed once in `init`.
    kernel_vts: bool,
    /// Raw (negative) errno of the last sd-login failure that was not
    /// fatal, plus the failure that produced the most recent error. Zero
    /// when nothing failed.
    last_errno: c_int = 0,

    /// Create the `"seat"` monitor. Does NOT enumerate: the first
    /// `process` reports every seat as `added`, so a caller that starts
    /// workers from `process` sees a uniform event stream.
    ///
    /// Fails with `error.MonitorCreateFailed` when logind's seat state is
    /// not available (containers without logind, `sd-login` built without
    /// inotify, ...). The caller may continue single-seat in that case.
    pub fn init(allocator: std.mem.Allocator, ops: SdLoginOps) Error!SeatMonitor {
        return initWithVtProbe(allocator, ops, probeKernelVts);
    }

    /// `init` with the kernel-VT probe injected (tests only; production
    /// uses `init`).
    pub fn initWithVtProbe(
        allocator: std.mem.Allocator,
        ops: SdLoginOps,
        vt_probe: VtProbe,
    ) Error!SeatMonitor {
        var monitor: ?*Monitor = null;
        const rc = ops.monitor_new(category, &monitor);
        if (rc < 0 or monitor == null) return error.MonitorCreateFailed;
        return .{
            .allocator = allocator,
            .ops = ops,
            .monitor = monitor,
            .kernel_vts = vt_probe(),
        };
    }

    /// Release the monitor and every string. Idempotent; after it returns
    /// the value is inert (`fd`, `process` and `seats` report nothing).
    pub fn deinit(self: *SeatMonitor) void {
        if (self.monitor == null) return;

        self.changes.deinit(self.allocator);
        self.changes = .empty;

        freeSeatItems(self.allocator, self.retired.items);
        self.retired.deinit(self.allocator);
        self.retired = .empty;

        freeSeatItems(self.allocator, self.seat_list.items);
        self.seat_list.deinit(self.allocator);
        self.seat_list = .empty;

        if (self.monitor) |m| self.ops.monitor_unref(m);
        self.monitor = null;
    }

    /// Pollable descriptor of the seat monitor: the inotify fd. Register it
    /// `EPOLLIN` (see `events`) and call `process` when it fires.
    pub fn fd(self: *const SeatMonitor) Error!c_int {
        const m = self.monitor orelse return error.MonitorUnavailable;
        const rc = self.ops.monitor_get_fd(m);
        if (rc < 0) return error.MonitorGetFdFailed;
        return rc;
    }

    /// Poll mask for `fd`: always `poll_in` (`sd-login.c:1246-1255`).
    pub fn events(self: *const SeatMonitor) Error!c_int {
        const m = self.monitor orelse return error.MonitorUnavailable;
        const rc = self.ops.monitor_get_events(m);
        if (rc < 0) return error.MonitorGetEventsFailed;
        return rc;
    }

    /// Timeout for `fd`: always `infinite_timeout`; there is no timer to
    /// integrate (`sd-login.c:1257-1267`). Exposed so the loop does not
    /// need to know that fact.
    pub fn timeoutUsec(self: *const SeatMonitor) Error!u64 {
        const m = self.monitor orelse return error.MonitorUnavailable;
        var usec: u64 = 0;
        const rc = self.ops.monitor_get_timeout(m, &usec);
        if (rc < 0) return error.MonitorGetTimeoutFailed;
        return usec;
    }

    /// Drain the monitor. `process` does this first; call it directly only
    /// if you must ack readability without re-enumerating.
    pub fn flush(self: *SeatMonitor) Error!void {
        const m = self.monitor orelse return error.MonitorUnavailable;
        const rc = self.ops.monitor_flush(m);
        if (rc < 0) {
            self.last_errno = rc;
            return error.FlushFailed;
        }
    }

    /// Current seats, sorted by name. Empty until the first successful
    /// `process`. Slices are borrowed until the next `process`/`deinit`.
    pub fn seats(self: *const SeatMonitor) []const SeatInfo {
        return self.seat_list.items;
    }

    /// Look up one seat by name. Borrowed, same lifetime as `seats`.
    pub fn seat(self: *const SeatMonitor, name: []const u8) ?SeatInfo {
        return findSeat(self.seat_list.items, name);
    }

    /// Re-enumerate the seats and return what changed.
    ///
    /// The monitor is coarse (see the file comment): this flushes the
    /// inotify fd, reads `sd_get_seats` plus one `sd_seat_get_active` per
    /// seat, sorts by name and diffs by name. Report order is removals
    /// (previous order) then additions (new order).
    ///
    /// The returned slice, and every string reached through it, is owned
    /// by the monitor and valid until the next successful `process` or
    /// `deinit`. On error nothing is changed: the previous seat list and
    /// change list stay valid.
    pub fn process(self: *SeatMonitor) Error![]const SeatChange {
        // Flush first: an unread inotify fd keeps epoll hot forever.
        try self.flush();

        // Enumerate into a scratch list. Nothing is mutated until the
        // enumeration and every allocation succeeded, so a failure leaves
        // the previous state (and its borrowed strings) intact.
        var next: std.ArrayListUnmanaged(SeatInfo) = .empty;
        var next_owned = true;
        errdefer if (next_owned) {
            freeSeatItems(self.allocator, next.items);
            next.deinit(self.allocator);
        };

        try self.enumerate(&next);
        std.mem.sort(SeatInfo, next.items, {}, lessThanSeat);

        // Capacity for the whole diff up front: the remainder is
        // allocation-free and therefore cannot fail halfway through.
        try self.changes.ensureTotalCapacity(self.allocator, self.seat_list.items.len + next.items.len);
        try self.retired.ensureTotalCapacity(self.allocator, self.seat_list.items.len);

        // The previous change list and the previous retirement batch end
        // their lifetimes here.
        self.changes.clearRetainingCapacity();
        self.freeRetired();

        // Removals: seats in the old list that are not in `next`. Their
        // strings move to `retired` so the caller can read the change.
        for (self.seat_list.items) |old| {
            if (findSeat(next.items, old.name) != null) continue;
            self.retired.appendAssumeCapacity(old);
            self.changes.appendAssumeCapacity(.{
                .removed = self.retired.items[self.retired.items.len - 1],
            });
        }

        // Additions: seats in `next` that were not in the old list.
        for (next.items) |fresh| {
            if (findSeat(self.seat_list.items, fresh.name) != null) continue;
            self.changes.appendAssumeCapacity(.{ .added = fresh });
        }

        // Seats that survived keep the fresh enumeration (so an active
        // session change is visible without restarting the worker); their
        // previous strings are released. Removed seats were moved above.
        for (self.seat_list.items) |old| {
            if (findSeat(next.items, old.name) == null) continue;
            freeSeatItem(self.allocator, old);
        }
        self.seat_list.deinit(self.allocator);
        self.seat_list = next;
        next_owned = false;

        return self.changes.items;
    }

    // -- internals ---------------------------------------------------------

    /// One full `sd_get_seats` + `sd_seat_get_active` pass.
    fn enumerate(self: *SeatMonitor, out: *std.ArrayListUnmanaged(SeatInfo)) Error!void {
        var raw: ?[*:null]?[*:0]u8 = null;
        const rc = self.ops.get_seats(&raw);
        if (rc < 0) {
            self.last_errno = rc;
            return error.EnumerateFailed;
        }
        // sd-login malloc'd the array and every string; release them all,
        // on the success path and on any later OOM.
        defer self.freeSeatArray(raw);

        // No /run/systemd/seats: an empty set, not an error
        // (sd-login.c:988-1010). Every previous seat becomes `removed`.
        const raw_seats = raw orelse return;

        var i: usize = 0;
        while (raw_seats[i]) |name_z| : (i += 1) {
            try self.appendSeat(out, name_z);
        }
    }

    /// Copy one C seat entry (name + active session) into `out`.
    fn appendSeat(
        self: *SeatMonitor,
        out: *std.ArrayListUnmanaged(SeatInfo),
        name_z: [*:0]const u8,
    ) Error!void {
        const name = std.mem.span(name_z);
        // The name is already known to logind as a filename under
        // /run/systemd/seats, so it cannot contain a path separator; the
        // daemon may use it for <seat>.seat.conf and ID_SEAT matching.
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        var session: ?[]const u8 = null;
        errdefer if (session) |s| self.allocator.free(s);

        var session_raw: ?[*:0]u8 = null;
        const rc = self.ops.seat_get_active(name_z, &session_raw);
        if (rc != 0 and !noActiveSession(rc)) {
            // Not ENXIO/ENODATA: the seat file exists but could not be
            // read (ENOMEM, EINVAL, ENOENT race with removal, ...). Do not
            // abort the whole enumeration; report "idle" and keep the rc.
            self.last_errno = rc;
        }
        // Free the C string whenever the implementation set it, even on an
        // unexpected error: sd-login's contract says it only sets it on
        // success, but leaking is worse than a defensive branch.
        if (session_raw) |ptr| {
            defer self.ops.free(ptr);
            if (rc == 0) session = try self.allocator.dupe(u8, std.mem.span(ptr));
        }

        try out.append(self.allocator, .{
            .name = name_copy,
            .active_session = session,
            .has_vt = self.kernel_vts and hasVt(name),
        });
    }

    fn freeSeatArray(self: *SeatMonitor, raw: ?[*:null]?[*:0]u8) void {
        const raw_seats = raw orelse return;
        var i: usize = 0;
        while (raw_seats[i]) |name_z| : (i += 1) self.ops.free(name_z);
        self.ops.free(@ptrCast(raw_seats));
    }

    fn freeRetired(self: *SeatMonitor) void {
        freeSeatItems(self.allocator, self.retired.items);
        self.retired.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `-ENXIO` (no seat state file) and `-ENODATA` (state file without an
/// active session) are the two documented "nobody is logged in" results
/// (`sd-login.c:854-886`). Everything else is unexpected.
fn noActiveSession(rc: c_int) bool {
    if (rc >= 0) return false;
    const errno_value = -rc;
    return errno_value == e_nxio or errno_value == e_nodata;
}

const e_nxio: c_int = @intFromEnum(std.posix.E.NXIO);
const e_nodata: c_int = @intFromEnum(std.posix.E.NODATA);

fn lessThanSeat(_: void, a: SeatInfo, b: SeatInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn findSeat(items: []const SeatInfo, name: []const u8) ?SeatInfo {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn freeSeatItems(allocator: std.mem.Allocator, items: []const SeatInfo) void {
    for (items) |item| freeSeatItem(allocator, item);
}

fn freeSeatItem(allocator: std.mem.Allocator, item: SeatInfo) void {
    allocator.free(item.name);
    if (item.active_session) |session| allocator.free(session);
}

// ---------------------------------------------------------------------------
// Production ops (translate-c `sd-login-c`)
// ---------------------------------------------------------------------------

const c_api = struct {
    fn getSeats(ret: *?[*:null]?[*:0]u8) callconv(.c) c_int {
        const c = @import("sd-login-c");
        var raw: [*c][*c]u8 = null;
        const rc = c.sd_get_seats(&raw);
        ret.* = if (raw == null) null else @ptrCast(raw);
        return rc;
    }

    fn seatGetActive(seat: [*:0]const u8, ret_session: *?[*:0]u8) callconv(.c) c_int {
        const c = @import("sd-login-c");
        var raw: [*c]u8 = null;
        // No uid needed: a NULL ret_uid is explicitly allowed by sd-login.
        const rc = c.sd_seat_get_active(seat, &raw, null);
        ret_session.* = if (raw == null) null else @ptrCast(raw);
        return rc;
    }

    fn monitorNew(category_z: [*:0]const u8, ret: *?*Monitor) callconv(.c) c_int {
        const c = @import("sd-login-c");
        var raw: ?*c.sd_login_monitor = null;
        const rc = c.sd_login_monitor_new(category_z, &raw);
        ret.* = if (raw) |m| @ptrCast(m) else null;
        return rc;
    }

    fn monitorUnref(m: *Monitor) callconv(.c) void {
        const c = @import("sd-login-c");
        _ = c.sd_login_monitor_unref(@ptrCast(@alignCast(m)));
    }

    fn monitorFlush(m: *Monitor) callconv(.c) c_int {
        const c = @import("sd-login-c");
        return c.sd_login_monitor_flush(@ptrCast(@alignCast(m)));
    }

    fn monitorGetFd(m: *Monitor) callconv(.c) c_int {
        const c = @import("sd-login-c");
        return c.sd_login_monitor_get_fd(@ptrCast(@alignCast(m)));
    }

    fn monitorGetEvents(m: *Monitor) callconv(.c) c_int {
        const c = @import("sd-login-c");
        return c.sd_login_monitor_get_events(@ptrCast(@alignCast(m)));
    }

    fn monitorGetTimeout(m: *Monitor, ret_usec: *u64) callconv(.c) c_int {
        const c = @import("sd-login-c");
        return c.sd_login_monitor_get_timeout(@ptrCast(@alignCast(m)), ret_usec);
    }

    fn free(ptr: ?*anyopaque) callconv(.c) void {
        std.c.free(ptr);
    }
};

// ---------------------------------------------------------------------------
// Worker contract tests (hermetic: a static environ block, no C calls).
// Pulled in by src/test_multiseat.zig and src/tests.zig.
// ---------------------------------------------------------------------------

/// Build an `Environ` over static `KEY=VALUE` entries. The block is
/// borrowed, never freed -- exactly the shape the OS hands to main.
fn testEnviron(comptime entries: []const [:0]const u8) std.process.Environ {
    const storage = struct {
        var slice: [entries.len:null]?[*:0]const u8 = undefined;
    };
    inline for (entries, 0..) |entry, i| storage.slice[i] = entry.ptr;
    return .{ .block = .{ .slice = &storage.slice } };
}

test "workerSeat: reads the daemon-provided seat name" {
    const env = testEnviron(&.{ "PATH=/bin", "KMSHAUNT_SEAT=seat-pci-0000_00_12_0", "LANG=C" });
    const name = workerSeat(env) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("seat-pci-0000_00_12_0", name);
}

test "workerSeat: null without the variable and on an empty value" {
    try std.testing.expect(workerSeat(testEnviron(&.{"PATH=/bin"})) == null);
    try std.testing.expect(workerSeat(testEnviron(&.{})) == null);
    // An empty name cannot identify a seat: treat it as unset.
    try std.testing.expect(workerSeat(testEnviron(&.{"KMSHAUNT_SEAT="})) == null);
}

test "workerEnviron: inherits the daemon environment and adds the seat" {
    const a = std.testing.allocator;
    const base = testEnviron(&.{ "PATH=/bin", "XKB_CONFIG_ROOT=/xkb", "KMSHAUNT_SEAT=stale" });
    var map = try workerEnviron(base, a, "seat1");
    defer map.deinit();

    // Everything the daemon had survives (the worker's login child needs
    // PATH and XKB_CONFIG_ROOT), and the seat identity is the new name --
    // a stale value from the daemon's own environment is overwritten.
    try std.testing.expectEqualStrings("/bin", map.get("PATH").?);
    try std.testing.expectEqualStrings("/xkb", map.get("XKB_CONFIG_ROOT").?);
    try std.testing.expectEqualStrings("seat1", map.get(worker_seat_env).?);
    try std.testing.expectEqual(@as(usize, 3), map.count());
}

test "workerEnviron: round-trips through workerSeat" {
    const a = std.testing.allocator;
    var map = try workerEnviron(testEnviron(&.{}), a, "seat-pci-0000_00_12_0");
    defer map.deinit();

    // The map is what std.process.spawn hands to the child; rebuild the
    // child-side view (a POSIX block) and read it back the way main.zig
    // does. This pins the daemon -> worker direction end to end.
    const block = try map.createPosixBlock(a, .{});
    defer block.deinit(a);
    const child_env = std.process.Environ{ .block = .{ .slice = block.slice } };
    const name = workerSeat(child_env) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("seat-pci-0000_00_12_0", name);
}