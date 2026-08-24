const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const diagram_assertion = @import("../assertion/diagram_adherence.zig");
const slice_assertion = @import("../assertion/slice_dependency.zig");
const slice_projection = @import("../projection/slice_projection.zig");
const plantuml = @import("../uml/plantuml.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = fluentapi.CheckOptions;
pub const Graph = extraction.Graph;
pub const Mood = assertion.Mood;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const SliceProjection = slice_projection.SliceProjection;
pub const SliceSuffix = slice_projection.SliceSuffix;
pub const DiagramAdherenceOptions = diagram_assertion.DiagramAdherenceOptions;

pub const BuilderError = slice_projection.InitError || error{
    ExclusionWithoutSelector,
    InvalidExclusionTarget,
    InvalidPattern,
    InvalidProjectPath,
    EmptySliceLabel,
    InvalidDiagram,
};

pub const ProjectSliceOptions = struct {
    locator: ?[]const u8 = null,
};

/// Lazy owned project scope with exactly one path-to-slice projection.
pub const ProjectSlices = struct {
    allocator: Allocator,
    project_locator: ?[]u8,
    projection: SliceProjection,
    path_filter: ?matching.Filter = null,
    exclusion_target: ?PatternTarget = null,
    exclusions: std.ArrayList(assertion.ScopePattern) = .empty,

    fn init(allocator: Allocator, options: ProjectSliceOptions) BuilderError!ProjectSlices {
        if (options.locator) |locator| {
            if (!containsNonWhitespace(locator)) return error.InvalidProjectPath;
        }
        return .{
            .allocator = allocator,
            .project_locator = if (options.locator) |locator| try allocator.dupe(u8, locator) else null,
            .projection = SliceProjection.initIdentity(),
        };
    }

    pub fn clone(self: *const ProjectSlices) BuilderError!ProjectSlices {
        const locator = if (self.project_locator) |value| try self.allocator.dupe(u8, value) else null;
        var locator_owned = true;
        errdefer if (locator_owned) if (locator) |value| self.allocator.free(value);
        var result = ProjectSlices{
            .allocator = self.allocator,
            .project_locator = locator,
            .projection = try self.projection.clone(self.allocator),
            .exclusion_target = self.exclusion_target,
        };
        locator_owned = false;
        errdefer result.deinit();
        if (self.path_filter) |*filter| result.path_filter = try filter.clone(self.allocator);
        try result.exclusions.ensureTotalCapacity(self.allocator, self.exclusions.items.len);
        for (self.exclusions.items) |exclusion| {
            result.exclusions.appendAssumeCapacity(try exclusion.clone(self.allocator));
        }
        return result;
    }

    pub fn deinit(self: *ProjectSlices) void {
        if (self.project_locator) |locator| self.allocator.free(locator);
        self.projection.deinit(self.allocator);
        if (self.path_filter) |*filter| filter.deinit();
        for (self.exclusions.items) |*exclusion| exclusion.deinit(self.allocator);
        self.exclusions.deinit(self.allocator);
        self.* = undefined;
    }

    /// Replaces the current projection with a one-segment `(**)` capture pattern.
    pub fn definedBy(self: *const ProjectSlices, pattern: []const u8) BuilderError!ProjectSlices {
        var next_projection = try SliceProjection.initPattern(self.allocator, pattern);
        errdefer next_projection.deinit(self.allocator);
        return self.withProjection(&next_projection, .path);
    }

    /// Replaces the current projection with an explicit regex using capture group 1.
    pub fn definedByRegex(
        self: *const ProjectSlices,
        expression: []const u8,
    ) BuilderError!ProjectSlices {
        var next_projection = try SliceProjection.initRegex(self.allocator, expression);
        errdefer next_projection.deinit(self.allocator);
        return self.withProjection(&next_projection, .path);
    }

    /// Replaces the current projection with deterministic file-stem suffix definitions.
    pub fn definedByFileSuffixes(
        self: *const ProjectSlices,
        definitions: []const SliceSuffix,
    ) BuilderError!ProjectSlices {
        var next_projection = try SliceProjection.initFileSuffixes(self.allocator, definitions);
        errdefer next_projection.deinit(self.allocator);
        return self.withProjection(&next_projection, .filename);
    }

    fn withProjection(
        self: *const ProjectSlices,
        next_projection: *SliceProjection,
        target: PatternTarget,
    ) BuilderError!ProjectSlices {
        var next_filter = try matching.Filter.init(
            self.allocator,
            .{ .glob = "**" },
            .path,
            .exact,
        );
        errdefer next_filter.deinit();
        var result = try self.clone();
        errdefer result.deinit();
        result.projection.deinit(result.allocator);
        result.projection = next_projection.*;
        next_projection.* = undefined;
        if (result.path_filter) |*filter| filter.deinit();
        result.path_filter = next_filter;
        next_filter = undefined;
        for (result.exclusions.items) |*exclusion| exclusion.deinit(result.allocator);
        result.exclusions.clearRetainingCapacity();
        result.exclusion_target = target;
        return result;
    }

    pub fn except(self: *const ProjectSlices, patterns: []const Pattern) BuilderError!ProjectSlices {
        return self.excludePatterns(patterns, self.exclusion_target orelse return error.ExclusionWithoutSelector);
    }

    pub fn exceptTargeted(
        self: *const ProjectSlices,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!ProjectSlices {
        if (self.exclusion_target == null) return error.ExclusionWithoutSelector;
        if (target == .declaration_name) return error.InvalidExclusionTarget;
        return self.excludePatterns(patterns, target);
    }

    fn excludePatterns(
        self: *const ProjectSlices,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!ProjectSlices {
        if (patterns.len == 0) return error.InvalidPattern;
        var result = try self.clone();
        errdefer result.deinit();
        try result.exclusions.ensureUnusedCapacity(result.allocator, patterns.len);
        for (patterns) |pattern| {
            if (pattern.source().len == 0) return error.InvalidPattern;
            const mode: matching.MatchingMode = switch (pattern) {
                .glob => .exact,
                .regex => .partial,
            };
            try result.path_filter.?.addExclusion(pattern, target, mode);
            result.exclusions.appendAssumeCapacity(try assertion.ScopePattern.initExclusion(
                result.allocator,
                0,
                pattern,
                target,
                mode,
            ));
        }
        return result;
    }

    fn projectLabels(
        self: *const ProjectSlices,
        allocator: Allocator,
        graph: *const Graph,
    ) slice_projection.LabelError!slice_projection.SliceLabels {
        return slice_projection.projectSliceLabelsFiltered(
            allocator,
            graph,
            &self.projection,
            if (self.path_filter) |*filter| filter else null,
        );
    }

    fn projectEdges(
        self: *const ProjectSlices,
        allocator: Allocator,
        graph: *const Graph,
    ) slice_projection.ProjectionError!slice_projection.ProjectedEdges {
        return slice_projection.projectSliceEdgesFiltered(
            allocator,
            graph,
            &self.projection,
            if (self.path_filter) |*filter| filter else null,
        );
    }

    pub fn should(self: *const ProjectSlices) BuilderError!SlicesShould {
        return .{ .rule = try SliceRuleContext.init(self, .should), .diagram_options = .{} };
    }

    pub fn shouldNot(self: *const ProjectSlices) BuilderError!SlicesShouldNot {
        return .{ .rule = try SliceRuleContext.init(self, .should_not) };
    }

    /// Extracts once and renders the real slice graph as deterministic PlantUML.
    pub fn toPlantUml(self: *const ProjectSlices, options: CheckOptions) anyerror![]u8 {
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
        return self.toPlantUmlGraph(options.allocator, &graph);
    }

    pub fn toPlantUmlGraph(
        self: *const ProjectSlices,
        allocator: Allocator,
        graph: *const Graph,
    ) (slice_projection.ProjectionError || plantuml.RenderError)![]u8 {
        var labels = try self.projectLabels(allocator, graph);
        defer labels.deinit(allocator);
        var edges = try self.projectEdges(allocator, graph);
        defer edges.deinit(allocator);
        return plantuml.renderPlantUml(allocator, labels.items(), edges.items());
    }

    pub fn exportAsPlantUml(
        self: *const ProjectSlices,
        options: CheckOptions,
        output_path: []const u8,
    ) anyerror!void {
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
        var labels = try self.projectLabels(options.allocator, &graph);
        defer labels.deinit(options.allocator);
        var edges = try self.projectEdges(options.allocator, &graph);
        defer edges.deinit(options.allocator);
        return plantuml.exportPlantUml(
            options.allocator,
            options.io,
            labels.items(),
            edges.items(),
            output_path,
        );
    }

    fn description(self: *const ProjectSlices, allocator: Allocator) Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        switch (self.projection) {
            .identity => output.writer.writeAll("project slices defined by file identity") catch
                return error.OutOfMemory,
            .pattern => |value| output.writer.print(
                "project slices defined by pattern \"{f}\"",
                .{std.zig.fmtString(value.source)},
            ) catch return error.OutOfMemory,
            .regex => |value| output.writer.print(
                "project slices defined by regex \"{f}\"",
                .{std.zig.fmtString(value.source)},
            ) catch return error.OutOfMemory,
            .suffix => output.writer.writeAll("project slices defined by file suffix") catch
                return error.OutOfMemory,
        }
        for (self.exclusions.items) |exclusion| {
            output.writer.print(
                ", except {s} {s}\"{f}\"",
                .{
                    exclusionTargetPhrase(exclusion.target),
                    if (exclusion.syntax == .regex) "regex " else "",
                    std.zig.fmtString(exclusion.expression),
                },
            ) catch return error.OutOfMemory;
        }
        return output.toOwnedSlice();
    }
};

const SliceRuleContext = struct {
    scope: ProjectSlices,
    mood: Mood,

    fn init(scope: *const ProjectSlices, mood: Mood) BuilderError!SliceRuleContext {
        return .{ .scope = try scope.clone(), .mood = mood };
    }

    fn clone(self: *const SliceRuleContext) BuilderError!SliceRuleContext {
        return .{ .scope = try self.scope.clone(), .mood = self.mood };
    }

    fn deinit(self: *SliceRuleContext) void {
        self.scope.deinit();
        self.* = undefined;
    }
};

pub const SlicesShould = struct {
    rule: SliceRuleContext,
    diagram_options: DiagramAdherenceOptions,

    pub fn deinit(self: *SlicesShould) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn containDependency(
        self: *const SlicesShould,
        source_slice: []const u8,
        target_slice: []const u8,
    ) BuilderError!SliceDependencyRule {
        return SliceDependencyRule.init(&self.rule, source_slice, target_slice);
    }

    pub fn ignoringOrphanSlices(self: *const SlicesShould) BuilderError!SlicesShould {
        return .{
            .rule = try self.rule.clone(),
            .diagram_options = .{
                .ignore_orphan_slices = true,
                .ignore_external_slices = self.diagram_options.ignore_external_slices,
            },
        };
    }

    pub fn ignoringExternalSlices(self: *const SlicesShould) BuilderError!SlicesShould {
        return .{
            .rule = try self.rule.clone(),
            .diagram_options = .{
                .ignore_orphan_slices = self.diagram_options.ignore_orphan_slices,
                .ignore_external_slices = true,
            },
        };
    }

    pub fn adhereToDiagram(
        self: *const SlicesShould,
        text: []const u8,
    ) BuilderError!DiagramAdherenceRule {
        return DiagramAdherenceRule.init(&self.rule, .inline_text, text, self.diagram_options);
    }

    pub fn adhereToDiagramInFile(
        self: *const SlicesShould,
        path: []const u8,
    ) BuilderError!DiagramAdherenceRule {
        return DiagramAdherenceRule.init(&self.rule, .file_path, path, self.diagram_options);
    }
};

pub const SlicesShouldNot = struct {
    rule: SliceRuleContext,

    pub fn deinit(self: *SlicesShouldNot) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn containDependency(
        self: *const SlicesShouldNot,
        source_slice: []const u8,
        target_slice: []const u8,
    ) BuilderError!SliceDependencyRule {
        return SliceDependencyRule.init(&self.rule, source_slice, target_slice);
    }
};

const DiagramSourceKind = enum { inline_text, file_path };

const DiagramSource = union(DiagramSourceKind) {
    inline_text: []u8,
    file_path: []u8,

    fn init(
        allocator: Allocator,
        kind: DiagramSourceKind,
        value: []const u8,
    ) BuilderError!DiagramSource {
        if (!containsNonWhitespace(value)) return error.InvalidDiagram;
        return switch (kind) {
            .inline_text => .{ .inline_text = try allocator.dupe(u8, value) },
            .file_path => .{ .file_path = try allocator.dupe(u8, value) },
        };
    }

    fn deinit(self: *DiagramSource, allocator: Allocator) void {
        switch (self.*) {
            inline else => |value| allocator.free(value),
        }
        self.* = undefined;
    }

    fn description(self: *const DiagramSource) []const u8 {
        return switch (self.*) {
            .inline_text => "inline PlantUML diagram",
            .file_path => |path| path,
        };
    }
};

/// Positive terminal validating strict relationship equality against inline or file PlantUML.
pub const DiagramAdherenceRule = struct {
    rule: SliceRuleContext,
    source: DiagramSource,
    options: DiagramAdherenceOptions,

    fn init(
        source_rule: *const SliceRuleContext,
        kind: DiagramSourceKind,
        value: []const u8,
        options: DiagramAdherenceOptions,
    ) BuilderError!DiagramAdherenceRule {
        var rule = try source_rule.clone();
        errdefer rule.deinit();
        return .{
            .rule = rule,
            .source = try DiagramSource.init(rule.scope.allocator, kind, value),
            .options = options,
        };
    }

    pub fn deinit(self: *DiagramAdherenceRule, allocator: Allocator) void {
        _ = allocator;
        const owner = self.rule.scope.allocator;
        self.source.deinit(owner);
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const DiagramAdherenceRule, allocator: Allocator) Allocator.Error![]u8 {
        const scope_description = try self.rule.scope.description(allocator);
        defer allocator.free(scope_description);
        return std.fmt.allocPrint(
            allocator,
            "{s} should adhere to {s}",
            .{ scope_description, self.source.description() },
        );
    }

    pub fn check(
        self: *const DiagramAdherenceRule,
        options: CheckOptions,
    ) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "slices.adhere_to_diagram", performCheck);
    }

    fn performCheck(
        self: *const DiagramAdherenceRule,
        options: CheckOptions,
    ) anyerror!assertion.ViolationList {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var graph = try extraction.extractProjectGraphLogged(
            options.allocator,
            options.io,
            self.rule.scope.project_locator,
            options.working_directory,
            options.extraction,
            options.clear_cache,
            &diagnostics,
            options.logger,
        );
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    pub fn checkGraph(
        self: *const DiagramAdherenceRule,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var labels = try self.rule.scope.projectLabels(options.allocator, graph);
        defer labels.deinit(options.allocator);
        if (try assertion.guardEmptyTest(
            options.allocator,
            labels.len(),
            options.allow_empty_tests,
            "slices.adhere_to_diagram",
            &.{},
            .should,
        )) |early| return early;

        var owned_text: ?[:0]u8 = null;
        defer if (owned_text) |value| options.allocator.free(value);
        const diagram_text: []const u8 = switch (self.source) {
            .inline_text => |text| text,
            .file_path => |path| blk: {
                owned_text = std.Io.Dir.cwd().readFileAllocOptions(
                    options.io,
                    path,
                    options.allocator,
                    .limited(std.math.maxInt(usize)),
                    .of(u8),
                    0,
                ) catch |failure| return if (failure == error.OutOfMemory)
                    error.OutOfMemory
                else
                    error.FileSystemFailure;
                break :blk owned_text.?;
            },
        };
        var parsed = try plantuml.parsePlantUml(options.allocator, diagram_text);
        defer parsed.deinit(options.allocator);
        const diagram = switch (parsed) {
            .diagram => |*value| value,
            .invalid => return error.InvalidDiagram,
        };
        var edges = try self.rule.scope.projectEdges(options.allocator, graph);
        defer edges.deinit(options.allocator);
        return diagram_assertion.gatherDiagramAdherenceViolations(
            options.allocator,
            edges.items(),
            labels.items(),
            diagram,
            self.options,
        );
    }
};

/// Owned terminal checking one required or forbidden direct dependency between projected slices.
pub const SliceDependencyRule = struct {
    rule: SliceRuleContext,
    source_slice: []u8,
    target_slice: []u8,

    fn init(
        source_rule: *const SliceRuleContext,
        source_slice: []const u8,
        target_slice: []const u8,
    ) BuilderError!SliceDependencyRule {
        if (!containsNonWhitespace(source_slice) or !containsNonWhitespace(target_slice)) {
            return error.EmptySliceLabel;
        }
        var rule = try source_rule.clone();
        errdefer rule.deinit();
        const owned_source = try rule.scope.allocator.dupe(u8, source_slice);
        errdefer rule.scope.allocator.free(owned_source);
        return .{
            .rule = rule,
            .source_slice = owned_source,
            .target_slice = try rule.scope.allocator.dupe(u8, target_slice),
        };
    }

    /// The allocator belongs to the `Checkable` contract; owned storage uses the builder allocator.
    pub fn deinit(self: *SliceDependencyRule, allocator: Allocator) void {
        _ = allocator;
        const owner = self.rule.scope.allocator;
        owner.free(self.source_slice);
        owner.free(self.target_slice);
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn description(
        self: *const SliceDependencyRule,
        allocator: Allocator,
    ) Allocator.Error![]u8 {
        const scope_description = try self.rule.scope.description(allocator);
        defer allocator.free(scope_description);
        return std.fmt.allocPrint(
            allocator,
            "{s} {f} contain dependency \"{f}\" -> \"{f}\"",
            .{
                scope_description,
                self.rule.mood,
                std.zig.fmtString(self.source_slice),
                std.zig.fmtString(self.target_slice),
            },
        );
    }

    pub fn check(
        self: *const SliceDependencyRule,
        options: CheckOptions,
    ) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "slices.dependency", performCheck);
    }

    fn performCheck(
        self: *const SliceDependencyRule,
        options: CheckOptions,
    ) anyerror!assertion.ViolationList {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var graph = try extraction.extractProjectGraphLogged(
            options.allocator,
            options.io,
            self.rule.scope.project_locator,
            options.working_directory,
            options.extraction,
            options.clear_cache,
            &diagnostics,
            options.logger,
        );
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    pub fn checkGraph(
        self: *const SliceDependencyRule,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var labels = try self.rule.scope.projectLabels(options.allocator, graph);
        defer labels.deinit(options.allocator);
        if (try assertion.guardEmptyTest(
            options.allocator,
            labels.len(),
            options.allow_empty_tests,
            "slices.scope",
            &.{},
            self.rule.mood,
        )) |early| return early;

        var edges = try self.rule.scope.projectEdges(options.allocator, graph);
        defer edges.deinit(options.allocator);
        return slice_assertion.gatherSliceDependencyViolations(
            options.allocator,
            edges.items(),
            self.source_slice,
            self.target_slice,
            self.rule.mood,
        );
    }
};

pub fn projectSlices(
    allocator: Allocator,
    options: ProjectSliceOptions,
) BuilderError!ProjectSlices {
    return ProjectSlices.init(allocator, options);
}

pub fn slices(allocator: Allocator, options: ProjectSliceOptions) BuilderError!ProjectSlices {
    return projectSlices(allocator, options);
}

fn exclusionTargetPhrase(target: PatternTarget) []const u8 {
    return switch (target) {
        .filename => "with name",
        .path_without_filename => "in folder",
        .path => "in path",
        .declaration_name => unreachable,
    };
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn addEdge(
    allocator: Allocator,
    graph: *Graph,
    source: []const u8,
    target: []const u8,
    external: bool,
) !void {
    try graph.add(
        allocator,
        source,
        target,
        external,
        extraction.ImportKinds.initOne(if (external) .named_module else .zig_file),
    );
}

fn sampleGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try addEdge(allocator, &graph, "src/features/api/root.zig", "src/features/services/worker.zig", false);
    try addEdge(allocator, &graph, "src/features/api/root.zig", "src/features/retrieval/repository.zig", false);
    try addEdge(allocator, &graph, "src/features/api/root.zig", "std", true);
    try addEdge(allocator, &graph, "src/features/orphan/alone.zig", "src/features/orphan/alone.zig", false);
    graph.sort();
    return graph;
}

fn featureScope(allocator: Allocator) !ProjectSlices {
    var base = try projectSlices(allocator, .{});
    defer base.deinit();
    return base.definedBy("src/features/(**)/");
}

test "slice builders are lazy branchable and expose pattern regex and suffix projections" {
    var base = try projectSlices(std.testing.allocator, .{ .locator = "fixture" });
    defer base.deinit();
    var pattern = try base.definedBy("src/features/(**)/");
    defer pattern.deinit();
    var regex = try base.definedByRegex("src/features/([^/]+)/");
    defer regex.deinit();
    var suffix = try base.definedByFileSuffixes(&.{.{ .suffix = "_repository", .label = "repositories" }});
    defer suffix.deinit();

    const base_label = (try base.projection.labelFor(std.testing.allocator, "src/features/api/root.zig")).?;
    defer std.testing.allocator.free(base_label);
    const pattern_label = (try pattern.projection.labelFor(std.testing.allocator, "src/features/api/root.zig")).?;
    defer std.testing.allocator.free(pattern_label);
    const regex_label = (try regex.projection.labelFor(std.testing.allocator, "src/features/services/root.zig")).?;
    defer std.testing.allocator.free(regex_label);
    const suffix_label = (try suffix.projection.labelFor(std.testing.allocator, "src/order_repository.zig")).?;
    defer std.testing.allocator.free(suffix_label);
    try std.testing.expectEqualStrings("src/features/api/root.zig", base_label);
    try std.testing.expectEqualStrings("api", pattern_label);
    try std.testing.expectEqualStrings("services", regex_label);
    try std.testing.expectEqualStrings("repositories", suffix_label);

    try std.testing.expectError(error.InvalidProjectPath, projectSlices(std.testing.allocator, .{ .locator = " " }));
    try std.testing.expectError(error.MissingSliceCapture, base.definedBy("src/**"));
}

test "slice exclusions remove internal labels and dependency endpoints before projection" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var base = try projectSlices(std.testing.allocator, .{});
    defer base.deinit();
    try std.testing.expectError(error.ExclusionWithoutSelector, base.except(&.{.{ .glob = "generated/**" }}));
    var scope = try base.definedBy("src/features/(**)/");
    defer scope.deinit();
    var without_retrieval = try scope.except(&.{.{ .glob = "src/features/retrieval/**" }});
    defer without_retrieval.deinit();
    var production = try without_retrieval.exceptTargeted(
        &.{.{ .regex = "^worker\\.zig$" }},
        .filename,
    );
    defer production.deinit();

    var labels = try production.projectLabels(std.testing.allocator, &graph);
    defer labels.deinit(std.testing.allocator);
    try std.testing.expect(labels.contains("api"));
    try std.testing.expect(labels.contains("orphan"));
    try std.testing.expect(!labels.contains("retrieval"));
    try std.testing.expect(!labels.contains("services"));
    var edges = try production.projectEdges(std.testing.allocator, &graph);
    defer edges.deinit(std.testing.allocator);
    try std.testing.expect(edges.find("api", "retrieval") == null);
    try std.testing.expect(edges.find("api", "services") == null);
    try std.testing.expect(edges.find("api", "std") != null);

    const description = try production.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "project slices defined by pattern \"src/features/(**)/\", except in path \"src/features/retrieval/**\", except with name regex \"^worker\\\\.zig$\"",
        description,
    );
    try std.testing.expectError(
        error.InvalidExclusionTarget,
        scope.exceptTargeted(&.{.{ .glob = "Worker" }}, .declaration_name),
    );

    var replaced = try production.definedByRegex("src/features/([^/]+)/");
    defer replaced.deinit();
    var replaced_labels = try replaced.projectLabels(std.testing.allocator, &graph);
    defer replaced_labels.deinit(std.testing.allocator);
    try std.testing.expect(replaced_labels.contains("retrieval"));
    try std.testing.expect(replaced_labels.contains("services"));
}

