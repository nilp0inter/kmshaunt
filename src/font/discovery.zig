//! src/font/discovery.zig -- fontconfig discovery + per-codepoint fallback
//! (ROADMAP M3.1/M3.2; D7: FreeType for outlines and bitmap color glyphs).
//!
//! This is the only file that calls fontconfig or FreeType. Everything else
//! in src/font/ works on the `Face` / `GlyphBitmap` values defined here.
//!
//! # C bindings
//!
//! Two translate-c modules are imported: `fontconfig_c` and `freetype_c`.
//! Shim headers (kept out of the tree; reproduce verbatim when wiring
//! build.zig with b.addTranslateC):
//!
//!   fontconfig shim:
//!     #include <fontconfig/fontconfig.h>
//!   FreeType shim (ftsynth has no ft2build.h macro, include it directly):
//!     #include <ft2build.h>
//!     #include FT_FREETYPE_H
//!     #include <freetype/ftsynth.h>
//!
//! Generated with zig 0.17.1 against fontconfig 2.18.3 and FreeType 2.14.3
//! from nixpkgs (store paths below; refresh with
//! `nix build nixpkgs#fontconfig.dev nixpkgs#fontconfig.lib nixpkgs#freetype.dev nixpkgs#freetype --print-out-paths --no-link`):
//!
//!   FCDEV=/nix/store/nbdi0r6jklg8r7lnzz5pw51aa1h1fhih-fontconfig-2.18.3-dev
//!   FTDEV=/nix/store/jpnd5wfvvva2hp63wl348ldxgl4lk25a-freetype-2.14.3-dev
//!   FCLIB=/nix/store/p3y4rk4gjnhs80339qq7jixjbhplqc16-fontconfig-2.18.3-lib
//!   FTLIB=/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3
//!   zig translate-c /tmp/kmshaunt_fc_shim.h -I$FCDEV/include -lc > /tmp/kmshaunt_fontconfig_c.zig
//!   zig translate-c /tmp/kmshaunt_ft_shim.h -I$FTDEV/include/freetype2 -lc > /tmp/kmshaunt_freetype_c.zig
//!
//! Standalone test command (run from the repo root; uses the HOST fontconfig
//! configuration and fonts, no sandbox):
//!
//!   nix run nixpkgs#zig -- test \
//!     --dep fontconfig_c --dep freetype_c \
//!     -Mroot=src/font/discovery.zig \
//!     -Mfontconfig_c=/tmp/kmshaunt_fontconfig_c.zig \
//!     -Mfreetype_c=/tmp/kmshaunt_freetype_c.zig \
//!     -lc -lfontconfig -lfreetype \
//!     -I$FCDEV/include -I$FTDEV/include/freetype2 \
//!     -L$FCLIB/lib -L$FTLIB/lib
//!
//! # Ownership
//!
//! `Discovery` owns the fontconfig config, the FreeType library, and every
//! `FT_Face` it ever loaded (one per distinct file+index, cached). `Face` is
//! a small copyable *handle*: it stays valid until `Discovery.deinit`, which
//! destroys all faces, the library and the config. Never call FT_Done_Face
//! on a handle's face yourself.
//!
//! Handles that refer to the same underlying `FT_Face` (style variants with
//! synthetic flags, repeated lookups) share FreeType's per-face state: the
//! pixel size and the single glyph slot. Setting a pixel size or loading a
//! glyph through one handle affects all of them; a `GlyphBitmap.buffer`
//! borrow is invalidated by the next load on that face (see `loadGlyph`).
//!
//! # Fallback cache
//!
//! `fallbackFace` caches per codepoint, including negative results, so a
//! missing codepoint is queried from fontconfig at most once per Discovery.

const std = @import("std");
const fc = @import("fontconfig_c");
const ft = @import("freetype_c");

/// Pixel layout of a rasterized glyph.
pub const PixelFormat = enum {
    /// 1 byte per pixel coverage, row-major. LCD renders are also `.gray`
    /// but store 3 bytes per pixel (one coverage byte per RGB subpixel), so
    /// `width` and `pitch` are ~3x the normal values.
    gray,
    /// 4 bytes per pixel, BGRA byte order (FreeType FT_PIXEL_MODE_BGRA),
    /// straight alpha, row-major.
    bgra,
};

/// One rasterized glyph.
///
/// `buffer` is BORROWED from the face's FreeType glyph slot: it stays valid
/// only until the next `loadGlyph`/`cellMetrics` on the same underlying
/// FT_Face (through any handle sharing it) or `Discovery.deinit`. Copy it
/// into the atlas before loading another glyph. Rows are `pitch` bytes
/// apart; `pitch` may be negative (bottom-up rows), in which case `buffer`
/// still spans the whole allocation and row 0 is at the far end.
///
/// `width`/`height` are in pixels (for LCD gray renders `width` counts
/// subpixels, ~3x the glyph width). `bearing_x` is the offset from the
/// pen position to the left edge of the bitmap; `bearing_y` is the offset
/// from the baseline UP to the top edge. `advance_x` is the horizontal
/// advance in whole pixels (26.6 fixed point truncated toward zero).
pub const GlyphBitmap = struct {
    buffer: []const u8,
    width: u32,
    height: u32,
    pitch: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance_x: i32,
    format: PixelFormat,
};

