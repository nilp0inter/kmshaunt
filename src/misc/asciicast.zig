//! asciicast v2/v3 playback (ROADMAP M2.4: the kmscon `--asciicast` /
//! `--asciicast-loop` option pair).
//!
//! Format authority: `docs/reference/kmscon-options.md` §5.6 ("Asciicast
//! format (`misc/asciinema.c`)", lines 389-407) plus the upstream specs
//! <https://docs.asciinema.org/manual/asciicast/v2/> and
//! <https://docs.asciinema.org/manual/asciicast/v3/> (v3 revision 2025-10-20).
//! Constants below were cross-checked against kmscon 10.1.0
//! `src/misc/asciinema.c`:
//!
//!   `ASCIINEMA_MAX_LINE`     256 KiB   (`getline` result, newline included)
//!   `ASCIINEMA_MAX_OUTPUT`   2 MiB     (sum of `"o"` data bytes)
//!   `ASCIINEMA_MAX_EVENTS`   16384     (number of `"o"` events)
//!   `ASCIINEMA_MIN_TIMER_NS` 1 ms      (player scheduling floor)
//!   `sec_to_ns`              3600 s    (per-event delay clamp)
//!
//! The reference doc renders the last limit as "timer clamp to 1 s per
//! event". That cannot be right: `sec_to_ns` clamps at `3600.0` seconds and
//! the timerfd is never reduced to 1 s. `max_event_delay_ns` uses the source
//! value (1 h) and the player clamps exactly like kmscon.
//!
//! ## Reading (`--asciicast`, `--asciicast-loop`) — Player
//!
//! kmscon semantics reproduced here (§5.6, `parse_event_line` /
//! `kmscon_asciinema_advance`):
//!
//!   * The first line is the header and must contain `"version"`; any value
//!     other than 2 or 3 is an error (`error.UnsupportedVersion`).
//!   * Only `"o"` events are played. `"i"`, `"m"`, `"r"` and unknown codes
//!     are ignored; in v3 their `t` is added to a pending interval so the
//!     next output happens after them.
//!   * v3 lines whose first byte is `#` are comments and are skipped. Any
//!     line whose first non-whitespace byte is not `[` is ignored, which is
//!     how kmscon also treats comments and blank lines in v2.
//!   * v2: `t` is absolute; the delay is `t - last_output_time`, clipped at
//!     zero. v3: `t` is a delta; the delay is `pending + t` and `pending` is
//!     cleared.
//!   * `data` must be a JSON string; it is played byte for byte.
//!   * A file with no output events is `error.NoOutputEvents`.
//!   * `--asciicast-loop` restarts at event 0 when the last event has been
//!     consumed (`Player.next`/`Player.peek` wrap forever). The terminal
//!     stops playback on the first keyboard input, just like kmscon
//!     (`terminal.c:972`, `1522-1527`); the player itself has no stop flag —
//!     the caller simply stops calling `next`.
//!
//! Playback delays are clamped to [`max_event_delay_ns`] and negative or NaN
//! intervals become zero, matching `sec_to_ns`. The 1 ms minimum in the
//! reference doc is the player's timer floor, not a property of the file; the
//! player keeps the recorded value and `Playback` coalesces the zero-delay
//! events as kmscon does. Reading a file edited by hand requires its event
//! lines to be valid JSON (kmscon's parser is byte-oriented, but `std.json`
//! is stricter and rejects invalid UTF-8).
//!
//! ## Driving playback — Playback
//!
//! `Player` parses the file; `Playback` drives the event stream the way
//! kmscon's timer does (`misc/asciinema.c` `kmscon_asciinema_start` /
//! `_advance` / `_stop`):
//!
//!   * `start` rewinds to event 0 and returns the first event's delay,
//!     floored at `min_timer_ns` (`schedule_event`). The caller arms a
//!     one-shot timer with it.
//!   * `advance` writes the due event plus every following zero-delay
//!     event (kmscon writes them all in one timer tick) and returns the
//!     delay to the next event, or null when the stream is exhausted
//!     without `loop`. The caller re-arms the timer with the returned
//!     delay, or tears the playback down on null.
//!   * `stop` ends playback until the next `start` — the console calls it
//!     on the first keyboard input (kmscon `terminal.c:978`).
//!   * The write sink receives the raw event bytes. kmscon feeds them to
//!     the terminal emulator, NOT to the pty child (`asciinema_write` ->
//!     `tsm_vte_input`, `terminal.c:478-486`): the animation renders on
//!     screen without typing into the login session. §5.2's "plays ... into
//!     the pty" wording is loose; the source is authoritative, and kmshaunt
//!     mirrors it (`main.zig` `playbackWrite` -> `vt.write`).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

