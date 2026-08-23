const std = @import("std");

const assertion = @import("../assertion.zig");
const check_options = @import("check_options.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = check_options.CheckOptions;
pub const ViolationList = assertion.ViolationList;

/// An owned type-erased terminal rule. `fromMove` boxes a concrete rule and invalidates the source,
/// so heterogeneous collections do not borrow rule storage and cannot dangle.
pub const Checkable = struct {
    context: *anyopaque,
    vtable: *const VTable,
    owner_allocator: Allocator,

    const VTable = struct {
        check: *const fn (context: *anyopaque, options: CheckOptions) anyerror!ViolationList,
        deinit: *const fn (context: *anyopaque, allocator: Allocator) void,
    };

    /// On allocation failure the caller still owns `rule`. On success `rule` is set to undefined
    /// and the returned Checkable owns both the boxed value and its optional `deinit(allocator)`.
    pub fn fromMove(allocator: Allocator, rule: anytype) Allocator.Error!Checkable {
        const Rule = @TypeOf(rule.*);
        comptime {
            if (!@hasDecl(Rule, "check")) {
                @compileError("a Checkable rule must declare check(self, CheckOptions)");
            }
        }

        const boxed = try allocator.create(Rule);
        boxed.* = rule.*;
        rule.* = undefined;

        return .{
            .context = boxed,
            .vtable = &Adapter(Rule).vtable,
            .owner_allocator = allocator,
        };
    }

    pub fn check(self: *Checkable, options: CheckOptions) anyerror!ViolationList {
        return self.vtable.check(self.context, options);
    }

    pub fn deinit(self: *Checkable) void {
        self.vtable.deinit(self.context, self.owner_allocator);
        self.* = undefined;
    }

    fn Adapter(comptime Rule: type) type {
        return struct {
            const vtable = VTable{
                .check = checkErased,
                .deinit = deinitErased,
            };

            fn checkErased(context: *anyopaque, options: CheckOptions) anyerror!ViolationList {
                const typed: *Rule = @ptrCast(@alignCast(context));
                return typed.check(options);
            }

            fn deinitErased(context: *anyopaque, allocator: Allocator) void {
                const typed: *Rule = @ptrCast(@alignCast(context));
                if (@hasDecl(Rule, "deinit")) typed.deinit(allocator);
                allocator.destroy(typed);
            }
        };
    }
};

/// Checks heterogeneous owned rules in order and moves their violations into one owned result.
/// The first technical/user error stops evaluation and destroys every already-produced violation.
pub fn checkAll(options: CheckOptions, rules: []Checkable) anyerror!ViolationList {
    var combined = ViolationList{};
    errdefer combined.deinit(options.allocator);

    for (rules) |*rule| {
        var current = try rule.check(options);
        defer current.deinit(options.allocator);
        try combined.appendListMove(options.allocator, &current);
    }
    return combined;
}

const TestBehavior = enum { pass, violate, fail };

fn TestRule(comptime behavior: TestBehavior) type {
    return struct {
        checks: *usize,
        deinits: *usize,
        observed_allow_empty: *bool,

        pub fn check(self: *@This(), options: CheckOptions) !ViolationList {
            self.checks.* += 1;
            self.observed_allow_empty.* = options.allow_empty_tests;
            if (behavior == .fail) return error.MockCheckFailed;
            if (behavior == .pass) return ViolationList{};

            var payload = try assertion.EmptyTestViolation.init(
                options.allocator,
                "mock.empty",
                &.{},
                false,
            );
            var violation = assertion.Violation.fromEmptyTestMove(&payload);
            var result = ViolationList{};
            result.appendMove(options.allocator, &violation) catch |err| {
                violation.deinit(options.allocator);
                return err;
            };
            return result;
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            _ = allocator;
            self.deinits.* += 1;
        }
    };
}

test "concrete terminal rule remains directly checkable" {
    var checks: usize = 0;
    var deinits: usize = 0;
    var observed_allow_empty = false;
    var rule = TestRule(.pass){
        .checks = &checks,
        .deinits = &deinits,
        .observed_allow_empty = &observed_allow_empty,
    };
    var result = try rule.check(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .allow_empty_tests = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passes());
    try std.testing.expectEqual(@as(usize, 1), checks);
    try std.testing.expect(observed_allow_empty);
    try std.testing.expectEqual(@as(usize, 0), deinits);
}

test "owned checkable invalidates source and releases boxed rule" {
    var checks: usize = 0;
    var deinits: usize = 0;
    var observed_allow_empty = false;
    var rule = TestRule(.pass){
        .checks = &checks,
        .deinits = &deinits,
        .observed_allow_empty = &observed_allow_empty,
    };
    var erased = try Checkable.fromMove(std.testing.allocator, &rule);
    var erased_is_owned = true;
    defer if (erased_is_owned) erased.deinit();
    var result = erased.check(CheckOptions.init(std.testing.allocator, std.testing.io)) catch |err| {
        erased.deinit();
        erased_is_owned = false;
        return err;
    };
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
    erased.deinit();
    erased_is_owned = false;
    try std.testing.expectEqual(@as(usize, 1), deinits);
}

test "heterogeneous rules return one clearly-owned violation list" {
    var pass_checks: usize = 0;
    var pass_deinits: usize = 0;
    var pass_allow_empty = false;
    var pass_rule = TestRule(.pass){
        .checks = &pass_checks,
        .deinits = &pass_deinits,
        .observed_allow_empty = &pass_allow_empty,
    };
    var pass = try Checkable.fromMove(std.testing.allocator, &pass_rule);

    var violation_checks: usize = 0;
    var violation_deinits: usize = 0;
    var violation_allow_empty = false;
    var violation_rule = TestRule(.violate){
        .checks = &violation_checks,
        .deinits = &violation_deinits,
        .observed_allow_empty = &violation_allow_empty,
    };
    var violating = Checkable.fromMove(std.testing.allocator, &violation_rule) catch |err| {
        pass.deinit();
        return err;
    };

    var rules = [_]Checkable{ pass, violating };
    pass = undefined;
    violating = undefined;
    defer for (&rules) |*rule| rule.deinit();

    var result = try checkAll(CheckOptions.init(std.testing.allocator, std.testing.io), &rules);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expect(!result.passes());
}

test "heterogeneous check stops and propagates rule errors" {
    var violation_checks: usize = 0;
    var violation_deinits: usize = 0;
    var violation_allow_empty = false;
    var violation_rule = TestRule(.violate){
        .checks = &violation_checks,
        .deinits = &violation_deinits,
        .observed_allow_empty = &violation_allow_empty,
    };
    var violating = try Checkable.fromMove(std.testing.allocator, &violation_rule);

    var failure_checks: usize = 0;
    var failure_deinits: usize = 0;
    var failure_allow_empty = false;
    var failure_rule = TestRule(.fail){
        .checks = &failure_checks,
        .deinits = &failure_deinits,
        .observed_allow_empty = &failure_allow_empty,
    };
    var failing = Checkable.fromMove(std.testing.allocator, &failure_rule) catch |err| {
        violating.deinit();
        return err;
    };

    var rules = [_]Checkable{ violating, failing };
    violating = undefined;
    failing = undefined;
    defer for (&rules) |*rule| rule.deinit();

    try std.testing.expectError(
        error.MockCheckFailed,
        checkAll(CheckOptions.init(std.testing.allocator, std.testing.io), &rules),
    );
    try std.testing.expectEqual(@as(usize, 1), failure_checks);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var checks: usize = 0;
    var deinits: usize = 0;
    var observed_allow_empty = false;
    var rule = TestRule(.violate){
        .checks = &checks,
        .deinits = &deinits,
        .observed_allow_empty = &observed_allow_empty,
    };
    var erased = try Checkable.fromMove(allocator, &rule);
    defer erased.deinit();

    var result = try erased.check(CheckOptions.init(allocator, std.testing.io));
    defer result.deinit(allocator);
    try std.testing.expect(!result.passes());
}

test "boxing and checking clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
