//! Terminal color palettes (ROADMAP M2.4: kmscon `--palette` /
//! `--palette-*` parity).
//!
//! This is the config-tree copy of `src/misc/palette.zig` (byte-identical
//! tables): `zig test src/config/config.zig` cannot import outside
//! `src/config/`, and the ROADMAP places palettes under `src/config/`.
//! Keep the two copies in sync until they are unified.
//!
//! All tables are transcribed from `docs/reference/kmscon-options.md` §5.10
//! (table at lines 500-516, preset list and source map at 485-524), which
//! reproduces the libtsm 4.8.0 `tsm-vte.c` arrays (`color_palette_legacy` …
//! `color_palette_base16_light`) and kmscon's `def_palette`
//! (`src/config.c:945-967`). Every one of the 162 RGB values below was also
//! cross-checked against the libtsm v4.8.0 sources
//! (github.com/kmscon/libtsm, tag v4.8.0, `src/tsm/tsm-vte.c`) and kmscon
//! 10.1.0 `src/config.c`; they match byte for byte.
//!
//! Notational note: §5.10 writes the soft-black and base16 rows in bare hex
//! shorthand (`3f,3f,3f`, `70,50,50`, …). This module stores plain decimal
//! RGB — e.g. `0x3f,0x3f,0x3f` → `63,63,63` and soft-black red `70,50,50` is
//! hex `0x70,0x50,0x50` → `112,80,80` (not decimal 70,50,50), per libtsm.

const std = @import("std");

/// Number of color slots: the 16 ANSI colors plus the default foreground and
/// default background (libtsm `TSM_COLOR_NUM`).
pub const palette_len = 18;

/// A 24-bit RGB color.
pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,

    /// Packed xRGB8888 layout — `(r << 16) | (g << 8) | b` with the top byte
    /// zero — the native bit pattern of KMS `DRM_FORMAT_XRGB8888`.
    pub fn xrgb(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }
};

/// Presets accepted by `--palette` (kmscon-options.md §5.10,
/// `get_palette` in libtsm `tsm-vte.c:410-431`). `nord` is a valid preset
/// even though the ROADMAP appendix omits it. Unset or unknown names fall
/// back to `legacy` in kmscon; this module reports `null` (see
/// `Preset.fromName`) and lets the caller apply that fallback.
pub const Preset = enum {
    custom,
    nord,
    solarized,
    solarized_black,
    solarized_white,
    soft_black,
    base16_dark,
    base16_light,
    vga,
    legacy,

    /// The kmscon `--palette=<name>` argument for this preset.
    pub fn kmsconName(self: Preset) []const u8 {
        return switch (self) {
            .custom => "custom",
            .nord => "nord",
            .solarized => "solarized",
            .solarized_black => "solarized-black",
            .solarized_white => "solarized-white",
            .soft_black => "soft-black",
            .base16_dark => "base16-dark",
            .base16_light => "base16-light",
            .vga => "vga",
            .legacy => "legacy",
        };
    }

    /// Parse a kmscon `--palette` value. Unknown names yield `null` (kmscon
    /// silently falls back to `legacy` for those).
    pub fn fromName(name: []const u8) ?Preset {
        inline for (std.meta.tags(Preset)) |tag| {
            if (std.mem.eql(u8, name, tag.kmsconName())) return tag;
        }
        return null;
    }

    /// The comptime-known 18-slot palette table for this preset.
    /// `custom` returns kmscon `def_palette` — the default base the
    /// `--palette-*` options are applied onto (byte-for-byte identical to
    /// `legacy`, per kmscon-options.md §5.10 and `config.c:945-967`).
    pub fn get(self: Preset) [palette_len]Color {
        return switch (self) {
            .custom => def_palette,
            .legacy => color_palette_legacy,
            .vga => color_palette_vga,
            .nord => color_palette_nord,
            .solarized => color_palette_solarized,
            .solarized_black => color_palette_solarized_black,
            .solarized_white => color_palette_solarized_white,
            .soft_black => color_palette_soft_black,
            .base16_dark => color_palette_base16_dark,
            .base16_light => color_palette_base16_light,
        };
    }
};