comptime {
    if (builtin.os.tag != .linux)
        @compileError("src/misc/asciicast.zig is Linux-only (raw file syscalls)");
}

/// Maximum bytes per physical line, newline included (`ASCIINEMA_MAX_LINE`).
pub const max_line: usize = 256 * 1024;
/// Maximum total `"o"` payload bytes (`ASCIINEMA_MAX_OUTPUT`).
pub const max_total_output: usize = 2 * 1024 * 1024;
/// Maximum number of `"o"` events (`ASCIINEMA_MAX_EVENTS`).
pub const max_events: usize = 16384;
/// Player timer floor (`ASCIINEMA_MIN_TIMER_NS`); playback only.
pub const min_timer_ns: u64 = std.time.ns_per_ms;
/// Per-event delay clamp in the player (`sec_to_ns` clamps at 3600 s).
pub const max_event_delay_ns: u64 = 3600 * std.time.ns_per_s;

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteZero;
                offset += n;
            },
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn readSome(fd: posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// One parsed asciicast output event, with its playback delay.
pub const Event = struct {
    delay_ns: u64,
    data: []u8,
};

/// In-memory asciicast reader for `--asciicast` / `--asciicast-loop`.
/// Reads and validates the whole file up front (kmscon does the same with
/// `getline`), rejecting any file the player would reject.
pub const Player = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    pos: usize = 0,
    loop: bool,
    total_output: usize = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, loop: bool) !Player {
        const fd = try posix.openat(posix.AT.FDCWD, path, .{}, 0);
        defer _ = linux.close(fd);

        var reader: LineReader = .{ .fd = fd, .allocator = allocator };
        defer reader.line.deinit(allocator);

        const header_line = (try reader.next()) orelse return error.MissingHeader;
        const version = try parseHeaderVersion(allocator, header_line);

        var self: Player = .{ .allocator = allocator, .loop = loop };
        errdefer self.deinit();

        var last_output_t: f64 = 0;
        var pending: f64 = 0;
        while (try reader.next()) |line| {
            if (version == 3 and line.len > 0 and line[0] == '#') continue;
            const trimmed = std.mem.trimStart(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] != '[') continue;

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            const items = switch (parsed.value) {
                .array => |arr| arr.items,
                else => return error.InvalidEvent,
            };
            if (items.len != 3) return error.InvalidEvent;
            const t = switch (items[0]) {
                .integer => |v| @as(f64, @floatFromInt(v)),
                .float => |v| v,
                .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidEvent,
                else => return error.InvalidEvent,
            };
            const code = switch (items[1]) {
                .string => |s| s,
                else => return error.InvalidEvent,
            };
            const data = switch (items[2]) {
                .string => |s| s,
                else => return error.InvalidEvent,
            };

            if (code.len != 1 or code[0] != 'o') {
                if (version == 3) pending += t;
                continue;
            }
            const delay_sec = if (version == 3) blk: {
                const d = pending + t;
                pending = 0;
                break :blk d;
            } else blk: {
                const d = t - last_output_t;
                last_output_t = t;
                break :blk if (d < 0) 0 else d;
            };
            try self.addEvent(delay_sec, data);
        }

        if (self.events.items.len == 0) return error.NoOutputEvents;
        return self;
    }

    pub fn deinit(self: *Player) void {
        for (self.events.items) |ev| self.allocator.free(ev.data);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Restart at event 0 (kmscon's `pos = 0` on start).
    pub fn reset(self: *Player) void {
        self.pos = 0;
    }

    /// Delay and data of the next output event, or null when the stream is
    /// exhausted and `loop` is off. With `loop` on, this wraps forever,
    /// rewinding `pos` to 0 like kmscon's `advance`.
    pub fn next(self: *Player) ?Event {
        if (self.pos >= self.events.items.len) {
            if (!self.loop or self.events.items.len == 0) return null;
            self.pos = 0;
        }
        const ev = self.events.items[self.pos];
        self.pos += 1;
        return ev;
    }

    /// Like `next` without consuming the event, so a caller can coalesce
    /// consecutive zero-delay events (kmscon's `advance` loop).
    pub fn peek(self: *const Player) ?Event {
        if (self.events.items.len == 0) return null;
        if (self.pos >= self.events.items.len) {
            if (!self.loop) return null;
            return self.events.items[0];
        }
        return self.events.items[self.pos];
    }

    fn addEvent(self: *Player, delay_sec: f64, data: []const u8) !void {
        if (self.events.items.len >= max_events) return error.TooManyEvents;
        if (data.len > max_total_output or self.total_output > max_total_output - data.len)
            return error.OutputTooLarge;
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        try self.events.append(self.allocator, .{
            .delay_ns = secToNs(delay_sec),
            .data = copy,
        });
        self.total_output += data.len;
    }
};

/// Timer-driven playback of a parsed asciicast stream (kmscon
/// `misc/asciinema.c` start/advance/stop). The caller owns the timer:
/// `start`/`advance` return the delay to arm, `advance` writes every event
/// that is due through `write_fn`. See the module header for the contract.
pub const Playback = struct {
    player: Player,
    write_fn: WriteFn,
    userdata: ?*anyopaque,
    stopped: bool = true,

    /// Sink for the raw event bytes. kmscon feeds the terminal emulator
    /// (`tsm_vte_input`), not the pty child; void because a terminal write
    /// cannot fail.
    pub const WriteFn = *const fn (userdata: ?*anyopaque, bytes: []const u8) void;

    /// Load and validate `path`; a bad file is an error the caller reports
    /// (kmscon logs "cannot load asciicast" and continues without it).
    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        loop: bool,
        write_fn: WriteFn,
        userdata: ?*anyopaque,
    ) !Playback {
        return .{
            .player = try Player.init(allocator, path, loop),
            .write_fn = write_fn,
            .userdata = userdata,
        };
    }

    pub fn deinit(self: *Playback) void {
        self.player.deinit();
        self.* = undefined;
    }

    /// Rewind to event 0 and return the delay to the first event, floored
    /// at `min_timer_ns` (kmscon `schedule_event`). Clears a previous stop.
    pub fn start(self: *Playback) u64 {
        self.player.reset();
        self.stopped = false;
        // Player.init guarantees at least one output event.
        return timerDelay(self.player.peek().?.delay_ns);
    }

    /// Write the due event plus every following zero-delay event (kmscon
    /// coalesces them in one timer tick), then return the delay to the next
    /// event. Null means the stream is exhausted without `loop` (or `stop`
    /// was called): the caller disarms the timer and tears down.
    pub fn advance(self: *Playback) ?u64 {
        if (self.stopped) return null;
        const p = &self.player;
        if (p.events.items.len == 0) {
            self.stopped = true;
            return null;
        }
        if (p.pos >= p.events.items.len) {
            if (!p.loop) {
                self.stopped = true;
                return null;
            }
            p.pos = 0;
        }
        // Write the due event plus its zero-delay followers; never
        // coalesce across the loop wrap (kmscon's do/while).
        while (true) {
            const ev = p.events.items[p.pos];
            p.pos += 1;
            self.write_fn(self.userdata, ev.data);
            if (p.pos >= p.events.items.len or p.events.items[p.pos].delay_ns != 0) break;
        }
        if (p.pos >= p.events.items.len) {
            if (!p.loop) {
                self.stopped = true;
                return null;
            }
            p.pos = 0;
        }
        return timerDelay(p.events.items[p.pos].delay_ns);
    }

    /// End playback until the next `start` (kmscon stops on the first
    /// keyboard input, `terminal.c:978`).
    pub fn stop(self: *Playback) void {
        self.stopped = true;
    }
};

