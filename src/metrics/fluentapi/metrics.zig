const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const threshold_assertion = @import("../assertion/threshold.zig");
const count_calculation = @import("../calculation/count.zig");
const structural = @import("../extraction/structural.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = fluentapi.CheckOptions;
pub const CountMetric = count_calculation.CountMetric;
pub const Filter = matching.Filter;
pub const Pattern = matching.Pattern;
pub const ScopePattern = assertion.ScopePattern;
pub const StructuralMetrics = structural.StructuralMetrics;

pub const BuilderError = Allocator.Error || error{
    InvalidPattern,
    InvalidProjectPath,
};

pub const ProjectOptions = struct {
    locator: ?[]const u8 = null,
};

pub const TargetLevel = enum {
    file,
    declaration,
    container,

    pub fn violationKind(self: TargetLevel) assertion.MetricTargetKind {
        return switch (self) {
            .file => .file,
            .declaration => .declaration,
            .container => .container,
        };
    }
};

pub const ScopePatterns = struct {
    values: std.ArrayList(ScopePattern) = .empty,

    pub fn deinit(self: *ScopePatterns, allocator: Allocator) void {
        for (self.values.items) |*pattern| pattern.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const ScopePatterns) []const ScopePattern {
        return self.values.items;
    }
};

const CompiledPattern = struct {
    evidence: ScopePattern,
    filter: Filter,

    fn initPattern(
        allocator: Allocator,
        selector_index: usize,
        pattern: Pattern,
        target: matching.PatternTarget,
    ) BuilderError!CompiledPattern {
        if (pattern.source().len == 0) return error.InvalidPattern;
        const mode: matching.MatchingMode = switch (pattern) {
            .glob => .exact,
            .regex => .partial,
        };
        var filter = Filter.init(allocator, pattern, target, mode) catch |failure| {
            return mapPatternFailure(failure);
        };
        errdefer filter.deinit();
        return .{
            .evidence = try ScopePattern.init(allocator, selector_index, pattern, target, mode),
            .filter = filter,
        };
    }

    fn initFile(
        allocator: Allocator,
        selector_index: usize,
        path: []const u8,
    ) BuilderError!CompiledPattern {
        if (path.len == 0) return error.InvalidPattern;
        var filter = matching.RegexFactory.exactFileMatcher(allocator, path) catch |failure| {
            return mapPatternFailure(failure);
        };
        errdefer filter.deinit();
        return .{
            .evidence = try ScopePattern.initLiteral(allocator, selector_index, path, .path),
            .filter = filter,
        };
    }

    fn clone(self: *const CompiledPattern, allocator: Allocator) BuilderError!CompiledPattern {
        return switch (self.evidence.syntax) {
            .glob => initPattern(
                allocator,
                self.evidence.selector_index,
                .{ .glob = self.evidence.expression },
                self.evidence.target,
            ),
            .regex => initPattern(
                allocator,
                self.evidence.selector_index,
                .{ .regex = self.evidence.expression },
                self.evidence.target,
            ),
            .literal => initFile(allocator, self.evidence.selector_index, self.evidence.expression),
        };
    }

    fn deinit(self: *CompiledPattern, allocator: Allocator) void {
        self.evidence.deinit(allocator);
        self.filter.deinit();
        self.* = undefined;
    }
};

const Selector = struct {
    alternatives: std.ArrayList(CompiledPattern) = .empty,

    fn initPatterns(
        allocator: Allocator,
        selector_index: usize,
        patterns: []const Pattern,
        target: matching.PatternTarget,
    ) BuilderError!Selector {
        if (patterns.len == 0) return error.InvalidPattern;
        var result = Selector{};
        errdefer result.deinit(allocator);
        try result.alternatives.ensureTotalCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            result.alternatives.appendAssumeCapacity(try CompiledPattern.initPattern(
                allocator,
                selector_index,
                pattern,
                target,
            ));
        }
        return result;
    }

    fn initFiles(
        allocator: Allocator,
        selector_index: usize,
        paths: []const []const u8,
    ) BuilderError!Selector {
        if (paths.len == 0) return error.InvalidPattern;
        var result = Selector{};
        errdefer result.deinit(allocator);
        try result.alternatives.ensureTotalCapacity(allocator, paths.len);
        for (paths) |path| {
            result.alternatives.appendAssumeCapacity(try CompiledPattern.initFile(
                allocator,
                selector_index,
                path,
            ));
        }
        return result;
    }

    fn clone(self: *const Selector, allocator: Allocator) BuilderError!Selector {
        var result = Selector{};
        errdefer result.deinit(allocator);
        try result.alternatives.ensureTotalCapacity(allocator, self.alternatives.items.len);
        for (self.alternatives.items) |*alternative| {
            result.alternatives.appendAssumeCapacity(try alternative.clone(allocator));
        }
        return result;
    }

    fn deinit(self: *Selector, allocator: Allocator) void {
        for (self.alternatives.items) |*alternative| alternative.deinit(allocator);
        self.alternatives.deinit(allocator);
        self.* = undefined;
    }

    fn matches(
        self: *const Selector,
        allocator: Allocator,
        path: []const u8,
        declaration_name: ?[]const u8,
        qualified_name: ?[]const u8,
    ) Allocator.Error!bool {
        for (self.alternatives.items) |*alternative| {
            const candidate = matching.Candidate{ .path = path, .declaration_name = declaration_name };
            if (alternative.filter.matches(allocator, candidate) catch |failure| switch (failure) {
                error.MissingDeclarationName => false,
                error.OutOfMemory => return error.OutOfMemory,
            }) return true;
            if (alternative.evidence.target != .declaration_name) continue;
            const qualified = qualified_name orelse continue;
            const simple = declaration_name orelse continue;
            if (std.mem.eql(u8, simple, qualified)) continue;
            if (alternative.filter.matches(allocator, .{
                .path = path,
                .declaration_name = qualified,
            }) catch |failure| switch (failure) {
                error.MissingDeclarationName => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            }) return true;
        }
        return false;
    }
};

