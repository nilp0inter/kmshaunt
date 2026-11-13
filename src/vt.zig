//! src/vt.zig -- the single Zig wrapper over the libghostty-vt 1.0.1 C API
//! (ROADMAP D1, M1.5). This is the ONLY file that touches libghostty-vt;
//! everything else in kmshaunt goes through the types below.
//!
//! The C bindings come from module "vt-c" (build.zig's b.addTranslateC of
//! src/vt-c.h, which includes <ghostty/vt.h>). API reference:
//! docs/reference/ghostty-vt-api.md (section numbers cited below refer to it).
//!
//! Conventions
//! -----------
//! - Every fallible C call returns GhosttyResult; `check` maps all nine codes
//!   to the Zig `Error` set (§0.1).
//! - Sized C structs (a leading `size_t size` field) are initialized with
//!   `.size = @sizeOf(T)` -- the GHOSTTY_INIT_SIZED equivalent (§0.2).
//! - Borrowed memory: slices returned by this wrapper point into library or
//!   terminal-owned storage. Each accessor documents its lifetime; the
//!   general rule is "valid until the next mutating terminal call" (§0.3).
//! - The terminal is not thread-safe (D2: one loop thread). Effect callbacks
//!   fire SYNCHRONOUSLY inside `Vt.write` and MUST NOT reenter the terminal
//!   (no write/reset/resize on the same terminal from a callback, §0.4).
//! - All library allocations use the default allocator (NULL); the wrapper
//!   never injects a Zig allocator into the library.
//!
//! Standalone test recipe (no build.zig needed; run from the repo root):
//!
//!   # 1. Bindings. Zig 0.17 caches the fetched dep as a tarball under
//!   #    ~/.cache/zig/p/. Extract its include dir and translate src/vt-c.h
//!   #    (the result is byte-identical to build.zig's addTranslateC output):
//!   PKG=ghostty-1.4.1-dev-5UdBC7mPUgFIzAVXNJOixiryPYogwYwnmN0zZWud4iSr
//!   mkdir -p /tmp/ghostty-dep
//!   tar -xzf ~/.cache/zig/p/$PKG.tar.gz -C /tmp/ghostty-dep $PKG/include
//!   zig translate-c src/vt-c.h -I /tmp/ghostty-dep/$PKG/include -lc > /tmp/vt_c.zig
//!   # 2. Built library: `zig build` leaves libghostty-vt.so under
//!   #    .zig-cache/o/<hash>/ (find it with: fd libghostty-vt .zig-cache).
//!   # 3. Run the tests:
//!   zig test --dep vt-c -Mroot=src/vt.zig -Mvt-c=/tmp/vt_c.zig \
//!       -lc -L.zig-cache/o/16861fd85abb75eb4433b66ad767d202 -lghostty-vt
//!
//!   (`zig` = Zig 0.17.1, e.g. `nix run nixpkgs#zig --`. The exact command
//!   verified for this file is repeated in the completion report; the -L
//!   directory is whichever .zig-cache/o/<hash> holds libghostty-vt.so.)

const std = @import("std");
const c = @import("vt-c");
const keymap = @import("input/keymap_table.zig");

// ---------------------------------------------------------------------------
// Errors (§0.1)
// ---------------------------------------------------------------------------

/// Every GhosttyResult code mapped to a Zig error. `NoValue` is a normal
/// "nothing there" answer for optional data (getters translate it to null
/// where that reads better); `Rejected` is the paste safety refusal (retry
/// with allow_unsafe after user confirmation); `Unsupported` means the
/// library predates the key or the feature was compiled out.
pub const Error = error{
    OutOfMemory, // GHOSTTY_OUT_OF_MEMORY (-1)
    InvalidValue, // GHOSTTY_INVALID_VALUE (-2)
    OutOfSpace, // GHOSTTY_OUT_OF_SPACE (-3): caller buffer too small
    NoValue, // GHOSTTY_NO_VALUE (-4)
    IoError, // GHOSTTY_IO_ERROR (-5)
    LimitExceeded, // GHOSTTY_LIMIT_EXCEEDED (-6)
    Rejected, // GHOSTTY_REJECTED (-7)
    Unsupported, // GHOSTTY_UNSUPPORTED (-8)
};

fn check(result: c.GhosttyResult) Error!void {
    return switch (result) {
        c.GHOSTTY_SUCCESS => {},
        c.GHOSTTY_OUT_OF_MEMORY => Error.OutOfMemory,
        c.GHOSTTY_INVALID_VALUE => Error.InvalidValue,
        c.GHOSTTY_OUT_OF_SPACE => Error.OutOfSpace,
        c.GHOSTTY_NO_VALUE => Error.NoValue,
        c.GHOSTTY_IO_ERROR => Error.IoError,
        c.GHOSTTY_LIMIT_EXCEEDED => Error.LimitExceeded,
        c.GHOSTTY_REJECTED => Error.Rejected,
        c.GHOSTTY_UNSUPPORTED => Error.Unsupported,
        // Not reachable with a 1.0.1 library; fail closed on future codes.
        else => Error.InvalidValue,
    };
}

/// The loaded library's version string (e.g. "1.0.1"). Library-owned,
/// never freed (§1.2).
pub fn version() []const u8 {
    return std.mem.span(c.ghostty_version());
}

// ---------------------------------------------------------------------------
// Small value types
// ---------------------------------------------------------------------------

/// 24-bit RGB color, layout-identical to GhosttyColorRgb (color.h:66).
pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const ColorScheme = enum(c_uint) { light = 0, dark = 1 };

pub const CursorStyle = enum(c_uint) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
};

pub const ActiveScreen = enum(c_uint) { primary = 0, alternate = 1 };

pub const ClipboardLocation = enum(c_uint) {
    standard = 0,
    selection = 1,
    primary = 2,
};

pub const OscTerminator = enum(c_uint) { st = 0, bel = 1 };

pub const Dirty = enum(c_uint) {
    /// GHOSTTY_RENDER_STATE_DIRTY_FALSE: nothing to draw.
    clean = 0,
    partial = 1,
    full = 2,
};

pub const Wide = enum(c_uint) {
    narrow = 0,
    wide = 1,
    /// Second column of a wide char: draw nothing.
    spacer_tail = 2,
    /// End-of-line spacer after a wide char on a soft wrap.
    spacer_head = 3,
};

pub const ImageProtocol = enum(c_uint) { kitty = 0 };

pub const ImageLayer = enum(c_uint) {
    below_background = 0,
    below_text = 1,
    above_text = 2,
};

pub const KittyPlacementKind = enum(c_uint) {
    virtual = 0,
    relative = 1,
    fixed = 2,
};

pub const KittyImageFormat = enum(c_uint) {
    rgb = 0,
    rgba = 1,
    /// Never returned for stored images (always fully decoded, §9.2).
    png = 2,
    gray_alpha = 3,
    gray = 4,
};

pub const MouseShape = enum(c_uint) {
    default = 0,
    context_menu = 1,
    help = 2,
    pointer = 3,
    progress = 4,
    wait = 5,
    cell = 6,
    crosshair = 7,
    text = 8,
    vertical_text = 9,
    alias = 10,
    copy = 11,
    move = 12,
    no_drop = 13,
    not_allowed = 14,
    grab = 15,
    grabbing = 16,
    all_scroll = 17,
    col_resize = 18,
    row_resize = 19,
    n_resize = 20,
    e_resize = 21,
    s_resize = 22,
    w_resize = 23,
    ne_resize = 24,
    nw_resize = 25,
    se_resize = 26,
    sw_resize = 27,
    ew_resize = 28,
    ns_resize = 29,
    nesw_resize = 30,
    nwse_resize = 31,
    zoom_in = 32,
    zoom_out = 33,
};

pub const MouseAction = enum(c_uint) { press = 0, release = 1, motion = 2 };

pub const MouseButton = enum(c_uint) {
    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
    nine = 9,
    ten = 10,
    eleven = 11,
};

pub const PasteSource = enum(c_uint) { clipboard = 0, text = 1 };

pub const PointTag = enum(c_uint) {
    active = 0,
    viewport = 1,
    screen = 2,
    history = 3,
};

/// A cell coordinate. `y` is u32 because history rows exceed u16.
pub const Point = struct { x: u16, y: u32 };

/// Surface-space position in pixels (f64, as the gesture API uses).
pub const SurfacePosition = struct { x: f64, y: f64 };

pub const Scrollbar = extern struct {
    total: u64,
    offset: u64,
    len: u64,
};

/// Viewport scroll behavior (§2.5). The viewport is the visible window
/// into the active screen plus its scrollback; scrolling it moves what is
/// displayed without touching the cursor or the program. `delta` and
/// `delta_prompt` are signed line counts (up/back is negative); `row` is
/// an absolute offset from the top of the scrollable area, in the same
/// space as `Scrollbar.offset` (clamped by the library).
pub const ScrollViewport = union(enum) {
    /// Jump to the top of the scrollback.
    top,
    /// Jump to the bottom (the active area).
    bottom,
    /// Scroll by a signed number of lines (up is negative).
    delta: isize,
    /// Scroll to an absolute row (clamped to the active area).
    row: usize,
    /// Scroll by whole prompts (OSC 133 markers); a no-op without them.
    delta_prompt: isize,
};

/// DA reply constants (device.h). Fill DeviceAttributes with these and
/// return true from the callback, or return false for the built-in VT220
/// answers (§8.3).
pub const da_conformance_vt220: u16 = 62;
pub const da_feature_ansi_color: u16 = 22;
pub const da_feature_clipboard: u16 = 52;
pub const da_device_type_vt220: u16 = 1;

/// Layout-identical to GhosttyDeviceAttributes (device.h:150). The size
/// callback receives a pointer to this; fill the sub-struct matching the
/// request (or all three) and return true.
pub const DeviceAttributes = extern struct {
    primary: Primary,
    secondary: Secondary,
    tertiary: Tertiary,

    pub const Primary = extern struct {
        conformance_level: u16,
        features: [64]u16,
        num_features: usize,
    };
    pub const Secondary = extern struct {
        device_type: u16,
        firmware_version: u16,
        rom_cartridge: u16,
    };
    pub const Tertiary = extern struct {
        unit_id: u32,
    };
};

/// Layout-identical to GhosttySizeReportSize (size_report.h:57). The size
/// callback fills this from the window geometry and returns true; the
/// library encodes the report itself (§8.3).
pub const SizeReport = extern struct {
    rows: u16,
    columns: u16,
    cell_width: u32,
    cell_height: u32,
};

comptime {
    if (@sizeOf(DeviceAttributes) != @sizeOf(c.GhosttyDeviceAttributes))
        @compileError("DeviceAttributes layout drift");
    if (@sizeOf(SizeReport) != @sizeOf(c.GhosttySizeReportSize))
        @compileError("SizeReport layout drift");
    if (@sizeOf(Rgb) != @sizeOf(c.GhosttyColorRgb))
        @compileError("Rgb layout drift");
    if (@sizeOf(Scrollbar) != @sizeOf(c.GhosttyTerminalScrollbar))
        @compileError("Scrollbar layout drift");
}

// ---------------------------------------------------------------------------
// Style (§4.4) -- the 16-byte GhosttyStyle as a Zig packed struct
// ---------------------------------------------------------------------------

pub const style_color_none: u8 = 0;
pub const style_color_palette: u8 = 1;
pub const style_color_rgb: u8 = 2;

/// A resolved style color: palette index (look it up in Colors.palette) or
/// direct RGB. `null` from Style.fg/bg/underlineColor means "terminal
/// default".
pub const StyleColor = union(enum) {
    palette: u8,
    rgb: Rgb,
};

