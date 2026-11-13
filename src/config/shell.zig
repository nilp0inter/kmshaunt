//! POSIX-shell-like command splitting for the `login=` config-file value
//! (kmscon `shl_split_command_string`, `src/shl/misc.h:186-393`, used by
//! `file_login` in `src/config.c:422-454`).
//!
//! Rules, replicated exactly:
//!   * unquoted space/tab separates words;
//!   * `'…'` quotes everything literally (backslash included);
//!   * `"…"` keeps spaces; backslash escapes only `"` and `\`, otherwise
//!     it is literal;
//!   * unquoted `\` escapes the next character; a trailing `\` is an error;
//!   * an unterminated quote is an error;
//!   * empty quoted sections produce NO word (`""` alone yields nothing) —
//!     a kmscon quirk that differs from POSIX shells.

const std = @import("std");
const diag_mod = @import("diag.zig");

pub const Error = diag_mod.Error;
pub const Diag = diag_mod.Diag;

/// Split `arg` into argv words. The returned slice and its strings are
/// allocated with `allocator` (typically the config arena).
pub fn splitCommandString(
    allocator: std.mem.Allocator,
    arg: []const u8,
    diag: *Diag,
) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (words.items) |w| allocator.free(w);
        words.deinit(allocator);
    }
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);

    const State = enum { unquoted, double, single };
    var state: State = .unquoted;
    var in_word = false;

    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        const c = arg[i];
        switch (state) {
            .unquoted => switch (c) {
                ' ', '\t' => {
                    if (in_word) {
                        const owned = try word.toOwnedSlice(allocator);
                        words.append(allocator, owned) catch |err| {
                            allocator.free(owned);
                            return err;
                        };
                        in_word = false;
                    }
                },
                '"' => state = .double,
                '\'' => state = .single,
                '\\' => {
                    if (i + 1 == arg.len) {
                        diag.print("trailing backslash in login argument", .{});
                        return error.InvalidValue;
                    }
                    i += 1;
                    try word.append(allocator, arg[i]);
                    in_word = true;
                },
                else => {
                    try word.append(allocator, c);
                    in_word = true;
                },
            },
            .double => switch (c) {
                '"' => state = .unquoted,
                '\\' => {
                    if (i + 1 < arg.len and (arg[i + 1] == '"' or arg[i + 1] == '\\')) {
                        i += 1;
                        try word.append(allocator, arg[i]);
                    } else {
                        try word.append(allocator, '\\');
                    }
                    in_word = true;
                },
                else => {
                    try word.append(allocator, c);
                    in_word = true;
                },
            },
            .single => switch (c) {
                '\'' => state = .unquoted,
                else => {
                    try word.append(allocator, c);
                    in_word = true;
                },
            },
        }
    }

    if (state != .unquoted) {
        diag.print("unterminated quote in login argument", .{});
        return error.InvalidValue;
    }
    if (in_word) {
        const owned = try word.toOwnedSlice(allocator);
        words.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return words.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn splitOk(arg: []const u8) ![]const []const u8 {
    var diag = Diag{};
    return splitCommandString(testing.allocator, arg, &diag) catch |err| {
        std.debug.print("split '{s}' failed: {s}\n", .{ arg, diag.message() });
        return err;
    };
}

fn freeAll(argv: []const []const u8) void {
    for (argv) |w| testing.allocator.free(w);
    testing.allocator.free(argv);
}

test "plain words and tabs" {
    const argv = try splitOk("/bin/bash -i");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 2), argv.len);
    try testing.expectEqualStrings("/bin/bash", argv[0]);
    try testing.expectEqualStrings("-i", argv[1]);

    const argv2 = try splitOk("a\tb  c");
    defer freeAll(argv2);
    try testing.expectEqual(@as(usize, 3), argv2.len);
    try testing.expectEqualStrings("b", argv2[1]);
}

test "single quotes keep everything literal" {
    const argv = try splitOk("/bin/sh -c 'echo hello  world'");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("echo hello  world", argv[2]);

    const argv2 = try splitOk("'a\\b'");
    defer freeAll(argv2);
    try testing.expectEqualStrings("a\\b", argv2[0]);
}

test "double quotes keep spaces, backslash escapes only quote and backslash" {
    const argv = try splitOk("\"a b\" c");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 2), argv.len);
    try testing.expectEqualStrings("a b", argv[0]);

    const argv2 = try splitOk("\"a\\\"b\\\\c\\nd\"");
    defer freeAll(argv2);
    try testing.expectEqualStrings("a\"b\\c\\nd", argv2[0]);
}

test "unquoted backslash escapes the next character" {
    const argv = try splitOk("a\\ b c\\\\d");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 2), argv.len);
    try testing.expectEqualStrings("a b", argv[0]);
    try testing.expectEqualStrings("c\\d", argv[1]);
}

test "quotes join adjacent sections into one word" {
    const argv = try splitOk("a\"b c\"'d e'f");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 1), argv.len);
    try testing.expectEqualStrings("ab cd ef", argv[0]);
}

test "empty quoted sections produce no word (kmscon quirk)" {
    const argv = try splitOk("\"\" ''");
    defer freeAll(argv);
    try testing.expectEqual(@as(usize, 0), argv.len);

    const argv2 = try splitOk("a\"\"b");
    defer freeAll(argv2);
    try testing.expectEqual(@as(usize, 1), argv2.len);
    try testing.expectEqualStrings("ab", argv2[0]);

    const argv3 = try splitOk("");
    defer freeAll(argv3);
    try testing.expectEqual(@as(usize, 0), argv3.len);
}

test "trailing backslash and unterminated quotes are errors" {
    var diag = Diag{};
    try testing.expectError(error.InvalidValue, splitCommandString(testing.allocator, "abc\\", &diag));
    try testing.expectError(error.InvalidValue, splitCommandString(testing.allocator, "\"abc", &diag));
    try testing.expectError(error.InvalidValue, splitCommandString(testing.allocator, "'abc", &diag));
    try testing.expectError(error.InvalidValue, splitCommandString(testing.allocator, "a \"b'", &diag));
}