test "slice suffix exclusions inherit the filename target" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var base = try projectSlices(std.testing.allocator, .{});
    defer base.deinit();
    var suffix = try base.definedByFileSuffixes(&.{.{ .suffix = "repository", .label = "repositories" }});
    defer suffix.deinit();
    var excluded = try suffix.except(&.{.{ .glob = "repository.zig" }});
    defer excluded.deinit();
    var labels = try excluded.projectLabels(std.testing.allocator, &graph);
    defer labels.deinit(std.testing.allocator);
    try std.testing.expect(!labels.contains("repositories"));
    const description = try excluded.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "project slices defined by file suffix, except with name \"repository.zig\"",
        description,
    );
}

test "both moods evaluate direct internal and external slice dependencies" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var negative = try scope.shouldNot();
    defer negative.deinit();

    var required_present = try positive.containDependency("api", "services");
    defer required_present.deinit(std.testing.allocator);
    var present_result = try required_present.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer present_result.deinit(std.testing.allocator);
    try std.testing.expect(present_result.passes());

    var required_missing = try positive.containDependency("models", "api");
    defer required_missing.deinit(std.testing.allocator);
    var missing_result = try required_missing.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer missing_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), missing_result.items().len);
    try std.testing.expect(missing_result.items()[0].slice_dependency.dependency == null);

    var forbidden = try negative.containDependency("api", "retrieval");
    defer forbidden.deinit(std.testing.allocator);
    var forbidden_result = try forbidden.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer forbidden_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), forbidden_result.items().len);
    try std.testing.expectEqualStrings("src/features/api/root.zig", forbidden_result.items()[0].slice_dependency.dependency.?.evidence()[0].source);

    var forbidden_external = try negative.containDependency("api", "std");
    defer forbidden_external.deinit(std.testing.allocator);
    var external_result = try forbidden_external.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer external_result.deinit(std.testing.allocator);
    try std.testing.expect(external_result.items()[0].slice_dependency.dependency.?.evidence()[0].external);

    var absent = try negative.containDependency("models", "api");
    defer absent.deinit(std.testing.allocator);
    var absent_result = try absent.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer absent_result.deinit(std.testing.allocator);
    try std.testing.expect(absent_result.passes());
}