/// Slots of the 18-color palette array. Enum order == palette slot order ==
/// libtsm `TSM_COLOR_*` indices (`src/libtsm.h`): black..white are the 16
/// ANSI colors, then the default foreground/background.
///
/// The color-name set is exactly the 18 `--palette-*` suffixes kmscon
/// registers (`config.c:1071-1089`). There is no `underscore` color and no
/// `--palette-underscore` option.
pub const ColorName = enum {
    black, // TSM_COLOR_BLACK (0)
    red, // TSM_COLOR_RED (1)
    green, // TSM_COLOR_GREEN (2)
    yellow, // TSM_COLOR_YELLOW (3)
    blue, // TSM_COLOR_BLUE (4)
    magenta, // TSM_COLOR_MAGENTA (5)
    cyan, // TSM_COLOR_CYAN (6)
    light_grey, // TSM_COLOR_LIGHT_GREY (7)
    dark_grey, // TSM_COLOR_DARK_GREY (8)
    light_red, // TSM_COLOR_LIGHT_RED (9)
    light_green, // TSM_COLOR_LIGHT_GREEN (10)
    light_yellow, // TSM_COLOR_LIGHT_YELLOW (11)
    light_blue, // TSM_COLOR_LIGHT_BLUE (12)
    light_magenta, // TSM_COLOR_LIGHT_MAGENTA (13)
    light_cyan, // TSM_COLOR_LIGHT_CYAN (14)
    white, // TSM_COLOR_WHITE (15)
    foreground, // TSM_COLOR_FOREGROUND (16)
    background, // TSM_COLOR_BACKGROUND (17)

    /// The kmscon `--palette-<name>` suffix for this color (hyphenated,
    /// e.g. `"light-grey"`).
    pub fn kmsconName(self: ColorName) []const u8 {
        return switch (self) {
            .black => "black",
            .red => "red",
            .green => "green",
            .yellow => "yellow",
            .blue => "blue",
            .magenta => "magenta",
            .cyan => "cyan",
            .light_grey => "light-grey",
            .dark_grey => "dark-grey",
            .light_red => "light-red",
            .light_green => "light-green",
            .light_yellow => "light-yellow",
            .light_blue => "light-blue",
            .light_magenta => "light-magenta",
            .light_cyan => "light-cyan",
            .white => "white",
            .foreground => "foreground",
            .background => "background",
        };
    }

    /// Parse a kmscon color name (the suffix after `palette-`). Only the
    /// documented hyphenated names are accepted; `"underscore"`, underscore
    /// forms like `"light_grey"`, and any other unknown name yield `null`
    /// (kmscon would reject such an option name at config parse time).
    pub fn fromName(name: []const u8) ?ColorName {
        inline for (std.meta.tags(ColorName)) |tag| {
            if (std.mem.eql(u8, name, tag.kmsconName())) return tag;
        }
        return null;
    }

    /// Index of this color inside the 18-slot palette array.
    pub fn slot(self: ColorName) usize {
        return @intFromEnum(self);
    }
};

/// kmscon `def_palette` (`src/config.c:945-967`): the default base of the
/// custom palette, byte-for-byte identical to the legacy palette. This is
/// the `base` argument callers pass to `applyCustom`; equivalently
/// `Preset.get(.custom)`.
pub const def_palette: [palette_len]Color = color_palette_legacy;

// ---------------------------------------------------------------------------
// Palette tables. Slot order: 16 ANSI colors (black, red, green, yellow,
// blue, magenta, cyan, light grey, dark grey, light red, light green, light
// yellow, light blue, light magenta, light cyan, white) then foreground,
// background. Source: kmscon-options.md §5.10 (lines 500-516), verified
// against libtsm v4.8.0 `tsm-vte.c` (`color_palette_legacy` at 213,
// `_vga` 235, `_nord` 257, `_solarized` 279, `_solarized_black` 301,
// `_solarized_white` 323, `_soft_black` 345, `_base16_dark` 367,
// `_base16_light` 389).
// ---------------------------------------------------------------------------

/// libtsm `color_palette_legacy` (tsm-vte.c:213-233); equals kmscon
/// `def_palette` (the `custom` default) and the `--palette-*` option
/// defaults in the master table (kmscon-options.md:98-115).
const color_palette_legacy: [palette_len]Color = .{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 205, .g = 0, .b = 0 }, // red
    .{ .r = 0, .g = 205, .b = 0 }, // green
    .{ .r = 205, .g = 205, .b = 0 }, // yellow
    .{ .r = 0, .g = 0, .b = 238 }, // blue
    .{ .r = 205, .g = 0, .b = 205 }, // magenta
    .{ .r = 0, .g = 205, .b = 205 }, // cyan
    .{ .r = 229, .g = 229, .b = 229 }, // light grey
    .{ .r = 127, .g = 127, .b = 127 }, // dark grey
    .{ .r = 255, .g = 0, .b = 0 }, // light red
    .{ .r = 0, .g = 255, .b = 0 }, // light green
    .{ .r = 255, .g = 255, .b = 0 }, // light yellow
    .{ .r = 92, .g = 92, .b = 255 }, // light blue
    .{ .r = 255, .g = 0, .b = 255 }, // light magenta
    .{ .r = 0, .g = 255, .b = 255 }, // light cyan
    .{ .r = 255, .g = 255, .b = 255 }, // white
    .{ .r = 229, .g = 229, .b = 229 }, // foreground
    .{ .r = 0, .g = 0, .b = 0 }, // background
};

/// libtsm `color_palette_vga` (tsm-vte.c:235-255).
const color_palette_vga: [palette_len]Color = .{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 170, .g = 0, .b = 0 }, // red
    .{ .r = 0, .g = 170, .b = 0 }, // green
    .{ .r = 170, .g = 85, .b = 0 }, // yellow
    .{ .r = 0, .g = 0, .b = 170 }, // blue
    .{ .r = 170, .g = 0, .b = 170 }, // magenta
    .{ .r = 0, .g = 170, .b = 170 }, // cyan
    .{ .r = 170, .g = 170, .b = 170 }, // light grey
    .{ .r = 85, .g = 85, .b = 85 }, // dark grey
    .{ .r = 255, .g = 85, .b = 85 }, // light red
    .{ .r = 85, .g = 255, .b = 85 }, // light green
    .{ .r = 255, .g = 255, .b = 85 }, // light yellow
    .{ .r = 85, .g = 85, .b = 255 }, // light blue
    .{ .r = 255, .g = 85, .b = 255 }, // light magenta
    .{ .r = 85, .g = 255, .b = 255 }, // light cyan
    .{ .r = 255, .g = 255, .b = 255 }, // white
    .{ .r = 170, .g = 170, .b = 170 }, // foreground
    .{ .r = 0, .g = 0, .b = 0 }, // background
};

