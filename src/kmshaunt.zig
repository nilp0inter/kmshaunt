//! Executable root: re-exports main.zig's entry point and std_options
//! (std.options resolves from the compilation root) and pulls every
//! kmshaunt module into the compilation, so `zig build` type-checks the
//! whole tree against the C bindings.

const main_mod = @import("main.zig");

pub const main = main_mod.main;
pub const std_options = main_mod.std_options;

comptime {
    // Pure modules.
    _ = @import("loop.zig");
    _ = @import("framebuffer.zig");
    _ = @import("video.zig");
    _ = @import("seat.zig");
    _ = @import("session.zig");
    _ = @import("render.zig");
    _ = @import("config/config.zig");
    _ = @import("config/keysyms.zig");
    _ = @import("config/shell.zig");
    _ = @import("config/display.zig");
    _ = @import("config/grab.zig");
    _ = @import("config/diag.zig");
    _ = @import("misc/pty.zig");
    _ = @import("misc/palette.zig");
    _ = @import("misc/issue.zig");
    _ = @import("misc/asciicast.zig");
    _ = @import("input/keymap_table.zig");
    _ = @import("video/layout.zig");
    _ = @import("video/fbdev.zig");
    _ = @import("seat/vt_real.zig");
    _ = @import("seat/vt_fake.zig");
    _ = @import("font/atlas.zig");
    _ = @import("font/sprite.zig");
    _ = @import("font/psf.zig");
    _ = @import("font/bitmap.zig");
    _ = @import("render/decorations.zig");
    _ = @import("render/image.zig");
    // C-interop modules (bindings wired in build.zig).
    _ = @import("vt.zig");
    _ = @import("video/drm2d.zig");
    _ = @import("input/xkb.zig");
    _ = @import("input/libinput.zig");
    _ = @import("seat/libseat.zig");
    _ = @import("seat/multiseat.zig");
    _ = @import("session/terminal.zig");
    _ = @import("session/manager.zig");
    _ = @import("render/cpu.zig");
    _ = @import("font/discovery.zig");
    _ = @import("font/shaper.zig");
    _ = @import("font/color.zig");
    _ = @import("misc/spng_decode.zig");
    _ = @import("misc/locale1.zig");
}
