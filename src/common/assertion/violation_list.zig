const std = @import("std");

const violation_module = @import("violation.zig");

const Allocator = std.mem.Allocator;
pub const Violation = violation_module.Violation;

/// Owned result of an architecture check. An empty list is the sole pass representation.
pub const ViolationList = struct {
    storage: std.ArrayList(Violation) = .empty,

    pub fn deinit(self: *ViolationList, allocator: Allocator) void {
        for (self.storage.items) |*violation| violation.deinit(allocator);
        self.storage.deinit(allocator);
        self.* = undefined;
    }

    pub fn passes(self: *const ViolationList) bool {
        return self.storage.items.len == 0;
    }

    pub fn items(self: *const ViolationList) []const Violation {
        return self.storage.items;
    }

    /// Transfers ownership only after the list append succeeds. On allocation failure the caller
    /// still owns `violation`; after success it is set to undefined to make the move visible.
    pub fn appendMove(
        self: *ViolationList,
        allocator: Allocator,
        violation: *Violation,
    ) Allocator.Error!void {
        try self.storage.append(allocator, violation.*);
        violation.* = undefined;
    }

    pub fn appendClone(
        self: *ViolationList,
        allocator: Allocator,
        violation: Violation,
    ) Violation.CloneError!void {
        var cloned = try violation.clone(allocator);
        errdefer cloned.deinit(allocator);
        try self.appendMove(allocator, &cloned);
    }

    pub fn clone(self: *const ViolationList, allocator: Allocator) Violation.CloneError!ViolationList {
        var result = ViolationList{};
        errdefer result.deinit(allocator);
        for (self.storage.items) |violation| try result.appendClone(allocator, violation);
        return result;
    }
};

fn emptyViolation(allocator: Allocator, rule_id: []const u8) !Violation {
    return .{ .empty_test = try violation_module.EmptyTestViolation.init(
        allocator,
        rule_id,
        &.{},
        false,
    ) };
}

test "empty violation list passes and moved violation makes it fail" {
    var list = ViolationList{};
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(list.passes());

    var violation = try emptyViolation(std.testing.allocator, "files.have_name");
    list.appendMove(std.testing.allocator, &violation) catch |err| {
        violation.deinit(std.testing.allocator);
        return err;
    };

    try std.testing.expect(!list.passes());
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var original = ViolationList{};
    defer original.deinit(allocator);
    var violation = try emptyViolation(allocator, "files.have_no_cycles");
    original.appendMove(allocator, &violation) catch |err| {
        violation.deinit(allocator);
        return err;
    };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(!cloned.passes());
    try std.testing.expect(original.items()[0].eql(cloned.items()[0]));
}

test "violation list cleans up moves and clones on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
