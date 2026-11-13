//! asciicast v2/v3 recording and playback (ROADMAP M2.4: the kmscon
//! `--asciicast` / `--asciicast-loop` option pair).
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
//! the timerfd is never reduced to 1 s. A 1 s clamp would also corrupt every
//! recording with a longer pause, so `max_event_delay_ns` uses the source
//! value (1 h) and the player clamps exactly like kmscon.
//!
//! ## Writing (Recorder)
//!
//! The header is the minimal one required by each spec, with a deterministic
//! key order and no optional metadata (no `timestamp`, so recordings are
//! reproducible):
//!
//!   v2: `{"version":2,"width":80,"height":24}`
//!   v3: `{"version":3,"term":{"cols":80,"rows":24}}`
//!
//! Events are newline-delimited JSON arrays written incrementally, so an
//! interrupted recording stays readable up to the last complete line:
//!
//!   v2: `[<absolute seconds>, "o", data]` / `[<absolute seconds>, "r", "WxH"]`
//!   v3: `[<seconds since previous event>, "o", data]` / `[…, "r", "WxH"]`
//!
//! v3 follows the player's accumulation rule (§5.6): every event is a delta
//! from the previous event, and a non-`o` event (a resize) consumes the time
//! up to itself, so the next output delta starts after the resize. This is
//! exactly what kmscon reconstructs: `pending_interval += t` for non-`o`
//! events and `delay = pending + t` for the next `o` event. Splitting one
//! oversized output chunk into several events gives the second and later
//! chunks a delta of zero; kmscon coalesces zero-delay events when playing.
//!
//! Times are truncated to microseconds and formatted with fixed six decimal
//! places (`1.250000`), the precision used by the v2 examples and accepted by
//! the player's `strtod`. The baseline is kept in whole elapsed microseconds,
//! so the v3 deltas telescope to the real elapsed time with no rounding
//! drift. A regressing clock saturates at a zero interval; arithmetic is
//! saturating and never wraps. Intervals are not clamped on write: kmscon's
//! player already clamps playback delays at 3600 s, and clamping in the file
//! would only lose information. Overflow of the u64 microsecond counter
//! saturates (never wraps), so a pathological clock can only produce one
//! very large interval, which the player clamps.
//!
//! Arbitrary terminal bytes are made valid UTF-8 before JSON encoding: every
//! byte that is not part of a valid UTF-8 sequence becomes U+FFFD (one
//! replacement per offending byte, not per maximal subpart). A multi-byte
//! sequence split across two `recordOutput` calls is carried over and
//! encoded once; `finish` flushes a dangling partial sequence as one U+FFFD,
//! so output is never split into two replacement characters. Escaping itself
//! is `std.json`'s encoder: control bytes become `\b \f \n \r \t` or
//! `\u00XX`, quote/backslash are escaped, valid UTF-8 is copied verbatim
//! (RFC 8259 permits the literal characters; the asciinema specs only
//! *recommend* `\uXXXX` for non-printables).
//!
//! Hard limits are enforced by stopping the recording *before* the line that
//! the player would reject. This matters because kmscon discards the whole
//! file on the first bad line (`asciinema.c:392-412`); a recording that kept
//! writing past a limit would not even replay its valid prefix. A single
//! output chunk that would exceed 256 KiB per line is split across events
//! (still bounded by the 16384-event and 2 MiB-payload caps). Once a limit is
//! hit, later `recordOutput`/`recordResize` calls are dropped and
//! `Recorder.stopped` is set; `finish` still closes the file cleanly.
//!
//! ## Reading (`--asciicast`, `--asciicast-loop`) — Player
//!
//! kmscon semantics reproduced here (§5.6, `parse_event_line`/
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
//! player keeps the recorded value and the terminal loop coalesces the
//! zero-delay events as kmscon does. Reading a file edited by hand requires
//! its event lines to be valid JSON (kmscon's parser is byte-oriented, but
//! `std.json` is stricter and rejects invalid UTF-8); the recorder always
//! produces lines that both accept.

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

/// Asciicast file format version.
pub const Format = enum {
    v2,
    v3,
};

