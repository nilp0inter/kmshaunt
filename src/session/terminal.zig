//! src/session/terminal.zig -- the terminal session (ROADMAP M1.4 pty+login,
//! M2.1 effects). Implements the src/session.zig Session vtable on top of
//! pty.Pty + vt.Vt + vt.Effects.
//!
//! Integration contract for main.zig
//! ---------------------------------
//! * `var ts = try TerminalSession.init(alloc, &cfg, cols, rows);`
//!   `const s = ts.session();` -- the Session handle. The struct must NOT be
//!   moved after init: the Effects table is registered lazily at the final
//!   address (see `ensureBound`), because init returns by value and the C
//!   userdata pointer must stay stable.
//!   init applies cfg.effectivePalette() to the terminal (16 ANSI colors +
//!   default fg/bg via the color_palette/color_foreground/color_background
//!   options; M2.4).
//! * `ts.setRenderer(r)` -- inject the render.Renderer (CpuRenderer). render()
//!   errors with NoRenderer until one is injected.
//! * `s.start()` opens the pty, builds the environment (below) and spawns
//!   cfg.login_argv. Then register `ts.masterFd()` with the epoll loop for
//!   EPOLLIN **edge-triggered** (kmscon misc/pty.c:448-466 does the same:
//!   /bin/login vhangup()s the tty, so HUP/EIO is NOT a reliable child-exit
//!   signal and level-triggered HUP would spin). On readiness call
//!   `ts.onPtyReadable()`, which drains the master into vt.write; every
//!   effect fires inline there.
//! * Child exit is tracked by PID, not by the tty: wire SIGCHLD (signalfd)
//!   to `ts.reapChild()`. It reaps non-blocking, fires hooks.child_exit and,
//!   when cfg.oneshot, stops the session. The pump also attempts a reap on
//!   EIO/EOF. Without oneshot the session stays up after child exit; the
//!   session manager decides whether to stop()/start() again (kmscon
//!   respawns login with retry throttling -- that policy lives above this
//!   module, in the hook owner).
//! * `ts.hooks` (set before start):
//!     - bell: BEL, gated by cfg.bell. main.zig wires this to KDMKTONE on
//!       the console fd (kmscon terminal.c:507-510 forwards BEL to the VT).
//!     - set_background / set_foreground: kmscon's private OSCs (bare
//!       identifiers, BEL or ST, NO reply -- docs/reference/kmscon-private-
//!       osc.md). main.zig wires set_background to terminal deactivate +
//!       DRM master release + input sleep (§3.2) and set_foreground to VT
//!       restore + DRM master retake + wake + full redraw (§3.3). Both are
//!       idempotent no-ops when already in the requested state; the retake
//!       may need the 50ms EBUSY retry timer (§3.3).
//!     - grab: grab-* InputEvents, forwarded verbatim to the session
//!       manager (kmscon grab resolution is not a session concern).
//!     - child_exit: terminal child status after reap, fired before the
//!       oneshot stop.
//! * `ts.blink_phase` -- main.zig's blink timer toggles this; render()
//!   passes it as the frame blink phase while cfg.blink is on (cursor and
//!   SGR text blink, M2.4).
//! * `ts.seat_name` / `ts.vt_nr` / `ts.drm` -- set before start; they feed
//!   XDG_SEAT / XDG_VTNR / TERM_SESSION_TYPE / KMS_START_SCRIPT below.
//!
//! Environment construction (kmscon misc/pty.c:204-249,
//! docs/reference/kmscon-options.md "Environ interactions")
//! --------------------------------------------------------
//! * cfg.reset_env (default on): the child starts from a COMPLETELY EMPTY
//!   environment. kmshaunt then adds a minimal PATH (default_path, same
//!   fallback as misc/pty.zig) and HOME (parent's HOME, else "/") so a
//!   non-login cfg.login_argv still works; /bin/login -p overrides both
//!   from login.defs/passwd. kmscon itself sets neither and relies on
//!   login(1) -- this is the one deliberate addition.
//! * cfg.reset_env off: the parent's full environment is inherited.
//! * On top of either base, in order: TERM=cfg.term (empty -> the
//!   xterm-ghostty default, ROADMAP D6), COLORTERM=truecolor
//!   (terminal.c:1492), XDG_SEAT/XDG_VTNR when seat info is set, and
//!   TERM_SESSION_TYPE=kms + KMS_START_SCRIPT=kmscon-launch-gui for DRM
//!   (TERM_SESSION_TYPE=fb otherwise).
//!
//! Effects routing (M2.1)
//! ----------------------
//!   write_pty        -> pty.write (every library reply: DA, DSR, size,
//!                       OSC 52 read replies, paste, ...). Single
//!                       non-blocking attempt: a full master drops the
//!                       reply rather than stalling the loop thread.
//!   bell             -> hooks.bell when cfg.bell.
//!   title/pwd        -> stored in-process (title()/pwd()); RIS clears them.
//!   clipboard_write  -> in-process buffer per location (OSC 52 stays
//!                       in-process per ROADMAP); denied unless
//!                       cfg.clipboard_write. Replies before return.
//!   clipboard_read   -> serves the buffer as text/plain; denied unless
//!                       cfg.clipboard_read. Replies before return.
//!   unknown_sequence -> exact, case-sensitive "setBackground" /
//!                       "setForeground" (kmscon-private-osc.md §1.4) fire
//!                       the hooks; NO reply. Everything else is ignored.
//!   size             -> current grid + cell pixels (XTWINOPS, mode 2048).
//!   color_scheme     -> dark (the console default).
//!   device_attributes-> VT220 conformance 62, features 22 (ANSI color) +
//!                       52 (clipboard); secondary VT220.
//!   render_hold      -> mode 2026: render() defers presentation while held.
//!   reset            -> clears stored title/pwd.
//!   resize_window    -> not installed: kmscon/libtsm does not honor
//!                       CSI 8;rows;cols t either.
//!   enquiry/xtversion/desktop_notification/progress_report/program_status/
//!   semantic_prompt  -> not installed (ignored), matching kmscon.
//!
//! Mouse routing (M2.3)
//! --------------------
//! Pointer events take one of two paths, decided per event by
//! vt.mouseTracking() (there is no mode-change callback):
//! * Tracking ON (X10/normal/button/any): motion/button/axis events are
//!   encoded by vt.MouseEncoder (mode + format refreshed from the
//!   terminal before every encode, so SGR/urxvt switches apply at once)
//!   and written to the pty. Wheel = button 4/5 (vertical) and 6/7
//!   (horizontal) press+release pairs at the last pointer position.
//! * Tracking OFF: the left button drives vt.SelectionGesture
//!   (press/drag/release). The gesture counts clicks itself (monotonic
//!   now_ns, 400 ms window matching libinput.double_click_window_ms):
//!   single = cell (the selection starts at the first drag), double =
//!   word, triple = line. Results are installed with vt.setSelection;
//!   the CPU renderer highlights selected cells (inverse video).
//!   Copy: on release -- and immediately on a double/triple press --
//!   vt.selectedText (Ghostty's PLAIN+UNWRAP+TRIM) lands in the
//!   in-process clipboard, primary AND standard (kmscon keeps a single
//!   copy buffer). Middle press pastes it through vt.paste (bracketed
//!   per mode 2004; unsafe text is refused, no confirmation prompt UI)
//!   and clears the selection; right press and any key event clear the
//!   selection too (kmscon terminal.c parity). Wheel events scroll the
//!   viewport 3 lines per detent (libinput reports +/-15 per wheel
//!   click), accumulated across fractional finger scrolls;
//!   natural-scrolling is applied by the input layer before us.
//! Enabling mouse tracking drops an in-progress selection (checked
//! after every pty pump). There is no autoscroll timer: kmscon's
//! selection does not autoscroll either.
//!
//! backspace-delete: the ghostty key encoder's BACKARROW_KEY_MODE option is
//! not exposed by vt.zig; its default (backspace emits 0x7f) already matches
//! cfg.backspace_delete = on. For off, handleKey intercepts unmodified
//! Backspace on the legacy path (kitty protocol active -> encoder decides).
//!
//! Tests: src/test_terminal.zig (needs vt-c + libghostty-vt; the exact
//! command is in that file's header and the completion report).

const std = @import("std");
const sess = @import("../session.zig");
const vt = @import("../vt.zig");
const render = @import("../render.zig");
const config = @import("../config/config.zig");
const pty_mod = @import("../misc/pty.zig");
const palette = @import("../misc/palette.zig");
const log = std.log.scoped(.terminal);
const asciicast = @import("../misc/asciicast.zig");

pub const Pty = pty_mod.Pty;

/// Minimal PATH for reset-env children; same fallback as misc/pty.zig.
pub const default_path = "/usr/local/bin:/usr/bin:/bin";

const reap_flags: u32 = std.posix.W.NOHANG | std.posix.W.UNTRACED;

/// Gesture click window: matches libinput.double_click_window_ms so the
/// input layer's click_count and the gesture's own counting agree.
const double_click_window_ns: u64 = 400 * std.time.ns_per_ms;
/// libinput reports one wheel detent as +/-15 axis units.
const wheel_detent: f64 = 15.0;
/// kmscon scrolls 3 lines per wheel event (terminal.c POINTER_WHEEL).
const scroll_lines_per_detent: f64 = 3.0;

/// Host hooks, all optional. `userdata` is passed to every callback.
/// Set before start(); see the module header for the wiring contract.
pub const Hooks = struct {
    userdata: ?*anyopaque = null,
    /// BEL (gated by cfg.bell). main.zig: KDMKTONE.
    bell: ?*const fn (userdata: ?*anyopaque) void = null,
    /// Private OSC setBackground. main.zig: deactivate + DRM master
    /// release + input sleep (kmscon-private-osc.md §3.2).
    set_background: ?*const fn (userdata: ?*anyopaque) void = null,
    /// Private OSC setForeground. main.zig: VT restore + DRM master
    /// retake + wake + redraw (kmscon-private-osc.md §3.3).
    set_foreground: ?*const fn (userdata: ?*anyopaque) void = null,
    /// grab-* event; the session manager resolves the id.
    grab: ?*const fn (userdata: ?*anyopaque, id: u16) void = null,
    /// Child exited (terminal status, after reap). Fired before the
    /// oneshot stop.
    child_exit: ?*const fn (userdata: ?*anyopaque, status: Pty.ReapStatus) void = null,
};

