//! src/input/keymap_table.zig -- xkb/evdev -> libghostty-vt key and modifier
//! mapping (ROADMAP M1.6, T1 unit-test target).
//!
//! `GhosttyKey`, `GhosttyMods` and `GhosttyKeyAction` mirror byte-for-byte the
//! C values of libghostty-vt 1.0.1 (include/ghostty/vt/key/event.h), which
//! are W3C UI Events KeyboardEvent code names. The evdev table follows
//! linux/include/uapi/linux/input-event-codes.h and maps every physical key
//! code to the W3C code ghostty uses; xkb keycodes are evdev + 8 (the
//! xkbcommon convention). `xkbKeysymToGhosttyKey` is a logical fallback for
//! event paths that only carry a keysym, and `keysymFromName` lets grab
//! parsing validate keysym names without linking xkbcommon.
//!
//! Values verified against:
//!   - include/ghostty/vt/key/event.h of the 1.0.1 tarball
//!   - linux include/uapi/linux/input-event-codes.h (v6.x)
//!   - xkbcommon-keysyms.h (libxkbcommon 1.13.2)

const std = @import("std");

// ---------------------------------------------------------------------------
// Ghostty key codes
// ---------------------------------------------------------------------------

/// Physical key codes: W3C UI Events `KeyboardEvent.code` values, exactly as
/// event.h defines them (GHOSTTY_KEY_*). Layout-independent: "key a" on a US
/// keyboard is the "ф" key on a Russian one, but both are `.a`.
pub const GhosttyKey = enum(c_uint) {
    unidentified = 0,

    // Writing System Keys (W3C § 3.1.1)
    backquote = 1,
    backslash = 2,
    bracket_left = 3,
    bracket_right = 4,
    comma = 5,
    digit_0 = 6,
    digit_1 = 7,
    digit_2 = 8,
    digit_3 = 9,
    digit_4 = 10,
    digit_5 = 11,
    digit_6 = 12,
    digit_7 = 13,
    digit_8 = 14,
    digit_9 = 15,
    equal = 16,
    intl_backslash = 17,
    intl_ro = 18,
    intl_yen = 19,
    a = 20,
    b = 21,
    c = 22,
    d = 23,
    e = 24,
    f = 25,
    g = 26,
    h = 27,
    i = 28,
    j = 29,
    k = 30,
    l = 31,
    m = 32,
    n = 33,
    o = 34,
    p = 35,
    q = 36,
    r = 37,
    s = 38,
    t = 39,
    u = 40,
    v = 41,
    w = 42,
    x = 43,
    y = 44,
    z = 45,
    minus = 46,
    period = 47,
    quote = 48,
    semicolon = 49,
    slash = 50,

    // Functional Keys (W3C § 3.1.2)
    alt_left = 51,
    alt_right = 52,
    backspace = 53,
    caps_lock = 54,
    context_menu = 55,
    control_left = 56,
    control_right = 57,
    enter = 58,
    meta_left = 59,
    meta_right = 60,
    shift_left = 61,
    shift_right = 62,
    space = 63,
    tab = 64,
    convert = 65,
    kana_mode = 66,
    non_convert = 67,

    // Control Pad Section (W3C § 3.2)
    delete = 68,
    end = 69,
    help = 70,
    home = 71,
    insert = 72,
    page_down = 73,
    page_up = 74,

    // Arrow Pad Section (W3C § 3.3)
    arrow_down = 75,
    arrow_left = 76,
    arrow_right = 77,
    arrow_up = 78,

    // Numpad Section (W3C § 3.4)
    num_lock = 79,
    numpad_0 = 80,
    numpad_1 = 81,
    numpad_2 = 82,
    numpad_3 = 83,
    numpad_4 = 84,
    numpad_5 = 85,
    numpad_6 = 86,
    numpad_7 = 87,
    numpad_8 = 88,
    numpad_9 = 89,
    numpad_add = 90,
    numpad_backspace = 91,
    numpad_clear = 92,
    numpad_clear_entry = 93,
    numpad_comma = 94,
    numpad_decimal = 95,
    numpad_divide = 96,
    numpad_enter = 97,
    numpad_equal = 98,
    numpad_memory_add = 99,
    numpad_memory_clear = 100,
    numpad_memory_recall = 101,
    numpad_memory_store = 102,
    numpad_memory_subtract = 103,
    numpad_multiply = 104,
    numpad_paren_left = 105,
    numpad_paren_right = 106,
    numpad_subtract = 107,
    numpad_separator = 108,
    numpad_up = 109,
    numpad_down = 110,
    numpad_right = 111,
    numpad_left = 112,
    numpad_begin = 113,
    numpad_home = 114,
    numpad_end = 115,
    numpad_insert = 116,
    numpad_delete = 117,
    numpad_page_up = 118,
    numpad_page_down = 119,

    // Function Section (W3C § 3.5)
    escape = 120,
    f1 = 121,
    f2 = 122,
    f3 = 123,
    f4 = 124,
    f5 = 125,
    f6 = 126,
    f7 = 127,
    f8 = 128,
    f9 = 129,
    f10 = 130,
    f11 = 131,
    f12 = 132,
    f13 = 133,
    f14 = 134,
    f15 = 135,
    f16 = 136,
    f17 = 137,
    f18 = 138,
    f19 = 139,
    f20 = 140,
    f21 = 141,
    f22 = 142,
    f23 = 143,
    f24 = 144,
    f25 = 145,
    fn_ = 146,
    fn_lock = 147,
    print_screen = 148,
    scroll_lock = 149,
    pause = 150,

    // Media Keys (W3C § 3.6)
    browser_back = 151,
    browser_favorites = 152,
    browser_forward = 153,
    browser_home = 154,
    browser_refresh = 155,
    browser_search = 156,
    browser_stop = 157,
    eject = 158,
    launch_app_1 = 159,
    launch_app_2 = 160,
    launch_mail = 161,
    media_play_pause = 162,
    media_select = 163,
    media_stop = 164,
    media_track_next = 165,
    media_track_previous = 166,
    power = 167,
    sleep = 168,
    audio_volume_down = 169,
    audio_volume_mute = 170,
    audio_volume_up = 171,
    wake_up = 172,

    // Legacy, Non-standard and Special Keys (W3C § 3.7)
    copy = 173,
    cut = 174,
    paste = 175,
};

/// Keyboard modifier keys bitmask (uint16_t in event.h:109).
///
/// The right-side bits are only meaningful when the corresponding base bit is
/// set. Some platforms cannot distinguish left/right and never set them.
pub const GhosttyMods = u16;

/// Shift key is pressed.
pub const mod_shift: GhosttyMods = 1 << 0;
/// Control key is pressed.
pub const mod_ctrl: GhosttyMods = 1 << 1;
/// Alt/Option key is pressed.
pub const mod_alt: GhosttyMods = 1 << 2;
/// Super/Command/Windows key is pressed.
pub const mod_super: GhosttyMods = 1 << 3;
/// Caps Lock is active.
pub const mod_caps_lock: GhosttyMods = 1 << 4;
/// Num Lock is active.
pub const mod_num_lock: GhosttyMods = 1 << 5;
/// Right shift is pressed (0 = left, 1 = right).
pub const mod_shift_side: GhosttyMods = 1 << 6;
/// Right ctrl is pressed (0 = left, 1 = right).
pub const mod_ctrl_side: GhosttyMods = 1 << 7;
/// Right alt is pressed (0 = left, 1 = right).
pub const mod_alt_side: GhosttyMods = 1 << 8;
/// Right super is pressed (0 = left, 1 = right).
pub const mod_super_side: GhosttyMods = 1 << 9;

