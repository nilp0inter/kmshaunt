//! Color glyph rasterization (ROADMAP M3.5, decision D7).
//!
//! Two sources of color glyphs, one output format:
//!
//!   * CBDT and sbix bitmap strikes through FreeType `FT_LOAD_COLOR`.
//!     Bitmap-only faces expose fixed strikes; the closest strike is
//!     selected and box-scaled to the requested pixel size.
//!   * COLRv0 and COLRv1 paint graphs through HarfBuzz `hb_raster_paint`
//!     (libharfbuzz-raster, stable since HarfBuzz 13.0).
//!
//! Routing consults the SFNT tables, not just `FT_FACE_FLAG_COLOR`:
//! FreeType >= 2.13 sets that flag for COLR faces too. A face with CBDT or
//! sbix takes the FreeType path; otherwise a COLR table takes the hb-raster
//! path. `FT_Load_Sfnt_Table` probes the tables without loading them.
//!
//! Output format (both paths, verified empirically in the tests below):
//! **BGRA8, premultiplied alpha**, rows top-down, tightly packed
//! (`pitch == width * 4`). FreeType documents `FT_LOAD_COLOR` bitmaps as
//! premultiplied BGRA (freetype.h, FT_LOAD_COLOR); hb-raster composites in
//! premultiplied BGRA32 (hb-raster-paint.cc, `color_to_premul_pixel`:
//! `b | g<<8 | r<<16 | a<<24`, little-endian byte order B,G,R,A). No
//! conversion is needed between the two paths.
//!
//! Geometry follows FreeType bitmap conventions: `bearing_x` is the left
//! edge relative to the pen origin, `bearing_y` the top edge above the
//! baseline (both in pixels, y up). hb-raster images are stored bottom-up
//! in glyph space (row 0 = `y_origin`, the bottom edge), so rows are flipped
//! on copy and `bearing_y = y_origin + height`.
//!
//! C interop: this module imports two translate-c modules, `freetype-c`
//! (ft2build.h + FT_FREETYPE_H + FT_TRUETYPE_TABLES_H + FT_COLOR_H) and
//! `harfbuzz-c` (hb.h + hb-ft.h + hb-raster.h), wired with `b.addTranslateC`
//! like `vt-c` (ROADMAP D3). It takes a raw `FT_Face` handle and does not
//! depend on discovery.zig.
//!
//! Thread safety: no global state. Every call mutates the caller's `FT_Face`
//! (pixel size, glyph slot) and creates/destroys its own HarfBuzz objects, so
//! a face must not be used concurrently. kmshaunt is single-threaded
//! (ROADMAP D2); callers serialize per face. Results are owned buffers meant
//! to be cached by the glyph atlas; nothing is cached here.
//!
//! Standalone test run (fonts and store paths verified on this machine;
//! override with KMSHAUNT_TEST_{CBDT,COLR,SBIX,TEXT}_FONT):
//!
//!   nix run nixpkgs#zig -- test \
//!     --dep freetype-c --dep harfbuzz-c \
//!     -Mroot=src/font/color.zig \
//!     -Mfreetype-c=/tmp/kmshaunt-color/freetype_c.zig \
//!     -Mharfbuzz-c=/tmp/kmshaunt-color/harfbuzz_c.zig \
//!     -lc \
//!     -I/nix/store/jpnd5wfvvva2hp63wl348ldxgl4lk25a-freetype-2.14.3-dev/include/freetype2 \
//!     -I/nix/store/blfwkd0n9d2k0yfh30c1q4m971zd52d9-harfbuzz-14.5.1-dev/include \
//!     -L/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3/lib \
//!     -L/nix/store/7ycrkhagmaxkd4ffxn3b00ylxb7hkc20-harfbuzz-14.5.1/lib \
//!     -lfreetype -lharfbuzz -lharfbuzz-raster
//!
//! The translate-c inputs live in /tmp/kmshaunt-color/{freetype,harfbuzz}_shim.h;
//! regenerate with `zig translate-c <shim> -lc -I<ft-dev>/include/freetype2
//! [-I<hb-dev>/include]`. Test fonts: nixpkgs#noto-fonts-color-emoji (CBDT),
//! googlefonts/color-fonts noto-glyf_colr_1.ttf (COLRv1) and noto-sbix.ttf
//! (sbix), nixpkgs#dejavu_fonts (non-color text).

