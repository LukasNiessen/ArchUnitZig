const std = @import("std");

const pattern_target = @import("pattern_target.zig");
const regex_module = @import("regex.zig");

const Allocator = std.mem.Allocator;
pub const Captures = regex_module.Captures;
pub const MatchingMode = pattern_target.MatchingMode;
pub const PatternTarget = pattern_target.PatternTarget;
pub const Regex = regex_module.Regex;

/// A compiled regular expression plus the ArchUnit field and matching semantics it describes.
/// Candidate field selection and path normalisation belong to `Filter`; this lower-level value
/// matches the selected byte slice and owns only its compiled regular expression.
pub const RegexMatcher = struct {
    regex: Regex,
    target: PatternTarget,
    matching: MatchingMode,

    pub fn compile(
        allocator: Allocator,
        expression: []const u8,
        target: PatternTarget,
        matching: MatchingMode,
    ) Regex.CompileError!RegexMatcher {
        return .{
            .regex = try Regex.compile(allocator, expression),
            .target = target,
            .matching = matching,
        };
    }

    pub fn deinit(self: *RegexMatcher) void {
        self.regex.deinit();
        self.* = undefined;
    }

    pub fn matches(
        self: *const RegexMatcher,
        allocator: Allocator,
        selected_value: []const u8,
    ) Regex.MatchError!bool {
        return switch (self.matching) {
            .partial => self.regex.isMatch(allocator, selected_value),
            .exact => if (try self.regex.find(allocator, selected_value)) |found|
                found.start == 0 and found.end == selected_value.len
            else
                false,
        };
    }

    /// Returns captures only when the match also satisfies this matcher's exact/partial mode.
    /// Capture texts borrow from `selected_value`; the returned outer collection must be freed.
    pub fn captures(
        self: *const RegexMatcher,
        allocator: Allocator,
        selected_value: []const u8,
    ) Regex.MatchError!?Captures {
        const found = (try self.regex.captures(allocator, selected_value)) orelse return null;
        if (self.matching == .exact and found.values[0].?.len != selected_value.len) {
            found.deinit(allocator);
            return null;
        }
        return found;
    }
};

pub fn fileNameMatcher(allocator: Allocator, expression: []const u8) Regex.CompileError!RegexMatcher {
    return RegexMatcher.compile(allocator, expression, .filename, .partial);
}

pub fn folderMatcher(allocator: Allocator, expression: []const u8) Regex.CompileError!RegexMatcher {
    return RegexMatcher.compile(allocator, expression, .path_without_filename, .partial);
}

pub fn pathMatcher(allocator: Allocator, expression: []const u8) Regex.CompileError!RegexMatcher {
    return RegexMatcher.compile(allocator, expression, .path, .partial);
}

pub fn declarationNameMatcher(
    allocator: Allocator,
    expression: []const u8,
) Regex.CompileError!RegexMatcher {
    return RegexMatcher.compile(allocator, expression, .declaration_name, .partial);
}

pub const ExactFileError = Regex.CompileError || error{EmptyExactPath};

/// Compiles a literal project-relative path. Regular-expression metacharacters have no special
/// meaning, and the resulting matcher accepts only the entire selected path.
pub fn exactFileMatcher(allocator: Allocator, path: []const u8) ExactFileError!RegexMatcher {
    if (path.len == 0) return error.EmptyExactPath;

    const quoted = try regex_module.quoteLiteral(allocator, path);
    defer allocator.free(quoted);
    return RegexMatcher.compile(allocator, quoted, .path, .exact);
}

test "factory functions assign all Zig matching targets" {
    var filename = try fileNameMatcher(std.testing.allocator, "service");
    defer filename.deinit();
    var folder = try folderMatcher(std.testing.allocator, "src/domain");
    defer folder.deinit();
    var path = try pathMatcher(std.testing.allocator, "src/.+\\.zig");
    defer path.deinit();
    var declaration = try declarationNameMatcher(std.testing.allocator, ".*Service");
    defer declaration.deinit();
    var exact_file = try exactFileMatcher(std.testing.allocator, "src/order[legacy].zig");
    defer exact_file.deinit();

    try std.testing.expectEqual(PatternTarget.filename, filename.target);
    try std.testing.expectEqual(PatternTarget.path_without_filename, folder.target);
    try std.testing.expectEqual(PatternTarget.path, path.target);
    try std.testing.expectEqual(PatternTarget.declaration_name, declaration.target);
    try std.testing.expectEqual(PatternTarget.path, exact_file.target);
    try std.testing.expectEqual(MatchingMode.exact, exact_file.matching);
}

test "partial and exact matcher modes have distinct behavior" {
    var partial = try fileNameMatcher(std.testing.allocator, "order");
    defer partial.deinit();
    var exact = try exactFileMatcher(std.testing.allocator, "src/order[legacy].zig");
    defer exact.deinit();

    try std.testing.expect(try partial.matches(std.testing.allocator, "order_service.zig"));
    try std.testing.expect(try exact.matches(std.testing.allocator, "src/order[legacy].zig"));
    try std.testing.expect(!try exact.matches(
        std.testing.allocator,
        "prefix/src/order[legacy].zig",
    ));
    try std.testing.expect(!try exact.matches(std.testing.allocator, "src/orderl.zig"));
}

test "matcher captures respect exact mode" {
    var matcher = try RegexMatcher.compile(
        std.testing.allocator,
        "src/([^/]+)",
        .path,
        .exact,
    );
    defer matcher.deinit();

    const captures = (try matcher.captures(std.testing.allocator, "src/domain")).?;
    defer captures.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("domain", captures.values[1].?);
    try std.testing.expectEqual(
        @as(?Captures, null),
        try matcher.captures(std.testing.allocator, "src/domain/model.zig"),
    );
}

test "factories preserve compile errors and reject empty exact paths" {
    try std.testing.expectError(
        error.MissingParen,
        pathMatcher(std.testing.allocator, "("),
    );
    try std.testing.expectError(
        error.EmptyExactPath,
        exactFileMatcher(std.testing.allocator, ""),
    );
}

fn exerciseFactoryAllocationFailures(allocator: Allocator) !void {
    var matcher = try exactFileMatcher(allocator, "src/order[legacy].zig");
    defer matcher.deinit();
    try std.testing.expect(try matcher.matches(allocator, "src/order[legacy].zig"));
}

test "exact-file factory cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFactoryAllocationFailures,
        .{},
    );
}
