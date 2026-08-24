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

    const acceptance_cache = b.pathFromRoot(".zig-cache/acceptance-global");
    const optimize_argument = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
    const clean_fixture = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        optimize_argument,
        "--global-cache-dir",
        acceptance_cache,
    });
    clean_fixture.setCwd(b.path("test/fixtures/acceptance projects/clean"));
    clean_fixture.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", acceptance_cache);
    clean_fixture.step.dependOn(&run_module_tests.step);

    const violating_fixture = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        optimize_argument,
        "--global-cache-dir",
        acceptance_cache,
    });
    violating_fixture.setCwd(b.path("test/fixtures/acceptance projects/violating"));
    violating_fixture.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", acceptance_cache);
    violating_fixture.step.dependOn(&clean_fixture.step);

    const acceptance = b.createModule(.{
        .root_source_file = b.path("test/acceptance.zig"),
        .target = target,
        .optimize = optimize,
    });
    acceptance.addImport("archunit", archunit);
    const acceptance_tests = b.addTest(.{ .root_module = acceptance });
    acceptance_tests.step.dependOn(&violating_fixture.step);
    const run_acceptance_tests = b.addRunArtifact(acceptance_tests);
    run_acceptance_tests.setCwd(b.path("."));

    const dogfood = b.createModule(.{
        .root_source_file = b.path("test/dogfood.zig"),
        .target = target,
        .optimize = optimize,
    });
    dogfood.addImport("archunit", archunit);
    const dogfood_tests = b.addTest(.{ .root_module = dogfood });
    dogfood_tests.step.dependOn(&run_acceptance_tests.step);
    const run_dogfood_tests = b.addRunArtifact(dogfood_tests);
    run_dogfood_tests.setCwd(b.path("."));

    const format_check = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "test/acceptance.zig", "test/dogfood.zig" },
        .check = true,
    });

    const test_step = b.step("test", "Run formatting checks and tests");
    test_step.dependOn(&format_check.step);
    test_step.dependOn(&run_dogfood_tests.step);
}
