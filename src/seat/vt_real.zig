//! src/seat/vt_real.zig -- real Linux kernel VT seat backend (ROADMAP M1.2).
//!
//! Implements the `seat.Seat` vtable on /dev/ttyN with the classic VT
//! protocol: KDSETMODE/KD_GRAPHICS for the console, VT_SETMODE(VT_PROCESS)
//! for negotiated VT switches, KDSKBMODE to keep the kernel keyboard away
//! from the console. Reference: kmscon `src/uterm/vt_real.c` (read in full;
//! every ioctl sequence below is taken from it and every intentional
//! deviation is called out).
//!
//! # What this backend does NOT do
//!
//! DRM master is owned by the video backend, not by the seat. The seat only
//! orders the VT operations and fires `Callbacks.deactivated` / `.activated`
//! *before* it acks the kernel, so `main.zig` can drop/retake master at the
//! right moment (drm2d-recipes constraint #2: `drmDropMaster` before
//! `VT_RELDISP`, otherwise the next DRM owner's `drmSetMaster` fails EBUSY).
//! A forced release while we still hold master is therefore the owner's bug,
//! not this file's.
//!
//! # Ioctl sequences (exact)
//!
//! `openVt(requested, switchvt)`:
//!   1. `requested == null`: open("/dev/tty0", O_RDWR|O_NOCTTY|O_CLOEXEC),
//!      `VT_GETSTATE` (0x5603) -> `vt_stat.v_active`, close the control fd.
//!   2. open("/dev/ttyN") where N is 1..=63.
//!   3. `VT_GETSTATE` on the VT fd (kmscon `real_open`).
//!   4. `switchvt and v_active != N`: `VT_ACTIVATE` (0x5606, arg N) then
//!      `VT_WAITACTIVE` (0x5607, arg N). VT_WAITACTIVE blocks in the kernel;
//!      EINTR is retried until `wait_timeout_ns` of monotonic time passed
//!      (`error.WaitFailed`). No VT_SETMODE here: the console stays in
//!      VT_AUTO until `activate`, so a seat that never activates never
//!      holds the switch protocol hostage.
//!
//! `activate()` (kmscon `real_open`/`real_restore` order):
//!   1. `KDSETMODE` (0x4B3A), KD_GRAPHICS (1)
//!   2. `VT_SETMODE` (0x5602), `vt_mode{ .mode = VT_PROCESS (1),
//!      .acqsig = SIGUSR1, .relsig = SIGUSR2, .waitv = 0, .frsig = 0 }`
//!   3. `KDGKBMODE` (0x4B44) -> saved mode (K_OFF rewritten to K_UNICODE so
//!      the console is not left with a dead keyboard)
//!   4. `KDSKBMODE` (0x4B45) K_RAW (0), then K_OFF (4) — kmscon sets both;
//!      the K_OFF failure is warning-only there and here.
//!   Failure rolls back to KD_TEXT/VT_AUTO/previous KBMODE.
//!
//! `deactivate()` (the "give the console back" path: shutdown, error
//! unwinding, explicit switch):
//!   1. `deactivated` callback (drops DRM master; must precede the ack)
//!   2. `VT_RELDISP` (0x5605) arg 1 — acknowledge a pending release; it is
//!      only meaningful while VT_PROCESS is installed. The kernel models the
//!      argument as "0: pending switch-from not OK, 1: pending switch-from
//!      OK, 2: completed switch-to OK" (`vt_ioctl.c`, `VT_RELDISP`) and
//!      answers EINVAL when no switch is pending (`vt_newvt < 0`), so EINVAL
//!      here means "nothing to release", not failure.
//!   3. `KDSETMODE` KD_TEXT (0)
//!   4. `KDSKBMODE` saved mode
//!   5. `VT_SETMODE` VT_AUTO (0)
//!
//! `handleSignal()`, release path (kernel asks us to leave; kmscon
//! `real_sig_leave`):
//!   1. `VT_GETSTATE`; ignore the signal when `v_active != N` (stale)
//!   2. `deactivated` callback
//!   3. `VT_RELDISP` arg 1
//!   VT_PROCESS is kept (VT_AUTO here would silence the acquire signal and
//!   the seat could never come back) and KD_TEXT is NOT set: the console we
//!   are leaving belongs to the next VT (drm2d-recipes: "never KD_TEXT while
//!   another VT is active").
//!
//! `handleSignal()`, acquire path (kmscon `real_sig_enter`):
//!   1. `VT_GETSTATE`; ignore when `v_active != N`
//!   2. `VT_RELDISP` arg VT_ACKACQ (2)
//!   3. `activate()` (KD_GRAPHICS + VT_SETMODE + keyboard off, fires
//!      `activated`)
//!
//! `deinit()` (kmscon `real_close`): `KDSKBMODE` saved, `VT_SETMODE`
//! VT_AUTO, `KDSETMODE` KD_TEXT, close the fd. No VT_RELDISP (kmscon does
//! not either; closing the fd leaves VT_PROCESS).
//!
//! # Signal delivery: signalfd, not a `signal(2)` handler
//!
//! ROADMAP D2 is one thread and one epoll loop, so the classic kmscon
//! `ev_eloop_register_signal_cb` handler is replaced by signalfd:
//! `loop.SignalSource` blocks SIGUSR1/SIGUSR2 in the process mask and
//! delivers them on the loop thread. `signal_set` is exported for exactly
//! that. The caller wires it as:
//!
//! ```zig
//! var signals: loop.SignalSource = undefined;
//! try signals.init(loop_, .{
//!     .callback = struct {
//!         fn cb(_: *loop.SignalSource, info: loop.SignalSource.Info, ud: usize) void {
//!             const vt: *vt_real.VtReal = @ptrFromInt(ud);
//!             vt.handleSignal(info.signo) catch |err| std.log.err("vt: {t}", .{err});
//!         }
//!     }.cb,
//!     .userdata = @intFromPtr(&vt_seat),
//!     .signals = &vt_real.signal_set,
//! });
//! ```
//!
//! Two hard ordering rules come with this:
//!   * SIGUSR1/SIGUSR2 MUST be blocked *before* `activate()` installs
//!     VT_PROCESS. Between VT_SETMODE and a signalfd registration the kernel
//!     would deliver them with their default action (`terminate`).
//!   * `handleSignal` only acts on the exact signal numbers stored in
//!     VT_SETMODE; anything else is ignored, so a shared SignalSource that
//!     also carries SIGTERM/SIGCHLD is fine.
//!
//! Signal numbers follow kmscon, which is the verified reference:
//! `.acqsig = SIGUSR1` ("VT is ours again", `real_sig_enter`) and
//! `.relsig = SIGUSR2` ("release the VT", `real_sig_leave`). The kernel has
//! no opinion about *which* numbers these are; only the VT_SETMODE payload
//! and the dispatch in `handleSignal` must agree, and both derive from
//! `acquire_signal` / `release_signal` below. (Some prose elsewhere names
//! them the other way round; the C source and kmscon's behavior win.)
//!
//! `VT_RELDISP` argument values (linux/vt.h, kmscon `real_sig_leave` /
//! `real_sig_enter`): 1 = acknowledge release, VT_ACKACQ (2) = acknowledge
//! acquisition, 0 = refuse the switch (unused here: `Seat.Callbacks` cannot
//! refuse).
//!
//! # pause / resume
//!
//! For a kernel VT there is no fd handoff as with libseat, so `pause` maps
//! to `deactivate()` (full give-back: VT_AUTO + KD_TEXT) plus the `pause`
//! callback, and `resume_` maps to `activate()` plus the `resume_` callback.
//!
//! # Kernel caveats carried over from the reference
//!
//! `VT_GETSTATE` returns `fg_console + 1` in `v_active` (exact for every VT)
//! and a 16-bit `v_state` bitmask, so only the bitmask is limited to VTs
//! below 16; the active-VT check we rely on is always exact (`vt_ioctl.c`,
//! `VT_GETSTATE`). The linux/vt.h warning about consoles >= 16 refers to
//! that bitmask.
//!
//! Re-entrancy: every callback is delivered through `seat.CallbackGuard`
//! (a callback that calls back into the seat cannot recurse through
//! callbacks; the operations themselves still run).
//!
//! # Tests
//!
//! `Sys` is injectable (ioctl/open/close/now as fn pointers over an opaque
//! context), so every test below runs hermetically against a fake kernel
//! that records ioctls. Run from the repository root with the src-level
//! test root (a module cannot import a file outside its own root directory):
//!
//!     nix run nixpkgs#zig -- test src/test_vt_real.zig

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const seat = @import("../seat.zig");