/// libtsm `color_palette_nord` (tsm-vte.c:257-277); new in libtsm 4.8.0,
/// absent from the ROADMAP appendix.
const color_palette_nord: [palette_len]Color = .{
    .{ .r = 59, .g = 66, .b = 82 }, // black
    .{ .r = 191, .g = 97, .b = 106 }, // red
    .{ .r = 163, .g = 190, .b = 140 }, // green
    .{ .r = 235, .g = 203, .b = 139 }, // yellow
    .{ .r = 129, .g = 161, .b = 193 }, // blue
    .{ .r = 180, .g = 142, .b = 173 }, // magenta
    .{ .r = 136, .g = 192, .b = 208 }, // cyan
    .{ .r = 229, .g = 233, .b = 240 }, // light grey
    .{ .r = 76, .g = 86, .b = 106 }, // dark grey
    .{ .r = 191, .g = 97, .b = 106 }, // light red
    .{ .r = 163, .g = 190, .b = 140 }, // light green
    .{ .r = 235, .g = 203, .b = 139 }, // light yellow
    .{ .r = 129, .g = 161, .b = 193 }, // light blue
    .{ .r = 180, .g = 142, .b = 173 }, // light magenta
    .{ .r = 143, .g = 188, .b = 187 }, // light cyan
    .{ .r = 236, .g = 239, .b = 244 }, // white
    .{ .r = 216, .g = 222, .b = 233 }, // foreground
    .{ .r = 46, .g = 52, .b = 64 }, // background
};

/// libtsm `color_palette_solarized` (tsm-vte.c:279-299).
const color_palette_solarized: [palette_len]Color = .{
    .{ .r = 7, .g = 54, .b = 66 }, // black
    .{ .r = 220, .g = 50, .b = 47 }, // red
    .{ .r = 133, .g = 153, .b = 0 }, // green
    .{ .r = 181, .g = 137, .b = 0 }, // yellow
    .{ .r = 38, .g = 139, .b = 210 }, // blue
    .{ .r = 211, .g = 54, .b = 130 }, // magenta
    .{ .r = 42, .g = 161, .b = 152 }, // cyan
    .{ .r = 238, .g = 232, .b = 213 }, // light grey
    .{ .r = 0, .g = 43, .b = 54 }, // dark grey
    .{ .r = 203, .g = 75, .b = 22 }, // light red
    .{ .r = 88, .g = 110, .b = 117 }, // light green
    .{ .r = 101, .g = 123, .b = 131 }, // light yellow
    .{ .r = 131, .g = 148, .b = 150 }, // light blue
    .{ .r = 108, .g = 113, .b = 196 }, // light magenta
    .{ .r = 147, .g = 161, .b = 161 }, // light cyan
    .{ .r = 253, .g = 246, .b = 227 }, // white
    .{ .r = 238, .g = 232, .b = 213 }, // foreground
    .{ .r = 7, .g = 54, .b = 66 }, // background
};

/// libtsm `color_palette_solarized_black` (tsm-vte.c:301-321): solarized
/// with black and background forced to pure black.
const color_palette_solarized_black: [palette_len]Color = .{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 220, .g = 50, .b = 47 }, // red
    .{ .r = 133, .g = 153, .b = 0 }, // green
    .{ .r = 181, .g = 137, .b = 0 }, // yellow
    .{ .r = 38, .g = 139, .b = 210 }, // blue
    .{ .r = 211, .g = 54, .b = 130 }, // magenta
    .{ .r = 42, .g = 161, .b = 152 }, // cyan
    .{ .r = 238, .g = 232, .b = 213 }, // light grey
    .{ .r = 0, .g = 43, .b = 54 }, // dark grey
    .{ .r = 203, .g = 75, .b = 22 }, // light red
    .{ .r = 88, .g = 110, .b = 117 }, // light green
    .{ .r = 101, .g = 123, .b = 131 }, // light yellow
    .{ .r = 131, .g = 148, .b = 150 }, // light blue
    .{ .r = 108, .g = 113, .b = 196 }, // light magenta
    .{ .r = 147, .g = 161, .b = 161 }, // light cyan
    .{ .r = 253, .g = 246, .b = 227 }, // white
    .{ .r = 238, .g = 232, .b = 213 }, // foreground
    .{ .r = 0, .g = 0, .b = 0 }, // background
};

/// libtsm `color_palette_solarized_white` (tsm-vte.c:323-343): solarized
/// with foreground/background swapped (fg = base02, bg = base2).
const color_palette_solarized_white: [palette_len]Color = .{
    .{ .r = 7, .g = 54, .b = 66 }, // black
    .{ .r = 220, .g = 50, .b = 47 }, // red
    .{ .r = 133, .g = 153, .b = 0 }, // green
    .{ .r = 181, .g = 137, .b = 0 }, // yellow
    .{ .r = 38, .g = 139, .b = 210 }, // blue
    .{ .r = 211, .g = 54, .b = 130 }, // magenta
    .{ .r = 42, .g = 161, .b = 152 }, // cyan
    .{ .r = 238, .g = 232, .b = 213 }, // light grey
    .{ .r = 0, .g = 43, .b = 54 }, // dark grey
    .{ .r = 203, .g = 75, .b = 22 }, // light red
    .{ .r = 88, .g = 110, .b = 117 }, // light green
    .{ .r = 101, .g = 123, .b = 131 }, // light yellow
    .{ .r = 131, .g = 148, .b = 150 }, // light blue
    .{ .r = 108, .g = 113, .b = 196 }, // light magenta
    .{ .r = 147, .g = 161, .b = 161 }, // light cyan
    .{ .r = 253, .g = 246, .b = 227 }, // white
    .{ .r = 7, .g = 54, .b = 66 }, // foreground
    .{ .r = 238, .g = 232, .b = 213 }, // background
};

