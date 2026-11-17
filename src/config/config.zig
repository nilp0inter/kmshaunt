//! kmshaunt configuration — kmscon-compatible CLI + config-file parser
//! (ROADMAP D5/M7.1). Spec: `docs/reference/kmscon-options.md`, verified
//! against kmscon 10.1.0 `src/config.c` and `src/misc/conf.c`.
//!
//! Layout:
//!   * `Config` — one typed field per option (all 92), exact kmscon
//!     defaults except the two deliberate kmshaunt deviations:
//!     `configdir = /etc/kmshaunt` and `term = xterm-ghostty` (ROADMAP D6).
//!   * `parseCli` — `--name value`, `--name=value`, `--no-name` negation,
//!     the six documented short forms (`-h -V -v -c -l -t`, bundling and
//!     attached values included), `--` login-argv semantics.
//!   * `parseFileText` — kmscon conf.c line syntax: `key` / `key=value`,
//!     `#` comments, `no-` negation, space/CR/tab stripping.
//!   * `load` / `loadSeat` — discovery (`<configdir>/kmshaunt.conf`,
//!     `<configdir>/<seat>.seat.conf`) with kmscon precedence:
//!     defaults < CLI (CONF_LOCKED) < main file < seat file.
//!   * Grabs, modes/screens, login shell-splitting and the keysym table
//!     live in the sibling modules; palette presets live in the canonical
//!     `src/misc/palette.zig`.
//!
//! Deliberate deviations from kmscon (assignment requirements, see the
//! module report): unknown/invalid CLI options are typed errors instead
//! of warn-and-ignore; uint values are strictly parsed with u32 bounds
//! instead of kmscon's `atoi`; file keys without a value and bool keys
//! with a value abort the load, as documented in kmscon-options.md §3.
//!
//! All dynamic values are owned by an arena inside `Config`; `deinit`
//! releases everything. Errors are typed (`diag.Error`) and the failing
//! option is named in `Config.error_message`.

const std = @import("std");

pub const diag = @import("diag.zig");
pub const Error = diag.Error;
pub const Diag = diag.Diag;
pub const grab = @import("grab.zig");
pub const display = @import("display.zig");
pub const shell = @import("shell.zig");
pub const keysyms = @import("keysyms.zig");
pub const palette = @import("../misc/palette.zig");

pub const Grab = grab.Grab;
pub const Mode = display.Mode;
pub const Screen = display.Screen;
pub const Orientation = display.Orientation;

/// kmshaunt config directory (kmscon: BUILD_CONFIG_DIR = /etc/kmscon).
pub const default_configdir = "/etc/kmshaunt";
/// ROADMAP D6: deliberate deviation from kmscon's `kmscon` default.
pub const default_term = "xterm-ghostty";
/// kmscon ISSUE_DEFAULT_PATH (misc/issue.h:20-24).
pub const default_issue_path =
    "/etc/issue:/etc/issue.d:/run/issue:/run/issue.d:/usr/lib/issue:/usr/lib/issue.d";
/// kmscon def_argv (config.c:334).
pub const default_login_argv = [_][]const u8{ "/bin/login", "-p" };

/// `--gpus` selection (config.c:466-498). `auxiliary` aliases `aux`,
/// `single` aliases `primary`; anything else is an error.
pub const Gpus = enum {
    all,
    primary,
    aux,

    pub fn parse(s: []const u8, d: *Diag) Error!Gpus {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "aux") or std.mem.eql(u8, s, "auxiliary")) return .aux;
        if (std.mem.eql(u8, s, "primary") or std.mem.eql(u8, s, "single")) return .primary;
        d.print("invalid GPU selection mode '{s}'", .{s});
        return error.InvalidValue;
    }
};

/// `--font-engine` backends. `pango` is an alias of `freetype` (ROADMAP
/// D7). Unknown names yield null: kmscon falls back to the backend chain
/// `freetype → pango → unifont → psf → 8x16` (font/font.c:219).
pub const FontEngine = enum {
    freetype,
    psf,
    unifont,
    @"8x16",

    pub fn parse(s: []const u8) ?FontEngine {
        if (std.mem.eql(u8, s, "freetype") or std.mem.eql(u8, s, "pango")) return .freetype;
        if (std.mem.eql(u8, s, "psf")) return .psf;
        if (std.mem.eql(u8, s, "unifont")) return .unifont;
        if (std.mem.eql(u8, s, "8x16")) return .@"8x16";
        return null;
    }
};

/// `--multi-monitor` (terminal.c:752-757): default `scaled`; `largest`
/// and `scaled` are recognized, ANY other value (including `clone`)
/// behaves as clone.
pub const MultiMonitor = enum {
    clone,
    largest,
    scaled,

    pub fn parse(s: []const u8) MultiMonitor {
        if (std.mem.eql(u8, s, "largest")) return .largest;
        if (std.mem.eql(u8, s, "scaled")) return .scaled;
        return .clone;
    }
};

/// ghostty `alpha-blending` (Config.zig:9876-9887). The Linux default is
/// linear-corrected (Config.zig:408-412); macOS defaults to native.
pub const AlphaBlending = enum {
    native,
    linear,
    @"linear-corrected",

    pub fn parse(s: []const u8, d: *Diag) Error!AlphaBlending {
        return std.meta.stringToEnum(AlphaBlending, s) orelse {
            d.print("invalid alpha-blending mode '{s}'", .{s});
            return error.InvalidValue;
        };
    }
};

/// ghostty `freetype-load-flags` (Config.zig:9912-9924). Defaults match
/// FreeType itself; `light` is the Fontconfig-world default. Parse per
/// Config.zig:517-521: comma list, `no-` disables, omitted flags keep
/// their default, `true`/`false` set ALL flags.
pub const FreetypeLoadFlags = packed struct {
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
    light: bool = true,

    pub fn parse(s: []const u8, d: *Diag) Error!FreetypeLoadFlags {
        var out: FreetypeLoadFlags = .{};
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (std.mem.eql(u8, tok, "true")) {
                out = .{ .hinting = true, .@"force-autohint" = true, .monochrome = true, .autohint = true, .light = true };
                continue;
            }
            if (std.mem.eql(u8, tok, "false")) {
                out = .{ .hinting = false, .@"force-autohint" = false, .monochrome = false, .autohint = false, .light = false };
                continue;
            }
            const neg = std.mem.startsWith(u8, tok, "no-");
            const name = if (neg) tok[3..] else tok;
            const on = !neg;
            if (std.mem.eql(u8, name, "hinting")) out.hinting = on
            else if (std.mem.eql(u8, name, "force-autohint")) out.@"force-autohint" = on
            else if (std.mem.eql(u8, name, "monochrome")) out.monochrome = on
            else if (std.mem.eql(u8, name, "autohint")) out.autohint = on
            else if (std.mem.eql(u8, name, "light")) out.light = on
            else {
                d.print("unknown freetype load flag '{s}'", .{tok});
                return error.InvalidValue;
            }
        }
        return out;
    }
};

/// ghostty font/Metrics.zig:454-479: a DELTA, not a target value.
/// "20%" -> percent multiplier 1.2 (20% LARGER); "2" -> absolute +2 px.
/// percent <= -100% clamps to multiplier 0 (:470). No range validation
/// (Config.zig:422-423 "little to no validation"). Used by the ghostty
/// cursor/underline adjust-* knobs; the kmscon adjust-cell-* trio keeps
/// its i32-percent path.
pub const MetricModifier = union(enum) {
    percent: f64,
    absolute: i32,

    pub fn parse(s: []const u8, d: *Diag) Error!MetricModifier {
        if (s.len == 0) {
            d.print("empty metric modifier", .{});
            return error.InvalidValue;
        }
        if (s[s.len - 1] == '%') {
            var p = std.fmt.parseFloat(f64, s[0 .. s.len - 1]) catch {
                d.print("cannot parse percent value '{s}'", .{s});
                return error.InvalidValue;
            };
            p /= 100;
            return .{ .percent = if (p <= -1) 0 else 1 + p };
        }
        const v = std.fmt.parseInt(i32, s, 10) catch {
            d.print("cannot parse metric modifier '{s}'", .{s});
            return error.InvalidValue;
        };
        return .{ .absolute = v };
    }

    /// Port of ghostty font/Metrics.zig:515-547 (integer targets):
    /// percent = round(v * max(0, p)); absolute = saturating add,
    /// unsigned targets clamped at 0, overflow -> maxInt * sign.
    pub fn apply(self: MetricModifier, v: anytype) @TypeOf(v) {
        const T = @TypeOf(v);
        return switch (self) {
            .percent => |p| @intFromFloat(@round(@as(f64, @floatFromInt(v)) * @max(0, p))),
            .absolute => |a| blk: {
                const sum = @as(i64, v) +| @as(i64, a);
                const clamped = if (@typeInfo(T).@"int".signedness == .unsigned) @max(0, sum) else sum;
                break :blk std.math.cast(T, clamped) orelse
                    std.math.maxInt(T) * @as(T, @intCast(std.math.sign(clamped)));
            },
        };
    }
};

/// ghostty `cursor-style` (Config.zig:883 + terminal/cursor.zig:9-25,
/// names exact). The DEFAULT style; DECSCUSR overrides at runtime.
pub const CursorStyle = enum {
    block,
    bar,
    underline,
    block_hollow,

    pub fn parse(s: []const u8, d: *Diag) Error!CursorStyle {
        return std.meta.stringToEnum(CursorStyle, s) orelse {
            d.print("invalid cursor style '{s}'", .{s});
            return error.InvalidValue;
        };
    }
};

/// Every option, in kmscon option-table order (config.c:981-1088).
/// The order matters: afterchecks run in this order.
pub const Option = enum {
    // Global
    help,
    version,
    verbose,
    debug,
    silent,
    configdir,
    // Seat
    vt,
    switchvt,
    libseat,
    // Session
    session_max,
    session_control,
    // Terminal
    issue,
    issue_path,
    asciicast,
    asciicast_loop,
    login,
    oneshot,
    term,
    reset_env,
    backspace_delete,
    sb_size,
    bell,
    blink,
    kitty_image_storage_limit,
    clipboard_read,
    clipboard_write,
    gui_osc,
    // Input
    xkb_model,
    xkb_layout,
    xkb_variant,
    xkb_options,
    xkb_keymap,
    xkb_compose_file,
    xkb_repeat_delay,
    xkb_repeat_rate,
    mouse,
    natural_scrolling,
    soft_cursor,
    dpms_timeout,
    // Grabs
    grab_scroll_up,
    grab_scroll_down,
    grab_page_up,
    grab_page_down,
    grab_zoom_in,
    grab_zoom_out,
    grab_session_next,
    grab_session_prev,
    grab_session_close,
    grab_terminal_new,
    grab_rotate_cw,
    grab_rotate_ccw,
    grab_reboot,
    // Video
    drm,
    hwaccel,
    gpus,
    use_original_mode,
    mode,
    multi_monitor,
    screen,
    // Font
    font_engine,
    font_size,
    font_name,
    adjust_cell_width,
    adjust_cell_height,
    adjust_font_baseline,
    // Ghostty rendering parity (v1.4.0 defaults)
    alpha_blending,
    freetype_load_flags,
    font_thicken,
    font_thicken_strength,
    adjust_cursor_thickness,
    adjust_cursor_height,
    adjust_underline_position,
    cursor_style,
    // Palette
    palette,
    palette_black,
    palette_red,
    palette_green,
    palette_yellow,
    palette_blue,
    palette_magenta,
    palette_cyan,
    palette_light_grey,
    palette_dark_grey,
    palette_light_red,
    palette_light_green,
    palette_light_yellow,
    palette_light_blue,
    palette_light_magenta,
    palette_light_cyan,
    palette_white,
    palette_foreground,
    palette_background,
};

pub const Kind = enum {
    bool,
    uint,
    string,
    vt,
    login,
    gpus,
    mode,
    screen,
    color,
    grab,
    font_engine,
    multi_monitor,
    palette,
    percent,
    metric,
    alpha_blending,
    freetype_load_flags,
    cursor_style,
    u8,

    /// Whether the option takes a value. `login` is a no-arg (bool-like)
    /// option on the CLI; in a file it requires a value (file_login).
    pub fn hasArg(self: Kind) bool {
        return switch (self) {
            .bool, .login => false,
            else => true,
        };
    }
};

const Spec = struct {
    opt: Option,
    name: []const u8,
    short: u8 = 0,
    kind: Kind,
    color: palette.ColorName = .black,
};