pub const TerminalSession = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,

    vt: vt.Vt,
    effects: vt.Effects,
    render_state: vt.RenderState,
    key_encoder: vt.KeyEncoder,
    mouse_encoder: vt.MouseEncoder,
    gesture: vt.SelectionGesture,
    pty: Pty = .{},
    active: bool = false,

    /// Injected by main.zig (CpuRenderer). Borrowed; not deinit'd here.
    renderer: ?render.Renderer = null,
    hooks: Hooks = .{},

    // Geometry. cell_w/cell_h are 0 until the first render/resize carries
    // real metrics; size reports and the mouse encoder use them.
    cols: u16,
    rows: u16,
    cell_w: u16 = 0,
    cell_h: u16 = 0,

    // Seat info for the child environment (set before start).
    seat_name: ?[]const u8 = null,
    vt_nr: ?u32 = null,
    /// DRM video backend: TERM_SESSION_TYPE=kms + KMS_START_SCRIPT.
    drm: bool = true,

    /// Blink phase driven by main.zig's blink timer (M2.4).
    blink_phase: bool = true,

    // Effect state.
    title_buf: std.ArrayListUnmanaged(u8) = .empty,
    pwd_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// In-process OSC 52 clipboard, one buffer per location.
    clipboard: [3]std.ArrayListUnmanaged(u8) = .{ .empty, .empty, .empty },
    render_held: bool = false,
    palette18: [18]u32 = @splat(0),
    last_pointer: struct { x: f32 = 0, y: f32 = 0 } = .{},
    /// M2.3: a left-button selection drag is in progress (tracking off).
    selecting: bool = false,
    /// Fractional wheel lines carried between axis events (handleAxis).
    scroll_accum: f64 = 0,
    /// Monotonic clock for the gesture's click counting; injectable for
    /// hermetic double-click tests (libinput.Input.now_ms convention).
    now_ns: *const fn () u64 = monotonicNs,

    /// Create the terminal, encoders, render state and the Effects table.
    /// The table is registered with the terminal lazily (ensureBound) at
    /// the struct's final address: init returns by value, and both the C
    /// userdata pointer and effects.userdata must point at stable storage.
    /// Do not move the struct after init.
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config.Config,
        cols: u16,
        rows: u16,
    ) !TerminalSession {
        var v = try vt.Vt.init(cols, rows);
        // ghostty grapheme-width-method=unicode enables mode 2027 by default;
        // ZWJ emoji sequences must arrive as one grapheme cell. setModeDefault
        // so RIS (which every parity frame sends) restores it.
        try v.setModeDefault(vt.mode(2027, false), true);
        errdefer v.deinit();
        var rs = try vt.RenderState.new();
        errdefer rs.deinit();
        var ke = try vt.KeyEncoder.new();
        errdefer ke.free();
        var me = try vt.MouseEncoder.new();
        errdefer me.free();
        var ge = try vt.SelectionGesture.new();
        errdefer ge.free(null);

        var self: TerminalSession = .{
            .allocator = allocator,
            .cfg = cfg,
            .vt = v,
            .effects = .{
                .userdata = null, // bound by ensureBound
                .write_pty = effWritePty,
                .bell = effBell,
                .title_changed = effTitle,
                .pwd_changed = effPwd,
                .size = effSize,
                .color_scheme = effColorScheme,
                .device_attributes = effDeviceAttributes,
                .clipboard_write = effClipboardWrite,
                .clipboard_read = effClipboardRead,
                .render_hold = effRenderHold,
                .reset = effReset,
                .unknown_sequence = effUnknown,
            },
            .render_state = rs,
            .key_encoder = ke,
            .mouse_encoder = me,
            .gesture = ge,
            .cols = cols,
            .rows = rows,
        };
        try self.vt.setScrollbackMaxLines(cfg.sb_size);
        // sb-size is a LINE budget; ghostty's default 10 KB byte cap would
        // prune history long before the line limit (M8.3). Size the byte
        // budget to hold sb_size lines of cells (16 B/cell is generous).
        try self.vt.setScrollbackMaxBytes(@as(usize, cfg.sb_size) * cols * 16);
        try self.vt.setOption(.default_cursor_blink, &cfg.blink);
        try self.applyPalette();
        return self;
    }

    /// Apply cfg.effectivePalette() (preset + palette-* overrides +
    /// custom) to the terminal: the 16 ANSI slots plus the default
    /// foreground/background. Slots 16..255 keep the standard xterm cube
    /// and grayscale (palette.xterm256), matching the library default and
    /// the CPU renderer's paletteColor. These set the terminal DEFAULTS:
    /// OSC 4/10/11 overrides still apply on top, and RIS restores this
    /// palette (libghostty keeps it as the palette "original").
    fn applyPalette(self: *TerminalSession) !void {
        const eff = self.cfg.effectivePalette();
        var pal: [256]vt.Rgb = undefined;
        for (0..16) |i| pal[i] = rgbFromPalette(eff[i]);
        for (16..256) |i| pal[i] = rgbFromPalette(palette.xterm256(@intCast(i)));
        try self.vt.setOption(.color_palette, &pal);
        const fg = rgbFromPalette(eff[16]);
        const bg = rgbFromPalette(eff[17]);
        try self.vt.setOption(.color_foreground, &fg);
        try self.vt.setOption(.color_background, &bg);
    }

    /// Stop the child and release everything. Safe after a failed start.
    pub fn deinit(self: *TerminalSession) void {
        self.stopImpl() catch {};
        self.render_state.deinit();
        self.key_encoder.free();
        self.mouse_encoder.free();
        self.gesture.free(&self.vt);
        self.vt.deinit();
        self.title_buf.deinit(self.allocator);
        self.pwd_buf.deinit(self.allocator);
        for (&self.clipboard) |*buf| buf.deinit(self.allocator);
    }

    /// The Session vtable handle. `self` must be at its final address.
    pub fn session(self: *TerminalSession) sess.Session {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn setRenderer(self: *TerminalSession, r: render.Renderer) void {
        self.renderer = r;
    }

    /// The pty master fd for epoll registration; -1 before start / after
    /// stop. Register EPOLLIN edge-triggered (module header).
    pub fn masterFd(self: *const TerminalSession) std.posix.fd_t {
        return self.pty.master_fd;
    }

    /// Current title (OSC 0/2), stored in-process.
    pub fn title(self: *const TerminalSession) []const u8 {
        return self.title_buf.items;
    }

    /// Current pwd (OSC 7 URI, unparsed), stored in-process.
    pub fn pwd(self: *const TerminalSession) []const u8 {
        return self.pwd_buf.items;
    }

    /// In-process clipboard contents for a location (text/plain).
    pub fn clipboardText(self: *const TerminalSession, location: vt.ClipboardLocation) []const u8 {
        return self.clipboard[@intFromEnum(location)].items;
    }

    /// Max bytes drained per pump before yielding to the loop (M8.1).
    /// A sustained output burst must not monopolize input/rendering;
    /// when the budget is hit the caller re-arms the edge-triggered
    /// source so pending data wakes the loop again.
    pub const pump_budget: usize = 256 * 1024;

    /// epoll pump: drain the pty master into the terminal, at most
    /// `pump_budget` bytes per call. Effects fire inline (vt.write).
    /// EIO/EOF means every slave fd closed -- NOT necessarily child exit
    /// (login vhangup); a non-blocking reap is attempted. Breaks on
    /// EAGAIN; register the fd edge-triggered. Returns true when the
    /// budget was exhausted (data may remain; re-arm the source).
    pub fn onPtyReadable(self: *TerminalSession) anyerror!bool {
        try self.ensureBound();
        if (!self.active) return false;
        var buf: [65536]u8 = undefined;
        var drained: usize = 0;
        var more = false;
        while (true) {
            const n = self.pty.read(&buf) catch |err| switch (err) {
                error.WouldBlock => break,
                error.InputOutput => {
                    try self.reapChild();
                    break;
                },
                else => return err,
            };
            if (n == 0) {
                try self.reapChild();
                break;
            }
            self.vt.write(buf[0..n]);
            drained += n;
            if (drained >= pump_budget) {
                more = true;
                break;
            }
        }
        // A program that enables mouse tracking takes over the pointer:
        // drop any in-progress selection (no mode-change callback exists,
        // so poll after every drain; module header).
        if (try self.vt.mouseTracking()) {
            if (self.selecting or (try self.vt.selection()) != null) try self.clearSelection();
        }
        return more;
    }

    /// SIGCHLD path (and the pump's EIO path): reap non-blocking. On a
    /// terminal status fire hooks.child_exit, then stop when cfg.oneshot.
    /// Without oneshot the session stays active; the hook owner decides
    /// whether to restart (module header).
    pub fn reapChild(self: *TerminalSession) anyerror!void {
        const result = try self.pty.reap(reap_flags) orelse return;
        switch (result.status) {
            .exited, .signaled => {},
            .stopped, .continued => return,
        }
        if (self.hooks.child_exit) |f| f(self.hooks.userdata, result.status);
        if (self.cfg.oneshot) try self.stopImpl();
    }

    // -- internals ---------------------------------------------------------

    /// Register the Effects table at the struct's stable address. Every
    /// entry point that can fire effects calls this first; after the first
    /// bind it is a single pointer compare.
    fn ensureBound(self: *TerminalSession) !void {
        if (self.effects.userdata != null) return;
        self.effects.userdata = self;
        try self.vt.setEffects(&self.effects);
    }

    fn startImpl(self: *TerminalSession) anyerror!void {
        if (self.active) return;
        try self.ensureBound();

        var p = try Pty.open(self.cols, self.rows);
        errdefer p.deinit();
        try p.setNonBlocking(true);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const env = try self.buildEnv(arena.allocator());

        try p.spawn(.{
            .argv = self.cfg.login_argv,
            .env = env,
            .winsize = .{
                .cols = self.cols,
                .rows = self.rows,
                .xpixel = pixelExtent(self.cols, self.cell_w),
                .ypixel = pixelExtent(self.rows, self.cell_h),
            },
            .allocator = self.allocator,
        });
        self.pty = p;
        self.active = true;
    }

    fn stopImpl(self: *TerminalSession) anyerror!void {
        if (!self.active) return;
        self.active = false;
        if (self.pty.child_pid > 0) {
            // SIGHUP, a short grace period, then SIGKILL; reap either way.
            self.pty.kill(.HUP) catch {};
            var waited_ms: u32 = 0;
            while (waited_ms < 200 and self.pty.child_pid > 0) : (waited_ms += 10) {
                if ((try self.pty.reap(reap_flags)) != null) break;
                sleepMs(10);
            }
            if (self.pty.child_pid > 0) {
                self.pty.kill(.KILL) catch {};
                while (self.pty.child_pid > 0) {
                    _ = self.pty.reap(0) catch |err| switch (err) {
                        error.Interrupted => continue,
                        else => break,
                    };
                }
            }
        }
        self.pty.deinit();
    }

    fn resizeImpl(self: *TerminalSession, cols: u16, rows: u16) anyerror!void {
        try self.ensureBound();
        try self.applyGeometry(cols, rows, self.cell_w, self.cell_h);
    }

    /// vt.resize (reflow) + TIOCSWINSZ + renderer reconfigure + mouse
    /// encoder geometry. Used by resize() and by render() when the context
    /// geometry changed (mode change / font size change).
    fn applyGeometry(self: *TerminalSession, cols: u16, rows: u16, cell_w: u16, cell_h: u16) !void {
        self.cols = cols;
        self.rows = rows;
        self.cell_w = cell_w;
        self.cell_h = cell_h;
        try self.vt.resize(cols, rows, cell_w, cell_h);
        if (self.active) try self.pty.resize(.{
            .cols = cols,
            .rows = rows,
            .xpixel = pixelExtent(cols, cell_w),
            .ypixel = pixelExtent(rows, cell_h),
        });
        if (self.renderer) |r| try r.resize(cols, rows, cell_w, cell_h);
        try self.updateMouseSize();
    }

    fn updateMouseSize(self: *TerminalSession) !void {
        if (self.cell_w == 0 or self.cell_h == 0) return;
        try self.mouse_encoder.setSize(.{
            .screen_width = @as(u32, self.cols) * self.cell_w,
            .screen_height = @as(u32, self.rows) * self.cell_h,
            .cell_width = self.cell_w,
            .cell_height = self.cell_h,
        });
    }

    fn renderImpl(self: *TerminalSession, ctx: *const sess.RenderContext) anyerror!void {
        try self.ensureBound();
        if (ctx.cols != self.cols or ctx.rows != self.rows or
            ctx.cell_w != self.cell_w or ctx.cell_h != self.cell_h)
        {
            try self.applyGeometry(ctx.cols, ctx.rows, ctx.cell_w, ctx.cell_h);
        }
        // Synchronized output (mode 2026): defer presentation while held.
        if (self.render_held) return;
        const r = self.renderer orelse return error.NoRenderer;

        try self.render_state.update(&self.vt);
        const colors = try self.render_state.colors();
        for (0..16) |i| self.palette18[i] = packRgb(colors.palette[i]);
        self.palette18[16] = packRgb(colors.foreground);
        self.palette18[17] = packRgb(colors.background);
        const cursor = try self.render_state.cursor();
        const opts: render.RenderOpts = .{
            .cursor_visible = cursor.visible,
            .cursor_style = switch (cursor.style) {
                .bar => .bar,
                .underline => .underline,
                // block_hollow has no renderer counterpart; draw block.
                .block, .block_hollow => .block,
            },
            // The session-wide blink phase: drives the cursor (when it
            // requests blinking) and SGR text blink alike (M2.4).
            .cursor_blink_on = if (self.cfg.blink) self.blink_phase else null,
            .palette = &self.palette18,
            .default_fg = self.palette18[16],
            .default_bg = self.palette18[17],
            .bg_opacity = 255,
        };
        try r.renderFrame(&self.render_state, ctx.fb, ctx.damage, opts);
        try self.render_state.clean();
    }

    fn onInputImpl(self: *TerminalSession, event: sess.InputEvent) anyerror!void {
        try self.ensureBound();
        switch (event) {
            .key => |k| try self.handleKey(k),
            .pointer_motion => |m| {
                self.last_pointer = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
                if (try self.vt.mouseTracking()) {
                    try self.handleMouse(.motion, null, m.x, m.y);
                } else if (self.selecting) {
                    try self.selectionDrag(m.x, m.y);
                }
            },
            .pointer_button => |b| {
                self.last_pointer = .{ .x = @floatCast(b.x), .y = @floatCast(b.y) };
                if (try self.vt.mouseTracking()) {
                    try self.handleMouse(if (b.pressed) .press else .release, mapButton(b.button), b.x, b.y);
                } else {
                    try self.handleSelectionButton(b);
                }
            },
            .pointer_axis => |a| try self.handleAxis(a),
            .grab => |g| {
                if (self.hooks.grab) |f| f(self.hooks.userdata, g.id);
            },
        }
    }

    fn handleKey(self: *TerminalSession, k: sess.InputEvent.Key) !void {
        if (!self.active) return;
        // kmscon resets the mouse selection on any key event
        // (terminal.c input_event).
        if (self.selecting or (try self.vt.selection()) != null) try self.clearSelection();
        const key = std.enums.fromInt(vt.Key, k.ghostty_key) orelse return;
        const action = std.enums.fromInt(vt.KeyAction, k.action) orelse return;

        // backspace-delete off: unmodified Backspace sends 0x08 on the
        // legacy path (kmscon terminal.c:1464). The encoder default is
        // 0x7f (= on); with the kitty protocol active the encoder decides.
        if (!self.cfg.backspace_delete and key == .backspace and k.mods == 0 and
            (try self.vt.kittyKeyboardFlags()) == 0)
        {
            try self.writeToPty("\x08");
            return;
        }

        try self.key_encoder.setFromTerminal(&self.vt);
        const ev: vt.KeyEvent = .{
            .action = action,
            .key = key,
            .mods = k.mods,
            .consumed_mods = k.consumed_mods,
            .utf8 = k.utf8 orelse "",
            .unshifted_codepoint = k.unshifted_codepoint orelse 0,
        };
        var buf: [64]u8 = undefined;
        const bytes = self.key_encoder.encode(ev, &buf) catch |err| switch (err) {
            error.OutOfSpace => blk: {
                var big: [256]u8 = undefined;
                break :blk try self.key_encoder.encode(ev, &big);
            },
            else => return err,
        };
        if (bytes.len > 0) try self.writeToPty(bytes);
    }

    fn handleMouse(self: *TerminalSession, action: vt.MouseAction, button: ?vt.MouseButton, x: f64, y: f64) !void {
        if (!self.active) return;
        // Reporting path: the caller gates on vt.mouseTracking(); the
        // check here keeps handleAxis safe. Mode + format are refreshed
        // from the terminal so X10/normal/button/any and SGR switches
        // apply without a mode-change callback.
        if (!(try self.vt.mouseTracking())) return;
        // Unmapped buttons (BTN_TASK, ...) must not encode as a phantom
        // button-3 press; motion without a button stays valid (any mode).
        if (action != .motion and button == null) return;
        try self.mouse_encoder.setFromTerminal(&self.vt);
        try self.updateMouseSize();
        var buf: [64]u8 = undefined;
        const bytes = try self.mouse_encoder.encode(.{
            .action = action,
            .button = button,
            .x = @floatCast(x),
            .y = @floatCast(y),
        }, &buf);
        if (bytes.len > 0) try self.writeToPty(bytes);
    }

    fn handleAxis(self: *TerminalSession, axis: sess.InputEvent.PointerAxis) !void {
        if (!self.active) return;
        if (try self.vt.mouseTracking()) {
            // Wheel events are button 4/5 (vertical) and 6/7 (horizontal)
            // press+release pairs at the last pointer position.
            if (axis.dy != 0) {
                const btn: vt.MouseButton = if (axis.dy > 0) .five else .four;
                try self.handleMouse(.press, btn, self.last_pointer.x, self.last_pointer.y);
                try self.handleMouse(.release, btn, self.last_pointer.x, self.last_pointer.y);
            }
            if (axis.dx != 0) {
                const btn: vt.MouseButton = if (axis.dx > 0) .seven else .six;
                try self.handleMouse(.press, btn, self.last_pointer.x, self.last_pointer.y);
                try self.handleMouse(.release, btn, self.last_pointer.x, self.last_pointer.y);
            }
            return;
        }
        // Local viewport scroll (natural-scrolling is already applied by
        // the input layer). libinput reports wheel detents as +/-15;
        // kmscon scrolls 3 lines per wheel event (terminal.c
        // POINTER_WHEEL). Accumulate so fractional finger/continuous
        // scrolls only move whole lines. Horizontal scroll has no
        // viewport counterpart (kmscon ignores it too).
        if (axis.dy == 0) return;
        self.scroll_accum += axis.dy / wheel_detent * scroll_lines_per_detent;
        const lines: isize = @intFromFloat(@trunc(self.scroll_accum));
        if (lines == 0) return;
        self.scroll_accum -= @floatFromInt(lines);
        try self.vt.scrollViewport(.{ .delta = lines });
    }

    // -- selection gestures (M2.3, tracking off) ---------------------------

    /// Left button: press starts the gesture (the gesture counts clicks:
    /// double = word, triple = line, installed and copied at once),
    /// release finishes a drag and copies. Middle press pastes the
    /// clipboard, right press cancels the selection (kmscon
    /// handle_pointer_button parity).
    fn handleSelectionButton(self: *TerminalSession, b: sess.InputEvent.PointerButton) !void {
        if (!self.active) return;
        if (self.cell_w == 0 or self.cell_h == 0) return; // no geometry yet
        switch (b.button) {
            0x110 => { // BTN_LEFT
                if (b.pressed) {
                    const ref = try self.cellRef(b.x, b.y);
                    const sel = try self.gesture.press(&self.vt, ref, .{
                        .position = .{ .x = b.x, .y = b.y },
                        .time_ns = self.now_ns(),
                        .repeat_interval_ns = double_click_window_ns,
                    });
                    if (sel) |s| {
                        // Double/triple click: word/line selected and copied
                        // at once; no drag follows (kmscon sets select=false).
                        self.selecting = false;
                        try self.vt.setSelection(&s);
                        try self.copySelection();
                    } else {
                        // Single click: the selection starts at the first
                        // drag; drop any previous selection.
                        self.selecting = true;
                        try self.vt.setSelection(null);
                    }
                } else {
                    const ref = try self.cellRef(b.x, b.y);
                    try self.gesture.release(&self.vt, ref);
                    if (self.selecting) {
                        self.selecting = false;
                        try self.copySelection();
                    }
                }
            },
            0x112 => { // BTN_MIDDLE: paste, then clear (kmscon)
                if (b.pressed) {
                    try self.pasteClipboard();
                    try self.clearSelection();
                }
            },
            0x111 => { // BTN_RIGHT: cancel the selection (kmscon)
                if (b.pressed) try self.clearSelection();
            },
            else => {},
        }
    }

    /// Extend the in-progress selection to the cell under the pointer.
    /// The real pixel position goes to the gesture: a cell is included
    /// only once the pointer crosses ~60% of its width.
    fn selectionDrag(self: *TerminalSession, x: f64, y: f64) !void {
        if (!self.active) return;
        if (self.cell_w == 0 or self.cell_h == 0) return;
        const ref = try self.cellRef(x, y);
        const geom: vt.GestureGeometry = .{
            .columns = self.cols,
            .cell_width = self.cell_w,
            .screen_height = @as(u32, self.rows) * self.cell_h,
        };
        if (try self.gesture.drag(&self.vt, ref, .{ .x = x, .y = y }, geom, false)) |sel| {
            try self.vt.setSelection(&sel);
        }
    }

    /// The viewport cell under a surface position, clamped to the grid
    /// (kmscon coord_to_cell). Untracked ref: install or pass it to the
    /// gesture before the next terminal mutation.
    fn cellRef(self: *TerminalSession, x: f64, y: f64) !vt.GridRef {
        const cw: f64 = @floatFromInt(self.cell_w);
        const ch: f64 = @floatFromInt(self.cell_h);
        const cx = std.math.clamp(@floor(x / cw), 0, @as(f64, @floatFromInt(self.cols - 1)));
        const cy = std.math.clamp(@floor(y / ch), 0, @as(f64, @floatFromInt(self.rows - 1)));
        return self.vt.gridRef(.viewport, .{ .x = @intFromFloat(cx), .y = @intFromFloat(cy) });
    }

    fn clearSelection(self: *TerminalSession) !void {
        self.selecting = false;
        self.gesture.reset(&self.vt);
        try self.vt.setSelection(null);
    }

    /// Copy the installed selection into the in-process clipboard:
    /// primary (X11 selection owner) and standard (kmscon keeps a single
    /// copy buffer, so OSC 52 reads and paste see it too). Formats into
    /// the primary buffer directly, growing it on OutOfSpace.
    fn copySelection(self: *TerminalSession) !void {
        const sel = (try self.vt.selection()) orelse return;
        const buf = &self.clipboard[@intFromEnum(vt.ClipboardLocation.primary)];
        var cap: usize = @max(buf.capacity, 4096);
        while (true) {
            try buf.ensureTotalCapacity(self.allocator, cap);
            const text = vt.selectedText(&self.vt, &sel, buf.allocatedSlice()) catch |err| switch (err) {
                error.OutOfSpace => {
                    cap *= 2;
                    continue;
                },
                else => return err,
            };
            buf.items.len = text.len;
            break;
        }
        const std_buf = &self.clipboard[@intFromEnum(vt.ClipboardLocation.standard)];
        std_buf.clearRetainingCapacity();
        try std_buf.appendSlice(self.allocator, buf.items);
    }

    /// Middle-click paste: primary first, standard as the fallback.
    /// vt.paste frames per mode 2004 (bracketed) or streams plain text
    /// through write_pty. Unsafe text (line terminators without bracketed
    /// paste, or the bracket terminator itself) is refused: the clipboard
    /// is program-writable when clipboard-write is on, so pasting it raw
    /// would be a command-injection vector. There is no confirmation
    /// prompt UI; refusal is silent apart from a log line.
    fn pasteClipboard(self: *TerminalSession) !void {
        const text = if (self.clipboardText(.primary).len > 0)
            self.clipboardText(.primary)
        else
            self.clipboardText(.standard);
        if (text.len == 0) return;
        _ = self.vt.paste(text, .{ .location = .primary, .allow_unsafe = false }) catch |err| switch (err) {
            error.Rejected => {
                log.warn("paste refused: clipboard text is unsafe to paste", .{});
                return;
            },
            else => return err,
        };
    }

    /// Write to the pty master, retrying a full non-blocking master with
    /// bounded POLLOUT polls (~1s total). Errors propagate to the input
    /// path; the effect sink (effWritePty) is best-effort by contract.
    fn writeToPty(self: *TerminalSession, bytes: []const u8) !void {
        if (!self.active or self.pty.master_fd < 0) return;
        var off: usize = 0;
        var polls: u32 = 0;
        while (off < bytes.len) {
            const n = self.pty.write(bytes[off..]) catch |err| switch (err) {
                error.WouldBlock => {
                    if (polls >= 100) return error.WouldBlock;
                    polls += 1;
                    var pfd = [_]std.posix.pollfd{.{
                        .fd = self.pty.master_fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = try std.posix.poll(&pfd, 10);
                    continue;
                },
                else => return err,
            };
            off += n;
        }
    }

    // -- environment -------------------------------------------------------

    fn buildEnv(self: *TerminalSession, aa: std.mem.Allocator) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        const cfg = self.cfg;
        if (cfg.reset_env) {
            // kmscon misc/pty.c:213-219: completely empty environment.
            // kmshaunt adds minimal PATH/HOME for non-login login_argv;
            // /bin/login -p overrides both (module header).
            try list.append(aa, "PATH=" ++ default_path);
            try list.append(aa, try std.fmt.allocPrint(aa, "HOME={s}", .{parentEnv("HOME") orelse "/"}));
        } else {
            var i: usize = 0;
            while (std.c.environ[i]) |entry_z| : (i += 1) {
                try list.append(aa, try aa.dupe(u8, std.mem.span(entry_z)));
            }
        }
        const term = if (cfg.term.len > 0) cfg.term else config.default_term;
        try putEnv(aa, &list, "TERM", term);
        try putEnv(aa, &list, "COLORTERM", "truecolor");
        if (self.seat_name) |seat| try putEnv(aa, &list, "XDG_SEAT", seat);
        if (self.vt_nr) |nr| try putEnv(aa, &list, "XDG_VTNR", try std.fmt.allocPrint(aa, "{d}", .{nr}));
        if (self.drm) {
            try putEnv(aa, &list, "KMS_START_SCRIPT", "kmscon-launch-gui");
            try putEnv(aa, &list, "TERM_SESSION_TYPE", "kms");
        } else {
            try putEnv(aa, &list, "TERM_SESSION_TYPE", "fb");
        }
        return list.items;
    }

    fn putEnv(
        aa: std.mem.Allocator,
        list: *std.ArrayListUnmanaged([]const u8),
        name: []const u8,
        value: []const u8,
    ) !void {
        const entry = try std.fmt.allocPrint(aa, "{s}={s}", .{ name, value });
        for (list.items) |*item| {
            if (item.len > name.len and std.mem.startsWith(u8, item.*, name) and item.*[name.len] == '=') {
                item.* = entry;
                return;
            }
        }
        try list.append(aa, entry);
    }

    fn parentEnv(name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (std.c.environ[i]) |entry_z| : (i += 1) {
            const entry = std.mem.span(entry_z);
            if (entry.len > name.len and std.mem.startsWith(u8, entry, name) and entry[name.len] == '=')
                return entry[name.len + 1 ..];
        }
        return null;
    }

    // -- effect callbacks (userdata = *TerminalSession) ---------------------
    // REENTRANCY: these fire inside vt.write/resize and must not mutate the
    // terminal (vt.zig Effects docs). pty writes and hook calls are safe.

    fn fromUserdata(userdata: ?*anyopaque) *TerminalSession {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn effWritePty(userdata: ?*anyopaque, data: []const u8) void {
        const self = fromUserdata(userdata);
        // Best-effort and NON-BLOCKING: this fires inside vt.write on the
        // loop thread. A child that stops reading stdin while flooding
        // queries fills the master input queue; polling here (writeToPty)
        // would stall input, rendering and VT switches ~1 s per reply.
        // Drop the reply instead; input writes keep the bounded retry.
        if (!self.active or self.pty.master_fd < 0) return;
        _ = self.pty.write(data) catch {};
    }

    fn effBell(userdata: ?*anyopaque) void {
        const self = fromUserdata(userdata);
        if (!self.cfg.bell) return;
        if (self.hooks.bell) |f| f(self.hooks.userdata);
    }

    fn effTitle(userdata: ?*anyopaque, t: []const u8) void {
        const self = fromUserdata(userdata);
        self.title_buf.clearRetainingCapacity();
        self.title_buf.appendSlice(self.allocator, t) catch {};
    }

    fn effPwd(userdata: ?*anyopaque, p: []const u8) void {
        const self = fromUserdata(userdata);
        self.pwd_buf.clearRetainingCapacity();
        self.pwd_buf.appendSlice(self.allocator, p) catch {};
    }

    fn effSize(userdata: ?*anyopaque, out: *vt.SizeReport) bool {
        const self = fromUserdata(userdata);
        out.* = .{
            .rows = self.rows,
            .columns = self.cols,
            .cell_width = self.cell_w,
            .cell_height = self.cell_h,
        };
        return true;
    }

    fn effColorScheme(userdata: ?*anyopaque, out: *vt.ColorScheme) bool {
        _ = userdata;
        out.* = .dark;
        return true;
    }

    fn effDeviceAttributes(userdata: ?*anyopaque, out: *vt.DeviceAttributes) bool {
        _ = userdata;
        out.primary = .{
            .conformance_level = vt.da_conformance_vt220,
            .features = @splat(0),
            .num_features = 2,
        };
        out.primary.features[0] = vt.da_feature_ansi_color;
        out.primary.features[1] = vt.da_feature_clipboard;
        out.secondary = .{
            .device_type = vt.da_device_type_vt220,
            .firmware_version = 0,
            .rom_cartridge = 0,
        };
        out.tertiary = .{ .unit_id = 0 };
        return true;
    }

    fn effClipboardWrite(userdata: ?*anyopaque, req: *const vt.ClipboardWriteRequest) void {
        const self = fromUserdata(userdata);
        // Default-deny: any output source could otherwise poison the
        // clipboard the user pastes from (cfg.clipboard_write opts in).
        if (!self.cfg.clipboard_write) {
            req.reply(.denied, false);
            return;
        }
        const buf = &self.clipboard[@intFromEnum(req.location)];
        buf.clearRetainingCapacity();
        if (req.contents.len > 0) {
            // Prefer text/plain; fall back to the first representation.
            var chosen = req.contents[0];
            for (req.contents) |content| {
                if (std.mem.eql(u8, content.mime, "text/plain")) {
                    chosen = content;
                    break;
                }
            }
            buf.appendSlice(self.allocator, chosen.data) catch {
                req.reply(.io_error, false);
                return;
            };
        }
        req.reply(.success, false);
    }

    fn effClipboardRead(userdata: ?*anyopaque, req: *const vt.ClipboardReadRequest) void {
        const self = fromUserdata(userdata);
        // Default-deny: any output source could otherwise exfiltrate the
        // clipboard (cfg.clipboard_read opts in).
        if (!self.cfg.clipboard_read) {
            req.reply(.denied, false);
            return;
        }
        const buf = &self.clipboard[@intFromEnum(req.location)];
        // Only text/plain is stored. A list-only request (no mimes) is
        // served without a prompt.
        var wants_text = req.mimes.len == 0;
        for (req.mimes) |mime| {
            if (std.mem.eql(u8, mime, "text/plain")) {
                wants_text = true;
                break;
            }
        }
        const text_mime = "text/plain";
        const available = [_][]const u8{text_mime};
        const avail: []const []const u8 = if (req.list) &available else &.{};
        if (!wants_text) {
            req.reply(.unsupported, &.{}, &.{}, false);
            return;
        }
        if (buf.items.len == 0) {
            req.reply(.success, &.{}, avail, false);
            return;
        }
        const contents = [_]vt.ClipboardContent{.{ .mime = text_mime, .data = buf.items }};
        req.reply(.success, &contents, avail, false);
    }

    fn effRenderHold(userdata: ?*anyopaque, held: bool) void {
        fromUserdata(userdata).render_held = held;
    }

    fn effReset(userdata: ?*anyopaque) void {
        const self = fromUserdata(userdata);
        // RIS: the library clears its own title/pwd without firing the
        // change callbacks; mirror that here.
        self.title_buf.clearRetainingCapacity();
        self.pwd_buf.clearRetainingCapacity();
    }

    fn effUnknown(userdata: ?*anyopaque, seq: vt.UnknownSequence) void {
        const self = fromUserdata(userdata);
        if (seq.tag != .osc or seq.truncated) return;
        // Exact, case-sensitive match on the bare identifier; both BEL and
        // ST terminators arrive here; NO reply (kmscon-private-osc.md
        // §1.4, §3.5).
        if (std.mem.eql(u8, seq.content, "setBackground")) {
            if (self.hooks.set_background) |f| f(self.hooks.userdata);
        } else if (std.mem.eql(u8, seq.content, "setForeground")) {
            if (self.hooks.set_foreground) |f| f(self.hooks.userdata);
        }
    }

    // -- Session vtable -----------------------------------------------------

    const vtable = sess.Session.VTable{
        .deinit = vtDeinit,
        .start = vtStart,
        .stop = vtStop,
        .isActive = vtIsActive,
        .resize = vtResize,
        .render = vtRender,
        .onInput = vtOnInput,
        .name = vtName,
    };

    fn cast(ptr: *anyopaque) *TerminalSession {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }
    fn vtStart(ptr: *anyopaque) anyerror!void {
        return cast(ptr).startImpl();
    }
    fn vtStop(ptr: *anyopaque) anyerror!void {
        return cast(ptr).stopImpl();
    }
    fn vtIsActive(ptr: *anyopaque) bool {
        return cast(ptr).active;
    }
    fn vtResize(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        return cast(ptr).resizeImpl(cols, rows);
    }
    fn vtRender(ptr: *anyopaque, ctx: *const sess.RenderContext) anyerror!void {
        return cast(ptr).renderImpl(ctx);
    }
    fn vtOnInput(ptr: *anyopaque, event: sess.InputEvent) anyerror!void {
        return cast(ptr).onInputImpl(event);
    }
    fn vtName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "terminal";
    }
};

/// Pixel extent for TIOCSWINSZ: grid cells times cell pixels, saturated
/// at the u16 winsize field width. 0 while the cell metric is unknown
/// (cell_px == 0), so pre-first-render spawns report pixels 0 rather than
/// a bogus size.
fn pixelExtent(cells: u16, cell_px: u16) u16 {
    const px: u32 = @as(u32, cells) * cell_px;
    return @intCast(@min(px, std.math.maxInt(u16)));
}

fn packRgb(c: vt.Rgb) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

fn rgbFromPalette(c: palette.Color) vt.Rgb {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

fn mapButton(code: u32) ?vt.MouseButton {
    return switch (code) {
        0x110 => .left, // BTN_LEFT
        0x111 => .right, // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        // Side buttons: X11 buttons 8/9 (4/5 are the wheel). The ghostty
        // encoder emits them as codes 128/129; ten/eleven are unsupported
        // by the encoder, so BTN_FORWARD/BTN_BACK stay unmapped.
        0x113 => .eight, // BTN_SIDE
        0x114 => .nine, // BTN_EXTRA
        else => null,
    };
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Tests: real vt + spawned shell children — never /bin/login. The shell is
// resolved by misc/test_env.zig (KMSHAUNT_TEST_SH, default /bin/sh) so the
// suite also runs in the Nix sandbox, where /bin/sh is busybox and cannot run
// the `read -t`/`read -N` scripts below. Run via src/test_terminal.zig; the
// command is in that file's header.
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_env = @import("../misc/test_env.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn testCfg(argv: []const []const u8) config.Config {
    var cfg = config.Config.init(testing.allocator);
    cfg.login_argv = argv;
    return cfg;
}

/// Capture the whole screen as text. Forces a full-dirty capture (a resize
/// round-trip) so every row is iterable regardless of prior update/clean
/// calls; vt.zig's Rows only exposes nextDirty.
fn screenText(ts: *TerminalSession, buf: []u8) ![]const u8 {
    try ts.vt.resize(ts.cols, ts.rows + 1, 0, 0);
    try ts.vt.resize(ts.cols, ts.rows, 0, 0);
    try ts.render_state.update(&ts.vt);
    var rows = try ts.render_state.rowsIter();
    var total: usize = 0;
    while (try rows.nextDirty()) |row| {
        var cells = try row.cells();
        while (try cells.next()) |cell| {
            if (total + cell.text.len >= buf.len) return error.OutOfSpace;
            @memcpy(buf[total..][0..cell.text.len], cell.text);
            total += cell.text.len;
        }
        buf[total] = '\n';
        total += 1;
    }
    return buf[0..total];
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn pumpUntil(
    ts: *TerminalSession,
    ctx: anytype,
    comptime pred: fn (@TypeOf(ctx), *TerminalSession) bool,
    timeout_ms: i64,
) !void {
    const start = nowMs();
    var pfd = [_]std.posix.pollfd{.{
        .fd = ts.masterFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (!pred(ctx, ts)) {
        if (nowMs() - start > timeout_ms) return error.TestTimeout;
        const ready = try std.posix.poll(&pfd, 10);
        if (ready > 0) {
            _ = try ts.onPtyReadable();
        }
    }
}

const TextWatch = struct {
    needle: []const u8,
    buf: [8192]u8 = undefined,
    len: usize = 0,

    fn pred(w: *TextWatch, ts: *TerminalSession) bool {
        const text = screenText(ts, &w.buf) catch return false;
        w.len = text.len;
        return std.mem.indexOf(u8, text, w.needle) != null;
    }
};

fn pumpUntilText(ts: *TerminalSession, needle: []const u8, timeout_ms: i64) ![]const u8 {
    var w = TextWatch{ .needle = needle };
    try pumpUntil(ts, &w, TextWatch.pred, timeout_ms);
    return w.buf[0..w.len];
}

fn inactivePred(_: void, ts: *TerminalSession) bool {
    return !ts.active;
}

const HookLog = struct {
    bells: u32 = 0,
    backgrounds: u32 = 0,
    foregrounds: u32 = 0,
    grabs: u32 = 0,
    last_grab: u16 = 0,
    exits: u32 = 0,
    last_exit: ?Pty.ReapStatus = null,

    fn hooks(self: *HookLog) Hooks {
        return .{
            .userdata = self,
            .bell = bellCb,
            .set_background = bgCb,
            .set_foreground = fgCb,
            .grab = grabCb,
            .child_exit = exitCb,
        };
    }
    fn log(ud: ?*anyopaque) *HookLog {
        return @ptrCast(@alignCast(ud.?));
    }
    fn bellCb(ud: ?*anyopaque) void {
        log(ud).bells += 1;
    }
    fn bgCb(ud: ?*anyopaque) void {
        log(ud).backgrounds += 1;
    }
    fn fgCb(ud: ?*anyopaque) void {
        log(ud).foregrounds += 1;
    }
    fn grabCb(ud: ?*anyopaque, id: u16) void {
        const l = log(ud);
        l.grabs += 1;
        l.last_grab = id;
    }
    fn exitCb(ud: ?*anyopaque, status: Pty.ReapStatus) void {
        const l = log(ud);
        l.exits += 1;
        l.last_exit = status;
    }
};

/// Type one character through the Session vtable (key encoder -> pty).
fn sendChar(s: sess.Session, key: vt.Key, ch: ?u8) !void {
    var buf: [1]u8 = undefined;
    const utf8: ?[]const u8 = if (ch) |c| blk: {
        buf[0] = c;
        break :blk &buf;
    } else null;
    try s.onInput(.{ .key = .{
        .ghostty_key = @intFromEnum(key),
        .mods = 0,
        .action = 1,
        .utf8 = utf8,
        .unshifted_codepoint = if (ch) |c| c else null,
    } });
}

test "terminal: start spawns child, output renders, env constructed" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello terminal'; printf ' T=%s C=%s S=%s' \"$TERM\" \"$COLORTERM\" \"$TERM_SESSION_TYPE\"" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();

    try testing.expectEqualStrings("terminal", s.name());
    try testing.expect(!s.isActive());
    try testing.expectEqual(@as(std.posix.fd_t, -1), ts.masterFd());
    try s.start();
    try testing.expect(s.isActive());
    try testing.expect(ts.masterFd() >= 0);
    // start is a no-op when already active.
    try s.start();

    const text = try pumpUntilText(&ts, "T=xterm-ghostty", 5000);
    try testing.expect(std.mem.indexOf(u8, text, "hello terminal") != null);
    try testing.expect(std.mem.indexOf(u8, text, "C=truecolor") != null);
    try testing.expect(std.mem.indexOf(u8, text, "S=kms") != null);
}

test "terminal: echo round-trip via onInput key encoding" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    // "echo roundtrip<Enter>" -- the tty/readline echo and the command
    // output both come back through the pump into the vt.
    const keys = [_]struct { k: vt.Key, c: ?u8 }{
        .{ .k = .e, .c = 'e' }, .{ .k = .c, .c = 'c' }, .{ .k = .h, .c = 'h' },
        .{ .k = .o, .c = 'o' }, .{ .k = .space, .c = ' ' }, .{ .k = .r, .c = 'r' },
        .{ .k = .o, .c = 'o' }, .{ .k = .u, .c = 'u' }, .{ .k = .n, .c = 'n' },
        .{ .k = .d, .c = 'd' }, .{ .k = .t, .c = 't' }, .{ .k = .r, .c = 'r' },
        .{ .k = .i, .c = 'i' }, .{ .k = .p, .c = 'p' }, .{ .k = .enter, .c = null },
    };
    for (keys) |key| try sendChar(s, key.k, key.c);
    _ = try pumpUntilText(&ts, "roundtrip", 5000);

    // "exit<Enter>": child exits; without oneshot the session stays up and
    // the child_exit hook fires with status 0.
    try sendChar(s, .e, 'e');
    try sendChar(s, .x, 'x');
    try sendChar(s, .i, 'i');
    try sendChar(s, .t, 't');
    try sendChar(s, .enter, null);
    try pumpUntil(&ts, &log, struct {
        fn p(l: *HookLog, _: *TerminalSession) bool {
            return l.exits > 0;
        }
    }.p, 5000);
    try testing.expectEqual(@as(u32, 1), log.exits);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 0 }, log.last_exit.?);
    try testing.expect(s.isActive());
}

test "terminal: echo-off canonical read receives typed keys (login password parity)" {
    // util-linux login reads the password through PAM misc_conv: a canonical
    // read(2) with ECHO cleared via TCSAFLUSH, after the username was read
    // with echo on. Reproduce that transition with sh + stty and type both
    // lines through the key encoder; the password must reach the child even
    // though nothing echoes it back (interactive login hang regression).
    //
    // Waiting for the prompt is part of the contract, not test convenience:
    // misc_conv disables ECHO with TCSAFLUSH *before* printing "Password: ",
    // so bytes typed ahead of the prompt are discarded by the kernel and the
    // password arrives truncated. Interactive-login scenarios (VM or T4) must
    // type the password only after the prompt is on screen.
    const stty = test_env.tool("stty") orelse return error.SkipZigTest;
    var cmd_buf: [320]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "read u; {s} -echo; printf 'Password: ' >&2; read p; {s} echo; printf 'GOT:%s:%s\\n' \"$u\" \"$p\"", .{ stty, stty });
    const argv = [_][]const u8{ test_env.shell(), "-c", cmd };
    var cfg = testCfg(&argv);
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    // Username with echo on (misc_conv PAM_PROMPT_ECHO_ON).
    const user = [_]struct { k: vt.Key, c: u8 }{
        .{ .k = .a, .c = 'a' }, .{ .k = .l, .c = 'l' }, .{ .k = .i, .c = 'i' },
        .{ .k = .c, .c = 'c' }, .{ .k = .e, .c = 'e' },
    };
    for (user) |key| try sendChar(s, key.k, key.c);
    try sendChar(s, .enter, null);
    _ = try pumpUntilText(&ts, "Password:", 5000);

    // Password with echo off (misc_conv PAM_PROMPT_ECHO_OFF): no echo comes
    // back, so only the child's own GOT line proves the keys arrived.
    const pass = [_]struct { k: vt.Key, c: u8 }{
        .{ .k = .f, .c = 'f' }, .{ .k = .o, .c = 'o' }, .{ .k = .o, .c = 'o' },
        .{ .k = .b, .c = 'b' }, .{ .k = .a, .c = 'a' }, .{ .k = .r, .c = 'r' },
    };
    for (pass) |key| try sendChar(s, key.k, key.c);
    try sendChar(s, .enter, null);
    _ = try pumpUntilText(&ts, "GOT:alice:foobar", 5000);
}

test "terminal: resize propagates to vt and pty winsize" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    try s.resize(100, 30);
    const ws = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 100), ws.cols);
    try testing.expectEqual(@as(u16, 30), ws.rows);
    try testing.expectEqual(@as(u16, 100), try ts.vt.cols());
    try testing.expectEqual(@as(u16, 30), try ts.vt.rows());
}

