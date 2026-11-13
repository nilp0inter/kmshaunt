//! src/font/shaper.zig -- cell-to-run grouping + HarfBuzz shaping (ROADMAP M3.3,
//! decision D7: FreeType for outlines, HarfBuzz for shaping).
//!
//! Two halves live in this file:
//!
//!  1. A PURE-Zig, allocation-free run groupier (`groupRuns` / `countRuns`).
//!     It turns a row of abstract `CellDesc`s into `Run`s that the shaper can
//!     feed to HarfBuzz one at a time. It has no C dependency and is heavily
//!     unit-tested below; it runs under a plain `zig test src/font/shaper.zig`.
//!
//!  2. A HarfBuzz interop layer (`Shaper`, `Feature`, `ShapedGlyph`,
//!     `ShapedRun`). It is compiled only when libc is linked, because it needs
//!     the `hb-c` module (translate-c of `hb.h` + `hb-ft.h`) and the harfbuzz /
//!     freetype libraries. Under the pure `zig test` invocation (no `-lc`) the
//!     shaping tests are skipped at comptime and the `hb-c` import is never
//!     resolved, so the pure half stays C-free.
//!
//! Run-grouping rules (M3.3 "same face, same style, no cursor split"):
//!   * Same `face_id` AND same `style_flags` coalesce into one run.
//!   * A cursor cell (`is_cursor`) always starts its own run, so shaping never
//!     crosses the cursor. A cursor base keeps its own wide continuations.
//!   * A wide-cell continuation (`width == 0`) stays attached to the run of its
//!     base cell regardless of its own face/style fields (it carries no glyph
//!     of its own). A leading continuation with no base starts a run.
//!   * Combining marks and zero-width joiners are ordinary cells for grouping:
//!     they do NOT force a split; they only split if face/style changes.
//!   * Empty input yields no runs.
//!
//! Cluster -> cell mapping: each base cell is added to the HarfBuzz buffer with
//! `cluster` set to its run-local cell index (continuations are skipped, they
//! are not independent characters). After shaping, a glyph's `cluster` is the
//! index of the FIRST cell of its cluster, so `ShapedGlyph.cell == cluster`.
//! With ligatures off (the default) mapping is 1:1; a multi-cell cluster (a
//! ligature, or a base + combining marks) reports its first cell. `cell` is
//! run-local: add `Run.start` to get the absolute grid index.
//!
//! Feature defaults (see `default_features`): `kern` ON, `liga` OFF (ROADMAP:
//! ligatures are optional and default off). `calt` is left at HarfBuzz's
//! built-in default (ON) -- we do not override it. Passing `features = null`
//! uses the defaults; passing a slice uses EXACTLY that slice (full control),
//! so a caller that wants to keep the defaults should prepend
//! `default_features`.
//!
//! RTL note: HarfBuzz may return glyphs in VISUAL order for right-to-left
//! scripts. `ShapedRun.direction` tells the renderer which way to lay the
//! glyphs out within the run. Terminal cells are stored in LOGICAL order; full
//! bidi reordering of the grid is out of scope for M3.
//!
//! ---------------------------------------------------------------------------
//! Standalone test commands (Zig 0.17.1, harfbuzz 14.5.1, freetype 2.14.3,
//! DejaVu fonts 2.37, all from nixpkgs). The `hb-c` bindings are generated from
//! this shim (reproduce with the translate-c command below):
//!
//!     /* hb-c.h */
//!     #include <hb.h>
//!     #include <hb-ft.h>
//!
//! Generate bindings (once):
//!     nix run nixpkgs#zig -- translate-c /tmp/shaper_probe/hb-c.h \
//!       -I/nix/store/skgmcaidl16rg8ivyd5s9206jws0wfy0-harfbuzz-14.5.1-dev/include/harfbuzz \
//!       -I/nix/store/jpnd5wfvvva2hp63wl348ldxgl4lk25a-freetype-2.14.3-dev/include \
//!       -lc > /tmp/shaper_probe/hb_c.zig
//!
//! PURE grouping tests (no C, no libraries):
//!     nix run nixpkgs#zig -- test src/font/shaper.zig
//!
//! FULL tests (grouping + shaping; links harfbuzz + freetype):
//!     nix run nixpkgs#zig -- test \
//!       --dep hb-c -Mroot=src/font/shaper.zig -Mhb-c=/tmp/shaper_probe/hb_c.zig \
//!       -lc \
//!       -L/nix/store/wny32h9l38jf8qw8rhhjfak9zbcgwkym-harfbuzz-14.5.1/lib \
//!       -L/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3/lib \
//!       -lharfbuzz -lfreetype
//! ---------------------------------------------------------------------------