/// libtsm `color_palette_soft_black` (tsm-vte.c:345-365).
const color_palette_soft_black: [palette_len]Color = .{
    .{ .r = 63, .g = 63, .b = 63 }, // black (0x3f)
    .{ .r = 112, .g = 80, .b = 80 }, // red (0x70,0x50,0x50)
    .{ .r = 96, .g = 180, .b = 138 }, // green (0x60,0xb4,0x8a)
    .{ .r = 223, .g = 175, .b = 143 }, // yellow (0xdf,0xaf,0x8f)
    .{ .r = 154, .g = 184, .b = 215 }, // blue (0x9a,0xb8,0xd7)
    .{ .r = 220, .g = 140, .b = 195 }, // magenta (0xdc,0x8c,0xc3)
    .{ .r = 140, .g = 208, .b = 211 }, // cyan (0x8c,0xd0,0xd3)
    .{ .r = 255, .g = 255, .b = 255 }, // light grey (0xff)
    .{ .r = 112, .g = 144, .b = 128 }, // dark grey (0x70,0x90,0x80)
    .{ .r = 220, .g = 163, .b = 163 }, // light red (0xdc,0xa3,0xa3)
    .{ .r = 114, .g = 213, .b = 163 }, // light green (0x72,0xd5,0xa3)
    .{ .r = 240, .g = 223, .b = 175 }, // light yellow (0xf0,0xdf,0xaf)
    .{ .r = 148, .g = 191, .b = 243 }, // light blue (0x94,0xbf,0xf3)
    .{ .r = 236, .g = 147, .b = 211 }, // light magenta (0xec,0x93,0xd3)
    .{ .r = 147, .g = 224, .b = 227 }, // light cyan (0x93,0xe0,0xe3)
    .{ .r = 220, .g = 220, .b = 204 }, // white (0xdc,0xdc,0xcc)
    .{ .r = 220, .g = 220, .b = 204 }, // foreground (0xdc,0xdc,0xcc)
    .{ .r = 44, .g = 44, .b = 44 }, // background (0x2c)
};

/// libtsm `color_palette_base16_dark` (tsm-vte.c:367-387): base16
/// "default dark".
const color_palette_base16_dark: [palette_len]Color = .{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 171, .g = 70, .b = 66 }, // red (0xab,0x46,0x42, base08)
    .{ .r = 161, .g = 181, .b = 108 }, // green (0xa1,0xb5,0x6c, base0B)
    .{ .r = 247, .g = 202, .b = 136 }, // yellow (0xf7,0xca,0x88, base0A)
    .{ .r = 124, .g = 175, .b = 194 }, // blue (0x7c,0xaf,0xc2, base0D)
    .{ .r = 186, .g = 139, .b = 175 }, // magenta (0xba,0x8b,0xaf, base0E)
    .{ .r = 134, .g = 193, .b = 185 }, // cyan (0x86,0xc1,0xb9, base0C)
    .{ .r = 170, .g = 170, .b = 170 }, // light grey (0xaa)
    .{ .r = 85, .g = 85, .b = 85 }, // dark grey (0x55)
    .{ .r = 171, .g = 70, .b = 66 }, // light red (base08)
    .{ .r = 161, .g = 181, .b = 108 }, // light green (base0B)
    .{ .r = 247, .g = 202, .b = 136 }, // light yellow (base0A)
    .{ .r = 124, .g = 175, .b = 194 }, // light blue (base0D)
    .{ .r = 186, .g = 139, .b = 175 }, // light magenta (base0E)
    .{ .r = 134, .g = 193, .b = 185 }, // light cyan (base0C)
    .{ .r = 255, .g = 255, .b = 255 }, // white (0xff)
    .{ .r = 216, .g = 216, .b = 216 }, // foreground (0xd8)
    .{ .r = 24, .g = 24, .b = 24 }, // background (0x18)
};

/// libtsm `color_palette_base16_light` (tsm-vte.c:389-409): base16
/// "default light"; ANSI slots identical to base16-dark, foreground and
/// background swapped.
const color_palette_base16_light: [palette_len]Color = .{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 171, .g = 70, .b = 66 }, // red (base08)
    .{ .r = 161, .g = 181, .b = 108 }, // green (base0B)
    .{ .r = 247, .g = 202, .b = 136 }, // yellow (base0A)
    .{ .r = 124, .g = 175, .b = 194 }, // blue (base0D)
    .{ .r = 186, .g = 139, .b = 175 }, // magenta (base0E)
    .{ .r = 134, .g = 193, .b = 185 }, // cyan (base0C)
    .{ .r = 170, .g = 170, .b = 170 }, // light grey (0xaa)
    .{ .r = 85, .g = 85, .b = 85 }, // dark grey (0x55)
    .{ .r = 171, .g = 70, .b = 66 }, // light red (base08)
    .{ .r = 161, .g = 181, .b = 108 }, // light green (base0B)
    .{ .r = 247, .g = 202, .b = 136 }, // light yellow (base0A)
    .{ .r = 124, .g = 175, .b = 194 }, // light blue (base0D)
    .{ .r = 186, .g = 139, .b = 175 }, // light magenta (base0E)
    .{ .r = 134, .g = 193, .b = 185 }, // light cyan (base0C)
    .{ .r = 255, .g = 255, .b = 255 }, // white (0xff)
    .{ .r = 24, .g = 24, .b = 24 }, // foreground (0x18)
    .{ .r = 216, .g = 216, .b = 216 }, // background (0xd8)
};

