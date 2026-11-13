//! src/test_fbdev.zig -- test root for the fbdev backend.
//!
//! `src/video/fbdev.zig` imports `../video.zig` and `../framebuffer.zig`
//! canonically, so its Zig module root must be `src/`. Running
//! `zig test src/video/fbdev.zig` would make `src/video/` the module root and
//! reject those imports as escaping it; this root file keeps the module at
//! `src/`:
//!
//!     zig test src/test_fbdev.zig
test {
    _ = @import("video/fbdev.zig");
}