/// Injectable monotonic clock, in nanoseconds.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque) u64 = monotonicNow,

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.context);
    }
};

fn monotonicNow(_: ?*anyopaque) u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Recorder configuration (`--asciicast` plus the two kmscon options that
/// describe the terminal it records).
pub const Options = struct {
    version: Format = .v2,
    width: u16,
    height: u16,
    /// `--asciicast-loop`. Playback-only: `Player` wraps at the end of the
    /// event stream; a recording is never looped and asciicast has no loop
    /// header field. The flag is accepted here because kmshaunt's option
    /// parser keeps `asciicast` and `asciicast-loop` in one value.
    loop: bool = false,
    clock: Clock = .{},
};

/// Streaming asciicast writer.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    format: Format,
    width: u16,
    height: u16,
    clock: Clock,
    start_ns: u64,
    /// Elapsed microseconds of the last written event (v3 delta baseline).
    last_elapsed_us: u64 = 0,
    /// `"o"` events written so far (the limit kmscon applies).
    output_events: usize = 0,
    /// `"o"` payload bytes written so far.
    output_bytes: usize = 0,
    /// Set once a hard limit would be exceeded; no further events are written.
    stopped: bool = false,
    finished: bool = false,
    /// Incomplete UTF-8 sequence carried over to the next `recordOutput`.
    pending: [4]u8 = undefined,
    pending_len: u8 = 0,
    /// JSON-encoding scratch buffer (sanitized payload, reused per call).
    scratch: std.ArrayList(u8) = .empty,
    /// One-line assembly buffer, `max_line` bytes.
    line_buf: []u8,

    /// Open `path` (truncating it) and write the header. The header is
    /// flushed immediately so even an empty file is a valid recording.
    pub fn init(allocator: std.mem.Allocator, path: []const u8, opts: Options) !Recorder {
        const fd = try posix.openat(posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o644);
        errdefer _ = linux.close(fd);

        const line_buf = try allocator.alloc(u8, max_line);
        errdefer allocator.free(line_buf);

        var self: Recorder = .{
            .allocator = allocator,
            .fd = fd,
            .format = opts.version,
            .width = opts.width,
            .height = opts.height,
            .clock = opts.clock,
            .start_ns = opts.clock.now(),
            .line_buf = line_buf,
        };
        errdefer self.scratch.deinit(allocator);
        try self.writeHeader();
        return self;
    }

    /// Close the file (if `finish` has not done so) and release memory.
    /// Errors from a still-open file are ignored; call `finish` first to
    /// observe them.
    pub fn deinit(self: *Recorder) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        self.allocator.free(self.line_buf);
        self.scratch.deinit(self.allocator);
        self.* = undefined;
    }

    /// Record bytes written to the terminal (the pty master's output).
    /// Empty input is a no-op.
    pub fn recordOutput(self: *Recorder, bytes: []const u8) !void {
        if (self.finished or self.stopped or self.fd < 0) return;
        if (bytes.len == 0) return;
        const elapsed_us = self.elapsedUs(self.clock.now());
        // Common case: already-valid UTF-8 and no carried state, so the
        // payload can be encoded straight from the caller's slice.
        if (self.pending_len == 0 and std.unicode.utf8ValidateSlice(bytes)) {
            try self.writeEventLine("o", bytes, elapsed_us);
            return;
        }
        const data = try self.sanitize(bytes);
        if (data.len == 0) return;
        try self.writeEventLine("o", data, elapsed_us);
    }

    /// Record a terminal resize (`"r"` event, both v2 and v3).
    pub fn recordResize(self: *Recorder, cols: u16, rows: u16) !void {
        if (self.finished or self.stopped or self.fd < 0) return;
        var buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "{d}x{d}", .{ cols, rows });
        try self.writeEventLine("r", data, self.elapsedUs(self.clock.now()));
    }

    /// Flush a dangling partial UTF-8 sequence and close the file.
    /// Idempotent; call `deinit` afterwards to free memory.
    pub fn finish(self: *Recorder) !void {
        if (self.finished) return;
        if (self.pending_len > 0) {
            self.pending_len = 0;
            try self.recordOutput("\u{FFFD}");
        }
        self.finished = true;
        const fd = self.fd;
        self.fd = -1;
        try closeFd(fd);
    }

    fn elapsedUs(self: *const Recorder, now_ns: u64) u64 {
        if (now_ns <= self.start_ns) return 0;
        return (now_ns - self.start_ns) / std.time.ns_per_us;
    }

    fn writeHeader(self: *Recorder) !void {
        var w = std.Io.Writer.fixed(self.line_buf);
        var st: std.json.Stringify = .{ .writer = &w };
        try st.beginObject();
        try st.objectField("version");
        try st.write(if (self.format == .v2) @as(u32, 2) else @as(u32, 3));
        switch (self.format) {
            .v2 => {
                try st.objectField("width");
                try st.write(@as(u32, self.width));
                try st.objectField("height");
                try st.write(@as(u32, self.height));
            },
            .v3 => {
                try st.objectField("term");
                try st.beginObject();
                try st.objectField("cols");
                try st.write(@as(u32, self.width));
                try st.objectField("rows");
                try st.write(@as(u32, self.height));
                try st.endObject();
            },
        }
        try st.endObject();
        try w.writeByte('\n');
        try writeAll(self.fd, self.line_buf[0..w.end]);
    }

    /// Write one event, splitting `data` when a single line would exceed
    /// `max_line` or the remaining payload budget.
    fn writeEventLine(self: *Recorder, code: []const u8, data: []const u8, elapsed_us: u64) !void {
        var offset: usize = 0;
        var first = true;
        while (offset < data.len) {
            if (self.stopped or self.finished) return;
            if (self.output_events >= max_events) {
                self.stopped = true;
                return;
            }

            var w = std.Io.Writer.fixed(self.line_buf);
            var st: std.json.Stringify = .{ .writer = &w };
            try st.beginArray();
            if (self.format == .v2) {
                const secs = elapsed_us / std.time.us_per_s;
                const micros = elapsed_us % std.time.us_per_s;
                try st.print("{d}.{d:0>6}", .{ secs, micros });
            } else {
                const delta = if (first) elapsed_us -| self.last_elapsed_us else 0;
                const secs = delta / std.time.us_per_s;
                const micros = delta % std.time.us_per_s;
                try st.print("{d}.{d:0>6}", .{ secs, micros });
            }
            try st.write(code);

            // Write the data string body ourselves so the raw chunk can be
            // chosen to fit the line exactly; escaping is still std.json's.
            try st.beginWriteRaw();
            try w.writeByte('"');
            const room = self.line_buf.len - w.end - 3; // closing quote, ']', '\n'
            var take = encodedPrefixLen(data[offset..], room);
            const budget = max_total_output - self.output_bytes;
            if (take > budget) take = rawPrefixLen(data[offset..], budget);
            if (take == 0) {
                self.stopped = true;
                return;
            }
            try std.json.Stringify.encodeJsonStringChars(data[offset .. offset + take], .{}, &w);
            try w.writeByte('"');
            st.endWriteRaw();
            try st.endArray();
            try w.writeByte('\n');
            try writeAll(self.fd, self.line_buf[0..w.end]);

            if (code.len == 1 and code[0] == 'o') {
                self.output_events += 1;
                self.output_bytes += take;
            }
            if (first) {
                self.last_elapsed_us = elapsed_us;
                first = false;
            }
            offset += take;
        }
    }

    /// Lossy UTF-8 conversion of `pending ++ input` into `scratch`.
    /// Returns the sanitized bytes, possibly empty when only a partial
    /// sequence is available.
    fn sanitize(self: *Recorder, input: []const u8) ![]const u8 {
        self.scratch.clearRetainingCapacity();
        const pending = self.pending[0..self.pending_len];
        self.pending_len = 0;
        const total = pending.len + input.len;
        var i: usize = 0;
        while (i < total) {
            const b = byteAt(pending, input, i);
            if (b < 0x80) {
                try self.scratch.append(self.allocator, b);
                i += 1;
                continue;
            }
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch {
                try appendReplacement(&self.scratch, self.allocator);
                i += 1;
                continue;
            };
            const remaining = total - i;
            if (remaining < seq_len) {
                var plausible = true;
                var k: usize = 1;
                while (k < remaining) : (k += 1) {
                    if (byteAt(pending, input, i + k) & 0xC0 != 0x80) {
                        plausible = false;
                        break;
                    }
                }
                if (plausible) {
                    var k2: usize = 0;
                    while (k2 < remaining) : (k2 += 1)
                        self.pending[k2] = byteAt(pending, input, i + k2);
                    self.pending_len = @intCast(remaining);
                    return self.scratch.items;
                }
                try appendReplacement(&self.scratch, self.allocator);
                i += 1;
                continue;
            }
            var seq: [4]u8 = undefined;
            var k: usize = 0;
            while (k < seq_len) : (k += 1) seq[k] = byteAt(pending, input, i + k);
            _ = std.unicode.utf8Decode(seq[0..seq_len]) catch {
                try appendReplacement(&self.scratch, self.allocator);
                i += 1;
                continue;
            };
            try self.scratch.appendSlice(self.allocator, seq[0..seq_len]);
            i += seq_len;
        }
        return self.scratch.items;
    }
};