/// The option registry, indexed by `@intFromEnum(Option)`.
const specs = [_]Spec{
    .{ .opt = .help, .name = "help", .short = 'h', .kind = .bool },
    .{ .opt = .version, .name = "version", .short = 'V', .kind = .bool },
    .{ .opt = .verbose, .name = "verbose", .short = 'v', .kind = .bool },
    .{ .opt = .debug, .name = "debug", .kind = .bool },
    .{ .opt = .silent, .name = "silent", .kind = .bool },
    .{ .opt = .configdir, .name = "configdir", .short = 'c', .kind = .string },
    .{ .opt = .vt, .name = "vt", .kind = .vt },
    .{ .opt = .switchvt, .name = "switchvt", .kind = .bool },
    .{ .opt = .libseat, .name = "libseat", .kind = .bool },
    .{ .opt = .session_max, .name = "session-max", .kind = .uint },
    .{ .opt = .session_control, .name = "session-control", .kind = .bool },
    .{ .opt = .issue, .name = "issue", .kind = .bool },
    .{ .opt = .issue_path, .name = "issue-path", .kind = .string },
    .{ .opt = .asciicast, .name = "asciicast", .kind = .string },
    .{ .opt = .asciicast_loop, .name = "asciicast-loop", .kind = .bool },
    .{ .opt = .login, .name = "login", .short = 'l', .kind = .login },
    .{ .opt = .oneshot, .name = "oneshot", .kind = .bool },
    .{ .opt = .term, .name = "term", .short = 't', .kind = .string },
    .{ .opt = .reset_env, .name = "reset-env", .kind = .bool },
    .{ .opt = .backspace_delete, .name = "backspace-delete", .kind = .bool },
    .{ .opt = .sb_size, .name = "sb-size", .kind = .uint },
    .{ .opt = .bell, .name = "bell", .kind = .bool },
    .{ .opt = .blink, .name = "blink", .kind = .bool },
    .{ .opt = .kitty_image_storage_limit, .name = "kitty-image-storage-limit", .kind = .uint },
    .{ .opt = .clipboard_read, .name = "clipboard-read", .kind = .bool },
    .{ .opt = .clipboard_write, .name = "clipboard-write", .kind = .bool },
    .{ .opt = .gui_osc, .name = "gui-osc", .kind = .bool },
    .{ .opt = .xkb_model, .name = "xkb-model", .kind = .string },
    .{ .opt = .xkb_layout, .name = "xkb-layout", .kind = .string },
    .{ .opt = .xkb_variant, .name = "xkb-variant", .kind = .string },
    .{ .opt = .xkb_options, .name = "xkb-options", .kind = .string },
    .{ .opt = .xkb_keymap, .name = "xkb-keymap", .kind = .string },
    .{ .opt = .xkb_compose_file, .name = "xkb-compose-file", .kind = .string },
    .{ .opt = .xkb_repeat_delay, .name = "xkb-repeat-delay", .kind = .uint },
    .{ .opt = .xkb_repeat_rate, .name = "xkb-repeat-rate", .kind = .uint },
    .{ .opt = .mouse, .name = "mouse", .kind = .bool },
    .{ .opt = .natural_scrolling, .name = "natural-scrolling", .kind = .bool },
    .{ .opt = .soft_cursor, .name = "soft-cursor", .kind = .bool },
    .{ .opt = .dpms_timeout, .name = "dpms-timeout", .kind = .uint },
    .{ .opt = .grab_scroll_up, .name = "grab-scroll-up", .kind = .grab },
    .{ .opt = .grab_scroll_down, .name = "grab-scroll-down", .kind = .grab },
    .{ .opt = .grab_page_up, .name = "grab-page-up", .kind = .grab },
    .{ .opt = .grab_page_down, .name = "grab-page-down", .kind = .grab },
    .{ .opt = .grab_zoom_in, .name = "grab-zoom-in", .kind = .grab },
    .{ .opt = .grab_zoom_out, .name = "grab-zoom-out", .kind = .grab },
    .{ .opt = .grab_session_next, .name = "grab-session-next", .kind = .grab },
    .{ .opt = .grab_session_prev, .name = "grab-session-prev", .kind = .grab },
    .{ .opt = .grab_session_close, .name = "grab-session-close", .kind = .grab },
    .{ .opt = .grab_terminal_new, .name = "grab-terminal-new", .kind = .grab },
    .{ .opt = .grab_rotate_cw, .name = "grab-rotate-cw", .kind = .grab },
    .{ .opt = .grab_rotate_ccw, .name = "grab-rotate-ccw", .kind = .grab },
    .{ .opt = .grab_reboot, .name = "grab-reboot", .kind = .grab },
    .{ .opt = .drm, .name = "drm", .kind = .bool },
    .{ .opt = .hwaccel, .name = "hwaccel", .kind = .bool },
    .{ .opt = .gpus, .name = "gpus", .kind = .gpus },
    .{ .opt = .use_original_mode, .name = "use-original-mode", .kind = .bool },
    .{ .opt = .mode, .name = "mode", .kind = .mode },
    .{ .opt = .multi_monitor, .name = "multi-monitor", .kind = .multi_monitor },
    .{ .opt = .screen, .name = "screen", .kind = .screen },
    .{ .opt = .font_engine, .name = "font-engine", .kind = .font_engine },
    .{ .opt = .font_size, .name = "font-size", .kind = .uint },
    .{ .opt = .font_name, .name = "font-name", .kind = .string },
    .{ .opt = .adjust_cell_width, .name = "adjust-cell-width", .kind = .percent },
    .{ .opt = .adjust_cell_height, .name = "adjust-cell-height", .kind = .percent },
    .{ .opt = .adjust_font_baseline, .name = "adjust-font-baseline", .kind = .percent },
    .{ .opt = .alpha_blending, .name = "alpha-blending", .kind = .alpha_blending },
    .{ .opt = .freetype_load_flags, .name = "freetype-load-flags", .kind = .freetype_load_flags },
    .{ .opt = .font_thicken, .name = "font-thicken", .kind = .bool },
    .{ .opt = .font_thicken_strength, .name = "font-thicken-strength", .kind = .u8 },
    .{ .opt = .adjust_cursor_thickness, .name = "adjust-cursor-thickness", .kind = .metric },
    .{ .opt = .adjust_cursor_height, .name = "adjust-cursor-height", .kind = .metric },
    .{ .opt = .adjust_underline_position, .name = "adjust-underline-position", .kind = .metric },
    .{ .opt = .cursor_style, .name = "cursor-style", .kind = .cursor_style },
    .{ .opt = .palette, .name = "palette", .kind = .palette },
    .{ .opt = .palette_black, .name = "palette-black", .kind = .color, .color = .black },
    .{ .opt = .palette_red, .name = "palette-red", .kind = .color, .color = .red },
    .{ .opt = .palette_green, .name = "palette-green", .kind = .color, .color = .green },
    .{ .opt = .palette_yellow, .name = "palette-yellow", .kind = .color, .color = .yellow },
    .{ .opt = .palette_blue, .name = "palette-blue", .kind = .color, .color = .blue },
    .{ .opt = .palette_magenta, .name = "palette-magenta", .kind = .color, .color = .magenta },
    .{ .opt = .palette_cyan, .name = "palette-cyan", .kind = .color, .color = .cyan },
    .{ .opt = .palette_light_grey, .name = "palette-light-grey", .kind = .color, .color = .light_grey },
    .{ .opt = .palette_dark_grey, .name = "palette-dark-grey", .kind = .color, .color = .dark_grey },
    .{ .opt = .palette_light_red, .name = "palette-light-red", .kind = .color, .color = .light_red },
    .{ .opt = .palette_light_green, .name = "palette-light-green", .kind = .color, .color = .light_green },
    .{ .opt = .palette_light_yellow, .name = "palette-light-yellow", .kind = .color, .color = .light_yellow },
    .{ .opt = .palette_light_blue, .name = "palette-light-blue", .kind = .color, .color = .light_blue },
    .{ .opt = .palette_light_magenta, .name = "palette-light-magenta", .kind = .color, .color = .light_magenta },
    .{ .opt = .palette_light_cyan, .name = "palette-light-cyan", .kind = .color, .color = .light_cyan },
    .{ .opt = .palette_white, .name = "palette-white", .kind = .color, .color = .white },
    .{ .opt = .palette_foreground, .name = "palette-foreground", .kind = .color, .color = .foreground },
    .{ .opt = .palette_background, .name = "palette-background", .kind = .color, .color = .background },
};

const name_map = std.StaticStringMap(usize).initComptime(blk: {
    var kvs: [specs.len]struct { []const u8, usize } = undefined;
    for (specs, 0..) |s, i| kvs[i] = .{ s.name, i };
    break :blk kvs;
});

fn shortSpec(c: u8) ?Spec {
    for (specs) |s| {
        if (s.short != 0 and s.short == c) return s;
    }
    return null;
}

