const std = @import("std");
const archunit = @import("archunit");

test "API does not bypass service" {
    var project = try archunit.projectSlices(std.testing.allocator, .{});
    defer project.deinit();
    var slices = try project.definedByRegex("^src/([^/]+)/");
    defer slices.deinit();
    var should_not = try slices.shouldNot();
    defer should_not.deinit();
    var rule = try should_not.containDependency("api", "domain");
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
