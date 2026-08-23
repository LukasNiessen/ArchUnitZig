//! Renderer-independent dependency-graph reports.

const node_selection = @import("graph/projection/node_selection.zig");
const query_options = @import("graph/projection/query_options.zig");
const report = @import("graph/projection/report.zig");

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

test {
    _ = @import("graph/projection/node_selection.zig");
    _ = @import("graph/projection/query_options.zig");
    _ = @import("graph/projection/report.zig");
}
