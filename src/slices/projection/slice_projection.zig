const std = @import("std");

const common_path = @import("../../common/path.zig");
const extraction = @import("../../common/extraction.zig");
const mapped_edge = @import("../../common/projection/mapped_edge.zig");
const matching = @import("../../common/matching.zig");
const projected_edge = @import("../../common/projection/projected_edge.zig");
const regex_module = @import("../../common/matching/regex.zig");

const Allocator = std.mem.Allocator;
pub const Edge = extraction.Edge;
pub const Graph = extraction.Graph;
pub const MappedEdge = mapped_edge.MappedEdge;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const ProjectedEdges = projected_edge.ProjectedEdges;
pub const Regex = regex_module.Regex;
pub const Filter = matching.Filter;

pub const InitError = Allocator.Error || Regex.CompileError || error{
    MissingSliceCapture,
    MultipleSliceCaptures,
    MissingRegexCapture,
    EmptySliceSuffix,
    EmptySliceLabel,
    DuplicateSliceSuffix,
    CharacterClassContainsSeparator,
};
pub const LabelError = Allocator.Error || Regex.MatchError;
pub const ProjectionError = InitError || LabelError || mapped_edge.ProjectionError;

/// One borrowed suffix-to-label definition. Suffixes match the file stem, not directories or the
/// final `.zig` extension. Longest suffix wins; declaration order breaks equal-length ties.
pub const SliceSuffix = struct {
    suffix: []const u8,
    label: []const u8,
};

const OwnedSuffix = struct {
    suffix: []u8,
    label: []u8,
    declaration_index: usize,

    fn clone(self: OwnedSuffix, allocator: Allocator) Allocator.Error!OwnedSuffix {
        const suffix = try allocator.dupe(u8, self.suffix);
        errdefer allocator.free(suffix);
        return .{
            .suffix = suffix,
            .label = try allocator.dupe(u8, self.label),
            .declaration_index = self.declaration_index,
        };
    }

    fn deinit(self: *OwnedSuffix, allocator: Allocator) void {
        allocator.free(self.suffix);
        allocator.free(self.label);
        self.* = undefined;
    }
};

const CaptureProjection = struct {
    source: []u8,
    regex: Regex,

    fn deinit(self: *CaptureProjection, allocator: Allocator) void {
        allocator.free(self.source);
        self.regex.deinit();
        self.* = undefined;
    }
};

const SuffixProjection = struct {
    definitions: std.ArrayList(OwnedSuffix) = .empty,

    fn init(allocator: Allocator, definitions: []const SliceSuffix) InitError!SuffixProjection {
        var result: SuffixProjection = .{};
        errdefer result.deinit(allocator);
        try result.definitions.ensureTotalCapacity(allocator, definitions.len);
        for (definitions, 0..) |definition, index| {
            if (!containsNonWhitespace(definition.suffix)) return error.EmptySliceSuffix;
            if (!containsNonWhitespace(definition.label)) return error.EmptySliceLabel;
            for (definitions[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.suffix, definition.suffix)) {
                    return error.DuplicateSliceSuffix;
                }
            }
            const suffix = try allocator.dupe(u8, definition.suffix);
            const owned_label = allocator.dupe(u8, definition.label) catch |failure| {
                allocator.free(suffix);
                return failure;
            };
            result.definitions.appendAssumeCapacity(.{
                .suffix = suffix,
                .label = owned_label,
                .declaration_index = index,
            });
        }
        std.mem.sort(OwnedSuffix, result.definitions.items, {}, suffixBefore);
        return result;
    }

    fn clone(self: *const SuffixProjection, allocator: Allocator) Allocator.Error!SuffixProjection {
        var result: SuffixProjection = .{};
        errdefer result.deinit(allocator);
        try result.definitions.ensureTotalCapacity(allocator, self.definitions.items.len);
        for (self.definitions.items) |definition| {
            result.definitions.appendAssumeCapacity(try definition.clone(allocator));
        }
        return result;
    }

    fn deinit(self: *SuffixProjection, allocator: Allocator) void {
        for (self.definitions.items) |*definition| definition.deinit(allocator);
        self.definitions.deinit(allocator);
        self.* = undefined;
    }

    fn label(self: *const SuffixProjection, path: []const u8) ?[]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse std.math.maxInt(usize);
        const file_name = if (slash == std.math.maxInt(usize)) path else path[slash + 1 ..];
        const dot = std.mem.lastIndexOfScalar(u8, file_name, '.');
        const stem = if (dot) |index| file_name[0..index] else file_name;
        for (self.definitions.items) |definition| {
            if (std.mem.endsWith(u8, stem, definition.suffix)) return definition.label;
        }
        return null;
    }
};

