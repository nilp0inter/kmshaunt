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
//!  5. Video: `Fbdev` when `--no-drm`, else one DRM backend per GPU selected
//!     by `--gpus` (master is per device). `--hwaccel` selects Drm3d
//!     (GBM/EGL/GLES2 scanout); a card where GBM/EGL/GLES2 cannot come up
//!     (error.Unsupported) or nothing is connected (error.NoConnectedDisplay)
//!     falls back to Drm2d with a warning. Each card modesets every enabled
//!     connected connector via `selectModeIndex` (`--mode`/`--use-original-mode`/
//!     preferred), `--screen` rotation/disable, `--soft-cursor` force, and a
//!     udev hotplug monitor: one Output per connector, one shared backend per
//!     card (M5.4 multi-connector scanout; Drm3d drives one connector).
//!  6. Font: `Discovery.primaryFace` + `cellMetrics`; the shared grid and
//!     per-connector viewports come from `computeLayout` (`--multi-monitor`
//!     clone/largest/scaled). `--font-size 0` derives a size from the primary
//!     connector's physical mm.
//!  7. `CpuRenderer`, `Manager` + heap-allocated `TerminalSession` factory,
//!     terminal hooks, `openInitial`.
//!  8. Input: `xkb.Keymap` + `Input` (libinput), sink routes to the manager,
//!     repeat through a `loop.Timer` adapter, VT-switch grabs handled here.
//!  9. Each terminal's pty master registered EPOLLIN edge-triggered.
//! 10. Frame loop paced by a one-shot frame timer (one display refresh)
//!     plus DRM page-flip completion events; under a sustained output burst
//!     the frame period stretches so render+present occupies a bounded
//!     fraction of the loop and the pty keeps draining (M8.1). DPMS +
//!     cursor-blink + kitty-animation + pointer-autohide timers.
//! 11. issue text, asciicast playback, locale1 live keymap follow.
//! 12. `loop.run`; SIGTERM/INT (or oneshot child exit) stops it; everything
//!     is deinitialised in reverse order.
//!
//! # Main-loop fd/event table
//!
//! | fd                    | interest        | handler                  |
//! |-----------------------|-----------------|--------------------------|
//! | signalfd              | IN              | onSignal                 |
//! | VT fd / libseat fd    | IN (+HUP VT)    | onVtEvent / onSeatEvent  |
//! | DRM event fd (each)   | IN              | onDrmEvent               |
//! | udev hotplug fd (each)| IN              | onHotplugEvent           |
//! | libinput fd           | IN              | onInputEvent             |
//! | each pty master       | IN \| ET        | onPtyEvent               |
//! | locale1 bus fd        | IN              | onLocale1Event           |
//! | DPMS timerfd          | IN              | onDpmsTimer              |
//! | blink timerfd         | IN              | onBlinkTimer             |
//! | repeat timerfd        | IN              | RepeatAdapter.fired      |
//! | kitty timerfd         | IN              | onKittyTimer             |
//!
//! Rendering uses a persistent shadow framebuffer sized to the shared canvas:
//! the CPU renderer paints only dirty rows, so the shadow accumulates the full
//! image across frames. Each output presents its viewport of the shadow
//! (crop/scale/rotate per its layout.Plan) into the backend's alternating back
//! buffer before each flip (the back buffer must hold a complete frame).
//! The software pointer is composited into the back buffer only (never the
//! shadow), with both its erase and draw rects damaged every frame.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");

const config = @import("config/config.zig");
const loop = @import("loop.zig");
const seat = @import("seat.zig");
const vt_real = @import("seat/vt_real.zig");
const vt_fake = @import("seat/vt_fake.zig");
const libseat = @import("seat/libseat.zig");
const multiseat = @import("seat/multiseat.zig");
const video = @import("video.zig");
const drm2d = @import("video/drm2d.zig");
const drm3d = @import("video/drm3d.zig");
const fbdev = @import("video/fbdev.zig");
const render = @import("render.zig");
const cpu = @import("render/cpu.zig");
const deco = @import("render/decorations.zig");
const pointer = @import("render/pointer.zig");
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

    // Seat workers (KMSHAUNT_SEAT set by runDaemon) always run the
    // console, whatever the inherited config says; layer their per-seat
    // config (CLI lock < main < <seat>.seat.conf, kmscon config.c:1167).
    const worker_seat = multiseat.workerSeat(init.minimal.environ);
    if (worker_seat) |name| {
        const seat_cfg = try cfg.loadSeat(arena, io, name);
        cfg.deinit();
        cfg = seat_cfg;
    }

    // Multi-seat daemon: libseat without a pinned VT (kmshaunt.service).
    // The single-seat path is selected whenever a VT is requested.
    const result = if (worker_seat == null and cfg.libseat and cfg.vt == null)
        runDaemon(io, arena, &cfg, init.minimal.environ)
    else
        runConsole(io, arena, &cfg, worker_seat);

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
/// Software-pointer autohide poll cadence: a quarter of the model's idle
/// timeout. The model owns the exact idle math (tick); the timer only
/// wakes it, so the hide lands within one poll after the deadline.
const pointer_poll_ns: u64 = @intCast(@divTrunc(pointer.default_idle_timeout_ns, 4));
/// M8.1 burst pacing: render+present runs in the single-threaded loop, so
/// rendering every refresh while output floods in caps pty consumption at
/// parse_rate * (1 - render_duty). While a burst is active the frame period
/// stretches so rendering occupies at most ~1/(1+factor) of the loop time
/// and the pty drains during the deferral. Cheap frames (small damage) keep
/// the refresh period, and idle/interactive damage is never delayed: the
/// burst gate requires a pty pump within the last refresh.
const burst_stretch_factor: u64 = 9;
/// Display-rate floor for burst frames (M8.4 T5 real-hardware finding). The
/// stretch factor bounds render duty for cheap frames, but on expensive
/// content (many cells, complex glyphs, large back-buffer blits) 9x the frame
/// cost pushed the visible frame period to ~0.5-1 s (1-2 fps): animation
/// became input-paced, since only the input hook (frame_due_ns = 0) forced a
/// frame. Cap the burst frame period so the display never drops below ~10 fps
/// even for expensive content. Frames cheaper than max_period/factor keep the
/// pure duty-bounding stretch; costlier frames trade throughput for a usable
/// display rate (a frame still cannot present faster than its own cost).
const max_burst_frame_period_ns: u64 = 100 * std.time.ns_per_ms;
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

/// One opened DRM card: Drm2d (dumb buffers) or Drm3d (GBM/EGL/GLES2,
/// `--hwaccel`). The legacy `video.Backend` vtable drives the primary
/// (first modeset) connector; this union adds the DRM-specific calls the
/// console needs (master handoff, event fd, hotplug, mode selection) and
/// the per-connector frame path (M5.4). Drm2d modesets several connectors
/// per card; Drm3d drives a single connector.
const DrmOutput = union(enum) {
    drm2d: *drm2d.Drm2d,
    drm3d: *drm3d.Drm3d,

    fn backend(self: DrmOutput) video.Backend {
        return switch (self) {
            .drm2d => |d| d.backend(),
            .drm3d => |d| d.backend(),
        };
    }

    fn cardName(self: DrmOutput) []const u8 {
        return switch (self) {
            .drm2d => |d| d.card_name,
            .drm3d => |d| d.card_name,
        };
    }

    fn cardPath(self: DrmOutput) []const u8 {
        return switch (self) {
            .drm2d => |d| d.card_path,
            .drm3d => |d| d.card_path,
        };
    }

    fn eventFd(self: DrmOutput) i32 {
        return switch (self) {
            .drm2d => |d| d.eventFd(),
            .drm3d => |d| d.eventFd(),
        };
    }

    fn hotplugFd(self: DrmOutput) ?i32 {
        return switch (self) {
            .drm2d => |d| d.hotplugFd(),
            .drm3d => |d| d.hotplugFd(),
        };
    }

    fn enableHotplug(self: DrmOutput, ops: drm2d.HotplugOps) !void {
        return switch (self) {
            .drm2d => |d| d.enableHotplug(ops),
            .drm3d => |d| d.enableHotplug(ops),
        };
    }

    fn takeMaster(self: DrmOutput) !void {
        return switch (self) {
            .drm2d => |d| d.takeMaster(),
            .drm3d => |d| d.takeMaster(),
        };
    }

    fn dropMaster(self: DrmOutput) !void {
        return switch (self) {
            .drm2d => |d| d.dropMaster(),
            .drm3d => |d| d.dropMaster(),
        };
    }

    fn readEvents(self: DrmOutput) !void {
        return switch (self) {
            .drm2d => |d| d.readEvents(),
            .drm3d => |d| d.readEvents(),
        };
    }

    fn needsFullRedraw(self: DrmOutput) bool {
        return switch (self) {
            .drm2d => |d| d.needsFullRedraw(),
            .drm3d => |d| d.needsFullRedraw(),
        };
    }

    fn flipPending(self: DrmOutput) bool {
        return switch (self) {
            .drm2d => |d| d.flipPending(),
            .drm3d => |d| d.flipPending(),
        };
    }

    fn pollHotplug(self: DrmOutput) !bool {
        return switch (self) {
            .drm2d => |d| d.pollHotplug(),
            .drm3d => |d| d.pollHotplug(),
        };
    }

    fn connectors(self: DrmOutput) ![]const video.ConnectorInfo {
        return switch (self) {
            .drm2d => |d| d.connectors(),
            .drm3d => |d| d.connectors(),
        };
    }

    fn selectModeIndex(self: DrmOutput, ci: usize, spec: ?video.ModeSpec, use_original: bool) !?usize {
        return switch (self) {
            .drm2d => |d| d.selectModeIndex(ci, spec, use_original),
            .drm3d => |d| d.selectModeIndex(ci, spec, use_original),
        };
    }

    fn setMode(self: DrmOutput, ci: usize, mi: usize) !void {
        return switch (self) {
            .drm2d => |d| d.setMode(ci, mi),
            .drm3d => |d| d.setMode(ci, mi),
        };
    }

    fn setDpms(self: DrmOutput, state: video.DpmsState) !void {
        return switch (self) {
            .drm2d => |d| d.setDpms(state),
            .drm3d => |d| d.setDpms(state),
        };
    }

    /// Back buffer of connector `ci` (index into the last connectors()
    /// probe). Drm3d has a single scanout, so the index is ignored there.
    fn beginFrameFor(self: DrmOutput, ci: usize) !*video.Framebuffer {
        return switch (self) {
            .drm2d => |d| d.beginFrameFor(ci),
            .drm3d => |d| d.beginFrame(),
        };
    }

    fn endFrameFor(self: DrmOutput, ci: usize, damage: []const video.Damage) !void {
        return switch (self) {
            .drm2d => |d| d.endFrameFor(ci, damage),
            .drm3d => |d| d.endFrame(damage),
        };
    }

    /// The card's backend identity: all outputs of one card share the same
    /// pointer (DRM master is per device).
    fn cardPtr(self: DrmOutput) *anyopaque {
        return switch (self) {
            .drm2d => |d| d,
            .drm3d => |d| d,
        };
    }

    fn deinit(self: DrmOutput) void {
        switch (self) {
            .drm2d => |d| d.deinit(),
            .drm3d => |d| d.deinit(),
        }
    }
};

/// Per-connector frame sink for present(): Drm2d drives each modeset
/// connector's own CRTC + buffer pair (M5.4); Drm3d's single scanout
/// ignores the connector index.
const DrmFrame = struct {
    drm: DrmOutput,
    ci: usize,

    fn beginFrame(self: DrmFrame) !*video.Framebuffer {
        return self.drm.beginFrameFor(self.ci);
    }

    fn endFrame(self: DrmFrame, damage: []const video.Damage) !void {
        return self.drm.endFrameFor(self.ci, damage);
    }
};

/// One driven DRM output: one connector modeset on its card's backend (one
/// backend per card — DRM master is per device), plus its viewport into the
/// shared canvas. No pointer into `outputs` is ever handed to the loop:
/// every fd callback uses the Console as userdata and drains all cards,
/// so the list may grow/reorder freely (ROADMAP M5.4).
const Output = struct {
    drm: DrmOutput,
    /// Card-level fd tokens, held by the card's first output only (the fds
    /// are registered once per card).
    event_token: ?loop.Token = null,
    hotplug_token: ?loop.Token = null,
    /// Driven connector index in the last connectors() probe.
    ci: usize = 0,
    /// Connector name, owned: a connectors() re-probe frees the borrowed
    /// slices, and reprobe diffs outputs by name (M5.4).
    name: []const u8 = "",
    mode: video.Mode = .{ .width_px = 0, .height_px = 0, .refresh_mhz = 0, .width_mm = 0, .height_mm = 0 },
    rotation: layout.Rotation = .normal,
    plan: layout.Plan = .{},
    /// Damage presented in this output's previous frame: the back buffer
    /// alternates, so it is two frames stale and the next blit must cover
    /// both frames' damage (M8.1 band-limited present).
    prev_damage: sess.DamageList = .empty,
};

/// A connector + mode chosen for one output (selectForCard/selectFbMode).
const ModeSelection = struct {
    ci: usize,
    mi: usize,
    mode: video.Mode,
    rotation: layout.Rotation,
    name: []const u8 = "",
};

/// Upper bound on simultaneous outputs: the GPU selection buffer holds 8
/// cards, each driving several connectors (M5.4); fbdev adds at most one.
/// Headroom for both.
const max_outputs = 16;