/// Keyboard input event types (event.h:62).
pub const GhosttyKeyAction = enum(c_int) {
    /// Key was released.
    release = 0,
    /// Key was pressed.
    press = 1,
    /// Key is being repeated (held down).
    repeat = 2,
};

// ---------------------------------------------------------------------------
// Linux input event codes (KEY_*)
// ---------------------------------------------------------------------------

/// Linux input event codes from linux/include/uapi/linux/input-event-codes.h.
/// libinput reports these for `EV_KEY` events; xkb keycodes are `code + 8`.
pub const key_code = struct {
    pub const key_reserved: u32 = 0;
    pub const key_esc: u32 = 1;
    pub const key_1: u32 = 2;
    pub const key_2: u32 = 3;
    pub const key_3: u32 = 4;
    pub const key_4: u32 = 5;
    pub const key_5: u32 = 6;
    pub const key_6: u32 = 7;
    pub const key_7: u32 = 8;
    pub const key_8: u32 = 9;
    pub const key_9: u32 = 10;
    pub const key_0: u32 = 11;
    pub const key_minus: u32 = 12;
    pub const key_equal: u32 = 13;
    pub const key_backspace: u32 = 14;
    pub const key_tab: u32 = 15;
    pub const key_q: u32 = 16;
    pub const key_w: u32 = 17;
    pub const key_e: u32 = 18;
    pub const key_r: u32 = 19;
    pub const key_t: u32 = 20;
    pub const key_y: u32 = 21;
    pub const key_u: u32 = 22;
    pub const key_i: u32 = 23;
    pub const key_o: u32 = 24;
    pub const key_p: u32 = 25;
    pub const key_leftbrace: u32 = 26;
    pub const key_rightbrace: u32 = 27;
    pub const key_enter: u32 = 28;
    pub const key_leftctrl: u32 = 29;
    pub const key_a: u32 = 30;
    pub const key_s: u32 = 31;
    pub const key_d: u32 = 32;
    pub const key_f: u32 = 33;
    pub const key_g: u32 = 34;
    pub const key_h: u32 = 35;
    pub const key_j: u32 = 36;
    pub const key_k: u32 = 37;
    pub const key_l: u32 = 38;
    pub const key_semicolon: u32 = 39;
    pub const key_apostrophe: u32 = 40;
    pub const key_grave: u32 = 41;
    pub const key_leftshift: u32 = 42;
    pub const key_backslash: u32 = 43;
    pub const key_z: u32 = 44;
    pub const key_x: u32 = 45;
    pub const key_c: u32 = 46;
    pub const key_v: u32 = 47;
    pub const key_b: u32 = 48;
    pub const key_n: u32 = 49;
    pub const key_m: u32 = 50;
    pub const key_comma: u32 = 51;
    pub const key_dot: u32 = 52;
    pub const key_slash: u32 = 53;
    pub const key_rightshift: u32 = 54;
    pub const key_kpasterisk: u32 = 55;
    pub const key_leftalt: u32 = 56;
    pub const key_space: u32 = 57;
    pub const key_capslock: u32 = 58;
    pub const key_f1: u32 = 59;
    pub const key_f2: u32 = 60;
    pub const key_f3: u32 = 61;
    pub const key_f4: u32 = 62;
    pub const key_f5: u32 = 63;
    pub const key_f6: u32 = 64;
    pub const key_f7: u32 = 65;
    pub const key_f8: u32 = 66;
    pub const key_f9: u32 = 67;
    pub const key_f10: u32 = 68;
    pub const key_numlock: u32 = 69;
    pub const key_scrolllock: u32 = 70;
    pub const key_kp7: u32 = 71;
    pub const key_kp8: u32 = 72;
    pub const key_kp9: u32 = 73;
    pub const key_kpminus: u32 = 74;
    pub const key_kp4: u32 = 75;
    pub const key_kp5: u32 = 76;
    pub const key_kp6: u32 = 77;
    pub const key_kpplus: u32 = 78;
    pub const key_kp1: u32 = 79;
    pub const key_kp2: u32 = 80;
    pub const key_kp3: u32 = 81;
    pub const key_kp0: u32 = 82;
    pub const key_kpdot: u32 = 83;
    pub const key_102nd: u32 = 86;
    pub const key_f11: u32 = 87;
    pub const key_f12: u32 = 88;
    pub const key_ro: u32 = 89;
    pub const key_katakana: u32 = 90;
    pub const key_henkan: u32 = 92;
    pub const key_muhenkan: u32 = 94;
    pub const key_kpjpcomma: u32 = 95;
    pub const key_kpenter: u32 = 96;
    pub const key_rightctrl: u32 = 97;
    pub const key_kpslash: u32 = 98;
    pub const key_sysrq: u32 = 99;
    pub const key_rightalt: u32 = 100;
    pub const key_home: u32 = 102;
    pub const key_up: u32 = 103;
    pub const key_pageup: u32 = 104;
    pub const key_left: u32 = 105;
    pub const key_right: u32 = 106;
    pub const key_end: u32 = 107;
    pub const key_down: u32 = 108;
    pub const key_pagedown: u32 = 109;
    pub const key_insert: u32 = 110;
    pub const key_delete: u32 = 111;
    pub const key_mute: u32 = 113;
    pub const key_volumedown: u32 = 114;
    pub const key_volumeup: u32 = 115;
    pub const key_power: u32 = 116;
    pub const key_kpequal: u32 = 117;
    pub const key_pause: u32 = 119;
    pub const key_kpcomma: u32 = 121;
    pub const key_yen: u32 = 124;
    pub const key_leftmeta: u32 = 125;
    pub const key_rightmeta: u32 = 126;
    pub const key_compose: u32 = 127;
    pub const key_stop: u32 = 128;
    pub const key_help: u32 = 138;
    pub const key_menu: u32 = 139;
    pub const key_sleep: u32 = 142;
    pub const key_wakeup: u32 = 143;
    pub const key_mail: u32 = 155;
    pub const key_bookmarks: u32 = 156;
    pub const key_back: u32 = 158;
    pub const key_forward: u32 = 159;
    pub const key_ejectcd: u32 = 161;
    pub const key_nextsong: u32 = 163;
    pub const key_playpause: u32 = 164;
    pub const key_previoussong: u32 = 165;
    pub const key_stopcd: u32 = 166;
    pub const key_homepage: u32 = 172;
    pub const key_refresh: u32 = 173;
    pub const key_kpleftparen: u32 = 179;
    pub const key_kprightparen: u32 = 180;
    pub const key_f13: u32 = 183;
    pub const key_f14: u32 = 184;
    pub const key_f15: u32 = 185;
    pub const key_f16: u32 = 186;
    pub const key_f17: u32 = 187;
    pub const key_f18: u32 = 188;
    pub const key_f19: u32 = 189;
    pub const key_f20: u32 = 190;
    pub const key_f21: u32 = 191;
    pub const key_f22: u32 = 192;
    pub const key_f23: u32 = 193;
    pub const key_f24: u32 = 194;
    pub const key_search: u32 = 217;
    /// KEY_CONTEXT_MENU (0x1b6): system context-menu consumer key.
    pub const key_context_menu: u32 = 0x1b6;
    /// KEY_FN (0x1d0).
    pub const key_fn: u32 = 0x1d0;
};

