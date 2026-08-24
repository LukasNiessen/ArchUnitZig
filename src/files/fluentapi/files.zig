const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const projection = @import("../../common/projection.zig");
const custom_assertion = @import("../assertion/custom_file_condition.zig");
const matching_files = @import("../assertion/matching_files.zig");
const dependency_assertion = @import("../assertion/depend_on_files.zig");
const external_assertion = @import("../assertion/depend_on_external_modules.zig");
const file_info_extraction = @import("../extraction/file_info.zig");
const file_cycles = @import("../projection/file_cycles.zig");

const Allocator = std.mem.Allocator;
pub const Filter = matching.Filter;
pub const Graph = extraction.Graph;
pub const Mood = assertion.Mood;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const ScopePattern = assertion.ScopePattern;
pub const CheckOptions = fluentapi.CheckOptions;
pub const CustomFilePredicate = custom_assertion.CustomFilePredicate;
pub const ExternalModuleCategories = external_assertion.ExternalModuleCategories;

pub const BuilderError = Allocator.Error || error{
    ExclusionWithoutSelector,
    InvalidDescription,
    InvalidExclusionTarget,
    InvalidPattern,
    InvalidProjectPath,
};

/// Lazy project identity retained by a file-scope builder. Relative locators are resolved only by a
/// future terminal check; constructing and narrowing a scope performs no filesystem access.
pub const ProjectOptions = struct {
    locator: ?[]const u8 = null,
};

/// Owned selector evidence for empty-test violations and reporting. The allocator passed to
/// `FilesScope.scopePatterns` must also be passed to `deinit`.
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

    pub fn len(self: *const ScopePatterns) usize {
        return self.values.items.len;
    }
};

/// An owned, sorted file selection. Its paths do not borrow the graph passed to `FilesScope.select`.
pub const SelectedFiles = struct {
    allocator: Allocator,
    values: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *SelectedFiles) void {
        for (self.values.items) |path| self.allocator.free(path);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn items(self: *const SelectedFiles) []const []const u8 {
        return self.values.items;
    }

    pub fn len(self: *const SelectedFiles) usize {
        return self.values.items.len;
    }
};

