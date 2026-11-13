const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "kmshaunt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // libghostty-vt, pinned to 1.0.1 in build.zig.zon. The C API is the
    // stable surface (D1): translate the shim header into the `vt-c`
    // module and link the library artifact.
    if (b.lazyDependency("ghostty", .{})) |dep| {
        const vt_c = b.addTranslateC(.{
            .root_source_file = b.path("src/vt-c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        vt_c.addIncludePath(dep.path("include"));
        exe.root_module.addImport("vt-c", vt_c.createModule());
        exe.root_module.linkLibrary(dep.artifact("ghostty-vt"));
    }

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
