pub const MetricValue = @import("reporting/report_data.zig").MetricValue;
pub const MetricsReportData = @import("reporting/report_data.zig").MetricsReportData;
pub const MetricsReportEntry = @import("reporting/report_data.zig").MetricsReportEntry;
pub const MetricsReportSection = @import("reporting/report_data.zig").MetricsReportSection;
pub const MetricsReportSectionKind = @import("reporting/report_data.zig").MetricsReportSectionKind;
pub const countSection = @import("reporting/report_data.zig").countSection;
pub const customSection = @import("reporting/report_data.zig").customSection;
pub const dependencySection = @import("reporting/report_data.zig").dependencySection;

test {
    _ = @import("reporting/report_data.zig");
}
