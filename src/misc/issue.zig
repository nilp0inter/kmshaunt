//! agetty-style `/etc/issue` collection and escape expansion (ROADMAP M2.4).
//!
//! kmscon reads `--issue-path` (a colon-separated list of files and
//! directories, directories scanned for `*.issue` in lexicographic order),
//! concatenates the result with a 256 KiB cap, masks files whose basename was
//! already read, and expands backslash escapes before writing the text to the
//! pty. This module mirrors `src/misc/issue.c` in kmscon 10.1.0.
//!
//! Escape semantics:
//!
//! | Escape       | Expansion                                                  |
//! |--------------|------------------------------------------------------------|
//! | `\\`         | literal backslash                                           |
//! | `\s`         | `uname().sysname`                                           |
//! | `\n`         | `uname().nodename` (not a newline)                          |
//! | `\r`         | `uname().release`                                           |
//! | `\v`         | `uname().version`                                           |
//! | `\m`         | `uname().machine`                                           |
//! | `\o`         | `uname().domainname`, or `(none)` when empty                |
//! | `\d`         | local date, `%Y-%m-%d`                                      |
//! | `\t`         | local time, `%H:%M:%S`                                      |
//! | `\l`         | pty/slave tty name                                          |
//! | `\S{field}`  | os-release field; bare `\S` means `PRETTY_NAME`             |
//! | `\e{name}`   | `ESC` followed by the SGR sequence for `name`               |
//! | `\4{iface}`  | best IPv4 address of `iface` (all interfaces when bare)     |
//! | `\6{iface}`  | best IPv6 address of `iface` (all interfaces when bare)     |
//! | `\a`         | all filtered local IPv4 addresses, by interface             |
//! | `\A`         | all local addresses (IPv4 and IPv6), unfiltered             |
//! | anything else| dropped silently                                            |
//!
//! Literal newlines in the collected text become `\r\n`; a trailing lone
//! backslash is dropped. Parameter text runs to the closing `}` (or to the end
//! of the text when the brace is missing), matching kmscon's `get_parameter`.
//!
//! All operating-system lookups live behind [`IssueContext`]:
//! [`systemContext`] performs the real `uname(2)`, `/etc/os-release`,
//! `/etc/localtime`, wall clock and rtnetlink address queries; a hand-built
//! context is fully hermetic and drives the unit tests.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux)
        @compileError("src/misc/issue.zig is Linux-only");
}

const native_endian = builtin.cpu.arch.endian();

/// Total amount of raw issue text collected from `issue-path`.
pub const max_issue_size = 256 * 1024;

/// kmscon's `ISSUE_DEFAULT_PATH` (`src/misc/issue.h`).
pub const default_issue_path =
    "/etc/issue:/etc/issue.d:/run/issue:/run/issue.d:/usr/lib/issue:/usr/lib/issue.d";

/// Maximum number of basenames kmscon records for masking (`MAX_FILES`).
const max_masked_files = 64;

/// `struct utsname` fields as reported by `\s \n \r \v \m \o`.
pub const Uts = struct {
    sysname: []const u8 = "",
    nodename: []const u8 = "",
    release: []const u8 = "",
    version: []const u8 = "",
    machine: []const u8 = "",
    domainname: []const u8 = "",
};

pub const AddressFamily = enum { ipv4, ipv6 };

/// Linux `RT_SCOPE_*` values carried by rtnetlink address messages.
pub const Scope = enum(u8) {
    universe = 0,
    site = 200,
    link = 253,
    host = 254,
    nowhere = 255,
    _,
};

/// `IFA_F_TEMPORARY` (alias of `IFA_F_SECONDARY`) from `linux/if_addr.h`.
pub const ifa_f_temporary: u32 = 0x01;

/// One address in the book used by `\4`, `\6`, `\a` and `\A`.
pub const Address = struct {
    interface: []const u8,
    address: []const u8,
    family: AddressFamily,
    scope: Scope = .universe,
    /// `IFA_FLAGS`; only [`ifa_f_temporary`] is interpreted.
    flags: u32 = 0,
    /// `ifa_cacheinfo.ifa_valid`, used to break quality ties.
    valid: u32 = 0,
};

/// One pre-parsed os-release entry.
pub const OsReleaseField = struct {
    name: []const u8,
    value: []const u8,
};

/// Where `\S` gets its field values from.
pub const OsRelease = union(enum) {
    /// No os-release: all fields expand to nothing.
    none,
    /// Raw `/etc/os-release` style contents, parsed with kmscon's line rules.
    content: []const u8,
    /// Pre-parsed fields; compared by exact `name`.
    fields: []const OsReleaseField,
};

/// Function-pointer environment lookup.
pub const EnvCallback = struct {
    context: ?*anyopaque = null,
    get: *const fn (?*anyopaque, key: []const u8) ?[]const u8,
};

/// Environment accessor carried by the context. No issue escape consumes it
/// yet; it exists so callers can build a context once and share it with the
/// code that will need logind/TERM state.
pub const Env = union(enum) {
    none,
    map: *const std.StringHashMapUnmanaged([]const u8),
    callback: EnvCallback,

    pub fn lookup(self: Env, key: []const u8) ?[]const u8 {
        return switch (self) {
            .none => null,
            .map => |map| map.get(key),
            .callback => |callback| callback.get(callback.context, key),
        };
    }
};

/// Injectable clock. `utc_offset_seconds` is added to `unix_seconds` before
/// formatting, exactly as `localtime(3)` would apply the local zone.
pub const Instant = struct {
    unix_seconds: i64 = 0,
    utc_offset_seconds: i32 = 0,
};

/// Everything the expansion needs. The default value is hermetic: no uname,
/// no os-release, no addresses and the Unix epoch.
pub const IssueContext = struct {
    uts: Uts = .{},
    /// Slave tty name for `\l`, e.g. `tty1` or `pts/3`.
    tty_name: []const u8 = "",
    os_release: OsRelease = .none,
    env: Env = .none,
    now: Instant = .{},
    addresses: []const Address = &.{},
};

// ---------------------------------------------------------------------------
// Escape expansion
// ---------------------------------------------------------------------------

