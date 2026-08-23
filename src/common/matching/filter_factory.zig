const std = @import("std");

const common_path = @import("../path.zig");
const filter_module = @import("filter.zig");
const pattern_module = @import("pattern.zig");
const regex_factory = @import("regex_factory.zig");

const Allocator = std.mem.Allocator;
pub const Filter = filter_module.Filter;
pub const Pattern = pattern_module.Pattern;

pub fn fileNameMatcher(allocator: Allocator, pattern: Pattern) pattern_module.CompileError!Filter {
    return Filter.init(allocator, pattern, .filename, .partial);
}

pub fn folderMatcher(allocator: Allocator, pattern: Pattern) pattern_module.CompileError!Filter {
    return Filter.init(allocator, pattern, .path_without_filename, .partial);
}

pub fn pathMatcher(allocator: Allocator, pattern: Pattern) pattern_module.CompileError!Filter {
    return Filter.init(allocator, pattern, .path, .partial);
}

pub fn declarationNameMatcher(
    allocator: Allocator,
    pattern: Pattern,
) pattern_module.CompileError!Filter {
    return Filter.init(allocator, pattern, .declaration_name, .partial);
}

pub fn exactFileMatcher(allocator: Allocator, file_path: []const u8) regex_factory.ExactFileError!Filter {
    const normalized = try common_path.normalize(allocator, file_path);
    defer allocator.free(normalized);
    return .{ .matcher = try regex_factory.exactFileMatcher(allocator, normalized) };
}

test "factory surface creates filters for every target" {
    var filename = try fileNameMatcher(std.testing.allocator, .{ .glob = "*.zig" });
    defer filename.deinit();
    var folder = try folderMatcher(std.testing.allocator, .{ .glob = "src/**" });
    defer folder.deinit();
    var path = try pathMatcher(std.testing.allocator, .{ .regex = "src/.+" });
    defer path.deinit();
    var declaration = try declarationNameMatcher(std.testing.allocator, .{ .glob = "*Service" });
    defer declaration.deinit();
    var exact = try exactFileMatcher(std.testing.allocator, "src\\order[legacy].zig");
    defer exact.deinit();

    try std.testing.expectEqual(filter_module.PatternTarget.filename, filename.target());
    try std.testing.expectEqual(filter_module.PatternTarget.path_without_filename, folder.target());
    try std.testing.expectEqual(filter_module.PatternTarget.path, path.target());
    try std.testing.expectEqual(filter_module.PatternTarget.declaration_name, declaration.target());
    try std.testing.expectEqual(filter_module.MatchingMode.exact, exact.matching());
    try std.testing.expect(try exact.matches(
        std.testing.allocator,
        .{ .path = "src/order[legacy].zig" },
    ));
}

test "exact-file factory rejects empty paths" {
    try std.testing.expectError(
        error.EmptyExactPath,
        exactFileMatcher(std.testing.allocator, ""),
    );
}
