/// The part of an analyzed item to which a pattern is applied.
pub const PatternTarget = enum {
    filename,
    path,
    path_without_filename,
    declaration_name,
};

pub const MatchingMode = enum {
    partial,
    exact,
};
