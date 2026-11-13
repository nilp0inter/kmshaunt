//! tools/render_golden.zig -- headless renderer for the T2 render goldens
//! (ROADMAP §4 T2, M3.10/M4.6, R6). NOT installed: a test tool only.
//!
//! A VT byte fixture + the pinned fonts go in, a deterministic PNG comes out:
//!
//!   fixture.bin -> vt.Vt -> vt.RenderState -> CpuRenderer -> Framebuffer
//!               (xrgb8888) -> RGBA -> tools/png.zig -> out.png
//!
//! With --check the generated PNG bytes are compared byte-exact against a
//! golden file (exit 0 match, 1 differ). That comparison IS the T2 test; the
//! nix flake check derivation runs it per fixture.
//!
//! # CLI
//!
//!   render_golden --fixture <file.bin> [--out <out.png>] [--check <golden.png>]
//!                 [--generate] [--cols 80] [--rows 24] [--font "JetBrains Mono"]
//!                 [--size 16] [--palette legacy] [--font-dir fixtures/t2/fonts]
//!
//!   --fixture <path>   VT byte fixture to feed the terminal (required).
//!   --out <path>       Write the rendered PNG here.
//!   --check <path>     Compare the rendered PNG byte-exact against this golden.
//!   --generate         Bless mode: --out writes a golden (same rendering path,
//!                      semantics for `update-goldens`). Requires --out.
//!   --cols / --rows    Terminal grid (default 80x24).
//!   --font <name>      Primary fontconfig family (default "JetBrains Mono").
//!   --size <px>        Font pixel size (default 16).
//!   --palette <name>   Palette preset, src/misc/palette.zig (default legacy).
//!   --font-dir <dir>   Pinned font directory (default fixtures/t2/fonts).
//!   --help             Usage.
//!
//! At least one of --out / --check is required. Exit codes: 0 success or
//! golden match, 1 golden differs, 2 usage or I/O error.
//!
//! # Determinism (R6)
//!
//! The PNG is a pure function of (fixture, grid, font name, size, palette,
//! pinned font bytes, pinned library versions):
//!
//! * Font pinning: before fontconfig initializes, the tool writes a private
//!   fonts.conf that exposes ONLY --font-dir (no host <dir>, no conf.d, no
//!   user config) and points FONTCONFIG_FILE at it (FONTCONFIG_PATH at the
//!   same private directory). discovery.Discovery.init then loads exactly
//!   the pinned faces; host fonts cannot leak in. The cache dir is private
//!   too, so no host font cache is read. The previous environment is
//!   restored afterwards (tests share the process with host-font suites).
//! * Cursor: always visible, block style, cursor_blink_on = null (steady,
//!   blink disabled), bg_opacity 255. default_fg/bg come from palette slots
//!   16/17, like the session.
//! * The framebuffer is cleared to the default background before the frame,
//!   exactly as the session does.
//! * tools/png.zig is deterministic (filter 0, pinned level-9 deflate, no
//!   ancillary chunks), so equal pixels give equal bytes.
//!
//! A FreeType/HarfBuzz/fontconfig bump can still change pixels: versions are
//! pinned by flake.lock, and a bump shows up as a byte diff in --check (R6).
//!
//! # Pinned fonts (fixtures/t2/fonts)
//!
//! The directory holds symlinks to the exact font files; fontconfig sees
//! nothing else. Recreate it with:
//!
//!   mkdir -p fixtures/t2/fonts
//!   # nixpkgs pinned by flake.lock (rev d4f25a3e562008648d45bcf2d70bcc7422cad84e):
//!   #   nix build github:nixos/nixpkgs/d4f25a3e562008648d45bcf2d70bcc7422cad84e#jetbrains-mono \
//!   #     github:nixos/nixpkgs/d4f25a3e562008648d45bcf2d70bcc7422cad84e#noto-fonts-color-emoji \
//!   #     github:nixos/nixpkgs/d4f25a3e562008648d45bcf2d70bcc7422cad84e#noto-fonts-cjk-sans \
//!   #     --no-link --print-out-paths
//!   JB=/nix/store/z97lbgi1sq3qfng5l2wj3rbqmlmzi4s5-jetbrains-mono-2.304/share/fonts/truetype
//!   EM=/nix/store/nf4gfq748yssxg2zy6yx141maqxsl8v4-noto-fonts-color-emoji-2.051/share/fonts/noto
//!   CJK=/nix/store/a9jx9h2bx20lnl3vrqmkz1q3jgpxqaaw-noto-fonts-cjk-sans-2.004/share/fonts/opentype/noto-cjk
//!   ln -s $JB/JetBrainsMono-{Regular,Bold,Italic,BoldItalic}.ttf fixtures/t2/fonts/
//!   ln -s $EM/NotoColorEmoji.ttf $CJK/NotoSansCJK-VF.otf.ttc fixtures/t2/fonts/
//!   # COLRv1 / sbix color fonts (same files src/font/color.zig tests use):
//!   # https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-glyf_colr_1.ttf
//!   # https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-sbix.ttf
//!   # sha256 fc1c3b581d01fcaed3283b9a12a04f784db0a22710e1c196dfb3a52696063fdc
//!   # sha256 fd68ec5f75e244db879b1f3aaf453627ed764453343a2dbaa8b17da8641d75b5
//!   ln -s /tmp/kmshaunt-fonts/noto-glyf_colr_1.ttf /tmp/kmshaunt-fonts/noto-sbix.ttf fixtures/t2/fonts/
//!
//! Only the four static JetBrains Mono weights are pinned (no variable
//! fonts), one CJK face, one CBDT emoji face. The COLRv1/sbix symlinks are
//! for the color-format goldens; if the /tmp files are absent fontconfig
//! simply skips them (the other goldens do not use them).
//!
//! Goldens live in fixtures/t2/goldens/<fixture-stem>.png. Bless them with:
//!
//!   render_golden --fixture fixtures/t2/box-drawing.bin \
//!       --generate --out fixtures/t2/goldens/box-drawing.png
//!
//! # Module wiring (Zig 0.17 import confinement)
//!
//! Zig confines @import to the module root's directory tree, so this file
//! cannot import ../src/ directly (same reason test_spng.zig sits at the
//! repository root). It imports two named modules instead:
//!
//!   "kmshaunt" -> src/render_golden_exports.zig (src-side root re-exporting
//!                 vt, cpu, discovery, palette, render, framebuffer; carries
//!                 the six translate-c modules below)
//!   "png"      -> tools/png.zig
//!
//! build.zig wiring (exe NOT installed; no b.installArtifact):
//!
//!   const golden_src = b.createModule(.{
//!       .root_source_file = b.path("src/render_golden_exports.zig"),
//!       .target = target, .optimize = optimize, .link_libc = true,
//!   });
//!   interop.wire(golden_src); // vt-c/fontconfig_c/freetype_c/freetype-c/
//!                             // hb-c/harfbuzz-c + ghostty-vt, fontconfig,
//!                             // freetype, harfbuzz, harfbuzz-raster
//!   const golden_png = b.createModule(.{
//!       .root_source_file = b.path("tools/png.zig"),
//!       .target = target, .optimize = optimize, .link_libc = true,
//!   });
//!   const golden_mod = b.createModule(.{
//!       .root_source_file = b.path("tools/render_golden.zig"),
//!       .target = target, .optimize = optimize, .link_libc = true,
//!   });
//!   golden_mod.addImport("kmshaunt", golden_src);
//!   golden_mod.addImport("png", golden_png);
//!   const render_golden = b.addExecutable(.{
//!       .name = "render_golden", .root_module = golden_mod,
//!   });
//!   const golden_tests = b.addTest(.{ .root_module = golden_mod });
//!   // run/artifact steps as needed; nothing is installed.
//!
//! # Standalone build/test (no build.zig; run from the repo root)
//!
//! Bindings: vt-c per the src/vt.zig header; fontconfig_c/freetype_c per the
//! src/font/discovery.zig header; hb-c per src/font/shaper.zig; freetype-c/
//! harfbuzz-c per src/font/color.zig. The commands below reuse the files
//! those recipes produce. `zig` = Zig 0.17.1 (nix run nixpkgs#zig --); the
//! -L ghostty directory is whichever .zig-cache/o/<hash> holds
//! libghostty-vt.so (fd libghostty-vt .zig-cache).
//!
//!   FCLIB=/nix/store/p3y4rk4gjnhs80339qq7jixjbhplqc16-fontconfig-2.18.3-lib
//!   FTLIB=/nix/store/zj7yb55h1zpmxmw6dp817n6y0370wji0-freetype-2.14.3
//!   HBLIB=/nix/store/7ycrkhagmaxkd4ffxn3b00ylxb7hkc20-harfbuzz-14.5.1
//!   COMMON="--dep vt-c --dep fontconfig_c --dep freetype_c \
//!     --dep hb-c --dep freetype-c --dep harfbuzz-c \
//!     -Mkmshaunt=src/render_golden_exports.zig \
//!     -Mvt-c=/tmp/vt_c.zig \
//!     -Mfontconfig_c=/tmp/kmshaunt_fontconfig_c.zig \
//!     -Mfreetype_c=/tmp/kmshaunt_freetype_c.zig \
//!     -Mhb-c=/tmp/shaper_probe/hb_c.zig \
//!     -Mfreetype-c=/tmp/kmshaunt-color/freetype_c.zig \
//!     -Mharfbuzz-c=/tmp/kmshaunt-color/harfbuzz_c.zig"
//!   LIBS="-lc -lghostty-vt -lfontconfig -lfreetype -lharfbuzz -lharfbuzz-raster \
//!     -L.zig-cache/o/16861fd85abb75eb4433b66ad767d202 \
//!     -L$FCLIB/lib -L$FTLIB/lib -L$HBLIB/lib"
//!   # --dep entries attach to the NEXT -M module.
//!   nix run nixpkgs#zig -- build-exe \
//!     --dep kmshaunt --dep png -Mroot=tools/render_golden.zig \
//!     $COMMON -Mpng=tools/png.zig $LIBS -femit-bin=zig-out/bin/render_golden
//!   nix run nixpkgs#zig -- test \
//!     --dep kmshaunt --dep png -Mroot=tools/render_golden.zig \
//!     $COMMON -Mpng=tools/png.zig $LIBS
//!
//! Only this file's tests run here (Zig collects tests from the root and from
//! files referenced inside `test` blocks; the module suites keep their own
//! roots, src/test_cpu.zig and test_spng.zig). The golden tests pin the fonts
//! and restore the host environment around each render, so they are safe to
//! run in a process that also uses host fontconfig.