/// The single-seat console. Heap-allocated and never moved: every callback
/// userdata pointer and every borrowed sub-object address derives from it.
/// Value-type sub-objects are embedded as optionals (their address is stable
/// inside this struct); the DRM backends and LibseatSeat own their heap allocation.
const Console = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,

    lp: loop.Loop = .{ .epoll_fd = -1 },
    signals: ?*loop.SignalSource = null,

    // Seat (exactly one of vt / libseat / fake_vt).
    vt: ?vt_real.VtReal = null,
    ls: ?*libseat.LibseatSeat = null,
    fake_vt: ?vt_fake.FakeVt = null,
    /// Daemon-spawned seat worker: the seat name from KMSHAUNT_SEAT.
    /// null for the daemon itself and ordinary single-seat consoles.
    worker_seat: ?[:0]const u8 = null,
    seat_handle: seat.Seat = undefined,
    seat_cbs: seat.Seat.Callbacks = .{},
    seat_token: ?loop.Token = null,

    // Video. DRM: one backend (Drm2d, or Drm3d with --hwaccel) per selected
    // card, modeset to every enabled connector (`outputs`, one per
    // connector, in card order). fbdev: a single output via `fb`. `backend`,
    // `mode` and `rotation` describe the primary (first) output for font
    // auto-sizing and logging.
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    fb: ?fbdev.Fbdev = null,
    backend: video.Backend = undefined,
    mode: video.Mode = .{ .width_px = 0, .height_px = 0, .refresh_mhz = 0, .width_mm = 0, .height_mm = 0 },
    /// Primary content rotation (M5.4); from cfg.screen, cycled by
    /// grab-rotate-cw/ccw. Per-output rotations live in Output.rotation.
    rotation: layout.Rotation = .normal,
    /// Shared terminal canvas from computeLayout (M5.4).
    canvas: layout.Canvas = .{},
    /// fbdev single-output viewport (DRM outputs use Output.plan).
    fb_plan: layout.Plan = .{},
    /// Scratch physical damage for the viewport present path.
    phys_damage: sess.DamageList = .empty,
    /// fbdev back-buffer damage history (DRM outputs use Output.prev_damage).
    fb_prev_damage: sess.DamageList = .empty,
    /// Hotplug arrived while the seat was inactive; reprobe on activation.
    reprobe_pending: bool = false,

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
    /// Effective xkb config: cfg fields win, locale1 fills unset ones
    /// (M6.5 startup parity). Tracked so setupLocale1 can close the
    /// read-vs-subscribe race.
    xkb_effective: xkb.Options = .{},
    input: ?libinput.Input = null,
    repeat: ?*RepeatAdapter = null,
    input_token: ?loop.Token = null,

    // Timers + misc.
    dpms_timer: loop.Timer = .{},
    blink_timer: loop.Timer = .{},
    respawn_timer: loop.Timer = .{},
    kitty_timer: loop.Timer = .{},
    asciicast_timer: loop.Timer = .{},
    /// M8.1 frame pacing: coalesces damage into one render per refresh.
    frame_timer: loop.Timer = .{},
    /// Software mouse pointer (canvas space); null when init failed —
    /// the console works without it.
    pointer: ?pointer.Pointer = null,
    /// One-shot autohide poll; armed only while the pointer is visible.
    pointer_timer: loop.Timer = .{},
    /// asciicast playback (M2.4), bound to the terminal it plays into.
    playback: ?*asciicast.Playback = null,
    playback_ts: ?*terminal.TerminalSession = null,
    loc1: ?*locale1.Locale1 = null,
    locale_token: ?loop.Token = null,

    // State.
    dirty: bool = false,
    full_redraw: bool = true,
    dpms_off: bool = false,
    seat_active: bool = false,
    respawn_pending: ?*terminal.TerminalSession = null,
    /// A frame timer arm is in flight (pins the deadline under load).
    frame_armed: bool = false,
    /// EWMA render+present cost (ns); drives the burst frame stretch.
    frame_cost_ns: u64 = 0,
    /// Monotonic deadline before which a burst frame may be deferred.
    frame_due_ns: i64 = 0,
    /// When the armed frame timer fires (ns); lets a pending full redraw
    /// preempt a burst-deferred arm without re-arming on every markDirty.
    frame_arm_deadline_ns: i64 = 0,
    /// Last pty pump completion (ns); the burst-activity gate.
    last_pump_ns: i64 = 0,
    /// Whether the most recent pty pump exhausted its drain budget (more
    /// pending). Distinguishes a sustained flood from a periodic trickle
    /// (e.g. btop): only a flood may defer a frame (burst gate).
    last_pump_more: bool = false,

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
        self.stopPlayback();
        self.pointer_timer.deinit();
        self.asciicast_timer.deinit();
        self.frame_timer.deinit();
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
        if (self.pointer) |*p| {
            p.deinit();
            self.pointer = null;
        }
        self.damage.deinit(self.alloc);
        self.phys_damage.deinit(self.alloc);
        self.fb_prev_damage.deinit(self.alloc);
        if (self.disc) |*d| {
            d.deinit();
            self.disc = null;
        }

        for (self.outputs.items) |*o| {
            if (o.hotplug_token) |t| self.lp.removeSource(t);
            if (o.event_token) |t| self.lp.removeSource(t);
            self.alloc.free(o.name);
            o.prev_damage.deinit(self.alloc);
        }
        // One backend per card: deinit each card once, not per output.
        var cards: [max_outputs]DrmOutput = undefined;
        for (cards[0..self.uniqueCards(&cards)]) |drm| drm.deinit();
        self.outputs.deinit(self.alloc);
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
        if (self.fake_vt) |*f| {
            // deactivate before deinit (vt_fake.zig deinit contract);
            // deinit fires no callbacks.
            self.seat_handle.deactivate() catch {};
            f.deinit();
            self.fake_vt = null;
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
        try self.asciicast_timer.init(&self.lp, .{ .callback = onAsciicastTimer, .userdata = @intFromPtr(self) });
        try self.frame_timer.init(&self.lp, .{ .callback = onFrameTimer, .userdata = @intFromPtr(self) });
        try self.pointer_timer.init(&self.lp, .{ .callback = onPointerTimer, .userdata = @intFromPtr(self) });
        if (self.cfg.blink) try self.blink_timer.armInterval(blink_interval_ns);
        self.armDpms();

        // 11. issue text before login.
        try self.showIssue();

        // 11b. asciicast playback after the issue text (kmscon
        // terminal_open: issue write, then asciinema_start). A bad file
        // only warns, like kmscon terminal.c:1528-1532.
        if (self.cfg.asciicast) |path| {
            self.startPlayback(path) catch |err|
                log.warn("cannot load asciicast {s}: {t}", .{ path, err });
        }

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
        if (self.worker_seat != null and self.cfg.vt == null) {
            // Fake-VT worker (M6.7): this seat has no kernel VT. FakeVt
            // starts active and is never switched (vt_fake.zig header,
            // kmscon vt_fake.c:39-41). No fd to register. session-control
            // stays enabled: kmscon only force-disables it on real VTs
            // (seat.c:780, uterm_vt_get_num > 0).
            self.fake_vt = vt_fake.FakeVt.init(self.alloc);
            self.seat_handle = self.fake_vt.?.seat();
            self.seat_handle.setCallbacks(&self.seat_cbs, @intFromPtr(self));
        } else if (self.cfg.libseat) {
            const ls = try libseat.LibseatSeat.init(self.alloc, libseat.LibseatOps.real);
            self.ls = ls;
            self.seat_handle = ls.seat();
            self.seat_handle.setCallbacks(&self.seat_cbs, @intFromPtr(self));
            if (ls.seatFd()) |fd| {
                self.seat_token = try self.lp.addSource(fd, loop.ev.in_, onSeatEvent, @intFromPtr(self));
            }
        } else {
            // Real VT: kmscon force-disables session-control with a warning
            // (seat.c:792-796). Clear it before Manager.init reads it.
            if (self.cfg.session_control) {
                log.warn("session control cannot be configured on real VT, disabling session control", .{});
                self.cfg.session_control = false;
            }
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
            const sel = try self.selectFbMode();
            try self.backend.setMode(sel.ci, sel.mi);
            self.mode = sel.mode;
            self.rotation = sel.rotation;
            return;
        }
        // --hwaccel selects Drm3d per card in openCard; cards where
        // GBM/EGL/GLES2 cannot come up fall back to Drm2d with a warning.
        try self.setupDrm();
    }

    /// Open one DRM backend per GPU selected by `--gpus` (DRM master is per
    /// device, recipes §10.3), modesetting every enabled connected connector
    /// on each card (M5.4). Falls back to card0 when enumeration/selection
    /// yields nothing.
    fn setupDrm(self: *Console) !void {
        const candidates = drm2d.enumerateGpus(self.alloc, self.io) catch |err| blk: {
            log.warn("gpu enumerate: {t}", .{err});
            break :blk null;
        };
        if (candidates) |cands| {
            defer drm2d.freeGpuCandidates(self.alloc, cands);
            var buf: [8]drm2d.GpuCandidate = undefined;
            const sel = drm2d.selectGpus(cands, gpuPolicy(self.cfg.gpus), &buf);
            for (sel) |g| {
                self.openCard(g.path) catch |err| log.warn("open {s}: {t}", .{ g.path, err });
            }
        }
        if (self.outputs.items.len == 0) {
            try self.openCard(null);
        }
        if (self.outputs.items.len == 0) return error.NoConnectedDisplay;
        self.mode = self.outputs.items[0].mode;
        self.rotation = self.outputs.items[0].rotation;
        self.backend = self.outputs.items[0].drm.backend();
    }

    /// Open a card with the configured backend, enable the udev hotplug
    /// monitor, take master and register the event + hotplug fds once per
    /// card (tokens on the first Output). Modeset every enabled connected
    /// connector and append one Output per connector, all sharing the
    /// card's backend (M5.4). All callbacks use the Console as userdata
    /// (never an Output pointer), so the outputs list may grow freely.
    /// error.NoConnectedDisplay when no connector can be driven.
    fn openCard(self: *Console, path: ?[]const u8) !void {
        const drm = try self.openDrmBackend(path);
        errdefer drm.deinit();
        drm.enableHotplug(drm2d.libudev.hotplugOps()) catch |err|
            log.warn("hotplug enable: {t}", .{err});
        try drm.takeMaster();
        const event_token = try self.lp.addSource(drm.eventFd(), loop.ev.in_, onDrmEvent, @intFromPtr(self));
        errdefer self.lp.removeSource(event_token);
        var hotplug_token: ?loop.Token = null;
        if (drm.hotplugFd()) |hfd| {
            hotplug_token = try self.lp.addSource(hfd, loop.ev.in_, onHotplugEvent, @intFromPtr(self));
        }
        errdefer {
            if (hotplug_token) |t| self.lp.removeSource(t);
        }
        const conns = try drm.connectors();
        var sel_buf: [max_outputs]ModeSelection = undefined;
        const room = max_outputs -| self.outputs.items.len;
        const sels = try self.selectForCard(drm, conns, sel_buf[0..room]);
        // Modeset first: a failed modeset only skips its own connector,
        // the others keep scanning out.
        var active: [max_outputs]ModeSelection = undefined;
        var n_active: usize = 0;
        for (sels) |s| {
            drm.setMode(s.ci, s.mi) catch |err| {
                log.warn("modeset {s}/{s}: {t}", .{ drm.cardName(), s.name, err });
                continue;
            };
            active[n_active] = s;
            n_active += 1;
        }
        if (n_active == 0) return error.NoConnectedDisplay;
        try self.outputs.ensureTotalCapacity(self.alloc, self.outputs.items.len + n_active);
        // Own the connector names: a later connectors() re-probe frees the
        // borrowed slices, and reprobe diffs outputs by name.
        var n_named: usize = 0;
        errdefer {
            for (active[0..n_named]) |s| self.alloc.free(s.name);
        }
        for (active[0..n_active]) |*s| {
            s.name = try self.alloc.dupe(u8, s.name);
            n_named += 1;
        }
        // No fallible step past this point: capacity is reserved and the
        // names are owned, so the appends cannot fail halfway.
        for (active[0..n_active], 0..) |s, i| {
            self.outputs.appendAssumeCapacity(.{
                .drm = drm,
                .event_token = if (i == 0) event_token else null,
                .hotplug_token = if (i == 0) hotplug_token else null,
                .ci = s.ci,
                .name = s.name,
                .mode = s.mode,
                .rotation = s.rotation,
            });
        }
    }

    /// Instantiate the backend for one card. `--hwaccel` tries Drm3d
    /// (GBM/EGL/GLES2); error.Unsupported (the GL stack cannot come up) and
    /// error.NoConnectedDisplay fall back to Drm2d with a warning. Other
    /// errors propagate to the caller's per-card warn-and-skip.
    fn openDrmBackend(self: *Console, path: ?[]const u8) !DrmOutput {
        if (self.cfg.hwaccel) {
            const d3 = drm3d.Drm3d.init(
                self.alloc,
                path,
                drm2d.libdrm.ops(),
                drm3d.libgbm.ops(),
                drm3d.libegl.ops(),
                drm3d.libgl.ops(),
            ) catch |err| switch (err) {
                error.Unsupported, error.NoConnectedDisplay => {
                    log.warn("--hwaccel: drm3d on {s}: {t}; using drm2d", .{ path orelse "/dev/dri/card0", err });
                    return self.openDrm2d(path);
                },
                else => return err,
            };
            log.info("--hwaccel: drm3d on {s}", .{path orelse "/dev/dri/card0"});
            return .{ .drm3d = d3 };
        }
        return self.openDrm2d(path);
    }

    /// Drm2d card open; `--soft-cursor` forces the software cursor (Drm3d
    /// always composites it in GL, so it has no such knob).
    fn openDrm2d(self: *Console, path: ?[]const u8) !DrmOutput {
        const drm = try drm2d.Drm2d.init(self.alloc, path, drm2d.libdrm.ops());
        errdefer drm.deinit();
        drm.setSoftCursorForce(self.cfg.soft_cursor);
        return .{ .drm2d = drm };
    }

    /// Remove one output (connector dropped or deselected). The backend is
    /// shared with the card's other outputs: deinit it only when the last
    /// output of the card goes away, and hand the fd tokens to a surviving
    /// output. `still_connected_ci` is the dropped connector's index in the
    /// last connectors() probe when it is still connected (null otherwise):
    /// such a connector is disabled so it stops scanning out (M5.4).
    fn removeOutput(self: *Console, index: usize, still_connected_ci: ?usize) void {
        var o = self.outputs.items[index];
        _ = self.outputs.swapRemove(index);
        var survivor: ?*Output = null;
        for (self.outputs.items) |*s| {
            if (s.drm.cardPtr() == o.drm.cardPtr()) {
                survivor = s;
                break;
            }
        }
        if (survivor) |s| {
            if (o.event_token) |t| {
                if (s.event_token == null) s.event_token = t else self.lp.removeSource(t);
            }
            if (o.hotplug_token) |t| {
                if (s.hotplug_token == null) s.hotplug_token = t else self.lp.removeSource(t);
            }
            if (still_connected_ci) |ci| {
                switch (o.drm) {
                    .drm2d => |d| d.disableConnector(ci) catch |err|
                        log.warn("disable {s}/{s}: {t}", .{ d.card_name, o.name, err }),
                    .drm3d => {}, // single connector: no sibling output exists
                }
            }
        } else {
            if (o.event_token) |t| self.lp.removeSource(t);
            if (o.hotplug_token) |t| self.lp.removeSource(t);
            o.drm.deinit();
        }
        self.alloc.free(o.name);
        o.prev_damage.deinit(self.alloc);
    }

    /// Every connected, enabled connector on a card + its mode via
    /// selectModeIndex (`mode=` / `use-original-mode` / preferred, M5.3), in
    /// probe order, written into `buf` (M5.4: one output per connector).
    /// Drm3d drives a single connector per card, so only its first selection
    /// is returned. `conns` is the caller's connectors() probe: reprobe also
    /// needs the full list to diff dropped outputs. Names borrow it.
    fn selectForCard(self: *Console, drm: DrmOutput, conns: []const video.ConnectorInfo, buf: []ModeSelection) ![]ModeSelection {
        const multi = switch (drm) {
            .drm2d => true,
            .drm3d => false,
        };
        var n: usize = 0;
        for (conns, 0..) |conn, ci| {
            if (n == buf.len) break;
            if (!conn.connected or conn.modes.len == 0) continue;
            const screen = self.cfg.getScreen(conn.card_name, conn.name);
            if (!screen.enabled) continue;
            const spec = modeSpecFor(self.cfg, conn.card_name, conn.name);
            const mi = (try drm.selectModeIndex(ci, spec, self.cfg.use_original_mode)) orelse continue;
            buf[n] = .{
                .ci = ci,
                .mi = mi,
                .mode = conn.modes[mi],
                .rotation = orientationToRotation(screen.orientation),
                .name = conn.name,
            };
            n += 1;
            if (!multi) break;
        }
        return buf[0..n];
    }

    /// fbdev path: first connected, enabled connector + preferred/mode= match
    /// (fbdev has no selectModeIndex; the manual match is kept).
    fn selectFbMode(self: *Console) !ModeSelection {
        const conns = try self.backend.connectors();
        for (conns, 0..) |conn, ci| {
            if (!conn.connected or conn.modes.len == 0) continue;
            const screen = self.cfg.getScreen(conn.card_name, conn.name);
            if (!screen.enabled) continue;
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
            return .{
                .ci = ci,
                .mi = mi,
                .mode = conn.modes[mi],
                .rotation = orientationToRotation(screen.orientation),
                .name = conn.name,
            };
        }
        return error.NoConnectedDisplay;
    }

    fn setupFont(self: *Console) !void {
        // ghostty interprets font-size in points at 96 DPI (pt*96/72 = pt*4/3);
        // match it so the same user value yields the same pixel size.
        self.size_px = if (self.cfg.font_size != 0)
            @intCast(@min((self.cfg.font_size * 4) / 3, std.math.maxInt(u16)))
        else
            autoFontSize(self.mode);

        self.disc = try discovery.Discovery.init(self.alloc);
        self.face = try self.disc.?.primaryFace(self.cfg.font_name, self.size_px);
        if (self.cfg.font_size != 0) try self.face.setCharSize(self.cfg.font_size, 96);
        // ghostty's px_per_em is the INTEGER y_ppem of the current size
        // (face/freetype.zig:840), not points*dpi/72. On the auto-size path
        // y_ppem == size_px, so one expression covers both.
        const px_f64 = @as(f64, @floatFromInt(self.face.ft_face.*.size.*.metrics.y_ppem));
        self.cell = try discovery.cellMetricsGhostty(self.face, px_f64, self.cfg.adjust_cell_width, self.cfg.adjust_cell_height, self.cfg.adjust_font_baseline);
        if (self.cell.cell_w == 0 or self.cell.cell_h == 0) return error.InvalidCellMetrics;

        self.renderer = try cpu.CpuRenderer.init(self.alloc, &self.disc.?, &self.face, .{
            .size_px = self.size_px,
            .size_points = self.cfg.font_size, // fractional char-size (ghostty); baseline calibrated +2
        });
        // Use the ghostty-compatible grid: baseline AND the face box the
        // emoji constraint needs (face_width/face_height/face_y).
        self.renderer.?.metrics = self.cell;
        try self.rebuildLayout();
    }


    /// Recompute the shared canvas + per-output viewports from the current
    /// cell size and rotations (computeLayout, M5.4), resize the renderer,
    /// rebuild the shadow framebuffer and re-apply the ghostty decoration
    /// knobs. Does not touch the session manager; callers that have one
    /// resize it separately.
    fn rebuildLayout(self: *Console) !void {
        var conns: [max_outputs]layout.Connector = undefined;
        var plans: [max_outputs]layout.Plan = undefined;
        var n: usize = 0;
        if (self.fb != null) {
            conns[0] = .{
                .width_px = self.mode.width_px,
                .height_px = self.mode.height_px,
                .width_mm = self.mode.width_mm,
                .height_mm = self.mode.height_mm,
                .rotation = self.rotation,
            };
            n = 1;
        } else {
            for (self.outputs.items) |o| {
                conns[n] = .{
                    .gpu = o.drm.cardName(),
                    .connector = o.name,
                    .width_px = o.mode.width_px,
                    .height_px = o.mode.height_px,
                    .width_mm = o.mode.width_mm,
                    .height_mm = o.mode.height_mm,
                    .rotation = o.rotation,
                };
                n += 1;
            }
        }
        const cell = layout.Cell{ .w = self.cell.cell_w, .h = self.cell.cell_h };
        const canvas = layout.computeLayout(conns[0..n], cell, mmMode(self.cfg.multi_monitor), plans[0..n]);
        self.canvas = canvas;
        if (self.input) |*in| in.setScreenSize(canvas.width, canvas.height);
        self.cols = @intCast(@max(1, @min(canvas.cols, std.math.maxInt(u16))));
        self.rows = @intCast(@max(1, @min(canvas.rows, std.math.maxInt(u16))));
        if (self.fb != null) {
            self.fb_plan = plans[0];
        } else {
            for (self.outputs.items, 0..) |*o, idx| o.plan = plans[idx];
        }
        // The shadow holds the complete canvas in logical (content) space.
        if (self.shadow) |*s| {
            if (s.width != canvas.width or s.height != canvas.height) {
                s.destroy(self.alloc);
                self.shadow = null;
                self.shadow = try video.Framebuffer.create(self.alloc, canvas.width, canvas.height, .xrgb8888, null);
            }
        } else {
            self.shadow = try video.Framebuffer.create(self.alloc, canvas.width, canvas.height, .xrgb8888, null);
        }
        // The software pointer is canvas-space: rebuild it when the canvas
        // size changes (zoom/hotplug); pure rotations keep it. The sprite scale
        // tracks the canvas height so the arrow stays usable on HiDPI panels.
        // Init failure is non-fatal — the console works without a pointer. Every
        // caller sets full_redraw, which erases any sprite left in the back
        // buffers.
        const ptr_stale = if (self.pointer) |*p|
            p.canvas_w != canvas.width or p.canvas_h != canvas.height
        else
            true;
        if (ptr_stale) {
            if (self.pointer) |*p| p.deinit();
            self.pointer = pointer.Pointer.init(self.alloc, canvas.width, canvas.height, .{
                .scale = pointer.scaleForCanvasHeight(canvas.height),
            }) catch |err| blk: {
                log.warn("pointer init: {t}", .{err});
                break :blk null;
            };
        }
        try self.renderer.?.resize(self.cols, self.rows, self.cell.cell_w, self.cell.cell_h);
        self.applyDecoConfig();
    }

    /// Push the ghostty cursor/decoration knobs into the decorations module
    /// (its fixed draw* signatures carry no config). Runs after every grid
    /// rebuild because the base values are font/cell metrics. Defaults are
    /// byte-identical to the unconfigured renderer: thickness 1, full-cell
    /// cursor height, no underline-position override.
    fn applyDecoConfig(self: *Console) void {
        // ghostty Metrics.cursor_thickness: modifier on the 1px base,
        // clamped >= 1 (font/Metrics.zig:34, Minimums :65).
        deco.cursor_thickness = @max(1, if (self.cfg.adjust_cursor_thickness) |m| m.apply(@as(u16, 1)) else 1);
        // ghostty Metrics.cursor_height: modifier on the cell height,
        // clamped >= 1 (Metrics.zig:320, Minimums :66); null = full cell.
        deco.cursor_height = if (self.cfg.adjust_cursor_height) |m| @max(1, m.apply(self.cell.cell_h)) else null;
        // ghostty adjust-underline-position: modifier on the u32 underline
        // row (Metrics.apply :408-410, unsigned clamp >= 0). Unset keeps
        // the renderer-computed row and the cursor's bottom-row fallback.
        if (self.cfg.adjust_underline_position) |m| {
            const fm = self.face.metrics();
            const baseline: i16 = @intCast(self.cell.baseline);
            const base = deco.rowFromBaseline(baseline, clampI16(fm.underline_position));
            const pos: u32 = @intCast(@max(0, base));
            const adjusted = m.apply(pos);
            const row: i16 = @intCast(@min(adjusted, std.math.maxInt(i16)));
            deco.adjusted_underline_pos = row;
            deco.cursor_underline_pos = row;
        } else {
            deco.adjusted_underline_pos = null;
            deco.cursor_underline_pos = null;
        }
    }

    fn setupSessions(self: *Console) !void {
        self.mgr = try manager.Manager.init(self.alloc, self.cfg);
        self.mgr.?.createSession = createTerminal;
        try self.mgr.?.resize(self.cols, self.rows);

        try self.mgr.?.openInitial();
    }

    fn setupInput(self: *Console) !void {
        // M6.5 parity: seed the keymap with locale1's CURRENT layout, not
        // just cfg. Explicit cfg fields win over locale1 (overlay).
        var cur_keymap: ?locale1.CurrentKeymap =
            locale1.Locale1.readCurrent(self.alloc, locale1.real) catch |err| blk: {
                log.info("locale1 startup read: {t}", .{err});
                break :blk null;
            };
        defer if (cur_keymap) |*c| c.deinit();
        const loc: locale1.KeymapOptions = if (cur_keymap) |*c| c.options() else .{};
        self.xkb_effective = loc.overlay(xkb.Options, .{
            .model = self.cfg.xkb_model,
            .layout = self.cfg.xkb_layout,
            .variant = self.cfg.xkb_variant,
            .options = self.cfg.xkb_options,
            .keymap_file = self.cfg.xkb_keymap,
        });
        self.keymap = try xkb.Keymap.init(self.io, self.alloc, self.xkb_effective);
        var li_ops = libinput.LibinputOps.real;
        if (self.worker_seat != null) li_ops.udev_assign_seat = workerAssignSeat;
        self.input = try libinput.Input.init(self.alloc, self.io, &self.keymap.?, self.cfg, li_ops);
        self.input.?.setSink(onInput, @intFromPtr(self));
        self.input.?.setScreenSize(self.canvas.width, self.canvas.height);

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
        // Close the race between the startup one-shot read and the
        // subscription: the follower's init snapshot is read after its
        // match is installed, so re-apply it if it differs from startup.
        const eff = l.keymapOptions().overlay(xkb.Options, .{
            .model = self.cfg.xkb_model,
            .layout = self.cfg.xkb_layout,
            .variant = self.cfg.xkb_variant,
            .options = self.cfg.xkb_options,
            .keymap_file = self.cfg.xkb_keymap,
        });
        if (!std.meta.eql(eff, self.xkb_effective)) {
            if (self.input) |*in| {
                if (in.state.reload(eff)) |_| {
                    self.xkb_effective = eff;
                } else |err| {
                    log.warn("keymap reload: {t}", .{err});
                }
            }
        }
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

    /// Start asciicast playback into the active terminal (M2.4). The
    /// player writes through playbackWrite; the timer drives the delays.
    fn startPlayback(self: *Console, path: []const u8) !void {
        const ts = self.activeTerminal() orelse return;
        const pb = try self.alloc.create(asciicast.Playback);
        errdefer self.alloc.destroy(pb);
        pb.* = try asciicast.Playback.init(self.alloc, path, self.cfg.asciicast_loop, playbackWrite, ts);
        errdefer pb.deinit();
        const delay = pb.start();
        try self.asciicast_timer.armOneShot(delay);
        self.playback = pb;
        self.playback_ts = ts;
    }

    /// Stop and free the playback: first key input, the bound session
    /// closed, the stream exhausted, or shutdown. Idempotent.
    fn stopPlayback(self: *Console) void {
        const pb = self.playback orelse return;
        pb.stop();
        pb.deinit();
        self.alloc.destroy(pb);
        self.playback = null;
        self.playback_ts = null;
        self.asciicast_timer.disarm() catch |err| log.warn("asciicast timer: {t}", .{err});
    }

    /// Whether the manager still owns this session (playback is bound to
    /// its terminal; closing that session ends the playback, like kmscon
    /// freeing the player in terminal_destroy).
    fn sessionAlive(self: *Console, ts: *terminal.TerminalSession) bool {
        const m = &self.mgr.?;
        for (m.sessions.items) |s| {
            if (s.ptr == @as(*anyopaque, ts)) return true;
        }
        return false;
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
        return self.worker_seat orelse "seat0";
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

    /// Each open card exactly once, in first-output order: outputs share
    /// one backend per card (M5.4). Writes into buf, returns the count.
    fn uniqueCards(self: *const Console, buf: []DrmOutput) usize {
        var n: usize = 0;
        for (self.outputs.items) |o| {
            var dup = false;
            for (buf[0..n]) |s| {
                if (s.cardPtr() == o.drm.cardPtr()) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            buf[n] = o.drm;
            n += 1;
        }
        return n;
    }

    /// This card's output driving the named connector, or null (the
    /// reprobe diff matches by owned name, M5.4).
    fn outputForName(self: *Console, drm: DrmOutput, name: []const u8) ?*Output {
        for (self.outputs.items) |*o| {
            if (o.drm.cardPtr() == drm.cardPtr() and std.mem.eql(u8, o.name, name)) return o;
        }
        return null;
    }

    /// Whether any output still references this card's backend.
    fn hasCardDrm(self: *const Console, drm: DrmOutput) bool {
        for (self.outputs.items) |o| {
            if (o.drm.cardPtr() == drm.cardPtr()) return true;
        }
        return false;
    }

    /// Set DPMS on every card once (M5.6): setDpms reaches all modeset
    /// connectors of a card, so shared backends must not be called per
    /// output. Returns true when at least one card accepted the state.
    fn setDpmsAll(self: *Console, state: video.DpmsState) bool {
        if (self.fb != null) {
            self.backend.setDpms(state) catch |err| {
                log.warn("dpms: {t}", .{err});
                return false;
            };
            return true;
        }
        var cards: [max_outputs]DrmOutput = undefined;
        var any = false;
        for (cards[0..self.uniqueCards(&cards)]) |drm| {
            drm.setDpms(state) catch |err| {
                log.warn("dpms {s}: {t}", .{ drm.cardName(), err });
                continue;
            };
            any = true;
        }
        return any;
    }

    /// Record damage and schedule a frame. Rendering never runs in the
    /// pty-drain or input hot path: the frame timer coalesces all damage
    /// since the last frame into one render, so a burst of pty reads costs
    /// one presentation and input is never blocked on drawing (kmscon's
    /// damage-driven model, M8.1).
    fn markDirty(self: *Console) void {
        self.dirty = true;
        self.scheduleFrame();
    }

    /// Arm the one-shot frame timer unless a frame is already scheduled.
    /// Re-arming on every markDirty would push the deadline back forever
    /// under continuous output (starvation), so the armed flag pins it.
    fn scheduleFrame(self: *Console) void {
        const interval = self.frameIntervalNs();
        const now = monotonicNs();
        if (self.frame_armed) {
            // A pending full redraw must not wait out a burst deferral: if
            // the current arm fires later than one refresh from now, re-arm
            // promptly. Once re-armed at `interval` the deadline is pinned
            // again, so repeated markDirty cannot starve it.
            const prompt = now + @as(i64, @intCast(interval));
            if (!(self.full_redraw and self.frame_arm_deadline_ns > prompt)) return;
        }
        self.frame_timer.armOneShot(interval) catch |err| {
            log.warn("frame timer: {t}", .{err});
            return;
        };
        self.frame_armed = true;
        self.frame_arm_deadline_ns = now + @as(i64, @intCast(interval));
    }

    /// One display refresh, clamped to 4..50 ms so a bogus mode can neither
    /// stall nor spin the frame clock. 60 Hz when the mode reports none.
    fn frameIntervalNs(self: *const Console) u64 {
        const mhz = self.mode.refresh_mhz;
        if (mhz == 0) return 16_666_667;
        const ns = @as(u64, 1_000_000_000_000) / @as(u64, mhz);
        return std.math.clamp(ns, 4 * std.time.ns_per_ms, 50 * std.time.ns_per_ms);
    }

    /// Burst frame deferral (M8.1). While pty output is flooding in, hold
    /// the frame until `frame_due_ns` so render+present occupies a bounded
    /// fraction of the loop; the pty drains during the deferral, which is
    /// what output-throughput benchmarks measure. Returns true when the
    /// frame was deferred (the frame timer is armed for the deadline).
    /// Full redraws and interactive damage (no pump within the last
    /// refresh) render immediately, and a due deadline always renders, so
    /// the last frame of a burst is at most one stretch late.
    fn deferBurstFrame(self: *Console) bool {
        if (self.full_redraw) return false;
        const now = monotonicNs();
        if (now >= self.frame_due_ns) return false;
        const interval: i64 = @intCast(self.frameIntervalNs());
        if (!burstPumpActive(now, self.last_pump_ns, interval, self.last_pump_more, self.frame_cost_ns)) return false;
        self.frame_timer.armOneShot(@intCast(self.frame_due_ns - now)) catch |err| {
            log.warn("frame timer: {t}", .{err});
            return false;
        };
        self.frame_armed = true;
        self.frame_arm_deadline_ns = self.frame_due_ns;
        return true;
    }

    fn onFrameTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        self.frame_armed = false;
        self.renderIfDirty();
    }

    fn videoTakeMaster(self: *Console) void {
        var cards: [max_outputs]DrmOutput = undefined;
        for (cards[0..self.uniqueCards(&cards)]) |drm|
            drm.takeMaster() catch |err| log.err("takeMaster: {t}", .{err});
    }

    fn videoDropMaster(self: *Console) void {
        var cards: [max_outputs]DrmOutput = undefined;
        for (cards[0..self.uniqueCards(&cards)]) |drm|
            drm.dropMaster() catch |err| log.err("dropMaster: {t}", .{err});
    }

    /// True while any output has a submitted flip in flight. The slowest
    /// output paces the frame loop; fbdev is synchronous (always false).
    fn anyFlipPending(self: *Console) bool {
        if (self.fb != null) return self.backend.flipPending();
        for (self.outputs.items) |o| {
            if (o.drm.flipPending()) return true;
        }
        return false;
    }

    /// Present the active session if there is damage and no flip is in
    /// flight. Called from the frame timer (damage coalescing) and from
    /// onDrmEvent (flip completion presents damage accumulated while the
    /// flip was in flight); fbdev is synchronous (flipPending always false).
    /// The session renders once into the shared shadow canvas, which is then
    /// presented into every output's back buffer through its viewport plan
    /// (M5.4). While a burst is active the frame may be deferred to its
    /// stretch deadline (deferBurstFrame) so the pty drains between frames.
    fn renderIfDirty(self: *Console) void {
        if (!self.dirty or self.dpms_off or !self.seat_active) return;
        if (self.anyFlipPending()) return;
        if (self.mgr == null or self.shadow == null) return;
        if (self.deferBurstFrame()) return;
        const m = &self.mgr.?;
        const shadow = &self.shadow.?;

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
        const t0 = monotonicNs();
        m.render(&ctx) catch |err| {
            log.warn("render: {t}", .{err});
            return;
        };
        // Advance kitty animations once per rendered frame and schedule
        // the next one (M4.4); the tick's new pixel generations reach the
        // renderer through the next frame's placement list.
        self.tickKittyAnimations();
        // Software pointer: inject the erase+draw rects as full-width row
        // bands (the renderer's damage vocabulary, so blitShadowBands stays
        // band-limited). Every output's shadow blit then restores the old
        // sprite position and endFrame's damage covers both rects; the
        // sprite itself is composited into the back buffers in present().
        if (self.pointer) |*p| {
            const pd = p.takeDamage();
            self.appendPointerBand(pd.old);
            self.appendPointerBand(pd.new);
        }
        if (self.fb != null) {
            self.present(self.backend, self.fb_plan, &self.fb_prev_damage);
        } else {
            for (self.outputs.items) |*o| {
                self.present(DrmFrame{ .drm = o.drm, .ci = o.ci }, o.plan, &o.prev_damage);
            }
        }
        // Commit the pointer rect only after every output composited it.
        if (self.pointer) |*p| p.markDrawn();
        const t2 = monotonicNs();
        // Burst pacing: remember the frame cost and set the next frame's
        // earliest due time. The EWMA rises slowly and falls fast (capped
        // at 2x the last frame), so a burst that turns into a trickle
        // re-paces to per-refresh rendering within a frame or two.
        const cost: u64 = @intCast(t2 - t0);
        self.frame_cost_ns = burstCostEwma(self.frame_cost_ns, cost);
        const stretch = burstStretchNs(self.frame_cost_ns, self.frameIntervalNs());
        self.frame_due_ns = t2 + @as(i64, @intCast(stretch));
        self.dirty = false;
        self.full_redraw = false;
    }

    /// Present the shadow canvas into one output's back buffer through its
    /// viewport plan, then flip. `backend` is the fbdev video.Backend or a
    /// DrmFrame selecting the connector (M5.4). The 1:1 unrotated full-canvas
    /// case -- including an integer letterbox offset -- uses the band-limited
    /// NT blit shifted by the offset and repaints only the static letterbox
    /// bands; scaled/rotated/fractional viewports blit only the damaged row
    /// bands through the plan (blitViewportBands) with row-band physical damage
    /// (Plan.damage), or a full frame on full_redraw / unmergeable damage.
    fn present(self: *Console, backend: anytype, plan: layout.Plan, prev_damage: *sess.DamageList) void {
        const shadow = &self.shadow.?;
        const fb = backend.beginFrame() catch |err| {
            log.warn("beginFrame: {t}", .{err});
            return;
        };
        const aligned = plan.scale == 1 and plan.conn.rotation == .normal and
            plan.src.x == 0 and plan.src.y == 0 and
            plan.src.w == self.canvas.width and plan.src.h == self.canvas.height and
            plan.dst.x >= 0 and plan.dst.y >= 0 and
            @floor(plan.dst.x) == plan.dst.x and @floor(plan.dst.y) == plan.dst.y;
        if (aligned) {
            const dx: u32 = @intFromFloat(plan.dst.x);
            const dy: u32 = @intFromFloat(plan.dst.y);
            if (dx + shadow.width <= fb.width and dy + shadow.height <= fb.height) {
                // The letterbox is static black: repaint just its bands
                // instead of a full-canvas fill every frame.
                if (dy > 0) fillBand(fb, 0, 0, fb.width, dy);
                const by = dy + shadow.height;
                if (by < fb.height) fillBand(fb, 0, by, fb.width, fb.height - by);
                if (dx > 0) fillBand(fb, 0, dy, dx, shadow.height);
                const bx = dx + shadow.width;
                if (bx < fb.width) fillBand(fb, bx, dy, fb.width - bx, shadow.height);
                self.blitShadowBands(fb, shadow, prev_damage, dx, dy);
                self.compositePointer(fb, plan, @intCast(dx), @intCast(dy), true);
                if (self.full_redraw) {
                    backend.endFrame(&.{}) catch |err| log.warn("endFrame: {t}", .{err});
                } else if (dx == 0 and dy == 0) {
                    backend.endFrame(self.damage.items) catch |err| log.warn("endFrame: {t}", .{err});
                } else {
                    self.phys_damage.clearRetainingCapacity();
                    for (self.damage.items) |r| {
                        self.phys_damage.append(self.alloc, .{
                            .x = r.x + dx,
                            .y = r.y + dy,
                            .w = r.w,
                            .h = r.h,
                        }) catch |err| {
                            log.warn("damage: {t}", .{err});
                            break;
                        };
                    }
                    backend.endFrame(self.phys_damage.items) catch |err| log.warn("endFrame: {t}", .{err});
                }
                return;
            }
        }
        // Viewport path (fractional letterbox, scaled or rotated): paint the
        // window through the plan. A full redraw clears the letterbox and blits
        // everything; incremental frames blit only the damaged row bands
        // (current + previous, for double-buffer staleness) so a pointer move
        // does not fill + repaint the whole canvas. The letterbox is static
        // black once a buffer is fully painted and is never written by the band
        // blit or the pointer, so it needs no per-frame clear.
        if (self.full_redraw) {
            fb.fill(0);
            render.blitViewport(fb.*, shadow.*, plan);
            self.compositePointer(fb, plan, 0, 0, false);
            self.setPrevDamage(prev_damage, &.{.{ .x = 0, .y = 0, .w = shadow.width, .h = shadow.height }});
            backend.endFrame(&.{}) catch |err| log.warn("endFrame: {t}", .{err});
            return;
        }
        if (!self.blitViewportBands(fb, shadow, plan, prev_damage)) {
            // Unmergeable damage: repaint the whole viewport and mark the next
            // frame full so the other back buffer is repainted too.
            fb.fill(0);
            render.blitViewport(fb.*, shadow.*, plan);
            self.compositePointer(fb, plan, 0, 0, false);
            self.setPrevDamage(prev_damage, &.{.{ .x = 0, .y = 0, .w = shadow.width, .h = shadow.height }});
            backend.endFrame(&.{}) catch |err| log.warn("endFrame: {t}", .{err});
            return;
        }
        self.compositePointer(fb, plan, 0, 0, false);
        self.phys_damage.clearRetainingCapacity();
        const cell = layout.Cell{ .w = self.cell.cell_w, .h = self.cell.cell_h };
        for (self.damage.items) |r| {
            const row0 = r.y / self.cell.cell_h;
            const row1 = (r.y + r.h + self.cell.cell_h - 1) / self.cell.cell_h;
            if (plan.damage(self.canvas, row0, row1, cell)) |pr| {
                self.phys_damage.append(self.alloc, .{
                    .x = @intCast(pr.x),
                    .y = @intCast(pr.y),
                    .w = pr.w,
                    .h = pr.h,
                }) catch |err| {
                    log.warn("damage: {t}", .{err});
                    break;
                };
            }
        }
        backend.endFrame(self.phys_damage.items) catch |err| log.warn("endFrame: {t}", .{err});
        self.setPrevDamage(prev_damage, self.damage.items);
    }

    /// Composite the software pointer into one output's BACK buffer after
    /// the shadow blit — never into the shadow canvas (draw invariant,
    /// render/pointer.zig). The aligned 1:1 case is an integer letterbox
    /// offset; scaled/rotated viewports inverse-map through the plan like
    /// render.blitViewport. renderIfDirty already gates seat_active and
    /// dpms_off; re-checked here so the draw gate lives at the draw.
    fn compositePointer(self: *Console, fb: *video.Framebuffer, plan: layout.Plan, dx: i32, dy: i32, aligned: bool) void {
        const p = &(self.pointer orelse return);
        if (!p.isVisible() or !self.seat_active or self.dpms_off) return;
        const pos = p.position();
        if (aligned) {
            blitPointer(fb, p.sprite(), pos.x + dx, pos.y + dy);
        } else {
            blitPointerViewport(fb, p.sprite(), pos, plan);
        }
    }

    /// Add one pointer erase/draw rect to the canvas damage as a full-width
    /// row band (Damage.fromRows): a small non-full-width rect would force
    /// blitShadowBands into a full-canvas copy on every pointer frame.
    /// Empty rects are skipped; on allocation failure force a full redraw
    /// rather than risk a ghost.
    fn appendPointerBand(self: *Console, r: video.Damage) void {
        if (r.isEmpty()) return;
        self.damage.append(self.alloc, video.Damage.fromRows(r.y, r.y + r.h, self.canvas.width)) catch |err| {
            log.warn("pointer damage: {t}", .{err});
            self.full_redraw = true;
        };
    }

    /// Arm the one-shot autohide poll. Re-armed on every motion/button
    /// (like armDpms); tick() owns the exact idle deadline.
    fn armPointerTimer(self: *Console) void {
        self.pointer_timer.armOneShot(pointer_poll_ns) catch |err|
            log.warn("pointer timer: {t}", .{err});
    }

    /// Copy only the shadow rows that changed since this back buffer was
    /// last front. Double buffering makes the back buffer two frames
    /// stale, so the blit covers this frame's damage plus the previous
    /// frame's. The dumb-buffer mapping is write-combining: a full-canvas
    /// memcpy costs milliseconds, so band-limited copies keep small-damage
    /// frames cheap (M8.1). Full-width row bands merge on the stack;
    /// full_redraw or unmergeable damage copies the whole canvas.
    fn blitShadowBands(
        self: *Console,
        fb: *video.Framebuffer,
        shadow: *const video.Framebuffer,
        prev_damage: *sess.DamageList,
        dx: u32,
        dy: u32,
    ) void {
        const full = video.Damage{ .x = 0, .y = 0, .w = shadow.width, .h = shadow.height };
        if (self.full_redraw) {
            self.blitBand(fb, shadow, 0, shadow.height, dx, dy);
            self.setPrevDamage(prev_damage, &.{full});
            return;
        }
        var iv: [256][2]u32 = undefined;
        var n: usize = 0;
        var overflow = false;
        for (self.damage.items) |d| {
            if (!bandInsert(&iv, &n, d, shadow.width)) {
                overflow = true;
                break;
            }
        }
        if (!overflow) {
            for (prev_damage.items) |d| {
                if (!bandInsert(&iv, &n, d, shadow.width)) {
                    overflow = true;
                    break;
                }
            }
        }
        if (overflow) {
            self.blitBand(fb, shadow, 0, shadow.height, dx, dy);
            self.setPrevDamage(prev_damage, &.{full});
            return;
        }
        if (n == 0) {
            prev_damage.clearRetainingCapacity();
            return;
        }
        // Insertion sort by y0 (n is small), then merge in place.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const band = iv[i];
            var j: usize = i;
            while (j > 0 and iv[j - 1][0] > band[0]) : (j -= 1) {
                iv[j] = iv[j - 1];
            }
            iv[j] = band;
        }
        var m: usize = 0;
        for (iv[0..n]) |band| {
            if (m > 0 and band[0] <= iv[m - 1][1]) {
                iv[m - 1][1] = @max(iv[m - 1][1], band[1]);
            } else {
                iv[m] = band;
                m += 1;
            }
        }
        for (iv[0..m]) |band| {
            self.blitBand(fb, shadow, band[0], band[1] - band[0], dx, dy);
        }
        self.setPrevDamage(prev_damage, self.damage.items);
    }

    /// Band-limited viewport blit: merge this frame's damage with the previous
    /// frame's (the back buffer is two frames stale) into full-width row bands
    /// and repaint only those through the plan. When the merged bands span the
    /// whole canvas the buffer is (re)initialized -- clear the letterbox and
    /// blit the full viewport -- which also covers the frame after a full_redraw
    /// (its prev_damage is the full canvas), so both back buffers get a full
    /// paint. Returns false when the damage is not mergeable into bands, so the
    /// caller falls back to a full repaint. Mirrors blitShadowBands' merging.
    fn blitViewportBands(
        self: *Console,
        fb: *video.Framebuffer,
        shadow: *const video.Framebuffer,
        plan: layout.Plan,
        prev_damage: *sess.DamageList,
    ) bool {
        var iv: [256][2]u32 = undefined;
        var n: usize = 0;
        for (self.damage.items) |d| {
            if (!bandInsert(&iv, &n, d, shadow.width)) return false;
        }
        for (prev_damage.items) |d| {
            if (!bandInsert(&iv, &n, d, shadow.width)) return false;
        }
        if (n == 0) return true;
        // Insertion sort by y0 (n is small), then merge in place.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const band = iv[i];
            var j: usize = i;
            while (j > 0 and iv[j - 1][0] > band[0]) : (j -= 1) {
                iv[j] = iv[j - 1];
            }
            iv[j] = band;
        }
        var m: usize = 0;
        for (iv[0..n]) |band| {
            if (m > 0 and band[0] <= iv[m - 1][1]) {
                iv[m - 1][1] = @max(iv[m - 1][1], band[1]);
            } else {
                iv[m] = band;
                m += 1;
            }
        }
        if (m == 1 and iv[0][0] == 0 and iv[0][1] == shadow.height) {
            fb.fill(0);
            render.blitViewport(fb.*, shadow.*, plan);
            return true;
        }
        for (iv[0..m]) |band| {
            render.blitViewportBand(fb.*, shadow.*, plan, band[0], band[1]);
        }
        return true;
    }

    /// Copy full-width shadow rows [y, y+h) into the back buffer at the
    /// (dx, dy) letterbox offset. The dumb-buffer mapping is write-combining:
    /// regular stores flush partial WC buffers through the cache hierarchy
    /// (~0.5 GB/s), while non-temporal stores combine full lines in the WC
    /// buffers themselves (several GB/s). x86-64 has SSE2 at baseline; other
    /// targets and unaligned pitches keep the plain memcpy (M8.1).
    fn blitBand(_: *Console, fb: *video.Framebuffer, shadow: *const video.Framebuffer, y: u32, h: u32, dx: u32, dy: u32) void {
        if (comptime builtin.cpu.arch == .x86_64) {
            const row_bytes: usize = @as(usize, shadow.width) * 4;
            // movntdq needs 16-byte-aligned destinations: the mmap base
            // is page-aligned, so a 16-aligned pitch keeps every row
            // start aligned; a whole-pixel x offset must be a multiple
            // of 4 pixels (16 bytes) as well.
            if (shadow.pitch % 16 == 0 and fb.pitch % 16 == 0 and
                @intFromPtr(fb.mem.ptr) % 16 == 0 and dx % 4 == 0)
            {
                var r: u32 = 0;
                while (r < h) : (r += 1) {
                    const row = y + r;
                    const src = shadow.mem[@as(usize, row) * shadow.pitch ..][0..row_bytes];
                    const dst = fb.mem[(@as(usize, row + dy) * fb.pitch) + @as(usize, dx) * 4 ..][0..row_bytes];
                    copyRowNT(dst, src);
                }
                asm volatile ("sfence" ::: .{ .memory = true });
                return;
            }
        }
        fb.blitFrom(shadow.*, @intCast(dx), @intCast(dy), .{ .x = 0, .y = y, .w = shadow.width, .h = h });
    }

    /// Paint one letterbox band black, honoring the pitch padding. Only the
    /// bands outside the canvas are repainted; the content area is covered by
    /// the blit (a full fb.fill would cost a full-canvas WC write per frame).
    fn fillBand(fb: *video.Framebuffer, x: u32, y: u32, w: u32, h: u32) void {
        var r: u32 = 0;
        while (r < h) : (r += 1) {
            const off = @as(usize, y + r) * fb.pitch + @as(usize, x) * 4;
            @memset(fb.mem[off..][0 .. @as(usize, w) * 4], 0);
        }
    }

    /// Append one full-width row band to the merge buffer; false when the
    /// damage is not a full-width band or the buffer is full (the caller
    /// falls back to a full-canvas blit).
    fn bandInsert(iv: *[256][2]u32, n: *usize, d: video.Damage, width: u32) bool {
        if (d.isEmpty()) return true;
        if (d.x != 0 or d.w != width) return false;
        if (n.* == iv.len) return false;
        iv[n.*] = .{ d.y, d.y + d.h };
        n.* += 1;
        return true;
    }

    /// Record this frame's damage as the next frame's staleness history.
    /// On allocation failure force a full blit next frame (conservative).
    fn setPrevDamage(self: *Console, prev: *sess.DamageList, items: []const video.Damage) void {
        prev.clearRetainingCapacity();
        prev.appendSlice(self.alloc, items) catch |err| {
            log.warn("prev damage: {t}", .{err});
            self.full_redraw = true;
        };
    }

    fn wakeDpms(self: *Console) void {
        if (self.dpms_off) {
            _ = self.setDpmsAll(.on);
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
            7, 8, 9, 10 => { // session next/prev/close/new
                m.handleGrab(id);
                if (self.playback_ts) |ts| {
                    if (!self.sessionAlive(ts)) self.stopPlayback();
                }
            },
            13 => self.handleReboot(), // reboot (disabled by default)
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

    /// grab-reboot (M6.4): follow /proc/sys/kernel/ctrl-alt-del exactly
    /// like kmscon seat_trigger_reboot (seat.c:421-455). 0 -> soft reboot
    /// (SIGINT to init); any other value -> sync() + hard reboot. An
    /// unreadable value defaults to the soft path, like kmscon.
    fn handleReboot(self: *Console) void {
        switch (rebootAction(readCtrlAltDel())) {
            .soft => {
                log.warn("soft reboot triggered by keyboard shortcut on seat {s}", .{self.seatName()});
                posix.kill(1, .INT) catch |err|
                    log.err("failed to signal PID 1 for reboot: {t}", .{err});
            },
            .hard => {
                log.warn("hard reboot triggered by keyboard shortcut on seat {s}", .{self.seatName()});
                linux.sync();
                // reboot(2): LINUX_REBOOT_MAGIC1/2 + RB_AUTOBOOT.
                const rc = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
                if (linux.errno(rc) != .SUCCESS)
                    log.err("failed to reboot system: {s}", .{@tagName(linux.errno(rc))});
            },
        }
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

    /// grab-rotate-cw/ccw: cycle the active (primary) output's rotation and
    /// reconfigure the shared grid (M5.4).
    fn handleRotate(self: *Console, id: u16) void {
        self.rotation = rotateStep(self.rotation, id);
        if (self.outputs.items.len > 0) self.outputs.items[0].rotation = self.rotation;
        self.reconfigureGrid() catch |err| {
            log.warn("rotate regrid: {t}", .{err});
            return;
        };
        self.full_redraw = true;
    }

    /// Recompute the shared canvas + viewports from the current cell size and
    /// rotations, resize the renderer and every session, and rebuild the
    /// shadow when the canvas size changed. The single mode-change ->
    /// session-resize path: zoom/rotate and the hotplug reprobe (M2.5).
    fn reconfigureGrid(self: *Console) !void {
        try self.rebuildLayout();
        if (self.mgr) |*m| try m.resize(self.cols, self.rows);
    }

    /// Re-probe connectors on every open card after a hotplug event,
    /// re-select modes, drop outputs that lost their connector, pick up
    /// newly added connectors and cards, then rebuild the layout and
    /// redraw (M5.4/M5.5). Runs with master held.
    fn reprobe(self: *Console) void {
        var cards: [max_outputs]DrmOutput = undefined;
        const n = self.uniqueCards(&cards);
        for (cards[0..n]) |drm| self.reprobeCard(drm);
        self.addNewCards();
        if (self.outputs.items.len == 0) {
            log.warn("hotplug: no connected displays remain", .{});
            return;
        }
        self.mode = self.outputs.items[0].mode;
        self.rotation = self.outputs.items[0].rotation;
        self.backend = self.outputs.items[0].drm.backend();
        self.reconfigureGrid() catch |err| {
            log.warn("hotplug regrid: {t}", .{err});
            return;
        };
        self.full_redraw = true;
        self.markDirty();
    }

    /// Re-probe one card: select every enabled connected connector, drop
    /// outputs whose connector went away or was deselected, re-modeset
    /// changed ones and pick up newly appeared connectors (M5.4/M5.5).
    /// One connectors() call serves both the selection and the removal
    /// diff: it invalidates previously borrowed names, so outputs are
    /// matched by their owned connector name.
    fn reprobeCard(self: *Console, drm: DrmOutput) void {
        const conns = drm.connectors() catch |err| {
            log.warn("reprobe {s}: {t}", .{ drm.cardName(), err });
            return;
        };
        var sel_buf: [max_outputs]ModeSelection = undefined;
        const sels = self.selectForCard(drm, conns, &sel_buf) catch |err| {
            log.warn("reprobe {s}: {t}", .{ drm.cardName(), err });
            return;
        };
        var i = self.outputs.items.len;
        while (i > 0) {
            i -= 1;
            const o = &self.outputs.items[i];
            if (o.drm.cardPtr() != drm.cardPtr()) continue;
            if (selectionFor(sels, o.name) != null) continue;
            // Still-connected dropped connectors are disabled by their
            // current index (probe indices shift when connectors vanish).
            const drop_ci: ?usize = for (conns, 0..) |c, ci| {
                if (c.connected and std.mem.eql(u8, c.name, o.name)) break ci;
            } else null;
            self.removeOutput(i, drop_ci);
        }
        // The last output of the card may have been dropped above, which
        // deinits the backend (conns/sels borrow it). addNewCards reopens
        // the card when new connectors are present.
        if (!self.hasCardDrm(drm)) return;
        for (sels) |s| {
            if (self.outputForName(drm, s.name)) |o| {
                const changed = o.mode.width_px != s.mode.width_px or
                    o.mode.height_px != s.mode.height_px or
                    o.mode.refresh_mhz != s.mode.refresh_mhz;
                if (changed) {
                    drm.setMode(s.ci, s.mi) catch |err|
                        log.warn("re-modeset {s}/{s}: {t}", .{ drm.cardName(), s.name, err });
                }
                o.ci = s.ci;
                o.mode = s.mode;
                o.rotation = s.rotation;
            } else {
                if (self.outputs.items.len >= max_outputs) {
                    log.warn("{s}: output limit ({d}) reached, skipping {s}", .{ drm.cardName(), max_outputs, s.name });
                    continue;
                }
                drm.setMode(s.ci, s.mi) catch |err| {
                    log.warn("hotplug modeset {s}/{s}: {t}", .{ drm.cardName(), s.name, err });
                    continue;
                };
                const name = self.alloc.dupe(u8, s.name) catch |err| {
                    log.warn("hotplug name {s}/{s}: {t}", .{ drm.cardName(), s.name, err });
                    continue;
                };
                self.outputs.append(self.alloc, .{
                    .drm = drm,
                    .ci = s.ci,
                    .name = name,
                    .mode = s.mode,
                    .rotation = s.rotation,
                }) catch |err| {
                    self.alloc.free(name);
                    log.warn("hotplug output {s}/{s}: {t}", .{ drm.cardName(), s.name, err });
                };
            }
        }
    }

    /// Open any newly appeared GPU that the policy selects and that is not
    /// already driven (GPU hotplug, M5.5). openCard modesets every enabled
    /// connector. Best effort.
    fn addNewCards(self: *Console) void {
        const candidates = drm2d.enumerateGpus(self.alloc, self.io) catch return;
        defer drm2d.freeGpuCandidates(self.alloc, candidates);
        var buf: [8]drm2d.GpuCandidate = undefined;
        const sel = drm2d.selectGpus(candidates, gpuPolicy(self.cfg.gpus), &buf);
        for (sel) |g| {
            if (self.hasCard(g.path)) continue;
            self.openCard(g.path) catch |err| log.warn("hotplug open {s}: {t}", .{ g.path, err });
        }
    }

    fn hasCard(self: *const Console, path: []const u8) bool {
        for (self.outputs.items) |o| {
            if (std.mem.eql(u8, o.drm.cardPath(), path)) return true;
        }
        return false;
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
        // Re-open evdev and re-track devices now that we own the seat.
        if (self.input) |*in| in.resume_() catch |err| log.warn("input resume: {t}", .{err});
        self.videoTakeMaster();
        if (self.reprobe_pending) {
            self.reprobe_pending = false;
            self.reprobe();
        }
        self.full_redraw = true;
        self.markDirty();
    }

    fn onSeatDeactivated(ud: usize) void {
        const self: *Console = @ptrFromInt(ud);
        self.seat_active = false;
        // Stop reading evdev while another session owns the seat (also
        // disarms key repeat); the onInput gate is the backstop.
        if (self.input) |*in| in.suspend_() catch |err| log.warn("input suspend: {t}", .{err});
        // Hide the software pointer; the activation full redraw erases it.
        if (self.pointer) |*p| p.hide();
        self.pointer_timer.disarm() catch |err| log.warn("pointer timer: {t}", .{err});
        self.markDirty();
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
        // Every card's event fd shares this handler (userdata = Console);
        // drain each card once — readEvents is non-blocking and returns
        // when empty.
        var cards: [max_outputs]DrmOutput = undefined;
        for (cards[0..self.uniqueCards(&cards)]) |drm| {
            drm.readEvents() catch |err| {
                log.warn("drm readEvents: {t}", .{err});
                continue;
            };
            if (drm.needsFullRedraw()) self.full_redraw = true;
        }
        self.renderIfDirty();
    }

    fn onHotplugEvent(lp: *loop.Loop, token: loop.Token, ud: usize, events: loop.Events) void {
        _ = lp;
        _ = token;
        _ = events;
        const self: *Console = @ptrFromInt(ud);
        var changed = false;
        var cards: [max_outputs]DrmOutput = undefined;
        for (cards[0..self.uniqueCards(&cards)]) |drm| {
            const hit = drm.pollHotplug() catch |err| blk: {
                log.warn("hotplug poll: {t}", .{err});
                break :blk false;
            };
            if (hit) changed = true;
        }
        if (!changed) return;
        if (!self.seat_active) {
            // No master: defer the re-modeset until the seat activates.
            self.reprobe_pending = true;
            return;
        }
        self.reprobe();
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
        self.pumpTerminal(reg);
    }

    fn pumpTerminal(self: *Console, reg: *PtyReg) void {
        const more = reg.ts.onPtyReadable() catch |err| {
            log.warn("pty pump: {t}", .{err});
            return;
        };
        self.last_pump_ns = monotonicNs();
        self.last_pump_more = more;
        self.markDirty();
        if (more) {
            // Budget exhausted: re-arm the edge-triggered source. MOD
            // re-reports readiness, so data left in the pty wakes the
            // loop again instead of stalling until the next write.
            self.lp.modifySource(reg.token, loop.ev.in_ | loop.ev.edge_triggered) catch |err|
                log.warn("pty rearm: {t}", .{err});
        }
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
        if (!self.setDpmsAll(.off)) return;
        self.dpms_off = true;
        // Hide the software pointer; the wake full redraw erases it.
        if (self.pointer) |*p| p.hide();
        self.pointer_timer.disarm() catch |err| log.warn("pointer timer: {t}", .{err});
        self.markDirty();
    }

    fn onPointerTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        const p = &(self.pointer orelse return);
        // tick() hides exactly once on the idle transition; the erase rect
        // reaches the back buffers through the next frame's damage.
        if (p.tick(monotonicNs())) self.markDirty();
        if (p.isVisible()) self.armPointerTimer();
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

    fn onAsciicastTimer(_: *loop.Timer, expirations: u64, ud: usize) void {
        _ = expirations;
        const self: *Console = @ptrFromInt(ud);
        const pb = self.playback orelse return;
        if (pb.advance()) |delay| {
            self.asciicast_timer.armOneShot(delay) catch |err| {
                log.warn("asciicast timer: {t}", .{err});
                self.stopPlayback();
            };
        } else {
            // Exhausted without loop (or stopped): tear down.
            self.stopPlayback();
        }
    }

    fn onInput(ud: usize, event: sess.InputEvent) void {
        const self: *Console = @ptrFromInt(ud);
        // Seat-ownership gate: while the VT/seat is inactive the kernel
        // owns the keyboard (it handles Ctrl+Alt+Fn to switch back to us),
        // so nothing may reach the sessions, wake DPMS or stop playback.
        // libinput is suspended as well; this holds even if it delivers.
        if (!self.seat_active) return;
        self.wakeDpms();
        // Software pointer tracking (additive: the events still reach the
        // manager below for selection). x/y are canvas pixels from the
        // input layer, absolute or accumulated.
        if (self.pointer) |*p| {
            switch (event) {
                .pointer_motion => |m| {
                    p.motion(m.x, m.y, monotonicNs());
                    self.armPointerTimer();
                    self.markDirty();
                },
                .pointer_button => {
                    p.button(monotonicNs());
                    self.armPointerTimer();
                    self.markDirty();
                },
                else => {},
            }
        }
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
        // The first keyboard input stops asciicast playback (kmscon
        // terminal.c:978); the key itself still reaches the session.
        if (event == .key) self.stopPlayback();
        if (self.mgr) |*m| m.onInput(event) catch |err| log.warn("onInput: {t}", .{err});
        // Interactive input is never held by the burst stretch: clear the
        // deferral deadline and re-arm the frame timer at the normal refresh
        // (a deferred arm would otherwise keep the echo waiting).
        self.frame_due_ns = 0;
        self.frame_armed = false;
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

/// Blend a frame's measured render+present cost into the running estimate.
/// The EWMA rises slowly (1/4 weight on the new sample) but falls fast: it
/// is capped at 2x the latest frame, so a burst that turns into a trickle
/// re-paces to per-refresh rendering within a frame or two. A zero estimate
/// (first frame) adopts the sample outright.
fn burstCostEwma(prev_ns: u64, cost_ns: u64) u64 {
    const avg = if (prev_ns == 0) cost_ns else (3 * prev_ns + cost_ns) / 4;
    return @min(avg, cost_ns * 2);
}

/// Earliest delay before the next burst frame: the measured cost scaled so
/// render+present occupies ~1/(1+factor) of the loop, never shorter than one
/// display refresh and never longer than the display-rate floor
/// (max_burst_frame_period_ns). Cheap frames thus keep the refresh period;
/// expensive frames stretch the frame clock only up to the floor, so
/// animation stays >= ~10 fps instead of collapsing to 1-2 fps.
fn burstStretchNs(cost_ns: u64, interval_ns: u64) u64 {
    const scaled = @min(cost_ns * burst_stretch_factor, max_burst_frame_period_ns);
    return @max(interval_ns, scaled);
}

/// Burst-activity gate: decide whether a frame may be held for the burst
/// stretch. A budget-exhausted pump (`pump_flood` = true) means more output
/// is pending, so the deferral is kept while that pump is within the last
/// display refresh. A pump that drained everything (`pump_flood` = false) is
/// a trickle — a periodic full-screen refresh such as btop at a fixed update
/// rate. A trickle of CHEAP frames renders on time (there is no flood to
/// drain, so the stretch only adds latency); a trickle of EXPENSIVE frames
/// (stretch would hit the display-rate cap) still coalesces to bound render
/// duty, which is what keeps output-throughput benchmarks from regressing.
fn burstPumpActive(now_ns: i64, last_pump_ns: i64, interval_ns: i64, pump_flood: bool, frame_cost_ns: u64) bool {
    if (now_ns - last_pump_ns >= interval_ns) return false;
    if (pump_flood) return true;
    return frame_cost_ns * burst_stretch_factor >= max_burst_frame_period_ns;
}

/// Non-temporal row copy: 64-byte unrolled movntdq stores with a regular
/// memcpy tail. `dst` must be 16-byte aligned (movntdq requirement);
/// `src` may be unaligned. Caller issues one sfence after the last row.
fn copyRowNT(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i + 64 <= dst.len) : (i += 64) {
        ntStore16(dst[i..], load16(src[i..]));
        ntStore16(dst[i + 16 ..], load16(src[i + 16 ..]));
        ntStore16(dst[i + 32 ..], load16(src[i + 32 ..]));
        ntStore16(dst[i + 48 ..], load16(src[i + 48 ..]));
    }
    while (i + 16 <= dst.len) : (i += 16) {
        ntStore16(dst[i..], load16(src[i..]));
    }
    if (i < dst.len) @memcpy(dst[i..], src[i..][0 .. dst.len - i]);
}

fn load16(p: []const u8) @Vector(16, u8) {
    return @as(*align(1) const @Vector(16, u8), @ptrCast(p.ptr)).*;
}

fn ntStore16(p: []u8, v: @Vector(16, u8)) void {
    asm volatile ("movntdq %[v], (%[p])"
        :
        : [p] "r" (p.ptr),
          [v] "x" (v),
        : .{ .memory = true }
    );
}

/// Milliseconds on the monotonic clock: the time base for kitty
/// animationTick, which requires a monotonic clock stable for the
/// terminal's lifetime.
fn monotonicMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Monotonic clock in nanoseconds (same source as monotonicMs).
fn monotonicNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Delay until the next animation frame is due, floored at 1 ms: a due
/// or past deadline must not disarm the timer (a zero delay) or spin the
/// loop (docs/reference/ghostty-vt-api.md §9.4).
fn kittyRedrawDelayNs(now_ms: u64, next_ms: u64) u64 {
    return @max(1, next_ms -| now_ms) * std.time.ns_per_ms;
}

// ---------------------------------------------------------------------------
// Software pointer compositing (back buffer only; render/pointer.zig owns
// position, visibility and damage tracking).
// ---------------------------------------------------------------------------

/// Source-over blend of one ARGB8888 sprite pixel onto an opaque back
/// buffer pixel. The result is always opaque (XRGB scanout); rounding is
/// symmetric (+127 before the /255).
fn blendPixel(dst: u32, src: u32) u32 {
    const a: u32 = src >> 24;
    if (a == 0) return dst;
    if (a == 255) return src | 0xFF000000;
    const inv_a = 255 - a;
    var out: u32 = 0xFF000000;
    inline for (.{ 0, 8, 16 }) |shift| {
        const s = (src >> shift) & 0xFF;
        const d = (dst >> shift) & 0xFF;
        out |= ((s * a + d * inv_a + 127) / 255) << shift;
    }
    return out;
}

/// Alpha-blit the pointer sprite into a back buffer at (dst_x, dst_y),
/// clipped to the destination on all four edges (the hotspot may sit at
/// the canvas edge). Writes only `fb`: the shadow canvas stays
/// pointer-free.
fn blitPointer(fb: *video.Framebuffer, sprite: *const video.Framebuffer, dst_x: i32, dst_y: i32) void {
    const dx0: i64 = dst_x;
    const dy0: i64 = dst_y;
    const x0 = @max(dx0, 0);
    const y0 = @max(dy0, 0);
    const x1 = @min(dx0 + sprite.width, @as(i64, fb.width));
    const y1 = @min(dy0 + sprite.height, @as(i64, fb.height));
    if (x1 <= x0 or y1 <= y0) return;
    var y: i64 = y0;
    while (y < y1) : (y += 1) {
        var x: i64 = x0;
        while (x < x1) : (x += 1) {
            const word = sprite.get(@intCast(x - dx0), @intCast(y - dy0));
            if (word >> 24 == 0) continue;
            const px: u32 = @intCast(x);
            const py: u32 = @intCast(y);
            fb.set(px, py, blendPixel(fb.get(px, py), word));
        }
    }
}

/// Physical bounding rect of a canvas-space rect under a viewport plan
/// (crop/scale/rotate), or null when it lies outside the viewport or the
/// plan is inactive. Same transform as Plan.damage / render.blitViewport:
/// canvas -> content (dst + (p - src) * scale) -> native rotation. The
/// integer corner enclosure over-covers by < 1 px, never under-covers.
fn pointerPhysicalRect(plan: layout.Plan, r: layout.Rect) ?video.Damage {
    if (!plan.active or plan.scale <= 0) return null;
    const vis = layout.Rect.intersect(r, plan.src) orelse return null;
    const sx: f64 = @floatFromInt(plan.src.x);
    const sy: f64 = @floatFromInt(plan.src.y);
    const c0x = plan.dst.x + (@as(f64, @floatFromInt(vis.x)) - sx) * plan.scale;
    const c0y = plan.dst.y + (@as(f64, @floatFromInt(vis.y)) - sy) * plan.scale;
    const c1x = plan.dst.x + (@as(f64, @floatFromInt(vis.endX())) - sx) * plan.scale;
    const c1y = plan.dst.y + (@as(f64, @floatFromInt(vis.endY())) - sy) * plan.scale;
    const x0: i32 = @intFromFloat(@floor(c0x));
    const y0: i32 = @intFromFloat(@floor(c0y));
    const x1: i32 = @as(i32, @intFromFloat(@ceil(c1x))) - 1;
    const y1: i32 = @as(i32, @intFromFloat(@ceil(c1y))) - 1;
    if (x1 < x0 or y1 < y0) return null;
    const rot = plan.conn.rotation;
    const pw = plan.conn.width_px;
    const ph = plan.conn.height_px;
    const corners = [_]layout.Point{
        rot.logicalToPhysical(x0, y0, pw, ph),
        rot.logicalToPhysical(x1, y0, pw, ph),
        rot.logicalToPhysical(x0, y1, pw, ph),
        rot.logicalToPhysical(x1, y1, pw, ph),
    };
    var lo_x: i32 = corners[0].x;
    var hi_x: i32 = corners[0].x;
    var lo_y: i32 = corners[0].y;
    var hi_y: i32 = corners[0].y;
    for (corners[1..]) |c| {
        lo_x = @min(lo_x, c.x);
        hi_x = @max(hi_x, c.x);
        lo_y = @min(lo_y, c.y);
        hi_y = @max(hi_y, c.y);
    }
    // Clamp to the native frame; hi is inclusive -> half-open +1.
    const px0 = @max(lo_x, 0);
    const py0 = @max(lo_y, 0);
    const px1 = @min(hi_x + 1, @as(i32, @intCast(pw)));
    const py1 = @min(hi_y + 1, @as(i32, @intCast(ph)));
    if (px1 <= px0 or py1 <= py0) return null;
    return .{
        .x = @intCast(px0),
        .y = @intCast(py0),
        .w = @intCast(px1 - px0),
        .h = @intCast(py1 - py0),
    };
}

/// Alpha-blit the pointer sprite through a scaled/rotated viewport plan
/// into a back buffer. Inverse-maps each physical pixel of the sprite's
/// bounding rect to content then canvas space with the same nearest-
/// neighbour sampling as render.blitViewport (floor(dst) origin, 1/scale
/// steps), so the pointer lands exactly on the content it points at.
fn blitPointerViewport(fb: *video.Framebuffer, sprite: *const video.Framebuffer, pos: pointer.Position, plan: layout.Plan) void {
    const bounds = pointerPhysicalRect(plan, .{
        .x = pos.x,
        .y = pos.y,
        .w = sprite.width,
        .h = sprite.height,
    }) orelse return;
    const phys = bounds.clipTo(fb.width, fb.height) orelse return;
    const inv = 1.0 / plan.scale;
    const dx0 = @floor(plan.dst.x);
    const dy0 = @floor(plan.dst.y);
    const sx: f64 = @floatFromInt(plan.src.x);
    const sy: f64 = @floatFromInt(plan.src.y);
    const rot = plan.conn.rotation;
    const pw = plan.conn.width_px;
    const ph = plan.conn.height_px;
    var py: u32 = phys.y;
    while (py < phys.y + phys.h) : (py += 1) {
        var px: u32 = phys.x;
        while (px < phys.x + phys.w) : (px += 1) {
            const c = rot.physicalToLogical(@intCast(px), @intCast(py), pw, ph);
            const fx = sx + (@as(f64, @floatFromInt(c.x)) - dx0) * inv;
            const fy = sy + (@as(f64, @floatFromInt(c.y)) - dy0) * inv;
            if (fx < 0 or fy < 0) continue;
            const cx: u32 = @intFromFloat(@floor(fx));
            const cy: u32 = @intFromFloat(@floor(fy));
            // Stay inside the viewport (largest-mode clipping) and the
            // sprite; the bounding rect may over-cover by a pixel.
            if (@as(i64, cx) < plan.src.x or @as(i64, cy) < plan.src.y or
                @as(i64, cx) >= plan.src.endX() or @as(i64, cy) >= plan.src.endY()) continue;
            const sp_x = @as(i64, cx) - pos.x;
            const sp_y = @as(i64, cy) - pos.y;
            if (sp_x < 0 or sp_y < 0 or sp_x >= sprite.width or sp_y >= sprite.height) continue;
            const word = sprite.get(@intCast(sp_x), @intCast(sp_y));
            if (word >> 24 == 0) continue;
            fb.set(px, py, blendPixel(fb.get(px, py), word));
        }
    }
}

/// The active console for the session factory (a plain fn pointer with no
/// closure). One console per process; the daemon spawns separate workers.
var current: ?*Console = null;

/// libinput seat assignment for seat workers: Input.init passes "seat0";
/// a worker must enumerate its own seat's devices (ID_SEAT filtering,
/// docs/reference/libseat-sdlogin.md §6.4). The seat name is NUL-terminated
/// (it came from getenv via multiseat.workerSeat).
fn workerAssignSeat(li: *libinput.Libinput, _: [*:0]const u8) callconv(.c) c_int {
    const c = current orelse return -1;
    const name = c.worker_seat orelse return libinput.LibinputOps.real.udev_assign_seat(li, "seat0");
    return libinput.LibinputOps.real.udev_assign_seat(li, name.ptr);
}

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

    // Kitty storage limit (M4.5): per-screen image storage budget comes
    // from the config (default 10 MiB; 0 disables the protocol).
    try ts.vt.setKittyStorageLimit(@as(u64, cfg.kitty_image_storage_limit));

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

    // ghostty cursor-style (Config.zig:883): the DEFAULT style; DECSCUSR
    // (CSI q) overrides at runtime and libghostty-vt restores the default
    // on RIS/DECSTR, like ghostty Terminal.zig:459-495.
    const cursor_style: vt.CursorStyle = switch (cfg.cursor_style) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    try ts.vt.setOption(.default_cursor_style, &cursor_style);

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

    // Seed the console's known cell metrics before start(): the spawn-time
    // TIOCSWINSZ must carry real pixel dimensions. A child that starts with
    // ws_xpixel/ws_ypixel = 0 (metrics only landed on the first render,
    // ~400 ms later) makes notcurses derive cellpx = 0 and permanently
    // disable pixel graphics (pixel_draw = NULL), which aborts demos that
    // require NCBLIT_PIXEL (keller) and silently degrades the others.
    if (c.cell.cell_w != 0 and c.cell.cell_h != 0) {
        ts.cell_w = c.cell.cell_w;
        ts.cell_h = c.cell.cell_h;
        try ts.session().resize(cols, rows);
    }

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

/// asciicast.Playback sink: feed the terminal emulator, NOT the pty child
/// (kmscon asciinema_write -> tsm_vte_input, terminal.c:478-486). The
/// animation renders on screen without typing into the login session.
fn playbackWrite(ud: ?*anyopaque, bytes: []const u8) void {
    const ts: *terminal.TerminalSession = @ptrCast(@alignCast(ud.?));
    ts.vt.write(bytes);
    if (current) |c| c.markDirty();
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

/// i32 -> i16 saturating clamp (same convention as render/cpu.zig's
/// clampI16): font metrics outside the cell-row range must not wrap.
fn clampI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// The selection for a connector name, or null: the reprobe diff matches
/// outputs to fresh selections by owned connector name (M5.4).
fn selectionFor(sels: []const ModeSelection, name: []const u8) ?ModeSelection {
    for (sels) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
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

/// Map `--gpus` to the backend GPU selection policy (M5.3).
fn gpuPolicy(g: config.Gpus) drm2d.GpuSelection {
    return switch (g) {
        .all => .all,
        .primary => .primary,
        .aux => .aux,
    };
}

/// Map `--multi-monitor` to the layout arrangement (M5.4).
fn mmMode(m: config.MultiMonitor) layout.MultiMonitorMode {
    return switch (m) {
        .clone => .clone,
        .largest => .largest,
        .scaled => .scaled,
    };
}

/// Build the layout.ModeSpec for a display from the three-tier `--mode`
/// lookup (M5.3). gpu/connector patterns are null when empty; a refresh rate
/// of 0 (absent) or one that does not fit u16 leaves the rate unspecified.
fn modeSpecFor(cfg: *const config.Config, gpu: []const u8, connector: []const u8) ?video.ModeSpec {
    const want = cfg.getMode(gpu, connector) orelse return null;
    return .{
        .pattern = .{
            .gpu = if (want.gpu.len > 0) want.gpu else null,
            .connector = if (want.connector.len > 0) want.connector else null,
        },
        .width = want.width,
        .height = want.height,
        .rate = if (want.refresh_rate > 0) std.math.cast(u16, want.refresh_rate) else null,
    };
}

/// grab-rotate-cw (11) / grab-rotate-ccw (12) step the rotation (M5.4).
fn rotateStep(r: layout.Rotation, grab_id: u16) layout.Rotation {
    return if (grab_id == 11) r.rotateCw() else r.rotateCcw();
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
// grab-reboot decision (M6.4, kmscon seat.c seat_trigger_reboot)
// ---------------------------------------------------------------------------

/// The reboot path selected by /proc/sys/kernel/ctrl-alt-del.
const RebootAction = enum {
    /// SIGINT to PID 1: init handles a graceful restart.
    soft,
    /// sync() + reboot(RB_AUTOBOOT).
    hard,
};

/// kmscon: 0 -> soft reboot, any other value -> hard reboot. A value that
/// could not be read defaults to soft (seat.c:421-455 initializes
/// ctrl_alt_del to 0 and only overwrites it on a successful fscanf).
fn rebootAction(ctrl_alt_del: ?i32) RebootAction {
    return if ((ctrl_alt_del orelse 0) == 0) .soft else .hard;
}

/// Read /proc/sys/kernel/ctrl-alt-del; null when the file cannot be opened
/// or read (kmscon defaults to the soft path in that case).
fn readCtrlAltDel() ?i32 {
    const fd = posix.openat(posix.AT.FDCWD, "/proc/sys/kernel/ctrl-alt-del", .{}, 0) catch return null;
    defer _ = linux.close(fd);
    var buf: [32]u8 = undefined;
    const n = posix.read(fd, &buf) catch return null;
    return parseCtrlAltDel(buf[0..n]);
}

/// fscanf("%d") semantics: leading whitespace, optional sign, decimal
/// digits; null when no integer is present (kmscon then defaults to soft).
fn parseCtrlAltDel(bytes: []const u8) ?i32 {
    var i: usize = 0;
    while (i < bytes.len and std.ascii.isWhitespace(bytes[i])) : (i += 1) {}
    const start = i;
    if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) i += 1;
    const digits = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {}
    if (i == digits) return null;
    return std.fmt.parseInt(i32, bytes[start..i], 10) catch null;
}

// ---------------------------------------------------------------------------
// Run paths
// ---------------------------------------------------------------------------

fn runConsole(io: std.Io, alloc: std.mem.Allocator, cfg: *config.Config, worker_seat: ?[:0]const u8) !void {
    const c = try alloc.create(Console);
    defer alloc.destroy(c);
    c.* = .{
        .alloc = alloc,
        .io = io,
        .cfg = cfg,
        .worker_seat = worker_seat,
    };
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
/// spawn one worker process per seat (a worker runs the single-seat console,
/// so there is no recursion). Seats with a real VT get a pinned-VT worker
/// (`--vt N --no-libseat`); seats without one get a fake-VT worker (M6.7,
/// no `--vt`, KMSHAUNT_SEAT selects FakeVt). Each worker inherits the daemon
/// environment plus KMSHAUNT_SEAT and the shared `--configdir`.
fn runDaemon(io: std.Io, alloc: std.mem.Allocator, cfg: *const config.Config, environ: std.process.Environ) !void {
    var lp = try loop.Loop.init();
    defer lp.deinit();

    var mon = try multiseat.SeatMonitor.init(alloc, multiseat.SdLoginOps.real);
    defer mon.deinit();

    const Daemon = struct {
        lp: *loop.Loop,
        mon: *multiseat.SeatMonitor,
        alloc: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        configdir: []const u8,
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
            var env = multiseat.workerEnviron(self.environ, self.alloc, s.name) catch |err| {
                log.err("worker environment for {s}: {t}", .{ s.name, err });
                return;
            };
            defer env.deinit();
            if (s.needsFakeVt()) {
                // M6.7: no kernel VT on this seat -> worker without --vt;
                // KMSHAUNT_SEAT makes it run the console on FakeVt.
                const child = std.process.spawn(self.io, .{
                    .argv = &.{ multiseat.worker_exe, "--configdir", self.configdir },
                    .environ_map = &env,
                }) catch |err| {
                    log.err("spawn fake-VT worker for {s}: {t}", .{ s.name, err });
                    return;
                };
                log.info("spawned fake-VT worker for {s} (pid {d})", .{ s.name, child.id orelse 0 });
                return;
            }
            const worker_vt = self.next_vt;
            self.next_vt +|= 1;
            var vt_buf: [16]u8 = undefined;
            const vt_arg = std.fmt.bufPrint(&vt_buf, "{d}", .{worker_vt}) catch return;
            const child = std.process.spawn(self.io, .{
                .argv = &.{ multiseat.worker_exe, "--configdir", self.configdir, "--no-libseat", "--no-switchvt", "--vt", vt_arg },
                .environ_map = &env,
            }) catch |err| {
                log.err("spawn worker for {s}: {t}", .{ s.name, err });
                return;
            };
            log.info("spawned worker for {s} on vt {d} (pid {d})", .{ s.name, worker_vt, child.id orelse 0 });
        }
    };

    var d = Daemon{ .lp = &lp, .mon = &mon, .alloc = alloc, .io = io, .environ = environ, .configdir = cfg.configdir };
    var ss: loop.SignalSource = undefined;
    try ss.init(&lp, .{ .callback = Daemon.onSignal, .userdata = @intFromPtr(&d), .signals = &.{ .TERM, .INT, .CHLD } });
    defer ss.deinit();

    const fd = try mon.fd();
    _ = try lp.addSource(fd, loop.ev.in_, Daemon.onSeat, @intFromPtr(&d));
    // Seats present at daemon startup are reported as `.added` on the
    // first process(); spawn their workers now (M6.7 S4), not only on the
    // next seat event.
    const initial = mon.process() catch |err| blk: {
        log.warn("initial seat enumerate: {t}", .{err});
        break :blk @as([]const multiseat.SeatChange, &.{});
    };
    for (initial) |ch| switch (ch) {
        .added => |s| {
            log.info("seat added: {s} (has_vt={})", .{ s.name, s.has_vt });
            d.spawnWorker(s);
        },
        .removed => {},
    };

    log.info("kmshaunt daemon: supervising seats", .{});
    try lp.run();
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

// ---------------------------------------------------------------------------
// M5.3-M5.7 video wiring tests (hermetic: no DRM device, no real GPU).
// ---------------------------------------------------------------------------

test "gpuPolicy: maps --gpus to the backend selection" {
    try std.testing.expectEqual(drm2d.GpuSelection.all, gpuPolicy(.all));
    try std.testing.expectEqual(drm2d.GpuSelection.primary, gpuPolicy(.primary));
    try std.testing.expectEqual(drm2d.GpuSelection.aux, gpuPolicy(.aux));
}

test "gpu selection: policy filters candidates through selectGpus" {
    const cands = [_]drm2d.GpuCandidate{
        .{ .path = "/dev/dri/card0", .name = "card0", .primary = true },
        .{ .path = "/dev/dri/card1", .name = "card1", .aux = true },
        .{ .path = "/dev/dri/card2", .name = "card2" },
    };
    var buf: [8]drm2d.GpuCandidate = undefined;
    try std.testing.expectEqual(@as(usize, 3), drm2d.selectGpus(&cands, gpuPolicy(.all), &buf).len);
    const prim = drm2d.selectGpus(&cands, gpuPolicy(.primary), &buf);
    try std.testing.expectEqual(@as(usize, 1), prim.len);
    try std.testing.expectEqualStrings("card0", prim[0].name);
    // aux keeps primary OR aux (the kmscon asymmetry).
    const aux = drm2d.selectGpus(&cands, gpuPolicy(.aux), &buf);
    try std.testing.expectEqual(@as(usize, 2), aux.len);
    try std.testing.expectEqualStrings("card0", aux[0].name);
    try std.testing.expectEqualStrings("card1", aux[1].name);
}

test "mmMode: maps --multi-monitor to the layout arrangement" {
    try std.testing.expectEqual(layout.MultiMonitorMode.clone, mmMode(.clone));
    try std.testing.expectEqual(layout.MultiMonitorMode.largest, mmMode(.largest));
    try std.testing.expectEqual(layout.MultiMonitorMode.scaled, mmMode(.scaled));
}

test "modeSpecFor: builds a ModeSpec from the three-tier --mode lookup" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit();
    var d = config.Diag{};
    try cfg.parseCli(&.{
        "--mode=card0[HDMI-A-1]1920x1080@60",
        "--mode=[DP-1]1280x720",
        "--mode=800x600",
    }, &d);

    // Exact gpu+connector tier: rate present.
    const exact = modeSpecFor(&cfg, "card0", "HDMI-A-1").?;
    try std.testing.expectEqualStrings("card0", exact.pattern.gpu.?);
    try std.testing.expectEqualStrings("HDMI-A-1", exact.pattern.connector.?);
    try std.testing.expectEqual(@as(u32, 1920), exact.width);
    try std.testing.expectEqual(@as(u32, 1080), exact.height);
    try std.testing.expectEqual(@as(?u16, 60), exact.rate);

    // Connector-only tier: gpu pattern null, rate absent -> null.
    const conn = modeSpecFor(&cfg, "card9", "DP-1").?;
    try std.testing.expect(conn.pattern.gpu == null);
    try std.testing.expectEqualStrings("DP-1", conn.pattern.connector.?);
    try std.testing.expectEqual(@as(?u16, null), conn.rate);

    // Global tier: both patterns null.
    const global = modeSpecFor(&cfg, "cardX", "VGA-1").?;
    try std.testing.expect(global.pattern.gpu == null);
    try std.testing.expect(global.pattern.connector == null);
    try std.testing.expectEqual(@as(u32, 800), global.width);
}

test "modeSpecFor: no matching --mode yields null; oversized rate is unspecified" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit();
    var d = config.Diag{};
    try cfg.parseCli(&.{"--mode=card0[HDMI-A-1]1920x1080@70000"}, &d);
    // Unmatched display.
    try std.testing.expect(modeSpecFor(&cfg, "card1", "DP-9") == null);
    // 70000 Hz does not fit u16: rate left unspecified rather than panicking.
    const spec = modeSpecFor(&cfg, "card0", "HDMI-A-1").?;
    try std.testing.expectEqual(@as(?u16, null), spec.rate);
}

test "rotateStep: grab 11 rotates cw, grab 12 rotates ccw, four steps wrap" {
    try std.testing.expectEqual(layout.Rotation.right, rotateStep(.normal, 11));
    try std.testing.expectEqual(layout.Rotation.normal, rotateStep(.left, 11));
    try std.testing.expectEqual(layout.Rotation.left, rotateStep(.normal, 12));
    try std.testing.expectEqual(layout.Rotation.normal, rotateStep(.right, 12));
    var r: layout.Rotation = .normal;
    for (0..4) |_| r = rotateStep(r, 11);
    try std.testing.expectEqual(layout.Rotation.normal, r);
}

test "multi-monitor wiring: mmMode + computeLayout shared grid for two outputs" {
    const conns = [_]layout.Connector{
        .{ .width_px = 1280, .height_px = 720 },
        .{ .width_px = 1920, .height_px = 1080 },
    };
    const cell = layout.Cell{ .w = 8, .h = 16 };
    var plans: [2]layout.Plan = undefined;
    // clone and scaled size the canvas from the smallest output (1280x720).
    const clone = layout.computeLayout(&conns, cell, mmMode(.clone), &plans);
    try std.testing.expectEqual(@as(u32, 160), clone.cols);
    try std.testing.expectEqual(@as(u32, 45), clone.rows);
    const scaled = layout.computeLayout(&conns, cell, mmMode(.scaled), &plans);
    try std.testing.expectEqual(@as(u32, 160), scaled.cols);
    try std.testing.expect(std.math.approxEqAbs(f64, 1.5, plans[1].scale, 1e-9));
    // largest sizes the canvas from the biggest output (1920x1080).
    const largest = layout.computeLayout(&conns, cell, mmMode(.largest), &plans);
    try std.testing.expectEqual(@as(u32, 240), largest.cols);
    try std.testing.expectEqual(@as(u32, 67), largest.rows);
}

test "selectionFor: matches fresh selections by connector name" {
    const mode = video.Mode{ .width_px = 1920, .height_px = 1080, .refresh_mhz = 60000, .width_mm = 530, .height_mm = 300 };
    const sels = [_]ModeSelection{
        .{ .ci = 0, .mi = 1, .mode = mode, .rotation = .normal, .name = "HDMI-A-1" },
        .{ .ci = 2, .mi = 0, .mode = mode, .rotation = .left, .name = "DP-1" },
    };
    try std.testing.expectEqual(@as(usize, 2), selectionFor(&sels, "DP-1").?.ci);
    try std.testing.expectEqual(layout.Rotation.left, selectionFor(&sels, "DP-1").?.rotation);
    try std.testing.expect(selectionFor(&sels, "VGA-1") == null);
    try std.testing.expect(selectionFor(&.{}, "DP-1") == null);
}

/// Bookkeeping-only console: the fake card pointers below are never
/// dereferenced (identity comparisons only), so no DRM device is needed.
fn testConsole() Console {
    return .{ .alloc = std.testing.allocator, .io = undefined, .cfg = undefined };
}

test "onInput: seat inactive drops the event (no VT input leak)" {
    // Regression: typing in another session (e.g. Hyprland) while kmshaunt's
    // VT is inactive must not leak into kmshaunt. While the seat is inactive
    // the kernel owns the keyboard, so onInput must drop the event before it
    // wakes DPMS, stops playback, reaches the manager or marks the console
    // dirty. (Active-path delivery is covered by the libinput dispatch tests.)
    var c = testConsole();
    c.seat_active = false;
    const ev = sess.InputEvent{ .key = .{
        .ghostty_key = @intFromEnum(kt.GhosttyKey.a),
        .mods = 0,
        .action = @intFromEnum(kt.GhosttyKeyAction.press),
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    } };
    Console.onInput(@intFromPtr(&c), ev);
    try std.testing.expect(!c.dirty);
}

test "uniqueCards: dedupes shared card backends in first-output order" {
    var c = testConsole();
    defer c.outputs.deinit(std.testing.allocator);
    const card0: *drm2d.Drm2d = @ptrFromInt(0x1000);
    const card1: *drm2d.Drm2d = @ptrFromInt(0x2000);
    const card2: *drm3d.Drm3d = @ptrFromInt(0x3000);
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card0 }, .name = "HDMI-A-1" });
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card1 }, .name = "HDMI-A-1" });
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card0 }, .name = "DP-1" });
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm3d = card2 }, .name = "eDP-1" });
    var cards: [max_outputs]DrmOutput = undefined;
    const n = c.uniqueCards(&cards);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(cards[0].cardPtr() == @as(*anyopaque, card0));
    try std.testing.expect(cards[1].cardPtr() == @as(*anyopaque, card1));
    try std.testing.expect(cards[2].cardPtr() == @as(*anyopaque, card2));
}

