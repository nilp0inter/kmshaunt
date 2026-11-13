//! src/loop.zig -- epoll event loop with timerfd and signalfd integration
//! (ROADMAP M1.1, threading decision D2).
//!
//! One thread, one epoll loop. `Loop` owns an epoll fd; timers (`Timer`) and
//! signal notifications (`SignalSource`) register as ordinary sources. No
//! dynamic allocation anywhere: the source registry is a fixed array inside
//! `Loop` and dispatch works on the batch snapshot epoll_wait returns.
//!
//! Removal during dispatch (strategy, see also `Loop` docs):
//!   each source lives in a fixed slot and is identified by `Token`
//!   (slot index + generation counter). `epoll_event.data` carries the
//!   token; after epoll_wait the batch is validated entry-by-entry against
//!   the registry so a source removed by any handler in the same batch (its
//!   own or another one) is skipped rather than dereferenced, and a freed
//!   slot reused by a later addSource cannot alias a stale entry.
//!
//! `stop()` is observed on the next `runOnce`/`run` cycle. Handlers run in
//! this loop's thread, so stopping from a handler works immediately; a
//! `runOnce` already blocked in epoll_wait is not preempted (use a bounded
//! timeout or a self-pipe if prompt wakeup is needed).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Maximum number of sources registered with one Loop.
pub const max_sources: usize = 256;

/// Raw epoll event mask. Handlers receive the interest events actually
/// reported (readiness + any of `ev.err`/`ev.hup` that the kernel attaches).
pub const Events = u32;

/// Common epoll event bits. `EPOLLIN` is spelled `in_` ("in" is a keyword).
pub const ev = struct {
    pub const in_: Events = linux.EPOLL.IN;
    pub const pri: Events = linux.EPOLL.PRI;
    pub const out: Events = linux.EPOLL.OUT;
    pub const err: Events = linux.EPOLL.ERR;
    pub const hup: Events = linux.EPOLL.HUP;
    pub const rd_hup: Events = linux.EPOLL.RDHUP;
    pub const edge_triggered: Events = linux.EPOLL.ET;
};

/// Opaque handle to a registered source. Do not fabricate these; keep the
/// value returned by `Loop.addSource`.
pub const Token = struct {
    index: u8,
    generation: u32,

    fn toU64(self: Token) u64 {
        return (@as(u64, self.index) << 32) | @as(u64, self.generation);
    }

    fn fromU64(raw: u64) Token {
        return .{
            .index = @truncate(raw >> 32),
            .generation = @truncate(raw),
        };
    }
};

/// Source handler; runs synchronously in the loop thread.
/// `events` is the raw epoll mask, `userdata` the value from addSource.
pub const Handler = *const fn (loop: *Loop, token: Token, userdata: usize, events: Events) void;

