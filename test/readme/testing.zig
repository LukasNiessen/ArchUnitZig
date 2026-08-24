const std = @import("std");
const archunit = @import("archunit");

pub fn renderedFailure() !archunit.TestResult {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var service = try files.inFile(&.{"src/service/root.zig"});
    defer service.deinit();
    var should_not = try service.shouldNot();
    defer should_not.deinit();
    var dependency = try should_not.dependOnFiles();
    defer dependency.deinit();
    var rule = try dependency.inFile(&.{"src/domain/root.zig"});
    defer rule.deinit(std.testing.allocator);
    var violations = try rule.check(.init(std.testing.allocator, std.testing.io));
    defer violations.deinit(std.testing.allocator);
    const sentence = try rule.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    return archunit.ResultFactory.fromViolations(
        std.testing.allocator,
        violations.items(),
        sentence,
        .{ .color = .{ .mode = .never } },
    );
}

test "testing support renders a concrete failure" {
    var result = try renderedFailure();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.passed);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "src/service/root.zig:1:16") != null);
}