test "outputForName: scoped to the card, matched by connector name" {
    var c = testConsole();
    defer c.outputs.deinit(std.testing.allocator);
    const card0: *drm2d.Drm2d = @ptrFromInt(0x1000);
    const card1: *drm2d.Drm2d = @ptrFromInt(0x2000);
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card0 }, .name = "HDMI-A-1" });
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card0 }, .name = "DP-1" });
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card1 }, .name = "DP-1" });
    const o = c.outputForName(.{ .drm2d = card0 }, "DP-1").?;
    try std.testing.expectEqualStrings("DP-1", o.name);
    try std.testing.expect(o.drm.cardPtr() == @as(*anyopaque, card0));
    // The same connector name on another card is a different output.
    const o1 = c.outputForName(.{ .drm2d = card1 }, "DP-1").?;
    try std.testing.expect(o1 != o);
    try std.testing.expect(c.outputForName(.{ .drm2d = card0 }, "VGA-1") == null);
}

test "hasCardDrm: tracks whether any output still references the card" {
    var c = testConsole();
    defer c.outputs.deinit(std.testing.allocator);
    const card0: *drm2d.Drm2d = @ptrFromInt(0x1000);
    try std.testing.expect(!c.hasCardDrm(.{ .drm2d = card0 }));
    try c.outputs.append(std.testing.allocator, .{ .drm = .{ .drm2d = card0 }, .name = "HDMI-A-1" });
    try std.testing.expect(c.hasCardDrm(.{ .drm2d = card0 }));
}