const std = @import("std");
const builtin = @import("builtin");

// HarfBuzz bindings (translate-c of hb.h + hb-ft.h). Lazy: only resolved when
// the shaping half is referenced, which requires libc (see gating below).
const hb = @import("hb-c");

// ===========================================================================
// Pure run grouping (no C dependency)
// ===========================================================================

/// `CellDesc.style_flags` bit: bold face.
pub const style_bold: u8 = 0x01;
/// `CellDesc.style_flags` bit: italic face.
pub const style_italic: u8 = 0x02;

/// One abstract terminal cell, as produced by the font/fallback layer.
/// Deliberately decoupled from libghostty and FreeType so grouping is pure.
pub const CellDesc = struct {
    /// Slot of the face chosen for this cell in the font manager's face table.
    face_id: u16,
    /// `style_bold` / `style_italic` bits selecting the face variant.
    style_flags: u8 = 0,
    /// ISO 15924 script tag (e.g. 'Arab', 'Hebr'); 0 = auto-detect at shape time.
    script_tag: u32 = 0,
    /// The cell's Unicode codepoint.
    codepoint: u21,
    /// True when the terminal cursor sits on this cell.
    is_cursor: bool = false,
    /// Cell width in columns: 1 narrow, 2 wide base, 0 wide continuation.
    width: u8 = 1,
};

/// A maximal span of cells that can be shaped together.
pub const Run = struct {
    /// Index of the first cell within the input slice.
    start: usize,
    /// Number of cells in the run (includes wide continuations).
    len: usize,
    face_id: u16,
    style_flags: u8,
};

pub const GroupError = error{
    /// The caller-provided output buffer is smaller than the number of runs.
    OutputTooSmall,
};

/// End index (exclusive) of the run that starts at `start`. Shared by
/// `groupRuns` and `countRuns` so the two can never disagree on the rules.
fn runEnd(cells: []const CellDesc, start: usize) usize {
    const base = cells[start];
    var i = start + 1;
    while (i < cells.len) : (i += 1) {
        const c = cells[i];
        if (c.width == 0) continue; // continuation attaches to its base
        if (c.is_cursor) break; // a cursor always starts its own run
        if (base.is_cursor) break; // a cursor base never extends past itself
        if (c.face_id != base.face_id or c.style_flags != base.style_flags) break;
    }
    return i;
}

/// Group `cells` into runs, writing them into the caller-provided `out` buffer
/// and returning the filled prefix. Allocation-free. The worst case is one run
/// per cell, so `out.len >= cells.len` always suffices. Returns
/// `error.OutputTooSmall` if `out` cannot hold all runs.
pub fn groupRuns(cells: []const CellDesc, out: []Run) GroupError![]Run {
    var n: usize = 0;
    var start: usize = 0;
    while (start < cells.len) {
        const end = runEnd(cells, start);
        if (n == out.len) return error.OutputTooSmall;
        out[n] = .{
            .start = start,
            .len = end - start,
            .face_id = cells[start].face_id,
            .style_flags = cells[start].style_flags,
        };
        n += 1;
        start = end;
    }
    return out[0..n];
}

/// Number of runs `groupRuns` would produce, without an output buffer.
/// Allocation-free; lets a caller size an exact buffer before grouping.
pub fn countRuns(cells: []const CellDesc) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (start < cells.len) {
        start = runEnd(cells, start);
        n += 1;
    }
    return n;
}