/// `schedule_event`: never arm the timer below `ASCIINEMA_MIN_TIMER_NS`.
fn timerDelay(delay_ns: u64) u64 {
    return @max(min_timer_ns, delay_ns);
}

fn parseHeaderVersion(allocator: std.mem.Allocator, line: []const u8) !u32 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidHeader,
    };
    const version_value = obj.get("version") orelse return error.MissingHeader;
    const version = switch (version_value) {
        .integer => |v| v,
        else => return error.InvalidHeader,
    };
    if (version != 2 and version != 3) return error.UnsupportedVersion;
    return @intCast(version);
}

/// Delay conversion matching kmscon `sec_to_ns`: non-positive and NaN
/// intervals become 0, values at or above 3600 s clamp to 3600 s.
fn secToNs(sec: f64) u64 {
    if (!(sec > 0)) return 0;
    if (sec >= 3600.0) return max_event_delay_ns;
    return @intFromFloat(sec * 1_000_000_000.0);
}

/// Streaming line reader over a file descriptor, capped at `max_line` bytes
/// per line (newline excluded; kmscon's `getline` cap includes it).
const LineReader = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    line: std.ArrayList(u8) = .empty,

    fn next(self: *LineReader) !?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            if (self.start == self.end) {
                if (self.eof) {
                    return if (self.line.items.len == 0) null else self.line.items;
                }
                const n = try readSome(self.fd, self.buf[0..]);
                if (n == 0) {
                    self.eof = true;
                    continue;
                }
                self.start = 0;
                self.end = n;
            }
            const chunk = self.buf[self.start..self.end];
            if (std.mem.findScalar(u8, chunk, '\n')) |nl| {
                try self.append(chunk[0..nl]);
                self.start += nl + 1;
                return self.line.items;
            }
            try self.append(chunk);
            self.start = self.end;
        }
    }

    fn append(self: *LineReader, bytes: []const u8) !void {
        if (self.line.items.len + bytes.len > max_line) return error.LineTooLong;
        try self.line.appendSlice(self.allocator, bytes);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testPath(allocator: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644);
    defer _ = linux.close(fd);
    try writeAll(fd, bytes);
}

