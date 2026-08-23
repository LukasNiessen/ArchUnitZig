const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const archunit = b.addModule("archunit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const regex_dependency = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    archunit.addImport("regex", regex_dependency.module("regex"));

    const module_tests = b.addTest(.{
        .root_module = archunit,
    });
    const run_module_tests = b.addRunArtifact(module_tests);
    run_module_tests.setCwd(b.path("."));

    const format_check = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });

    const test_step = b.step("test", "Run formatting checks and tests");
    test_step.dependOn(&format_check.step);
    test_step.dependOn(&run_module_tests.step);
}