/// Map a Linux evdev key code (input-event-codes.h `KEY_*`, as reported by
/// libinput) to the physical `GhosttyKey`. Unknown codes yield `.unidentified`.
pub fn evdevToGhosttyKey(code: u32) GhosttyKey {
    return switch (code) {
        key_code.key_esc => .escape,
        key_code.key_1 => .digit_1,
        key_code.key_2 => .digit_2,
        key_code.key_3 => .digit_3,
        key_code.key_4 => .digit_4,
        key_code.key_5 => .digit_5,
        key_code.key_6 => .digit_6,
        key_code.key_7 => .digit_7,
        key_code.key_8 => .digit_8,
        key_code.key_9 => .digit_9,
        key_code.key_0 => .digit_0,
        key_code.key_minus => .minus,
        key_code.key_equal => .equal,
        key_code.key_backspace => .backspace,
        key_code.key_tab => .tab,
        key_code.key_q => .q,
        key_code.key_w => .w,
        key_code.key_e => .e,
        key_code.key_r => .r,
        key_code.key_t => .t,
        key_code.key_y => .y,
        key_code.key_u => .u,
        key_code.key_i => .i,
        key_code.key_o => .o,
        key_code.key_p => .p,
        key_code.key_leftbrace => .bracket_left,
        key_code.key_rightbrace => .bracket_right,
        key_code.key_enter => .enter,
        key_code.key_leftctrl => .control_left,
        key_code.key_a => .a,
        key_code.key_s => .s,
        key_code.key_d => .d,
        key_code.key_f => .f,
        key_code.key_g => .g,
        key_code.key_h => .h,
        key_code.key_j => .j,
        key_code.key_k => .k,
        key_code.key_l => .l,
        key_code.key_semicolon => .semicolon,
        key_code.key_apostrophe => .quote,
        key_code.key_grave => .backquote,
        key_code.key_leftshift => .shift_left,
        key_code.key_backslash => .backslash,
        key_code.key_z => .z,
        key_code.key_x => .x,
        key_code.key_c => .c,
        key_code.key_v => .v,
        key_code.key_b => .b,
        key_code.key_n => .n,
        key_code.key_m => .m,
        key_code.key_comma => .comma,
        key_code.key_dot => .period,
        key_code.key_slash => .slash,
        key_code.key_rightshift => .shift_right,
        key_code.key_kpasterisk => .numpad_multiply,
        key_code.key_leftalt => .alt_left,
        key_code.key_space => .space,
        key_code.key_capslock => .caps_lock,

        // F1..F10 (evdev 59..68 -> ghostty 121..130); F11=87, F12=88 are
        // not contiguous with F1..F10, so they get explicit prongs.
        key_code.key_f1 ... key_code.key_f10 => @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.f1) + (code - key_code.key_f1))),
        key_code.key_f11 => .f11,
        key_code.key_f12 => .f12,

        key_code.key_numlock => .num_lock,
        key_code.key_scrolllock => .scroll_lock,
        key_code.key_kp7 => .numpad_7,
        key_code.key_kp8 => .numpad_8,
        key_code.key_kp9 => .numpad_9,
        key_code.key_kpminus => .numpad_subtract,
        key_code.key_kp4 => .numpad_4,
        key_code.key_kp5 => .numpad_5,
        key_code.key_kp6 => .numpad_6,
        key_code.key_kpplus => .numpad_add,
        key_code.key_kp1 => .numpad_1,
        key_code.key_kp2 => .numpad_2,
        key_code.key_kp3 => .numpad_3,
        key_code.key_kp0 => .numpad_0,
        key_code.key_kpdot => .numpad_decimal,
        key_code.key_102nd => .intl_backslash,
        key_code.key_ro => .intl_ro,
        key_code.key_katakana => .kana_mode,
        key_code.key_henkan => .convert,
        key_code.key_muhenkan => .non_convert,
        key_code.key_kpjpcomma => .numpad_comma,
        key_code.key_kpenter => .numpad_enter,
        key_code.key_rightctrl => .control_right,
        key_code.key_kpslash => .numpad_divide,
        key_code.key_sysrq => .print_screen,
        key_code.key_rightalt => .alt_right,
        key_code.key_home => .home,
        key_code.key_up => .arrow_up,
        key_code.key_pageup => .page_up,
        key_code.key_left => .arrow_left,
        key_code.key_right => .arrow_right,
        key_code.key_end => .end,
        key_code.key_down => .arrow_down,
        key_code.key_pagedown => .page_down,
        key_code.key_insert => .insert,
        key_code.key_delete => .delete,
        key_code.key_mute => .audio_volume_mute,
        key_code.key_volumedown => .audio_volume_down,
        key_code.key_volumeup => .audio_volume_up,
        key_code.key_power => .power,
        key_code.key_kpequal => .numpad_equal,
        key_code.key_pause => .pause,
        key_code.key_kpcomma => .numpad_comma,
        key_code.key_yen => .intl_yen,
        key_code.key_leftmeta => .meta_left,
        key_code.key_rightmeta => .meta_right,
        key_code.key_stop => .media_stop,
        key_code.key_help => .help,
        key_code.key_menu, key_code.key_context_menu => .context_menu,
        key_code.key_sleep => .sleep,
        key_code.key_wakeup => .wake_up,
        key_code.key_mail => .launch_mail,
        key_code.key_bookmarks => .browser_favorites,
        key_code.key_back => .browser_back,
        key_code.key_forward => .browser_forward,
        key_code.key_ejectcd => .eject,
        key_code.key_nextsong => .media_track_next,
        key_code.key_playpause => .media_play_pause,
        key_code.key_previoussong => .media_track_previous,
        key_code.key_stopcd => .media_stop,
        key_code.key_homepage => .browser_home,
        key_code.key_refresh => .browser_refresh,
        key_code.key_kpleftparen => .numpad_paren_left,
        key_code.key_kprightparen => .numpad_paren_right,

        // F13..F24 (evdev 183..194 -> ghostty 133..144)
        key_code.key_f13 ... key_code.key_f24 => @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.f13) + (code - key_code.key_f13))),

        key_code.key_search => .browser_search,
        key_code.key_fn => .fn_,
        else => .unidentified,
    };
}

/// Map an xkb keycode (xkbcommon convention: evdev + 8) to the physical
/// `GhosttyKey`. Keycodes below 8 have no evdev code and yield `.unidentified`.
pub fn xkbKeycodeToGhosttyKey(keycode: u32) GhosttyKey {
    if (keycode < 8) return .unidentified;
    return evdevToGhosttyKey(keycode - 8);
}

