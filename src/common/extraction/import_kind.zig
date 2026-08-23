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