fn suffixBefore(_: void, left: OwnedSuffix, right: OwnedSuffix) bool {
    if (left.suffix.len != right.suffix.len) return left.suffix.len > right.suffix.len;
    return left.declaration_index < right.declaration_index;
}

/// Owned pure path-to-slice projection. Values can be cloned into independent builder branches.
pub const SliceProjection = union(enum) {
    identity: void,
    pattern: CaptureProjection,
    regex: CaptureProjection,
    suffix: SuffixProjection,

    pub fn initIdentity() SliceProjection {
        return .{ .identity = {} };
    }

    /// Compiles a glob-like prefix containing exactly one literal `(**)` segment capture.
    pub fn initPattern(allocator: Allocator, pattern: []const u8) InitError!SliceProjection {
        const owned_source = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_source);
        return .{ .pattern = .{
            .source = owned_source,
            .regex = try compileCapturePattern(allocator, pattern),
        } };
    }

    /// Compiles an explicit partial regex and selects capture group 1 as the slice label.
    pub fn initRegex(allocator: Allocator, expression: []const u8) InitError!SliceProjection {
        const owned_source = try allocator.dupe(u8, expression);
        errdefer allocator.free(owned_source);
        var regex = try Regex.compile(allocator, expression);
        errdefer regex.deinit();
        if (regex.captureCount() == 0) return error.MissingRegexCapture;
        return .{ .regex = .{ .source = owned_source, .regex = regex } };
    }

    pub fn initFileSuffixes(
        allocator: Allocator,
        definitions: []const SliceSuffix,
    ) InitError!SliceProjection {
        return .{ .suffix = try SuffixProjection.init(allocator, definitions) };
    }

    pub fn clone(self: *const SliceProjection, allocator: Allocator) InitError!SliceProjection {
        return switch (self.*) {
            .identity => initIdentity(),
            .pattern => |value| initPattern(allocator, value.source),
            .regex => |value| initRegex(allocator, value.source),
            .suffix => |value| .{ .suffix = try value.clone(allocator) },
        };
    }

    pub fn deinit(self: *SliceProjection, allocator: Allocator) void {
        switch (self.*) {
            .identity => {},
            .pattern => |*value| value.deinit(allocator),
            .regex => |*value| value.deinit(allocator),
            .suffix => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    /// Returns an owned label, or null when this projection treats the path as an orphan.
    pub fn labelFor(
        self: *const SliceProjection,
        allocator: Allocator,
        path: []const u8,
    ) LabelError!?[]u8 {
        const normalized = try common_path.normalize(allocator, path);
        defer allocator.free(normalized);
        return switch (self.*) {
            .identity => try allocator.dupe(u8, normalized),
            .pattern => |*value| try captureLabel(allocator, &value.regex, normalized),
            .regex => |*value| try captureLabel(allocator, &value.regex, normalized),
            .suffix => |*value| if (value.label(normalized)) |label|
                try allocator.dupe(u8, label)
            else
                null,
        };
    }
};

fn captureLabel(allocator: Allocator, regex: *const Regex, path: []const u8) LabelError!?[]u8 {
    const captures = (try regex.captures(allocator, path)) orelse return null;
    defer captures.deinit(allocator);
    if (captures.values.len < 2) return null;
    const capture = captures.values[1] orelse return null;
    if (capture.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, capture));
}

const OwnedMapping = struct {
    source_label: []u8,
    target_label: []u8,

    fn deinit(self: *OwnedMapping, allocator: Allocator) void {
        allocator.free(self.source_label);
        allocator.free(self.target_label);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedMapping) MappedEdge {
        return .{ .source_label = self.source_label, .target_label = self.target_label };
    }
};

