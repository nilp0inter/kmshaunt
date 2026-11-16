//! Grab (keyboard shortcut) parsing and matching — kmscon `--grab-*`
//! parity (kmscon-options.md §5.7, kmscon `src/misc/conf.c:838-1108`).
//!
//! Grammar: a comma-separated list of shortcuts; each shortcut is
//! `+`-joined tokens. Modifiers (`<Shift>`, `<Lock>`, `<Control>`/`<Ctrl>`,
//! `<Alt>`, `<Logo>`, case-insensitive) may appear only in the FIRST token;
//! the rest of that token and every later token are case-sensitive xkb
//! keysym names (see `keysyms.zig`). A multi-keysym shortcut like
//! `H+E+L+L+O` matches a key producing exactly that keysym sequence.
//!
//! Matching requires the event's 5-bit modifier mask (shift, lock/caps,
//! control, alt, logo) to EQUAL the grab's mask — any extra held modifier
//! of those five breaks the match — and the keysym sequence to match
//! exactly in count and value.
//!
//! An empty value, or a shortcut with no key (e.g. `<Ctrl>` alone),
//! contributes nothing; a grab with no shortcuts is disabled.

const std = @import("std");
const keysyms = @import("keysyms.zig");
const diag_mod = @import("diag.zig");

pub const Error = diag_mod.Error;
pub const Diag = diag_mod.Diag;

/// The five modifier bits, in kmscon `shl_xkb_mods` order
/// (`src/shl/misc.h:509-515`).
pub const shift: u5 = 1 << 0;
pub const lock: u5 = 1 << 1;
pub const control: u5 = 1 << 2;
pub const alt: u5 = 1 << 3;
pub const logo: u5 = 1 << 4;

/// One shortcut: an exact modifier mask plus the keysym sequence a key
/// must produce. An empty `keysyms` matches any key event with equal mods
/// (kmscon `grab_matches` when `grab_num_syms == 0`); the parser never
/// produces such shortcuts, but the match rule is kept for parity.
pub const Shortcut = struct {
    mods: u5 = 0,
    keysyms: []const u32 = &.{},
};

pub const Grab = struct {
    shortcuts: []const Shortcut = &.{},

    /// kmscon `conf_grab_matches`: exact modifier equality, then exact
    /// keysym-sequence equality, for any of the shortcuts.
    pub fn matches(self: Grab, ev_mods: u5, ev_syms: []const u32) bool {
        for (self.shortcuts) |s| {
            if (s.mods != ev_mods) continue;
            if (s.keysyms.len == 0) return true;
            if (std.mem.eql(u32, s.keysyms, ev_syms)) return true;
        }
        return false;
    }

    /// Parse a `--grab-*` value. Empty input yields a disabled grab.
    /// On failure the `Diag` names the problem (invalid modifier, missing
    /// `>`, invalid keysym with a case suggestion).
    pub fn parse(allocator: std.mem.Allocator, arg: []const u8, diag: *Diag) Error!Grab {
        var shortcuts: std.ArrayList(Shortcut) = .empty;
        errdefer shortcuts.deinit(allocator);

        // Comma-separated shortcuts; empty entries are dropped
        // (shl_split_string with keep_empty=false).
        var list = std.mem.splitScalar(u8, arg, ',');
        while (list.next()) |part| {
            if (part.len == 0) continue;

            var syms: std.ArrayList(u32) = .empty;
            errdefer syms.deinit(allocator);
            var mods: u5 = 0;

            var tokens = std.mem.splitScalar(u8, part, '+');
            var j: usize = 0;
            while (tokens.next()) |token| : (j += 1) {
                if (token.len == 0) continue;
                if (try parseSingle(token, j == 0, &mods, diag)) |sym| {
                    try syms.append(allocator, sym);
                }
            }

            // No key in this shortcut (empty or modifiers-only): skipped.
            if (syms.items.len == 0) {
                syms.deinit(allocator);
                continue;
            }
            try shortcuts.append(allocator, .{
                .mods = mods,
                .keysyms = try syms.toOwnedSlice(allocator),
            });
        }

        return .{ .shortcuts = try shortcuts.toOwnedSlice(allocator) };
    }

    /// Release a grab returned by `parse`. Must NOT be called on the
    /// comptime `defaults` (their storage is static).
    pub fn deinit(self: *Grab, allocator: std.mem.Allocator) void {
        for (self.shortcuts) |s| allocator.free(s.keysyms);
        allocator.free(self.shortcuts);
        self.* = .{};
    }
};

