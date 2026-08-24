const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const projection = @import("../../common/projection.zig");
const predicate_assertion = @import("../assertion/predicate.zig");
const threshold_assertion = @import("../assertion/threshold.zig");
const count_calculation = @import("../calculation/count.zig");
const custom_calculation = @import("../calculation/custom.zig");
const dependency_calculation = @import("../calculation/dependency.zig");
const structural = @import("../extraction/structural.zig");
const report_data = @import("../reporting/report_data.zig");
const report_export = @import("../reporting/export_support.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = fluentapi.CheckOptions;
pub const CountMetric = count_calculation.CountMetric;
pub const Filter = matching.Filter;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const ScopePattern = assertion.ScopePattern;
pub const StructuralMetrics = structural.StructuralMetrics;

pub const BuilderError = Allocator.Error || error{
    ExclusionWithoutSelector,
    InvalidExclusionTarget,
    InvalidPattern,
    InvalidProjectPath,
    InvalidMetricDescription,
    InvalidMetricName,
    InvalidThreshold,
    UnsupportedDependencyTarget,
    UnsupportedProjectedSelectors,
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

pub const ProjectedTargetLevel = enum {
    module,
    slice,

    pub fn targetKind(self: ProjectedTargetLevel) assertion.MetricTargetKind {
        return switch (self) {
            .module => .module,
            .slice => .slice,
        };
    }

    pub fn pluralName(self: ProjectedTargetLevel) []const u8 {
        return switch (self) {
            .module => "modules",
            .slice => "slices",
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
        var filter = self.filter.clone(allocator) catch |failure| return mapPatternFailure(failure);
        errdefer filter.deinit();
        return .{
            .evidence = try self.evidence.clone(allocator),
            .filter = filter,
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
    exclusions: std.ArrayList(ScopePattern) = .empty,

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
        try result.exclusions.ensureTotalCapacity(allocator, self.exclusions.items.len);
        for (self.exclusions.items) |exclusion| {
            result.exclusions.appendAssumeCapacity(try exclusion.clone(allocator));
        }
        return result;
    }

    fn deinit(self: *Selector, allocator: Allocator) void {
        for (self.alternatives.items) |*alternative| alternative.deinit(allocator);
        self.alternatives.deinit(allocator);
        for (self.exclusions.items) |*exclusion| exclusion.deinit(allocator);
        self.exclusions.deinit(allocator);
        self.* = undefined;
    }

    fn inheritedTarget(self: *const Selector) PatternTarget {
        return self.alternatives.items[0].evidence.target;
    }

    fn addExclusions(
        self: *Selector,
        allocator: Allocator,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!void {
        if (patterns.len == 0) return error.InvalidPattern;
        try self.exclusions.ensureUnusedCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            if (pattern.source().len == 0) return error.InvalidPattern;
            const mode: matching.MatchingMode = switch (pattern) {
                .glob => .exact,
                .regex => .partial,
            };
            for (self.alternatives.items) |*alternative| {
                alternative.filter.addExclusion(pattern, target, mode) catch |failure| {
                    return mapPatternFailure(failure);
                };
            }
            self.exclusions.appendAssumeCapacity(try ScopePattern.initExclusion(
                allocator,
                self.alternatives.items[0].evidence.selector_index,
                pattern,
                target,
                mode,
            ));
        }
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
            var positive = alternative.filter.matchesPositive(allocator, candidate) catch |failure| switch (failure) {
                error.MissingDeclarationName => false,
                error.OutOfMemory => return error.OutOfMemory,
            };
            const distinct_qualified = alternative.evidence.target == .declaration_name and
                qualified_name != null and declaration_name != null and
                !std.mem.eql(u8, declaration_name.?, qualified_name.?);
            if (distinct_qualified and !positive) {
                positive = alternative.filter.matchesPositive(allocator, .{
                    .path = path,
                    .declaration_name = qualified_name.?,
                }) catch |failure| switch (failure) {
                    error.MissingDeclarationName => unreachable,
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            if (!positive) continue;
            if (try alternative.filter.excludes(allocator, candidate)) continue;
            if (distinct_qualified and try alternative.filter.excludes(allocator, .{
                .path = path,
                .declaration_name = qualified_name.?,
            })) continue;
            return true;
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

    pub fn except(self: *const MetricsScope, patterns: []const Pattern) BuilderError!MetricsScope {
        return self.excludePatterns(patterns, null);
    }

    pub fn exceptTargeted(
        self: *const MetricsScope,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!MetricsScope {
        return self.excludePatterns(patterns, target);
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

    /// Dependency metrics are file-level in the fluent facade. Module and slice projections use
    /// the public pure `calculateDependencyMetrics` boundary with their own internal labels.
    pub fn dependency(self: *const MetricsScope) BuilderError!DependencyMetrics {
        if (self.target_level != .file) return error.UnsupportedDependencyTarget;
        return .{ .scope = try self.clone() };
    }

    /// Defines a custom metric over the scope's current file, declaration, or container subjects.
    /// Calculation contexts are borrowed and must outlive the selection and all derived rules.
    pub fn customMetric(
        self: *const MetricsScope,
        name: []const u8,
        description_value: []const u8,
        calculation: custom_calculation.CustomMetricCalculation,
    ) BuilderError!CustomMetricSelection {
        return CustomMetricSelection.initStructural(self, name, description_value, calculation);
    }

    /// Defines a custom metric over caller-projected module or slice labels. The mapper is borrowed
    /// by value; any context inside it must outlive the selection and every derived rule. Internal
    /// projected self-edges establish the complete subject universe.
    pub fn customMetricForProjection(
        self: *const MetricsScope,
        target_level: ProjectedTargetLevel,
        mapper: projection.MapFunction,
        name: []const u8,
        description_value: []const u8,
        calculation: custom_calculation.CustomMetricCalculation,
    ) BuilderError!CustomMetricSelection {
        if (self.selectors.items.len != 0) return error.UnsupportedProjectedSelectors;
        return CustomMetricSelection.initProjected(
            self,
            target_level,
            mapper,
            name,
            description_value,
            calculation,
        );
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
        for (self.selectors.items) |selector| {
            count_value += selector.alternatives.items.len + selector.exclusions.items.len;
        }
        try result.values.ensureTotalCapacity(allocator, count_value);
        for (self.selectors.items) |selector| {
            for (selector.alternatives.items) |alternative| {
                result.values.appendAssumeCapacity(try alternative.evidence.clone(allocator));
            }
            for (selector.exclusions.items) |exclusion| {
                result.values.appendAssumeCapacity(try exclusion.clone(allocator));
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

    fn excludePatterns(
        self: *const MetricsScope,
        patterns: []const Pattern,
        explicit_target: ?PatternTarget,
    ) BuilderError!MetricsScope {
        if (self.selectors.items.len == 0) return error.ExclusionWithoutSelector;
        const target = explicit_target orelse self.selectors.items[self.selectors.items.len - 1].inheritedTarget();
        if (target == .declaration_name and self.target_level == .file) return error.InvalidExclusionTarget;
        var result = try self.clone();
        errdefer result.deinit();
        try result.selectors.items[result.selectors.items.len - 1].addExclusions(
            result.allocator,
            patterns,
            target,
        );
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
            for (selector.exclusions.items) |exclusion| {
                try writer.writeAll(", except ");
                try writer.writeAll(selectorPhrase(exclusion, self.target_level));
                try writer.writeByte(' ');
                if (exclusion.syntax == .regex) try writer.writeAll("regex ");
                try writer.print("\"{f}\"", .{std.zig.fmtString(exclusion.expression)});
            }
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

    pub fn gatherReportData(self: *const CountMetrics, options: CheckOptions) anyerror!report_data.MetricsReportData {
        const summary_value = try self.summary(options);
        const scope_description = try self.scope.description(options.allocator);
        defer options.allocator.free(scope_description);
        const title = try std.fmt.allocPrint(options.allocator, "Count metrics — {s}", .{scope_description});
        defer options.allocator.free(title);
        var section = try report_data.countSection(
            options.allocator,
            title,
            summary_value.subject_count,
            summary_value.invalid_syntax_subjects,
            summary_value.totals,
        );
        var section_owned = true;
        errdefer if (section_owned) section.deinit(options.allocator);
        var data = report_data.MetricsReportData{};
        errdefer data.deinit(options.allocator);
        try data.appendSectionMove(options.allocator, &section);
        section_owned = false;
        data.sort();
        return data;
    }

    pub fn toHtml(
        self: *const CountMetrics,
        options: CheckOptions,
        export_options: report_export.MetricsExportOptions,
    ) anyerror![]u8 {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.toHtml(options.allocator, options.io, &data, export_options);
    }

    pub fn exportAsHtml(
        self: *const CountMetrics,
        options: CheckOptions,
        output_path: []const u8,
        export_options: report_export.MetricsExportOptions,
    ) anyerror!void {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.exportAsHtml(
            options.allocator,
            options.io,
            &data,
            output_path,
            export_options,
        );
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

    pub fn shouldSatisfy(
        self: *const CountMetricSelection,
        predicate: predicate_assertion.MetricPredicate,
    ) BuilderError!MetricPredicateRule {
        return metricPredicateRule(&self.scope, .{ .count = self.metric }, predicate);
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

pub const DependencyMetricKind = enum {
    afferent_coupling,
    efferent_coupling,
    instability,
    coupling_factor,

    pub fn name(self: DependencyMetricKind) []const u8 {
        return @tagName(self);
    }

    pub fn value(
        self: DependencyMetricKind,
        info: dependency_calculation.DependencyMetricInfo,
    ) assertion.MetricValue {
        return switch (self) {
            .afferent_coupling => .{ .unsigned = @intCast(info.afferent_coupling) },
            .efferent_coupling => .{ .unsigned = @intCast(info.efferent_coupling) },
            .instability => .{ .floating = info.instability },
            .coupling_factor => .{ .floating = info.coupling_factor },
        };
    }
};

pub const DependencyMetrics = struct {
    scope: MetricsScope,

    pub fn deinit(self: *DependencyMetrics) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn analyze(
        self: *const DependencyMetrics,
        options: CheckOptions,
    ) anyerror!dependency_calculation.DependencyMetricSnapshot {
        var complete = try extractFileDependencyMetrics(&self.scope, options);
        defer complete.deinit(options.allocator);
        var selected = dependency_calculation.DependencyMetricSnapshot{
            .projected_subject_count = complete.projected_subject_count,
        };
        errdefer selected.deinit(options.allocator);
        try selected.values.ensureTotalCapacity(options.allocator, complete.items().len);
        for (complete.items()) |value| {
            if (!try self.scope.matches(options.allocator, value.identifier, null, null)) continue;
            selected.values.appendAssumeCapacity(try value.clone(options.allocator));
        }
        return selected;
    }

    pub fn afferentCoupling(self: *const DependencyMetrics) BuilderError!DependencyCountSelection {
        return .{ .scope = try self.scope.clone(), .metric = .afferent_coupling };
    }

    pub fn efferentCoupling(self: *const DependencyMetrics) BuilderError!DependencyCountSelection {
        return .{ .scope = try self.scope.clone(), .metric = .efferent_coupling };
    }

    pub fn instability(self: *const DependencyMetrics) BuilderError!DependencyRatioSelection {
        return .{ .scope = try self.scope.clone(), .metric = .instability };
    }

    pub fn couplingFactor(self: *const DependencyMetrics) BuilderError!DependencyRatioSelection {
        return .{ .scope = try self.scope.clone(), .metric = .coupling_factor };
    }

    pub fn summary(self: *const DependencyMetrics, options: CheckOptions) anyerror!DependencySummary {
        var snapshot = try self.analyze(options);
        defer snapshot.deinit(options.allocator);
        var result = DependencySummary{
            .projected_subject_count = snapshot.projected_subject_count,
            .selected_subject_count = snapshot.items().len,
        };
        for (snapshot.items()) |value| {
            result.total_afferent_coupling += value.afferent_coupling;
            result.total_efferent_coupling += value.efferent_coupling;
            result.average_instability += value.instability;
            result.average_coupling_factor += value.coupling_factor;
        }
        if (result.selected_subject_count != 0) {
            const denominator = @as(f64, @floatFromInt(result.selected_subject_count));
            result.average_instability /= denominator;
            result.average_coupling_factor /= denominator;
        }
        return result;
    }

    pub fn gatherReportData(self: *const DependencyMetrics, options: CheckOptions) anyerror!report_data.MetricsReportData {
        const summary_value = try self.summary(options);
        const scope_description = try self.scope.description(options.allocator);
        defer options.allocator.free(scope_description);
        const title = try std.fmt.allocPrint(options.allocator, "Dependency metrics — {s}", .{scope_description});
        defer options.allocator.free(title);
        var section = try report_data.dependencySection(
            options.allocator,
            title,
            summary_value.projected_subject_count,
            summary_value.selected_subject_count,
            summary_value.total_afferent_coupling,
            summary_value.total_efferent_coupling,
            summary_value.average_instability,
            summary_value.average_coupling_factor,
        );
        var section_owned = true;
        errdefer if (section_owned) section.deinit(options.allocator);
        var data = report_data.MetricsReportData{};
        errdefer data.deinit(options.allocator);
        try data.appendSectionMove(options.allocator, &section);
        section_owned = false;
        data.sort();
        return data;
    }

    pub fn toHtml(
        self: *const DependencyMetrics,
        options: CheckOptions,
        export_options: report_export.MetricsExportOptions,
    ) anyerror![]u8 {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.toHtml(options.allocator, options.io, &data, export_options);
    }

    pub fn exportAsHtml(
        self: *const DependencyMetrics,
        options: CheckOptions,
        output_path: []const u8,
        export_options: report_export.MetricsExportOptions,
    ) anyerror!void {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.exportAsHtml(
            options.allocator,
            options.io,
            &data,
            output_path,
            export_options,
        );
    }
};

pub const DependencySummary = struct {
    projected_subject_count: usize = 0,
    selected_subject_count: usize = 0,
    total_afferent_coupling: usize = 0,
    total_efferent_coupling: usize = 0,
    average_instability: f64 = 0.0,
    average_coupling_factor: f64 = 0.0,
};

pub const DependencyMeasurement = struct {
    target_identifier: []u8,
    metric: DependencyMetricKind,
    value: assertion.MetricValue,

    pub fn deinit(self: *DependencyMeasurement, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        self.* = undefined;
    }
};

pub const DependencyMeasurements = struct {
    values: std.ArrayList(DependencyMeasurement) = .empty,

    pub fn deinit(self: *DependencyMeasurements, allocator: Allocator) void {
        for (self.values.items) |*value| value.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const DependencyMeasurements) []const DependencyMeasurement {
        return self.values.items;
    }
};

pub const DependencyCountSelection = struct {
    scope: MetricsScope,
    metric: DependencyMetricKind,

    pub fn deinit(self: *DependencyCountSelection) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn measure(self: *const DependencyCountSelection, options: CheckOptions) anyerror!DependencyMeasurements {
        return measureDependency(&self.scope, self.metric, options);
    }

    pub fn shouldBeBelow(self: *const DependencyCountSelection, value: usize) BuilderError!DependencyThresholdRule {
        return dependencyThreshold(&self.scope, self.metric, .below, .{ .unsigned = @intCast(value) });
    }
    pub fn shouldBeAbove(self: *const DependencyCountSelection, value: usize) BuilderError!DependencyThresholdRule {
        return dependencyThreshold(&self.scope, self.metric, .above, .{ .unsigned = @intCast(value) });
    }
    pub fn shouldBe(self: *const DependencyCountSelection, value: usize) BuilderError!DependencyThresholdRule {
        return dependencyThreshold(&self.scope, self.metric, .equal, .{ .unsigned = @intCast(value) });
    }
    pub fn shouldBeBelowOrEqual(self: *const DependencyCountSelection, value: usize) BuilderError!DependencyThresholdRule {
        return dependencyThreshold(&self.scope, self.metric, .below_or_equal, .{ .unsigned = @intCast(value) });
    }
    pub fn shouldBeAboveOrEqual(self: *const DependencyCountSelection, value: usize) BuilderError!DependencyThresholdRule {
        return dependencyThreshold(&self.scope, self.metric, .above_or_equal, .{ .unsigned = @intCast(value) });
    }

    pub fn shouldSatisfy(
        self: *const DependencyCountSelection,
        predicate: predicate_assertion.MetricPredicate,
    ) BuilderError!MetricPredicateRule {
        return metricPredicateRule(&self.scope, .{ .dependency = self.metric }, predicate);
    }
};

pub const DependencyRatioSelection = struct {
    scope: MetricsScope,
    metric: DependencyMetricKind,

    pub fn deinit(self: *DependencyRatioSelection) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn measure(self: *const DependencyRatioSelection, options: CheckOptions) anyerror!DependencyMeasurements {
        return measureDependency(&self.scope, self.metric, options);
    }

    pub fn shouldBeBelow(self: *const DependencyRatioSelection, value: f64) BuilderError!DependencyThresholdRule {
        return self.threshold(.below, value);
    }
    pub fn shouldBeAbove(self: *const DependencyRatioSelection, value: f64) BuilderError!DependencyThresholdRule {
        return self.threshold(.above, value);
    }
    pub fn shouldBe(self: *const DependencyRatioSelection, value: f64) BuilderError!DependencyThresholdRule {
        return self.threshold(.equal, value);
    }
    pub fn shouldBeBelowOrEqual(self: *const DependencyRatioSelection, value: f64) BuilderError!DependencyThresholdRule {
        return self.threshold(.below_or_equal, value);
    }
    pub fn shouldBeAboveOrEqual(self: *const DependencyRatioSelection, value: f64) BuilderError!DependencyThresholdRule {
        return self.threshold(.above_or_equal, value);
    }

    pub fn shouldSatisfy(
        self: *const DependencyRatioSelection,
        predicate: predicate_assertion.MetricPredicate,
    ) BuilderError!MetricPredicateRule {
        return metricPredicateRule(&self.scope, .{ .dependency = self.metric }, predicate);
    }

    fn threshold(
        self: *const DependencyRatioSelection,
        comparison: assertion.MetricComparison,
        value: f64,
    ) BuilderError!DependencyThresholdRule {
        if (!std.math.isFinite(value)) return error.InvalidThreshold;
        return dependencyThreshold(&self.scope, self.metric, comparison, .{ .floating = value });
    }
};

pub const DependencyThresholdRule = struct {
    scope: MetricsScope,
    metric: DependencyMetricKind,
    comparison: assertion.MetricComparison,
    threshold_value: assertion.MetricValue,

    pub fn deinit(self: *DependencyThresholdRule, _: Allocator) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const DependencyThresholdRule, allocator: Allocator) Allocator.Error![]u8 {
        const scope_description = try self.scope.description(allocator);
        defer allocator.free(scope_description);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        output.writer.print(
            "{s} dependency metric {s} should be {s} ",
            .{ scope_description, self.metric.name(), comparisonPhrase(self.comparison) },
        ) catch return error.OutOfMemory;
        writeMetricValue(&output.writer, self.threshold_value) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn check(self: *const DependencyThresholdRule, options: CheckOptions) anyerror!assertion.ViolationList {
        var measurements = try measureDependency(&self.scope, self.metric, options);
        defer measurements.deinit(options.allocator);
        var evidence = try self.scope.scopePatterns(options.allocator);
        defer evidence.deinit(options.allocator);
        if (try assertion.guardEmptyTest(
            options.allocator,
            measurements.items().len,
            options.allow_empty_tests,
            "metrics.dependency",
            evidence.items(),
            .should,
        )) |guarded| return guarded;

        var result = assertion.ViolationList{};
        errdefer result.deinit(options.allocator);
        for (measurements.items()) |measurement| {
            if (try threshold_assertion.passes(measurement.value, self.comparison, self.threshold_value)) continue;
            var payload = try assertion.MetricViolation.init(
                options.allocator,
                measurement.target_identifier,
                .file,
                self.metric.name(),
                measurement.value,
                self.comparison,
                self.threshold_value,
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

fn dependencyThreshold(
    scope: *const MetricsScope,
    metric: DependencyMetricKind,
    comparison: assertion.MetricComparison,
    threshold_value: assertion.MetricValue,
) BuilderError!DependencyThresholdRule {
    return .{
        .scope = try scope.clone(),
        .metric = metric,
        .comparison = comparison,
        .threshold_value = threshold_value,
    };
}

fn measureDependency(
    scope: *const MetricsScope,
    metric: DependencyMetricKind,
    options: CheckOptions,
) anyerror!DependencyMeasurements {
    var builder = DependencyMetrics{ .scope = try scope.clone() };
    defer builder.deinit();
    var snapshot = try builder.analyze(options);
    defer snapshot.deinit(options.allocator);
    var result = DependencyMeasurements{};
    errdefer result.deinit(options.allocator);
    try result.values.ensureTotalCapacity(options.allocator, snapshot.items().len);
    for (snapshot.items()) |value| {
        result.values.appendAssumeCapacity(.{
            .target_identifier = try options.allocator.dupe(u8, value.identifier),
            .metric = metric,
            .value = metric.value(value),
        });
    }
    return result;
}

fn extractFileDependencyMetrics(
    scope: *const MetricsScope,
    options: CheckOptions,
) anyerror!dependency_calculation.DependencyMetricSnapshot {
    var diagnostics = common_error.ErrorContext.init(options.allocator);
    defer diagnostics.deinit();
    var graph = try extraction.extractProjectGraph(
        options.allocator,
        options.io,
        scope.owned_locator,
        options.working_directory,
        options.extraction,
        options.clear_cache,
        &diagnostics,
    );
    defer graph.deinit(options.allocator);

    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(options.allocator);
    var label_set = std.StringHashMap(void).init(options.allocator);
    defer label_set.deinit();
    for (graph.items()) |edge| {
        if (edge.external or !std.mem.eql(u8, edge.source, edge.target)) continue;
        try labels.append(options.allocator, edge.source);
        try label_set.put(edge.source, {});
    }
    const mapper_context = FileEdgeProjection{ .labels = &label_set };
    var edges = try projection.projectEdges(
        options.allocator,
        &graph,
        projection.MapFunction.fromContext(FileEdgeProjection, &mapper_context, FileEdgeProjection.map),
    );
    defer edges.deinit(options.allocator);
    return dependency_calculation.calculateDependencyMetrics(
        options.allocator,
        labels.items,
        edges.items(),
    );
}

const FileEdgeProjection = struct {
    labels: *const std.StringHashMap(void),

    fn map(self: *const FileEdgeProjection, edge: *const extraction.Edge) ?projection.MappedEdge {
        if (edge.external or std.mem.eql(u8, edge.source, edge.target)) return null;
        if (!self.labels.contains(edge.source) or !self.labels.contains(edge.target)) return null;
        return .{ .source_label = edge.source, .target_label = edge.target };
    }
};

const BuiltInMetricSelection = union(enum) {
    count: CountMetric,
    dependency: DependencyMetricKind,

    fn name(self: BuiltInMetricSelection) []const u8 {
        return switch (self) {
            .count => |metric| metric.name(),
            .dependency => |metric| metric.name(),
        };
    }

    fn ruleId(self: BuiltInMetricSelection) []const u8 {
        return switch (self) {
            .count => "metrics.count",
            .dependency => "metrics.dependency",
        };
    }

    fn sentenceFragment(self: BuiltInMetricSelection) []const u8 {
        return switch (self) {
            .count => "count",
            .dependency => "dependency metric",
        };
    }

    fn value(self: BuiltInMetricSelection, info: custom_calculation.CustomMetricInfo) !assertion.MetricValue {
        return switch (self) {
            .count => |metric| .{ .unsigned = @intCast(metric.measure(info.structural.?)) },
            .dependency => |metric| dependencyValueFromFacts(metric, info.dependency orelse
                return error.MissingDependencyMetricFacts),
        };
    }
};

/// Executable arbitrary predicate over one selected built-in metric. Predicate contexts are
/// borrowed under the same lifetime contract as custom metric callbacks.
pub const MetricPredicateRule = struct {
    scope: MetricsScope,
    metric: BuiltInMetricSelection,
    predicate: predicate_assertion.MetricPredicate,

    pub fn deinit(self: *MetricPredicateRule, _: Allocator) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const MetricPredicateRule, allocator: Allocator) Allocator.Error![]u8 {
        const scope_description = try self.scope.description(allocator);
        defer allocator.free(scope_description);
        return std.fmt.allocPrint(
            allocator,
            "{s} {s} {s} should satisfy its metric assertion",
            .{ scope_description, self.metric.sentenceFragment(), self.metric.name() },
        );
    }

    pub fn check(self: *const MetricPredicateRule, options: CheckOptions) anyerror!assertion.ViolationList {
        var analysis = try analyzeStructuralMetricSubjects(&self.scope, options);
        defer analysis.deinit(options.allocator);
        var evidence = try self.scope.scopePatterns(options.allocator);
        defer evidence.deinit(options.allocator);
        if (try assertion.guardEmptyTest(
            options.allocator,
            analysis.subjects.items.len,
            options.allow_empty_tests,
            self.metric.ruleId(),
            evidence.items(),
            .should,
        )) |guarded| return guarded;

        var subjects: std.ArrayList(predicate_assertion.MetricPredicateSubject) = .empty;
        defer subjects.deinit(options.allocator);
        try subjects.ensureTotalCapacity(options.allocator, analysis.subjects.items.len);
        for (analysis.subjects.items) |info| {
            subjects.appendAssumeCapacity(.{
                .info = info,
                .metric_name = self.metric.name(),
                .value = try self.metric.value(info),
            });
        }
        return predicate_assertion.gatherMetricPredicateViolations(
            options.allocator,
            subjects.items,
            self.predicate,
        );
    }
};

fn metricPredicateRule(
    scope: *const MetricsScope,
    metric: BuiltInMetricSelection,
    predicate: predicate_assertion.MetricPredicate,
) BuilderError!MetricPredicateRule {
    return .{ .scope = try scope.clone(), .metric = metric, .predicate = predicate };
}

fn dependencyValueFromFacts(
    metric: DependencyMetricKind,
    facts: custom_calculation.CustomDependencyFacts,
) assertion.MetricValue {
    return switch (metric) {
        .afferent_coupling => .{ .unsigned = @intCast(facts.afferent_coupling) },
        .efferent_coupling => .{ .unsigned = @intCast(facts.efferent_coupling) },
        .instability => .{ .floating = facts.instability },
        .coupling_factor => .{ .floating = facts.coupling_factor },
    };
}

const ProjectedMetricTarget = struct {
    level: ProjectedTargetLevel,
    mapper: projection.MapFunction,
};

/// Owned custom metric definition and lazy subject source. Name and description storage belong to
/// this selection; callback and mapper contexts remain explicitly borrowed.
pub const CustomMetricSelection = struct {
    scope: MetricsScope,
    name: []u8,
    description_value: []u8,
    calculation: custom_calculation.CustomMetricCalculation,
    projected_target: ?ProjectedMetricTarget = null,

    fn initStructural(
        scope: *const MetricsScope,
        name: []const u8,
        description_value: []const u8,
        calculation: custom_calculation.CustomMetricCalculation,
    ) BuilderError!CustomMetricSelection {
        return initOwned(scope, name, description_value, calculation, null);
    }

    fn initProjected(
        scope: *const MetricsScope,
        level: ProjectedTargetLevel,
        mapper: projection.MapFunction,
        name: []const u8,
        description_value: []const u8,
        calculation: custom_calculation.CustomMetricCalculation,
    ) BuilderError!CustomMetricSelection {
        return initOwned(
            scope,
            name,
            description_value,
            calculation,
            .{ .level = level, .mapper = mapper },
        );
    }

    fn initOwned(
        scope: *const MetricsScope,
        name: []const u8,
        description_value: []const u8,
        calculation: custom_calculation.CustomMetricCalculation,
        projected_target: ?ProjectedMetricTarget,
    ) BuilderError!CustomMetricSelection {
        if (!hasText(name)) return error.InvalidMetricName;
        if (!hasText(description_value)) return error.InvalidMetricDescription;
        var owned_scope = try scope.clone();
        errdefer owned_scope.deinit();
        const owned_name = try scope.allocator.dupe(u8, name);
        errdefer scope.allocator.free(owned_name);
        return .{
            .scope = owned_scope,
            .name = owned_name,
            .description_value = try scope.allocator.dupe(u8, description_value),
            .calculation = calculation,
            .projected_target = projected_target,
        };
    }

    pub fn clone(self: *const CustomMetricSelection) BuilderError!CustomMetricSelection {
        return initOwned(
            &self.scope,
            self.name,
            self.description_value,
            self.calculation,
            self.projected_target,
        );
    }

    pub fn deinit(self: *CustomMetricSelection) void {
        const allocator = self.scope.allocator;
        allocator.free(self.name);
        allocator.free(self.description_value);
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn metricName(self: *const CustomMetricSelection) []const u8 {
        return self.name;
    }

    pub fn metricDescription(self: *const CustomMetricSelection) []const u8 {
        return self.description_value;
    }

    pub fn targetKind(self: *const CustomMetricSelection) assertion.MetricTargetKind {
        if (self.projected_target) |target| return target.level.targetKind();
        return self.scope.target_level.violationKind();
    }

    pub fn measure(
        self: *const CustomMetricSelection,
        options: CheckOptions,
    ) anyerror!custom_calculation.CustomMetricMeasurements {
        var analysis = try analyzeCustomMetricSubjects(self, options);
        defer analysis.deinit(options.allocator);
        return custom_calculation.measure(options.allocator, analysis.subjects.items, self.definition());
    }

    pub fn gatherReportData(
        self: *const CustomMetricSelection,
        options: CheckOptions,
    ) anyerror!report_data.MetricsReportData {
        var measurements = try self.measure(options);
        defer measurements.deinit(options.allocator);
        const subjects = try self.subjectDescription(options.allocator);
        defer options.allocator.free(subjects);
        const title = try std.fmt.allocPrint(
            options.allocator,
            "Custom metric {s} ({s}) — {s}",
            .{ self.name, self.description_value, subjects },
        );
        defer options.allocator.free(title);
        var section = try report_data.customSection(options.allocator, title, &measurements);
        var section_owned = true;
        errdefer if (section_owned) section.deinit(options.allocator);
        var data = report_data.MetricsReportData{};
        errdefer data.deinit(options.allocator);
        try data.appendSectionMove(options.allocator, &section);
        section_owned = false;
        data.sort();
        return data;
    }

    pub fn toHtml(
        self: *const CustomMetricSelection,
        options: CheckOptions,
        export_options: report_export.MetricsExportOptions,
    ) anyerror![]u8 {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.toHtml(options.allocator, options.io, &data, export_options);
    }

    pub fn exportAsHtml(
        self: *const CustomMetricSelection,
        options: CheckOptions,
        output_path: []const u8,
        export_options: report_export.MetricsExportOptions,
    ) anyerror!void {
        var data = try self.gatherReportData(options);
        defer data.deinit(options.allocator);
        return report_export.exportAsHtml(
            options.allocator,
            options.io,
            &data,
            output_path,
            export_options,
        );
    }

    pub fn shouldBeBelow(
        self: *const CustomMetricSelection,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        return self.threshold(.below, threshold_value);
    }

    pub fn shouldBeAbove(
        self: *const CustomMetricSelection,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        return self.threshold(.above, threshold_value);
    }

    pub fn shouldBe(
        self: *const CustomMetricSelection,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        return self.threshold(.equal, threshold_value);
    }

    pub fn shouldBeBelowOrEqual(
        self: *const CustomMetricSelection,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        return self.threshold(.below_or_equal, threshold_value);
    }

    pub fn shouldBeAboveOrEqual(
        self: *const CustomMetricSelection,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        return self.threshold(.above_or_equal, threshold_value);
    }

    pub fn shouldSatisfy(
        self: *const CustomMetricSelection,
        predicate: custom_calculation.CustomMetricPredicate,
    ) BuilderError!CustomMetricPredicateRule {
        return .{ .selection = try self.clone(), .predicate = predicate };
    }

    fn threshold(
        self: *const CustomMetricSelection,
        comparison: assertion.MetricComparison,
        threshold_value: assertion.MetricValue,
    ) BuilderError!CustomMetricThresholdRule {
        custom_calculation.validateValue(threshold_value) catch return error.InvalidThreshold;
        return .{
            .selection = try self.clone(),
            .comparison = comparison,
            .threshold_value = threshold_value,
        };
    }

    fn definition(self: *const CustomMetricSelection) custom_calculation.CustomMetricDefinition {
        return .{
            .name = self.name,
            .description = self.description_value,
            .calculation = self.calculation,
        };
    }

    fn subjectDescription(self: *const CustomMetricSelection, allocator: Allocator) Allocator.Error![]u8 {
        if (self.projected_target) |target| {
            return std.fmt.allocPrint(allocator, "projected Zig {s}", .{target.level.pluralName()});
        }
        return self.scope.description(allocator);
    }
};

pub const CustomMetricThresholdRule = struct {
    selection: CustomMetricSelection,
    comparison: assertion.MetricComparison,
    threshold_value: assertion.MetricValue,

    pub fn deinit(self: *CustomMetricThresholdRule, _: Allocator) void {
        self.selection.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const CustomMetricThresholdRule, allocator: Allocator) Allocator.Error![]u8 {
        const subjects = try self.selection.subjectDescription(allocator);
        defer allocator.free(subjects);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        output.writer.print(
            "{s} custom metric {s} ({s}) should be {s} ",
            .{
                subjects,
                self.selection.name,
                self.selection.description_value,
                comparisonPhrase(self.comparison),
            },
        ) catch return error.OutOfMemory;
        writeMetricValue(&output.writer, self.threshold_value) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn check(self: *const CustomMetricThresholdRule, options: CheckOptions) anyerror!assertion.ViolationList {
        var analysis = try analyzeCustomMetricSubjects(&self.selection, options);
        defer analysis.deinit(options.allocator);
        if (try guardCustomMetricEmpty(&self.selection, analysis.subjects.items.len, options)) |guarded| {
            return guarded;
        }
        return custom_calculation.gatherThresholdViolations(
            options.allocator,
            analysis.subjects.items,
            self.selection.definition(),
            self.comparison,
            self.threshold_value,
        );
    }
};

pub const CustomMetricPredicateRule = struct {
    selection: CustomMetricSelection,
    predicate: custom_calculation.CustomMetricPredicate,

    pub fn deinit(self: *CustomMetricPredicateRule, _: Allocator) void {
        self.selection.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const CustomMetricPredicateRule, allocator: Allocator) Allocator.Error![]u8 {
        const subjects = try self.selection.subjectDescription(allocator);
        defer allocator.free(subjects);
        return std.fmt.allocPrint(
            allocator,
            "{s} custom metric {s} ({s}) should satisfy its custom assertion",
            .{ subjects, self.selection.name, self.selection.description_value },
        );
    }

    pub fn check(self: *const CustomMetricPredicateRule, options: CheckOptions) anyerror!assertion.ViolationList {
        var analysis = try analyzeCustomMetricSubjects(&self.selection, options);
        defer analysis.deinit(options.allocator);
        if (try guardCustomMetricEmpty(&self.selection, analysis.subjects.items.len, options)) |guarded| {
            return guarded;
        }
        return custom_calculation.gatherPredicateViolations(
            options.allocator,
            analysis.subjects.items,
            self.selection.definition(),
            self.predicate,
        );
    }
};

const CustomMetricSubjectAnalysis = struct {
    structural_analysis: ?MetricAnalysis = null,
    dependency_analysis: ?dependency_calculation.DependencyMetricSnapshot = null,
    subjects: std.ArrayList(custom_calculation.CustomMetricInfo) = .empty,

    fn deinit(self: *CustomMetricSubjectAnalysis, allocator: Allocator) void {
        self.subjects.deinit(allocator);
        if (self.dependency_analysis) |*analysis| analysis.deinit(allocator);
        if (self.structural_analysis) |*analysis| analysis.deinit(allocator);
        self.* = undefined;
    }
};

fn analyzeCustomMetricSubjects(
    selection: *const CustomMetricSelection,
    options: CheckOptions,
) anyerror!CustomMetricSubjectAnalysis {
    if (selection.projected_target) |target| {
        return analyzeProjectedCustomMetricSubjects(selection, target, options);
    }
    return analyzeStructuralMetricSubjects(&selection.scope, options);
}

fn analyzeStructuralMetricSubjects(
    scope: *const MetricsScope,
    options: CheckOptions,
) anyerror!CustomMetricSubjectAnalysis {
    var structural_analysis = try scope.analyze(options);
    errdefer structural_analysis.deinit(options.allocator);
    var dependency_analysis: ?dependency_calculation.DependencyMetricSnapshot = null;
    errdefer if (dependency_analysis) |*analysis| analysis.deinit(options.allocator);
    if (scope.target_level == .file) {
        dependency_analysis = try extractFileDependencyMetrics(scope, options);
    }

    var subjects: std.ArrayList(custom_calculation.CustomMetricInfo) = .empty;
    errdefer subjects.deinit(options.allocator);
    try subjects.ensureTotalCapacity(options.allocator, structural_analysis.subjects.items.len);
    for (structural_analysis.subjects.items) |subject| {
        const dependency = if (dependency_analysis) |*analysis|
            if (analysis.find(subject.identifier)) |value| customDependencyFacts(value.*) else null
        else
            null;
        subjects.appendAssumeCapacity(.{
            .identifier = subject.identifier,
            .name = subject.name,
            .qualified_name = subject.qualified_name,
            .file_path = subject.file_path,
            .target_kind = subject.target_level.violationKind(),
            .syntax_valid = subject.syntax_valid,
            .structural = subject.metrics,
            .dependency = dependency,
            .source_file_count = 1,
        });
    }
    return .{
        .structural_analysis = structural_analysis,
        .dependency_analysis = dependency_analysis,
        .subjects = subjects,
    };
}

fn analyzeProjectedCustomMetricSubjects(
    selection: *const CustomMetricSelection,
    target: ProjectedMetricTarget,
    options: CheckOptions,
) anyerror!CustomMetricSubjectAnalysis {
    var diagnostics = common_error.ErrorContext.init(options.allocator);
    defer diagnostics.deinit();
    var graph = try extraction.extractProjectGraph(
        options.allocator,
        options.io,
        selection.scope.owned_locator,
        options.working_directory,
        options.extraction,
        options.clear_cache,
        &diagnostics,
    );
    defer graph.deinit(options.allocator);
    var projected_edges = try projection.projectEdges(options.allocator, &graph, target.mapper);
    defer projected_edges.deinit(options.allocator);

    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(options.allocator);
    for (projected_edges.items()) |edge| {
        if (!std.mem.eql(u8, edge.source_label, edge.target_label)) continue;
        if (!projectedEdgeHasInternalEvidence(edge)) continue;
        try labels.append(options.allocator, edge.source_label);
    }
    var dependency_analysis = try dependency_calculation.calculateDependencyMetrics(
        options.allocator,
        labels.items,
        projected_edges.items(),
    );
    errdefer dependency_analysis.deinit(options.allocator);
    var subjects: std.ArrayList(custom_calculation.CustomMetricInfo) = .empty;
    errdefer subjects.deinit(options.allocator);
    try subjects.ensureTotalCapacity(options.allocator, dependency_analysis.items().len);
    for (dependency_analysis.items()) |dependency| {
        subjects.appendAssumeCapacity(.{
            .identifier = dependency.identifier,
            .name = dependency.identifier,
            .target_kind = target.level.targetKind(),
            .dependency = customDependencyFacts(dependency),
            .source_file_count = try projectedSourceFileCount(
                options.allocator,
                projected_edges.items(),
                dependency.identifier,
            ),
        });
    }
    return .{ .dependency_analysis = dependency_analysis, .subjects = subjects };
}

fn customDependencyFacts(
    dependency: dependency_calculation.DependencyMetricInfo,
) custom_calculation.CustomDependencyFacts {
    return .{
        .afferent_coupling = dependency.afferent_coupling,
        .efferent_coupling = dependency.efferent_coupling,
        .instability = dependency.instability,
        .coupling_factor = dependency.coupling_factor,
    };
}

fn projectedEdgeHasInternalEvidence(edge: projection.ProjectedEdge) bool {
    for (edge.evidence()) |evidence| if (!evidence.external) return true;
    return false;
}

fn projectedSourceFileCount(
    allocator: Allocator,
    edges: []const projection.ProjectedEdge,
    label: []const u8,
) Allocator.Error!usize {
    var sources = std.StringHashMap(void).init(allocator);
    defer sources.deinit();
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.source_label, label) or
            !std.mem.eql(u8, edge.target_label, label)) continue;
        for (edge.evidence()) |evidence| {
            if (evidence.external or !std.mem.eql(u8, evidence.source, evidence.target)) continue;
            try sources.put(evidence.source, {});
        }
    }
    return sources.count();
}

fn guardCustomMetricEmpty(
    selection: *const CustomMetricSelection,
    matched_count: usize,
    options: CheckOptions,
) anyerror!?assertion.ViolationList {
    var evidence = try selection.scope.scopePatterns(options.allocator);
    defer evidence.deinit(options.allocator);
    return assertion.guardEmptyTest(
        options.allocator,
        matched_count,
        options.allow_empty_tests,
        "metrics.custom",
        evidence.items(),
        .should,
    );
}

fn hasText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn writeMetricValue(writer: *std.Io.Writer, value: assertion.MetricValue) std.Io.Writer.Error!void {
    switch (value) {
        .signed => |number| try writer.print("{d}", .{number}),
        .unsigned => |number| try writer.print("{d}", .{number}),
        .floating => |number| try writer.print("{d}", .{number}),
    }
}

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

test "metric exclusions cover file simple-name and qualified declaration-name candidates" {
    const options = CheckOptions.init(std.testing.allocator, std.testing.io);
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    try std.testing.expectError(error.ExclusionWithoutSelector, root.except(&.{.{ .glob = "generated/**" }}));

    var source = try root.inPath(&.{.{ .glob = "src/**" }});
    defer source.deinit();
    var without_support = try source.exceptTargeted(&.{.{ .glob = "support.zig" }}, .filename);
    defer without_support.deinit();
    var file_analysis = try without_support.analyze(options);
    defer file_analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), file_analysis.subjects.items.len);
    try std.testing.expectEqualStrings("src/root.zig", file_analysis.subjects.items[0].identifier);
    try std.testing.expectError(
        error.InvalidExclusionTarget,
        source.exceptTargeted(&.{.{ .glob = "Worker" }}, .declaration_name),
    );

    var declarations = try root.forDeclarationsMatching(&.{.{ .glob = "*" }});
    defer declarations.deinit();
    var without_nested = try declarations.except(&.{.{ .glob = "Namespace.Nested" }});
    defer without_nested.deinit();
    var nested_analysis = try without_nested.analyze(options);
    defer nested_analysis.deinit(std.testing.allocator);
    var namespace_seen = false;
    for (nested_analysis.subjects.items) |subject| {
        const qualified = subject.qualified_name orelse subject.name;
        try std.testing.expect(!std.mem.eql(u8, qualified, "Namespace.Nested"));
        if (std.mem.eql(u8, qualified, "Namespace")) namespace_seen = true;
    }
    try std.testing.expect(namespace_seen);
    var without_support_declarations = try without_nested.exceptTargeted(
        &.{.{ .glob = "support.zig" }},
        .filename,
    );
    defer without_support_declarations.deinit();
    var declaration_analysis = try without_support_declarations.analyze(options);
    defer declaration_analysis.deinit(std.testing.allocator);
    for (declaration_analysis.subjects.items) |subject| {
        try std.testing.expect(!std.mem.eql(u8, subject.qualified_name orelse subject.name, "Namespace.Nested"));
        try std.testing.expect(!std.mem.eql(u8, subject.file_path, "src/support.zig"));
    }
    var original_analysis = try declarations.analyze(options);
    defer original_analysis.deinit(std.testing.allocator);
    try std.testing.expect(original_analysis.subjects.items.len > declaration_analysis.subjects.items.len);

    const description = try without_support_declarations.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "Zig declarations, with declaration name \"*\", except with declaration name \"Namespace.Nested\", except with name \"support.zig\"",
        description,
    );
    var evidence = try without_support_declarations.scopePatterns(std.testing.allocator);
    defer evidence.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), evidence.items().len);
    try std.testing.expect(evidence.items()[1].is_exclusion);
    try std.testing.expectEqual(PatternTarget.filename, evidence.items()[2].target);
}

test "container exclusions keep target-level vocabulary in descriptions" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var containers = try root.forContainersMatching(&.{.{ .glob = "*" }});
    defer containers.deinit();
    var without_worker = try containers.except(&.{.{ .regex = "^Worker$" }});
    defer without_worker.deinit();
    var analysis = try without_worker.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer analysis.deinit(std.testing.allocator);
    for (analysis.subjects.items) |subject| try std.testing.expect(!std.mem.eql(u8, subject.name, "Worker"));
    const description = try without_worker.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "Zig containers, with container name \"*\", except with container name regex \"^Worker$\"",
        description,
    );
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

test "file dependency metrics preserve the full-project denominator after selection" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();
    var analysis = try dependencies.analyze(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), analysis.projected_subject_count);
    try std.testing.expectEqual(@as(usize, 1), analysis.items().len);
    const a = analysis.items()[0];
    try std.testing.expectEqualStrings("src/a.zig", a.identifier);
    try std.testing.expectEqual(@as(usize, 0), a.afferent_coupling);
    try std.testing.expectEqual(@as(usize, 2), a.efferent_coupling);
    try std.testing.expectEqual(@as(f64, 1.0), a.instability);
    try std.testing.expectEqual(@as(f64, 0.25), a.coupling_factor);

    const summary = try dependencies.summary(CheckOptions.init(std.testing.allocator, std.testing.io));
    try std.testing.expectEqual(@as(usize, 5), summary.projected_subject_count);
    try std.testing.expectEqual(@as(usize, 1), summary.selected_subject_count);
    try std.testing.expectEqual(@as(usize, 2), summary.total_efferent_coupling);
    try std.testing.expectEqual(@as(f64, 1.0), summary.average_instability);
    try std.testing.expectEqual(@as(f64, 0.25), summary.average_coupling_factor);
}

test "dependency summary aggregates the complete fixture exactly" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var dependencies = try root.dependency();
    defer dependencies.deinit();
    const summary = try dependencies.summary(CheckOptions.init(std.testing.allocator, std.testing.io));

    try std.testing.expectEqual(@as(usize, 5), summary.projected_subject_count);
    try std.testing.expectEqual(@as(usize, 5), summary.selected_subject_count);
    try std.testing.expectEqual(@as(usize, 3), summary.total_afferent_coupling);
    try std.testing.expectEqual(@as(usize, 3), summary.total_efferent_coupling);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), summary.average_instability, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), summary.average_coupling_factor, 0.000_001);
}

test "dependency count and ratio measurements retain numeric types" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/b.zig"});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();
    var afferent = try dependencies.afferentCoupling();
    defer afferent.deinit();
    var incoming = try afferent.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer incoming.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), incoming.items()[0].value.unsigned);

    var instability_selection = try dependencies.instability();
    defer instability_selection.deinit();
    var instability_values = try instability_selection.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer instability_values.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0.5), instability_values.items()[0].value.floating);
}

test "dependency thresholds use shared violations and empty guards" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();
    var efferent = try dependencies.efferentCoupling();
    defer efferent.deinit();
    var count_rule = try efferent.shouldBeBelowOrEqual(1);
    defer count_rule.deinit(std.testing.allocator);
    var count_result = try count_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer count_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), count_result.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.metric, count_result.items()[0].kind());
    try std.testing.expectEqualStrings("efferent_coupling", count_result.items()[0].metric.metric_name);

    var instability_selection = try dependencies.instability();
    defer instability_selection.deinit();
    var ratio_rule = try instability_selection.shouldBe(1.0);
    defer ratio_rule.deinit(std.testing.allocator);
    var ratio_result = try ratio_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer ratio_result.deinit(std.testing.allocator);
    try std.testing.expect(ratio_result.passes());
    try std.testing.expectError(error.InvalidThreshold, instability_selection.shouldBeBelow(std.math.nan(f64)));

    var missing = try root.withName(&.{.{ .glob = "missing.zig" }});
    defer missing.deinit();
    var missing_dependencies = try missing.dependency();
    defer missing_dependencies.deinit();
    var factor = try missing_dependencies.couplingFactor();
    defer factor.deinit();
    var empty_rule = try factor.shouldBeBelow(1.0);
    defer empty_rule.deinit(std.testing.allocator);
    var empty_result = try empty_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer empty_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, empty_result.items()[0].kind());
}