/// Lazy, immutable-by-copy metrics scope. Construction and narrowing perform no filesystem I/O.
pub const MetricsScope = struct {
    allocator: Allocator,
    owned_locator: ?[]u8 = null,
    target_level: TargetLevel = .file,
    selectors: std.ArrayList(Selector) = .empty,

    fn init(allocator: Allocator, options: ProjectOptions) BuilderError!MetricsScope {
        if (options.locator) |locator| {
            if (locator.len == 0) return error.InvalidProjectPath;
            return .{ .allocator = allocator, .owned_locator = try allocator.dupe(u8, locator) };
        }
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MetricsScope) void {
        if (self.owned_locator) |locator| self.allocator.free(locator);
        for (self.selectors.items) |*selector| selector.deinit(self.allocator);
        self.selectors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const MetricsScope) BuilderError!MetricsScope {
        var result = MetricsScope{ .allocator = self.allocator, .target_level = self.target_level };
        errdefer result.deinit();
        if (self.owned_locator) |locator| result.owned_locator = try self.allocator.dupe(u8, locator);
        try result.selectors.ensureTotalCapacity(self.allocator, self.selectors.items.len);
        for (self.selectors.items) |*selector| {
            result.selectors.appendAssumeCapacity(try selector.clone(self.allocator));
        }
        return result;
    }

    pub fn projectLocator(self: *const MetricsScope) ?[]const u8 {
        return self.owned_locator;
    }

    pub fn targetLevel(self: *const MetricsScope) TargetLevel {
        return self.target_level;
    }

    pub fn selectorCount(self: *const MetricsScope) usize {
        return self.selectors.items.len;
    }

    pub fn withName(self: *const MetricsScope, patterns: []const Pattern) BuilderError!MetricsScope {
        return self.selectPatterns(patterns, .filename, null);
    }

    pub fn inFolder(self: *const MetricsScope, patterns: []const Pattern) BuilderError!MetricsScope {
        return self.selectPatterns(patterns, .path_without_filename, null);
    }

    pub fn inPath(self: *const MetricsScope, patterns: []const Pattern) BuilderError!MetricsScope {
        return self.selectPatterns(patterns, .path, null);
    }

    pub fn inFile(self: *const MetricsScope, paths: []const []const u8) BuilderError!MetricsScope {
        var result = try self.clone();
        errdefer result.deinit();
        var selector = try Selector.initFiles(
            self.allocator,
            result.selectors.items.len,
            paths,
        );
        result.selectors.append(self.allocator, selector) catch {
            selector.deinit(self.allocator);
            return error.OutOfMemory;
        };
        return result;
    }

    /// Switches the subject level to every named declaration and matches both simple and qualified
    /// declaration names.
    pub fn forDeclarationsMatching(
        self: *const MetricsScope,
        patterns: []const Pattern,
    ) BuilderError!MetricsScope {
        return self.selectPatterns(patterns, .declaration_name, .declaration);
    }

    /// Switches the subject level to declaration-bound Zig containers only.
    pub fn forContainersMatching(
        self: *const MetricsScope,
        patterns: []const Pattern,
    ) BuilderError!MetricsScope {
        return self.selectPatterns(patterns, .declaration_name, .container);
    }

    pub fn count(self: *const MetricsScope) BuilderError!CountMetrics {
        return .{ .scope = try self.clone() };
    }

    pub fn analyze(self: *const MetricsScope, options: CheckOptions) anyerror!MetricAnalysis {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var project = try structural.extractProjectInfo(
            options.allocator,
            options.io,
            self.owned_locator,
            options.working_directory,
            options.extraction,
            &diagnostics,
        );
        errdefer project.deinit(options.allocator);
        var subjects: std.ArrayList(MetricSubject) = .empty;
        errdefer subjects.deinit(options.allocator);

        for (project.files.items) |*file| switch (self.target_level) {
            .file => {
                if (try self.matches(options.allocator, file.path, null, null)) {
                    try subjects.append(options.allocator, .{
                        .identifier = file.path,
                        .name = std.fs.path.basename(file.path),
                        .file_path = file.path,
                        .target_level = .file,
                        .syntax_valid = file.syntax_valid,
                        .metrics = file.metrics,
                    });
                }
            },
            .declaration, .container => {
                for (file.declarations.items) |*declaration| {
                    if (self.target_level == .container and !declaration.isContainer()) continue;
                    if (!try self.matches(
                        options.allocator,
                        file.path,
                        declaration.name,
                        declaration.qualified_name,
                    )) continue;
                    try subjects.append(options.allocator, .{
                        .identifier = declaration.identifier,
                        .name = declaration.name,
                        .qualified_name = declaration.qualified_name,
                        .file_path = file.path,
                        .target_level = self.target_level,
                        .syntax_valid = true,
                        .metrics = declaration.metrics,
                    });
                }
            },
        };
        return .{ .project = project, .subjects = subjects };
    }

    pub fn scopePatterns(self: *const MetricsScope, allocator: Allocator) Allocator.Error!ScopePatterns {
        var result = ScopePatterns{};
        errdefer result.deinit(allocator);
        var count_value: usize = 0;
        for (self.selectors.items) |selector| count_value += selector.alternatives.items.len;
        try result.values.ensureTotalCapacity(allocator, count_value);
        for (self.selectors.items) |selector| {
            for (selector.alternatives.items) |alternative| {
                result.values.appendAssumeCapacity(try alternative.evidence.clone(allocator));
            }
        }
        return result;
    }

    pub fn description(self: *const MetricsScope, allocator: Allocator) Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        self.writeDescription(&output.writer) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn selectPatterns(
        self: *const MetricsScope,
        patterns: []const Pattern,
        target: matching.PatternTarget,
        new_level: ?TargetLevel,
    ) BuilderError!MetricsScope {
        var result = try self.clone();
        errdefer result.deinit();
        if (new_level) |level| result.target_level = level;
        var selector = try Selector.initPatterns(
            self.allocator,
            result.selectors.items.len,
            patterns,
            target,
        );
        result.selectors.append(self.allocator, selector) catch {
            selector.deinit(self.allocator);
            return error.OutOfMemory;
        };
        return result;
    }

    fn matches(
        self: *const MetricsScope,
        allocator: Allocator,
        path: []const u8,
        declaration_name: ?[]const u8,
        qualified_name: ?[]const u8,
    ) Allocator.Error!bool {
        for (self.selectors.items) |*selector| {
            if (!try selector.matches(allocator, path, declaration_name, qualified_name)) return false;
        }
        return true;
    }

    fn writeDescription(self: *const MetricsScope, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(switch (self.target_level) {
            .file => "Zig project files",
            .declaration => "Zig declarations",
            .container => "Zig containers",
        });
        for (self.selectors.items) |selector| {
            const alternatives = selector.alternatives.items;
            std.debug.assert(alternatives.len != 0);
            try writer.writeAll(", ");
            try writer.writeAll(selectorPhrase(alternatives[0].evidence, self.target_level));
            try writer.writeByte(' ');
            if (alternatives.len > 1) try writer.writeByte('(');
            for (alternatives, 0..) |alternative, index| {
                if (index != 0) try writer.writeAll(" or ");
                if (alternative.evidence.syntax == .regex) try writer.writeAll("regex ");
                try writer.print("\"{f}\"", .{std.zig.fmtString(alternative.evidence.expression)});
            }
            if (alternatives.len > 1) try writer.writeByte(')');
        }
    }
};

