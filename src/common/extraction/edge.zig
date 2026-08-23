const std = @import("std");

const identifier = @import("identifier.zig");
const import_kind = @import("import_kind.zig");
const source_location = @import("source_location.zig");

const Allocator = std.mem.Allocator;
pub const ImportKind = import_kind.ImportKind;
pub const ImportKinds = import_kind.ImportKinds;
pub const SourceLocation = source_location.SourceLocation;

/// One owned dependency in the extracted project graph.
pub const Edge = struct {
    source: []const u8,
    target: []const u8,
    external: bool,
    import_kinds: ImportKinds,
    locations: std.ArrayList(SourceLocation) = .empty,

    pub fn init(
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        external: bool,
        import_kinds: ImportKinds,
    ) Allocator.Error!Edge {
        return initWithLocations(allocator, source, target, external, import_kinds, &.{});
    }

    pub fn initWithLocations(
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        external: bool,
        import_kinds: ImportKinds,
        locations: []const SourceLocation,
    ) Allocator.Error!Edge {
        const owned_source = try identifier.normalize(allocator, source);
        errdefer allocator.free(owned_source);

        const owned_target = try identifier.normalize(allocator, target);
        errdefer allocator.free(owned_target);
        var owned_locations: std.ArrayList(SourceLocation) = .empty;
        errdefer owned_locations.deinit(allocator);
        try owned_locations.appendSlice(allocator, locations);

        var edge = Edge{
            .source = owned_source,
            .target = owned_target,
            .external = external,
            .import_kinds = import_kinds,
            .locations = owned_locations,
        };
        edge.sortAndDeduplicateLocations();
        return edge;
    }

    pub fn clone(self: Edge, allocator: Allocator) Allocator.Error!Edge {
        return initWithLocations(
            allocator,
            self.source,
            self.target,
            self.external,
            self.import_kinds,
            self.locations.items,
        );
    }

    pub fn mergeLocations(
        self: *Edge,
        allocator: Allocator,
        locations: []const SourceLocation,
    ) Allocator.Error!void {
        try self.locations.appendSlice(allocator, locations);
        self.sortAndDeduplicateLocations();
    }

    pub fn locationItems(self: *const Edge) []const SourceLocation {
        return self.locations.items;
    }

    pub fn deinit(self: *Edge, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.target);
        self.locations.deinit(allocator);
        self.* = undefined;
    }

    pub fn eql(self: Edge, other: Edge) bool {
        return std.mem.eql(u8, self.source, other.source) and
            std.mem.eql(u8, self.target, other.target) and
            self.external == other.external and
            self.import_kinds.eql(other.import_kinds) and
            locationsEqual(self.locations.items, other.locations.items);
    }

    fn sortAndDeduplicateLocations(self: *Edge) void {
        std.mem.sort(SourceLocation, self.locations.items, {}, struct {
            fn lessThan(_: void, left: SourceLocation, right: SourceLocation) bool {
                return left.lessThan(right);
            }
        }.lessThan);
        if (self.locations.items.len < 2) return;
        var output_index: usize = 1;
        for (self.locations.items[1..]) |location| {
            if (std.meta.eql(self.locations.items[output_index - 1], location)) continue;
            self.locations.items[output_index] = location;
            output_index += 1;
        }
        self.locations.items.len = output_index;
    }
};

fn locationsEqual(left: []const SourceLocation, right: []const SourceLocation) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_location, right_location| {
        if (!std.meta.eql(left_location, right_location)) return false;
    }
    return true;
}

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

test "edge locations are owned sorted and deduplicated" {
    const locations = [_]SourceLocation{
        .{ .byte_offset = 20, .line = 2, .column = 5 },
        .{ .byte_offset = 4, .line = 1, .column = 5 },
        .{ .byte_offset = 20, .line = 2, .column = 5 },
    };
    var edge = try Edge.initWithLocations(
        std.testing.allocator,
        "src/main.zig",
        "src/model.zig",
        false,
        ImportKinds.initOne(.zig_file),
        &locations,
    );
    defer edge.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), edge.locationItems().len);
    try std.testing.expectEqual(@as(u32, 4), edge.locationItems()[0].byte_offset);
}