test "dependency terminals erase as Checkable and declaration scopes are rejected" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var declarations = try root.forDeclarationsMatching(&.{.{ .glob = "*" }});
    defer declarations.deinit();
    try std.testing.expectError(error.UnsupportedDependencyTarget, declarations.dependency());

    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();
    var factor = try dependencies.couplingFactor();
    defer factor.deinit();
    var terminal = try factor.shouldBeBelowOrEqual(0.25);
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    const sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "Zig project files, in file \"src/a.zig\" dependency metric coupling_factor should be below or equal to 0.25",
        sentence,
    );
    var result = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

fn exerciseDependencyBuilderAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "fixture" });
    defer root.deinit();
    var selected = try root.inPath(&.{.{ .glob = "src/**" }});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();
    var instability_selection = try dependencies.instability();
    defer instability_selection.deinit();
    var terminal = try instability_selection.shouldBeBelowOrEqual(0.75);
    defer terminal.deinit(allocator);
    const sentence = try terminal.description(allocator);
    defer allocator.free(sentence);
}

test "dependency metric builder chains release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDependencyBuilderAllocationFailures,
        .{},
    );
}

fn dependencyWeightedLines(_: Allocator, info: custom_calculation.CustomMetricInfo) !assertion.MetricValue {
    if (info.target_kind != .file or info.file_path == null or info.structural == null or info.dependency == null) {
        return error.IncompleteFileMetricInfo;
    }
    return .{ .unsigned = @intCast(
        info.structural.?.non_blank_lines + info.dependency.?.efferent_coupling,
    ) };
}

