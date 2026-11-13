//! src/input/xkb.zig -- xkbcommon keymap / state / compose wrapper
//! (ROADMAP M1.6 keyboard, M6.5 xkb options and locale1 live updates).
//!
//! Wraps libxkbcommon (verified against 1.13.2) for the input layer:
//! `Keymap` compiles RMLVO names or a keymap file, `State` turns evdev key
//! events into `KeyEvent`s carrying libghostty-vt key codes/modifiers plus
//! UTF-8 text, `Compose` runs the XKB Compose sequence state machine, and
//! `RepeatConfig` carries the kmscon repeat options (the timer itself lives
//! in the input layer).
//!
//! C shim: the `xkb-c` module is the translate-c output of
//!
//!     #include <xkbcommon/xkbcommon.h>
//!     #include <xkbcommon/xkbcommon-compose.h>
//!     #include <xkbcommon/xkbcommon-names.h>
//!
//! wired through b.addTranslateC like `vt-c` (build.zig, D3). All C access
//! goes through the generated bindings, never hand-written externs.
//!
//! Standalone test command (headless; xkbcommon needs no devices, but it
//! does need the xkeyboard-config data root and, for locale Compose tables,
//! the libX11 locale dir — neither is at /usr/share on NixOS):
//!
//!     nix build nixpkgs#libxkbcommon.dev nixpkgs#libxkbcommon \
//!         nixpkgs#xkeyboard_config nixpkgs#libx11 --print-out-paths --no-link
//!     XKB_CONFIG_ROOT=<xkeyboard_config>/share/X11/xkb \
//!     XLOCALEDIR=<libx11>/share/X11/locale \
//!     nix run nixpkgs#zig -- test \
//!         --dep xkb-c -Mroot=src/input/xkb.zig -Mxkb-c=/tmp/xkb_c.zig \
//!         -lc -I<libxkbcommon.dev>/include \
//!         -L<libxkbcommon>/lib -lxkbcommon
//!
//! where /tmp/xkb_c.zig is `zig translate-c` of the shim above with
//! `-I<libxkbcommon.dev>/include -lc`.
//!
//! Defaults (kmscon parity, docs/reference/kmscon-options.md §1):
//! - RMLVO: rules are always "evdev" (kmscon input_uxkb.c:94). Unset (null)
//!   or empty model/layout/variant/options mean "xkbcommon default", which
//!   resolves to model pc105, layout us (after consulting XKB_DEFAULT_*
//!   environment variables). `keymap_file` takes precedence over RMLVO
//!   (kmscon seat.c:737-739); an unreadable/invalid file falls back to RMLVO,
//!   and a failing RMLVO falls back to the all-empty default keymap
//!   (kmscon input_uxkb.c:116-133). Unlike kmscon there is no embedded
//!   binary fallback keymap: if even the default fails, init returns
//!   error.KeymapCompileFailed.
//! - Repeat: delay 250 ms, rate 50 ms *between repeats* (kmscon's
//!   --xkb-repeat-rate is an interval in ms, not Hz; config.c:1022-1023).
//!   `RepeatConfig` stores Hz, so the default is 20 Hz. Clamping follows
//!   input_set_conf (input.c:573-580): 0 -> default, >= 1000 -> 999.
//!
//! KeyEvent lifetimes: `utf8` borrows `State.utf8_buf` and is valid until
//! the next `State.processKey` on the same state (or reload/deinit). For a
//! composed event it borrows `Compose.buf` instead and is valid until the
//! next `Compose.feed`/`reset`. Both buffers are 64 bytes; longer strings
//! are truncated (xkb_state_key_get_utf8 / xkb_compose_state_get_utf8
//! semantics). `Keymap.layoutName` borrows the keymap until reload/deinit.
//!
//! Modifier mapping: xkb_state_serialize_mods(EFFECTIVE) is decoded through
//! the keymap's real-modifier indices — Shift -> mod_shift, Control ->
//! mod_ctrl, Mod1 -> mod_alt, Mod4 -> mod_super, Lock -> mod_caps_lock,
//! Mod2 -> mod_num_lock (xkbcommon-names.h; the same five real mods kmscon
//! matches grabs against, shl/misc.h:517-533, plus NumLock). The right-side
//! bits are set from the physically depressed right modifier keycodes,
//! which this wrapper tracks itself (xkbcommon has no per-key query);
//! `updateMask` clears that tracking because out-of-band updates carry no
//! physical key information. AltGr (ISO_Level3_Shift/Mod5) deliberately
//! does not set mod_alt, matching kmscon.
//!
//! Key processing order follows kmscon input_uxkb.c:430-543 and the
//! xkbcommon docs: query keysyms/UTF-8/consumed mods *before*
//! xkb_state_update_key, feed Compose with the single (Caps-transformed)
//! keysym — NoSymbol when the key yields several keysyms — then update the
//! state, then serialize modifiers (so a just-pressed modifier is included
//! in its own event). Compose status COMPOSING or CANCELLED suppresses the
//! event entirely (processKey returns null, kmscon's -ENOKEY); COMPOSED
//! replaces the event text with the composed string. After COMPOSED or
//! CANCELLED the compose state is reset so holding a key cannot repeat the
//! last sequence. Unlike kmscon (whose event path is keysym-only), a
//! composed result that has UTF-8 but no keysym is kept, and ctrl/alt/super
//! bypass Compose so shortcuts are never swallowed by a dead-key sequence.
//!
//! ctrl+a: xkbcommon applies the Control keysym transformation in
//! xkb_state_key_get_utf8, so the event carries utf8 "\x01" (not empty).
//! `keysym` stays 'a' — keysyms are not control-transformed.
//!
//! `reload` rebuilds keymap and state preserving *nothing*: depressed,
//! latched and locked modifiers, the active layout and any Compose progress
//! are lost (kmscon input_update_keymap tears the device state down the
//! same way, input.c:541-567). The attached Compose table survives — it is
//! keymap-independent — but its sequence progress is reset.
//!
//! `shouldRepeat` takes an *evdev keycode*: xkb_keymap_key_repeats is a
//! per-physical-key property (kmscon input_uxkb.c:396), not a keysym one.

