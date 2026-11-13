//! `--mode` and `--screen` parsing and lookup — kmscon parity
//! (kmscon-options.md §5.3/§5.4, kmscon `src/config.c:519-750`).
//!
//! Both options are repeatable lists. Grammar:
//!
//!   mode:   `gpu[connector]WxH[@rate]`, `[connector]WxH[@rate]`, `WxH[@rate]`
//!   screen: `gpu[connector]config`, `[connector]config`, `config`
//!           with config = normal|left|right|upside-down|disabled
//!
//! W and H must be non-zero; rate is optional (0 when absent); gpu and
//! connector names are limited to 63 characters (MAX_DISPLAY_NAME_LEN-1).
//! Lookup is three-tier, first match wins: (1) exact gpu+connector,
//! (2) connector only, (3) global (no gpu/connector). Unmatched displays
//! get the default mode (no match) / normal+enabled (screen).
//!
//! Deviation from kmscon's sscanf-based parser (documented in the module
//! report): trailing garbage after a valid value and negative numbers are
//! rejected here instead of silently ignored/wrapped.

const std = @import("std");
const diag_mod = @import("diag.zig");

pub const Error = diag_mod.Error;
pub const Diag = diag_mod.Diag;

/// kmscon MAX_DISPLAY_NAME_LEN (64) minus the NUL: the sscanf field width.
pub const max_name_len = 63;

pub const Mode = struct {
    gpu: []const u8 = "",
    connector: []const u8 = "",
    width: u32,
    height: u32,
    refresh_rate: u32 = 0,
};

pub const Orientation = enum {
    normal,
    left,
    right,
    upside_down,

    pub fn fromName(s: []const u8) ?Orientation {
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "upside-down")) return .upside_down;
        return null;
    }
};

pub const Screen = struct {
    gpu: []const u8 = "",
    connector: []const u8 = "",
    orientation: Orientation = .normal,
    enabled: bool = true,
};

/// Parse one `--mode` value. The three grammar forms are distinguished
/// structurally, equivalent to kmscon's three sscanf attempts in order.
pub fn parseMode(allocator: std.mem.Allocator, arg: []const u8, diag: *Diag) Error!Mode {
    var gpu: []const u8 = "";
    var connector: []const u8 = "";
    var dims = arg;

    if (std.mem.indexOfScalar(u8, arg, '[')) |open| {
        const close_rel = std.mem.indexOfScalar(u8, arg[open + 1 ..], ']') orelse {
            diag.print("missing ']' in mode '{s}'", .{arg});
            return error.InvalidValue;
        };
        const close = open + 1 + close_rel;
        if (open == 0) {
            connector = arg[1..close];
        } else {
            gpu = arg[0..open];
            connector = arg[open + 1 .. close];
        }
        dims = arg[close + 1 ..];
        if (gpu.len > max_name_len or connector.len == 0 or connector.len > max_name_len) {
            diag.print("invalid gpu/connector name in mode '{s}'", .{arg});
            return error.InvalidValue;
        }
    }

    const x = std.mem.indexOfScalar(u8, dims, 'x') orelse {
        diag.print("invalid mode '{s}'", .{arg});
        return error.InvalidValue;
    };
    const width = try parseNum(dims[0..x], arg, diag);
    var rest = dims[x + 1 ..];
    var rate: u32 = 0;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        rate = try parseNum(rest[at + 1 ..], arg, diag);
        rest = rest[0..at];
    }
    const height = try parseNum(rest, arg, diag);
    if (width == 0 or height == 0) {
        diag.print("mode '{s}' has zero width or height", .{arg});
        return error.InvalidValue;
    }

    return .{
        .gpu = try allocator.dupe(u8, gpu),
        .connector = try allocator.dupe(u8, connector),
        .width = width,
        .height = height,
        .refresh_rate = rate,
    };
}

/// Parse one `--screen` value.
pub fn parseScreen(allocator: std.mem.Allocator, arg: []const u8, diag: *Diag) Error!Screen {
    var gpu: []const u8 = "";
    var connector: []const u8 = "";
    var config = arg;

    if (arg.len > 0 and arg[0] == '[') {
        const close = std.mem.indexOfScalar(u8, arg, ']') orelse {
            diag.print("missing ']' in screen '{s}'", .{arg});
            return error.InvalidValue;
        };
        connector = arg[1..close];
        config = arg[close + 1 ..];
        if (connector.len == 0 or connector.len > max_name_len) {
            diag.print("invalid connector name in screen '{s}'", .{arg});
            return error.InvalidValue;
        }
    } else if (std.mem.indexOfScalar(u8, arg, '[')) |open| {
        const close_rel = std.mem.indexOfScalar(u8, arg[open + 1 ..], ']') orelse {
            diag.print("missing ']' in screen '{s}'", .{arg});
            return error.InvalidValue;
        };
        const close = open + 1 + close_rel;
        gpu = arg[0..open];
        connector = arg[open + 1 .. close];
        config = arg[close + 1 ..];
        if (gpu.len > max_name_len or connector.len == 0 or connector.len > max_name_len) {
            diag.print("invalid gpu/connector name in screen '{s}'", .{arg});
            return error.InvalidValue;
        }
    }

    var orientation: Orientation = .normal;
    var enabled = true;
    if (std.mem.eql(u8, config, "disabled")) {
        enabled = false;
    } else if (Orientation.fromName(config)) |o| {
        orientation = o;
    } else {
        diag.print("invalid screen config '{s}'", .{arg});
        return error.InvalidValue;
    }

    return .{
        .gpu = try allocator.dupe(u8, gpu),
        .connector = try allocator.dupe(u8, connector),
        .orientation = orientation,
        .enabled = enabled,
    };
}