const std = @import("std");
const kmshaunt = @import("kmshaunt");
const png = @import("png");

const vt = kmshaunt.vt;
const cpu = kmshaunt.cpu;
const discovery = kmshaunt.discovery;
const presets = kmshaunt.palette;
const render = kmshaunt.render;
const Framebuffer = kmshaunt.framebuffer.Framebuffer;

pub const default_cols: u16 = 80;
pub const default_rows: u16 = 24;
pub const default_font = "JetBrains Mono";
pub const default_size_px: u16 = 16;
pub const default_palette: presets.Preset = .legacy;
pub const default_font_dir = "fixtures/t2/fonts";

/// Fixture/golden read cap: fixtures are a few hundred bytes, goldens a few
/// hundred KiB; 64 MiB is far above both and bounds a runaway read.
const max_file_bytes = 64 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Font pinning (R6)
// ---------------------------------------------------------------------------

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// Installs a private fontconfig configuration exposing ONLY the pinned font
/// directory, for as long as the Discovery lives. FONTCONFIG_FILE points at
/// the generated fonts.conf, FONTCONFIG_PATH at the private directory (no
/// host conf.d). The previous environment is restored by `restore`, and the
/// private directory (config + font cache) is deleted.
const FontPin = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_dir: [:0]u8,
    prev_file: ?[:0]u8,
    prev_path: ?[:0]u8,

    fn install(allocator: std.mem.Allocator, io: std.Io, font_dir: []const u8) !FontPin {
        const abs_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, font_dir, allocator);
        defer allocator.free(abs_dir);

        const template = try allocator.dupeSentinel(u8, "/tmp/kmshaunt-render-golden-XXXXXX", 0);
        defer allocator.free(template);
        const made = mkdtemp(template.ptr) orelse return error.MkdtempFailed;
        const tmp_dir = try allocator.dupeSentinel(u8, std.mem.span(made), 0);
        errdefer allocator.free(tmp_dir);

        const conf = try std.fmt.allocPrint(allocator,
            \\<?xml version="1.0"?>
            \\<fontconfig>
            \\  <dir>{s}</dir>
            \\  <cachedir>{s}/cache</cachedir>
            \\</fontconfig>
            \\
        , .{ abs_dir, tmp_dir });
        defer allocator.free(conf);
        const conf_path = try std.fmt.allocPrintSentinel(allocator, "{s}/fonts.conf", .{tmp_dir}, 0);
        defer allocator.free(conf_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = conf_path, .data = conf });

        const prev_file = try dupEnv(allocator, "FONTCONFIG_FILE");
        errdefer if (prev_file) |p| allocator.free(p);
        const prev_path = try dupEnv(allocator, "FONTCONFIG_PATH");
        errdefer if (prev_path) |p| allocator.free(p);
        if (setenv("FONTCONFIG_FILE", conf_path.ptr, 1) != 0) return error.SetenvFailed;
        if (setenv("FONTCONFIG_PATH", tmp_dir.ptr, 1) != 0) return error.SetenvFailed;

        return .{
            .allocator = allocator,
            .io = io,
            .tmp_dir = tmp_dir,
            .prev_file = prev_file,
            .prev_path = prev_path,
        };
    }

    fn restore(self: *FontPin) void {
        restoreEnv("FONTCONFIG_FILE", self.prev_file);
        restoreEnv("FONTCONFIG_PATH", self.prev_path);
        std.Io.Dir.cwd().deleteTree(self.io, self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
        if (self.prev_file) |p| self.allocator.free(p);
        if (self.prev_path) |p| self.allocator.free(p);
        self.* = undefined;
    }
};