/// epoll reactor.
///
/// Dispatch/removal safety strategy: sources sit in a fixed-capacity slot
/// registry (`sources` + `generations`). `Token` is (slot index, generation).
/// epoll_wait returns a snapshot batch; dispatch re-checks slot occupancy and
/// generation for every entry before invoking the handler, so:
///   - a handler removing its own source keeps running and the loop is fine;
///   - a handler removing *another* source that also has an event in this
///     batch yields a generation mismatch for the stale entry, which is then
///     skipped (no deferred-removal list, no EPOLLONESHOT re-arm dance);
///   - a slot freed mid-batch and reused by a new addSource gets a fresh
///     generation, so the stale entry can never alias the new source.
/// Generation wrap-around after 2^32 removals of one slot is not handled
/// (would take ~13 years at 10 removals/ns; ignored on purpose).
pub const Loop = struct {
    epoll_fd: posix.fd_t,
    stopped: bool = false,
    sources: [max_sources]?Source = @splat(null),
    generations: [max_sources]u32 = @splat(0),

    pub const Source = struct {
        fd: posix.fd_t,
        events: Events,
        handler: Handler,
        userdata: usize,
    };

    pub const InitError = error{ OutOfMemory, ProcessFdQuotaExceeded, SystemFdQuotaExceeded } ||
        posix.UnexpectedError;

    pub const AddError = error{ FdAlreadyAdded, OutOfSlots, InvalidFd, UnsupportedFd, OutOfMemory } ||
        posix.UnexpectedError;

    pub const ModifyError = error{ InvalidFd, InvalidToken } || posix.UnexpectedError;

    /// epoll_wait only ever fails with EINTR (retried) or programmer bugs
    /// (bad fd, bad buffer); the latter are unreachable if this module is
    /// used as intended.
    pub const RunOnceError = error{};

    /// Create an epoll fd (EPOLL_CLOEXEC) and an empty source registry.
    pub fn init() InitError!Loop {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        return switch (linux.errno(rc)) {
            .SUCCESS => Loop{ .epoll_fd = @intCast(rc) },
            .NOMEM => error.OutOfMemory,
            .NFILE => error.SystemFdQuotaExceeded,
            .MFILE => error.ProcessFdQuotaExceeded,
            .INVAL => unreachable, // only CLOEXEC passed; invalid flags impossible
            else => |e| posix.unexpectedErrno(e),
        };
    }

    /// Close the epoll fd. Sources do not need individual removal first;
    /// their registrations die with the fd. The Loop must outlive its
    /// sources' deinit calls (removeSource tolerates a closed epoll fd).
    pub fn deinit(self: *Loop) void {
        if (self.epoll_fd != -1) {
            closeFd(self.epoll_fd);
            self.epoll_fd = -1;
        }
    }

    /// Register a source. `handler` is stored per source (not in
    /// epoll_event.data, which carries only the token) and invoked with
    /// `userdata` on readiness. One registration per fd.
    pub fn addSource(
        self: *Loop,
        fd: posix.fd_t,
        events: Events,
        handler: Handler,
        userdata: usize,
    ) AddError!Token {
        for (self.sources) |maybe_src| {
            if (maybe_src) |src| {
                if (src.fd == fd) return error.FdAlreadyAdded;
            }
        }
        var index: ?usize = null;
        for (&self.sources, 0..) |*maybe_src, i| {
            if (maybe_src.* == null) {
                index = i;
                break;
            }
        }
        const idx = index orelse return error.OutOfSlots;

        const token = Token{ .index = @intCast(idx), .generation = self.generations[idx] };
        var evt = linux.epoll_event{ .events = events, .data = .{ .u64 = token.toU64() } };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &evt);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .EXIST => return error.FdAlreadyAdded,
            .BADF => return error.InvalidFd, // fd already closed
            .INVAL => unreachable, // epoll fd or events are invalid for us
            .PERM => return error.UnsupportedFd, // fd type does not support epoll
            .NOMEM => return error.OutOfMemory,
            else => |e| return posix.unexpectedErrno(e),
        }
        self.sources[idx] = .{ .fd = fd, .events = events, .handler = handler, .userdata = userdata };
        return token;
    }

    /// Unregister a source. Safe to call from inside a handler, for the
    /// source's own token or another source's. Stale or already-removed
    /// tokens are ignored. Errors are ignored on purpose: EPOLL_CTL_DEL on a
    /// closed epoll fd (EBADF) or an fd that epoll already dropped (ENOENT)
    /// still leaves us with the slot freed, which is what matters.
    pub fn removeSource(self: *Loop, token: Token) void {
        const idx: usize = token.index;
        if (idx >= max_sources) return;
        if (self.sources[idx]) |src| {
            if (self.generations[idx] != token.generation) return; // stale token
            const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, src.fd, null);
            switch (linux.errno(rc)) {
                .SUCCESS, .BADF, .NOENT => {},
                else => |e| {
                    if (std.options.unexpected_error_tracing) {
                        std.debug.print("loop: removeSource: unexpected errno {d}\n", .{@backingInt(e)});
                    }
                },
            }
            self.generations[idx] +%= 1;
            self.sources[idx] = null;
        }
    }

    /// Change the interest mask of a registered source. The token is
    /// rewritten into epoll_event.data so the batch snapshot stays
    /// consistent with the registry.
    pub fn modifySource(self: *Loop, token: Token, events: Events) ModifyError!void {
        const idx: usize = token.index;
        if (idx >= max_sources) return error.InvalidToken;
        if (self.generations[idx] != token.generation) return error.InvalidToken;
        const src = self.sources[idx] orelse return error.InvalidToken;
        var evt = linux.epoll_event{ .events = events, .data = .{ .u64 = token.toU64() } };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, src.fd, &evt);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .BADF => return error.InvalidFd,
            else => |e| return posix.unexpectedErrno(e),
        }
        self.sources[idx].?.events = events;
    }

    fn waitBatch(self: *Loop, events: []linux.epoll_event, timeout_ms: i32) usize {
        while (true) {
            const rc = linux.epoll_wait(self.epoll_fd, events.ptr, @intCast(events.len), timeout_ms);
            switch (linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue, // spurious wakeup: retry, as required
                else => unreachable, // EBADF/EFAULT/EINVAL are programmer bugs
            }
        }
    }

    /// Wait up to `timeout_ms` (null = forever, 0 = poll) and dispatch every
    /// ready source. Returns the number of handlers dispatched. If `stop()`
    /// was called, returns 0 immediately; if a handler calls `stop()` mid-
    /// batch, the remaining batch entries are skipped and the count reflects
    /// only what ran.
    pub fn runOnce(self: *Loop, timeout_ms: ?i32) RunOnceError!usize {
        if (self.stopped) return 0;
        const timeout: i32 = timeout_ms orelse -1;
        var events: [64]linux.epoll_event = undefined;
        const n = self.waitBatch(&events, timeout);
        var dispatched: usize = 0;
        for (events[0..n]) |evt| {
            if (self.stopped) break;
            const token = Token.fromU64(evt.data.u64);
            if (self.generations[token.index] != token.generation) continue; // removed mid-batch
            const src = self.sources[token.index] orelse continue;
            (src.handler)(self, token, src.userdata, evt.events);
            dispatched += 1;
        }
        return dispatched;
    }

    /// Run until `stop()` is called (from any handler).
    pub fn run(self: *Loop) RunOnceError!void {
        while (!self.stopped) {
            _ = try self.runOnce(null);
        }
    }

    /// Ask the loop to stop dispatching; takes effect at the next runOnce/
    /// run boundary.
    pub fn stop(self: *Loop) void {
        self.stopped = true;
    }
};