test "terminal: pty winsize reports pixel dimensions (kitten icat parity)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();

    // Spawn before any render: cell metrics unknown -> pixels 0, grid set.
    try s.start();
    const spawned = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 80), spawned.cols);
    try testing.expectEqual(@as(u16, 24), spawned.rows);
    try testing.expectEqual(@as(u16, 0), spawned.xpixel);
    try testing.expectEqual(@as(u16, 0), spawned.ypixel);

    // The first render carries real cell metrics: pixels = grid * cell
    // size, visible to the child through TIOCGWINSZ (plain `kitten icat`
    // reads exactly these fields).
    var mock = MockRenderer{ .allocator = testing.allocator };
    ts.setRenderer(mock.renderer());
    var fb = try render.Framebuffer.create(testing.allocator, 640, 384, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 80,
        .rows = 24,
    };
    try s.render(&ctx);
    const rendered = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 640), rendered.xpixel);
    try testing.expectEqual(@as(u16, 384), rendered.ypixel);

    // A session resize keeps the cell metrics and recomputes the pixels.
    try s.resize(100, 30);
    const resized = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 100), resized.cols);
    try testing.expectEqual(@as(u16, 30), resized.rows);
    try testing.expectEqual(@as(u16, 800), resized.xpixel);
    try testing.expectEqual(@as(u16, 480), resized.ypixel);
}