/// Expand all escapes in `raw`, converting literal newlines to CRLF.
///
/// Returns an allocated buffer, even when nothing is produced. Caller frees
/// with the same allocator.
pub fn expand(
    allocator: std.mem.Allocator,
    raw: []const u8,
    ctx: *const IssueContext,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // kmscon normalises RAT_UNIVERSE to RAT_SITE before filtering \a.
    var best_quality: u8 = 0;
    for (ctx.addresses) |address| {
        best_quality = @max(best_quality, @intFromEnum(rating(address)));
    }
    if (best_quality == @intFromEnum(Rating.universe))
        best_quality = @intFromEnum(Rating.site);

    var pos: usize = 0;
    while (pos < raw.len) {
        const relative = std.mem.indexOfScalar(u8, raw[pos..], '\\') orelse {
            try writeLiteral(allocator, &out, raw[pos..]);
            break;
        };
        const escape = pos + relative;
        try writeLiteral(allocator, &out, raw[pos..escape]);

        pos = escape + 1;
        if (pos >= raw.len) break; // trailing backslash is dropped
        const code = raw[pos];
        pos += 1;

        switch (code) {
            '\\' => try out.append(allocator, '\\'),
            's' => try out.appendSlice(allocator, ctx.uts.sysname),
            'n' => try out.appendSlice(allocator, ctx.uts.nodename),
            'r' => try out.appendSlice(allocator, ctx.uts.release),
            'v' => try out.appendSlice(allocator, ctx.uts.version),
            'm' => try out.appendSlice(allocator, ctx.uts.machine),
            'o' => {
                if (ctx.uts.domainname.len == 0) {
                    try out.appendSlice(allocator, "(none)");
                } else {
                    try out.appendSlice(allocator, ctx.uts.domainname);
                }
            },
            'd' => {
                const civil = civilTime(ctx.now);
                // Format the magnitude as unsigned; a signed `{d:0>4}` would
                // emit a leading '+' for positive years.
                if (civil.year < 0) try out.append(allocator, '-');
                try out.print(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                    @abs(civil.year),
                    civil.month,
                    civil.day,
                });
            },
            't' => {
                const civil = civilTime(ctx.now);
                try out.print(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{
                    civil.hour,
                    civil.minute,
                    civil.second,
                });
            },
            'l' => try out.appendSlice(allocator, ctx.tty_name),
            'S' => {
                var buffer: [64]u8 = undefined;
                const field_param = getParameter(raw, &pos, &buffer);
                const field = field_param orelse "PRETTY_NAME";
                if (osReleaseLookup(ctx.os_release, field)) |value| {
                    try out.appendSlice(allocator, value);
                }
            },
            'e' => {
                // kmscon writes ESC unconditionally, before parsing a name.
                try out.append(allocator, 0x1b);
                var buffer: [16]u8 = undefined;
                const name = getParameter(raw, &pos, &buffer) orelse continue;
                if (colorSequence(name)) |sequence| {
                    try out.appendSlice(allocator, sequence);
                }
            },
            '4', '6' => {
                var buffer: [16]u8 = undefined;
                const interface = getParameter(raw, &pos, &buffer);
                const family: AddressFamily = if (code == '4') .ipv4 else .ipv6;
                if (bestAddress(ctx.addresses, interface orelse "", family)) |address| {
                    try out.appendSlice(allocator, address);
                }
            },
            'a' => {
                // kmscon does not parse a parameter for \a/\A.
                try appendAllAddresses(allocator, &out, ctx.addresses, best_quality, true, false);
            },
            'A' => {
                try appendAllAddresses(allocator, &out, ctx.addresses, best_quality, false, true);
            },
            else => {}, // unknown escapes are dropped silently
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Write literal text, translating each `\n` into `\r\n`.
fn writeLiteral(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) std.mem.Allocator.Error!void {
    var start: usize = 0;
    while (std.mem.indexOfScalar(u8, text[start..], '\n')) |relative| {
        const newline = start + relative;
        try out.appendSlice(allocator, text[start..newline]);
        try out.appendSlice(allocator, "\r\n");
        start = newline + 1;
    }
    try out.appendSlice(allocator, text[start..]);
}

/// kmscon's `get_parameter`: read `{...}` into `buffer`, truncating at
/// `buffer.len - 1` bytes while still consuming the whole parameter.
///
/// Returns `null` when `raw[pos]` is not `{` (position unchanged). A missing
/// closing brace consumes the rest of the text and still returns the value.
fn getParameter(raw: []const u8, pos: *usize, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0) return null;
    var index = pos.*;
    if (index >= raw.len or raw[index] != '{') return null;
    index += 1;

    var length: usize = 0;
    while (index < raw.len and raw[index] != '}') : (index += 1) {
        if (length < buffer.len - 1) {
            buffer[length] = raw[index];
            length += 1;
        }
    }
    if (index < raw.len) index += 1; // consume '}'
    pos.* = index;
    return buffer[0..length];
}

// ---------------------------------------------------------------------------
// os-release
// ---------------------------------------------------------------------------

const os_release_line_size = 512;

/// Look up a field, honouring the context's os-release source.
fn osReleaseLookup(source: OsRelease, field: []const u8) ?[]const u8 {
    return switch (source) {
        .none => null,
        .content => |content| parseOsRelease(content, field),
        .fields => |fields| blk: {
            for (fields) |entry| {
                if (std.mem.eql(u8, entry.name, field)) break :blk entry.value;
            }
            break :blk null;
        },
    };
}

/// `read_os_release_field` from kmscon: `fgets` chunks of at most 511 bytes,
/// exact name match at the start of a chunk, one trailing newline stripped and
/// double quotes removed when they enclose the whole value.
fn parseOsRelease(content: []const u8, field: []const u8) ?[]const u8 {
    if (field.len >= os_release_line_size) return null;

    var pos: usize = 0;
    while (pos < content.len) {
        var end = @min(pos + (os_release_line_size - 1), content.len);
        if (std.mem.indexOfScalar(u8, content[pos..end], '\n')) |relative| {
            end = pos + relative + 1;
        }
        const line = content[pos..end];

        if (line.len > field.len and
            std.mem.eql(u8, line[0..field.len], field) and
            line[field.len] == '=')
        {
            var value = line[field.len + 1 ..];
            if (value.len > 0 and value[value.len - 1] == '\n')
                value = value[0 .. value.len - 1];
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
                value = value[1 .. value.len - 1];
            return value;
        }
        pos = end;
    }
    return null;
}

// ---------------------------------------------------------------------------
// SGR colour names
// ---------------------------------------------------------------------------

const ColorName = struct {
    name: []const u8,
    sequence: []const u8,
};

/// `color_sequence_from_colorname` in kmscon, including its quirks:
/// `lightgray` produces `[37m`, `underscore` does not exist.
const color_names = [_]ColorName{
    .{ .name = "black", .sequence = "[30m" },
    .{ .name = "blink", .sequence = "[5m" },
    .{ .name = "blue", .sequence = "[34m" },
    .{ .name = "bold", .sequence = "[1m" },
    .{ .name = "brown", .sequence = "[33m" },
    .{ .name = "cyan", .sequence = "[36m" },
    .{ .name = "darkgray", .sequence = "[1;30m" },
    .{ .name = "gray", .sequence = "[37m" },
    .{ .name = "green", .sequence = "[32m" },
    .{ .name = "halfbright", .sequence = "[2m" },
    .{ .name = "lightblue", .sequence = "[1;34m" },
    .{ .name = "lightcyan", .sequence = "[1;36m" },
    .{ .name = "lightgray", .sequence = "[37m" },
    .{ .name = "lightgreen", .sequence = "[1;32m" },
    .{ .name = "lightmagenta", .sequence = "[1;35m" },
    .{ .name = "lightred", .sequence = "[1;31m" },
    .{ .name = "magenta", .sequence = "[35m" },
    .{ .name = "red", .sequence = "[31m" },
    .{ .name = "reset", .sequence = "[0m" },
    .{ .name = "reverse", .sequence = "[7m" },
    .{ .name = "white", .sequence = "[1;37m" },
    .{ .name = "yellow", .sequence = "[1;33m" },
};

/// SGR sequence (without the leading ESC) for a colour name, or `null`.
pub fn colorSequence(name: []const u8) ?[]const u8 {
    for (color_names) |color| {
        if (std.mem.eql(u8, color.name, name)) return color.sequence;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Address selection
// ---------------------------------------------------------------------------

const Rating = enum(u8) {
    bad = 0,
    link = 1,
    temporary = 2,
    site = 3,
    universe = 4,
};

fn scopeRating(scope: Scope) Rating {
    return switch (scope) {
        .universe => .universe,
        .site => .site,
        .link => .link,
        else => .bad, // HOST/NOWHERE/unknown
    };
}

fn rating(address: Address) Rating {
    const base = scopeRating(address.scope);
    if (address.flags & ifa_f_temporary != 0 and
        @intFromEnum(base) >= @intFromEnum(Rating.temporary))
    {
        return .temporary;
    }
    return base;
}

/// `issue_network_get_best_ip`: highest quality wins; on a quality tie the
/// larger `valid` lifetime wins; on a complete tie the later address wins.
fn bestAddress(
    addresses: []const Address,
    interface: []const u8,
    family: AddressFamily,
) ?[]const u8 {
    var best: ?*const Address = null;
    for (addresses) |*address| {
        if (address.family != family) continue;
        if (interface.len != 0 and !std.mem.eql(u8, address.interface, interface))
            continue;
        if (best) |current| {
            const current_quality = @intFromEnum(rating(current.*));
            const candidate_quality = @intFromEnum(rating(address.*));
            if (current_quality > candidate_quality) continue;
            if (current_quality == candidate_quality and current.valid > address.valid)
                continue;
        }
        best = address;
    }
    return if (best) |address| address.address else null;
}

const AddressGroup = struct {
    interface: []const u8,
    addresses: std.ArrayList([]const u8),
};

/// kmscon's `issue_network_get_all_ip`, rendered as
/// `iface: addr addr \r\n` lines. `\a` passes `filter = true` and only the
/// IPv4 family (per the documented escape table); `\A` passes
/// `filter = false` and both families.
fn appendAllAddresses(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    addresses: []const Address,
    best_quality: u8,
    filter: bool,
    include_ipv6: bool,
) std.mem.Allocator.Error!void {
    var groups: std.ArrayList(AddressGroup) = .empty;
    defer {
        for (groups.items) |*group| group.addresses.deinit(allocator);
        groups.deinit(allocator);
    }

    const passes: usize = if (include_ipv6) 2 else 1;
    var pass: usize = 0;
    while (pass < passes) : (pass += 1) {
        const family: AddressFamily = if (pass == 0) .ipv4 else .ipv6;
        for (addresses) |address| {
            if (address.family != family) continue;
            if (filter and @intFromEnum(rating(address)) < best_quality) continue;

            var group_index: ?usize = null;
            for (groups.items, 0..) |group, index| {
                if (std.mem.eql(u8, group.interface, address.interface)) {
                    group_index = index;
                    break;
                }
            }
            if (group_index == null) {
                try groups.append(allocator, .{
                    .interface = address.interface,
                    .addresses = .empty,
                });
                group_index = groups.items.len - 1;
            }
            const group = &groups.items[group_index.?];
            if (group.addresses.items.len >= 32) continue;
            try group.addresses.append(allocator, address.address);
        }
    }

    for (groups.items) |group| {
        try out.appendSlice(allocator, group.interface);
        try out.appendSlice(allocator, ": ");
        for (group.addresses.items) |address| {
            try out.appendSlice(allocator, address);
            try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, "\r\n");
    }
}

// ---------------------------------------------------------------------------
// Calendar formatting
// ---------------------------------------------------------------------------

const CivilTime = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// Local civil time for `instant`, equivalent to `localtime(3)` followed by
/// `strftime("%Y-%m-%d")` / `strftime("%H:%M:%S")`.
fn civilTime(instant: Instant) CivilTime {
    const local = instant.unix_seconds + @as(i64, instant.utc_offset_seconds);
    const days = @divFloor(local, 86400);
    const seconds = local - days * 86400;
    const date = civilFromDays(days);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(@divTrunc(seconds, 3600)),
        .minute = @intCast(@divTrunc(@mod(seconds, 3600), 60)),
        .second = @intCast(@mod(seconds, 60)),
    };
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

/// Howard Hinnant's `civil_from_days`, valid for negative day counts too.
fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    const year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{
        .year = year + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

// ---------------------------------------------------------------------------
// Issue file collection
// ---------------------------------------------------------------------------

/// Read one issue file, capping the result at `max_issue_size` bytes.
/// Unreadable paths yield `null`, mirroring kmscon's silent skipping.
pub fn readIssueFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    return readFileCapped(allocator, io, path, max_issue_size);
}

/// Collect issue text from a colon-separated list of files and directories.
///
/// Directories contribute entries whose name ends in `.issue` in lexicographic
/// byte order (dotfiles excluded, as with glob's period rule). Files are masked
/// by basename so the first one in search-path order wins, and the total is
/// capped at [`max_issue_size`]. Returns `null` when nothing was read.
pub fn collectIssueText(
    allocator: std.mem.Allocator,
    io: std.Io,
    search_path: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    if (search_path.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var masked: std.ArrayList([]const u8) = .empty;
    defer {
        for (masked.items) |name| allocator.free(name);
        masked.deinit(allocator);
    }

    var limit: usize = max_issue_size;
    var entries = std.mem.splitScalar(u8, search_path, ':');
    while (entries.next()) |entry| {
        if (limit == 0) break;
        if (entry.len == 0) continue; // strtok_r skips empty fields

        const stat = std.Io.Dir.cwd().statFile(io, entry, .{}) catch continue;
        if (stat.kind == .directory) {
            try appendDirectory(allocator, io, &out, &masked, entry, &limit);
        } else {
            try appendIssueFile(allocator, io, &out, &masked, entry, &limit);
        }
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    masked: *std.ArrayList([]const u8),
    dir_path: []const u8,
    limit: *usize,
) std.mem.Allocator.Error!void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".issue")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.pdq([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        if (limit.* == 0) break;
        const path = try allocator.print("{s}/{s}", .{ dir_path, name });
        defer allocator.free(path);
        try appendIssueFile(allocator, io, out, masked, path, limit);
    }
}

fn appendIssueFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    masked: *std.ArrayList([]const u8),
    path: []const u8,
    limit: *usize,
) std.mem.Allocator.Error!void {
    if (limit.* == 0) return;

    const base = std.fs.path.basename(path);
    for (masked.items) |name| {
        if (std.mem.eql(u8, name, base)) return;
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    // kmscon records the basename as soon as fopen succeeds, even if reading
    // later fails or yields nothing.
    if (masked.items.len < max_masked_files - 1) {
        try masked.append(allocator, try allocator.dupe(u8, base));
    }

    limit.* -= try appendFileContents(allocator, io, file, out, limit.*);
}

fn readFileCapped(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    cap: usize,
) std.mem.Allocator.Error!?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return readOpenFile(allocator, io, file, cap);
}

/// Append at most `cap` bytes from `file` to `out` and return how many were
/// appended. Read errors end the transfer but keep the bytes read so far,
/// like kmscon's `fread`/`fwrite` loop.
fn appendFileContents(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    out: *std.ArrayList(u8),
    cap: usize,
) std.mem.Allocator.Error!usize {
    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var chunk: [4096]u8 = undefined;

    var total: usize = 0;
    while (total < cap) {
        const want = @min(chunk.len, cap - total);
        const n = reader.interface.readSliceShort(chunk[0..want]) catch break;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..n]);
        total += n;
    }
    return total;
}

fn readOpenFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    cap: usize,
) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    _ = try appendFileContents(allocator, io, file, &out, cap);
    return try out.toOwnedSlice(allocator);
}

