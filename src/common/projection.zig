pub const MapFunction = @import("projection/mapped_edge.zig").MapFunction;
pub const MappedEdge = @import("projection/mapped_edge.zig").MappedEdge;
pub const NodeProjectionOptions = @import("projection/project_nodes.zig").NodeProjectionOptions;
pub const ProjectedCycle = @import("projection/projected_cycle.zig").ProjectedCycle;
pub const ProjectedCycles = @import("projection/projected_cycle.zig").ProjectedCycles;
pub const ProjectedEdge = @import("projection/projected_edge.zig").ProjectedEdge;
pub const ProjectedEdges = @import("projection/projected_edge.zig").ProjectedEdges;
pub const ProjectedNode = @import("projection/projected_node.zig").ProjectedNode;
pub const ProjectedNodes = @import("projection/projected_node.zig").ProjectedNodes;
pub const ProjectionError = @import("projection/projected_edge.zig").ProjectionError;
pub const projectEdges = @import("projection/project_edges.zig").projectEdges;
pub const projectToNodes = @import("projection/project_nodes.zig").projectToNodes;

test {
    _ = @import("projection/mapped_edge.zig");
    _ = @import("projection/project_edges.zig");
    _ = @import("projection/project_nodes.zig");
    _ = @import("projection/projected_cycle.zig");
    _ = @import("projection/projected_edge.zig");
    _ = @import("projection/projected_node.zig");
}