fn declarationOrContainerRatio(
    _: Allocator,
    info: custom_calculation.CustomMetricInfo,
) !assertion.MetricValue {
    if (info.structural == null or info.file_path == null) return error.IncompleteStructuralMetricInfo;
    return switch (info.target_kind) {
        .declaration => .{ .signed = @intCast(info.structural.?.tokens) },
        .container => .{ .floating = @as(f64, @floatFromInt(info.structural.?.functions)) /
            @as(f64, @floatFromInt(@max(info.structural.?.fields, 1))) },
        else => error.UnexpectedStructuralTarget,
    };
}

fn metricFixtureGroup(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "src/a.zig")) return "api";
    if (std.mem.eql(u8, path, "src/b.zig") or std.mem.eql(u8, path, "src/c.zig")) return "domain";
    if (std.mem.eql(u8, path, "src/isolated.zig")) return "isolated";
    if (std.mem.eql(u8, path, "build.zig")) return "build";
    return "external";
}

fn projectMetricFixture(edge: *const extraction.Edge) ?projection.MappedEdge {
    return .{
        .source_label = metricFixtureGroup(edge.source),
        .target_label = if (edge.external) "external" else metricFixtureGroup(edge.target),
    };
}

fn projectedSourceFiles(_: Allocator, info: custom_calculation.CustomMetricInfo) !assertion.MetricValue {
    if ((info.target_kind != .module and info.target_kind != .slice) or
        info.file_path != null or info.structural != null or info.dependency == null)
    {
        return error.InvalidProjectedMetricInfo;
    }
    return .{ .unsigned = @intCast(info.source_file_count) };
}