fn closeFd(fd: posix.fd_t) void {
    switch (linux.errno(linux.close(fd))) {
        .SUCCESS => {},
        // close() releases the fd even when it returns an error, and Linux
        // never blocks on close, so there is nothing to retry or report.
        else => {},
    }
}

/// A timerfd integrated into a Loop. Fires on a monotonic clock; the
/// callback is invoked with the number of expirations since the last read
/// (>= 1; > 1 only after a stall, because timerfd coalesces).
pub const Timer = struct {
    fd: posix.fd_t = -1,
    loop_: ?*Loop = null,
    token: Token = undefined,
    options: Options = undefined,

    pub const Callback = *const fn (self: *Timer, expirations: u64, userdata: usize) void;

    pub const Options = struct {
        callback: Callback,
        /// Opaque value handed back to the callback.
        userdata: usize = 0,
    };

    pub const InitError = error{ OutOfMemory, ProcessFdQuotaExceeded, SystemFdQuotaExceeded } ||
        Loop.AddError;

    pub const ArmError = error{ InvalidFd } || posix.UnexpectedError;

    /// Create a nonblocking CLOCK_MONOTONIC timerfd and register it in
    /// `loop` with EPOLLIN interest. The Loop must outlive this Timer.
    pub fn init(self: *Timer, loop_: *Loop, options: Options) InitError!void {
        const rc = linux.timerfd_create(
            linux.TIMERFD_CLOCK.MONOTONIC,
            .{ .NONBLOCK = true, .CLOEXEC = true },
        );
        const fd: posix.fd_t = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOMEM => return error.OutOfMemory,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL => unreachable, // clock/flags are fixed and valid
            else => |e| return posix.unexpectedErrno(e),
        };
        errdefer closeFd(fd);
        const token = loop_.addSource(fd, ev.in_, timerEventHandler, @intFromPtr(self)) catch |err| {
            return err;
        };
        self.* = .{ .fd = fd, .loop_ = loop_, .token = token, .options = options };
    }

    /// Unregister and close the timerfd.
    pub fn deinit(self: *Timer) void {
        if (self.loop_) |lp| {
            lp.removeSource(self.token);
            self.loop_ = null;
        }
        if (self.fd != -1) {
            closeFd(self.fd);
            self.fd = -1;
        }
    }

    /// General arm: first expiration after `value`, then every `interval`.
    /// Zero `value` disarms. Pass e.g. `nsToTimespec(ns)` for convenience.
    pub fn arm(self: *Timer, value: linux.timespec, interval: linux.timespec) ArmError!void {
        const new_value = linux.itimerspec{ .it_interval = interval, .it_value = value };
        const rc = linux.timerfd_settime(self.fd, linux.TFD.TIMER{}, &new_value, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .BADF => return error.InvalidFd,
            .INVAL => unreachable, // flags fixed; only bad fds remain
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    /// Fire once after `delay_ns`.
    pub fn armOneShot(self: *Timer, delay_ns: u64) ArmError!void {
        return self.arm(nsToTimespec(delay_ns), .{ .sec = 0, .nsec = 0 });
    }

    /// Fire every `interval_ns`, first fire after `interval_ns`.
    pub fn armInterval(self: *Timer, interval_ns: u64) ArmError!void {
        const ts = nsToTimespec(interval_ns);
        return self.arm(ts, ts);
    }

    /// Stop the timer. The source stays registered and can be armed again.
    pub fn disarm(self: *Timer) ArmError!void {
        const zero = linux.timespec{ .sec = 0, .nsec = 0 };
        return self.arm(zero, zero);
    }

    pub fn getFd(self: *const Timer) posix.fd_t {
        return self.fd;
    }

    fn timerEventHandler(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
        _ = loop_;
        _ = token;
        _ = events;
        const self: *Timer = @ptrFromInt(userdata);
        // Drain the expiration count. EAGAIN (nothing expired since the last
        // read) is harmless and skips the callback.
        var expirations: u64 = 0;
        const n = posix.read(self.fd, std.mem.asBytes(&expirations)) catch return;
        if (n == 0) return; // EOF cannot happen on a timerfd; be safe
        if (expirations > 0) {
            (self.options.callback)(self, expirations, self.options.userdata);
        }
    }
};

/// Convert ns to the timespec type timerfd_settime expects.
pub fn nsToTimespec(ns: u64) linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// Blocks a caller-selectable set of signals with rt_sigprocmask(2) and
/// exposes them through a nonblocking signalfd registered in a Loop. The
/// original thread signal mask is restored on deinit.
///
/// Blocked signals stay blocked (the process cannot die from them while this
/// source exists); the callback consumes them via signalfd reads.
pub const SignalSource = struct {
    fd: posix.fd_t = -1,
    loop_: *Loop = undefined,
    token: Token = undefined,
    old_mask: linux.sigset_t = undefined,
    options: Options = undefined,

    /// The default set a console usually cares about.
    pub const default_signals = [_]posix.SIG{ .TERM, .INT, .CHLD, .HUP };

    /// Per-signal data, copied out of signalfd_siginfo. `exit_code` is
    /// meaningful only for SIGCHLD: the raw child exit status for a clean
    /// exit (si_code == CLD_EXITED), or the terminating signal number for a
    /// signal death (si_code == CLD_KILLED). Unlike a wait(2) status it is
    /// NOT wait-encoded: signalfd(2) already delivers the decoded value, so
    /// no `>> 8` (WEXITSTATUS) shift is needed. `code` is si_code
    /// (CLD_EXITED == 1 for a clean exit).
    pub const Info = struct {
        signo: u32,
        code: i32,
        pid: u32,
        uid: u32,
        exit_code: i32,
    };

    pub const Callback = *const fn (self: *SignalSource, info: Info, userdata: usize) void;

    pub const Options = struct {
        callback: Callback,
        /// Opaque value handed back to the callback.
        userdata: usize = 0,
        /// Signals to block and receive. Duplicates are harmless.
        signals: []const posix.SIG = default_signals[0..],
    };

    pub const InitError = error{ OutOfMemory, ProcessFdQuotaExceeded, SystemFdQuotaExceeded } ||
        Loop.AddError;

    /// Apply `how` to the calling thread's signal mask with the raw
    /// rt_sigprocmask(2) syscall.
    ///
    /// The set is the kernel-ABI `linux.sigset_t` (one word, 8 bytes on
    /// x86_64), which is exactly what signalfd(2) consumes.
    /// `posix.sigprocmask` cannot be used here: under `-lc` it resolves to
    /// libc's `sigprocmask`, whose `posix.sigset_t` is the 128-byte library
    /// ABI, so handing it a kernel set is a type error (and the wrong size in
    /// principle). Going straight to the syscall is valid in both freestanding
    /// and libc builds -- libc's wrapper is a thin shim over this same call
    /// and keeps no userspace copy of the mask.
    fn setSignalMask(how: u32, set: ?*const linux.sigset_t, old_set: ?*linux.sigset_t) void {
        switch (linux.errno(linux.sigprocmask(how, set, old_set))) {
            .SUCCESS => return,
            // `how` is a compile-time constant and every pointer comes from a
            // live local, so the documented failure modes cannot occur.
            .FAULT, .INVAL => unreachable,
            else => unreachable,
        }
    }

    /// Block `options.signals`, create a nonblocking CLOEXEC signalfd, and
    /// register it in `loop` with EPOLLIN interest. The Loop must outlive
    /// this source.
    pub fn init(self: *SignalSource, loop_: *Loop, options: Options) InitError!void {
        var mask = linux.sigemptyset();
        for (options.signals) |sig| {
            linux.sigaddset(&mask, sig);
        }
        // Block first: signals sent between here and the signalfd creation
        // are queued and become visible through the fd instead of escaping.
        var old_mask: linux.sigset_t = undefined;
        setSignalMask(linux.SIG.BLOCK, &mask, &old_mask);
        errdefer setSignalMask(linux.SIG.SETMASK, &old_mask, null);

        const fd_rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        const fd: posix.fd_t = switch (linux.errno(fd_rc)) {
            .SUCCESS => @intCast(fd_rc),
            .NOMEM => return error.OutOfMemory,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .BADF, .INVAL => unreachable, // fd -1 and fixed flags
            else => |e| return posix.unexpectedErrno(e),
        };
        errdefer closeFd(fd);

        const token = loop_.addSource(fd, ev.in_, signalEventHandler, @intFromPtr(self)) catch |err| {
            return err;
        };
        self.* = .{ .fd = fd, .loop_ = loop_, .token = token, .old_mask = old_mask, .options = options };
    }

    /// Restore the thread signal mask saved by `init`. Pending signals are
    /// drained through the fd first so that restoring the mask cannot deliver
    /// (and fatally act on) a signal nobody consumed.
    pub fn deinit(self: *SignalSource) void {
        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            const n = posix.read(self.fd, std.mem.asBytes(&info)) catch break;
            if (n != @sizeOf(linux.signalfd_siginfo)) break;
            // Dropped on purpose: deinit means nobody wants them.
        }
        self.loop_.removeSource(self.token);
        if (self.fd != -1) {
            closeFd(self.fd);
            self.fd = -1;
        }
        setSignalMask(linux.SIG.SETMASK, &self.old_mask, null);
    }

    pub fn getFd(self: *const SignalSource) posix.fd_t {
        return self.fd;
    }

    fn signalEventHandler(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
        _ = loop_;
        _ = token;
        _ = events;
        const self: *SignalSource = @ptrFromInt(userdata);
        // Drain all pending signals: the fd is level-triggered, one
        // signalfd_siginfo per read, and every pending signal must reach
        // the callback exactly once.
        while (true) {
            var info: linux.signalfd_siginfo = undefined;
            const n = posix.read(self.fd, std.mem.asBytes(&info)) catch return;
            if (n != @sizeOf(linux.signalfd_siginfo)) return; // truncated read
            (self.options.callback)(self, .{
                .signo = info.signo,
                .code = info.code,
                .pid = info.pid,
                .uid = info.uid,
                .exit_code = info.status,
            }, self.options.userdata);
        }
    }
};