// ---------------------------------------------------------------------------
// M6.4 grab-reboot decision tests (hermetic: no /proc read, no reboot).
// ---------------------------------------------------------------------------

test "parseCtrlAltDel: fscanf %d semantics" {
    try std.testing.expectEqual(@as(?i32, 0), parseCtrlAltDel("0\n"));
    try std.testing.expectEqual(@as(?i32, 1), parseCtrlAltDel("1\n"));
    try std.testing.expectEqual(@as(?i32, 1), parseCtrlAltDel(" 1 "));
    try std.testing.expectEqual(@as(?i32, 0), parseCtrlAltDel("+0"));
    try std.testing.expectEqual(@as(?i32, -1), parseCtrlAltDel("-1"));
    try std.testing.expectEqual(@as(?i32, 1), parseCtrlAltDel("1 trailing text"));
    try std.testing.expectEqual(@as(?i32, null), parseCtrlAltDel(""));
    try std.testing.expectEqual(@as(?i32, null), parseCtrlAltDel("\n"));
    try std.testing.expectEqual(@as(?i32, null), parseCtrlAltDel("abc"));
    try std.testing.expectEqual(@as(?i32, null), parseCtrlAltDel("+"));
}

test "rebootAction: 0 soft, nonzero hard, unreadable defaults soft (kmscon)" {
    try std.testing.expectEqual(RebootAction.soft, rebootAction(0));
    try std.testing.expectEqual(RebootAction.hard, rebootAction(1));
    try std.testing.expectEqual(RebootAction.hard, rebootAction(2));
    try std.testing.expectEqual(RebootAction.hard, rebootAction(-1));
    try std.testing.expectEqual(RebootAction.soft, rebootAction(null));
}