pub const Underline = enum(u3) {
    none = 0,
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

/// GhosttyStyleFlags (style.h:140): bits 0-7 attribute flags, bits 8-10
/// underline style, bits 11-15 reserved.
pub const StyleFlags = packed struct(u16) {
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    /// Swap fg/bg when drawing.
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: Underline,
    _reserved: u5,
};

/// The 16-byte GhosttyStyle (style.h:227) mapped bit-for-bit: three
/// {tag: u8, value: u24} color slots, flags, reserved. The value field holds
/// the palette index (tag = palette) or r | g<<8 | b<<16 (tag = rgb); use
/// the fg()/bg()/underlineColor() accessors instead of reading it directly.
pub const Style = packed struct(u128) {
    fg_tag: u8,
    fg_value: u24,
    bg_tag: u8,
    bg_value: u24,
    underline_tag: u8,
    underline_value: u24,
    flags: StyleFlags,
    reserved: u16,

    pub const default: Style = .{
        .fg_tag = style_color_none,
        .fg_value = 0,
        .bg_tag = style_color_none,
        .bg_value = 0,
        .underline_tag = style_color_none,
        .underline_value = 0,
        .flags = @bitCast(@as(u16, 0)),
        .reserved = 0,
    };

    pub fn fg(self: Style) ?StyleColor {
        return styleColor(self.fg_tag, self.fg_value);
    }

    pub fn bg(self: Style) ?StyleColor {
        return styleColor(self.bg_tag, self.bg_value);
    }

    pub fn underlineColor(self: Style) ?StyleColor {
        return styleColor(self.underline_tag, self.underline_value);
    }

    pub fn isDefault(self: Style) bool {
        return self == Style.default;
    }
};

fn styleColor(tag: u8, value: u24) ?StyleColor {
    return switch (tag) {
        style_color_palette => .{ .palette = @truncate(value) },
        style_color_rgb => .{ .rgb = .{
            .r = @truncate(value),
            .g = @truncate(value >> 8),
            .b = @truncate(value >> 16),
        } },
        else => null,
    };
}

fn styleFromC(s: c.GhosttyStyle) Style {
    return .{
        .fg_tag = s.fg_color.tag,
        .fg_value = styleValueFromC(s.fg_color),
        .bg_tag = s.bg_color.tag,
        .bg_value = styleValueFromC(s.bg_color),
        .underline_tag = s.underline_color.tag,
        .underline_value = styleValueFromC(s.underline_color),
        .flags = @bitCast(s.flags),
        .reserved = s.reserved,
    };
}

fn styleValueFromC(sc: c.GhosttyStyleColor) u24 {
    return switch (sc.tag) {
        c.GHOSTTY_STYLE_COLOR_RGB => @as(u24, sc.value.rgb.r) |
            (@as(u24, sc.value.rgb.g) << 8) |
            (@as(u24, sc.value.rgb.b) << 16),
        // NONE and PALETTE both keep the low byte (0 / palette index).
        else => sc.value.palette,
    };
}

comptime {
    if (@sizeOf(Style) != 16 or @sizeOf(c.GhosttyStyle) != 16)
        @compileError("Style must stay 16 bytes");
}

// ---------------------------------------------------------------------------
// Selection values (§6.1) -- frozen layouts, cast-compatible with the C API
// ---------------------------------------------------------------------------

/// Untracked grid reference (grid_ref.h:107, frozen 16 bytes). Valid only
/// until the next mutating terminal call; install selections built from
/// refs with Vt.setSelection, which copies them into tracked state.
pub const GridRef = extern struct {
    node: ?*anyopaque = null,
    x: u16 = 0,
    y: u16 = 0,
};

/// Frozen 40-byte selection (selection.h:210). `start` may come after `end`
/// (upward drag); `rectangle` = block selection between opposite corners.
pub const Selection = extern struct {
    start: GridRef = .{},
    end: GridRef = .{},
    rectangle: bool = false,
};

comptime {
    if (@sizeOf(GridRef) != @sizeOf(c.GhosttyGridRef) or @sizeOf(GridRef) != 16)
        @compileError("GridRef layout drift");
    if (@sizeOf(Selection) != @sizeOf(c.GhosttySelection) or @sizeOf(Selection) != 40)
        @compileError("Selection layout drift");
    if (@offsetOf(Selection, "rectangle") != @offsetOf(c.GhosttySelection, "rectangle"))
        @compileError("Selection layout drift");
}

/// Inclusive row-local selection range from the render state (§4.2).
pub const SelectionRange = struct { start_x: u16, end_x: u16 };

// ---------------------------------------------------------------------------
// Sys hooks (§1.3) -- process-global, set once at startup
// ---------------------------------------------------------------------------

pub const LogLevel = enum(c_uint) {
    err = 0,
    warning = 1,
    info = 2,
    debug = 3,
};

/// Log callback. `scope` is e.g. "osc"/"kitty" (empty = default scope).
/// Both slices are borrowed for the call only. Without a callback logs are
/// discarded; release builds compile debug messages out entirely.
pub const LogFn = *const fn (
    userdata: ?*anyopaque,
    level: LogLevel,
    scope: []const u8,
    message: []const u8,
) void;

/// The allocator handed to the PNG decode callback. It is a LimitedAllocator
/// capped at 400 MB per image (docs/spikes/q2-libspng.md): `alloc` returns
/// null above the cap, which the callback MUST treat as failure. Use it ONLY
/// through these two methods (ghostty_alloc/ghostty_free); never dereference
/// the underlying vtable.
pub const ImageAllocator = struct {
    raw: [*c]const c.GhosttyAllocator,

    pub fn alloc(self: ImageAllocator, len: usize) ?[]u8 {
        const ptr = c.ghostty_alloc(self.raw, len) orelse return null;
        return ptr[0..len];
    }

    pub fn free(self: ImageAllocator, buf: []u8) void {
        c.ghostty_free(self.raw, buf.ptr, buf.len);
    }
};

/// Decoded PNG output. On success the library takes ownership of `pixels`
/// (allocated with the callback's ImageAllocator) and frees it itself;
/// `pixels.len` must equal the allocation size. Layout contract: 8-bit RGBA,
/// rows top-left first, no padding -- exactly width * height * 4 bytes.
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

/// PNG decode hook (§1.3, wired to libspng in D4). Return true after filling
/// `out`; on failure free anything you allocated and return false (the
/// library then rejects the image). Without this hook PNG kitty images are
/// rejected. `data` is borrowed for the call only.
pub const DecodePngFn = *const fn (
    userdata: ?*anyopaque,
    allocator: ImageAllocator,
    data: []const u8,
    out: *DecodedImage,
) bool;

fn sysLogTrampoline(
    userdata: ?*anyopaque,
    level: c.GhosttySysLogLevel,
    scope: [*c]const u8,
    scope_len: usize,
    message: [*c]const u8,
    message_len: usize,
) callconv(.c) void {
    const f = sys_log_fn orelse return;
    f(userdata, @enumFromInt(level), cSlice(scope, scope_len), cSlice(message, message_len));
}

fn sysDecodePngTrampoline(
    userdata: ?*anyopaque,
    allocator: [*c]const c.GhosttyAllocator,
    data: [*c]const u8,
    data_len: usize,
    out: [*c]c.GhosttySysImage,
) callconv(.c) bool {
    const f = sys_decode_png_fn orelse return false;
    var img: DecodedImage = .{ .width = 0, .height = 0, .pixels = &.{} };
    if (!f(userdata, .{ .raw = allocator }, cSlice(data, data_len), &img)) return false;
    if (img.pixels.len == 0) return false;
    out.* = .{
        .width = img.width,
        .height = img.height,
        .data = img.pixels.ptr,
        .data_len = img.pixels.len,
    };
    return true;
}

// The C sys userdata slot stays free for the host (setSysUserdata); the
// installed Zig hooks live in these process-global slots. One slot per
// hook: installing one must never clobber the other. Startup-only.
var sys_decode_png_fn: ?DecodePngFn = null;
var sys_log_fn: ?LogFn = null;

/// Install the PNG decoder (or null to disable). Process-global and NOT
/// thread-safe: call once at startup BEFORE any other library use (§0.4).
pub fn setDecodePng(f: ?DecodePngFn) Error!void {
    sys_decode_png_fn = f;
    const value: ?*const anyopaque = if (f != null) @ptrCast(&sysDecodePngTrampoline) else null;
    try check(c.ghostty_sys_set(c.GHOSTTY_SYS_OPT_DECODE_PNG, value));
}

/// Install the log callback (or null to discard logs). Same startup rules
/// as setDecodePng.
pub fn setLog(f: ?LogFn) Error!void {
    sys_log_fn = f;
    const value: ?*const anyopaque = if (f != null) @ptrCast(&sysLogTrampoline) else null;
    try check(c.ghostty_sys_set(c.GHOSTTY_SYS_OPT_LOG, value));
}

/// Install the library's built-in stderr logger ("[level](scope): message").
pub fn setLogStderr() Error!void {
    sys_log_fn = null;
    try check(c.ghostty_sys_set(c.GHOSTTY_SYS_OPT_LOG, @ptrCast(&c.ghostty_sys_log_stderr)));
}

/// The userdata passed to the sys callbacks (GHOSTTY_SYS_OPT_USERDATA).
/// Startup-only, like the other sys setters.
pub fn setSysUserdata(userdata: ?*anyopaque) Error!void {
    try check(c.ghostty_sys_set(c.GHOSTTY_SYS_OPT_USERDATA, userdata));
}

// ---------------------------------------------------------------------------
// Effects (§8) -- Zig callbacks + C trampolines, one userdata pointer
// ---------------------------------------------------------------------------

pub const ClipboardWriteResult = enum(c_uint) {
    success = 0,
    denied = 1,
    unsupported = 2,
    busy = 3,
    invalid_data = 4,
    io_error = 5,
};

pub const ClipboardReadResult = enum(c_uint) {
    success = 0,
    denied = 1,
    unsupported = 2,
    busy = 3,
    io_error = 4,
};

/// One decoded MIME representation. Layout-identical to
/// GhosttyClipboardContent (two borrowed {ptr, len} pairs), which lets the
/// trampolines cast whole arrays without copying.
pub const ClipboardContent = struct {
    mime: []const u8,
    data: []const u8,
};

comptime {
    if (@sizeOf(ClipboardContent) != @sizeOf(c.GhosttyClipboardContent) or
        @sizeOf([]const u8) != @sizeOf(c.GhosttyString))
        @compileError("ClipboardContent layout drift");
    if (@offsetOf(ClipboardContent, "data") != @offsetOf(c.GhosttyClipboardContent, "data"))
        @compileError("ClipboardContent layout drift");
}

/// OSC 52 / OSC 1337 Copy / OSC 5522 write request (§8.4). The VT stream is
/// paused while the callback runs: answer with `reply` BEFORE returning
/// (returning without replying denies the write). All slices are borrowed
/// for the call only. `contents` empty = clear the destination.
pub const ClipboardWriteRequest = struct {
    location: ClipboardLocation,
    contents: []const ClipboardContent,
    /// Requesting program name, if the protocol carries one.
    name: []const u8,
    /// Session grant already held: skip the permission prompt.
    granted: bool,
    /// May offer "remember" via the reply.
    can_remember: bool,
    reply_state: *const anyopaque,

    /// Answer the request. `remember` is only honored on success when
    /// can_remember. More than one reply is safely ignored by the library.
    pub fn reply(self: *const ClipboardWriteRequest, result: ClipboardWriteResult, remember: bool) void {
        const raw: *const c.GhosttyClipboardWrite = @ptrCast(@alignCast(self.reply_state));
        var r: c.GhosttyClipboardWriteReply = .{
            .size = @sizeOf(c.GhosttyClipboardWriteReply),
            .result = @intFromEnum(result),
            .remember = remember,
        };
        raw.reply.?(raw, &r);
    }
};

/// OSC 52 `?` / OSC 5522 read request (§8.4). Synchronous: answer with
/// `reply` before returning. `mimes` are the requested types in preference
/// order; a `list`-only request (no mimes) is served without a prompt.
pub const ClipboardReadRequest = struct {
    location: ClipboardLocation,
    mimes: []const []const u8,
    list: bool,
    name: []const u8,
    granted: bool,
    can_remember: bool,
    reply_state: *const anyopaque,

    /// Answer the request. On success pass one representation per requested
    /// mime in `contents`, and the available MIME list when `list` was set.
    /// The arrays must stay valid until reply() returns (stack arrays in the
    /// callback are fine; the library consumes them synchronously).
    pub fn reply(
        self: *const ClipboardReadRequest,
        result: ClipboardReadResult,
        contents: []const ClipboardContent,
        available: []const []const u8,
        remember: bool,
    ) void {
        const raw: *const c.GhosttyClipboardRead = @ptrCast(@alignCast(self.reply_state));
        var r: c.GhosttyClipboardReadReply = .{
            .size = @sizeOf(c.GhosttyClipboardReadReply),
            .result = @intFromEnum(result),
            .contents = if (contents.len > 0) @ptrCast(contents.ptr) else null,
            .contents_len = contents.len,
            .available = if (available.len > 0) @ptrCast(available.ptr) else null,
            .available_len = available.len,
            .remember = remember,
        };
        raw.reply.?(raw, &r);
    }
};

pub const UnknownSequenceTag = enum { apc, osc };

/// Unknown APC/OSC sequence (§8.5) -- kmscon's private setBackground /
/// setForeground OSCs land here. `content` is everything between the
/// introducer and the terminator INCLUDING the OSC number (e.g.
/// "7400;status=busy"), binary-safe, borrowed for the call only. Reply (if
/// any) goes through write_pty, terminated the same way (`terminator`).
pub const UnknownSequence = struct {
    tag: UnknownSequenceTag,
    /// Longer than UNKNOWN_MAX_BYTES or OOM.
    truncated: bool,
    content: []const u8,
    /// Only meaningful for osc.
    terminator: OscTerminator,
};

pub const DesktopNotification = struct {
    title: []const u8,
    body: []const u8,
};

pub const ProgressState = enum(c_uint) {
    remove = 0,
    set = 1,
    err = 2,
    indeterminate = 3,
    pause = 4,
};

pub const ProgressReport = struct {
    state: ProgressState,
    /// 0..100, or -1 when omitted.
    progress: i8,
};

pub const ProgramStatusState = enum(c_uint) {
    idle = 0,
    working = 1,
    done = 2,
    blocked = 3,
    err = 4,
    clear = 5,
};

pub const ProgramStatusKind = enum(c_uint) {
    none = 0,
    permission = 1,
    question = 2,
    auth = 3,
};

pub const ProgramStatus = struct {
    state: ProgramStatusState,
    kind: ProgramStatusKind,
    /// -1..100.
    progress: i8,
    id: []const u8,
    app: []const u8,
    title: []const u8,
    message: []const u8,
};

pub const SemanticPromptKind = enum(c_uint) {
    invalid = 0,
    prompt_start = 1,
    input_start = 2,
    output_start = 3,
    command_end = 4,
};

pub const SemanticPromptPromptKind = enum(c_uint) {
    primary = 0,
    right = 1,
    continuation = 2,
    secondary = 3,
};

pub const SemanticPrompt = struct {
    kind: SemanticPromptKind,
    prompt_kind: SemanticPromptPromptKind,
    exit_code: ?i32,
    command: []const u8,
    err: []const u8,
};

/// The 19 effect callbacks (§8). Register with Vt.setEffects; the struct
/// itself is the single C userdata pointer, and `userdata` below is the host
/// context handed to every Zig callback.
///
/// REENTRANCY: callbacks fire synchronously inside Vt.write (and resize, for
/// render_hold/size). They MUST NOT call write/reset/resize -- or any other
/// mutating function -- on the same terminal; nothing checks it, the bytes
/// would parse into the middle of the sequence that fired you. Keep them
/// fast and non-blocking: the VT stream is stalled while they run. Reading
/// terminal data (title, pwd, sizes) inside a callback is allowed.
///
/// A null optional callback means "ignore the request": queries get no
/// answer, device_attributes falls back to the built-in VT220 replies.
/// `write_pty` is REQUIRED for real programs -- every library-generated
/// reply flows through it, in order.
///
/// The Effects struct must outlive the terminal (or the next setEffects).
pub const Effects = struct {
    /// Host context passed as the first argument of every callback.
    userdata: ?*anyopaque = null,

    /// Single sink for every reply the library generates (§8.1). `data` is
    /// borrowed for the call only: write it to the pty master immediately.
    write_pty: *const fn (userdata: ?*anyopaque, data: []const u8) void,

    /// BEL (0x07).
    bell: ?*const fn (userdata: ?*anyopaque) void = null,
    /// OSC 0/2; `title` is the new value, borrowed for the call.
    title_changed: ?*const fn (userdata: ?*anyopaque, title: []const u8) void = null,
    /// OSC 7 / OSC 9 / OSC 1337 CurrentDir; also fires on clear (empty).
    pwd_changed: ?*const fn (userdata: ?*anyopaque, pwd: []const u8) void = null,
    /// ENQ (0x05). Return the response bytes; they must stay valid until
    /// the callback returns (a static string is fine). Empty = no response.
    enquiry: ?*const fn (userdata: ?*anyopaque) []const u8 = null,
    /// CSI > q. Return e.g. "kmshaunt 0.1"; empty = default "libghostty".
    /// Same lifetime rule as enquiry.
    xtversion: ?*const fn (userdata: ?*anyopaque) []const u8 = null,
    /// XTWINOPS CSI 14/16/18/19 t + mode 2048. Fill from the window state
    /// and return true; false suppresses the report.
    size: ?*const fn (userdata: ?*anyopaque, out: *SizeReport) bool = null,
    /// CSI ? 996 n. Fill and return true to answer CSI ? 997 ; Ps n,
    /// where Ps is 1 for dark and 2 for light.
    color_scheme: ?*const fn (userdata: ?*anyopaque, out: *ColorScheme) bool = null,
    /// DA1/2/3. Fill the matching sub-struct and return true; false = the
    /// built-in VT220 answers (CSI ? 62 ; 22 c etc.).
    device_attributes: ?*const fn (userdata: ?*anyopaque, out: *DeviceAttributes) bool = null,
    /// Must reply before returning (see ClipboardWriteRequest).
    clipboard_write: ?*const fn (userdata: ?*anyopaque, req: *const ClipboardWriteRequest) void = null,
    /// Must reply before returning (see ClipboardReadRequest). Installing
    /// this also enables kitty paste events (mode 5522).
    clipboard_read: ?*const fn (userdata: ?*anyopaque, req: *const ClipboardReadRequest) void = null,
    /// Synchronized output (mode 2026), always in pairs. While held, defer
    /// presentation; also fires held=false on reset and resize.
    render_hold: ?*const fn (userdata: ?*anyopaque, held: bool) void = null,
    /// Full reset (RIS) AFTER the terminal reset itself. Title/pwd callbacks
    /// do NOT fire for the cleared values; update your display here.
    reset: ?*const fn (userdata: ?*anyopaque) void = null,
    /// CSI 8 ; rows ; cols t. 0 = keep that dimension. The terminal is NOT
    /// resized by this; decide and call Vt.resize yourself (opt-in).
    resize_window: ?*const fn (userdata: ?*anyopaque, rows: u16, cols: u16) void = null,
    /// Complete APC/OSC the library does not implement (§8.5). Requires
    /// UNKNOWN_MAX_BYTES > 0, which setEffects sets to 2048.
    unknown_sequence: ?*const fn (userdata: ?*anyopaque, seq: UnknownSequence) void = null,
    /// OSC 9 / OSC 777.
    desktop_notification: ?*const fn (userdata: ?*anyopaque, notification: DesktopNotification) void = null,
    /// OSC 9;4 progress.
    progress_report: ?*const fn (userdata: ?*anyopaque, report: ProgressReport) void = null,
    /// OSC 7501 program status.
    program_status: ?*const fn (userdata: ?*anyopaque, report: ProgramStatus) void = null,
    /// OSC 133 shell-integration steps.
    semantic_prompt: ?*const fn (userdata: ?*anyopaque, event: SemanticPrompt) void = null,
};

fn effectsFrom(userdata: ?*anyopaque) *Effects {
    return @ptrCast(@alignCast(userdata.?));
}

fn cSlice(ptr: [*c]const u8, len: usize) []const u8 {
    if (len == 0) return &.{};
    return ptr[0..len];
}

fn toCString(s: []const u8) c.GhosttyString {
    return .{ .ptr = if (s.len > 0) s.ptr else "".ptr, .len = s.len };
}

fn writePtyTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const e = effectsFrom(userdata);
    e.write_pty(e.userdata, cSlice(data, len));
}

fn bellTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const e = effectsFrom(userdata);
    if (e.bell) |f| f(e.userdata);
}

fn titleChangedTrampoline(terminal: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.title_changed orelse return;
    // Reading data inside the callback is allowed (§8.2); the title is
    // borrowed until the next mutating call, which covers this callback.
    var title: c.GhosttyString = .{};
    const r = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_TITLE, &title);
    f(e.userdata, if (r == c.GHOSTTY_SUCCESS) cSlice(title.ptr, title.len) else &.{});
}

