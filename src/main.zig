//! kmshaunt entry point: argument parsing, console startup and main loop.
//!
//! ROADMAP M1 (first login on drm2d) + M2 (terminal behavior). The command
//! line is parsed by `config.Config.load` (kmscon-compatible, all 77
//! options); `--help`/`--version` short-circuit through `Config.exit`. The
//! legacy `parseArgs` helper and its tests are kept for the M0 contract.
//!
//! # Startup sequence (single seat, `runConsole`)
//!
//!  1. `Config.load` (CLI lock < main file), honour `--configdir`.
//!  2. `spng_decode.install()` — process-global PNG hook, before any VT use.
//!  3. `Loop` + `SignalSource` (SIGTERM/INT/CHLD, plus USR1/USR2 for the real
//!     VT). The signals are blocked here, before the seat is activated.
//!  4. Seat: `LibseatSeat` when `--libseat`, else `VtReal.openVt`. Callbacks
//!     activated/deactivated drive DRM master take/drop. The VT/libseat fd
//!     is registered with the loop.
//!  5. Video: `Fbdev` when `--no-drm`, else `Drm2d` (`--hwaccel` requests
//!     Drm3d, whose GBM/EGL/GL bindings are not wired into build.zig yet, so
//!     it falls back to Drm2d with a warning). First connected connector +
//!     preferred mode, with `--mode`/`--screen` overrides; `setMode`.
//!  6. Font: `Discovery.primaryFace` + `cellMetrics`; grid = mode / cell.
//!     `--font-size 0` derives a size from the connector's physical mm.
//!  7. `CpuRenderer`, `Manager` + heap-allocated `TerminalSession` factory,
//!     terminal hooks, `openInitial`.
//!  8. Input: `xkb.Keymap` + `Input` (libinput), sink routes to the manager,
//!     repeat through a `loop.Timer` adapter, VT-switch grabs handled here.
//!  9. Each terminal's pty master registered EPOLLIN edge-triggered.
//! 10. Frame loop paced by DRM page-flip events; DPMS + cursor-blink +
//!     kitty-animation timers.
//! 11. issue text, asciicast recorder, locale1 live keymap follow.
//! 12. `loop.run`; SIGTERM/INT (or oneshot child exit) stops it; everything
//!     is deinitialised in reverse order.
//!
//! # Main-loop fd/event table
//!
//! | fd                    | interest        | handler                  |
//! |-----------------------|-----------------|--------------------------|
//! | signalfd              | IN              | onSignal                 |
//! | VT fd / libseat fd    | IN (+HUP VT)    | onVtEvent / onSeatEvent  |
//! | DRM event fd          | IN              | onDrmEvent               |
//! | libinput fd           | IN              | onInputEvent             |
//! | each pty master       | IN \| ET        | onPtyEvent               |
//! | locale1 bus fd        | IN              | onLocale1Event           |
//! | DPMS timerfd          | IN              | onDpmsTimer              |
//! | blink timerfd         | IN              | onBlinkTimer             |
//! | repeat timerfd        | IN              | RepeatAdapter.fired      |
//! | kitty timerfd         | IN              | onKittyTimer             |
//!
//! Rendering uses a persistent shadow framebuffer: the CPU renderer paints
//! only dirty rows, so the shadow accumulates the full image across frames
//! and is blitted into the backend's alternating back buffer before each
//! flip (the back buffer must hold a complete frame).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const config = @import("config/config.zig");
const loop = @import("loop.zig");
const seat = @import("seat.zig");
const vt_real = @import("seat/vt_real.zig");
const libseat = @import("seat/libseat.zig");
const multiseat = @import("seat/multiseat.zig");
const video = @import("video.zig");
const drm2d = @import("video/drm2d.zig");
const fbdev = @import("video/fbdev.zig");
const render = @import("render.zig");
const cpu = @import("render/cpu.zig");
const discovery = @import("font/discovery.zig");
const vt = @import("vt.zig");
const layout = @import("video/layout.zig");
const atlas = @import("font/atlas.zig");
const sess = @import("session.zig");
const terminal = @import("session/terminal.zig");
const manager = @import("session/manager.zig");
const xkb = @import("input/xkb.zig");
const kt = @import("input/keymap_table.zig");
const libinput = @import("input/libinput.zig");
const spng = @import("misc/spng_decode.zig");
const issue = @import("misc/issue.zig");
const asciicast = @import("misc/asciicast.zig");
const locale1 = @import("misc/locale1.zig");

const version = "0.0.1";

const log = std.log.scoped(.kmshaunt);

// ---------------------------------------------------------------------------
// Runtime log level (verbose/debug/silent). The default log function filters
// against `log_filter`, which main() sets from the parsed config.
// ---------------------------------------------------------------------------

var log_filter: std.log.Level = .warn;

pub const std_options: std.Options = .{
    // Let every level reach consoleLog; the runtime filter below decides.
    .log_level = .debug,
    .logFn = consoleLog,
};

fn consoleLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Level is ordered err < warn < info < debug; show level <= filter.
    if (@intFromEnum(level) > @intFromEnum(log_filter)) return;
    std.log.defaultLog(level, scope, format, args);
}

// ---------------------------------------------------------------------------
// M0 argument parsing (kept with its tests). The console itself uses the
// full kmscon-compatible parser in config.zig; this helper remains the
// simple, independently-tested contract for the three M0 actions.
// ---------------------------------------------------------------------------

/// What the command line asks the program to do.
pub const Action = enum {
    /// Print the version string to stdout and exit successfully.
    print_version,
    /// Print the usage text to stdout and exit successfully.
    print_help,
    /// Run the console.
    run,
};

/// The outcome of parsing the command line.
pub const ParseResult = union(enum) {
    ok: Action,
    /// The first unrecognized argument; report it on stderr and exit 2.
    unknown: []const u8,
};

