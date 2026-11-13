//! Integration test root: every kmshaunt module's tests in one libc-linked
//! binary (`zig build test`). The C bindings and system libraries are wired
//! in build.zig exactly as for the executable. The spng decoder's tests run
//! from the repository-root harness test_spng.zig (second test artifact of
//! the same step): they need tools/png.zig, outside this module's tree.

test {
    // Entry point.
    _ = @import("main.zig");
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
    // C-interop modules.
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
    // Src-level roots carrying their own integration tests on top of the
    // module tests (drm3d GBM/EGL/GL backend tests; fake libinput event
    // queue over a real xkb keymap; fake libseat backend protocol tests;
    // real libseat ops over the noop backend; fake sd-bus locale1 reader;
    // fake sd-login multiseat monitor).
    _ = @import("test_drm3d.zig");
    _ = @import("test_libinput.zig");
    _ = @import("test_libseat.zig");
    _ = @import("test_libseat_real.zig");
    _ = @import("test_locale1.zig");
    _ = @import("test_manager.zig");
    _ = @import("test_multiseat.zig");
}