const log = std.log.scoped(.vt_real);

// ---------------------------------------------------------------------------
// Constants (linux/kd.h, linux/vt.h; verified against linux-headers 7.2)
// ---------------------------------------------------------------------------

/// Kernel `MAX_NR_CONSOLES - 1`: valid VT numbers are 1..=63.
pub const max_vt: u8 = 63;

/// Signal the kernel raises when our VT becomes active.
pub const acquire_signal: posix.SIG = .USR1;
/// Signal the kernel raises when it wants our VT released.
pub const release_signal: posix.SIG = .USR2;
/// Signals a `loop.SignalSource` must block and forward to `handleSignal`.
pub const signal_set = [_]posix.SIG{ acquire_signal, release_signal };

/// How long `openVt` retries an EINTR-interrupted VT_WAITACTIVE. VT_WAITACTIVE
/// blocks inside the kernel, so this is a retry bound, not a timer.
pub const default_wait_timeout_ns: u64 = 2 * std.time.ns_per_s;

/// VT ioctl request numbers and arguments (linux/vt.h).
pub const vt = struct {
    pub const setmode: u32 = 0x5602; // VT_SETMODE
    pub const getstate: u32 = 0x5603; // VT_GETSTATE
    pub const reldisp: u32 = 0x5605; // VT_RELDISP
    pub const activate: u32 = 0x5606; // VT_ACTIVATE
    pub const waitactive: u32 = 0x5607; // VT_WAITACTIVE

    pub const auto: u8 = 0x00; // VT_AUTO
    pub const process: u8 = 0x01; // VT_PROCESS
    pub const ackacq: usize = 0x02; // VT_ACKACQ: acknowledge acquisition
    pub const release_ack: usize = 1; // allow a pending VT switch
};

/// Console ioctl request numbers and modes (linux/kd.h).
pub const kd = struct {
    pub const setmode: u32 = 0x4B3A; // KDSETMODE
    pub const getkbmode: u32 = 0x4B44; // KDGKBMODE (writes an int)
    pub const setkbmode: u32 = 0x4B45; // KDSKBMODE

    pub const raw: u8 = 0x00; // K_RAW
    pub const unicode: u8 = 0x03; // K_UNICODE
    pub const off: u8 = 0x04; // K_OFF
};

/// `struct vt_mode` (linux/vt.h): `__u8 mode; __u8 waitv; __s16 relsig;
/// __s16 acqsig; __s16 frsig;`. Size 8, alignment 2.
pub const VtMode = extern struct {
    mode: u8 = 0,
    waitv: u8 = 0,
    relsig: i16 = 0,
    acqsig: i16 = 0,
    frsig: i16 = 0,
};

/// `struct vt_stat` (linux/vt.h): three `__u16`.
pub const VtStat = extern struct {
    v_active: u16 = 0,
    v_signal: u16 = 0,
    v_state: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(VtMode) == 8 and @alignOf(VtMode) == 2);
    std.debug.assert(@sizeOf(VtStat) == 6 and @alignOf(VtStat) == 2);
}

/// `/dev/ttyNN` needs 10 bytes; the sentinel array keeps it NUL-terminated
/// for open(2) without an allocation.
const path_buf_len = 16;

// ---------------------------------------------------------------------------
// Injectable syscall surface
// ---------------------------------------------------------------------------

/// Every kernel interaction this backend needs. All callbacks take the
/// opaque `ctx` first so tests can hand in a fake device without globals;
/// `Sys.real` ignores it.
///
/// `ioctl` returns `>= 0` on success and `-errno` on failure (a negative
/// errno, not -1/errno) — this is what makes the fake kernels below
/// hermetic and what `realIoctl` translates the raw syscall result into.
pub const Sys = struct {
    ctx: ?*anyopaque = null,
    ioctl: *const fn (ctx: ?*anyopaque, fd: posix.fd_t, request: u32, arg: usize) isize,
    open: *const fn (ctx: ?*anyopaque, path: [*:0]const u8, flags: u32) isize,
    close: *const fn (ctx: ?*anyopaque, fd: posix.fd_t) void,
    /// Monotonic nanoseconds, used only for the VT_WAITACTIVE retry bound.
    now: *const fn (ctx: ?*anyopaque) i64,

    pub const real: Sys = .{
        .ctx = null,
        .ioctl = realIoctl,
        .open = realOpen,
        .close = realClose,
        .now = realNow,
    };
};