const CompiledPattern = struct {
    evidence: ScopePattern,
    filter: Filter,

    fn initPattern(
        allocator: Allocator,
        selector_index: usize,
        pattern: Pattern,
        target: PatternTarget,
    ) BuilderError!CompiledPattern {
        if (pattern.source().len == 0) return error.InvalidPattern;
        const matching_mode = matchingModeFor(pattern);
        var filter = Filter.init(allocator, pattern, target, matching_mode) catch |failure| {
            return mapPatternFailure(failure);
        };
        errdefer filter.deinit();
        return .{
            .evidence = try ScopePattern.init(
                allocator,
                selector_index,
                pattern,
                target,
                matching_mode,
            ),
            .filter = filter,
        };
    }

    fn initLiteral(
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
        target: PatternTarget,
    ) BuilderError!Selector {
        if (patterns.len == 0) return error.InvalidPattern;
        var result: Selector = .{};
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
        var result: Selector = .{};
        errdefer result.deinit(allocator);
        try result.alternatives.ensureTotalCapacity(allocator, paths.len);
        for (paths) |path| {
            result.alternatives.appendAssumeCapacity(try CompiledPattern.initLiteral(
                allocator,
                selector_index,
                path,
            ));
        }
        return result;
    }

    fn clone(self: *const Selector, allocator: Allocator) BuilderError!Selector {
        var result: Selector = .{};
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
            const mode = matchingModeFor(pattern);
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

    fn matches(self: *const Selector, allocator: Allocator, path: []const u8) Allocator.Error!bool {
        for (self.alternatives.items) |*alternative| {
            if (alternative.filter.matches(allocator, .{ .path = path }) catch |failure| switch (failure) {
                error.MissingDeclarationName => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            }) return true;
        }
        return false;
    }
};

/// Owned scope stage for a file rule.
///
/// Every narrowing method returns a deep independent owner. Deinitialize each returned value; use
/// `clone` instead of plain struct assignment when another owner is required.
pub const FilesScope = struct {
    allocator: Allocator,
    owned_locator: ?[]u8 = null,
    selectors: std.ArrayList(Selector) = .empty,

    fn init(allocator: Allocator, options: ProjectOptions) BuilderError!FilesScope {
        if (options.locator) |locator| {
            if (locator.len == 0) return error.InvalidProjectPath;
            return .{
                .allocator = allocator,
                .owned_locator = try allocator.dupe(u8, locator),
            };
        }
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FilesScope) void {
        if (self.owned_locator) |locator| self.allocator.free(locator);
        for (self.selectors.items) |*selector| selector.deinit(self.allocator);
        self.selectors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const FilesScope) BuilderError!FilesScope {
        var result = FilesScope{ .allocator = self.allocator };
        errdefer result.deinit();
        if (self.owned_locator) |locator| {
            result.owned_locator = try self.allocator.dupe(u8, locator);
        }
        try result.selectors.ensureTotalCapacity(self.allocator, self.selectors.items.len);
        for (self.selectors.items) |*selector| {
            result.selectors.appendAssumeCapacity(try selector.clone(self.allocator));
        }
        return result;
    }

    pub fn projectLocator(self: *const FilesScope) ?[]const u8 {
        return self.owned_locator;
    }

    pub fn selectorCount(self: *const FilesScope) usize {
        return self.selectors.items.len;
    }

    pub fn patternCount(self: *const FilesScope, selector_index: usize) ?usize {
        if (selector_index >= self.selectors.items.len) return null;
        return self.selectors.items[selector_index].alternatives.items.len;
    }

    /// The positive grammar stage. The returned value owns an independent clone of this scope.
    pub fn should(self: *const FilesScope) BuilderError!FilesShould {
        return .{ .rule = try FileRuleContext.init(self, .should) };
    }

    /// The negated grammar stage. The returned value owns an independent clone of this scope.
    pub fn shouldNot(self: *const FilesScope) BuilderError!FilesShouldNot {
        return .{ .rule = try FileRuleContext.init(self, .should_not) };
    }

    /// Returns an independent owned copy of the user-facing selector facts in chain order.
    pub fn scopePatterns(self: *const FilesScope, allocator: Allocator) Allocator.Error!ScopePatterns {
        var result: ScopePatterns = .{};
        errdefer result.deinit(allocator);
        var pattern_count: usize = 0;
        for (self.selectors.items) |selector| {
            pattern_count += selector.alternatives.items.len + selector.exclusions.items.len;
        }
        try result.values.ensureTotalCapacity(allocator, pattern_count);
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

    /// Narrows by last path segment. Alternatives within this call use OR semantics.
    pub fn withName(self: *const FilesScope, patterns: []const Pattern) BuilderError!FilesScope {
        return self.selectPatterns(patterns, .filename);
    }

    /// Narrows by the project-relative path without its last segment.
    pub fn inFolder(self: *const FilesScope, patterns: []const Pattern) BuilderError!FilesScope {
        return self.selectPatterns(patterns, .path_without_filename);
    }

    /// Narrows by the complete project-relative path.
    pub fn inPath(self: *const FilesScope, patterns: []const Pattern) BuilderError!FilesScope {
        return self.selectPatterns(patterns, .path);
    }

    /// Narrows by one of the exact project-relative paths. Metacharacters are always literal.
    pub fn inFile(self: *const FilesScope, paths: []const []const u8) BuilderError!FilesScope {
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

    /// Excludes alternatives from the immediately preceding selector using that selector's target.
    pub fn except(self: *const FilesScope, patterns: []const Pattern) BuilderError!FilesScope {
        return self.excludePatterns(patterns, null);
    }

    /// Excludes alternatives from the immediately preceding selector using an explicit path field.
    pub fn exceptTargeted(
        self: *const FilesScope,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesScope {
        return self.excludePatterns(patterns, target);
    }

    /// Purely evaluates this scope against one normalized project-relative path.
    pub fn matchesPath(self: *const FilesScope, path: []const u8) Allocator.Error!bool {
        for (self.selectors.items) |*selector| {
            if (!try selector.matches(self.allocator, path)) return false;
        }
        return true;
    }

    /// Purely selects the internal file nodes represented by self-edges in a normalized graph.
    pub fn select(self: *const FilesScope, graph: *const Graph) Allocator.Error!SelectedFiles {
        var result = SelectedFiles{ .allocator = self.allocator };
        errdefer result.deinit();
        for (graph.items()) |edge| {
            if (edge.external or !std.mem.eql(u8, edge.source, edge.target)) continue;
            if (!try self.matchesPath(edge.source)) continue;
            const owned_path = try self.allocator.dupe(u8, edge.source);
            result.values.append(self.allocator, owned_path) catch {
                self.allocator.free(owned_path);
                return error.OutOfMemory;
            };
        }
        std.mem.sort([]u8, result.values.items, {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        return result;
    }

    /// Selects internal dependency-object candidates. Unlike subject selection, this also includes
    /// concrete non-Zig targets such as ZON and embedded files that have no synthetic self-edge.
    pub fn selectDependencyObjects(
        self: *const FilesScope,
        graph: *const Graph,
    ) Allocator.Error!SelectedFiles {
        var result = SelectedFiles{ .allocator = self.allocator };
        errdefer result.deinit();
        for (graph.items()) |edge| {
            if (edge.external) continue;
            const candidate = if (std.mem.eql(u8, edge.source, edge.target)) edge.source else edge.target;
            if (containsSelected(result.values.items, candidate)) continue;
            if (!try self.matchesPath(candidate)) continue;
            const owned_path = try self.allocator.dupe(u8, candidate);
            result.values.append(self.allocator, owned_path) catch {
                self.allocator.free(owned_path);
                return error.OutOfMemory;
            };
        }
        std.mem.sort([]u8, result.values.items, {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        return result;
    }

    /// Allocates a stable English-like description from owned selector evidence. The caller frees
    /// the returned slice with `allocator`.
    pub fn description(self: *const FilesScope, allocator: Allocator) Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        self.writeDescription(&output.writer) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn selectPatterns(
        self: *const FilesScope,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesScope {
        var result = try self.clone();
        errdefer result.deinit();
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
        self: *const FilesScope,
        patterns: []const Pattern,
        explicit_target: ?PatternTarget,
    ) BuilderError!FilesScope {
        if (self.selectors.items.len == 0) return error.ExclusionWithoutSelector;
        const target = explicit_target orelse self.selectors.items[self.selectors.items.len - 1].inheritedTarget();
        if (target == .declaration_name) return error.InvalidExclusionTarget;
        var result = try self.clone();
        errdefer result.deinit();
        try result.selectors.items[result.selectors.items.len - 1].addExclusions(
            result.allocator,
            patterns,
            target,
        );
        return result;
    }

    fn writeDescription(self: *const FilesScope, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("project files");
        try self.writeSelectorDescription(writer);
    }

    fn writeSelectorDescription(self: *const FilesScope, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.selectors.items) |selector| {
            const alternatives = selector.alternatives.items;
            std.debug.assert(alternatives.len != 0);
            try writer.writeAll(", ");
            try writer.writeAll(selectorPhrase(alternatives[0].evidence));
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
                try writer.writeAll(selectorPhrase(exclusion));
                try writer.writeByte(' ');
                if (exclusion.syntax == .regex) try writer.writeAll("regex ");
                try writer.print("\"{f}\"", .{std.zig.fmtString(exclusion.expression)});
            }
        }
    }
};

/// Shared owned data behind both public mood stages. Predicate implementations consume this one
/// context and call `mood.holds`; positive and negative assertion logic is never duplicated.
pub const FileRuleContext = struct {
    scope: FilesScope,
    mood_value: Mood,

    fn init(scope: *const FilesScope, selected_mood: Mood) BuilderError!FileRuleContext {
        return .{ .scope = try scope.clone(), .mood_value = selected_mood };
    }

    pub fn deinit(self: *FileRuleContext) void {
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn clone(self: *const FileRuleContext) BuilderError!FileRuleContext {
        return .{ .scope = try self.scope.clone(), .mood_value = self.mood_value };
    }

    pub fn mood(self: *const FileRuleContext) Mood {
        return self.mood_value;
    }

    pub fn predicateHolds(self: *const FileRuleContext, predicate_result: bool) bool {
        return self.mood_value.holds(predicate_result);
    }

    pub fn select(self: *const FileRuleContext, graph: *const Graph) Allocator.Error!SelectedFiles {
        return self.scope.select(graph);
    }

    pub fn scopePatterns(self: *const FileRuleContext, allocator: Allocator) Allocator.Error!ScopePatterns {
        return self.scope.scopePatterns(allocator);
    }

    pub fn description(self: *const FileRuleContext, allocator: Allocator) Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        self.scope.writeDescription(&output.writer) catch return error.OutOfMemory;
        output.writer.print(", {f}", .{self.mood_value}) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }
};

/// Positive mood stage. Future positive-only predicates can live here without becoming available
/// after `shouldNot`.
pub const FilesShould = struct {
    rule: FileRuleContext,

    pub fn deinit(self: *FilesShould) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn mood(self: *const FilesShould) Mood {
        return self.rule.mood();
    }

    pub fn predicateHolds(self: *const FilesShould, predicate_result: bool) bool {
        return self.rule.predicateHolds(predicate_result);
    }

    pub fn select(self: *const FilesShould, graph: *const Graph) Allocator.Error!SelectedFiles {
        return self.rule.select(graph);
    }

    pub fn scopePatterns(self: *const FilesShould, allocator: Allocator) Allocator.Error!ScopePatterns {
        return self.rule.scopePatterns(allocator);
    }

    pub fn description(self: *const FilesShould, allocator: Allocator) Allocator.Error![]u8 {
        return self.rule.description(allocator);
    }

    /// Completes the positive-only file-cycle grammar with an independently owned terminal rule.
    pub fn haveNoCycles(self: *const FilesShould) BuilderError!FilesHaveNoCycles {
        return .{ .rule = try self.rule.clone() };
    }

    pub fn haveName(self: *const FilesShould, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .filename);
    }

    pub fn beInFolder(self: *const FilesShould, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .path_without_filename);
    }

    pub fn beInPath(self: *const FilesShould, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .path);
    }

    pub fn dependOnFiles(self: *const FilesShould) BuilderError!FilesDependOnBuilder {
        return .{ .rule = try self.rule.clone() };
    }

    pub fn dependOnExternalModules(self: *const FilesShould) BuilderError!FilesExternalModuleBuilder {
        return .{
            .rule = try self.rule.clone(),
            .categories = external_assertion.defaultExternalModuleCategories(),
        };
    }

    pub fn adhereTo(
        self: *const FilesShould,
        predicate: CustomFilePredicate,
        policy_description: []const u8,
    ) BuilderError!FilesAdhereTo {
        return FilesAdhereTo.init(&self.rule, predicate, policy_description);
    }
};

/// Positive terminal rule for elementary cycles in the selected internal file graph.
pub const FilesHaveNoCycles = struct {
    rule: FileRuleContext,

    /// The allocator argument is the Checkable box allocator. Scope storage remembers and uses its
    /// own builder allocator, so moving a rule into a differently allocated Checkable stays safe.
    pub fn deinit(self: *FilesHaveNoCycles, allocator: Allocator) void {
        _ = allocator;
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const FilesHaveNoCycles, allocator: Allocator) Allocator.Error![]u8 {
        const prefix = try self.rule.description(allocator);
        defer allocator.free(prefix);
        return std.fmt.allocPrint(allocator, "{s} have no cycles", .{prefix});
    }

    pub fn check(self: *const FilesHaveNoCycles, options: CheckOptions) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "files.have_no_cycles", performCheck);
    }

    fn performCheck(self: *const FilesHaveNoCycles, options: CheckOptions) anyerror!assertion.ViolationList {
        var graph = try extractRuleGraph(&self.rule, options);
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    fn checkGraph(
        self: *const FilesHaveNoCycles,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var selected = try self.rule.select(graph);
        defer selected.deinit();
        if (try guardRuleSelection(&self.rule, selected.len(), options, "files.have_no_cycles")) |early| return early;

        var cycles = try file_cycles.projectSelectedFileCycles(
            options.allocator,
            graph,
            selected.items(),
        );
        defer cycles.deinit(options.allocator);
        var result = assertion.ViolationList{};
        errdefer result.deinit(options.allocator);
        for (cycles.items()) |cycle| {
            var payload = try assertion.CycleViolation.initClone(options.allocator, cycle);
            var violation = assertion.Violation.fromCycleMove(&payload);
            result.appendMove(options.allocator, &violation) catch |failure| {
                violation.deinit(options.allocator);
                return failure;
            };
        }
        return result;
    }
};

/// Shared terminal for name, folder, and full-path predicates in either mood.
pub const FilesMatchPattern = struct {
    rule: FileRuleContext,
    predicate: CompiledPattern,

    fn init(
        source_rule: *const FileRuleContext,
        pattern: Pattern,
        target: PatternTarget,
    ) BuilderError!FilesMatchPattern {
        var result = FilesMatchPattern{
            .rule = try source_rule.clone(),
            .predicate = undefined,
        };
        errdefer result.rule.deinit();
        result.predicate = try CompiledPattern.initPattern(
            source_rule.scope.allocator,
            0,
            pattern,
            target,
        );
        return result;
    }

    pub fn deinit(self: *FilesMatchPattern, allocator: Allocator) void {
        _ = allocator;
        self.predicate.deinit(self.rule.scope.allocator);
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const FilesMatchPattern, allocator: Allocator) Allocator.Error![]u8 {
        const prefix = try self.rule.description(allocator);
        defer allocator.free(prefix);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        output.writer.print("{s} {s} ", .{ prefix, predicatePhrase(self.predicate.evidence.target) }) catch
            return error.OutOfMemory;
        if (self.predicate.evidence.syntax == .regex) {
            output.writer.writeAll("regex ") catch return error.OutOfMemory;
        }
        output.writer.print("\"{f}\"", .{std.zig.fmtString(self.predicate.evidence.expression)}) catch
            return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn check(self: *const FilesMatchPattern, options: CheckOptions) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "files.match_pattern", performCheck);
    }

    fn performCheck(self: *const FilesMatchPattern, options: CheckOptions) anyerror!assertion.ViolationList {
        var graph = try extractRuleGraph(&self.rule, options);
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    fn checkGraph(
        self: *const FilesMatchPattern,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var selected = try self.rule.select(graph);
        defer selected.deinit();
        if (try guardRuleSelection(
            &self.rule,
            selected.len(),
            options,
            ruleIdForTarget(self.predicate.evidence.target),
        )) |early| return early;
        return matching_files.gatherMatchingFileViolations(
            options.allocator,
            selected.items(),
            &self.predicate.filter,
            self.predicate.evidence,
            self.rule.mood(),
        );
    }
};

/// Object-selection stage for the direct file-dependency predicate. At least one object selector
/// is required before the value becomes checkable.
pub const FilesDependOnBuilder = struct {
    rule: FileRuleContext,

    pub fn deinit(self: *FilesDependOnBuilder) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn withName(self: *const FilesDependOnBuilder, patterns: []const Pattern) BuilderError!FilesDependOn {
        return self.startPatterns(patterns, .filename);
    }

    pub fn inFolder(self: *const FilesDependOnBuilder, patterns: []const Pattern) BuilderError!FilesDependOn {
        return self.startPatterns(patterns, .path_without_filename);
    }

    pub fn inPath(self: *const FilesDependOnBuilder, patterns: []const Pattern) BuilderError!FilesDependOn {
        return self.startPatterns(patterns, .path);
    }

    pub fn inFile(self: *const FilesDependOnBuilder, paths: []const []const u8) BuilderError!FilesDependOn {
        var base = try projectFiles(self.rule.scope.allocator, .{});
        defer base.deinit();
        var objects = try base.inFile(paths);
        defer objects.deinit();
        return FilesDependOn.init(&self.rule, &objects);
    }

    fn startPatterns(
        self: *const FilesDependOnBuilder,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesDependOn {
        var base = try projectFiles(self.rule.scope.allocator, .{});
        defer base.deinit();
        var objects = try base.selectPatterns(patterns, target);
        defer objects.deinit();
        return FilesDependOn.init(&self.rule, &objects);
    }
};

/// Checkable direct dependency rule with one or more independently owned object selectors.
pub const FilesDependOn = struct {
    rule: FileRuleContext,
    objects: FilesScope,

    fn init(rule: *const FileRuleContext, objects: *const FilesScope) BuilderError!FilesDependOn {
        var result = FilesDependOn{
            .rule = try rule.clone(),
            .objects = undefined,
        };
        errdefer result.rule.deinit();
        result.objects = try objects.clone();
        return result;
    }

    pub fn deinit(self: *FilesDependOn, allocator: Allocator) void {
        _ = allocator;
        self.objects.deinit();
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn withName(self: *const FilesDependOn, patterns: []const Pattern) BuilderError!FilesDependOn {
        var narrowed = try self.objects.withName(patterns);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn inFolder(self: *const FilesDependOn, patterns: []const Pattern) BuilderError!FilesDependOn {
        var narrowed = try self.objects.inFolder(patterns);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn inPath(self: *const FilesDependOn, patterns: []const Pattern) BuilderError!FilesDependOn {
        var narrowed = try self.objects.inPath(patterns);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn inFile(self: *const FilesDependOn, paths: []const []const u8) BuilderError!FilesDependOn {
        var narrowed = try self.objects.inFile(paths);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn except(self: *const FilesDependOn, patterns: []const Pattern) BuilderError!FilesDependOn {
        var narrowed = try self.objects.except(patterns);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn exceptTargeted(
        self: *const FilesDependOn,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesDependOn {
        var narrowed = try self.objects.exceptTargeted(patterns, target);
        defer narrowed.deinit();
        return init(&self.rule, &narrowed);
    }

    pub fn description(self: *const FilesDependOn, allocator: Allocator) Allocator.Error![]u8 {
        const prefix = try self.rule.description(allocator);
        defer allocator.free(prefix);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        output.writer.print("{s} depend on files", .{prefix}) catch return error.OutOfMemory;
        self.objects.writeSelectorDescription(&output.writer) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn check(self: *const FilesDependOn, options: CheckOptions) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "files.depend_on_files", performCheck);
    }

    fn performCheck(self: *const FilesDependOn, options: CheckOptions) anyerror!assertion.ViolationList {
        var graph = try extractRuleGraph(&self.rule, options);
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    fn checkGraph(
        self: *const FilesDependOn,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var subjects = try self.rule.select(graph);
        defer subjects.deinit();
        if (try guardRuleSelection(
            &self.rule,
            subjects.len(),
            options,
            "files.depend_on_files.subject",
        )) |early| return early;
        var objects = try self.objects.selectDependencyObjects(graph);
        defer objects.deinit();
        if (try guardScopeSelection(
            &self.objects,
            self.rule.mood(),
            objects.len(),
            options,
            "files.depend_on_files.object",
        )) |early| return early;

        var edges = try projection.projectEdges(
            options.allocator,
            graph,
            projection.perInternalEdge(),
        );
        defer edges.deinit(options.allocator);
        return dependency_assertion.gatherFileDependencyViolations(
            options.allocator,
            edges.items(),
            subjects.items(),
            objects.items(),
            self.rule.mood(),
        );
    }
};

/// External dependency category stage. Named external modules are enabled by default; other Zig
/// dependency classes require an explicit opt-in before matching completes the terminal.
pub const FilesExternalModuleBuilder = struct {
    rule: FileRuleContext,
    categories: ExternalModuleCategories,

    pub fn deinit(self: *FilesExternalModuleBuilder) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn includingCompilerModules(self: *const FilesExternalModuleBuilder) BuilderError!FilesExternalModuleBuilder {
        return self.withCategory(.compiler_module);
    }

    pub fn includingCHeaders(self: *const FilesExternalModuleBuilder) BuilderError!FilesExternalModuleBuilder {
        return self.withCategory(.c_header);
    }

    pub fn includingResources(self: *const FilesExternalModuleBuilder) BuilderError!FilesExternalModuleBuilder {
        return self.withCategory(.resource);
    }

    pub fn matching(
        self: *const FilesExternalModuleBuilder,
        patterns: []const Pattern,
    ) BuilderError!FilesExternalModules {
        return FilesExternalModules.init(&self.rule, self.categories, patterns);
    }

    fn withCategory(
        self: *const FilesExternalModuleBuilder,
        category: external_assertion.ExternalModuleCategory,
    ) BuilderError!FilesExternalModuleBuilder {
        var categories = self.categories;
        categories.insert(category);
        return .{ .rule = try self.rule.clone(), .categories = categories };
    }
};

/// Checkable external-module allowlist/blocklist with OR-combined module patterns.
pub const FilesExternalModules = struct {
    rule: FileRuleContext,
    categories: ExternalModuleCategories,
    module_patterns: std.ArrayList(CompiledPattern) = .empty,
    exclusions: std.ArrayList(ScopePattern) = .empty,

    fn init(
        source_rule: *const FileRuleContext,
        categories: ExternalModuleCategories,
        patterns: []const Pattern,
    ) BuilderError!FilesExternalModules {
        if (patterns.len == 0) return error.InvalidPattern;
        var result = FilesExternalModules{
            .rule = try source_rule.clone(),
            .categories = categories,
        };
        errdefer result.deinit(source_rule.scope.allocator);
        try result.appendPatterns(patterns);
        return result;
    }

    pub fn deinit(self: *FilesExternalModules, allocator: Allocator) void {
        _ = allocator;
        const owner = self.rule.scope.allocator;
        for (self.module_patterns.items) |*pattern| pattern.deinit(owner);
        self.module_patterns.deinit(owner);
        for (self.exclusions.items) |*exclusion| exclusion.deinit(owner);
        self.exclusions.deinit(owner);
        self.rule.deinit();
        self.* = undefined;
    }

    fn clone(self: *const FilesExternalModules) BuilderError!FilesExternalModules {
        var result = FilesExternalModules{
            .rule = try self.rule.clone(),
            .categories = self.categories,
        };
        errdefer result.deinit(self.rule.scope.allocator);
        try result.module_patterns.ensureTotalCapacity(
            self.rule.scope.allocator,
            self.module_patterns.items.len,
        );
        for (self.module_patterns.items) |*pattern| {
            result.module_patterns.appendAssumeCapacity(try pattern.clone(self.rule.scope.allocator));
        }
        try result.exclusions.ensureTotalCapacity(
            self.rule.scope.allocator,
            self.exclusions.items.len,
        );
        for (self.exclusions.items) |exclusion| {
            result.exclusions.appendAssumeCapacity(try exclusion.clone(self.rule.scope.allocator));
        }
        return result;
    }

    pub fn matching(self: *const FilesExternalModules, patterns: []const Pattern) BuilderError!FilesExternalModules {
        if (patterns.len == 0) return error.InvalidPattern;
        var result = try self.clone();
        errdefer result.deinit(self.rule.scope.allocator);
        try result.appendPatterns(patterns);
        return result;
    }

    pub fn except(self: *const FilesExternalModules, patterns: []const Pattern) BuilderError!FilesExternalModules {
        return self.excludePatterns(patterns, .path);
    }

    pub fn exceptTargeted(
        self: *const FilesExternalModules,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesExternalModules {
        if (target == .declaration_name) return error.InvalidExclusionTarget;
        return self.excludePatterns(patterns, target);
    }

    pub fn includingCompilerModules(self: *const FilesExternalModules) BuilderError!FilesExternalModules {
        return self.withCategory(.compiler_module);
    }

    pub fn includingCHeaders(self: *const FilesExternalModules) BuilderError!FilesExternalModules {
        return self.withCategory(.c_header);
    }

    pub fn includingResources(self: *const FilesExternalModules) BuilderError!FilesExternalModules {
        return self.withCategory(.resource);
    }

    fn withCategory(
        self: *const FilesExternalModules,
        category: external_assertion.ExternalModuleCategory,
    ) BuilderError!FilesExternalModules {
        var result = try self.clone();
        result.categories.insert(category);
        return result;
    }

    fn appendPatterns(self: *FilesExternalModules, patterns: []const Pattern) BuilderError!void {
        const allocator = self.rule.scope.allocator;
        try self.module_patterns.ensureUnusedCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            self.module_patterns.appendAssumeCapacity(try CompiledPattern.initPattern(
                allocator,
                0,
                pattern,
                .path,
            ));
        }
    }

    fn excludePatterns(
        self: *const FilesExternalModules,
        patterns: []const Pattern,
        target: PatternTarget,
    ) BuilderError!FilesExternalModules {
        if (patterns.len == 0) return error.InvalidPattern;
        var result = try self.clone();
        errdefer result.deinit(self.rule.scope.allocator);
        const allocator = result.rule.scope.allocator;
        try result.exclusions.ensureUnusedCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            if (pattern.source().len == 0) return error.InvalidPattern;
            const mode = matchingModeFor(pattern);
            for (result.module_patterns.items) |*module_pattern| {
                module_pattern.filter.addExclusion(pattern, target, mode) catch |failure| {
                    return mapPatternFailure(failure);
                };
            }
            result.exclusions.appendAssumeCapacity(try ScopePattern.initExclusion(
                allocator,
                0,
                pattern,
                target,
                mode,
            ));
        }
        return result;
    }

    pub fn description(self: *const FilesExternalModules, allocator: Allocator) Allocator.Error![]u8 {
        const prefix = try self.rule.description(allocator);
        defer allocator.free(prefix);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        output.writer.print("{s} depend on external modules matching ", .{prefix}) catch return error.OutOfMemory;
        if (self.module_patterns.items.len > 1) output.writer.writeByte('(') catch return error.OutOfMemory;
        for (self.module_patterns.items, 0..) |pattern, index| {
            if (index != 0) output.writer.writeAll(" or ") catch return error.OutOfMemory;
            if (pattern.evidence.syntax == .regex) output.writer.writeAll("regex ") catch return error.OutOfMemory;
            output.writer.print("\"{f}\"", .{std.zig.fmtString(pattern.evidence.expression)}) catch
                return error.OutOfMemory;
        }
        if (self.module_patterns.items.len > 1) output.writer.writeByte(')') catch return error.OutOfMemory;
        for (self.exclusions.items) |exclusion| {
            output.writer.print(", except {s} ", .{selectorPhrase(exclusion)}) catch return error.OutOfMemory;
            if (exclusion.syntax == .regex) output.writer.writeAll("regex ") catch return error.OutOfMemory;
            output.writer.print("\"{f}\"", .{std.zig.fmtString(exclusion.expression)}) catch
                return error.OutOfMemory;
        }
        return output.toOwnedSlice();
    }

    pub fn check(self: *const FilesExternalModules, options: CheckOptions) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "files.depend_on_external_modules", performCheck);
    }

    fn performCheck(self: *const FilesExternalModules, options: CheckOptions) anyerror!assertion.ViolationList {
        var graph = try extractRuleGraph(&self.rule, options);
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    fn checkGraph(
        self: *const FilesExternalModules,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var subjects = try self.rule.select(graph);
        defer subjects.deinit();
        if (try guardRuleSelection(
            &self.rule,
            subjects.len(),
            options,
            "files.depend_on_external_modules.subject",
        )) |early| return early;
        var edges = try projection.projectEdges(options.allocator, graph, projection.perExternalEdge());
        defer edges.deinit(options.allocator);
        var filters: std.ArrayList(*const Filter) = .empty;
        defer filters.deinit(options.allocator);
        try filters.ensureTotalCapacity(options.allocator, self.module_patterns.items.len);
        for (self.module_patterns.items) |*pattern| filters.appendAssumeCapacity(&pattern.filter);

        var category_edges: usize = 0;
        for (edges.items()) |edge| {
            if (!containsSelected(subjects.items(), edge.source_label) or
                !external_assertion.edgeInCategories(edge, self.categories)) continue;
            category_edges += 1;
        }
        if (self.rule.mood() == .should) {
            if (try guardCompiledPatternSelection(
                self.module_patterns.items,
                self.exclusions.items,
                self.rule.mood(),
                category_edges,
                options,
                "files.depend_on_external_modules.object",
            )) |early| return early;
        }
        return external_assertion.gatherExternalModuleDependencyViolations(
            options.allocator,
            edges.items(),
            subjects.items(),
            filters.items,
            self.categories,
            self.rule.mood(),
        );
    }
};

/// Terminal escape hatch for a project-specific policy over borrowed, byte-safe file information.
pub const FilesAdhereTo = struct {
    rule: FileRuleContext,
    predicate: CustomFilePredicate,
    owned_description: []const u8,

    fn init(
        source_rule: *const FileRuleContext,
        predicate: CustomFilePredicate,
        policy_description: []const u8,
    ) BuilderError!FilesAdhereTo {
        if (!containsNonWhitespace(policy_description)) return error.InvalidDescription;
        var result = FilesAdhereTo{
            .rule = try source_rule.clone(),
            .predicate = predicate,
            .owned_description = undefined,
        };
        errdefer result.rule.deinit();
        result.owned_description = try source_rule.scope.allocator.dupe(u8, policy_description);
        return result;
    }

    pub fn deinit(self: *FilesAdhereTo, allocator: Allocator) void {
        _ = allocator;
        const owner = self.rule.scope.allocator;
        owner.free(self.owned_description);
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn description(self: *const FilesAdhereTo, allocator: Allocator) Allocator.Error![]u8 {
        const prefix = try self.rule.description(allocator);
        defer allocator.free(prefix);
        return std.fmt.allocPrint(
            allocator,
            "{s} adhere to \"{f}\"",
            .{ prefix, std.zig.fmtString(self.owned_description) },
        );
    }

    pub fn check(self: *const FilesAdhereTo, options: CheckOptions) anyerror!assertion.ViolationList {
        return fluentapi.runLoggedCheck(self, options, "files.adhere_to", performCheck);
    }

    fn performCheck(self: *const FilesAdhereTo, options: CheckOptions) anyerror!assertion.ViolationList {
        if (options.logger) |logger| try logger.logExtraction("source inspection started");
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var project = try extraction.locateProject(
            options.allocator,
            options.io,
            self.rule.scope.projectLocator(),
            options.working_directory,
            &diagnostics,
        );
        defer project.deinit(options.allocator);
        var source_files = try extraction.enumerateSourceFiles(
            options.allocator,
            options.io,
            project.path,
            .{ .exclusions = options.extraction.exclusions },
            &diagnostics,
        );
        defer source_files.deinit(options.allocator);

        var selected_count: usize = 0;
        for (source_files.items()) |path| {
            if (try self.rule.scope.matchesPath(path)) selected_count += 1;
        }
        if (options.logger) |logger| try logger.logExtraction("source inspection completed");
        if (try guardRuleSelection(&self.rule, selected_count, options, "files.adhere_to")) |early| return early;

        var result = assertion.ViolationList{};
        errdefer result.deinit(options.allocator);
        for (source_files.items()) |path| {
            if (!try self.rule.scope.matchesPath(path)) continue;
            var loaded = try file_info_extraction.loadFileInfo(
                options.allocator,
                options.io,
                project.path,
                path,
                &diagnostics,
            );
            defer loaded.deinit(options.allocator);
            var current = try custom_assertion.gatherCustomFileViolations(
                options.allocator,
                &.{loaded.view},
                self.predicate,
                self.owned_description,
                self.rule.mood(),
            );
            defer current.deinit(options.allocator);
            try result.appendListMove(options.allocator, &current);
        }
        return result;
    }
};

/// Negated mood stage. It is deliberately one mood flag over the same context and assertions.
pub const FilesShouldNot = struct {
    rule: FileRuleContext,

    pub fn deinit(self: *FilesShouldNot) void {
        self.rule.deinit();
        self.* = undefined;
    }

    pub fn mood(self: *const FilesShouldNot) Mood {
        return self.rule.mood();
    }

    pub fn predicateHolds(self: *const FilesShouldNot, predicate_result: bool) bool {
        return self.rule.predicateHolds(predicate_result);
    }

    pub fn select(self: *const FilesShouldNot, graph: *const Graph) Allocator.Error!SelectedFiles {
        return self.rule.select(graph);
    }

    pub fn scopePatterns(self: *const FilesShouldNot, allocator: Allocator) Allocator.Error!ScopePatterns {
        return self.rule.scopePatterns(allocator);
    }

    pub fn description(self: *const FilesShouldNot, allocator: Allocator) Allocator.Error![]u8 {
        return self.rule.description(allocator);
    }

    pub fn haveName(self: *const FilesShouldNot, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .filename);
    }

    pub fn beInFolder(self: *const FilesShouldNot, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .path_without_filename);
    }

    pub fn beInPath(self: *const FilesShouldNot, pattern: Pattern) BuilderError!FilesMatchPattern {
        return FilesMatchPattern.init(&self.rule, pattern, .path);
    }

    pub fn dependOnFiles(self: *const FilesShouldNot) BuilderError!FilesDependOnBuilder {
        return .{ .rule = try self.rule.clone() };
    }

    pub fn dependOnExternalModules(self: *const FilesShouldNot) BuilderError!FilesExternalModuleBuilder {
        return .{
            .rule = try self.rule.clone(),
            .categories = external_assertion.defaultExternalModuleCategories(),
        };
    }

    pub fn adhereTo(
        self: *const FilesShouldNot,
        predicate: CustomFilePredicate,
        policy_description: []const u8,
    ) BuilderError!FilesAdhereTo {
        return FilesAdhereTo.init(&self.rule, predicate, policy_description);
    }
};

pub fn projectFiles(allocator: Allocator, options: ProjectOptions) BuilderError!FilesScope {
    return FilesScope.init(allocator, options);
}

pub fn files(allocator: Allocator, options: ProjectOptions) BuilderError!FilesScope {
    return projectFiles(allocator, options);
}

fn mapPatternFailure(failure: anyerror) BuilderError {
    return if (failure == error.OutOfMemory) error.OutOfMemory else error.InvalidPattern;
}

fn matchingModeFor(pattern: Pattern) matching.MatchingMode {
    return switch (pattern) {
        .glob => .exact,
        .regex => .partial,
    };
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn extractRuleGraph(rule: *const FileRuleContext, options: CheckOptions) anyerror!Graph {
    var diagnostics = common_error.ErrorContext.init(options.allocator);
    defer diagnostics.deinit();
    return extraction.extractProjectGraphLogged(
        options.allocator,
        options.io,
        rule.scope.projectLocator(),
        options.working_directory,
        options.extraction,
        options.clear_cache,
        &diagnostics,
        options.logger,
    );
}

fn guardRuleSelection(
    rule: *const FileRuleContext,
    matched_count: usize,
    options: CheckOptions,
    rule_id: []const u8,
) anyerror!?assertion.ViolationList {
    return guardScopeSelection(&rule.scope, rule.mood(), matched_count, options, rule_id);
}

fn guardScopeSelection(
    scope_value: *const FilesScope,
    mood: Mood,
    matched_count: usize,
    options: CheckOptions,
    rule_id: []const u8,
) anyerror!?assertion.ViolationList {
    if (matched_count != 0) return null;
    var scope = try scope_value.scopePatterns(options.allocator);
    defer scope.deinit(options.allocator);
    return assertion.guardEmptyTest(
        options.allocator,
        matched_count,
        options.allow_empty_tests,
        rule_id,
        scope.items(),
        mood,
    );
}

fn guardCompiledPatternSelection(
    patterns: []const CompiledPattern,
    exclusions: []const ScopePattern,
    mood: Mood,
    matched_count: usize,
    options: CheckOptions,
    rule_id: []const u8,
) anyerror!?assertion.ViolationList {
    if (matched_count != 0) return null;
    var evidence = ScopePatterns{};
    defer evidence.deinit(options.allocator);
    try evidence.values.ensureTotalCapacity(options.allocator, patterns.len + exclusions.len);
    for (patterns) |pattern| evidence.values.appendAssumeCapacity(try pattern.evidence.clone(options.allocator));
    for (exclusions) |exclusion| evidence.values.appendAssumeCapacity(try exclusion.clone(options.allocator));
    return assertion.guardEmptyTest(
        options.allocator,
        matched_count,
        options.allow_empty_tests,
        rule_id,
        evidence.items(),
        mood,
    );
}

fn containsSelected(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, wanted)) return true;
    return false;
}

fn selectorPhrase(pattern: ScopePattern) []const u8 {
    return switch (pattern.target) {
        .filename => "with name",
        .path_without_filename => "in folder",
        .path => if (pattern.syntax == .literal) "in file" else "in path",
        .declaration_name => unreachable,
    };
}

fn predicatePhrase(target: PatternTarget) []const u8 {
    return switch (target) {
        .filename => "have name",
        .path_without_filename => "be in folder",
        .path => "be in path",
        .declaration_name => unreachable,
    };
}

fn ruleIdForTarget(target: PatternTarget) []const u8 {
    return switch (target) {
        .filename => "files.have_name",
        .path_without_filename => "files.be_in_folder",
        .path => "files.be_in_path",
        .declaration_name => unreachable,
    };
}

test "entry points own optional locators without touching the filesystem" {
    var locator = [_]u8{ 'm', 'i', 's', 's', 'i', 'n', 'g', '/', 'p', 'r', 'o', 'j', 'e', 'c', 't' };
    var verbose = try projectFiles(std.testing.allocator, .{ .locator = &locator });
    defer verbose.deinit();
    var short = try files(std.testing.allocator, .{ .locator = &locator });
    defer short.deinit();
    @memset(&locator, 'x');

    try std.testing.expectEqualStrings("missing/project", verbose.projectLocator().?);
    try std.testing.expectEqualStrings(verbose.projectLocator().?, short.projectLocator().?);
    try std.testing.expectEqual(@as(usize, 0), verbose.selectorCount());
    try std.testing.expect(try verbose.matchesPath("any/file.zig"));
}

test "selector calls use AND while alternatives within one call use OR" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var folders = try entry.inFolder(&.{
        .{ .glob = "src/api" },
        .{ .glob = "src/domain" },
    });
    defer folders.deinit();
    var scope = try folders.withName(&.{
        .{ .glob = "handler.zig" },
        .{ .glob = "order.zig" },
    });
    defer scope.deinit();

    try std.testing.expectEqual(@as(usize, 2), scope.selectorCount());
    try std.testing.expectEqual(@as(?usize, 2), scope.patternCount(0));
    try std.testing.expectEqual(@as(?usize, 2), scope.patternCount(1));
    try std.testing.expectEqual(@as(?usize, null), scope.patternCount(2));
    try std.testing.expect(try scope.matchesPath("src/api/handler.zig"));
    try std.testing.expect(try scope.matchesPath("src/domain/order.zig"));
    try std.testing.expect(!try scope.matchesPath("src/api/model.zig"));
    try std.testing.expect(!try scope.matchesPath("test/api/handler.zig"));
}

test "file selector exclusions inherit or explicitly target the immediately preceding selector" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    try std.testing.expectError(error.ExclusionWithoutSelector, entry.except(&.{.{ .glob = "generated/**" }}));

    var source = try entry.inPath(&.{
        .{ .glob = "src/**" },
        .{ .glob = "test/**" },
    });
    defer source.deinit();
    var without_generated = try source.except(&.{.{ .glob = "src/**/generated/**" }});
    defer without_generated.deinit();
    var without_tests = try without_generated.exceptTargeted(
        &.{.{ .regex = "_test\\.zig$" }},
        .filename,
    );
    defer without_tests.deinit();

    try std.testing.expect(try without_tests.matchesPath("src/domain/order.zig"));
    try std.testing.expect(!try without_tests.matchesPath("src/domain/generated/deep/model.zig"));
    try std.testing.expect(!try without_tests.matchesPath("src/domain/order_test.zig"));
    try std.testing.expect(try without_tests.matchesPath("test/helper.zig"));
    try std.testing.expect(try source.matchesPath("src/domain/order_test.zig"));
    try std.testing.expectError(
        error.InvalidExclusionTarget,
        source.exceptTargeted(&.{.{ .glob = "Legacy" }}, .declaration_name),
    );

    const description = try without_tests.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(
        "project files, in path (\"src/**\" or \"test/**\"), except in path \"src/**/generated/**\", except with name regex \"_test\\\\.zig$\"",
        description,
    );
    var evidence = try without_tests.scopePatterns(std.testing.allocator);
    defer evidence.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), evidence.len());
    try std.testing.expect(!evidence.items()[1].is_exclusion);
    try std.testing.expect(evidence.items()[2].is_exclusion);
    try std.testing.expectEqual(PatternTarget.filename, evidence.items()[3].target);
}

test "real file selection omits explicit filename exclusions without changing the source branch" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var source = try entry.inPath(&.{.{ .glob = "src/**" }});
    defer source.deinit();
    var production = try source.exceptTargeted(&.{.{ .glob = "*_test.zig" }}, .filename);
    defer production.deinit();
    var positive = try production.should();
    defer positive.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var graph = try extractRuleGraph(&positive.rule, options);
    defer graph.deinit(std.testing.allocator);
    var selected = try production.select(&graph);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 3), selected.len());
    try std.testing.expect(!containsSelected(selected.items(), "src/domain/order_test.zig"));
    try std.testing.expect(try source.matchesPath("src/domain/order_test.zig"));
}

