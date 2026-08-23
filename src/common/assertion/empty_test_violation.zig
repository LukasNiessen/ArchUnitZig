const std = @import("std");

const scope_pattern = @import("scope_pattern.zig");

const Allocator = std.mem.Allocator;
pub const ScopePattern = scope_pattern.ScopePattern;

pub const InitError = Allocator.Error || error{EmptyRuleId};

/// Facts describing a vacuous architecture rule whose selectors matched no candidates.
/// `rule_id` is a stable machine identifier such as `files.have_name`, not a rendered message.
pub const EmptyTestViolation = struct {
    rule_id: []const u8,
    scope: []ScopePattern,
    is_negated: bool,

    pub fn init(
        allocator: Allocator,
        rule_id: []const u8,
        scope: []const ScopePattern,
        is_negated: bool,
    ) InitError!EmptyTestViolation {
        if (std.mem.trim(u8, rule_id, " \t\r\n").len == 0) return error.EmptyRuleId;

        const owned_rule_id = try allocator.dupe(u8, rule_id);
        errdefer allocator.free(owned_rule_id);
        const owned_scope = try allocator.alloc(ScopePattern, scope.len);
        errdefer allocator.free(owned_scope);

        var initialized: usize = 0;
        errdefer for (owned_scope[0..initialized]) |*pattern| pattern.deinit(allocator);
        for (scope, 0..) |pattern, index| {
            owned_scope[index] = try pattern.clone(allocator);
            initialized += 1;
        }

        return .{
            .rule_id = owned_rule_id,
            .scope = owned_scope,
            .is_negated = is_negated,
        };
    }

    pub fn clone(self: EmptyTestViolation, allocator: Allocator) InitError!EmptyTestViolation {
        return init(allocator, self.rule_id, self.scope, self.is_negated);
    }

    pub fn deinit(self: *EmptyTestViolation, allocator: Allocator) void {
        allocator.free(self.rule_id);
        for (self.scope) |*pattern| pattern.deinit(allocator);
        allocator.free(self.scope);
        self.* = undefined;
    }

    pub fn eql(self: EmptyTestViolation, other: EmptyTestViolation) bool {
        if (!std.mem.eql(u8, self.rule_id, other.rule_id) or
            self.is_negated != other.is_negated or
            self.scope.len != other.scope.len) return false;

        for (self.scope, other.scope) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

test "empty test violation owns rule and grouped scope facts" {
    var first = try ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "src/**" },
        .path,
        .partial,
    );
    defer first.deinit(std.testing.allocator);
    var alternative = try ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "test/**" },
        .path,
        .partial,
    );
    defer alternative.deinit(std.testing.allocator);
    var second_selector = try ScopePattern.init(
        std.testing.allocator,
        1,
        .{ .glob = "*.zig" },
        .filename,
        .partial,
    );
    defer second_selector.deinit(std.testing.allocator);

    var violation = try EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_name",
        &.{ first, alternative, second_selector },
        true,
    );
    defer violation.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("files.have_name", violation.rule_id);
    try std.testing.expectEqual(@as(usize, 3), violation.scope.len);
    try std.testing.expectEqual(@as(usize, 0), violation.scope[1].selector_index);
    try std.testing.expectEqual(@as(usize, 1), violation.scope[2].selector_index);
    try std.testing.expect(violation.is_negated);
}

test "empty test violation rejects a missing machine rule identifier" {
    try std.testing.expectError(
        error.EmptyRuleId,
        EmptyTestViolation.init(std.testing.allocator, " \t", &.{}, false),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var scope = try ScopePattern.init(
        allocator,
        0,
        .{ .regex = "src/(.+)" },
        .path,
        .partial,
    );
    defer scope.deinit(allocator);
    var violation = try EmptyTestViolation.init(
        allocator,
        "files.depend_on_files",
        &.{scope},
        false,
    );
    defer violation.deinit(allocator);
    var cloned = try violation.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(violation.eql(cloned));
}

test "empty test construction and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