/// Borrowed selected subject. All slices remain valid until `MetricAnalysis.deinit`.
pub const MetricSubject = struct {
    identifier: []const u8,
    name: []const u8,
    qualified_name: ?[]const u8 = null,
    file_path: []const u8,
    target_level: TargetLevel,
    syntax_valid: bool,
    metrics: StructuralMetrics,
};

/// Owned project analysis plus its borrowed, deterministic selected-subject view.
pub const MetricAnalysis = struct {
    project: structural.ProjectInfo,
    subjects: std.ArrayList(MetricSubject),

    pub fn deinit(self: *MetricAnalysis, allocator: Allocator) void {
        self.subjects.deinit(allocator);
        self.project.deinit(allocator);
        self.* = undefined;
    }
};

pub const CountMetrics = struct {
    scope: MetricsScope,

    pub fn deinit(self: *CountMetrics) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn declarations(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.declarations);
    }
    pub fn functions(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.functions);
    }
    pub fn tests(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.tests);
    }
    pub fn constants(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.constants);
    }
    pub fn variables(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.variables);
    }
    pub fn fields(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.fields);
    }
    pub fn structs(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.structs);
    }
    pub fn unions(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.unions);
    }
    pub fn enums(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.enums);
    }
    pub fn opaqueTypes(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.opaque_types);
    }
    pub fn errorSets(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.error_sets);
    }
    pub fn otherDeclarations(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.other_declarations);
    }
    pub fn anonymousContainers(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.anonymous_containers);
    }
    pub fn imports(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.imports);
    }
    pub fn statements(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.statements);
    }
    pub fn tokens(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.tokens);
    }
    pub fn sourceLines(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.source_lines);
    }
    pub fn nonBlankLines(self: *const CountMetrics) BuilderError!CountMetricSelection {
        return self.selection(.non_blank_lines);
    }

    pub fn summary(self: *const CountMetrics, options: CheckOptions) anyerror!CountSummary {
        var analysis = try self.scope.analyze(options);
        defer analysis.deinit(options.allocator);
        var result = CountSummary{ .subject_count = analysis.subjects.items.len };
        for (analysis.subjects.items) |subject| {
            if (!subject.syntax_valid) result.invalid_syntax_subjects += 1;
            result.totals.add(subject.metrics);
        }
        return result;
    }

    fn selection(self: *const CountMetrics, metric: CountMetric) BuilderError!CountMetricSelection {
        return .{ .scope = try self.scope.clone(), .metric = metric };
    }
};

