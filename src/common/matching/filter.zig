const std = @import("std");

const common_path = @import("../path.zig");
const pattern_module = @import("pattern.zig");
const pattern_target = @import("pattern_target.zig");
const regex_factory = @import("regex_factory.zig");

const Allocator = std.mem.Allocator;
pub const MatchingMode = pattern_target.MatchingMode;
pub const Pattern = pattern_module.Pattern;
pub const PatternTarget = pattern_target.PatternTarget;

pub const Candidate = struct {
    path: []const u8,
    declaration_name: ?[]const u8 = null,
};

pub const MatchError = std.mem.Allocator.Error || error{MissingDeclarationName};

/// An owned compiled pattern, its candidate field, and any exclusions qualifying this pattern.
/// Exclusions are alternatives: a positive match is rejected when any exclusion matches.
pub const Filter = struct {
    allocator: Allocator,
    matcher: regex_factory.RegexMatcher,
    exclusions: std.ArrayList(Filter) = .empty,

    pub fn init(
        allocator: Allocator,
        pattern: Pattern,
        pattern_target_value: PatternTarget,
        matching_mode: MatchingMode,
    ) pattern_module.CompileError!Filter {
        return .{ .allocator = allocator, .matcher = .{
            .regex = try pattern.compile(allocator),
            .target = pattern_target_value,
            .matching = matching_mode,
        } };
    }

    pub fn deinit(self: *Filter) void {
        for (self.exclusions.items) |*exclusion| exclusion.deinit();
        self.exclusions.deinit(self.allocator);
        self.matcher.deinit();
        self.* = undefined;
    }

    pub fn clone(self: *const Filter, allocator: Allocator) pattern_module.CompileError!Filter {
        var result = Filter{
            .allocator = allocator,
            .matcher = try regex_factory.RegexMatcher.compile(
                allocator,
                self.matcher.regex.source(),
                self.target(),
                self.matching(),
            ),
        };
        errdefer result.deinit();
        try result.exclusions.ensureTotalCapacity(allocator, self.exclusions.items.len);
        for (self.exclusions.items) |*exclusion| {
            result.exclusions.appendAssumeCapacity(try exclusion.clone(allocator));
        }
        return result;
    }

    pub fn appendExclusionMove(self: *Filter, exclusion: *Filter) Allocator.Error!void {
        try self.exclusions.append(self.allocator, exclusion.*);
        exclusion.* = undefined;
    }

    pub fn addExclusion(
        self: *Filter,
        pattern: Pattern,
        target_value: PatternTarget,
        matching_mode: MatchingMode,
    ) pattern_module.CompileError!void {
        var exclusion = try Filter.init(self.allocator, pattern, target_value, matching_mode);
        self.appendExclusionMove(&exclusion) catch |failure| {
            exclusion.deinit();
            return failure;
        };
    }

    pub fn exclusionCount(self: *const Filter) usize {
        return self.exclusions.items.len;
    }

    pub fn target(self: *const Filter) PatternTarget {
        return self.matcher.target;
    }

    pub fn matching(self: *const Filter) MatchingMode {
        return self.matcher.matching;
    }

    pub fn matches(
        self: *const Filter,
        allocator: Allocator,
        candidate: Candidate,
    ) MatchError!bool {
        if (!try self.matchesOwn(allocator, candidate)) return false;
        for (self.exclusions.items) |*exclusion| {
            const excluded = exclusion.matches(allocator, candidate) catch |failure| switch (failure) {
                error.MissingDeclarationName => false,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (excluded) return false;
        }
        return true;
    }

    fn matchesOwn(
        self: *const Filter,
        allocator: Allocator,
        candidate: Candidate,
    ) MatchError!bool {
        if (self.target() == .declaration_name) {
            const name = candidate.declaration_name orelse return error.MissingDeclarationName;
            return self.matcher.matches(allocator, name);
        }

        const normalized = try common_path.normalize(allocator, candidate.path);
        defer allocator.free(normalized);
        const selected = selectPathTarget(normalized, self.target());
        return self.matcher.matches(allocator, selected);
    }
};

fn selectPathTarget(normalized_path: []const u8, target: PatternTarget) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, normalized_path, '/');
    return switch (target) {
        .filename => if (separator) |index| normalized_path[index + 1 ..] else normalized_path,
        .path => normalized_path,
        .path_without_filename => if (separator) |index| normalized_path[0..index] else ".",
        .declaration_name => unreachable,
    };
}

/// All filters in a selector are alternatives (OR).
pub fn matchesAny(
    allocator: Allocator,
    candidate: Candidate,
    filters: []const Filter,
) MatchError!bool {
    for (filters) |*filter| {
        if (try filter.matches(allocator, candidate)) return true;
    }
    return false;
}

/// Independent selector calls are cumulative (AND), while each selector's filters are alternatives
/// (OR). An empty list of selector calls therefore matches every candidate.
pub fn matchesSelectors(
    allocator: Allocator,
    candidate: Candidate,
    selectors: []const []const Filter,
) MatchError!bool {
    for (selectors) |filters| {
        if (!try matchesAny(allocator, candidate, filters)) return false;
    }
    return true;
}