/// open(2) flags for the VT fd: kmscon's `O_RDWR | O_NOCTTY | O_CLOEXEC`.
const open_flags: u32 = @bitCast(linux.O{
    .ACCMODE = .RDWR,
    .NOCTTY = true,
    .CLOEXEC = true,
});

const eintr: isize = -@as(isize, @intCast(@intFromEnum(linux.E.INTR)));
const einval: isize = -@as(isize, @intCast(@intFromEnum(linux.E.INVAL)));

fn realIoctl(ctx: ?*anyopaque, fd: posix.fd_t, request: u32, arg: usize) isize {
    _ = ctx;
    const rc = linux.ioctl(fd, request, arg);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| -@as(isize, @intCast(@intFromEnum(e))),
    };
}

fn realOpen(ctx: ?*anyopaque, path: [*:0]const u8, flags: u32) isize {
    _ = ctx;
    const rc = linux.open(path, @bitCast(flags), 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(@as(isize, @intCast(rc))),
        else => |e| -@as(isize, @intCast(@intFromEnum(e))),
    };
}

fn realClose(ctx: ?*anyopaque, fd: posix.fd_t) void {
    _ = ctx;
    _ = linux.close(fd);
}

fn realNow(ctx: ?*anyopaque) i64 {
    _ = ctx;
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// VtReal
// ---------------------------------------------------------------------------

/// Real VT seat. The `Seat` vtable is in `vtable`; one instance per console.
pub const VtReal = struct {
    sys: Sys = Sys.real,

    /// The open VT fd (`/dev/ttyN`). Owned here and exposed so the loop can
    /// watch it for EPOLLHUP (VT revoked) or drain stray console input.
    /// Never close it from outside: `deinit()` does that after restoring
    /// the console.
    vt_fd: posix.fd_t = -1,

    /// Active VT number, 1..=63; 0 while closed.
    num: u8 = 0,
    path_buf: [path_buf_len:0]u8 = undefined,
    path_len: usize = 0,

    /// Keyboard mode found by KDGKBMODE in `activate`, restored on
    /// `deactivate`/`deinit`. KDGKBMODE writes an `int`, hence i32.
    saved_kbmode: i32 = kd.unicode,
    kbmode_saved: bool = false,

    /// VT_PROCESS is installed (activate succeeded, not yet restored).
    mode_taken: bool = false,
    /// We own the console (KD_GRAPHICS is set).
    active: bool = false,
    /// A libseat-style device pause is in effect (pause/resume_ balance).
    paused: bool = false,

    /// Retry bound for VT_WAITACTIVE; 0 means "do not retry EINTR".
    wait_timeout_ns: u64 = default_wait_timeout_ns,

    callbacks: ?*const seat.Seat.Callbacks = null,
    userdata: usize = 0,
    guard: seat.CallbackGuard = .{},

    pub fn init(sys: Sys) VtReal {
        return .{ .sys = sys };
    }

    /// The seat interface for this VT.
    pub fn asSeat(self: *VtReal) seat.Seat {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ------------------------------------------------------------- queries

    /// VT number, 0 while closed.
    pub fn vtNum(self: *const VtReal) u8 {
        return self.num;
    }

    /// Borrowed "/dev/ttyN" of the open VT (empty while closed). Valid until
    /// the next `openVt`.
    pub fn path(self: *const VtReal) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn isActive(self: *VtReal) bool {
        return self.active;
    }

    // -------------------------------------------------------------- open

    /// Open the VT. `requested == null` uses the currently active VT read
    /// with VT_GETSTATE on /dev/tty0; otherwise the given number (1..=63).
    /// With `switchvt`, a target VT that is not active is made active with
    /// VT_ACTIVATE + VT_WAITACTIVE. Re-opening restores and closes the
    /// previous VT first.
    pub fn openVt(self: *VtReal, requested: ?u8, switchvt: bool) seat.OpenVtError!seat.VtInfo {
        if (self.vt_fd >= 0) self.closeInternal();
        self.path_len = 0;

        const num: u8 = if (requested) |n| blk: {
            if (n == 0 or n > max_vt) return error.InvalidVt;
            break :blk n;
        } else blk: {
            // kmscon reads the active VT from the VT it opened; the contract
            // says query /dev/tty0 for "current VT" explicitly.
            const ctl = try self.openDevice("/dev/tty0");
            defer self.sys.close(self.sys.ctx, ctl);
            var st = VtStat{};
            if (!self.ioctlOk(ctl, vt.getstate, @intFromPtr(&st))) return error.IoctlFailed;
            if (st.v_active == 0 or st.v_active > @as(u16, max_vt)) return error.InvalidVt;
            break :blk @intCast(st.v_active);
        };

        const fd = try self.openTty(num);
        errdefer {
            self.sys.close(self.sys.ctx, fd);
            self.path_len = 0;
        }

        // kmscon real_open: learn the active VT from the VT fd itself.
        var st = VtStat{};
        if (!self.ioctlOk(fd, vt.getstate, @intFromPtr(&st))) return error.IoctlFailed;

        if (switchvt and st.v_active != num) {
            if (!self.ioctlOk(fd, vt.activate, num)) return error.IoctlFailed;
            try self.waitActive(fd, num);
        }

        self.vt_fd = fd;
        self.num = num;
        return .{ .vt_num = num, .path = self.path() };
    }

    fn openDevice(self: *VtReal, path_z: [*:0]const u8) seat.OpenVtError!posix.fd_t {
        const rc = self.sys.open(self.sys.ctx, path_z, open_flags);
        if (rc < 0) return error.OpenFailed;
        return @intCast(rc);
    }

    /// Format "/dev/ttyN" into `path_buf` (NUL-terminated) and open it.
    fn openTty(self: *VtReal, num: u8) seat.OpenVtError!posix.fd_t {
        var scratch: [path_buf_len]u8 = undefined;
        const body = std.mem.print(&scratch, "/dev/tty{d}", .{num}) catch unreachable;
        @memcpy(self.path_buf[0..body.len], body);
        self.path_buf[body.len] = 0;
        self.path_len = body.len;
        return self.openDevice(self.path_buf[0..body.len : 0]) catch |err| {
            self.path_len = 0; // no VT is open, so there is no path either
            return err;
        };
    }

    /// VT_WAITACTIVE with an EINTR retry bound. The ioctl blocks inside the
    /// kernel; only an interruptible return lets us look at the deadline.
    fn waitActive(self: *VtReal, fd: posix.fd_t, num: u8) seat.OpenVtError!void {
        const deadline = self.sys.now(self.sys.ctx) + @as(i64, @intCast(self.wait_timeout_ns));
        while (true) {
            const rc = self.sys.ioctl(self.sys.ctx, fd, vt.waitactive, @intCast(num));
            if (rc >= 0) return;
            if (rc != eintr) return error.WaitFailed;
            if (self.sys.now(self.sys.ctx) >= deadline) return error.WaitFailed;
        }
    }

    // ------------------------------------------------------------ activate

    /// Take the console: KD_GRAPHICS, VT_PROCESS, keyboard off. No-op when
    /// already active. The VT must be the active console (openVt with
    /// `switchvt`, or the acquire signal).
    pub fn activate(self: *VtReal) anyerror!void {
        if (self.vt_fd < 0) return error.NotOpen;
        if (self.active) return;

        if (!self.ioctlOk(self.vt_fd, kd.setmode, seat.kd_mode.graphics)) return error.IoctlFailed;

        if (!self.setVtMode(.process)) {
            _ = self.setKdMode(seat.kd_mode.text);
            return error.IoctlFailed;
        }

        var kbmode: i32 = kd.unicode;
        if (!self.ioctlOk(self.vt_fd, kd.getkbmode, @intFromPtr(&kbmode))) {
            _ = self.setVtMode(.auto);
            _ = self.setKdMode(seat.kd_mode.text);
            return error.IoctlFailed;
        }
        // Restoring K_OFF would leave the next console user without a
        // keyboard; kmscon substitutes K_UNICODE, so do we.
        self.saved_kbmode = if (kbmode == kd.off) kd.unicode else kbmode;
        self.kbmode_saved = true;

        if (!self.ioctlOk(self.vt_fd, kd.setkbmode, kd.raw)) {
            _ = self.restoreKbmode();
            _ = self.setVtMode(.auto);
            _ = self.setKdMode(seat.kd_mode.text);
            return error.IoctlFailed;
        }
        // kmscon treats K_OFF failure as a warning: the console already
        // ignores keys because evdev is our input source.
        if (!self.ioctlOk(self.vt_fd, kd.setkbmode, kd.off)) {
            log.warn("VT {d}: KDSKBMODE(K_OFF) failed; kernel keyboard stays enabled", .{self.num});
        }

        self.mode_taken = true;
        self.active = true;
        self.fire("activated");
    }

    /// Give the console back: notify, acknowledge any pending release,
    /// KD_TEXT, keyboard restored, VT_AUTO. No-op when we do not own it.
    pub fn deactivate(self: *VtReal) anyerror!void {
        if (self.vt_fd < 0) return;
        if (!self.active and !self.mode_taken) return;

        if (self.active) {
            self.active = false;
            // Before VT_RELDISP: the owner drops DRM master here (constraint
            // #2 of docs/reference/drm2d-recipes.md).
            self.fire("deactivated");
        }

        var failed = false;
        if (self.mode_taken) {
            // Acknowledge the release while VT_PROCESS is still installed;
            // after VT_AUTO the kernel ignores VT_RELDISP.
            if (!self.ackRelease()) failed = true;
        }
        if (!self.setKdMode(seat.kd_mode.text)) failed = true;
        if (!self.restoreKbmode()) failed = true;
        if (!self.setVtMode(.auto)) failed = true;
        self.mode_taken = false;

        if (failed) return error.IoctlFailed;
    }

    // ------------------------------------------------------------- signals

    /// Dispatch a VT signal read from `loop.SignalSource`. `signo` is the
    /// raw `signalfd_siginfo.signo`; anything that is not the configured
    /// acquire/release signal is ignored.
    pub fn handleSignal(self: *VtReal, signo: u32) anyerror!void {
        const acq: u32 = @intFromEnum(acquire_signal);
        const rel: u32 = @intFromEnum(release_signal);
        if (signo == rel) return self.onReleaseSignal();
        if (signo == acq) return self.onAcquireSignal();
    }

    /// Kernel wants the VT back: notify, then VT_RELDISP(1). Stays in
    /// VT_PROCESS and leaves KD_GRAPHICS alone (the next VT owns the
    /// console; kmscon's `real_sig_leave`).
    fn onReleaseSignal(self: *VtReal) anyerror!void {
        if (self.vt_fd < 0) return;
        var st = VtStat{};
        if (!self.ioctlOk(self.vt_fd, vt.getstate, @intFromPtr(&st))) return error.IoctlFailed;
        if (st.v_active != self.num) return; // stale: the switch went elsewhere

        if (self.active) {
            self.active = false;
            self.fire("deactivated");
        }
        if (!self.ackRelease()) return error.IoctlFailed;
    }

    /// The VT is ours again: ack the acquisition, then take the console
    /// (kmscon's `real_sig_enter`).
    fn onAcquireSignal(self: *VtReal) anyerror!void {
        if (self.vt_fd < 0) return;
        var st = VtStat{};
        if (!self.ioctlOk(self.vt_fd, vt.getstate, @intFromPtr(&st))) return error.IoctlFailed;
        if (st.v_active != self.num) return; // stale

        if (!self.ioctlOk(self.vt_fd, vt.reldisp, vt.ackacq)) return error.IoctlFailed;
        try self.activate();
    }

    // -------------------------------------------------------- pause/resume

    /// libseat-style device pause: notify, then give the console back (no fd
    /// handoff exists for a kernel VT). Idempotent.
    pub fn pause(self: *VtReal) anyerror!void {
        if (self.paused) return;
        self.paused = true;
        self.fire("pause");
        try self.deactivate();
    }

    /// libseat-style device resume: take the console, then notify. A failed
    /// activate keeps `paused` set so the caller can retry.
    pub fn resume_(self: *VtReal) anyerror!void {
        if (!self.paused) return;
        try self.activate();
        self.paused = false;
        self.fire("resume_");
    }

    // ------------------------------------------------------------ callbacks

    /// Install the event callbacks. `callbacks` is borrowed and must outlive
    /// the seat (see `seat.Seat.Callbacks`).
    pub fn setCallbacks(self: *VtReal, callbacks: *const seat.Seat.Callbacks, userdata: usize) void {
        self.callbacks = callbacks;
        self.userdata = userdata;
    }

    fn fire(self: *VtReal, comptime field: []const u8) void {
        const cbs = self.callbacks orelse return;
        self.guard.dispatch(@field(cbs, field), self.userdata);
    }

    // --------------------------------------------------------------- close

    /// Restore the console and close the fd: KDSKBMODE saved, VT_SETMODE
    /// VT_AUTO, KDSETMODE KD_TEXT, close (kmscon `real_close` order).
    /// Idempotent; fires `deactivated` if we still owned the console.
    pub fn deinit(self: *VtReal) void {
        self.closeInternal();
        self.callbacks = null;
        self.userdata = 0;
    }

    fn closeInternal(self: *VtReal) void {
        if (self.vt_fd < 0) return;

        if (self.active) {
            self.active = false;
            self.fire("deactivated");
        }

        if (!self.restoreKbmode())
            log.warn("VT {d}: cannot restore KBMODE on close", .{self.num});
        if (!self.setVtMode(.auto))
            log.warn("VT {d}: cannot restore VT_AUTO on close", .{self.num});
        if (!self.setKdMode(seat.kd_mode.text))
            log.warn("VT {d}: cannot restore KD_TEXT on close", .{self.num});

        self.sys.close(self.sys.ctx, self.vt_fd);
        self.vt_fd = -1;
        self.num = 0;
        self.path_len = 0;
        self.mode_taken = false;
        self.paused = false;
    }

    // ------------------------------------------------------------- helpers

    const AutoOrProcess = enum { auto, process };

    fn ioctlOk(self: *const VtReal, fd: posix.fd_t, request: u32, arg: usize) bool {
        return self.sys.ioctl(self.sys.ctx, fd, request, arg) >= 0;
    }

    /// VT_RELDISP(1): allow a pending switch. EINVAL is the kernel's answer
    /// when no switch is pending (`vt_reldisp`: `vt_newvt < 0` plus a
    /// non-VT_ACKACQ argument), which under VT_PROCESS can only mean
    /// "nothing to release" — success for our purpose.
    fn ackRelease(self: *const VtReal) bool {
        const rc = self.sys.ioctl(self.sys.ctx, self.vt_fd, vt.reldisp, vt.release_ack);
        return rc >= 0 or rc == einval;
    }

    fn setKdMode(self: *const VtReal, mode: u8) bool {
        return self.ioctlOk(self.vt_fd, kd.setmode, mode);
    }

    fn setVtMode(self: *const VtReal, comptime mode: AutoOrProcess) bool {
        const vm = switch (mode) {
            .auto => VtMode{},
            .process => processMode(),
        };
        return self.ioctlOk(self.vt_fd, vt.setmode, @intFromPtr(&vm));
    }

    fn restoreKbmode(self: *VtReal) bool {
        if (!self.kbmode_saved) return true;
        const arg: usize = if (self.saved_kbmode >= 0) @intCast(self.saved_kbmode) else kd.unicode;
        self.kbmode_saved = false;
        return self.ioctlOk(self.vt_fd, kd.setkbmode, arg);
    }

    fn processMode() VtMode {
        return .{
            .mode = vt.process,
            .waitv = 0,
            .relsig = @intCast(@intFromEnum(release_signal)),
            .acqsig = @intCast(@intFromEnum(acquire_signal)),
            .frsig = 0,
        };
    }

    // -------------------------------------------------------------- vtable

    const vtable = seat.Seat.VTable{
        .deinit = vtDeinit,
        .activate = vtActivate,
        .deactivate = vtDeactivate,
        .isActive = vtIsActive,
        .pause = vtPause,
        .resume_ = vtResume,
        .setCallbacks = vtSetCallbacks,
    };

    fn cast(ptr: *anyopaque) *VtReal {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn vtActivate(ptr: *anyopaque) anyerror!void {
        try cast(ptr).activate();
    }

    fn vtDeactivate(ptr: *anyopaque) anyerror!void {
        try cast(ptr).deactivate();
    }

    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).isActive();
    }

    fn vtPause(ptr: *anyopaque) anyerror!void {
        try cast(ptr).pause();
    }

    fn vtResume(ptr: *anyopaque) anyerror!void {
        try cast(ptr).resume_();
    }

    fn vtSetCallbacks(ptr: *anyopaque, callbacks: *const seat.Seat.Callbacks, userdata: usize) void {
        cast(ptr).setCallbacks(callbacks, userdata);
    }
};

// ---------------------------------------------------------------------------
// Tests: a fake kernel that records every ioctl/open/close.
// ---------------------------------------------------------------------------

const eio: isize = -@as(isize, @intCast(@intFromEnum(linux.E.IO)));

/// One recorded syscall. `mode`/`stat` are decoded copies, so assertions do
/// not depend on pointers into the seat.
const Call = struct {
    kind: Kind,
    fd: posix.fd_t = -1,
    request: u32 = 0,
    arg: usize = 0,
    path: [path_buf_len]u8 = @splat(0),
    path_len: usize = 0,
    mode: ?VtMode = null,
    stat: ?VtStat = null,

    const Kind = enum { open, close, ioctl };

    fn setPath(self: *Call, s: []const u8) void {
        const n = @min(s.len, self.path.len);
        @memcpy(self.path[0..n], s[0..n]);
        self.path_len = n;
    }

    fn pathSlice(self: *const Call) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// A fake kernel. Fds are handed out in sequence from `next_fd` so the
/// control fd and the VT fd are distinguishable.
const Fake = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,

    next_fd: isize = 3,
    active_vt: u16 = 3,
    kbmode: i32 = kd.unicode,
    fail_open: bool = false,
    /// This request returns -EIO.
    fail_request: ?u32 = null,
    /// Leading VT_WAITACTIVE calls that return -EINTR.
    eintr: usize = 0,
    /// Result of VT_RELDISP unless `fail_request` already covers it.
    reldisp_rc: isize = 0,
    now_ns: i64 = 0,
    now_step: i64 = std.time.ns_per_s,

    fn init(a: std.mem.Allocator) Fake {
        return .{ .allocator = a };
    }

    fn deinit(self: *Fake) void {
        self.calls.deinit(self.allocator);
    }

    fn sys(self: *Fake) Sys {
        return .{
            .ctx = self,
            .ioctl = fakeIoctl,
            .open = fakeOpen,
            .close = fakeClose,
            .now = fakeNow,
        };
    }

    fn record(self: *Fake, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake: oom");
    }

    /// Requests of every ioctl recorded from call index `start`.
    fn requestsFrom(self: *const Fake, start: usize, buf: []u32) []const u32 {
        var n: usize = 0;
        for (self.calls.items[start..]) |c| {
            if (c.kind != .ioctl) continue;
            buf[n] = c.request;
            n += 1;
        }
        return buf[0..n];
    }

    fn requests(self: *const Fake, buf: []u32) []const u32 {
        return self.requestsFrom(0, buf);
    }

    /// The last recorded ioctl for `request`.
    fn lastIoctl(self: *const Fake, request: u32) ?Call {
        var i = self.calls.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.calls.items[i];
            if (c.kind == .ioctl and c.request == request) return c;
        }
        return null;
    }

    fn ioctlArgs(self: *const Fake, buf: []usize) []const usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c.kind != .ioctl) continue;
            buf[n] = c.arg;
            n += 1;
        }
        return buf[0..n];
    }

    fn fakeIoctl(ctx: ?*anyopaque, fd: posix.fd_t, request: u32, arg: usize) isize {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        var call = Call{ .kind = .ioctl, .fd = fd, .request = request, .arg = arg };
        switch (request) {
            vt.setmode => {
                const m: *const VtMode = @ptrFromInt(arg);
                call.mode = m.*;
            },
            vt.getstate => {
                const st: *VtStat = @ptrFromInt(arg);
                st.* = .{ .v_active = self.active_vt };
                call.stat = st.*;
            },
            kd.getkbmode => {
                const kb: *i32 = @ptrFromInt(arg);
                kb.* = self.kbmode;
            },
            else => {},
        }
        self.record(call);

        if (self.fail_request == request) return eio;
        if (request == vt.reldisp) return self.reldisp_rc;
        if (request == vt.waitactive and self.eintr > 0) {
            self.eintr -= 1;
            return eintr;
        }
        return 0;
    }

    fn fakeOpen(ctx: ?*anyopaque, path: [*:0]const u8, flags: u32) isize {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        var call = Call{ .kind = .open, .arg = flags };
        call.setPath(std.mem.span(path));
        self.record(call);
        if (self.fail_open) return eio;
        const fd = self.next_fd;
        self.next_fd += 1;
        return fd;
    }

    fn fakeClose(ctx: ?*anyopaque, fd: posix.fd_t) void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.record(.{ .kind = .close, .fd = fd });
    }

    fn fakeNow(ctx: ?*anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.now_ns += self.now_step;
        return self.now_ns;
    }
};

