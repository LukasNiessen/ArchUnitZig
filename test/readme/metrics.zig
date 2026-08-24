const std = @import("std");
const archunit = @import("archunit");

test "source files stay small" {
    var project = try archunit.metrics(std.testing.allocator, .{});
    defer project.deinit();
    var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
    defer source.deinit();
    var counts = try source.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var rule = try functions.shouldBeBelowOrEqual(2);
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