/// The full configuration: one typed field per option, exact kmscon
/// defaults (except configdir/term, see the module doc). Dynamic values
/// are arena-owned; call `deinit` when done.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,

    /// Set when a parse fails; names the offending option.
    error_message: ?[]const u8 = null,
    /// Non-fatal problems (unknown file keys, mode/use-original-mode
    /// conflict, …), in occurrence order.
    warnings: std.ArrayList([]const u8) = .empty,
    /// CONF_LOCKED: options set on the command line cannot be overridden
    /// by config files (misc/conf.c:283,309-311,336-338).
    locked: std.EnumArray(Option, bool) = std.EnumArray(Option, bool).initFill(false),
    /// Set by the help/version afterchecks: quit right after parsing.
    exit: bool = false,

    // Global Options
    help: bool = false,
    version: bool = false,
    verbose: bool = false,
    debug: bool = false,
    silent: bool = false,
    configdir: []const u8 = default_configdir,

    // Seat Options
    vt: ?[]const u8 = null,
    switchvt: bool = true,
    libseat: bool = false,

    // Session Options
    session_max: u32 = 50,
    session_control: bool = false,

    // Terminal Options
    issue: bool = true,
    issue_path: []const u8 = default_issue_path,
    asciicast: ?[]const u8 = null,
    asciicast_loop: bool = false,
    login: bool = false,
    login_argv: []const []const u8 = &default_login_argv,
    oneshot: bool = false,
    term: []const u8 = default_term,
    reset_env: bool = true,
    backspace_delete: bool = true,
    sb_size: u32 = 1000,
    bell: bool = false,
    blink: bool = true,
    /// Per-screen kitty image storage budget in bytes; 0 disables the
    /// protocol (ROADMAP M4.5/M7).
    kitty_image_storage_limit: u32 = 10485760,
    /// OSC 52 / kitty clipboard reads: denied by default. Any program
    /// that can write terminal output (including remote SSH sessions)
    /// could otherwise exfiltrate the console clipboard. There is no
    /// prompt UI, so the policy is allow/deny, not ask.
    clipboard_read: bool = false,
    /// OSC 52 / kitty clipboard writes: denied by default (clipboard
    /// poisoning feeding the paste path). Opt in for remote set-clipboard
    /// workflows; pastes stay safety-checked regardless.
    clipboard_write: bool = false,
    /// kmscon private setBackground/setForeground OSCs (GUI launch
    /// handoff): denied by default. Any output source could otherwise
    /// drop or steal DRM master. Opt in for kmscon-launch-gui workflows.
    gui_osc: bool = false,

    // Input Options
    xkb_model: ?[]const u8 = null,
    xkb_layout: ?[]const u8 = null,
    xkb_variant: ?[]const u8 = null,
    xkb_options: ?[]const u8 = null,
    xkb_keymap: ?[]const u8 = null,
    xkb_compose_file: ?[]const u8 = null,
    xkb_repeat_delay: u32 = 250,
    xkb_repeat_rate: u32 = 50,
    mouse: bool = true,
    natural_scrolling: bool = false,
    soft_cursor: bool = false,
    dpms_timeout: u32 = 600,

    // Grabs / Keyboard-Shortcuts
    grab_scroll_up: Grab = grab.defaults.scroll_up,
    grab_scroll_down: Grab = grab.defaults.scroll_down,
    grab_page_up: Grab = grab.defaults.page_up,
    grab_page_down: Grab = grab.defaults.page_down,
    grab_zoom_in: Grab = grab.defaults.zoom_in,
    grab_zoom_out: Grab = grab.defaults.zoom_out,
    grab_session_next: Grab = grab.defaults.session_next,
    grab_session_prev: Grab = grab.defaults.session_prev,
    grab_session_close: Grab = grab.defaults.session_close,
    grab_terminal_new: Grab = grab.defaults.terminal_new,
    grab_rotate_cw: Grab = grab.defaults.rotate_cw,
    grab_rotate_ccw: Grab = grab.defaults.rotate_ccw,
    grab_reboot: Grab = grab.defaults.reboot,

    // Video Options
    drm: bool = true,
    hwaccel: bool = false,
    gpus: Gpus = .all,
    use_original_mode: bool = false,
    modes: std.ArrayList(Mode) = .empty,
    multi_monitor: MultiMonitor = .scaled,
    screens: std.ArrayList(Screen) = .empty,

    // Font Options
    font_engine: ?FontEngine = null,
    font_size: u32 = 0,
    font_name: []const u8 = "monospace",
    /// ghostty-compatible cell adjustments, in percent (0 = unchanged).
    adjust_cell_width: i32 = 0,
    adjust_cell_height: i32 = 0,
    adjust_font_baseline: i32 = 0,

    // Ghostty rendering parity — defaults are ghostty v1.4.0 Linux defaults
    // (.pixel-perfect-config-spec.md). font-thicken* only take effect on
    // macOS in ghostty; they are stored for config parity, inert on Linux.
    alpha_blending: AlphaBlending = .@"linear-corrected", // Config.zig:408-412
    freetype_load_flags: FreetypeLoadFlags = .{}, // Config.zig:546
    font_thicken: bool = false, // Config.zig:345
    font_thicken_strength: u8 = 255, // Config.zig:355
    adjust_cursor_thickness: ?MetricModifier = null, // Config.zig:467
    adjust_cursor_height: ?MetricModifier = null, // Config.zig:471
    adjust_underline_position: ?MetricModifier = null, // Config.zig:447
    cursor_style: CursorStyle = .block, // Config.zig:883

    // Palette Options
    palette: ?palette.Preset = null,
    custom_palette: [palette.palette_len]palette.Color = palette.Preset.custom.get(),

    pub fn init(gpa: std.mem.Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// The palette actually in effect: `custom` uses the 18
    /// `palette-*` values, a named preset uses its table, unset/unknown
    /// falls back to legacy (libtsm get_palette, tsm-vte.c:410-431).
    pub fn effectivePalette(self: *const Config) [palette.palette_len]palette.Color {
        const p = self.palette orelse return palette.Preset.legacy.get();
        if (p == .custom) return self.custom_palette;
        return p.get();
    }

    /// Three-tier mode lookup (see `display.getMode`).
    pub fn getMode(self: *const Config, gpu: []const u8, connector: []const u8) ?Mode {
        return display.getMode(self.modes.items, gpu, connector);
    }

    /// Three-tier screen lookup (see `display.getScreen`).
    pub fn getScreen(self: *const Config, gpu: []const u8, connector: []const u8) Screen {
        return display.getScreen(self.screens.items, gpu, connector);
    }

    // -- error/warning reporting ------------------------------------------

    fn fail(self: *Config, comptime fmt: []const u8, args: anytype) void {
        self.error_message = std.fmt.allocPrint(self.allocator(), fmt, args) catch null;
    }

    fn warn(self: *Config, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator(), fmt, args) catch return;
        self.warnings.append(self.allocator(), msg) catch return;
    }

    // -- option application ------------------------------------------------

    /// Apply one option value; on failure `error_message` names the
    /// option and `diag` carries the detail. Does not touch `locked`.
    fn setOption(self: *Config, opt: Option, on: bool, value: ?[]const u8, d: *Diag) Error!void {
        self.applyOption(opt, on, value, d) catch |err| {
            if (d.len == 0) d.print("{s}", .{@errorName(err)});
            self.fail("option '{s}': {s}", .{ specs[@intFromEnum(opt)].name, d.message() });
            return err;
        };
    }

    fn applyOption(self: *Config, opt: Option, on: bool, value: ?[]const u8, d: *Diag) Error!void {
        const alloc = self.allocator();
        const spec = specs[@intFromEnum(opt)];
        switch (spec.kind) {
            .bool => {
                inline for (specs) |s| {
                    if (s.kind == .bool and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = on;
                        return;
                    }
                }
                unreachable;
            },
            .uint => {
                const v = try parseUint(value.?, d);
                inline for (specs) |s| {
                    if (s.kind == .uint and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = v;
                        return;
                    }
                }
                unreachable;
            },
            .percent => {
                const v = try parsePercent(value.?, d);
                inline for (specs) |s| {
                    if (s.kind == .percent and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = v;
                        return;
                    }
                }
                unreachable;
            },
            .metric => {
                const v = try MetricModifier.parse(value.?, d);
                inline for (specs) |s| {
                    if (s.kind == .metric and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = v;
                        return;
                    }
                }
                unreachable;
            },
            .string => {
                const v = try alloc.dupe(u8, value.?);
                inline for (specs) |s| {
                    if (s.kind == .string and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = v;
                        return;
                    }
                }
                unreachable;
            },
            .vt => self.vt = try parseVt(alloc, value.?),
            .login => {
                if (value) |v| {
                    // File: shell-split argv (file_login, config.c:422-454).
                    const argv = try shell.splitCommandString(alloc, v, d);
                    if (argv.len == 0) {
                        d.print("empty argument given for 'login' config-option", .{});
                        return error.InvalidValue;
                    }
                    self.login_argv = argv;
                } else {
                    // CLI: bool-like; argv restored to the default until
                    // the aftercheck consumes the remaining args.
                    self.login_argv = &default_login_argv;
                }
                self.login = on;
            },
            .gpus => self.gpus = try Gpus.parse(value.?, d),
            .alpha_blending => self.alpha_blending = try AlphaBlending.parse(value.?, d),
            .freetype_load_flags => self.freetype_load_flags = try FreetypeLoadFlags.parse(value.?, d),
            .cursor_style => self.cursor_style = try CursorStyle.parse(value.?, d),
            .u8 => {
                const v = try parseUint(value.?, d);
                if (v > 255) {
                    d.print("value '{s}' out of range (0..255)", .{value.?});
                    return error.InvalidValue;
                }
                self.font_thicken_strength = @intCast(v);
            },
            .mode => {
                const m = try display.parseMode(alloc, value.?, d);
                try self.modes.append(alloc, m);
            },
            .screen => {
                const s = try display.parseScreen(alloc, value.?, d);
                try self.screens.append(alloc, s);
            },
            .color => self.custom_palette[spec.color.slot()] = try parseColor(value.?, d),
            .grab => {
                const g = try Grab.parse(alloc, value.?, d);
                inline for (specs) |s| {
                    if (s.kind == .grab and s.opt == opt) {
                        @field(self, @tagName(s.opt)) = g;
                        return;
                    }
                }
                unreachable;
            },
            .font_engine => self.font_engine = FontEngine.parse(value.?),
            .multi_monitor => self.multi_monitor = MultiMonitor.parse(value.?),
            .palette => self.palette = palette.Preset.fromName(value.?),
        }
    }

    // -- CLI ----------------------------------------------------------------

    /// Parse command-line arguments (without argv[0]). Recognized options
    /// are marked CONF_LOCKED. Positional arguments follow GNU getopt
    /// permutation: they collect at the end and become the login argv
    /// when `--login` was given (everything after `--` included).
    pub fn parseCli(self: *Config, args: []const []const u8, d: *Diag) Error!void {
        const alloc = self.allocator();
        var positionals: std.ArrayList([]const u8) = .empty;
        var tail: []const []const u8 = &.{};

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                tail = args[i + 1 ..];
                break;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                const eq = std.mem.indexOfScalar(u8, body, '=');
                const name = if (eq) |e| body[0..e] else body;
                const value: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

                var on = true;
                var lookup = name;
                if (std.mem.startsWith(u8, name, "no-")) {
                    on = false;
                    lookup = name[3..];
                }
                const idx = name_map.get(lookup) orelse {
                    self.fail("unknown option '--{s}'", .{name});
                    return error.UnknownOption;
                };
                const spec = specs[idx];
                // no- forms exist only for no-arg (bool/login) options.
                if (!on and spec.kind.hasArg()) {
                    self.fail("unknown option '--{s}'", .{name});
                    return error.UnknownOption;
                }
                if (!spec.kind.hasArg()) {
                    if (value != null) {
                        self.fail("option '--{s}' takes no argument", .{name});
                        return error.UnexpectedArgument;
                    }
                    try self.setOption(spec.opt, on, null, d);
                } else {
                    const v = value orelse blk: {
                        if (i + 1 >= args.len) {
                            self.fail("option '--{s}' requires an argument", .{name});
                            return error.MissingArgument;
                        }
                        i += 1;
                        break :blk args[i];
                    };
                    try self.setOption(spec.opt, on, v, d);
                }
                self.locked.set(spec.opt, true);
            } else if (arg.len > 1 and arg[0] == '-') {
                // Short-option bundle; an arg-taking short consumes the
                // rest of the bundle or the next argv element.
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const c = arg[j];
                    const spec = shortSpec(c) orelse {
                        self.fail("unknown option '-{c}'", .{c});
                        return error.UnknownOption;
                    };
                    if (!spec.kind.hasArg()) {
                        try self.setOption(spec.opt, true, null, d);
                        self.locked.set(spec.opt, true);
                    } else {
                        const v = if (j + 1 < arg.len) arg[j + 1 ..] else blk: {
                            if (i + 1 >= args.len) {
                                self.fail("option '-{c}' requires an argument", .{c});
                                return error.MissingArgument;
                            }
                            i += 1;
                            break :blk args[i];
                        };
                        try self.setOption(spec.opt, true, v, d);
                        self.locked.set(spec.opt, true);
                        break;
                    }
                }
            } else {
                // Lone "-" and non-options are positional arguments.
                try positionals.append(alloc, arg);
            }
        }

        const remaining = try alloc.alloc([]const u8, positionals.items.len + tail.len);
        @memcpy(remaining[0..positionals.items.len], positionals.items);
        @memcpy(remaining[positionals.items.len..], tail);

        // aftercheck_login (config.c:392-419): consume all remaining args.
        if (self.login) {
            if (remaining.len == 0) {
                self.fail("Arguments for --login missing", .{});
                return error.MissingLoginArguments;
            }
            const argv = try alloc.alloc([]const u8, remaining.len);
            for (remaining, 0..) |a, k| argv[k] = try alloc.dupe(u8, a);
            self.login_argv = argv;
        } else if (remaining.len > 0) {
            self.fail("Unparsed remaining args starting with: {s}", .{remaining[0]});
            return error.UnparsedArguments;
        }

        self.afterchecks();
    }

    // -- config file ----------------------------------------------------------

    /// Parse config-file text (kmscon conf.c parse_buffer/parse_line).
    /// Runs the option afterchecks at the end, like conf_ctx_parse_file.
    pub fn parseFileText(self: *Config, text: []const u8, d: *Diag) Error!void {
        var rest = text;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const line = if (nl) |n| rest[0..n] else rest;
            const unterminated = nl == null;
            rest = if (nl) |n| rest[n + 1 ..] else &.{};
            try self.parseLine(line, unterminated, d);
        }
        self.afterchecks();
    }

    fn parseLine(self: *Config, line: []const u8, eof_unterminated: bool, d: *Diag) Error!void {
        // Key runs to the first '#', '=' or end of line.
        var i: usize = 0;
        while (i < line.len and line[i] != '#' and line[i] != '=') : (i += 1) {}
        const key = strip(line[0..i]);
        var value: ?[]const u8 = null;
        var delim: u8 = 0;
        if (i < line.len) {
            delim = line[i];
            if (delim == '=') {
                var j = i + 1;
                while (j < line.len and line[j] != '#') : (j += 1) {}
                value = strip(line[i + 1 .. j]);
            }
        }
        if (key.len == 0) return;
        if (eof_unterminated and delim == 0) {
            self.fail("unterminated key '{s}' at end of config file", .{key});
            return error.UnterminatedKey;
        }

        var on = true;
        var name = key;
        if (std.mem.startsWith(u8, key, "no-")) {
            on = false;
            name = key[3..];
        }
        const idx = name_map.get(name) orelse {
            // Unknown keys are logged and skipped (misc/conf.c -EAGAIN).
            self.warn("unknown config option '{s}'", .{key});
            return;
        };
        const opt: Option = @enumFromInt(idx);
        // CONF_LOCKED: CLI-set options cannot be overridden by files.
        if (self.locked.get(opt)) return;
        const spec = specs[idx];

        if (!spec.kind.hasArg()) {
            if (spec.kind == .login) {
                // file_login requires a value even though login is a
                // no-arg option on the CLI.
                const v = value orelse {
                    self.fail("option 'login': no arguments for 'login' config-option", .{});
                    return error.MissingValue;
                };
                try self.setOption(opt, on, v, d);
            } else {
                if (value != null) {
                    self.fail("option '{s}': config option '{s}' does not take arguments", .{ spec.name, key });
                    return error.UnexpectedArgument;
                }
                try self.setOption(opt, on, null, d);
            }
        } else {
            const v = value orelse {
                self.fail("option '{s}': config option '{s}' requires an argument", .{ spec.name, key });
                return error.MissingValue;
            };
            try self.setOption(opt, on, v, d);
        }
    }

    /// Option afterchecks, in spirit of kmscon's table-order pass:
    /// debug implies verbose; help/version request exit; a configured
    /// mode clears use-original-mode (config.c:1158-1165).
    fn afterchecks(self: *Config) void {
        if (self.debug) self.verbose = true;
        if (self.help or self.version) self.exit = true;
        if (self.use_original_mode and self.modes.items.len != 0) {
            self.warn(
                "Cannot use --mode if --use-original-mode is enabled. Try --no-use-original-mode.",
                .{},
            );
            self.use_original_mode = false;
        }
    }

    // -- discovery and loading -------------------------------------------------

    /// Full main-context load: CLI first (locking every set option), then
    /// `<configdir>/kmshaunt.conf` unless help/version requested exit.
    pub fn load(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) Error!Config {
        var self = Config.init(alloc);
        errdefer self.deinit();
        var d = Diag{};
        try self.parseCli(args, &d);
        if (self.exit) return self;
        try self.loadMainFile(io, &d);
        return self;
    }

    /// Seat context: copy the main context (values AND locked flags),
    /// then layer `<configdir>/<seat>.seat.conf` on top
    /// (kmscon_conf_load_seat, config.c:1167-1185).
    pub fn loadSeat(
        main: *const Config,
        alloc: std.mem.Allocator,
        io: std.Io,
        seat: []const u8,
    ) Error!Config {
        var self = Config.init(alloc);
        errdefer self.deinit();
        try self.copyFrom(main);
        self.afterchecks();
        var d = Diag{};
        const file = try std.fmt.allocPrint(self.allocator(), "{s}.seat.conf", .{seat});
        const path = try std.Io.Dir.path.join(self.allocator(), &.{ self.configdir, file });
        try self.parseFilePath(io, path, &d);
        return self;
    }

    fn loadMainFile(self: *Config, io: std.Io, d: *Diag) Error!void {
        const path = try std.Io.Dir.path.join(self.allocator(), &.{ self.configdir, "kmshaunt.conf" });
        try self.parseFilePath(io, path, d);
    }

    /// A missing file is silently fine; an unreadable one is an error
    /// (misc/conf.c:493-496).
    fn parseFilePath(self: *Config, io: std.Io, path: []const u8, d: *Diag) Error!void {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator(), .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            error.AccessDenied => {
                self.fail("read access to config file {s} denied", .{path});
                return error.AccessDenied;
            },
            else => {
                self.fail("cannot read config file {s}: {s}", .{ path, @errorName(err) });
                return error.ReadError;
            },
        };
        try self.parseFileText(text, d);
    }

    /// Deep copy of every option value plus the locked flags
    /// (conf_ctx_parse_ctx). The arena is fresh; nothing is shared.
    fn copyFrom(self: *Config, src: *const Config) Error!void {
        const alloc = self.allocator();
        const value_fields = .{
            "help",              "version",           "verbose",        "debug",
            "silent",            "switchvt",          "libseat",        "session_max",
            "session_control",   "issue",             "asciicast_loop", "login",
            "oneshot",           "reset_env",         "backspace_delete", "sb_size",
            "bell",              "blink",             "xkb_repeat_delay", "xkb_repeat_rate",
            "mouse",             "natural_scrolling", "soft_cursor",    "dpms_timeout",
            "drm",               "hwaccel",           "gpus",           "use_original_mode",
            "multi_monitor",     "font_size",         "font_engine",    "palette",
            "kitty_image_storage_limit", "clipboard_read", "clipboard_write", "gui_osc",
            "adjust_cell_width",  "adjust_cell_height",  "adjust_font_baseline",
            "alpha_blending",     "freetype_load_flags", "font_thicken",
            "font_thicken_strength", "adjust_cursor_thickness", "adjust_cursor_height",
            "adjust_underline_position", "cursor_style",
        };
        inline for (value_fields) |f| @field(self, f) = @field(src, f);

        self.configdir = try alloc.dupe(u8, src.configdir);
        self.issue_path = try alloc.dupe(u8, src.issue_path);
        self.term = try alloc.dupe(u8, src.term);
        self.font_name = try alloc.dupe(u8, src.font_name);
        self.vt = try dupeOpt(alloc, src.vt);
        self.asciicast = try dupeOpt(alloc, src.asciicast);
        self.xkb_model = try dupeOpt(alloc, src.xkb_model);
        self.xkb_layout = try dupeOpt(alloc, src.xkb_layout);
        self.xkb_variant = try dupeOpt(alloc, src.xkb_variant);
        self.xkb_options = try dupeOpt(alloc, src.xkb_options);
        self.xkb_keymap = try dupeOpt(alloc, src.xkb_keymap);
        self.xkb_compose_file = try dupeOpt(alloc, src.xkb_compose_file);

        const argv = try alloc.alloc([]const u8, src.login_argv.len);
        for (src.login_argv, 0..) |a, i| argv[i] = try alloc.dupe(u8, a);
        self.login_argv = argv;

        const grab_fields = .{
            "grab_scroll_up",   "grab_scroll_down",  "grab_page_up",
            "grab_page_down",   "grab_zoom_in",      "grab_zoom_out",
            "grab_session_next", "grab_session_prev", "grab_session_close",
            "grab_terminal_new", "grab_rotate_cw",   "grab_rotate_ccw",
            "grab_reboot",
        };
        inline for (grab_fields) |f| @field(self, f) = try copyGrab(alloc, @field(src, f));

        for (src.modes.items) |m| {
            try self.modes.append(alloc, .{
                .gpu = try alloc.dupe(u8, m.gpu),
                .connector = try alloc.dupe(u8, m.connector),
                .width = m.width,
                .height = m.height,
                .refresh_rate = m.refresh_rate,
            });
        }
        for (src.screens.items) |s| {
            try self.screens.append(alloc, .{
                .gpu = try alloc.dupe(u8, s.gpu),
                .connector = try alloc.dupe(u8, s.connector),
                .orientation = s.orientation,
                .enabled = s.enabled,
            });
        }

        self.custom_palette = src.custom_palette;
        self.locked = src.locked;
    }
};

