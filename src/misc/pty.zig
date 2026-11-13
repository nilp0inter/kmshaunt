//! pty spawn for the terminal session (ROADMAP M1.4).
//!
//! Owns a Unix98 pseudo-terminal pair and spawns a child process with the
//! slave as its controlling terminal, then execs the requested program
//! (`/bin/login -p` in kmshaunt). Does not use `std.process.Child`: everything
//! between `fork(2)` and `execve(2)` in the child uses only async-signal-safe
//! `std.os.linux` syscalls — no heap allocation, no locks, no std error paths.
//! Null-terminated `argv`/`envp` arrays are built in the parent before the
//! fork.
//!
//! The environment passed via `SpawnOptions.env` is the *entire* environment
//! of the child (kmshaunt implements `TERM` and `reset-env` semantics above
//! this module). When `argv[0]` contains no `/`, it is resolved via `PATH`
//! read from that same caller-provided environment rather than the parent's
//! process environment.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux)
        @compileError("src/misc/pty.zig is Linux-only");
}

// Stable Linux UAPI tty/pty ioctl numbers (include/uapi/asm-generic/ioctls.h).
/// `_IOR('T', 0x30, unsigned int)` — fetch `/dev/pts/<N>` number from master.
const TIOCGPTN: u32 = 0x80045430;
/// `_IOW('T', 0x31, int)` — set or clear the slave lock (`unlockpt(3)`).
const TIOCSPTLCK: u32 = 0x40045431;
/// Make the given tty the controlling terminal of the calling session leader.
const TIOCSCTTY: u32 = 0x540E;
const TIOCGWINSZ: u32 = 0x5413;
const TIOCSWINSZ: u32 = 0x5414;

/// `execvpe(3)` fallback when the caller-provided environment carries no `PATH`.
const default_path = "/usr/local/bin:/usr/bin:/bin";