fn pwdChangedTrampoline(terminal: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.pwd_changed orelse return;
    var pwd: c.GhosttyString = .{};
    const r = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_PWD, &pwd);
    f(e.userdata, if (r == c.GHOSTTY_SUCCESS) cSlice(pwd.ptr, pwd.len) else &.{});
}

fn enquiryTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) c.GhosttyString {
    const e = effectsFrom(userdata);
    const f = e.enquiry orelse return .{};
    return toCString(f(e.userdata));
}

fn xtversionTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) c.GhosttyString {
    const e = effectsFrom(userdata);
    const f = e.xtversion orelse return .{};
    return toCString(f(e.userdata));
}

fn sizeTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, out: [*c]c.GhosttySizeReportSize) callconv(.c) bool {
    const e = effectsFrom(userdata);
    const f = e.size orelse return false;
    return f(e.userdata, @ptrCast(out));
}

fn colorSchemeTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, out: [*c]c.GhosttyColorScheme) callconv(.c) bool {
    const e = effectsFrom(userdata);
    const f = e.color_scheme orelse return false;
    return f(e.userdata, @ptrCast(out));
}

fn deviceAttributesTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, out: [*c]c.GhosttyDeviceAttributes) callconv(.c) bool {
    const e = effectsFrom(userdata);
    const f = e.device_attributes orelse return false;
    return f(e.userdata, @ptrCast(out));
}

fn clipboardWriteTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, write: [*c]const c.GhosttyClipboardWrite) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.clipboard_write orelse return;
    const w = &write.*;
    // GhosttyClipboardContent is two {ptr, len} pairs, exactly the layout of
    // ClipboardContent (comptime-checked above), so the array casts without
    // copying. Valid for the call only.
    const contents: []const ClipboardContent = if (w.contents_len == 0)
        &.{}
    else
        @as([*]const ClipboardContent, @ptrCast(@alignCast(w.contents)))[0..w.contents_len];
    const req: ClipboardWriteRequest = .{
        .location = @enumFromInt(w.location),
        .contents = contents,
        .name = cSlice(w.name.ptr, w.name.len),
        .granted = w.granted,
        .can_remember = w.can_remember,
        .reply_state = write,
    };
    f(e.userdata, &req);
}

fn clipboardReadTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, read: [*c]const c.GhosttyClipboardRead) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.clipboard_read orelse return;
    const r = &read.*;
    const mimes: []const []const u8 = if (r.mimes_len == 0)
        &.{}
    else
        @as([*]const []const u8, @ptrCast(@alignCast(r.mimes)))[0..r.mimes_len];
    const req: ClipboardReadRequest = .{
        .location = @enumFromInt(r.location),
        .mimes = mimes,
        .list = r.list,
        .name = cSlice(r.name.ptr, r.name.len),
        .granted = r.granted,
        .can_remember = r.can_remember,
        .reply_state = read,
    };
    f(e.userdata, &req);
}

fn renderHoldTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, held: bool) callconv(.c) void {
    const e = effectsFrom(userdata);
    if (e.render_hold) |f| f(e.userdata, held);
}

fn resetTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const e = effectsFrom(userdata);
    if (e.reset) |f| f(e.userdata);
}

fn resizeWindowTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, request: [*c]const c.GhosttyTerminalResizeWindow) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.resize_window orelse return;
    const req = &request.*;
    // GRID is the only tag in 1.0.1; ignore anything a future library adds.
    if (req.tag != c.GHOSTTY_TERMINAL_RESIZE_WINDOW_GRID) return;
    f(e.userdata, req.value.grid.rows, req.value.grid.columns);
}

fn unknownSequenceTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, sequence: [*c]const c.GhosttyTerminalUnknownSequence) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.unknown_sequence orelse return;
    const s = &sequence.*;
    const seq: UnknownSequence = switch (s.tag) {
        c.GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC => .{
            .tag = .apc,
            .truncated = s.value.apc.truncated,
            .content = cSlice(s.value.apc.content.ptr, s.value.apc.content.len),
            .terminator = .st,
        },
        c.GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC => .{
            .tag = .osc,
            .truncated = s.value.osc.truncated,
            .content = cSlice(s.value.osc.content.ptr, s.value.osc.content.len),
            .terminator = @enumFromInt(s.value.osc.terminator),
        },
        else => return,
    };
    f(e.userdata, seq);
}

fn desktopNotificationTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, notification: [*c]const c.GhosttyTerminalDesktopNotification) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.desktop_notification orelse return;
    const n = &notification.*;
    f(e.userdata, .{
        .title = cSlice(n.title.ptr, n.title.len),
        .body = cSlice(n.body.ptr, n.body.len),
    });
}

fn progressReportTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, report: [*c]const c.GhosttyTerminalProgressReport) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.progress_report orelse return;
    const r = &report.*;
    f(e.userdata, .{ .state = @enumFromInt(r.state), .progress = r.progress });
}

fn programStatusTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, report: [*c]const c.GhosttyTerminalProgramStatus) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.program_status orelse return;
    const p = &report.*;
    f(e.userdata, .{
        .state = @enumFromInt(p.state),
        .kind = @enumFromInt(p.kind),
        .progress = p.progress,
        .id = cSlice(p.id.ptr, p.id.len),
        .app = cSlice(p.app.ptr, p.app.len),
        .title = cSlice(p.title.ptr, p.title.len),
        .message = cSlice(p.message.ptr, p.message.len),
    });
}

fn semanticPromptTrampoline(_: c.GhosttyTerminal, userdata: ?*anyopaque, event: [*c]const c.GhosttyTerminalSemanticPrompt) callconv(.c) void {
    const e = effectsFrom(userdata);
    const f = e.semantic_prompt orelse return;
    const ev = &event.*;
    f(e.userdata, .{
        .kind = @enumFromInt(ev.kind),
        .prompt_kind = @enumFromInt(ev.prompt_kind),
        .exit_code = if (ev.has_exit_code) ev.exit_code else null,
        .command = cSlice(ev.command.ptr, ev.command.len),
        .err = cSlice(ev.@"error".ptr, ev.@"error".len),
    });
}

// ---------------------------------------------------------------------------
// Terminal options / data keys (§3) -- typed enums for the escape hatches
// ---------------------------------------------------------------------------

/// All GHOSTTY_TERMINAL_OPT_* keys (terminal.h:2033). Typed setters below
/// cover what kmshaunt needs now; Vt.setOption is the escape hatch for the
/// rest (value points to the documented type, callbacks passed directly).
pub const TerminalOption = enum(c_uint) {
    userdata = 1,
    write_pty = 2,
    bell = 3,
    enquiry = 4,
    xtversion = 5,
    title_changed = 6,
    size = 7,
    color_scheme = 8,
    device_attributes = 9,
    title = 10,
    pwd = 11,
    color_foreground = 12,
    color_background = 13,
    color_cursor = 14,
    color_palette = 15,
    kitty_image_storage_limit = 16,
    kitty_image_medium_file = 17,
    kitty_image_medium_temp_file = 18,
    kitty_image_medium_shared_mem = 19,
    apc_max_bytes = 20,
    apc_max_bytes_kitty = 21,
    selection = 22,
    default_cursor_style = 23,
    default_cursor_blink = 24,
    glyph_protocol = 25,
    pwd_changed = 26,
    clipboard_write = 27,
    scrollback_max_bytes = 28,
    scrollback_max_lines = 29,
    desktop_notification = 30,
    progress_report = 31,
    continuation_max_bytes = 32,
    title_report = 33,
    mode_default = 34,
    mode = 35,
    unknown_sequence = 36,
    unknown_max_bytes = 37,
    terminfo_name = 38,
    clipboard_read = 39,
    clipboard_write_max_bytes = 40,
    resize_pull_scrollback = 41,
    render_hold = 42,
    semantic_prompt = 43,
    reset = 44,
    xt_checksum_report = 45,
    xt_checksum_extension = 46,
    program_status = 47,
    resize_window = 48,
};

/// All GHOSTTY_TERMINAL_DATA_* read keys (terminal.h:2665).
pub const TerminalData = enum(c_uint) {
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_sgr_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,
    kitty_image_storage_limit = 26,
    kitty_image_medium_file = 27,
    kitty_image_medium_temp_file = 28,
    kitty_image_medium_shared_mem = 29,
    kitty_graphics = 30,
    selection = 31,
    viewport_active = 32,
    vt_processing_error = 33,
    scrollback_max_bytes = 34,
    scrollback_max_lines = 35,
    continuation_max_bytes = 36,
    mode = 37,
    vt_ground = 38,
    cursor_at_prompt = 39,
    clipboard_write_max_bytes = 40,
    mouse_shape = 41,
    memory_usage = 42,
};

/// Build a GhosttyMode word (modes.h:93): value bits 0-14, ANSI flag bit 15.
pub fn mode(value: u15, ansi: bool) u16 {
    return c.ghostty_mode_new(value, ansi);
}

// ---------------------------------------------------------------------------
// Vt -- the terminal (§2)
// ---------------------------------------------------------------------------