pub const CountSummary = struct {
    subject_count: usize = 0,
    invalid_syntax_subjects: usize = 0,
    totals: StructuralMetrics = .{},
};

pub const MetricMeasurement = struct {
    target_identifier: []u8,
    target_kind: assertion.MetricTargetKind,
    metric: CountMetric,
    value: usize,

    pub fn deinit(self: *MetricMeasurement, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        self.* = undefined;
    }
};

pub const MetricMeasurements = struct {
    values: std.ArrayList(MetricMeasurement) = .empty,

    pub fn deinit(self: *MetricMeasurements, allocator: Allocator) void {
        for (self.values.items) |*measurement| measurement.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const MetricMeasurements) []const MetricMeasurement {
        return self.values.items;
    }
};

pub const CountMetricSelection = struct {
    scope: MetricsScope,
    metric: CountMetric,

    pub fn deinit(self: *CountMetricSelection) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn measure(self: *const CountMetricSelection, options: CheckOptions) anyerror!MetricMeasurements {
        var analysis = try self.scope.analyze(options);
        defer analysis.deinit(options.allocator);
        var result = MetricMeasurements{};
        errdefer result.deinit(options.allocator);
        try result.values.ensureTotalCapacity(options.allocator, analysis.subjects.items.len);
        for (analysis.subjects.items) |subject| {
            result.values.appendAssumeCapacity(.{
                .target_identifier = try options.allocator.dupe(u8, subject.identifier),
                .target_kind = subject.target_level.violationKind(),
                .metric = self.metric,
                .value = self.metric.measure(subject.metrics),
            });
        }
        return result;
    }

    pub fn shouldBeBelow(self: *const CountMetricSelection, value: usize) BuilderError!MetricThresholdRule {
        return self.threshold(.below, value);
    }
    pub fn shouldBeAbove(self: *const CountMetricSelection, value: usize) BuilderError!MetricThresholdRule {
        return self.threshold(.above, value);
    }
    pub fn shouldBe(self: *const CountMetricSelection, value: usize) BuilderError!MetricThresholdRule {
        return self.threshold(.equal, value);
    }
    pub fn shouldBeBelowOrEqual(self: *const CountMetricSelection, value: usize) BuilderError!MetricThresholdRule {
        return self.threshold(.below_or_equal, value);
    }
    pub fn shouldBeAboveOrEqual(self: *const CountMetricSelection, value: usize) BuilderError!MetricThresholdRule {
        return self.threshold(.above_or_equal, value);
    }

    fn threshold(
        self: *const CountMetricSelection,
        comparison: assertion.MetricComparison,
        value: usize,
    ) BuilderError!MetricThresholdRule {
        return .{
            .scope = try self.scope.clone(),
            .metric = self.metric,
            .comparison = comparison,
            .threshold_value = value,
        };
    }
};