// ---------------------------------------------------------------------------
// XKB keysym fallback
// ---------------------------------------------------------------------------

/// XKB keysym values (xkbcommon-keysyms.h / X11 keysymdef.h) used by the
/// logical fallback and the name table.
pub const keysym = struct {
    pub const space: u32 = 0x0020;
    pub const plus: u32 = 0x002b;
    pub const comma: u32 = 0x002c;
    pub const minus: u32 = 0x002d;
    pub const period: u32 = 0x002e;
    pub const slash: u32 = 0x002f;
    pub const equal: u32 = 0x003d;
    pub const underscore: u32 = 0x005f;

    pub const backspace: u32 = 0xff08;
    pub const tab: u32 = 0xff09;
    pub const return_: u32 = 0xff0d;
    pub const pause: u32 = 0xff13;
    pub const scroll_lock: u32 = 0xff14;
    pub const sys_req: u32 = 0xff15;
    pub const escape: u32 = 0xff1b;
    pub const delete: u32 = 0xffff;

    pub const home: u32 = 0xff50;
    pub const left: u32 = 0xff51;
    pub const up: u32 = 0xff52;
    pub const right: u32 = 0xff53;
    pub const down: u32 = 0xff54;
    pub const prior: u32 = 0xff55; // = Page_Up
    pub const next: u32 = 0xff56; // = Page_Down
    pub const end: u32 = 0xff57;
    pub const begin: u32 = 0xff58;
    pub const insert: u32 = 0xff63;
    pub const num_lock: u32 = 0xff7f;

    pub const kp_enter: u32 = 0xff8d;
    pub const kp_home: u32 = 0xff95;
    pub const kp_left: u32 = 0xff96;
    pub const kp_up: u32 = 0xff97;
    pub const kp_right: u32 = 0xff98;
    pub const kp_down: u32 = 0xff99;
    pub const kp_prior: u32 = 0xff9a;
    pub const kp_next: u32 = 0xff9b;
    pub const kp_end: u32 = 0xff9c;
    pub const kp_begin: u32 = 0xff9d;
    pub const kp_insert: u32 = 0xff9e;
    pub const kp_delete: u32 = 0xff9f;

    pub const kp_multiply: u32 = 0xffaa;
    pub const kp_add: u32 = 0xffab;
    pub const kp_separator: u32 = 0xffac;
    pub const kp_subtract: u32 = 0xffad;
    pub const kp_decimal: u32 = 0xffae;
    pub const kp_divide: u32 = 0xffaf;
    /// KP_0 = 0xffb0; KP_n = `kp0_base + n` (0xffb9 for KP_9).
    pub const kp0_base: u32 = 0xffb0;
    pub const kp_equal: u32 = 0xffbd;
    /// F1 = 0xffbe; F_n = `f1_base + n - 1` (F24 = 0xffd5, F35 = 0xffe0).
    pub const f1_base: u32 = 0xffbe;

    pub const shift_left: u32 = 0xffe1;
    pub const shift_right: u32 = 0xffe2;
    pub const control_left: u32 = 0xffe3;
    pub const control_right: u32 = 0xffe4;
    pub const caps_lock: u32 = 0xffe5;
    pub const meta_left: u32 = 0xffe7;
    pub const meta_right: u32 = 0xffe8;
    pub const alt_left: u32 = 0xffe9;
    pub const alt_right: u32 = 0xffea;
    pub const super_left: u32 = 0xffeb;
    pub const super_right: u32 = 0xffec;
    /// AltGr; the physical key is the right alt on most layouts.
    pub const iso_level3_shift: u32 = 0xfe03;
    pub const iso_left_tab: u32 = 0xfe20;
};

/// Logical fallback: map an XKB keysym to the nearest `GhosttyKey` when no
/// physical keycode is available. ASCII letters/digits keep the physical-key
/// semantics (both 'a' and 'A' are `.a`; the shift state travels in the mods
/// bitmask). Keysyms produced by the shifted variant of a key (plus, underscore)
/// map to the key that produces them. Unknown keysyms yield `.unidentified`.
pub fn xkbKeysymToGhosttyKey(sym: u32) GhosttyKey {
    if (sym >= 'a' and sym <= 'z')
        return @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.a) + (sym - 'a')));
    if (sym >= 'A' and sym <= 'Z')
        return @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.a) + (sym - 'A')));
    if (sym >= '0' and sym <= '9')
        return @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.digit_0) + (sym - '0')));
    return switch (sym) {
        keysym.space => .space,
        keysym.plus, keysym.equal => .equal,
        keysym.minus, keysym.underscore => .minus,
        keysym.comma => .comma,
        keysym.period => .period,
        keysym.slash => .slash,
        keysym.backspace => .backspace,
        keysym.tab, keysym.iso_left_tab => .tab,
        keysym.return_ => .enter,
        keysym.escape => .escape,
        keysym.delete => .delete,
        keysym.insert => .insert,
        keysym.home, keysym.begin => .home,
        keysym.end => .end,
        keysym.prior => .page_up,
        keysym.next => .page_down,
        keysym.left => .arrow_left,
        keysym.up => .arrow_up,
        keysym.right => .arrow_right,
        keysym.down => .arrow_down,
        keysym.pause => .pause,
        keysym.scroll_lock => .scroll_lock,
        keysym.sys_req => .print_screen,
        keysym.num_lock => .num_lock,
        keysym.caps_lock => .caps_lock,

        // F1..F24
        keysym.f1_base ... keysym.f1_base + 23 => @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.f1) + (sym - keysym.f1_base))),
        keysym.f1_base + 24 => .f25,

        keysym.shift_left => .shift_left,
        keysym.shift_right => .shift_right,
        keysym.control_left => .control_left,
        keysym.control_right => .control_right,
        keysym.alt_left => .alt_left,
        keysym.alt_right, keysym.iso_level3_shift => .alt_right,
        keysym.meta_left, keysym.super_left => .meta_left,
        keysym.meta_right, keysym.super_right => .meta_right,

        // keypad
        keysym.kp0_base ... keysym.kp0_base + 9 => @enumFromInt(@as(c_uint, @intFromEnum(GhosttyKey.numpad_0) + (sym - keysym.kp0_base))),
        keysym.kp_enter => .numpad_enter,
        keysym.kp_equal => .numpad_equal,
        keysym.kp_multiply => .numpad_multiply,
        keysym.kp_add => .numpad_add,
        keysym.kp_separator => .numpad_separator,
        keysym.kp_subtract => .numpad_subtract,
        keysym.kp_decimal => .numpad_decimal,
        keysym.kp_divide => .numpad_divide,
        keysym.kp_home => .numpad_home,
        keysym.kp_left => .numpad_left,
        keysym.kp_up => .numpad_up,
        keysym.kp_right => .numpad_right,
        keysym.kp_down => .numpad_down,
        keysym.kp_prior => .numpad_page_up,
        keysym.kp_next => .numpad_page_down,
        keysym.kp_end => .numpad_end,
        keysym.kp_begin => .numpad_begin,
        keysym.kp_insert => .numpad_insert,
        keysym.kp_delete => .numpad_delete,
        else => .unidentified,
    };
}