// ---------------------------------------------------------------- tests

const TestUtil = struct {
    fn pipe() ![2]posix.fd_t {
        var fds: [2]posix.fd_t = undefined;
        const rc = linux.pipe(&fds);
        switch (linux.errno(rc)) {
            .SUCCESS => return fds,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    fn writeByte(fd: posix.fd_t, b: u8) !void {
        const byte = [1]u8{b};
        const rc = linux.write(fd, &byte, byte.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    fn monotonicNs() u64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

test "Timer: one-shot fires once, within tolerance" {
    var lp = try Loop.init();
    defer lp.deinit();

    const Context = struct {
        fired: *usize,
        fired_ns: *u64,
        start_ns: u64,
        fn cb(self: *Timer, expirations: u64, userdata: usize) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.fired.* += 1;
            ctx.fired_ns.* = TestUtil.monotonicNs() - ctx.start_ns;
            _ = self;
            _ = expirations;
        }
    };

    var fired: usize = 0;
    var fired_ns: u64 = 0;
    var ctx = Context{ .fired = &fired, .fired_ns = &fired_ns, .start_ns = TestUtil.monotonicNs() };
    var timer: Timer = undefined;
    try timer.init(&lp, .{ .callback = Context.cb, .userdata = @intFromPtr(&ctx) });
    defer timer.deinit();

    const delay_ns: u64 = 50 * std.time.ns_per_ms;
    try timer.armOneShot(delay_ns);
    _ = try lp.runOnce(200); // well above the delay

    try std.testing.expectEqual(@as(usize, 1), fired);
    try std.testing.expect(fired_ns >= delay_ns);
    try std.testing.expect(fired_ns - delay_ns <= 200 * std.time.ns_per_ms);

    // One-shot: it must not fire again.
    _ = try lp.runOnce(150);
    try std.testing.expectEqual(@as(usize, 1), fired);
}

test "Timer: interval fires repeatedly until disarmed" {
    var lp = try Loop.init();
    defer lp.deinit();

    const Context = struct {
        fired: *usize,
        fn cb(self: *Timer, expirations: u64, userdata: usize) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.fired.* += 1;
            _ = self;
            _ = expirations;
        }
    };

    var fired: usize = 0;
    var ctx = Context{ .fired = &fired };

    var timer: Timer = undefined;
    try timer.init(&lp, .{ .callback = Context.cb, .userdata = @intFromPtr(&ctx) });
    defer timer.deinit();

    try timer.armInterval(5 * std.time.ns_per_ms);
    const start_ns = TestUtil.monotonicNs();
    while (TestUtil.monotonicNs() - start_ns < 40 * std.time.ns_per_ms) {
        _ = try lp.runOnce(40);
    }
    try std.testing.expect(fired >= 2);

    try timer.disarm();
    // Drain one expiration that may have raced the disarm, then assert
    // stability.
    _ = try lp.runOnce(50);
    const after_drain = fired;
    _ = try lp.runOnce(50);
    try std.testing.expectEqual(after_drain, fired);
}

test "SignalSource: blocked SIGTERM is observed and the process survives" {
    var lp = try Loop.init();
    defer lp.deinit();

    const Context = struct {
        got: *?SignalSource.Info,
        fn cb(self: *SignalSource, info: SignalSource.Info, userdata: usize) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.got.* = info;
            _ = self;
        }
    };

    var got: ?SignalSource.Info = null;
    var ctx = Context{ .got = &got };

    var ss: SignalSource = undefined;
    try ss.init(&lp, .{ .callback = Context.cb, .userdata = @intFromPtr(&ctx) });
    defer ss.deinit();

    // SIGTERM is in the blocked set, so this must not kill us: it goes to
    // the pending queue, appears on the signalfd, and is consumed there.
    try posix.kill(linux.getpid(), .TERM);
    _ = try lp.runOnce(500);

    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u32, @intFromEnum(posix.SIG.TERM)), got.?.signo);
}

