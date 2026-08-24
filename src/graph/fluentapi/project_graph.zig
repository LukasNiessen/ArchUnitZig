const std = @import("std");

const collapse_module = @import("../projection/collapse.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const pattern_module = @import("../../common/matching/pattern.zig");
const query_options = @import("../projection/query_options.zig");
const report = @import("../projection/report.zig");
const rendering = @import("../rendering/renderer.zig");
const snapshot_factory = @import("../projection/snapshot_factory.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = fluentapi.CheckOptions;
pub const Graph = extraction.Graph;
pub const GraphQueryOptions = query_options.GraphQueryOptions;
pub const GraphReportSnapshot = report.GraphReportSnapshot;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;

pub const BuilderError = Allocator.Error || pattern_module.CompileError || collapse_module.CollapseError || error{
    InvalidPattern,
    ExclusionWithoutSelector,
    InvalidExclusionTarget,
    InvalidProjectPath,
    InvalidTitle,
};

pub const ProjectGraphOptions = struct {
    locator: ?[]const u8 = null,
    query: GraphQueryOptions = .{},
};

/// Owned immutable-in-behavior builder. Each modifier returns an independent value.
pub const ProjectGraphBuilder = struct {
    allocator: Allocator,
    project_locator: ?[]u8,
    include_external_dependencies: bool,
    include_self_dependencies: bool,
    focus: ?OwnedFocus,
    focus_exclusions: OwnedExclusions = .{},
    reachable_from: ?OwnedPattern,
    reachable_from_exclusions: OwnedExclusions = .{},
    dependents_of: ?OwnedPattern,
    dependents_of_exclusions: OwnedExclusions = .{},
    collapse: ?OwnedCollapse,
    title: []u8,
    last_query: ?QueryKind = null,

    fn init(allocator: Allocator, options: ProjectGraphOptions) BuilderError!ProjectGraphBuilder {
        if (options.locator) |locator| {
            if (!containsNonWhitespace(locator)) return error.InvalidProjectPath;
        }
        if (!containsNonWhitespace(options.query.title)) return error.InvalidTitle;
        if ((options.query.focus == null and options.query.focus_exclusions.len != 0) or
            (options.query.reachable_from == null and options.query.reachable_from_exclusions.len != 0) or
            (options.query.dependents_of == null and options.query.dependents_of_exclusions.len != 0))
        {
            return error.ExclusionWithoutSelector;
        }

        var result: ProjectGraphBuilder = result: {
            const project_locator = if (options.locator) |locator| try allocator.dupe(u8, locator) else null;
            errdefer if (project_locator) |locator| allocator.free(locator);
            const title = try allocator.dupe(u8, options.query.title);
            errdefer allocator.free(title);
            break :result .{
                .allocator = allocator,
                .project_locator = project_locator,
                .include_external_dependencies = options.query.include_external_dependencies,
                .include_self_dependencies = options.query.include_self_dependencies,
                .focus = null,
                .reachable_from = null,
                .dependents_of = null,
                .collapse = null,
                .title = title,
            };
        };
        errdefer result.deinit();
        if (options.query.focus) |focus| result.focus = .{
            .pattern = try OwnedPattern.init(allocator, focus.pattern),
            .depth = focus.depth,
        };
        try result.focus_exclusions.initFrom(allocator, options.query.focus_exclusions);
        if (options.query.reachable_from) |pattern| {
            result.reachable_from = try OwnedPattern.init(allocator, pattern);
        }
        try result.reachable_from_exclusions.initFrom(allocator, options.query.reachable_from_exclusions);
        if (options.query.dependents_of) |pattern| {
            result.dependents_of = try OwnedPattern.init(allocator, pattern);
        }
        try result.dependents_of_exclusions.initFrom(allocator, options.query.dependents_of_exclusions);
        if (options.query.collapse) |collapse| {
            var validator = try collapse_module.Collapser.init(allocator, collapse);
            defer validator.deinit();
            result.collapse = try OwnedCollapse.init(allocator, collapse);
        }
        return result;
    }

    pub fn clone(self: *const ProjectGraphBuilder) BuilderError!ProjectGraphBuilder {
        var result = try init(self.allocator, .{
            .locator = self.project_locator,
            .query = self.queryOptions(),
        });
        result.last_query = self.last_query;
        return result;
    }

    pub fn deinit(self: *ProjectGraphBuilder) void {
        if (self.project_locator) |locator| self.allocator.free(locator);
        if (self.focus) |*focus| focus.pattern.deinit(self.allocator);
        self.focus_exclusions.deinit(self.allocator);
        if (self.reachable_from) |*pattern| pattern.deinit(self.allocator);
        self.reachable_from_exclusions.deinit(self.allocator);
        if (self.dependents_of) |*pattern| pattern.deinit(self.allocator);
        self.dependents_of_exclusions.deinit(self.allocator);
        if (self.collapse) |*collapse| collapse.deinit(self.allocator);
        self.allocator.free(self.title);
        self.* = undefined;
    }

    pub fn includeExternalDependencies(self: *const ProjectGraphBuilder) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.include_external_dependencies = true;
        return init(self.allocator, .{ .locator = self.project_locator, .query = query });
    }

    pub fn includeSelfDependencies(self: *const ProjectGraphBuilder) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.include_self_dependencies = true;
        return init(self.allocator, .{ .locator = self.project_locator, .query = query });
    }

    pub fn focusOn(
        self: *const ProjectGraphBuilder,
        pattern: Pattern,
        depth: usize,
    ) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.focus = .{ .pattern = pattern, .depth = depth };
        query.focus_exclusions = &.{};
        var result = try init(self.allocator, .{ .locator = self.project_locator, .query = query });
        result.last_query = .focus;
        return result;
    }

    pub fn reachableFrom(self: *const ProjectGraphBuilder, pattern: Pattern) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.reachable_from = pattern;
        query.reachable_from_exclusions = &.{};
        var result = try init(self.allocator, .{ .locator = self.project_locator, .query = query });
        result.last_query = .reachable_from;
        return result;
    }

    pub fn dependentsOf(self: *const ProjectGraphBuilder, pattern: Pattern) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.dependents_of = pattern;
        query.dependents_of_exclusions = &.{};
        var result = try init(self.allocator, .{ .locator = self.project_locator, .query = query });
        result.last_query = .dependents_of;
        return result;
    }

    pub fn except(
        self: *const ProjectGraphBuilder,
        patterns: []const Pattern,
    ) BuilderError!ProjectGraphBuilder {
        return self.excludePatterns(patterns, .path);
    }

    pub fn exceptTargeted(
        self: *const ProjectGraphBuilder,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!ProjectGraphBuilder {
        if (target == .declaration_name) return error.InvalidExclusionTarget;
        return self.excludePatterns(patterns, target);
    }

    fn excludePatterns(
        self: *const ProjectGraphBuilder,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!ProjectGraphBuilder {
        const query_kind = self.last_query orelse return error.ExclusionWithoutSelector;
        if (patterns.len == 0) return error.InvalidPattern;
        var result = try self.clone();
        errdefer result.deinit();
        switch (query_kind) {
            .focus => try result.focus_exclusions.append(result.allocator, patterns, target),
            .reachable_from => try result.reachable_from_exclusions.append(result.allocator, patterns, target),
            .dependents_of => try result.dependents_of_exclusions.append(result.allocator, patterns, target),
        }
        return result;
    }

    pub fn collapseToFolderDepth(
        self: *const ProjectGraphBuilder,
        depth: usize,
    ) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.collapse = .{ .folder_depth = depth };
        return init(self.allocator, .{ .locator = self.project_locator, .query = query });
    }

    pub fn collapseByPattern(
        self: *const ProjectGraphBuilder,
        expression: []const u8,
        replacement: []const u8,
    ) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.collapse = .{ .pattern = .{
            .expression = expression,
            .replacement = replacement,
        } };
        return init(self.allocator, .{ .locator = self.project_locator, .query = query });
    }

    pub fn titled(self: *const ProjectGraphBuilder, title: []const u8) BuilderError!ProjectGraphBuilder {
        var query = self.queryOptions();
        query.title = title;
        return init(self.allocator, .{ .locator = self.project_locator, .query = query });
    }

    /// Extracts lazily using the supplied per-check options. The returned snapshot belongs to the
    /// check allocator, not the allocator that stores this builder.
    pub fn snapshot(
        self: *const ProjectGraphBuilder,
        options: CheckOptions,
    ) anyerror!GraphReportSnapshot {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var graph = try extraction.extractProjectGraphLogged(
            options.allocator,
            options.io,
            self.project_locator,
            options.working_directory,
            options.extraction,
            options.clear_cache,
            &diagnostics,
            options.logger,
        );
        defer graph.deinit(options.allocator);
        return snapshot_factory.createSnapshot(options.allocator, &graph, self.queryOptions());
    }

    pub fn summary(
        self: *const ProjectGraphBuilder,
        options: CheckOptions,
    ) anyerror!report.GraphReportSummary {
        var report_snapshot = try self.snapshot(options);
        defer report_snapshot.deinit(options.allocator);
        return report_snapshot.summary;
    }

    pub fn render(
        self: *const ProjectGraphBuilder,
        options: CheckOptions,
        format: rendering.GraphReportFormat,
    ) anyerror![]u8 {
        var report_snapshot = try self.snapshot(options);
        defer report_snapshot.deinit(options.allocator);
        return rendering.GraphRenderer.render(options.allocator, &report_snapshot, format);
    }

    pub fn exportReport(
        self: *const ProjectGraphBuilder,
        options: CheckOptions,
        format: rendering.GraphReportFormat,
        output_path: []const u8,
    ) anyerror!void {
        var report_snapshot = try self.snapshot(options);
        defer report_snapshot.deinit(options.allocator);
        return rendering.GraphRenderer.exportReport(
            options.allocator,
            options.io,
            &report_snapshot,
            format,
            output_path,
        );
    }

    pub fn toDot(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .dot);
    }

    pub fn toMermaid(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .mermaid);
    }

    pub fn toD2(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .d2);
    }

    pub fn toCsv(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .csv);
    }

    pub fn toJson(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .json);
    }

    pub fn toHtml(self: *const ProjectGraphBuilder, options: CheckOptions) anyerror![]u8 {
        return self.render(options, .html);
    }

    pub fn exportAsDot(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .dot, path);
    }

    pub fn exportAsMermaid(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .mermaid, path);
    }

    pub fn exportAsD2(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .d2, path);
    }

    pub fn exportAsCsv(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .csv, path);
    }

    pub fn exportAsJson(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .json, path);
    }

    pub fn exportAsHtml(self: *const ProjectGraphBuilder, options: CheckOptions, path: []const u8) anyerror!void {
        return self.exportReport(options, .html, path);
    }

    pub fn queryOptions(self: *const ProjectGraphBuilder) GraphQueryOptions {
        return .{
            .include_external_dependencies = self.include_external_dependencies,
            .include_self_dependencies = self.include_self_dependencies,
            .focus = if (self.focus) |focus| .{
                .pattern = focus.pattern.borrowed(),
                .depth = focus.depth,
            } else null,
            .focus_exclusions = self.focus_exclusions.items(),
            .reachable_from = if (self.reachable_from) |pattern| pattern.borrowed() else null,
            .reachable_from_exclusions = self.reachable_from_exclusions.items(),
            .dependents_of = if (self.dependents_of) |pattern| pattern.borrowed() else null,
            .dependents_of_exclusions = self.dependents_of_exclusions.items(),
            .collapse = if (self.collapse) |collapse| collapse.borrowed() else null,
            .title = self.title,
        };
    }
};