fn projectedInstability(_: Allocator, info: custom_calculation.CustomMetricInfo) !assertion.MetricValue {
    return .{ .floating = info.dependency.?.instability };
}

fn findCustomMeasurement(
    measurements: *const custom_calculation.CustomMetricMeasurements,
    identifier: []const u8,
) ?*const custom_calculation.CustomMetricMeasurement {
    for (measurements.items()) |*measurement| {
        if (std.mem.eql(u8, measurement.target_identifier, identifier)) return measurement;
    }
    return null;
}

test "custom file metrics receive structural and dependency-safe views" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var metric = try selected.customMetric(
        "dependency_weighted_lines",
        "non-blank lines plus distinct outgoing file dependencies",
        custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
    );
    defer metric.deinit();
    var measurements = try metric.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer measurements.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dependency_weighted_lines", metric.metricName());
    try std.testing.expectEqual(assertion.MetricTargetKind.file, metric.targetKind());
    try std.testing.expectEqual(@as(usize, 1), measurements.items().len);
    try std.testing.expectEqualStrings("src/a.zig", measurements.items()[0].target_identifier);
    try std.testing.expectEqual(@as(u64, 8), measurements.items()[0].value.unsigned);
}

test "custom declaration and container metrics preserve signed and floating values" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var declaration_scope = try root.forDeclarationsMatching(&.{.{ .glob = "choose" }});
    defer declaration_scope.deinit();
    var declaration_metric = try declaration_scope.customMetric(
        "token_score",
        "signed declaration token score",
        custom_calculation.CustomMetricCalculation.fromStateless(declarationOrContainerRatio),
    );
    defer declaration_metric.deinit();
    var declaration_values = try declaration_metric.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer declaration_values.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.MetricTargetKind.declaration, declaration_values.items()[0].target_kind);
    try std.testing.expect(declaration_values.items()[0].value.signed > 0);

    var container_scope = try root.forContainersMatching(&.{.{ .glob = "Worker" }});
    defer container_scope.deinit();
    var container_metric = try container_scope.customMetric(
        "function_field_ratio",
        "functions divided by fields",
        custom_calculation.CustomMetricCalculation.fromStateless(declarationOrContainerRatio),
    );
    defer container_metric.deinit();
    var container_values = try container_metric.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer container_values.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.MetricTargetKind.container, container_values.items()[0].target_kind);
    try std.testing.expectEqual(@as(f64, 1.0), container_values.items()[0].value.floating);
}