pub const Vt = struct {
    handle: c.GhosttyTerminal,

    /// Create a terminal with `cols` x `rows` cells (both > 0). Starts with
    /// the library defaults; kmshaunt sets the kitty storage limit to 10 MiB
    /// (setKittyStorageLimit to change, 0 disables the protocol). Configure
    /// effects with setEffects before feeding real program output.
    pub fn init(n_cols: u16, n_rows: u16) Error!Vt {
        var handle: c.GhosttyTerminal = null;
        try check(c.ghostty_terminal_new(null, &handle, n_cols, n_rows));
        var self: Vt = .{ .handle = handle };
        self.setKittyStorageLimit(default_kitty_storage_limit) catch |err| {
            c.ghostty_terminal_free(handle);
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Vt) void {
        c.ghostty_terminal_free(self.handle);
        self.handle = null;
    }

    /// Resize the grid and store the cell pixel size (used by image
    /// protocols and size reports). Reflows the primary screen, disables
    /// synchronized output (render_hold fires held=false), and emits an
    /// in-band size report when mode 2048 is on (§2.1).
    pub fn resize(self: *Vt, n_cols: u16, n_rows: u16, cell_w_px: u32, cell_h_px: u32) Error!void {
        try check(c.ghostty_terminal_resize(self.handle, n_cols, n_rows, cell_w_px, cell_h_px));
    }

    /// Feed pty output into the parser. Never fails; malformed input is
    /// skipped safely. Effect callbacks fire synchronously inside this call
    /// (see Effects for the reentrancy rule). Sequences and partial UTF-8
    /// may be split across calls.
    pub fn write(self: *Vt, bytes: []const u8) void {
        if (bytes.len == 0) return;
        c.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// Full RIS (ESC c): clears screen + scrollback, restores mode reset
    /// defaults, clears title/pwd; dimensions preserved. Ends a render hold.
    /// Does NOT fire the reset effect (host-driven reset, §8.2).
    pub fn reset(self: *Vt) void {
        c.ghostty_terminal_reset(self.handle);
    }

    /// Register all 19 effect trampolines with `effects` as the single
    /// userdata pointer, enable unknown-sequence reporting (2048 bytes,
    /// allocation-free for OSC), and answer XTGETTCAP "TN" with
    /// "xterm-ghostty" (D6). `effects` is borrowed until deinit or the next
    /// setEffects call.
    pub fn setEffects(self: *Vt, effects: *Effects) Error!void {
        const t = self.handle;
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_USERDATA, effects));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePtyTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(&bellTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&titleChangedTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_PWD_CHANGED, @ptrCast(&pwdChangedTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_ENQUIRY, @ptrCast(&enquiryTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_XTVERSION, @ptrCast(&xtversionTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_SIZE, @ptrCast(&sizeTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, @ptrCast(&colorSchemeTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, @ptrCast(&deviceAttributesTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, @ptrCast(&clipboardWriteTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, @ptrCast(&clipboardReadTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_RENDER_HOLD, @ptrCast(&renderHoldTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_RESET, @ptrCast(&resetTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW, @ptrCast(&resizeWindowTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, @ptrCast(&unknownSequenceTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, @ptrCast(&desktopNotificationTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, @ptrCast(&progressReportTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, @ptrCast(&programStatusTrampoline)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, @ptrCast(&semanticPromptTrampoline)));
        const unknown_max: usize = 2048;
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_max));
        const terminfo = toCString(terminfo_name);
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo));
    }

    // -- typed data getters (§3.2) -----------------------------------------

    pub fn cols(self: *Vt) Error!u16 {
        return self.getU16(c.GHOSTTY_TERMINAL_DATA_COLS);
    }
    pub fn rows(self: *Vt) Error!u16 {
        return self.getU16(c.GHOSTTY_TERMINAL_DATA_ROWS);
    }
    pub fn cursorX(self: *Vt) Error!u16 {
        return self.getU16(c.GHOSTTY_TERMINAL_DATA_CURSOR_X);
    }
    pub fn cursorY(self: *Vt) Error!u16 {
        return self.getU16(c.GHOSTTY_TERMINAL_DATA_CURSOR_Y);
    }
    pub fn cursorPendingWrap(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP);
    }
    pub fn cursorVisible(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE);
    }
    pub fn activeScreen(self: *Vt) Error!ActiveScreen {
        var out: c.GhosttyTerminalScreen = 0;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &out));
        return @enumFromInt(out);
    }
    pub fn widthPx(self: *Vt) Error!u32 {
        return self.getU32(c.GHOSTTY_TERMINAL_DATA_WIDTH_PX);
    }
    pub fn heightPx(self: *Vt) Error!u32 {
        return self.getU32(c.GHOSTTY_TERMINAL_DATA_HEIGHT_PX);
    }
    pub fn totalRows(self: *Vt) Error!usize {
        return self.getUsize(c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
    }
    pub fn scrollbackRows(self: *Vt) Error!usize {
        return self.getUsize(c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS);
    }
    pub fn viewportActive(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE);
    }
    /// Parser at ground: safe to inject your own sequences.
    pub fn vtGround(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_VT_GROUND);
    }
    pub fn cursorAtPrompt(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT);
    }
    /// A non-graceful VT processing error happened; informational, cannot
    /// be unset.
    pub fn vtProcessingError(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR);
    }
    pub fn kittyKeyboardFlags(self: *Vt) Error!u8 {
        var out: c.GhosttyKittyKeyFlags = 0;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &out));
        return out;
    }

    /// Current title. Borrowed until the next mutating terminal call.
    pub fn title(self: *Vt) Error![]const u8 {
        var out: c.GhosttyString = .{};
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_TITLE, &out));
        return cSlice(out.ptr, out.len);
    }

    /// Current pwd (OSC 7 URI, unparsed). Borrowed until the next mutating
    /// terminal call.
    pub fn pwd(self: *Vt) Error![]const u8 {
        var out: c.GhosttyString = .{};
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_PWD, &out));
        return cSlice(out.ptr, out.len);
    }

    /// Scrollbar position; poll once per frame / write batch and diff --
    /// there is no change notification (§2.5).
    pub fn scrollbar(self: *Vt) Error!Scrollbar {
        var out: c.GhosttyTerminalScrollbar = undefined;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &out));
        return @as(*const Scrollbar, @ptrCast(&out)).*;
    }

    /// Any mouse tracking mode on. There is NO mode-change callback: poll
    /// after writes (or refresh the mouse encoder with setFromTerminal).
    pub fn mouseTracking(self: *Vt) Error!bool {
        return self.getBool(c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING);
    }

    /// The app's OSC 22 pointer-shape request; initially .text. Poll after
    /// writes, like mouseTracking (§8.6).
    pub fn mouseShape(self: *Vt) Error!MouseShape {
        var out: c.GhosttyMouseShape = 0;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE, &out));
        return @enumFromInt(out);
    }

    /// Read a mode's current value. Build the mode word with `mode()`.
    pub fn getMode(self: *Vt, m: u16) Error!bool {
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = m };
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg));
        return cfg.value;
    }

    /// Set a mode's current value (does not change the reset default).
    pub fn setMode(self: *Vt, m: u16, value: bool) Error!void {
        const cfg: c.GhosttyTerminalModeConfig = .{ .mode = m, .value = value };
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_MODE, &cfg));
    }

    /// Set a mode's reset default (RIS restores it).
    pub fn setModeDefault(self: *Vt, m: u16, value: bool) Error!void {
        const cfg: c.GhosttyTerminalModeConfig = .{ .mode = m, .value = value };
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &cfg));
    }

    // -- scrollback (§3.1 #28/29) ------------------------------------------

    /// Scrollback byte budget (primary screen). null restores the default
    /// (10,000 bytes); 0 erases history; maxInt(usize) = no limit.
    pub fn setScrollbackMaxBytes(self: *Vt, bytes: ?usize) Error!void {
        if (bytes) |v| {
            try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &v));
        } else {
            try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, null));
        }
    }

    /// Configured byte budget; null = unlimited.
    pub fn scrollbackMaxBytes(self: *Vt) Error!?usize {
        var out: usize = 0;
        const r = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return out;
    }

    /// Scrollback line budget. null removes the limit (the default).
    pub fn setScrollbackMaxLines(self: *Vt, lines: ?usize) Error!void {
        if (lines) |v| {
            try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &v));
        } else {
            try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, null));
        }
    }

    pub fn scrollbackMaxLines(self: *Vt) Error!?usize {
        var out: usize = 0;
        const r = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return out;
    }

    // -- viewport scrolling (§2.5) -----------------------------------------

    /// Scroll the viewport. On the alternate screen (no scrollback) the
    /// viewport stays on the active area. A moved viewport marks the whole
    /// render frame dirty, so the next RenderState.update repaints it.
    pub fn scrollViewport(self: *Vt, behavior: ScrollViewport) Error!void {
        const b: c.GhosttyTerminalScrollViewport = switch (behavior) {
            .top => .{ .tag = @intCast(c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP) },
            .bottom => .{ .tag = @intCast(c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM) },
            .delta => |d| .{
                .tag = @intCast(c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA),
                .value = .{ .delta = d },
            },
            .row => |r| .{
                .tag = @intCast(c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW),
                .value = .{ .row = r },
            },
            .delta_prompt => |d| .{
                .tag = @intCast(c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT),
                .value = .{ .delta_prompt = d },
            },
        };
        try check(c.ghostty_terminal_scroll_viewport(self.handle, b));
    }

    /// Jump to the top of the scrollback.
    pub fn scrollTop(self: *Vt) Error!void {
        try self.scrollViewport(.top);
    }

    /// Jump to the bottom (the active area).
    pub fn scrollBottom(self: *Vt) Error!void {
        try self.scrollViewport(.bottom);
    }

    /// Scroll back one full viewport page (grab-page-up).
    pub fn pageUp(self: *Vt) Error!void {
        const page_rows: isize = @intCast(try self.rows());
        try self.scrollViewport(.{ .delta = -page_rows });
    }

    /// Scroll forward one full viewport page (grab-page-down).
    pub fn pageDown(self: *Vt) Error!void {
        const page_rows: isize = @intCast(try self.rows());
        try self.scrollViewport(.{ .delta = page_rows });
    }

    // -- selection (§6) -----------------------------------------------------

    /// Install (or clear with null) the active-screen selection. The value
    /// is copied into terminal-owned tracked state immediately, so the
    /// untracked refs in `sel` may die right after this call.
    pub fn setSelection(self: *Vt, sel: ?*const Selection) Error!void {
        const value: ?*const anyopaque = if (sel) |s| @ptrCast(s) else null;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SELECTION, value));
    }

    /// Untracked snapshot of the installed selection; null if none. The
    /// refs are valid until the next mutating terminal call.
    pub fn selection(self: *Vt) Error!?Selection {
        var out: c.GhosttySelection = undefined;
        const r = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SELECTION, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return @as(*const Selection, @ptrCast(&out)).*;
    }

    /// An untracked grid reference for a cell. Fast for active/viewport;
    /// screen/history may walk the page list. Valid until the next mutating
    /// terminal call (§2.7).
    pub fn gridRef(self: *Vt, tag: PointTag, point: Point) Error!GridRef {
        const p: c.GhosttyPoint = .{
            .tag = @intFromEnum(tag),
            .value = .{ .coordinate = .{ .x = point.x, .y = point.y } },
        };
        var out: c.GhosttyGridRef = .{};
        try check(c.ghostty_terminal_grid_ref(self.handle, p, &out));
        return @as(*const GridRef, @ptrCast(&out)).*;
    }

    // -- kitty (§9) ----------------------------------------------------------

    /// Per-screen kitty image storage budget in bytes. kmshaunt default:
    /// 10 MiB (set at init). 0 disables the whole protocol, deleting stored
    /// images and placements.
    pub fn setKittyStorageLimit(self: *Vt, bytes: u64) Error!void {
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &bytes));
    }

    pub fn kittyStorageLimit(self: *Vt) Error!u64 {
        var out: u64 = 0;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &out));
        return out;
    }

    /// Borrowed kitty storage handle for the ACTIVE screen. Invalidated by
    /// any mutating terminal call (write, reset, resize, alt-screen switch):
    /// re-fetch every frame (§9.1).
    pub fn kittyGraphics(self: *Vt) Error!KittyGraphics {
        var out: c.GhosttyKittyGraphics = null;
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, @ptrCast(&out)));
        return .{ .handle = out };
    }

    // -- paste (§3.3) ---------------------------------------------------------

    /// Paste `text` into the terminal. With mode 5522 + a clipboard_read
    /// effect the program gets a kitty paste event; otherwise the text is
    /// framed per mode 2004 (bracketed paste) and streamed through
    /// write_pty. Returns whether anything was written.
    ///
    /// Safety: with allow_unsafe = false, text containing line terminators
    /// or the bracketed-paste-end sequence is refused with error.Rejected
    /// and NOTHING is written -- confirm with the user, then retry with
    /// allow_unsafe = true. Requires a write_pty effect (error.InvalidValue
    /// without one).
    pub fn paste(self: *Vt, text: []const u8, opts: PasteOptions) Error!bool {
        var mime = toCString("text/plain");
        var ctx: PasteReaderCtx = .{ .text = text };
        var p: c.GhosttyPaste = .{
            .size = @sizeOf(c.GhosttyPaste),
            .location = @intFromEnum(opts.location),
            .source = @intFromEnum(opts.source),
            .mimes = &mime,
            .mimes_len = 1,
            .reader = .{ .read = pasteReaderTrampoline, .userdata = &ctx },
            .allow_unsafe = opts.allow_unsafe,
        };
        var pasted: bool = false;
        try check(c.ghostty_terminal_paste(self.handle, &p, &pasted));
        return pasted;
    }

    // -- generic escape hatches (§3) ------------------------------------------

    /// Set any terminal option. `value` points to the documented type
    /// (callbacks are passed as function pointers); null restores the
    /// default where one exists.
    pub fn setOption(self: *Vt, option: TerminalOption, value: ?*const anyopaque) Error!void {
        try check(c.ghostty_terminal_set(self.handle, @intFromEnum(option), value));
    }

    /// Read any terminal data key into `out` (pointer to the documented
    /// out type). error.NoValue when the key has no value right now.
    pub fn getData(self: *Vt, data: TerminalData, out: *anyopaque) Error!void {
        try check(c.ghostty_terminal_get(self.handle, @intFromEnum(data), out));
    }

    fn getU16(self: *Vt, key: c.GhosttyTerminalData) Error!u16 {
        var out: u16 = 0;
        try check(c.ghostty_terminal_get(self.handle, key, &out));
        return out;
    }
    fn getU32(self: *Vt, key: c.GhosttyTerminalData) Error!u32 {
        var out: u32 = 0;
        try check(c.ghostty_terminal_get(self.handle, key, &out));
        return out;
    }
    fn getUsize(self: *Vt, key: c.GhosttyTerminalData) Error!usize {
        var out: usize = 0;
        try check(c.ghostty_terminal_get(self.handle, key, &out));
        return out;
    }
    fn getBool(self: *Vt, key: c.GhosttyTerminalData) Error!bool {
        var out: bool = false;
        try check(c.ghostty_terminal_get(self.handle, key, &out));
        return out;
    }
};

/// TERM answered to XTGETTCAP "TN" (ROADMAP D6).
pub const terminfo_name = "xterm-ghostty";
/// kmshaunt kitty storage default: 10 MiB per screen.
pub const default_kitty_storage_limit: u64 = 10 * 1024 * 1024;

pub const PasteOptions = struct {
    location: ClipboardLocation = .primary,
    source: PasteSource = .clipboard,
    /// false refuses unsafe text with error.Rejected (nothing written);
    /// retry with true only after user confirmation.
    allow_unsafe: bool = false,
};

const PasteReaderCtx = struct { text: []const u8 };

fn pasteReaderTrampoline(userdata: ?*anyopaque, _: c.GhosttyString, writer: c.GhosttyWriter) callconv(.c) bool {
    const ctx: *PasteReaderCtx = @ptrCast(@alignCast(userdata.?));
    if (ctx.text.len == 0) return true;
    // Called at most once; stream the single text representation.
    return writer.write.?(writer.userdata, ctx.text.ptr, ctx.text.len);
}

/// Whether `text` is safe to paste without confirmation: no \n, \r, or
/// bracketed-paste-end sequence (§3.3).
pub fn pasteIsSafe(text: []const u8) bool {
    return c.ghostty_paste_is_safe(text.ptr, text.len);
}

// ---------------------------------------------------------------------------
// Render state (§4)
// ---------------------------------------------------------------------------

/// Effective frame colors (§4.1). `cursor` is null unless explicitly set.
pub const Colors = struct {
    background: Rgb,
    foreground: Rgb,
    cursor: ?Rgb,
    palette: [256]Rgb,
};

/// Cursor snapshot (§4.1). `viewport` is null when the cursor is outside
/// the captured viewport (e.g. scrolled into history).
pub const Cursor = struct {
    pub const Viewport = struct { x: u16, y: u16, wide_tail: bool };
    viewport: ?Viewport,
    visible: bool,
    blinking: bool,
    password_input: bool,
    style: CursorStyle,
};

/// One drawable cell (§4.3). `text` is the whole grapheme cluster as UTF-8
/// (base codepoint first), borrowed from the RenderState scratch buffer:
/// valid until the next Cells.next/select on the same iterator or the next
/// RenderState.update. Empty for cells without text. `fg`/`bg` null = draw
/// with Colors.foreground/background; bold color handling is NOT applied
/// by the library. Width comes from `wide`, never from the font (R1).
pub const Cell = struct {
    text: []const u8,
    style: Style,
    fg: ?Rgb,
    bg: ?Rgb,
    wide: Wide,
    selected: bool,
    has_styling: bool,
};

/// Render-state snapshot of the viewport (§4). Create once, reuse every
/// frame: update() captures the viewport and consumes terminal dirty state;
/// after it, no terminal access is needed until the next update. Call
/// clean() only after the whole frame rendered successfully.
pub const RenderState = struct {
    handle: c.GhosttyRenderState,
    row_iter: c.GhosttyRenderStateRowIterator,
    cells_handle: c.GhosttyRenderStateRowCells,
    image_iter: c.GhosttyRenderStateImageIterator,
    // Scratch for GRAPHEMES_UTF8 (the C API requires a caller buffer; a
    // NULL buffer only queries the size). Grown on demand, kept across
    // frames; library default allocator, freed in deinit.
    text_ptr: [*]u8,
    text_cap: usize,

    const initial_text_cap = 256;

    pub fn new() Error!RenderState {
        var handle: c.GhosttyRenderState = null;
        try check(c.ghostty_render_state_new(null, &handle));
        errdefer c.ghostty_render_state_free(handle);

        var row_iter: c.GhosttyRenderStateRowIterator = null;
        try check(c.ghostty_render_state_row_iterator_new(null, &row_iter));
        errdefer c.ghostty_render_state_row_iterator_free(row_iter);

        var cells_handle: c.GhosttyRenderStateRowCells = null;
        try check(c.ghostty_render_state_row_cells_new(null, &cells_handle));
        errdefer c.ghostty_render_state_row_cells_free(cells_handle);

        var image_iter: c.GhosttyRenderStateImageIterator = null;
        try check(c.ghostty_render_state_image_iterator_new(null, &image_iter));
        errdefer c.ghostty_render_state_image_iterator_free(image_iter);

        const text_ptr = c.ghostty_alloc(null, initial_text_cap) orelse return Error.OutOfMemory;
        return .{
            .handle = handle,
            .row_iter = row_iter,
            .cells_handle = cells_handle,
            .image_iter = image_iter,
            .text_ptr = text_ptr,
            .text_cap = initial_text_cap,
        };
    }

    pub fn deinit(self: *RenderState) void {
        c.ghostty_render_state_image_iterator_free(self.image_iter);
        c.ghostty_render_state_row_cells_free(self.cells_handle);
        c.ghostty_render_state_row_iterator_free(self.row_iter);
        c.ghostty_render_state_free(self.handle);
        c.ghostty_free(null, self.text_ptr, self.text_cap);
        self.* = undefined;
    }

    /// Capture the viewport (begin+end in one call; single-threaded D2).
    /// Invalidates all previously returned row/cell/image data.
    pub fn update(self: *RenderState, vt: *Vt) Error!void {
        try check(c.ghostty_render_state_update(self.handle, vt.handle));
    }

    pub fn dirty(self: *RenderState) Error!Dirty {
        var out: c.GhosttyRenderStateDirty = 0;
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &out));
        return @enumFromInt(out);
    }

    pub fn cols(self: *RenderState) Error!u16 {
        var out: u16 = 0;
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_COLS, &out));
        return out;
    }

    pub fn rows(self: *RenderState) Error!u16 {
        var out: u16 = 0;
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &out));
        return out;
    }

    pub fn colors(self: *RenderState) Error!Colors {
        var out: c.GhosttyRenderStateColors = .{ .size = @sizeOf(c.GhosttyRenderStateColors) };
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &out));
        var result: Colors = .{
            .background = rgbFromC(out.background),
            .foreground = rgbFromC(out.foreground),
            .cursor = if (out.cursor_has_value) rgbFromC(out.cursor) else null,
            .palette = undefined,
        };
        for (&result.palette, out.palette) |*dst, src| dst.* = rgbFromC(src);
        return result;
    }

    pub fn cursor(self: *RenderState) Error!Cursor {
        var out: c.GhosttyRenderStateCursor = .{ .size = @sizeOf(c.GhosttyRenderStateCursor) };
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &out));
        return .{
            .viewport = if (out.viewport_has_value)
                .{ .x = out.viewport_x, .y = out.viewport_y, .wide_tail = out.wide_tail }
            else
                null,
            .visible = out.visible,
            .blinking = out.blinking,
            .password_input = out.password_input,
            .style = @enumFromInt(out.visual_style),
        };
    }

    /// Repopulate and return the row iterator. Row data is valid only until
    /// the next update (§4.2).
    pub fn rowsIter(self: *RenderState) Error!Rows {
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iter)));
        return .{ .state = self };
    }

    /// Repopulate and return the image placement iterator (§9.6). This is
    /// THE drawing list for images -- do not also draw from the kitty
    /// storage iterator. Iteration order is NOT draw order: sort by layer,
    /// then z ascending, and draw BELOW_BACKGROUND -> cell backgrounds ->
    /// BELOW_TEXT -> text -> ABOVE_TEXT.
    pub fn images(self: *RenderState) Error!Images {
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, @ptrCast(&self.image_iter)));
        return .{ .state = self };
    }

    /// Changes whenever the placement list changes (including scroll and
    /// resize); cache "list read" on it. Per-image pixel changes are tracked
    /// by ImagePlacement.image_generation (§9.6).
    pub fn imagePlacementsGeneration(self: *RenderState) Error!u64 {
        var out: u64 = 0;
        try check(c.ghostty_render_state_get(self.handle, c.GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION, &out));
        return out;
    }

    /// Mark ALL dirty data consumed (global -> clean, every row flag
    /// cleared). Call only after the whole frame rendered successfully.
    pub fn clean(self: *RenderState) Error!void {
        try check(c.ghostty_render_state_clean(self.handle));
    }

    fn growTextBuf(self: *RenderState, needed: usize) Error!void {
        const ptr = c.ghostty_alloc(null, needed) orelse return Error.OutOfMemory;
        c.ghostty_free(null, self.text_ptr, self.text_cap);
        self.text_ptr = ptr;
        self.text_cap = needed;
    }
};

fn rgbFromC(v: c.GhosttyColorRgb) Rgb {
    return .{ .r = v.r, .g = v.g, .b = v.b };
}