// ---------------------------------------------------------------------------
// Keysym name lookup (grab parsing without linking xkbcommon)
// ---------------------------------------------------------------------------

const SymName = struct {
    name: []const u8,
    sym: u32,
};

/// Keysym names (canonical xkbcommon spelling) for the keys kmscon grabs use
/// plus the aliases and modifier keys the input module needs. F1..F35 and
/// KP_0..KP_9 are handled numerically by `keysymFromName`, not listed here.
const sym_names = [_]SymName{
    .{ .name = "BackSpace", .sym = 0xff08 },
    .{ .name = "Tab", .sym = 0xff09 },
    .{ .name = "Linefeed", .sym = 0xff0a },
    .{ .name = "Clear", .sym = 0xff0b },
    .{ .name = "Return", .sym = 0xff0d },
    .{ .name = "Pause", .sym = 0xff13 },
    .{ .name = "Scroll_Lock", .sym = 0xff14 },
    .{ .name = "Sys_Req", .sym = 0xff15 },
    .{ .name = "Escape", .sym = 0xff1b },
    .{ .name = "Delete", .sym = 0xffff },
    .{ .name = "Home", .sym = 0xff50 },
    .{ .name = "Left", .sym = 0xff51 },
    .{ .name = "Up", .sym = 0xff52 },
    .{ .name = "Right", .sym = 0xff53 },
    .{ .name = "Down", .sym = 0xff54 },
    .{ .name = "Prior", .sym = 0xff55 },
    .{ .name = "Page_Up", .sym = 0xff55 },
    .{ .name = "Next", .sym = 0xff56 },
    .{ .name = "Page_Down", .sym = 0xff56 },
    .{ .name = "End", .sym = 0xff57 },
    .{ .name = "Begin", .sym = 0xff58 },
    .{ .name = "Insert", .sym = 0xff63 },
    .{ .name = "Num_Lock", .sym = 0xff7f },
    .{ .name = "KP_Tab", .sym = 0xff89 },
    .{ .name = "KP_Enter", .sym = 0xff8d },
    .{ .name = "KP_F1", .sym = 0xff91 },
    .{ .name = "KP_F2", .sym = 0xff92 },
    .{ .name = "KP_F3", .sym = 0xff93 },
    .{ .name = "KP_F4", .sym = 0xff94 },
    .{ .name = "KP_Home", .sym = 0xff95 },
    .{ .name = "KP_Left", .sym = 0xff96 },
    .{ .name = "KP_Up", .sym = 0xff97 },
    .{ .name = "KP_Right", .sym = 0xff98 },
    .{ .name = "KP_Down", .sym = 0xff99 },
    .{ .name = "KP_Prior", .sym = 0xff9a },
    .{ .name = "KP_Page_Up", .sym = 0xff9a },
    .{ .name = "KP_Next", .sym = 0xff9b },
    .{ .name = "KP_Page_Down", .sym = 0xff9b },
    .{ .name = "KP_End", .sym = 0xff9c },
    .{ .name = "KP_Begin", .sym = 0xff9d },
    .{ .name = "KP_Insert", .sym = 0xff9e },
    .{ .name = "KP_Delete", .sym = 0xff9f },
    .{ .name = "KP_Multiply", .sym = 0xffaa },
    .{ .name = "KP_Add", .sym = 0xffab },
    .{ .name = "KP_Separator", .sym = 0xffac },
    .{ .name = "KP_Subtract", .sym = 0xffad },
    .{ .name = "KP_Decimal", .sym = 0xffae },
    .{ .name = "KP_Divide", .sym = 0xffaf },
    .{ .name = "KP_Equal", .sym = 0xffbd },
    .{ .name = "plus", .sym = 0x002b },
    .{ .name = "comma", .sym = 0x002c },
    .{ .name = "minus", .sym = 0x002d },
    .{ .name = "period", .sym = 0x002e },
    .{ .name = "slash", .sym = 0x002f },
    .{ .name = "equal", .sym = 0x003d },
    .{ .name = "underscore", .sym = 0x005f },
    .{ .name = "space", .sym = 0x0020 },
    .{ .name = "Shift_L", .sym = 0xffe1 },
    .{ .name = "Shift_R", .sym = 0xffe2 },
    .{ .name = "Control_L", .sym = 0xffe3 },
    .{ .name = "Control_R", .sym = 0xffe4 },
    .{ .name = "Caps_Lock", .sym = 0xffe5 },
    .{ .name = "Shift_Lock", .sym = 0xffe6 },
    .{ .name = "Meta_L", .sym = 0xffe7 },
    .{ .name = "Meta_R", .sym = 0xffe8 },
    .{ .name = "Alt_L", .sym = 0xffe9 },
    .{ .name = "Alt_R", .sym = 0xffea },
    .{ .name = "Super_L", .sym = 0xffeb },
    .{ .name = "Super_R", .sym = 0xffec },
    .{ .name = "Hyper_L", .sym = 0xffed },
    .{ .name = "Hyper_R", .sym = 0xffee },
    .{ .name = "ISO_Level3_Shift", .sym = 0xfe03 },
    .{ .name = "ISO_Left_Tab", .sym = 0xfe20 },
};