const QueryKind = enum { focus, reachable_from, dependents_of };

const OwnedPatternExclusion = struct {
    pattern: OwnedPattern,
    target: PatternTarget,

    fn init(
        allocator: Allocator,
        exclusion: query_options.PatternExclusion,
    ) BuilderError!OwnedPatternExclusion {
        if (exclusion.target == .declaration_name) return error.InvalidExclusionTarget;
        return .{
            .pattern = try OwnedPattern.init(allocator, exclusion.pattern),
            .target = exclusion.target,
        };
    }

    fn deinit(self: *OwnedPatternExclusion, allocator: Allocator) void {
        self.pattern.deinit(allocator);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedPatternExclusion) query_options.PatternExclusion {
        return .{ .pattern = self.pattern.borrowed(), .target = self.target };
    }
};

const OwnedExclusions = struct {
    values: std.ArrayList(OwnedPatternExclusion) = .empty,
    borrowed_values: std.ArrayList(query_options.PatternExclusion) = .empty,

    fn initFrom(
        self: *OwnedExclusions,
        allocator: Allocator,
        exclusions: []const query_options.PatternExclusion,
    ) BuilderError!void {
        try self.values.ensureTotalCapacity(allocator, exclusions.len);
        for (exclusions) |exclusion| {
            self.values.appendAssumeCapacity(try OwnedPatternExclusion.init(allocator, exclusion));
        }
        try self.refreshBorrowed(allocator);
    }

    fn append(
        self: *OwnedExclusions,
        allocator: Allocator,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!void {
        try self.values.ensureUnusedCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            self.values.appendAssumeCapacity(try OwnedPatternExclusion.init(allocator, .{
                .pattern = pattern,
                .target = target,
            }));
        }
        try self.refreshBorrowed(allocator);
    }

    fn refreshBorrowed(self: *OwnedExclusions, allocator: Allocator) Allocator.Error!void {
        self.borrowed_values.clearRetainingCapacity();
        try self.borrowed_values.ensureTotalCapacity(allocator, self.values.items.len);
        for (self.values.items) |*value| self.borrowed_values.appendAssumeCapacity(value.borrowed());
    }

    fn items(self: *const OwnedExclusions) []const query_options.PatternExclusion {
        return self.borrowed_values.items;
    }

    fn deinit(self: *OwnedExclusions, allocator: Allocator) void {
        self.borrowed_values.deinit(allocator);
        for (self.values.items) |*value| value.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }
};