fn byteAt(pending: []const u8, input: []const u8, i: usize) u8 {
    return if (i < pending.len) pending[i] else input[i - pending.len];
}

fn appendReplacement(list: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try list.appendSlice(allocator, "\u{FFFD}");
}

fn unitLen(data: []const u8, i: usize) usize {
    const b = data[i];
    if (b < 0x80) return 1;
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// JSON-encoded length of one UTF-8 unit, matching
/// `std.json.Stringify.encodeJsonStringChars` with `.escape_unicode = false`.
fn unitCost(data: []const u8, i: usize) usize {
    const b = data[i];
    if (b < 0x20) return switch (b) {
        0x08, 0x09, 0x0A, 0x0C, 0x0D => 2,
        else => 6,
    };
    if (b == '"' or b == '\\') return 2;
    if (b < 0x80) return 1;
    return unitLen(data, i);
}

/// Longest prefix of `data` (ending on a UTF-8 boundary) whose JSON encoding
/// fits in `budget` bytes.
fn encodedPrefixLen(data: []const u8, budget: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const cost = unitCost(data, i);
        if (used + cost > budget) break;
        used += cost;
        i += unitLen(data, i);
    }
    return i;
}

/// Longest prefix of `data` (ending on a UTF-8 boundary) of at most
/// `budget` raw bytes.
fn rawPrefixLen(data: []const u8, budget: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const len = unitLen(data, i);
        if (used + len > budget) break;
        used += len;
        i += len;
    }
    return i;
}

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