/// Face-wide metrics in whole pixels (26.6 values truncated toward zero).
/// `descender` is negative. `underline_position` is the offset from the
/// baseline DOWN to the underline center (negative = below the baseline,
/// FreeType convention); `underline_thickness` is the stroke width.
/// Requires a prior `setPixelSize`; returns zeroes if no size is set.
pub const Metrics = struct {
    ascender: i32,
    descender: i32,
    height: i32,
    underline_position: i32,
    underline_thickness: i32,
};

/// Terminal cell geometry derived under the MONOSPACE ASSUMPTION: every
/// cell has the advance of '0' (or space if the face lacks '0'), and the
/// cell height is ascender - descender with no extra leading. `baseline`
/// is the distance from the cell top to the baseline (= ascender).
pub const CellMetrics = struct {
    cell_w: u16,
    cell_h: u16,
    baseline: u16,
};

/// Handle to one loaded FreeType face. Copyable; valid until the owning
/// `Discovery.deinit`. See the module comment for shared-state rules.
pub const Face = struct {
    /// The wrapped FT_Face. Owned by Discovery; do not destroy it.
    ft_face: ft.FT_Face,
    /// No real bold face exists: the renderer gets emboldened rasters from
    /// `loadGlyph` (FT_GlyphSlot_Embolden is applied there, keeping all C
    /// calls in this file). Exposed so the renderer can key its atlas on
    /// the synthesis (see atlas.flag_synthetic_bold).
    synthetic_bold: bool = false,
    /// No real italic face exists: `loadGlyph` shears outline glyphs with
    /// FT_GlyphSlot_Oblique. Bitmap glyphs cannot be sheared and are
    /// returned unsheared. Exposed for atlas keying (flag_synthetic_italic).
    synthetic_italic: bool = false,
    /// Render monochrome outlines with FT_RENDER_MODE_LCD (tripled-width
    /// gray subpixel coverage) instead of NORMAL. Color glyphs and bitmap
    /// glyphs always render NORMAL regardless of this flag.
    lcd: bool = false,

    /// Select the pixel size. Scalable faces use FT_Set_Pixel_Sizes
    /// (square pixels). Bitmap-only faces (CBDT/sbix color emoji, PSF-style
    /// console fonts) reject arbitrary sizes, so the available strike whose
    /// em size is closest to `px` is selected with FT_Select_Size instead;
    /// the raster then comes out at that strike's native size. Affects every
    /// handle sharing this FT_Face.
    pub fn setPixelSize(self: Face, px: u16) !void {
        const face = self.ft_face;
        if ((face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE) != 0 or face.*.num_fixed_sizes == 0) {
            try ftCheck(ft.FT_Set_Pixel_Sizes(face, 0, px));
            return;
        }
        var best: ft.FT_Int = 0;
        var best_diff: u64 = std.math.maxInt(u64);
        var i: ft.FT_Int = 0;
        while (i < face.*.num_fixed_sizes) : (i += 1) {
            const strike = face.*.available_sizes[@intCast(i)];
            const diff = @abs(strike.y_ppem - @as(i64, px) * 64);
            if (diff < best_diff) {
                best_diff = diff;
                best = i;
            }
        }
        try ftCheck(ft.FT_Select_Size(face, best));
    }

    /// Select the size in points at a DPI (FT_Set_Char_Size), giving a
    /// fractional pixel size like ghostty (pt*dpi/72). Bitmap-only faces fall
    /// back to the nearest strike via setPixelSize.
    pub fn setCharSize(self: Face, points: u32, dpi: u32) !void {
        const face = self.ft_face;
        if ((face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE) != 0 or face.*.num_fixed_sizes == 0) {
            try ftCheck(ft.FT_Set_Char_Size(face, 0, @intCast(points * 64), dpi, dpi));
            return;
        }
        try self.setPixelSize(@intCast((points * dpi) / 72));
    }

    /// FT_Get_Char_Index; null when the face has no glyph for `cp`
    /// (FreeType's glyph 0 means "missing").
    pub fn glyphIndex(self: Face, cp: u21) ?u32 {
        const idx = ft.FT_Get_Char_Index(self.ft_face, cp);
        return if (idx == 0) null else idx;
    }

    /// Load and rasterize glyph `idx`. With `color`, FT_LOAD_COLOR is set
    /// so embedded color bitmaps (CBDT/sbix) come out BGRA; COLR outlines
    /// are NOT painted here (that is hb_raster's job, ROADMAP D7/M3.5).
    /// Synthetic bold/italic flags on this handle are applied before
    /// rendering. Invalidates any previously borrowed GlyphBitmap.buffer
    /// on the same underlying face.
    pub fn loadGlyph(self: Face, idx: u32, color: bool) !GlyphBitmap {
        var flags: ft.FT_Int32 = ft.FT_LOAD_DEFAULT;
        if (color) flags |= @intCast(ft.FT_LOAD_COLOR);
        try ftCheck(ft.FT_Load_Glyph(self.ft_face, idx, flags));
        const slot = self.ft_face.*.glyph;
        if (self.synthetic_bold) ft.FT_GlyphSlot_Embolden(slot);
        if (self.synthetic_italic and slot.*.format == ft.FT_GLYPH_FORMAT_OUTLINE) {
            ft.FT_GlyphSlot_Oblique(slot);
        }
        // LCD subpixel rendering only applies to monochrome outlines;
        // bitmap strikes and color glyphs render NORMAL.
        const outline = slot.*.format == ft.FT_GLYPH_FORMAT_OUTLINE;
        const mode: ft.FT_Render_Mode = if (self.lcd and outline and !color)
            ft.FT_RENDER_MODE_LCD
        else
            ft.FT_RENDER_MODE_NORMAL;
        try ftCheck(ft.FT_Render_Glyph(slot, mode));
        const bmp = &slot.*.bitmap;
        const format: PixelFormat = switch (bmp.*.pixel_mode) {
            ft.FT_PIXEL_MODE_GRAY, ft.FT_PIXEL_MODE_LCD => .gray,
            ft.FT_PIXEL_MODE_BGRA => .bgra,
            else => return error.UnsupportedPixelMode,
        };
        const stride: usize = @intCast(@abs(bmp.*.pitch));
        const buffer: []const u8 = if (bmp.*.rows == 0 or bmp.*.buffer == null)
            &.{}
        else
            bmp.*.buffer[0 .. stride * bmp.*.rows];
        return .{
            .buffer = buffer,
            .width = bmp.*.width,
            .height = bmp.*.rows,
            .pitch = bmp.*.pitch,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .advance_x = @intCast(@divTrunc(slot.*.advance.x, 64)),
            .format = format,
        };
    }

    /// FT_HAS_COLOR: the face carries embedded color bitmaps (CBDT/sbix).
    pub fn hasColor(self: Face) bool {
        return (self.ft_face.*.face_flags & ft.FT_FACE_FLAG_COLOR) != 0;
    }

    /// Face-wide metrics in pixels; see `Metrics`.
    pub fn metrics(self: Face) Metrics {
        const face = self.ft_face.*;
        if (face.size == null) return std.mem.zeroes(Metrics);
        const sm = face.size.*.metrics;
        var underline_position: i32 = face.underline_position;
        var underline_thickness: i32 = face.underline_thickness;
        if ((face.face_flags & ft.FT_FACE_FLAG_SCALABLE) != 0 and face.units_per_EM != 0) {
            // Scalable faces report underline metrics in font units;
            // scale them to the current pixel size. Bitmap faces already
            // report pixels.
            const ppem: i64 = sm.y_ppem;
            underline_position = @intCast(@divTrunc(@as(i64, face.underline_position) * ppem, face.units_per_EM));
            underline_thickness = @intCast(@divTrunc(@as(i64, face.underline_thickness) * ppem, face.units_per_EM));
        }
        return .{
            .ascender = px26(sm.ascender),
            .descender = px26(sm.descender),
            .height = px26(sm.height),
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
        };
    }

    /// Family name, borrowed from FreeType; valid until Discovery.deinit.
    /// Empty if the face has no name.
    pub fn familyName(self: Face) []const u8 {
        const name = self.ft_face.*.family_name;
        if (name == null) return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    }
};