/// Parse the arguments after the program name.
///
/// The first recognized flag wins; anything else is reported as unknown.
pub fn parseArgs(args: []const []const u8) ParseResult {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .{ .ok = .print_version };
        if (std.mem.eql(u8, arg, "--help")) return .{ .ok = .print_help };
        return .{ .unknown = arg };
    }
    return .{ .ok = .run };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var cfg = config.Config.load(arena, io, args[1..]) catch |err| {
        try stderr.print("kmshaunt: invalid configuration ({s})\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(2);
    };

    if (cfg.exit) {
        if (cfg.help) {
            try stdout.writeAll(config.help_text);
        } else {
            try stdout.print("kmshaunt {s}\n", .{version});
        }
        try stdout.flush();
        cfg.deinit();
        return;
    }

    log_filter = if (cfg.debug) .debug else if (cfg.verbose) .info else if (cfg.silent) .err else .warn;
    for (cfg.warnings.items) |w| log.warn("{s}", .{w});

    // Multi-seat daemon: libseat without a pinned VT (kmshaunt.service).
    // The single-seat path is selected whenever a VT is requested.
    const result = if (cfg.libseat and cfg.vt == null)
        runDaemon(io, arena, &cfg)
    else
        runConsole(io, arena, &cfg);

    result catch |err| {
        log.err("console failed: {t}", .{err});
        cfg.deinit();
        std.process.exit(1);
    };
    cfg.deinit();
}

// ---------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------

/// KDMKTONE (linux/kd.h): lower 16 bits frequency (Hz), upper 16 duration (ms).
const kdmktone: u32 = 0x4B30;
/// Cursor blink half-period (kmscon uses ~500 ms).
const blink_interval_ns: u64 = 500 * std.time.ns_per_ms;
/// Throttle before respawning a login child that exited (non-oneshot).
const respawn_delay_ns: u64 = 500 * std.time.ns_per_ms;
/// Zoom bounds (px) for grab-zoom-in/out. kmscon floors zoom-out at 1 px;
/// no max is configured, so kmshaunt caps at a readable upper bound (M3.8).
const min_font_px: u16 = 1;
const max_font_px: u16 = 128;

/// One registered pty master. Heap-allocated so the epoll userdata pointer
/// stays stable across list growth.
const PtyReg = struct {
    ts: *terminal.TerminalSession,
    token: loop.Token,
};

