const std = @import("std");

const empty_test = @import("empty_test_violation.zig");

const Allocator = std.mem.Allocator;
pub const EmptyTestViolation = empty_test.EmptyTestViolation;

/// Closed, data-only architecture disagreement. Formatters exhaustively switch on this union in
/// the testing layer; rule code never stores its final prose here.
pub const Violation = union(enum) {
    empty_test: EmptyTestViolation,

    pub const Kind = std.meta.Tag(Violation);
    pub const CloneError = empty_test.InitError;

    pub fn fromEmptyTestMove(payload: *EmptyTestViolation) Violation {
        const result = Violation{ .empty_test = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn kind(self: Violation) Kind {
        return std.meta.activeTag(self);
    }

    pub fn clone(self: Violation, allocator: Allocator) CloneError!Violation {
        return switch (self) {
            .empty_test => |value| .{ .empty_test = try value.clone(allocator) },
        };
    }

    pub fn deinit(self: *Violation, allocator: Allocator) void {
        switch (self.*) {
            .empty_test => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn eql(self: Violation, other: Violation) bool {
        if (self.kind() != other.kind()) return false;
        return switch (self) {
            .empty_test => |left| left.eql(other.empty_test),
        };
    }
};

fn formatterDispatchBoundary(violation: Violation) []const u8 {
    return switch (violation) {
        .empty_test => "format-empty-selection-in-testing-layer",
    };
}

test "tagged union exposes exhaustive presentation dispatch without formatting prose" {
    var payload = try EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_name",
        &.{},
        false,
    );
    var violation = Violation.fromEmptyTestMove(&payload);
    defer violation.deinit(std.testing.allocator);

    try std.testing.expectEqual(Violation.Kind.empty_test, violation.kind());
    try std.testing.expectEqualStrings(
        "format-empty-selection-in-testing-layer",
        formatterDispatchBoundary(violation),
    );
}

test "violation clone owns independent payload storage" {
    var payload = try EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_no_cycles",
        &.{},
        false,
    );
    var original = Violation.fromEmptyTestMove(&payload);
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.empty_test.rule_id.ptr != cloned.empty_test.rule_id.ptr);
}