test "player: v3 comments, ignored events and loop semantics" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "play.cast");
    defer allocator.free(path);

    const file =
        \\{"version":3,"term":{"cols":80,"rows":24}}
        \\# a comment line
        \\[0.5, "o", "a"]
        \\[0.25, "r", "100x40"]
        \\[0.25, "o", "b"]
        \\
    ;
    try writeFile(path, file);

    var player = try Player.init(allocator, path, true);
    defer player.deinit();

    const first = player.next().?;
    try testing.expectEqualStrings("a", first.data);
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), first.delay_ns);

    const second = player.next().?;
    try testing.expectEqualStrings("b", second.data);
    // 0.25 s pending from the resize plus its own 0.25 s.
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), second.delay_ns);

    // Loop restarts at event 0.
    const wrapped = player.next().?;
    try testing.expectEqualStrings("a", wrapped.data);
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), wrapped.delay_ns);

    player.reset();
    try testing.expectEqualStrings("a", player.peek().?.data);

    var finite = try Player.init(allocator, path, false);
    defer finite.deinit();
    _ = finite.next();
    _ = finite.next();
    try testing.expectEqual(@as(?Event, null), finite.next());
}

test "player: v2 absolute timing, delay clipping and errors" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "play2.cast");
    defer allocator.free(path);

    const file =
        \\{"version":2,"width":80,"height":24}
        \\[0.5, "o", "a"]
        \\[0.25, "o", "b"]
        \\[1.0, "m", ""]
        \\[1.5, "o", "c"]
        \\
    ;
    try writeFile(path, file);

    var player = try Player.init(allocator, path, false);
    defer player.deinit();

    const first = player.next().?;
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), first.delay_ns);
    const second = player.next().?;
    try testing.expectEqual(@as(u64, 0), second.delay_ns); // clipped at 0
    const third = player.next().?;
    try testing.expectEqual(@as(u64, 1250 * std.time.ns_per_ms), third.delay_ns); // 1.5 - 0.25
    try testing.expectEqualStrings("c", third.data);

    const bad_path = try testPath(allocator, &tmp, "bad.cast");
    defer allocator.free(bad_path);
    try writeFile(bad_path, "{\"version\":1,\"width\":80,\"height\":24}\n[0.0,\"o\",\"x\"]\n");
    try testing.expectError(error.UnsupportedVersion, Player.init(allocator, bad_path, false));

    const empty_path = try testPath(allocator, &tmp, "empty.cast");
    defer allocator.free(empty_path);
    try writeFile(empty_path, "{\"version\":2,\"width\":80,\"height\":24}\n");
    try testing.expectError(error.NoOutputEvents, Player.init(allocator, empty_path, false));
}