fn mapEdge(
    allocator: Allocator,
    projection: *const SliceProjection,
    edge: *const Edge,
    path_filter: ?*const Filter,
) ProjectionError!?OwnedMapping {
    if (!try pathIncluded(allocator, path_filter, edge.source)) return null;
    if (!edge.external and !try pathIncluded(allocator, path_filter, edge.target)) return null;
    const source_label = (try projection.labelFor(allocator, edge.source)) orelse return null;
    errdefer allocator.free(source_label);
    const target_label = if (edge.external)
        try allocator.dupe(u8, edge.target)
    else
        (try projection.labelFor(allocator, edge.target)) orelse {
            allocator.free(source_label);
            return null;
        };

    if (!edge.external and std.mem.eql(u8, source_label, target_label)) {
        allocator.free(source_label);
        allocator.free(target_label);
        return null;
    }
    return .{ .source_label = source_label, .target_label = target_label };
}

/// Applies one slice projection and aggregates concrete raw evidence by slice dependency.
pub fn projectSliceEdges(
    allocator: Allocator,
    graph: *const Graph,
    slice_projection: *const SliceProjection,
) ProjectionError!ProjectedEdges {
    return projectSliceEdgesFiltered(allocator, graph, slice_projection, null);
}

/// Applies one slice projection after filtering internal source and target paths. External targets
/// remain graph identifiers; only their internal source path is filtered.
pub fn projectSliceEdgesFiltered(
    allocator: Allocator,
    graph: *const Graph,
    slice_projection: *const SliceProjection,
    path_filter: ?*const Filter,
) ProjectionError!ProjectedEdges {
    var result: ProjectedEdges = .{};
    errdefer result.deinit(allocator);
    for (graph.items()) |*raw_edge| {
        var mapped = (try mapEdge(allocator, slice_projection, raw_edge, path_filter)) orelse continue;
        defer mapped.deinit(allocator);
        const borrowed = mapped.borrowed();
        try borrowed.validate();
        if (result.findMutable(borrowed.source_label, borrowed.target_label)) |existing| {
            try existing.appendEvidence(allocator, raw_edge.*);
            continue;
        }
        var projected = try ProjectedEdge.init(allocator, borrowed, raw_edge.*);
        result.appendMove(allocator, &projected) catch |failure| {
            projected.deinit(allocator);
            return failure;
        };
    }
    result.sort();
    return result;
}