const Counters = struct {
    activated: usize = 0,
    deactivated: usize = 0,
    paused: usize = 0,
    resumed: usize = 0,

    fn onActivated(ud: usize) void {
        const c: *Counters = @ptrFromInt(ud);
        c.activated += 1;
    }
    fn onDeactivated(ud: usize) void {
        const c: *Counters = @ptrFromInt(ud);
        c.deactivated += 1;
    }
    fn onPause(ud: usize) void {
        const c: *Counters = @ptrFromInt(ud);
        c.paused += 1;
    }
    fn onResume(ud: usize) void {
        const c: *Counters = @ptrFromInt(ud);
        c.resumed += 1;
    }

    const callbacks = seat.Seat.Callbacks{
        .activated = onActivated,
        .deactivated = onDeactivated,
        .pause = onPause,
        .resume_ = onResume,
    };
};

/// Open a VT that is already the active one (no switch), for tests that only
/// care about the activate/deactivate side.
fn openActive(fake: *Fake, v: *VtReal, num: u8) !void {
    fake.active_vt = num;
    v.* = VtReal.init(fake.sys());
    _ = try v.openVt(num, false);
}

test "openVt: requested VT already active opens it without switching" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    fake.active_vt = 3;
    var v = VtReal.init(fake.sys());

    const info = try v.openVt(3, true);

    try std.testing.expectEqual(@as(u8, 3), info.vt_num);
    try std.testing.expectEqualStrings("/dev/tty3", info.path);
    try std.testing.expectEqual(@as(posix.fd_t, 3), v.vt_fd);
    try std.testing.expectEqual(@as(u8, 3), v.vtNum());
    try std.testing.expectEqualStrings("/dev/tty3", v.path());

    try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try std.testing.expectEqual(Call.Kind.open, fake.calls.items[0].kind);
    try std.testing.expectEqualStrings("/dev/tty3", fake.calls.items[0].pathSlice());
    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{vt.getstate}, fake.requests(&buf));
}

