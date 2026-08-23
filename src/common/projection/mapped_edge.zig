const std = @import("std");

const extraction = @import("../extraction.zig");

pub const Edge = extraction.Edge;
pub const ProjectionError = error{InvalidProjectionLabel};

/// Borrowed labels returned by a `MapFunction`. Projection clones them before the next mapper call.
pub const MappedEdge = struct {
    source_label: []const u8,
    target_label: []const u8,

    pub fn validate(self: MappedEdge) ProjectionError!void {
        if (self.source_label.len == 0 or self.target_label.len == 0) {
            return error.InvalidProjectionLabel;
        }
    }
};

/// Borrowed type-erased hook. Returning null drops an edge; returned labels live through the call.
pub const MapFunction = struct {
    context: ?*const anyopaque,
    map_fn: *const fn (context: ?*const anyopaque, edge: *const Edge) ?MappedEdge,

    pub fn init(
        context: ?*const anyopaque,
        map_fn: *const fn (context: ?*const anyopaque, edge: *const Edge) ?MappedEdge,
    ) MapFunction {
        return .{ .context = context, .map_fn = map_fn };
    }

    pub fn fromStateless(
        comptime map_fn: *const fn (edge: *const Edge) ?MappedEdge,
    ) MapFunction {
        return .{
            .context = null,
            .map_fn = struct {
                fn map(_: ?*const anyopaque, edge: *const Edge) ?MappedEdge {
                    return map_fn(edge);
                }
            }.map,
        };
    }

    pub fn fromContext(
        comptime Context: type,
        context: *const Context,
        comptime map_fn: *const fn (context: *const Context, edge: *const Edge) ?MappedEdge,
    ) MapFunction {
        return .{
            .context = context,
            .map_fn = struct {
                fn map(raw_context: ?*const anyopaque, edge: *const Edge) ?MappedEdge {
                    const typed_context: *const Context = @ptrCast(@alignCast(raw_context.?));
                    return map_fn(typed_context, edge);
                }
            }.map,
        };
    }

    pub fn map(self: MapFunction, edge: *const Edge) ?MappedEdge {
        return self.map_fn(self.context, edge);
    }
};

test "map functions can relabel or drop raw edges without ambient state" {
    const Mapper = struct {
        fn map(edge: *const Edge) ?MappedEdge {
            if (edge.external) return null;
            return .{ .source_label = "source-group", .target_label = "target-group" };
        }
    };
    const mapper = MapFunction.fromStateless(Mapper.map);
    var internal = try Edge.init(
        std.testing.allocator,
        "src/main.zig",
        "src/model.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer internal.deinit(std.testing.allocator);
    var external = try Edge.init(
        std.testing.allocator,
        "src/main.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    defer external.deinit(std.testing.allocator);

    const mapped = mapper.map(&internal).?;
    try mapped.validate();
    try std.testing.expectEqualStrings("source-group", mapped.source_label);
    try std.testing.expect(mapper.map(&external) == null);
}

test "empty mapped labels are rejected" {
    try std.testing.expectError(
        error.InvalidProjectionLabel,
        (MappedEdge{ .source_label = "", .target_label = "target" }).validate(),
    );
}

test "typed mapper contexts are borrowed safely" {
    const Context = struct {
        keep_external: bool,

        fn map(self: *const @This(), edge: *const Edge) ?MappedEdge {
            if (edge.external and !self.keep_external) return null;
            return .{ .source_label = edge.source, .target_label = edge.target };
        }
    };
    const context = Context{ .keep_external = false };
    const mapper = MapFunction.fromContext(Context, &context, Context.map);
    var external = try Edge.init(
        std.testing.allocator,
        "src/main.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    defer external.deinit(std.testing.allocator);
    try std.testing.expect(mapper.map(&external) == null);
}