/// Fontconfig discovery and FreeType face ownership. One instance per
/// process is enough; it is not thread-safe (ROADMAP D2: one thread).
pub const Discovery = struct {
    allocator: std.mem.Allocator,
    config: *fc.FcConfig,
    library: ft.FT_Library,
    /// Every distinct FT_Face loaded, for cleanup at deinit. Lookups are a
    /// linear scan: a console session keeps only a handful of faces.
    faces: std.ArrayList(*FaceRec),
    /// Per-codepoint fallback results, including negatives (null).
    fallback_cache: std.AutoHashMap(u21, ?Face),

    const FaceRec = struct {
        ft_face: ft.FT_Face,
        /// Owned, NUL-terminated file path (also the cache key).
        file: [:0]u8,
        index: i64,
    };

    /// Load the host fontconfig configuration with all fonts
    /// (FcInitLoadConfigAndFonts) and initialize FreeType.
    pub fn init(allocator: std.mem.Allocator) !Discovery {
        const config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInit;
        errdefer fc.FcConfigDestroy(config);
        var library: ft.FT_Library = null;
        try ftCheck(ft.FT_Init_FreeType(&library));
        return .{
            .allocator = allocator,
            .config = config,
            .library = library,
            .faces = .empty,
            .fallback_cache = std.AutoHashMap(u21, ?Face).init(allocator),
        };
    }

    /// Destroy every owned face, the FreeType library and the fontconfig
    /// config. All `Face` handles and borrowed buffers become invalid.
    pub fn deinit(self: *Discovery) void {
        self.fallback_cache.deinit();
        for (self.faces.items) |rec| {
            _ = ft.FT_Done_Face(rec.ft_face);
            self.allocator.free(rec.file);
            self.allocator.destroy(rec);
        }
        self.faces.deinit(self.allocator);
        _ = ft.FT_Done_FreeType(self.library);
        fc.FcConfigDestroy(self.config);
        self.* = undefined;
    }

    /// Match the primary face. `font_name` is a fontconfig pattern name
    /// ("JetBrains Mono", "DejaVu Sans Mono:bold", ...); null selects the
    /// generic "monospace" alias, i.e. the host's default monospace font.
    /// The returned face is sized to `size_px`.
    pub fn primaryFace(self: *Discovery, font_name: ?[]const u8, size_px: u16) !Face {
        const pat = try self.parsePattern(font_name orelse "monospace");
        defer fc.FcPatternDestroy(pat);
        const match = try self.matchPattern(pat);
        defer fc.FcPatternDestroy(match);
        const file = try patternString(match, fc.FC_FILE);
        const index = patternInt(match, fc.FC_INDEX) catch 0;
        const face = try self.loadFace(file, index);
        try face.setPixelSize(size_px);
        return face;
    }

    /// Bold/italic/bold-italic variant of `base`, matched through
    /// fontconfig with the base family plus weight/slant properties.
    ///
    /// Whether the match is a real variant is decided from the loaded face,
    /// NOT from the matched pattern's weight/slant: FcFontMatch echoes the
    /// requested weight/slant into the result even when the matched font does
    /// not actually have them. A match that is the same face as `base` is never
    /// a real variant. Otherwise the face's FreeType style flags
    /// (FT_STYLE_FLAG_BOLD / FT_STYLE_FLAG_ITALIC) say which styles it has; a
    /// distinct face with neither flag set is treated as a variable-font named
    /// instance and trusted for the requested styles. Requested styles the
    /// matched face lacks are synthesized on it. If the match offers none of
    /// the requested styles, the base face is returned with
    /// `synthetic_bold`/`synthetic_italic` set instead. The variant inherits
    /// the base's current pixel size and lcd flag.
    pub fn faceForStyle(self: *Discovery, base: Face, bold: bool, italic: bool) !Face {
        if (!bold and !italic) return base;

        const pat = fc.FcPatternCreate() orelse return error.FontconfigFailure;
        defer fc.FcPatternDestroy(pat);
        const family = base.familyName();
        const family_z = try self.allocator.allocSentinel(u8, family.len, 0);
        defer self.allocator.free(family_z);
        @memcpy(family_z, family);
        if (fc.FcPatternAddString(pat, fc.FC_FAMILY, family_z.ptr) == fc.FcFalse)
            return error.FontconfigFailure;
        const weight: c_int = if (bold) fc.FC_WEIGHT_BOLD else fc.FC_WEIGHT_REGULAR;
        const slant: c_int = if (italic) fc.FC_SLANT_ITALIC else fc.FC_SLANT_ROMAN;
        if (fc.FcPatternAddInteger(pat, fc.FC_WEIGHT, weight) == fc.FcFalse)
            return error.FontconfigFailure;
        if (fc.FcPatternAddInteger(pat, fc.FC_SLANT, slant) == fc.FcFalse)
            return error.FontconfigFailure;

        const match = try self.matchPattern(pat);
        defer fc.FcPatternDestroy(match);
        const file = try patternString(match, fc.FC_FILE);
        const index = patternInt(match, fc.FC_INDEX) catch 0;
        var face = try self.loadFace(file, index);

        const same_face = face.ft_face == base.ft_face;
        const style_flags = face.ft_face.*.style_flags;
        var face_bold = (style_flags & ft.FT_STYLE_FLAG_BOLD) != 0;
        var face_italic = (style_flags & ft.FT_STYLE_FLAG_ITALIC) != 0;
        // A distinct face whose style flags report neither style is typically
        // a variable-font named instance (FreeType does not set the bold/italic
        // flags for those); trust fontconfig's match for the requested styles
        // in that case. The same face as the base is never a real variant.
        if (!same_face and !face_bold and !face_italic) {
            face_bold = bold;
            face_italic = italic;
        }
        const real_bold = bold and face_bold;
        const real_italic = italic and face_italic;

        if (!real_bold and !real_italic) {
            // No real variant: synthesize on the base face.
            return .{
                .ft_face = base.ft_face,
                .synthetic_bold = base.synthetic_bold or bold,
                .synthetic_italic = base.synthetic_italic or italic,
                .lcd = base.lcd,
            };
        }

        if (base.ft_face.*.size != null) {
            try face.setPixelSize(base.ft_face.*.size.*.metrics.y_ppem);
        }
        face.synthetic_bold = base.synthetic_bold or (bold and !face_bold);
        face.synthetic_italic = base.synthetic_italic or (italic and !face_italic);
        face.lcd = base.lcd;
        return face;
    }

    /// Fallback face covering codepoint `cp`, or null when no installed
    /// font covers it. Results (positive and negative) are cached per
    /// codepoint; a second call for the same cp returns the identical
    /// handle without querying fontconfig. The returned face has no pixel
    /// size set yet: call `setPixelSize` before loading glyphs.
    pub fn fallbackFace(self: *Discovery, cp: u21) !?Face {
        if (self.fallback_cache.get(cp)) |entry| return entry;
        const face = try self.queryFallback(cp);
        try self.fallback_cache.put(cp, face);
        return face;
    }

    /// Query fontconfig for a face whose charset contains `cp`: FcFontSort
    /// with a charset pattern, then an explicit FcCharSetHasChar filter
    /// (FcFontSort alone can rank fonts that do not actually cover the
    /// codepoint). First covering face in sort order wins.
    fn queryFallback(self: *Discovery, cp: u21) !?Face {
        const pat = fc.FcPatternCreate() orelse return error.FontconfigFailure;
        defer fc.FcPatternDestroy(pat);
        const cs = fc.FcCharSetCreate() orelse return error.FontconfigFailure;
        defer fc.FcCharSetDestroy(cs);
        if (fc.FcCharSetAddChar(cs, cp) == fc.FcFalse) return error.FontconfigFailure;
        // FcPatternAddCharSet copies the charset; ours is freed by the defer.
        if (fc.FcPatternAddCharSet(pat, fc.FC_CHARSET, cs) == fc.FcFalse)
            return error.FontconfigFailure;
        _ = fc.FcConfigSubstitute(self.config, pat, fc.FcMatchPattern);
        fc.FcDefaultSubstitute(pat);
        var result: fc.FcResult = fc.FcResultNoMatch;
        const set = fc.FcFontSort(self.config, pat, fc.FcFalse, null, &result);
        if (set == null or result != fc.FcResultMatch) return null;
        defer fc.FcFontSetDestroy(set);
        var i: c_int = 0;
        while (i < set.*.nfont) : (i += 1) {
            const cand = set.*.fonts[@intCast(i)] orelse continue;
            var cand_cs: ?*fc.FcCharSet = null;
            if (fc.FcPatternGetCharSet(cand, fc.FC_CHARSET, 0, &cand_cs) != fc.FcResultMatch)
                continue;
            if (fc.FcCharSetHasChar(cand_cs, cp) == fc.FcFalse) continue;
            const file = patternString(cand, fc.FC_FILE) catch continue;
            const index = patternInt(cand, fc.FC_INDEX) catch 0;
            return try self.loadFace(file, index);
        }
        return null;
    }

    /// Load (or reuse) the face at file+index. The path is duplicated into
    /// owned storage; `file` itself may be borrowed pattern memory.
    fn loadFace(self: *Discovery, file: []const u8, index: i64) !Face {
        for (self.faces.items) |rec| {
            if (rec.index == index and std.mem.eql(u8, rec.file, file))
                return .{ .ft_face = rec.ft_face };
        }
        const file_z = try self.allocator.allocSentinel(u8, file.len, 0);
        errdefer self.allocator.free(file_z);
        @memcpy(file_z, file);
        var ft_face: ft.FT_Face = null;
        try ftCheck(ft.FT_New_Face(self.library, file_z.ptr, index, &ft_face));
        errdefer _ = ft.FT_Done_Face(ft_face);
        const rec = try self.allocator.create(FaceRec);
        errdefer self.allocator.destroy(rec);
        rec.* = .{ .ft_face = ft_face, .file = file_z, .index = index };
        try self.faces.append(self.allocator, rec);
        return .{ .ft_face = rec.ft_face };
    }

    fn parsePattern(self: *Discovery, name: []const u8) !*fc.FcPattern {
        const name_z = try self.allocator.allocSentinel(u8, name.len, 0);
        defer self.allocator.free(name_z);
        @memcpy(name_z, name);
        return fc.FcNameParse(name_z.ptr) orelse error.BadFontName;
    }

    /// FcConfigSubstitute + FcDefaultSubstitute + FcFontMatch.
    fn matchPattern(self: *Discovery, pat: *fc.FcPattern) !*fc.FcPattern {
        _ = fc.FcConfigSubstitute(self.config, pat, fc.FcMatchPattern);
        fc.FcDefaultSubstitute(pat);
        var result: fc.FcResult = fc.FcResultNoMatch;
        const match = fc.FcFontMatch(self.config, pat, &result);
        if (match == null or result != fc.FcResultMatch) return error.NoFontMatch;
        return match.?;
    }
};

