/* translate-c shim for the HarfBuzz bindings, shared under two module
 * names: "hb-c" (src/font/shaper.zig) and "harfbuzz-c" (src/font/color.zig).
 * Superset of both modules' documented shims: shaper needs hb.h + hb-ft.h,
 * color additionally needs hb-raster.h (libharfbuzz-raster, built by the
 * nix/overlay.nix withRaster override). Include paths come from harfbuzz.pc
 * and freetype2.pc (hb-ft.h includes ft2build.h). */
#include <hb.h>
#include <hb-ft.h>
#include <hb-raster.h>