const OwnedFocus = struct {
    pattern: OwnedPattern,
    depth: usize,
};

const OwnedPattern = struct {
    syntax: matching.PatternSyntax,
    expression: []u8,

    fn init(allocator: Allocator, pattern: Pattern) BuilderError!OwnedPattern {
        if (pattern.source().len == 0) return error.InvalidPattern;
        var compiled = try pattern.compile(allocator);
        defer compiled.deinit();
        return .{
            .syntax = pattern.syntax(),
            .expression = try allocator.dupe(u8, pattern.source()),
        };
    }

    fn deinit(self: *OwnedPattern, allocator: Allocator) void {
        allocator.free(self.expression);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedPattern) Pattern {
        return switch (self.syntax) {
            .glob => .{ .glob = self.expression },
            .regex => .{ .regex = self.expression },
            .literal => unreachable,
        };
    }
};

const OwnedCollapse = union(enum) {
    folder_depth: usize,
    pattern: OwnedPatternCollapse,

    const OwnedPatternCollapse = struct {
        expression: []u8,
        replacement: []u8,
    };

    fn init(allocator: Allocator, collapse: query_options.CollapseQuery) Allocator.Error!OwnedCollapse {
        return switch (collapse) {
            .folder_depth => |depth| .{ .folder_depth = depth },
            .pattern => |pattern| blk: {
                const expression = try allocator.dupe(u8, pattern.expression);
                errdefer allocator.free(expression);
                break :blk .{ .pattern = .{
                    .expression = expression,
                    .replacement = try allocator.dupe(u8, pattern.replacement),
                } };
            },
        };
    }

    fn deinit(self: *OwnedCollapse, allocator: Allocator) void {
        switch (self.*) {
            .folder_depth => {},
            .pattern => |pattern| {
                allocator.free(pattern.expression);
                allocator.free(pattern.replacement);
            },
        }
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedCollapse) query_options.CollapseQuery {
        return switch (self.*) {
            .folder_depth => |depth| .{ .folder_depth = depth },
            .pattern => |pattern| .{ .pattern = .{
                .expression = pattern.expression,
                .replacement = pattern.replacement,
            } },
        };
    }
};