test "empty slice projections use the universal non-vacuity guard" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var base = try projectSlices(std.testing.allocator, .{});
    defer base.deinit();
    var unmatched = try base.definedBy("other/(**)/");
    defer unmatched.deinit();
    var negative = try unmatched.shouldNot();
    defer negative.deinit();
    var rule = try negative.containDependency("api", "retrieval");
    defer rule.deinit(std.testing.allocator);

    var rejected = try rule.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, rejected.items()[0].kind());
    try std.testing.expectEqualStrings("slices.scope", rejected.items()[0].empty_test.rule_id);
    try std.testing.expect(rejected.items()[0].empty_test.is_negated);

    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try rule.checkGraph(options, &graph);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "feature-sliced fixture exposes isolated allowed forbidden and external component edges" {
    var base = try projectSlices(std.testing.allocator, .{ .locator = "test/fixtures/slices-basic" });
    defer base.deinit();
    var scope = try base.definedBy("src/features/(**)/");
    defer scope.deinit();
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var graph = try extraction.extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        scope.project_locator,
        ".",
        .{},
        true,
        &diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    var labels = try slice_projection.projectSliceLabels(std.testing.allocator, &graph, &scope.projection);
    defer labels.deinit(std.testing.allocator);
    try std.testing.expect(labels.contains("orphan"));
    var edges = try slice_projection.projectSliceEdges(std.testing.allocator, &graph, &scope.projection);
    defer edges.deinit(std.testing.allocator);
    try std.testing.expect(edges.find("api", "services") != null);
    try std.testing.expect(edges.find("api", "retrieval") != null);
    try std.testing.expect(edges.find("api", "api") == null);
    try std.testing.expect(edges.find("api", "std") != null);

    var negative = try scope.shouldNot();
    defer negative.deinit();
    var forbidden = try negative.containDependency("api", "retrieval");
    defer forbidden.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try forbidden.check(options);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "slice exclusions change real fixture rules and PlantUML consistently" {
    var base = try projectSlices(std.testing.allocator, .{ .locator = "test/fixtures/slices-basic" });
    defer base.deinit();
    var scope = try base.definedBy("src/features/(**)/");
    defer scope.deinit();
    var without_retrieval = try scope.except(&.{.{ .glob = "src/features/retrieval/**" }});
    defer without_retrieval.deinit();
    var negative = try without_retrieval.shouldNot();
    defer negative.deinit();
    var forbidden = try negative.containDependency("api", "retrieval");
    defer forbidden.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try forbidden.check(options);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
    const diagram = try without_retrieval.toPlantUml(options);
    defer std.testing.allocator.free(diagram);
    try std.testing.expect(std.mem.indexOf(u8, diagram, "retrieval") == null);
}

test "strict inline PlantUML reports unexpected actual and missing declared relationships" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var rule = try positive.adhereToDiagram(
        "@startuml\n" ++
            "component [api] as A\n" ++
            "component [services] as S\n" ++
            "component [models] as M\n" ++
            "A --> S\n" ++
            "S --> M\n" ++
            "@enduml",
    );
    defer rule.deinit(std.testing.allocator);
    var result = try rule.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.items().len);
    try std.testing.expectEqualStrings("retrieval", result.items()[0].slice_dependency.target_slice);
    try std.testing.expectEqualStrings("std", result.items()[1].slice_dependency.target_slice);
    try std.testing.expectEqualStrings("models", result.items()[2].slice_dependency.target_slice);
    try std.testing.expect(result.items()[2].slice_dependency.dependency == null);
}