/// One `--palette-<name>=R,G,B` override. `name` is the kmscon color name
/// without the `palette-` prefix (e.g. `"light-grey"`).
pub const ColorOverride = struct {
    name: []const u8,
    color: Color,
};

pub const CustomError = error{
    /// The override `name` is not one of the 18 documented color names
    /// (e.g. `"underscore"`, for which no `--palette-underscore` option
    /// exists).
    UnknownColorName,
};

/// Builds the custom palette: `base` is the documented default
/// (`def_palette` == `Preset.get(.custom)` == the legacy palette, kmscon
/// `config.c:945-967`) with every override written into its slot. Unknown
/// color names are an error (kmscon rejects such option names at config
/// parse time). Repeated names: last one wins ("only the last argument
/// matters").
pub fn applyCustom(
    base: [palette_len]Color,
    overrides: []const ColorOverride,
) CustomError![palette_len]Color {
    var out = base;
    for (overrides) |o| {
        const cn = ColorName.fromName(o.name) orelse return error.UnknownColorName;
        out[cn.slot()] = o.color;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests. Palette expectations are the doc's §5.10 table values, transcribed
// inline so every slot of every preset is checked against the doc.
// ---------------------------------------------------------------------------

fn expectWholePalette(preset: Preset, expected: [palette_len]Color) !void {
    const got = preset.get();
    try std.testing.expectEqual(palette_len, got.len);
    try std.testing.expectEqual(expected, got);
}

test "xrgb packs the xRGB8888 bit pattern" {
    try std.testing.expectEqual(@as(u32, 0x00AB4642), (Color{ .r = 0xAB, .g = 0x46, .b = 0x42 }).xrgb());
    try std.testing.expectEqual(@as(u32, 0x00000000), (Color{ .r = 0, .g = 0, .b = 0 }).xrgb());
    try std.testing.expectEqual(@as(u32, 0x00FFFFFF), (Color{ .r = 255, .g = 255, .b = 255 }).xrgb());
    try std.testing.expectEqual(@as(u32, 0x00E50000), (Color{ .r = 229, .g = 0, .b = 0 }).xrgb());
}

test "preset names round-trip and unknown names are null" {
    inline for (std.meta.tags(Preset)) |p| {
        try std.testing.expectEqual(p, Preset.fromName(p.kmsconName()));
    }
    try std.testing.expectEqualStrings("solarized-black", Preset.solarized_black.kmsconName());
    try std.testing.expectEqualStrings("base16-light", Preset.base16_light.kmsconName());
    try std.testing.expectEqualStrings("nord", Preset.nord.kmsconName());
    try std.testing.expectEqual(@as(?Preset, null), Preset.fromName("solarized_black"));
    try std.testing.expectEqual(@as(?Preset, null), Preset.fromName("vga!"));
    try std.testing.expectEqual(@as(?Preset, null), Preset.fromName(""));
}

test "legacy palette matches the documented --palette-* defaults" {
    // Master table, kmscon-options.md:98-115 (== def_palette, config.c:945-967).
    const expected: [palette_len]Color = .{
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 205, .g = 0, .b = 0 }, // red
        .{ .r = 0, .g = 205, .b = 0 }, // green
        .{ .r = 205, .g = 205, .b = 0 }, // yellow
        .{ .r = 0, .g = 0, .b = 238 }, // blue
        .{ .r = 205, .g = 0, .b = 205 }, // magenta
        .{ .r = 0, .g = 205, .b = 205 }, // cyan
        .{ .r = 229, .g = 229, .b = 229 }, // light grey
        .{ .r = 127, .g = 127, .b = 127 }, // dark grey
        .{ .r = 255, .g = 0, .b = 0 }, // light red
        .{ .r = 0, .g = 255, .b = 0 }, // light green
        .{ .r = 255, .g = 255, .b = 0 }, // light yellow
        .{ .r = 92, .g = 92, .b = 255 }, // light blue
        .{ .r = 255, .g = 0, .b = 255 }, // light magenta
        .{ .r = 0, .g = 255, .b = 255 }, // light cyan
        .{ .r = 255, .g = 255, .b = 255 }, // white
        .{ .r = 229, .g = 229, .b = 229 }, // foreground
        .{ .r = 0, .g = 0, .b = 0 }, // background
    };
    try expectWholePalette(.legacy, expected);
}

test "vga palette matches doc §5.10" {
    try expectWholePalette(.vga, .{
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 170, .g = 0, .b = 0 }, // red
        .{ .r = 0, .g = 170, .b = 0 }, // green
        .{ .r = 170, .g = 85, .b = 0 }, // yellow
        .{ .r = 0, .g = 0, .b = 170 }, // blue
        .{ .r = 170, .g = 0, .b = 170 }, // magenta
        .{ .r = 0, .g = 170, .b = 170 }, // cyan
        .{ .r = 170, .g = 170, .b = 170 }, // light grey
        .{ .r = 85, .g = 85, .b = 85 }, // dark grey
        .{ .r = 255, .g = 85, .b = 85 }, // light red
        .{ .r = 85, .g = 255, .b = 85 }, // light green
        .{ .r = 255, .g = 255, .b = 85 }, // light yellow
        .{ .r = 85, .g = 85, .b = 255 }, // light blue
        .{ .r = 255, .g = 85, .b = 255 }, // light magenta
        .{ .r = 85, .g = 255, .b = 255 }, // light cyan
        .{ .r = 255, .g = 255, .b = 255 }, // white
        .{ .r = 170, .g = 170, .b = 170 }, // foreground
        .{ .r = 0, .g = 0, .b = 0 }, // background
    });
}