test "burstCostEwma: first sample adopted, rises slowly, falls fast" {
    // First frame adopts the sample outright.
    try std.testing.expectEqual(@as(u64, 8_000_000), burstCostEwma(0, 8_000_000));
    // Rising: 1/4 weight on the new sample (3*8 + 16)/4 = 10.
    try std.testing.expectEqual(@as(u64, 10_000_000), burstCostEwma(8_000_000, 16_000_000));
    // Falling: capped at 2x the latest frame, so a cheap frame after a burst
    // collapses the estimate immediately (min((3*16+1)/4=12, 2*1=2) = 2).
    try std.testing.expectEqual(@as(u64, 2_000_000), burstCostEwma(16_000_000, 1_000_000));
    // A zero-cost frame drives the estimate to zero.
    try std.testing.expectEqual(@as(u64, 0), burstCostEwma(16_000_000, 0));
}

test "burstStretchNs: refresh floor, cost scaling, display-rate floor" {
    const refresh: u64 = 16_666_667;
    // Cheap frame: never shorter than one refresh.
    try std.testing.expectEqual(refresh, burstStretchNs(1_000_000, refresh));
    // Expensive frame below the floor: cost * factor (8 ms * 9 = 72 ms).
    try std.testing.expectEqual(@as(u64, 72_000_000), burstStretchNs(8_000_000, refresh));
    // Costly frame: 9x cost would be 900 ms, but the display-rate floor caps
    // the period at 100 ms (>= 10 fps) so animation never collapses to 1-2 fps.
    try std.testing.expectEqual(max_burst_frame_period_ns, burstStretchNs(100_000_000, refresh));
    // Pathological frame: still capped at the floor, not 9x cost.
    try std.testing.expectEqual(max_burst_frame_period_ns, burstStretchNs(10 * std.time.ns_per_s, refresh));
    // Zero cost still yields one refresh.
    try std.testing.expectEqual(refresh, burstStretchNs(0, refresh));
}