test "openVt: null queries VT_GETSTATE on /dev/tty0 and uses the active VT" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    fake.active_vt = 4;
    var v = VtReal.init(fake.sys());

    const info = try v.openVt(null, false);

    try std.testing.expectEqual(@as(u8, 4), info.vt_num);
    try std.testing.expectEqualStrings("/dev/tty4", info.path);
    try std.testing.expectEqual(@as(posix.fd_t, 4), v.vt_fd); // 3 was the control fd

    try std.testing.expectEqual(@as(usize, 5), fake.calls.items.len);
    try std.testing.expectEqual(Call.Kind.open, fake.calls.items[0].kind);
    try std.testing.expectEqualStrings("/dev/tty0", fake.calls.items[0].pathSlice());
    try std.testing.expectEqual(Call.Kind.ioctl, fake.calls.items[1].kind);
    try std.testing.expectEqual(vt.getstate, fake.calls.items[1].request);
    try std.testing.expectEqual(Call.Kind.close, fake.calls.items[2].kind);
    try std.testing.expectEqual(@as(posix.fd_t, 3), fake.calls.items[2].fd);
    try std.testing.expectEqualStrings("/dev/tty4", fake.calls.items[3].pathSlice());
    try std.testing.expectEqual(vt.getstate, fake.calls.items[4].request);
}