/// kmscon `parse_single_grab`: optional leading `<mod>` tokens (first
/// '+'-token only), then the remainder is one keysym name. Spaces around
/// modifiers and before the key are skipped; the key name itself keeps
/// any interior/trailing spaces (which then fail the keysym lookup,
/// exactly as in kmscon). Returns null when the token has no key.
fn parseSingle(token: []const u8, allow_mods: bool, mods: *u5, diag: *Diag) Error!?u32 {
    var i: usize = 0;
    while (i < token.len and token[i] == ' ') : (i += 1) {}

    if (allow_mods) {
        while (i < token.len and token[i] == '<') {
            const start = i + 1;
            var end = start;
            while (end < token.len and token[end] != '>') : (end += 1) {}
            if (end == token.len) {
                diag.print("missing '>' near '{s}'", .{token[i..]});
                return error.InvalidValue;
            }
            const m = token[start..end];
            if (std.ascii.eqlIgnoreCase(m, "shift")) {
                mods.* |= shift;
            } else if (std.ascii.eqlIgnoreCase(m, "lock")) {
                mods.* |= lock;
            } else if (std.ascii.eqlIgnoreCase(m, "control") or std.ascii.eqlIgnoreCase(m, "ctrl")) {
                mods.* |= control;
            } else if (std.ascii.eqlIgnoreCase(m, "alt")) {
                mods.* |= alt;
            } else if (std.ascii.eqlIgnoreCase(m, "logo")) {
                mods.* |= logo;
            } else {
                diag.print("invalid modifier '{s}'", .{m});
                return error.InvalidValue;
            }
            i = end + 1;
            while (i < token.len and token[i] == ' ') : (i += 1) {}
        }
    }

    while (i < token.len and token[i] == ' ') : (i += 1) {}
    const name = token[i..];
    if (name.len == 0) return null;

    if (keysyms.fromName(name)) |v| return v;
    if (keysyms.suggestion(name)) |sugg| {
        diag.print(
            "invalid keysym '{s}', did you mean '{s}'? (keysyms are case-sensitive)",
            .{ name, sugg },
        );
        return error.InvalidValue;
    }
    diag.print("invalid key '{s}'", .{name});
    return error.InvalidValue;
}