test "burstPumpActive: cheap trickle renders on time; flood and costly trickle coalesce" {
    // Regression: btop at a fixed update rate writes one full-screen refresh
    // per period and every pump drains the pty (more = false). The old gate
    // only checked "a pump happened within the last refresh", so it held each
    // cheap frame for the burst stretch (up to the 100 ms cap) — the periodic
    // output hitch. A cheap trickle must render on time. Expensive frames and
    // real floods must still coalesce so render duty stays bounded (removing
    // that coalescing regressed the notcurses throughput geomean ~19%).
    const interval: i64 = 4_166_667;
    const now: i64 = 1_000_000_000;
    const cheap: u64 = 1_000_000; // 1 ms * 9 = 9 ms, below the 100 ms cap
    const costly: u64 = 20_000_000; // 20 ms * 9 = 180 ms, hits the cap
    try std.testing.expect(!burstPumpActive(now, now - 1_000, interval, false, cheap));
    try std.testing.expect(burstPumpActive(now, now - 1_000, interval, false, costly));
    try std.testing.expect(burstPumpActive(now, now - 1_000, interval, true, cheap));
    try std.testing.expect(!burstPumpActive(now, now - interval, interval, true, costly));
    try std.testing.expect(!burstPumpActive(now, now - interval - 1, interval, false, costly));
}