test "openVt: switchvt issues VT_ACTIVATE then VT_WAITACTIVE" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    fake.active_vt = 1;
    var v = VtReal.init(fake.sys());

    _ = try v.openVt(2, true);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ vt.getstate, vt.activate, vt.waitactive },
        fake.requests(&buf),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.calls.items[2].arg);
    try std.testing.expectEqual(@as(usize, 2), fake.calls.items[3].arg);

    // Without switchvt the same target is opened but not activated.
    var fake2 = Fake.init(std.testing.allocator);
    defer fake2.deinit();
    fake2.active_vt = 1;
    var v2 = VtReal.init(fake2.sys());
    _ = try v2.openVt(2, false);
    try std.testing.expectEqualSlices(u32, &.{vt.getstate}, fake2.requests(&buf));
}

test "openVt: VT numbers outside 1..=63 are rejected without syscalls" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v = VtReal.init(fake.sys());

    try std.testing.expectError(error.InvalidVt, v.openVt(0, false));
    try std.testing.expectError(error.InvalidVt, v.openVt(64, false));
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
}

test "openVt: failures map to the contract errors and leak no fd" {
    // open(2) failure.
    {
        var fake = Fake.init(std.testing.allocator);
        defer fake.deinit();
        fake.fail_open = true;
        var v = VtReal.init(fake.sys());
        try std.testing.expectError(error.OpenFailed, v.openVt(2, false));
        try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
    }
    // VT_GETSTATE on /dev/tty0 fails: the control fd is closed anyway.
    {
        var fake = Fake.init(std.testing.allocator);
        defer fake.deinit();
        fake.fail_request = vt.getstate;
        var v = VtReal.init(fake.sys());
        try std.testing.expectError(error.IoctlFailed, v.openVt(null, false));
        try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
        try std.testing.expectEqual(Call.Kind.close, fake.calls.items[2].kind);
    }
    // VT_WAITACTIVE fails: the VT fd is closed by the errdefer.
    {
        var fake = Fake.init(std.testing.allocator);
        defer fake.deinit();
        fake.active_vt = 1;
        fake.fail_request = vt.waitactive;
        var v = VtReal.init(fake.sys());
        try std.testing.expectError(error.WaitFailed, v.openVt(2, true));
        try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
        try std.testing.expectEqual(Call.Kind.close, fake.calls.items[fake.calls.items.len - 1].kind);
    }
    // A VT_WAITACTIVE that only returns EINTR must give up at the deadline.
    {
        var fake = Fake.init(std.testing.allocator);
        defer fake.deinit();
        fake.active_vt = 1;
        fake.eintr = 10;
        fake.now_step = std.time.ns_per_s;
        var v = VtReal.init(fake.sys());
        v.wait_timeout_ns = 2 * std.time.ns_per_s;
        try std.testing.expectError(error.WaitFailed, v.openVt(2, true));
        try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
    }
}

