const std = @import("std");

const common_error = @import("../../common/error.zig");
const import_kind = @import("../../common/extraction/import_kind.zig");
const source_parser = @import("../../common/extraction/source_parser.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const ImportKind = import_kind.ImportKind;
pub const ImportKinds = import_kind.ImportKinds;
pub const ImportSummary = import_kind.ImportSummary;
pub const TopLevelDeclarationCounts = source_parser.TopLevelDeclarationCounts;

/// Borrowed file data passed to a custom predicate.
///
/// All slices remain valid only for the predicate call that receives this value. `source_bytes` is
/// arbitrary file data and is not promised to be UTF-8. Extension includes its leading dot.
pub const FileInfo = struct {
    path: []const u8,
    stem: []const u8,
    extension: []const u8,
    directory: []const u8,
    source_bytes: []const u8,
    non_blank_line_count: usize,
    imports: ImportSummary,
    top_level_declarations: ?TopLevelDeclarationCounts,
};

/// One source read backing a borrowed `FileInfo` view. The relative path and its derived slices
/// still borrow the caller's path; only the source buffer is owned here.
pub const LoadedFileInfo = struct {
    source_storage: [:0]u8,
    view: FileInfo,

    pub fn deinit(self: *LoadedFileInfo, allocator: Allocator) void {
        allocator.free(self.source_storage);
        self.* = undefined;
    }
};

/// Reads exactly one project-relative source and derives a callback view. No source copy is made
/// after the required filesystem read.
pub fn loadFileInfo(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    relative_path: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!LoadedFileInfo {
    const absolute_path = std.fs.path.join(allocator, &.{ project_root, relative_path }) catch {
        return diagnostics.failTechnical(.out_of_memory, "files.file_info.path", relative_path, error.OutOfMemory);
    };
    defer allocator.free(absolute_path);
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        absolute_path,
        allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    ) catch |failure| return mapReadFailure(diagnostics, relative_path, failure);
    errdefer allocator.free(source);

    return .{
        .source_storage = source,
        .view = try inspectFileBytes(allocator, relative_path, source, diagnostics),
    };
}

/// Derives a byte-safe view without taking ownership of either input slice. Invalid Zig syntax is
/// intentionally analyzed permissively: bytes and line counts remain available, while declaration
/// facts are `null` and imports are empty.
pub fn inspectFileBytes(
    allocator: Allocator,
    relative_path: []const u8,
    source_bytes: [:0]const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!FileInfo {
    const basename = std.fs.path.basename(relative_path);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];
    const directory = std.fs.path.dirname(relative_path) orelse "";
    var imports: ImportSummary = .{};
    var declarations: ?TopLevelDeclarationCounts = null;

    if (std.mem.eql(u8, extension, ".zig")) {
        var parsed = try source_parser.parseSource(
            allocator,
            relative_path,
            source_bytes,
            .permissive,
            diagnostics,
        );
        defer parsed.deinit(allocator);
        declarations = parsed.top_level_declarations;
        for (parsed.references.items) |reference| imports.record(reference.kind);
    }

    return .{
        .path = relative_path,
        .stem = stem,
        .extension = extension,
        .directory = directory,
        .source_bytes = source_bytes,
        .non_blank_line_count = countNonBlankLines(source_bytes),
        .imports = imports,
        .top_level_declarations = declarations,
    };
}

fn countNonBlankLines(source: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\x0b\x0c").len != 0) count += 1;
    }
    return count;
}

fn mapReadFailure(
    diagnostics: *common_error.ErrorContext,
    relative_path: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "files.file_info.read", relative_path, failure);
    }
    return diagnostics.failTechnical(.file_system, "files.file_info.read", relative_path, failure);
}

test "file info exposes byte-safe paths lines imports and root declarations" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const model = @import("model.zig");
        \\
        \\pub fn run() void {
        \\    _ = std;
        \\}
        \\test "run" {}
    ;
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const info = try inspectFileBytes(
        std.testing.allocator,
        "src/services/order_service.zig",
        source,
        &diagnostics,
    );

    try std.testing.expectEqualStrings("src/services/order_service.zig", info.path);
    try std.testing.expectEqualStrings("order_service", info.stem);
    try std.testing.expectEqualStrings(".zig", info.extension);
    try std.testing.expectEqualStrings("src/services", info.directory);
    try std.testing.expectEqual(@as(usize, 6), info.non_blank_line_count);
    try std.testing.expectEqual(@as(usize, 2), info.imports.total);
    try std.testing.expectEqual(@as(usize, 1), info.imports.count(.standard_library));
    try std.testing.expectEqual(@as(usize, 1), info.imports.count(.zig_file));
    try std.testing.expect(info.imports.kinds.contains(.standard_library));
    const declarations = info.top_level_declarations.?;
    try std.testing.expectEqual(@as(usize, 4), declarations.total);
    try std.testing.expectEqual(@as(usize, 1), declarations.functions);
    try std.testing.expectEqual(@as(usize, 2), declarations.variables);
    try std.testing.expectEqual(@as(usize, 1), declarations.tests);
}

test "invalid UTF-8 and empty files remain inspectable without invented syntax facts" {
    const binary: [:0]const u8 = &[_:0]u8{ 0xff, '\n', '\n', 'x' };
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const invalid = try inspectFileBytes(std.testing.allocator, "src/legacy.zig", binary, &diagnostics);
    try std.testing.expectEqualSlices(u8, binary, invalid.source_bytes);
    try std.testing.expectEqual(@as(usize, 2), invalid.non_blank_line_count);
    try std.testing.expectEqual(@as(usize, 0), invalid.imports.total);
    try std.testing.expectEqual(@as(?TopLevelDeclarationCounts, null), invalid.top_level_declarations);

    const empty: [:0]const u8 = "";
    const empty_info = try inspectFileBytes(std.testing.allocator, "empty.zig", empty, &diagnostics);
    try std.testing.expectEqualStrings("", empty_info.directory);
    try std.testing.expectEqual(@as(usize, 0), empty_info.non_blank_line_count);
    try std.testing.expectEqual(@as(usize, 0), empty_info.top_level_declarations.?.total);
}

test "ZON files expose bytes but no Zig declaration or import analysis" {
    const source: [:0]const u8 = ".{ .name = .fixture }";
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const info = try inspectFileBytes(std.testing.allocator, "build.zig.zon", source, &diagnostics);
    try std.testing.expectEqualStrings("build.zig", info.stem);
    try std.testing.expectEqualStrings(".zon", info.extension);
    try std.testing.expectEqual(@as(usize, 0), info.imports.total);
    try std.testing.expectEqual(@as(?TopLevelDeclarationCounts, null), info.top_level_declarations);
}

test "loaded file info owns only its one source buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.zig", .data = "pub fn sample() void {}\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var loaded = try loadFileInfo(
        std.testing.allocator,
        std.testing.io,
        root,
        "sample.zig",
        &diagnostics,
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(loaded.source_storage.ptr, loaded.view.source_bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), loaded.view.top_level_declarations.?.functions);
}
