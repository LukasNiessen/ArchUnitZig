const std = @import("std");

const query_options = @import("query_options.zig");
const regex_module = @import("../../common/matching/regex.zig");

const Allocator = std.mem.Allocator;
const Regex = regex_module.Regex;

pub const CollapseError = Allocator.Error || Regex.CompileError || Regex.MatchError || error{
    InvalidFolderDepth,
    InvalidCollapseReplacement,
};

/// A compiled collapse strategy reusable across every node in one snapshot operation.
pub const Collapser = union(enum) {
    none,
    folder_depth: usize,
    pattern: PatternState,

    const PatternState = struct {
        regex: Regex,
        replacement: []const u8,
    };

    pub fn init(
        allocator: Allocator,
        strategy: ?query_options.CollapseQuery,
    ) CollapseError!Collapser {
        const selected = strategy orelse return .none;
        return switch (selected) {
            .folder_depth => |depth| if (depth == 0)
                error.InvalidFolderDepth
            else
                .{ .folder_depth = depth },
            .pattern => |pattern| blk: {
                var regex = try Regex.compile(allocator, pattern.expression);
                errdefer regex.deinit();
                try validateReplacement(pattern.replacement, regex.captureCount());
                break :blk .{ .pattern = .{
                    .regex = regex,
                    .replacement = pattern.replacement,
                } };
            },
        };
    }

    pub fn deinit(self: *Collapser) void {
        switch (self.*) {
            .pattern => |*pattern| pattern.regex.deinit(),
            else => {},
        }
        self.* = undefined;
    }

    pub fn collapse(self: *const Collapser, allocator: Allocator, label: []const u8) CollapseError![]u8 {
        return switch (self.*) {
            .none => allocator.dupe(u8, label),
            .folder_depth => |depth| collapseFolder(allocator, label, depth),
            .pattern => |*pattern| collapsePattern(allocator, label, pattern),
        };
    }
};

fn validateReplacement(replacement: []const u8, capture_count: usize) error{InvalidCollapseReplacement}!void {
    var index: usize = 0;
    while (index < replacement.len) : (index += 1) {
        if (replacement[index] != '$') continue;
        if (index + 1 == replacement.len) return error.InvalidCollapseReplacement;
        index += 1;
        const symbol = replacement[index];
        if (symbol == '$') continue;
        if (symbol < '0' or symbol > '9') return error.InvalidCollapseReplacement;
        if (symbol - '0' > capture_count) return error.InvalidCollapseReplacement;
    }
}

fn collapseFolder(allocator: Allocator, label: []const u8, depth: usize) Allocator.Error![]u8 {
    const last_separator = std.mem.lastIndexOfScalar(u8, label, '/') orelse
        return allocator.dupe(u8, label);
    const folders = label[0..last_separator];
    if (folders.len == 0) return allocator.dupe(u8, label);

    var separators_seen: usize = 0;
    for (folders, 0..) |byte, index| {
        if (byte != '/') continue;
        separators_seen += 1;
        if (separators_seen == depth) return allocator.dupe(u8, folders[0..index]);
    }
    return allocator.dupe(u8, folders);
}

fn collapsePattern(
    allocator: Allocator,
    label: []const u8,
    pattern: *const Collapser.PatternState,
) CollapseError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    while (cursor <= label.len) {
        const remaining = label[cursor..];
        const captures = (try pattern.regex.captures(allocator, remaining)) orelse {
            try output.appendSlice(allocator, remaining);
            break;
        };
        defer captures.deinit(allocator);
        const full_match = captures.values[0].?;
        const match_start = @intFromPtr(full_match.ptr) - @intFromPtr(remaining.ptr);
        const match_end = match_start + full_match.len;
        try output.appendSlice(allocator, remaining[0..match_start]);
        try appendReplacement(allocator, &output, pattern.replacement, captures.values);
        cursor += match_end;

        if (full_match.len != 0) continue;
        if (cursor == label.len) break;
        const scalar_length = std.unicode.utf8ByteSequenceLength(label[cursor]) catch 1;
        const consumed = @min(@as(usize, scalar_length), label.len - cursor);
        try output.appendSlice(allocator, label[cursor .. cursor + consumed]);
        cursor += consumed;
    }
    return output.toOwnedSlice(allocator);
}

fn appendReplacement(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    replacement: []const u8,
    captures: []const ?[]const u8,
) Allocator.Error!void {
    var index: usize = 0;
    while (index < replacement.len) : (index += 1) {
        if (replacement[index] != '$') {
            try output.append(allocator, replacement[index]);
            continue;
        }
        index += 1;
        const symbol = replacement[index];
        if (symbol == '$') {
            try output.append(allocator, '$');
            continue;
        }
        const capture_index: usize = symbol - '0';
        if (captures[capture_index]) |capture| try output.appendSlice(allocator, capture);
    }
}

fn expectCollapse(strategy: ?query_options.CollapseQuery, label: []const u8, expected: []const u8) !void {
    var collapser = try Collapser.init(std.testing.allocator, strategy);
    defer collapser.deinit();
    const collapsed = try collapser.collapse(std.testing.allocator, label);
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqualStrings(expected, collapsed);
}

test "folder collapse keeps root files and projects nested paths to a positive depth" {
    try expectCollapse(.{ .folder_depth = 1 }, "src/domain/service.zig", "src");
    try expectCollapse(.{ .folder_depth = 2 }, "src/domain/service.zig", "src/domain");
    try expectCollapse(.{ .folder_depth = 8 }, "src/domain/service.zig", "src/domain");
    try expectCollapse(.{ .folder_depth = 1 }, "build.zig", "build.zig");
    try std.testing.expectError(
        error.InvalidFolderDepth,
        Collapser.init(std.testing.allocator, .{ .folder_depth = 0 }),
    );
}

test "pattern collapse replaces globally with captures optional values and literal dollars" {
    try expectCollapse(
        .{ .pattern = .{ .expression = "(?:src|test)/([^/ ]+)/([^/ ]+)", .replacement = "$1/$$/$2" } },
        "src/domain/a.zig test/support/b.zig",
        "domain/$/a.zig support/$/b.zig",
    );
    try expectCollapse(
        .{ .pattern = .{ .expression = "^(src/)?(.*)$", .replacement = "$1$2" } },
        "main.zig",
        "main.zig",
    );
}

test "pattern collapse rejects malformed expressions and capture replacements" {
    try std.testing.expectError(
        error.MissingParen,
        Collapser.init(std.testing.allocator, .{ .pattern = .{
            .expression = "(",
            .replacement = "$0",
        } }),
    );
    try std.testing.expectError(
        error.InvalidCollapseReplacement,
        Collapser.init(std.testing.allocator, .{ .pattern = .{
            .expression = "(src)",
            .replacement = "$2",
        } }),
    );
    try std.testing.expectError(
        error.InvalidCollapseReplacement,
        Collapser.init(std.testing.allocator, .{ .pattern = .{
            .expression = "src",
            .replacement = "$name",
        } }),
    );
}

test "zero-length global matches advance by a Unicode scalar" {
    try expectCollapse(
        .{ .pattern = .{ .expression = "", .replacement = "_" } },
        "aé",
        "_a_é_",
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var collapser = try Collapser.init(allocator, .{ .pattern = .{
        .expression = "(?:src|test)/([^/ ]+)/([^/ ]+)",
        .replacement = "$1/$$/$2",
    } });
    defer collapser.deinit();
    const collapsed = try collapser.collapse(allocator, "src/domain/a.zig test/support/b.zig");
    defer allocator.free(collapsed);
}

test "pattern collapse cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