// ===========================================================================
// HarfBuzz shaping (requires the `hb-c` module + libc)
// ===========================================================================

/// Layout direction of a shaped run. HarfBuzz may emit glyphs in visual order
/// for RTL scripts; the renderer uses this to place them within the run.
pub const Direction = enum { ltr, rtl, ttb, btt };

/// One shaped glyph, mapped back to its originating cell.
pub const ShapedGlyph = struct {
    /// FreeType/HarfBuzz glyph index (hb_glyph_info_t.codepoint after shaping).
    glyph_index: u32,
    /// Run-local index of the originating cell (the cluster's first cell).
    /// Add `Run.start` for the absolute grid index.
    cell: usize,
    /// Raw HarfBuzz cluster value (equals `cell` with our cluster assignment).
    cluster: u32,
    /// Advances and offsets in pixels (converted from HarfBuzz 26.6 fixed point).
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

/// The result of shaping one run: the glyphs plus their layout direction.
/// `glyphs` is allocated with the Shaper's allocator; free it with
/// `shaper.allocator.free(result.glyphs)` when done.
pub const ShapedRun = struct {
    glyphs: []ShapedGlyph,
    direction: Direction,
};

/// A HarfBuzz font feature. Plain data so it can be built without C; `parse`
/// and `toHb` cross into HarfBuzz.
pub const Feature = struct {
    /// Big-endian 4cc tag, e.g. `tag("liga")`.
    tag: u32,
    /// 0 = off, 1 = on (other values are feature-specific).
    value: u32,
    /// Cluster range the feature applies to; default = whole buffer.
    start: u32 = 0,
    end: u32 = 0xFFFFFFFF,

    /// Parse a font-features string: "+liga", "-liga", "kern", "kern=0",
    /// "liga[2:5]=1", ... via hb_feature_from_string.
    pub fn parse(s: []const u8) error{InvalidFeature}!Feature {
        var f: hb.hb_feature_t = undefined;
        if (hb.hb_feature_from_string(s.ptr, @intCast(s.len), &f) == 0)
            return error.InvalidFeature;
        return .{ .tag = f.tag, .value = f.value, .start = f.start, .end = f.end };
    }

    pub fn toHb(self: Feature) hb.hb_feature_t {
        return .{ .tag = self.tag, .value = self.value, .start = self.start, .end = self.end };
    }
};

/// Build a big-endian HarfBuzz tag from four ASCII bytes (pure, no C).
pub fn tag(s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) |
        (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Default features: kern ON, liga OFF. `calt` is intentionally absent so it
/// keeps HarfBuzz's built-in default (ON). See the module comment.
pub const default_features = [_]Feature{
    .{ .tag = tag("kern"), .value = 1 },
    .{ .tag = tag("liga"), .value = 0 },
};

pub const ShapeError = error{
    /// The face pointer was null.
    InvalidFace,
    /// The FT_Face has no size set; call FT_Set_Pixel_Sizes before shaping.
    SizeNotSet,
    /// hb_ft_font_create failed.
    HbFontCreateFailed,
    OutOfMemory,
};

// HarfBuzz direction constants are c_int; the API takes hb_direction_t (c_uint).
const dir_ltr: hb.hb_direction_t = @intCast(hb.HB_DIRECTION_LTR);
const dir_rtl: hb.hb_direction_t = @intCast(hb.HB_DIRECTION_RTL);

fn directionFromHb(d: hb.hb_direction_t) Direction {
    const di: c_int = @intCast(d);
    return switch (di) {
        hb.HB_DIRECTION_RTL => .rtl,
        hb.HB_DIRECTION_TTB => .ttb,
        hb.HB_DIRECTION_BTT => .btt,
        else => .ltr,
    };
}

/// HarfBuzz positions are 26.6 fixed point when the font comes from FreeType.
fn posToPx(v: hb.hb_position_t) f32 {
    return @as(f32, @floatFromInt(v)) / 64.0;
}

/// Cache key: an hb_font is specific to a face AND a pixel size.
const FontKey = struct { face: usize, size_px: u16 };

/// Shapes runs with HarfBuzz, caching hb_font_t per (face, size).
///
/// The caller owns the FT_Face and must keep it alive (and at a fixed pixel
/// size) for as long as the Shaper may use its cached fonts. The Shaper does
/// not destroy the faces; it only destroys the hb_fonts it created.
pub const Shaper = struct {
    allocator: std.mem.Allocator,
    fonts: std.AutoHashMap(FontKey, *hb.hb_font_t),

    pub fn init(allocator: std.mem.Allocator) Shaper {
        return .{
            .allocator = allocator,
            .fonts = std.AutoHashMap(FontKey, *hb.hb_font_t).init(allocator),
        };
    }

    pub fn deinit(self: *Shaper) void {
        var it = self.fonts.valueIterator();
        while (it.next()) |font| hb.hb_font_destroy(font.*);
        self.fonts.deinit();
    }

    /// Get (or create + cache) the hb_font for an FT_Face at its current size.
    fn getFont(self: *Shaper, ft_face: hb.FT_Face) ShapeError!*hb.hb_font_t {
        if (ft_face == null) return error.InvalidFace;
        if (ft_face[0].size == null) return error.SizeNotSet;
        const size_px: u16 = ft_face[0].size[0].metrics.x_ppem;
        const key = FontKey{ .face = @intFromPtr(ft_face), .size_px = size_px };
        if (self.fonts.get(key)) |font| return font;
        const font = hb.hb_ft_font_create(ft_face, null) orelse return error.HbFontCreateFailed;
        errdefer hb.hb_font_destroy(font);
        try self.fonts.put(key, font);
        return font;
    }

    /// Shape one run. `face` is an `FT_Face` (type-erased); its pixel size must
    /// already be set. `features = null` uses `default_features`; a non-null
    /// slice is used verbatim. The returned glyphs are allocated with
    /// `self.allocator`.
    pub fn shape(
        self: *Shaper,
        face: *anyopaque,
        run_cells: []const CellDesc,
        features: ?[]const Feature,
    ) ShapeError!ShapedRun {
        const ft_face: hb.FT_Face = @ptrCast(@alignCast(face));
        const font = try self.getFont(ft_face);
        return self.shapeWithFont(font, run_cells, features);
    }

    /// Shape one run with an already-created hb_font (the "raw hb_font_t"
    /// path). Same buffer/cluster/feature handling as `shape`.
    pub fn shapeWithFont(
        self: *Shaper,
        font: *hb.hb_font_t,
        run_cells: []const CellDesc,
        features: ?[]const Feature,
    ) ShapeError!ShapedRun {
        if (run_cells.len == 0) {
            return .{ .glyphs = try self.allocator.alloc(ShapedGlyph, 0), .direction = .ltr };
        }

        const buf = hb.hb_buffer_create() orelse return error.OutOfMemory;
        defer hb.hb_buffer_destroy(buf);

        // Add one codepoint per base cell; cluster = run-local cell index.
        // Wide continuations (width == 0) are not independent characters.
        var explicit_script: u32 = 0;
        for (run_cells, 0..) |cd, i| {
            if (cd.width == 0) continue;
            hb.hb_buffer_add(buf, cd.codepoint, @intCast(i));
            if (explicit_script == 0 and cd.script_tag != 0)
                explicit_script = cd.script_tag;
        }

        // Script + direction: explicit when a cell names a script, otherwise
        // guessed from the codepoints. Arabic/Hebrew resolve to RTL.
        if (explicit_script != 0) {
            const script = hb.hb_script_from_iso15924_tag(explicit_script);
            hb.hb_buffer_set_script(buf, script);
            const d = hb.hb_script_get_horizontal_direction(script);
            hb.hb_buffer_set_direction(buf, if (d == dir_rtl) dir_rtl else dir_ltr);
        }
        hb.hb_buffer_guess_segment_properties(buf);
        var direction = hb.hb_buffer_get_direction(buf);
        if (direction == hb.HB_DIRECTION_INVALID) {
            hb.hb_buffer_set_direction(buf, dir_ltr);
            direction = dir_ltr;
        }

        // Monotone grapheme clusters: a glyph's cluster is its first cell.
        hb.hb_buffer_set_cluster_level(buf, hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);

        // Features: defaults when null, otherwise the caller's exact list.
        const feats: []const Feature = features orelse &default_features;
        const hb_feats = try self.allocator.alloc(hb.hb_feature_t, feats.len);
        defer self.allocator.free(hb_feats);
        for (feats, 0..) |f, i| hb_feats[i] = f.toHb();

        hb.hb_shape(
            font,
            buf,
            if (hb_feats.len == 0) null else hb_feats.ptr,
            @intCast(hb_feats.len),
        );

        var len: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &len);
        const positions = hb.hb_buffer_get_glyph_positions(buf, &len);
        const n: usize = @intCast(len);
        const glyphs = try self.allocator.alloc(ShapedGlyph, n);
        errdefer self.allocator.free(glyphs);
        for (0..n) |i| {
            const info = infos[i];
            const pos = positions[i];
            glyphs[i] = .{
                .glyph_index = info.codepoint,
                .cell = @intCast(info.cluster),
                .cluster = info.cluster,
                .x_advance = posToPx(pos.x_advance),
                .y_advance = posToPx(pos.y_advance),
                .x_offset = posToPx(pos.x_offset),
                .y_offset = posToPx(pos.y_offset),
            };
        }

        return .{ .glyphs = glyphs, .direction = directionFromHb(direction) };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Concise cell builder for the pure grouping tests.
fn cell(codepoint: u21) CellDesc {
    return .{ .face_id = 0, .codepoint = codepoint };
}

fn expectRuns(cells: []const CellDesc, expected: []const Run) !void {
    var buf: [64]Run = undefined;
    const runs = try groupRuns(cells, &buf);
    try testing.expectEqual(expected.len, runs.len);
    for (expected, runs) |e, r| {
        try testing.expectEqual(e.start, r.start);
        try testing.expectEqual(e.len, r.len);
        try testing.expectEqual(e.face_id, r.face_id);
        try testing.expectEqual(e.style_flags, r.style_flags);
    }
    try testing.expectEqual(expected.len, countRuns(cells));
}

test "grouping: empty input yields no runs" {
    var buf: [4]Run = undefined;
    const runs = try groupRuns(&.{}, &buf);
    try testing.expectEqual(@as(usize, 0), runs.len);
    try testing.expectEqual(@as(usize, 0), countRuns(&.{}));
}

test "grouping: single cell" {
    const cells = [_]CellDesc{cell('a')};
    try expectRuns(&cells, &.{.{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 }});
}

test "grouping: same face + style coalesces" {
    const cells = [_]CellDesc{ cell('a'), cell('b'), cell('c'), cell('d'), cell('e') };
    try expectRuns(&cells, &.{.{ .start = 0, .len = 5, .face_id = 0, .style_flags = 0 }});
}

test "grouping: style split" {
    const a = cell('a');
    var b = cell('b');
    b.style_flags = style_bold;
    var c = cell('c');
    c.style_flags = style_bold | style_italic;
    const cells = [_]CellDesc{ a, b, c };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 1, .len = 1, .face_id = 0, .style_flags = style_bold },
        .{ .start = 2, .len = 1, .face_id = 0, .style_flags = style_bold | style_italic },
    });
}

