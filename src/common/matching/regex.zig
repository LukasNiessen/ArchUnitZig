const std = @import("std");
const backend = @import("regex");

const Allocator = std.mem.Allocator;

/// A byte range into the input passed to `find`.
pub const MatchRange = struct {
    start: usize,
    end: usize,
};

/// Capture texts borrow from the input passed to `captures`; only the outer slice is owned.
pub const Captures = struct {
    values: []?[]const u8,

    pub fn deinit(self: Captures, allocator: Allocator) void {
        allocator.free(self.values);
    }
};

/// The allocator-aware regular-expression boundary used by ArchUnitZig.
///
/// Backend types deliberately do not escape this file. A compiled value owns its program and must
/// be released with `deinit`; matching uses the allocator supplied for transient engine storage.
pub const Regex = struct {
    compiled: backend.Regexp,

    pub const CompileError = backend.ParseError;
    pub const MatchError = backend.ExecError;

    pub fn compile(allocator: Allocator, expression: []const u8) CompileError!Regex {
        return .{ .compiled = try backend.compile(allocator, expression) };
    }

    pub fn deinit(self: *Regex) void {
        self.compiled.deinit();
        self.* = undefined;
    }

    /// Returns the expression owned by this compiled value.
    pub fn source(self: *const Regex) []const u8 {
        return self.compiled.string();
    }

    pub fn captureCount(self: *const Regex) usize {
        return self.compiled.numSubexp();
    }

    pub fn isMatch(self: *const Regex, allocator: Allocator, input: []const u8) MatchError!bool {
        return self.compiled.match(allocator, input);
    }

    pub fn find(self: *const Regex, allocator: Allocator, input: []const u8) MatchError!?MatchRange {
        const found = (try self.compiled.findIndex(allocator, input)) orelse return null;
        return .{ .start = found.start, .end = found.end };
    }

    pub fn captures(self: *const Regex, allocator: Allocator, input: []const u8) MatchError!?Captures {
        const values = (try self.compiled.findSubmatch(allocator, input)) orelse return null;
        return .{ .values = values };
    }
};

/// Escapes a literal so that compiling the result cannot interpret regular-expression syntax.
pub fn quoteLiteral(allocator: Allocator, literal: []const u8) Allocator.Error![]u8 {
    return backend.quoteMeta(allocator, literal);
}

test "compile reports malformed expressions" {
    try std.testing.expectError(error.MissingParen, Regex.compile(std.testing.allocator, "("));
}

test "compiled regex owns its expression and finds byte ranges" {
    var expression = [_]u8{ 's', 'e', 'r', 'v', 'i', 'c', 'e' };
    var regex = try Regex.compile(std.testing.allocator, &expression);
    defer regex.deinit();
    @memset(&expression, 'x');

    try std.testing.expectEqualStrings("service", regex.source());
    try std.testing.expect(try regex.isMatch(std.testing.allocator, "order_service.zig"));
    try std.testing.expectEqual(
        MatchRange{ .start = 6, .end = 13 },
        (try regex.find(std.testing.allocator, "order_service.zig")).?,
    );
}

test "captures borrow input while their outer collection is owned" {
    var regex = try Regex.compile(std.testing.allocator, "src/([^/]+)/.*\\.zig");
    defer regex.deinit();

    const captures = (try regex.captures(
        std.testing.allocator,
        "src/feature/order_service.zig",
    )).?;
    defer captures.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), regex.captureCount());
    try std.testing.expectEqual(@as(usize, 2), captures.values.len);
    try std.testing.expectEqualStrings("src/feature/order_service.zig", captures.values[0].?);
    try std.testing.expectEqualStrings("feature", captures.values[1].?);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var regex = try Regex.compile(allocator, "src/([^/]+)/.*\\.zig");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(allocator, "src/feature/service.zig"));
    const captures = (try regex.captures(allocator, "src/feature/service.zig")).?;
    defer captures.deinit(allocator);
    try std.testing.expectEqualStrings("feature", captures.values[1].?);
}

test "compilation and capture matching clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "nested repetition handles adversarial non-matching input" {
    var input: [4097]u8 = undefined;
    @memset(input[0..4096], 'a');
    input[4096] = '!';

    var regex = try Regex.compile(std.testing.allocator, "(a+)+$");
    defer regex.deinit();

    try std.testing.expect(!try regex.isMatch(std.testing.allocator, &input));
}

test "literal quoting escapes every supported metacharacter" {
    const quoted = try quoteLiteral(std.testing.allocator, "src/order[legacy].zig");
    defer std.testing.allocator.free(quoted);

    var regex = try Regex.compile(std.testing.allocator, quoted);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(std.testing.allocator, "src/order[legacy].zig"));
    try std.testing.expect(!try regex.isMatch(std.testing.allocator, "src/orderl.zig"));
}