/// Cell geometry for terminal layout; see `CellMetrics` for the monospace
/// assumption. Loads '0' (or space) without rendering to read its advance,
/// so it invalidates borrowed glyph buffers on `face` like `loadGlyph`.
/// Requires a prior `setPixelSize`.
pub fn cellMetrics(face: Face) !CellMetrics {
    const idx = face.glyphIndex('0') orelse face.glyphIndex(' ') orelse
        return error.NoReferenceGlyph;
    try ftCheck(ft.FT_Load_Glyph(face.ft_face, idx, ft.FT_LOAD_DEFAULT));
    const advance = face.ft_face.*.glyph.*.advance.x;
    const m = face.metrics();
    const w = @max(1, @as(i32, @intCast(@divTrunc(advance, 64))));
    const h = @max(1, m.height);
    return .{
        .cell_w = @intCast(w),
        .cell_h = @intCast(h),
        .baseline = @intCast(@max(0, m.ascender)),
    };
}

/// ghostty-compatible cell geometry (port of ghostty src/font/Metrics.zig
/// `calc` + `apply` and src/font/face/freetype.zig vertical-metric selection).
/// Reads hhea/OS/2 like ghostty, uses a fractional pixel size, rounds (not
/// truncates), includes the line gap, and derives the baseline from the cell
/// bottom with half-gap centering, so identical user adjust-* percentages yield
/// the same grid as ghostty. `px_f64` is the fractional pixel size; aw/ah/ab are
/// the adjust-cell-width/height and adjust-font-baseline percentages.
pub fn cellMetricsGhostty(face: Face, px_f64: f64, aw: i32, ah: i32, ab: i32) !CellMetrics {
    const f = face.ft_face;
    const idx = face.glyphIndex('0') orelse face.glyphIndex(' ') orelse
        return error.NoReferenceGlyph;
    try ftCheck(ft.FT_Load_Glyph(f, idx, ft.FT_LOAD_DEFAULT));
    const face_width = @as(f64, @floatFromInt(f.*.glyph.*.advance.x)) / 64.0;

    const upm: f64 = @floatFromInt(f.*.units_per_EM);
    const ppu = if (upm > 0) px_f64 / upm else 0.0;
    const hhea_raw = ft.FT_Get_Sfnt_Table(f, ft.FT_SFNT_HHEA);
    const os2_raw = ft.FT_Get_Sfnt_Table(f, ft.FT_SFNT_OS2);
    const hhea: ?*const ft.TT_HoriHeader = if (hhea_raw) |p| @ptrCast(@alignCast(p)) else null;
    const os2: ?*const ft.TT_OS2 = if (os2_raw) |p| @ptrCast(@alignCast(p)) else null;

    var ascent: f64 = 0;
    var descent: f64 = 0;
    var line_gap: f64 = 0;
    var have = false;
    if (os2) |o| {
        if (o.*.fsSelection & (1 << 7) != 0) {
            ascent = @as(f64, @floatFromInt(o.*.sTypoAscender)) * ppu;
            descent = @as(f64, @floatFromInt(o.*.sTypoDescender)) * ppu;
            line_gap = @as(f64, @floatFromInt(o.*.sTypoLineGap)) * ppu;
            have = true;
        }
    }
    if (!have) {
        if (hhea) |h| {
            if (h.*.Ascender != 0 or h.*.Descender != 0) {
                ascent = @as(f64, @floatFromInt(h.*.Ascender)) * ppu;
                descent = @as(f64, @floatFromInt(h.*.Descender)) * ppu;
                line_gap = @as(f64, @floatFromInt(h.*.Line_Gap)) * ppu;
                have = true;
            }
        }
    }
    if (!have) {
        if (os2) |o| {
            if (o.*.sTypoAscender != 0 or o.*.sTypoDescender != 0) {
                ascent = @as(f64, @floatFromInt(o.*.sTypoAscender)) * ppu;
                descent = @as(f64, @floatFromInt(o.*.sTypoDescender)) * ppu;
                line_gap = @as(f64, @floatFromInt(o.*.sTypoLineGap)) * ppu;
            } else {
                ascent = @as(f64, @floatFromInt(o.*.usWinAscent)) * ppu;
                descent = -@as(f64, @floatFromInt(o.*.usWinDescent)) * ppu;
                line_gap = 0;
            }
            have = true;
        }
    }
    if (!have) {
        const sm = f.*.size.*.metrics;
        ascent = @as(f64, @floatFromInt(sm.ascender)) / 64.0;
        descent = @as(f64, @floatFromInt(sm.descender)) / 64.0;
        line_gap = @as(f64, @floatFromInt(sm.height)) / 64.0 - (ascent - descent);
    }
    const face_height = ascent - descent + line_gap;

    var cw = @round(face_width);
    var ch = @round(face_height);
    const face_baseline = line_gap / 2.0 - descent;
    var cb = @round(face_baseline - (ch - face_height) / 2.0); // from cell bottom

    cw = @max(1, @round(cw * (100.0 + @as(f64, @floatFromInt(aw))) / 100.0));
    const orig_ch = ch;
    ch = @max(1, @round(ch * (100.0 + @as(f64, @floatFromInt(ah))) / 100.0));
    const half = (ch - orig_ch) / 2.0;
    const face_y = cb - face_baseline;
    const pos = face_y - (orig_ch - face_height) / 2.0;
    cb += if (pos > 0) @floor(half) else @ceil(half);
    cb = @round(cb * (100.0 + @as(f64, @floatFromInt(ab))) / 100.0);

    const baseline_top = ch - cb;
    return .{
        .cell_w = @intCast(@as(i32, @intFromFloat(cw))),
        .cell_h = @intCast(@as(i32, @intFromFloat(ch))),
        .baseline = @intCast(@max(0, @as(i32, @intFromFloat(baseline_top)))),
    };
}