fn dupEnv(allocator: std.mem.Allocator, name: [:0]const u8) !?[:0]u8 {
    if (std.c.getenv(name.ptr)) |value| {
        return try allocator.dupeSentinel(u8, std.mem.span(value), 0);
    }
    return null;
}

fn restoreEnv(name: [:0]const u8, prev: ?[:0]const u8) void {
    if (prev) |p| {
        _ = setenv(name.ptr, p.ptr, 1);
    } else {
        _ = unsetenv(name.ptr);
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Everything that influences the pixels. Defaults are the golden defaults;
/// the CLI overrides them, the tests use them as-is.
pub const Request = struct {
    fixture: []const u8,
    cols: u16 = default_cols,
    rows: u16 = default_rows,
    font_name: []const u8 = default_font,
    size_px: u16 = default_size_px,
    palette: presets.Preset = default_palette,
    /// Directory holding ONLY the pinned fonts (see the module comment).
    font_dir: []const u8 = default_font_dir,
};

/// Render `req.fixture` to a deterministic PNG file image. The caller owns
/// the returned bytes. Pins the fonts for the whole render and restores the
/// environment before returning.
pub fn renderPng(allocator: std.mem.Allocator, io: std.Io, req: Request) ![]u8 {
    var pin = try FontPin.install(allocator, io, req.font_dir);
    defer pin.restore();

    var palette18: [18]u32 = undefined;
    for (&palette18, req.palette.get()) |*dst, c| dst.* = c.xrgb();

    // Heap-allocated so the renderer's borrowed pointer stays valid if this
    // frame's locals move (same pattern as cpu.zig's test Env).
    const d = try allocator.create(discovery.Discovery);
    defer allocator.destroy(d);
    d.* = try discovery.Discovery.init(allocator);
    defer d.deinit();
    var face = try d.primaryFace(req.font_name, req.size_px);
    var renderer = try cpu.CpuRenderer.init(allocator, d, &face, .{ .size_px = req.size_px });
    defer renderer.deinit();
    try renderer.resize(req.cols, req.rows, renderer.metrics.cell_w, renderer.metrics.cell_h);

    var t = try vt.Vt.init(req.cols, req.rows);
    defer t.deinit();
    t.write(req.fixture);

    var state = try vt.RenderState.new();
    defer state.deinit();
    try state.update(&t);

    const w = @as(u32, req.cols) * renderer.metrics.cell_w;
    const h = @as(u32, req.rows) * renderer.metrics.cell_h;
    var f = try Framebuffer.create(allocator, w, h, .xrgb8888, null);
    defer f.destroy(allocator);
    f.fill(palette18[17]); // the session clears to the default background

    var damage: render.DamageList = .empty;
    defer damage.deinit(allocator);
    // renderFrame cleans the state itself on success (cpu.zig contract).
    try renderer.renderFrame(&state, &f, &damage, .{
        .cursor_visible = true,
        .cursor_style = .block,
        .cursor_blink_on = null, // blink disabled: steady cursor (R6)
        .palette = &palette18,
        .default_fg = palette18[16],
        .default_bg = palette18[17],
        .bg_opacity = 255,
    });

    // xrgb8888 (0xXXRRGGBB words, pitch-strided) -> tightly packed RGBA.
    const rgba = try allocator.alloc(u8, @as(usize, w) * h * 4);
    defer allocator.free(rgba);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row_bytes = @as(usize, w) * 4;
        const src = f.mem[@as(usize, y) * f.pitch ..][0..row_bytes];
        const dst = rgba[@as(usize, y) * row_bytes ..][0..row_bytes];
        var i: usize = 0;
        while (i < row_bytes) : (i += 4) {
            const word = std.mem.readInt(u32, src[i..][0..4], .little);
            dst[i + 0] = @truncate(word >> 16);
            dst[i + 1] = @truncate(word >> 8);
            dst[i + 2] = @truncate(word);
            dst[i + 3] = 255;
        }
    }

    return png.encodePng(allocator, .{
        .width = w,
        .height = h,
        .format = .rgba32,
        .pixels = rgba,
    });
}

// ---------------------------------------------------------------------------
// Golden comparison (the T2 check)
// ---------------------------------------------------------------------------

pub const Compare = struct {
    match: bool,
    /// First differing byte offset; null when one file is a prefix of the
    /// other (the length difference is the diff) or on match.
    first_diff: ?usize,
    rendered_len: usize,
    golden_len: usize,
};

/// Byte-exact comparison of the rendered PNG against golden bytes.
pub fn compareBytes(rendered: []const u8, golden: []const u8) Compare {
    const n = @min(rendered.len, golden.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (rendered[i] != golden[i]) {
            return .{ .match = false, .first_diff = i, .rendered_len = rendered.len, .golden_len = golden.len };
        }
    }
    const match = rendered.len == golden.len;
    return .{
        .match = match,
        .first_diff = if (match) null else n,
        .rendered_len = rendered.len,
        .golden_len = golden.len,
    };
}

/// Read `golden_path` and compare byte-exact. This is what --check runs.
pub fn checkGoldenFile(allocator: std.mem.Allocator, io: std.Io, rendered: []const u8, golden_path: []const u8) !Compare {
    const golden = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(max_file_bytes));
    defer allocator.free(golden);
    return compareBytes(rendered, golden);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const usage =
    \\Usage: render_golden --fixture <file.bin> [--out <out.png>] [--check <golden.png>]
    \\                     [--generate] [--cols N] [--rows N] [--font NAME]
    \\                     [--size PX] [--palette PRESET] [--font-dir DIR]
    \\
    \\Headless T2 golden renderer: VT byte fixture + pinned fonts -> PNG.
    \\
    \\  --fixture <path>   VT byte fixture (required)
    \\  --out <path>       write the rendered PNG here
    \\  --check <path>     compare byte-exact against this golden (exit 1 on differ)
    \\  --generate         bless mode: --out writes a golden (requires --out)
    \\  --cols N           grid columns (default 80)
    \\  --rows N           grid rows (default 24)
    \\  --font NAME        primary fontconfig family (default "JetBrains Mono")
    \\  --size PX          font pixel size (default 16)
    \\  --palette PRESET   legacy, vga, nord, solarized, solarized-black,
    \\                     solarized-white, soft-black, base16-dark, base16-light,
    \\                     custom (default legacy)
    \\  --font-dir DIR     pinned font directory (default fixtures/t2/fonts)
    \\  --help             this text
    \\
    \\Exit codes: 0 success/match, 1 golden differs, 2 usage or I/O error.
    \\
;

const Options = struct {
    fixture: ?[]const u8 = null,
    out: ?[]const u8 = null,
    check: ?[]const u8 = null,
    generate: bool = false,
    help: bool = false,
    cols: u16 = default_cols,
    rows: u16 = default_rows,
    font: []const u8 = default_font,
    size: u16 = default_size_px,
    palette: presets.Preset = default_palette,
    font_dir: []const u8 = default_font_dir,
};

fn parseArgs(args: []const []const u8, stderr: *std.Io.Writer) !Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--generate")) {
            opts.generate = true;
            continue;
        }
        const value: []const u8 = if (i + 1 < args.len) args[i + 1] else {
            try stderr.print("render_golden: {s} requires a value\n", .{arg});
            return error.MissingValue;
        };
        if (std.mem.eql(u8, arg, "--fixture")) {
            opts.fixture = value;
        } else if (std.mem.eql(u8, arg, "--out")) {
            opts.out = value;
        } else if (std.mem.eql(u8, arg, "--check")) {
            opts.check = value;
        } else if (std.mem.eql(u8, arg, "--font")) {
            opts.font = value;
        } else if (std.mem.eql(u8, arg, "--font-dir")) {
            opts.font_dir = value;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            opts.cols = try parseDim(value, "--cols", stderr);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            opts.rows = try parseDim(value, "--rows", stderr);
        } else if (std.mem.eql(u8, arg, "--size")) {
            opts.size = try parseDim(value, "--size", stderr);
        } else if (std.mem.eql(u8, arg, "--palette")) {
            opts.palette = presets.Preset.fromName(value) orelse {
                try stderr.print("render_golden: unknown palette '{s}'\n", .{value});
                return error.InvalidPalette;
            };
        } else {
            try stderr.print("render_golden: unrecognized argument '{s}'\n", .{arg});
            return error.UnknownOption;
        }
        i += 1;
    }
    if (opts.help) return opts;
    if (opts.fixture == null) {
        try stderr.writeAll("render_golden: --fixture is required\n");
        return error.MissingFixture;
    }
    if (opts.out == null and opts.check == null) {
        try stderr.writeAll("render_golden: nothing to do: pass --out and/or --check\n");
        return error.NothingToDo;
    }
    if (opts.generate and opts.out == null) {
        try stderr.writeAll("render_golden: --generate requires --out\n");
        return error.GenerateNeedsOut;
    }
    return opts;
}

