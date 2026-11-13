//! Temporary combined test root: verifies all independent green modules
//! compile together (type identity across imports). Replaced by the real
//! integration test root when build.zig wiring lands.
test {
    _ = @import("loop.zig");
    _ = @import("misc/pty.zig");
    _ = @import("misc/palette.zig");
    _ = @import("misc/issue.zig");
    _ = @import("misc/asciicast.zig");
    _ = @import("video/layout.zig");
    _ = @import("framebuffer.zig");
    _ = @import("video.zig");
    _ = @import("seat.zig");
    _ = @import("session.zig");
    _ = @import("render.zig");
    _ = @import("input/keymap_table.zig");
    _ = @import("font/atlas.zig");
    _ = @import("render/decorations.zig");
    _ = @import("font/sprite.zig");
    _ = @import("font/psf.zig");
    _ = @import("font/bitmap.zig");
}