/// Dirty-row iterator (§4.2). nextDirty skips clean rows when dirty is
/// partial, returns every remaining row when full, and nothing when clean.
/// It does not clear dirty state.
pub const Rows = struct {
    state: *RenderState,

    pub fn nextDirty(self: *Rows) Error!?Row {
        var y: u16 = 0;
        if (!c.ghostty_render_state_row_iterator_next_dirty(self.state.row_iter, &y)) return null;
        return Row{ .state = self.state, .y = y };
    }
};

pub const Row = struct {
    state: *RenderState,
    /// Row index counting from the highest captured row (overscan shifts
    /// it; use viewportY for placement).
    y: u16,

    /// Position in the viewport: 0..rows-1, negative above, >= rows below
    /// (overscan).
    pub fn viewportY(self: *const Row) Error!i32 {
        var out: i32 = 0;
        try check(c.ghostty_render_state_row_get(self.state.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &out));
        return out;
    }

    pub fn dirty(self: *const Row) Error!bool {
        var out: bool = false;
        try check(c.ghostty_render_state_row_get(self.state.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &out));
        return out;
    }

    /// Inclusive selection range for this row; null when the row is not in
    /// the selection.
    pub fn selection(self: *const Row) Error!?SelectionRange {
        var out: c.GhosttyRenderStateRowSelection = .{ .size = @sizeOf(c.GhosttyRenderStateRowSelection) };
        const r = c.ghostty_render_state_row_get(self.state.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return .{ .start_x = out.start_x, .end_x = out.end_x };
    }

    /// Repopulate the shared cells handle for this row and return its
    /// iterator. One handle is reused for every row (§4.3).
    pub fn cells(self: *const Row) Error!Cells {
        try check(c.ghostty_render_state_row_get(self.state.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.state.cells_handle)));
        return .{ .state = self.state, .x = 0 };
    }
};

/// Cell iterator for one row. `next` walks columns left to right; `select`
/// jumps to a column. Each step invalidates the previous Cell's borrowed
/// `text`.
pub const Cells = struct {
    state: *RenderState,
    x: u16,

    pub fn next(self: *Cells) Error!?Cell {
        if (!c.ghostty_render_state_row_cells_next(self.state.cells_handle)) return null;
        defer self.x += 1;
        return try self.read();
    }

    pub fn select(self: *Cells, x: u16) Error!Cell {
        try check(c.ghostty_render_state_row_cells_select(self.state.cells_handle, x));
        self.x = x;
        return self.read();
    }

    fn read(self: *Cells) Error!Cell {
        const h = self.state.cells_handle;

        var raw: c.GhosttyCell = 0;
        try check(c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw));
        var wide: c.GhosttyCellWide = 0;
        try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide));

        // Whole cluster as UTF-8 into the shared scratch buffer; on
        // OUT_OF_SPACE the library reports the exact size needed (it writes
        // nothing), so grow once and retry.
        var buf: c.GhosttyBuffer = .{ .ptr = self.state.text_ptr, .cap = self.state.text_cap };
        var r = c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf);
        if (r == c.GHOSTTY_OUT_OF_SPACE) {
            try self.state.growTextBuf(buf.len);
            buf = .{ .ptr = self.state.text_ptr, .cap = self.state.text_cap };
            r = c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf);
        }
        try check(r);

        var style: c.GhosttyStyle = undefined;
        try check(c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));

        var fg: c.GhosttyColorRgb = undefined;
        const fg_r = c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
        if (fg_r != c.GHOSTTY_NO_VALUE) try check(fg_r);

        var bg: c.GhosttyColorRgb = undefined;
        const bg_r = c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
        if (bg_r != c.GHOSTTY_NO_VALUE) try check(bg_r);

        var selected: bool = false;
        try check(c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected));
        var has_styling: bool = false;
        try check(c.ghostty_render_state_row_cells_get(h, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has_styling));

        return .{
            .text = buf.ptr[0..buf.len],
            .style = styleFromC(style),
            .fg = if (fg_r == c.GHOSTTY_SUCCESS) rgbFromC(fg) else null,
            .bg = if (bg_r == c.GHOSTTY_SUCCESS) rgbFromC(bg) else null,
            .wide = @enumFromInt(wide),
            .selected = selected,
            .has_styling = has_styling,
        };
    }
};

/// One image placement from the render state (§9.6). Texture cache key:
/// (protocol, image_id, image_generation); fetch pixels through
/// Vt.kittyGraphics().image(image_id). Viewport positions may be negative
/// or exceed the grid (fixed/relative placements report full size): clip.
pub const ImagePlacement = struct {
    protocol: ImageProtocol,
    image_id: u32,
    image_generation: u64,
    layer: ImageLayer,
    /// Within-layer order, lower first; virtual placements always -1.
    z: i32,
    viewport_col: i32,
    viewport_row: i32,
    grid_cols: u32,
    grid_rows: u32,
    /// Pixel offset within the top-left cell (virtual: centering, can
    /// exceed a cell).
    cell_offset_x: u32,
    cell_offset_y: u32,
    /// Destination size in pixels.
    pixel_width: u32,
    pixel_height: u32,
    /// Crop rect in image pixels; scale to pixel_width/height when drawing.
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    /// 0 when the cells asked for none.
    kitty_placement_id: u32,
    kitty_kind: KittyPlacementKind,
};

pub const Images = struct {
    state: *RenderState,

    pub fn next(self: *Images) Error!?ImagePlacement {
        const h = self.state.image_iter;
        if (!c.ghostty_render_state_image_iterator_next(h)) return null;

        var protocol: c.GhosttyImageProtocol = 0;
        var image_id: u32 = 0;
        var generation: u64 = 0;
        var layer: c.GhosttyImageLayer = 0;
        var z: i32 = 0;
        var col: i32 = 0;
        var row: i32 = 0;
        var grid_cols: u32 = 0;
        var grid_rows: u32 = 0;
        var off_x: u32 = 0;
        var off_y: u32 = 0;
        var px_w: u32 = 0;
        var px_h: u32 = 0;
        var src_x: u32 = 0;
        var src_y: u32 = 0;
        var src_w: u32 = 0;
        var src_h: u32 = 0;
        var placement_id: u32 = 0;
        var kind: c.GhosttyRenderStateKittyPlacementKind = 0;

        // Every key is always present for a placement: one bulk read.
        const keys = [_]c.GhosttyRenderStateImageData{
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID,
            c.GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND,
        };
        var values = [_]?*anyopaque{
            &protocol, &image_id, &generation, &layer,    &z,        &col,      &row,
            &grid_cols, &grid_rows, &off_x,    &off_y,    &px_w,     &px_h,     &src_x,
            &src_y,    &src_w,     &src_h,    &placement_id, &kind,
        };
        var written: usize = 0;
        try check(c.ghostty_render_state_image_get_multi(h, keys.len, &keys, &values, &written));

        return .{
            .protocol = @enumFromInt(protocol),
            .image_id = image_id,
            .image_generation = generation,
            .layer = @enumFromInt(layer),
            .z = z,
            .viewport_col = col,
            .viewport_row = row,
            .grid_cols = grid_cols,
            .grid_rows = grid_rows,
            .cell_offset_x = off_x,
            .cell_offset_y = off_y,
            .pixel_width = px_w,
            .pixel_height = px_h,
            .source_x = src_x,
            .source_y = src_y,
            .source_width = src_w,
            .source_height = src_h,
            .kitty_placement_id = placement_id,
            .kitty_kind = @enumFromInt(kind),
        };
    }
};

// ---------------------------------------------------------------------------
// Kitty graphics (§9)
// ---------------------------------------------------------------------------

/// Borrowed storage handle (see Vt.kittyGraphics for the lifetime rule).
pub const KittyGraphics = struct {
    handle: c.GhosttyKittyGraphics,

    /// Changes whenever a program sends/replaces/places/deletes an image;
    /// 0 = storage empty. Never reused: safe as a cache key. Does NOT track
    /// placements moving on scroll/resize (use
    /// RenderState.imagePlacementsGeneration for that).
    pub fn generation(self: KittyGraphics) Error!u64 {
        var out: u64 = 0;
        try check(c.ghostty_kitty_graphics_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &out));
        return out;
    }

    /// Look up an image by id; null if absent or the protocol is disabled.
    /// The handle is borrowed until the next mutating terminal call (read
    /// pixels and draw within the same frame). Texture cache key =
    /// (image_id, generation).
    pub fn image(self: KittyGraphics, image_id: u32) ?KittyImage {
        const h = c.ghostty_kitty_graphics_image(self.handle, image_id) orelse return null;
        return .{ .handle = h };
    }

    /// Advance every playing animation to the frame due at `now_ms` (your
    /// monotonic clock, ms). Returns the next due time, or null when nothing
    /// is playing. Call ONCE per prepared frame, never in a loop; schedule
    /// the next redraw at the returned time (floor ~8 ms so the loop cannot
    /// spin). Mutates storage: invalidates image handles and pixel pointers,
    /// but not this storage handle (§9.4).
    pub fn animationTick(self: KittyGraphics, now_ms: u64) Error!?u64 {
        var next: u64 = 0;
        const r = c.ghostty_kitty_graphics_animation_tick(self.handle, now_ms, &next);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return next;
    }

    /// Populate a placement iterator with ALL storage placements (§9.3).
    /// For drawing use RenderState.images instead -- this iterator is for
    /// introspection; drawing from both double-draws.
    pub fn fillPlacements(self: KittyGraphics, iter: *KittyPlacementIterator) Error!void {
        try check(c.ghostty_kitty_graphics_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, @ptrCast(&iter.handle)));
    }
};

pub const KittyImage = struct {
    handle: c.GhosttyKittyGraphicsImage,

    pub fn id(self: KittyImage) Error!u32 {
        var out: u32 = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_ID, &out));
        return out;
    }
    pub fn width(self: KittyImage) Error!u32 {
        var out: u32 = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &out));
        return out;
    }
    pub fn height(self: KittyImage) Error!u32 {
        var out: u32 = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &out));
        return out;
    }
    /// Stored images are always fully decoded (never .png).
    pub fn format(self: KittyImage) Error!KittyImageFormat {
        var out: c.GhosttyKittyImageFormat = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &out));
        return @enumFromInt(out);
    }
    /// Changes when the pixels may change (send/replace/animation frame);
    /// never 0 for a stored image.
    pub fn generation(self: KittyImage) Error!u64 {
        var out: u64 = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, &out));
        return out;
    }
    /// width * height * bytes-per-pixel, known even before the pixels
    /// arrive (counts against the storage limit from the start).
    pub fn expectedLen(self: KittyImage) Error!usize {
        var out: usize = 0;
        try check(c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_EXPECTED_LEN, &out));
        return out;
    }
    /// Raw decoded pixels, borrowed until the next mutating terminal call
    /// or animationTick. null while the image is still arriving. For
    /// animations this is the current frame's pixels.
    pub fn pixels(self: KittyImage) Error!?[]const u8 {
        var out: c.GhosttyString = .{};
        const r = c.ghostty_kitty_graphics_image_get(self.handle, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return cSlice(out.ptr, out.len);
    }
};

/// Storage-side placement data (§9.3).
pub const KittyPlacement = struct {
    image_id: u32,
    placement_id: u32,
    /// Unicode placeholder cells; storage has no position for it.
    is_virtual: bool,
    /// Pixel offset within the top-left cell.
    x_offset: u32,
    y_offset: u32,
    /// Crop in image pixels; 0 width/height = full image.
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
    z: i32,
};

