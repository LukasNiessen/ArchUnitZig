const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const file_cycles = @import("../projection/file_cycles.zig");

const Allocator = std.mem.Allocator;
pub const Filter = matching.Filter;
pub const Graph = extraction.Graph;
pub const Mood = assertion.Mood;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const ScopePattern = assertion.ScopePattern;
pub const CheckOptions = fluentapi.CheckOptions;

pub const BuilderError = Allocator.Error || error{
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
        var filter = Filter.init(allocator, pattern, target, .partial) catch |failure| {
            return mapPatternFailure(failure);
        };
        errdefer filter.deinit();
        return .{
            .evidence = try ScopePattern.init(
                allocator,
                selector_index,
                pattern,
                target,
                .partial,
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
            .literal => initLiteral(
                allocator,
                self.evidence.selector_index,
                self.evidence.expression,
            ),
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
        return result;
    }

    fn deinit(self: *Selector, allocator: Allocator) void {
        for (self.alternatives.items) |*alternative| alternative.deinit(allocator);
        self.alternatives.deinit(allocator);
        self.* = undefined;
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
        for (self.selectors.items) |selector| pattern_count += selector.alternatives.items.len;
        try result.values.ensureTotalCapacity(allocator, pattern_count);
        for (self.selectors.items) |selector| {
            for (selector.alternatives.items) |alternative| {
                result.values.appendAssumeCapacity(try alternative.evidence.clone(allocator));
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

    fn writeDescription(self: *const FilesScope, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("project files");
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
        return std.fmt.allocPrint(allocator, "{s}, have no cycles", .{prefix});
    }

    pub fn check(self: *const FilesHaveNoCycles, options: CheckOptions) anyerror!assertion.ViolationList {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var graph = try extraction.extractProjectGraph(
            options.allocator,
            options.io,
            self.rule.scope.projectLocator(),
            options.working_directory,
            options.extraction,
            options.clear_cache,
            &diagnostics,
        );
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
        if (selected.len() == 0) {
            if (options.allow_empty_tests) return .{};
            return self.emptySelection(options.allocator);
        }

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

    fn emptySelection(
        self: *const FilesHaveNoCycles,
        allocator: Allocator,
    ) anyerror!assertion.ViolationList {
        var scope = try self.rule.scopePatterns(allocator);
        defer scope.deinit(allocator);
        var payload = try assertion.EmptyTestViolation.init(
            allocator,
            "files.have_no_cycles",
            scope.items(),
            false,
        );
        var violation = assertion.Violation.fromEmptyTestMove(&payload);
        var result = assertion.ViolationList{};
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
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

fn selectorPhrase(pattern: ScopePattern) []const u8 {
    return switch (pattern.target) {
        .filename => "with name",
        .path_without_filename => "in folder",
        .path => if (pattern.syntax == .literal) "in file" else "in path",
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
    const first_path = try formatCyclePath(std.testing.allocator, failing.items()[0].cycle.cycle);
    defer std.testing.allocator.free(first_path);
    try std.testing.expectEqualStrings("src/a.zig -> src/b.zig -> src/a.zig", first_path);
    const first_import = failing.items()[0].cycle.cycle.items()[0].evidence()[0];
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
    var positive = try branch.should();
    defer positive.deinit();
    var negated = try branch.shouldNot();
    defer negated.deinit();
    var selected = try positive.select(&graph);
    defer selected.deinit();
    var evidence = try negated.scopePatterns(allocator);
    defer evidence.deinit(allocator);
    const description = try positive.description(allocator);
    defer allocator.free(description);
    try std.testing.expectEqual(@as(usize, 2), selected.len());
}

test "file scope construction branching and selection clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