const std = @import("std");
const ft = @import("freetype-c");
const hb = @import("harfbuzz-c");

// translate-c types the C macros as c_long/c_int; pin them to the exact
// parameter types once instead of casting at every call site.
const load_color: ft.FT_Int32 = @intCast(ft.FT_LOAD_COLOR);
const load_outline: ft.FT_Int32 = @intCast(ft.FT_LOAD_NO_BITMAP | ft.FT_LOAD_NO_HINTING);
const render_normal: ft.FT_Render_Mode = @intCast(ft.FT_RENDER_MODE_NORMAL);
const format_bitmap: ft.FT_Glyph_Format = @intCast(ft.FT_GLYPH_FORMAT_BITMAP);
const format_outline: ft.FT_Glyph_Format = @intCast(ft.FT_GLYPH_FORMAT_OUTLINE);
const pixel_bgra: u8 = @intCast(ft.FT_PIXEL_MODE_BGRA);
const raster_bgra32: hb.hb_raster_format_t = @intCast(hb.HB_RASTER_FORMAT_BGRA32);
// FT_MAKE_TAG('C','O','L','R'); the translate-c macro uses a nested C cast
// that does not lower to Zig, so build the big-endian tag by hand.
const colr_tag: ft.FT_ULong = (@as(ft.FT_ULong, 'C') << 24) |
    (@as(ft.FT_ULong, 'O') << 16) | (@as(ft.FT_ULong, 'L') << 8) | 'R';
const cbdt_tag: ft.FT_ULong = (@as(ft.FT_ULong, 'C') << 24) |
    (@as(ft.FT_ULong, 'B') << 16) | (@as(ft.FT_ULong, 'D') << 8) | 'T';

/// Raw FreeType face handle (`FT_FaceRec *`), re-exported so callers do not
/// need the C module themselves.
pub const FT_Face = ft.FT_Face;

pub const Error = error{
    /// FT_Set_Pixel_Sizes rejected the requested size.
    SetPixelSizesFailed,
    /// hb_ft_font_create returned NULL.
    HbFontCreateFailed,
    /// hb_raster_paint_create_or_fail returned NULL.
    HbPaintCreateFailed,
    /// Width * height overflowed the buffer size arithmetic.
    Overflow,
    OutOfMemory,
};