/// Geometry of a placement resolved against the current terminal (§9.3).
pub const PlacementRenderInfo = struct {
    pixel_width: u32,
    pixel_height: u32,
    grid_cols: u32,
    grid_rows: u32,
    /// Meaningful only when viewport_visible.
    viewport_col: i32,
    viewport_row: i32,
    viewport_visible: bool,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

pub const Autoscroll = enum(c_uint) { none = 0, up = 1, down = 2 };

pub const KittyPlacementIterator = struct {
    handle: c.GhosttyKittyGraphicsPlacementIterator,

    pub fn new() Error!KittyPlacementIterator {
        var handle: c.GhosttyKittyGraphicsPlacementIterator = null;
        try check(c.ghostty_kitty_graphics_placement_iterator_new(null, &handle));
        return .{ .handle = handle };
    }

    pub fn free(self: *KittyPlacementIterator) void {
        c.ghostty_kitty_graphics_placement_iterator_free(self.handle);
        self.handle = null;
    }

    /// Visit only certain layers: bitmask of layer masks (1<<layer).
    /// 0 = all layers (the default).
    pub fn setLayerMask(self: *KittyPlacementIterator, mask: u32) Error!void {
        try check(c.ghostty_kitty_graphics_placement_iterator_set(self.handle, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER, &mask));
    }

    pub fn next(self: *KittyPlacementIterator) bool {
        return c.ghostty_kitty_graphics_placement_next(self.handle);
    }

    /// Read the placement the iterator is positioned on.
    pub fn get(self: *KittyPlacementIterator) Error!KittyPlacement {
        var image_id: u32 = 0;
        var placement_id: u32 = 0;
        var is_virtual: bool = false;
        var x_offset: u32 = 0;
        var y_offset: u32 = 0;
        var src_x: u32 = 0;
        var src_y: u32 = 0;
        var src_w: u32 = 0;
        var src_h: u32 = 0;
        var columns: u32 = 0;
        var rows: u32 = 0;
        var z: i32 = 0;
        const keys = [_]c.GhosttyKittyGraphicsPlacementData{
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_X,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_Y,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_WIDTH,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_HEIGHT,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS,
            c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
        };
        var values = [_]?*anyopaque{
            &image_id, &placement_id, &is_virtual, &x_offset, &y_offset, &src_x,
            &src_y,    &src_w,        &src_h,      &columns,  &rows,     &z,
        };
        var written: usize = 0;
        try check(c.ghostty_kitty_graphics_placement_get_multi(self.handle, keys.len, &keys, &values, &written));
        return .{
            .image_id = image_id,
            .placement_id = placement_id,
            .is_virtual = is_virtual,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .source_x = src_x,
            .source_y = src_y,
            .source_width = src_w,
            .source_height = src_h,
            .columns = columns,
            .rows = rows,
            .z = z,
        };
    }

    /// Full resolved geometry of the current placement. Virtual placements
    /// have no position: viewport_visible is false.
    pub fn renderInfo(self: *KittyPlacementIterator, img: KittyImage, vt: *Vt) Error!PlacementRenderInfo {
        var out: c.GhosttyKittyGraphicsPlacementRenderInfo = .{ .size = @sizeOf(c.GhosttyKittyGraphicsPlacementRenderInfo) };
        try check(c.ghostty_kitty_graphics_placement_render_info(self.handle, img.handle, vt.handle, &out));
        return .{
            .pixel_width = out.pixel_width,
            .pixel_height = out.pixel_height,
            .grid_cols = out.grid_cols,
            .grid_rows = out.grid_rows,
            .viewport_col = out.viewport_col,
            .viewport_row = out.viewport_row,
            .viewport_visible = out.viewport_visible,
            .source_x = out.source_x,
            .source_y = out.source_y,
            .source_width = out.source_width,
            .source_height = out.source_height,
        };
    }

    /// Top-left cell in the viewport; row negative above the viewport.
    /// null when the placement is entirely outside (or virtual).
    pub fn viewportPos(self: *KittyPlacementIterator, img: KittyImage, vt: *Vt) Error!?struct { col: i32, row: i32 } {
        var col: i32 = 0;
        var row: i32 = 0;
        const r = c.ghostty_kitty_graphics_placement_viewport_pos(self.handle, img.handle, vt.handle, &col, &row);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return .{ .col = col, .row = row };
    }
};

// ---------------------------------------------------------------------------
// Key encoder (§5.1)
// ---------------------------------------------------------------------------

pub const Key = keymap.GhosttyKey;
pub const Mods = keymap.GhosttyMods;
pub const KeyAction = keymap.GhosttyKeyAction;

/// One key event. `key` is the PHYSICAL W3C code (layout-independent);
/// `utf8` is the layout-produced UNMODIFIED text (never C0 controls -- leave
/// empty and the encoder uses the logical key). `unshifted_codepoint` feeds
/// the kitty protocol's alternate reporting (0 = unknown).
pub const KeyEvent = struct {
    action: KeyAction = .press,
    key: Key,
    mods: Mods = 0,
    utf8: []const u8 = "",
    unshifted_codepoint: u32 = 0,
};

pub const KeyEncoder = struct {
    handle: c.GhosttyKeyEncoder,
    event: c.GhosttyKeyEvent,

    pub fn new() Error!KeyEncoder {
        var handle: c.GhosttyKeyEncoder = null;
        try check(c.ghostty_key_encoder_new(null, &handle));
        errdefer c.ghostty_key_encoder_free(handle);
        var event: c.GhosttyKeyEvent = null;
        try check(c.ghostty_key_event_new(null, &event));
        return .{ .handle = handle, .event = event };
    }

    pub fn free(self: *KeyEncoder) void {
        c.ghostty_key_event_free(self.event);
        c.ghostty_key_encoder_free(self.handle);
        self.* = undefined;
    }

    /// Copy the terminal's current modes (cursor/keypad application,
    /// modifyOtherKeys, kitty flags, ...) into the encoder. Call after
    /// writes that may have changed modes.
    pub fn setFromTerminal(self: *KeyEncoder, vt: *Vt) Error!void {
        try check(c.ghostty_key_encoder_set_from_terminal(self.handle, vt.handle));
    }

    /// Encode into the caller's buffer, returning the written slice (empty
    /// when the event produces no output, e.g. an unmodified modifier key).
    /// error.OutOfSpace when the buffer is too small (retry larger; key
    /// sequences are short). `ev.utf8` is borrowed for this call only.
    pub fn encode(self: *KeyEncoder, ev: KeyEvent, buf: []u8) Error![]const u8 {
        try check(c.ghostty_key_event_set_action(self.event, @intCast(@intFromEnum(ev.action))));
        try check(c.ghostty_key_event_set_key(self.event, @intFromEnum(ev.key)));
        try check(c.ghostty_key_event_set_mods(self.event, ev.mods));
        try check(c.ghostty_key_event_set_utf8(self.event, toCString(ev.utf8)));
        try check(c.ghostty_key_event_set_unshifted_codepoint(self.event, ev.unshifted_codepoint));
        var written: usize = 0;
        try check(c.ghostty_key_encoder_encode(self.handle, self.event, buf.ptr, buf.len, &written));
        return buf[0..written];
    }
};

// ---------------------------------------------------------------------------
// Mouse encoder (§5.2)
// ---------------------------------------------------------------------------

/// Mouse event in surface-space pixels. `button` null = no button (normal
/// for motion events).
pub const MouseEvent = struct {
    action: MouseAction,
    button: ?MouseButton = null,
    mods: Mods = 0,
    x: f32,
    y: f32,
};

/// Screen/cell geometry for the mouse encoder (sized struct in C).
/// cell_width/cell_height must be nonzero.
pub const MouseSize = struct {
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    padding_top: u32 = 0,
    padding_bottom: u32 = 0,
    padding_right: u32 = 0,
    padding_left: u32 = 0,
};

pub const MouseEncoder = struct {
    handle: c.GhosttyMouseEncoder,
    event: c.GhosttyMouseEvent,

    pub fn new() Error!MouseEncoder {
        var handle: c.GhosttyMouseEncoder = null;
        try check(c.ghostty_mouse_encoder_new(null, &handle));
        errdefer c.ghostty_mouse_encoder_free(handle);
        var event: c.GhosttyMouseEvent = null;
        try check(c.ghostty_mouse_event_new(null, &event));
        return .{ .handle = handle, .event = event };
    }

    pub fn free(self: *MouseEncoder) void {
        c.ghostty_mouse_event_free(self.event);
        c.ghostty_mouse_encoder_free(self.handle);
        self.* = undefined;
    }

    /// Copy tracking mode + format from the terminal and clear last-cell
    /// state. There is NO "mouse mode changed" callback: poll
    /// Vt.mouseTracking() after writes (and Vt.mouseShape() for the OSC 22
    /// pointer shape), or refresh with this call before encoding.
    pub fn setFromTerminal(self: *MouseEncoder, vt: *Vt) Error!void {
        try check(c.ghostty_mouse_encoder_set_from_terminal(self.handle, vt.handle));
    }

    pub fn setSize(self: *MouseEncoder, size: MouseSize) Error!void {
        var s: c.GhosttyMouseEncoderSize = .{
            .size = @sizeOf(c.GhosttyMouseEncoderSize),
            .screen_width = size.screen_width,
            .screen_height = size.screen_height,
            .cell_width = size.cell_width,
            .cell_height = size.cell_height,
            .padding_top = size.padding_top,
            .padding_bottom = size.padding_bottom,
            .padding_right = size.padding_right,
            .padding_left = size.padding_left,
        };
        try check(c.ghostty_mouse_encoder_set(self.handle, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &s));
    }

    pub fn reset(self: *MouseEncoder) Error!void {
        try check(c.ghostty_mouse_encoder_reset(self.handle));
    }

    /// Encode into the caller's buffer; empty slice when tracking is off or
    /// the event is deduplicated. error.OutOfSpace when too small.
    pub fn encode(self: *MouseEncoder, ev: MouseEvent, buf: []u8) Error![]const u8 {
        try check(c.ghostty_mouse_event_set_action(self.event, @intFromEnum(ev.action)));
        if (ev.button) |b| {
            try check(c.ghostty_mouse_event_set_button(self.event, @intFromEnum(b)));
        } else {
            try check(c.ghostty_mouse_event_clear_button(self.event));
        }
        try check(c.ghostty_mouse_event_set_mods(self.event, ev.mods));
        try check(c.ghostty_mouse_event_set_position(self.event, .{ .x = ev.x, .y = ev.y }));
        var written: usize = 0;
        try check(c.ghostty_mouse_encoder_encode(self.handle, self.event, buf.ptr, buf.len, &written));
        return buf[0..written];
    }
};

/// Focus event bytes: CSI I on gain, CSI O on loss (§5.3). Only send while
/// mode 1004 is set (Vt.getMode(mode(1004, false))).
pub fn focusEncode(gained: bool, buf: []u8) Error![]const u8 {
    var written: usize = 0;
    const event: c.GhosttyFocusEvent = if (gained) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST;
    try check(c.ghostty_focus_encode(event, buf.ptr, buf.len, &written));
    return buf[0..written];
}

// ---------------------------------------------------------------------------
// Selection gesture (§6.5) + selected text (§6.4)
// ---------------------------------------------------------------------------

/// Surface geometry for drag/autoscroll (cell_width and screen_height must
/// be nonzero).
pub const GestureGeometry = struct {
    columns: u32,
    cell_width: u32,
    padding_left: u32 = 0,
    screen_height: u32,
};

pub const PressOptions = struct {
    /// Surface position of the press (pixels).
    position: ?SurfacePosition = null,
    /// Monotonic time of the press; without it only single-click is
    /// possible.
    time_ns: ?u64 = null,
    /// Max movement (pixels) that still counts as a repeat click.
    repeat_distance: ?f64 = null,
    /// Max interval between clicks for double/triple click.
    repeat_interval_ns: ?u64 = null,
};

/// Pointer-gesture interpreter (§6.5). Create once; serialize calls with
/// terminal mutations (gestures hold tracked refs). Events do NOT install
/// the selection -- pass the result to Vt.setSelection yourself.
pub const SelectionGesture = struct {
    handle: c.GhosttySelectionGesture,
    press_ev: c.GhosttySelectionGestureEvent,
    drag_ev: c.GhosttySelectionGestureEvent,
    tick_ev: c.GhosttySelectionGestureEvent,
    release_ev: c.GhosttySelectionGestureEvent,

    pub fn new() Error!SelectionGesture {
        var handle: c.GhosttySelectionGesture = null;
        try check(c.ghostty_selection_gesture_new(null, &handle));
        errdefer c.ghostty_selection_gesture_free(handle, null);

        var press_ev: c.GhosttySelectionGestureEvent = null;
        try check(c.ghostty_selection_gesture_event_new(null, &press_ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS));
        errdefer c.ghostty_selection_gesture_event_free(press_ev);
        var drag_ev: c.GhosttySelectionGestureEvent = null;
        try check(c.ghostty_selection_gesture_event_new(null, &drag_ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG));
        errdefer c.ghostty_selection_gesture_event_free(drag_ev);
        var tick_ev: c.GhosttySelectionGestureEvent = null;
        try check(c.ghostty_selection_gesture_event_new(null, &tick_ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK));
        errdefer c.ghostty_selection_gesture_event_free(tick_ev);
        var release_ev: c.GhosttySelectionGestureEvent = null;
        try check(c.ghostty_selection_gesture_event_new(null, &release_ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE));
        return .{
            .handle = handle,
            .press_ev = press_ev,
            .drag_ev = drag_ev,
            .tick_ev = tick_ev,
            .release_ev = release_ev,
        };
    }

    /// Pass the terminal most recently used, or null if it was freed.
    pub fn free(self: *SelectionGesture, vt: ?*Vt) void {
        c.ghostty_selection_gesture_event_free(self.release_ev);
        c.ghostty_selection_gesture_event_free(self.tick_ev);
        c.ghostty_selection_gesture_event_free(self.drag_ev);
        c.ghostty_selection_gesture_event_free(self.press_ev);
        c.ghostty_selection_gesture_free(self.handle, if (vt) |v| v.handle else null);
        self.* = undefined;
    }

    pub fn reset(self: *SelectionGesture, vt: *Vt) void {
        c.ghostty_selection_gesture_reset(self.handle, vt.handle);
    }

    /// Press at a cell: applies click-count logic (single/double/triple ->
    /// cell/word/line by default) and returns the selection snapshot. A
    /// single click (cell behavior) returns null -- the selection starts at
    /// the first drag; double/triple clicks select the word/line at once.
    pub fn press(self: *SelectionGesture, vt: *Vt, ref: GridRef, opts: PressOptions) Error!?Selection {
        const ev = self.press_ev;
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref));
        if (opts.position) |p| {
            const pos: c.GhosttySurfacePosition = .{ .x = p.x, .y = p.y };
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos));
        }
        if (opts.time_ns) |t| {
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &t));
        }
        if (opts.repeat_distance) |d| {
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &d));
        }
        if (opts.repeat_interval_ns) |i| {
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &i));
        }
        // NOTE: RECTANGLE/GEOMETRY/VIEWPORT are invalid on PRESS events
        // (the library rejects them); rectangle selection starts at drag.
        return self.dispatch(vt, ev);
    }

    /// Extend the selection to a cell; updates the autoscroll request
    /// (query with autoscroll()). `position` is the pointer in surface
    /// pixels: a cell is only included once the pointer crosses ~60% of its
    /// width, so pass the real pointer position, not the cell origin.
    pub fn drag(self: *SelectionGesture, vt: *Vt, ref: GridRef, position: SurfacePosition, geometry: GestureGeometry, rectangle: bool) Error!?Selection {
        const ev = self.drag_ev;
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref));
        const pos: c.GhosttySurfacePosition = .{ .x = position.x, .y = position.y };
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos));
        const geom = geometryToC(geometry);
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geom));
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle));
        return self.dispatch(vt, ev);
    }

    /// Autoscroll tick: scrolls the viewport exactly one row in the reported
    /// direction and continues the drag there. You own the timer (tick
    /// faster = scroll faster). null when there is no direction.
    pub fn tick(self: *SelectionGesture, vt: *Vt, viewport: Point, position: SurfacePosition, geometry: GestureGeometry) Error!?Selection {
        const ev = self.tick_ev;
        const coord: c.GhosttyPointCoordinate = .{ .x = viewport.x, .y = viewport.y };
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &coord));
        const pos: c.GhosttySurfacePosition = .{ .x = position.x, .y = position.y };
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos));
        const geom = geometryToC(geometry);
        try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geom));
        return self.dispatch(vt, ev);
    }

    /// Release; `ref` null = the pointer missed a cell. Produces no
    /// selection.
    pub fn release(self: *SelectionGesture, vt: *Vt, ref: ?GridRef) Error!void {
        const ev = self.release_ev;
        if (ref) |r| {
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &r));
        } else {
            try check(c.ghostty_selection_gesture_event_set(ev, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, null));
        }
        _ = try self.dispatch(vt, ev);
    }

    /// 0 = inactive, 1/2/3 = single/double/triple click.
    pub fn clickCount(self: *SelectionGesture, vt: *Vt) Error!u8 {
        var out: u8 = 0;
        try check(c.ghostty_selection_gesture_get(self.handle, vt.handle, c.GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &out));
        return out;
    }

    pub fn dragged(self: *SelectionGesture, vt: *Vt) Error!bool {
        var out: bool = false;
        try check(c.ghostty_selection_gesture_get(self.handle, vt.handle, c.GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &out));
        return out;
    }

    pub fn autoscroll(self: *SelectionGesture, vt: *Vt) Error!Autoscroll {
        var out: c.GhosttySelectionGestureAutoscroll = 0;
        try check(c.ghostty_selection_gesture_get(self.handle, vt.handle, c.GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &out));
        return @enumFromInt(out);
    }

    fn dispatch(self: *SelectionGesture, vt: *Vt, ev: c.GhosttySelectionGestureEvent) Error!?Selection {
        var out: c.GhosttySelection = undefined;
        const r = c.ghostty_selection_gesture_event(self.handle, vt.handle, ev, &out);
        if (r == c.GHOSTTY_NO_VALUE) return null;
        try check(r);
        return @as(*const Selection, @ptrCast(&out)).*;
    }
};

fn geometryToC(g: GestureGeometry) c.GhosttySelectionGestureGeometry {
    return .{
        .columns = g.columns,
        .cell_width = g.cell_width,
        .padding_left = g.padding_left,
        .screen_height = g.screen_height,
    };
}

/// The selected text, formatted exactly like Ghostty's clipboard copy:
/// PLAIN + UNWRAP + TRIM (§6.4). Writes into the caller's buffer;
/// error.OutOfSpace when too small. `sel` refs must be valid untracked
/// snapshots (no terminal mutation since they were produced).
pub fn selectedText(vt: *Vt, sel: *const Selection, buf: []u8) Error![]const u8 {
    var formatter: c.GhosttyFormatter = null;
    try check(c.ghostty_formatter_terminal_new(null, &formatter, vt.handle));
    defer c.ghostty_formatter_free(formatter);

    const emit: c.GhosttyFormatterFormat = c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_EMIT, &emit));
    const unwrap: bool = true;
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap));
    const trim: bool = true;
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_TRIM, &trim));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, sel));

    var written: usize = 0;
    try check(c.ghostty_formatter_format_buf(formatter, buf.ptr, buf.len, &written));
    return buf[0..written];
}

// ---------------------------------------------------------------------------
// Tests -- real library round-trips (see the recipe in the header comment)
// ---------------------------------------------------------------------------

const testing = std.testing;

// Force semantic analysis of every public declaration (not just the ones
// the behavioral tests happen to call), so the whole API surface is
// type-checked even before the session manager wires it up.
test "public API surface compiles" {
    // Reference every wrapper type so all of their methods are analyzed.
    // (Not a blind recursion: the vt-c module contains @compileError macro
    // stubs that must not be referenced.)
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Vt);
    std.testing.refAllDecls(RenderState);
    std.testing.refAllDecls(Rows);
    std.testing.refAllDecls(Row);
    std.testing.refAllDecls(Cells);
    std.testing.refAllDecls(Images);
    std.testing.refAllDecls(Effects);
    std.testing.refAllDecls(KeyEncoder);
    std.testing.refAllDecls(MouseEncoder);
    std.testing.refAllDecls(SelectionGesture);
    std.testing.refAllDecls(KittyGraphics);
    std.testing.refAllDecls(KittyImage);
    std.testing.refAllDecls(KittyPlacementIterator);
    std.testing.refAllDecls(ClipboardWriteRequest);
    std.testing.refAllDecls(ClipboardReadRequest);
    std.testing.refAllDecls(ImageAllocator);
    std.testing.refAllDecls(Style);
    std.testing.refAllDecls(Cursor);
}

