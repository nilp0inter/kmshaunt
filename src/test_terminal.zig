//! src/test_terminal.zig -- test root for the terminal session.
//!
//! `src/session/terminal.zig` imports parent files (../vt.zig, ../session.zig,
//! ../misc/pty.zig, ../config/config.zig, ../render.zig), so it cannot be its
//! own `zig test` root. This src-level root pulls its tests in. vt.zig needs
//! the "vt-c" module and libghostty-vt; follow the standalone recipe in
//! src/vt.zig's header (run from the repo root):
//!
//!   PKG=ghostty-1.4.1-dev-5UdBC7mPUgFIzAVXNJOixiryPYogwYwnmN0zZWud4iSr
//!   mkdir -p /tmp/ghostty-dep
//!   tar -xzf ~/.cache/zig/p/$PKG.tar.gz -C /tmp/ghostty-dep $PKG/include
//!   nix run nixpkgs#zig -- translate-c src/vt-c.h \
//!       -I /tmp/ghostty-dep/$PKG/include -lc > /tmp/vt_c.zig
//!   nix run nixpkgs#zig -- test --dep vt-c -Mroot=src/test_terminal.zig \
//!       -Mvt-c=/tmp/vt_c.zig \
//!       -lc -L.zig-cache/o/16861fd85abb75eb4433b66ad767d202 -lghostty-vt
//!
//! (The -L directory is whichever .zig-cache/o/<hash> holds
//! libghostty-vt.so; find it with: fd libghostty-vt .zig-cache)

test {
    _ = @import("session/terminal.zig");
}
