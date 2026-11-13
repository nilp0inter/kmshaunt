//! src/test_vt_fake.zig -- unit-test root for `src/seat/vt_fake.zig`
//! (ROADMAP M6.2 fake VT).
//!
//! Zig 0.17 sets a module's root directory to the root source file's
//! directory, so a root at `src/seat/vt_fake.zig` itself could not import
//! the shared `src/seat.zig` contract ("import of file outside module
//! path"). This one-line root keeps the canonical `../seat.zig` import and
//! the single `Seat` type identity, and gives a runnable command:
//!
//!     zig test src/test_vt_fake.zig
//!
//! Integration folds this root into build.zig's test step.

test {
    _ = @import("seat/vt_fake.zig");
}