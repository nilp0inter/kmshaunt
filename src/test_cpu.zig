//! src/test_cpu.zig -- test root for the CPU renderer (src/render/cpu.zig).
//!
//! cpu.zig lives in src/render/ and imports parent files (vt.zig,
//! framebuffer.zig, font/*), so it needs this src-level root. The tests
//! use a REAL libghostty-vt terminal and the HOST fontconfig/monospace
//! face, so three translate-c modules and three C libraries are required.
//!
//! Bindings (reproduce when missing; see the headers of src/vt.zig and
//! src/font/discovery.zig for the full recipes):
//!
//!   # vt-c: extract the ghostty dep include dir from ~/.cache/zig/p/,
//!   # then: zig translate-c src/vt-c.h -I <dep>/include -lc > /tmp/vt_c.zig
//!   # fontconfig_c / freetype_c: shims + translate-c per discovery.zig.
//!
//! Run from the repo root (zig = 0.17.1; the -L ghostty directory is
//! whichever .zig-cache/o/<hash> holds libghostty-vt.so, found with
//! `fd libghostty-vt .zig-cache`):
//!
//!   FCLIB=/nix/store/p3y4rk4gjnhs80339qq7jixjbhplqc16-fontconfig-2.18.3-lib
//!   FTLIB=/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3
//!   nix run nixpkgs#zig -- test \
//!     --dep vt-c --dep fontconfig_c --dep freetype_c \
//!     -Mroot=src/test_cpu.zig \
//!     -Mvt-c=/tmp/vt_c.zig \
//!     -Mfontconfig_c=/tmp/kmshaunt_fontconfig_c.zig \
//!     -Mfreetype_c=/tmp/kmshaunt_freetype_c.zig \
//!     -lc -lghostty-vt -lfontconfig -lfreetype \
//!     -L.zig-cache/o/16861fd85abb75eb4433b66ad767d202 \
//!     -L$FCLIB/lib -L$FTLIB/lib

test {
    _ = @import("render/cpu.zig");
}