/// Collect issue text from `search_path` (`null` or empty means the default
/// path) and expand it. Returns `null` when the search path produced nothing.
pub fn getBuffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    search_path: ?[]const u8,
    ctx: *const IssueContext,
) std.mem.Allocator.Error!?[]u8 {
    const path = search_path orelse default_issue_path;
    const raw = (try collectIssueText(allocator, io, path)) orelse return null;
    defer allocator.free(raw);
    return try expand(allocator, raw, ctx);
}

// ---------------------------------------------------------------------------
// Real system context (OS lookups)
// ---------------------------------------------------------------------------

/// An [`IssueContext`] populated from the running system, plus the arena that
/// owns the strings it points at. Call `deinit` when done.
pub const SystemContext = struct {
    arena: std.heap.ArenaAllocator,
    ctx: IssueContext,

    pub fn deinit(self: *SystemContext) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Capture the real `uname`, `/etc/os-release`, local time and address book.
/// The returned context is immutable; expansion no longer touches the system.
pub fn systemContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_name: []const u8,
) std.mem.Allocator.Error!SystemContext {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const uts = std.posix.uname();
    const now_seconds = std.Io.Clock.real.now(io).toSeconds();

    const ctx: IssueContext = .{
        .uts = .{
            .sysname = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.sysname, 0)),
            .nodename = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.nodename, 0)),
            .release = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.release, 0)),
            .version = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.version, 0)),
            .machine = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.machine, 0)),
            .domainname = try arena_allocator.dupe(u8, std.mem.sliceTo(&uts.domainname, 0)),
        },
        .tty_name = try arena_allocator.dupe(u8, tty_name),
        .os_release = .{ .content = try loadOsRelease(arena_allocator, io) },
        .now = .{
            .unix_seconds = now_seconds,
            .utc_offset_seconds = localUtcOffset(arena_allocator, io, now_seconds),
        },
        .addresses = try systemAddresses(arena_allocator),
    };

    return .{ .arena = arena, .ctx = ctx };
}