test "player: hard limits reject oversized payloads and event counts" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "limits.cast");
    defer allocator.free(path);

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(allocator);
    const header = "{\"version\":2,\"width\":80,\"height\":24}\n";

    // 2 MiB payload cap: 9 events of 240 KiB each (every physical line
    // stays under the 256 KiB line cap, so the payload limit is what hits).
    const chunk = try allocator.alloc(u8, 240 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 'A');
    try file.appendSlice(allocator, header);
    for (0..9) |_| {
        try file.appendSlice(allocator, "[0.0,\"o\",\"");
        try file.appendSlice(allocator, chunk);
        try file.appendSlice(allocator, "\"]\n");
    }
    try writeFile(path, file.items);
    try testing.expectError(error.OutputTooLarge, Player.init(allocator, path, false));

    // 16384-event cap.
    file.clearRetainingCapacity();
    try file.appendSlice(allocator, header);
    for (0..max_events + 1) |_| {
        try file.appendSlice(allocator, "[0.0,\"o\",\"x\"]\n");
    }
    try writeFile(path, file.items);
    try testing.expectError(error.TooManyEvents, Player.init(allocator, path, false));
}

test "long v3 intervals are clamped on playback" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "long.cast");
    defer allocator.free(path);

    // Two hours of idleness: the player clamps it to `sec_to_ns`'s 3600 s
    // like kmscon does.
    const file =
        \\{"version":3,"term":{"cols":80,"rows":24}}
        \\[7200.0, "o", "x"]
        \\
    ;
    try writeFile(path, file);

    var player = try Player.init(allocator, path, false);
    defer player.deinit();
    const ev = player.next().?;
    try testing.expectEqualStrings("x", ev.data);
    try testing.expectEqual(max_event_delay_ns, ev.delay_ns);
}

/// In-memory write sink for the Playback tests.
const PlaybackSink = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    writes: u32 = 0,

    fn write(ud: ?*anyopaque, bytes: []const u8) void {
        const self: *PlaybackSink = @ptrCast(@alignCast(ud.?));
        self.writes += 1;
        self.buf.appendSlice(self.allocator, bytes) catch @panic("playback test: oom");
    }

    fn deinit(self: *PlaybackSink) void {
        self.buf.deinit(self.allocator);
    }
};

/// v2 fixture: "hello" at 0, " world" at 0.05, "!" at 0.05 (zero delay),
/// "done" at 0.5. Delays: 0, 50 ms, 0, 450 ms.
const playback_fixture =
    \\{"version":2,"width":80,"height":24}
    \\[0.0, "o", "hello"]
    \\[0.05, "o", " world"]
    \\[0.05, "o", "!"]
    \\[0.5, "o", "done"]
    \\