test "SignalSource: SIGCHLD reports pid and exit status" {
    var lp = try Loop.init();
    defer lp.deinit();

    const Context = struct {
        got: *?SignalSource.Info,
        fn cb(self: *SignalSource, info: SignalSource.Info, userdata: usize) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.got.* = info;
            _ = self;
        }
    };

    var got: ?SignalSource.Info = null;
    var ctx = Context{ .got = &got };

    var ss: SignalSource = undefined;
    // Blocking SIGCHLD must happen before fork, or the default (ignore)
    // disposition eats the notification.
    try ss.init(&lp, .{ .callback = Context.cb, .userdata = @intFromPtr(&ctx) });
    defer ss.deinit();

    const rc = linux.fork();
    const child_pid: posix.pid_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.OutOfMemory,
        else => |e| return posix.unexpectedErrno(e),
    };
    if (child_pid == 0) {
        // Child: exit immediately with status 7; no allocation, no stdlib.
        linux.exit_group(7);
    }

    _ = try lp.runOnce(1000);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u32, @intFromEnum(posix.SIG.CHLD)), got.?.signo);
    try std.testing.expectEqual(@as(u32, @intCast(child_pid)), got.?.pid);
    // signalfd copies the decoded exit status (no wait(2) encoding): the
    // child exited with 7, so exit_code must be 7 directly.
    try std.testing.expectEqual(@as(i32, 7), got.?.exit_code);
    try std.testing.expect(got.?.code == 1); // si_code: CLD_EXITED

    // Reap the zombie. Here waitpid DOES use the wait(2) status encoding,
    // so the WEXITSTATUS decode is correct and must also yield 7.
    var wstatus: i32 = 0;
    const wrc = linux.waitpid(child_pid, &wstatus, 0);
    switch (linux.errno(wrc)) {
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
    }
    try std.testing.expectEqual(@as(i32, 7), (wstatus >> 8) & 0xff);
}