test "nord palette matches doc §5.10" {
    try expectWholePalette(.nord, .{
        .{ .r = 59, .g = 66, .b = 82 }, // black
        .{ .r = 191, .g = 97, .b = 106 }, // red
        .{ .r = 163, .g = 190, .b = 140 }, // green
        .{ .r = 235, .g = 203, .b = 139 }, // yellow
        .{ .r = 129, .g = 161, .b = 193 }, // blue
        .{ .r = 180, .g = 142, .b = 173 }, // magenta
        .{ .r = 136, .g = 192, .b = 208 }, // cyan
        .{ .r = 229, .g = 233, .b = 240 }, // light grey
        .{ .r = 76, .g = 86, .b = 106 }, // dark grey
        .{ .r = 191, .g = 97, .b = 106 }, // light red
        .{ .r = 163, .g = 190, .b = 140 }, // light green
        .{ .r = 235, .g = 203, .b = 139 }, // light yellow
        .{ .r = 129, .g = 161, .b = 193 }, // light blue
        .{ .r = 180, .g = 142, .b = 173 }, // light magenta
        .{ .r = 143, .g = 188, .b = 187 }, // light cyan
        .{ .r = 236, .g = 239, .b = 244 }, // white
        .{ .r = 216, .g = 222, .b = 233 }, // foreground
        .{ .r = 46, .g = 52, .b = 64 }, // background
    });
}

test "solarized palette matches doc §5.10" {
    try expectWholePalette(.solarized, .{
        .{ .r = 7, .g = 54, .b = 66 }, // black
        .{ .r = 220, .g = 50, .b = 47 }, // red
        .{ .r = 133, .g = 153, .b = 0 }, // green
        .{ .r = 181, .g = 137, .b = 0 }, // yellow
        .{ .r = 38, .g = 139, .b = 210 }, // blue
        .{ .r = 211, .g = 54, .b = 130 }, // magenta
        .{ .r = 42, .g = 161, .b = 152 }, // cyan
        .{ .r = 238, .g = 232, .b = 213 }, // light grey
        .{ .r = 0, .g = 43, .b = 54 }, // dark grey
        .{ .r = 203, .g = 75, .b = 22 }, // light red
        .{ .r = 88, .g = 110, .b = 117 }, // light green
        .{ .r = 101, .g = 123, .b = 131 }, // light yellow
        .{ .r = 131, .g = 148, .b = 150 }, // light blue
        .{ .r = 108, .g = 113, .b = 196 }, // light magenta
        .{ .r = 147, .g = 161, .b = 161 }, // light cyan
        .{ .r = 253, .g = 246, .b = 227 }, // white
        .{ .r = 238, .g = 232, .b = 213 }, // foreground
        .{ .r = 7, .g = 54, .b = 66 }, // background
    });
}

test "solarized-black palette matches doc §5.10" {
    try expectWholePalette(.solarized_black, .{
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 220, .g = 50, .b = 47 }, // red
        .{ .r = 133, .g = 153, .b = 0 }, // green
        .{ .r = 181, .g = 137, .b = 0 }, // yellow
        .{ .r = 38, .g = 139, .b = 210 }, // blue
        .{ .r = 211, .g = 54, .b = 130 }, // magenta
        .{ .r = 42, .g = 161, .b = 152 }, // cyan
        .{ .r = 238, .g = 232, .b = 213 }, // light grey
        .{ .r = 0, .g = 43, .b = 54 }, // dark grey
        .{ .r = 203, .g = 75, .b = 22 }, // light red
        .{ .r = 88, .g = 110, .b = 117 }, // light green
        .{ .r = 101, .g = 123, .b = 131 }, // light yellow
        .{ .r = 131, .g = 148, .b = 150 }, // light blue
        .{ .r = 108, .g = 113, .b = 196 }, // light magenta
        .{ .r = 147, .g = 161, .b = 161 }, // light cyan
        .{ .r = 253, .g = 246, .b = 227 }, // white
        .{ .r = 238, .g = 232, .b = 213 }, // foreground
        .{ .r = 0, .g = 0, .b = 0 }, // background
    });
}