fn parseDim(value: []const u8, flag: []const u8, stderr: *std.Io.Writer) !u16 {
    const n = std.fmt.parseInt(u16, value, 10) catch {
        try stderr.print("render_golden: {s} expects a number 1..65535, got '{s}'\n", .{ flag, value });
        return error.InvalidNumber;
    };
    if (n == 0) {
        try stderr.print("render_golden: {s} must be at least 1\n", .{flag});
        return error.InvalidNumber;
    }
    return n;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const opts = parseArgs(args[1..], stderr) catch {
        try stderr.writeAll("Try 'render_golden --help' for more information.\n");
        try stderr.flush();
        std.process.exit(2);
    };
    if (opts.help) {
        try stdout.writeAll(usage);
        try stdout.flush();
        return;
    }

    const fixture = std.Io.Dir.cwd().readFileAlloc(io, opts.fixture.?, allocator, .limited(max_file_bytes)) catch |err| {
        try stderr.print("render_golden: cannot read fixture '{s}': {s}\n", .{ opts.fixture.?, @errorName(err) });
        try stderr.flush();
        std.process.exit(2);
    };
    const rendered = renderPng(allocator, io, .{
        .fixture = fixture,
        .cols = opts.cols,
        .rows = opts.rows,
        .font_name = opts.font,
        .size_px = opts.size,
        .palette = opts.palette,
        .font_dir = opts.font_dir,
    }) catch |err| {
        try stderr.print("render_golden: render failed: {s} (font dir '{s}')\n", .{ @errorName(err), opts.font_dir });
        try stderr.flush();
        std.process.exit(2);
    };

    if (opts.out) |path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch |err| {
            try stderr.print("render_golden: cannot write '{s}': {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(2);
        };
        if (opts.generate) {
            try stdout.print("golden written: {s} ({d} bytes)\n", .{ path, rendered.len });
        } else {
            try stdout.print("wrote {s} ({d} bytes)\n", .{ path, rendered.len });
        }
    }

    if (opts.check) |path| {
        const cmp = checkGoldenFile(allocator, io, rendered, path) catch |err| {
            try stderr.print("render_golden: cannot read golden '{s}': {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(2);
        };
        if (cmp.match) {
            try stdout.print("MATCH {s} ({d} bytes)\n", .{ path, cmp.golden_len });
            try stdout.flush();
            return;
        }
        try stdout.print("DIFFER {s}: rendered {d} bytes, golden {d} bytes, first diff at byte {d}\n", .{
            path, cmp.rendered_len, cmp.golden_len, cmp.first_diff orelse cmp.golden_len,
        });
        try stdout.flush();
        std.process.exit(1);
    }
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests (run from the repo root; the pinned font dir and goldens are
// repo-relative). Each render pins the fonts and restores the environment,
// so these are safe alongside host-fontconfig suites.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "render_golden: same fixture renders byte-identical PNGs (determinism)" {
    const a = testing.allocator;
    const one = try renderPng(a, testing.io, .{ .fixture = "hello" });
    defer a.free(one);
    const two = try renderPng(a, testing.io, .{ .fixture = "hello" });
    defer a.free(two);
    try testing.expectEqualStrings(one, two);
    try testing.expect(std.mem.startsWith(u8, one, png.signature));
}

test "render_golden: box-drawing fixture renders a non-empty PNG" {
    const a = testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/t2/box-drawing.bin", a, .limited(max_file_bytes));
    defer a.free(fixture);
    const img = try renderPng(a, testing.io, .{ .fixture = fixture });
    defer a.free(img);
    try testing.expect(std.mem.startsWith(u8, img, png.signature));
    try testing.expect(img.len > 1000);
    // IHDR: 80x24 cells at the pinned font's cell size (>= 1px per cell).
    const w = std.mem.readInt(u32, img[16..20], .big);
    const h = std.mem.readInt(u32, img[20..24], .big);
    try testing.expect(w >= default_cols and h >= default_rows);
    // Ink on screen: different from a blank terminal's PNG.
    const blank = try renderPng(a, testing.io, .{ .fixture = "" });
    defer a.free(blank);
    try testing.expect(!std.mem.eql(u8, img, blank));
}

test "render_golden: check matches a generated golden and rejects a corrupted one" {
    const a = testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/t2/box-drawing.bin", a, .limited(max_file_bytes));
    defer a.free(fixture);
    const img = try renderPng(a, testing.io, .{ .fixture = fixture });
    defer a.free(img);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "golden.png", .data = img });
    const golden_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/golden.png", .{tmp.sub_path});
    defer a.free(golden_path);

    const ok = try checkGoldenFile(a, testing.io, img, golden_path);
    try testing.expect(ok.match);
    try testing.expectEqual(@as(?usize, null), ok.first_diff);

    // Flip one byte in the middle: the comparison must report that offset.
    const corrupted = try a.dupe(u8, img);
    defer a.free(corrupted);
    corrupted[corrupted.len / 2] ^= 0xff;
    const bad = compareBytes(img, corrupted);
    try testing.expect(!bad.match);
    try testing.expectEqual(@as(?usize, corrupted.len / 2), bad.first_diff);

    // A truncated golden differs too (length is part of the comparison).
    const short = compareBytes(img, img[0 .. img.len - 1]);
    try testing.expect(!short.match);
}

