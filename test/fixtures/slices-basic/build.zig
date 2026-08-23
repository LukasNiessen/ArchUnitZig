const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("slices_fixture", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run fixture tests");
    test_step.dependOn(&run_tests.step);
}