test "solarized-white palette matches doc §5.10" {
    try expectWholePalette(.solarized_white, .{
        .{ .r = 7, .g = 54, .b = 66 }, // black
        .{ .r = 220, .g = 50, .b = 47 }, // red
        .{ .r = 133, .g = 153, .b = 0 }, // green
        .{ .r = 181, .g = 137, .b = 0 }, // yellow
        .{ .r = 38, .g = 139, .b = 210 }, // blue
        .{ .r = 211, .g = 54, .b = 130 }, // magenta
        .{ .r = 42, .g = 161, .b = 152 }, // cyan
        .{ .r = 238, .g = 232, .b = 213 }, // light grey
        .{ .r = 0, .g = 43, .b = 54 }, // dark grey
        .{ .r = 203, .g = 75, .b = 22 }, // light red
        .{ .r = 88, .g = 110, .b = 117 }, // light green
        .{ .r = 101, .g = 123, .b = 131 }, // light yellow
        .{ .r = 131, .g = 148, .b = 150 }, // light blue
        .{ .r = 108, .g = 113, .b = 196 }, // light magenta
        .{ .r = 147, .g = 161, .b = 161 }, // light cyan
        .{ .r = 253, .g = 246, .b = 227 }, // white
        .{ .r = 7, .g = 54, .b = 66 }, // foreground
        .{ .r = 238, .g = 232, .b = 213 }, // background
    });
}

test "soft-black palette matches doc §5.10" {
    try expectWholePalette(.soft_black, .{
        .{ .r = 63, .g = 63, .b = 63 }, // black (0x3f)
        .{ .r = 112, .g = 80, .b = 80 }, // red (0x70,0x50,0x50)
        .{ .r = 96, .g = 180, .b = 138 }, // green (0x60,0xb4,0x8a)
        .{ .r = 223, .g = 175, .b = 143 }, // yellow (0xdf,0xaf,0x8f)
        .{ .r = 154, .g = 184, .b = 215 }, // blue (0x9a,0xb8,0xd7)
        .{ .r = 220, .g = 140, .b = 195 }, // magenta (0xdc,0x8c,0xc3)
        .{ .r = 140, .g = 208, .b = 211 }, // cyan (0x8c,0xd0,0xd3)
        .{ .r = 255, .g = 255, .b = 255 }, // light grey (0xff)
        .{ .r = 112, .g = 144, .b = 128 }, // dark grey (0x70,0x90,0x80)
        .{ .r = 220, .g = 163, .b = 163 }, // light red (0xdc,0xa3,0xa3)
        .{ .r = 114, .g = 213, .b = 163 }, // light green (0x72,0xd5,0xa3)
        .{ .r = 240, .g = 223, .b = 175 }, // light yellow (0xf0,0xdf,0xaf)
        .{ .r = 148, .g = 191, .b = 243 }, // light blue (0x94,0xbf,0xf3)
        .{ .r = 236, .g = 147, .b = 211 }, // light magenta (0xec,0x93,0xd3)
        .{ .r = 147, .g = 224, .b = 227 }, // light cyan (0x93,0xe0,0xe3)
        .{ .r = 220, .g = 220, .b = 204 }, // white (0xdc,0xdc,0xcc)
        .{ .r = 220, .g = 220, .b = 204 }, // foreground (0xdc,0xdc,0xcc)
        .{ .r = 44, .g = 44, .b = 44 }, // background (0x2c)
    });
}

test "base16-dark palette matches doc §5.10" {
    try expectWholePalette(.base16_dark, .{
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 171, .g = 70, .b = 66 }, // red (0xab,0x46,0x42)
        .{ .r = 161, .g = 181, .b = 108 }, // green (0xa1,0xb5,0x6c)
        .{ .r = 247, .g = 202, .b = 136 }, // yellow (0xf7,0xca,0x88)
        .{ .r = 124, .g = 175, .b = 194 }, // blue (0x7c,0xaf,0xc2)
        .{ .r = 186, .g = 139, .b = 175 }, // magenta (0xba,0x8b,0xaf)
        .{ .r = 134, .g = 193, .b = 185 }, // cyan (0x86,0xc1,0xb9)
        .{ .r = 170, .g = 170, .b = 170 }, // light grey (0xaa)
        .{ .r = 85, .g = 85, .b = 85 }, // dark grey (0x55)
        .{ .r = 171, .g = 70, .b = 66 }, // light red
        .{ .r = 161, .g = 181, .b = 108 }, // light green
        .{ .r = 247, .g = 202, .b = 136 }, // light yellow
        .{ .r = 124, .g = 175, .b = 194 }, // light blue
        .{ .r = 186, .g = 139, .b = 175 }, // light magenta
        .{ .r = 134, .g = 193, .b = 185 }, // light cyan
        .{ .r = 255, .g = 255, .b = 255 }, // white
        .{ .r = 216, .g = 216, .b = 216 }, // foreground (0xd8)
        .{ .r = 24, .g = 24, .b = 24 }, // background (0x18)
    });
}

