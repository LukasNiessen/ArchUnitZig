const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const domain = b.addModule("domain", .{
        .root_source_file = b.path("src/domain/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const application = b.addModule("application", .{
        .root_source_file = b.path("src/application/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    application.addImport("domain", domain);
    const vendor_package = b.addModule("vendor_pkg", .{
        .root_source_file = b.path("vendor/vendor_pkg/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = b.addModule("acceptance_app", .{
        .root_source_file = b.path("src/presentation/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.addImport("application", application);
    app.addImport("vendor_pkg", vendor_package);
    app.addIncludePath(b.path("include"));

    const app_tests = b.addTest(.{ .root_module = app });
    const run_app_tests = b.addRunArtifact(app_tests);

    const infrastructure = b.addModule("infrastructure", .{
        .root_source_file = b.path("src/infrastructure/repository.zig"),
        .target = target,
        .optimize = optimize,
    });
    infrastructure.addImport("domain", domain);
    app.addImport("infrastructure", infrastructure);
    const infrastructure_tests = b.addTest(.{ .root_module = infrastructure });
    const run_infrastructure_tests = b.addRunArtifact(infrastructure_tests);
    run_infrastructure_tests.step.dependOn(&run_app_tests.step);

    const integration = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration.addImport("app", app);
    integration.addImport("vendor_pkg", vendor_package);
    const integration_tests = b.addTest(.{ .root_module = integration });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&run_infrastructure_tests.step);

    const test_step = b.step("test", "Build and run the acceptance fixture tests");
    test_step.dependOn(&run_integration_tests.step);
}