fn closeFd(fd: posix.fd_t) !void {
    switch (linux.errno(linux.close(fd))) {
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
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
    /// exhausted and `loop` is off. With `loop` on, this wraps forever.
    pub fn next(self: *Player) ?Event {
        const ev = self.peek() orelse return null;
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

const FakeClock = struct {
    times: []const u64,
    index: usize = 0,

    fn now(ctx: ?*anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx.?));
        const i = @min(self.index, self.times.len - 1);
        self.index += 1;
        return self.times[i];
    }

    fn clock(self: *FakeClock) Clock {
        return .{ .context = self, .now_fn = FakeClock.now };
    }
};

fn testPath(allocator: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{}, 0);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try readSome(fd, &buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
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

/// Parse one line as a 3-element event array, copying the strings so they
/// outlive the JSON parse.
const TestEvent = struct {
    time: f64,
    code: u8,
    data: []u8,

    fn deinit(self: TestEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

fn parseEventForTest(allocator: std.mem.Allocator, line: []const u8) !TestEvent {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    const time = switch (items[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.InvalidEvent,
    };
    const code = switch (items[1]) {
        .string => |s| if (s.len == 1) s[0] else return error.InvalidEvent,
        else => return error.InvalidEvent,
    };
    const data = switch (items[2]) {
        .string => |s| s,
        else => return error.InvalidEvent,
    };
    return .{
        .time = time,
        .code = code,
        .data = try allocator.dupe(u8, data),
    };
}

test "v2: exact three-event recording, parsed back" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "v2.cast");
    defer allocator.free(path);

    var clock = FakeClock{ .times = &.{ 0, 0, 100_000_000, 1_250_000_000 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v2,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();

    try rec.recordOutput("hello");
    try rec.recordOutput(" world");
    try rec.recordOutput("\r\n");
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);

    // Note: lines of a Zig multiline string literal do not process escapes,
    // so the last line contains the four bytes `\r\n` JSON needs.
    const expected =
        \\{"version":2,"width":80,"height":24}
        \\[0.000000,"o","hello"]
        \\[0.100000,"o"," world"]
        \\[1.250000,"o","\r\n"]
        \\
    ;
    try testing.expectEqualStrings(expected, content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, allocator, lines.next().?, .{});
    defer header.deinit();
    try testing.expectEqual(@as(i64, 2), header.value.object.get("version").?.integer);
    try testing.expectEqual(@as(i64, 80), header.value.object.get("width").?.integer);
    try testing.expectEqual(@as(i64, 24), header.value.object.get("height").?.integer);

    const times = [_]f64{ 0.0, 0.1, 1.25 };
    const payloads = [_][]const u8{ "hello", " world", "\r\n" };
    for (times, payloads) |want_time, want_data| {
        const ev = try parseEventForTest(allocator, lines.next().?);
        defer ev.deinit(allocator);
        try testing.expectEqual(@as(u8, 'o'), ev.code);
        try testing.expectApproxEqAbs(want_time, ev.time, 1e-9);
        try testing.expectEqualStrings(want_data, ev.data);
    }
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(@as(usize, 3), rec.output_events);
}

test "v3: deltas are relative to the previous event, resizes included" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "v3.cast");
    defer allocator.free(path);

    var clock = FakeClock{ .times = &.{ 0, 0, 500_000_000, 1_000_000_000 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v3,
        .width = 80,
        .height = 24,
        .loop = true, // playback flag: must not affect the recording
        .clock = clock.clock(),
    });
    defer rec.deinit();

    try rec.recordOutput("a");
    try rec.recordResize(100, 40);
    try rec.recordOutput("b");
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);

    const expected =
        \\{"version":3,"term":{"cols":80,"rows":24}}
        \\[0.000000,"o","a"]
        \\[0.500000,"r","100x40"]
        \\[0.500000,"o","b"]
        \\
    ;
    try testing.expectEqualStrings(expected, content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, allocator, lines.next().?, .{});
    defer header.deinit();
    const term = header.value.object.get("term").?.object;
    try testing.expectEqual(@as(i64, 80), term.get("cols").?.integer);
    try testing.expectEqual(@as(i64, 24), term.get("rows").?.integer);

    var sum: f64 = 0;
    const want = [_]struct { dt: f64, code: u8, data: []const u8 }{
        .{ .dt = 0.0, .code = 'o', .data = "a" },
        .{ .dt = 0.5, .code = 'r', .data = "100x40" },
        .{ .dt = 0.5, .code = 'o', .data = "b" },
    };
    for (want) |w| {
        const ev = try parseEventForTest(allocator, lines.next().?);
        defer ev.deinit(allocator);
        try testing.expectEqual(w.code, ev.code);
        try testing.expectEqualStrings(w.data, ev.data);
        try testing.expectApproxEqAbs(w.dt, ev.time, 1e-9);
        sum += ev.time;
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-9);
    // The resize line is an event but not an output event (kmscon's limit).
    try testing.expectEqual(@as(usize, 2), rec.output_events);
}

test "arbitrary bytes produce valid JSON with lossy UTF-8" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "binary.cast");
    defer allocator.free(path);

    var clock = FakeClock{ .times = &.{ 0, 0 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v2,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();

    // NUL, an invalid lead byte, another invalid lead byte, ASCII.
    try rec.recordOutput(&.{ 0x00, 0xFF, 0xFE, 'A' });
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    const ev = try parseEventForTest(allocator, lines.next().?);
    defer ev.deinit(allocator);
    try testing.expectEqualStrings("\x00\u{FFFD}\u{FFFD}A", ev.data);
}

test "a UTF-8 sequence split across calls stays one code point" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "split.cast");
    defer allocator.free(path);

    // "é" is C3 A9.
    var clock = FakeClock{ .times = &.{ 0, 0, 10_000_000 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v2,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();

    try rec.recordOutput(&.{0xC3});
    try rec.recordOutput(&.{0xA9});
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    const ev = try parseEventForTest(allocator, lines.next().?);
    defer ev.deinit(allocator);
    try testing.expectEqualStrings("é", ev.data);
    try testing.expectEqual(@as(usize, 1), rec.output_events);
}

test "finish flushes a dangling UTF-8 prefix as one replacement character" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "dangling.cast");
    defer allocator.free(path);

    // E2 82 is the start of a three-byte sequence; the third byte never
    // arrives, so finish emits a single U+FFFD, not two.
    var clock = FakeClock{ .times = &.{ 0, 0, 10_000_000 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v3,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();

    try rec.recordOutput(&.{ 0xE2, 0x82 });
    try testing.expectEqual(@as(usize, 0), rec.output_events);
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    const ev = try parseEventForTest(allocator, lines.next().?);
    defer ev.deinit(allocator);
    try testing.expectEqualStrings("\u{FFFD}", ev.data);
    try testing.expectEqual(@as(usize, 1), rec.output_events);
}

test "clock regression yields a zero interval" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "regress.cast");
    defer allocator.free(path);

    var clock = FakeClock{ .times = &.{ 1_000_000_000, 500_000_000 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v3,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();
    try rec.recordOutput("x");
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    const ev = try parseEventForTest(allocator, lines.next().?);
    defer ev.deinit(allocator);
    try testing.expectEqual(@as(f64, 0.0), ev.time);
}

test "hard limit: a payload larger than one line is split, and the 2 MiB cap stops recording" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "limits.cast");
    defer allocator.free(path);

    const chunk = try allocator.alloc(u8, 300 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 'A');

    var clock = FakeClock{ .times = &.{ 0, 0 } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v3,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();

    try rec.recordOutput(chunk);
    try testing.expectEqual(@as(usize, 2), rec.output_events);

    const content = try readAll(allocator, path);
    defer allocator.free(content);

    // Every physical line fits the player's 256 KiB limit, newline included.
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    var rebuilt: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line.len + 1 <= max_line);
        const ev = try parseEventForTest(allocator, line);
        defer ev.deinit(allocator);
        try testing.expectEqual(@as(u8, 'o'), ev.code);
        rebuilt += ev.data.len;
    }
    try testing.expectEqual(chunk.len, rebuilt);

    // Fill the file to the 2 MiB payload cap; further output is dropped.
    const big = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(big);
    @memset(big, 'B');
    try rec.recordOutput(big);
    try rec.recordOutput(big);
    try rec.recordOutput(big); // would overflow the cap

    try testing.expect(rec.stopped);
    try rec.finish();

    var player = try Player.init(allocator, path, false);
    defer player.deinit();
    var total: usize = 0;
    while (player.next()) |ev| total += ev.data.len;
    try testing.expectEqual(max_total_output, total);
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

test "long v3 intervals are recorded verbatim and clamped on playback" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(allocator, &tmp, "long.cast");
    defer allocator.free(path);

    // Two hours of idleness: the writer keeps the real interval (lossless),
    // the player clamps it to `sec_to_ns`'s 3600 s like kmscon does.
    var clock = FakeClock{ .times = &.{ 0, 7200 * std.time.ns_per_s } };
    var rec = try Recorder.init(allocator, path, .{
        .version = .v3,
        .width = 80,
        .height = 24,
        .clock = clock.clock(),
    });
    defer rec.deinit();
    try rec.recordOutput("x");
    try rec.finish();

    const content = try readAll(allocator, path);
    defer allocator.free(content);
    try testing.expect(std.mem.endsWith(u8, content, "[7200.000000,\"o\",\"x\"]\n"));

    var player = try Player.init(allocator, path, false);
    defer player.deinit();
    const ev = player.next().?;
    try testing.expectEqualStrings("x", ev.data);
    try testing.expectEqual(max_event_delay_ns, ev.delay_ns);
}