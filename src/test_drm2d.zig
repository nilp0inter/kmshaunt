//! Test root for the drm2d backend (ROADMAP M1.3).
//!
//! `zig test src/video/drm2d.zig` cannot import ../video.zig (imports outside
//! the root file's module path are rejected), so the test root lives at the
//! src level and pulls the backend's tests in:
//!
//!     nix run nixpkgs#zig -- test src/test_drm2d.zig

test {
    _ = @import("video/drm2d.zig");
}
