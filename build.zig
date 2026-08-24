const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const python = b.findProgram(&.{ "python3", "python" }, &.{}) catch "python";

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

    const readme_fixture = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        optimize_argument,
        "--global-cache-dir",
        acceptance_cache,
    });
    readme_fixture.setCwd(b.path("test/fixtures/readme-consumer"));
    readme_fixture.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", acceptance_cache);
    readme_fixture.step.dependOn(&run_dogfood_tests.step);

    const readme = b.createModule(.{
        .root_source_file = b.path("test/readme.zig"),
        .target = target,
        .optimize = optimize,
    });
    readme.addImport("archunit", archunit);
    const readme_tests = b.addTest(.{ .root_module = readme });
    readme_tests.step.dependOn(&readme_fixture.step);
    const run_readme_tests = b.addRunArtifact(readme_tests);
    run_readme_tests.setCwd(b.path("test/fixtures/readme-consumer"));

    const format_check = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
            "test/acceptance.zig",
            "test/dogfood.zig",
            "test/readme.zig",
            "test/readme",
        },
        .check = true,
    });

    const docs_library = b.addLibrary(.{
        .name = "archunit-docs",
        .linkage = .static,
        .root_module = archunit,
    });
    docs_library.step.dependOn(&run_readme_tests.step);

    const build_docs = b.addSystemCommand(&.{
        python,
        "scripts/build_docs.py",
        "--root",
    });
    build_docs.addDirectoryArg(b.path("."));
    build_docs.addArg("--output");
    const docs_output = build_docs.addOutputDirectoryArg("documentation-site");
    build_docs.addArg("--api-docs");
    build_docs.addDirectoryArg(docs_library.getEmittedDocs());

    const check_docs = b.addSystemCommand(&.{
        python,
        "scripts/check_docs.py",
        "--root",
    });
    check_docs.addDirectoryArg(b.path("."));
    check_docs.addArg("--site");
    check_docs.addDirectoryArg(docs_output);
    check_docs.step.dependOn(&build_docs.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_output,
        .install_dir = .prefix,
        .install_subdir = "docs-site",
    });
    install_docs.step.dependOn(&check_docs.step);

    const docs_step = b.step("docs", "Build and validate the documentation site");
    docs_step.dependOn(&format_check.step);
    docs_step.dependOn(&install_docs.step);

    const test_step = b.step("test", "Run formatting checks and tests");
    test_step.dependOn(&format_check.step);
    test_step.dependOn(&run_readme_tests.step);
}