/// Map a FreeType error code to a Zig error.
fn ftCheck(err: ft.FT_Error) !void {
    if (err == ft.FT_Err_Ok) return;
    return switch (err) {
        ft.FT_Err_Cannot_Open_Resource => error.CannotOpenResource,
        ft.FT_Err_Unknown_File_Format => error.UnknownFileFormat,
        ft.FT_Err_Invalid_File_Format => error.InvalidFileFormat,
        ft.FT_Err_Invalid_Argument => error.InvalidArgument,
        ft.FT_Err_Invalid_Glyph_Index => error.InvalidGlyphIndex,
        ft.FT_Err_Invalid_Pixel_Size => error.InvalidPixelSize,
        ft.FT_Err_Cannot_Render_Glyph => error.CannotRenderGlyph,
        else => error.FreeTypeFailure,
    };
}

/// 26.6 fixed point -> whole pixels, truncated toward zero.
fn px26(v: ft.FT_Pos) i32 {
    return @intCast(@divTrunc(v, 64));
}

/// String property of a fontconfig pattern. The slice is BORROWED from the
/// pattern and dies with it.
fn patternString(pat: *const fc.FcPattern, object: [*:0]const u8) ![]const u8 {
    var s: [*c]fc.FcChar8 = null;
    if (fc.FcPatternGetString(pat, object, 0, &s) != fc.FcResultMatch or s == null)
        return error.MissingProperty;
    return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
}