test "terminal: spawn-time winsize carries known cell pixels" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    // Metrics known before start (e.g. a respawn after a mode change):
    // the spawn-time winsize must carry them, not just the grid.
    ts.cell_w = 8;
    ts.cell_h = 16;
    const s = ts.session();
    try s.start();
    const ws = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 80), ws.cols);
    try testing.expectEqual(@as(u16, 24), ws.rows);
    try testing.expectEqual(@as(u16, 640), ws.xpixel);
    try testing.expectEqual(@as(u16, 384), ws.ypixel);
}

test "terminal: pixelExtent saturates at u16 and yields 0 for unknown cells" {
    try testing.expectEqual(@as(u16, 640), pixelExtent(80, 8));
    try testing.expectEqual(@as(u16, 384), pixelExtent(24, 16));
    try testing.expectEqual(@as(u16, 0), pixelExtent(80, 0));
    try testing.expectEqual(@as(u16, 0), pixelExtent(0, 16));
    try testing.expectEqual(@as(u16, 65535), pixelExtent(65535, 2));
    try testing.expectEqual(@as(u16, 65535), pixelExtent(4096, 16));
}

test "terminal: mode-change resize reflows the terminal grid (M2.5)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    // One 120-char line: at 80 columns it soft-wraps onto two rows, but
    // the full sequence is still contiguous in the row text only when the
    // grid is wide enough to hold it on one row.
    var long_buf: [120]u8 = undefined;
    for (&long_buf, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 10));
    const long: []const u8 = &long_buf;
    ts.vt.write(long);
    var buf: [8192]u8 = undefined;

    // A mode change narrows the grid: the session resize must reflow the
    // line through vt.resize (libghostty), not just report the new size.
    try s.resize(40, 24);
    try testing.expectEqual(@as(u16, 40), try ts.vt.cols());
    try testing.expectEqual(@as(u16, 24), try ts.vt.rows());
    const ws = try ts.pty.getWinsize();
    try testing.expectEqual(@as(u16, 40), ws.cols);
    try testing.expectEqual(@as(u16, 24), ws.rows);
    const narrow = try screenText(&ts, &buf);
    try testing.expect(std.mem.indexOf(u8, narrow, long) == null); // re-wrapped
    try testing.expect(std.mem.indexOf(u8, narrow, long[0..40]) != null);
    try testing.expect(std.mem.indexOf(u8, narrow, long[40..80]) != null);
    try testing.expect(std.mem.indexOf(u8, narrow, long[80..120]) != null);

    // Widening again reflows the soft-wrapped line back onto one row.
    try s.resize(120, 24);
    const wide = try screenText(&ts, &buf);
    try testing.expect(std.mem.indexOf(u8, wide, long) != null);
}

