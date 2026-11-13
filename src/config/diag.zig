//! Shared parse-error set and diagnostic buffer for the config parsers.
//!
//! Every parse failure is a typed error; the human-readable detail (naming
//! the offending option and value) is written into a `Diag` by the parser
//! and copied into `Config.error_message` by the top-level entry points.

const std = @import("std");

pub const Error = error{
    /// CLI: an option that is not registered (including `no-` forms of
    /// argument-taking options, which kmscon does not register).
    UnknownOption,
    /// CLI: an argument-taking option was given no value.
    MissingArgument,
    /// A no-argument (boolean) option was given a value (`--mouse=1`,
    /// `mouse=1` in a file).
    UnexpectedArgument,
    /// File: an argument-taking key appeared without a value.
    MissingValue,
    /// A value failed its type parser (uint, color, grab, mode, screen,
    /// gpus, login argv, …). The `Diag` carries the detail.
    InvalidValue,
    /// File: a bare key ran to end of file without `\n`, `#` or `=`
    /// (kmscon-options.md §3 "Overflow").
    UnterminatedKey,
    /// CLI: positional arguments remain and `--login` was not given.
    UnparsedArguments,
    /// CLI: `--login` was given but no arguments remain for the argv.
    MissingLoginArguments,
    /// A config file exists but is not readable.
    AccessDenied,
    /// A config file could not be read.
    ReadError,
    OutOfMemory,
};

/// Fixed-buffer diagnostic message. Parsers print the detail here; the
/// buffer avoids allocating on the error path. Overlong messages truncate.
pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn reset(self: *Diag) void {
        self.len = 0;
    }

    pub fn print(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch {
            self.len = self.buf.len;
            return;
        };
        self.len += s.len;
    }

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};