test "custom projected module and slice metrics use caller-defined labels" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    const mapper = projection.MapFunction.fromStateless(projectMetricFixture);
    var modules = try root.customMetricForProjection(
        .module,
        mapper,
        "source_files",
        "distinct Zig source files contributing to the projected label",
        custom_calculation.CustomMetricCalculation.fromStateless(projectedSourceFiles),
    );
    defer modules.deinit();
    var module_values = try modules.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer module_values.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), module_values.items().len);
    try std.testing.expectEqual(assertion.MetricTargetKind.module, modules.targetKind());
    try std.testing.expectEqual(@as(u64, 2), findCustomMeasurement(&module_values, "domain").?.value.unsigned);

    var slices = try root.customMetricForProjection(
        .slice,
        mapper,
        "instability",
        "project-specific slice instability",
        custom_calculation.CustomMetricCalculation.fromStateless(projectedInstability),
    );
    defer slices.deinit();
    var slice_values = try slices.measure(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer slice_values.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.MetricTargetKind.slice, slices.targetKind());
    try std.testing.expectEqual(@as(f64, 1.0), findCustomMeasurement(&slice_values, "api").?.value.floating);
    try std.testing.expectEqual(@as(f64, 0.0), findCustomMeasurement(&slice_values, "domain").?.value.floating);
}