/// The single-seat console. Heap-allocated and never moved: every callback
/// userdata pointer and every borrowed sub-object address derives from it.
/// Value-type sub-objects are embedded as optionals (their address is stable
/// inside this struct); Drm2d and LibseatSeat own their heap allocation.
const Console = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,

    lp: loop.Loop = .{ .epoll_fd = -1 },
    signals: ?*loop.SignalSource = null,

    // Seat (exactly one of vt / libseat).
    vt: ?vt_real.VtReal = null,
    ls: ?*libseat.LibseatSeat = null,
    seat_handle: seat.Seat = undefined,
    seat_cbs: seat.Seat.Callbacks = .{},
    seat_token: ?loop.Token = null,

    // Video (exactly one of drm / fb).
    drm: ?*drm2d.Drm2d = null,
    fb: ?fbdev.Fbdev = null,
    backend: video.Backend = undefined,
    drm_token: ?loop.Token = null,
    mode: video.Mode = .{ .width_px = 0, .height_px = 0, .refresh_mhz = 0, .width_mm = 0, .height_mm = 0 },
    /// Content rotation applied at present time (M5.4); initial value from
    /// cfg.screen, cycled by grab-rotate-cw/ccw. Renderer-side (drm2d has
    /// no plane rotation).
    rotation: layout.Rotation = .normal,

    // Font + renderer.
    disc: ?discovery.Discovery = null,
    face: discovery.Face = undefined,
    cell: discovery.CellMetrics = .{ .cell_w = 0, .cell_h = 0, .baseline = 0 },
    size_px: u16 = 0,
    renderer: ?cpu.CpuRenderer = null,
    cols: u16 = 80,
    rows: u16 = 24,
    shadow: ?video.Framebuffer = null,
    damage: sess.DamageList = .empty,

    // Sessions.
    mgr: ?manager.Manager = null,
    terminals: std.ArrayListUnmanaged(*terminal.TerminalSession) = .empty,
    pty_regs: std.ArrayListUnmanaged(*PtyReg) = .empty,

    // Input.
    keymap: ?xkb.Keymap = null,
    input: ?libinput.Input = null,
    repeat: ?*RepeatAdapter = null,
    input_token: ?loop.Token = null,

    // Timers + misc.
    dpms_timer: loop.Timer = .{},
    blink_timer: loop.Timer = .{},
    respawn_timer: loop.Timer = .{},
    kitty_timer: loop.Timer = .{},
    recorder: ?*asciicast.Recorder = null,
    loc1: ?*locale1.Locale1 = null,
    locale_token: ?loop.Token = null,

    // State.
    dirty: bool = false,
    full_redraw: bool = true,
    dpms_off: bool = false,
    seat_active: bool = false,
    respawn_pending: ?*terminal.TerminalSession = null,

    // -- lifecycle ---------------------------------------------------------

    fn deinit(self: *Console) void {
        // Reverse order of setup. Every step is null-safe so partial-init
        // unwinding works. The loop outlives its sources.
        if (self.locale_token) |t| self.lp.removeSource(t);
        if (self.loc1) |l| {
            l.deinit();
            self.alloc.destroy(l);
            self.loc1 = null;
        }
        if (self.recorder) |r| {
            r.finish() catch {};
            r.deinit();
            self.alloc.destroy(r);
            self.recorder = null;
        }
        self.respawn_timer.deinit();
        self.kitty_timer.deinit();
        self.blink_timer.deinit();
        self.dpms_timer.deinit();

        if (self.input_token) |t| self.lp.removeSource(t);
        if (self.repeat) |r| {
            r.timer.deinit();
            self.alloc.destroy(r);
            self.repeat = null;
        }
        if (self.input) |*in| {
            in.deinit();
            self.input = null;
        }
        if (self.keymap) |*k| {
            k.deinit();
            self.keymap = null;
        }

        // Sessions: manager stops + deinits live sessions; then free the
        // heap structs and pty registrations the factory created.
        if (self.mgr) |*m| {
            m.deinit();
            self.mgr = null;
        }
        for (self.pty_regs.items) |reg| {
            self.lp.removeSource(reg.token);
            self.alloc.destroy(reg);
        }
        self.pty_regs.deinit(self.alloc);
        for (self.terminals.items) |ts| self.alloc.destroy(ts);
        self.terminals.deinit(self.alloc);

        if (self.renderer) |*r| {
            r.deinit();
            self.renderer = null;
        }
        if (self.shadow) |*s| {
            s.destroy(self.alloc);
            self.shadow = null;
        }
        self.damage.deinit(self.alloc);
        if (self.disc) |*d| {
            d.deinit();
            self.disc = null;
        }

        if (self.drm_token) |t| self.lp.removeSource(t);
        if (self.drm) |d| {
            d.deinit();
            self.drm = null;
        }
        if (self.fb) |*f| {
            f.deinit();
            self.fb = null;
        }

        if (self.seat_token) |t| self.lp.removeSource(t);
        if (self.ls) |l| {
            l.deinit();
            self.ls = null;
        }
        if (self.vt) |*v| {
            v.deinit();
            self.vt = null;
        }

        if (self.signals) |s| {
            s.deinit();
            self.alloc.destroy(s);
            self.signals = null;
        }
        self.lp.deinit();
    }

    fn setup(self: *Console) !void {
        // 2. Process-global PNG hook before any VT use.
        spng.install();

        // 3. Loop + signals (blocked before the seat activates).
        self.lp = try loop.Loop.init();
        const sigs: []const posix.SIG = if (self.cfg.libseat)
            &.{ .TERM, .INT, .CHLD }
        else
            &.{ .TERM, .INT, .CHLD, .USR1, .USR2 };
        const ss = try self.alloc.create(loop.SignalSource);
        errdefer self.alloc.destroy(ss);
        try ss.init(&self.lp, .{
            .callback = onSignal,
            .userdata = @intFromPtr(self),
            .signals = sigs,
        });
        self.signals = ss;

        // 4. Seat.
        try self.setupSeat();

        // 5. Video + modeset.
        try self.setupVideo();

        // 6. Font + grid.
        try self.setupFont();

        // 7. Renderer + sessions.
        try self.setupSessions();

        // 8. Input.
        try self.setupInput();

        // 10. Timers.
        try self.dpms_timer.init(&self.lp, .{ .callback = onDpmsTimer, .userdata = @intFromPtr(self) });
        try self.blink_timer.init(&self.lp, .{ .callback = onBlinkTimer, .userdata = @intFromPtr(self) });
        try self.respawn_timer.init(&self.lp, .{ .callback = onRespawnTimer, .userdata = @intFromPtr(self) });
        try self.kitty_timer.init(&self.lp, .{ .callback = onKittyTimer, .userdata = @intFromPtr(self) });
        if (self.cfg.blink) try self.blink_timer.armInterval(blink_interval_ns);
        self.armDpms();

        // 11. issue text before login.
        try self.showIssue();

        // 12. locale1 live keymap follow (best effort: no bus is fine).
        self.setupLocale1() catch |err| log.info("locale1 unavailable: {t}", .{err});

        // Activate the seat last: the activated callback takes DRM master
        // and triggers the first redraw, now that everything exists.
        try self.seat_handle.activate();
        // libseat may have fired activation before the sessions existed;
        // guarantee a first full frame regardless of seat backend.
        self.seat_active = true;
        self.full_redraw = true;
        self.markDirty();
    }

    fn setupSeat(self: *Console) !void {
        self.seat_cbs = .{
            .activated = onSeatActivated,
            .deactivated = onSeatDeactivated,
        };
        if (self.cfg.libseat) {
            const ls = try libseat.LibseatSeat.init(self.alloc, libseat.LibseatOps.real);
            self.ls = ls;
            self.seat_handle = ls.seat();
            self.seat_handle.setCallbacks(&self.seat_cbs, @intFromPtr(self));
            if (ls.seatFd()) |fd| {
                self.seat_token = try self.lp.addSource(fd, loop.ev.in_, onSeatEvent, @intFromPtr(self));
            }
        } else {
            self.vt = vt_real.VtReal.init(vt_real.Sys.real);
            const v = &self.vt.?;
            const requested = try vtNumber(self.cfg.vt);
            _ = try v.openVt(requested, self.cfg.switchvt);
            self.seat_handle = v.asSeat();
            self.seat_handle.setCallbacks(&self.seat_cbs, @intFromPtr(self));
            self.seat_token = try self.lp.addSource(v.vt_fd, loop.ev.in_ | loop.ev.hup, onVtEvent, @intFromPtr(self));
        }
    }

    fn setupVideo(self: *Console) !void {
        if (!self.cfg.drm) {
            self.fb = try fbdev.Fbdev.initReal(self.alloc, null);
            self.backend = self.fb.?.backend();
        } else {
            if (self.cfg.hwaccel) {
                // Drm3d exists but its GBM/EGL/GL C bindings are not wired
                // into build.zig (owned by the build integration); fall back.
                log.warn("--hwaccel: Drm3d not available in this build, using Drm2d", .{});
            }
            self.drm = try drm2d.Drm2d.init(self.alloc, null, drm2d.libdrm.ops());
            self.backend = self.drm.?.backend();
            try self.drm.?.takeMaster();
            self.drm_token = try self.lp.addSource(self.drm.?.eventFd(), loop.ev.in_, onDrmEvent, @intFromPtr(self));
        }

        const sel = try self.selectMode();
        try self.backend.setMode(sel.ci, sel.mi);
        self.mode = sel.mode;
    }

    /// First connected, enabled connector + preferred mode, honouring the
    /// three-tier `--mode`/`--screen` lookup (config.getMode/getScreen).
    fn selectMode(self: *Console) !struct { ci: usize, mi: usize, mode: video.Mode } {
        const conns = try self.backend.connectors();
        for (conns, 0..) |conn, ci| {
            if (!conn.connected or conn.modes.len == 0) continue;
            const screen = self.cfg.getScreen(conn.card_name, conn.name);
            if (!screen.enabled) continue;
            self.rotation = orientationToRotation(screen.orientation);
            var mi: usize = conn.preferred_mode orelse 0;
            if (self.cfg.getMode(conn.card_name, conn.name)) |want| {
                for (conn.modes, 0..) |m, j| {
                    if (m.width_px == want.width and m.height_px == want.height and
                        (want.refresh_rate == 0 or m.refresh_mhz == want.refresh_rate * 1000))
                    {
                        mi = j;
                        break;
                    }
                }
            }
            return .{ .ci = ci, .mi = mi, .mode = conn.modes[mi] };
        }
        return error.NoConnectedDisplay;
    }

    fn setupFont(self: *Console) !void {
        self.size_px = if (self.cfg.font_size != 0)
            @intCast(@min(self.cfg.font_size, std.math.maxInt(u16)))
        else
            autoFontSize(self.mode);

        self.disc = try discovery.Discovery.init(self.alloc);
        self.face = try self.disc.?.primaryFace(self.cfg.font_name, self.size_px);
        self.cell = try discovery.cellMetrics(self.face);
        if (self.cell.cell_w == 0 or self.cell.cell_h == 0) return error.InvalidCellMetrics;

        const eff = self.rotation.effectiveDimensions(self.mode.width_px, self.mode.height_px);
        self.cols = @intCast(@max(1, @min(eff.w / self.cell.cell_w, std.math.maxInt(u16))));
        self.rows = @intCast(@max(1, @min(eff.h / self.cell.cell_h, std.math.maxInt(u16))));

        self.renderer = try cpu.CpuRenderer.init(self.alloc, &self.disc.?, &self.face, .{
            .size_px = self.size_px,
        });
        try self.renderer.?.resize(self.cols, self.rows, self.cell.cell_w, self.cell.cell_h);

        self.shadow = try video.Framebuffer.create(self.alloc, eff.w, eff.h, .xrgb8888, null);
    }

    fn setupSessions(self: *Console) !void {
        self.mgr = try manager.Manager.init(self.alloc, self.cfg);
        self.mgr.?.createSession = createTerminal;
        try self.mgr.?.resize(self.cols, self.rows);

        if (self.cfg.asciicast) |path| {
            const r = try self.alloc.create(asciicast.Recorder);
            errdefer self.alloc.destroy(r);
            r.* = try asciicast.Recorder.init(self.alloc, path, .{
                .width = self.cols,
                .height = self.rows,
                .loop = self.cfg.asciicast_loop,
            });
            self.recorder = r;
        }

        try self.mgr.?.openInitial();
    }

    fn setupInput(self: *Console) !void {
        self.keymap = try xkb.Keymap.init(self.io, self.alloc, .{
            .model = self.cfg.xkb_model,
            .layout = self.cfg.xkb_layout,
            .variant = self.cfg.xkb_variant,
            .options = self.cfg.xkb_options,
            .keymap_file = self.cfg.xkb_keymap,
        });
        self.input = try libinput.Input.init(self.alloc, self.io, &self.keymap.?, self.cfg, libinput.LibinputOps.real);
        self.input.?.setSink(onInput, @intFromPtr(self));

        const ra = try self.alloc.create(RepeatAdapter);
        errdefer self.alloc.destroy(ra);
        ra.* = .{ .input = &self.input.? };
        try ra.timer.init(&self.lp, .{ .callback = RepeatAdapter.fired, .userdata = @intFromPtr(ra) });
        self.repeat = ra;
        self.input.?.attachRepeatTimer(.{ .ctx = ra, .arm = RepeatAdapter.arm, .disarm = RepeatAdapter.disarm });

        self.input_token = try self.lp.addSource(self.input.?.fd(), loop.ev.in_, onInputEvent, @intFromPtr(self));
        try self.input.?.dispatch(); // initial DEVICE_ADDED
    }

    fn setupLocale1(self: *Console) !void {
        const l = try self.alloc.create(locale1.Locale1);
        errdefer self.alloc.destroy(l);
        l.* = try locale1.Locale1.init(self.alloc, locale1.real);
        self.loc1 = l;
        const fd = try l.fd();
        self.locale_token = try self.lp.addSource(fd, loop.ev.in_, onLocale1Event, @intFromPtr(self));
    }

    fn showIssue(self: *Console) !void {
        if (!self.cfg.issue) return;
        const active = self.mgr.?.activeSession() orelse return;
        const ts: *terminal.TerminalSession = @ptrCast(@alignCast(active.ptr));
        var sys = try issue.systemContext(self.alloc, self.io, self.ttyName());
        defer sys.deinit();
        const text = (try issue.getBuffer(self.alloc, self.io, self.cfg.issue_path, &sys.ctx)) orelse return;
        defer self.alloc.free(text);
        ts.vt.write(text);
        self.markDirty();
    }

    // -- helpers -----------------------------------------------------------

    fn ttyName(self: *const Console) []const u8 {
        if (self.vt) |*v| {
            const p = v.path();
            return std.fs.path.basename(p);
        }
        return "tty0";
    }

    fn seatName(self: *const Console) []const u8 {
        _ = self;
        return "seat0";
    }

    fn vtNr(self: *const Console) ?u32 {
        if (self.vt) |*v| return v.vtNum();
        return null;
    }

    fn armDpms(self: *Console) void {
        if (self.cfg.dpms_timeout == 0) return;
        self.dpms_timer.armOneShot(@as(u64, self.cfg.dpms_timeout) * std.time.ns_per_s) catch |err|
            log.warn("dpms timer: {t}", .{err});
    }

    fn markDirty(self: *Console) void {
        self.dirty = true;
        self.renderIfDirty();
    }

    fn videoTakeMaster(self: *Console) void {
        if (self.drm) |d| d.takeMaster() catch |err| log.err("takeMaster: {t}", .{err});
    }

    fn videoDropMaster(self: *Console) void {
        if (self.drm) |d| d.dropMaster() catch |err| log.err("dropMaster: {t}", .{err});
    }

    /// Present the active session if there is damage and no flip is in
    /// flight. DRM completion re-triggers this through onDrmEvent; fbdev is
    /// synchronous (flipPending always false).
    fn renderIfDirty(self: *Console) void {
        if (!self.dirty or self.dpms_off or !self.seat_active) return;
        if (self.backend.flipPending()) return;
        if (self.mgr == null or self.shadow == null) return;
        const m = &self.mgr.?;
        const shadow = &self.shadow.?;

        const fb = self.backend.beginFrame() catch |err| {
            log.warn("beginFrame: {t}", .{err});
            return;
        };
        self.damage.clearRetainingCapacity();
        const ctx = sess.RenderContext{
            .fb = shadow,
            .damage = &self.damage,
            .cell_w = self.cell.cell_w,
            .cell_h = self.cell.cell_h,
            .cols = self.cols,
            .rows = self.rows,
        };
        // Kitty pixels come from the active session's terminal (M4);
        // the render state alone cannot reach the storage.
        self.renderer.?.vt = if (self.activeTerminal()) |ts| &ts.vt else null;
        m.render(&ctx) catch |err| {
            log.warn("render: {t}", .{err});
            return;
        };
        // Advance kitty animations once per rendered frame and schedule
        // the next one (M4.4); the tick's new pixel generations reach the
        // renderer through the next frame's placement list.
        self.tickKittyAnimations();
        // The shadow holds the complete image in logical (content) space;
        // blit it into the physical back buffer, rotating if needed (M5.4).
        if (self.rotation == .normal) {
            fb.blitFrom(shadow.*, 0, 0, .{ .x = 0, .y = 0, .w = shadow.width, .h = shadow.height });
        } else {
            cpu.blitRotated(fb.*, shadow.*, self.rotation);
        }
        // Rotated frames are fully repainted, so present the whole frame.
        const dmg: []const video.Damage = if (self.full_redraw or self.rotation != .normal) &.{} else self.damage.items;
        self.backend.endFrame(dmg) catch |err| {
            log.warn("endFrame: {t}", .{err});
            return;
        };
        self.dirty = false;
        self.full_redraw = false;
    }

    fn wakeDpms(self: *Console) void {
        if (self.dpms_off) {
            self.backend.setDpms(.on) catch |err| log.warn("dpms on: {t}", .{err});
            self.dpms_off = false;
            self.full_redraw = true;
        }
        self.armDpms();
    }

    fn switchVt(self: *Console, n: u8) void {
        if (self.vt) |*v| {
            const rc = linux.ioctl(v.vt_fd, vt_real.vt.activate, n);
            if (linux.errno(rc) != .SUCCESS) log.warn("VT_ACTIVATE {d} failed", .{n});
        }
    }

    fn ringBell(self: *Console) void {
        if (!self.cfg.bell) return;
        if (self.vt) |*v| {
            // 880 Hz for 100 ms (kmscon forwards BEL to the VT).
            const arg: usize = (100 << 16) | 880;
            _ = linux.ioctl(v.vt_fd, kdmktone, arg);
        }
    }

    fn requestQuit(self: *Console) void {
        self.lp.stop();
    }

    fn reapChildren(self: *Console) void {
        for (self.pty_regs.items) |reg| {
            reg.ts.reapChild() catch |err| log.warn("reap: {t}", .{err});
        }
    }

    /// Resolve a grab id that is not a session grab (those are handled by
    /// the manager). VT-switch is handled in the input sink before this.
    fn handleGrab(self: *Console, id: u16) void {
        if (self.mgr == null) return;
        const m = &self.mgr.?;
        switch (id) {
            7, 8, 9, 10 => m.handleGrab(id), // session next/prev/close/new
            13 => { // reboot (disabled by default)
                log.warn("reboot grab triggered", .{});
                // reboot(2): LINUX_REBOOT_MAGIC1/2 + RB_AUTOBOOT (linux/reboot.h).
                _ = linux.syscall4(.reboot, 0xfee1dead, 0x28121969, 0x01234567, 0);
            },
            1, 2, 3, 4 => self.handleScroll(id), // scroll/page (M2.2)
            5, 6 => self.handleZoom(id), // zoom in/out (M3.8)
            11, 12 => self.handleRotate(id), // rotate cw/ccw (M5.4)
            else => log.debug("grab {d}: unknown action", .{id}),
        }
        self.markDirty();
    }

    /// The focused terminal session, or null when there is none.
    fn activeTerminal(self: *Console) ?*terminal.TerminalSession {
        const m = &self.mgr.?;
        const s = m.activeSession() orelse return null;
        return @ptrCast(@alignCast(s.ptr));
    }

    /// grab-scroll-up/down (1 line) and grab-page-up/down (full page) on
    /// the active session's viewport (M2.2). A moved viewport marks the
    /// whole frame dirty, so markDirty below repaints it.
    fn handleScroll(self: *Console, id: u16) void {
        const ts = self.activeTerminal() orelse return;
        const result = switch (id) {
            1 => ts.vt.scrollViewport(.{ .delta = -1 }),
            2 => ts.vt.scrollViewport(.{ .delta = 1 }),
            3 => ts.vt.pageUp(),
            4 => ts.vt.pageDown(),
            else => return,
        };
        result catch |err| log.warn("scroll grab: {t}", .{err});
    }

    /// grab-zoom-in/out: step the font size, then reconfigure the grid and
    /// every session (M3.8).
    fn handleZoom(self: *Console, id: u16) void {
        const steps: i32 = if (id == 5) 1 else -1;
        const next = atlas.applyZoom(
            @floatFromInt(self.size_px),
            steps,
            @floatFromInt(min_font_px),
            @floatFromInt(max_font_px),
        );
        const new_px: u16 = @intFromFloat(next);
        if (new_px == self.size_px) return;
        const metrics = self.renderer.?.setFontSize(new_px) catch |err| {
            log.warn("zoom: {t}", .{err});
            return;
        };
        self.size_px = new_px;
        self.cell = metrics;
        self.reconfigureGrid() catch |err| log.warn("zoom regrid: {t}", .{err});
        self.full_redraw = true;
    }

    /// grab-rotate-cw/ccw: cycle the screen rotation and reconfigure (M5.4).
    fn handleRotate(self: *Console, id: u16) void {
        self.rotation = if (id == 11) self.rotation.rotateCw() else self.rotation.rotateCcw();
        self.reconfigureGrid() catch |err| {
            log.warn("rotate regrid: {t}", .{err});
            return;
        };
        self.full_redraw = true;
    }

    /// Recompute the grid from the current cell size and rotation, resize
    /// the renderer and every session, and rebuild the shadow framebuffer
    /// when the logical (post-rotation) size changed. Shared by zoom/rotate.
    fn reconfigureGrid(self: *Console) !void {
        const eff = self.rotation.effectiveDimensions(self.mode.width_px, self.mode.height_px);
        self.cols = @intCast(@max(1, @min(eff.w / self.cell.cell_w, std.math.maxInt(u16))));
        self.rows = @intCast(@max(1, @min(eff.h / self.cell.cell_h, std.math.maxInt(u16))));
        try self.renderer.?.resize(self.cols, self.rows, self.cell.cell_w, self.cell.cell_h);
        try self.mgr.?.resize(self.cols, self.rows);
        if (self.shadow) |*s| {
            if (s.width != eff.w or s.height != eff.h) {
                s.destroy(self.alloc);
                self.shadow = null;
                self.shadow = try video.Framebuffer.create(self.alloc, eff.w, eff.h, .xrgb8888, null);
            }
        }
    }

    fn respawn(self: *Console, ts: *terminal.TerminalSession) void {
        self.respawn_pending = ts;
        self.respawn_timer.armOneShot(respawn_delay_ns) catch |err| log.warn("respawn timer: {t}", .{err});
    }

    fn doRespawn(self: *Console) void {
        const ts = self.respawn_pending orelse return;
        self.respawn_pending = null;
        const s = ts.session();
        s.stop() catch |err| log.warn("respawn stop: {t}", .{err});
        s.start() catch |err| {
            log.err("respawn start: {t}", .{err});
            return;
        };
        // Re-register the (new) pty master.
        for (self.pty_regs.items) |reg| {
            if (reg.ts == ts) {
                self.lp.removeSource(reg.token);
                reg.token = self.lp.addSource(ts.masterFd(), loop.ev.in_ | loop.ev.edge_triggered, onPtyEvent, @intFromPtr(reg)) catch |err| {
                    log.err("respawn register: {t}", .{err});
                    return;
                };
                break;
            }
        }
        self.full_redraw = true;
        self.markDirty();
    }

    // -- loop handlers -----------------------------------------------------

    fn onSignal(_: *loop.SignalSource, info: loop.SignalSource.Info, ud: usize) void {
        const self: *Console = @ptrFromInt(ud);
        const signo = info.signo;
        if (signo == @intFromEnum(posix.SIG.TERM) or signo == @intFromEnum(posix.SIG.INT)) {
            self.requestQuit();
        } else if (signo == @intFromEnum(posix.SIG.CHLD)) {
            self.reapChildren();
        } else if (signo == @intFromEnum(posix.SIG.USR1) or signo == @intFromEnum(posix.SIG.USR2)) {
            if (self.vt) |*v| v.handleSignal(signo) catch |err| log.err("vt signal: {t}", .{err});
        }
    }

    fn onSeatActivated(ud: usize) void {
        const self: *Console = @ptrFromInt(ud);
        self.seat_active = true;
        self.videoTakeMaster();
        self.full_redraw = true;
        self.markDirty();
    }

    fn onSeatDeactivated(ud: usize) void {
        const self: *Console = @ptrFromInt(ud);
        self.seat_active = false;
        self.videoDropMaster();
    }

    fn onVtEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        const self: *Console = @ptrFromInt(ud);
        if (events & loop.ev.hup != 0) {
            log.warn("VT fd hung up", .{});
            self.requestQuit();
        }
    }

    fn onSeatEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        _ = events;
        const self: *Console = @ptrFromInt(ud);
        if (self.ls) |ls| _ = ls.dispatch(0) catch |err| log.warn("libseat dispatch: {t}", .{err});
    }

    fn onDrmEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        const self: *Console = @ptrFromInt(ud);
        if (events & (loop.ev.err | loop.ev.hup) != 0) {
            log.warn("DRM fd error/hangup", .{});
            self.requestQuit();
            return;
        }
        if (self.drm) |d| {
            d.readEvents() catch |err| {
                log.warn("drm readEvents: {t}", .{err});
                return;
            };
            if (d.needsFullRedraw()) self.full_redraw = true;
        }
        self.renderIfDirty();
    }

    fn onInputEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        _ = events;
        const self: *Console = @ptrFromInt(ud);
        if (self.input) |*in| in.dispatch() catch |err| log.warn("input dispatch: {t}", .{err});
    }

    fn onPtyEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        _ = events;
        const reg: *PtyReg = @ptrFromInt(ud);
        const self = current orelse return;
        self.pumpTerminal(reg.ts);
    }

    fn pumpTerminal(self: *Console, ts: *terminal.TerminalSession) void {
        if (self.recorder == null) {
            ts.onPtyReadable() catch |err| log.warn("pty pump: {t}", .{err});
        } else {
            // Recording path: tap the master bytes for the asciicast recorder
            // before feeding the terminal (terminal.zig has no output hook).
            var buf: [16384]u8 = undefined;
            while (true) {
                const n = posix.read(ts.masterFd(), &buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.InputOutput => {
                        ts.reapChild() catch {};
                        break;
                    },
                    else => break,
                };
                if (n == 0) {
                    ts.reapChild() catch {};
                    break;
                }
                const bytes = buf[0..n];
                self.recorder.?.recordOutput(bytes) catch |err| log.warn("asciicast: {t}", .{err});
                ts.vt.write(bytes);
            }
        }
        self.markDirty();
    }

    fn onLocale1Event(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        _ = events;
        const self: *Console = @ptrFromInt(ud);
        const l = self.loc1 orelse return;
        const change = l.process() catch |err| {
            log.warn("locale1 process: {t}", .{err});
            return;
        };
        if (change) |ch| {
            if (self.input) |*in| {
                in.state.reload(ch.options.toXkb(xkb.Options)) catch |err|
                    log.warn("keymap reload: {t}", .{err});
            }
        }
    }

    fn onDpmsTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        if (self.dpms_off) return;
        self.backend.setDpms(.off) catch |err| {
            log.warn("dpms off: {t}", .{err});
            return;
        };
        self.dpms_off = true;
    }

    fn onBlinkTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        if (!self.cfg.blink) return;
        if (self.mgr) |*m| {
            if (m.activeSession()) |s| {
                const ts: *terminal.TerminalSession = @ptrCast(@alignCast(s.ptr));
                ts.blink_phase = !ts.blink_phase;
            }
        }
        self.markDirty();
    }

    fn onRespawnTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        self.doRespawn();
    }

    fn onKittyTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        self.markDirty();
    }

    fn onInput(ud: usize, event: sess.InputEvent) void {
        const self: *Console = @ptrFromInt(ud);
        self.wakeDpms();
        // VT-switch: Ctrl+Alt+F1..F12 produce XF86Switch_VT_1..12. The input
        // event carries the physical key (the keysym is not in InputEvent),
        // so detect the combination that yields those keysyms.
        if (event == .key) {
            const k = event.key;
            const press = @intFromEnum(kt.GhosttyKeyAction.press);
            const repeat = @intFromEnum(kt.GhosttyKeyAction.repeat);
            if ((k.action == press or k.action == repeat) and
                (k.mods & (kt.mod_ctrl | kt.mod_alt)) == (kt.mod_ctrl | kt.mod_alt))
            {
                const f1 = @intFromEnum(kt.GhosttyKey.f1);
                const f12 = @intFromEnum(kt.GhosttyKey.f12);
                if (k.ghostty_key >= f1 and k.ghostty_key <= f12) {
                    self.switchVt(@intCast(k.ghostty_key - f1 + 1));
                    return;
                }
            }
        }
        if (self.mgr) |*m| m.onInput(event) catch |err| log.warn("onInput: {t}", .{err});
        self.markDirty();
    }

    /// Advance the active terminal's kitty animations and arm the redraw
    /// timer at the next frame's due time (M4.4). Called once after each
    /// rendered frame; the timer re-enters through markDirty, so every
    /// animation frame is ticked exactly once per rendered frame.
    /// animationTick mutates storage (invalidating image handles), which
    /// is safe here: the frame is already drawn.
    fn tickKittyAnimations(self: *Console) void {
        const ts = self.activeTerminal() orelse return;
        const kg = ts.vt.kittyGraphics() catch |err| {
            log.warn("kitty graphics: {t}", .{err});
            return;
        };
        const now = monotonicMs();
        const next = kg.animationTick(now) catch |err| {
            log.warn("kitty animation tick: {t}", .{err});
            return;
        };
        if (next) |n| {
            self.kitty_timer.armOneShot(kittyRedrawDelayNs(now, n)) catch |err|
                log.warn("kitty timer: {t}", .{err});
        } else {
            self.kitty_timer.disarm() catch |err|
                log.warn("kitty timer disarm: {t}", .{err});
        }
    }
};

