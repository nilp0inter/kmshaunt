//! src/test_vt_real.zig -- test root for the real VT seat backend.
//!
//! `src/seat/vt_real.zig` imports `../seat.zig`, so it cannot be its own
//! `zig test` root (a module may not import files outside its root
//! directory). This src-level root is inside the same module as the code
//! under test and pulls the file's tests in:
//!
//!     nix run nixpkgs#zig -- test src/test_vt_real.zig

test {
    _ = @import("seat/vt_real.zig");
}