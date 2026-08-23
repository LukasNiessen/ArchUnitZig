const std = @import("std");

const import_kind = @import("../extraction/import_kind.zig");
const mood_module = @import("mood.zig");
const source_parser = @import("../extraction/source_parser.zig");

const Allocator = std.mem.Allocator;
pub const ImportSummary = import_kind.ImportSummary;
pub const Mood = mood_module.Mood;
pub const TopLevelDeclarationCounts = source_parser.TopLevelDeclarationCounts;
pub const InitError = Allocator.Error || error{ EmptyDescription, EmptySourcePath };

/// Owned summary for one file that disagrees with a user predicate. Source bytes are deliberately
/// omitted: callback access is borrowed and a violation should not duplicate an arbitrary file.
pub const CustomFileViolation = struct {
    source_path: []const u8,
    description: []const u8,
    source_byte_count: usize,
    non_blank_line_count: usize,
    imports: ImportSummary,
    top_level_declarations: ?TopLevelDeclarationCounts,
    mood: Mood,

    pub fn init(
        allocator: Allocator,
        source_path: []const u8,
        description: []const u8,
        source_byte_count: usize,
        non_blank_line_count: usize,
        imports: ImportSummary,
        top_level_declarations: ?TopLevelDeclarationCounts,
        mood: Mood,
    ) InitError!CustomFileViolation {
        if (source_path.len == 0) return error.EmptySourcePath;
        if (!containsNonWhitespace(description)) return error.EmptyDescription;
        const owned_path = try allocator.dupe(u8, source_path);
        errdefer allocator.free(owned_path);
        const owned_description = try allocator.dupe(u8, description);
        return .{
            .source_path = owned_path,
            .description = owned_description,
            .source_byte_count = source_byte_count,
            .non_blank_line_count = non_blank_line_count,
            .imports = imports,
            .top_level_declarations = top_level_declarations,
            .mood = mood,
        };
    }

    pub fn clone(self: CustomFileViolation, allocator: Allocator) InitError!CustomFileViolation {
        return init(
            allocator,
            self.source_path,
            self.description,
            self.source_byte_count,
            self.non_blank_line_count,
            self.imports,
            self.top_level_declarations,
            self.mood,
        );
    }

    pub fn deinit(self: *CustomFileViolation, allocator: Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.description);
        self.* = undefined;
    }

    pub fn eql(self: CustomFileViolation, other: CustomFileViolation) bool {
        return std.mem.eql(u8, self.source_path, other.source_path) and
            std.mem.eql(u8, self.description, other.description) and
            self.source_byte_count == other.source_byte_count and
            self.non_blank_line_count == other.non_blank_line_count and
            std.meta.eql(self.imports, other.imports) and
            std.meta.eql(self.top_level_declarations, other.top_level_declarations) and
            self.mood == other.mood;
    }
};

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "custom file violations clone owned summaries without source bytes" {
    var imports: ImportSummary = .{};
    imports.record(.standard_library);
    var original = try CustomFileViolation.init(
        std.testing.allocator,
        "src/main.zig",
        "entry points stay small",
        128,
        7,
        imports,
        .{ .total = 2, .functions = 1, .variables = 1 },
        .should,
    );
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.source_path.ptr != cloned.source_path.ptr);
    try std.testing.expect(original.description.ptr != cloned.description.ptr);
    try std.testing.expectEqual(@as(usize, 1), cloned.imports.count(.standard_library));
}

test "custom file violation descriptions must carry a policy" {
    try std.testing.expectError(
        error.EmptyDescription,
        CustomFileViolation.init(
            std.testing.allocator,
            "src/main.zig",
            " \n\t",
            0,
            0,
            .{},
            null,
            .should_not,
        ),
    );
}