test "terminal: sb-size scrollback retained, not byte-pruned (M8.3)" {
    var cfg = testCfg(&.{test_env.shell()});
    cfg.sb_size = 4000;
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();

    // The byte budget must be sized to sb-size, not left at ghostty's
    // 10 KB default (which prunes history to ~one page regardless of the
    // line budget). Cells are 8 B in a ~512 KiB page, so sb_size*cols*16
    // is a generous ~2x provision.
    const budget = (try ts.vt.scrollbackMaxBytes()).?;
    try testing.expect(budget >= @as(usize, cfg.sb_size) * 80);

    // Push 2x sb_size lines straight into the vt (no pty child needed).
    // The LINE budget must govern retention: history stays near sb_size,
    // not the ~one page a 10 KB byte budget would leave.
    var i: usize = 0;
    while (i < 2 * @as(usize, cfg.sb_size)) : (i += 1) {
        var line: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&line, "line {d}\n", .{i});
        ts.vt.write(s);
    }
    const history = try ts.vt.scrollbackRows();
    // Line pruning is page-granular: history lands within one page below
    // sb_size. Half of sb_size is far above the ~one page the unfixed
    // 10 KB byte budget would retain.
    try testing.expect(history >= @as(usize, cfg.sb_size) / 2);
    try testing.expect(history <= @as(usize, cfg.sb_size));
}