pub const Pty = struct {
    /// Master side of the pty pair; stays open in the parent. Register this
    /// with epoll (after `setNonBlocking(true)`) for terminal I/O.
    master_fd: std.posix.fd_t = -1,
    /// Absolute path of the slave device (`/dev/pts/<N>`), NUL-terminated.
    /// Populated by `open`, consumed in the child by `spawn`.
    slave_path: [32:0]u8 = undefined,
    /// PID of the live child, or 0 before `spawn` / after `reap` collects a
    /// terminal status (`exited` / `signaled`).
    child_pid: std.posix.pid_t = 0,

    pub const Winsize = struct {
        cols: u16,
        rows: u16,
    };

    pub const OpenError = std.posix.OpenError || error{
        /// `TIOCGPTN` (`grantpt` equivalent) or `TIOCSPTLCK` (`unlockpt`) failed.
        GrantFailed,
        /// Formatted `/dev/pts/<N>` exceeded `slave_path`.
        SlaveNameTooLong,
        /// `ioctl(TIOCSWINSZ)` failed on the master.
        WinsizeFailed,
    };

    pub const SpawnOptions = struct {
        /// Program and arguments. `argv[0]` is the executable: if it contains
        /// `/`, it is passed straight to `execve(2)`; otherwise it is searched
        /// along `PATH` from `env` (`execvpe` semantics).
        argv: []const []const u8,
        /// Complete environment of the child as `"NAME=value"` entries. `null`
        /// gives an empty environment.
        env: ?[]const []const u8 = null,
        /// Optional working directory for the child; `null` inherits the
        /// parent's cwd.
        cwd: ?[]const u8 = null,
        /// Optional spawn-time window size; overrides the size set at `open`.
        winsize: ?Winsize = null,
        /// Used in the parent before `fork(2)` to build NUL-terminated `argv`
        /// and `envp` blocks; freed before `spawn` returns.
        allocator: std.mem.Allocator,
    };

    pub const SpawnError = std.mem.Allocator.Error || error{
        /// `argv` had length 0.
        EmptyArgv,
        /// This `Pty` already owns an unreaped child.
        AlreadySpawned,
        /// `cwd` contained an interior NUL or exceeded `PATH_MAX`.
        InvalidCwd,
        /// `fork(2)` failed with `EAGAIN` / `ENOMEM`.
        SystemResources,
        /// `fork(2)` failed for another reason.
        ForkFailed,
        /// Spawn-time `TIOCSWINSZ` failed.
        WinsizeFailed,
    };

    pub const ReadError = std.posix.ReadError;

    pub const WriteError = error{
        /// `EAGAIN` on a non-blocking master.
        WouldBlock,
        /// `EIO` — slave side is closed.
        InputOutput,
        /// `EPIPE`.
        BrokenPipe,
        /// `ENOMEM` / `ENOBUFS`.
        SystemResources,
        Unexpected,
    };

    pub const WinsizeError = error{WinsizeFailed};
    pub const NonBlockingError = error{FcntlFailed};

    pub const ReapStatus = union(enum) {
        exited: u8,
        signaled: u8,
        stopped: u8,
        continued,
    };

    pub const ReapResult = struct {
        pid: std.posix.pid_t,
        status: ReapStatus,
    };

    pub const ReapError = error{
        /// `waitpid(2)` returned `EINTR` (only possible when caller clears
        /// `W.NOHANG`).
        Interrupted,
        WaitFailed,
    };

    pub const KillError = std.posix.KillError || error{NoChild};

    /// Allocate a new Unix98 pty master (`/dev/ptmx`, `O_RDWR | O_NOCTTY`,
    /// `FD_CLOEXEC` cleared on master per assignment item 1), unlock its slave
    /// via `TIOCGPTN` + `TIOCSPTLCK`, record the slave path `/dev/pts/<N>`, and
    /// apply the initial window size (`cols == 0 and rows == 0` leaves the
    /// kernel default untouched). The slave itself is opened later in the
    /// forked child by `spawn`.
    pub fn open(cols: u16, rows: u16) OpenError!Pty {
        var self = Pty{};
        self.master_fd = try openPtmx();
        errdefer {
            _ = linux.close(self.master_fd);
            self.master_fd = -1;
        }

        // grantpt(3): on modern Linux devpts the kernel sets slave ownership at
        // ptmx open time; TIOCGPTN validates the master and yields the pty
        // index needed to form ptsname without touching glibc static buffers.
        var pty_num: c_uint = 0;
        if (linux.errno(linux.ioctl(self.master_fd, TIOCGPTN, @intFromPtr(&pty_num))) != .SUCCESS)
            return error.GrantFailed;

        // unlockpt(3): clear the slave lock so the child can open /dev/pts/<N>.
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(self.master_fd, TIOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
            return error.GrantFailed;

        // ptsname_r(3) equivalent into our inline buffer.
        const written = std.fmt.bufPrint(&self.slave_path, "/dev/pts/{d}", .{pty_num}) catch
            return error.SlaveNameTooLong;
        // NUL-terminate. When the buffer fills completely, the sentinel at
        // [len] is already 0; only shorter writes need the explicit terminator.
        if (written.len < self.slave_path.len)
            self.slave_path[written.len] = 0;

        if (cols != 0 or rows != 0)
            try setWinsizeFd(self.master_fd, cols, rows);

        return self;
    }

    fn openPtmx() std.posix.OpenError!std.posix.fd_t {
        // Master opened RDWR | NOCTTY with FD_CLOEXEC clear (CLOEXEC = false).
        // The child closes master_fd explicitly (and via close_range) before
        // exec so it never leaks into the session process.
        const flags: std.posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = false };
        return std.posix.openatZ(std.posix.AT.FDCWD, "/dev/ptmx", flags, 0) catch |err| switch (err) {
            error.FileNotFound => std.posix.openatZ(std.posix.AT.FDCWD, "/dev/pts/ptmx", flags, 0),
            else => err,
        };
    }

    /// Toggle `O_NONBLOCK` on `master_fd`. `open` returns a blocking master;
    /// enable non-blocking mode when registering `master_fd` with an epoll loop.
    pub fn setNonBlocking(self: *Pty, non_blocking: bool) NonBlockingError!void {
        const cur = linux.fcntl(self.master_fd, linux.F.GETFL, 0);
        if (linux.errno(cur) != .SUCCESS) return error.FcntlFailed;
        // O_NONBLOCK bit extracted from the packed O struct so the mask is
        // correct on every arch's ABI, not just x86_64's bit 11.
        const o_nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
        const next = if (non_blocking) cur | o_nonblock else cur & ~o_nonblock;
        if (linux.errno(linux.fcntl(self.master_fd, linux.F.SETFL, next)) != .SUCCESS)
            return error.FcntlFailed;
    }

    /// Fork a child wired to the slave side of this pty and exec `opts.argv`.
    /// On any child-side setup or exec failure the child exits with status 127
    /// via `_exit(2)`.
    pub fn spawn(self: *Pty, opts: SpawnOptions) SpawnError!void {
        if (opts.argv.len == 0 or opts.argv[0].len == 0) return error.EmptyArgv;
        if (self.child_pid > 0) return error.AlreadySpawned;

        if (opts.winsize) |ws|
            try setWinsizeFd(self.master_fd, ws.cols, ws.rows);

        // Pre-validate and NUL-terminate cwd on the parent stack so the child
        // never runs formatting or validation code.
        var cwd_buf: [std.posix.PATH_MAX:0]u8 = undefined;
        const cwd_z: ?[*:0]const u8 = if (opts.cwd) |dir| blk: {
            if (dir.len == 0 or dir.len >= cwd_buf.len or std.mem.indexOfScalar(u8, dir, 0) != null)
                return error.InvalidCwd;
            @memcpy(cwd_buf[0..dir.len], dir);
            cwd_buf[dir.len] = 0;
            break :blk &cwd_buf;
        } else null;

        // Build NUL-terminated argv, envp, and (when argv[0] is a bare name)
        // every candidate `<dir>/<argv[0]>` path in the parent before fork() so
        // the child touches neither the allocator nor std.fmt.
        var arena = std.heap.ArenaAllocator.init(opts.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const argv_z = try buildZVector(aa, opts.argv);
        const env_slice = opts.env orelse &.{};
        const envp_z = try buildZVector(aa, env_slice);
        const candidates_z = try buildExecCandidates(aa, opts.argv[0], env_slice);

        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.ForkFailed,
        }
        if (rc == 0) {
            childExec(
                &self.slave_path,
                self.master_fd,
                cwd_z,
                candidates_z,
                argv_z,
                envp_z,
            );
        }
        self.child_pid = @intCast(rc);
    }

    /// Allocate a NUL-terminated copy of `bytes`. `Allocator.dupeZ` was
    /// removed in Zig 0.17; `allocSentinel` provides the same
    /// sentinel-terminated slice shape the child's raw `execve` needs.
    fn dupeZ(aa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![:0]u8 {
        const buf = try aa.allocSentinel(u8, bytes.len, 0);
        @memcpy(buf[0..bytes.len], bytes);
        return buf;
    }

    fn buildZVector(
        aa: std.mem.Allocator,
        items: []const []const u8,
    ) std.mem.Allocator.Error![*:null]const ?[*:0]const u8 {
        const vec = try aa.allocSentinel(?[*:0]const u8, items.len, null);
        for (items, 0..) |item, i| {
            vec[i] = (try dupeZ(aa, item)).ptr;
        }
        return vec.ptr;
    }

    /// Pre-expand candidate executable paths in the parent:
    /// - If `argv0` contains `/`, the single candidate is `argv0` itself.
    /// - Otherwise split `PATH` from `env` (falling back to `default_path` when
    ///   `PATH` is unset or empty) on `:` with POSIX empty-component = `.`
    ///   semantics and join `<dir>/<argv0>`.
    fn buildExecCandidates(
        aa: std.mem.Allocator,
        argv0: []const u8,
        env: []const []const u8,
    ) std.mem.Allocator.Error![*:null]const ?[*:0]const u8 {
        if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
            const single = try aa.allocSentinel(?[*:0]const u8, 1, null);
            single[0] = (try dupeZ(aa, argv0)).ptr;
            return single.ptr;
        }

        const path_val = blk: {
            for (env) |entry| {
                if (std.mem.startsWith(u8, entry, "PATH=") and entry.len > "PATH=".len)
                    break :blk entry["PATH=".len..];
            }
            break :blk default_path;
        };

        var count: usize = 1;
        for (path_val) |ch| {
            if (ch == ':') count += 1;
        }
        const list = try aa.allocSentinel(?[*:0]const u8, count, null);
        var it = std.mem.splitScalar(u8, path_val, ':');
        var idx: usize = 0;
        while (it.next()) |comp| : (idx += 1) {
            const dir = if (comp.len == 0) "." else comp;
            const joined = try std.fmt.allocPrintSentinel(aa, "{s}/{s}", .{ dir, argv0 }, 0);
            list[idx] = joined.ptr;
        }
        return list.ptr;
    }

    /// Child-side post-fork body. Async-signal-safe: invokes only raw Linux
    /// syscalls via `std.os.linux.*` on pre-built buffers and terminates with
    /// `_exit(127)` (`SYS.exit`) if any step fails.
    fn childExec(
        slave_path: [*:0]const u8,
        master_fd: std.posix.fd_t,
        cwd_z: ?[*:0]const u8,
        candidates_z: [*:null]const ?[*:0]const u8,
        argv_z: [*:null]const ?[*:0]const u8,
        envp_z: [*:null]const ?[*:0]const u8,
    ) noreturn {
        // 1. Start a new session so the child loses any prior controlling tty
        //    and becomes session + process-group leader.
        if (linux.errno(linux.setsid()) != .SUCCESS)
            linux.exit(127);

        // 2. Reset the signal mask (kmshaunt blocks SIGCHLD/SIGTERM for
        //    signalfd in the parent; the login session must not inherit a
        //    blocked mask).
        const empty_mask = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);

        // 3. Open the slave device and make it the controlling terminal of
        //    this session via TIOCSCTTY.
        const slave_rc = linux.openat(linux.AT.FDCWD, slave_path, .{ .ACCMODE = .RDWR, .NOCTTY = false }, 0);
        if (linux.errno(slave_rc) != .SUCCESS)
            linux.exit(127);
        const slave_fd: std.posix.fd_t = @intCast(slave_rc);

        if (linux.errno(linux.ioctl(slave_fd, TIOCSCTTY, 0)) != .SUCCESS)
            linux.exit(127);

        // 4. Duplicate the slave onto stdin/stdout/stderr.
        if (linux.errno(linux.dup2(slave_fd, std.posix.STDIN_FILENO)) != .SUCCESS)
            linux.exit(127);
        if (linux.errno(linux.dup2(slave_fd, std.posix.STDOUT_FILENO)) != .SUCCESS)
            linux.exit(127);
        if (linux.errno(linux.dup2(slave_fd, std.posix.STDERR_FILENO)) != .SUCCESS)
            linux.exit(127);

        // 5. Close the inherited master and every other descriptor >= 3
        //    (slave_fd if >= 3, signalfd, timerfd, epoll, DRM, etc.).
        if (master_fd > 2) _ = linux.close(master_fd);
        closeFrom3();

        // 6. Optional chdir.
        if (cwd_z) |dir| {
            if (linux.errno(linux.chdir(dir)) != .SUCCESS)
                linux.exit(127);
        }

        // 7. execve across the pre-built candidate path list.
        var i: usize = 0;
        while (candidates_z[i]) |path_z| : (i += 1) {
            _ = linux.execve(path_z, argv_z, envp_z);
        }
        linux.exit(127);
    }

    fn closeFrom3() void {
        const rc = linux.close_range(3, std.math.maxInt(std.posix.fd_t), .{
            .UNSHARE = false,
            .CLOEXEC = false,
        });
        if (linux.errno(rc) == .SUCCESS) return;

        // Pre-5.9 fallback: close descriptors 3..NOFILE sequentially.
        var lim: linux.rlimit = undefined;
        const cap: usize = if (linux.errno(linux.getrlimit(.NOFILE, &lim)) == .SUCCESS)
            @min(lim.cur, 65536)
        else
            1024;
        var fd: std.posix.fd_t = 3;
        while (fd < cap) : (fd += 1) {
            _ = linux.close(fd);
        }
    }

    /// Read bytes produced by the slave side from `master_fd`. Returns `0` on
    /// EOF and `error.InputOutput` (`EIO`) once all slave descriptors have
    /// closed (standard Linux pty hangup indicator).
    pub fn read(self: *const Pty, buf: []u8) ReadError!usize {
        return std.posix.read(self.master_fd, buf);
    }

    /// Write bytes into `master_fd` toward the slave's input queue. Retries on
    /// `EINTR` and clamps individual syscalls to the Linux `0x7ffff000` transfer
    /// ceiling.
    pub fn write(self: *const Pty, bytes: []const u8) WriteError!usize {
        if (bytes.len == 0) return 0;
        const max_count: usize = 0x7ffff000;
        while (true) {
            const rc = linux.write(self.master_fd, bytes.ptr, @min(bytes.len, max_count));
            switch (linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .IO => return error.InputOutput,
                .PIPE => return error.BrokenPipe,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .INVAL, .FAULT => unreachable,
                else => return error.Unexpected,
            }
        }
    }

    /// Update the pty window size via `TIOCSWINSZ` on `master_fd`; the kernel
    /// delivers `SIGWINCH` to the foreground process group on the slave.
    pub fn resize(self: *Pty, cols: u16, rows: u16) WinsizeError!void {
        return setWinsizeFd(self.master_fd, cols, rows);
    }

    fn setWinsizeFd(fd: std.posix.fd_t, cols: u16, rows: u16) WinsizeError!void {
        const ws = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (linux.errno(linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS)
            return error.WinsizeFailed;
    }

    /// Query the current pty window size via `TIOCGWINSZ` on `master_fd`.
    pub fn getWinsize(self: *const Pty) WinsizeError!Winsize {
        var ws: std.posix.winsize = undefined;
        if (linux.errno(linux.ioctl(self.master_fd, TIOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS)
            return error.WinsizeFailed;
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// Non-blocking `waitpid(2)` wrapper (`W.NOHANG | W.UNTRACED` by default),
    /// designed to be called from a `SIGCHLD`-driven epoll loop:
    /// - Returns `null` when no child has been spawned, when `WNOHANG` is set
    ///   and the child has not yet changed state, or when the child has already
    ///   been reaped (`ECHILD`).
    /// - Clears `child_pid` once a terminal status (`exited` or `signaled`) is
    ///   collected so subsequent calls are idempotent no-ops.
    pub fn reap(self: *Pty, flags: u32) ReapError!?ReapResult {
        if (self.child_pid <= 0) return null;
        var status: i32 = 0;
        const rc = linux.waitpid(self.child_pid, &status, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .CHILD => {
                self.child_pid = 0;
                return null;
            },
            .INTR => return error.Interrupted,
            .INVAL => unreachable,
            else => return error.WaitFailed,
        }
        if (rc == 0) return null;

        const pid: std.posix.pid_t = @intCast(rc);
        const st: u32 = @bitCast(status);
        if (std.posix.W.IFEXITED(st)) {
            self.child_pid = 0;
            return .{ .pid = pid, .status = .{ .exited = std.posix.W.EXITSTATUS(st) } };
        }
        if (std.posix.W.IFSIGNALED(st)) {
            self.child_pid = 0;
            return .{ .pid = pid, .status = .{ .signaled = @intCast(@intFromEnum(std.posix.W.TERMSIG(st))) } };
        }
        if (std.posix.W.IFSTOPPED(st)) {
            return .{ .pid = pid, .status = .{ .stopped = @intCast(@intFromEnum(std.posix.W.STOPSIG(st))) } };
        }
        if (st == 0xffff) {
            return .{ .pid = pid, .status = .continued };
        }
        return error.WaitFailed;
    }

    /// Send `sig` to the spawned child. Returns `error.NoChild` if no child is
    /// currently tracked (guards against `kill(0, sig)` signalling our own
    /// process group).
    pub fn kill(self: *const Pty, sig: std.posix.SIG) KillError!void {
        if (self.child_pid <= 0) return error.NoChild;
        return std.posix.kill(self.child_pid, sig);
    }

    /// Close `master_fd`. Safe to call multiple times.
    pub fn deinit(self: *Pty) void {
        if (self.master_fd >= 0) {
            _ = linux.close(self.master_fd);
            self.master_fd = -1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_path_env = "PATH=/run/current-system/sw/bin:/usr/bin:/bin";
const default_reap_flags: u32 = std.posix.W.NOHANG | std.posix.W.UNTRACED;

fn fileExistsZ(path: [*:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

fn findSh() []const u8 {
    if (fileExistsZ("/bin/sh")) return "/bin/sh";
    if (fileExistsZ("/run/current-system/sw/bin/sh")) return "/run/current-system/sw/bin/sh";
    return "sh";
}

fn findTool(comptime name: []const u8) ?[]const u8 {
    const nixos = "/run/current-system/sw/bin/" ++ name;
    if (fileExistsZ(nixos)) return nixos;
    const usr = "/usr/bin/" ++ name;
    if (fileExistsZ(usr)) return usr;
    const bin = "/bin/" ++ name;
    if (fileExistsZ(bin)) return bin;
    return null;
}

fn sleepMs(ms: u64) void {
    const req = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&req, null);
}

/// Drain `pty` until EOF / `EIO` (all slave fds closed by the exiting child)
/// with a bounded poll timeout so tests never hang if a child wedges.
fn readAllFromMaster(pty: *const Pty, out: []u8) ![]u8 {
    var total: usize = 0;
    var pfd = [_]std.posix.pollfd{.{
        .fd = pty.master_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var attempts: usize = 0;
    while (total < out.len and attempts < 500) : (attempts += 1) {
        const ready = try std.posix.poll(&pfd, 10);
        if (ready == 0) continue;
        if (pfd[0].revents & std.posix.POLL.IN != 0) {
            const n = pty.read(out[total..]) catch |err| switch (err) {
                error.InputOutput => break,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        } else if (pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            break;
        }
    }
    return out[0..total];
}

fn reapWithRetry(pty: *Pty) !Pty.ReapResult {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (try pty.reap(default_reap_flags)) |res| return res;
        sleepMs(10);
    }
    return error.TestTimeout;
}

test "(a) spawn /bin/sh -c 'echo hello' -> parent reads 'hello'" {
    var pty = try Pty.open(80, 24);
    defer pty.deinit();

    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ findSh(), "-c", "echo hello" },
        .env = &.{test_path_env},
    });

    var buf: [256]u8 = undefined;
    const got = try readAllFromMaster(&pty, &buf);
    const trimmed = std.mem.trim(u8, got, " \t\r\n");
    try testing.expectEqualStrings("hello", trimmed);

    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 0 }, res.status);
}

test "(b) spawn /bin/sh -c 'exit 42' -> reap reports exited(42)" {
    var pty = try Pty.open(80, 24);
    defer pty.deinit();

    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ findSh(), "-c", "exit 42" },
        .env = &.{test_path_env},
    });

    var buf: [64]u8 = undefined;
    _ = try readAllFromMaster(&pty, &buf);

    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 42 }, res.status);
}