test "filename folder path and exact-file selectors inspect distinct path facts" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var named = try entry.withName(&.{.{ .glob = "*_service.zig" }});
    defer named.deinit();
    var folder = try entry.inFolder(&.{.{ .glob = "src/**/services" }});
    defer folder.deinit();
    var path = try entry.inPath(&.{.{ .regex = "^src/.+/order\\.zig$" }});
    defer path.deinit();
    var exact = try entry.inFile(&.{"src/order[legacy].zig"});
    defer exact.deinit();

    try std.testing.expect(try named.matchesPath("src/orders/order_service.zig"));
    try std.testing.expect(!try named.matchesPath("src/orders/order_repository.zig"));
    try std.testing.expect(try folder.matchesPath("src/orders/services/order.zig"));
    try std.testing.expect(!try folder.matchesPath("test/orders/services/order.zig"));
    var root_folder = try entry.inFolder(&.{.{ .glob = "." }});
    defer root_folder.deinit();
    try std.testing.expect(try root_folder.matchesPath("build.zig"));
    try std.testing.expect(!try root_folder.matchesPath("src/build.zig"));
    try std.testing.expect(try path.matchesPath("src/orders/order.zig"));
    try std.testing.expect(!try path.matchesPath("src/order.zig"));
    try std.testing.expect(try exact.matchesPath("src/order[legacy].zig"));
    try std.testing.expect(!try exact.matchesPath("src/orderl.zig"));
    var exact_evidence = try exact.scopePatterns(std.testing.allocator);
    defer exact_evidence.deinit(std.testing.allocator);
    try std.testing.expectEqual(matching.PatternSyntax.literal, exact_evidence.items()[0].syntax);
    try std.testing.expectEqual(matching.MatchingMode.exact, exact_evidence.items()[0].matching);
}

