const std = @import("std");
const archunit = @import("archunit");
const testing_example = @import("readme/testing.zig");

const SourceBlock = struct {
    id: []const u8,
    path: []const u8,
};

const source_blocks = [_]SourceBlock{
    .{ .id = "build-wiring", .path = "build.zig" },
    .{ .id = "first-test", .path = "test/architecture.zig" },
    .{ .id = "files-example", .path = "../../../test/readme/files.zig" },
    .{ .id = "layers-example", .path = "../../../test/readme/layers.zig" },
    .{ .id = "slices-example", .path = "../../../test/readme/slices.zig" },
    .{ .id = "metrics-example", .path = "../../../test/readme/metrics.zig" },
    .{ .id = "graph-example", .path = "../../../test/readme/graph.zig" },
    .{ .id = "testing-example", .path = "../../../test/readme/testing.zig" },
};

test {
    _ = archunit;
    _ = @import("readme/files.zig");
    _ = @import("readme/layers.zig");
    _ = @import("readme/slices.zig");
    _ = @import("readme/metrics.zig");
    _ = @import("readme/graph.zig");
    _ = testing_example;
}

test "README examples execute from the consumer project" {
    var failure = try testing_example.renderedFailure();
    defer failure.deinit(std.testing.allocator);
    try std.testing.expect(!failure.passed);
}

test "every README fence is synchronized with exercised documentation" {
    const allocator = std.testing.allocator;
    const readme_raw = try readFile(allocator, "../../../README.md");
    defer allocator.free(readme_raw);
    const readme = try normalizeLineEndings(allocator, readme_raw);
    defer allocator.free(readme);

    for (source_blocks) |source_block| {
        const source_raw = try readFile(allocator, source_block.path);
        defer allocator.free(source_raw);
        const source = try normalizeLineEndings(allocator, source_raw);
        defer allocator.free(source);
        try std.testing.expectEqualStrings(
            std.mem.trimEnd(u8, source, "\n"),
            try fencedBlock(allocator, readme, source_block.id),
        );
    }

    try std.testing.expectEqualStrings(
        "zig fetch --save=archunit git+https://github.com/LukasNiessen/ArchUnitZig.git#main",
        try fencedBlock(allocator, readme, "install"),
    );
    var failure = try testing_example.renderedFailure();
    defer failure.deinit(allocator);
    try std.testing.expectEqualStrings(
        failure.message,
        try fencedBlock(allocator, readme, "failure-output"),
    );
    try std.testing.expectEqual(@as(usize, 20), countOccurrences(readme, "```"));
    try std.testing.expectEqual(@as(usize, 10), countOccurrences(readme, "<!-- readme-test:"));
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(std.math.maxInt(usize)),
    );
}

fn normalizeLineEndings(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, source.len - std.mem.count(u8, source, "\r"));
    var index: usize = 0;
    for (source) |byte| {
        if (byte == '\r') continue;
        result[index] = byte;
        index += 1;
    }
    return result;
}

fn fencedBlock(allocator: std.mem.Allocator, readme: []const u8, id: []const u8) ![]const u8 {
    const marker = try std.fmt.allocPrint(allocator, "<!-- readme-test:{s} -->", .{id});
    defer allocator.free(marker);
    const marker_start = std.mem.indexOf(u8, readme, marker) orelse return error.MissingReadmeMarker;
    const fence_start = std.mem.indexOfPos(u8, readme, marker_start + marker.len, "```") orelse
        return error.MissingReadmeFence;
    const content_start = (std.mem.indexOfScalarPos(u8, readme, fence_start, '\n') orelse
        return error.MissingReadmeFenceNewline) + 1;
    const content_end = std.mem.indexOfPos(u8, readme, content_start, "\n```") orelse
        return error.UnclosedReadmeFence;
    return readme[content_start..content_end];
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}