/// Look up a keysym by its xkbcommon name, for grab parsing.
///
/// Keysym names are case-sensitive in kmscon, so by default the exact
/// canonical spelling is required ("Page_Up", "BackSpace", "KP_Add"). With
/// `case_insensitive` the match ignores ASCII case (useful for user input
/// outside the strict kmscon grammar). Single printable characters (`!`..`~`)
/// are accepted as their own keysym value, as xkbcommon does. F1..F35 and
/// KP_0..KP_9 are parsed numerically. Returns null for unknown names.
pub fn keysymFromName(name: []const u8, case_insensitive: bool) ?u32 {
    if (name.len == 1) {
        const c = name[0];
        if (c >= '!' and c <= '~') return c;
        return null;
    }

    for (sym_names) |entry| {
        const eq = if (case_insensitive)
            std.ascii.eqlIgnoreCase(name, entry.name)
        else
            std.mem.eql(u8, name, entry.name);
        if (eq) return entry.sym;
    }

    // F1..F35: F1 = 0xffbe. Only F1..F35 exist.
    if (name.len > 1 and (name[0] == 'F' or (case_insensitive and name[0] == 'f'))) {
        var n: u32 = 0;
        var ok = true;
        for (name[1..]) |c| {
            if (c < '0' or c > '9') {
                ok = false;
                break;
            }
            n = n * 10 + (c - '0');
            if (n > 35) {
                ok = false;
                break;
            }
        }
        if (ok and n >= 1) return 0xffbe + (n - 1);
    }

    // KP_0..KP_9: KP_0 = 0xffb0.
    if (name.len == 4) {
        const kp = name[0..3];
        const kp_ok = if (case_insensitive)
            std.ascii.eqlIgnoreCase(kp, "KP_")
        else
            std.mem.eql(u8, kp, "KP_");
        if (kp_ok) {
            const c = name[3];
            if (c >= '0' and c <= '9') return @as(u32, 0xffb0) + (c - '0');
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GhosttyKey integer values match event.h anchors" {
    const v = struct {
        fn v(k: GhosttyKey) u32 {
            return @intFromEnum(k);
        }
    }.v;
    try std.testing.expectEqual(@as(u32, 0), v(.unidentified));
    try std.testing.expectEqual(@as(u32, 20), v(.a));
    try std.testing.expectEqual(@as(u32, 45), v(.z));
    try std.testing.expectEqual(@as(u32, 6), v(.digit_0));
    try std.testing.expectEqual(@as(u32, 58), v(.enter));
    try std.testing.expectEqual(@as(u32, 120), v(.escape));
    try std.testing.expectEqual(@as(u32, 78), v(.arrow_up));
    try std.testing.expectEqual(@as(u32, 121), v(.f1));
    try std.testing.expectEqual(@as(u32, 132), v(.f12));
    try std.testing.expectEqual(@as(u32, 144), v(.f24));
    try std.testing.expectEqual(@as(u32, 80), v(.numpad_0));
    try std.testing.expectEqual(@as(u32, 56), v(.control_left));
    // extra anchors across the dense range (event.h:122-312)
    try std.testing.expectEqual(@as(u32, 1), v(.backquote));
    try std.testing.expectEqual(@as(u32, 46), v(.minus));
    try std.testing.expectEqual(@as(u32, 63), v(.space));
    try std.testing.expectEqual(@as(u32, 68), v(.delete));
    try std.testing.expectEqual(@as(u32, 74), v(.page_up));
    try std.testing.expectEqual(@as(u32, 97), v(.numpad_enter));
    try std.testing.expectEqual(@as(u32, 149), v(.scroll_lock));
    try std.testing.expectEqual(@as(u32, 150), v(.pause));
    try std.testing.expectEqual(@as(u32, 171), v(.audio_volume_up));
    try std.testing.expectEqual(@as(u32, 175), v(.paste));

    // mods bitmask (event.h:111-127)
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 0), mod_shift);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 1), mod_ctrl);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 2), mod_alt);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 3), mod_super);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 4), mod_caps_lock);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 5), mod_num_lock);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 6), mod_shift_side);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 7), mod_ctrl_side);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 8), mod_alt_side);
    try std.testing.expectEqual(@as(GhosttyMods, 1 << 9), mod_super_side);

    // action values (event.h:63-70)
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(GhosttyKeyAction.release));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(GhosttyKeyAction.press));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(GhosttyKeyAction.repeat));
}

test "evdev keycode mapping" {
    const m = evdevToGhosttyKey;
    // raw-number anchors against input-event-codes.h
    try std.testing.expectEqual(GhosttyKey.escape, m(1));
    try std.testing.expectEqual(GhosttyKey.a, m(30));
    try std.testing.expectEqual(GhosttyKey.space, m(57));
    try std.testing.expectEqual(GhosttyKey.num_lock, m(69));
    try std.testing.expectEqual(GhosttyKey.numpad_0, m(82));
    try std.testing.expectEqual(GhosttyKey.arrow_up, m(103));
    try std.testing.expectEqual(GhosttyKey.f24, m(194));
    try std.testing.expectEqual(GhosttyKey.unidentified, m(0));
    try std.testing.expectEqual(GhosttyKey.unidentified, m(0xffff_ffff));

    // letters and digits
    try std.testing.expectEqual(GhosttyKey.a, m(key_code.key_a));
    try std.testing.expectEqual(GhosttyKey.z, m(key_code.key_z));
    try std.testing.expectEqual(GhosttyKey.q, m(key_code.key_q));
    try std.testing.expectEqual(GhosttyKey.m, m(key_code.key_m));
    try std.testing.expectEqual(GhosttyKey.digit_0, m(key_code.key_0));
    try std.testing.expectEqual(GhosttyKey.digit_1, m(key_code.key_1));
    try std.testing.expectEqual(GhosttyKey.digit_9, m(key_code.key_9));
    try std.testing.expectEqual(GhosttyKey.minus, m(key_code.key_minus));
    try std.testing.expectEqual(GhosttyKey.equal, m(key_code.key_equal));
    try std.testing.expectEqual(GhosttyKey.backquote, m(key_code.key_grave));
    try std.testing.expectEqual(GhosttyKey.semicolon, m(key_code.key_semicolon));
    try std.testing.expectEqual(GhosttyKey.bracket_left, m(key_code.key_leftbrace));
    try std.testing.expectEqual(GhosttyKey.period, m(key_code.key_dot));
    try std.testing.expectEqual(GhosttyKey.slash, m(key_code.key_slash));

    // function keys
    try std.testing.expectEqual(GhosttyKey.f1, m(key_code.key_f1));
    try std.testing.expectEqual(GhosttyKey.f10, m(key_code.key_f10));
    try std.testing.expectEqual(GhosttyKey.f11, m(key_code.key_f11));
    try std.testing.expectEqual(GhosttyKey.f12, m(key_code.key_f12));
    try std.testing.expectEqual(GhosttyKey.f13, m(key_code.key_f13));
    try std.testing.expectEqual(GhosttyKey.f24, m(key_code.key_f24));

    // arrows and navigation
    try std.testing.expectEqual(GhosttyKey.arrow_up, m(key_code.key_up));
    try std.testing.expectEqual(GhosttyKey.arrow_down, m(key_code.key_down));
    try std.testing.expectEqual(GhosttyKey.arrow_left, m(key_code.key_left));
    try std.testing.expectEqual(GhosttyKey.arrow_right, m(key_code.key_right));
    try std.testing.expectEqual(GhosttyKey.home, m(key_code.key_home));
    try std.testing.expectEqual(GhosttyKey.end, m(key_code.key_end));
    try std.testing.expectEqual(GhosttyKey.page_up, m(key_code.key_pageup));
    try std.testing.expectEqual(GhosttyKey.page_down, m(key_code.key_pagedown));
    try std.testing.expectEqual(GhosttyKey.insert, m(key_code.key_insert));
    try std.testing.expectEqual(GhosttyKey.delete, m(key_code.key_delete));

    // locks, system keys
    try std.testing.expectEqual(GhosttyKey.caps_lock, m(key_code.key_capslock));
    try std.testing.expectEqual(GhosttyKey.num_lock, m(key_code.key_numlock));
    try std.testing.expectEqual(GhosttyKey.scroll_lock, m(key_code.key_scrolllock));
    try std.testing.expectEqual(GhosttyKey.print_screen, m(key_code.key_sysrq));
    try std.testing.expectEqual(GhosttyKey.pause, m(key_code.key_pause));

    // modifiers
    try std.testing.expectEqual(GhosttyKey.control_left, m(key_code.key_leftctrl));
    try std.testing.expectEqual(GhosttyKey.control_right, m(key_code.key_rightctrl));
    try std.testing.expectEqual(GhosttyKey.shift_left, m(key_code.key_leftshift));
    try std.testing.expectEqual(GhosttyKey.shift_right, m(key_code.key_rightshift));
    try std.testing.expectEqual(GhosttyKey.alt_left, m(key_code.key_leftalt));
    try std.testing.expectEqual(GhosttyKey.alt_right, m(key_code.key_rightalt));
    try std.testing.expectEqual(GhosttyKey.meta_left, m(key_code.key_leftmeta));
    try std.testing.expectEqual(GhosttyKey.meta_right, m(key_code.key_rightmeta));

    // numpad
    try std.testing.expectEqual(GhosttyKey.numpad_0, m(key_code.key_kp0));
    try std.testing.expectEqual(GhosttyKey.numpad_1, m(key_code.key_kp1));
    try std.testing.expectEqual(GhosttyKey.numpad_9, m(key_code.key_kp9));
    try std.testing.expectEqual(GhosttyKey.numpad_add, m(key_code.key_kpplus));
    try std.testing.expectEqual(GhosttyKey.numpad_subtract, m(key_code.key_kpminus));
    try std.testing.expectEqual(GhosttyKey.numpad_multiply, m(key_code.key_kpasterisk));
    try std.testing.expectEqual(GhosttyKey.numpad_divide, m(key_code.key_kpslash));
    try std.testing.expectEqual(GhosttyKey.numpad_decimal, m(key_code.key_kpdot));
    try std.testing.expectEqual(GhosttyKey.numpad_enter, m(key_code.key_kpenter));
    try std.testing.expectEqual(GhosttyKey.numpad_equal, m(key_code.key_kpequal));
    try std.testing.expectEqual(GhosttyKey.numpad_comma, m(key_code.key_kpcomma));
    try std.testing.expectEqual(GhosttyKey.numpad_paren_left, m(key_code.key_kpleftparen));
    try std.testing.expectEqual(GhosttyKey.numpad_paren_right, m(key_code.key_kprightparen));

    // media and consumer keys
    try std.testing.expectEqual(GhosttyKey.audio_volume_mute, m(key_code.key_mute));
    try std.testing.expectEqual(GhosttyKey.audio_volume_down, m(key_code.key_volumedown));
    try std.testing.expectEqual(GhosttyKey.audio_volume_up, m(key_code.key_volumeup));
    try std.testing.expectEqual(GhosttyKey.power, m(key_code.key_power));
    try std.testing.expectEqual(GhosttyKey.sleep, m(key_code.key_sleep));
    try std.testing.expectEqual(GhosttyKey.wake_up, m(key_code.key_wakeup));
    try std.testing.expectEqual(GhosttyKey.media_play_pause, m(key_code.key_playpause));
    try std.testing.expectEqual(GhosttyKey.media_track_next, m(key_code.key_nextsong));
    try std.testing.expectEqual(GhosttyKey.media_track_previous, m(key_code.key_previoussong));
    try std.testing.expectEqual(GhosttyKey.browser_back, m(key_code.key_back));
    try std.testing.expectEqual(GhosttyKey.browser_forward, m(key_code.key_forward));
    try std.testing.expectEqual(GhosttyKey.browser_home, m(key_code.key_homepage));
    try std.testing.expectEqual(GhosttyKey.launch_mail, m(key_code.key_mail));
    try std.testing.expectEqual(GhosttyKey.context_menu, m(key_code.key_menu));
}

