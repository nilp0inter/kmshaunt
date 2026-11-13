//! src/test_decorations.zig -- unit-test root for
//! `src/render/decorations.zig` (ROADMAP M3.7).
//!
//! Zig 0.17 sets a module's root directory to the root source file's
//! directory, so a root at `src/render/decorations.zig` itself cannot import
//! the shared `framebuffer.zig` contract in `src/` ("import of file outside
//! module path"). This one-line root keeps the canonical import and the
//! single `Framebuffer` type identity, and gives a runnable command:
//!
//!     zig test src/test_decorations.zig
//!
//! Integration folds this root into build.zig's test step.

test {
    _ = @import("render/decorations.zig");
}