const std = @import("std");
const c = @import("xkb-c");
const kt = @import("keymap_table.zig");

pub const GhosttyKey = kt.GhosttyKey;
pub const GhosttyMods = kt.GhosttyMods;

/// xkb keycode offset: xkb keycodes are evdev codes + 8 (the xkbcommon
/// convention, kmscon EVDEV_KEYCODE_OFFSET).
const evdev_offset: u32 = 8;

/// Size of the borrowed UTF-8 buffers in State and Compose. Longer strings
/// are truncated; a single key event or compose result never approaches
/// this in practice (a few codepoints at most).
const utf8_buf_len = 64;

/// Cap for reading keymap/compose files (a full serialized keymap is
/// ~1 MiB; compose tables are smaller).
const max_file_len = 16 * 1024 * 1024;

const invalid_index: u32 = std.math.maxInt(u32);

/// RMLVO plus keymap-file options, mirroring kmscon's --xkb-model,
/// --xkb-layout, --xkb-variant, --xkb-options and --xkb-keymap. Null and
/// empty strings both mean "xkbcommon default" (pc105/us). `keymap_file`
/// wins over the RMLVO fields when it loads successfully.
pub const Options = struct {
    model: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    options: ?[]const u8 = null,
    keymap_file: ?[]const u8 = null,
};

/// Key-repeat configuration passthrough (kmscon --xkb-repeat-delay /
/// --xkb-repeat-rate). The repeat timer lives in the input layer; this
/// module only carries the values and answers `Keymap.shouldRepeat`.
///
/// kmscon expresses both options in milliseconds: delay before the first
/// repeat, and interval between repeats. `rate_hz` is the converted
/// frequency (1000 / interval), so the kmscon defaults 250 ms / 50 ms
/// become 250 ms / 20 Hz here.
pub const RepeatConfig = struct {
    delay_ms: u32 = default_delay_ms,
    rate_hz: u32 = default_rate_hz,

    /// kmscon config.c:1022 (--xkb-repeat-delay default).
    pub const default_delay_ms: u32 = 250;
    /// kmscon config.c:1023 (--xkb-repeat-rate default, ms between repeats).
    pub const default_rate_ms: u32 = 50;
    pub const default_rate_hz: u32 = 1000 / default_rate_ms;

    /// Convert kmscon-style millisecond options, applying input_set_conf's
    /// clamping (input.c:573-580): 0 selects the default, values >= 1000
    /// are capped at 999. The interval-to-Hz conversion truncates.
    pub fn fromKmsconMs(delay_ms: u32, rate_ms: u32) RepeatConfig {
        const d = if (delay_ms == 0) default_delay_ms else @min(delay_ms, 999);
        const r = if (rate_ms == 0) default_rate_ms else @min(rate_ms, 999);
        return .{ .delay_ms = d, .rate_hz = 1000 / r };
    }
};

/// One processed key event. `utf8` is borrowed — see the module header for
/// lifetimes. `keysym` is the effective single keysym (Caps-transformed,
/// or the composed keysym); 0 (NoSymbol) when the key yields several
/// keysyms or none. `consumed_mods` is the raw xkb modifier mask the key's
/// type consumes for level selection (xkb_state_key_get_consumed_mods) —
/// a static property of the key, e.g. Shift|Lock for alphabetic keys,
/// independent of which modifiers are currently active. Not GhosttyMods bits.
pub const KeyEvent = struct {
    ghostty_key: GhosttyKey,
    mods: GhosttyMods,
    utf8: ?[]const u8,
    unshifted_codepoint: ?u21,
    keysym: u32,
    consumed_mods: u32,
};