test "diagram modifiers are branchable and deliberately ignore external and undeclared slices" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    var base = try scope.should();
    defer base.deinit();
    var orphans = try base.ignoringOrphanSlices();
    defer orphans.deinit();
    var external = try base.ignoringExternalSlices();
    defer external.deinit();
    var combined = try orphans.ignoringExternalSlices();
    defer combined.deinit();
    try std.testing.expect(!base.diagram_options.ignore_orphan_slices);
    try std.testing.expect(!base.diagram_options.ignore_external_slices);
    try std.testing.expect(orphans.diagram_options.ignore_orphan_slices);
    try std.testing.expect(!orphans.diagram_options.ignore_external_slices);
    try std.testing.expect(!external.diagram_options.ignore_orphan_slices);
    try std.testing.expect(external.diagram_options.ignore_external_slices);

    var rule = try combined.adhereToDiagram(
        "@startuml\ncomponent [api]\ncomponent [services]\n[api] -> [services]\n@enduml",
    );
    defer rule.deinit(std.testing.allocator);
    var result = try rule.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

test "diagram source validation is lazy and the empty guard precedes file I/O" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    try std.testing.expectError(error.InvalidDiagram, positive.adhereToDiagram(" "));

    var malformed = try positive.adhereToDiagram("@startuml\ncomponent api\n@enduml");
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidDiagram,
        malformed.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph),
    );
    var missing_file = try positive.adhereToDiagramInFile("missing/architecture.puml");
    defer missing_file.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.FileSystemFailure,
        missing_file.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph),
    );

    var base = try projectSlices(std.testing.allocator, .{});
    defer base.deinit();
    var unmatched = try base.definedBy("missing/(**)/");
    defer unmatched.deinit();
    var unmatched_positive = try unmatched.should();
    defer unmatched_positive.deinit();
    var guarded = try unmatched_positive.adhereToDiagramInFile("missing/architecture.puml");
    defer guarded.deinit(std.testing.allocator);
    var guarded_result = try guarded.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer guarded_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, guarded_result.items()[0].kind());
    try std.testing.expectEqualStrings("slices.adhere_to_diagram", guarded_result.items()[0].empty_test.rule_id);
}