test "owned scopes branch without mutating or borrowing their base" {
    var pattern = [_]u8{ 's', 'r', 'c', '/', '*', '*' };
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var base = try entry.inFolder(&.{.{ .glob = &pattern }});
    defer base.deinit();
    @memset(&pattern, 'x');
    var services = try base.withName(&.{.{ .glob = "*_service.zig" }});
    defer services.deinit();
    var repositories = try base.withName(&.{.{ .glob = "*_repository.zig" }});
    defer repositories.deinit();

    try std.testing.expectEqual(@as(usize, 1), base.selectorCount());
    try std.testing.expectEqual(@as(usize, 2), services.selectorCount());
    try std.testing.expectEqual(@as(usize, 2), repositories.selectorCount());
    try std.testing.expect(try base.matchesPath("src/orders/order.zig"));
    try std.testing.expect(try services.matchesPath("src/orders/order_service.zig"));
    try std.testing.expect(!try services.matchesPath("src/orders/order_repository.zig"));
    try std.testing.expect(try repositories.matchesPath("src/orders/order_repository.zig"));

    var evidence = try base.scopePatterns(std.testing.allocator);
    defer evidence.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), evidence.len());
    try std.testing.expectEqualStrings("src/**", evidence.items()[0].expression);
}

test "explicit clone remains valid after its source owner is destroyed" {
    var cloned: FilesScope = undefined;
    {
        var entry = try projectFiles(std.testing.allocator, .{ .locator = "fixture" });
        defer entry.deinit();
        var source = try entry.inPath(&.{.{ .glob = "src/**" }});
        defer source.deinit();
        cloned = try source.clone();
    }
    defer cloned.deinit();

    try std.testing.expectEqualStrings("fixture", cloned.projectLocator().?);
    try std.testing.expect(try cloned.matchesPath("src/domain/order.zig"));
}

test "invalid locators and selector alternatives are clear user errors" {
    try std.testing.expectError(
        error.InvalidProjectPath,
        projectFiles(std.testing.allocator, .{ .locator = "" }),
    );
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    try std.testing.expectError(error.InvalidPattern, entry.withName(&.{}));
    try std.testing.expectError(error.InvalidPattern, entry.inFolder(&.{.{ .glob = "" }}));
    try std.testing.expectError(error.InvalidPattern, entry.inPath(&.{.{ .regex = "(" }}));
    try std.testing.expectError(error.InvalidPattern, entry.inFile(&.{""}));
}

test "scope stage type keeps selection before future mood and terminal stages" {
    try std.testing.expect(@hasDecl(FilesScope, "withName"));
    try std.testing.expect(@hasDecl(FilesScope, "inFolder"));
    try std.testing.expect(@hasDecl(FilesScope, "should"));
    try std.testing.expect(@hasDecl(FilesScope, "shouldNot"));
    try std.testing.expect(!@hasDecl(SelectedFiles, "withName"));
    try std.testing.expect(!@hasDecl(SelectedFiles, "inFolder"));
}

test "one stored scope produces independent positive and negated mood owners" {
    var positive: FilesShould = undefined;
    var negated: FilesShouldNot = undefined;
    {
        var entry = try projectFiles(std.testing.allocator, .{ .locator = "fixture" });
        defer entry.deinit();
        var base = try entry.inFolder(&.{.{ .glob = "src/domain" }});
        defer base.deinit();
        positive = try base.should();
        negated = try base.shouldNot();
        try std.testing.expectEqual(@as(usize, 1), base.selectorCount());
    }
    defer positive.deinit();
    defer negated.deinit();

    try std.testing.expectEqual(Mood.should, positive.mood());
    try std.testing.expectEqual(Mood.should_not, negated.mood());
    var positive_evidence = try positive.scopePatterns(std.testing.allocator);
    defer positive_evidence.deinit(std.testing.allocator);
    var negated_evidence = try negated.scopePatterns(std.testing.allocator);
    defer negated_evidence.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/domain", positive_evidence.items()[0].expression);
    try std.testing.expect(positive_evidence.items()[0].eql(negated_evidence.items()[0]));
}