test "filter selects normalized filename path and folder targets" {
    var filename = try Filter.init(
        std.testing.allocator,
        .{ .glob = "service.zig" },
        .filename,
        .partial,
    );
    defer filename.deinit();
    var path = try Filter.init(
        std.testing.allocator,
        .{ .glob = "src/domain/*.zig" },
        .path,
        .partial,
    );
    defer path.deinit();
    var folder = try Filter.init(
        std.testing.allocator,
        .{ .glob = "src/domain" },
        .path_without_filename,
        .partial,
    );
    defer folder.deinit();
    const candidate = Candidate{ .path = "src\\\\domain\\service.zig" };

    try std.testing.expect(try filename.matches(std.testing.allocator, candidate));
    try std.testing.expect(try path.matches(std.testing.allocator, candidate));
    try std.testing.expect(try folder.matches(std.testing.allocator, candidate));
}

test "a root-level file has the conventional dot folder" {
    var folder = try Filter.init(
        std.testing.allocator,
        .{ .glob = "." },
        .path_without_filename,
        .partial,
    );
    defer folder.deinit();

    try std.testing.expect(try folder.matches(
        std.testing.allocator,
        .{ .path = "build.zig" },
    ));
}

test "declaration target requires and selects a declaration name" {
    var filter = try Filter.init(
        std.testing.allocator,
        .{ .glob = "*Service" },
        .declaration_name,
        .partial,
    );
    defer filter.deinit();

    try std.testing.expectError(
        error.MissingDeclarationName,
        filter.matches(std.testing.allocator, .{ .path = "src/order.zig" }),
    );
    try std.testing.expect(try filter.matches(std.testing.allocator, .{
        .path = "src/order.zig",
        .declaration_name = "OrderService",
    }));
}

test "regular-expression filters distinguish partial and exact matching" {
    var partial = try Filter.init(
        std.testing.allocator,
        .{ .regex = "service" },
        .filename,
        .partial,
    );
    defer partial.deinit();
    var exact = try Filter.init(
        std.testing.allocator,
        .{ .regex = "service" },
        .filename,
        .exact,
    );
    defer exact.deinit();

    try std.testing.expect(try partial.matches(
        std.testing.allocator,
        .{ .path = "src/order_service.zig" },
    ));
    try std.testing.expect(!try exact.matches(
        std.testing.allocator,
        .{ .path = "src/order_service.zig" },
    ));
    try std.testing.expect(try exact.matches(
        std.testing.allocator,
        .{ .path = "src/service" },
    ));
}

test "patterns within selectors use OR and selector calls use AND" {
    var zig_name = try Filter.init(std.testing.allocator, .{ .glob = "*.zig" }, .filename, .partial);
    defer zig_name.deinit();
    var zon_name = try Filter.init(std.testing.allocator, .{ .glob = "*.zon" }, .filename, .partial);
    defer zon_name.deinit();
    var source_path = try Filter.init(std.testing.allocator, .{ .glob = "src/**" }, .path, .partial);
    defer source_path.deinit();
    var test_path = try Filter.init(std.testing.allocator, .{ .glob = "test/**" }, .path, .partial);
    defer test_path.deinit();

    const extensions = [_]Filter{ zig_name, zon_name };
    const source_or_test = [_]Filter{ source_path, test_path };
    const selectors = [_][]const Filter{ &extensions, &source_or_test };

    try std.testing.expect(try matchesSelectors(
        std.testing.allocator,
        .{ .path = "src/domain/model.zig" },
        &selectors,
    ));
    try std.testing.expect(!try matchesSelectors(
        std.testing.allocator,
        .{ .path = "docs/model.zig" },
        &selectors,
    ));
    try std.testing.expect(try matchesSelectors(
        std.testing.allocator,
        .{ .path = "anything" },
        &.{},
    ));
    try std.testing.expect(!try matchesAny(
        std.testing.allocator,
        .{ .path = "anything" },
        &.{},
    ));
}

test "filter exclusions are OR alternatives applied after the positive match" {
    var filter = try Filter.init(std.testing.allocator, .{ .glob = "src/**" }, .path, .exact);
    defer filter.deinit();
    try filter.addExclusion(.{ .glob = "src/**/generated/**" }, .path, .exact);
    try filter.addExclusion(.{ .regex = "_generated\\.zig$" }, .filename, .partial);

    try std.testing.expect(try filter.matches(
        std.testing.allocator,
        .{ .path = "src/domain/service.zig" },
    ));
    try std.testing.expect(!try filter.matches(
        std.testing.allocator,
        .{ .path = "src/domain/generated/deep/model.zig" },
    ));
    try std.testing.expect(!try filter.matches(
        std.testing.allocator,
        .{ .path = "src/domain/model_generated.zig" },
    ));
    try std.testing.expect(!try filter.matches(
        std.testing.allocator,
        .{ .path = "test/domain/service.zig" },
    ));
}

test "filter clones own independent compiled exclusions" {
    var filter = try Filter.init(std.testing.allocator, .{ .glob = "src/**" }, .path, .exact);
    defer filter.deinit();
    try filter.addExclusion(.{ .glob = "src/generated/**" }, .path, .exact);
    var cloned = try filter.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(@as(usize, 1), cloned.exclusionCount());
    try std.testing.expect(!try cloned.matches(
        std.testing.allocator,
        .{ .path = "src/generated/file.zig" },
    ));
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var filter = try Filter.init(allocator, .{ .glob = "src/**/*.zig" }, .path, .partial);
    defer filter.deinit();
    try filter.addExclusion(.{ .regex = "generated" }, .path, .partial);
    var cloned = try filter.clone(allocator);
    defer cloned.deinit();
    try std.testing.expect(try filter.matches(allocator, .{ .path = "src\\domain\\model.zig" }));
}

test "filter compilation and matching clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