test "xkb keycode mapping (evdev + 8)" {
    try std.testing.expectEqual(GhosttyKey.a, xkbKeycodeToGhosttyKey(30 + 8));
    try std.testing.expectEqual(GhosttyKey.enter, xkbKeycodeToGhosttyKey(28 + 8));
    try std.testing.expectEqual(GhosttyKey.numpad_0, xkbKeycodeToGhosttyKey(82 + 8));
    try std.testing.expectEqual(GhosttyKey.arrow_up, xkbKeycodeToGhosttyKey(103 + 8));
    try std.testing.expectEqual(GhosttyKey.f1, xkbKeycodeToGhosttyKey(59 + 8));
    try std.testing.expectEqual(GhosttyKey.control_left, xkbKeycodeToGhosttyKey(29 + 8));
    try std.testing.expectEqual(GhosttyKey.space, xkbKeycodeToGhosttyKey(57 + 8));
    try std.testing.expectEqual(GhosttyKey.shift_right, xkbKeycodeToGhosttyKey(54 + 8));
    // xkb codes below the first evdev code have no key
    try std.testing.expectEqual(GhosttyKey.unidentified, xkbKeycodeToGhosttyKey(0));
    try std.testing.expectEqual(GhosttyKey.unidentified, xkbKeycodeToGhosttyKey(7));
}

test "keysym fallback mapping" {
    const s = xkbKeysymToGhosttyKey;
    try std.testing.expectEqual(GhosttyKey.enter, s(keysym.return_));
    try std.testing.expectEqual(GhosttyKey.backspace, s(keysym.backspace));
    try std.testing.expectEqual(GhosttyKey.tab, s(keysym.tab));
    try std.testing.expectEqual(GhosttyKey.tab, s(keysym.iso_left_tab));
    try std.testing.expectEqual(GhosttyKey.escape, s(keysym.escape));
    try std.testing.expectEqual(GhosttyKey.arrow_up, s(keysym.up));
    try std.testing.expectEqual(GhosttyKey.arrow_down, s(keysym.down));
    try std.testing.expectEqual(GhosttyKey.arrow_left, s(keysym.left));
    try std.testing.expectEqual(GhosttyKey.arrow_right, s(keysym.right));
    try std.testing.expectEqual(GhosttyKey.page_up, s(keysym.prior));
    try std.testing.expectEqual(GhosttyKey.page_down, s(keysym.next));
    try std.testing.expectEqual(GhosttyKey.home, s(keysym.home));
    try std.testing.expectEqual(GhosttyKey.end, s(keysym.end));
    try std.testing.expectEqual(GhosttyKey.insert, s(keysym.insert));
    try std.testing.expectEqual(GhosttyKey.delete, s(keysym.delete));
    try std.testing.expectEqual(GhosttyKey.pause, s(keysym.pause));
    try std.testing.expectEqual(GhosttyKey.scroll_lock, s(keysym.scroll_lock));
    try std.testing.expectEqual(GhosttyKey.print_screen, s(keysym.sys_req));
    try std.testing.expectEqual(GhosttyKey.caps_lock, s(keysym.caps_lock));
    try std.testing.expectEqual(GhosttyKey.num_lock, s(keysym.num_lock));
    // function keys
    try std.testing.expectEqual(GhosttyKey.f1, s(keysym.f1_base));
    try std.testing.expectEqual(GhosttyKey.f12, s(keysym.f1_base + 11));
    try std.testing.expectEqual(GhosttyKey.f24, s(keysym.f1_base + 23));
    try std.testing.expectEqual(GhosttyKey.f25, s(keysym.f1_base + 24));
    try std.testing.expectEqual(GhosttyKey.unidentified, s(keysym.f1_base + 25)); // F26: no ghostty key
    // modifiers
    try std.testing.expectEqual(GhosttyKey.shift_left, s(keysym.shift_left));
    try std.testing.expectEqual(GhosttyKey.shift_right, s(keysym.shift_right));
    try std.testing.expectEqual(GhosttyKey.control_left, s(keysym.control_left));
    try std.testing.expectEqual(GhosttyKey.control_right, s(keysym.control_right));
    try std.testing.expectEqual(GhosttyKey.alt_left, s(keysym.alt_left));
    try std.testing.expectEqual(GhosttyKey.alt_right, s(keysym.alt_right));
    try std.testing.expectEqual(GhosttyKey.alt_right, s(keysym.iso_level3_shift)); // AltGr
    try std.testing.expectEqual(GhosttyKey.meta_left, s(keysym.super_left));
    try std.testing.expectEqual(GhosttyKey.meta_right, s(keysym.super_right));
    // ASCII letters/digits and punctuation
    try std.testing.expectEqual(GhosttyKey.a, s('a'));
    try std.testing.expectEqual(GhosttyKey.a, s('A'));
    try std.testing.expectEqual(GhosttyKey.z, s('z'));
    try std.testing.expectEqual(GhosttyKey.z, s('Z'));
    try std.testing.expectEqual(GhosttyKey.digit_0, s('0'));
    try std.testing.expectEqual(GhosttyKey.digit_9, s('9'));
    try std.testing.expectEqual(GhosttyKey.space, s(keysym.space));
    try std.testing.expectEqual(GhosttyKey.equal, s(keysym.plus));
    try std.testing.expectEqual(GhosttyKey.equal, s(keysym.equal));
    try std.testing.expectEqual(GhosttyKey.minus, s(keysym.minus));
    try std.testing.expectEqual(GhosttyKey.minus, s(keysym.underscore));
    // keypad
    try std.testing.expectEqual(GhosttyKey.numpad_0, s(keysym.kp0_base));
    try std.testing.expectEqual(GhosttyKey.numpad_9, s(keysym.kp0_base + 9));
    try std.testing.expectEqual(GhosttyKey.numpad_add, s(keysym.kp_add));
    try std.testing.expectEqual(GhosttyKey.numpad_subtract, s(keysym.kp_subtract));
    try std.testing.expectEqual(GhosttyKey.numpad_multiply, s(keysym.kp_multiply));
    try std.testing.expectEqual(GhosttyKey.numpad_divide, s(keysym.kp_divide));
    try std.testing.expectEqual(GhosttyKey.numpad_decimal, s(keysym.kp_decimal));
    try std.testing.expectEqual(GhosttyKey.numpad_separator, s(keysym.kp_separator));
    try std.testing.expectEqual(GhosttyKey.numpad_enter, s(keysym.kp_enter));
    try std.testing.expectEqual(GhosttyKey.numpad_equal, s(keysym.kp_equal));
    try std.testing.expectEqual(GhosttyKey.numpad_home, s(keysym.kp_home));
    try std.testing.expectEqual(GhosttyKey.numpad_page_up, s(keysym.kp_prior));
    try std.testing.expectEqual(GhosttyKey.numpad_page_down, s(keysym.kp_next));
    // unknown keysyms
    try std.testing.expectEqual(GhosttyKey.unidentified, s(0xdead_beef));
    try std.testing.expectEqual(GhosttyKey.unidentified, s('~'));
}