fn dupeOpt(alloc: std.mem.Allocator, s: ?[]const u8) Error!?[]const u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
}

fn copyGrab(alloc: std.mem.Allocator, g: Grab) Error!Grab {
    const shortcuts = try alloc.alloc(grab.Shortcut, g.shortcuts.len);
    for (g.shortcuts, 0..) |s, i| {
        shortcuts[i] = .{ .mods = s.mods, .keysyms = try alloc.dupe(u32, s.keysyms) };
    }
    return .{ .shortcuts = shortcuts };
}

// ---------------------------------------------------------------------------
// Per-type value parsers
// ---------------------------------------------------------------------------

/// Strict unsigned decimal with u32 bounds. kmscon uses atoi here; the
/// assignment requires bounds checks and typed errors, so garbage,
/// negatives and overflow are rejected instead of silently mangled.
/// Signed percentage like ghostty's adjust-* options: "-5%", "+18%", "10".
fn parsePercent(s: []const u8, d: *Diag) Error!i32 {
    var rest = s;
    if (rest.len > 0 and rest[rest.len - 1] == '%') rest = rest[0 .. rest.len - 1];
    if (rest.len == 0) {
        d.print("empty percent value '{s}'", .{s});
        return error.InvalidValue;
    }
    const neg = rest[0] == '-';
    if (neg or rest[0] == '+') rest = rest[1..];
    const mag = parseBase0(rest) orelse {
        d.print("cannot parse percent value '{s}'", .{s});
        return error.InvalidValue;
    };
    if (mag > 1000) {
        d.print("percent value out of range '{s}'", .{s});
        return error.InvalidValue;
    }
    const v: i32 = @intCast(mag);
    return if (neg) -v else v;
}

fn parseUint(s: []const u8, d: *Diag) Error!u32 {
    var rest = s;
    if (rest.len > 0 and rest[0] == '+') rest = rest[1..];
    if (rest.len == 0) {
        d.print("empty unsigned value", .{});
        return error.InvalidValue;
    }
    var v: u64 = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') {
            d.print("invalid unsigned integer '{s}'", .{s});
            return error.InvalidValue;
        }
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(u32)) {
            d.print("value '{s}' out of range", .{s});
            return error.InvalidValue;
        }
    }
    return @intCast(v);
}

/// `R,G,B` with each component 0..255 (config.c:770-822). Components are
/// parsed like shl_strtou: base 0 (0x hex / 0 octal), leading whitespace
/// allowed (that is why `255, 0, 0` works), whole string consumed.
/// Empty entries are kept, so arity errors are exact.
fn parseColor(s: []const u8, d: *Diag) Error!palette.Color {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (n == 3) {
            d.print("more than 3 values given, 3 expected", .{});
            return error.InvalidValue;
        }
        parts[n] = part;
        n += 1;
    }
    if (n != 3) {
        d.print("{d} values given, 3 expected", .{n});
        return error.InvalidValue;
    }
    var rgb: [3]u8 = undefined;
    for (parts, 0..) |part, i| rgb[i] = try parseColorComponent(part, d);
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn parseColorComponent(s: []const u8, d: *Diag) Error!u8 {
    const v = parseBase0(s) orelse {
        d.print("cannot parse color value '{s}'", .{s});
        return error.InvalidValue;
    };
    if (v > 255) {
        d.print("color value {d} out of range (0..255)", .{v});
        return error.InvalidValue;
    }
    return @intCast(v);
}

/// shl_strtou: strtoul(base 0) consuming the whole string, fitting u32.
/// Leading whitespace and '+' are accepted; '-' wraps and thus fails.
fn parseBase0(s: []const u8) ?u32 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    var rest = s[i..];
    if (rest.len > 0 and rest[0] == '+') rest = rest[1..];
    if (rest.len == 0) return null;
    var base: u8 = 10;
    if (rest.len >= 2 and rest[0] == '0') {
        if (rest[1] == 'x' or rest[1] == 'X') {
            base = 16;
            rest = rest[2..];
        } else {
            base = 8;
        }
    }
    if (rest.len == 0) return null;
    var v: u64 = 0;
    for (rest) |c| {
        const digit = std.fmt.charToDigit(c, base) catch return null;
        v = v * base + digit;
        if (v > std.math.maxInt(u32)) return null;
    }
    return @intCast(v);
}

/// conf_parse_vt (config.c:340-372): numeric → /dev/ttyN; `.`/`/` prefix
/// → verbatim; anything else → /dev/ prefix; empty stays empty.
fn parseVt(alloc: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (parseBase0(s)) |n| {
        return std.fmt.allocPrint(alloc, "/dev/tty{d}", .{n});
    }
    if (s.len > 0 and s[0] != '.' and s[0] != '/') {
        return std.mem.concat(alloc, u8, &.{ "/dev/", s });
    }
    return alloc.dupe(u8, s);
}