fn loadOsRelease(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error![]const u8 {
    const release_size_limit = 1024 * 1024;
    if (try readFileCapped(allocator, io, "/etc/os-release", release_size_limit)) |data|
        return data;
    if (try readFileCapped(allocator, io, "/usr/lib/os-release", release_size_limit)) |data|
        return data;
    return "";
}

/// Offset to add to UTC at `seconds`, read from `/etc/localtime`.
/// Falls back to 0 (UTC) when the zone file is unavailable or malformed.
fn localUtcOffset(allocator: std.mem.Allocator, io: std.Io, seconds: i64) i32 {
    const data = (readFileCapped(allocator, io, "/etc/localtime", 1024 * 1024) catch return 0) orelse
        return 0;

    var reader: std.Io.Reader = .fixed(data);
    var tz = std.Tz.parse(allocator, &reader) catch return 0;
    defer tz.deinit();

    if (tz.transitions.len != 0) {
        var index = tz.transitions.len;
        while (index > 0) {
            index -= 1;
            const transition = tz.transitions[index];
            if (transition.ts <= seconds) return transition.timetype.offset;
        }
    }
    for (tz.timetypes) |timetype| {
        if (!timetype.isDst()) return timetype.offset;
    }
    return tz.timetypes[0].offset;
}

// ---------------------------------------------------------------------------
// rtnetlink address enumeration
// ---------------------------------------------------------------------------

const IfAddrMsg = extern struct {
    family: u8,
    prefixlen: u8,
    flags: u8,
    scope: u8,
    index: u32,
};

const NetlinkRequest = extern struct {
    header: linux.nlmsghdr,
    gen: extern struct {
        family: u8,
        padding: [3]u8,
    },
};

const nlmsg_align = 4;
const rta_align = 4;

const ifa_address: u16 = 1;
const ifa_local: u16 = 2;
const ifa_cacheinfo: u16 = 6;
const ifa_flags: u16 = 8;

/// Dump the kernel address book with rtnetlink (`RTM_GETADDR`), following
/// kmscon's `issue_network_gen_book`.
fn systemAddresses(allocator: std.mem.Allocator) std.mem.Allocator.Error![]Address {
    var list: std.ArrayList(Address) = .empty;
    defer list.deinit(allocator);

    const socket_result = linux.socket(
        linux.AF.NETLINK,
        linux.SOCK.RAW | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(socket_result) != .SUCCESS) return &.{};
    const fd: linux.fd_t = @intCast(socket_result);
    defer _ = linux.close(fd);

    const name_socket_result = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM | linux.SOCK.CLOEXEC,
        0,
    );
    const name_fd: ?linux.fd_t = if (linux.errno(name_socket_result) == .SUCCESS)
        @intCast(name_socket_result)
    else
        null;
    defer if (name_fd) |name_fd_value| {
        _ = linux.close(name_fd_value);
    };

    var request: NetlinkRequest = .{
        .header = .{
            .len = @sizeOf(NetlinkRequest),
            .type = .RTM_GETADDR,
            .flags = linux.NLM_F_REQUEST | linux.NLM_F_DUMP,
            .seq = 1,
            .pid = 0,
        },
        .gen = .{ .family = 0, .padding = .{ 0, 0, 0 } },
    };
    var kernel_address: linux.sockaddr.nl = .{
        .family = linux.AF.NETLINK,
        .__pad1 = 0,
        .pid = 0,
        .groups = 0,
    };

    const sent = linux.sendto(
        fd,
        @ptrCast(&request),
        @sizeOf(NetlinkRequest),
        0,
        @ptrCast(&kernel_address),
        @sizeOf(linux.sockaddr.nl),
    );
    if (linux.errno(sent) != .SUCCESS) return &.{};

    var buffer: [65536]u8 = undefined;
    var done = false;
    while (!done) {
        const received = linux.recvfrom(fd, @ptrCast(&buffer), buffer.len, 0, null, null);
        if (linux.errno(received) != .SUCCESS) break;
        if (received == 0) break;
        const keep_going = try parseNetlinkMessages(
            allocator,
            &list,
            name_fd,
            buffer[0..received],
        );
        done = !keep_going;
    }

    return try list.toOwnedSlice(allocator);
}