test "grouping: alternating faces" {
    var a = cell('a');
    a.face_id = 1;
    var b = cell('b');
    b.face_id = 2;
    var c = cell('c');
    c.face_id = 1;
    var d = cell('d');
    d.face_id = 2;
    const cells = [_]CellDesc{ a, b, c, d };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 1, .face_id = 1, .style_flags = 0 },
        .{ .start = 1, .len = 1, .face_id = 2, .style_flags = 0 },
        .{ .start = 2, .len = 1, .face_id = 1, .style_flags = 0 },
        .{ .start = 3, .len = 1, .face_id = 2, .style_flags = 0 },
    });
}

test "grouping: cursor splits both sides" {
    const a = cell('a');
    var b = cell('b');
    b.is_cursor = true;
    const c = cell('c');
    const cells = [_]CellDesc{ a, b, c };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 1, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 2, .len = 1, .face_id = 0, .style_flags = 0 },
    });
}

test "grouping: cursor at start and at end" {
    var a = cell('a');
    a.is_cursor = true;
    const start_cells = [_]CellDesc{ a, cell('b'), cell('c') };
    try expectRuns(&start_cells, &.{
        .{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 1, .len = 2, .face_id = 0, .style_flags = 0 },
    });

    var z = cell('z');
    z.is_cursor = true;
    const end_cells = [_]CellDesc{ cell('x'), cell('y'), z };
    try expectRuns(&end_cells, &.{
        .{ .start = 0, .len = 2, .face_id = 0, .style_flags = 0 },
        .{ .start = 2, .len = 1, .face_id = 0, .style_flags = 0 },
    });
}