/// Strict decimal unsigned integer (no sign, no trailing garbage).
fn parseNum(s: []const u8, arg: []const u8, diag: *Diag) Error!u32 {
    if (s.len == 0) {
        diag.print("invalid mode '{s}'", .{arg});
        return error.InvalidValue;
    }
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') {
            diag.print("invalid mode '{s}'", .{arg});
            return error.InvalidValue;
        }
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(u32)) {
            diag.print("mode '{s}' value out of range", .{arg});
            return error.InvalidValue;
        }
    }
    return @intCast(v);
}

/// kmscon `config_get_mode`: (1) gpu+connector, (2) connector only,
/// (3) global; first match within each tier wins. Null when nothing
/// matches (caller uses the default mode).
pub fn getMode(modes: []const Mode, gpu: []const u8, connector: []const u8) ?Mode {
    for (modes) |m| {
        if (m.gpu.len > 0 and std.mem.eql(u8, m.gpu, gpu) and
            m.connector.len > 0 and std.mem.eql(u8, m.connector, connector)) return m;
    }
    for (modes) |m| {
        if (m.gpu.len == 0 and m.connector.len > 0 and
            std.mem.eql(u8, m.connector, connector)) return m;
    }
    for (modes) |m| {
        if (m.gpu.len == 0 and m.connector.len == 0) return m;
    }
    return null;
}

