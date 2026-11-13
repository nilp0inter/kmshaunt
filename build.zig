const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // src/kmshaunt.zig re-exports main.zig's entry point unchanged and pulls
    // every module into the compilation (the console wiring lands in
    // main.zig later).
    const exe = b.addExecutable(.{
        .name = "kmshaunt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kmshaunt.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // One test binary for every module under src/. The spng decoder's tests
    // live in the repository-root harness test_spng.zig: they need
    // tools/png.zig, which a root under src/ cannot import (Zig confines
    // imports to the root module's directory tree).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const spng_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_spng.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const interop = CInterop.init(b, target, optimize);
    interop.wire(exe.root_module);
    interop.wire(unit_tests.root_module);
    interop.wire(spng_tests.root_module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(spng_tests).step);
}

/// The translated C shims and system libraries every root module needs.
/// Shim include directories come from pkg-config at build-graph time;
/// linking uses pkg-config too (linkSystemLibrary's default). Inside
/// `nix develop` (or the nix package build) PKG_CONFIG_PATH points at the
/// dev outputs of all C dependencies; on other hosts the default search
/// paths apply.
const CInterop = struct {
    vt_c: ?*std.Build.Module,
    ghostty_vt: ?*std.Build.Step.Compile,
    drm_c: *std.Build.Module,
    xkb_c: *std.Build.Module,
    libinput_c: *std.Build.Module,
    fontconfig_c: *std.Build.Module,
    freetype_c: *std.Build.Module,
    hb_c: *std.Build.Module,
    sd_bus_c: *std.Build.Module,
    sd_login_c: *std.Build.Module,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) CInterop {
        // libghostty-vt, pinned to 1.0.1 in build.zig.zon. The C API is the
        // stable surface (D1): translate the shim header into the `vt-c`
        // module and link the library artifact.
        var vt_c: ?*std.Build.Module = null;
        var ghostty_vt: ?*std.Build.Step.Compile = null;
        if (b.lazyDependency("ghostty", .{})) |dep| {
            const vt = translateC(b, target, optimize, "src/vt-c.h", &.{});
            vt.addIncludePath(dep.path("include"));
            vt_c = vt.createModule();
            ghostty_vt = dep.artifact("ghostty-vt");
        }

        const drm = translateC(b, target, optimize, "src/drm-c.h", &.{"libdrm"});
        const xkb = translateC(b, target, optimize, "src/xkb-c.h", &.{"xkbcommon"});
        const libinput = translateC(b, target, optimize, "src/libinput-c.h", &.{ "libinput", "libudev" });
        const fontconfig = translateC(b, target, optimize, "src/fontconfig-c.h", &.{"fontconfig"});
        const freetype = translateC(b, target, optimize, "src/freetype-c.h", &.{"freetype2"});
        const hb = translateC(b, target, optimize, "src/hb-c.h", &.{ "harfbuzz", "freetype2" });
        const sd_bus = translateC(b, target, optimize, "src/sd-bus-c.h", &.{"libsystemd"});
        const sd_login = translateC(b, target, optimize, "src/sd-login-c.h", &.{"libsystemd"});

        return .{
            .vt_c = vt_c,
            .ghostty_vt = ghostty_vt,
            .drm_c = drm.createModule(),
            .xkb_c = xkb.createModule(),
            .libinput_c = libinput.createModule(),
            .fontconfig_c = fontconfig.createModule(),
            .freetype_c = freetype.createModule(),
            .hb_c = hb.createModule(),
            .sd_bus_c = sd_bus.createModule(),
            .sd_login_c = sd_login.createModule(),
        };
    }

    /// Expose the translated modules under the exact names the sources
    /// @import and link every system library. The freetype and harfbuzz
    /// shims are supersets shared under both spellings (discovery.zig uses
    /// underscores, color.zig hyphens, shaper.zig hb-c).
    fn wire(self: CInterop, m: *std.Build.Module) void {
        if (self.vt_c) |vt| m.addImport("vt-c", vt);
        if (self.ghostty_vt) |lib| m.linkLibrary(lib);
        m.addImport("drm-c", self.drm_c);
        m.addImport("xkb-c", self.xkb_c);
        m.addImport("libinput-c", self.libinput_c);
        m.addImport("fontconfig_c", self.fontconfig_c);
        m.addImport("freetype_c", self.freetype_c);
        m.addImport("freetype-c", self.freetype_c);
        m.addImport("hb-c", self.hb_c);
        m.addImport("harfbuzz-c", self.hb_c);
        m.addImport("sd-bus-c", self.sd_bus_c);
        m.addImport("sd-login-c", self.sd_login_c);

        // pkg-config module names (libdrm.pc, xkbcommon.pc, libinput.pc,
        // libudev.pc, libsystemd.pc, fontconfig.pc, freetype2.pc,
        // harfbuzz.pc, harfbuzz-raster.pc from the withRaster overlay,
        // spng.pc, libseat.pc). spng and seat are link-only:
        // spng_decode.zig and libseat.zig carry their own C declarations.
        for ([_][]const u8{
            "libdrm",     "xkbcommon",  "libinput", "libudev",
            "libsystemd", "fontconfig", "freetype2", "harfbuzz",
            "harfbuzz-raster", "spng",  "libseat",
        }) |name| m.linkSystemLibrary(name, .{});
    }
};

/// translate-c of `header` with the include directories pkg-config reports
/// for `pkgs`.
fn translateC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    header: []const u8,
    pkgs: []const []const u8,
) *std.Build.Step.TranslateC {
    const t = b.addTranslateC(.{
        .root_source_file = b.path(header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (pkgs) |pkg| {
        for (pkgConfigIncludePaths(b, pkg)) |dir| {
            t.addIncludePath(.{ .cwd_relative = dir });
        }
    }
    return t;
}

/// `-I` directories from `pkg-config --cflags-only-I <pkg>`. Empty when
/// pkg-config or the .pc file is unavailable: the headers may still sit on
/// the default search path (non-Nix hosts).
fn pkgConfigIncludePaths(b: *std.Build, pkg: []const u8) []const []const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "pkg-config", "--cflags-only-I", pkg },
    }) catch return &.{};
    if (result.term != .exited or result.term.exited != 0) return &.{};
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    while (it.next()) |flag| {
        if (flag.len > 2 and std.mem.startsWith(u8, flag, "-I")) {
            dirs.append(b.allocator, flag[2..]) catch @panic("OOM");
        }
    }
    return dirs.toOwnedSlice(b.allocator) catch @panic("OOM");
}
