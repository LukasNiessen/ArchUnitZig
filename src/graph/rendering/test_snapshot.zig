const std = @import("std");

const extraction = @import("../../common/extraction.zig");
const report = @import("../projection/report.zig");

pub fn make(allocator: std.mem.Allocator) !report.GraphReportSnapshot {
    var nodes = [_]report.GraphReportNode{
        try report.GraphReportNode.init(allocator, "n0", "app/\"api\"\n.zig"),
        try report.GraphReportNode.init(allocator, "n1", "domain<&>.zig"),
        try report.GraphReportNode.init(allocator, "n2", "assets/config,<x>.json"),
        try report.GraphReportNode.init(allocator, "n3", "std"),
    };
    defer for (&nodes) |*node| node.deinit(allocator);

    var edges = [_]report.GraphReportEdge{
        try report.GraphReportEdge.init(
            allocator,
            nodes[0].label,
            nodes[1].label,
            2,
            false,
            extraction.ImportKinds.initMany(&.{ .zig_file, .root_module }),
            extraction.TargetClasses.initOne(.internal),
            extraction.TargetAvailabilities.initOne(.resolved),
        ),
        try report.GraphReportEdge.init(
            allocator,
            nodes[0].label,
            nodes[2].label,
            1,
            false,
            extraction.ImportKinds.initOne(.embedded_file),
            extraction.TargetClasses.initOne(.resource),
            extraction.TargetAvailabilities.initOne(.resolved),
        ),
        try report.GraphReportEdge.init(
            allocator,
            nodes[0].label,
            nodes[3].label,
            1,
            true,
            extraction.ImportKinds.initOne(.standard_library),
            extraction.TargetClasses.initOne(.compiler),
            extraction.TargetAvailabilities.initOne(.unresolved),
        ),
    };
    defer for (&edges) |*edge| edge.deinit(allocator);

    return report.GraphReportSnapshot.init(
        allocator,
        "Architecture <Main>\r\n\"quoted\"",
        &nodes,
        &edges,
        .{
            .node_count = nodes.len,
            .edge_count = edges.len,
            .raw_edge_count = 4,
            .external_edge_count = 1,
        },
    );
}