test "activate: KD_GRAPHICS, VT_PROCESS with kmscon signal numbers, keyboard off" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));

    const base = fake.calls.items.len;
    try v.activate();

    try std.testing.expect(v.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ kd.setmode, vt.setmode, kd.getkbmode, kd.setkbmode, kd.setkbmode },
        fake.requestsFrom(base, &buf),
    );

    const setmode_kd = fake.calls.items[base];
    try std.testing.expectEqual(@as(usize, seat.kd_mode.graphics), setmode_kd.arg);

    const mode = fake.calls.items[base + 1].mode.?;
    try std.testing.expectEqual(vt.process, mode.mode);
    try std.testing.expectEqual(@as(u8, 0), mode.waitv);
    try std.testing.expectEqual(@as(i16, @intCast(@intFromEnum(release_signal))), mode.relsig);
    try std.testing.expectEqual(@as(i16, @intCast(@intFromEnum(acquire_signal))), mode.acqsig);
    try std.testing.expectEqual(@as(i16, 0), mode.frsig);

    try std.testing.expectEqual(@as(usize, kd.raw), fake.calls.items[base + 3].arg);
    try std.testing.expectEqual(@as(usize, kd.off), fake.calls.items[base + 4].arg);
}

test "activate: K_OFF is not restored as the previous keyboard mode" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    fake.kbmode = kd.off; // a stale K_OFF left by a previous owner
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    try v.activate();
    try std.testing.expectEqual(@as(i32, kd.unicode), v.saved_kbmode);

    try v.deactivate();
    try std.testing.expectEqual(@as(usize, kd.unicode), fake.lastIoctl(kd.setkbmode).?.arg);
}

test "activate is idempotent" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    try v.activate();
    const n = fake.calls.items.len;
    try v.activate();
    try std.testing.expectEqual(n, fake.calls.items.len);
    try std.testing.expect(v.isActive());
}

test "deactivate: ack release, KD_TEXT, restore kbmode, VT_AUTO" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();
    const base = fake.calls.items.len;

    try v.deactivate();

    try std.testing.expect(!v.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ vt.reldisp, kd.setmode, kd.setkbmode, vt.setmode },
        fake.requestsFrom(base, &buf),
    );
    try std.testing.expectEqual(@as(usize, vt.release_ack), fake.calls.items[base].arg);
    try std.testing.expectEqual(@as(usize, seat.kd_mode.text), fake.calls.items[base + 1].arg);
    try std.testing.expectEqual(@as(usize, kd.unicode), fake.calls.items[base + 2].arg);
    try std.testing.expectEqual(vt.auto, fake.calls.items[base + 3].mode.?.mode);

    // Second deactivate: nothing owns the console any more, no ioctls.
    const after = fake.calls.items.len;
    try v.deactivate();
    try std.testing.expectEqual(after, fake.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);
}

test "deactivate before activate is a no-op" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    const n = fake.calls.items.len;
    try v.deactivate();
    try std.testing.expectEqual(n, fake.calls.items.len);
}

test "deactivate: VT_RELDISP EINVAL means no pending switch, other errors surface" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);

    // No switch was requested: the kernel answers EINVAL and deactivate
    // still restores everything.
    fake.reldisp_rc = einval;
    try v.activate();
    try v.deactivate();
    try std.testing.expect(!v.isActive());
    try std.testing.expect(!v.mode_taken);

    fake.reldisp_rc = eio;
    try v.activate();
    try std.testing.expectError(error.IoctlFailed, v.deactivate());
    try std.testing.expect(!v.isActive());
    try std.testing.expect(!v.mode_taken);
    v.deinit();
}

test "release signal: notify + VT_RELDISP(1), keep VT_PROCESS, no KD_TEXT" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();
    const base = fake.calls.items.len;

    try v.handleSignal(@intFromEnum(release_signal));

    try std.testing.expect(!v.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ vt.getstate, vt.reldisp }, fake.requestsFrom(base, &buf));
    try std.testing.expectEqual(@as(usize, vt.release_ack), fake.calls.items[base + 1].arg);
    // VT_PROCESS must still be installed or the acquire signal never comes.
    try std.testing.expect(v.mode_taken);
    try std.testing.expectEqual(vt.process, fake.lastIoctl(vt.setmode).?.mode.?.mode);
}

test "acquire signal: VT_RELDISP(VT_ACKACQ) then activate" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();
    try v.handleSignal(@intFromEnum(release_signal));

    // The kernel left our VT with K_OFF; restore must not reuse it.
    fake.kbmode = kd.off;
    const base = fake.calls.items.len;
    try v.handleSignal(@intFromEnum(acquire_signal));

    try std.testing.expect(v.isActive());
    try std.testing.expectEqual(@as(usize, 2), counters.activated);

    var buf: [16]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ vt.getstate, vt.reldisp, kd.setmode, vt.setmode, kd.getkbmode, kd.setkbmode, kd.setkbmode },
        fake.requestsFrom(base, &buf),
    );
    try std.testing.expectEqual(@as(usize, vt.ackacq), fake.calls.items[base + 1].arg);

    try v.deactivate();
    try std.testing.expectEqual(@as(usize, kd.unicode), fake.lastIoctl(kd.setkbmode).?.arg);
}

