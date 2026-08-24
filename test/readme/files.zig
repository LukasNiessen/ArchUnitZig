const std = @import("std");
const archunit = @import("archunit");

test "API files depend on service files" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var api = try files.inPath(&.{.{ .glob = "src/api/**" }});
    defer api.deinit();
    var should = try api.should();
    defer should.deinit();
    var dependency = try should.dependOnFiles();
    defer dependency.deinit();
    var rule = try dependency.inPath(&.{.{ .glob = "src/service/**" }});
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
