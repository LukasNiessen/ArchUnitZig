//! Renderer-independent dependency-graph reports.

const node_selection = @import("graph/projection/node_selection.zig");
const project_graph = @import("graph/fluentapi/project_graph.zig");
const query_options = @import("graph/projection/query_options.zig");
const report = @import("graph/projection/report.zig");
const renderer = @import("graph/rendering/renderer.zig");
const snapshot_factory = @import("graph/projection/snapshot_factory.zig");

pub const GraphReportNode = report.GraphReportNode;
pub const GraphReportEdge = report.GraphReportEdge;
pub const GraphReportSummary = report.GraphReportSummary;
pub const GraphReportSnapshot = report.GraphReportSnapshot;
pub const CollapseQuery = query_options.CollapseQuery;
pub const FocusQuery = query_options.FocusQuery;
pub const GraphQueryOptions = query_options.GraphQueryOptions;
pub const PatternCollapse = query_options.PatternCollapse;
pub const NodeSelection = node_selection.NodeSelection;
pub const selectGraphNodes = node_selection.selectNodes;
pub const GraphSnapshotError = snapshot_factory.SnapshotError;
pub const createGraphSnapshot = snapshot_factory.createSnapshot;
pub const GraphBuilderError = project_graph.BuilderError;
pub const ProjectGraphBuilder = project_graph.ProjectGraphBuilder;
pub const ProjectGraphOptions = project_graph.ProjectGraphOptions;
pub const dependencyGraph = project_graph.dependencyGraph;
pub const projectGraph = project_graph.projectGraph;
pub const GraphReportFormat = renderer.GraphReportFormat;
pub const GraphRenderError = renderer.RenderError;
pub const GraphExportError = renderer.ExportError;
pub const GraphRenderer = renderer.GraphRenderer;

test {
    _ = @import("graph/rendering/escaping.zig");
    _ = @import("graph/rendering/json_renderer.zig");
    _ = @import("graph/rendering/renderer.zig");
    _ = @import("graph/rendering/html_renderer.zig");
    _ = @import("graph/rendering/support.zig");
    _ = @import("graph/rendering/text_renderers.zig");
    _ = @import("graph/fluentapi/project_graph.zig");
    _ = @import("graph/projection/collapse.zig");
    _ = @import("graph/projection/node_selection.zig");
    _ = @import("graph/projection/query_options.zig");
    _ = @import("graph/projection/report.zig");
    _ = @import("graph/projection/snapshot_factory.zig");
}