test "render_golden: committed T2 goldens are byte-exact" {
    const a = testing.allocator;
    const cases = [_][]const u8{
        "box-drawing",
        "combining-marks",
        "cjk-wide",
        "decorations",
        "bold-italic",
        "blocks-braille-powerline",
        "legacy-computing",
        "cursor-styles",
        "zwj-family",
        "flags",
        "skin-tones",
        "variation-selectors",
    };
    for (cases) |name| {
        const fixture_path = try std.fmt.allocPrint(a, "fixtures/t2/{s}.bin", .{name});
        defer a.free(fixture_path);
        const golden_path = try std.fmt.allocPrint(a, "fixtures/t2/goldens/{s}.png", .{name});
        defer a.free(golden_path);
        const fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_path, a, .limited(max_file_bytes));
        defer a.free(fixture);
        const img = try renderPng(a, testing.io, .{ .fixture = fixture });
        defer a.free(img);
        const cmp = try checkGoldenFile(a, testing.io, img, golden_path);
        if (!cmp.match) {
            std.debug.print("golden mismatch for {s}: rendered {d} bytes, golden {d} bytes, first diff {d}\n", .{
                name, cmp.rendered_len, cmp.golden_len, cmp.first_diff orelse cmp.golden_len,
            });
        }
        try testing.expect(cmp.match);
    }
}