test "file-backed fixture diagram passes when external slices are deliberately ignored" {
    var base = try projectSlices(std.testing.allocator, .{ .locator = "test/fixtures/slices-basic" });
    defer base.deinit();
    var scope = try base.definedBy("src/features/(**)/");
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var internal_only = try positive.ignoringExternalSlices();
    defer internal_only.deinit();
    var rule = try internal_only.adhereToDiagramInFile(
        "test/fixtures/slices-basic/docs/architecture.puml",
    );
    defer rule.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try rule.check(options);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

test "generated PlantUML is deterministic exported and strictly round-trip valid" {
    var graph = try sampleGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    const rendered = try scope.toPlantUmlGraph(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "component [orphan]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "component [std]") != null);

    var parsed = try plantuml.parsePlantUml(std.testing.allocator, rendered);
    defer parsed.deinit(std.testing.allocator);
    const intended = switch (parsed) {
        .diagram => |*value| value,
        .invalid => return error.TestExpectedEqual,
    };
    var labels = try slice_projection.projectSliceLabels(std.testing.allocator, &graph, &scope.projection);
    defer labels.deinit(std.testing.allocator);
    var edges = try slice_projection.projectSliceEdges(std.testing.allocator, &graph, &scope.projection);
    defer edges.deinit(std.testing.allocator);
    var round_trip = try diagram_assertion.gatherDiagramAdherenceViolations(
        std.testing.allocator,
        edges.items(),
        labels.items(),
        intended,
        .{},
    );
    defer round_trip.deinit(std.testing.allocator);
    try std.testing.expect(round_trip.passes());

    var fixture_base = try projectSlices(std.testing.allocator, .{ .locator = "test/fixtures/slices-basic" });
    defer fixture_base.deinit();
    var fixture = try fixture_base.definedBy("src/features/(**)/");
    defer fixture.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "generated.puml" });
    defer std.testing.allocator.free(output_path);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    try fixture.exportAsPlantUml(options, output_path);
    const exported = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        output_path,
        std.testing.allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(exported);
    const generated = try fixture.toPlantUml(options);
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings(generated, exported);
}