test "both moods select the same files and invert one shared predicate" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    for ([_][]const u8{
        "src/domain/order.zig",
        "src/domain/order_test.zig",
        "src/api/handler.zig",
    }) |path| {
        try graph.add(
            std.testing.allocator,
            path,
            path,
            false,
            extraction.ImportKinds.initEmpty(),
        );
    }
    graph.sort();
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var scope = try entry.inFolder(&.{.{ .glob = "src/domain" }});
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var negated = try scope.shouldNot();
    defer negated.deinit();
    var positive_files = try positive.select(&graph);
    defer positive_files.deinit();
    var negated_files = try negated.select(&graph);
    defer negated_files.deinit();

    try std.testing.expectEqual(positive_files.len(), negated_files.len());
    var positive_violations: usize = 0;
    var negated_violations: usize = 0;
    for (positive_files.items(), negated_files.items()) |positive_path, negated_path| {
        try std.testing.expectEqualStrings(positive_path, negated_path);
        const is_test_file = std.mem.endsWith(u8, positive_path, "_test.zig");
        if (!positive.predicateHolds(is_test_file)) {
            positive_violations += 1;
            try std.testing.expectEqualStrings("src/domain/order.zig", positive_path);
        }
        if (!negated.predicateHolds(is_test_file)) {
            negated_violations += 1;
            try std.testing.expectEqualStrings("src/domain/order_test.zig", negated_path);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), positive_violations);
    try std.testing.expectEqual(@as(usize, 1), negated_violations);
}

test "mood stages prevent repeated or out-of-order fluent grammar and offer no synonyms" {
    inline for ([_][]const u8{
        "must", "mustNot", "never", "always", "shall", "shallNot", "may", "mayNot",
    }) |synonym| {
        try std.testing.expect(!@hasDecl(FilesScope, synonym));
        try std.testing.expect(!@hasDecl(FilesShould, synonym));
        try std.testing.expect(!@hasDecl(FilesShouldNot, synonym));
    }
    inline for ([_][]const u8{ "should", "shouldNot", "withName", "inFolder", "inPath", "inFile" }) |invalid| {
        try std.testing.expect(!@hasDecl(FilesShould, invalid));
        try std.testing.expect(!@hasDecl(FilesShouldNot, invalid));
    }
}

test "have no cycles is available only in the positive mood" {
    try std.testing.expect(@hasDecl(FilesShould, "haveNoCycles"));
    try std.testing.expect(!@hasDecl(FilesShouldNot, "haveNoCycles"));
}

test "all self-contained matching predicates exist in both moods and end the grammar" {
    inline for ([_][]const u8{ "haveName", "beInFolder", "beInPath" }) |predicate| {
        try std.testing.expect(@hasDecl(FilesShould, predicate));
        try std.testing.expect(@hasDecl(FilesShouldNot, predicate));
        try std.testing.expect(!@hasDecl(FilesMatchPattern, predicate));
    }
    inline for ([_][]const u8{ "should", "shouldNot", "withName", "inFolder", "inPath", "inFile" }) |stage| {
        try std.testing.expect(!@hasDecl(FilesMatchPattern, stage));
    }
}

fn matchingGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    for ([_][]const u8{
        "root.zig",
        "src/api/handler.zig",
        "src/domain/order.zig",
        "src/domain/order_test.zig",
    }) |path| try graph.add(allocator, path, path, false, extraction.ImportKinds.initEmpty());
    graph.sort();
    return graph;
}

fn selectedMatchingScope(allocator: Allocator) !FilesScope {
    var entry = try projectFiles(allocator, .{});
    defer entry.deinit();
    var folders = try entry.inFolder(&.{
        .{ .glob = "src/api" },
        .{ .glob = "src/domain" },
    });
    defer folders.deinit();
    return folders.withName(&.{
        .{ .glob = "handler.zig" },
        .{ .glob = "order*.zig" },
    });
}

fn checkPatternGraph(
    terminal: *const FilesMatchPattern,
    allocator: Allocator,
    graph: *const Graph,
) !assertion.ViolationList {
    return terminal.checkGraph(CheckOptions.init(allocator, std.testing.io), graph);
}

test "name folder and path predicates use one pure mood path over multiple subject selectors" {
    var graph = try matchingGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try selectedMatchingScope(std.testing.allocator);
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var negated = try scope.shouldNot();
    defer negated.deinit();

    var positive_name = try positive.haveName(.{ .glob = "order*.zig" });
    defer positive_name.deinit(std.testing.allocator);
    var positive_name_result = try checkPatternGraph(&positive_name, std.testing.allocator, &graph);
    defer positive_name_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive_name_result.items().len);
    try std.testing.expectEqualStrings(
        "src/api/handler.zig",
        positive_name_result.items()[0].matching.subject_path,
    );
    try std.testing.expectEqual(matching.PatternTarget.filename, positive_name_result.items()[0].matching.target);
    try std.testing.expectEqual(matching.MatchingMode.exact, positive_name_result.items()[0].matching.matching_mode);

    var negated_name = try negated.haveName(.{ .glob = "order*.zig" });
    defer negated_name.deinit(std.testing.allocator);
    var negated_name_result = try checkPatternGraph(&negated_name, std.testing.allocator, &graph);
    defer negated_name_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), negated_name_result.items().len);
    try std.testing.expectEqual(assertion.Mood.should_not, negated_name_result.items()[0].matching.mood);

    var positive_folder = try positive.beInFolder(.{ .glob = "src/domain" });
    defer positive_folder.deinit(std.testing.allocator);
    var positive_folder_result = try checkPatternGraph(&positive_folder, std.testing.allocator, &graph);
    defer positive_folder_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive_folder_result.items().len);
    try std.testing.expectEqual(matching.PatternTarget.path_without_filename, positive_folder_result.items()[0].matching.target);

    var negated_folder = try negated.beInFolder(.{ .glob = "src/domain" });
    defer negated_folder.deinit(std.testing.allocator);
    var negated_folder_result = try checkPatternGraph(&negated_folder, std.testing.allocator, &graph);
    defer negated_folder_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), negated_folder_result.items().len);

    var positive_path = try positive.beInPath(.{ .regex = "domain" });
    defer positive_path.deinit(std.testing.allocator);
    var positive_path_result = try checkPatternGraph(&positive_path, std.testing.allocator, &graph);
    defer positive_path_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive_path_result.items().len);
    try std.testing.expectEqual(matching.PatternTarget.path, positive_path_result.items()[0].matching.target);
    try std.testing.expectEqual(matching.MatchingMode.partial, positive_path_result.items()[0].matching.matching_mode);

    var negated_path = try negated.beInPath(.{ .regex = "domain" });
    defer negated_path.deinit(std.testing.allocator);
    var negated_path_result = try checkPatternGraph(&negated_path, std.testing.allocator, &graph);
    defer negated_path_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), negated_path_result.items().len);
}

test "matching predicate construction owns patterns and rejects invalid expressions immediately" {
    var scope = try projectFiles(std.testing.allocator, .{});
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var source = [_]u8{ '*', '.', 'z', 'i', 'g' };
    var terminal = try positive.haveName(.{ .glob = &source });
    defer terminal.deinit(std.testing.allocator);
    @memset(&source, 'x');
    const description = try terminal.description(std.testing.allocator);
    defer std.testing.allocator.free(description);

    try std.testing.expectEqualStrings("project files, should have name \"*.zig\"", description);
    try std.testing.expectError(error.InvalidPattern, positive.haveName(.{ .regex = "(" }));
}

test "matching predicates run through extraction and treat root files as folder dot" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var root_scope = try entry.inFile(&.{"root.zig"});
    defer root_scope.deinit();
    var positive = try root_scope.should();
    defer positive.deinit();
    var terminal = try positive.beInFolder(.{ .glob = "." });
    defer terminal.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try terminal.check(options);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passes());
}

test "direct and erased terminals log one lifecycle with extraction cache and violation events" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var root_scope = try entry.inFile(&.{"root.zig"});
    defer root_scope.deinit();
    var positive = try root_scope.should();
    defer positive.deinit();
    var terminal = try positive.haveName(.{ .glob = "missing.zig" });
    var terminal_owned = true;
    defer if (terminal_owned) terminal.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    options.logging = .{ .level = .debug, .writer = &output.writer };

    var direct = try terminal.check(options);
    defer direct.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), direct.items().len);
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    terminal_owned = false;
    defer erased.deinit();
    var through_erasure = try erased.check(options);
    defer through_erasure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), through_erasure.items().len);

    const text = output.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "[start_check]"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "[end_check]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "[extraction] project graph extraction started") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[cache] cache cleared") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[cache] cache miss") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[violation] kind=matching") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rule=files.match_pattern violations=1") != null);
}

fn expectEmptyMatchingRule(
    terminal: *const FilesMatchPattern,
    expected_rule_id: []const u8,
    expected_negated: bool,
) !void {
    var graph = try matchingGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var result = try terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, result.items()[0].kind());
    try std.testing.expectEqualStrings(expected_rule_id, result.items()[0].empty_test.rule_id);
    try std.testing.expectEqual(expected_negated, result.items()[0].empty_test.is_negated);
}

test "matching predicates share predicate-specific empty guards in both moods" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var missing = try entry.inPath(&.{.{ .glob = "missing/**" }});
    defer missing.deinit();
    var positive = try missing.should();
    defer positive.deinit();
    var negated = try missing.shouldNot();
    defer negated.deinit();
    var name = try positive.haveName(.{ .glob = "*.zig" });
    defer name.deinit(std.testing.allocator);
    try expectEmptyMatchingRule(&name, "files.have_name", false);
    var folder = try negated.beInFolder(.{ .glob = "src" });
    defer folder.deinit(std.testing.allocator);
    try expectEmptyMatchingRule(&folder, "files.be_in_folder", true);
    var path = try positive.beInPath(.{ .glob = "src/**" });
    defer path.deinit(std.testing.allocator);
    try expectEmptyMatchingRule(&path, "files.be_in_path", false);

    var graph = try matchingGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try path.checkGraph(options, &graph);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "matching terminal moves safely into a heterogeneous Checkable" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var root_scope = try entry.inFile(&.{"root.zig"});
    defer root_scope.deinit();
    var positive = try root_scope.should();
    defer positive.deinit();
    var terminal = try positive.haveName(.{ .glob = "root.zig" });
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try erased.check(options);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passes());
}

fn exerciseMatchingTerminalAllocationFailures(allocator: Allocator) !void {
    var graph = try matchingGraph(allocator);
    defer graph.deinit(allocator);
    var entry = try projectFiles(allocator, .{});
    defer entry.deinit();
    var scope = try entry.inFolder(&.{
        .{ .glob = "src/api" },
        .{ .glob = "src/domain" },
    });
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var terminal = try positive.haveName(.{ .regex = "order" });
    defer terminal.deinit(allocator);
    var result = try terminal.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "matching terminal cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMatchingTerminalAllocationFailures,
        .{},
    );
}

test "depend on files exposes an object builder in both moods and requires an object selector" {
    try std.testing.expect(@hasDecl(FilesShould, "dependOnFiles"));
    try std.testing.expect(@hasDecl(FilesShouldNot, "dependOnFiles"));
    try std.testing.expect(!@hasDecl(FilesDependOnBuilder, "check"));
    inline for ([_][]const u8{ "withName", "inFolder", "inPath", "inFile" }) |selector| {
        try std.testing.expect(@hasDecl(FilesDependOnBuilder, selector));
        try std.testing.expect(@hasDecl(FilesDependOn, selector));
    }
    inline for ([_][]const u8{ "should", "shouldNot", "dependOnFiles" }) |stage| {
        try std.testing.expect(!@hasDecl(FilesDependOn, stage));
    }
}

fn dependencyGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    for ([_][]const u8{
        "src/api/handler.zig",
        "src/database/model.zig",
        "src/database/root.zig",
    }) |path| try graph.add(allocator, path, path, false, extraction.ImportKinds.initEmpty());
    try graph.addLocated(
        allocator,
        "src/api/handler.zig",
        "src/database/root.zig",
        false,
        extraction.ImportKinds.initOne(.named_module),
        &.{.{ .byte_offset = 0, .line = 1, .column = 1 }},
    );
    try graph.addLocated(
        allocator,
        "src/api/handler.zig",
        "config.zon",
        false,
        extraction.ImportKinds.initOne(.zon_file),
        &.{.{ .byte_offset = 20, .line = 2, .column = 1 }},
    );
    try graph.addLocated(
        allocator,
        "src/database/root.zig",
        "src/database/model.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        &.{.{ .byte_offset = 0, .line = 1, .column = 1 }},
    );
    try graph.add(
        allocator,
        "src/api/handler.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    graph.sort();
    return graph;
}