test "(c) env passing: MYVAR=kmshaunt replaces child environment" {
    var pty = try Pty.open(80, 24);
    defer pty.deinit();

    // Also print ${HOME:-UNSET} with HOME omitted from env to verify the
    // caller's environment list fully replaces the parent's environment.
    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ findSh(), "-c", "printf '%s:%s' \"$MYVAR\" \"${HOME:-UNSET}\"" },
        .env = &.{ "MYVAR=kmshaunt", test_path_env },
    });

    var buf: [256]u8 = undefined;
    const got = try readAllFromMaster(&pty, &buf);
    try testing.expectEqualStrings("kmshaunt:UNSET", got);

    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 0 }, res.status);
}

test "(d) resize(120, 40) reflected in getWinsize and child stty size" {
    var pty = try Pty.open(80, 24);
    defer pty.deinit();

    const initial = try pty.getWinsize();
    try testing.expectEqual(@as(u16, 80), initial.cols);
    try testing.expectEqual(@as(u16, 24), initial.rows);

    try pty.resize(120, 40);
    const updated = try pty.getWinsize();
    try testing.expectEqual(@as(u16, 120), updated.cols);
    try testing.expectEqual(@as(u16, 40), updated.rows);

    const stty_bin = findTool("stty") orelse "stty";
    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ stty_bin, "size" },
        .env = &.{test_path_env},
    });

    var buf: [128]u8 = undefined;
    const got = try readAllFromMaster(&pty, &buf);
    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 0 }, res.status);
    try testing.expectEqualStrings("40 120", std.mem.trim(u8, got, " \t\r\n"));
}