test "grouping: consecutive cursors each get a run" {
    var a = cell('a');
    a.is_cursor = true;
    var b = cell('b');
    b.is_cursor = true;
    const cells = [_]CellDesc{ a, b };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 1, .len = 1, .face_id = 0, .style_flags = 0 },
    });
}

test "grouping: combining mark attaches (no split)" {
    const cells = [_]CellDesc{ cell('a'), cell(0x0301) }; // a + combining acute
    try expectRuns(&cells, &.{.{ .start = 0, .len = 2, .face_id = 0, .style_flags = 0 }});
}

test "grouping: zero-width joiner does not split" {
    const cells = [_]CellDesc{ cell(0x1F468), cell(0x200D), cell(0x1F469) };
    try expectRuns(&cells, &.{.{ .start = 0, .len = 3, .face_id = 0, .style_flags = 0 }});
}

test "grouping: wide continuation attaches to base" {
    var base = cell(0x6F22); // 漢
    base.width = 2;
    var cont = cell(0);
    cont.width = 0;
    var x = cell('x');
    x.face_id = 1;
    const cells = [_]CellDesc{ base, cont, x };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 2, .face_id = 0, .style_flags = 0 },
        .{ .start = 2, .len = 1, .face_id = 1, .style_flags = 0 },
    });
}