/// Effects capture context: records pty replies and effect hits.
const Capture = struct {
    pty: [8192]u8 = undefined,
    pty_len: usize = 0,
    bells: u32 = 0,
    titles: u32 = 0,
    last_title: [256]u8 = undefined,
    last_title_len: usize = 0,
    pwds: u32 = 0,
    resets: u32 = 0,
    holds: u32 = 0,
    last_held: bool = false,
    resize_rows: u16 = 0,
    resize_cols: u16 = 0,
    resizes: u32 = 0,
    unknowns: u32 = 0,
    last_unknown: [4096]u8 = undefined,
    last_unknown_len: usize = 0,
    last_unknown_tag: UnknownSequenceTag = .osc,
    last_unknown_terminator: OscTerminator = .st,
    last_unknown_truncated: bool = false,
    clip_writes: u32 = 0,
    last_clip_data: [256]u8 = undefined,
    last_clip_data_len: usize = 0,
    clip_reads: u32 = 0,
    size_reports: u32 = 0,
    schemes: u32 = 0,
    das: u32 = 0,
    notifications: u32 = 0,
    progress: u32 = 0,
    program_status: u32 = 0,
    semantic_prompts: u32 = 0,

    fn writePty(userdata: ?*anyopaque, data: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        const n = @min(data.len, self.pty.len - self.pty_len);
        @memcpy(self.pty[self.pty_len..][0..n], data[0..n]);
        self.pty_len += n;
    }
    fn ptyBytes(self: *Capture) []const u8 {
        return self.pty[0..self.pty_len];
    }
    fn clearPty(self: *Capture) void {
        self.pty_len = 0;
    }
    fn bell(userdata: ?*anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.bells += 1;
    }
    fn titleChanged(userdata: ?*anyopaque, title: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.titles += 1;
        const n = @min(title.len, self.last_title.len);
        @memcpy(self.last_title[0..n], title[0..n]);
        self.last_title_len = n;
    }
    fn pwdChanged(userdata: ?*anyopaque, _: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.pwds += 1;
    }
    fn enquiry(_: ?*anyopaque) []const u8 {
        return "OK";
    }
    fn xtversion(_: ?*anyopaque) []const u8 {
        return "kmshaunt-test";
    }
    fn size(userdata: ?*anyopaque, out: *SizeReport) bool {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.size_reports += 1;
        out.* = .{ .rows = 30, .columns = 100, .cell_width = 8, .cell_height = 16 };
        return true;
    }
    fn colorScheme(userdata: ?*anyopaque, out: *ColorScheme) bool {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.schemes += 1;
        out.* = .dark;
        return true;
    }
    fn deviceAttributes(userdata: ?*anyopaque, out: *DeviceAttributes) bool {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.das += 1;
        out.primary = .{ .conformance_level = 63, .features = @splat(0), .num_features = 1 };
        out.primary.features[0] = 1;
        out.secondary = .{ .device_type = 1, .firmware_version = 10, .rom_cartridge = 0 };
        out.tertiary = .{ .unit_id = 0x12345678 };
        return true;
    }
    fn clipboardWrite(userdata: ?*anyopaque, req: *const ClipboardWriteRequest) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.clip_writes += 1;
        if (req.contents.len > 0) {
            const data = req.contents[0].data;
            const n = @min(data.len, self.last_clip_data.len);
            @memcpy(self.last_clip_data[0..n], data[0..n]);
            self.last_clip_data_len = n;
        }
        req.reply(.success, false);
    }
    fn clipboardRead(userdata: ?*anyopaque, req: *const ClipboardReadRequest) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.clip_reads += 1;
        const contents = [_]ClipboardContent{.{ .mime = "text/plain", .data = "world" }};
        req.reply(.success, &contents, &.{}, false);
    }
    fn renderHold(userdata: ?*anyopaque, held: bool) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.holds += 1;
        self.last_held = held;
    }
    fn reset(userdata: ?*anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.resets += 1;
    }
    fn resizeWindow(userdata: ?*anyopaque, rows: u16, cols: u16) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.resizes += 1;
        self.resize_rows = rows;
        self.resize_cols = cols;
    }
    fn unknownSequence(userdata: ?*anyopaque, seq: UnknownSequence) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.unknowns += 1;
        const n = @min(seq.content.len, self.last_unknown.len);
        @memcpy(self.last_unknown[0..n], seq.content[0..n]);
        self.last_unknown_len = n;
        self.last_unknown_tag = seq.tag;
        self.last_unknown_terminator = seq.terminator;
        self.last_unknown_truncated = seq.truncated;
    }
    fn desktopNotification(userdata: ?*anyopaque, _: DesktopNotification) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.notifications += 1;
    }
    fn progressReport(userdata: ?*anyopaque, _: ProgressReport) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.progress += 1;
    }
    fn programStatus(userdata: ?*anyopaque, _: ProgramStatus) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.program_status += 1;
    }
    fn semanticPrompt(userdata: ?*anyopaque, _: SemanticPrompt) void {
        const self: *Capture = @ptrCast(@alignCast(userdata.?));
        self.semantic_prompts += 1;
    }

    fn effects(self: *Capture) Effects {
        return .{
            .userdata = self,
            .write_pty = writePty,
            .bell = bell,
            .title_changed = titleChanged,
            .pwd_changed = pwdChanged,
            .enquiry = enquiry,
            .xtversion = xtversion,
            .size = size,
            .color_scheme = colorScheme,
            .device_attributes = deviceAttributes,
            .clipboard_write = clipboardWrite,
            .clipboard_read = clipboardRead,
            .render_hold = renderHold,
            .reset = reset,
            .resize_window = resizeWindow,
            .unknown_sequence = unknownSequence,
            .desktop_notification = desktopNotification,
            .progress_report = progressReport,
            .program_status = programStatus,
            .semantic_prompt = semanticPrompt,
        };
    }
};

fn testVt(effects: *Effects) !Vt {
    var vt = try Vt.init(80, 24);
    errdefer vt.deinit();
    try vt.setEffects(effects);
    return vt;
}

test "version and library features" {
    try testing.expectEqualStrings("1.0.1", version());
    var kitty: bool = false;
    try check(c.ghostty_build_info(c.GHOSTTY_BUILD_INFO_KITTY_GRAPHICS, &kitty));
    try testing.expect(kitty);
}

test "terminal write, render state cells, cursor, dirty lifecycle" {
    var vt = try Vt.init(80, 24);
    defer vt.deinit();
    var rs = try RenderState.new();
    defer rs.deinit();

    vt.write("hello\r\nworld");
    vt.write("\x1b[3;5H"); // cursor to row 3, col 5 (1-based)

    try testing.expectEqual(@as(u16, 80), try vt.cols());
    try testing.expectEqual(@as(u16, 24), try vt.rows());
    try testing.expectEqual(@as(u16, 4), try vt.cursorX());
    try testing.expectEqual(@as(u16, 2), try vt.cursorY());

    try rs.update(&vt);
    try testing.expectEqual(Dirty.full, try rs.dirty());
    try testing.expectEqual(@as(u16, 80), try rs.cols());
    try testing.expectEqual(@as(u16, 24), try rs.rows());

    const cursor = try rs.cursor();
    try testing.expect(cursor.visible);
    try testing.expectEqual(CursorStyle.block, cursor.style);
    try testing.expectEqual(@as(u16, 4), cursor.viewport.?.x);
    try testing.expectEqual(@as(u16, 2), cursor.viewport.?.y);

    const colors = try rs.colors();
    try testing.expectEqual(@as(?Rgb, null), colors.cursor);

    var rows = try rs.rowsIter();
    var seen: u32 = 0;
    var row0_text: [80]u8 = undefined;
    var row0_len: usize = 0;
    var row1_text: [80]u8 = undefined;
    var row1_len: usize = 0;
    while (try rows.nextDirty()) |row| {
        seen += 1;
        var cells = try row.cells();
        var x: usize = 0;
        while (try cells.next()) |cell| {
            if (row.y == 0 and x < row0_text.len) {
                const n = @min(cell.text.len, row0_text.len - x);
                @memcpy(row0_text[x..][0..n], cell.text[0..n]);
                if (n > 0) row0_len = @max(row0_len, x + n);
            }
            if (row.y == 1 and x < row1_text.len) {
                const n = @min(cell.text.len, row1_text.len - x);
                @memcpy(row1_text[x..][0..n], cell.text[0..n]);
                if (n > 0) row1_len = @max(row1_len, x + n);
            }
            if (row.y == 0 and x == 0) {
                try testing.expectEqualStrings("h", cell.text);
                try testing.expectEqual(Wide.narrow, cell.wide);
                try testing.expectEqual(@as(?Rgb, null), cell.fg);
                try testing.expectEqual(@as(?Rgb, null), cell.bg);
                try testing.expect(cell.style.isDefault());
                try testing.expect(!cell.selected);
            }
            x += 1;
        }
        try testing.expectEqual(@as(usize, 80), x);
    }
    try testing.expectEqual(@as(u32, 24), seen);
    try testing.expectEqualStrings("hello", row0_text[0..row0_len]);
    try testing.expectEqualStrings("world", row1_text[0..row1_len]);

    // clean -> no dirty; a fresh write -> partial with only that row dirty.
    try rs.clean();
    try testing.expectEqual(Dirty.clean, try rs.dirty());
    try rs.update(&vt);
    try testing.expectEqual(Dirty.clean, try rs.dirty());

    vt.write("\x1b[1;1HXYZ");
    try rs.update(&vt);
    try testing.expectEqual(Dirty.partial, try rs.dirty());
    rows = try rs.rowsIter();
    var dirty_rows: u32 = 0;
    var saw_row0 = false;
    while (try rows.nextDirty()) |row| {
        dirty_rows += 1;
        try testing.expect(try row.dirty());
        // The written row plus the row the cursor left are dirty.
        try testing.expect(row.y == 0 or row.y == 2);
        if (row.y == 0) {
            saw_row0 = true;
            try testing.expectEqual(@as(i32, 0), try row.viewportY());
            var cells = try row.cells();
            const c0 = (try cells.next()) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("X", c0.text);
        }
    }
    try testing.expect(saw_row0);
    try testing.expectEqual(@as(u32, 2), dirty_rows);
}

test "effects: writePty captures the built-in DA reply" {
    var cap: Capture = .{};
    var effects = cap.effects();
    // No device_attributes callback override: null -> built-in VT220.
    effects.device_attributes = null;
    var vt = try testVt(&effects);
    defer vt.deinit();

    vt.write("\x1b[c");
    try testing.expectEqualStrings("\x1b[?62;22c", cap.ptyBytes());
}

test "effects: custom device attributes, enquiry, xtversion, color scheme" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    vt.write("\x1b[c");
    try testing.expectEqual(@as(u32, 1), cap.das);
    try testing.expectEqualStrings("\x1b[?63;1c", cap.ptyBytes());

    cap.clearPty();
    vt.write("\x05");
    try testing.expectEqualStrings("OK", cap.ptyBytes());

    cap.clearPty();
    vt.write("\x1b[>q");
    try testing.expect(std.mem.indexOf(u8, cap.ptyBytes(), "kmshaunt-test") != null);

    cap.clearPty();
    vt.write("\x1b[?996n");
    try testing.expectEqual(@as(u32, 1), cap.schemes);
    try testing.expectEqualStrings("\x1b[?997;1n", cap.ptyBytes());
}

test "effects: bell, title, pwd, reset, render hold, resize window" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    vt.write("\x07");
    try testing.expectEqual(@as(u32, 1), cap.bells);

    vt.write("\x1b]0;My Title\x07");
    try testing.expectEqual(@as(u32, 1), cap.titles);
    try testing.expectEqualStrings("My Title", cap.last_title[0..cap.last_title_len]);
    try testing.expectEqualStrings("My Title", try vt.title());

    vt.write("\x1b]7;file://host/tmp\x07");
    try testing.expectEqual(@as(u32, 1), cap.pwds);
    try testing.expectEqualStrings("file://host/tmp", try vt.pwd());

    vt.write("\x1b[?2026h");
    try testing.expectEqual(@as(u32, 1), cap.holds);
    try testing.expect(cap.last_held);
    vt.write("\x1b[?2026l");
    try testing.expectEqual(@as(u32, 2), cap.holds);
    try testing.expect(!cap.last_held);

    vt.write("\x1b[8;10;20t");
    try testing.expectEqual(@as(u32, 1), cap.resizes);
    try testing.expectEqual(@as(u16, 10), cap.resize_rows);
    try testing.expectEqual(@as(u16, 20), cap.resize_cols);
    // The terminal itself is NOT resized by the request.
    try testing.expectEqual(@as(u16, 80), try vt.cols());

    vt.write("\x1bc");
    try testing.expectEqual(@as(u32, 1), cap.resets);
    try testing.expectEqualStrings("", try vt.title());
}

test "effects: notifications (desktop, progress, program status, semantic prompt)" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    vt.write("\x1b]9;Hello there\x07");
    try testing.expectEqual(@as(u32, 1), cap.notifications);

    vt.write("\x1b]9;4;1;50\x07");
    try testing.expectEqual(@as(u32, 1), cap.progress);

    vt.write("\x1b]133;A\x07");
    try testing.expectEqual(@as(u32, 1), cap.semantic_prompts);

    vt.write("\x1b]7501;state=working:app=test\x07");
    try testing.expectEqual(@as(u32, 1), cap.program_status);
}

test "effects: unknown OSC arrives verbatim (kmscon private hook)" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    vt.write("\x1b]setBackground\x07");
    try testing.expectEqual(@as(u32, 1), cap.unknowns);
    try testing.expectEqualStrings("setBackground", cap.last_unknown[0..cap.last_unknown_len]);
    try testing.expectEqual(@as(@TypeOf(cap.last_unknown_tag), .osc), cap.last_unknown_tag);
    try testing.expectEqual(OscTerminator.bel, cap.last_unknown_terminator);
    try testing.expect(!cap.last_unknown_truncated);

    // Numeric-but-unimplemented OSC keeps the number in the content.
    vt.write("\x1b]7400;status=busy\x1b\\");
    try testing.expectEqual(@as(u32, 2), cap.unknowns);
    try testing.expectEqualStrings("7400;status=busy", cap.last_unknown[0..cap.last_unknown_len]);
    try testing.expectEqual(OscTerminator.st, cap.last_unknown_terminator);

    // Unknown APC.
    vt.write("\x1b_unknown-apc\x1b\\");
    try testing.expectEqual(@as(u32, 3), cap.unknowns);
    try testing.expectEqual(@as(@TypeOf(cap.last_unknown_tag), .apc), cap.last_unknown_tag);
    try testing.expectEqualStrings("unknown-apc", cap.last_unknown[0..cap.last_unknown_len]);
}

test "effects: clipboard write and read reply before return" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    // OSC 52 write, base64 "hello".
    vt.write("\x1b]52;c;aGVsbG8=\x07");
    try testing.expectEqual(@as(u32, 1), cap.clip_writes);
    try testing.expectEqualStrings("hello", cap.last_clip_data[0..cap.last_clip_data_len]);

    // OSC 52 read: our reply "world" must come back base64-encoded.
    cap.clearPty();
    vt.write("\x1b]52;c;?\x07");
    try testing.expectEqual(@as(u32, 1), cap.clip_reads);
    try testing.expect(std.mem.indexOf(u8, cap.ptyBytes(), "d29ybGQ=") != null);
}

test "resize changes reported size and answers XTWINOPS" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    try vt.resize(100, 30, 8, 16);
    try testing.expectEqual(@as(u16, 100), try vt.cols());
    try testing.expectEqual(@as(u16, 30), try vt.rows());
    try testing.expectEqual(@as(u32, 800), try vt.widthPx());
    try testing.expectEqual(@as(u32, 480), try vt.heightPx());

    cap.clearPty();
    vt.write("\x1b[18t"); // report grid size
    try testing.expectEqual(@as(u32, 1), cap.size_reports);
    try testing.expectEqualStrings("\x1b[8;30;100t", cap.ptyBytes());

    // In-band size reports (mode 2048) fire on resize itself.
    try vt.setMode(mode(2048, false), true);
    cap.clearPty();
    try vt.resize(90, 25, 8, 16);
    // NOTE: the resize path encodes the mode-2048 report itself (from the
    // resize geometry) and writes it via write_pty -- the SIZE callback is
    // only consulted for VT queries and VT-stream mode enablement.
    try testing.expect(std.mem.indexOf(u8, cap.ptyBytes(), "\x1b[48;25;90;400;720t") != null);
}