/// Source-of-truth default bindings (kmscon `src/config.c:915-943`,
/// kmscon-options.md §5.7). `grab-reboot` has no default (disabled).
pub const defaults = struct {
    const up = keysyms.fromName("Up").?;
    const down = keysyms.fromName("Down").?;
    const prior = keysyms.fromName("Prior").?;
    const next = keysyms.fromName("Next").?;
    const plus = keysyms.fromName("plus").?;
    const equal = keysyms.fromName("equal").?;
    const minus = keysyms.fromName("minus").?;
    const zero = keysyms.fromName("0").?;
    const right = keysyms.fromName("Right").?;
    const left = keysyms.fromName("Left").?;
    const backspace = keysyms.fromName("BackSpace").?;
    const ret = keysyms.fromName("Return").?;

    pub const scroll_up: Grab = .{ .shortcuts = &.{.{ .mods = shift, .keysyms = &.{up} }} };
    pub const scroll_down: Grab = .{ .shortcuts = &.{.{ .mods = shift, .keysyms = &.{down} }} };
    pub const page_up: Grab = .{ .shortcuts = &.{.{ .mods = shift, .keysyms = &.{prior} }} };
    pub const page_down: Grab = .{ .shortcuts = &.{.{ .mods = shift, .keysyms = &.{next} }} };
    /// Ctrl+plus AND Ctrl+equal (two-keysym grab).
    pub const zoom_in: Grab = .{ .shortcuts = &.{
        .{ .mods = control, .keysyms = &.{plus} },
        .{ .mods = control, .keysyms = &.{equal} },
    } };
    pub const zoom_out: Grab = .{ .shortcuts = &.{.{ .mods = control, .keysyms = &.{minus} }} };
    /// Ctrl+0: restore the configured font size (ghostty reset_font_size;
    /// kmscon has no reset grab, this is a ghostty-parity extension).
    pub const zoom_reset: Grab = .{ .shortcuts = &.{.{ .mods = control, .keysyms = &.{zero} }} };
    pub const session_next: Grab = .{ .shortcuts = &.{.{ .mods = control | logo, .keysyms = &.{right} }} };
    pub const session_prev: Grab = .{ .shortcuts = &.{.{ .mods = control | logo, .keysyms = &.{left} }} };
    pub const session_close: Grab = .{ .shortcuts = &.{.{ .mods = control | logo, .keysyms = &.{backspace} }} };
    pub const terminal_new: Grab = .{ .shortcuts = &.{.{ .mods = control | logo, .keysyms = &.{ret} }} };
    /// Logo+plus AND Logo+equal (two-keysym grab).
    pub const rotate_cw: Grab = .{ .shortcuts = &.{
        .{ .mods = logo, .keysyms = &.{plus} },
        .{ .mods = logo, .keysyms = &.{equal} },
    } };
    pub const rotate_ccw: Grab = .{ .shortcuts = &.{.{ .mods = logo, .keysyms = &.{minus} }} };
    /// No default binding — disabled unless configured.
    pub const reboot: Grab = .{};
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseOk(arg: []const u8) !Grab {
    var diag = Diag{};
    return Grab.parse(testing.allocator, arg, &diag) catch |err| {
        std.debug.print("parse '{s}' failed: {s}\n", .{ arg, diag.message() });
        return err;
    };
}

test "default bindings match the kmscon source table" {
    const d = defaults;
    try testing.expectEqual(@as(usize, 1), d.scroll_up.shortcuts.len);
    try testing.expectEqual(shift, d.scroll_up.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0xff52}, d.scroll_up.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0xff54}, d.scroll_down.shortcuts[0].keysyms);
    try testing.expectEqual(shift, d.scroll_down.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0xff55}, d.page_up.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0xff56}, d.page_down.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0x2d}, d.zoom_out.shortcuts[0].keysyms);
    try testing.expectEqual(control, d.zoom_out.shortcuts[0].mods);
    try testing.expectEqual(control | logo, d.session_next.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0xff53}, d.session_next.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0xff51}, d.session_prev.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0xff08}, d.session_close.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0xff0d}, d.terminal_new.shortcuts[0].keysyms);
    try testing.expectEqualSlices(u32, &.{0x2d}, d.rotate_ccw.shortcuts[0].keysyms);
    try testing.expectEqual(logo, d.rotate_ccw.shortcuts[0].mods);
    try testing.expectEqual(@as(usize, 0), d.reboot.shortcuts.len);
}

test "dual-keysym defaults: zoom-in and rotate-cw match plus AND equal" {
    const plus: u32 = 0x2b;
    const equal: u32 = 0x3d;
    try testing.expectEqual(@as(usize, 2), defaults.zoom_in.shortcuts.len);
    try testing.expect(defaults.zoom_in.matches(control, &.{plus}));
    try testing.expect(defaults.zoom_in.matches(control, &.{equal}));
    try testing.expect(!defaults.zoom_in.matches(control | shift, &.{plus}));
    try testing.expect(!defaults.zoom_in.matches(0, &.{plus}));
    try testing.expectEqual(@as(usize, 2), defaults.rotate_cw.shortcuts.len);
    try testing.expect(defaults.rotate_cw.matches(logo, &.{plus}));
    try testing.expect(defaults.rotate_cw.matches(logo, &.{equal}));
    try testing.expect(!defaults.rotate_cw.matches(logo | alt, &.{equal}));
    try testing.expect(!defaults.rotate_cw.matches(control, &.{plus}));
}

test "zoom-reset default: Ctrl+0 (ghostty reset_font_size)" {
    try testing.expectEqual(@as(usize, 1), defaults.zoom_reset.shortcuts.len);
    try testing.expectEqual(control, defaults.zoom_reset.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0x30}, defaults.zoom_reset.shortcuts[0].keysyms);
    try testing.expect(defaults.zoom_reset.matches(control, &.{0x30}));
    try testing.expect(!defaults.zoom_reset.matches(control | shift, &.{0x30}));
}

test "grab grammar: modifiers and keysym" {
    var g = try parseOk("<Ctrl><Alt>F1");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.shortcuts.len);
    try testing.expectEqual(control | alt, g.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0xffbe}, g.shortcuts[0].keysyms);
    try testing.expect(g.matches(control | alt, &.{0xffbe}));
}