pub fn projectGraph(allocator: Allocator, options: ProjectGraphOptions) BuilderError!ProjectGraphBuilder {
    return ProjectGraphBuilder.init(allocator, options);
}

pub fn dependencyGraph(allocator: Allocator, options: ProjectGraphOptions) BuilderError!ProjectGraphBuilder {
    return projectGraph(allocator, options);
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "graph builder modifiers are owned and branchable" {
    var base = try projectGraph(std.testing.allocator, .{ .locator = "fixture" });
    defer base.deinit();
    var pattern_buffer = [_]u8{ 's', 'r', 'c', '/', '*', '*' };
    var focused = try base.focusOn(.{ .glob = &pattern_buffer }, 2);
    defer focused.deinit();
    @memset(&pattern_buffer, 'x');
    var external = try focused.includeExternalDependencies();
    defer external.deinit();
    var titled_builder = try external.titled("Architecture");
    defer titled_builder.deinit();

    try std.testing.expect(base.queryOptions().focus == null);
    try std.testing.expect(!focused.queryOptions().include_external_dependencies);
    try std.testing.expect(external.queryOptions().include_external_dependencies);
    try std.testing.expectEqualStrings("src/**", focused.queryOptions().focus.?.pattern.source());
    try std.testing.expectEqualStrings("Project dependency graph", external.queryOptions().title);
    try std.testing.expectEqualStrings("Architecture", titled_builder.queryOptions().title);

    var cloned = try titled_builder.clone();
    defer cloned.deinit();
    try std.testing.expectEqualStrings("Architecture", cloned.queryOptions().title);
    try std.testing.expect(cloned.title.ptr != titled_builder.title.ptr);
}

test "graph exclusions attach only to the immediately preceding query and own patterns" {
    var base = try projectGraph(std.testing.allocator, .{});
    defer base.deinit();
    try std.testing.expectError(error.ExclusionWithoutSelector, base.except(&.{.{ .glob = "generated/**" }}));
    var focused = try base.focusOn(.{ .glob = "src/**" }, 1);
    defer focused.deinit();
    var generated_pattern = [_]u8{ 's', 'r', 'c', '/', '*', '*', '/', 'g', 'e', 'n', 'e', 'r', 'a', 't', 'e', 'd', '/', '*', '*' };
    var no_generated = try focused.except(&.{.{ .glob = &generated_pattern }});
    defer no_generated.deinit();
    @memset(&generated_pattern, 'x');
    var production = try no_generated.exceptTargeted(&.{.{ .regex = "_test\\.zig$" }}, .filename);
    defer production.deinit();
    try std.testing.expectEqual(@as(usize, 2), production.queryOptions().focus_exclusions.len);
    try std.testing.expectEqualStrings(
        "src/**/generated/**",
        production.queryOptions().focus_exclusions[0].pattern.source(),
    );

    var reachable = try production.reachableFrom(.{ .glob = "src/root.zig" });
    defer reachable.deinit();
    var without_generated_roots = try reachable.exceptTargeted(
        &.{.{ .glob = "root.zig" }},
        .filename,
    );
    defer without_generated_roots.deinit();
    try std.testing.expectEqual(@as(usize, 2), without_generated_roots.queryOptions().focus_exclusions.len);
    try std.testing.expectEqual(@as(usize, 1), without_generated_roots.queryOptions().reachable_from_exclusions.len);

    var titled_builder = try production.titled("Filtered graph");
    defer titled_builder.deinit();
    try std.testing.expectError(
        error.ExclusionWithoutSelector,
        titled_builder.except(&.{.{ .glob = "late/**" }}),
    );
    try std.testing.expectError(
        error.InvalidExclusionTarget,
        focused.exceptTargeted(&.{.{ .glob = "Legacy" }}, .declaration_name),
    );
}

test "all modifiers compose and the dependency graph alias has the same entry contract" {
    var base = try dependencyGraph(std.testing.allocator, .{});
    defer base.deinit();
    var self_edges = try base.includeSelfDependencies();
    defer self_edges.deinit();
    var reachable = try self_edges.reachableFrom(.{ .glob = "src/app/**" });
    defer reachable.deinit();
    var dependents = try reachable.dependentsOf(.{ .regex = "domain" });
    defer dependents.deinit();
    var folder = try dependents.collapseToFolderDepth(2);
    defer folder.deinit();
    var pattern = try folder.collapseByPattern("^src/([^/]+)$", "$1");
    defer pattern.deinit();

    const options = pattern.queryOptions();
    try std.testing.expect(options.include_self_dependencies);
    try std.testing.expect(options.reachable_from != null);
    try std.testing.expect(options.dependents_of != null);
    try std.testing.expect(options.collapse.? == .pattern);
}

test "builder validates project title patterns folder depth and replacements early" {
    try std.testing.expectError(
        error.InvalidProjectPath,
        projectGraph(std.testing.allocator, .{ .locator = " \t" }),
    );
    var base = try projectGraph(std.testing.allocator, .{});
    defer base.deinit();
    const orphan_exclusion = [_]query_options.PatternExclusion{.{
        .pattern = .{ .glob = "generated/**" },
        .target = .path,
    }};
    try std.testing.expectError(error.ExclusionWithoutSelector, projectGraph(std.testing.allocator, .{
        .query = .{ .focus_exclusions = &orphan_exclusion },
    }));
    try std.testing.expectError(error.InvalidTitle, base.titled("\n"));
    try std.testing.expectError(error.InvalidPattern, base.focusOn(.{ .glob = "" }, 1));
    try std.testing.expectError(error.MissingParen, base.reachableFrom(.{ .regex = "(" }));
    try std.testing.expectError(error.InvalidFolderDepth, base.collapseToFolderDepth(0));
    try std.testing.expectError(
        error.InvalidCollapseReplacement,
        base.collapseByPattern("(src)", "$2"),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var base = try projectGraph(allocator, .{ .locator = "fixture" });
    defer base.deinit();
    var focused = try base.focusOn(.{ .regex = "src/(app|domain)" }, 2);
    defer focused.deinit();
    var production = try focused.except(&.{.{ .glob = "src/generated/**" }});
    defer production.deinit();
    var reachable = try production.reachableFrom(.{ .glob = "src/app/**" });
    defer reachable.deinit();
    var current = try reachable.exceptTargeted(&.{.{ .regex = "_generated\\.zig$" }}, .filename);
    defer current.deinit();
    var collapsed = try current.collapseByPattern("^src/([^/]+)/.*$", "$1");
    defer collapsed.deinit();
    var titled_builder = try collapsed.titled("Allocation-safe graph");
    defer titled_builder.deinit();
    var cloned = try titled_builder.clone();
    defer cloned.deinit();
}

test "graph builder chains and clones clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

fn findSnapshotEdge(
    snapshot_value: *const GraphReportSnapshot,
    source: []const u8,
    target: []const u8,
) ?*const report.GraphReportEdge {
    for (snapshot_value.edges) |*edge| {
        if (std.mem.eql(u8, edge.source, source) and std.mem.eql(u8, edge.target, target)) return edge;
    }
    return null;
}

test "real Zig fixture extracts focus external compiler and resource nodes lazily" {
    var base = try projectGraph(std.testing.allocator, .{ .locator = "test/fixtures/graph-basic" });
    defer base.deinit();
    var focused = try base.focusOn(.{ .glob = "src/app/main.zig" }, 1);
    defer focused.deinit();
    var external = try focused.includeExternalDependencies();
    defer external.deinit();
    var titled_builder = try external.titled("Fixture Architecture");
    defer titled_builder.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var snapshot_value = try titled_builder.snapshot(options);
    defer snapshot_value.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Fixture Architecture", snapshot_value.title);
    try std.testing.expectEqual(@as(usize, 5), snapshot_value.summary.node_count);
    try std.testing.expectEqual(@as(usize, 4), snapshot_value.summary.edge_count);
    try std.testing.expectEqual(@as(usize, 4), snapshot_value.summary.raw_edge_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot_value.summary.external_edge_count);
    try std.testing.expectEqualStrings("assets/settings.json", snapshot_value.nodes[0].label);
    try std.testing.expectEqualStrings("src/app/main.zig", snapshot_value.nodes[1].label);
    try std.testing.expectEqualStrings("src/domain/service.zig", snapshot_value.nodes[2].label);
    try std.testing.expectEqualStrings("src/root.zig", snapshot_value.nodes[3].label);
    try std.testing.expectEqualStrings("std", snapshot_value.nodes[4].label);

    const resource = findSnapshotEdge(&snapshot_value, "src/app/main.zig", "assets/settings.json").?;
    try std.testing.expect(resource.target_classes.contains(.resource));
    try std.testing.expect(resource.import_kinds.contains(.embedded_file));
    const compiler = findSnapshotEdge(&snapshot_value, "src/app/main.zig", "std").?;
    try std.testing.expect(compiler.external);
    try std.testing.expect(compiler.target_classes.contains(.compiler));
}

test "real graph fixture excludes focused filenames before snapshot projection" {
    var base = try projectGraph(std.testing.allocator, .{ .locator = "test/fixtures/graph-basic" });
    defer base.deinit();
    var focused = try base.focusOn(.{ .glob = "src/**" }, 0);
    defer focused.deinit();
    var without_main = try focused.exceptTargeted(&.{.{ .glob = "main.zig" }}, .filename);
    defer without_main.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var snapshot_value = try without_main.snapshot(options);
    defer snapshot_value.deinit(std.testing.allocator);
    for (snapshot_value.nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.label, "src/app/main.zig"));
    }
    try std.testing.expect(snapshot_value.summary.node_count > 0);
}