test "key encoder: plain text, ctrl-c, arrows; OutOfSpace on tiny buffer" {
    var vt = try Vt.init(80, 24);
    defer vt.deinit();
    var enc = try KeyEncoder.new();
    defer enc.free();
    try enc.setFromTerminal(&vt);

    var buf: [64]u8 = undefined;
    const a = try enc.encode(.{ .key = .a, .utf8 = "a" }, &buf);
    try testing.expectEqualStrings("a", a);

    const ctrl_c = try enc.encode(.{ .key = .c, .mods = keymap.mod_ctrl }, &buf);
    try testing.expectEqualStrings("\x03", ctrl_c);

    const up = try enc.encode(.{ .key = .arrow_up }, &buf);
    try testing.expectEqualStrings("\x1b[A", up);

    const enter = try enc.encode(.{ .key = .enter }, &buf);
    try testing.expectEqualStrings("\r", enter);

    // Unmodified modifier key: no output.
    const shift = try enc.encode(.{ .key = .shift_left }, &buf);
    try testing.expectEqual(@as(usize, 0), shift.len);

    var tiny: [1]u8 = undefined;
    try testing.expectError(Error.OutOfSpace, enc.encode(.{ .key = .arrow_up }, &tiny));
}

test "mouse encoder: SGR press/release, tracking poll, OSC 22 shape" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    try testing.expect(!try vt.mouseTracking());
    try testing.expectEqual(MouseShape.text, try vt.mouseShape());

    vt.write("\x1b[?1000;1006h"); // normal tracking + SGR format
    try testing.expect(try vt.mouseTracking());

    var enc = try MouseEncoder.new();
    defer enc.free();
    try enc.setFromTerminal(&vt);
    try enc.setSize(.{
        .screen_width = 640,
        .screen_height = 384,
        .cell_width = 8,
        .cell_height = 16,
    });

    var buf: [64]u8 = undefined;
    const press = try enc.encode(.{ .action = .press, .button = .left, .x = 0, .y = 0 }, &buf);
    try testing.expectEqualStrings("\x1b[<0;1;1M", press);
    const release = try enc.encode(.{ .action = .release, .button = .left, .x = 0, .y = 0 }, &buf);
    try testing.expectEqualStrings("\x1b[<0;1;1m", release);

    vt.write("\x1b]22;pointer\x07");
    try testing.expectEqual(MouseShape.pointer, try vt.mouseShape());

    vt.write("\x1b[?1000l");
    try testing.expect(!try vt.mouseTracking());
    try enc.setFromTerminal(&vt);
    const off = try enc.encode(.{ .action = .press, .button = .left, .x = 0, .y = 0 }, &buf);
    try testing.expectEqual(@as(usize, 0), off.len);
}

test "focus encode" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b[I", try focusEncode(true, &buf));
    try testing.expectEqualStrings("\x1b[O", try focusEncode(false, &buf));
}

test "paste: plain, bracketed, unsafe rejection and retry" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    try testing.expect(pasteIsSafe("hello"));
    try testing.expect(!pasteIsSafe("a\nb"));
    try testing.expect(!pasteIsSafe("a\x1b[201~b"));

    try testing.expect(try vt.paste("hi", .{}));
    try testing.expectEqualStrings("hi", cap.ptyBytes());

    cap.clearPty();
    try vt.setMode(mode(2004, false), true);
    try testing.expect(try vt.paste("hi", .{}));
    try testing.expectEqualStrings("\x1b[200~hi\x1b[201~", cap.ptyBytes());

    // Unsafe text: refused, nothing written; retry with allow_unsafe.
    cap.clearPty();
    try vt.setMode(mode(2004, false), false);
    try testing.expectError(Error.Rejected, vt.paste("a\nb", .{}));
    try testing.expectEqual(@as(usize, 0), cap.ptyBytes().len);
    try testing.expect(try vt.paste("a\nb", .{ .allow_unsafe = true }));
    try testing.expectEqualStrings("a\rb", cap.ptyBytes());
}

test "render state: styles, resolved colors, graphemes, wide cells" {
    var vt = try Vt.init(80, 24);
    defer vt.deinit();
    var rs = try RenderState.new();
    defer rs.deinit();

    vt.write("\x1b[1;31;44mX\x1b[0m");
    vt.write("e\u{0301}"); // e + combining acute
    vt.write("界");

    try rs.update(&vt);
    const colors = try rs.colors();
    var rows = try rs.rowsIter();
    const row = (try rows.nextDirty()) orelse return error.TestUnexpectedResult;
    var cells = try row.cells();

    const x_cell = (try cells.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("X", x_cell.text);
    try testing.expect(x_cell.style.flags.bold);
    try testing.expect(x_cell.has_styling);
    try testing.expectEqual(colors.palette[1], x_cell.fg.?);
    try testing.expectEqual(colors.palette[4], x_cell.bg.?);

    const grapheme = (try cells.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("e\u{0301}", grapheme.text);
    try testing.expectEqual(Wide.narrow, grapheme.wide);

    const wide = (try cells.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("界", wide.text);
    try testing.expectEqual(Wide.wide, wide.wide);
    const tail = (try cells.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Wide.spacer_tail, tail.wide);

    // Random access via select.
    const again = try cells.select(0);
    try testing.expectEqualStrings("X", again.text);
}

test "selection: gesture press/drag, install, row range, selected text" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();
    vt.write("hello world");

    var gesture = try SelectionGesture.new();
    defer gesture.free(&vt);

    const start = try vt.gridRef(.viewport, .{ .x = 0, .y = 0 });
    const end = try vt.gridRef(.viewport, .{ .x = 4, .y = 0 });
    const geom: GestureGeometry = .{ .columns = 80, .cell_width = 8, .screen_height = 384 };

    const sel_press = try gesture.press(&vt, start, .{
        .position = .{ .x = 0, .y = 0 },
        .time_ns = 1_000_000,
        .repeat_interval_ns = 500_000_000,
    });
    // Single click uses cell behavior: no selection until the drag.
    try testing.expectEqual(@as(?Selection, null), sel_press);
    try testing.expectEqual(@as(u8, 1), try gesture.clickCount(&vt));

    // Pointer near the right edge of cell 4 (x=39, cell_width 8) so the
    // end cell crosses the inclusion threshold.
    const sel_drag = try gesture.drag(&vt, end, .{ .x = 39, .y = 0 }, geom, false);
    try testing.expect(sel_drag != null);
    try testing.expect(try gesture.dragged(&vt));
    try vt.setSelection(&sel_drag.?);
    try gesture.release(&vt, end);

    // Installed selection reads back.
    const installed = try vt.selection();
    try testing.expect(installed != null);

    // Selected text via the formatter (Ghostty's copy combination).
    var buf: [256]u8 = undefined;
    const text = try selectedText(&vt, &installed.?, &buf);
    try testing.expectEqualStrings("hello", text);

    // Render state exposes the row range and per-cell selection.
    var rs = try RenderState.new();
    defer rs.deinit();
    try rs.update(&vt);
    var rows = try rs.rowsIter();
    const row = (try rows.nextDirty()) orelse return error.TestUnexpectedResult;
    const range = (try row.selection()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), range.start_x);
    try testing.expectEqual(@as(u16, 4), range.end_x);
    var cells = try row.cells();
    const c0 = (try cells.next()) orelse return error.TestUnexpectedResult;
    try testing.expect(c0.selected);
    const c5 = try cells.select(5);
    try testing.expect(!c5.selected);

    // Clearing the selection removes the row range.
    try vt.setSelection(null);
    try testing.expectEqual(@as(?Selection, null), try vt.selection());
}

test "kitty: storage limit, image upload, pixels by id+generation, placements" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();
    try vt.resize(80, 24, 8, 16);

    try testing.expectEqual(default_kitty_storage_limit, try vt.kittyStorageLimit());
    var kg = try vt.kittyGraphics();
    try testing.expectEqual(@as(u64, 0), try kg.generation());
    try testing.expectEqual(@as(?u64, null), try kg.animationTick(0));

    // Transmit + display a 2x2 RGBA image (id 1), q=2 suppresses the reply.
    const pixels = [_]u8{
        255, 0,   0,   255, 0, 255, 0,   255,
        0,   0,   255, 255, 255, 255, 255, 255,
    };
    var b64: [std.base64.standard.Encoder.calcSize(pixels.len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, &pixels);
    var apc_buf: [128]u8 = undefined;
    const apc = try std.fmt.bufPrint(&apc_buf, "\x1b_Gf=32,s=2,v=2,i=1,a=T,q=2;{s}\x1b\\", .{encoded});
    vt.write(apc);

    kg = try vt.kittyGraphics(); // re-fetch after the mutating write
    const gen = try kg.generation();
    try testing.expect(gen != 0);
    const img = kg.image(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), try img.width());
    try testing.expectEqual(@as(u32, 2), try img.height());
    try testing.expectEqual(KittyImageFormat.rgba, try img.format());
    try testing.expectEqual(@as(usize, 16), try img.expectedLen());
    try testing.expect(try img.generation() != 0);
    try testing.expectEqualSlices(u8, &pixels, (try img.pixels()).?);
    try testing.expectEqual(@as(?KittyImage, null), kg.image(999));

    // Storage-side placement iteration.
    var iter = try KittyPlacementIterator.new();
    defer iter.free();
    try kg.fillPlacements(&iter);
    try testing.expect(iter.next());
    const placement = try iter.get();
    try testing.expectEqual(@as(u32, 1), placement.image_id);
    try testing.expect(!placement.is_virtual);
    const info = try iter.renderInfo(img, &vt);
    try testing.expect(info.viewport_visible);
    try testing.expectEqual(@as(u32, 2), info.pixel_width);
    try testing.expectEqual(@as(u32, 2), info.pixel_height);
    try testing.expect(!iter.next());

    // Render-state image list (the drawing path).
    var rs = try RenderState.new();
    defer rs.deinit();
    try rs.update(&vt);
    var images = try rs.images();
    const rp = (try images.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ImageProtocol.kitty, rp.protocol);
    try testing.expectEqual(@as(u32, 1), rp.image_id);
    try testing.expectEqual(try img.generation(), rp.image_generation);
    try testing.expectEqual(@as(u32, 2), rp.pixel_width);
    try testing.expectEqual(@as(u32, 2), rp.pixel_height);
    try testing.expectEqual(@as(?ImagePlacement, null), try images.next());

    // Disabling the protocol deletes stored images.
    try vt.setKittyStorageLimit(0);
    try testing.expectEqual(@as(u64, 0), try vt.kittyStorageLimit());
    kg = try vt.kittyGraphics();
    try testing.expectEqual(@as(?KittyImage, null), kg.image(1));
}

test "sys: PNG decode hook feeds kitty storage; log hook installs" {
    // A fake decoder that ignores the PNG bytes and returns a 1x1 red
    // pixel allocated with the callback's LimitedAllocator.
    const FakePng = struct {
        var calls: u32 = 0;
        fn decode(_: ?*anyopaque, allocator: ImageAllocator, _: []const u8, out: *DecodedImage) bool {
            calls += 1;
            const buf = allocator.alloc(4) orelse return false;
            buf[0] = 255;
            buf[1] = 0;
            buf[2] = 0;
            buf[3] = 255;
            out.* = .{ .width = 1, .height = 1, .pixels = buf };
            return true;
        }
    };
    FakePng.calls = 0;
    try setDecodePng(FakePng.decode);
    defer setDecodePng(null) catch {};
    try setSysUserdata(null);

    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    // f=100 = PNG medium; the payload bytes are irrelevant to the fake.
    vt.write("\x1b_Gf=100,i=7,a=T,q=2;AAAA\x1b\\");
    try testing.expectEqual(@as(u32, 1), FakePng.calls);
    const kg = try vt.kittyGraphics();
    const img = kg.image(7) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(KittyImageFormat.rgba, try img.format());
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, (try img.pixels()).?);

    // Log hook: install and clear (both must succeed).
    const NoopLog = struct {
        fn log(_: ?*anyopaque, _: LogLevel, _: []const u8, _: []const u8) void {}
    };
    try setLog(NoopLog.log);

    // Regression: installing the log hook must not clobber the PNG hook.
    vt.write("\x1b_Gf=100,i=8,a=T,q=2;AAAA\x1b\\");
    try testing.expectEqual(@as(u32, 2), FakePng.calls);
    const kg2 = try vt.kittyGraphics();
    try testing.expect(kg2.image(8) != null);

    try setLog(null);
    try setLogStderr();
    try setLog(null);
}

test "scrollback options and generic escape hatches" {
    var vt = try Vt.init(80, 24);
    defer vt.deinit();

    try vt.setScrollbackMaxBytes(1_000_000);
    try testing.expectEqual(@as(?usize, 1_000_000), try vt.scrollbackMaxBytes());
    try vt.setScrollbackMaxBytes(null);
    try vt.setScrollbackMaxLines(500);
    try testing.expectEqual(@as(?usize, 500), try vt.scrollbackMaxLines());
    try vt.setScrollbackMaxLines(null);
    try testing.expectEqual(@as(?usize, null), try vt.scrollbackMaxLines());

    // Generic set/get: default cursor style option + cols data key.
    const style: CursorStyle = .underline;
    try vt.setOption(.default_cursor_style, &style);
    var cols_out: u16 = 0;
    try vt.getData(.cols, &cols_out);
    try testing.expectEqual(@as(u16, 80), cols_out);

    // InvalidValue mapping: cols/rows must be > 0.
    try testing.expectError(Error.InvalidValue, Vt.init(0, 0));

    // Scrollbar reflects scrollback state.
    const sb = try vt.scrollbar();
    try testing.expectEqual(@as(u64, 24), sb.len);
    try testing.expect(try vt.viewportActive());
}

test "viewport scrolling: top/bottom/delta/page (§2.5)" {
    var vt = try Vt.init(10, 4);
    defer vt.deinit();
    try vt.setScrollbackMaxLines(100);

    // Feed 20 lines into a 4-row viewport so most scroll into history.
    vt.write("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n10\r\n" ++
        "11\r\n12\r\n13\r\n14\r\n15\r\n16\r\n17\r\n18\r\n19\r\n20\r\n");
    try testing.expect(try vt.viewportActive());
    const bottom = try vt.scrollbar();
    try testing.expectEqual(@as(u64, 4), bottom.len);
    try testing.expect(bottom.total > bottom.len); // scrollback exists
    try testing.expect(bottom.offset >= 4); // room to scroll up

    // Top: viewport leaves the active area, offset 0.
    try vt.scrollTop();
    try testing.expect(!try vt.viewportActive());
    try testing.expectEqual(@as(u64, 0), (try vt.scrollbar()).offset);

    // Bottom: back to the active area.
    try vt.scrollBottom();
    try testing.expect(try vt.viewportActive());
    try testing.expectEqual(bottom.offset, (try vt.scrollbar()).offset);

    // Delta up by 2 lines.
    try vt.scrollViewport(.{ .delta = -2 });
    try testing.expect(!try vt.viewportActive());
    try testing.expectEqual(bottom.offset - 2, (try vt.scrollbar()).offset);

    // Page up/down move by the viewport height (4 rows).
    try vt.scrollBottom();
    try vt.pageUp();
    try testing.expectEqual(bottom.offset - 4, (try vt.scrollbar()).offset);
    try vt.pageDown();
    try testing.expect(try vt.viewportActive());
    try testing.expectEqual(bottom.offset, (try vt.scrollbar()).offset);

    // Absolute row round-trips through the scrollbar offset space.
    try vt.scrollViewport(.{ .row = 1 });
    try testing.expectEqual(@as(u64, 1), (try vt.scrollbar()).offset);
}

test "mode helpers and reset semantics" {
    var cap: Capture = .{};
    var effects = cap.effects();
    var vt = try testVt(&effects);
    defer vt.deinit();

    try testing.expectEqual(@as(u16, 1004), mode(1004, false));
    try testing.expectEqual(@as(u16, 4 | 0x8000), mode(4, true));

    try vt.setMode(mode(1004, false), true);
    try testing.expect(try vt.getMode(mode(1004, false)));
    try vt.setModeDefault(mode(2004, false), true);

    vt.write("content");
    vt.reset();
    // Host-driven reset does not fire the reset effect.
    try testing.expectEqual(@as(u32, 0), cap.resets);
    try testing.expectEqual(@as(u16, 0), try vt.cursorX());
    // Reset default restored by RIS.
    try testing.expect(try vt.getMode(mode(2004, false)));
    // Current-mode value was restored to its reset default (false).
    try testing.expect(!try vt.getMode(mode(1004, false)));
}
