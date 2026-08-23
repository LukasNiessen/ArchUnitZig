const std = @import("std");

const extraction = @import("../extraction.zig");
const mapped_edge = @import("mapped_edge.zig");

pub const Edge = extraction.Edge;
pub const MapFunction = mapped_edge.MapFunction;
pub const MappedEdge = mapped_edge.MappedEdge;

/// Keeps every non-self dependency, regardless of externality.
pub fn perEdge() MapFunction {
    return MapFunction.fromStateless(mapNonSelf);
}

/// Keeps non-self dependencies whose extraction classification is internal.
pub fn perInternalEdge() MapFunction {
    return MapFunction.fromStateless(mapInternal);
}

/// Keeps non-self dependencies whose extraction classification is external.
pub fn perExternalEdge() MapFunction {
    return MapFunction.fromStateless(mapExternal);
}

/// Keeps raw identifiers exactly, including self-edges, for deliberate node-preserving views.
pub fn identity() MapFunction {
    return MapFunction.fromStateless(mapIdentity);
}

fn mapNonSelf(edge: *const Edge) ?MappedEdge {
    if (isSelfEdge(edge)) return null;
    return mapped(edge);
}

fn mapInternal(edge: *const Edge) ?MappedEdge {
    if (edge.external or isSelfEdge(edge)) return null;
    return mapped(edge);
}

fn mapExternal(edge: *const Edge) ?MappedEdge {
    if (!edge.external or isSelfEdge(edge)) return null;
    return mapped(edge);
}

fn mapIdentity(edge: *const Edge) ?MappedEdge {
    return mapped(edge);
}

fn mapped(edge: *const Edge) MappedEdge {
    return .{ .source_label = edge.source, .target_label = edge.target };
}

fn isSelfEdge(edge: *const Edge) bool {
    return std.mem.eql(u8, edge.source, edge.target);
}

fn makeEdge(
    source: []const u8,
    target: []const u8,
    external: bool,
    kind: extraction.ImportKind,
) !Edge {
    return Edge.init(
        std.testing.allocator,
        source,
        target,
        external,
        extraction.ImportKinds.initOne(kind),
    );
}

test "standard factories drop self edges while identity retains them" {
    var internal_self = try makeEdge(
        "src/main.zig",
        "src/main.zig",
        false,
        .zig_file,
    );
    defer internal_self.deinit(std.testing.allocator);
    var external_self = try makeEdge(
        "synthetic",
        "synthetic",
        true,
        .named_module,
    );
    defer external_self.deinit(std.testing.allocator);

    for ([_]MapFunction{ perEdge(), perInternalEdge(), perExternalEdge() }) |mapper| {
        try std.testing.expect(mapper.map(&internal_self) == null);
        try std.testing.expect(mapper.map(&external_self) == null);
    }
    try std.testing.expect(identity().map(&internal_self) != null);
    try std.testing.expect(identity().map(&external_self) != null);
}

test "Zig import kinds preserve the shared internal external meaning" {
    const Case = struct {
        target: []const u8,
        external: bool,
        kind: extraction.ImportKind,
    };
    const cases = [_]Case{
        .{ .target = "src/model.zig", .external = false, .kind = .zig_file },
        .{ .target = "src/root.zig", .external = false, .kind = .root_module },
        .{ .target = "root", .external = true, .kind = .root_module },
        .{ .target = "assets/schema.json", .external = false, .kind = .embedded_file },
        .{ .target = "missing/schema.json", .external = true, .kind = .embedded_file },
        .{ .target = "unresolved_package", .external = true, .kind = .named_module },
        .{ .target = "std", .external = true, .kind = .standard_library },
        .{ .target = "builtin", .external = true, .kind = .builtin_module },
        .{ .target = "sqlite3.h", .external = true, .kind = .c_header },
    };

    for (cases) |case| {
        var edge = try makeEdge("src/main.zig", case.target, case.external, case.kind);
        defer edge.deinit(std.testing.allocator);
        try std.testing.expect(perEdge().map(&edge) != null);
        try std.testing.expectEqual(!case.external, perInternalEdge().map(&edge) != null);
        try std.testing.expectEqual(case.external, perExternalEdge().map(&edge) != null);
    }
}

test "factories have no ambient state and borrow normalized raw identifiers" {
    for ([_]MapFunction{ perEdge(), perInternalEdge(), perExternalEdge(), identity() }) |mapper| {
        try std.testing.expect(mapper.context == null);
    }

    const internal = perInternalEdge();
    var edge = try makeEdge(
        "src\\api\\handler.zig",
        "src\\domain\\model.zig",
        false,
        .zig_file,
    );
    defer edge.deinit(std.testing.allocator);
    const result = internal.map(&edge).?;
    try std.testing.expectEqualStrings("src/api/handler.zig", result.source_label);
    try std.testing.expectEqualStrings("src/domain/model.zig", result.target_label);
    try std.testing.expect(result.source_label.ptr == edge.source.ptr);
    try std.testing.expect(result.target_label.ptr == edge.target.ptr);
}

test "factories compose with deterministic edge projection" {
    const projection = @import("project_edges.zig");
    var graph: extraction.Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "src/main.zig",
        false,
        extraction.ImportKinds.initEmpty(),
    );
    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "src/model.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );

    var all_dependencies = try projection.projectEdges(std.testing.allocator, &graph, perEdge());
    defer all_dependencies.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), all_dependencies.len());

    var internal_dependencies = try projection.projectEdges(std.testing.allocator, &graph, perInternalEdge());
    defer internal_dependencies.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), internal_dependencies.len());
    try std.testing.expectEqualStrings("src/model.zig", internal_dependencies.items()[0].target_label);

    var external_dependencies = try projection.projectEdges(std.testing.allocator, &graph, perExternalEdge());
    defer external_dependencies.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), external_dependencies.len());
    try std.testing.expectEqualStrings("std", external_dependencies.items()[0].target_label);

    var full_identity = try projection.projectEdges(std.testing.allocator, &graph, identity());
    defer full_identity.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), full_identity.len());
}
