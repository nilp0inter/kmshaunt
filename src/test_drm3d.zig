//! Test root for the drm3d backend (ROADMAP M5.1).
//!
//! `zig test src/video/drm3d.zig` cannot import ../video.zig (imports outside
//! the root file's module path are rejected), so the test root lives at the
//! src level and pulls the backend's tests in:
//!
//!     nix run nixpkgs#zig -- test src/test_drm3d.zig

test {
    _ = @import("video/drm3d.zig");
}