fn dependencySubject(allocator: Allocator, mood: Mood) !FileRuleContext {
    var entry = try projectFiles(allocator, .{});
    defer entry.deinit();
    var api = try entry.inFile(&.{"src/api/handler.zig"});
    defer api.deinit();
    return FileRuleContext.init(&api, mood);
}

test "dependency object selection includes ZON targets and excludes external modules" {
    var graph = try dependencyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var scope = try projectFiles(std.testing.allocator, .{});
    defer scope.deinit();
    var selected = try scope.selectDependencyObjects(&graph);
    defer selected.deinit();

    try std.testing.expectEqual(@as(usize, 4), selected.len());
    try std.testing.expectEqualStrings("config.zon", selected.items()[0]);
    try std.testing.expectEqualStrings("src/api/handler.zig", selected.items()[1]);
    try std.testing.expect(!containsSelected(selected.items(), "std"));
}

test "dependency object exclusions qualify only the latest object selector" {
    var graph = try dependencyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var rule = try dependencySubject(std.testing.allocator, .should);
    defer rule.deinit();
    var builder = FilesDependOnBuilder{ .rule = try rule.clone() };
    defer builder.deinit();
    var database = try builder.inPath(&.{.{ .glob = "src/database/**" }});
    defer database.deinit(std.testing.allocator);
    var only_root = try database.exceptTargeted(&.{.{ .glob = "model.zig" }}, .filename);
    defer only_root.deinit(std.testing.allocator);
    var config_too = try only_root.inFile(&.{"config.zon"});
    defer config_too.deinit(std.testing.allocator);

    var selected = try config_too.objects.selectDependencyObjects(&graph);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 0), selected.len());
    try std.testing.expect(try only_root.objects.matchesPath("src/database/root.zig"));
    try std.testing.expect(!try only_root.objects.matchesPath("src/database/model.zig"));
    try std.testing.expect(try database.objects.matchesPath("src/database/model.zig"));

    const description = try only_root.description(std.testing.allocator);
    defer std.testing.allocator.free(description);
    try std.testing.expect(std.mem.indexOf(
        u8,
        description,
        "depend on files, in path \"src/database/**\", except with name \"model.zig\"",
    ) != null);
}

test "direct dependency allowlists and blocklists chain object selectors with grouped evidence" {
    var graph = try dependencyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var positive_rule = try dependencySubject(std.testing.allocator, .should);
    defer positive_rule.deinit();
    var positive_builder = FilesDependOnBuilder{ .rule = try positive_rule.clone() };
    defer positive_builder.deinit();
    var database_folder = try positive_builder.inFolder(&.{.{ .glob = "src/database" }});
    defer database_folder.deinit(std.testing.allocator);
    var database_root = try database_folder.withName(&.{.{ .glob = "root.zig" }});
    defer database_root.deinit(std.testing.allocator);
    var positive = try database_root.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer positive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive.items().len);
    try std.testing.expectEqualStrings("config.zon", positive.items()[0].file_dependency.items()[0].target_label);

    var negative_rule = try dependencySubject(std.testing.allocator, .should_not);
    defer negative_rule.deinit();
    var negative_builder = FilesDependOnBuilder{ .rule = try negative_rule.clone() };
    defer negative_builder.deinit();
    var forbidden = try negative_builder.inPath(&.{
        .{ .glob = "src/database/**" },
        .{ .glob = "config.zon" },
    });
    defer forbidden.deinit(std.testing.allocator);
    var negative = try forbidden.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer negative.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), negative.items().len);
    try std.testing.expectEqual(@as(usize, 2), negative.items()[0].file_dependency.items().len);
    try std.testing.expectEqualStrings("src/api/handler.zig", negative.items()[0].file_dependency.source_path);
    try std.testing.expectEqual(@as(u32, 1), negative.items()[0].file_dependency.items()[1].evidence()[0].locationItems()[0].line);
}

test "dependency checks are direct only and ignore normalization self edges" {
    var graph = try dependencyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var rule = try dependencySubject(std.testing.allocator, .should_not);
    defer rule.deinit();
    var builder = FilesDependOnBuilder{ .rule = try rule.clone() };
    defer builder.deinit();
    var transitive_object = try builder.inFile(&.{"src/database/model.zig"});
    defer transitive_object.deinit(std.testing.allocator);
    var transitive = try transitive_object.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer transitive.deinit(std.testing.allocator);
    try std.testing.expect(transitive.passes());

    var self_object = try builder.inFile(&.{"src/api/handler.zig"});
    defer self_object.deinit(std.testing.allocator);
    var self_result = try self_object.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer self_result.deinit(std.testing.allocator);
    try std.testing.expect(self_result.passes());
}

test "dependency rules guard missing subject and object selections separately" {
    var graph = try dependencyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var missing_subject = try entry.inFolder(&.{.{ .glob = "missing" }});
    defer missing_subject.deinit();
    var missing_mood = try missing_subject.should();
    defer missing_mood.deinit();
    var subject_builder = try missing_mood.dependOnFiles();
    defer subject_builder.deinit();
    var subject_terminal = try subject_builder.inFolder(&.{.{ .glob = "src/database" }});
    defer subject_terminal.deinit(std.testing.allocator);
    var subject_result = try subject_terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer subject_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "files.depend_on_files.subject",
        subject_result.items()[0].empty_test.rule_id,
    );

    var api = try entry.inFile(&.{"src/api/handler.zig"});
    defer api.deinit();
    var negated = try api.shouldNot();
    defer negated.deinit();
    var object_builder = try negated.dependOnFiles();
    defer object_builder.deinit();
    var object_terminal = try object_builder.inFolder(&.{.{ .glob = "missing" }});
    defer object_terminal.deinit(std.testing.allocator);
    var object_result = try object_terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer object_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "files.depend_on_files.object",
        object_result.items()[0].empty_test.rule_id,
    );
    try std.testing.expect(object_result.items()[0].empty_test.is_negated);

    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try object_terminal.checkGraph(options, &graph);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());

    var positive = try api.should();
    defer positive.deinit();
    var positive_object_builder = try positive.dependOnFiles();
    defer positive_object_builder.deinit();
    var positive_object = try positive_object_builder.inFolder(&.{.{ .glob = "missing" }});
    defer positive_object.deinit(std.testing.allocator);
    var positive_object_result = try positive_object.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer positive_object_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "files.depend_on_files.object",
        positive_object_result.items()[0].empty_test.rule_id,
    );
    try std.testing.expect(!positive_object_result.items()[0].empty_test.is_negated);
}

test "API to database fixture resolves module aliases and ZON objects with locations" {
    const modules = [_]fluentapi.ModuleOverride{.{
        .name = "database",
        .source_path = "src/database/root.zig",
    }};
    const units = [_]fluentapi.CompilationUnitOverride{.{
        .id = "app",
        .root_source_path = "src/main.zig",
        .modules = &modules,
    }};
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-dependencies" });
    defer entry.deinit();
    var api = try entry.inFolder(&.{.{ .glob = "src/api" }});
    defer api.deinit();
    var negated = try api.shouldNot();
    defer negated.deinit();
    var builder = try negated.dependOnFiles();
    defer builder.deinit();
    var database = try builder.inFolder(&.{.{ .glob = "src/database" }});
    defer database.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    options.extraction.module_resolution = .{ .compilation_units = &units };
    var database_result = try database.check(options);
    defer database_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), database_result.items().len);
    const alias_edge = database_result.items()[0].file_dependency.items()[0].evidence()[0];
    try std.testing.expect(alias_edge.import_kinds.contains(.named_module));
    try std.testing.expectEqual(@as(u32, 1), alias_edge.locationItems()[0].line);

    var config = try builder.inFile(&.{"config.zon"});
    defer config.deinit(std.testing.allocator);
    var config_result = try config.check(options);
    defer config_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config_result.items().len);
    const zon_edge = config_result.items()[0].file_dependency.items()[0].evidence()[0];
    try std.testing.expect(zon_edge.import_kinds.contains(.zon_file));
    try std.testing.expectEqual(@as(u32, 2), zon_edge.locationItems()[0].line);

    var positive = try api.should();
    defer positive.deinit();
    var positive_builder = try positive.dependOnFiles();
    defer positive_builder.deinit();
    var allowed_terminal = try positive_builder.inPath(&.{
        .{ .glob = "src/database/**" },
        .{ .glob = "config.zon" },
        .{ .glob = "src/main.zig" },
    });
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &allowed_terminal);
    defer erased.deinit();
    var allowed_result = try erased.check(options);
    defer allowed_result.deinit(std.testing.allocator);
    try std.testing.expect(allowed_result.passes());
}

fn exerciseDependOnAllocationFailures(allocator: Allocator) !void {
    var graph = try dependencyGraph(allocator);
    defer graph.deinit(allocator);
    var rule = try dependencySubject(allocator, .should_not);
    defer rule.deinit();
    var builder = FilesDependOnBuilder{ .rule = try rule.clone() };
    defer builder.deinit();
    var terminal = try builder.inPath(&.{
        .{ .glob = "src/database/**" },
        .{ .glob = "config.zon" },
    });
    defer terminal.deinit(allocator);
    var result = try terminal.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "depend on files terminal cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDependOnAllocationFailures,
        .{},
    );
}

test "external module policy builder exists in both moods and category modifiers are explicit" {
    try std.testing.expect(@hasDecl(FilesShould, "dependOnExternalModules"));
    try std.testing.expect(@hasDecl(FilesShouldNot, "dependOnExternalModules"));
    try std.testing.expect(!@hasDecl(FilesExternalModuleBuilder, "check"));
    try std.testing.expect(@hasDecl(FilesExternalModuleBuilder, "matching"));
    inline for ([_][]const u8{
        "includingCompilerModules",
        "includingCHeaders",
        "includingResources",
    }) |modifier| {
        try std.testing.expect(@hasDecl(FilesExternalModuleBuilder, modifier));
        try std.testing.expect(@hasDecl(FilesExternalModules, modifier));
    }
    try std.testing.expect(@hasDecl(FilesExternalModules, "matching"));
    try std.testing.expect(!@hasDecl(FilesExternalModules, "should"));
}

fn externalPolicyGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try graph.add(allocator, "src/client.zig", "src/client.zig", false, extraction.ImportKinds.initEmpty());
    try graph.addClassifiedLocated(
        allocator,
        "src/client.zig",
        "http_client",
        true,
        extraction.ImportKinds.initOne(.named_module),
        .external,
        .resolved,
        &.{.{ .byte_offset = 0, .line = 1, .column = 1 }},
    );
    try graph.addClassifiedLocated(
        allocator,
        "src/client.zig",
        "telemetry",
        true,
        extraction.ImportKinds.initOne(.named_module),
        .external,
        .unresolved,
        &.{.{ .byte_offset = 20, .line = 2, .column = 1 }},
    );
    try graph.addClassifiedLocated(
        allocator,
        "src/client.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
        .compiler,
        .resolved,
        &.{.{ .byte_offset = 40, .line = 3, .column = 1 }},
    );
    graph.sort();
    return graph;
}

fn externalSubject(allocator: Allocator, mood: Mood) !FileRuleContext {
    var entry = try projectFiles(allocator, .{});
    defer entry.deinit();
    var client = try entry.inFile(&.{"src/client.zig"});
    defer client.deinit();
    return FileRuleContext.init(&client, mood);
}

test "external module terminals OR repeated patterns and keep compiler modules opt in" {
    var graph = try externalPolicyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var rule = try externalSubject(std.testing.allocator, .should_not);
    defer rule.deinit();
    var builder = FilesExternalModuleBuilder{
        .rule = try rule.clone(),
        .categories = external_assertion.defaultExternalModuleCategories(),
    };
    defer builder.deinit();
    var first = try builder.matching(&.{.{ .glob = "http_client" }});
    defer first.deinit(std.testing.allocator);
    var both = try first.matching(&.{.{ .regex = "^telemetry$" }});
    defer both.deinit(std.testing.allocator);
    var result = try both.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(@as(usize, 2), result.items()[0].external_module_dependency.items().len);
    try std.testing.expectEqualStrings("http_client", result.items()[0].external_module_dependency.items()[0].target_label);
    try std.testing.expectEqualStrings("telemetry", result.items()[0].external_module_dependency.items()[1].target_label);

    var compiler_default = try builder.matching(&.{.{ .glob = "std" }});
    defer compiler_default.deinit(std.testing.allocator);
    var empty = try compiler_default.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.passes());

    var compiler_enabled = try compiler_default.includingCompilerModules();
    defer compiler_enabled.deinit(std.testing.allocator);
    var compiler_result = try compiler_enabled.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer compiler_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiler_result.items().len);
    try std.testing.expectEqualStrings("std", compiler_result.items()[0].external_module_dependency.items()[0].target_label);
}