pub const MetricThresholdRule = struct {
    scope: MetricsScope,
    metric: CountMetric,
    comparison: assertion.MetricComparison,
    threshold_value: usize,

    pub fn deinit(self: *MetricThresholdRule, _: Allocator) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const MetricThresholdRule, allocator: Allocator) Allocator.Error![]u8 {
        const scope_description = try self.scope.description(allocator);
        defer allocator.free(scope_description);
        return std.fmt.allocPrint(
            allocator,
            "{s} count {s} should be {s} {d}",
            .{ scope_description, self.metric.name(), comparisonPhrase(self.comparison), self.threshold_value },
        );
    }

    pub fn check(self: *const MetricThresholdRule, options: CheckOptions) anyerror!assertion.ViolationList {
        var selection = CountMetricSelection{ .scope = try self.scope.clone(), .metric = self.metric };
        defer selection.deinit();
        var measurements = try selection.measure(options);
        defer measurements.deinit(options.allocator);
        var evidence = try self.scope.scopePatterns(options.allocator);
        defer evidence.deinit(options.allocator);
        if (try assertion.guardEmptyTest(
            options.allocator,
            measurements.items().len,
            options.allow_empty_tests,
            "metrics.count",
            evidence.items(),
            .should,
        )) |guarded| return guarded;

        const threshold_value = assertion.MetricValue{ .unsigned = @intCast(self.threshold_value) };
        var result = assertion.ViolationList{};
        errdefer result.deinit(options.allocator);
        for (measurements.items()) |measurement| {
            const measured = assertion.MetricValue{ .unsigned = @intCast(measurement.value) };
            if (try threshold_assertion.passes(measured, self.comparison, threshold_value)) continue;
            var payload = try assertion.MetricViolation.init(
                options.allocator,
                measurement.target_identifier,
                measurement.target_kind,
                self.metric.name(),
                measured,
                self.comparison,
                threshold_value,
            );
            var violation = assertion.Violation.fromMetricMove(&payload);
            result.appendMove(options.allocator, &violation) catch |failure| {
                violation.deinit(options.allocator);
                return failure;
            };
        }
        return result;
    }
};