/// One rasterized color glyph. `pixels` holds `height` rows of `width`
/// BGRA8 pixels with premultiplied alpha, top-down, no row padding
/// (`pitch == width * 4`). Bearings are in pixels relative to the pen
/// origin, y up (FreeType `bitmap_left` / `bitmap_top` conventions).
pub const ColorGlyph = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    pitch: u32,
    bearing_x: i32,
    bearing_y: i32,

    pub fn deinit(self: *ColorGlyph, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// True if the face carries color glyphs: CBDT/sbix strikes or a COLR
/// table (v0 or v1). FreeType >= 2.13 sets `FT_FACE_FLAG_COLOR` for COLR
/// faces too; older versions only set it for bitmap strikes, so the COLR
/// table is probed explicitly as well.
pub fn hasColorGlyphs(face: *FT_Face) bool {
    if (ft.FT_HAS_COLOR(face.*)) return true;
    return hasTable(face.*, colr_tag);
}

/// Rasterize one color glyph at `size_px` pixels per EM.
///
/// CBDT/sbix strikes are loaded at their native ppem (FreeType refuses
/// other sizes on bitmap-only faces) and box-scaled to `size_px`; COLR
/// paint graphs are rasterized directly at `size_px`.
///
/// Returns null when the glyph has no color representation (the caller
/// falls back to the gray outline path): the face has no color tables, the
/// glyph is not a BGRA bitmap on a bitmap-color face, or the glyph has no
/// COLR paint entry. `size_px == 0` also returns null.
///
/// COLRv1 paints that reference the foreground color resolve to opaque
/// black (the hb-raster default); palette index 0 is used.
///
/// Mutates `face` (pixel size and glyph slot); see the module comment for
/// thread-safety.
pub fn renderColor(
    alloc: std.mem.Allocator,
    face: *FT_Face,
    glyph_index: u32,
    size_px: u16,
) Error!?ColorGlyph {
    if (size_px == 0) return null;
    const f = face.*;
    // FT_FACE_FLAG_COLOR alone cannot route: FreeType also sets it for
    // COLR faces. Bitmap strikes (CBDT/sbix) go through FT_LOAD_COLOR,
    // COLR paint graphs through hb-raster.
    const bitmap_color = ft.FT_HAS_COLOR(f) and (ft.FT_HAS_SBIX(f) or hasTable(f, cbdt_tag));
    if (bitmap_color) return renderBitmapColor(alloc, f, glyph_index, size_px);
    if (hasTable(f, colr_tag)) {
        if (ft.FT_Set_Pixel_Sizes(f, 0, size_px) != 0) return Error.SetPixelSizesFailed;
        return renderColr(alloc, f, glyph_index);
    }
    return null;
}

fn hasTable(f: ft.FT_Face, tag: ft.FT_ULong) bool {
    var len: ft.FT_ULong = 0;
    return ft.FT_Load_Sfnt_Table(f, tag, 0, null, &len) == 0 and len > 0;
}

/// CBDT/sbix path: FT_LOAD_COLOR yields a premultiplied BGRA bitmap at
/// the strike's native ppem, box-scaled to the requested size.
fn renderBitmapColor(alloc: std.mem.Allocator, f: ft.FT_Face, glyph_index: u32, size_px: u16) Error!?ColorGlyph {
    const face = &f.*;
    if (face.num_fixed_sizes > 0) {
        // Bitmap-only faces reject FT_Set_Pixel_Sizes for non-strike
        // sizes (FT_Err_Invalid_PPem); select the closest strike instead.
        if (ft.FT_Select_Size(f, bestStrike(face, size_px)) != 0) return Error.SetPixelSizesFailed;
    } else {
        if (ft.FT_Set_Pixel_Sizes(f, 0, size_px) != 0) return Error.SetPixelSizesFailed;
    }

    // A failed load means the glyph has no color bitmap (e.g. an outline
    // or .notdef in a bitmap-only emoji font): fall back, don't error.
    if (ft.FT_Load_Glyph(f, glyph_index, load_color) != 0) return null;
    const slot = &f.*.glyph.*;
    if (slot.format != format_bitmap) return null;
    if (ft.FT_Render_Glyph(slot, render_normal) != 0) return null;

    const bmp = &slot.bitmap;
    if (bmp.pixel_mode != pixel_bgra) return null;
    if (bmp.width == 0 or bmp.rows == 0) return null;

    const width: u32 = bmp.width;
    const height: u32 = bmp.rows;
    const pitch = try std.math.mul(u32, width, 4);
    const pixels = try alloc.alloc(u8, @as(usize, pitch) * height);
    errdefer alloc.free(pixels);

    // Normalize to tight top-down rows. FreeType color bitmaps are
    // top-down with positive pitch; negative pitch (bottom-up storage)
    // is handled for completeness.
    const row_bytes: usize = pitch;
    const src_stride: usize = @intCast(if (bmp.pitch >= 0) bmp.pitch else -bmp.pitch);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row: usize = if (bmp.pitch >= 0) y else height - 1 - y;
        const src = bmp.buffer[src_row * src_stride ..][0..row_bytes];
        @memcpy(pixels[@as(usize, y) * pitch ..][0..row_bytes], src);
    }

    const ppem: u32 = face.size.*.metrics.x_ppem;
    if (ppem == 0 or ppem == size_px) {
        return ColorGlyph{
            .pixels = pixels,
            .width = width,
            .height = height,
            .pitch = pitch,
            .bearing_x = slot.bitmap_left,
            .bearing_y = slot.bitmap_top,
        };
    }

    // Scale the strike to the requested ppem. Averaging premultiplied
    // channels is the correct box filter for premultiplied alpha.
    const dw = scaledDim(width, size_px, ppem);
    const dh = scaledDim(height, size_px, ppem);
    const scaled_pitch = try std.math.mul(u32, dw, 4);
    const scaled = try boxScale(alloc, pixels, width, height, dw, dh);
    alloc.free(pixels);
    return ColorGlyph{
        .pixels = scaled,
        .width = dw,
        .height = dh,
        .pitch = scaled_pitch,
        .bearing_x = scaleCoord(slot.bitmap_left, size_px, ppem),
        .bearing_y = scaleCoord(slot.bitmap_top, size_px, ppem),
    };
}

