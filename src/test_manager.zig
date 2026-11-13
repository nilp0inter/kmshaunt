//! src/test_manager.zig -- test root for the session manager (ROADMAP M6.3).
//!
//! `src/session/manager.zig` imports parent files (../session.zig,
//! ../config/config.zig), so it cannot be its own `zig test` root. This
//! src-level root pulls its tests in. Everything is hermetic (std only,
//! no C libraries, no named modules). Run from the repo root:
//!
//!   nix run nixpkgs#zig -- test src/test_manager.zig

test {
    _ = @import("session/manager.zig");
}