/// Integer property of a fontconfig pattern.
fn patternInt(pat: *const fc.FcPattern, object: [*:0]const u8) !c_int {
    var v: c_int = 0;
    if (fc.FcPatternGetInteger(pat, object, 0, &v) != fc.FcResultMatch)
        return error.MissingProperty;
    return v;
}

// ---------------------------------------------------------------------------
// Tests: run against the HOST fontconfig (see the module comment for the
// exact standalone command). They adapt to the installed font set: CJK and
// color-emoji paths assert coverage only when such a font exists, and the
// guaranteed-missing noncharacter U+10FFFF always exercises the negative
// cache path. The LCD width test instead pins the KMSHAUNT_TEST_TEXT_FONT
// fixture (DejaVu Sans) so it does not depend on the host monospace match.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Path of the pinned text-font fixture (DejaVu Sans). The derivation
/// exports KMSHAUNT_TEST_TEXT_FONT; the fallback is the same store path
/// the color.zig tests use. Keeps font-sensitive tests independent of
/// the host's fontconfig match.
fn testTextFontPath(alloc: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("KMSHAUNT_TEST_TEXT_FONT")) |value|
        return alloc.dupe(u8, std.mem.span(value));
    return alloc.dupe(u8, "/nix/store/mz1hvwkd5i24d93ihpdczqhn65mik69d-dejavu-fonts-2.37/share/fonts/truetype/DejaVuSans.ttf");
}