pub fn metrics(allocator: Allocator, options: ProjectOptions) BuilderError!MetricsScope {
    return MetricsScope.init(allocator, options);
}

fn mapPatternFailure(failure: anyerror) BuilderError {
    return if (failure == error.OutOfMemory) error.OutOfMemory else error.InvalidPattern;
}

fn selectorPhrase(pattern: ScopePattern, target_level: TargetLevel) []const u8 {
    return switch (pattern.target) {
        .filename => "with name",
        .path_without_filename => "in folder",
        .path => if (pattern.syntax == .literal) "in file" else "in path",
        .declaration_name => switch (target_level) {
            .file => unreachable,
            .declaration => "with declaration name",
            .container => "with container name",
        },
    };
}

fn comparisonPhrase(comparison: assertion.MetricComparison) []const u8 {
    return switch (comparison) {
        .below => "below",
        .above => "above",
        .equal => "equal to",
        .below_or_equal => "below or equal to",
        .above_or_equal => "above or equal to",
    };
}

test "metrics scopes are lazy owned and immutable across selector branches" {
    var locator = [_]u8{ 'm', 'i', 's', 's', 'i', 'n', 'g' };
    var root = try metrics(std.testing.allocator, .{ .locator = &locator });
    defer root.deinit();
    var source = try root.inPath(&.{.{ .glob = "src/**" }});
    defer source.deinit();
    var containers = try source.forContainersMatching(&.{.{ .glob = "*Service" }});
    defer containers.deinit();
    @memset(&locator, 'x');

    try std.testing.expectEqualStrings("missing", root.projectLocator().?);
    try std.testing.expectEqual(TargetLevel.file, root.targetLevel());
    try std.testing.expectEqual(@as(usize, 0), root.selectorCount());
    try std.testing.expectEqual(TargetLevel.container, containers.targetLevel());
    try std.testing.expectEqual(@as(usize, 2), containers.selectorCount());
}

test "file and container selectors analyze the real structural fixture" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var root_file = try root.inFile(&.{"src/root.zig"});
    defer root_file.deinit();
    var file_analysis = try root_file.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer file_analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), file_analysis.subjects.items.len);
    try std.testing.expectEqualStrings("src/root.zig", file_analysis.subjects.items[0].identifier);

    var worker = try root.forContainersMatching(&.{.{ .glob = "Worker" }});
    defer worker.deinit();
    var container_analysis = try worker.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer container_analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), container_analysis.subjects.items.len);
    try std.testing.expectEqualStrings("src/root.zig:Worker", container_analysis.subjects.items[0].identifier);
    try std.testing.expectEqual(@as(usize, 1), container_analysis.subjects.items[0].metrics.functions);
    try std.testing.expectEqual(@as(usize, 1), container_analysis.subjects.items[0].metrics.fields);

    var nested_simple = try root.forContainersMatching(&.{.{ .glob = "Nested" }});
    defer nested_simple.deinit();
    var nested_simple_analysis = try nested_simple.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer nested_simple_analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), nested_simple_analysis.subjects.items.len);
    try std.testing.expectEqualStrings(
        "src/support.zig:Namespace.Nested",
        nested_simple_analysis.subjects.items[0].identifier,
    );

    var nested_qualified = try root.forContainersMatching(&.{.{ .glob = "Namespace.Nested" }});
    defer nested_qualified.deinit();
    var nested_qualified_analysis = try nested_qualified.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer nested_qualified_analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), nested_qualified_analysis.subjects.items.len);
}

