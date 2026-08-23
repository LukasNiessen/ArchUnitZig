//! Renderer-independent dependency-graph reports.

const report = @import("graph/projection/report.zig");

pub const GraphReportNode = report.GraphReportNode;
pub const GraphReportEdge = report.GraphReportEdge;
pub const GraphReportSummary = report.GraphReportSummary;
pub const GraphReportSnapshot = report.GraphReportSnapshot;

test {
    _ = @import("graph/projection/report.zig");
}
