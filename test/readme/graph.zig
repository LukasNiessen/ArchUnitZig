const std = @import("std");
const archunit = @import("archunit");

test "render the project graph as Mermaid" {
    var graph = try archunit.projectGraph(std.testing.allocator, .{});
    defer graph.deinit();
    const mermaid = try graph.toMermaid(.init(std.testing.allocator, std.testing.io));
    defer std.testing.allocator.free(mermaid);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "src/api/root.zig") != null);
}