/// Milliseconds on the monotonic clock: the time base for kitty
/// animationTick, which requires a monotonic clock stable for the
/// terminal's lifetime.
fn monotonicMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Delay until the next animation frame is due, floored at 1 ms: a due
/// or past deadline must not disarm the timer (a zero delay) or spin the
/// loop (docs/reference/ghostty-vt-api.md §9.4).
fn kittyRedrawDelayNs(now_ms: u64, next_ms: u64) u64 {
    return @max(1, next_ms -| now_ms) * std.time.ns_per_ms;
}

/// The active console for the session factory (a plain fn pointer with no
/// closure). One console per process; the daemon spawns separate workers.
var current: ?*Console = null;

/// loop.Timer -> libinput.RepeatTimerOps adapter (libinput.zig header).
const RepeatAdapter = struct {
    input: *libinput.Input,
    timer: loop.Timer = .{},

    fn arm(ctx: ?*anyopaque, delay_ns: u64, interval_ns: u64) !void {
        const self: *RepeatAdapter = @ptrCast(@alignCast(ctx.?));
        try self.timer.arm(loop.nsToTimespec(delay_ns), loop.nsToTimespec(interval_ns));
    }

    fn disarm(ctx: ?*anyopaque) !void {
        const self: *RepeatAdapter = @ptrCast(@alignCast(ctx.?));
        try self.timer.disarm();
    }

    fn fired(_: *loop.Timer, expirations: u64, ud: usize) void {
        const self: *RepeatAdapter = @ptrFromInt(ud);
        self.input.repeatExpired(expirations);
    }
};