test "init, primary monospace face, cell metrics" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const face = try d.primaryFace(null, 16);
    try testing.expect(face.familyName().len > 0);
    try testing.expect(!face.synthetic_bold);
    try testing.expect(!face.synthetic_italic);

    const m = face.metrics();
    try testing.expect(m.ascender > 0);
    try testing.expect(m.descender < 0);
    try testing.expect(m.height > 0);
    try testing.expect(m.underline_thickness >= 0);

    const cm = try cellMetrics(face);
    try testing.expect(cm.cell_w > 0);
    try testing.expect(cm.cell_h > 0);
    try testing.expect(cm.baseline > 0);
    try testing.expect(cm.baseline < cm.cell_h);
}

test "explicit name, face cache identity, pixel size scaling" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const a = try d.primaryFace("monospace", 16);
    const b = try d.primaryFace(null, 16);
    // Same match, same underlying face: loaded exactly once.
    try testing.expect(a.ft_face == b.ft_face);
    try testing.expectEqual(@as(usize, 1), d.faces.items.len);

    try a.setPixelSize(16);
    const m16 = a.metrics();
    try a.setPixelSize(32);
    const m32 = a.metrics();
    try testing.expect(m32.height > m16.height);
    try testing.expect(m32.ascender > m16.ascender);
}

test "'A' loads a nonzero gray bitmap" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const face = try d.primaryFace(null, 16);
    const idx = face.glyphIndex('A') orelse return error.TestUnexpectedResult;
    try testing.expect(face.glyphIndex(0x10FFFF) == null);

    const g = try face.loadGlyph(idx, false);
    try testing.expect(g.format == .gray);
    try testing.expect(g.width > 0);
    try testing.expect(g.height > 0);
    try testing.expect(g.advance_x > 0);
    try testing.expectEqual(@as(usize, @intCast(@abs(g.pitch))) * g.height, g.buffer.len);
    var nonzero = false;
    for (g.buffer) |byte| {
        if (byte != 0) {
            nonzero = true;
            break;
        }
    }
    try testing.expect(nonzero);

    // FT_LOAD_COLOR on a monochrome glyph still renders gray.
    const gc = try face.loadGlyph(idx, true);
    try testing.expect(gc.format == .gray);
}

test "lcd flag renders triple-width subpixel coverage" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    // Pin the text fixture (DejaVu Sans, a scalable outline face) rather
    // than the host's monospace match: outside the sandbox the host font
    // set can match a face whose 'A' is a bitmap strike, so the width
    // relation below would depend on the environment.
    const path = try testTextFontPath(testing.allocator);
    defer testing.allocator.free(path);
    var face = try d.loadFace(path, 0);
    try face.setPixelSize(16);
    const idx = face.glyphIndex('A') orelse return error.TestUnexpectedResult;
    // The fixture is a scalable outline face without bitmap strikes, so
    // 'A' must load as an outline and the lcd flag must select LCD
    // rendering (loadGlyph falls back to NORMAL only for bitmap/color
    // glyphs).
    try ftCheck(ft.FT_Load_Glyph(face.ft_face, idx, ft.FT_LOAD_DEFAULT));
    try testing.expect(face.ft_face.*.glyph.*.format == ft.FT_GLYPH_FORMAT_OUTLINE);

    face.lcd = true;
    const lcd = try face.loadGlyph(idx, false);
    const lcd_pixel_mode = face.ft_face.*.glyph.*.bitmap.pixel_mode;
    try testing.expect(lcd.format == .gray);
    face.lcd = false;
    const normal = try face.loadGlyph(idx, false);
    const normal_pixel_mode = face.ft_face.*.glyph.*.bitmap.pixel_mode;

    // Direct evidence of the render modes: LCD yields FT_PIXEL_MODE_LCD
    // (one coverage byte per RGB subpixel), NORMAL yields GRAY.
    try testing.expect(lcd_pixel_mode == ft.FT_PIXEL_MODE_LCD);
    try testing.expect(normal_pixel_mode == ft.FT_PIXEL_MODE_GRAY);

    // LCD triples the horizontal resolution, but not to exactly 3x the
    // NORMAL width: FreeType grid-fits the outline's control box to whole
    // pixels for NORMAL, while for LCD it first pads the box by 2/3 pixel
    // on each side for the 5-tap LCD filter (ft_lcd_padding, +/-43 in 26.6
    // units), then rounds and triples the width. The padding grows the
    // rounded box by at most one pixel per side, so the LCD width is a
    // multiple of 3 in [3*normal, 3*normal + 6]. Height is untouched.
    try testing.expect(lcd.width % 3 == 0);
    try testing.expect(lcd.width >= normal.width * 3);
    try testing.expect(lcd.width <= normal.width * 3 + 6);
    try testing.expectEqual(normal.height, lcd.height);
}