/// A compiled keymap plus its xkb context. Owns both; `deinit` releases
/// them. States created from this keymap hold their own reference to the
/// underlying xkb_keymap, so they stay valid across `reload`, but they keep
/// the *old* layout — recreate them (or use `State.reload`) after a reload.
pub const Keymap = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    ctx: *c.struct_xkb_context,
    map: *c.struct_xkb_keymap,
    mods: ModIndices,

    /// Real-modifier indices cached at compile time; invalid_index when
    /// the keymap does not define the modifier.
    pub const ModIndices = struct {
        shift: u32 = invalid_index,
        ctrl: u32 = invalid_index,
        alt: u32 = invalid_index,
        super: u32 = invalid_index,
        caps: u32 = invalid_index,
        num: u32 = invalid_index,

        fn cache(map: *c.struct_xkb_keymap) ModIndices {
            return .{
                .shift = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_SHIFT),
                .ctrl = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_CTRL),
                .alt = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_ALT),
                .super = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_LOGO),
                .caps = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_CAPS),
                .num = c.xkb_keymap_mod_get_index(map, c.XKB_MOD_NAME_NUM),
            };
        }
    };

    /// Compile a keymap. `io` is needed only for reading `opts.keymap_file`
    /// (Zig 0.17 std.Io); it is stored for `reload`. See the module header
    /// for the fallback chain and defaults.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Keymap {
        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer c.xkb_context_unref(ctx);
        const map = try compileKeymap(ctx, io, allocator, opts);
        return .{
            .io = io,
            .allocator = allocator,
            .ctx = ctx,
            .map = map,
            .mods = ModIndices.cache(map),
        };
    }

    pub fn deinit(self: *Keymap) void {
        c.xkb_keymap_unref(self.map);
        c.xkb_context_unref(self.ctx);
    }

    /// Rebuild the keymap in place (locale1 live update, M6.5). Atomic: on
    /// failure the old keymap stays. Existing `State`s keep the old keymap
    /// until recreated; prefer `State.reload`, which swaps both together.
    pub fn reload(self: *Keymap, opts: Options) !void {
        const map = try self.compile(opts);
        self.adopt(map);
    }

    /// Whether the physical key auto-repeats (xkb_keymap_key_repeats).
    /// `evdev_code` is the Linux input event code; the xkb keycode is
    /// derived internally. Modifiers and locks do not repeat.
    pub fn shouldRepeat(self: *const Keymap, evdev_code: u32) bool {
        return c.xkb_keymap_key_repeats(self.map, evdev_code +| evdev_offset) != 0;
    }

    pub fn numLayouts(self: *const Keymap) u32 {
        return c.xkb_keymap_num_layouts(self.map);
    }

    /// Layout name borrowed from the keymap (valid until reload/deinit);
    /// null when `index` is out of range.
    pub fn layoutName(self: *const Keymap, index: u32) ?[]const u8 {
        const name = c.xkb_keymap_layout_get_name(self.map, index) orelse return null;
        return std.mem.span(name);
    }

    /// Layout index by the keymap's descriptive layout name ("German",
    /// "English (US)", ...); null when no layout has that name. The short
    /// RMLVO names ("de", "us") are not present in a compiled keymap
    /// (xkbcommon.h xkb_layout_index_t notes).
    pub fn layoutIndex(self: *const Keymap, name: []const u8) !?u32 {
        const z = try self.allocator.dupeSentinel(u8, name, 0);
        defer self.allocator.free(z);
        const idx = c.xkb_keymap_layout_get_index(self.map, z.ptr);
        if (idx == invalid_index) return null;
        return idx;
    }

    fn compile(self: *const Keymap, opts: Options) !*c.struct_xkb_keymap {
        return compileKeymap(self.ctx, self.io, self.allocator, opts);
    }

    fn adopt(self: *Keymap, map: *c.struct_xkb_keymap) void {
        c.xkb_keymap_unref(self.map);
        self.map = map;
        self.mods = ModIndices.cache(map);
    }
};

/// Compile with kmscon's fallback chain: keymap file, then the requested
/// RMLVO, then the all-empty default RMLVO (input_uxkb.c:116-133).
fn compileKeymap(
    ctx: *c.struct_xkb_context,
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Options,
) !*c.struct_xkb_keymap {
    if (opts.keymap_file) |path| {
        if (try compileFromFile(ctx, io, allocator, path)) |map| return map;
    }
    if (try compileFromNames(ctx, allocator, opts)) |map| return map;
    const requested = opts.model != null or opts.layout != null or
        opts.variant != null or opts.options != null;
    if (requested) {
        if (try compileFromNames(ctx, allocator, .{})) |map| return map;
    }
    return error.KeymapCompileFailed;
}

fn compileFromFile(
    ctx: *c.struct_xkb_context,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?*c.struct_xkb_keymap {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_len)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // kmscon logs and falls back to RMLVO when the file cannot be read.
        else => return null,
    };
    defer allocator.free(data);
    return c.xkb_keymap_new_from_buffer(
        ctx,
        data.ptr,
        data.len,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );
}

fn compileFromNames(
    ctx: *c.struct_xkb_context,
    allocator: std.mem.Allocator,
    opts: Options,
) !?*c.struct_xkb_keymap {
    const model = try dupOpt(allocator, opts.model);
    defer if (model) |s| allocator.free(s);
    const layout = try dupOpt(allocator, opts.layout);
    defer if (layout) |s| allocator.free(s);
    const variant = try dupOpt(allocator, opts.variant);
    defer if (variant) |s| allocator.free(s);
    const options = try dupOpt(allocator, opts.options);
    defer if (options) |s| allocator.free(s);

    const names = c.struct_xkb_rule_names{
        .rules = "evdev",
        .model = if (model) |s| s.ptr else null,
        .layout = if (layout) |s| s.ptr else null,
        .variant = if (variant) |s| s.ptr else null,
        .options = if (options) |s| s.ptr else null,
    };
    return c.xkb_keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
}

fn dupOpt(allocator: std.mem.Allocator, s: ?[]const u8) !?[:0]u8 {
    const v = s orelse return null;
    return try allocator.dupeSentinel(u8, v, 0);
}