// ---------------------------------------------------------------------------
// Terminal factory + hooks
// ---------------------------------------------------------------------------

/// Manager.createSession factory: heap-allocate a TerminalSession (it must
/// not move after init), wire renderer/hooks/seat info, start it and register
/// its pty master edge-triggered. The manager's subsequent start() is a no-op.
fn createTerminal(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    cols: u16,
    rows: u16,
) anyerror!sess.Session {
    const c = current orelse return error.NoConsole;
    const ts = try alloc.create(terminal.TerminalSession);
    errdefer alloc.destroy(ts);
    ts.* = try terminal.TerminalSession.init(alloc, cfg, cols, rows);
    errdefer ts.deinit();

    // Kitty storage limit (M4.5): config.zig has no
    // kitty-image-storage-limit option yet, so Vt.init's 10 MiB default
    // (vt.default_kitty_storage_limit) applies.
    //
    // R3 root hardening: the VT unit runs as root, and kitty file /
    // temp-file / shared-memory media could read root-only files. Keep
    // them disabled (a NULL value disables each; they are off by
    // default, this pins them off explicitly). Only direct data and
    // PNG media remain when euid is 0.
    if (linux.geteuid() == 0) {
        try ts.vt.setOption(.kitty_image_medium_file, null);
        try ts.vt.setOption(.kitty_image_medium_temp_file, null);
        try ts.vt.setOption(.kitty_image_medium_shared_mem, null);
    }

    ts.setRenderer(c.renderer.?.renderer());
    ts.seat_name = c.seatName();
    ts.vt_nr = c.vtNr();
    ts.drm = cfg.drm;
    ts.hooks = .{
        .userdata = ts,
        .bell = hookBell,
        .set_background = hookBackground,
        .set_foreground = hookForeground,
        .grab = hookGrab,
        .child_exit = hookChildExit,
    };

    try ts.session().start();
    try c.terminals.append(alloc, ts);

    const reg = try alloc.create(PtyReg);
    errdefer alloc.destroy(reg);
    reg.* = .{ .ts = ts, .token = undefined };
    reg.token = try c.lp.addSource(ts.masterFd(), loop.ev.in_ | loop.ev.edge_triggered, Console.onPtyEvent, @intFromPtr(reg));
    c.pty_regs.append(alloc, reg) catch |err| {
        c.lp.removeSource(reg.token);
        return err;
    };

    return ts.session();
}