/// Index of the strike closest to `size_px`; ties prefer the larger
/// strike (downscaling keeps more detail than upscaling).
fn bestStrike(face: *const ft.struct_FT_FaceRec_, size_px: u16) ft.FT_Int {
    var best: ft.FT_Int = 0;
    var best_diff: i64 = std.math.maxInt(i64);
    var best_ppem: i64 = -1;
    var i: ft.FT_Int = 0;
    while (i < face.num_fixed_sizes) : (i += 1) {
        const strike = face.available_sizes[@intCast(i)];
        const ppem: i64 = (strike.y_ppem + 32) >> 6; // 26.6 -> rounded pixels
        const diff: i64 = @intCast(@abs(ppem - @as(i64, size_px)));
        if (diff < best_diff or (diff == best_diff and ppem > best_ppem)) {
            best = i;
            best_diff = diff;
            best_ppem = ppem;
        }
    }
    return best;
}

fn scaledDim(dim: u32, size_px: u16, ppem: u32) u32 {
    const n: u64 = @as(u64, dim) * size_px;
    const d: u64 = ppem;
    return @intCast(@max((n + d / 2) / d, 1));
}

fn scaleCoord(v: i32, size_px: u16, ppem: u32) i32 {
    const n: i64 = @as(i64, v) * size_px;
    const d: u64 = ppem;
    const mag: i64 = @intCast((@abs(n) + d / 2) / d);
    return @intCast(if (n < 0) -mag else mag);
}

/// Area-average (box) resample of tight premultiplied BGRA rows.
fn boxScale(alloc: std.mem.Allocator, src: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) Error![]u8 {
    const dst = try alloc.alloc(u8, @as(usize, dw) * dh * 4);
    errdefer alloc.free(dst);
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y0: u64 = @as(u64, dy) * sh / dh;
        const y1: u64 = @max((@as(u64, dy) + 1) * sh / dh, y0 + 1);
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x0: u64 = @as(u64, dx) * sw / dw;
            const x1: u64 = @max((@as(u64, dx) + 1) * sw / dw, x0 + 1);
            var sum = [4]u64{ 0, 0, 0, 0 };
            var count: u64 = 0;
            var sy: u64 = y0;
            while (sy < y1) : (sy += 1) {
                const row: usize = @intCast(sy * sw);
                var sx: u64 = x0;
                while (sx < x1) : (sx += 1) {
                    const p = src[(row + @as(usize, @intCast(sx))) * 4 ..][0..4];
                    sum[0] += p[0];
                    sum[1] += p[1];
                    sum[2] += p[2];
                    sum[3] += p[3];
                    count += 1;
                }
            }
            const o = (@as(usize, dy) * dw + dx) * 4;
            dst[o + 0] = @intCast((sum[0] + count / 2) / count);
            dst[o + 1] = @intCast((sum[1] + count / 2) / count);
            dst[o + 2] = @intCast((sum[2] + count / 2) / count);
            dst[o + 3] = @intCast((sum[3] + count / 2) / count);
        }
    }
    return dst;
}