test "grouping: continuation attaches even with mismatched face/style" {
    var base = cell(0x6F22);
    base.width = 2;
    base.face_id = 1;
    var cont = cell(0);
    cont.width = 0;
    cont.face_id = 9; // ignored: continuation carries no glyph
    cont.style_flags = style_bold;
    const cells = [_]CellDesc{ base, cont };
    try expectRuns(&cells, &.{.{ .start = 0, .len = 2, .face_id = 1, .style_flags = 0 }});
}

test "grouping: cursor wide base keeps its continuation" {
    var base = cell(0x6F22);
    base.width = 2;
    base.is_cursor = true;
    var cont = cell(0);
    cont.width = 0;
    const cells = [_]CellDesc{ base, cont, cell('x') };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 2, .face_id = 0, .style_flags = 0 },
        .{ .start = 2, .len = 1, .face_id = 0, .style_flags = 0 },
    });
}

test "grouping: leading continuation with no base starts a run" {
    var cont = cell(0);
    cont.width = 0;
    var a = cell('a');
    a.face_id = 1;
    const cells = [_]CellDesc{ cont, a };
    try expectRuns(&cells, &.{
        .{ .start = 0, .len = 1, .face_id = 0, .style_flags = 0 },
        .{ .start = 1, .len = 1, .face_id = 1, .style_flags = 0 },
    });
}

test "grouping: OutputTooSmall when buffer is short" {
    var b = cell('b');
    b.face_id = 1;
    const cells = [_]CellDesc{ cell('a'), b };
    var one: [1]Run = undefined;
    try testing.expectError(error.OutputTooSmall, groupRuns(&cells, &one));
    var two: [2]Run = undefined;
    const runs = try groupRuns(&cells, &two);
    try testing.expectEqual(@as(usize, 2), runs.len);
}