fn hookBell(ud: ?*anyopaque) void {
    _ = ud;
    if (current) |c| c.ringBell();
}

fn hookBackground(ud: ?*anyopaque) void {
    _ = ud;
    const c = current orelse return;
    // GUI launch: release DRM master so the GUI can take it (kmscon §3.2).
    c.videoDropMaster();
}

fn hookForeground(ud: ?*anyopaque) void {
    _ = ud;
    const c = current orelse return;
    // GUI exit: retake master and redraw (kmscon §3.3).
    c.videoTakeMaster();
    c.full_redraw = true;
    c.markDirty();
}

fn hookGrab(ud: ?*anyopaque, id: u16) void {
    _ = ud;
    if (current) |c| c.handleGrab(id);
}

fn hookChildExit(ud: ?*anyopaque, status: terminal.Pty.ReapStatus) void {
    const c = current orelse return;
    const ts: *terminal.TerminalSession = @ptrCast(@alignCast(ud.?));
    log.info("login child exited: {any}", .{status});
    if (c.cfg.oneshot) {
        c.requestQuit();
    } else {
        c.respawn(ts);
    }
}

// ---------------------------------------------------------------------------
// Auto font size + VT number parsing
// ---------------------------------------------------------------------------

/// `--font-size 0`: derive a pixel size from the panel's physical height so
/// HiDPI panels get a readable font (~12 pt at the panel DPI). Falls back to
/// 16 px when the connector reports no physical size.
fn autoFontSize(mode: video.Mode) u16 {
    if (mode.height_mm == 0) return 16;
    const px = (@as(u64, mode.height_px) * 254) / (@as(u64, mode.height_mm) * 60);
    return @intCast(std.math.clamp(px, 8, 72));
}

