const std = @import("std");

const classifier = @import("classifier.zig");
const graph_module = @import("graph.zig");
const import_kind = @import("import_kind.zig");

const Allocator = std.mem.Allocator;
pub const ClassifiedReference = classifier.ClassifiedReference;
pub const Graph = graph_module.Graph;
pub const ImportKind = import_kind.ImportKind;
pub const ImportKinds = import_kind.ImportKinds;
pub const SourceLocation = classifier.SourceLocation;

/// Borrowed classified references for one enumerated project source.
pub const SourceReferences = struct {
    source_path: []const u8,
    references: []const ClassifiedReference = &.{},
};

/// Builds a deterministically ordered graph with one self-edge for every `.zig` source.
pub fn normalizeGraph(
    allocator: Allocator,
    sources: []const SourceReferences,
) graph_module.AddError!Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);

    for (sources) |source| {
        if (std.mem.endsWith(u8, source.source_path, ".zig")) {
            try graph.add(
                allocator,
                source.source_path,
                source.source_path,
                false,
                ImportKinds.initEmpty(),
            );
        }
        for (source.references) |reference| {
            try graph.addClassifiedLocated(
                allocator,
                source.source_path,
                reference.target,
                reference.external,
                ImportKinds.initOne(reference.kind),
                reference.class,
                reference.availability,
                &.{reference.location},
            );
        }
    }
    graph.sort();
    return graph;
}

fn makeClassified(
    target: []const u8,
    kind: ImportKind,
    external: bool,
    location: SourceLocation,
) ClassifiedReference {
    return .{
        .raw_target = target,
        .target = target,
        .mapped_source_path = null,
        .kind = kind,
        .location = location,
        .class = if (external) .external else .internal,
        .availability = .resolved,
        .external = external,
    };
}

test "import-free Zig files receive self-edges while ZON entries do not" {
    const sources = [_]SourceReferences{
        .{ .source_path = "src/empty.zig" },
        .{ .source_path = "src/main.zig" },
        .{ .source_path = "config/settings.zon" },
    };
    var graph = try normalizeGraph(std.testing.allocator, &sources);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), graph.len());
    try std.testing.expect(graph.find("src/empty.zig", "src/empty.zig") != null);
    try std.testing.expect(graph.find("src/main.zig", "src/main.zig") != null);
}

test "parallel edges union kinds and retain sorted unique locations" {
    const first = SourceLocation{ .byte_offset = 30, .line = 3, .column = 5 };
    const second = SourceLocation{ .byte_offset = 10, .line = 2, .column = 5 };
    const references = [_]ClassifiedReference{
        makeClassified("src/model.zig", .zig_file, false, first),
        makeClassified("src/model.zig", .root_module, false, second),
        makeClassified("src/model.zig", .zig_file, false, first),
    };
    const sources = [_]SourceReferences{.{ .source_path = "src/main.zig", .references = &references }};
    var graph = try normalizeGraph(std.testing.allocator, &sources);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), graph.len());
    const dependency = graph.find("src/main.zig", "src/model.zig") orelse return error.TestExpectedEqual;
    try std.testing.expect(dependency.import_kinds.contains(.zig_file));
    try std.testing.expect(dependency.import_kinds.contains(.root_module));
    try std.testing.expectEqual(@as(usize, 2), dependency.locationItems().len);
    try std.testing.expectEqual(@as(u32, 10), dependency.locationItems()[0].byte_offset);
    try std.testing.expectEqual(@as(u32, 30), dependency.locationItems()[1].byte_offset);
}

test "graph ordering is independent of source and reference order" {
    const early = SourceLocation{ .byte_offset = 5, .line = 1, .column = 6 };
    const late = SourceLocation{ .byte_offset = 25, .line = 2, .column = 6 };
    const a_references = [_]ClassifiedReference{
        makeClassified("std", .standard_library, true, late),
        makeClassified("src/shared.zig", .zig_file, false, early),
    };
    const a_reversed = [_]ClassifiedReference{
        makeClassified("src/shared.zig", .zig_file, false, early),
        makeClassified("std", .standard_library, true, late),
    };
    const first_sources = [_]SourceReferences{
        .{ .source_path = "src/z.zig" },
        .{ .source_path = "src/a.zig", .references = &a_references },
    };
    const second_sources = [_]SourceReferences{
        .{ .source_path = "src/a.zig", .references = &a_reversed },
        .{ .source_path = "src/z.zig" },
    };
    var first_graph = try normalizeGraph(std.testing.allocator, &first_sources);
    defer first_graph.deinit(std.testing.allocator);
    var second_graph = try normalizeGraph(std.testing.allocator, &second_sources);
    defer second_graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(first_graph.len(), second_graph.len());
    for (first_graph.items(), second_graph.items()) |first_edge, second_edge| {
        try std.testing.expect(first_edge.eql(second_edge));
    }
}

test "equal external names from different sources remain separate edges" {
    const location = SourceLocation{ .byte_offset = 5, .line = 1, .column = 6 };
    const a_refs = [_]ClassifiedReference{makeClassified("dependency", .named_module, true, location)};
    const b_refs = [_]ClassifiedReference{makeClassified("dependency", .named_module, true, location)};
    const sources = [_]SourceReferences{
        .{ .source_path = "src/a.zig", .references = &a_refs },
        .{ .source_path = "src/b.zig", .references = &b_refs },
    };
    var graph = try normalizeGraph(std.testing.allocator, &sources);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), graph.len());
    try std.testing.expect(graph.find("src/a.zig", "dependency") != null);
    try std.testing.expect(graph.find("src/b.zig", "dependency") != null);
}

test "normalization owns borrowed source and target buffers" {
    var source_path = [_]u8{ 's', 'r', 'c', '/', 'm', 'a', 'i', 'n', '.', 'z', 'i', 'g' };
    var target = [_]u8{ 'd', 'e', 'p', 'e', 'n', 'd', 'e', 'n', 'c', 'y' };
    const location = SourceLocation{ .byte_offset = 5, .line = 1, .column = 6 };
    const references = [_]ClassifiedReference{makeClassified(&target, .named_module, true, location)};
    const sources = [_]SourceReferences{.{ .source_path = &source_path, .references = &references }};
    var graph = try normalizeGraph(std.testing.allocator, &sources);
    defer graph.deinit(std.testing.allocator);
    source_path[0] = 'X';
    target[0] = 'Y';
    try std.testing.expect(graph.find("src/main.zig", "src/main.zig") != null);
    try std.testing.expect(graph.find("src/main.zig", "dependency") != null);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    const location = SourceLocation{ .byte_offset = 8, .line = 1, .column = 9 };
    const references = [_]ClassifiedReference{
        makeClassified("src/model.zig", .zig_file, false, location),
        makeClassified("std", .standard_library, true, location),
        makeClassified("src/model.zig", .root_module, false, location),
    };
    const sources = [_]SourceReferences{
        .{ .source_path = "src/main.zig", .references = &references },
        .{ .source_path = "src/empty.zig" },
    };
    var graph = try normalizeGraph(allocator, &sources);
    defer graph.deinit(allocator);
}

test "graph normalization cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