test "fallback: CJK coverage or graceful null, negative cache" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const cjk = try d.fallbackFace(0x6F22); // 漢
    if (cjk) |f| {
        try f.setPixelSize(16);
        const idx = f.glyphIndex(0x6F22) orelse return error.TestUnexpectedResult;
        const g = try f.loadGlyph(idx, false);
        try testing.expect(g.width > 0);
        try testing.expect(g.height > 0);
        // Cache hit: identical face pointer, no re-query.
        const again = try d.fallbackFace(0x6F22);
        try testing.expect(again != null);
        try testing.expect(again.?.ft_face == f.ft_face);
    }

    // U+10FFFF is a noncharacter no font covers: always the null path,
    // and the negative result is cached too.
    try testing.expect(try d.fallbackFace(0x10FFFF) == null);
    try testing.expect(try d.fallbackFace(0x10FFFF) == null);
    try testing.expect(d.fallback_cache.get(0x10FFFF) != null); // entry present...
    try testing.expect(d.fallback_cache.get(0x10FFFF).? == null); // ...and negative
}

test "fallback cache hit returns the same face pointer" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    // 'A' is covered by any usable host font set.
    const first = try d.fallbackFace('A') orelse return error.TestUnexpectedResult;
    const second = try d.fallbackFace('A') orelse return error.TestUnexpectedResult;
    try testing.expect(first.ft_face == second.ft_face);
}

fn checkStyleVariant(d: *Discovery, base: Face, bold: bool, italic: bool) !void {
    const v = try d.faceForStyle(base, bold, italic);
    if (v.ft_face == base.ft_face) {
        // No real variant: the base face carries the synthetic flags.
        try testing.expectEqual(bold, v.synthetic_bold);
        try testing.expectEqual(italic, v.synthetic_italic);
    }
    const idx = v.glyphIndex('A') orelse return error.TestUnexpectedResult;
    const g = try v.loadGlyph(idx, false);
    try testing.expect(g.width > 0);
    try testing.expect(g.buffer.len > 0);
}

test "style variants: real faces or synthetic flags" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const base = try d.primaryFace(null, 16);
    const plain = try d.faceForStyle(base, false, false);
    try testing.expect(plain.ft_face == base.ft_face);
    try testing.expect(!plain.synthetic_bold);
    try testing.expect(!plain.synthetic_italic);

    try checkStyleVariant(&d, base, true, false);
    try checkStyleVariant(&d, base, false, true);
    try checkStyleVariant(&d, base, true, true);
}

test "faceForStyle synthesizes on single-style families" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    // These families ship only a regular face, so a bold/italic request must
    // come back as the base face with synthetic flags. This is the regression
    // test for reading the matched pattern's weight (FcFontMatch echoes the
    // request) instead of the loaded face's FreeType style flags.
    const candidates = [_][]const u8{ "Unifont", "DejaVu Math TeX Gyre" };
    var found = false;
    var synthetic_exercised = false;
    for (candidates) |name| {
        const base = d.primaryFace(name, 16) catch continue;
        // Skip if fontconfig fell back to a different family.
        if (!std.mem.eql(u8, base.familyName(), name)) continue;
        found = true;
        const bold = try d.faceForStyle(base, true, false);
        const italic = try d.faceForStyle(base, false, true);
        const bi = try d.faceForStyle(base, true, true);
        if (bold.ft_face == base.ft_face) {
            try testing.expect(bold.synthetic_bold);
            synthetic_exercised = true;
        }
        if (italic.ft_face == base.ft_face) {
            try testing.expect(italic.synthetic_italic);
            synthetic_exercised = true;
        }
        if (bi.ft_face == base.ft_face) {
            try testing.expect(bi.synthetic_bold and bi.synthetic_italic);
            synthetic_exercised = true;
        }
        const idx = bold.glyphIndex('A') orelse continue;
        const g = try bold.loadGlyph(idx, false);
        try testing.expect(g.buffer.len > 0);
    }
    // When a single-style family is present the synthetic branch must run;
    // on hosts without one, skip gracefully (the invariant is still checked
    // by checkStyleVariant above).
    if (found) try testing.expect(synthetic_exercised);
}

test "synthetic flags embolden and oblique the raster" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    const base = try d.primaryFace(null, 24);
    const idx = base.glyphIndex('A') orelse return error.TestUnexpectedResult;
    const plain = try base.loadGlyph(idx, false);
    const plain_w = plain.width;

    var synth = base;
    synth.synthetic_bold = true;
    synth.synthetic_italic = true;
    const styled = try synth.loadGlyph(idx, false);
    // Emboldening grows the raster of a nonzero outline glyph.
    try testing.expect(styled.width > plain_w);
    try testing.expect(styled.buffer.len > 0);
}

test "color font renders BGRA via FT_LOAD_COLOR when available" {
    var d = try Discovery.init(testing.allocator);
    defer d.deinit();

    // Load a color emoji font by name rather than through fallbackFace:
    // FcFontSort can rank a monochrome face that also covers the codepoint
    // (e.g. DejaVu Sans) above the color font, and preferring color is the
    // renderer's job (M3.5), not discovery's. Noto Color Emoji is CBDT
    // (bitmap-only), so this also exercises the strike-selection path of
    // setPixelSize. If no color font is installed the match has no color
    // and the assertions are skipped gracefully.
    const f = try d.primaryFace("Noto Color Emoji", 16);
    if (!f.hasColor()) return;
    const idx = f.glyphIndex(0x1F600) orelse return error.TestUnexpectedResult; // 😀
    const g = try f.loadGlyph(idx, true);
    try testing.expect(g.format == .bgra);
    try testing.expect(g.width > 0);
    try testing.expect(g.height > 0);
    try testing.expectEqual(@as(usize, @intCast(@abs(g.pitch))) * g.height, g.buffer.len);
    var nonzero = false;
    for (g.buffer) |byte| {
        if (byte != 0) {
            nonzero = true;
            break;
        }
    }
    try testing.expect(nonzero);
}
