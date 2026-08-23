const path = @import("../path.zig");

/// Returns an owned identifier with platform separators normalised to `/` and repeated separators
/// collapsed. Extraction is responsible for making internal identifiers project-relative before
/// they enter the graph; this function intentionally leaves other bytes, including `..`, alone so
/// unresolved external targets remain diagnosable.
pub const normalize = path.normalize;
