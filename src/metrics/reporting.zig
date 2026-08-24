pub const MetricValue = @import("reporting/report_data.zig").MetricValue;
pub const MetricsReportData = @import("reporting/report_data.zig").MetricsReportData;
pub const MetricsReportEntry = @import("reporting/report_data.zig").MetricsReportEntry;
pub const MetricsReportSection = @import("reporting/report_data.zig").MetricsReportSection;
pub const MetricsReportSectionKind = @import("reporting/report_data.zig").MetricsReportSectionKind;
pub const countSection = @import("reporting/report_data.zig").countSection;
pub const customSection = @import("reporting/report_data.zig").customSection;
pub const dependencySection = @import("reporting/report_data.zig").dependencySection;
pub const MetricsExportOptions = @import("reporting/html_renderer.zig").MetricsExportOptions;
pub const MetricsRenderError = @import("reporting/html_renderer.zig").RenderError;
pub const metricsToHtml = @import("reporting/html_renderer.zig").toHtml;
pub const MetricsExportError = @import("reporting/export_support.zig").ExportError;
pub const exportMetricsAsHtml = @import("reporting/export_support.zig").exportAsHtml;
pub const resolveMetricsHtmlPath = @import("reporting/export_support.zig").resolveHtmlPath;

test {
    _ = @import("reporting/report_data.zig");
    _ = @import("reporting/html_renderer.zig");
    _ = @import("reporting/export_support.zig");
}