const CustomPredicateContext = struct {
    calls: *usize,
    expected_kind: assertion.MetricTargetKind,

    fn satisfies(
        self: *const CustomPredicateContext,
        _: Allocator,
        value: assertion.MetricValue,
        info: custom_calculation.CustomMetricInfo,
    ) !bool {
        self.calls.* += 1;
        if (info.target_kind != self.expected_kind) return error.UnexpectedPredicateContext;
        return value.unsigned < 8;
    }
};

fn failCustomCalculation(_: Allocator, _: custom_calculation.CustomMetricInfo) !assertion.MetricValue {
    return error.CustomCalculationFailed;
}

fn failCustomPredicate(_: Allocator, _: assertion.MetricValue, _: custom_calculation.CustomMetricInfo) !bool {
    return error.CustomPredicateFailed;
}

test "custom thresholds and predicates retain descriptions and callback context" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var metric = try selected.customMetric(
        "dependency_weighted_lines",
        "non-blank lines plus distinct outgoing file dependencies",
        custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
    );
    defer metric.deinit();
    var threshold_rule = try metric.shouldBeBelow(.{ .unsigned = 8 });
    defer threshold_rule.deinit(std.testing.allocator);
    var threshold_result = try threshold_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer threshold_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.custom_metric, threshold_result.items()[0].kind());
    try std.testing.expectEqualStrings(
        "non-blank lines plus distinct outgoing file dependencies",
        threshold_result.items()[0].custom_metric.metric_description,
    );

    var calls: usize = 0;
    const predicate_context = CustomPredicateContext{ .calls = &calls, .expected_kind = .file };
    var predicate_rule = try metric.shouldSatisfy(custom_calculation.CustomMetricPredicate.fromContext(
        CustomPredicateContext,
        &predicate_context,
        CustomPredicateContext.satisfies,
    ));
    defer predicate_rule.deinit(std.testing.allocator);
    var predicate_result = try predicate_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer predicate_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(assertion.Violation.Kind.custom_metric, predicate_result.items()[0].kind());
    try std.testing.expectEqual(assertion.CustomMetricExpectation.predicate, std.meta.activeTag(
        predicate_result.items()[0].custom_metric.expectation,
    ));
}

