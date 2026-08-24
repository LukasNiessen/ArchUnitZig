const std = @import("std");
const archunit = @import("archunit");

test "production files have no cycles" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var production = try files.inPath(&.{ .{ .glob = "src/*.zig" }, .{ .glob = "src/**/*.zig" } });
    defer production.deinit();
    var should = try production.should();
    defer should.deinit();
    var rule = try should.haveNoCycles();
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