test "two sources dispatch in a single runOnce" {
    var lp = try Loop.init();
    defer lp.deinit();

    const pa = try TestUtil.pipe();
    defer closeFd(pa[0]);
    defer closeFd(pa[1]);
    const pb = try TestUtil.pipe();
    defer closeFd(pb[0]);
    defer closeFd(pb[1]);

    const Context = struct {
        count: *usize,
        fn cb(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.count.* += 1;
            _ = loop_;
            _ = token;
            _ = events;
        }
    };

    var a_count: usize = 0;
    var b_count: usize = 0;
    var ca = Context{ .count = &a_count };
    var cb2 = Context{ .count = &b_count };
    _ = try lp.addSource(pa[0], ev.in_, Context.cb, @intFromPtr(&ca));
    _ = try lp.addSource(pb[0], ev.in_, Context.cb, @intFromPtr(&cb2));

    try TestUtil.writeByte(pa[1], 'x');
    try TestUtil.writeByte(pb[1], 'y');

    const n = try lp.runOnce(1000);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), a_count);
    try std.testing.expectEqual(@as(usize, 1), b_count);

    // Consume the bytes; nothing more may fire.
    var buf: [2]u8 = undefined;
    _ = try posix.read(pa[0], &buf);
    _ = try posix.read(pb[0], &buf);
    _ = try lp.runOnce(50);
    try std.testing.expectEqual(@as(usize, 1), a_count);
    try std.testing.expectEqual(@as(usize, 1), b_count);
}

