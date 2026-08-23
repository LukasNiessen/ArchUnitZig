const std = @import("std");

const identifier = @import("identifier.zig");
const import_kind = @import("import_kind.zig");

const Allocator = std.mem.Allocator;
pub const ImportKind = import_kind.ImportKind;
pub const ImportKinds = import_kind.ImportKinds;

/// One owned dependency in the extracted project graph.
pub const Edge = struct {
    source: []const u8,
    target: []const u8,
    external: bool,
    import_kinds: ImportKinds,

    pub fn init(
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        external: bool,
        import_kinds: ImportKinds,
    ) Allocator.Error!Edge {
        const owned_source = try identifier.normalize(allocator, source);
        errdefer allocator.free(owned_source);

        const owned_target = try identifier.normalize(allocator, target);

        return .{
            .source = owned_source,
            .target = owned_target,
            .external = external,
            .import_kinds = import_kinds,
        };
    }

    pub fn clone(self: Edge, allocator: Allocator) Allocator.Error!Edge {
        const owned_source = try allocator.dupe(u8, self.source);
        errdefer allocator.free(owned_source);

        const owned_target = try allocator.dupe(u8, self.target);

        return .{
            .source = owned_source,
            .target = owned_target,
            .external = self.external,
            .import_kinds = self.import_kinds,
        };
    }

    pub fn deinit(self: *Edge, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.target);
        self.* = undefined;
    }

    pub fn eql(self: Edge, other: Edge) bool {
        return std.mem.eql(u8, self.source, other.source) and
            std.mem.eql(u8, self.target, other.target) and
            self.external == other.external and
            self.import_kinds.eql(other.import_kinds);
    }
};

test "an edge owns normalised identifiers and import kinds" {
    var edge = try Edge.init(
        std.testing.allocator,
        "src\\api\\handler.zig",
        "src//domain/model.zig",
        false,
        ImportKinds.initMany(&.{ .zig_file, .root_module }),
    );
    defer edge.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/api/handler.zig", edge.source);
    try std.testing.expectEqualStrings("src/domain/model.zig", edge.target);
    try std.testing.expect(!edge.external);
    try std.testing.expect(edge.import_kinds.contains(.zig_file));
    try std.testing.expect(edge.import_kinds.contains(.root_module));
}

test "cloning an edge creates independent identifier storage" {
    var original = try Edge.init(
        std.testing.allocator,
        "src/source.zig",
        "std",
        true,
        ImportKinds.initOne(.standard_library),
    );
    defer original.deinit(std.testing.allocator);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.source.ptr != cloned.source.ptr);
    try std.testing.expect(original.target.ptr != cloned.target.ptr);
}