test "count measurements and summaries use selected subject facts" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var root_file = try root.inFile(&.{"src/root.zig"});
    defer root_file.deinit();
    var counts = try root_file.count();
    defer counts.deinit();
    var lines = try counts.nonBlankLines();
    defer lines.deinit();
    var measurements = try lines.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer measurements.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), measurements.items().len);
    try std.testing.expectEqual(@as(usize, 13), measurements.items()[0].value);
    try std.testing.expectEqual(CountMetric.non_blank_lines, measurements.items()[0].metric);

    const summary = try counts.summary(CheckOptions.init(std.testing.allocator, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), summary.subject_count);
    try std.testing.expectEqual(@as(usize, 0), summary.invalid_syntax_subjects);
    try std.testing.expectEqual(@as(usize, 4), summary.totals.declarations);
    try std.testing.expectEqual(@as(usize, 13), summary.totals.non_blank_lines);
}

test "count threshold rules report boundaries and guard empty scopes" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var root_file = try root.inFile(&.{"src/root.zig"});
    defer root_file.deinit();
    var counts = try root_file.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var failing = try functions.shouldBeBelow(1);
    defer failing.deinit(std.testing.allocator);
    var failed = try failing.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), failed.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.metric, failed.items()[0].kind());
    try std.testing.expectEqual(@as(u64, 1), failed.items()[0].metric.measured.unsigned);

    var passing = try functions.shouldBeBelowOrEqual(1);
    defer passing.deinit(std.testing.allocator);
    var passed = try passing.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer passed.deinit(std.testing.allocator);
    try std.testing.expect(passed.passes());

    var equal = try functions.shouldBe(1);
    defer equal.deinit(std.testing.allocator);
    var equal_result = try equal.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer equal_result.deinit(std.testing.allocator);
    try std.testing.expect(equal_result.passes());
    var above = try functions.shouldBeAbove(0);
    defer above.deinit(std.testing.allocator);
    var above_result = try above.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer above_result.deinit(std.testing.allocator);
    try std.testing.expect(above_result.passes());

    var missing = try root.withName(&.{.{ .glob = "missing.zig" }});
    defer missing.deinit();
    var missing_counts = try missing.count();
    defer missing_counts.deinit();
    var tokens = try missing_counts.tokens();
    defer tokens.deinit();
    var empty_rule = try tokens.shouldBeAbove(0);
    defer empty_rule.deinit(std.testing.allocator);
    var rejected = try empty_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, rejected.items()[0].kind());
    var allowed_options = CheckOptions.init(std.testing.allocator, std.testing.io);
    allowed_options.allow_empty_tests = true;
    var allowed = try empty_rule.check(allowed_options);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "count terminals erase as Checkable with an owned sentence" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var workers = try root.forContainersMatching(&.{.{ .glob = "Worker" }});
    defer workers.deinit();
    var counts = try workers.count();
    defer counts.deinit();
    var fields = try counts.fields();
    defer fields.deinit();
    var terminal = try fields.shouldBeAboveOrEqual(1);
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    const sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "Zig containers, with container name \"Worker\" count fields should be above or equal to 1",
        sentence,
    );
    var result = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

fn exerciseBuilderAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "fixture" });
    defer root.deinit();
    var selected = try root.inPath(&.{.{ .glob = "src/**" }});
    defer selected.deinit();
    var declarations = try selected.forDeclarationsMatching(&.{.{ .regex = "Service$" }});
    defer declarations.deinit();
    var counts = try declarations.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var terminal = try functions.shouldBeBelow(10);
    defer terminal.deinit(allocator);
    const sentence = try terminal.description(allocator);
    defer allocator.free(sentence);
}

test "metrics builder chains release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseBuilderAllocationFailures,
        .{},
    );
}