test "custom terminals repeat safely erase as Checkable and guard before callbacks" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var metric = try selected.customMetric(
        "dependency_weighted_lines",
        "non-blank lines plus distinct outgoing file dependencies",
        custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
    );
    defer metric.deinit();
    var terminal = try metric.shouldBeBelowOrEqual(.{ .unsigned = 8 });
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    const sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "Zig project files, in file \"src/a.zig\" custom metric dependency_weighted_lines " ++
            "(non-blank lines plus distinct outgoing file dependencies) should be below or equal to 8",
        sentence,
    );
    var first = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer first.deinit(std.testing.allocator);
    var second = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(first.passes());
    try std.testing.expect(second.passes());

    var missing = try root.withName(&.{.{ .glob = "missing.zig" }});
    defer missing.deinit();
    var never_called = try missing.customMetric(
        "never_called",
        "empty scopes guard before custom calculation",
        custom_calculation.CustomMetricCalculation.fromStateless(failCustomCalculation),
    );
    defer never_called.deinit();
    var empty_terminal = try never_called.shouldBe(.{ .unsigned = 0 });
    defer empty_terminal.deinit(std.testing.allocator);
    var empty_result = try empty_terminal.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer empty_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, empty_result.items()[0].kind());
}

test "custom callback errors and builder validation remain explicit" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    try std.testing.expectError(
        error.InvalidMetricName,
        root.customMetric(
            " ",
            "described metric",
            custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
        ),
    );
    try std.testing.expectError(
        error.InvalidMetricDescription,
        root.customMetric(
            "metric",
            "\t",
            custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
        ),
    );
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    try std.testing.expectError(
        error.UnsupportedProjectedSelectors,
        selected.customMetricForProjection(
            .module,
            projection.MapFunction.fromStateless(projectMetricFixture),
            "source_files",
            "source files per module",
            custom_calculation.CustomMetricCalculation.fromStateless(projectedSourceFiles),
        ),
    );

    var failing = try selected.customMetric(
        "failing",
        "calculation error propagation",
        custom_calculation.CustomMetricCalculation.fromStateless(failCustomCalculation),
    );
    defer failing.deinit();
    try std.testing.expectError(
        error.CustomCalculationFailed,
        failing.measure(CheckOptions.init(std.testing.allocator, std.testing.io)),
    );

    var valid = try selected.customMetric(
        "valid",
        "predicate error propagation",
        custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
    );
    defer valid.deinit();
    try std.testing.expectError(error.InvalidThreshold, valid.shouldBeBelow(.{ .floating = std.math.inf(f64) }));
    var predicate_rule = try valid.shouldSatisfy(
        custom_calculation.CustomMetricPredicate.fromStateless(failCustomPredicate),
    );
    defer predicate_rule.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.CustomPredicateFailed,
        predicate_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io)),
    );
}

fn exerciseCustomMetricBuilderAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "fixture" });
    defer root.deinit();
    var containers = try root.forContainersMatching(&.{.{ .glob = "*Service" }});
    defer containers.deinit();
    var metric = try containers.customMetric(
        "risk",
        "project-specific structural risk",
        custom_calculation.CustomMetricCalculation.fromStateless(declarationOrContainerRatio),
    );
    defer metric.deinit();
    var cloned = try metric.clone();
    defer cloned.deinit();
    var terminal = try metric.shouldBeAboveOrEqual(.{ .floating = 0.5 });
    defer terminal.deinit(allocator);
    const sentence = try terminal.description(allocator);
    defer allocator.free(sentence);
}

test "custom metric builder chains release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCustomMetricBuilderAllocationFailures,
        .{},
    );
}

fn countMatchesSubject(
    _: Allocator,
    value: assertion.MetricValue,
    info: predicate_assertion.MetricPredicateInfo,
) !bool {
    if (info.target_kind != .file or info.structural == null or info.dependency == null) {
        return error.IncompleteCountPredicateContext;
    }
    return value.unsigned == info.structural.?.functions;
}

fn atMostOneDependency(
    _: Allocator,
    value: assertion.MetricValue,
    info: predicate_assertion.MetricPredicateInfo,
) !bool {
    if (info.dependency == null) return error.MissingDependencyPredicateContext;
    return value.unsigned <= 1;
}

