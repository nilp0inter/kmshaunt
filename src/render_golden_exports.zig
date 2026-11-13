//! src/render_golden_exports.zig -- src-side module root for the T2 headless
//! golden tool (tools/render_golden.zig, ROADMAP §4 T2).
//!
//! Zig 0.17 confines @import to the module root's directory tree ("import of
//! file outside module path"), so a root under tools/ cannot reach src/ --
//! the same confinement that puts test_spng.zig at the repository root. This
//! file gives the tool one named module ("kmshaunt") rooted inside src/ that
//! re-exports exactly the modules the golden renderer needs, no more. It is
//! not part of the kmshaunt executable or `zig build test`; only the
//! render_golden exe/test artifacts import it (wiring: tools/render_golden.zig
//! header).

pub const vt = @import("vt.zig");
pub const cpu = @import("render/cpu.zig");
pub const discovery = @import("font/discovery.zig");
pub const palette = @import("misc/palette.zig");
pub const render = @import("render.zig");
pub const framebuffer = @import("framebuffer.zig");
