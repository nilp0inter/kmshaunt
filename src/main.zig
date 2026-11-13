//! kmshaunt entry point: argument parsing and startup.
//!
//! The console itself is not implemented yet; M0 only wires the build,
//! the package and the first VM test around this skeleton.

const std = @import("std");

const version = "0.0.1";

const usage =
    \\Usage: kmshaunt [OPTION]
    \\
    \\A Linux KMS/DRM console on top of libghostty-vt.
    \\
    \\Options:
    \\  --version  Print the version and exit
    \\  --help     Print this help and exit
    \\
;

/// What the command line asks the program to do.
pub const Action = enum {
    /// Print the version string to stdout and exit successfully.
    print_version,
    /// Print the usage text to stdout and exit successfully.
    print_help,
    /// Run the console. Not implemented yet.
    run,
};

/// The outcome of parsing the command line.
pub const ParseResult = union(enum) {
    ok: Action,
    /// The first unrecognized argument; report it on stderr and exit 2.
    unknown: []const u8,
};

/// Parse the arguments after the program name.
///
/// The first recognized flag wins; anything else is reported as unknown.
pub fn parseArgs(args: []const []const u8) ParseResult {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .{ .ok = .print_version };
        if (std.mem.eql(u8, arg, "--help")) return .{ .ok = .print_help };
        return .{ .unknown = arg };
    }
    return .{ .ok = .run };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    switch (parseArgs(args[1..])) {
        .ok => |action| switch (action) {
            .print_version => {
                try stdout.print("kmshaunt {s}\n", .{version});
                try stdout.flush();
            },
            .print_help => {
                try stdout.writeAll(usage);
                try stdout.flush();
            },
            .run => {
                try stderr.writeAll("kmshaunt: not implemented yet\n");
                try stderr.flush();
                std.process.exit(1);
            },
        },
        .unknown => |arg| {
            try stderr.print("kmshaunt: unrecognized argument '{s}'\n", .{arg});
            try stderr.writeAll("Try 'kmshaunt --help' for more information.\n");
            try stderr.flush();
            std.process.exit(2);
        },
    }
}

test "parseArgs: no arguments runs the console" {
    try std.testing.expectEqual(Action.run, parseArgs(&.{}).ok);
}

test "parseArgs: --version prints the version" {
    try std.testing.expectEqual(Action.print_version, parseArgs(&.{"--version"}).ok);
}

test "parseArgs: --help prints the usage" {
    try std.testing.expectEqual(Action.print_help, parseArgs(&.{"--help"}).ok);
}

test "parseArgs: unknown argument is reported" {
    const result = parseArgs(&.{"--bogus"});
    try std.testing.expectEqualStrings("--bogus", result.unknown);
}

test "parseArgs: the first argument decides" {
    try std.testing.expectEqual(Action.print_version, parseArgs(&.{ "--version", "--help" }).ok);
    try std.testing.expectEqualStrings("--bogus", parseArgs(&.{ "--bogus", "--version" }).unknown);
}

test "parseArgs: a bare word is unknown" {
    try std.testing.expectEqualStrings("run", parseArgs(&.{"run"}).unknown);
}
