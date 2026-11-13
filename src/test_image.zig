//! src/test_image.zig -- test root for src/render/image.zig.
//!
//! `zig test src/render/image.zig` cannot resolve the canonical
//! `@import("../framebuffer.zig")` (import outside the module path), so
//! the tests run from this src-level root instead:
//!
//!     nix run nixpkgs#zig -- test src/test_image.zig

test {
    _ = @import("render/image.zig");
}