/// Parse one datagram of rtnetlink messages. Returns `false` on `NLMSG_DONE`
/// or `NLMSG_ERROR`.
fn parseNetlinkMessages(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Address),
    name_fd: ?linux.fd_t,
    data: []const u8,
) std.mem.Allocator.Error!bool {
    const header_size = @sizeOf(linux.nlmsghdr);
    var offset: usize = 0;
    while (offset + header_size <= data.len) {
        const header: *align(1) const linux.nlmsghdr = @ptrCast(data.ptr + offset);
        const message_len: usize = header.len;
        if (message_len < header_size or offset + message_len > data.len) break;

        switch (header.type) {
            .DONE, .ERROR => return false,
            .RTM_NEWADDR => try parseAddressMessage(
                allocator,
                list,
                name_fd,
                data[offset .. offset + message_len],
            ),
            else => {},
        }
        offset += std.mem.alignForward(usize, message_len, nlmsg_align);
    }
    return true;
}

fn parseAddressMessage(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Address),
    name_fd: ?linux.fd_t,
    message: []const u8,
) std.mem.Allocator.Error!void {
    const header_size = @sizeOf(linux.nlmsghdr);
    if (message.len < header_size + @sizeOf(IfAddrMsg)) return;
    const ifaddr: *align(1) const IfAddrMsg = @ptrCast(message.ptr + header_size);
    if (ifaddr.family != linux.AF.INET and ifaddr.family != linux.AF.INET6) return;

    var address_bytes: [16]u8 = undefined;
    var have_local = false;
    var have_any = false;
    var flags: u32 = 0;
    var valid: u32 = 0;

    var attr_offset: usize = header_size + @sizeOf(IfAddrMsg);
    while (attr_offset + 4 <= message.len) {
        const attr_len = std.mem.readInt(u16, message[attr_offset..][0..2], native_endian);
        const attr_type = std.mem.readInt(u16, message[attr_offset + 2 ..][0..2], native_endian);
        if (attr_len < 4 or attr_offset + attr_len > message.len) break;
        const attr_data = message[attr_offset + 4 .. attr_offset + attr_len];

        switch (attr_type) {
            ifa_address => {
                if (!have_local and !have_any) {
                    if (copyAddressBytes(&address_bytes, attr_data, ifaddr.family))
                        have_any = true;
                }
            },
            ifa_local => {
                if (copyAddressBytes(&address_bytes, attr_data, ifaddr.family))
                    have_local = true;
            },
            ifa_flags => {
                if (attr_data.len >= 4)
                    flags = std.mem.readInt(u32, attr_data[0..4], native_endian);
            },
            ifa_cacheinfo => {
                if (attr_data.len >= 8)
                    valid = std.mem.readInt(u32, attr_data[4..8], native_endian);
            },
            else => {},
        }

        attr_offset += std.mem.alignForward(usize, attr_len, rta_align);
    }

    if (!have_local and !have_any) return;

    var formatted: [46]u8 = undefined;
    const address_text = if (ifaddr.family == linux.AF.INET)
        formatIpv4(address_bytes[0..4], &formatted)
    else
        formatIpv6(address_bytes[0..16], &formatted);

    var interface_buffer: [16]u8 = undefined;
    const interface = if (name_fd) |fd| blk: {
        const name = interfaceName(fd, ifaddr.index) orelse break :blk "Unknown";
        interface_buffer = name;
        break :blk std.mem.sliceTo(&interface_buffer, 0);
    } else "Unknown";

    try list.append(allocator, .{
        .interface = try allocator.dupe(u8, interface),
        .address = try allocator.dupe(u8, address_text),
        .family = if (ifaddr.family == linux.AF.INET) .ipv4 else .ipv6,
        .scope = @enumFromInt(ifaddr.scope),
        .flags = flags,
        .valid = valid,
    });
}

fn copyAddressBytes(destination: *[16]u8, data: []const u8, family: u8) bool {
    const wanted: usize = if (family == linux.AF.INET) 4 else 16;
    if (data.len < wanted) return false;
    @memcpy(destination[0..wanted], data[0..wanted]);
    return true;
}

fn interfaceName(fd: linux.fd_t, index: u32) ?[16]u8 {
    const IfReq = extern struct {
        name: [16]u8,
        data: [24]u8,
    };
    var request: IfReq = .{
        .name = @splat(0),
        .data = @splat(0),
    };
    std.mem.writeInt(i32, request.data[0..4], @intCast(index), native_endian);
    const result = linux.ioctl(fd, linux.SIOCGIFNAME, @intFromPtr(&request));
    if (linux.errno(result) != .SUCCESS) return null;
    return request.name;
}

fn formatIpv4(bytes: []const u8, buffer: *[46]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch "0.0.0.0";
}

