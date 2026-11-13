/* translate-c shim for the FreeType bindings, shared under two module
 * names: "freetype_c" (src/font/discovery.zig) and "freetype-c"
 * (src/font/color.zig). Superset of both modules' documented shims:
 * discovery needs ftsynth.h, color needs the SFNT table and color headers.
 * Include path comes from freetype2.pc (include/freetype2). */
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_COLOR_H
#include <freetype/ftsynth.h>
