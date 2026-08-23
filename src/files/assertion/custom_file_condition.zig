const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const file_info = @import("../extraction/file_info.zig");

const Allocator = std.mem.Allocator;
pub const FileInfo = file_info.FileInfo;

/// Custom predicates may allocate from the per-check allocator and may return any error. A
/// predicate error aborts analysis unchanged and is never converted into a violation.
pub const CustomFilePredicate = *const fn (allocator: Allocator, info: FileInfo) anyerror!bool;

/// Pure evaluation of already-inspected borrowed files. A violation owns scalar evidence and user
/// description, but never the borrowed source bytes.
pub fn gatherCustomFileViolations(
    allocator: Allocator,
    infos: []const FileInfo,
    predicate: CustomFilePredicate,
    description: []const u8,
    mood: assertion.Mood,
) anyerror!assertion.ViolationList {
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);

    for (infos) |info| {
        const predicate_result = try predicate(allocator, info);
        if (mood.holds(predicate_result)) continue;
        var payload = try assertion.CustomFileViolation.init(
            allocator,
            info.path,
            description,
            info.source_bytes.len,
            info.non_blank_line_count,
            info.imports,
            info.top_level_declarations,
            mood,
        );
        var violation = assertion.Violation.fromCustomFileMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

fn atMostOneImport(_: Allocator, info: FileInfo) !bool {
    return info.imports.total <= 1;
}

fn failPredicate(_: Allocator, _: FileInfo) !bool {
    return error.PredicateAnalysisFailed;
}

const first = FileInfo{
    .path = "src/first.zig",
    .stem = "first",
    .extension = ".zig",
    .directory = "src",
    .source_bytes = "const std = @import(\"std\");",
    .non_blank_line_count = 1,
    .imports = imports: {
        var value: file_info.ImportSummary = .{};
        value.record(.standard_library);
        break :imports value;
    },
    .top_level_declarations = .{ .total = 1, .variables = 1 },
};

const second = FileInfo{
    .path = "src/second.zig",
    .stem = "second",
    .extension = ".zig",
    .directory = "src",
    .source_bytes = "two imports",
    .non_blank_line_count = 1,
    .imports = imports: {
        var value: file_info.ImportSummary = .{};
        value.record(.zig_file);
        value.record(.named_module);
        break :imports value;
    },
    .top_level_declarations = .{ .total = 0 },
};

test "custom predicates produce complementary positive and negative violations" {
    var positive = try gatherCustomFileViolations(
        std.testing.allocator,
        &.{ first, second },
        atMostOneImport,
        "files use at most one import",
        .should,
    );
    defer positive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive.items().len);
    try std.testing.expectEqualStrings("src/second.zig", positive.items()[0].custom_file.source_path);
    try std.testing.expectEqual(@as(usize, 2), positive.items()[0].custom_file.imports.total);

    var negative = try gatherCustomFileViolations(
        std.testing.allocator,
        &.{ first, second },
        atMostOneImport,
        "files must not use at most one import",
        .should_not,
    );
    defer negative.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), negative.items().len);
    try std.testing.expectEqualStrings("src/first.zig", negative.items()[0].custom_file.source_path);
}

test "custom predicate errors propagate unchanged without partial violations" {
    try std.testing.expectError(
        error.PredicateAnalysisFailed,
        gatherCustomFileViolations(
            std.testing.allocator,
            &.{first},
            failPredicate,
            "predicate succeeds",
            .should,
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var result = try gatherCustomFileViolations(
        allocator,
        &.{second},
        atMostOneImport,
        "files use at most one import",
        .should,
    );
    defer result.deinit(allocator);
    var cloned = try result.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(result.items()[0].eql(cloned.items()[0]));
}

test "custom violation gathering and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