test "external module exclusions use the shared filter and retain later OR alternatives" {
    var graph = try externalPolicyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var rule = try externalSubject(std.testing.allocator, .should_not);
    defer rule.deinit();
    var builder = FilesExternalModuleBuilder{
        .rule = try rule.clone(),
        .categories = external_assertion.defaultExternalModuleCategories(),
    };
    defer builder.deinit();
    var broad = try builder.matching(&.{.{ .regex = ".+" }});
    defer broad.deinit(std.testing.allocator);
    var without_telemetry = try broad.except(&.{.{ .glob = "telemetry" }});
    defer without_telemetry.deinit(std.testing.allocator);
    var telemetry_restored = try without_telemetry.matching(&.{.{ .glob = "telemetry" }});
    defer telemetry_restored.deinit(std.testing.allocator);

    var excluded = try without_telemetry.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer excluded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), excluded.items().len);
    try std.testing.expectEqual(@as(usize, 1), excluded.items()[0].external_module_dependency.items().len);
    try std.testing.expectEqualStrings(
        "http_client",
        excluded.items()[0].external_module_dependency.items()[0].target_label,
    );

    var restored = try telemetry_restored.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), restored.items()[0].external_module_dependency.items().len);
    try std.testing.expectError(
        error.InvalidExclusionTarget,
        broad.exceptTargeted(&.{.{ .glob = "Legacy" }}, .declaration_name),
    );
}

test "negative external absence passes while positive zero-candidate rules stay guarded" {
    var graph = try externalPolicyGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var rule = try externalSubject(std.testing.allocator, .should_not);
    defer rule.deinit();
    var builder = FilesExternalModuleBuilder{
        .rule = try rule.clone(),
        .categories = external_assertion.defaultExternalModuleCategories(),
    };
    defer builder.deinit();
    var terminal = try builder.matching(&.{.{ .glob = "misspelled" }});
    defer terminal.deinit(std.testing.allocator);
    var rejected = try terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected.passes());

    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try terminal.checkGraph(options, &graph);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());

    var positive_rule = try externalSubject(std.testing.allocator, .should);
    defer positive_rule.deinit();
    var positive_builder = FilesExternalModuleBuilder{
        .rule = try positive_rule.clone(),
        .categories = external_assertion.defaultExternalModuleCategories(),
    };
    defer positive_builder.deinit();
    var positive_miss = try positive_builder.matching(&.{.{ .glob = "misspelled" }});
    defer positive_miss.deinit(std.testing.allocator);
    var positive_miss_result = try positive_miss.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer positive_miss_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive_miss_result.items().len);
    try std.testing.expectEqual(
        assertion.Violation.Kind.external_module_dependency,
        positive_miss_result.items()[0].kind(),
    );
    var allow_empty_options = CheckOptions.init(std.testing.allocator, std.testing.io);
    allow_empty_options.allow_empty_tests = true;
    var positive_miss_allowed = try positive_miss.checkGraph(allow_empty_options, &graph);
    defer positive_miss_allowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        assertion.Violation.Kind.external_module_dependency,
        positive_miss_allowed.items()[0].kind(),
    );

    var no_external: Graph = .{};
    defer no_external.deinit(std.testing.allocator);
    try no_external.add(
        std.testing.allocator,
        "src/client.zig",
        "src/client.zig",
        false,
        extraction.ImportKinds.initEmpty(),
    );
    var positive_empty = try positive_miss.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &no_external,
    );
    defer positive_empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "files.depend_on_external_modules.object",
        positive_empty.items()[0].empty_test.rule_id,
    );
    var positive_empty_allowed = try positive_miss.checkGraph(allow_empty_options, &no_external);
    defer positive_empty_allowed.deinit(std.testing.allocator);
    try std.testing.expect(positive_empty_allowed.passes());
    var negative_empty = try terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &no_external,
    );
    defer negative_empty.deinit(std.testing.allocator);
    try std.testing.expect(negative_empty.passes());

    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var missing = try entry.inFolder(&.{.{ .glob = "missing" }});
    defer missing.deinit();
    var missing_mood = try missing.should();
    defer missing_mood.deinit();
    var missing_builder = try missing_mood.dependOnExternalModules();
    defer missing_builder.deinit();
    var missing_terminal = try missing_builder.matching(&.{.{ .glob = "http_client" }});
    defer missing_terminal.deinit(std.testing.allocator);
    var missing_result = try missing_terminal.checkGraph(
        CheckOptions.init(std.testing.allocator, std.testing.io),
        &graph,
    );
    defer missing_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "files.depend_on_external_modules.subject",
        missing_result.items()[0].empty_test.rule_id,
    );
}

test "external module fixture distinguishes local aliases packages unresolved and explicit categories" {
    const modules = [_]fluentapi.ModuleOverride{
        .{ .name = "database", .source_path = "src/database/root.zig" },
        .{ .name = "http_client", .source_path = "vendor/http/root.zig", .origin = .package },
    };
    const units = [_]fluentapi.CompilationUnitOverride{.{
        .id = "app",
        .root_source_path = "src/main.zig",
        .modules = &modules,
    }};
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-dependencies" });
    defer entry.deinit();
    var api = try entry.inFolder(&.{.{ .glob = "src/api" }});
    defer api.deinit();
    var negated = try api.shouldNot();
    defer negated.deinit();
    var builder = try negated.dependOnExternalModules();
    defer builder.deinit();
    var package = try builder.matching(&.{.{ .glob = "http_client" }});
    defer package.deinit(std.testing.allocator);
    var named = try package.matching(&.{.{ .glob = "telemetry" }});
    defer named.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    options.extraction.module_resolution = .{ .compilation_units = &units };
    var named_result = try named.check(options);
    defer named_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), named_result.items().len);
    const named_edges = named_result.items()[0].external_module_dependency.items();
    try std.testing.expectEqual(@as(usize, 2), named_edges.len);
    try std.testing.expect(named_edges[0].evidence()[0].target_availabilities.contains(.resolved));
    try std.testing.expect(named_edges[1].evidence()[0].target_availabilities.contains(.unresolved));
    for (named_edges) |edge| try std.testing.expect(!std.mem.eql(u8, edge.target_label, "database"));

    var compiler_builder = try builder.includingCompilerModules();
    defer compiler_builder.deinit();
    var compiler = try compiler_builder.matching(&.{
        .{ .glob = "std" },
        .{ .glob = "builtin" },
    });
    defer compiler.deinit(std.testing.allocator);
    var compiler_result = try compiler.check(options);
    defer compiler_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), compiler_result.items()[0].external_module_dependency.items().len);
    for (compiler_result.items()[0].external_module_dependency.items()) |edge| {
        try std.testing.expect(!std.mem.eql(u8, edge.target_label, "root"));
    }

    var header_builder = try builder.includingCHeaders();
    defer header_builder.deinit();
    var header = try header_builder.matching(&.{.{ .glob = "sqlite3.h" }});
    defer header.deinit(std.testing.allocator);
    var header_result = try header.check(options);
    defer header_result.deinit(std.testing.allocator);
    try std.testing.expect(header_result.items()[0].external_module_dependency.items()[0].evidence()[0].target_classes.contains(.c_header));

    var resource_builder = try builder.includingResources();
    defer resource_builder.deinit();
    var resource = try resource_builder.matching(&.{.{ .glob = "missing.json" }});
    defer resource.deinit(std.testing.allocator);
    var resource_result = try resource.check(options);
    defer resource_result.deinit(std.testing.allocator);
    try std.testing.expect(resource_result.items()[0].external_module_dependency.items()[0].evidence()[0].target_classes.contains(.resource));

    var positive = try api.should();
    defer positive.deinit();
    var positive_builder = try positive.dependOnExternalModules();
    defer positive_builder.deinit();
    var allowed_package = try positive_builder.matching(&.{.{ .glob = "http_client" }});
    defer allowed_package.deinit(std.testing.allocator);
    var allowed_named = try allowed_package.matching(&.{.{ .glob = "telemetry" }});
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &allowed_named);
    defer erased.deinit();
    var allowed_result = try erased.check(options);
    defer allowed_result.deinit(std.testing.allocator);
    try std.testing.expect(allowed_result.passes());
}

fn exerciseExternalTerminalAllocationFailures(allocator: Allocator) !void {
    var graph = try externalPolicyGraph(allocator);
    defer graph.deinit(allocator);
    var rule = try externalSubject(allocator, .should_not);
    defer rule.deinit();
    var builder = FilesExternalModuleBuilder{
        .rule = try rule.clone(),
        .categories = external_assertion.defaultExternalModuleCategories(),
    };
    defer builder.deinit();
    var first = try builder.matching(&.{.{ .glob = "http_client" }});
    defer first.deinit(allocator);
    var terminal = try first.matching(&.{.{ .regex = "telemetry" }});
    defer terminal.deinit(allocator);
    var result = try terminal.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "external module terminal cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExternalTerminalAllocationFailures,
        .{},
    );
}

fn handlerHasExpectedFileInfo(allocator: Allocator, info: file_info_extraction.FileInfo) !bool {
    const copied_path = try allocator.dupe(u8, info.path);
    defer allocator.free(copied_path);
    return std.mem.eql(u8, copied_path, "src/api/handler.zig") and
        std.mem.eql(u8, info.stem, "handler") and
        std.mem.eql(u8, info.extension, ".zig") and
        std.mem.eql(u8, info.directory, "src/api") and
        info.source_bytes.len != 0 and
        info.non_blank_line_count == 4 and
        info.imports.total == 1 and
        info.imports.count(.zig_file) == 1 and
        info.top_level_declarations.?.functions == 1 and
        info.top_level_declarations.?.variables == 1;
}

fn alwaysAcceptFile(_: Allocator, _: file_info_extraction.FileInfo) !bool {
    return true;
}

fn predicateCheckFailure(_: Allocator, _: file_info_extraction.FileInfo) !bool {
    return error.ProjectSpecificAnalysisFailed;
}

fn acceptInvalidAndEmpty(info_allocator: Allocator, info: file_info_extraction.FileInfo) !bool {
    _ = info_allocator;
    if (std.mem.eql(u8, info.stem, "legacy")) {
        return info.source_bytes.len == 2 and
            info.source_bytes[0] == 0xff and
            info.non_blank_line_count == 1 and
            info.imports.total == 0 and
            info.top_level_declarations == null;
    }
    if (std.mem.eql(u8, info.stem, "empty")) {
        return info.source_bytes.len == 0 and
            info.non_blank_line_count == 0 and
            info.top_level_declarations.?.total == 0;
    }
    return false;
}

test "adhereTo grammar owns its description and exists in both moods" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var positive = try entry.should();
    defer positive.deinit();
    var negative = try entry.shouldNot();
    defer negative.deinit();
    var mutable_description = [_]u8{ 'f', 'i', 'l', 'e', 's', ' ', 's', 't', 'a', 'y', ' ', 's', 'm', 'a', 'l', 'l' };
    var terminal = try positive.adhereTo(alwaysAcceptFile, &mutable_description);
    defer terminal.deinit(std.testing.allocator);
    @memset(&mutable_description, 'x');
    const rendered = try terminal.description(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "project files, should adhere to \"files stay small\"",
        rendered,
    );
    try std.testing.expect(@hasDecl(FilesShould, "adhereTo"));
    try std.testing.expect(@hasDecl(FilesShouldNot, "adhereTo"));
    try std.testing.expectError(
        error.InvalidDescription,
        negative.adhereTo(alwaysAcceptFile, " \n\t"),
    );
}

test "adhereTo checks a selected real Zig file and moves through Checkable" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var handler = try entry.inFile(&.{"src/api/handler.zig"});
    defer handler.deinit();
    var positive = try handler.should();
    defer positive.deinit();
    var terminal = try positive.adhereTo(
        handlerHasExpectedFileInfo,
        "handler metadata stays stable",
    );
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    var result = try erased.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var negative = try handler.shouldNot();
    defer negative.deinit();
    var rejected = try negative.adhereTo(alwaysAcceptFile, "handler must not match");
    defer rejected.deinit(std.testing.allocator);
    var negative_result = try rejected.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer negative_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), negative_result.items().len);
    const violation = negative_result.items()[0].custom_file;
    try std.testing.expectEqualStrings("src/api/handler.zig", violation.source_path);
    try std.testing.expectEqualStrings("handler must not match", violation.description);
    try std.testing.expectEqual(Mood.should_not, violation.mood);
    try std.testing.expectEqual(@as(usize, 1), violation.imports.total);
    try std.testing.expectEqual(@as(usize, 1), violation.top_level_declarations.?.functions);
}