test "slice terminal owns a stable sentence and can move into Checkable" {
    var scope = try featureScope(std.testing.allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var terminal = try positive.containDependency("api", "services");
    var terminal_owned = true;
    defer if (terminal_owned) terminal.deinit(std.testing.allocator);
    const sentence = try terminal.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "project slices defined by pattern \"src/features/(**)/\" should contain dependency \"api\" -> \"services\"",
        sentence,
    );
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    terminal_owned = false;
    defer erased.deinit();
    const erased_sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(erased_sentence);
    try std.testing.expectEqualStrings(sentence, erased_sentence);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try sampleGraph(allocator);
    defer graph.deinit(allocator);
    var base = try projectSlices(allocator, .{});
    defer base.deinit();
    var scope = try base.definedByRegex("src/features/([^/]+)/");
    defer scope.deinit();
    var filtered = try scope.except(&.{.{ .glob = "src/features/generated/**" }});
    defer filtered.deinit();
    var production = try filtered.exceptTargeted(&.{.{ .regex = "_generated\\.zig$" }}, .filename);
    defer production.deinit();
    var negative = try production.shouldNot();
    defer negative.deinit();
    var rule = try negative.containDependency("api", "retrieval");
    defer rule.deinit(allocator);
    var result = try rule.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

fn exerciseDiagramAllocationFailures(allocator: Allocator) !void {
    var graph = try sampleGraph(allocator);
    defer graph.deinit(allocator);
    var scope = try featureScope(allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var modified = try positive.ignoringExternalSlices();
    defer modified.deinit();
    var rule = try modified.adhereToDiagram(
        "@startuml\ncomponent [api]\ncomponent [services]\n[api] -> [services]\n@enduml",
    );
    defer rule.deinit(allocator);
    var result = try rule.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    const rendered = try scope.toPlantUmlGraph(allocator, &graph);
    defer allocator.free(rendered);
}

test "slice fluent builders and checks clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseDiagramAllocationFailures, .{});
}