/// strip_spaces (misc/conf.c): spaces, CR and tabs at both ends.
fn strip(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isStripChar(s[start])) : (start += 1) {}
    while (end > start and isStripChar(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn isStripChar(c: u8) bool {
    return c == ' ' or c == '\r' or c == '\t';
}

// ---------------------------------------------------------------------------
// Help text (kmscon print_help shape, config.c:46-310; kmshaunt names).
// Note: --multi-monitor is deliberately absent, as in kmscon; --libseat
// shows [on] exactly like kmscon's help even though its default is off.
// ---------------------------------------------------------------------------

/// Zig multiline literals carry no escape sequences, so the raw text below
/// marks tabs with the two-character sequence `\t`; they are converted to
/// real tabs at comptime. No other backslashes occur in the help text.
const help_raw =
    \\Usage:
    \\\tkmshaunt [options]
    \\\tkmshaunt -h [options]
    \\\tkmshaunt -l [options] -- /bin/login [login-arguments]
    \\
    \\You can prefix boolean options with "no-" to negate them. If an argument is
    \\given multiple times, only the last argument matters if not otherwise stated.
    \\
    \\General Options:
    \\\t-h, --help                          Print this help and exit
    \\\t-V, --version                       Print version information and exit
    \\\t-v, --verbose               [off]   Print verbose messages
    \\\t    --debug                 [off]   Enable debug mode
    \\\t    --silent                [off]   Suppress notices and warnings
    \\\t-c, --configdir </foo/bar>  [/etc/kmshaunt]
    \\\t                                    Path to config directory
    \\
    \\Seat Options:
    \\\t    --vt <vt>               [auto]  Select which VT to run on
    \\\t    --switchvt              [on]    Automatically switch to VT
    \\\t    --libseat               [on]    Use libseat for seat management,
    \\\t                                    input and video devices
    \\
    \\Session Options:
    \\\t    --session-max <max>         [50]  Maximum number of sessions
    \\\t    --session-control           [off] Allow keyboard session-control
    \\
    \\Terminal Options:
    \\\t-l, --login                 [/bin/login -p]
    \\\t                              Start the given login process instead
    \\\t                              of the default process; all arguments
    \\\t                              following '--' will be be parsed as
    \\\t                              argv to this process. No more options
    \\\t                              after '--' will be parsed so use it at
    \\\t                              the end of the argument string
    \\\t    --oneshot                [off]
    \\\t                              When the login process exits, exit kmshaunt
    \\\t                              This is useful for setup scripts, or asking
    \\\t                              for disk encryption.
    \\\t                              (default: off)
    \\\t-t, --term <TERM>           [xterm-ghostty]
    \\\t                              Value of the TERM environment variable
    \\\t                              for the child process
    \\\t    --reset-env             [on]
    \\\t                              Reset environment before running child
    \\\t                              process
    \\\t    --issue                 [on]
    \\\t                              Display issue files before the
    \\\t                              login prompt. Use --no-issue to
    \\\t                              let the login process handle it.
    \\\t    --issue-path <path>     [/etc/issue:/etc/issue.d:/run/issue:/run/issue.d:/usr/lib/issue:/usr/lib/issue.d]
    \\\t                              Colon-separated list of issue
    \\\t                              files and directories to read
    \\\t                              when using --issue
    \\\t    --asciicast <path>
    \\\t                              Play an asciicast animation after
    \\\t                              opening the terminal session
    \\\t    --asciicast-loop        [off]
    \\\t                              Loop the asciicast animation
    \\\t    --backspace-delete      [on]
    \\\t                              Send delete character when backspace is
    \\\t                              pressed
    \\\t    --sb-size <num>         [1000]
    \\\t                              Size of the scrollback-buffer in lines
    \\\t    --bell                  [off]
    \\\t                              Enable bell forwarding to the VT
    \\\t    --blink                 [on]
    \\\t                              Enable or disable cursor/text blinking
    \\\t    --kitty-image-storage-limit <bytes>
    \\\t                              Set the per-screen kitty image storage
    \\\t                              budget in bytes; 0 disables the protocol
    \\\t    --clipboard-read        [off]
    \\\t                              Allow programs to read the console
    \\\t                              clipboard (OSC 52); denied by default
    \\\t    --clipboard-write       [off]
    \\\t                              Allow programs to set the console
    \\\t                              clipboard (OSC 52); denied by default
    \\\t    --gui-osc               [off]
    \\\t                              Honor kmscon private setBackground /
    \\\t                              setForeground OSCs (GUI launch handoff)
    \\
    \\Input Options:
    \\\t    --xkb-model <model>        [-]  Set XkbModel for input devices
    \\\t    --xkb-layout <layout>      [-]  Set XkbLayout for input devices
    \\\t    --xkb-variant <variant>    [-]  Set XkbVariant for input devices
    \\\t    --xkb-options <options>    [-]  Set XkbOptions for input devices
    \\\t    --xkb-keymap <FILE>        [-]  Use a predefined keymap for
    \\\t                                    input devices
    \\\t    --xkb-compose-file <FILE>  [-]  Use a predefined compose file for
    \\\t                                    input devices
    \\\t    --xkb-repeat-delay <msecs> [250]
    \\\t                                 Initial delay for key-repeat in ms
    \\\t    --xkb-repeat-rate <msecs>  [50]
    \\\t                                 Delay between two key repeats in ms
    \\\t    --mouse                    [on]
    \\\t                                 Enable mouse support
    \\\t    --natural-scrolling        [off]
    \\\t                                 Invert mouse wheel direction
    \\\t    --soft-cursor              [off]
    \\\t                                 Force software cursor
    \\\t    --dpms-timeout <secs>      [600]
    \\\t                                 Screen timeout in seconds (0=off)
    \\
    \\Grabs / Keyboard-Shortcuts:
    \\\t    --grab-scroll-up <grab>     [<Shift>Up]
    \\\t                                  Shortcut to scroll up
    \\\t    --grab-scroll-down <grab>   [<Shift>Down]
    \\\t                                  Shortcut to scroll down
    \\\t    --grab-page-up <grab>       [<Shift>Prior]
    \\\t                                  Shortcut to scroll page up
    \\\t    --grab-page-down <grab>     [<Shift>Next]
    \\\t                                  Shortcut to scroll page down
    \\\t    --grab-zoom-in <grab>       [<Ctrl>plus]
    \\\t                                  Shortcut to increase font size
    \\\t    --grab-zoom-out <grab>      [<Ctrl>minus]
    \\\t                                  Shortcut to decrease font size
    \\\t    --grab-session-next <grab>  [<Ctrl><Logo>Right]
    \\\t                                  Switch to the next session
    \\\t    --grab-session-prev <grab>  [<Ctrl><Logo>Left]
    \\\t                                  Switch to the previous session
    \\\t    --grab-session-close <grab> [<Ctrl><Logo>BackSpace]
    \\\t                                  Close current session
    \\\t    --grab-terminal-new <grab>  [<Ctrl><Logo>Return]
    \\\t                                  Create a new terminal session
    \\\t    --grab-rotate-cw <grab>     [<Logo>plus]
    \\\t                                  Rotate output clock-wise
    \\\t    --grab-rotate-ccw <grab>    [<Logo>minus]
    \\\t                                  Rotate output counter-clock-wise
    \\\t    --grab-reboot <grab>        []
    \\\t                                  Reboot the system (disabled by default)
    \\
    \\Video Options:
    \\\t    --drm                     [on]    Use DRM if available
    \\\t    --hwaccel                 [off]   Use 3D hardware-acceleration if
    \\\t                                      available
    \\\t    --gpus={all,aux,primary}  [all]   GPU selection mode
    \\\t    --use-original-mode       [off]   Use original KMS video mode
    \\\t    --mode <gpu>[<connector>]<width>x<height>@<rate>
    \\\t                                      Set the desired mode for the
    \\\t                                      gpu/connector. It can be specified
    \\\t                                      multiple time, for different monitors
    \\\t                                      GPU, connector and rate are optional
    \\\t                                      If the specified mode is
    \\\t                                      not available or encounters an
    \\\t                                      error, a default mode will be used.
    \\\t                                      This option is incompatible with
    \\\t                                      --use-original-mode.
    \\\t    --screen <gpu>[<connector>]<orientation|disabled>
    \\\t                                      Specify how to use each screen.
    \\\t                                      Set the orientation, or just disable
    \\\t                                      a monitor. GPU and connector are
    \\\t                                      optional
    \\
    \\Font Options:
    \\\t    --font-engine <engine>  [freetype]
    \\\t                              Font rendering engine
    \\\t    --font-size <pixels>    [0]
    \\\t                              Font size in pixels, 0 means auto
    \\\t    --font-name <name>      [monospace]
    \\\t                              Font name
    \\\t    --adjust-cell-width <pct>  [0]
    \\\t                              Cell width adjustment in percent
    \\\t    --adjust-cell-height <pct> [0]
    \\\t                              Cell height adjustment in percent
    \\\t    --adjust-font-baseline <pct> [0]
    \\\t                              Font baseline adjustment in percent
    \\\t    --alpha-blending <mode> [linear-corrected]
    \\\t                              Alpha blending color space: native,
    \\\t                              linear or linear-corrected (ghostty)
    \\\t    --freetype-load-flags <flags>
    \\\t                              Comma-separated FreeType load flags:
    \\\t                              hinting, force-autohint, monochrome,
    \\\t                              autohint, light; no- prefix disables
    \\\t    --font-thicken            [off]
    \\\t                              Thicker font stroke (macOS-only in
    \\\t                              ghostty; inert on Linux)
    \\\t    --font-thicken-strength <0..255> [255]
    \\\t                              Thickening strength (macOS-only in
    \\\t                              ghostty; inert on Linux)
    \\\t    --adjust-cursor-thickness <mod>
    \\\t                              Cursor thickness delta: px or percent
    \\\t    --adjust-cursor-height <mod>
    \\\t                              Cursor height delta: px or percent
    \\\t    --adjust-underline-position <mod>
    \\\t                              Underline position delta: px or percent
    \\\t    --cursor-style <style>    [block]
    \\\t                              Default cursor style: block, bar,
    \\\t                              underline or block_hollow
    \\
    \\Palette Options:
    \\\t    --palette <name>                [default]
    \\\t                                      Select the used color palette.
    \\\t                                      specify `custom' to use the
    \\\t                                      following color options
    \\\t    --palette-black <color>         [  0,   0,   0]
    \\\t                                      Black in custom palette
    \\\t    --palette-red <color>           [205,   0,   0]
    \\\t                                      Red in custom palette
    \\\t    --palette-green <color>         [  0, 205,   0]
    \\\t                                      Green in custom palette
    \\\t    --palette-yellow <color>        [205, 205,   0]
    \\\t                                      Yellow in custom palette
    \\\t    --palette-blue <color>          [  0,   0, 238]
    \\\t                                      Blue in custom palette
    \\\t    --palette-magenta <color>       [205,   0, 205]
    \\\t                                      Magenta in custom palette
    \\\t    --palette-cyan <color>          [  0, 205, 205]
    \\\t                                      Cyan in custom palette
    \\\t    --palette-light-grey <color>    [229, 229, 229]
    \\\t                                      Light grey in custom palette
    \\\t    --palette-dark-grey <color>     [127, 127, 127]
    \\\t                                      Dark grey in custom palette
    \\\t    --palette-light-red <color>     [255,   0,   0]
    \\\t                                      Light red in custom palette
    \\\t    --palette-light-green <color>   [  0, 255,   0]
    \\\t                                      Light green in custom palette
    \\\t    --palette-light-yellow <color>  [255, 255,   0]
    \\\t                                      Light yellow in custom palette
    \\\t    --palette-light-blue <color>    [ 92,  92, 255]
    \\\t                                      Light blue in custom palette
    \\\t    --palette-light-magenta <color> [255,   0, 255]
    \\\t                                      Light magenta in custom palette
    \\\t    --palette-light-cyan <color>    [  0, 255, 255]
    \\\t                                      Light cyan in custom palette
    \\\t    --palette-white <color>         [255, 255, 255]
    \\\t                                      White in custom palette
    \\\t    --palette-foreground <color>    [229, 229, 229]
    \\\t                                      Default foreground color in
    \\\t                                      custom palette
    \\\t    --palette-background <color>    [  0,   0,   0]
    \\\t                                      Default background color in
    \\\t                                      custom palette
    \\
    ;

const help_tab_count = blk: {
    @setEvalBranchQuota(100000);
    var count: usize = 0;
    var i: usize = 0;
    while (i < help_raw.len) : (i += 1) {
        if (i + 1 < help_raw.len and help_raw[i] == '\\' and help_raw[i + 1] == 't') {
            count += 1;
            i += 1;
        }
    }
    break :blk count;
};

const help_storage = blk: {
    @setEvalBranchQuota(100000);
    var out: [help_raw.len - help_tab_count]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < help_raw.len) {
        if (i + 1 < help_raw.len and help_raw[i] == '\\' and help_raw[i + 1] == 't') {
            out[n] = '\t';
            n += 1;
            i += 2;
        } else {
            out[n] = help_raw[i];
            n += 1;
            i += 1;
        }
    }
    break :blk out;
};

pub const help_text: []const u8 = &help_storage;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = @import("grab.zig");
    _ = @import("display.zig");
    _ = @import("shell.zig");
    _ = @import("keysyms.zig");
    _ = @import("diag.zig");
    _ = @import("../misc/palette.zig");
}

fn cliOk(cfg: *Config, args: []const []const u8) !void {
    var d = Diag{};
    cfg.parseCli(args, &d) catch |err| {
        std.debug.print("CLI parse failed: {s}\n", .{d.message()});
        return err;
    };
}

fn fileOk(cfg: *Config, text: []const u8) !void {
    var d = Diag{};
    cfg.parseFileText(text, &d) catch |err| {
        std.debug.print("file parse failed: {s}\n", .{d.message()});
        return err;
    };
}

fn tmpPath(alloc: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

test "defaults: every option at its documented kmscon default" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();

    // Global
    try testing.expect(!cfg.help);
    try testing.expect(!cfg.version);
    try testing.expect(!cfg.verbose);
    try testing.expect(!cfg.debug);
    try testing.expect(!cfg.silent);
    try testing.expectEqualStrings("/etc/kmshaunt", cfg.configdir);
    // Seat
    try testing.expectEqual(@as(?[]const u8, null), cfg.vt);
    try testing.expect(cfg.switchvt);
    try testing.expect(!cfg.libseat);
    // Session
    try testing.expectEqual(@as(u32, 50), cfg.session_max);
    try testing.expect(!cfg.session_control);
    // Terminal
    try testing.expect(cfg.issue);
    try testing.expectEqualStrings(default_issue_path, cfg.issue_path);
    try testing.expectEqual(@as(?[]const u8, null), cfg.asciicast);
    try testing.expect(!cfg.asciicast_loop);
    try testing.expect(!cfg.login);
    try testing.expectEqual(@as(usize, 2), cfg.login_argv.len);
    try testing.expectEqualStrings("/bin/login", cfg.login_argv[0]);
    try testing.expectEqualStrings("-p", cfg.login_argv[1]);
    try testing.expect(!cfg.oneshot);
    try testing.expectEqualStrings("xterm-ghostty", cfg.term); // ROADMAP D6
    try testing.expect(cfg.reset_env);
    try testing.expect(cfg.backspace_delete);
    try testing.expectEqual(@as(u32, 1000), cfg.sb_size);
    try testing.expect(!cfg.bell);
    try testing.expect(cfg.blink);
    try testing.expectEqual(@as(u32, 10485760), cfg.kitty_image_storage_limit);
    try testing.expect(!cfg.clipboard_read);
    try testing.expect(!cfg.clipboard_write);
    try testing.expect(!cfg.gui_osc);
    // Input
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_model);
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_layout);
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_variant);
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_options);
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_keymap);
    try testing.expectEqual(@as(?[]const u8, null), cfg.xkb_compose_file);
    try testing.expectEqual(@as(u32, 250), cfg.xkb_repeat_delay);
    try testing.expectEqual(@as(u32, 50), cfg.xkb_repeat_rate);
    try testing.expect(cfg.mouse);
    try testing.expect(!cfg.natural_scrolling);
    try testing.expect(!cfg.soft_cursor);
    try testing.expectEqual(@as(u32, 600), cfg.dpms_timeout);
    // Video
    try testing.expect(cfg.drm);
    try testing.expect(!cfg.hwaccel);
    try testing.expectEqual(Gpus.all, cfg.gpus);
    try testing.expect(!cfg.use_original_mode);
    try testing.expectEqual(@as(usize, 0), cfg.modes.items.len);
    try testing.expectEqual(MultiMonitor.scaled, cfg.multi_monitor);
    try testing.expectEqual(@as(usize, 0), cfg.screens.items.len);
    // Font
    try testing.expectEqual(@as(?FontEngine, null), cfg.font_engine);
    try testing.expectEqual(@as(u32, 0), cfg.font_size);
    try testing.expectEqualStrings("monospace", cfg.font_name);
    // Ghostty rendering parity (v1.4.0 Linux defaults)
    try testing.expectEqual(AlphaBlending.@"linear-corrected", cfg.alpha_blending);
    try testing.expect(cfg.freetype_load_flags.hinting);
    try testing.expect(!cfg.freetype_load_flags.@"force-autohint");
    try testing.expect(!cfg.freetype_load_flags.monochrome);
    try testing.expect(cfg.freetype_load_flags.autohint);
    try testing.expect(cfg.freetype_load_flags.light);
    try testing.expect(!cfg.font_thicken);
    try testing.expectEqual(@as(u8, 255), cfg.font_thicken_strength);
    try testing.expectEqual(@as(?MetricModifier, null), cfg.adjust_cursor_thickness);
    try testing.expectEqual(@as(?MetricModifier, null), cfg.adjust_cursor_height);
    try testing.expectEqual(@as(?MetricModifier, null), cfg.adjust_underline_position);
    try testing.expectEqual(CursorStyle.block, cfg.cursor_style);
    // Palette
    try testing.expectEqual(@as(?palette.Preset, null), cfg.palette);
    try testing.expectEqual(palette.Preset.custom.get(), cfg.custom_palette);
    try testing.expectEqual(palette.Preset.legacy.get(), cfg.effectivePalette());
    // Grabs: defaults are the source-macro table (grab.zig tests pin the
    // keysyms); spot-check the shapes here.
    try testing.expectEqual(@as(usize, 1), cfg.grab_scroll_up.shortcuts.len);
    try testing.expectEqual(@as(usize, 2), cfg.grab_zoom_in.shortcuts.len);
    try testing.expectEqual(@as(usize, 2), cfg.grab_rotate_cw.shortcuts.len);
    try testing.expectEqual(@as(usize, 0), cfg.grab_reboot.shortcuts.len);
    // State
    try testing.expect(!cfg.exit);
    try testing.expectEqual(@as(?[]const u8, null), cfg.error_message);
    for (std.meta.tags(Option)) |o| try testing.expect(!cfg.locked.get(o));
}

test "registry: all 92 options, unique names, documented short forms" {
    try testing.expectEqual(@as(usize, 92), specs.len);
    try testing.expectEqual(@as(usize, 92), std.meta.tags(Option).len);
    for (specs, 0..) |s, i| {
        try testing.expectEqual(@as(Option, @enumFromInt(i)), s.opt);
        try testing.expectEqual(@as(?usize, i), name_map.get(s.name));
    }
    const shorts = [_]u8{ 'h', 'V', 'v', 'c', 'l', 't' };
    var count: usize = 0;
    for (specs) |s| {
        if (s.short != 0) {
            count += 1;
            try testing.expect(std.mem.indexOfScalar(u8, &shorts, s.short) != null);
        }
    }
    try testing.expectEqual(@as(usize, 6), count);
}

test "MetricModifier: ghostty delta semantics (font/Metrics.zig:454-547)" {
    var d = Diag{};
    // Percent is a multiplier delta: "20%" -> 1.2, "-20%" -> 0.8.
    try testing.expectApproxEqAbs(@as(f64, 1.2), (try MetricModifier.parse("20%", &d)).percent, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.8), (try MetricModifier.parse("-20%", &d)).percent, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.025), (try MetricModifier.parse("2.5%", &d)).percent, 1e-12);
    // <= -100% clamps to multiplier 0.
    try testing.expectEqual(@as(f64, 0), (try MetricModifier.parse("-100%", &d)).percent);
    try testing.expectEqual(@as(f64, 0), (try MetricModifier.parse("-150%", &d)).percent);
    // No % = absolute pixel delta (ghostty parses i32 base 10).
    try testing.expectEqual(MetricModifier{ .absolute = 2 }, try MetricModifier.parse("2", &d));
    try testing.expectEqual(MetricModifier{ .absolute = -2 }, try MetricModifier.parse("-2", &d));
    // Garbage and empty values are typed errors.
    try testing.expectError(error.InvalidValue, MetricModifier.parse("", &d));
    try testing.expectError(error.InvalidValue, MetricModifier.parse("%", &d));
    try testing.expectError(error.InvalidValue, MetricModifier.parse("abc", &d));
    try testing.expectError(error.InvalidValue, MetricModifier.parse("1.5", &d));

    // apply: percent rounds (half away from zero), absolute saturates.
    const p20 = MetricModifier{ .percent = 1.2 };
    try testing.expectEqual(@as(u16, 12), p20.apply(@as(u16, 10)));
    try testing.expectEqual(@as(u16, 1), p20.apply(@as(u16, 1)));
    const p25 = MetricModifier{ .percent = 1.25 };
    try testing.expectEqual(@as(u16, 13), p25.apply(@as(u16, 10))); // round(12.5)
    const p100 = MetricModifier{ .percent = 2 };
    try testing.expectEqual(@as(u16, 2), p100.apply(@as(u16, 1)));
    const m100 = MetricModifier{ .percent = 0 };
    try testing.expectEqual(@as(u16, 0), m100.apply(@as(u16, 10)));
    const neg = MetricModifier{ .absolute = -20 };
    try testing.expectEqual(@as(u16, 0), neg.apply(@as(u16, 10))); // unsigned clamps at 0
    try testing.expectEqual(@as(i32, -10), neg.apply(@as(i32, 10)));
    const big = MetricModifier{ .absolute = std.math.maxInt(i32) };
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), big.apply(@as(u16, 10)));
}

test "FreetypeLoadFlags: defaults, no- prefix, true/false, unknown flag" {
    var d = Diag{};
    const def: FreetypeLoadFlags = .{};
    try testing.expect(def.hinting and def.autohint and def.light);
    try testing.expect(!def.@"force-autohint" and !def.monochrome);

    const nohint = try FreetypeLoadFlags.parse("no-hinting", &d);
    try testing.expect(!nohint.hinting);
    try testing.expect(nohint.autohint and nohint.light); // omitted keep defaults

    const mix = try FreetypeLoadFlags.parse("force-autohint, no-light", &d);
    try testing.expect(mix.@"force-autohint" and !mix.light and mix.hinting);

    const all = try FreetypeLoadFlags.parse("true", &d);
    try testing.expect(all.hinting and all.@"force-autohint" and all.monochrome and all.autohint and all.light);
    const none = try FreetypeLoadFlags.parse("false", &d);
    try testing.expect(!none.hinting and !none.@"force-autohint" and !none.monochrome and !none.autohint and !none.light);

    try testing.expectError(error.InvalidValue, FreetypeLoadFlags.parse("bogus", &d));
}

test "AlphaBlending and CursorStyle: enum values and invalid names" {
    var d = Diag{};
    try testing.expectEqual(AlphaBlending.native, try AlphaBlending.parse("native", &d));
    try testing.expectEqual(AlphaBlending.linear, try AlphaBlending.parse("linear", &d));
    try testing.expectEqual(AlphaBlending.@"linear-corrected", try AlphaBlending.parse("linear-corrected", &d));
    try testing.expectError(error.InvalidValue, AlphaBlending.parse("srgb", &d));

    try testing.expectEqual(CursorStyle.block, try CursorStyle.parse("block", &d));
    try testing.expectEqual(CursorStyle.bar, try CursorStyle.parse("bar", &d));
    try testing.expectEqual(CursorStyle.underline, try CursorStyle.parse("underline", &d));
    try testing.expectEqual(CursorStyle.block_hollow, try CursorStyle.parse("block_hollow", &d));
    try testing.expectError(error.InvalidValue, CursorStyle.parse("hollow", &d));
}

test "ghostty knobs: file parse, seat copy, invalid values are typed errors" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg,
        \\alpha-blending=linear
        \\freetype-load-flags=no-hinting,force-autohint
        \\font-thicken
        \\font-thicken-strength=0
        \\adjust-cursor-thickness=100%
        \\adjust-cursor-height=-2
        \\adjust-underline-position=2
        \\cursor-style=block_hollow
        \\
    );
    try testing.expectEqual(AlphaBlending.linear, cfg.alpha_blending);
    try testing.expect(!cfg.freetype_load_flags.hinting);
    try testing.expect(cfg.freetype_load_flags.@"force-autohint");
    try testing.expect(cfg.font_thicken);
    try testing.expectEqual(@as(u8, 0), cfg.font_thicken_strength);
    try testing.expectApproxEqAbs(@as(f64, 2), cfg.adjust_cursor_thickness.?.percent, 1e-12);
    try testing.expectEqual(MetricModifier{ .absolute = -2 }, cfg.adjust_cursor_height.?);
    try testing.expectEqual(MetricModifier{ .absolute = 2 }, cfg.adjust_underline_position.?);
    try testing.expectEqual(CursorStyle.block_hollow, cfg.cursor_style);

    // Seat copies carry the knob values (copyFrom value_fields).
    var seat = try cfg.loadSeat(testing.allocator, testing.io, "seat0");
    defer seat.deinit();
    try testing.expectEqual(AlphaBlending.linear, seat.alpha_blending);
    try testing.expectEqual(CursorStyle.block_hollow, seat.cursor_style);
    try testing.expectEqual(MetricModifier{ .absolute = 2 }, seat.adjust_underline_position.?);

    var d = Diag{};
    try testing.expectError(error.InvalidValue, cfg.parseFileText("font-thicken-strength=256\n", &d));
    try testing.expectError(error.InvalidValue, cfg.parseFileText("alpha-blending=bogus\n", &d));
    try testing.expectError(error.InvalidValue, cfg.parseFileText("cursor-style=bogus\n", &d));
    try testing.expectError(error.InvalidValue, cfg.parseFileText("freetype-load-flags=bogus\n", &d));
    try testing.expectError(error.InvalidValue, cfg.parseFileText("adjust-cursor-thickness=bogus\n", &d));
}

test "sample config file exercises every option type" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    const sample =
        \\# kmshaunt.conf — every option, all types
        \\help
        \\version
        \\verbose
        \\debug
        \\silent
        \\configdir = /tmp/sample-dir
        \\vt=3
        \\switchvt
        \\no-libseat
        \\session-max=7
        \\session-control
        \\no-issue
        \\issue-path=/etc/issue:/run/issue
        \\asciicast=/tmp/demo.cast
        \\asciicast-loop
        \\login=/bin/bash -i
        \\oneshot
        \\term=screen-256color
        \\no-reset-env
        \\no-backspace-delete
        \\sb-size=2000
        \\bell
        \\no-blink
        \\kitty-image-storage-limit=8388608
        \\xkb-model=pc105
        \\xkb-layout=de
        \\xkb-variant=nodeadkeys
        \\xkb-options=ctrl:nocaps
        \\xkb-keymap=/usr/share/keymap.xkb
        \\xkb-compose-file=/usr/share/compose
        \\xkb-repeat-delay=300
        \\xkb-repeat-rate=40
        \\no-mouse
        \\natural-scrolling
        \\soft-cursor
        \\dpms-timeout=120
        \\grab-scroll-up=<Shift>Up,<Ctrl>u
        \\grab-scroll-down=<Shift>Down
        \\grab-page-up=<Shift>Prior
        \\grab-page-down=<Shift>Next
        \\grab-zoom-in=<Ctrl>plus
        \\grab-zoom-out=<Ctrl>minus
        \\grab-session-next=<Ctrl><Logo>Right
        \\grab-session-prev=<Ctrl><Logo>Left
        \\grab-session-close=<Ctrl><Logo>BackSpace
        \\grab-terminal-new=<Ctrl><Logo>Return
        \\grab-rotate-cw=<Logo>plus
        \\grab-rotate-ccw=<Logo>minus
        \\grab-reboot=<Ctrl><Alt>Delete
        \\no-drm
        \\hwaccel
        \\gpus=auxiliary
        \\use-original-mode
        \\mode=card0[HDMI-A-1]1920x1080@60
        \\mode=[DP-1]1280x720
        \\mode=800x600
        \\multi-monitor=largest
        \\screen=card0[HDMI-A-1]right
        \\screen=[DP-1]left
        \\screen=disabled
        \\font-engine=pango
        \\font-size=16
        \\font-name=JetBrains Mono
        \\alpha-blending=linear
        \\freetype-load-flags=no-hinting,force-autohint
        \\font-thicken
        \\font-thicken-strength=128
        \\adjust-cursor-thickness=2
        \\adjust-cursor-height=20%
        \\adjust-underline-position=-1
        \\cursor-style=bar
        \\palette=nord
        \\palette-black=1,2,3
        \\palette-red=205, 0, 0
        \\palette-green=0,205,0
        \\palette-yellow=205,205,0
        \\palette-blue=0,0,238
        \\palette-magenta=205,0,205
        \\palette-cyan=0,205,205
        \\palette-light-grey=229,229,229
        \\palette-dark-grey=127,127,127
        \\palette-light-red=255,0,0
        \\palette-light-green=0,255,0
        \\palette-light-yellow=255,255,0
        \\palette-light-blue=92,92,255
        \\palette-light-magenta=255,0,255
        \\palette-light-cyan=0,255,255
        \\palette-white=255,255,255
        \\palette-foreground=255, 0, 0
        \\palette-background=0,0,0
        \\
    ;
    try fileOk(&cfg, sample);

    try testing.expect(cfg.help and cfg.version and cfg.verbose and cfg.debug and cfg.silent);
    try testing.expect(cfg.exit); // help/version aftercheck
    try testing.expectEqualStrings("/tmp/sample-dir", cfg.configdir);
    try testing.expectEqualStrings("/dev/tty3", cfg.vt.?);
    try testing.expect(cfg.switchvt);
    try testing.expect(!cfg.libseat);
    try testing.expectEqual(@as(u32, 7), cfg.session_max);
    try testing.expect(cfg.session_control);
    try testing.expect(!cfg.issue);
    try testing.expectEqualStrings("/etc/issue:/run/issue", cfg.issue_path);
    try testing.expectEqualStrings("/tmp/demo.cast", cfg.asciicast.?);
    try testing.expect(cfg.asciicast_loop);
    try testing.expect(cfg.login);
    try testing.expectEqual(@as(usize, 2), cfg.login_argv.len);
    try testing.expectEqualStrings("/bin/bash", cfg.login_argv[0]);
    try testing.expectEqualStrings("-i", cfg.login_argv[1]);
    try testing.expect(cfg.oneshot);
    try testing.expectEqualStrings("screen-256color", cfg.term);
    try testing.expect(!cfg.reset_env);
    try testing.expect(!cfg.backspace_delete);
    try testing.expectEqual(@as(u32, 2000), cfg.sb_size);
    try testing.expect(cfg.bell);
    try testing.expect(!cfg.blink);
    try testing.expectEqual(@as(u32, 8388608), cfg.kitty_image_storage_limit);
    try testing.expectEqualStrings("pc105", cfg.xkb_model.?);
    try testing.expectEqualStrings("de", cfg.xkb_layout.?);
    try testing.expectEqualStrings("nodeadkeys", cfg.xkb_variant.?);
    try testing.expectEqualStrings("ctrl:nocaps", cfg.xkb_options.?);
    try testing.expectEqualStrings("/usr/share/keymap.xkb", cfg.xkb_keymap.?);
    try testing.expectEqualStrings("/usr/share/compose", cfg.xkb_compose_file.?);
    try testing.expectEqual(@as(u32, 300), cfg.xkb_repeat_delay);
    try testing.expectEqual(@as(u32, 40), cfg.xkb_repeat_rate);
    try testing.expect(!cfg.mouse);
    try testing.expect(cfg.natural_scrolling);
    try testing.expect(cfg.soft_cursor);
    try testing.expectEqual(@as(u32, 120), cfg.dpms_timeout);
    try testing.expectEqual(@as(usize, 2), cfg.grab_scroll_up.shortcuts.len);
    try testing.expect(cfg.grab_scroll_up.matches(grab.control, &.{'u'}));
    try testing.expectEqual(@as(usize, 1), cfg.grab_zoom_in.shortcuts.len);
    try testing.expectEqual(@as(usize, 1), cfg.grab_reboot.shortcuts.len);
    try testing.expect(cfg.grab_reboot.matches(grab.control | grab.alt, &.{0xffff}));
    try testing.expect(!cfg.drm);
    try testing.expect(cfg.hwaccel);
    try testing.expectEqual(Gpus.aux, cfg.gpus);
    // use-original-mode + mode: aftercheck clears it (config.c:1158-1165).
    try testing.expect(!cfg.use_original_mode);
    try testing.expectEqual(@as(usize, 1), cfg.warnings.items.len);
    try testing.expectEqual(@as(usize, 3), cfg.modes.items.len);
    try testing.expectEqual(MultiMonitor.largest, cfg.multi_monitor);
    try testing.expectEqual(@as(usize, 3), cfg.screens.items.len);
    try testing.expectEqual(FontEngine.freetype, cfg.font_engine.?); // pango alias
    try testing.expectEqual(@as(u32, 16), cfg.font_size);
    try testing.expectEqualStrings("JetBrains Mono", cfg.font_name);
    // Ghostty rendering parity knobs
    try testing.expectEqual(AlphaBlending.linear, cfg.alpha_blending);
    try testing.expect(!cfg.freetype_load_flags.hinting);
    try testing.expect(cfg.freetype_load_flags.@"force-autohint");
    try testing.expect(cfg.freetype_load_flags.autohint); // omitted keeps default
    try testing.expect(cfg.freetype_load_flags.light);
    try testing.expect(cfg.font_thicken);
    try testing.expectEqual(@as(u8, 128), cfg.font_thicken_strength);
    try testing.expectEqual(MetricModifier{ .absolute = 2 }, cfg.adjust_cursor_thickness.?);
    try testing.expectApproxEqAbs(@as(f64, 1.2), cfg.adjust_cursor_height.?.percent, 1e-12);
    try testing.expectEqual(MetricModifier{ .absolute = -1 }, cfg.adjust_underline_position.?);
    try testing.expectEqual(CursorStyle.bar, cfg.cursor_style);
    try testing.expectEqual(palette.Preset.nord, cfg.palette.?);
    try testing.expectEqual(palette.Color{ .r = 1, .g = 2, .b = 3 }, cfg.custom_palette[0]);
    try testing.expectEqual(palette.Color{ .r = 255, .g = 0, .b = 0 }, cfg.custom_palette[16]);
    // custom palette overrides only apply when palette=custom.
    try testing.expectEqual(palette.Preset.nord.get(), cfg.effectivePalette());
    // Nothing locked: file options never set CONF_LOCKED.
    for (std.meta.tags(Option)) |o| try testing.expect(!cfg.locked.get(o));
}

test "CLI: value forms, short forms, bundles, attached values" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{ "--sb-size", "42", "--term=foot", "-c", "/etc/x", "-tlinux", "-vh" });
    try testing.expectEqual(@as(u32, 42), cfg.sb_size);
    // -tlinux attaches its value to the short form and wins over --term=foot.
    try testing.expectEqualStrings("linux", cfg.term);
    try testing.expectEqualStrings("/etc/x", cfg.configdir);
    try testing.expect(cfg.verbose);
    try testing.expect(cfg.help);
    try testing.expect(cfg.locked.get(.sb_size));
    try testing.expect(cfg.locked.get(.term));
    try testing.expect(cfg.locked.get(.configdir));
    try testing.expect(cfg.locked.get(.verbose));
    try testing.expect(cfg.locked.get(.help));

    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try cliOk(&cfg2, &.{"-c/etc/y"});
    try testing.expectEqualStrings("/etc/y", cfg2.configdir);
}

test "CLI: no- negation, last one wins" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{ "--no-mouse", "--no-switchvt", "--bell", "--no-blink", "--sb-size=1", "--sb-size=9" });
    try testing.expect(!cfg.mouse);
    try testing.expect(!cfg.switchvt);
    try testing.expect(cfg.bell);
    try testing.expect(!cfg.blink);
    try testing.expectEqual(@as(u32, 9), cfg.sb_size);
    try testing.expect(cfg.locked.get(.mouse));
    // no- on an argument-taking option is not registered.
    var d = Diag{};
    try testing.expectError(error.UnknownOption, cfg.parseCli(&.{"--no-sb-size=3"}, &d));
}

test "CLI: help and version return flags and set exit" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{"--help"});
    try testing.expect(cfg.help and cfg.exit);

    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try cliOk(&cfg2, &.{"-V"});
    try testing.expect(cfg2.version and cfg2.exit);
}

test "CLI: unknown option is a typed error naming it" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.UnknownOption, cfg.parseCli(&.{"--bogus"}, &d));
    try testing.expect(std.mem.indexOf(u8, cfg.error_message.?, "--bogus") != null);
    try testing.expectError(error.UnknownOption, cfg.parseCli(&.{"-z"}, &d));
}

test "CLI: missing and unexpected arguments are typed errors" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.MissingArgument, cfg.parseCli(&.{"--sb-size"}, &d));
    try testing.expect(std.mem.indexOf(u8, cfg.error_message.?, "sb-size") != null);
    try testing.expectError(error.MissingArgument, cfg.parseCli(&.{"-c"}, &d));
    try testing.expectError(error.UnexpectedArgument, cfg.parseCli(&.{"--mouse=1"}, &d));
    try testing.expectError(error.UnexpectedArgument, cfg.parseCli(&.{"--no-mouse=1"}, &d));
}

test "CLI: invalid values are typed errors naming the option" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.InvalidValue, cfg.parseCli(&.{"--gpus=bogus"}, &d));
    try testing.expectError(error.InvalidValue, cfg.parseCli(&.{"--grab-scroll-up=<Shift>up"}, &d));
    try testing.expectError(error.InvalidValue, cfg.parseCli(&.{"--mode=0x100"}, &d));
}

test "CLI: login consumes everything after --" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{ "--login", "--", "/bin/bash", "-i", "--not-an-option" });
    try testing.expect(cfg.login);
    try testing.expectEqual(@as(usize, 3), cfg.login_argv.len);
    try testing.expectEqualStrings("/bin/bash", cfg.login_argv[0]);
    try testing.expectEqualStrings("-i", cfg.login_argv[1]);
    try testing.expectEqualStrings("--not-an-option", cfg.login_argv[2]);

    // -l short form; options before -- still apply.
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try cliOk(&cfg2, &.{ "-l", "--bell", "--", "/bin/sh" });
    try testing.expect(cfg2.login and cfg2.bell);
    try testing.expectEqualStrings("/bin/sh", cfg2.login_argv[0]);
}

test "CLI: login without remaining args is an error" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.MissingLoginArguments, cfg.parseCli(&.{"--login"}, &d));
    try testing.expectError(error.MissingLoginArguments, cfg.parseCli(&.{"--login", "--"}, &d));
}

test "CLI: positional args need login; getopt permutation applies" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.UnparsedArguments, cfg.parseCli(&.{"stray"}, &d));
    try testing.expect(std.mem.indexOf(u8, cfg.error_message.?, "stray") != null);
    // Positionals before options are permuted to the end (GNU getopt).
    try cliOk(&cfg, &.{ "--login", "/bin/bash", "--bell", "extra" });
    try testing.expect(cfg.login);
    try testing.expect(cfg.bell);
    try testing.expectEqual(@as(usize, 2), cfg.login_argv.len);
    try testing.expectEqualStrings("/bin/bash", cfg.login_argv[0]);
    try testing.expectEqualStrings("extra", cfg.login_argv[1]);
    // Without "--", "-i" looks like a short option, not a login argument.
    var cfg3 = Config.init(testing.allocator);
    defer cfg3.deinit();
    try testing.expectError(error.UnknownOption, cfg3.parseCli(&.{ "--login", "-i" }, &d));
    // Without --login, args after -- are unparsed leftovers.
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try testing.expectError(error.UnparsedArguments, cfg2.parseCli(&.{ "--", "x" }, &d));
}

test "CLI: no-login restores the default argv" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{"--no-login"});
    try testing.expect(!cfg.login);
    try testing.expectEqualStrings("/bin/login", cfg.login_argv[0]);
    try testing.expectEqualStrings("-p", cfg.login_argv[1]);
}

test "file: comments, whitespace, bare bools, no- negation, empty values" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg,
        \\### General Options ###
        \\  # indented comment
        \\mouse # trailing comment
        \\no-blink
        ++ "\n  sb-size\t=  77  \n" ++
        \\term = my term # comment
        \\asciicast=
        \\
    );
    try testing.expect(cfg.mouse);
    try testing.expect(!cfg.blink);
    try testing.expectEqual(@as(u32, 77), cfg.sb_size);
    try testing.expectEqualStrings("my term", cfg.term);
    try testing.expectEqualStrings("", cfg.asciicast.?);
}

test "file: unknown keys warn and skip" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "rotate=normal\nseats=seat0\nbell\n");
    try testing.expect(cfg.bell);
    try testing.expectEqual(@as(usize, 2), cfg.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, cfg.warnings.items[0], "rotate") != null);
    try testing.expect(std.mem.indexOf(u8, cfg.warnings.items[1], "seats") != null);
}

test "file: bool with value and missing value abort the load" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.UnexpectedArgument, cfg.parseFileText("mouse=1\n", &d));
    try testing.expect(std.mem.indexOf(u8, cfg.error_message.?, "mouse") != null);
    try testing.expectError(error.MissingValue, cfg.parseFileText("sb-size\n", &d));
    try testing.expectError(error.MissingValue, cfg.parseFileText("login\n", &d));
    // A bad value aborts too, and later lines are not applied.
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try testing.expectError(error.InvalidValue, cfg2.parseFileText("sb-size=abc\nbell\n", &d));
    try testing.expect(!cfg2.bell);
}

test "file: unterminated key at EOF is an error (doc overflow rule)" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    var d = Diag{};
    try testing.expectError(error.UnterminatedKey, cfg.parseFileText("bell\nmouse", &d));
    // With a trailing newline, or a '=' / '#' terminator, it is fine.
    try fileOk(&cfg, "bell\nmouse\n");
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try fileOk(&cfg2, "term=abc");
    try testing.expectEqualStrings("abc", cfg2.term);
    var cfg3 = Config.init(testing.allocator);
    defer cfg3.deinit();
    try fileOk(&cfg3, "mouse # comment");
    try testing.expect(cfg3.mouse);
}

test "file: no- prefix is recognized for every option, meaningful for bools" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    // kmscon: non-bool parsers ignore `on`, so no-sb-size still parses.
    try fileOk(&cfg, "no-sb-size=5\nno-mouse\nno-login=/bin/sh\n");
    try testing.expectEqual(@as(u32, 5), cfg.sb_size);
    try testing.expect(!cfg.mouse);
    try testing.expect(!cfg.login); // file_login sets login=on=false
    try testing.expectEqualStrings("/bin/sh", cfg.login_argv[0]);
}

test "file: login shell-split vs CLI argv (the CLI-vs-file difference)" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "login=/bin/sh -c 'echo hi there'\n");
    try testing.expect(cfg.login);
    try testing.expectEqual(@as(usize, 3), cfg.login_argv.len);
    try testing.expectEqualStrings("echo hi there", cfg.login_argv[2]);
    // Empty login value is fatal.
    var d = Diag{};
    try testing.expectError(error.InvalidValue, cfg.parseFileText("login=\"\"\n", &d));
    try testing.expectError(error.InvalidValue, cfg.parseFileText("login='unclosed\n", &d));
}

test "uint bounds: sb-size 0 and max, dpms-timeout 0, overflow rejected" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "sb-size=0\ndpms-timeout=0\nsession-max=4294967295\n");
    try testing.expectEqual(@as(u32, 0), cfg.sb_size);
    try testing.expectEqual(@as(u32, 0), cfg.dpms_timeout);
    try testing.expectEqual(@as(u32, 4294967295), cfg.session_max);
    try fileOk(&cfg, "sb-size=4294967295\n");
    try testing.expectEqual(@as(u32, 4294967295), cfg.sb_size);
    var d = Diag{};
    inline for (.{ "sb-size=4294967296", "sb-size=-1", "sb-size=12x", "sb-size=", "dpms-timeout=1.5" }) |bad| {
        var c = Config.init(testing.allocator);
        defer c.deinit();
        try testing.expectError(error.InvalidValue, c.parseFileText(bad ++ "\n", &d));
        try testing.expect(std.mem.indexOf(u8, c.error_message.?, bad[0 .. std.mem.indexOfScalar(u8, bad, '=').?]) != null);
    }
}

test "kitty-image-storage-limit: default, CLI and file parse" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 10485760), cfg.kitty_image_storage_limit);

    try cliOk(&cfg, &.{ "--kitty-image-storage-limit", "123" });
    try testing.expectEqual(@as(u32, 123), cfg.kitty_image_storage_limit);
    try testing.expect(cfg.locked.get(.kitty_image_storage_limit));

    var file_cfg = Config.init(testing.allocator);
    defer file_cfg.deinit();
    try fileOk(&file_cfg, "kitty-image-storage-limit=456\n");
    try testing.expectEqual(@as(u32, 456), file_cfg.kitty_image_storage_limit);

    // 0 is valid and disables the protocol.
    try fileOk(&file_cfg, "kitty-image-storage-limit=0\n");
    try testing.expectEqual(@as(u32, 0), file_cfg.kitty_image_storage_limit);

    var d = Diag{};
    var bad_cfg = Config.init(testing.allocator);
    defer bad_cfg.deinit();
    try testing.expectError(error.InvalidValue, bad_cfg.parseFileText("kitty-image-storage-limit=4294967296\n", &d));
    try testing.expect(std.mem.indexOf(u8, bad_cfg.error_message.?, "kitty-image-storage-limit") != null);
}

test "clipboard-read/write: default off, CLI and file parse" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try testing.expect(!cfg.clipboard_read);
    try testing.expect(!cfg.clipboard_write);
    try cliOk(&cfg, &.{ "--clipboard-read", "--clipboard-write" });
    try testing.expect(cfg.clipboard_read);
    try testing.expect(cfg.clipboard_write);
    try testing.expect(cfg.locked.get(.clipboard_read));
    try testing.expect(cfg.locked.get(.clipboard_write));

    var file_cfg = Config.init(testing.allocator);
    defer file_cfg.deinit();
    try fileOk(&file_cfg, "clipboard-read\nno-clipboard-write\n");
    try testing.expect(file_cfg.clipboard_read);
    try testing.expect(!file_cfg.clipboard_write);
}

test "gui-osc: default off, CLI and file parse" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try testing.expect(!cfg.gui_osc);
    try cliOk(&cfg, &.{"--gui-osc"});
    try testing.expect(cfg.gui_osc);
    var file_cfg = Config.init(testing.allocator);
    defer file_cfg.deinit();
    try fileOk(&file_cfg, "gui-osc\n");
    try testing.expect(file_cfg.gui_osc);
}

test "vt: numeric, name, path and base-0 quirks" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "vt=2\n");
    try testing.expectEqualStrings("/dev/tty2", cfg.vt.?);
    try fileOk(&cfg, "vt=tty3\n");
    try testing.expectEqualStrings("/dev/tty3", cfg.vt.?);
    try fileOk(&cfg, "vt=./mytty\n");
    try testing.expectEqualStrings("./mytty", cfg.vt.?);
    try fileOk(&cfg, "vt=/dev/ttyS0\n");
    try testing.expectEqualStrings("/dev/ttyS0", cfg.vt.?);
    // shl_strtou uses base 0: octal and hex are numbers too.
    try fileOk(&cfg, "vt=010\n");
    try testing.expectEqualStrings("/dev/tty8", cfg.vt.?);
    try fileOk(&cfg, "vt=0x10\n");
    try testing.expectEqualStrings("/dev/tty16", cfg.vt.?);
    try fileOk(&cfg, "vt=\n");
    try testing.expectEqualStrings("", cfg.vt.?);
}

test "gpus: aliases and invalid value" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "gpus=auxiliary\n");
    try testing.expectEqual(Gpus.aux, cfg.gpus);
    try fileOk(&cfg, "gpus=single\n");
    try testing.expectEqual(Gpus.primary, cfg.gpus);
    try fileOk(&cfg, "gpus=all\n");
    try testing.expectEqual(Gpus.all, cfg.gpus);
    try fileOk(&cfg, "gpus=aux\n");
    try testing.expectEqual(Gpus.aux, cfg.gpus);
    try fileOk(&cfg, "gpus=primary\n");
    try testing.expectEqual(Gpus.primary, cfg.gpus);
    var d = Diag{};
    try testing.expectError(error.InvalidValue, cfg.parseFileText("gpus=secondary\n", &d));
}

test "font-engine: pango aliases freetype, unknown falls back to unset" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "font-engine=pango\n");
    try testing.expectEqual(FontEngine.freetype, cfg.font_engine.?);
    try fileOk(&cfg, "font-engine=freetype\n");
    try testing.expectEqual(FontEngine.freetype, cfg.font_engine.?);
    try fileOk(&cfg, "font-engine=psf\n");
    try testing.expectEqual(FontEngine.psf, cfg.font_engine.?);
    try fileOk(&cfg, "font-engine=unifont\n");
    try testing.expectEqual(FontEngine.unifont, cfg.font_engine.?);
    try fileOk(&cfg, "font-engine=8x16\n");
    try testing.expectEqual(FontEngine.@"8x16", cfg.font_engine.?);
    try fileOk(&cfg, "font-engine=bogus\n");
    try testing.expectEqual(@as(?FontEngine, null), cfg.font_engine);
}

test "multi-monitor: default scaled, unknown values behave as clone" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try testing.expectEqual(MultiMonitor.scaled, cfg.multi_monitor);
    try fileOk(&cfg, "multi-monitor=largest\n");
    try testing.expectEqual(MultiMonitor.largest, cfg.multi_monitor);
    try fileOk(&cfg, "multi-monitor=clone\n");
    try testing.expectEqual(MultiMonitor.clone, cfg.multi_monitor);
    try fileOk(&cfg, "multi-monitor=anything-else\n");
    try testing.expectEqual(MultiMonitor.clone, cfg.multi_monitor);
}

test "palette: presets incl nord, unknown is legacy, custom uses overrides" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "palette=nord\n");
    try testing.expectEqual(palette.Preset.nord, cfg.palette.?);
    try testing.expectEqual(palette.Preset.nord.get(), cfg.effectivePalette());
    try testing.expectEqual(palette.Color{ .r = 46, .g = 52, .b = 64 }, cfg.effectivePalette()[17]);
    try fileOk(&cfg, "palette=bogus\n");
    try testing.expectEqual(@as(?palette.Preset, null), cfg.palette);
    try testing.expectEqual(palette.Preset.legacy.get(), cfg.effectivePalette());
    try fileOk(&cfg, "palette=custom\npalette-red=10,20,30\npalette-background=1,2,3\n");
    const eff = cfg.effectivePalette();
    try testing.expectEqual(palette.Color{ .r = 10, .g = 20, .b = 30 }, eff[1]);
    try testing.expectEqual(palette.Color{ .r = 1, .g = 2, .b = 3 }, eff[17]);
    try testing.expectEqual(palette.Color{ .r = 0, .g = 0, .b = 0 }, eff[0]);
    // All preset names round-trip.
    for (std.meta.tags(palette.Preset)) |p| {
        var c = Config.init(testing.allocator);
        defer c.deinit();
        const line = try std.fmt.allocPrint(testing.allocator, "palette={s}\n", .{p.kmsconName()});
        defer testing.allocator.free(line);
        try fileOk(&c, line);
        try testing.expectEqual(p, c.palette.?);
    }
}

test "color: spaces after commas, base-0 components, bounds and arity" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg, "palette-foreground=255, 0, 0\n");
    try testing.expectEqual(palette.Color{ .r = 255, .g = 0, .b = 0 }, cfg.custom_palette[16]);
    try fileOk(&cfg, "palette-red=0xff,010,0x0\n");
    try testing.expectEqual(palette.Color{ .r = 255, .g = 8, .b = 0 }, cfg.custom_palette[1]);
    var d = Diag{};
    inline for (.{
        "palette-red=256,0,0", "palette-red=1,2", "palette-red=1,2,3,4",
        "palette-red=1,,3",    "palette-red=-1,0,0", "palette-red=1,2,x",
    }) |bad| {
        var c = Config.init(testing.allocator);
        defer c.deinit();
        try testing.expectError(error.InvalidValue, c.parseFileText(bad ++ "\n", &d));
        try testing.expect(std.mem.indexOf(u8, c.error_message.?, "palette-red") != null);
    }
}

test "mode and screen: repeatable append, three-tier lookup via Config" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{
        "--mode=card0[HDMI-A-1]1920x1080@60",
        "--mode", "[HDMI-A-1]1280x720",
        "--mode=800x600",
        "--screen=card0[HDMI-A-1]right",
        "--screen=[HDMI-A-1]left",
        "--screen=upside-down",
    });
    try testing.expectEqual(@as(usize, 3), cfg.modes.items.len);
    try testing.expectEqual(@as(usize, 3), cfg.screens.items.len);
    try testing.expectEqual(@as(u32, 1920), cfg.getMode("card0", "HDMI-A-1").?.width);
    try testing.expectEqual(@as(u32, 1280), cfg.getMode("card1", "HDMI-A-1").?.width);
    try testing.expectEqual(@as(u32, 800), cfg.getMode("card1", "DP-9").?.width);
    // A global mode matches any display (tier 3).
    try testing.expectEqual(@as(u32, 800), cfg.getMode("card0", "X").?.width);
    // Without a global entry, an unmatched display has no mode.
    const no_global = [_]Mode{.{ .gpu = "card0", .connector = "HDMI-A-1", .width = 1, .height = 1 }};
    try testing.expectEqual(@as(?Mode, null), display.getMode(&no_global, "card0", "X"));
    try testing.expectEqual(Orientation.right, cfg.getScreen("card0", "HDMI-A-1").orientation);
    try testing.expectEqual(Orientation.left, cfg.getScreen("card1", "HDMI-A-1").orientation);
    try testing.expectEqual(Orientation.upside_down, cfg.getScreen("card1", "DP-9").orientation);
    // use-original-mode is cleared when modes exist (CLI aftercheck).
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try cliOk(&cfg2, &.{ "--use-original-mode", "--mode=800x600" });
    try testing.expect(!cfg2.use_original_mode);
    try testing.expectEqual(@as(usize, 1), cfg2.warnings.items.len);
    // Alone it stays on.
    var cfg3 = Config.init(testing.allocator);
    defer cfg3.deinit();
    try cliOk(&cfg3, &.{"--use-original-mode"});
    try testing.expect(cfg3.use_original_mode);
}

test "grabs through config: override dual defaults, disable with empty" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{ "--grab-zoom-in=<Ctrl><Shift>plus", "--grab-rotate-cw=", "--grab-reboot=<Ctrl><Alt>Delete" });
    try testing.expectEqual(@as(usize, 1), cfg.grab_zoom_in.shortcuts.len);
    try testing.expect(cfg.grab_zoom_in.matches(grab.control | grab.shift, &.{0x2b}));
    try testing.expect(!cfg.grab_zoom_in.matches(grab.control, &.{0x3d}));
    try testing.expectEqual(@as(usize, 0), cfg.grab_rotate_cw.shortcuts.len);
    try testing.expect(cfg.grab_reboot.matches(grab.control | grab.alt, &.{0xffff}));
}

test "debug implies verbose, in CLI and file" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try cliOk(&cfg, &.{"--debug"});
    try testing.expect(cfg.debug and cfg.verbose);
    var cfg2 = Config.init(testing.allocator);
    defer cfg2.deinit();
    try fileOk(&cfg2, "debug\n");
    try testing.expect(cfg2.debug and cfg2.verbose);
}

test "load: CLI overrides file (CONF_LOCKED), file fills the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmpPath(alloc, &tmp, "");
    defer alloc.free(dir);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kmshaunt.conf",
        .data = "sb-size=111\nbell\nterm=from-file\nxkb-layout=de\n",
    });
    var cfg = try Config.load(alloc, testing.io, &.{ "--configdir", dir, "--sb-size=333", "--term=from-cli" });
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 333), cfg.sb_size); // CLI wins
    try testing.expectEqualStrings("from-cli", cfg.term); // CLI wins
    try testing.expect(cfg.bell); // file applies
    try testing.expectEqualStrings("de", cfg.xkb_layout.?); // file applies
    try testing.expect(cfg.locked.get(.sb_size));
    try testing.expect(!cfg.locked.get(.bell));
}

test "load: --configdir changes the discovery root; missing file is fine" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmpPath(alloc, &tmp, "");
    defer alloc.free(dir);
    // No file yet: defaults survive.
    var cfg2 = try Config.load(alloc, testing.io, &.{ "--configdir", dir });
    defer cfg2.deinit();
    try testing.expectEqual(@as(u32, 1000), cfg2.sb_size);
    // Now create the file and reload.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kmshaunt.conf", .data = "sb-size=55\n" });
    var cfg3 = try Config.load(alloc, testing.io, &.{ "-c", dir });
    defer cfg3.deinit();
    try testing.expectEqual(@as(u32, 55), cfg3.sb_size);
}

test "load: help/version skip file loading" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmpPath(alloc, &tmp, "");
    defer alloc.free(dir);
    // A file that would fail to parse must not be read.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kmshaunt.conf", .data = "sb-size=garbage\n" });
    var cfg = try Config.load(alloc, testing.io, &.{ "--configdir", dir, "--help" });
    defer cfg.deinit();
    try testing.expect(cfg.help and cfg.exit);
    try testing.expectEqual(@as(u32, 1000), cfg.sb_size);
}

test "load: unreadable config file is AccessDenied" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest; // root reads everything
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmpPath(alloc, &tmp, "");
    defer alloc.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kmshaunt.conf", .data = "bell\n" });
    try tmp.dir.setFilePermissions(testing.io, "kmshaunt.conf", std.Io.File.Permissions.fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(testing.io, "kmshaunt.conf", std.Io.File.Permissions.fromMode(0o644), .{}) catch {};
    try testing.expectError(error.AccessDenied, Config.load(alloc, testing.io, &.{ "--configdir", dir }));
}

test "seat: main file < seat file < CLI, locks inherited" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmpPath(alloc, &tmp, "");
    defer alloc.free(dir);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kmshaunt.conf",
        .data = "sb-size=111\nbell\nterm=from-file\nxkb-layout=de\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "seat0.seat.conf",
        .data = "sb-size=222\nno-bell\nterm=from-seat\nxkb-layout=us\n",
    });
    var main = try Config.load(alloc, testing.io, &.{ "--configdir", dir, "--sb-size=333", "--term=from-cli" });
    defer main.deinit();
    var seat = try main.loadSeat(alloc, testing.io, "seat0");
    defer seat.deinit();
    try testing.expectEqual(@as(u32, 333), seat.sb_size); // CLI lock survives
    try testing.expectEqualStrings("from-cli", seat.term); // CLI lock survives
    try testing.expect(!seat.bell); // seat file overrides main file
    try testing.expectEqualStrings("us", seat.xkb_layout.?); // seat file overrides main file
    try testing.expect(seat.locked.get(.sb_size));
    try testing.expect(!seat.locked.get(.bell));
    // The main context is untouched by the seat layer.
    try testing.expect(main.bell);
    try testing.expectEqualStrings("de", main.xkb_layout.?);
    // A seat without a seat file just copies main.
    var seat1 = try main.loadSeat(alloc, testing.io, "seat1");
    defer seat1.deinit();
    try testing.expect(seat1.bell);
    try testing.expectEqual(@as(u32, 333), seat1.sb_size);
    try testing.expectEqualStrings("de", seat1.xkb_layout.?);
}

test "seat: deep copy owns its strings, lists and grabs" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try fileOk(&cfg,
        \\login=/bin/bash -i
        \\mode=card0[HDMI-A-1]1920x1080@60
        \\screen=[DP-1]left
        \\grab-zoom-in=<Ctrl>plus,<Ctrl>equal
        \\vt=4
        \\cursor-style=bar
        \\palette=custom
        \\palette-red=9,9,9
        \\
    );
    var seat = try cfg.loadSeat(testing.allocator, testing.io, "seat0");
    defer seat.deinit();
    try testing.expectEqualStrings("/bin/bash", seat.login_argv[0]);
    try testing.expectEqual(@as(usize, 1), seat.modes.items.len);
    try testing.expectEqualStrings("card0", seat.modes.items[0].gpu);
    try testing.expectEqual(@as(usize, 1), seat.screens.items.len);
    try testing.expectEqual(Orientation.left, seat.screens.items[0].orientation);
    try testing.expectEqual(@as(usize, 2), seat.grab_zoom_in.shortcuts.len);
    try testing.expect(seat.grab_zoom_in.matches(grab.control, &.{0x3d}));
    try testing.expectEqualStrings("/dev/tty4", seat.vt.?);
    try testing.expectEqual(CursorStyle.bar, seat.cursor_style);
    try testing.expectEqual(palette.Color{ .r = 9, .g = 9, .b = 9 }, seat.custom_palette[1]);
    // Mutating the seat must not touch main (independent arenas).
    seat.custom_palette[1] = .{ .r = 0, .g = 0, .b = 0 };
    try testing.expectEqual(palette.Color{ .r = 9, .g = 9, .b = 9 }, cfg.custom_palette[1]);
}

test "help text keeps the kmscon shape and quirks" {
    // --multi-monitor is a real option but absent from --help.
    try testing.expect(std.mem.indexOf(u8, help_text, "multi-monitor") == null);
    // The comptime conversion turned the `\t` markers into real tabs.
    try testing.expect(std.mem.indexOfScalar(u8, help_text, '\t') != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "\\t") == null);
    try testing.expect(std.mem.indexOf(u8, help_text, "General Options:") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "Grabs / Keyboard-Shortcuts:") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "Palette Options:") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "[/etc/kmshaunt]") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "[xterm-ghostty]") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "Reboot the system (disabled by default)") != null);
    // Every option name except multi-monitor appears in the help.
    for (specs) |s| {
        if (s.opt == .multi_monitor) continue;
        const needle = try std.fmt.allocPrint(testing.allocator, "--{s}", .{s.name});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, help_text, needle) != null);
    }
}