test "adhereTo propagates callback errors instead of manufacturing violations" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var handler = try entry.inFile(&.{"src/api/handler.zig"});
    defer handler.deinit();
    var positive = try handler.should();
    defer positive.deinit();
    var terminal = try positive.adhereTo(predicateCheckFailure, "callback succeeds");
    defer terminal.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ProjectSpecificAnalysisFailed,
        terminal.check(CheckOptions.init(std.testing.allocator, std.testing.io)),
    );
}

test "adhereTo guards empty subjects before invoking the callback" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var missing = try entry.inFolder(&.{.{ .glob = "missing" }});
    defer missing.deinit();
    var positive = try missing.should();
    defer positive.deinit();
    var terminal = try positive.adhereTo(predicateCheckFailure, "callback succeeds");
    defer terminal.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    var rejected = try terminal.check(options);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("files.adhere_to", rejected.items()[0].empty_test.rule_id);

    options.allow_empty_tests = true;
    var allowed = try terminal.check(options);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "adhereTo presents invalid UTF-8 and empty sources as byte-safe views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = ".{ .name = .custom_fixture }" });
    const invalid = [_]u8{ 0xff, '\n' };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/legacy.zig", .data = &invalid });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/empty.zig", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var entry = try projectFiles(std.testing.allocator, .{ .locator = root });
    defer entry.deinit();
    var source = try entry.inFolder(&.{.{ .glob = "src" }});
    defer source.deinit();
    var positive = try source.should();
    defer positive.deinit();
    var terminal = try positive.adhereTo(acceptInvalidAndEmpty, "raw sources stay inspectable");
    defer terminal.deinit(std.testing.allocator);
    var result = try terminal.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

fn exerciseAdhereToTerminalAllocationFailures(allocator: Allocator) !void {
    var entry = try projectFiles(allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var handler = try entry.inFile(&.{"src/api/handler.zig"});
    defer handler.deinit();
    var positive = try handler.should();
    defer positive.deinit();
    var terminal = try positive.adhereTo(handlerHasExpectedFileInfo, "handler metadata stays stable");
    defer terminal.deinit(allocator);
    var result = try terminal.check(CheckOptions.init(allocator, std.testing.io));
    defer result.deinit(allocator);
    try std.testing.expect(result.passes());
}

test "adhereTo terminal cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAdhereToTerminalAllocationFailures,
        .{},
    );
}

fn expectEmptyGuardForTerminal(
    terminal: anytype,
    expected_rule_id: []const u8,
    expected_negated: bool,
) !void {
    var rejected = try terminal.check(CheckOptions.init(std.testing.allocator, std.testing.io));
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rejected.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, rejected.items()[0].kind());
    try std.testing.expectEqualStrings(expected_rule_id, rejected.items()[0].empty_test.rule_id);
    try std.testing.expectEqual(expected_negated, rejected.items()[0].empty_test.is_negated);
    try std.testing.expectEqual(@as(usize, 1), rejected.items()[0].empty_test.scope.len);
    try std.testing.expectEqualStrings(
        "src/servcies",
        rejected.items()[0].empty_test.scope[0].expression,
    );

    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try terminal.check(options);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "every public file terminal shares the real-fixture empty subject guard" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-selection" });
    defer entry.deinit();
    var misspelled = try entry.inFolder(&.{.{ .glob = "src/servcies" }});
    defer misspelled.deinit();
    var positive = try misspelled.should();
    defer positive.deinit();
    var negative = try misspelled.shouldNot();
    defer negative.deinit();

    var cycles = try positive.haveNoCycles();
    defer cycles.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&cycles, "files.have_no_cycles", false);

    var name = try negative.haveName(.{ .glob = "*.zig" });
    defer name.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&name, "files.have_name", true);

    var folder = try negative.beInFolder(.{ .glob = "src" });
    defer folder.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&folder, "files.be_in_folder", true);

    var path = try negative.beInPath(.{ .glob = "src/**" });
    defer path.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&path, "files.be_in_path", true);

    var dependency_builder = try positive.dependOnFiles();
    defer dependency_builder.deinit();
    var dependency = try dependency_builder.inFolder(&.{.{ .glob = "src/domain" }});
    defer dependency.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&dependency, "files.depend_on_files.subject", false);

    var external_builder = try negative.dependOnExternalModules();
    defer external_builder.deinit();
    var external = try external_builder.matching(&.{.{ .glob = "std" }});
    defer external.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&external, "files.depend_on_external_modules.subject", true);

    var custom = try positive.adhereTo(predicateCheckFailure, "callback must not run");
    defer custom.deinit(std.testing.allocator);
    try expectEmptyGuardForTerminal(&custom, "files.adhere_to", false);
}

fn checkCycleFixture(locator: []const u8) !assertion.ViolationList {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = locator });
    defer entry.deinit();
    var positive = try entry.should();
    defer positive.deinit();
    var terminal = try positive.haveNoCycles();
    defer terminal.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    return terminal.check(options);
}

test "have no cycles passes and fails against real Zig fixture projects" {
    var passing = try checkCycleFixture("test/fixtures/files-cycles/pass");
    defer passing.deinit(std.testing.allocator);
    try std.testing.expect(passing.passes());

    var failing = try checkCycleFixture("test/fixtures/files-cycles/fail");
    defer failing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), failing.items().len);
    for (failing.items()) |violation| try std.testing.expectEqual(assertion.Violation.Kind.cycle, violation.kind());

    const formatCyclePath = @import("../../testing.zig").formatCyclePath;
    const first_path = try formatCyclePath(std.testing.allocator, failing.items()[0].cycle.path);
    defer std.testing.allocator.free(first_path);
    try std.testing.expectEqualStrings("src/a.zig -> src/b.zig -> src/a.zig", first_path);
    const first_import = failing.items()[0].cycle.path.items()[0].evidence()[0];
    try std.testing.expectEqualStrings("src/a.zig", first_import.source);
    try std.testing.expectEqualStrings("src/b.zig", first_import.target);
    try std.testing.expectEqual(@as(usize, 1), first_import.locationItems().len);
    try std.testing.expectEqual(@as(u32, 1), first_import.locationItems()[0].line);
}

test "selection boundaries do not contract an outside intermediate file" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-cycles/fail" });
    defer entry.deinit();
    var boundary = try entry.inFolder(&.{.{ .glob = "src/boundary" }});
    defer boundary.deinit();
    var positive = try boundary.should();
    defer positive.deinit();
    var terminal = try positive.haveNoCycles();
    defer terminal.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try terminal.check(options);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passes());
}

test "empty selections fail by default and can be explicitly allowed" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-cycles/pass" });
    defer entry.deinit();
    var missing = try entry.inPath(&.{.{ .glob = "missing/**" }});
    defer missing.deinit();
    var positive = try missing.should();
    defer positive.deinit();
    var terminal = try positive.haveNoCycles();
    defer terminal.deinit(std.testing.allocator);
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var rejected = try terminal.check(options);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rejected.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, rejected.items()[0].kind());
    try std.testing.expectEqualStrings("files.have_no_cycles", rejected.items()[0].empty_test.rule_id);

    options.allow_empty_tests = true;
    var allowed = try terminal.check(options);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "have no cycles terminal moves safely into a heterogeneous Checkable" {
    var entry = try projectFiles(std.testing.allocator, .{ .locator = "test/fixtures/files-cycles/pass" });
    defer entry.deinit();
    var positive = try entry.should();
    defer positive.deinit();
    var terminal = try positive.haveNoCycles();
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &terminal);
    defer erased.deinit();
    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    var result = try erased.check(options);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passes());
}

fn exerciseCycleRuleAllocationFailures(allocator: Allocator) !void {
    var graph: Graph = .{};
    defer graph.deinit(allocator);
    try graph.add(allocator, "a.zig", "a.zig", false, extraction.ImportKinds.initEmpty());
    try graph.add(allocator, "b.zig", "b.zig", false, extraction.ImportKinds.initEmpty());
    try graph.add(allocator, "a.zig", "b.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "b.zig", "a.zig", false, extraction.ImportKinds.initOne(.zig_file));
    graph.sort();
    var entry = try projectFiles(allocator, .{});
    defer entry.deinit();
    var positive = try entry.should();
    defer positive.deinit();
    var terminal = try positive.haveNoCycles();
    defer terminal.deinit(allocator);
    var result = try terminal.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "have no cycles cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCycleRuleAllocationFailures,
        .{},
    );
}

test "positive and negated descriptions share one stable sentence renderer" {
    var entry = try projectFiles(std.testing.allocator, .{});
    defer entry.deinit();
    var folders = try entry.inFolder(&.{
        .{ .glob = "src/api" },
        .{ .glob = "src/domain" },
    });
    defer folders.deinit();
    var scope = try folders.withName(&.{.{ .glob = "order*.zig" }});
    defer scope.deinit();
    var positive = try scope.should();
    defer positive.deinit();
    var negated = try scope.shouldNot();
    defer negated.deinit();
    const positive_description = try positive.description(std.testing.allocator);
    defer std.testing.allocator.free(positive_description);
    const negated_description = try negated.description(std.testing.allocator);
    defer std.testing.allocator.free(negated_description);

    try std.testing.expectEqualStrings(
        "project files, in folder (\"src/api\" or \"src/domain\"), with name \"order*.zig\", should",
        positive_description,
    );
    try std.testing.expectEqualStrings(
        "project files, in folder (\"src/api\" or \"src/domain\"), with name \"order*.zig\", should not",
        negated_description,
    );
}

fn fixtureRoot(allocator: Allocator) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "test/fixtures/files-selection",
        allocator,
    );
}

fn graphFromFixture(allocator: Allocator, root: []const u8) !Graph {
    var diagnostics = common_error.ErrorContext.init(allocator);
    defer diagnostics.deinit();
    var source_files = try extraction.enumerateSourceFiles(
        allocator,
        std.testing.io,
        root,
        .{},
        &diagnostics,
    );
    defer source_files.deinit(allocator);
    const sources = try allocator.alloc(extraction.SourceReferences, source_files.items().len);
    defer allocator.free(sources);
    for (source_files.items(), sources) |path, *source| source.* = .{ .source_path = path };
    return extraction.normalizeGraph(allocator, sources);
}

test "full public scope syntax selects files from a real Zig fixture project" {
    const root = try fixtureRoot(std.testing.allocator);
    defer std.testing.allocator.free(root);
    var selected: SelectedFiles = undefined;
    {
        var graph = try graphFromFixture(std.testing.allocator, root);
        defer graph.deinit(std.testing.allocator);
        var all_files = try projectFiles(std.testing.allocator, .{ .locator = root });
        defer all_files.deinit();
        var domain_files = try all_files.inFolder(&.{.{ .glob = "src/domain" }});
        defer domain_files.deinit();
        var domain_sources = try domain_files.withName(&.{
            .{ .glob = "order.zig" },
            .{ .glob = "order_test.zig" },
        });
        defer domain_sources.deinit();
        try std.testing.expectEqualStrings(root, domain_sources.projectLocator().?);
        selected = try domain_sources.select(&graph);
    }
    defer selected.deinit();

    try std.testing.expectEqual(@as(usize, 2), selected.len());
    try std.testing.expectEqualStrings("src/domain/order.zig", selected.items()[0]);
    try std.testing.expectEqualStrings("src/domain/order_test.zig", selected.items()[1]);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph: Graph = .{};
    defer graph.deinit(allocator);
    for ([_][]const u8{
        "src/api/handler.zig",
        "src/domain/order.zig",
        "src/domain/order_test.zig",
    }) |path| {
        try graph.add(allocator, path, path, false, extraction.ImportKinds.initEmpty());
    }
    graph.sort();
    var entry = try projectFiles(allocator, .{ .locator = "fixture" });
    defer entry.deinit();
    var base = try entry.inFolder(&.{
        .{ .glob = "src/api" },
        .{ .glob = "src/domain" },
    });
    defer base.deinit();
    var branch = try base.withName(&.{.{ .glob = "order*.zig" }});
    defer branch.deinit();
    var production = try branch.except(&.{.{ .regex = "_test\\.zig$" }});
    defer production.deinit();
    var positive = try production.should();
    defer positive.deinit();
    var negated = try production.shouldNot();
    defer negated.deinit();
    var selected = try positive.select(&graph);
    defer selected.deinit();
    var evidence = try negated.scopePatterns(allocator);
    defer evidence.deinit(allocator);
    const description = try positive.description(allocator);
    defer allocator.free(description);
    try std.testing.expectEqual(@as(usize, 1), selected.len());
}

test "file scope construction branching and selection clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