/// The production playback sink shape (main.zig playbackWrite): raw
/// asciicast bytes go to the terminal emulator, never to the pty child.
fn playbackSink(ud: ?*anyopaque, bytes: []const u8) void {
    const ts: *TerminalSession = @ptrCast(@alignCast(ud.?));
    ts.vt.write(bytes);
}

test "terminal: asciicast playback renders into the terminal (M2.4)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/play.cast", .{tmp.sub_path[0..]});
    defer testing.allocator.free(path);
    const file =
        \\{"version":2,"width":80,"height":24}
        \\[0.0, "o", "hello asciicast"]
        \\
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "play.cast", .data = file });

    // Drive the Playback synchronously (the console arms a timer with the
    // returned delays; the write path is the one under test here).
    var pb = try asciicast.Playback.init(testing.allocator, path, false, playbackSink, &ts);
    defer pb.deinit();
    _ = pb.start();
    try testing.expectEqual(@as(?u64, null), pb.advance());

    var buf: [8192]u8 = undefined;
    const text = try screenText(&ts, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "hello asciicast") != null);
}

test "terminal: DA and size reports reply through write_pty" {
    // The replies go to the child's input; the default tty ECHOCTL echoes
    // them back to the master as "^["-prefixed text, which the vt renders.
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033[c\\033[18t'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    const text = try pumpUntilText(&ts, "?62;22;52c", 5000);
    try testing.expect(std.mem.indexOf(u8, text, "8;24;80t") != null);
}

test "terminal: effect replies drop on a full master instead of stalling" {
    // A child that never reads stdin fills the pty input queue; library
    // replies (DA1 here) must then be dropped, not polled: effWritePty
    // fires inside vt.write on the loop thread, so a bounded retry stalls
    // the whole console ~1 s per reply.
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    try ts.ensureBound();

    var p = try Pty.open(80, 24);
    errdefer p.deinit();
    try p.setNonBlocking(true);
    const slave = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        &p.slave_path,
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    );
    defer std.posix.close(slave);
    ts.pty = p;
    ts.active = true;
    p.master_fd = -1; // ownership moved to ts (deinit closes it)

    // Fill the slave input queue: nobody reads it.
    const fill: [4096]u8 = @splat('x');
    var full = false;
    for (0..64) |_| {
        _ = ts.pty.write(&fill) catch |err| switch (err) {
            error.WouldBlock => {
                full = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(full);

    const start = monotonicNs();
    ts.vt.write("\x1b[c"); // DA1: the reply goes through effWritePty
    const elapsed = monotonicNs() - start;
    try testing.expect(elapsed < 500 * std.time.ns_per_ms);
}

test "terminal: OSC52 clipboard set/get/clear in-process" {
    // Set "hello" (base64 aGVsbG8=) and read it back (reply echoed); the
    // clear is delayed with the bash builtin read -t so the set state is
    // observable before it arrives (no external sleep in the minimal PATH).
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033]52;c;aGVsbG8=\\007\\033]52;c;?\\007'; read -t 0.3 x; printf '\\033]52;c;\\007'" });
    defer cfg.deinit();
    cfg.clipboard_read = true;
    cfg.clipboard_write = true;
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    const text = try pumpUntilText(&ts, "aGVsbG8=", 5000);
    try testing.expect(std.mem.indexOf(u8, text, "52;c;aGVsbG8=") != null);
    try testing.expectEqualStrings("hello", ts.clipboardText(.standard));
    try testing.expectEqual(@as(usize, 0), ts.clipboardText(.primary).len);

    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.clipboardText(.standard).len == 0;
        }
    }.p, 5000);
}

test "terminal: OSC52 write denied by default" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033]52;c;aGVsbG8=\\007'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var hook_log = HookLog{};
    ts.hooks = hook_log.hooks();
    const s = ts.session();
    try s.start();
    try pumpUntil(&ts, &hook_log, struct {
        fn p(l: *HookLog, _: *TerminalSession) bool {
            return l.exits > 0;
        }
    }.p, 5000);
    try testing.expectEqual(@as(usize, 0), ts.clipboardText(.standard).len);
}

test "terminal: middle-click paste refuses unsafe text unless bracketed" {
    // Without mode 2004 the two-line clipboard must not reach the child;
    // with mode 2004 the same text pastes bracketed; the bracket
    // terminator itself is refused even then.
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'READY'; read -t 0.5 -N 3 x; printf 'GOT:%s' \"$x\"; printf '\\033[?2004h'; read -r -N 15 y; printf 'BRLEN:%s' \"${#y}\"; read -t 0.5 -N 1 z; printf 'END:%s' \"$z\"" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "READY", 5000);

    const primary = &ts.clipboard[@intFromEnum(vt.ClipboardLocation.primary)];
    try primary.appendSlice(testing.allocator, "a\nb");

    // Unbracketed: refused, the child's read times out empty.
    try sendButton(s, 0x112, true, 4, 8, 1);
    const text = try pumpUntilText(&ts, "GOT:", 5000);
    try testing.expect(std.mem.indexOf(u8, text, "GOT:a") == null);

    // Bracketed: the same two lines arrive framed (6 + 3 + 6 bytes).
    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.vt.getMode(vt.mode(2004, false)) catch false;
        }
    }.p, 5000);
    try sendButton(s, 0x112, true, 4, 8, 1);
    _ = try pumpUntilText(&ts, "BRLEN:15", 5000);

    // The bracket terminator escapes the framing: refused even bracketed.
    primary.clearRetainingCapacity();
    try primary.appendSlice(testing.allocator, "a\x1b[201~b");
    try sendButton(s, 0x112, true, 4, 8, 1);
    const end = try pumpUntilText(&ts, "END:", 5000);
    try testing.expect(std.mem.indexOf(u8, end, "END:a") == null);
}