// ---------------------------------------------------------------------------
// Software pointer compositing tests (hermetic: CPU framebuffers only).
// ---------------------------------------------------------------------------

test "blendPixel: source-over onto opaque dst" {
    // Transparent keeps the destination.
    try std.testing.expectEqual(@as(u32, 0xFF123456), blendPixel(0xFF123456, 0x00ABCDEF));
    // Opaque replaces it (X bits forced opaque).
    try std.testing.expectEqual(@as(u32, 0xFFABCDEF), blendPixel(0xFF123456, 0xFFABCDEF));
    // ~50% white over black: (255*128 + 0*127 + 127)/255 = 128 per channel.
    try std.testing.expectEqual(@as(u32, 0xFF808080), blendPixel(0xFF000000, 0x80FFFFFF));
    // Per-channel independence: half red over blue (a=128, inv=127).
    try std.testing.expectEqual(@as(u32, 0xFF80007F), blendPixel(0xFF0000FF, 0x80FF0000));
}

test "blitPointer: clipped source-over sprite blit" {
    const a = std.testing.allocator;
    var fb = try video.Framebuffer.create(a, 8, 8, .xrgb8888, null);
    defer fb.destroy(a);
    var sprite = try video.Framebuffer.create(a, 4, 4, .argb8888, null);
    defer sprite.destroy(a);
    fb.fill(0xFF000000);
    sprite.set(0, 0, 0xFFFFFFFF); // opaque white
    sprite.set(1, 0, 0x00000000); // transparent
    sprite.set(0, 1, 0x80FF0000); // half red

    // Negative offset clips the top/left: only sprite (1,1)..(3,3) land,
    // all transparent -> fb unchanged.
    blitPointer(&fb, &sprite, -1, -1);
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.get(0, 0));

    // Bottom-right clip: sprite (0,0) -> fb(6,6), (0,1) -> fb(6,7);
    // columns/rows past the edge are dropped.
    blitPointer(&fb, &sprite, 6, 6);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb.get(6, 6));
    try std.testing.expectEqual(@as(u32, 0xFF800000), fb.get(6, 7));
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.get(7, 6)); // transparent sprite (1,0)

    // Fully out of bounds: no-op.
    blitPointer(&fb, &sprite, 8, 0);
    blitPointer(&fb, &sprite, 0, -4);
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.get(7, 7));
}