test "modifiers are case-insensitive, ctrl/control alias, spaces allowed" {
    var g = try parseOk("<SHIFT><cTrL> <Logo>A");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(shift | control | logo, g.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0x41}, g.shortcuts[0].keysyms);

    var g2 = try parseOk("<control>x");
    defer g2.deinit(testing.allocator);
    try testing.expectEqual(control, g2.shortcuts[0].mods);

    var g3 = try parseOk("<Lock><Alt>Delete");
    defer g3.deinit(testing.allocator);
    try testing.expectEqual(lock | alt, g3.shortcuts[0].mods);
    try testing.expectEqualSlices(u32, &.{0xffff}, g3.shortcuts[0].keysyms);
}

test "unknown modifier is an error naming it" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "<Hyper>A", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid modifier 'Hyper'") != null);
}

test "missing '>' is an error" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "<CtrlA", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "missing '>'") != null);
}

test "modifiers only allowed in the first +-token" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "A+<Ctrl>B", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid key '<Ctrl>B'") != null);
}

test "keysyms are case-sensitive; wrong case suggests the canonical name" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "<Shift>up", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "did you mean 'Up'?") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "case-sensitive") != null);

    var diag2 = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "NotAKey", &diag2));
    try testing.expect(std.mem.indexOf(u8, diag2.message(), "invalid key 'NotAKey'") != null);
}

test "multi-keysym shortcut matches the exact keysym sequence" {
    var g = try parseOk("<Shift>H+E+L+L+O");
    defer g.deinit(testing.allocator);
    const hello = [_]u32{ 'H', 'E', 'L', 'L', 'O' };
    try testing.expectEqualSlices(u32, &hello, g.shortcuts[0].keysyms);
    try testing.expect(g.matches(shift, &hello));
    try testing.expect(!g.matches(shift, &.{ 'H', 'E', 'L', 'L' }));
    try testing.expect(!g.matches(shift, &.{ 'H', 'E', 'L', 'O' }));
    try testing.expect(!g.matches(0, &hello));
}

test "comma list builds several shortcuts for one action" {
    var g = try parseOk("<Shift>Up,<Ctrl>u");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.shortcuts.len);
    try testing.expect(g.matches(shift, &.{0xff52}));
    try testing.expect(g.matches(control, &.{'u'}));
    try testing.expect(!g.matches(control, &.{0xff52}));
}

test "empty value and modifiers-only shortcuts disable the grab" {
    inline for (.{ "", ",", "<Ctrl>", "<Ctrl>+", "+", "<Ctrl>,<Alt>" }) |arg| {
        var g = try parseOk(arg);
        defer g.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), g.shortcuts.len);
        try testing.expect(!g.matches(0, &.{}));
        try testing.expect(!g.matches(control, &.{0x41}));
    }
    // A disabled shortcut among valid ones is dropped, the rest kept.
    var g = try parseOk("<Ctrl>,<Shift>Up");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.shortcuts.len);
    try testing.expect(g.matches(shift, &.{0xff52}));
}

test "modifier mask must match exactly (all five bits)" {
    var g = try parseOk("<Ctrl><Logo>Right");
    defer g.deinit(testing.allocator);
    const right: u32 = 0xff53;
    try testing.expect(g.matches(control | logo, &.{right}));
    // Any extra modifier of the five breaks the match.
    try testing.expect(!g.matches(control | logo | shift, &.{right}));
    try testing.expect(!g.matches(control | logo | lock, &.{right}));
    try testing.expect(!g.matches(control | logo | alt, &.{right}));
    // Missing modifiers break it too.
    try testing.expect(!g.matches(control, &.{right}));
    try testing.expect(!g.matches(logo, &.{right}));
    try testing.expect(!g.matches(0, &.{right}));
    // Keysym must match exactly.
    try testing.expect(!g.matches(control | logo, &.{0xff51}));
    try testing.expect(!g.matches(control | logo, &.{ right, right }));
    try testing.expect(!g.matches(control | logo, &.{}));
}

test "trailing space in the key name is kept and fails (kmscon quirk)" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, Grab.parse(testing.allocator, "<Ctrl>F1 ", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid key 'F1 '") != null);
    // Leading spaces before modifiers/key are skipped.
    var g = try parseOk("  <Ctrl>  F1");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches(control, &.{0xffbe}));
}