test "terminal: private OSC setBackground/setForeground hooks, no reply" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033]setBackground\\a\\033]setForeground\\033\\\\\\033]setBackground;\\a\\033]setbackground\\a'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    try pumpUntil(&ts, &log, struct {
        fn p(l: *HookLog, _: *TerminalSession) bool {
            return l.backgrounds == 1 and l.foregrounds == 1;
        }
    }.p, 5000);
    // Let any (wrong) reply or the non-matching variants arrive.
    sleepMs(100);
    _ = try ts.onPtyReadable();
    try testing.expectEqual(@as(u32, 1), log.backgrounds);
    try testing.expectEqual(@as(u32, 1), log.foregrounds);
    // No reply and no visible output: the screen stays blank.
    var buf: [8192]u8 = undefined;
    const text = try screenText(&ts, &buf);
    try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, text, "\n").len);
}

test "terminal: oneshot stops the session when the child exits" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "exit 3" });
    cfg.oneshot = true;
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    try pumpUntil(&ts, {}, inactivePred, 5000);
    try testing.expect(!s.isActive());
    try testing.expectEqual(@as(u32, 1), log.exits);
    try testing.expectEqual(Pty.ReapStatus{ .exited = 3 }, log.last_exit.?);
    try testing.expectEqual(@as(std.posix.fd_t, -1), ts.masterFd());
    // stop is a no-op when already inactive.
    try s.stop();
}

test "terminal: reset-env clears the parent environment" {
    try testing.expectEqual(@as(c_int, 0), setenv("KMSHAUNT_ENV_PROBE", "parent", 1));
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '[%s] %s:%s' \"${KMSHAUNT_ENV_PROBE:-UNSET}\" \"$XDG_SEAT\" \"$XDG_VTNR\"" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    ts.seat_name = "seat0";
    ts.vt_nr = 2;
    const s = ts.session();
    try s.start();

    const text = try pumpUntilText(&ts, "[UNSET]", 5000);
    try testing.expect(std.mem.indexOf(u8, text, "seat0:2") != null);
}

test "terminal: no-reset-env inherits the parent environment" {
    try testing.expectEqual(@as(c_int, 0), setenv("KMSHAUNT_ENV_PROBE", "parent", 1));
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '[%s]' \"${KMSHAUNT_ENV_PROBE:-UNSET}\"" });
    cfg.reset_env = false;
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    _ = try pumpUntilText(&ts, "[parent]", 5000);
}

test "terminal: title, pwd, bell hook and RIS clear" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033]0;My Title\\a\\033]7;file://h/tmp\\a\\a\\033c'" });
    cfg.bell = true;
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    try pumpUntil(&ts, &log, struct {
        fn p(l: *HookLog, _: *TerminalSession) bool {
            return l.bells == 1;
        }
    }.p, 5000);
    // RIS (ESC c) follows the bell in the same stream; wait for the clear.
    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.title().len == 0;
        }
    }.p, 5000);
    try testing.expectEqual(@as(usize, 0), ts.pwd().len);
}

test "terminal: bell gated off by cfg.bell" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'x\\ay'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    _ = try pumpUntilText(&ts, "xy", 5000);
    try testing.expectEqual(@as(u32, 0), log.bells);
}

test "terminal: grab events reach the hook" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "exit 0" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var log = HookLog{};
    ts.hooks = log.hooks();
    const s = ts.session();
    try s.start();

    try s.onInput(.{ .grab = .{ .id = 7 } });
    try testing.expectEqual(@as(u32, 1), log.grabs);
    try testing.expectEqual(@as(u16, 7), log.last_grab);
}

/// Mock renderer: records calls/opts, paints one pixel, appends one rect.
const MockRenderer = struct {
    allocator: std.mem.Allocator,
    rendered: u32 = 0,
    resizes: u32 = 0,
    grid: ?struct { cols: u16, rows: u16, cell_w: u16, cell_h: u16 } = null,
    last_opts: ?render.RenderOpts = null,

    fn renderer(self: *MockRenderer) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = render.Renderer.VTable{
        .deinit = vtDeinit,
        .resize = vtResize,
        .renderFrame = vtRenderFrame,
    };
    fn cast(ptr: *anyopaque) *MockRenderer {
        return @ptrCast(@alignCast(ptr));
    }
    fn vtDeinit(_: *anyopaque) void {}
    fn vtResize(ptr: *anyopaque, cols: u16, rows: u16, cw: u16, ch: u16) anyerror!void {
        const m = cast(ptr);
        m.resizes += 1;
        m.grid = .{ .cols = cols, .rows = rows, .cell_w = cw, .cell_h = ch };
    }
    fn vtRenderFrame(
        ptr: *anyopaque,
        state: *const anyopaque,
        fb: *render.Framebuffer,
        damage: *render.DamageList,
        opts: render.RenderOpts,
    ) anyerror!void {
        const m = cast(ptr);
        m.rendered += 1;
        m.last_opts = opts;
        // The opaque state must be the session's RenderState.
        const rs: *vt.RenderState = @ptrCast(@alignCast(@constCast(state)));
        try testing.expect((rs.cols() catch 0) != 0);
        fb.set(0, 0, opts.default_fg);
        try damage.append(m.allocator, .{ .x = 0, .y = 0, .w = opts.palette[0], .h = 1 });
    }
};

test "terminal: render delegates to the injected renderer with damage" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'x'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    ts.setRenderer(mock.renderer());
    const s = ts.session();
    try s.start();
    _ = try pumpUntilText(&ts, "x", 5000);

    var fb = try render.Framebuffer.create(testing.allocator, 640, 384, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 80,
        .rows = 24,
    };
    try s.render(&ctx);
    try testing.expectEqual(@as(u32, 1), mock.rendered);
    try testing.expectEqual(@as(u32, 1), mock.resizes);
    try testing.expectEqual(@as(u16, 8), mock.grid.?.cell_w);
    try testing.expectEqual(@as(usize, 1), damage.items.len);
    try testing.expectEqual(mock.last_opts.?.default_fg, fb.get(0, 0));
    try testing.expectEqual(@as(u8, 255), mock.last_opts.?.bg_opacity);
    try testing.expect(mock.last_opts.?.cursor_visible);

    // Second frame: renderer still called, damage accumulates.
    try s.render(&ctx);
    try testing.expectEqual(@as(u32, 2), mock.rendered);
    try testing.expectEqual(@as(usize, 2), damage.items.len);

    // Synchronized output (mode 2026) defers presentation.
    ts.vt.write("\x1b[?2026h");
    try testing.expect(ts.render_held);
    try s.render(&ctx);
    try testing.expectEqual(@as(u32, 2), mock.rendered);
    ts.vt.write("\x1b[?2026l");
    try testing.expect(!ts.render_held);
    try s.render(&ctx);
    try testing.expectEqual(@as(u32, 3), mock.rendered);
}

test "terminal: render without a renderer is an error" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "exit 0" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    const s = ts.session();
    try s.start();

    var fb = try render.Framebuffer.create(testing.allocator, 64, 48, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 80,
        .rows = 24,
    };
    try testing.expectError(error.NoRenderer, s.render(&ctx));
}

test "terminal: mouse reporting routes button events to the encoder" {
    // bash builtin read -N 6 consumes exactly one X10 press report
    // (ESC [ M b x y); the trailing Enter completes the canonical line.
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033[?1000h'; read -r -N 6 x; printf 'MOUSE_OK'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    ts.setRenderer(mock.renderer());
    const s = ts.session();
    try s.start();

    // Establish cell geometry the way main.zig does (first render).
    var fb = try render.Framebuffer.create(testing.allocator, 640, 384, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 80,
        .rows = 24,
    };
    try s.render(&ctx);

    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.vt.mouseTracking() catch false;
        }
    }.p, 5000);
    try s.onInput(.{ .pointer_button = .{
        .button = 0x110,
        .pressed = true,
        .x = 4,
        .y = 8,
        .click_count = 1,
    } });
    try sendChar(s, .enter, null);
    _ = try pumpUntilText(&ts, "MOUSE_OK", 5000);
}

// -- M2.3: selection, copy/paste, wheel scroll -----------------------------

var fake_clock_ns: u64 = 0;
fn fakeNowNs() u64 {
    return fake_clock_ns;
}

/// Establish 8x16 cell geometry through a render, the way main.zig's
/// first frame does. The mock stays borrowed by the session, so the
/// caller owns it.
fn renderGeometry(ts: *TerminalSession, s: sess.Session, mock: *MockRenderer) !void {
    ts.setRenderer(mock.renderer());
    var fb = try render.Framebuffer.create(testing.allocator, 640, 384, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 8,
        .cell_h = 16,
        .cols = 80,
        .rows = 24,
    };
    try s.render(&ctx);
}

fn sendButton(s: sess.Session, button: u32, pressed: bool, x: f64, y: f64, count: u8) !void {
    try s.onInput(.{ .pointer_button = .{
        .button = button,
        .pressed = pressed,
        .x = x,
        .y = y,
        .click_count = count,
    } });
}

fn sendMotion(s: sess.Session, x: f64, y: f64) !void {
    try s.onInput(.{ .pointer_motion = .{ .dx = 0, .dy = 0, .absolute = false, .x = x, .y = y } });
}

fn sendAxis(s: sess.Session, dy: f64) !void {
    try s.onInput(.{ .pointer_axis = .{ .dx = 0, .dy = dy } });
}

test "terminal: drag selection installs, copies on release, right-click clears" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello world'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "hello world", 5000);

    // Motion without a press never selects.
    try sendMotion(s, 20, 8);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());

    // Press in cell 0: single click, no selection until the first drag.
    try sendButton(s, 0x110, true, 4, 8, 1);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());
    // Drag to cell 4 (x=39 crosses the ~60% inclusion threshold).
    try sendMotion(s, 39, 8);
    try testing.expect((try ts.vt.selection()) != null);
    try testing.expect(ts.selecting);
    // Release copies "hello" into both clipboard locations.
    try sendButton(s, 0x110, false, 39, 8, 1);
    try testing.expect(!ts.selecting);
    try testing.expectEqualStrings("hello", ts.clipboardText(.primary));
    try testing.expectEqualStrings("hello", ts.clipboardText(.standard));

    // Right press clears the selection (kmscon parity).
    try sendButton(s, 0x111, true, 39, 8, 1);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());
}