/// COLRv0/v1 path: hb_raster_paint evaluates the paint graph into a
/// premultiplied BGRA32 image.
fn renderColr(alloc: std.mem.Allocator, f: ft.FT_Face, glyph_index: u32) Error!?ColorGlyph {
    // hb_ft_font_create derives the hb scale from the FT size set above:
    // scale = ppem * 64, i.e. glyph coordinates are 26.6 pixels.
    // hb-ft.h re-translates FreeType, so its FT_Face is a nominally distinct
    // (but layout-identical) C pointer; cross the module boundary with ptrCast.
    const hb_font = hb.hb_ft_font_create(@ptrCast(f), null) orelse return Error.HbFontCreateFailed;
    defer hb.hb_font_destroy(hb_font);

    var gext: hb.hb_glyph_extents_t = undefined;
    if (hb.hb_font_get_glyph_extents(hb_font, glyph_index, &gext) == 0) {
        // hb-ft refuses extents for COLR glyphs ("FreeType doesn't return
        // COLR glyph extents", hb-ft.cc); use the base outline metrics.
        if (!outlineExtents(f, glyph_index, &gext)) return null;
    }
    if (gext.width == 0 or gext.height == 0) return null;

    const paint = hb.hb_raster_paint_create_or_fail() orelse return Error.HbPaintCreateFailed;
    defer hb.hb_raster_paint_destroy(paint);

    // Map 26.6 glyph space to pixels for both the extents and the paint
    // graph (equivalent to the reference util's scale_factor = 64).
    hb.hb_raster_paint_set_transform(paint, 1.0 / 64.0, 0, 0, 1.0 / 64.0, 0, 0);
    // Foreground for COLRv1 foreground-referencing paints: opaque black.
    hb.hb_raster_paint_set_foreground(paint, hb.HB_COLOR(0, 0, 0, 255));
    if (hb.hb_raster_paint_set_glyph_extents(paint, &gext) == 0) return null;
    // _or_fail: false for glyphs without color paint data (no synthesized
    // monochrome outline), which is exactly the null contract.
    if (hb.hb_raster_paint_glyph_or_fail(paint, hb_font, glyph_index) == 0) return null;

    const image = hb.hb_raster_paint_render(paint) orelse return null;
    defer hb.hb_raster_image_destroy(image);

    var ext: hb.hb_raster_extents_t = undefined;
    hb.hb_raster_image_get_extents(image, &ext);
    if (ext.width == 0 or ext.height == 0) return null;
    // Documented invariant of hb_raster_paint_render; guard anyway so a
    // future A8 result can never be mislabeled as BGRA.
    if (hb.hb_raster_image_get_format(image) != raster_bgra32) return null;
    const buf = hb.hb_raster_image_get_buffer(image) orelse return null;

    const width: u32 = ext.width;
    const height: u32 = ext.height;
    const pitch = try std.math.mul(u32, width, 4);
    const pixels = try alloc.alloc(u8, @as(usize, pitch) * height);
    errdefer alloc.free(pixels);

    // hb-raster row 0 is the bottom edge (y-up glyph space); flip to
    // FreeType-style top-down rows.
    const row_bytes: usize = pitch;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row: usize = height - 1 - y;
        const src = buf[src_row * ext.stride ..][0..row_bytes];
        @memcpy(pixels[@as(usize, y) * pitch ..][0..row_bytes], src);
    }

    return ColorGlyph{
        .pixels = pixels,
        .width = width,
        .height = height,
        .pitch = pitch,
        .bearing_x = ext.x_origin,
        .bearing_y = ext.y_origin + @as(i32, @intCast(height)),
    };
}