;

test "playback: output, zero-delay coalescing, timer floor and exhaustion" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "playback.cast");
    defer allocator.free(path);
    try writeFile(path, playback_fixture);

    var sink = PlaybackSink{ .allocator = allocator };
    defer sink.deinit();
    var pb = try Playback.init(allocator, path, false, PlaybackSink.write, &sink);
    defer pb.deinit();

    // First delay is 0: the timer floor applies (schedule_event).
    try testing.expectEqual(min_timer_ns, pb.start());
    try testing.expectEqual(@as(u32, 0), sink.writes);

    // First tick writes only "hello"; the next event is 50 ms away.
    try testing.expectEqual(@as(?u64, 50 * std.time.ns_per_ms), pb.advance());
    try testing.expectEqualStrings("hello", sink.buf.items);

    // Second tick coalesces the zero-delay "!" with " world".
    try testing.expectEqual(@as(?u64, 450 * std.time.ns_per_ms), pb.advance());
    try testing.expectEqualStrings("hello world!", sink.buf.items);
    try testing.expectEqual(@as(u32, 3), sink.writes);

    // Last event exhausts the stream: null, and further ticks are no-ops.
    try testing.expectEqual(@as(?u64, null), pb.advance());
    try testing.expectEqualStrings("hello world!done", sink.buf.items);
    try testing.expectEqual(@as(u32, 4), sink.writes);
    try testing.expectEqual(@as(?u64, null), pb.advance());
    try testing.expectEqual(@as(u32, 4), sink.writes);
}

test "playback: stop ends output until the next start (first key input)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "stop.cast");
    defer allocator.free(path);
    try writeFile(path, playback_fixture);

    var sink = PlaybackSink{ .allocator = allocator };
    defer sink.deinit();
    var pb = try Playback.init(allocator, path, false, PlaybackSink.write, &sink);
    defer pb.deinit();

    _ = pb.start();
    _ = pb.advance(); // "hello"
    pb.stop();
    try testing.expectEqual(@as(?u64, null), pb.advance());
    try testing.expectEqualStrings("hello", sink.buf.items);

    // stop is not permanent across start: a new playback rewinds.
    try testing.expectEqual(min_timer_ns, pb.start());
    try testing.expectEqual(@as(?u64, 50 * std.time.ns_per_ms), pb.advance());
    try testing.expectEqualStrings("hellohello", sink.buf.items);
}

test "playback: loop wraps at the end of the stream" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "loop.cast");
    defer allocator.free(path);

    const file =
        \\{"version":2,"width":80,"height":24}
        \\[0.0, "o", "a"]
        \\[0.25, "o", "b"]
        \\
    ;
    try writeFile(path, file);

    var sink = PlaybackSink{ .allocator = allocator };
    defer sink.deinit();
    var pb = try Playback.init(allocator, path, true, PlaybackSink.write, &sink);
    defer pb.deinit();

    try testing.expectEqual(min_timer_ns, pb.start());
    try testing.expectEqual(@as(?u64, 250 * std.time.ns_per_ms), pb.advance());
    try testing.expectEqualStrings("a", sink.buf.items);

    // "b" is last: with loop on, the next delay is event 0's (floored).
    try testing.expectEqual(min_timer_ns, pb.advance());
    try testing.expectEqualStrings("ab", sink.buf.items);

    // The stream wraps forever.
    for (0..3) |_| {
        try testing.expectEqual(@as(?u64, 250 * std.time.ns_per_ms), pb.advance());
        try testing.expectEqual(min_timer_ns, pb.advance());
    }
    try testing.expectEqualStrings("abababab", sink.buf.items);

    // Even a looping playback stops on input.
    pb.stop();
    try testing.expectEqual(@as(?u64, null), pb.advance());
    try testing.expectEqualStrings("abababab", sink.buf.items);
}