test "terminal: double-click selects word, triple-click selects line" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello world'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "hello world", 5000);
    fake_clock_ns = 0;
    ts.now_ns = fakeNowNs;

    // Single click on cell 1: no selection.
    try sendButton(s, 0x110, true, 12, 8, 1);
    try sendButton(s, 0x110, false, 12, 8, 1);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());

    // Second press within the 400 ms window: word, copied at once.
    fake_clock_ns = 100 * std.time.ns_per_ms;
    try sendButton(s, 0x110, true, 12, 8, 2);
    try testing.expect((try ts.vt.selection()) != null);
    try testing.expectEqualStrings("hello", ts.clipboardText(.primary));
    try sendButton(s, 0x110, false, 12, 8, 2);

    // Third press: the whole line.
    fake_clock_ns = 200 * std.time.ns_per_ms;
    try sendButton(s, 0x110, true, 12, 8, 3);
    try testing.expectEqualStrings("hello world", ts.clipboardText(.primary));
    try sendButton(s, 0x110, false, 12, 8, 3);

    // After the window expires a press is single again: selection cleared.
    fake_clock_ns = 700 * std.time.ns_per_ms;
    try sendButton(s, 0x110, true, 12, 8, 1);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());
    try sendButton(s, 0x110, false, 12, 8, 1);
}

test "terminal: middle-click pastes clipboard, bracketed under mode 2004" {
    // First paste is plain (5 bytes "hello"); the child then enables
    // bracketed paste and the second paste arrives framed (6+5+6 bytes).
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello world'; read -r -N 5 a; printf 'P1'; printf '\\033[?2004h'; read -r -N 17 b; printf 'P2'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "hello world", 5000);

    // Select "hello" and release -> clipboard.
    try sendButton(s, 0x110, true, 4, 8, 1);
    try sendMotion(s, 39, 8);
    try sendButton(s, 0x110, false, 39, 8, 1);
    try testing.expectEqualStrings("hello", ts.clipboardText(.primary));

    // Middle press pastes plain "hello" and clears the selection.
    try sendButton(s, 0x112, true, 4, 8, 1);
    _ = try pumpUntilText(&ts, "P1", 5000);
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());

    // Wait for mode 2004 to arrive, then paste again: bracketed.
    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.vt.getMode(vt.mode(2004, false)) catch false;
        }
    }.p, 5000);
    try sendButton(s, 0x112, true, 4, 8, 1);
    _ = try pumpUntilText(&ts, "P2", 5000);
}

test "terminal: wheel scrolls the viewport when not tracking" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "i=0; while [ $i -lt 60 ]; do printf 'line %s\\n' \"$i\"; i=$((i+1)); done" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "line 59", 5000);

    const bottom = try ts.vt.scrollbar();
    try testing.expectEqual(bottom.total, bottom.offset + bottom.len);
    // One detent up = 3 lines (kmscon), one detent down returns.
    try sendAxis(s, -15);
    try testing.expectEqual(bottom.offset - 3, (try ts.vt.scrollbar()).offset);
    try sendAxis(s, 15);
    try testing.expectEqual(bottom.offset, (try ts.vt.scrollbar()).offset);
    // Fractional finger scrolls accumulate: 5 x -2 units = -2 lines.
    for (0..5) |_| try sendAxis(s, -2);
    try testing.expectEqual(bottom.offset - 2, (try ts.vt.scrollbar()).offset);
}

test "terminal: enabling mouse tracking drops the selection" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello world'" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "hello world", 5000);

    try sendButton(s, 0x110, true, 4, 8, 1);
    try sendMotion(s, 39, 8);
    try testing.expect((try ts.vt.selection()) != null);

    // The program enables tracking; the next pump drops the selection.
    ts.vt.write("\x1b[?1000h");
    _ = try ts.onPtyReadable();
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());
    try testing.expect(!ts.selecting);
}

test "terminal: key events clear the selection" {
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf 'hello world'; read x" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    _ = try pumpUntilText(&ts, "hello world", 5000);

    try sendButton(s, 0x110, true, 4, 8, 1);
    try sendMotion(s, 39, 8);
    try sendButton(s, 0x110, false, 39, 8, 1);
    try testing.expect((try ts.vt.selection()) != null);

    try sendChar(s, .a, 'a');
    try testing.expectEqual(@as(?vt.Selection, null), try ts.vt.selection());
}

test "terminal: mouse reporting SGR format, motion filtered in normal mode" {
    // Mode 1000 (normal) + 1006 (SGR): motion is not reported, so the
    // first 9 bytes the child reads are the press report ESC[<0;1;1M.
    // The case statement matches the raw bytes (the vt would swallow the
    // CSI if it were printed back).
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033[?1000h\\033[?1006h'; read -r -N 9 x; case \"$x\" in *'0;1;1M') printf SGR_OK;; *) printf SGR_BAD;; esac" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.vt.mouseTracking() catch false;
        }
    }.p, 5000);

    try sendMotion(s, 20, 20);
    try sendButton(s, 0x110, true, 4, 8, 1);
    _ = try pumpUntilText(&ts, "SGR_OK", 5000);
}

test "terminal: side buttons report as extended buttons, not the wheel" {
    // BTN_SIDE -> ghostty .eight -> xterm extended code 128 (NOT wheel
    // 64/65). SGR press report is ESC[<128;1;1M = 11 bytes.
    var cfg = testCfg(&.{ test_env.shell(), "-c", "printf '\\033[?1000h\\033[?1006h'; read -r -N 11 x; case \"$x\" in *'128;1;1M') printf SIDE_OK;; *) printf SIDE_BAD;; esac" });
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    const s = ts.session();
    try s.start();
    try renderGeometry(&ts, s, &mock);
    try pumpUntil(&ts, {}, struct {
        fn p(_: void, t: *TerminalSession) bool {
            return t.vt.mouseTracking() catch false;
        }
    }.p, 5000);

    try sendButton(s, 0x113, true, 4, 8, 1); // BTN_SIDE
    _ = try pumpUntilText(&ts, "SIDE_OK", 5000);
}

test "terminal: init applies the configured preset palette (M2.4)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    cfg.palette = .solarized;
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();

    try ts.render_state.update(&ts.vt);
    const colors = try ts.render_state.colors();
    const want = palette.Preset.solarized.get();
    for (0..16) |i| {
        try testing.expectEqual(want[i].r, colors.palette[i].r);
        try testing.expectEqual(want[i].g, colors.palette[i].g);
        try testing.expectEqual(want[i].b, colors.palette[i].b);
    }
    try testing.expectEqual(want[16].r, colors.foreground.r);
    try testing.expectEqual(want[16].g, colors.foreground.g);
    try testing.expectEqual(want[16].b, colors.foreground.b);
    try testing.expectEqual(want[17].r, colors.background.r);
    try testing.expectEqual(want[17].g, colors.background.g);
    try testing.expectEqual(want[17].b, colors.background.b);
    // Slots 16..255 keep the standard xterm extension.
    try testing.expectEqual(@as(u8, 255), colors.palette[196].r);
    try testing.expectEqual(@as(u8, 0), colors.palette[196].g);
    try testing.expectEqual(@as(u8, 0), colors.palette[196].b);
    try testing.expectEqual(@as(u8, 8), colors.palette[232].r);

    // An OSC 4 override applies on top; RIS restores the configured
    // palette (it is the terminal default, not an override).
    ts.vt.write("\x1b]4;1;rgb:ff/ff/ff\x07");
    try ts.render_state.update(&ts.vt);
    const overridden = try ts.render_state.colors();
    try testing.expectEqual(@as(u8, 255), overridden.palette[1].r);
    ts.vt.reset();
    try ts.render_state.update(&ts.vt);
    const after = try ts.render_state.colors();
    try testing.expectEqual(want[1].r, after.palette[1].r);
    try testing.expectEqual(want[1].g, after.palette[1].g);
    try testing.expectEqual(want[1].b, after.palette[1].b);
}

test "terminal: custom palette overrides reach the terminal (M2.4)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    cfg.palette = .custom;
    cfg.custom_palette[1] = .{ .r = 10, .g = 20, .b = 30 };
    cfg.custom_palette[16] = .{ .r = 200, .g = 201, .b = 202 };
    cfg.custom_palette[17] = .{ .r = 40, .g = 50, .b = 60 };
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();

    try ts.render_state.update(&ts.vt);
    const colors = try ts.render_state.colors();
    try testing.expectEqual(@as(u8, 10), colors.palette[1].r);
    try testing.expectEqual(@as(u8, 20), colors.palette[1].g);
    try testing.expectEqual(@as(u8, 30), colors.palette[1].b);
    try testing.expectEqual(@as(u8, 200), colors.foreground.r);
    try testing.expectEqual(@as(u8, 201), colors.foreground.g);
    try testing.expectEqual(@as(u8, 202), colors.foreground.b);
    try testing.expectEqual(@as(u8, 40), colors.background.r);
    try testing.expectEqual(@as(u8, 50), colors.background.g);
    try testing.expectEqual(@as(u8, 60), colors.background.b);
    // Untouched slots keep the custom base (== legacy).
    try testing.expectEqual(@as(u8, 205), colors.palette[3].r);
}

test "terminal: unset palette falls back to legacy (M2.4)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();

    try ts.render_state.update(&ts.vt);
    const colors = try ts.render_state.colors();
    const want = palette.Preset.legacy.get();
    for (0..16) |i| {
        try testing.expectEqual(want[i].r, colors.palette[i].r);
        try testing.expectEqual(want[i].g, colors.palette[i].g);
        try testing.expectEqual(want[i].b, colors.palette[i].b);
    }
    try testing.expectEqual(want[16].r, colors.foreground.r);
    try testing.expectEqual(want[17].r, colors.background.r);
}

test "terminal: render passes the blink phase for cursor and text blink (M2.4)" {
    var cfg = testCfg(&.{test_env.shell()});
    defer cfg.deinit();
    var ts = try TerminalSession.init(testing.allocator, &cfg, 80, 24);
    defer ts.deinit();
    var mock = MockRenderer{ .allocator = testing.allocator };
    ts.setRenderer(mock.renderer());

    var fb = try render.Framebuffer.create(testing.allocator, 64, 48, .xrgb8888, null);
    defer fb.destroy(testing.allocator);
    var damage: render.DamageList = .empty;
    defer damage.deinit(testing.allocator);
    // Zero cell metrics match the pre-first-render session geometry, so
    // no resize round-trip interferes.
    const ctx = sess.RenderContext{
        .fb = &fb,
        .damage = &damage,
        .cell_w = 0,
        .cell_h = 0,
        .cols = 80,
        .rows = 24,
    };
    const s = ts.session();

    // A steady cursor (DECSCUSR 2) must not gate the phase: SGR text
    // blink needs it even when the cursor does not blink.
    ts.vt.write("\x1b[2 q");
    ts.blink_phase = false;
    try s.render(&ctx);
    try testing.expectEqual(@as(?bool, false), mock.last_opts.?.cursor_blink_on);
    ts.blink_phase = true;
    try s.render(&ctx);
    try testing.expectEqual(@as(?bool, true), mock.last_opts.?.cursor_blink_on);

    // cfg.blink off: no phase (everything steady).
    cfg.blink = false;
    try s.render(&ctx);
    try testing.expectEqual(@as(?bool, null), mock.last_opts.?.cursor_blink_on);
}