test "real fixture composes extraction options with collapse aggregation and summary" {
    var base = try projectGraph(std.testing.allocator, .{ .locator = "test/fixtures/graph-basic" });
    defer base.deinit();
    var external = try base.includeExternalDependencies();
    defer external.deinit();
    var collapsed = try external.collapseToFolderDepth(2);
    defer collapsed.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var snapshot_value = try collapsed.snapshot(options);
    defer snapshot_value.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), snapshot_value.summary.node_count);
    try std.testing.expectEqual(@as(usize, 4), snapshot_value.summary.edge_count);
    try std.testing.expectEqual(@as(usize, 6), snapshot_value.summary.raw_edge_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot_value.summary.external_edge_count);
    try std.testing.expectEqual(
        @as(usize, 2),
        findSnapshotEdge(&snapshot_value, "src/app", "src/domain").?.count,
    );
    try std.testing.expect(findSnapshotEdge(&snapshot_value, "src/domain", "src/domain") == null);
    try std.testing.expectEqual(snapshot_value.summary, try collapsed.summary(options));

    options.clear_cache = true;
    options.extraction.include_resources = false;
    var without_resources = try external.snapshot(options);
    defer without_resources.deinit(std.testing.allocator);
    try std.testing.expect(findSnapshotEdge(
        &without_resources,
        "src/app/main.zig",
        "assets/settings.json",
    ) == null);
    try std.testing.expectEqual(@as(usize, 5), without_resources.summary.raw_edge_count);
}

test "real fixture fluent render and export terminals share the snapshot contract" {
    var base = try projectGraph(std.testing.allocator, .{ .locator = "test/fixtures/graph-basic" });
    defer base.deinit();
    var external = try base.includeExternalDependencies();
    defer external.deinit();
    var titled_builder = try external.titled("Fixture Graph");
    defer titled_builder.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    const json = try titled_builder.toJson(options);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Fixture Graph", parsed.value.object.get("title").?.string);
    try std.testing.expect(parsed.value.object.get("nodes").?.array.items.len > 0);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const output_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "reports", "architecture.html" },
    );
    defer std.testing.allocator.free(output_path);
    options.clear_cache = false;
    try titled_builder.exportAsHtml(options, output_path);
    const exported = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        output_path,
        std.testing.allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(exported);
    const expected = try titled_builder.toHtml(options);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, exported);
}