/// `inet_ntop(AF_INET6)` rendering: longest zero run compressed (leftmost on a
/// tie), lowercase hex without leading zeros, IPv4-mapped form preserved.
fn formatIpv6(bytes: []const u8, buffer: *[46]u8) []const u8 {
    if (bytes.len < 16) return "::";
    if (std.mem.allEqual(u8, bytes[0..10], 0) and
        bytes[10] == 0xff and bytes[11] == 0xff)
    {
        return std.fmt.bufPrint(buffer, "::ffff:{d}.{d}.{d}.{d}", .{
            bytes[12], bytes[13], bytes[14], bytes[15],
        }) catch "::";
    }

    var groups: [8]u16 = undefined;
    for (&groups, 0..) |*group, index| {
        group.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .big);
    }

    var best_start: usize = 0;
    var best_len: usize = 0;
    var index: usize = 0;
    while (index < groups.len) {
        if (groups[index] != 0) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < groups.len and groups[index] == 0) index += 1;
        const length = index - start;
        if (length > best_len) {
            best_start = start;
            best_len = length;
        }
    }

    var length: usize = 0;
    var need_separator = false;
    index = 0;
    while (index < groups.len) {
        if (best_len >= 2 and index == best_start) {
            buffer[length] = ':';
            buffer[length + 1] = ':';
            length += 2;
            index += best_len;
            need_separator = false;
            if (index == groups.len) break;
            continue;
        }
        if (need_separator) {
            buffer[length] = ':';
            length += 1;
        }
        length += writeGroup(buffer[length..], groups[index]);
        need_separator = true;
        index += 1;
    }
    return buffer[0..length];
}