test "pointerPhysicalRect: crop/scale/rotate mapping" {
    // 1:1 with an integer letterbox offset.
    const aligned = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 100, .height_px = 80 },
        .src = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .scale = 1,
        .dst = .{ .x = 20, .y = 20, .w = 60, .h = 40 },
    };
    try std.testing.expectEqual(
        @as(?video.Damage, .{ .x = 25, .y = 25, .w = 12, .h = 19 }),
        pointerPhysicalRect(aligned, .{ .x = 5, .y = 5, .w = 12, .h = 19 }),
    );
    // 2x upscale: the rect doubles in content space.
    const scaled = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 120, .height_px = 80 },
        .src = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .scale = 2,
        .dst = .{ .x = 0, .y = 0, .w = 120, .h = 80 },
    };
    try std.testing.expectEqual(
        @as(?video.Damage, .{ .x = 10, .y = 10, .w = 24, .h = 38 }),
        pointerPhysicalRect(scaled, .{ .x = 5, .y = 5, .w = 12, .h = 19 }),
    );
    // Right rotation swaps the extents: content (10,20)-(21,38) maps to
    // native (pw-1-y, x) with pw=80.
    const rotated = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 80, .height_px = 100, .rotation = .right },
        .src = .{ .x = 0, .y = 0, .w = 100, .h = 80 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 0, .w = 100, .h = 80 },
    };
    try std.testing.expectEqual(
        @as(?video.Damage, .{ .x = 41, .y = 10, .w = 19, .h = 12 }),
        pointerPhysicalRect(rotated, .{ .x = 10, .y = 20, .w = 12, .h = 19 }),
    );
    // Largest-mode clipping: outside the viewport -> null; partial
    // overlap keeps only the visible part.
    const clipped = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 50, .height_px = 50 },
        .src = .{ .x = 10, .y = 10, .w = 40, .h = 40 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 0, .w = 40, .h = 40 },
    };
    try std.testing.expectEqual(@as(?video.Damage, null), pointerPhysicalRect(clipped, .{ .x = 0, .y = 0, .w = 5, .h = 5 }));
    try std.testing.expectEqual(
        @as(?video.Damage, .{ .x = 0, .y = 0, .w = 5, .h = 5 }),
        pointerPhysicalRect(clipped, .{ .x = 5, .y = 5, .w = 10, .h = 10 }),
    );
    // Inactive plan -> null.
    try std.testing.expectEqual(@as(?video.Damage, null), pointerPhysicalRect(.{}, .{ .x = 0, .y = 0, .w = 5, .h = 5 }));
}

test "blitPointerViewport: scaled and rotated sprite placement" {
    const a = std.testing.allocator;
    var sprite = try video.Framebuffer.create(a, 2, 2, .argb8888, null);
    defer sprite.destroy(a);
    sprite.set(0, 0, 0xFFFFFFFF);
    sprite.set(1, 0, 0xFF00FF00);
    sprite.set(0, 1, 0xFF0000FF);
    sprite.set(1, 1, 0x00000000);
    const pos = pointer.Position{ .x = 5, .y = 5 };

    // 2x upscale: each sprite pixel becomes a 2x2 block at (10,10).
    var fb = try video.Framebuffer.create(a, 120, 80, .xrgb8888, null);
    defer fb.destroy(a);
    fb.fill(0xFF000000);
    const scaled = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 120, .height_px = 80 },
        .src = .{ .x = 0, .y = 0, .w = 60, .h = 40 },
        .scale = 2,
        .dst = .{ .x = 0, .y = 0, .w = 120, .h = 80 },
    };
    blitPointerViewport(&fb, &sprite, pos, scaled);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb.get(10, 10));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb.get(11, 11));
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), fb.get(12, 10));
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), fb.get(10, 12));
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.get(12, 12)); // transparent
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.get(9, 9)); // outside

    // Right rotation: sprite (0,0) at content (5,5) -> native (80-1-5,5)
    // = (74,5); the 2x2 sprite spans content x 5..6, y 5..6 -> native
    // x 73..74, y 5..6.
    var rfb = try video.Framebuffer.create(a, 80, 100, .xrgb8888, null);
    defer rfb.destroy(a);
    rfb.fill(0xFF000000);
    const rotated = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 80, .height_px = 100, .rotation = .right },
        .src = .{ .x = 0, .y = 0, .w = 100, .h = 80 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 0, .w = 100, .h = 80 },
    };
    blitPointerViewport(&rfb, &sprite, pos, rotated);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), rfb.get(74, 5));
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), rfb.get(74, 6));
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), rfb.get(73, 5));
    try std.testing.expectEqual(@as(u32, 0xFF000000), rfb.get(73, 6)); // transparent
}

test "onPointerTimer: autohide marks dirty exactly once; null pointer is a no-op" {
    var c = testConsole();
    // Null pointer: the callback is a no-op (init-failure path).
    Console.onPointerTimer(undefined, 0, @intFromPtr(&c));
    try std.testing.expect(!c.dirty);

    // Visible pointer past its idle deadline: tick hides it and schedules
    // the erase frame. frame_armed pins scheduleFrame so no real timerfd
    // is needed.
    c.frame_armed = true;
    c.pointer = try pointer.Pointer.init(std.testing.allocator, 64, 64, .{});
    defer if (c.pointer) |*p| p.deinit();
    c.pointer.?.motion(10, 10, 0);
    Console.onPointerTimer(undefined, 0, @intFromPtr(&c));
    try std.testing.expect(!c.pointer.?.isVisible());
    try std.testing.expect(c.dirty);

    // Later ticks never re-hide or re-dirty (erase happens exactly once).
    c.dirty = false;
    Console.onPointerTimer(undefined, 0, @intFromPtr(&c));
    try std.testing.expect(!c.dirty);
}