/// Keyboard state for one keymap: modifier/layout tracking, key processing
/// and optional Compose integration. Create with `State.init(&keymap)`;
/// the state refs the keymap internally.
pub const State = struct {
    keymap: *Keymap,
    state: *c.struct_xkb_state,
    compose: ?*Compose = null,
    utf8_buf: [utf8_buf_len]u8 = undefined,
    /// Bitmask of depressed right-side modifier evdev codes, for the
    /// GhosttyMods side bits. xkbcommon cannot report which physical key
    /// holds a modifier, so processKey tracks it.
    right_down: u128 = 0,

    pub fn init(keymap: *Keymap) !State {
        const state = c.xkb_state_new(keymap.map) orelse return error.XkbStateFailed;
        return .{ .keymap = keymap, .state = state };
    }

    pub fn deinit(self: *State) void {
        c.xkb_state_unref(self.state);
    }

    /// Attach (or detach with null) a Compose state machine. Borrowed: the
    /// Compose must outlive every processKey call that uses it.
    pub fn setCompose(self: *State, compose: ?*Compose) void {
        self.compose = compose;
    }

    /// Rebuild keymap and state together (locale1 live update, M6.5).
    /// Preserves nothing: held/latched/locked modifiers, layout and Compose
    /// sequence progress are all reset. The Compose table stays attached.
    /// Atomic: on failure both keymap and state are unchanged.
    pub fn reload(self: *State, opts: Options) !void {
        const map = try self.keymap.compile(opts);
        errdefer c.xkb_keymap_unref(map);
        const state = c.xkb_state_new(map) orelse return error.XkbStateFailed;
        c.xkb_state_unref(self.state);
        self.state = state;
        self.keymap.adopt(map);
        self.right_down = 0;
        if (self.compose) |cp| cp.reset();
    }

    /// Process one evdev key event. Returns null when Compose consumes the
    /// event (a sequence is in progress, or was cancelled by this key) —
    /// kmscon emits no key event in that case either. Releases always
    /// produce an event (with null utf8) so the terminal sees key-ups.
    ///
    /// `utf8` borrows this state's buffer (or the Compose buffer for a
    /// composed event) until the next processKey/feed — copy it if it must
    /// outlive that.
    pub fn processKey(self: *State, evdev_code: u32, pressed: bool) ?KeyEvent {
        const kc = evdev_code +| evdev_offset;

        // Query before xkb_state_update_key (xkbcommon ordering; kmscon
        // input_uxkb.c:475-482).
        var syms: [*c]const u32 = null;
        const num_syms = c.xkb_state_key_get_syms(self.state, kc, &syms);
        var one_sym: u32 = c.XKB_KEY_NoSymbol;
        if (num_syms == 1) one_sym = c.xkb_state_key_get_one_sym(self.state, kc);
        const consumed = c.xkb_state_key_get_consumed_mods(self.state, kc);
        const unshifted = self.unshiftedCodepoint(kc);

        var utf8: ?[]const u8 = null;
        if (pressed and num_syms > 0) {
            const n = c.xkb_state_key_get_utf8(self.state, kc, @ptrCast(&self.utf8_buf), self.utf8_buf.len);
            if (n > 0) utf8 = self.utf8_buf[0..@min(@as(usize, @intCast(n)), self.utf8_buf.len)];
        }

        // Compose runs on presses only, fed with the single keysym (or
        // NoSymbol for multi-keysym keys, per xkb_compose_state_feed docs).
        var suppressed = false;
        if (pressed) {
            if (self.compose) |cp| {
                const feed_sym: u32 = if (num_syms == 1) one_sym else c.XKB_KEY_NoSymbol;
                switch (cp.feed(feed_sym, self.mods())) {
                    .none => {},
                    .composing, .cancelled => suppressed = true,
                    .composed => |composed| {
                        utf8 = if (composed.utf8.len > 0) composed.utf8 else null;
                        one_sym = composed.keysym;
                    },
                }
            }
        }

        // Update even when Compose suppresses the event (kmscon does the
        // same before its -ENOKEY return).
        _ = c.xkb_state_update_key(
            self.state,
            kc,
            if (pressed) c.XKB_KEY_DOWN else c.XKB_KEY_UP,
        );
        self.trackRightModifier(evdev_code, pressed);

        if (suppressed) return null;

        return .{
            .ghostty_key = kt.xkbKeycodeToGhosttyKey(kc),
            .mods = self.mods(),
            .utf8 = utf8,
            .unshifted_codepoint = unshifted,
            .keysym = one_sym,
            .consumed_mods = consumed,
        };
    }

    /// Effective modifiers as GhosttyMods (see the module header for the
    /// index mapping). Useful for grab matching between key events.
    pub fn mods(self: *State) GhosttyMods {
        const mask = c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_EFFECTIVE);
        const mi = &self.keymap.mods;
        var m: GhosttyMods = 0;
        if (modActive(mask, mi.shift)) m |= kt.mod_shift;
        if (modActive(mask, mi.ctrl)) m |= kt.mod_ctrl;
        if (modActive(mask, mi.alt)) m |= kt.mod_alt;
        if (modActive(mask, mi.super)) m |= kt.mod_super;
        if (modActive(mask, mi.caps)) m |= kt.mod_caps_lock;
        if (modActive(mask, mi.num)) m |= kt.mod_num_lock;
        if (m & kt.mod_shift != 0 and self.rightDown(kt.key_code.key_rightshift)) m |= kt.mod_shift_side;
        if (m & kt.mod_ctrl != 0 and self.rightDown(kt.key_code.key_rightctrl)) m |= kt.mod_ctrl_side;
        if (m & kt.mod_alt != 0 and self.rightDown(kt.key_code.key_rightalt)) m |= kt.mod_alt_side;
        if (m & kt.mod_super != 0 and self.rightDown(kt.key_code.key_rightmeta)) m |= kt.mod_super_side;
        return m;
    }

    /// Out-of-band state update (xkb_state_update_mask, client-style). All
    /// six components must be passed together or the state is incoherent.
    /// Clears the physical right-modifier tracking: masks carry no key
    /// information.
    pub fn updateMask(
        self: *State,
        depressed_mods: u32,
        latched_mods: u32,
        locked_mods: u32,
        depressed_layout: u32,
        latched_layout: u32,
        locked_layout: u32,
    ) void {
        _ = c.xkb_state_update_mask(
            self.state,
            depressed_mods,
            latched_mods,
            locked_mods,
            depressed_layout,
            latched_layout,
            locked_layout,
        );
        self.right_down = 0;
    }

    /// Lock a layout of a multi-layout keymap (layout switching without a
    /// reload). Preserves the modifier state; depressed/latched layout are
    /// cleared. `layout` is a keymap layout index, not an RMLVO name.
    pub fn setLayout(self: *State, layout: u32) void {
        self.updateMask(
            c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_DEPRESSED),
            c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_LATCHED),
            c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_LOCKED),
            0,
            0,
            layout,
        );
    }

    /// Effective layout index (xkb_state_serialize_layout).
    pub fn activeLayout(self: *State) u32 {
        return c.xkb_state_serialize_layout(self.state, c.XKB_STATE_LAYOUT_EFFECTIVE);
    }

    pub const Leds = struct {
        caps_lock: bool,
        num_lock: bool,
        scroll_lock: bool,
    };

    /// Lock LED state for the renderer indicators (xkb LED names, the same
    /// ones kmscon writes back to the keyboard, input_uxkb.c:259-287).
    pub fn leds(self: *State) Leds {
        return .{
            .caps_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_CAPS) > 0,
            .num_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_NUM) > 0,
            .scroll_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_SCROLL) > 0,
        };
    }

    /// The codepoint the key produces with no modifiers: level 1 of the
    /// key's effective layout, converted to UTF-32. Null when the key has
    /// no text representation at level 1.
    fn unshiftedCodepoint(self: *State, kc: u32) ?u21 {
        const layout = c.xkb_state_key_get_layout(self.state, kc);
        var syms: [*c]const u32 = null;
        const n = c.xkb_keymap_key_get_syms_by_level(self.keymap.map, kc, layout, 0, &syms);
        if (n < 1) return null;
        const cp = c.xkb_keysym_to_utf32(syms[0]);
        if (cp == 0 or cp > 0x10ffff) return null;
        return @intCast(cp);
    }

    fn trackRightModifier(self: *State, evdev_code: u32, pressed: bool) void {
        switch (evdev_code) {
            kt.key_code.key_rightshift,
            kt.key_code.key_rightctrl,
            kt.key_code.key_rightalt,
            kt.key_code.key_rightmeta,
            => {
                const bit = @as(u128, 1) << @intCast(evdev_code);
                if (pressed) self.right_down |= bit else self.right_down &= ~bit;
            },
            else => {},
        }
    }

    fn rightDown(self: *const State, evdev_code: u32) bool {
        return self.right_down & (@as(u128, 1) << @intCast(evdev_code)) != 0;
    }
};