/// Base-outline extents in 26.6 pixels, shaped like hb_glyph_extents_t
/// (height negative, y up). Used when hb-ft declines COLR glyph extents.
fn outlineExtents(f: ft.FT_Face, glyph_index: u32, gext: *hb.hb_glyph_extents_t) bool {
    if (ft.FT_Load_Glyph(f, glyph_index, load_outline) != 0) return false;
    const slot = &f.*.glyph.*;
    if (slot.format != format_outline) return false;
    const m = slot.metrics;
    if (m.width == 0 or m.height == 0) return false;
    gext.* = .{
        .x_bearing = @intCast(m.horiBearingX),
        .y_bearing = @intCast(m.horiBearingY),
        .width = @intCast(m.width),
        .height = @intCast(-m.height),
    };
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────
//
// Real-font tests; run with the standalone command in the module comment.
// std.testing.allocator fails the run on any leak (acceptance f).

const test_fonts = struct {
    // nix build nixpkgs#noto-fonts-color-emoji --print-out-paths --no-link
    const cbdt = "/nix/store/k20i11yvcd2gdahxv59gck68w6sq5kwr-noto-fonts-color-emoji-2.051/share/fonts/noto/NotoColorEmoji.ttf";
    // https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-glyf_colr_1.ttf
    const colr = "/tmp/kmshaunt-fonts/noto-glyf_colr_1.ttf";
    // .../noto-sbix.ttf from the same commit
    const sbix = "/tmp/kmshaunt-fonts/noto-sbix.ttf";
    // nix build nixpkgs#dejavu_fonts --print-out-paths --no-link
    const text = "/nix/store/mz1hvwkd5i24d93ihpdczqhn65mik69d-dejavu-fonts-2.37/share/fonts/truetype/DejaVuSans.ttf";
};

fn testFontPath(alloc: std.mem.Allocator, env_name: [:0]const u8, default: []const u8) ![]u8 {
    if (std.c.getenv(env_name.ptr)) |value| {
        return alloc.dupe(u8, std.mem.span(value));
    }
    return alloc.dupe(u8, default);
}

const TestFace = struct {
    lib: ft.FT_Library,
    face: ft.FT_Face,

    fn open(alloc: std.mem.Allocator, path: []const u8) !TestFace {
        var lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInitFailed;
        errdefer _ = ft.FT_Done_FreeType(lib);
        const zpath = try alloc.dupeSentinel(u8, path, 0);
        defer alloc.free(zpath);
        var face: ft.FT_Face = null;
        if (ft.FT_New_Face(lib, zpath.ptr, 0, &face) != 0) return error.FreeTypeOpenFailed;
        return .{ .lib = lib, .face = face };
    }

    fn close(self: *TestFace) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.lib);
    }
};

const PixelStats = struct {
    nonempty: usize = 0,
    solid: usize = 0,
    transparent: usize = 0,
    partial: usize = 0,
    distinct_rgb: usize = 0,

    fn scan(glyph: ColorGlyph) !PixelStats {
        var stats = PixelStats{};
        var seen = std.AutoHashMap(u24, void).init(std.testing.allocator);
        defer seen.deinit();
        var i: usize = 0;
        while (i < glyph.pixels.len) : (i += 4) {
            const p = glyph.pixels[i..][0..4];
            const b = p[0];
            const g = p[1];
            const r = p[2];
            const a = p[3];
            if (a == 255) {
                stats.solid += 1;
            } else if (a == 0) {
                stats.transparent += 1;
            } else {
                stats.partial += 1;
            }
            if (p[0] != 0 or p[1] != 0 or p[2] != 0 or a != 0) stats.nonempty += 1;
            // Premultiplied invariant: no channel may exceed alpha.
            try std.testing.expect(b <= a and g <= a and r <= a);
            if (a != 0) {
                const key: u24 = @as(u24, r) << 16 | @as(u24, g) << 8 | b;
                try seen.put(key, {});
            }
        }
        stats.distinct_rgb = seen.count();
        return stats;
    }
};

