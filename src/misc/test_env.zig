//! Test-only environment resolution shared by `misc/pty.zig` and
//! `session/terminal.zig`.
//!
//! The unit suite spawns real shell children, so it must not hardcode
//! `/bin/sh` or FHS tool paths: in the default Nix sandbox `/bin/sh` is the
//! daemon's minimal busybox (no fractional `read -t`, no `read -N`) and the
//! runtime FHS directories are empty. The Nix unit derivation
//! (`nix/tests/unit.nix`) exports `KMSHAUNT_TEST_SH` and puts coreutils on
//! `PATH`, so the suite resolves both from the environment it inherits.
//!
//! Every returned slice lives in module-level storage and stays valid for the
//! rest of the process: callers never free anything. Each value is resolved on
//! first use and cached, which is sound because the Zig test runner executes
//! tests one at a time on a single thread.

const std = @import("std");
const linux = std.os.linux;

/// Path env used when the process environment carries no usable `PATH`; the
/// same directories the suite used to hardcode (correct on a NixOS host).
const fallback_path_env = "PATH=/run/current-system/sw/bin:/usr/bin:/bin";

/// `PATH` values longer than this fall back to `fallback_path_env`.
const path_env_max = 16 * 1024;

var shell_storage: [std.fs.max_path_bytes]u8 = undefined;
var shell_value: []const u8 = "";

var path_env_storage: [path_env_max]u8 = undefined;
var path_env_value: []const u8 = "";

/// Shell used to spawn test children: `KMSHAUNT_TEST_SH` when set and
/// non-empty, otherwise the first existing of `/bin/sh` and
/// `/run/current-system/sw/bin/sh`, otherwise `sh` resolved through `PATH`.
pub fn shell() []const u8 {
    if (shell_value.len == 0) shell_value = resolveShell();
    return shell_value;
}

/// `"PATH=..."` for the child environment: the process `PATH` when set and
/// non-empty, otherwise `/run/current-system/sw/bin:/usr/bin:/bin`.
pub fn pathEnv() []const u8 {
    if (path_env_value.len == 0) path_env_value = resolvePathEnv();
    return path_env_value;
}

/// Absolute path of `name`: searched in the directories of the process `PATH`
/// in order, then in `/run/current-system/sw/bin`, `/usr/bin` and `/bin`. Null
/// when no such entry exists.
///
/// Each distinct `name` gets its own cache slot, so two tools can be held at
/// the same time (the returned slice is never overwritten while the process
/// lives). The slots are keyed by the name at runtime on purpose: a static
/// `var` declared inside this generic function is shared by every
/// instantiation, which made the second tool resolve to the first one's path
/// (the pty controlling-tty test ran `stty -o tty= -p $$` because `ps`
/// answered the `stty` path).
pub fn tool(comptime name: []const u8) ?[]const u8 {
    for (&tool_slots) |*slot| {
        if (!std.mem.eql(u8, slot.name, name)) continue;
        if (!slot.resolved) {
            slot.value = resolveTool(name, &slot.storage);
            slot.resolved = true;
        }
        return slot.value;
    }
    // First request for this name: claim a free slot.
    for (&tool_slots) |*slot| {
        if (slot.name.len != 0) continue;
        slot.name = name;
        slot.value = resolveTool(name, &slot.storage);
        slot.resolved = true;
        return slot.value;
    }
    // More distinct tools than slots (never happens: the suite asks for
    // `stty` and `ps`): report "not found" rather than hand out a path
    // that another name owns.
    return null;
}

/// One resolved tool path. `value` points into `storage` and stays valid
/// for the rest of the process.
const ToolSlot = struct {
    name: []const u8 = "",
    storage: [std.fs.max_path_bytes]u8 = undefined,
    value: ?[]const u8 = null,
    resolved: bool = false,
};

const tool_slot_count = 8;

var tool_slots: [tool_slot_count]ToolSlot = .{
    .{}, .{}, .{}, .{},
    .{}, .{}, .{}, .{},
};

fn resolveShell() []const u8 {
    if (envValue("KMSHAUNT_TEST_SH")) |value| {
        if (value.len <= shell_storage.len) return copyTo(&shell_storage, value);
    }
    if (exists("/bin/sh")) return "/bin/sh";
    if (exists("/run/current-system/sw/bin/sh")) return "/run/current-system/sw/bin/sh";
    return "sh";
}

fn resolvePathEnv() []const u8 {
    const value = envValue("PATH") orelse return fallback_path_env;
    const len = "PATH=".len + value.len;
    if (len > path_env_storage.len) return fallback_path_env;
    @memcpy(path_env_storage[0.."PATH=".len], "PATH=");
    @memcpy(path_env_storage["PATH=".len..][0..value.len], value);
    return path_env_storage[0..len];
}

fn resolveTool(comptime name: []const u8, storage: []u8) ?[]const u8 {
    if (envValue("PATH")) |path| {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = joinZ(storage, dir, name) orelse continue;
            if (exists(candidate.ptr)) return candidate[0..candidate.len];
        }
    }
    for ([_][:0]const u8{ "/run/current-system/sw/bin", "/usr/bin", "/bin" }) |dir| {
        const candidate = joinZ(storage, dir, name) orelse continue;
        if (exists(candidate.ptr)) return candidate[0..candidate.len];
    }
    return null;
}

/// `dir ++ "/" ++ name`, NUL-terminated in `storage`; null when it does not
/// fit (a path that long cannot exist).
fn joinZ(storage: []u8, dir: []const u8, name: []const u8) ?[:0]u8 {
    const len = dir.len + 1 + name.len;
    if (len + 1 > storage.len) return null;
    @memcpy(storage[0..dir.len], dir);
    storage[dir.len] = '/';
    @memcpy(storage[dir.len + 1 ..][0..name.len], name);
    storage[len] = 0;
    return storage[0..len :0];
}

fn copyTo(storage: []u8, value: []const u8) []const u8 {
    const n = @min(storage.len, value.len);
    @memcpy(storage[0..n], value[0..n]);
    return storage[0..n];
}

fn envValue(name: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    const value = std.mem.span(raw);
    if (value.len == 0) return null;
    return value[0..value.len];
}

fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

const testing = std.testing;

test "tool keeps one path per name (regression: shared cache)" {
    // The pty controlling-tty test resolves `ps` after the resize test
    // resolved `stty`; a cache shared across instantiations handed the ps
    // test the stty path, so the child ran `stty -o tty= -p $$` and the
    // test failed with exit 1 instead of a pts/<N> reading.
    const stty = tool("stty") orelse return error.SkipZigTest;
    const ps = tool("ps") orelse return error.SkipZigTest;
    try testing.expect(std.mem.endsWith(u8, stty, "/stty"));
    try testing.expect(std.mem.endsWith(u8, ps, "/ps"));
    // Repeated requests keep returning the same per-name answers.
    try testing.expectEqualStrings(stty, tool("stty").?);
    try testing.expectEqualStrings(ps, tool("ps").?);
}