fn modActive(mask: u32, index: u32) bool {
    return index < 32 and mask & (@as(u32, 1) << @intCast(index)) != 0;
}

/// Result of feeding one keysym to the Compose state machine. `composed`
/// borrows the Compose buffer until the next feed/reset.
pub const ComposeResult = union(enum) {
    /// No sequence active (or the keysym was ignored).
    none,
    /// A sequence is in progress; the key event must be suppressed.
    composing,
    /// A sequence completed; insert this text instead of the raw key text.
    composed: Composed,
    /// The sequence was cancelled by an unmatched keysym; suppress the event.
    cancelled,

    pub const Composed = struct {
        utf8: []const u8,
        keysym: u32,
    };
};

/// XKB Compose sequence state machine (M6.5 --xkb-compose-file). Owns its
/// own xkb context, table and state. Table selection mirrors kmscon
/// uxkb_compose_table_init (input_uxkb.c:158-189): a given file is tried
/// first; an unreadable file disables compose (error.ComposeFileFailed),
/// an unparseable one falls back to the locale table; without a file the
/// locale table is used directly. The locale is the caller's choice —
/// kmscon picks LC_ALL, then LC_CTYPE, then LANG, then "C" (seat.c:590-599).
pub const Compose = struct {
    ctx: *c.struct_xkb_context,
    table: *c.struct_xkb_compose_table,
    state: *c.struct_xkb_compose_state,
    buf: [utf8_buf_len]u8 = undefined,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        locale: []const u8,
        compose_file: ?[]const u8,
    ) !Compose {
        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer c.xkb_context_unref(ctx);

        const locale_z = try allocator.dupeSentinel(u8, locale, 0);
        defer allocator.free(locale_z);

        var table: ?*c.struct_xkb_compose_table = null;
        if (compose_file) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_len)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ComposeFileFailed,
            };
            defer allocator.free(data);
            table = c.xkb_compose_table_new_from_buffer(
                ctx,
                data.ptr,
                data.len,
                locale_z.ptr,
                c.XKB_COMPOSE_FORMAT_TEXT_V1,
                c.XKB_COMPOSE_COMPILE_NO_FLAGS,
            );
            // Parse failure falls through to the locale table (kmscon).
        }
        if (table == null) {
            table = c.xkb_compose_table_new_from_locale(ctx, locale_z.ptr, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
        }
        const t = table orelse return error.ComposeTableFailed;
        errdefer c.xkb_compose_table_unref(t);

        const state = c.xkb_compose_state_new(t, c.XKB_COMPOSE_STATE_NO_FLAGS) orelse
            return error.ComposeStateFailed;
        return .{ .ctx = ctx, .table = t, .state = state };
    }

    pub fn deinit(self: *Compose) void {
        c.xkb_compose_state_unref(self.state);
        c.xkb_compose_table_unref(self.table);
        c.xkb_context_unref(self.ctx);
    }

    /// Feed one keysym (usually KeyEvent.keysym of a press). Ctrl/alt/super
    /// bypass compose and reset any in-progress sequence so shortcuts are
    /// never swallowed; xkb_compose_state_feed itself ignores modifier
    /// keysyms. After a composed or cancelled result the state is reset
    /// (kmscon input_uxkb.c:504-512).
    pub fn feed(self: *Compose, keysym: u32, mods: GhosttyMods) ComposeResult {
        if (mods & (kt.mod_ctrl | kt.mod_alt | kt.mod_super) != 0) {
            c.xkb_compose_state_reset(self.state);
            return .none;
        }
        _ = c.xkb_compose_state_feed(self.state, keysym);
        switch (c.xkb_compose_state_get_status(self.state)) {
            c.XKB_COMPOSE_COMPOSING => return .composing,
            c.XKB_COMPOSE_COMPOSED => {
                const sym = c.xkb_compose_state_get_one_sym(self.state);
                var n = c.xkb_compose_state_get_utf8(self.state, @ptrCast(&self.buf), self.buf.len);
                if (n <= 0 and sym != c.XKB_KEY_NoSymbol) {
                    n = c.xkb_keysym_to_utf8(sym, @ptrCast(&self.buf), self.buf.len);
                }
                c.xkb_compose_state_reset(self.state);
                if (n <= 0) return .none;
                return .{ .composed = .{
                    .utf8 = self.buf[0..@min(@as(usize, @intCast(n)), self.buf.len)],
                    .keysym = sym,
                } };
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(self.state);
                return .cancelled;
            },
            else => return .none, // XKB_COMPOSE_NOTHING
        }
    }

    /// Abort any in-progress sequence.
    pub fn reset(self: *Compose) void {
        c.xkb_compose_state_reset(self.state);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testKeymap(opts: Options) !Keymap {
    return Keymap.init(testing.io, testing.allocator, opts);
}

fn tmpPath(alloc: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

/// Minimal hermetic compose table (used when the locale table is not
/// installed, and for the processKey integration test).
const inline_compose =
    \\<dead_acute> <a> : "á" aacute
    \\<dead_acute> <A> : "Á" Aacute
    \\<dead_acute> <e> : "é" eacute
    \\
;

fn expectUtf8(ev: ?KeyEvent, want: []const u8) !void {
    const e = ev orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(want, e.utf8 orelse return error.TestUnexpectedResult);
}

test "default keymap compiles and yields a state" {
    var km = try testKeymap(.{});
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();
    try testing.expect(km.numLayouts() >= 1);
    try testing.expectEqual(@as(u32, 0), st.activeLayout());
}

test "us: 'a' press and release" {
    var km = try testKeymap(.{ .model = "pc105", .layout = "us" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    const ev = st.processKey(kt.key_code.key_a, true) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(GhosttyKey.a, ev.ghostty_key);
    try testing.expectEqualStrings("a", ev.utf8.?);
    try testing.expectEqual(@as(u32, 'a'), ev.keysym);
    try testing.expectEqual(@as(GhosttyMods, 0), ev.mods);
    try testing.expectEqual(@as(?u21, 'a'), ev.unshifted_codepoint);
    // Alphabetic keys consume Shift and Lock for level selection, even
    // when no modifier is active.
    const shift_lock = c.xkb_keymap_mod_get_mask(km.map, c.XKB_MOD_NAME_SHIFT) |
        c.xkb_keymap_mod_get_mask(km.map, c.XKB_MOD_NAME_CAPS);
    try testing.expectEqual(shift_lock, ev.consumed_mods);

    const rel = st.processKey(kt.key_code.key_a, false) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(GhosttyKey.a, rel.ghostty_key);
    try testing.expect(rel.utf8 == null);
    try testing.expectEqual(@as(GhosttyMods, 0), rel.mods);
}

test "us: shift+a -> 'A' with shift mod; side bits track the right key" {
    var km = try testKeymap(.{ .layout = "us" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    const shift = st.processKey(kt.key_code.key_leftshift, true).?;
    try testing.expectEqual(GhosttyKey.shift_left, shift.ghostty_key);
    try testing.expect(shift.utf8 == null);
    try testing.expectEqual(kt.mod_shift, shift.mods);

    const ev = st.processKey(kt.key_code.key_a, true).?;
    try testing.expectEqualStrings("A", ev.utf8.?);
    try testing.expectEqual(@as(u32, 'A'), ev.keysym);
    try testing.expectEqual(kt.mod_shift, ev.mods); // left shift: no side bit
    try testing.expectEqual(GhosttyKey.a, ev.ghostty_key);
    try testing.expectEqual(@as(?u21, 'a'), ev.unshifted_codepoint);

    _ = st.processKey(kt.key_code.key_a, false);
    _ = st.processKey(kt.key_code.key_leftshift, false);
    try testing.expectEqual(@as(GhosttyMods, 0), st.mods());

    const rshift = st.processKey(kt.key_code.key_rightshift, true).?;
    try testing.expectEqual(kt.mod_shift | kt.mod_shift_side, rshift.mods);
    _ = st.processKey(kt.key_code.key_rightshift, false);
}

test "us: ctrl+a -> ctrl mod and utf8 0x01 (xkb Control transformation)" {
    var km = try testKeymap(.{ .layout = "us" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    const ctrl = st.processKey(kt.key_code.key_leftctrl, true).?;
    try testing.expectEqual(kt.mod_ctrl, ctrl.mods);
    const ev = st.processKey(kt.key_code.key_a, true).?;
    try testing.expectEqual(kt.mod_ctrl, ev.mods);
    try testing.expectEqualStrings("\x01", ev.utf8.?);
    _ = st.processKey(kt.key_code.key_a, false);
    _ = st.processKey(kt.key_code.key_leftctrl, false);
}

test "modifier bits: alt, super, caps lock, num lock; LEDs" {
    var km = try testKeymap(.{ .layout = "us" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    const alt = st.processKey(kt.key_code.key_leftalt, true).?;
    try testing.expectEqual(kt.mod_alt, alt.mods);
    _ = st.processKey(kt.key_code.key_leftalt, false);

    const super = st.processKey(kt.key_code.key_leftmeta, true).?;
    try testing.expectEqual(kt.mod_super, super.mods);
    _ = st.processKey(kt.key_code.key_leftmeta, false);

    try testing.expect(!st.leds().caps_lock);
    _ = st.processKey(kt.key_code.key_capslock, true);
    try testing.expectEqual(kt.mod_caps_lock, st.mods());
    try testing.expect(st.leds().caps_lock);
    _ = st.processKey(kt.key_code.key_capslock, false);
    try testing.expect(st.leds().caps_lock); // lock survives the release
    _ = st.processKey(kt.key_code.key_capslock, true);
    _ = st.processKey(kt.key_code.key_capslock, false);
    try testing.expect(!st.leds().caps_lock);
    try testing.expectEqual(@as(GhosttyMods, 0), st.mods());

    try testing.expect(!st.leds().num_lock);
    _ = st.processKey(kt.key_code.key_numlock, true);
    _ = st.processKey(kt.key_code.key_numlock, false);
    try testing.expect(st.leds().num_lock);
    try testing.expectEqual(kt.mod_num_lock, st.mods());
    try testing.expect(!st.leds().scroll_lock);
}

test "de layout: evdev 21 (y on us) -> 'z' (localectl parity)" {
    var km = try testKeymap(.{ .layout = "de" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    const ev = st.processKey(kt.key_code.key_y, true).?;
    try testing.expectEqualStrings("z", ev.utf8.?);
    try testing.expectEqual(@as(u32, 'z'), ev.keysym);
    try testing.expectEqual(GhosttyKey.y, ev.ghostty_key); // physical key stays y
    try testing.expectEqual(@as(?u21, 'z'), ev.unshifted_codepoint);
}

test "compose: dead_acute + a -> á (locale table or inline fallback)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const path = try tmpPath(alloc, &tmp, "Compose");
    defer alloc.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Compose", .data = inline_compose });

    var cp = Compose.init(testing.io, alloc, "en_US.UTF-8", null) catch |err| switch (err) {
        // No locale compose data in this environment: use the inline file.
        error.ComposeTableFailed => try Compose.init(testing.io, alloc, "C", path),
        else => return err,
    };
    defer cp.deinit();

    try testing.expectEqual(ComposeResult.composing, cp.feed(c.XKB_KEY_dead_acute, 0));
    const r = cp.feed('a', 0);
    switch (r) {
        .composed => |composed| {
            try testing.expectEqualStrings("á", composed.utf8);
            try testing.expectEqual(@as(u32, c.XKB_KEY_aacute), composed.keysym);
        },
        else => return error.TestUnexpectedResult,
    }
    // Reset after composed: the next 'a' is plain again.
    try testing.expectEqual(ComposeResult.none, cp.feed('a', 0));

    // Cancellation: unmatched keysym cancels, then normal input resumes.
    try testing.expectEqual(ComposeResult.composing, cp.feed(c.XKB_KEY_dead_acute, 0));
    try testing.expectEqual(ComposeResult.cancelled, cp.feed('x', 0));
    try testing.expectEqual(ComposeResult.none, cp.feed('a', 0));

    // Ctrl bypasses compose and aborts the sequence.
    try testing.expectEqual(ComposeResult.composing, cp.feed(c.XKB_KEY_dead_acute, 0));
    try testing.expectEqual(ComposeResult.none, cp.feed('a', kt.mod_ctrl));
    try testing.expectEqual(ComposeResult.none, cp.feed('a', 0));
}

test "compose integration: processKey suppresses dead keys, emits composed text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const path = try tmpPath(alloc, &tmp, "Compose");
    defer alloc.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Compose", .data = inline_compose });

    // us(intl) puts dead_acute on the quote key (evdev 40).
    var km = try testKeymap(.{ .layout = "us", .variant = "intl" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();
    var cp = try Compose.init(testing.io, alloc, "C", path);
    defer cp.deinit();
    // Without compose the dead key yields its keysym and no text.
    const dead = st.processKey(kt.key_code.key_apostrophe, true).?;
    try testing.expectEqual(@as(u32, c.XKB_KEY_dead_acute), dead.keysym);
    try testing.expect(dead.utf8 == null);
    _ = st.processKey(kt.key_code.key_apostrophe, false);

    st.setCompose(&cp);

    // With compose: dead key press is swallowed, 'a' completes to á.
    try testing.expect(st.processKey(kt.key_code.key_apostrophe, true) == null);
    const ev = st.processKey(kt.key_code.key_a, true).?;
    try testing.expectEqualStrings("á", ev.utf8.?);
    try testing.expectEqual(@as(u32, c.XKB_KEY_aacute), ev.keysym);
    try testing.expectEqual(GhosttyKey.a, ev.ghostty_key);
    _ = st.processKey(kt.key_code.key_a, false);
    _ = st.processKey(kt.key_code.key_apostrophe, false);

    // Cancelled sequence: the cancelling key is swallowed too (kmscon).
    try testing.expect(st.processKey(kt.key_code.key_apostrophe, true) == null);
    try testing.expect(st.processKey(kt.key_code.key_x, true) == null);
    _ = st.processKey(kt.key_code.key_x, false);
    _ = st.processKey(kt.key_code.key_apostrophe, false);
    try expectUtf8(st.processKey(kt.key_code.key_a, true), "a");
    _ = st.processKey(kt.key_code.key_a, false);
}

test "repeat config: kmscon defaults and clamping; shouldRepeat per key" {
    const defaults = RepeatConfig{};
    try testing.expectEqual(@as(u32, 250), defaults.delay_ms);
    try testing.expectEqual(@as(u32, 20), defaults.rate_hz);
    try testing.expectEqual(defaults, RepeatConfig.fromKmsconMs(250, 50));
    try testing.expectEqual(defaults, RepeatConfig.fromKmsconMs(0, 0));
    try testing.expectEqual(RepeatConfig{ .delay_ms = 999, .rate_hz = 1 }, RepeatConfig.fromKmsconMs(1000, 1000));
    try testing.expectEqual(RepeatConfig{ .delay_ms = 300, .rate_hz = 25 }, RepeatConfig.fromKmsconMs(300, 40));

    var km = try testKeymap(.{ .layout = "us" });
    defer km.deinit();
    try testing.expect(km.shouldRepeat(kt.key_code.key_a));
    try testing.expect(km.shouldRepeat(kt.key_code.key_f1));
    try testing.expect(!km.shouldRepeat(kt.key_code.key_leftshift));
    try testing.expect(!km.shouldRepeat(kt.key_code.key_leftctrl));
    try testing.expect(!km.shouldRepeat(kt.key_code.key_capslock));
}

test "reload switches layout live and preserves nothing" {
    var km = try testKeymap(.{ .layout = "us" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    _ = st.processKey(kt.key_code.key_leftshift, true);
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "Y");
    _ = st.processKey(kt.key_code.key_y, false);

    try st.reload(.{ .layout = "de" });
    try testing.expectEqual(@as(GhosttyMods, 0), st.mods()); // held shift is gone
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "z");
    _ = st.processKey(kt.key_code.key_y, false);
    _ = st.processKey(kt.key_code.key_leftshift, false);

    // Keymap.reload alone also works (states must then be recreated).
    try km.reload(.{ .layout = "us" });
    var st2 = try State.init(&km);
    defer st2.deinit();
    try expectUtf8(st2.processKey(kt.key_code.key_y, true), "y");
}

test "multi-layout keymap: layout queries, setLayout, updateMask" {
    var km = try testKeymap(.{ .layout = "us,de" });
    defer km.deinit();
    var st = try State.init(&km);
    defer st.deinit();

    try testing.expectEqual(@as(u32, 2), km.numLayouts());
    // Compiled keymaps carry descriptive layout names, not RMLVO names.
    try testing.expectEqual(@as(?u32, 0), try km.layoutIndex("English (US)"));
    try testing.expectEqual(@as(?u32, 1), try km.layoutIndex("German"));
    try testing.expectEqual(@as(?u32, null), try km.layoutIndex("French"));
    try testing.expectEqualStrings("German", km.layoutName(1).?);
    try testing.expect(km.layoutName(99) == null);

    try testing.expectEqual(@as(u32, 0), st.activeLayout());
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "y");
    _ = st.processKey(kt.key_code.key_y, false);

    st.setLayout(1);
    try testing.expectEqual(@as(u32, 1), st.activeLayout());
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "z");
    _ = st.processKey(kt.key_code.key_y, false);

    st.updateMask(0, 0, 0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 0), st.activeLayout());
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "y");
    _ = st.processKey(kt.key_code.key_y, false);

    // Out-of-band locked Caps Lock shows up in mods and LEDs.
    const caps_mask = c.xkb_keymap_mod_get_mask(km.map, c.XKB_MOD_NAME_CAPS);
    st.updateMask(0, 0, caps_mask, 0, 0, 0);
    try testing.expectEqual(kt.mod_caps_lock, st.mods());
    try testing.expect(st.leds().caps_lock);
}

test "keymap_file: precedence over RMLVO, fallbacks for bad file and bad RMLVO" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const path = try tmpPath(alloc, &tmp, "us.xkb");
    defer alloc.free(path);

    {
        var us = try testKeymap(.{ .layout = "us" });
        defer us.deinit();
        const serialized = c.xkb_keymap_get_as_string(us.map, c.XKB_KEYMAP_FORMAT_TEXT_V1);
        try testing.expect(serialized != null);
        defer std.c.free(serialized);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "us.xkb", .data = std.mem.span(serialized) });
    }

    // The file wins over layout=de.
    var from_file = try testKeymap(.{ .layout = "de", .keymap_file = path });
    defer from_file.deinit();
    var st = try State.init(&from_file);
    defer st.deinit();
    try expectUtf8(st.processKey(kt.key_code.key_y, true), "y");
    _ = st.processKey(kt.key_code.key_y, false);

    // Unreadable file falls back to the requested RMLVO (de).
    var missing = try testKeymap(.{ .layout = "de", .keymap_file = ".zig-cache/tmp/no-such-keymap.xkb" });
    defer missing.deinit();
    var st2 = try State.init(&missing);
    defer st2.deinit();
    try expectUtf8(st2.processKey(kt.key_code.key_y, true), "z");
    _ = st2.processKey(kt.key_code.key_y, false);

    // Invalid RMLVO falls back to the default keymap (us).
    var bad = try testKeymap(.{ .layout = "no_such_layout_xyz" });
    defer bad.deinit();
    var st3 = try State.init(&bad);
    defer st3.deinit();
    try expectUtf8(st3.processKey(kt.key_code.key_a, true), "a");
}