test "grouping: countRuns matches worst case one-per-cell" {
    var a = cell('a');
    a.face_id = 1;
    var b = cell('b');
    b.face_id = 2;
    var c = cell('c');
    c.face_id = 3;
    const cells = [_]CellDesc{ a, b, c };
    try testing.expectEqual(@as(usize, 3), countRuns(&cells));
}

// ---------------------------------------------------------------------------
// Shaping tests. Compiled only when libc is linked (the full standalone command
// passes -lc -lharfbuzz -lfreetype and the hb-c module). Under the pure command
// these skip at comptime and never resolve the hb-c import.
// ---------------------------------------------------------------------------

/// DejaVu Sans from the nix store (has an 'fi' ligature, kern pairs, Arabic).
const test_font_path = "/nix/store/mz1hvwkd5i24d93ihpdczqhn65mik69d-dejavu-fonts-2.37/share/fonts/truetype/DejaVuSans.ttf";

const TestFont = struct {
    lib: hb.FT_Library,
    face: hb.FT_Face,
    shaper: Shaper,

    fn init() !TestFont {
        // Skip gracefully if the pinned font is absent (FT_New_Face fails below).
        var lib: hb.FT_Library = null;
        if (hb.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInitFailed;
        errdefer _ = hb.FT_Done_FreeType(lib);
        var face: hb.FT_Face = null;
        if (hb.FT_New_Face(lib, test_font_path, 0, &face) != 0) return error.SkipZigTest;
        errdefer _ = hb.FT_Done_Face(face);
        if (hb.FT_Set_Pixel_Sizes(face, 0, 32) != 0) return error.SizeSetFailed;
        return .{ .lib = lib, .face = face, .shaper = Shaper.init(testing.allocator) };
    }

    fn deinit(self: *TestFont) void {
        self.shaper.deinit();
        _ = hb.FT_Done_Face(self.face);
        _ = hb.FT_Done_FreeType(self.lib);
    }

    fn shape(self: *TestFont, cells: []const CellDesc, features: ?[]const Feature) !ShapedRun {
        return self.shaper.shape(@ptrCast(self.face), cells, features);
    }
};

fn totalAdvance(glyphs: []const ShapedGlyph) f32 {
    var sum: f32 = 0;
    for (glyphs) |g| sum += g.x_advance;
    return sum;
}

test "shaping: AV kerning changes advance vs unkerned" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    const cells = [_]CellDesc{ cell('A'), cell('V') };

    const kerned = try tf.shape(&cells, null); // defaults: kern on
    defer testing.allocator.free(kerned.glyphs);
    const kern_off = [_]Feature{.{ .tag = tag("kern"), .value = 0 }};
    const unkerned = try tf.shape(&cells, &kern_off);
    defer testing.allocator.free(unkerned.glyphs);

    try testing.expectEqual(@as(usize, 2), kerned.glyphs.len);
    try testing.expectEqual(@as(usize, 2), unkerned.glyphs.len);
    try testing.expect(totalAdvance(kerned.glyphs) != totalAdvance(unkerned.glyphs));
}

test "shaping: fi ligature off -> 2 glyphs, +liga -> 1 glyph" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    const cells = [_]CellDesc{ cell('f'), cell('i') };

    const off = try tf.shape(&cells, null); // defaults: liga off
    defer testing.allocator.free(off.glyphs);
    try testing.expectEqual(@as(usize, 2), off.glyphs.len);

    const liga_on = [_]Feature{.{ .tag = tag("liga"), .value = 1 }};
    const on = try tf.shape(&cells, &liga_on);
    defer testing.allocator.free(on.glyphs);
    try testing.expectEqual(@as(usize, 1), on.glyphs.len);
    // The ligature belongs to the cluster's first cell.
    try testing.expectEqual(@as(usize, 0), on.glyphs[0].cell);
}