/// Map the config `--screen` orientation to the layout rotation (M5.4).
fn orientationToRotation(o: config.Orientation) layout.Rotation {
    return switch (o) {
        .normal => .normal,
        .left => .left,
        .right => .right,
        .upside_down => .inverted,
    };
}

/// config.vt is a device path ("/dev/ttyN"); VtReal.openVt wants the number.
fn vtNumber(vt_path: ?[]const u8) !?u8 {
    const p = vt_path orelse return null;
    const base = std.fs.path.basename(p);
    const digits = if (std.mem.startsWith(u8, base, "tty")) base[3..] else base;
    const n = std.fmt.parseInt(u8, digits, 10) catch return error.InvalidVt;
    if (n == 0 or n > vt_real.max_vt) return error.InvalidVt;
    return n;
}

// ---------------------------------------------------------------------------
// Run paths
// ---------------------------------------------------------------------------

fn runConsole(io: std.Io, alloc: std.mem.Allocator, cfg: *const config.Config) !void {
    const c = try alloc.create(Console);
    defer alloc.destroy(c);
    c.* = .{ .alloc = alloc, .io = io, .cfg = cfg };
    errdefer c.deinit();
    current = c;
    defer current = null;

    try c.setup();
    log.info("kmshaunt console up: {d}x{d} grid, {d}px font, vt {s}", .{
        c.cols, c.rows, c.size_px, c.ttyName(),
    });
    try c.lp.run();
    c.deinit();
}