test "(e) controlling tty: child ps -o tty= reports pts/<N>" {
    const ps_bin = findTool("ps") orelse return error.SkipZigTest;

    var pty = try Pty.open(80, 24);
    defer pty.deinit();

    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "{s} -o tty= -p $$", .{ps_bin});

    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ findSh(), "-c", cmd },
        .env = &.{test_path_env},
    });

    var buf: [128]u8 = undefined;
    const got = try readAllFromMaster(&pty, &buf);
    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 0 }, res.status);

    const tty_name = std.mem.trim(u8, got, " \t\r\n");
    try testing.expect(std.mem.startsWith(u8, tty_name, "pts/"));
    // Cross-check against the slave path recorded at open() (/dev/pts/<N>).
    const expected_pts = std.mem.sliceTo(&pty.slave_path, 0)["/dev/".len..];
    try testing.expectEqualStrings(expected_pts, tty_name);
}

test "(f) SIGCHLD-driven WNOHANG reap loop + write/kill roundtrip" {
    var pty = try Pty.open(80, 24);
    defer pty.deinit();
    try pty.setNonBlocking(true);

    // Child reads a line from stdin (the slave) and exits with status 7 once
    // it receives it. While it waits on stdin, WNOHANG reap must return null.
    try pty.spawn(.{
        .allocator = testing.allocator,
        .argv = &.{ findSh(), "-c", "read line; exit 7" },
        .env = &.{test_path_env},
    });

    try testing.expect((try pty.reap(default_reap_flags)) == null);

    const written = try pty.write("go\n");
    try testing.expectEqual(@as(usize, 3), written);

    var buf: [128]u8 = undefined;
    _ = try readAllFromMaster(&pty, &buf);

    const res = try reapWithRetry(&pty);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 7 }, res.status);
    // Subsequent reaps after terminal status return null cleanly.
    try testing.expect((try pty.reap(default_reap_flags)) == null);
    try testing.expectError(error.NoChild, pty.kill(.TERM));
}