/// kmscon `config_get_screen`: same three tiers; unmatched displays fall
/// back to normal orientation, enabled.
pub fn getScreen(screens: []const Screen, gpu: []const u8, connector: []const u8) Screen {
    for (screens) |s| {
        if (s.gpu.len > 0 and std.mem.eql(u8, s.gpu, gpu) and
            s.connector.len > 0 and std.mem.eql(u8, s.connector, connector)) return s;
    }
    for (screens) |s| {
        if (s.gpu.len == 0 and s.connector.len > 0 and
            std.mem.eql(u8, s.connector, connector)) return s;
    }
    for (screens) |s| {
        if (s.gpu.len == 0 and s.connector.len == 0) return s;
    }
    return .{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn modeOk(arg: []const u8) !Mode {
    var diag = Diag{};
    return parseMode(testing.allocator, arg, &diag) catch |err| {
        std.debug.print("parseMode '{s}' failed: {s}\n", .{ arg, diag.message() });
        return err;
    };
}

fn screenOk(arg: []const u8) !Screen {
    var diag = Diag{};
    return parseScreen(testing.allocator, arg, &diag) catch |err| {
        std.debug.print("parseScreen '{s}' failed: {s}\n", .{ arg, diag.message() });
        return err;
    };
}

test "mode grammar: all three forms, rate optional" {
    const m = try modeOk("card0[HDMI-A-1]1920x1080@60");
    defer testing.allocator.free(m.gpu);
    defer testing.allocator.free(m.connector);
    try testing.expectEqualStrings("card0", m.gpu);
    try testing.expectEqualStrings("HDMI-A-1", m.connector);
    try testing.expectEqual(@as(u32, 1920), m.width);
    try testing.expectEqual(@as(u32, 1080), m.height);
    try testing.expectEqual(@as(u32, 60), m.refresh_rate);

    const m2 = try modeOk("[DP-1]1280x720");
    defer testing.allocator.free(m2.gpu);
    defer testing.allocator.free(m2.connector);
    try testing.expectEqualStrings("", m2.gpu);
    try testing.expectEqualStrings("DP-1", m2.connector);
    try testing.expectEqual(@as(u32, 0), m2.refresh_rate);

    const m3 = try modeOk("800x600@75");
    defer testing.allocator.free(m3.gpu);
    defer testing.allocator.free(m3.connector);
    try testing.expectEqualStrings("", m3.gpu);
    try testing.expectEqualStrings("", m3.connector);
    try testing.expectEqual(@as(u32, 800), m3.width);
    try testing.expectEqual(@as(u32, 600), m3.height);
    try testing.expectEqual(@as(u32, 75), m3.refresh_rate);

    const m4 = try modeOk("1024x768");
    defer testing.allocator.free(m4.gpu);
    defer testing.allocator.free(m4.connector);
    try testing.expectEqual(@as(u32, 0), m4.refresh_rate);
}

test "mode rejects zero dimensions, bad syntax, overlong names" {
    var diag = Diag{};
    inline for (.{
        "0x1080@60",   "1920x0@60",  "0x0",      "1920",
        "1920x1080@",  "1920x1080x", "axb",      "1920x1080@60Hz",
        "card0[]1920x1080",          "[HDMI]1920x1080extra",
        "card0[HDMI]1920x-1",        "1920x1080@-60",
    }) |bad| {
        diag.reset();
        try testing.expectError(error.InvalidValue, parseMode(testing.allocator, bad, &diag));
    }
    // 63-char names are the limit (sscanf %63[^[]).
    const long63 = comptime blk: {
        var buf: [63]u8 = undefined;
        @memset(&buf, 'a');
        break :blk buf;
    };
    const long64 = comptime blk: {
        var buf: [64]u8 = undefined;
        @memset(&buf, 'a');
        break :blk buf;
    };
    const ok = try modeOk(long63 ++ "[HDMI]640x480");
    defer testing.allocator.free(ok.gpu);
    defer testing.allocator.free(ok.connector);
    try testing.expectEqual(@as(usize, 63), ok.gpu.len);
    try testing.expectError(error.InvalidValue, parseMode(testing.allocator, long64 ++ "[HDMI]640x480", &diag));
    try testing.expectError(error.InvalidValue, parseMode(testing.allocator, "[" ++ long64 ++ "]640x480", &diag));
}

test "screen grammar: orientations, disabled, all three forms" {
    const s = try screenOk("card0[DP-1]right");
    defer testing.allocator.free(s.gpu);
    defer testing.allocator.free(s.connector);
    try testing.expectEqualStrings("card0", s.gpu);
    try testing.expectEqualStrings("DP-1", s.connector);
    try testing.expectEqual(Orientation.right, s.orientation);
    try testing.expect(s.enabled);

    const s2 = try screenOk("[HDMI-A-1]left");
    defer testing.allocator.free(s2.gpu);
    defer testing.allocator.free(s2.connector);
    try testing.expectEqual(Orientation.left, s2.orientation);

    inline for (.{
        .{ "normal", Orientation.normal, true },
        .{ "left", Orientation.left, true },
        .{ "right", Orientation.right, true },
        .{ "upside-down", Orientation.upside_down, true },
        .{ "disabled", Orientation.normal, false },
    }) |case| {
        const s3 = try screenOk(case[0]);
        defer testing.allocator.free(s3.gpu);
        defer testing.allocator.free(s3.connector);
        try testing.expectEqual(case[1], s3.orientation);
        try testing.expectEqual(case[2], s3.enabled);
        try testing.expectEqualStrings("", s3.gpu);
        try testing.expectEqualStrings("", s3.connector);
    }
}

test "screen rejects unknown configs and empty connector" {
    var diag = Diag{};
    inline for (.{ "sideways", "card0[DP-1]rotated", "[]normal", "[DP-1]sideways", "", "card0[]right" }) |bad| {
        diag.reset();
        try testing.expectError(error.InvalidValue, parseScreen(testing.allocator, bad, &diag));
    }
}

test "mode lookup: three tiers, first match wins" {
    const modes = [_]Mode{
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width = 1, .height = 1 },
        .{ .connector = "HDMI-A-1", .width = 2, .height = 2 },
        .{ .width = 3, .height = 3 },
        .{ .gpu = "card0", .connector = "HDMI-A-1", .width = 4, .height = 4 },
        .{ .connector = "DP-1", .width = 5, .height = 5 },
    };
    // Tier 1 beats tier 2 and 3; first of two tier-1 entries wins.
    try testing.expectEqual(@as(u32, 1), getMode(&modes, "card0", "HDMI-A-1").?.width);
    // Tier 2 when gpu does not match.
    try testing.expectEqual(@as(u32, 2), getMode(&modes, "card1", "HDMI-A-1").?.width);
    // Tier 3 global fallback.
    try testing.expectEqual(@as(u32, 3), getMode(&modes, "card1", "DP-2").?.width);
    // Connector-only entry for DP-1 (tier 2).
    try testing.expectEqual(@as(u32, 5), getMode(&modes, "card9", "DP-1").?.width);
    // No match at all.
    try testing.expectEqual(@as(?Mode, null), getMode(&.{}, "card0", "HDMI-A-1"));
    const only_global = [_]Mode{.{ .width = 9, .height = 9 }};
    try testing.expectEqual(@as(u32, 9), getMode(&only_global, "any", "thing").?.width);
}

test "screen lookup: three tiers and normal/enabled fallback" {
    const screens = [_]Screen{
        .{ .gpu = "card0", .connector = "DP-1", .orientation = .right },
        .{ .connector = "DP-1", .orientation = .left },
        .{ .orientation = .upside_down, .enabled = false },
    };
    try testing.expectEqual(Orientation.right, getScreen(&screens, "card0", "DP-1").orientation);
    try testing.expectEqual(Orientation.left, getScreen(&screens, "card1", "DP-1").orientation);
    const global = getScreen(&screens, "card1", "HDMI-A-1");
    try testing.expectEqual(Orientation.upside_down, global.orientation);
    try testing.expect(!global.enabled);
    // Unmatched: normal + enabled.
    const fallback = getScreen(&.{}, "card0", "DP-1");
    try testing.expectEqual(Orientation.normal, fallback.orientation);
    try testing.expect(fallback.enabled);
}
