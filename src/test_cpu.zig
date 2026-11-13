//! src/test_cpu.zig -- test root for the CPU renderer (src/render/cpu.zig).
//!
//! cpu.zig lives in src/render/ and imports parent files (vt.zig,
//! framebuffer.zig, font/*), so it needs this src-level root. The tests
//! use a REAL libghostty-vt terminal and the HOST fontconfig fonts, so
//! six translate-c modules and five C libraries are required: vt-c,
//! fontconfig_c, freetype_c (discovery), hb-c (shaper), freetype-c and
//! harfbuzz-c (color).
//!
//! Bindings (reproduce when missing):
//!   * vt-c: extract the ghostty dep include dir from ~/.cache/zig/p/,
//!     then: zig translate-c src/vt-c.h -I <dep>/include -lc > /tmp/vt_c.zig
//!   * fontconfig_c / freetype_c: shims + translate-c per the header of
//!     src/font/discovery.zig.
//!   * hb-c (hb.h + hb-ft.h): shim + translate-c per the header of
//!     src/font/shaper.zig.
//!   * freetype-c / harfbuzz-c (FT_TRUETYPE_TABLES_H / FT_COLOR_H /
//!     hb-raster.h shims): per the header of src/font/color.zig.
//!
//! Run from the repo root (zig = 0.17.1; the -L ghostty directory is
//! whichever .zig-cache/o/<hash> holds libghostty-vt.so, found with
//! `fd libghostty-vt .zig-cache`):
//!
//!   FCLIB=/nix/store/p3y4rk4gjnhs80339qq7jixjbhplqc16-fontconfig-2.18.3-lib
//!   FTLIB=/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3
//!   HBLIB=/nix/store/7ycrkhagmaxkd4ffxn3b00ylxb7hkc20-harfbuzz-14.5.1
//!   nix run nixpkgs#zig -- test \
//!     --dep vt-c --dep fontconfig_c --dep freetype_c \
//!     --dep hb-c --dep freetype-c --dep harfbuzz-c \
//!     -Mroot=src/test_cpu.zig \
//!     -Mvt-c=/tmp/vt_c.zig \
//!     -Mfontconfig_c=/tmp/kmshaunt_fontconfig_c.zig \
//!     -Mfreetype_c=/tmp/kmshaunt_freetype_c.zig \
//!     -Mhb-c=/tmp/shaper_probe/hb_c.zig \
//!     -Mfreetype-c=/tmp/kmshaunt-color/freetype_c.zig \
//!     -Mharfbuzz-c=/tmp/kmshaunt-color/harfbuzz_c.zig \
//!     -lc -lghostty-vt -lfontconfig -lfreetype -lharfbuzz -lharfbuzz-raster \
//!     -L.zig-cache/o/16861fd85abb75eb4433b66ad767d202 \
//!     -L$FCLIB/lib -L$FTLIB/lib -L$HBLIB/lib

test {
    _ = @import("render/cpu.zig");
}