/// Multi-seat daemon (kmshaunt.service: `--libseat`, no pinned VT). A
/// simplified supervision path: SeatMonitor reports seat add/remove and we
/// spawn one pinned-VT worker process per seat (a worker with `--vt` runs the
/// single-seat console, so there is no recursion). Full udev ID_SEAT filtering
/// and fake-VT workers for non-seat0 seats are M6; this supervises seat0-class
/// seats with real VTs.
fn runDaemon(io: std.Io, alloc: std.mem.Allocator, cfg: *const config.Config) !void {
    var lp = try loop.Loop.init();
    defer lp.deinit();

    var mon = try multiseat.SeatMonitor.init(alloc, multiseat.SdLoginOps.real);
    defer mon.deinit();

    const Daemon = struct {
        lp: *loop.Loop,
        mon: *multiseat.SeatMonitor,
        alloc: std.mem.Allocator,
        io: std.Io,
        next_vt: u8 = 2,

        fn onSignal(_: *loop.SignalSource, info: loop.SignalSource.Info, ud: usize) void {
            const self: *@This() = @ptrFromInt(ud);
            if (info.signo == @intFromEnum(posix.SIG.TERM) or info.signo == @intFromEnum(posix.SIG.INT)) {
                self.lp.stop();
            }
        }
        fn onSeat(lp_: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
            _ = lp_;
            _ = token;
            _ = events;
            const self: *@This() = @ptrFromInt(ud);
            const changes = self.mon.process() catch |err| {
                log.warn("seat monitor: {t}", .{err});
                return;
            };
            for (changes) |ch| switch (ch) {
                .added => |s| {
                    log.info("seat added: {s} (has_vt={})", .{ s.name, s.has_vt });
                    self.spawnWorker(s);
                },
                .removed => |s| log.info("seat removed: {s}", .{s.name}),
            };
        }
        fn spawnWorker(self: *@This(), s: multiseat.SeatInfo) void {
            if (s.needsFakeVt()) {
                log.warn("seat {s} needs a fake VT worker (M6); skipping", .{s.name});
                return;
            }
            const worker_vt = self.next_vt;
            self.next_vt +|= 1;
            var vt_buf: [16]u8 = undefined;
            const vt_arg = std.fmt.bufPrint(&vt_buf, "{d}", .{worker_vt}) catch return;
            const child = std.process.spawn(self.io, .{ .argv = &.{ "kmshaunt", "--vt", vt_arg } }) catch |err| {
                log.err("spawn worker for {s}: {t}", .{ s.name, err });
                return;
            };
            log.info("spawned worker for {s} on vt {d} (pid {d})", .{ s.name, worker_vt, child.id orelse 0 });
        }
    };

    var d = Daemon{ .lp = &lp, .mon = &mon, .alloc = alloc, .io = io };
    var ss: loop.SignalSource = undefined;
    try ss.init(&lp, .{ .callback = Daemon.onSignal, .userdata = @intFromPtr(&d), .signals = &.{ .TERM, .INT, .CHLD } });
    defer ss.deinit();

    const fd = try mon.fd();
    _ = try lp.addSource(fd, loop.ev.in_, Daemon.onSeat, @intFromPtr(&d));
    _ = mon.process() catch |err| log.warn("initial seat enumerate: {t}", .{err});

    log.info("kmshaunt daemon: supervising seats", .{});
    try lp.run();
    _ = cfg;
}

// ---------------------------------------------------------------------------
// M0 parseArgs tests (kept unchanged)
// ---------------------------------------------------------------------------

test "parseArgs: no arguments runs the console" {
    try std.testing.expectEqual(Action.run, parseArgs(&.{}).ok);
}

test "parseArgs: --version prints the version" {
    try std.testing.expectEqual(Action.print_version, parseArgs(&.{"--version"}).ok);
}

test "parseArgs: --help prints the usage" {
    try std.testing.expectEqual(Action.print_help, parseArgs(&.{"--help"}).ok);
}

test "parseArgs: unknown argument is reported" {
    const result = parseArgs(&.{"--bogus"});
    try std.testing.expectEqualStrings("--bogus", result.unknown);
}

test "parseArgs: the first argument decides" {
    try std.testing.expectEqual(Action.print_version, parseArgs(&.{ "--version", "--help" }).ok);
    try std.testing.expectEqualStrings("--bogus", parseArgs(&.{ "--bogus", "--version" }).unknown);
}

test "parseArgs: a bare word is unknown" {
    try std.testing.expectEqualStrings("run", parseArgs(&.{"run"}).unknown);
}

test "kittyRedrawDelayNs: future deadline, due and past floor at 1 ms" {
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), kittyRedrawDelayNs(100, 150));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), kittyRedrawDelayNs(100, 100));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), kittyRedrawDelayNs(100, 90));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), kittyRedrawDelayNs(std.math.maxInt(u64), 0));
}