test "keysym name lookup covers kmscon grab keys" {
    const ks = keysymFromName;
    // kmscon default grabs (docs/reference/kmscon-options.md §5.7):
    // Shift+Up, Shift+Down, Shift+Prior, Shift+Next, Ctrl+plus/Ctrl+equal,
    // Ctrl+minus, Ctrl+Logo+Right/Left/BackSpace/Return, Logo+plus/equal/minus.
    try std.testing.expectEqual(@as(?u32, 0xff52), ks("Up", false));
    try std.testing.expectEqual(@as(?u32, 0xff54), ks("Down", false));
    try std.testing.expectEqual(@as(?u32, 0xff55), ks("Prior", false));
    try std.testing.expectEqual(@as(?u32, 0xff56), ks("Next", false));
    try std.testing.expectEqual(@as(?u32, 0x002b), ks("plus", false));
    try std.testing.expectEqual(@as(?u32, 0x003d), ks("equal", false));
    try std.testing.expectEqual(@as(?u32, 0x002d), ks("minus", false));
    try std.testing.expectEqual(@as(?u32, 0xff53), ks("Right", false));
    try std.testing.expectEqual(@as(?u32, 0xff51), ks("Left", false));
    try std.testing.expectEqual(@as(?u32, 0xff08), ks("BackSpace", false));
    try std.testing.expectEqual(@as(?u32, 0xff0d), ks("Return", false));
    // remaining grab-set names
    try std.testing.expectEqual(@as(?u32, 0xff55), ks("Page_Up", false));
    try std.testing.expectEqual(@as(?u32, 0xff56), ks("Page_Down", false));
    try std.testing.expectEqual(@as(?u32, 0xff50), ks("Home", false));
    try std.testing.expectEqual(@as(?u32, 0xff57), ks("End", false));
    try std.testing.expectEqual(@as(?u32, 0xff63), ks("Insert", false));
    try std.testing.expectEqual(@as(?u32, 0xffff), ks("Delete", false));
    try std.testing.expectEqual(@as(?u32, 0xff09), ks("Tab", false));
    try std.testing.expectEqual(@as(?u32, 0xff1b), ks("Escape", false));
    try std.testing.expectEqual(@as(?u32, 0x0020), ks("space", false));
    try std.testing.expectEqual(@as(?u32, 0x005f), ks("underscore", false));
    try std.testing.expectEqual(@as(?u32, 0xffbe), ks("F1", false));
    try std.testing.expectEqual(@as(?u32, 0xffc9), ks("F12", false));
    try std.testing.expectEqual(@as(?u32, 0xffd5), ks("F24", false));
    try std.testing.expectEqual(@as(?u32, 0xffb0), ks("KP_0", false));
    try std.testing.expectEqual(@as(?u32, 0xffab), ks("KP_Add", false));
    try std.testing.expectEqual(@as(?u32, 0xffad), ks("KP_Subtract", false));
    // single ASCII letters and digits
    try std.testing.expectEqual(@as(?u32, 0x006e), ks("n", false));
    try std.testing.expectEqual(@as(?u32, 0x0070), ks("p", false));
    try std.testing.expectEqual(@as(?u32, 0x0041), ks("A", false));
    try std.testing.expectEqual(@as(?u32, 0x007a), ks("z", false));
    try std.testing.expectEqual(@as(?u32, 0x0030), ks("0", false));
    try std.testing.expectEqual(@as(?u32, 0x0039), ks("9", false));
    try std.testing.expectEqual(@as(?u32, 0x0021), ks("!", false));
    // keysym names are case-sensitive by default (kmscon behavior)
    try std.testing.expect(ks("backspace", false) == null);
    try std.testing.expect(ks("PAGE_UP", false) == null);
    try std.testing.expect(ks("kp_add", false) == null);
    try std.testing.expect(ks("F1x", false) == null);
    try std.testing.expect(ks("F0", false) == null);
    try std.testing.expect(ks("F36", false) == null);
    try std.testing.expect(ks("", false) == null);
    // case-insensitive mode matches the canonical names
    try std.testing.expectEqual(@as(?u32, 0xff08), ks("backspace", true));
    try std.testing.expectEqual(@as(?u32, 0xff55), ks("page_up", true));
    try std.testing.expectEqual(@as(?u32, 0xffbe), ks("f1", true));
    try std.testing.expectEqual(@as(?u32, 0xffab), ks("kp_add", true));
    try std.testing.expectEqual(@as(?u32, 0xffad), ks("kp_SUBTRACT", true));
}