test "signals for another VT or unknown signals are ignored" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();

    fake.active_vt = 9; // somebody else owns the console now
    const base = fake.calls.items.len;
    try v.handleSignal(@intFromEnum(release_signal));
    try v.handleSignal(@intFromEnum(acquire_signal));

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ vt.getstate, vt.getstate }, fake.requestsFrom(base, &buf));
    try std.testing.expect(v.isActive());
    try std.testing.expectEqual(@as(usize, 0), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 1), counters.activated);

    const after = fake.calls.items.len;
    try v.handleSignal(15); // SIGTERM is not ours
    try v.handleSignal(28);
    try std.testing.expectEqual(after, fake.calls.items.len);
}

test "pause/resume: deactivate/activate plus their own callbacks" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();

    const base = fake.calls.items.len;
    try v.pause();
    try std.testing.expect(!v.isActive());
    try std.testing.expect(v.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ vt.reldisp, kd.setmode, kd.setkbmode, vt.setmode },
        fake.requestsFrom(base, &buf),
    );

    // pause is idempotent.
    const after_pause = fake.calls.items.len;
    try v.pause();
    try std.testing.expectEqual(after_pause, fake.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), counters.paused);

    const base2 = fake.calls.items.len;
    try v.resume_();
    try std.testing.expect(v.isActive());
    try std.testing.expect(!v.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);
    try std.testing.expectEqual(@as(usize, 2), counters.activated);
    try std.testing.expectEqualSlices(
        u32,
        &.{ kd.setmode, vt.setmode, kd.getkbmode, kd.setkbmode, kd.setkbmode },
        fake.requestsFrom(base2, &buf),
    );

    // resume_ without a pause is a no-op.
    const after_resume = fake.calls.items.len;
    try v.resume_();
    try std.testing.expectEqual(after_resume, fake.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);
}

test "deinit restores the console, closes the fd and is idempotent" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);

    var counters = Counters{};
    v.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));
    try v.activate();
    const base = fake.calls.items.len;

    v.deinit();

    try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
    try std.testing.expectEqual(@as(u8, 0), v.vtNum());
    try std.testing.expectEqualStrings("", v.path());
    try std.testing.expect(!v.isActive());
    try std.testing.expectEqual(@as(usize, 1), counters.deactivated);

    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ kd.setkbmode, vt.setmode, kd.setmode },
        fake.requestsFrom(base, &buf),
    );
    try std.testing.expectEqual(@as(usize, kd.unicode), fake.calls.items[base].arg);
    try std.testing.expectEqual(vt.auto, fake.calls.items[base + 1].mode.?.mode);
    try std.testing.expectEqual(@as(usize, seat.kd_mode.text), fake.calls.items[base + 2].arg);
    try std.testing.expectEqual(Call.Kind.close, fake.calls.items[base + 3].kind);
    try std.testing.expectEqual(@as(posix.fd_t, 3), fake.calls.items[base + 3].fd);

    const after = fake.calls.items.len;
    v.deinit();
    try std.testing.expectEqual(after, fake.calls.items.len);
}

test "openVt on an open seat restores and closes the previous VT first" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    try v.activate();
    const base = fake.calls.items.len;

    fake.active_vt = 5;
    const info = try v.openVt(5, false);

    try std.testing.expectEqual(@as(u8, 5), info.vt_num);
    try std.testing.expectEqual(@as(posix.fd_t, 4), v.vt_fd);
    var buf: [16]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ kd.setkbmode, vt.setmode, kd.setmode, vt.getstate },
        fake.requestsFrom(base, &buf),
    );
    // close(3) (the old VT) precedes open("/dev/tty5").
    var saw_close = false;
    var saw_open = false;
    for (fake.calls.items[base..]) |c| {
        if (c.kind == .close and c.fd == 3) saw_close = true;
        if (c.kind == .open and std.mem.eql(u8, c.pathSlice(), "/dev/tty5")) {
            saw_open = true;
            try std.testing.expect(saw_close);
        }
    }
    try std.testing.expect(saw_open);
}

/// Re-entrant callback: deactivates from inside the activated delivery.
const Reentrant = struct {
    v: *VtReal,
    deactivated: usize = 0,

    fn onActivated(ud: usize) void {
        const r: *Reentrant = @ptrFromInt(ud);
        r.v.deactivate() catch {};
    }
    fn onDeactivated(ud: usize) void {
        const r: *Reentrant = @ptrFromInt(ud);
        r.deactivated += 1;
    }
};

test "re-entrant deactivate from the activated callback is guarded" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);
    defer v.deinit();

    var re = Reentrant{ .v = &v };
    const cbs = seat.Seat.Callbacks{
        .activated = Reentrant.onActivated,
        .deactivated = Reentrant.onDeactivated,
    };
    v.setCallbacks(&cbs, @intFromPtr(&re));

    const base = fake.calls.items.len;
    try v.activate();

    // The state change of the nested deactivate applies, the nested
    // deactivated delivery is dropped by CallbackGuard.
    try std.testing.expect(!v.isActive());
    try std.testing.expectEqual(@as(usize, 0), re.deactivated);
    try std.testing.expectEqual(@as(usize, 0), v.guard.depth);
    var buf: [16]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ kd.setmode, vt.setmode, kd.getkbmode, kd.setkbmode, kd.setkbmode, vt.reldisp, kd.setmode, kd.setkbmode, vt.setmode },
        fake.requestsFrom(base, &buf),
    );
}

test "seat vtable forwards every operation" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    var v: VtReal = undefined;
    try openActive(&fake, &v, 3);

    var counters = Counters{};
    const s = v.asSeat();
    s.setCallbacks(&Counters.callbacks, @intFromPtr(&counters));

    try s.activate();
    try std.testing.expect(s.isActive());
    try s.pause();
    try s.resume_();
    try s.deactivate();
    try std.testing.expectEqual(@as(usize, 2), counters.activated);
    try std.testing.expectEqual(@as(usize, 2), counters.deactivated);
    try std.testing.expectEqual(@as(usize, 1), counters.paused);
    try std.testing.expectEqual(@as(usize, 1), counters.resumed);
    s.deinit();
    try std.testing.expectEqual(@as(posix.fd_t, -1), v.vt_fd);
}