fn writeGroup(buffer: []u8, value: u16) usize {
    const digits = "0123456789abcdef";
    if (value == 0) {
        buffer[0] = '0';
        return 1;
    }
    var temp: [4]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    while (remaining != 0) : (remaining >>= 4) {
        temp[count] = digits[remaining & 0xf];
        count += 1;
    }
    for (0..count) |index| {
        buffer[index] = temp[count - 1 - index];
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectExpansion(expected: []const u8, raw: []const u8, ctx: *const IssueContext) !void {
    const out = try expand(std.testing.allocator, raw, ctx);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

const test_uts: Uts = .{
    .sysname = "Linux",
    .nodename = "testhost",
    .release = "6.12.0",
    .version = "#1 SMP",
    .machine = "x86_64",
    .domainname = "",
};

fn testEnvCallback(context: ?*anyopaque, key: []const u8) ?[]const u8 {
    _ = context;
    if (std.mem.eql(u8, key, "TERM")) return "linux";
    return null;
}

test "default context is hermetic" {
    var ctx: IssueContext = .{};
    try expectExpansion("", "", &ctx);
    try expectExpansion("plain text", "plain text", &ctx);
    try expectExpansion(
        "(none)1970-01-0100:00:00\x1b",
        "\\s\\n\\r\\v\\m\\o\\d\\t\\l\\S\\e\\4\\6\\a\\A",
        &ctx,
    );
}

test "literal newlines become CRLF" {
    var ctx: IssueContext = .{};
    try expectExpansion("a\r\nb", "a\nb", &ctx);
    try expectExpansion("a\r\nb\r\n", "a\nb\n", &ctx);
    try expectExpansion("\r\n", "\n", &ctx);
    try expectExpansion("a\r\r\nb", "a\r\nb", &ctx);
}

test "backslash is literal" {
    var ctx: IssueContext = .{};
    try expectExpansion("\\", "\\\\", &ctx);
    try expectExpansion("a\\b", "a\\\\b", &ctx);
}

test "uname escapes" {
    var ctx: IssueContext = .{ .uts = test_uts };
    try expectExpansion("Linux", "\\s", &ctx);
    try expectExpansion("testhost", "\\n", &ctx);
    try expectExpansion("6.12.0", "\\r", &ctx);
    try expectExpansion("#1 SMP", "\\v", &ctx);
    try expectExpansion("x86_64", "\\m", &ctx);
    try expectExpansion("(none)", "\\o", &ctx);
    ctx.uts.domainname = "example.org";
    try expectExpansion("example.org", "\\o", &ctx);
}

test "date and time use injected instant" {
    var ctx: IssueContext = .{ .now = .{ .unix_seconds = 1_700_000_000 } };
    try expectExpansion("2023-11-14", "\\d", &ctx);
    try expectExpansion("22:13:20", "\\t", &ctx);
    try expectExpansion("2023-11-14 22:13:20", "\\d \\t", &ctx);

    ctx.now.utc_offset_seconds = 3600;
    try expectExpansion("2023-11-14", "\\d", &ctx);
    try expectExpansion("23:13:20", "\\t", &ctx);

    ctx.now.utc_offset_seconds = -5 * 3600;
    try expectExpansion("17:13:20", "\\t", &ctx);
}

test "date and time before the epoch" {
    var ctx: IssueContext = .{ .now = .{ .unix_seconds = 0, .utc_offset_seconds = -1 } };
    try expectExpansion("1969-12-31", "\\d", &ctx);
    try expectExpansion("23:59:59", "\\t", &ctx);
}

test "tty name escape" {
    var ctx: IssueContext = .{ .tty_name = "tty1" };
    try expectExpansion("tty1", "\\l", &ctx);
}

test "os-release field expansion" {
    const content =
        \\PRETTY_NAME="Kmscon Test"
        \\VERSION_ID=42
        \\ID=kmscon
        \\QUOTED="with spaces"
        \\EMPTY=
        \\NOQUOTE=value
        \\
    ;
    var ctx: IssueContext = .{ .os_release = .{ .content = content } };

    try expectExpansion("Kmscon Test", "\\S", &ctx);
    try expectExpansion("Kmscon Test", "\\S{PRETTY_NAME}", &ctx);
    try expectExpansion("42", "\\S{VERSION_ID}", &ctx);
    try expectExpansion("kmscon", "\\S{ID}", &ctx);
    try expectExpansion("with spaces", "\\S{QUOTED}", &ctx);
    try expectExpansion("value", "\\S{NOQUOTE}", &ctx);
    try expectExpansion("", "\\S{EMPTY}", &ctx);
    try expectExpansion("", "\\S{MISSING}", &ctx);
    try expectExpansion("", "\\S{}", &ctx);
    try expectExpansion("", "\\S{ID tail", &ctx);
    try expectExpansion("[42]", "[\\S{VERSION_ID}]", &ctx);
}

test "os-release pre-parsed fields" {
    const fields = [_]OsReleaseField{
        .{ .name = "PRETTY_NAME", .value = "Parsed Name" },
        .{ .name = "VERSION_ID", .value = "7" },
    };
    var ctx: IssueContext = .{ .os_release = .{ .fields = &fields } };
    try expectExpansion("Parsed Name", "\\S", &ctx);
    try expectExpansion("Parsed Name", "\\S{PRETTY_NAME}", &ctx);
    try expectExpansion("7", "\\S{VERSION_ID}", &ctx);
    try expectExpansion("", "\\S{ID}", &ctx);
}

test "os-release without braces leaves following text alone" {
    const fields = [_]OsReleaseField{.{ .name = "PRETTY_NAME", .value = "Name" }};
    var ctx: IssueContext = .{ .os_release = .{ .fields = &fields } };
    try expectExpansion("Name rest", "\\S rest", &ctx);
}

test "every colour name expands exactly" {
    const cases = [_]struct { name: []const u8, sequence: []const u8 }{
        .{ .name = "black", .sequence = "[30m" },
        .{ .name = "blink", .sequence = "[5m" },
        .{ .name = "blue", .sequence = "[34m" },
        .{ .name = "bold", .sequence = "[1m" },
        .{ .name = "brown", .sequence = "[33m" },
        .{ .name = "cyan", .sequence = "[36m" },
        .{ .name = "darkgray", .sequence = "[1;30m" },
        .{ .name = "gray", .sequence = "[37m" },
        .{ .name = "green", .sequence = "[32m" },
        .{ .name = "halfbright", .sequence = "[2m" },
        .{ .name = "lightblue", .sequence = "[1;34m" },
        .{ .name = "lightcyan", .sequence = "[1;36m" },
        .{ .name = "lightgray", .sequence = "[37m" },
        .{ .name = "lightgreen", .sequence = "[1;32m" },
        .{ .name = "lightmagenta", .sequence = "[1;35m" },
        .{ .name = "lightred", .sequence = "[1;31m" },
        .{ .name = "magenta", .sequence = "[35m" },
        .{ .name = "red", .sequence = "[31m" },
        .{ .name = "reset", .sequence = "[0m" },
        .{ .name = "reverse", .sequence = "[7m" },
        .{ .name = "white", .sequence = "[1;37m" },
        .{ .name = "yellow", .sequence = "[1;33m" },
    };
    var ctx: IssueContext = .{};
    for (cases) |case| {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "\\e{{{s}}}", .{case.name});
        defer std.testing.allocator.free(raw);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "\x1b{s}", .{case.sequence});
        defer std.testing.allocator.free(expected);
        try expectExpansion(expected, raw, &ctx);
    }
}

test "colour escape quirks" {
    var ctx: IssueContext = .{};
    // No braces: ESC is still emitted.
    try expectExpansion("\x1b", "\\e", &ctx);
    // Unknown name: ESC only. kmscon has no "underscore" entry.
    try expectExpansion("\x1b", "\\e{underscore}", &ctx);
    try expectExpansion("\x1b", "\\e{bogus}", &ctx);
    try expectExpansion("\x1b", "\\e{}", &ctx);
    // Unterminated parameter consumes the rest of the text.
    try expectExpansion("\x1b[31m", "\\e{red", &ctx);
    try expectExpansion("\x1b rest", "\\e rest", &ctx);
    // Names are truncated to 15 bytes by get_parameter.
    try expectExpansion("\x1b", "\\e{lightmagentaXXXX}", &ctx);
}

const test_addresses = [_]Address{
    .{
        .interface = "eth0",
        .address = "192.0.2.10",
        .family = .ipv4,
        .scope = .universe,
        .valid = 100,
    },
    .{
        .interface = "eth0",
        .address = "198.51.100.7",
        .family = .ipv4,
        .scope = .site,
        .valid = 999,
    },
    .{
        .interface = "eth0",
        .address = "203.0.113.9",
        .family = .ipv4,
        .scope = .universe,
        .valid = 200,
    },
    .{
        .interface = "eth0",
        .address = "2001:db8::1",
        .family = .ipv6,
        .scope = .universe,
        .valid = 50,
    },
    .{
        .interface = "eth0",
        .address = "fe80::1",
        .family = .ipv6,
        .scope = .link,
        .valid = 999,
    },
    .{
        .interface = "wlan0",
        .address = "10.0.0.5",
        .family = .ipv4,
        .scope = .universe,
        .valid = 500,
    },
    .{
        .interface = "lo",
        .address = "127.0.0.1",
        .family = .ipv4,
        .scope = .host,
    },
    .{
        .interface = "lo",
        .address = "::1",
        .family = .ipv6,
        .scope = .host,
    },
};

test "best address selection" {
    var ctx: IssueContext = .{ .addresses = &test_addresses };
    // Quality dominates; ties go to the larger valid lifetime.
    try expectExpansion("203.0.113.9", "\\4{eth0}", &ctx);
    try expectExpansion("2001:db8::1", "\\6{eth0}", &ctx);
    // No interface parameter means all interfaces.
    try expectExpansion("10.0.0.5", "\\4", &ctx);
    try expectExpansion("2001:db8::1", "\\6", &ctx);
    // Unknown interface and wrong family expand to nothing.
    try expectExpansion("", "\\4{missing}", &ctx);
    try expectExpansion("", "\\6{wlan0}", &ctx);
    // Unterminated parameter consumes the rest.
    try expectExpansion("10.0.0.5", "\\4{wlan0", &ctx);
}

test "temporary addresses lose to universe addresses" {
    const addresses = [_]Address{
        .{
            .interface = "eth0",
            .address = "192.0.2.10",
            .family = .ipv4,
            .scope = .universe,
            .flags = ifa_f_temporary,
            .valid = 999,
        },
        .{
            .interface = "eth0",
            .address = "198.51.100.7",
            .family = .ipv4,
            .scope = .universe,
            .valid = 1,
        },
    };
    var ctx: IssueContext = .{ .addresses = &addresses };
    try expectExpansion("198.51.100.7", "\\4{eth0}", &ctx);
}

test "all addresses: \\a is filtered IPv4, \\A is everything" {
    var ctx: IssueContext = .{ .addresses = &test_addresses };
    try expectExpansion(
        "eth0: 192.0.2.10 198.51.100.7 203.0.113.9 \r\nwlan0: 10.0.0.5 \r\n",
        "\\a",
        &ctx,
    );
    try expectExpansion(
        "eth0: 192.0.2.10 198.51.100.7 203.0.113.9 2001:db8::1 fe80::1 \r\n" ++
            "wlan0: 10.0.0.5 \r\n" ++
            "lo: 127.0.0.1 ::1 \r\n",
        "\\A",
        &ctx,
    );
    // \a and \A do not parse a parameter in kmscon.
    try expectExpansion(
        "eth0: 192.0.2.10 198.51.100.7 203.0.113.9 \r\nwlan0: 10.0.0.5 \r\n{eth0}",
        "\\a{eth0}",
        &ctx,
    );
}

test "unknown escapes are dropped silently" {
    var ctx: IssueContext = .{ .uts = test_uts };
    try expectExpansion("ab", "a\\zb", &ctx);
    try expectExpansion("ab", "a\\0b", &ctx);
    try expectExpansion("ab", "a\\ b", &ctx);
    try expectExpansion("ab", "a\\{b", &ctx);
    try expectExpansion("abc", "abc\\", &ctx);
    try expectExpansion("Linuxx", "\\sx", &ctx);
}

test "multiline text with escapes" {
    var ctx: IssueContext = .{
        .uts = test_uts,
        .tty_name = "tty1",
        .os_release = .{ .fields = &.{.{ .name = "PRETTY_NAME", .value = "Distro" }} },
    };
    const raw = "Welcome to \\S\nhost \\n on \\l\n";
    try expectExpansion("Welcome to Distro\r\nhost testhost on tty1\r\n", raw, &ctx);
}

test "empty file" {
    var ctx: IssueContext = .{};
    const out = try expand(std.testing.allocator, "", &ctx);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "env accessor: map and callback" {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "KEY", "value");

    const from_map: Env = .{ .map = &map };
    try std.testing.expectEqualStrings("value", from_map.lookup("KEY").?);
    try std.testing.expect(from_map.lookup("MISSING") == null);

    const from_callback: Env = .{ .callback = .{ .get = testEnvCallback } };
    try std.testing.expectEqualStrings("linux", from_callback.lookup("TERM").?);
    try std.testing.expect(from_callback.lookup("NOPE") == null);

    const no_env: Env = .none;
    try std.testing.expect(no_env.lookup("KEY") == null);
}

test "readIssueFile reads and caps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "issue", .data = "hello\n" });
    const data = (try readIssueFile(std.testing.allocator, io, ".zig-cache/tmp/" ++ tmp.sub_path ++ "/issue")).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello\n", data);

    const missing = try readIssueFile(
        std.testing.allocator,
        io,
        ".zig-cache/tmp/" ++ tmp.sub_path ++ "/missing",
    );
    try std.testing.expect(missing == null);

    const big = try std.testing.allocator.alloc(u8, max_issue_size + 17);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "big", .data = big });
    const capped = (try readIssueFile(
        std.testing.allocator,
        io,
        ".zig-cache/tmp/" ++ tmp.sub_path ++ "/big",
    )).?;
    defer std.testing.allocator.free(capped);
    try std.testing.expectEqual(max_issue_size, capped.len);
}