/// Owned deterministic set of labels selected by a slice projection.
pub const SliceLabels = struct {
    values: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *SliceLabels, allocator: Allocator) void {
        for (self.values.items) |value| allocator.free(value);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const SliceLabels) []const []const u8 {
        return self.values.items;
    }

    pub fn len(self: *const SliceLabels) usize {
        return self.values.items.len;
    }

    pub fn contains(self: *const SliceLabels, label: []const u8) bool {
        for (self.values.items) |candidate| {
            if (std.mem.eql(u8, candidate, label)) return true;
        }
        return false;
    }

    fn appendOwnedUnique(
        self: *SliceLabels,
        allocator: Allocator,
        label: ?[]u8,
    ) Allocator.Error!void {
        const owned = label orelse return;
        for (self.values.items) |candidate| {
            if (std.mem.eql(u8, candidate, owned)) {
                allocator.free(owned);
                return;
            }
        }
        errdefer allocator.free(owned);
        try self.values.append(allocator, owned);
    }

    fn sort(self: *SliceLabels) void {
        std.mem.sort([]u8, self.values.items, {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
    }
};

/// Projects every internal graph endpoint. Self edges make isolated matched files visible.
pub fn projectSliceLabels(
    allocator: Allocator,
    graph: *const Graph,
    slice_projection: *const SliceProjection,
) LabelError!SliceLabels {
    return projectSliceLabelsFiltered(allocator, graph, slice_projection, null);
}

pub fn projectSliceLabelsFiltered(
    allocator: Allocator,
    graph: *const Graph,
    slice_projection: *const SliceProjection,
    path_filter: ?*const Filter,
) LabelError!SliceLabels {
    var result: SliceLabels = .{};
    errdefer result.deinit(allocator);
    for (graph.items()) |edge| {
        if (try pathIncluded(allocator, path_filter, edge.source)) {
            try result.appendOwnedUnique(allocator, try slice_projection.labelFor(allocator, edge.source));
        }
        if (!edge.external and try pathIncluded(allocator, path_filter, edge.target)) {
            try result.appendOwnedUnique(allocator, try slice_projection.labelFor(allocator, edge.target));
        }
    }
    result.sort();
    return result;
}

fn pathIncluded(
    allocator: Allocator,
    path_filter: ?*const Filter,
    path: []const u8,
) LabelError!bool {
    const filter = path_filter orelse return true;
    return filter.matches(allocator, .{ .path = path }) catch |failure| switch (failure) {
        error.MissingDeclarationName => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn compileCapturePattern(allocator: Allocator, pattern: []const u8) InitError!Regex {
    const marker = "(**)";
    const capture_index = std.mem.indexOf(u8, pattern, marker) orelse
        return error.MissingSliceCapture;
    if (std.mem.indexOf(u8, pattern[capture_index + marker.len ..], marker) != null) {
        return error.MultipleSliceCaptures;
    }

    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(allocator);
    try expression.append(allocator, '^');
    var index: usize = 0;
    while (index < pattern.len) {
        if (index == capture_index) {
            try expression.appendSlice(allocator, "([^/]+)");
            index += marker.len;
            continue;
        }
        switch (pattern[index]) {
            '*' => try appendStar(allocator, &expression, pattern, &index),
            '?' => {
                try expression.appendSlice(allocator, "[^/]");
                index += 1;
            },
            '[' => try appendCharacterClass(allocator, &expression, pattern, &index),
            '\\' => {
                try expression.append(allocator, '/');
                index += 1;
            },
            else => {
                try appendEscapedLiteralByte(allocator, &expression, pattern[index]);
                index += 1;
            },
        }
    }
    try expression.appendSlice(allocator, ".*$");
    return Regex.compile(allocator, expression.items);
}

fn appendStar(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    glob: []const u8,
    index: *usize,
) Allocator.Error!void {
    if (index.* + 1 >= glob.len or glob[index.* + 1] != '*') {
        try expression.appendSlice(allocator, "[^/]*");
        index.* += 1;
        return;
    }
    index.* += 2;
    while (index.* < glob.len and glob[index.*] == '*') index.* += 1;
    if (index.* < glob.len and isSeparator(glob[index.*])) {
        try expression.appendSlice(allocator, "(?:.*/)?");
        index.* += 1;
    } else {
        try expression.appendSlice(allocator, ".*");
    }
}

fn appendCharacterClass(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    glob: []const u8,
    index: *usize,
) InitError!void {
    const closing = std.mem.indexOfScalar(u8, glob[index.* + 1 ..], ']') orelse {
        try expression.appendSlice(allocator, "\\[");
        index.* += 1;
        return;
    };
    const closing_index = index.* + 1 + closing;
    const content = glob[index.* + 1 .. closing_index];
    const only_negation = content.len == 1 and content[0] == '!';
    if (content.len == 0 or only_negation) {
        try expression.appendSlice(allocator, "\\[");
        index.* += 1;
        return;
    }
    if (classCanContainSeparator(content)) return error.CharacterClassContainsSeparator;
    const negated = content[0] == '!';
    try expression.append(allocator, '[');
    if (negated) try expression.appendSlice(allocator, "^/");
    for (content[@intFromBool(negated)..]) |byte| {
        if (byte == '[' or byte == ']' or byte == '^' or byte == '\\') {
            try expression.append(allocator, '\\');
        }
        try expression.append(allocator, byte);
    }
    try expression.append(allocator, ']');
    index.* = closing_index + 1;
}

fn classCanContainSeparator(content: []const u8) bool {
    const start: usize = @intFromBool(content[0] == '!');
    const values = content[start..];
    for (values, 0..) |byte, index| {
        if (isSeparator(byte)) return true;
        if (byte != '-' or index == 0 or index + 1 == values.len) continue;
        if (values[index - 1] <= '/' and '/' <= values[index + 1]) return true;
    }
    return false;
}

fn appendEscapedLiteralByte(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    byte: u8,
) Allocator.Error!void {
    if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$", byte) != null) {
        try expression.append(allocator, '\\');
    }
    try expression.append(allocator, byte);
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn makeGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try graph.add(allocator, "src/features/api/a.zig", "src/features/services/b.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/features/api/c.zig", "src/features/services/d.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/features/api/a.zig", "src/features/api/helper.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/features/api/a.zig", "std", true, extraction.ImportKinds.initOne(.standard_library));
    try graph.add(allocator, "src/features/orphan/alone.zig", "src/features/orphan/alone.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/bootstrap.zig", "src/features/api/a.zig", false, extraction.ImportKinds.initOne(.zig_file));
    return graph;
}

test "capture patterns validate one segment and normalize Windows paths" {
    try std.testing.expectError(error.MissingSliceCapture, SliceProjection.initPattern(std.testing.allocator, "src/**"));
    try std.testing.expectError(error.MultipleSliceCaptures, SliceProjection.initPattern(std.testing.allocator, "(**)/(**)"));

    var projection = try SliceProjection.initPattern(std.testing.allocator, "src\\features\\(**)\\");
    defer projection.deinit(std.testing.allocator);
    const label = (try projection.labelFor(std.testing.allocator, "src\\features\\api\\handler.zig")).?;
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("api", label);
    try std.testing.expect((try projection.labelFor(std.testing.allocator, "src/bootstrap.zig")) == null);
}

test "explicit regex uses capture one and rejects expressions without captures" {
    try std.testing.expectError(error.MissingRegexCapture, SliceProjection.initRegex(std.testing.allocator, "src/.+"));
    var projection = try SliceProjection.initRegex(std.testing.allocator, "features/([^/]+)/");
    defer projection.deinit(std.testing.allocator);
    const label = (try projection.labelFor(std.testing.allocator, "prefix/features/orders/root.zig")).?;
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("orders", label);
}

test "file suffix projection chooses longest suffix and validates definitions" {
    try std.testing.expectError(error.EmptySliceSuffix, SliceProjection.initFileSuffixes(std.testing.allocator, &.{.{ .suffix = "", .label = "empty" }}));
    try std.testing.expectError(error.DuplicateSliceSuffix, SliceProjection.initFileSuffixes(std.testing.allocator, &.{
        .{ .suffix = "_repo", .label = "one" },
        .{ .suffix = "_repo", .label = "two" },
    }));
    var projection = try SliceProjection.initFileSuffixes(std.testing.allocator, &.{
        .{ .suffix = "repo", .label = "repositories" },
        .{ .suffix = "order_repo", .label = "orders" },
    });
    defer projection.deinit(std.testing.allocator);
    const longest = (try projection.labelFor(std.testing.allocator, "src/sales_order_repo.zig")).?;
    defer std.testing.allocator.free(longest);
    try std.testing.expectEqualStrings("orders", longest);
    try std.testing.expect((try projection.labelFor(std.testing.allocator, "src/service.zig")) == null);
}

test "slice projection aggregates duplicates drops orphans and intra-slice edges and retains external edges" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var projection = try SliceProjection.initPattern(std.testing.allocator, "src/features/(**)/");
    defer projection.deinit(std.testing.allocator);
    var labels = try projectSliceLabels(std.testing.allocator, &graph, &projection);
    defer labels.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), labels.len());
    try std.testing.expectEqualStrings("api", labels.items()[0]);
    try std.testing.expectEqualStrings("orphan", labels.items()[1]);
    try std.testing.expectEqualStrings("services", labels.items()[2]);

    var edges = try projectSliceEdges(std.testing.allocator, &graph, &projection);
    defer edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), edges.len());
    const internal = edges.find("api", "services").?;
    try std.testing.expectEqual(@as(usize, 2), internal.evidence().len);
    const external = edges.find("api", "std").?;
    try std.testing.expect(external.evidence()[0].external);
    try std.testing.expect(edges.find("api", "api") == null);
}

test "external identifiers equal to slice labels remain concrete external dependencies" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try graph.add(std.testing.allocator, "src/features/api/root.zig", "api", true, extraction.ImportKinds.initOne(.named_module));
    var projection = try SliceProjection.initPattern(std.testing.allocator, "src/features/(**)/");
    defer projection.deinit(std.testing.allocator);
    var edges = try projectSliceEdges(std.testing.allocator, &graph, &projection);
    defer edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), edges.len());
    try std.testing.expect(edges.find("api", "api").?.evidence()[0].external);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try makeGraph(allocator);
    defer graph.deinit(allocator);
    var projection = try SliceProjection.initPattern(allocator, "src/features/(**)/");
    defer projection.deinit(allocator);
    var clone = try projection.clone(allocator);
    defer clone.deinit(allocator);
    var labels = try projectSliceLabels(allocator, &graph, &clone);
    defer labels.deinit(allocator);
    var edges = try projectSliceEdges(allocator, &graph, &clone);
    defer edges.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), labels.len());
    try std.testing.expectEqual(@as(usize, 2), edges.len());
}

test "slice projection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
