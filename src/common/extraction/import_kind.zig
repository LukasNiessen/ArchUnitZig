const std = @import("std");

/// Describes how a Zig source file expressed a dependency.
///
/// The categories deliberately preserve compiler modules and non-code inputs instead of flattening
/// every target that is not another project file into one "external import" bucket.
pub const ImportKind = enum {
    zig_file,
    zon_file,
    named_module,
    standard_library,
    builtin_module,
    root_module,
    embedded_file,
    c_header,
};

pub const ImportKinds = std.EnumSet(ImportKind);

const import_kind_count = std.meta.fields(ImportKind).len;

/// Value-only occurrence counts plus the set of distinct import mechanisms.
pub const ImportSummary = struct {
    total: usize = 0,
    kinds: ImportKinds = ImportKinds.initEmpty(),
    counts: [import_kind_count]usize = [_]usize{0} ** import_kind_count,

    pub fn count(self: ImportSummary, kind: ImportKind) usize {
        return self.counts[@intFromEnum(kind)];
    }

    pub fn record(self: *ImportSummary, kind: ImportKind) void {
        self.total += 1;
        self.kinds.insert(kind);
        self.counts[@intFromEnum(kind)] += 1;
    }
};

test "import kinds form a real set" {
    var kinds = ImportKinds.initOne(.zig_file);
    kinds.insert(.embedded_file);
    kinds.insert(.zig_file);

    try std.testing.expectEqual(@as(usize, 2), kinds.count());
    try std.testing.expect(kinds.contains(.zig_file));
    try std.testing.expect(kinds.contains(.embedded_file));
    try std.testing.expect(!kinds.contains(.named_module));
}

test "import kind sets union without losing either kind" {
    const source_kinds = ImportKinds.initMany(&.{ .zig_file, .root_module });
    const target_kinds = ImportKinds.initMany(&.{ .root_module, .zon_file });
    const combined = source_kinds.unionWith(target_kinds);

    try std.testing.expectEqual(@as(usize, 3), combined.count());
    try std.testing.expect(combined.contains(.zig_file));
    try std.testing.expect(combined.contains(.root_module));
    try std.testing.expect(combined.contains(.zon_file));
}

test "import summaries retain repeated occurrences and distinct kinds" {
    var summary: ImportSummary = .{};
    summary.record(.zig_file);
    summary.record(.zig_file);
    summary.record(.named_module);

    try std.testing.expectEqual(@as(usize, 3), summary.total);
    try std.testing.expectEqual(@as(usize, 2), summary.count(.zig_file));
    try std.testing.expectEqual(@as(usize, 1), summary.count(.named_module));
    try std.testing.expectEqual(@as(usize, 2), summary.kinds.count());
}
