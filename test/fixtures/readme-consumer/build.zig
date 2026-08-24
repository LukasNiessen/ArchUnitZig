const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const archunit = b.dependency("archunit", .{ .target = target, .optimize = optimize });

    const architecture = b.createModule(.{
        .root_source_file = b.path("test/architecture.zig"),
        .target = target,
        .optimize = optimize,
    });
    architecture.addImport("archunit", archunit.module("archunit"));
    const architecture_tests = b.addTest(.{ .root_module = architecture });
    const run_architecture_tests = b.addRunArtifact(architecture_tests);
    run_architecture_tests.setCwd(b.path("."));

    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "test" }, .check = true });
    const test_step = b.step("test", "Run formatting and architecture tests");
    test_step.dependOn(&format.step);
    test_step.dependOn(&run_architecture_tests.step);
}