test "shaping: Arabic salam shapes to connected forms" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    // س ل ا م  (seen, lam, alef, meem). The lam-alef pair forms a mandatory
    // ligature, so the shaped glyph count is below the codepoint count.
    const cells = [_]CellDesc{ cell(0x0633), cell(0x0644), cell(0x0627), cell(0x0645) };
    const res = try tf.shape(&cells, null);
    defer testing.allocator.free(res.glyphs);

    try testing.expect(res.glyphs.len >= 1);
    try testing.expect(res.glyphs.len < cells.len);
    try testing.expectEqual(Direction.rtl, res.direction);
}

test "shaping: cluster mapping round-trips cell indices" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    const cells = [_]CellDesc{ cell('A'), cell('B'), cell('C') };
    const res = try tf.shape(&cells, null);
    defer testing.allocator.free(res.glyphs);

    try testing.expectEqual(@as(usize, 3), res.glyphs.len);
    for (res.glyphs, 0..) |g, i| {
        try testing.expectEqual(i, g.cell);
        try testing.expectEqual(@as(u32, @intCast(i)), g.cluster);
        try testing.expect(g.glyph_index != 0);
    }
    try testing.expectEqual(Direction.ltr, res.direction);
}

test "shaping: combining mark maps to its base cell" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    // 'a' + combining acute: two cells, the mark's glyph clusters onto cell 0.
    const cells = [_]CellDesc{ cell('a'), cell(0x0301) };
    const res = try tf.shape(&cells, null);
    defer testing.allocator.free(res.glyphs);

    try testing.expect(res.glyphs.len >= 1);
    for (res.glyphs) |g| {
        try testing.expect(g.cell < cells.len);
    }
    // Every glyph maps to a valid cell; the base is cell 0.
    try testing.expectEqual(@as(usize, 0), res.glyphs[0].cell);
}

test "shaping: wide continuation is not shaped as a separate glyph" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    var base = cell('W');
    base.width = 2;
    var cont = cell(0);
    cont.width = 0;
    const cells = [_]CellDesc{ base, cont };
    const res = try tf.shape(&cells, null);
    defer testing.allocator.free(res.glyphs);

    try testing.expectEqual(@as(usize, 1), res.glyphs.len);
    try testing.expectEqual(@as(usize, 0), res.glyphs[0].cell);
}

test "shaping: empty run yields no glyphs" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    const res = try tf.shape(&.{}, null);
    defer testing.allocator.free(res.glyphs);
    try testing.expectEqual(@as(usize, 0), res.glyphs.len);
    try testing.expectEqual(Direction.ltr, res.direction);
}

test "shaping: font cache reuses hb_font across calls" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    var tf = try TestFont.init();
    defer tf.deinit();

    const cells = [_]CellDesc{cell('a')};
    const r1 = try tf.shape(&cells, null);
    defer testing.allocator.free(r1.glyphs);
    const r2 = try tf.shape(&cells, null);
    defer testing.allocator.free(r2.glyphs);
    try testing.expectEqual(@as(usize, 1), tf.shaper.fonts.count());
}

test "feature: parse +liga / -liga / kern" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    const plus = try Feature.parse("+liga");
    try testing.expectEqual(tag("liga"), plus.tag);
    try testing.expectEqual(@as(u32, 1), plus.value);

    const minus = try Feature.parse("-liga");
    try testing.expectEqual(tag("liga"), minus.tag);
    try testing.expectEqual(@as(u32, 0), minus.value);

    const bare = try Feature.parse("kern");
    try testing.expectEqual(tag("kern"), bare.tag);
    try testing.expectEqual(@as(u32, 1), bare.value);

    try testing.expectError(error.InvalidFeature, Feature.parse("not a feature!!"));
}

test "feature: default features are kern on, liga off" {
    if (comptime !builtin.link_libc) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 2), default_features.len);
    try testing.expectEqual(tag("kern"), default_features[0].tag);
    try testing.expectEqual(@as(u32, 1), default_features[0].value);
    try testing.expectEqual(tag("liga"), default_features[1].tag);
    try testing.expectEqual(@as(u32, 0), default_features[1].value);
}
