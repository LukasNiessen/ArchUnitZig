const std = @import("std");
const archunit = @import("archunit");

test "inspect a rule with explicit verbosity and highlighted output" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var service = try files.inFile(&.{"src/service/root.zig"});
    defer service.deinit();
    var should = try service.should();
    defer should.deinit();
    var rule = try should.haveName(.{ .glob = "root.zig" });
    defer rule.deinit(std.testing.allocator);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var options = archunit.CheckOptions.init(std.testing.allocator, std.testing.io);
    options.logging = .{
        .level = .debug,
        .writer = &output.writer,
        .writer_color = true,
    };
    var violations = try rule.check(options);
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(violations.passes());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "selected file: src/service/root.zig") != null);
}