test "base16-light palette matches doc §5.10" {
    try expectWholePalette(.base16_light, .{
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 171, .g = 70, .b = 66 }, // red
        .{ .r = 161, .g = 181, .b = 108 }, // green
        .{ .r = 247, .g = 202, .b = 136 }, // yellow
        .{ .r = 124, .g = 175, .b = 194 }, // blue
        .{ .r = 186, .g = 139, .b = 175 }, // magenta
        .{ .r = 134, .g = 193, .b = 185 }, // cyan
        .{ .r = 170, .g = 170, .b = 170 }, // light grey
        .{ .r = 85, .g = 85, .b = 85 }, // dark grey
        .{ .r = 171, .g = 70, .b = 66 }, // light red
        .{ .r = 161, .g = 181, .b = 108 }, // light green
        .{ .r = 247, .g = 202, .b = 136 }, // light yellow
        .{ .r = 124, .g = 175, .b = 194 }, // light blue
        .{ .r = 186, .g = 139, .b = 175 }, // light magenta
        .{ .r = 134, .g = 193, .b = 185 }, // light cyan
        .{ .r = 255, .g = 255, .b = 255 }, // white
        .{ .r = 24, .g = 24, .b = 24 }, // foreground (0x18)
        .{ .r = 216, .g = 216, .b = 216 }, // background (0xd8)
    });
}

test "custom default is the documented def_palette identity" {
    // def_palette (config.c:945-967) is byte-identical to legacy per doc §5.10.
    try std.testing.expectEqual(Preset.legacy.get(), Preset.custom.get());
    try std.testing.expectEqual(Preset.legacy.get(), def_palette);
    // Empty overrides keep the base untouched.
    const no_overrides = try applyCustom(Preset.custom.get(), &.{});
    try std.testing.expectEqual(Preset.custom.get(), no_overrides);
}

test "custom palette applies overrides onto the base" {
    const base = Preset.custom.get();
    const out = try applyCustom(base, &.{
        .{ .name = "red", .color = .{ .r = 1, .g = 2, .b = 3 } },
        .{ .name = "light-grey", .color = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .name = "background", .color = .{ .r = 40, .g = 50, .b = 60 } },
        .{ .name = "foreground", .color = .{ .r = 70, .g = 80, .b = 90 } },
    });
    try std.testing.expectEqual(Color{ .r = 1, .g = 2, .b = 3 }, out[ColorName.red.slot()]);
    try std.testing.expectEqual(Color{ .r = 10, .g = 20, .b = 30 }, out[ColorName.light_grey.slot()]);
    try std.testing.expectEqual(Color{ .r = 40, .g = 50, .b = 60 }, out[ColorName.background.slot()]);
    try std.testing.expectEqual(Color{ .r = 70, .g = 80, .b = 90 }, out[ColorName.foreground.slot()]);
    // All untouched slots stay at the base value.
    for (0..palette_len) |i| {
        if (i == ColorName.red.slot() or i == ColorName.light_grey.slot() or
            i == ColorName.background.slot() or i == ColorName.foreground.slot()) continue;
        try std.testing.expectEqual(base[i], out[i]);
    }
    // Repeated names: last one wins.
    const dup = try applyCustom(base, &.{
        .{ .name = "blue", .color = .{ .r = 1, .g = 1, .b = 1 } },
        .{ .name = "blue", .color = .{ .r = 2, .g = 2, .b = 2 } },
    });
    try std.testing.expectEqual(Color{ .r = 2, .g = 2, .b = 2 }, dup[ColorName.blue.slot()]);
}

test "custom palette rejects underscore and unknown color names" {
    try std.testing.expectError(
        error.UnknownColorName,
        applyCustom(Preset.custom.get(), &.{.{
            .name = "underscore",
            .color = .{ .r = 0, .g = 0, .b = 0 },
        }}),
    );
    try std.testing.expectError(
        error.UnknownColorName,
        applyCustom(Preset.custom.get(), &.{.{
            .name = "purple",
            .color = .{ .r = 0, .g = 0, .b = 0 },
        }}),
    );
    // kmscon color names are hyphenated; the underscore form is not an option.
    try std.testing.expectError(
        error.UnknownColorName,
        applyCustom(Preset.custom.get(), &.{.{
            .name = "light_grey",
            .color = .{ .r = 0, .g = 0, .b = 0 },
        }}),
    );
    try std.testing.expectEqual(@as(?ColorName, null), ColorName.fromName("underscore"));
    try std.testing.expectEqual(@as(?ColorName, null), ColorName.fromName("dark grey"));
}

test "color-name set and slot mapping match the doc" {
    // The 18 names, in slot order, exactly as kmscon registers them
    // (config.c:1071-1089); black=0 … background=17 (TSM_COLOR_*).
    const names = [_][]const u8{
        "black",        "red",         "green",    "yellow",     "blue",
        "magenta",      "cyan",        "light-grey", "dark-grey", "light-red",
        "light-green",  "light-yellow", "light-blue", "light-magenta", "light-cyan",
        "white",        "foreground",  "background",
    };
    for (names, 0..) |n, i| {
        const cn = ColorName.fromName(n) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(i, cn.slot());
        try std.testing.expectEqualStrings(n, cn.kmsconName());
    }
    try std.testing.expectEqual(palette_len, names.len);
}

test "palette tables are comptime-known" {
    const b16_light_bg: Color = comptime Preset.base16_light.get()[ColorName.background.slot()];
    try std.testing.expectEqual(Color{ .r = 216, .g = 216, .b = 216 }, b16_light_bg);
    const nord_blue: Color = comptime Preset.nord.get()[ColorName.blue.slot()];
    try std.testing.expectEqual(Color{ .r = 129, .g = 161, .b = 193 }, nord_blue);
    const vga_fg: Color = comptime Preset.vga.get()[ColorName.foreground.slot()];
    try std.testing.expectEqual(Color{ .r = 170, .g = 170, .b = 170 }, vga_fg);
}