fn expectShape(glyph: ColorGlyph) !void {
    try std.testing.expect(glyph.width > 0);
    try std.testing.expect(glyph.height > 0);
    try std.testing.expectEqual(glyph.width * 4, glyph.pitch);
    try std.testing.expectEqual(@as(usize, glyph.pitch) * glyph.height, glyph.pixels.len);
}

test "CBDT: NotoColorEmoji U+1F600 at 32px is BGRA with alpha variation" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_CBDT_FONT", test_fonts.cbdt);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    try std.testing.expect(hasColorGlyphs(&tf.face));
    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);
    try std.testing.expect(gid != 0);

    var glyph = (try renderColor(alloc, &tf.face, gid, 32)) orelse
        return error.TestUnexpectedNull;
    defer glyph.deinit(alloc);
    try expectShape(glyph);
    // A 32px strike should be roughly cell-sized, not font-unit sized.
    try std.testing.expect(glyph.width <= 64 and glyph.height <= 64);

    const stats = try PixelStats.scan(glyph);
    try std.testing.expect(stats.nonempty > 0);
    // Rounded emoji: fully opaque interior AND transparent corners, so
    // not a solid rectangle; antialiased edge gives partial alpha too.
    try std.testing.expect(stats.solid > 0);
    try std.testing.expect(stats.transparent > 0);
    try std.testing.expect(stats.partial > 0);
    try std.testing.expect(stats.distinct_rgb > 3);

    // Byte-order sanity (e): the grinning face is yellow, so opaque
    // pixels must have high R and G with low B in BGRA order.
    var yellow: usize = 0;
    var i: usize = 0;
    while (i < glyph.pixels.len) : (i += 4) {
        const p = glyph.pixels[i..][0..4];
        if (p[3] == 255 and p[2] > 128 and p[1] > 128 and p[0] < 128) yellow += 1;
    }
    try std.testing.expect(yellow > 0);
}

test "COLRv1: noto-glyf_colr_1 U+1F600 at 32px paints multiple colors" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_COLR_FONT", test_fonts.colr);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    // FreeType >= 2.13 sets FT_FACE_FLAG_COLOR for COLR faces too, so the
    // flag alone cannot distinguish them; routing must consult the tables.
    try std.testing.expect(hasColorGlyphs(&tf.face));
    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);
    try std.testing.expect(gid != 0);

    var glyph = (try renderColor(alloc, &tf.face, gid, 32)) orelse
        return error.TestUnexpectedNull;
    defer glyph.deinit(alloc);
    try expectShape(glyph);
    try std.testing.expect(glyph.width <= 64 and glyph.height <= 64);

    const stats = try PixelStats.scan(glyph);
    try std.testing.expect(stats.nonempty > 0);
    // The COLRv1 paint graph (gradients, layers) must produce many colors,
    // not a monochrome silhouette.
    try std.testing.expect(stats.distinct_rgb > 3);
}