fn stableEnough(
    _: Allocator,
    value: assertion.MetricValue,
    info: predicate_assertion.MetricPredicateInfo,
) !bool {
    if (info.dependency == null) return error.MissingDependencyPredicateContext;
    return value.floating < 0.5;
}

fn failMetricPredicate(
    _: Allocator,
    _: assertion.MetricValue,
    _: predicate_assertion.MetricPredicateInfo,
) !bool {
    return error.MetricPredicateFailed;
}

fn acceptMetricPredicate(
    _: Allocator,
    _: assertion.MetricValue,
    _: predicate_assertion.MetricPredicateInfo,
) !bool {
    return true;
}

fn rejectMetricPredicate(
    _: Allocator,
    _: assertion.MetricValue,
    _: predicate_assertion.MetricPredicateInfo,
) !bool {
    return false;
}

test "count shouldSatisfy receives the value and full file subject facts" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/root.zig"});
    defer selected.deinit();
    var counts = try selected.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var passing = try functions.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(countMatchesSubject),
    );
    defer passing.deinit(std.testing.allocator);
    var result = try passing.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var failing = try functions.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(rejectMetricPredicate),
    );
    defer failing.deinit(std.testing.allocator);
    var failed = try failing.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), failed.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.metric_predicate, failed.items()[0].kind());
    try std.testing.expectEqualStrings("functions", failed.items()[0].metric_predicate.metric_name);
    try std.testing.expectEqual(@as(u64, 1), failed.items()[0].metric_predicate.measured.unsigned);
}

test "dependency count and ratio shouldSatisfy preserve numeric tags and coupling context" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var dependencies = try selected.dependency();
    defer dependencies.deinit();

    var efferent = try dependencies.efferentCoupling();
    defer efferent.deinit();
    var count_rule = try efferent.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(atMostOneDependency),
    );
    defer count_rule.deinit(std.testing.allocator);
    var count_result = try count_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer count_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), count_result.items()[0].metric_predicate.measured.unsigned);

    var instability_selection = try dependencies.instability();
    defer instability_selection.deinit();
    var ratio_rule = try instability_selection.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(stableEnough),
    );
    defer ratio_rule.deinit(std.testing.allocator);
    var ratio_result = try ratio_rule.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer ratio_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 1.0), ratio_result.items()[0].metric_predicate.measured.floating);
    try std.testing.expectEqual(assertion.MetricTargetKind.file, ratio_result.items()[0].metric_predicate.target_kind);
}

test "built-in metric predicates propagate errors and guard empty selections first" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/root.zig"});
    defer selected.deinit();
    var counts = try selected.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var failing = try functions.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(failMetricPredicate),
    );
    defer failing.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.MetricPredicateFailed,
        failing.check(CheckOptions.init(std.testing.allocator, std.testing.io)),
    );

    var missing = try root.withName(&.{.{ .glob = "missing.zig" }});
    defer missing.deinit();
    var missing_counts = try missing.count();
    defer missing_counts.deinit();
    var tokens = try missing_counts.tokens();
    defer tokens.deinit();
    var guarded = try tokens.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(failMetricPredicate),
    );
    defer guarded.deinit(std.testing.allocator);
    var guarded_result = try guarded.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer guarded_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, guarded_result.items()[0].kind());
}

test "built-in metric predicate terminals repeat and erase as Checkable" {
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-structural" });
    defer root.deinit();
    var selected = try root.inFile(&.{"src/root.zig"});
    defer selected.deinit();
    var counts = try selected.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var terminal = try functions.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(acceptMetricPredicate),
    );
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    const sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "Zig project files, in file \"src/root.zig\" count functions should satisfy its metric assertion",
        sentence,
    );
    var first_result = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer first_result.deinit(std.testing.allocator);
    var second_result = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer second_result.deinit(std.testing.allocator);
    try std.testing.expect(first_result.passes());
    try std.testing.expect(second_result.passes());
}

fn assertExactMetricTerminals(comptime Selection: type) void {
    comptime {
        const required = .{
            "shouldBeBelow",
            "shouldBeAbove",
            "shouldBe",
            "shouldBeBelowOrEqual",
            "shouldBeAboveOrEqual",
            "shouldSatisfy",
        };
        for (required) |name| {
            if (!@hasDecl(Selection, name)) @compileError(@typeName(Selection) ++ " is missing " ++ name);
        }
        const forbidden = .{ "shouldEqual", "atMost", "atLeast", "between", "shouldMeet" };
        for (forbidden) |name| {
            if (@hasDecl(Selection, name)) @compileError(@typeName(Selection) ++ " exposes forbidden synonym " ++ name);
        }
    }
}

test "metric selections expose exactly the intended six assertion verbs without synonyms" {
    assertExactMetricTerminals(CountMetricSelection);
    assertExactMetricTerminals(DependencyCountSelection);
    assertExactMetricTerminals(DependencyRatioSelection);
    assertExactMetricTerminals(CustomMetricSelection);
}

fn exerciseMetricPredicateBuilderAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "fixture" });
    defer root.deinit();
    var selected = try root.inPath(&.{.{ .glob = "src/**" }});
    defer selected.deinit();
    var counts = try selected.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var terminal = try functions.shouldSatisfy(
        predicate_assertion.MetricPredicate.fromStateless(acceptMetricPredicate),
    );
    defer terminal.deinit(allocator);
    const sentence = try terminal.description(allocator);
    defer allocator.free(sentence);
}

test "metric predicate builder chains release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMetricPredicateBuilderAllocationFailures,
        .{},
    );
}

test "metric builders gather typed report data render HTML and export through one boundary" {
    const options = CheckOptions.init(std.testing.allocator, std.testing.io);
    var root = try metrics(std.testing.allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();

    var counts = try root.count();
    defer counts.deinit();
    var count_data = try counts.gatherReportData(options);
    defer count_data.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), count_data.items().len);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.count, count_data.items()[0].kind);
    const count_html = try counts.toHtml(
        options,
        .{ .title = "Count report", .include_timestamp = false },
    );
    defer std.testing.allocator.free(count_html);
    try std.testing.expect(std.mem.indexOf(u8, count_html, "subject_count") != null);

    var dependencies = try root.dependency();
    defer dependencies.deinit();
    var dependency_data = try dependencies.gatherReportData(options);
    defer dependency_data.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.dependency, dependency_data.items()[0].kind);
    const dependency_html = try dependencies.toHtml(
        options,
        .{ .title = "Dependency report", .include_timestamp = false },
    );
    defer std.testing.allocator.free(dependency_html);
    try std.testing.expect(std.mem.indexOf(u8, dependency_html, "average_instability") != null);

    var selected = try root.inFile(&.{"src/a.zig"});
    defer selected.deinit();
    var custom = try selected.customMetric(
        "dependency_weighted_lines",
        "non-blank lines plus distinct outgoing file dependencies",
        custom_calculation.CustomMetricCalculation.fromStateless(dependencyWeightedLines),
    );
    defer custom.deinit();
    var custom_data = try custom.gatherReportData(options);
    defer custom_data.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.custom, custom_data.items()[0].kind);
    try std.testing.expectEqualStrings("src/a.zig", custom_data.items()[0].items()[0].label);
    try std.testing.expectEqual(@as(u64, 8), custom_data.items()[0].items()[0].value.unsigned);
    const custom_html = try custom.toHtml(
        options,
        .{ .title = "Custom report", .include_timestamp = false },
    );
    defer std.testing.allocator.free(custom_html);
    try std.testing.expect(std.mem.indexOf(u8, custom_html, "dependency_weighted_lines") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const requested = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "nested", "counts" });
    defer std.testing.allocator.free(requested);
    try counts.exportAsHtml(
        options,
        requested,
        .{ .title = "Exported count report", .include_timestamp = false },
    );
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}.html", .{requested});
    defer std.testing.allocator.free(expected);
    const written = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        expected,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "<title>Exported count report</title>") != null);
}

fn exerciseMetricReportingAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "test/fixtures/metrics-dependency" });
    defer root.deinit();
    var counts = try root.count();
    defer counts.deinit();
    const html = try counts.toHtml(
        CheckOptions.init(allocator, std.testing.io),
        .{ .include_timestamp = false },
    );
    defer allocator.free(html);
}

test "metric reporting releases analysis data and partial rendering allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMetricReportingAllocationFailures,
        .{},
    );
}

fn exerciseBuilderAllocationFailures(allocator: Allocator) !void {
    var root = try metrics(allocator, .{ .locator = "fixture" });
    defer root.deinit();
    var selected = try root.inPath(&.{.{ .glob = "src/**" }});
    defer selected.deinit();
    var declarations = try selected.forDeclarationsMatching(&.{.{ .regex = "Service$" }});
    defer declarations.deinit();
    var current = try declarations.except(&.{.{ .glob = "LegacyService" }});
    defer current.deinit();
    var generated_free = try current.exceptTargeted(&.{.{ .glob = "generated.zig" }}, .filename);
    defer generated_free.deinit();
    var counts = try generated_free.count();
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