test "removing a source inside its own handler is safe" {
    var lp = try Loop.init();
    defer lp.deinit();

    const pa = try TestUtil.pipe();
    defer closeFd(pa[0]);
    defer closeFd(pa[1]);
    const pb = try TestUtil.pipe();
    defer closeFd(pb[0]);
    defer closeFd(pb[1]);

    const Context = struct {
        count: *usize,
        own: Token,
        other: Token,
        // Removes BOTH its own source and the other one mid-dispatch: exercises
        // self-removal plus a stale batch entry for the other source.
        fn cbA(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.count.* += 1;
            loop_.removeSource(ctx.own);
            loop_.removeSource(ctx.other);
            _ = token;
            _ = events;
        }
        fn cbB(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
            const ctx: *@This() = @ptrFromInt(userdata);
            ctx.count.* += 1;
            _ = loop_;
            _ = token;
            _ = events;
        }
    };

    var a_count: usize = 0;
    var b_count: usize = 0;
    var ca = Context{ .count = &a_count, .own = undefined, .other = undefined };
    var cb_ctx = Context{ .count = &b_count, .own = undefined, .other = undefined };

    const ta = try lp.addSource(pa[0], ev.in_, Context.cbA, @intFromPtr(&ca));
    const tb = try lp.addSource(pb[0], ev.in_, Context.cbB, @intFromPtr(&cb_ctx));
    ca.own = ta;
    ca.other = tb;
    cb_ctx.own = tb;
    cb_ctx.other = ta;

    try TestUtil.writeByte(pa[1], 'x');
    try TestUtil.writeByte(pb[1], 'y');
    _ = try lp.runOnce(1000);

    // A fired exactly once. Depending on epoll's event order B may or may
    // not have fired in the same batch; either way nothing fires afterwards.
    try std.testing.expectEqual(@as(usize, 1), a_count);
    const b_snapshot = b_count;
    _ = try lp.runOnce(30);
    try std.testing.expectEqual(@as(usize, 1), a_count);
    try std.testing.expectEqual(b_snapshot, b_count);

    // The loop still works for new sources (slot reuse + generation guard).
    const pc = try TestUtil.pipe();
    defer closeFd(pc[0]);
    defer closeFd(pc[1]);
    var c_count: usize = 0;
    var cc = Context{ .count = &c_count, .own = undefined, .other = undefined };
    _ = try lp.addSource(pc[0], ev.in_, Context.cbB, @intFromPtr(&cc));
    try TestUtil.writeByte(pc[1], 'z');
    _ = try lp.runOnce(1000);
    try std.testing.expectEqual(@as(usize, 1), c_count);
}

test "stop() from a handler makes run() return" {
    var lp = try Loop.init();
    defer lp.deinit();

    const pa = try TestUtil.pipe();
    defer closeFd(pa[0]);
    defer closeFd(pa[1]);

    const Stopper = struct {
        fn cb(loop_: *Loop, token: Token, userdata: usize, events: Events) void {
            _ = token;
            _ = userdata;
            _ = events;
            loop_.stop();
        }
    };
    _ = try lp.addSource(pa[0], ev.in_, Stopper.cb, 0);
    try TestUtil.writeByte(pa[1], 'x');

    try lp.run(); // infinite-ish wait; the handler stops it after one batch
    try std.testing.expect(lp.stopped);
    // Once stopped, runOnce returns immediately with nothing dispatched.
    try std.testing.expectEqual(@as(usize, 0), try lp.runOnce(0));
}