test "COLRv1: byte order matches CPAL palette entries in BGRA order" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_COLR_FONT", test_fonts.colr);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    var pdata: ft.FT_Palette_Data = undefined;
    try std.testing.expectEqual(@as(ft.FT_Error, 0), ft.FT_Palette_Data_Get(tf.face, &pdata));
    try std.testing.expect(pdata.num_palettes > 0);
    try std.testing.expect(pdata.num_palette_entries > 0);
    var palette: [*c]ft.FT_Color = null;
    try std.testing.expectEqual(@as(ft.FT_Error, 0), ft.FT_Palette_Select(tf.face, 0, &palette));

    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);
    var glyph = (try renderColor(alloc, &tf.face, gid, 32)) orelse
        return error.TestUnexpectedNull;
    defer glyph.deinit(alloc);

    // Opaque pixels must equal CPAL entries byte-for-byte in BGRA order
    // (FT_Color is {blue, green, red, alpha}). Count the RGBA reading too:
    // BGRA must win, and at least one match must have R != B so the two
    // readings are actually distinguishable.
    var bgra_matches: usize = 0;
    var rgba_matches: usize = 0;
    var distinguishable: usize = 0;
    var i: usize = 0;
    while (i < glyph.pixels.len) : (i += 4) {
        const p = glyph.pixels[i..][0..4];
        if (p[3] != 255) continue;
        var e: u16 = 0;
        while (e < pdata.num_palette_entries) : (e += 1) {
            const c = palette[e];
            if (c.alpha != 255) continue;
            if (p[0] == c.blue and p[1] == c.green and p[2] == c.red) {
                bgra_matches += 1;
                if (c.red != c.blue) distinguishable += 1;
            }
            if (p[0] == c.red and p[1] == c.green and p[2] == c.blue) rgba_matches += 1;
        }
    }
    try std.testing.expect(bgra_matches > 0);
    try std.testing.expect(distinguishable > 0);
    try std.testing.expect(bgra_matches > rgba_matches);
}

test "sbix: noto-sbix U+1F600 renders nonempty BGRA" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_SBIX_FONT", test_fonts.sbix);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    try std.testing.expect(hasColorGlyphs(&tf.face));
    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);
    try std.testing.expect(gid != 0);

    var glyph = (try renderColor(alloc, &tf.face, gid, 32)) orelse
        return error.TestUnexpectedNull;
    defer glyph.deinit(alloc);
    try expectShape(glyph);
    const stats = try PixelStats.scan(glyph);
    try std.testing.expect(stats.nonempty > 0);
    try std.testing.expect(stats.distinct_rgb > 1);
}

test "non-color: DejaVu Sans 'A' has no color and renders null" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_TEXT_FONT", test_fonts.text);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    try std.testing.expect(!hasColorGlyphs(&tf.face));
    const gid = ft.FT_Get_Char_Index(tf.face, 'A');
    try std.testing.expect(gid != 0);
    try std.testing.expectEqual(@as(?ColorGlyph, null), try renderColor(alloc, &tf.face, gid, 32));
}

test "non-color glyph in a COLR font renders null" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_COLR_FONT", test_fonts.colr);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();

    // Glyph 0 (.notdef) has no COLR entry; hb_raster_paint_glyph_or_fail
    // must report failure rather than synthesize a monochrome outline.
    try std.testing.expectEqual(@as(?ColorGlyph, null), try renderColor(alloc, &tf.face, 0, 32));
    // Out-of-range glyph index: null, not a crash.
    const oob: u32 = @intCast(tf.face.*.num_glyphs + 1);
    try std.testing.expectEqual(@as(?ColorGlyph, null), try renderColor(alloc, &tf.face, oob, 32));
    // Zero size: null by contract.
    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);
    try std.testing.expectEqual(@as(?ColorGlyph, null), try renderColor(alloc, &tf.face, gid, 0));
}

test "repeat renders across sizes stay leak-free and consistent" {
    const alloc = std.testing.allocator;
    const path = try testFontPath(alloc, "KMSHAUNT_TEST_COLR_FONT", test_fonts.colr);
    defer alloc.free(path);
    var tf = try TestFace.open(alloc, path);
    defer tf.close();
    const gid = ft.FT_Get_Char_Index(tf.face, 0x1F600);

    for ([_]u16{ 16, 32, 48, 32 }) |size| {
        var glyph = (try renderColor(alloc, &tf.face, gid, size)) orelse
            return error.TestUnexpectedNull;
        try expectShape(glyph);
        // Larger ppem must not shrink the image.
        try std.testing.expect(glyph.width >= size / 2 and glyph.width <= size * 2);
        glyph.deinit(alloc);
    }
}