test "collectIssueText: order, directories and masking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "issue", .data = "root-" });
    try tmp.dir.createDirPath(io, "issue.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "issue.d/00.issue", .data = "zero-" });
    try tmp.dir.writeFile(io, .{ .sub_path = "issue.d/10.issue", .data = "ten-" });
    try tmp.dir.writeFile(io, .{ .sub_path = "issue.d/issue", .data = "masked-" });
    try tmp.dir.writeFile(io, .{ .sub_path = "issue.d/.hidden.issue", .data = "hidden-" });
    try tmp.dir.writeFile(io, .{ .sub_path = "issue.d/ignored.txt", .data = "ignored-" });

    const base = ".zig-cache/tmp/" ++ tmp.sub_path;
    const search = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/issue:{s}/issue.d:{s}/missing.issue",
        .{ base, base, base },
    );
    defer std.testing.allocator.free(search);

    const raw = (try collectIssueText(std.testing.allocator, io, search)).?;
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("root-zero-ten-", raw);
}

test "collectIssueText: empty input and empty files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try std.testing.expect((try collectIssueText(std.testing.allocator, io, "")) == null);

    const base = ".zig-cache/tmp/" ++ tmp.sub_path;
    const search = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty", .{base});
    defer std.testing.allocator.free(search);
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try std.testing.expect((try collectIssueText(std.testing.allocator, io, search)) == null);

    const dirmissing = try std.fmt.allocPrint(std.testing.allocator, "{s}/no-such-dir", .{base});
    defer std.testing.allocator.free(dirmissing);
    try std.testing.expect((try collectIssueText(std.testing.allocator, io, dirmissing)) == null);
}

test "getBuffer: collect and expand pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "issue", .data = "Host \\n on \\l\n" });
    const base = ".zig-cache/tmp/" ++ tmp.sub_path;
    const search = try std.fmt.allocPrint(std.testing.allocator, "{s}/issue", .{base});
    defer std.testing.allocator.free(search);

    var ctx: IssueContext = .{ .uts = test_uts, .tty_name = "tty2" };
    const buffer = (try getBuffer(std.testing.allocator, io, search, &ctx)).?;
    defer std.testing.allocator.free(buffer);
    try std.testing.expectEqualStrings("Host testhost on tty2\r\n", buffer);
}

test "getBuffer: nothing found yields null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const base = ".zig-cache/tmp/" ++ tmp.sub_path;
    const search = try std.fmt.allocPrint(std.testing.allocator, "{s}/nope", .{base});
    defer std.testing.allocator.free(search);
    var ctx: IssueContext = .{};
    try std.testing.expect((try getBuffer(std.testing.allocator, io, search, &ctx)) == null);
}

test "IPv4 and IPv6 formatting" {
    var buffer: [46]u8 = undefined;
    try std.testing.expectEqualStrings("192.0.2.1", formatIpv4(&[_]u8{ 192, 0, 2, 1 }, &buffer));
    try std.testing.expectEqualStrings(
        "2001:db8::1",
        formatIpv6(&[_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &buffer),
    );
    try std.testing.expectEqualStrings(
        "::1",
        formatIpv6(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &buffer),
    );
    const zeros: [16]u8 = @splat(0);
    try std.testing.expectEqualStrings("::", formatIpv6(&zeros, &buffer));
    try std.testing.expectEqualStrings(
        "::ffff:192.0.2.1",
        formatIpv6(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 1 }, &buffer),
    );
    try std.testing.expectEqualStrings(
        "fe80::1:2",
        formatIpv6(&[_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2 }, &buffer),
    );
}

test "systemContext resolves real lookups" {
    var system = try systemContext(std.testing.allocator, std.testing.io, "tty1");
    defer system.deinit();

    try std.testing.expect(system.ctx.uts.sysname.len > 0);
    try std.testing.expectEqualStrings("tty1", system.ctx.tty_name);
    switch (system.ctx.os_release) {
        // The file may legitimately be empty or absent; the variant is what
        // matters for the loader having run.
        .content => {},
        else => return error.TestUnexpectedResult,
    }
}