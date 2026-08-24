const std = @import("std");

const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const matching = @import("../matching.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = ".archignore";
const max_file_size = 1024 * 1024;

/// One owned snapshot of the root policy. The exact path, presence, and content fingerprint are
/// retained separately from the effective patterns so cache identity can conservatively track
/// comment and line-ending edits too.
pub const ArchIgnore = struct {
    path: []const u8,
    present: bool = false,
    fingerprint: [32]u8 = [_]u8{0} ** 32,
    pattern_storage: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ArchIgnore, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.pattern_storage.items) |pattern| allocator.free(pattern);
        self.pattern_storage.deinit(allocator);
        self.* = undefined;
    }

    pub fn patterns(self: *const ArchIgnore) []const []const u8 {
        return self.pattern_storage.items;
    }
};

/// Loads only `<project_root>/.archignore`. A missing file is a valid, cache-identifiable state.
pub fn load(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ArchIgnore {
    const joined_path = std.fs.path.join(allocator, &.{ project_root, file_name }) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.load_archignore", file_name, error.OutOfMemory);
    };
    defer allocator.free(joined_path);
    const normalized_path = common_path.normalize(allocator, joined_path) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.load_archignore", file_name, error.OutOfMemory);
    };

    var result = ArchIgnore{ .path = normalized_path };
    errdefer result.deinit(allocator);
    const contents = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        joined_path,
        allocator,
        .limited(max_file_size),
        .of(u8),
        0,
    ) catch |failure| switch (failure) {
        error.FileNotFound => return result,
        error.OutOfMemory => return diagnostics.failTechnical(
            .out_of_memory,
            "project.load_archignore",
            normalized_path,
            failure,
        ),
        else => |other| return diagnostics.failTechnical(
            .file_system,
            "project.load_archignore",
            normalized_path,
            other,
        ),
    };
    defer allocator.free(contents);

    result.present = true;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(contents);
    hash.final(&result.fingerprint);
    try parseContents(allocator, &result, contents, diagnostics);
    return result;
}

fn parseContents(
    allocator: Allocator,
    result: *ArchIgnore,
    contents: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const pattern = std.mem.trim(u8, line, " \t\r");
        if (pattern.len == 0 or pattern[0] == '#') continue;
        try validatePattern(allocator, result.path, line_number, pattern, diagnostics);
        const owned = allocator.dupe(u8, pattern) catch {
            return diagnostics.failTechnical(
                .out_of_memory,
                "project.parse_archignore",
                result.path,
                error.OutOfMemory,
            );
        };
        result.pattern_storage.append(allocator, owned) catch {
            allocator.free(owned);
            return diagnostics.failTechnical(
                .out_of_memory,
                "project.parse_archignore",
                result.path,
                error.OutOfMemory,
            );
        };
    }
}

fn validatePattern(
    allocator: Allocator,
    path: []const u8,
    line_number: usize,
    pattern: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    if (pattern[0] == '!') return failPattern(
        allocator,
        diagnostics,
        path,
        line_number,
        error.UnsupportedNegation,
    );
    if (std.mem.indexOfScalar(u8, pattern, 0) != null) return failPattern(
        allocator,
        diagnostics,
        path,
        line_number,
        error.NulByte,
    );

    const without_anchor = if (pattern[0] == '/') pattern[1..] else pattern;
    if (without_anchor.len == 0) return failPattern(
        allocator,
        diagnostics,
        path,
        line_number,
        error.EmptyPattern,
    );
    const normalized = common_path.normalize(allocator, without_anchor) catch {
        return diagnostics.failTechnical(
            .out_of_memory,
            "project.parse_archignore",
            path,
            error.OutOfMemory,
        );
    };
    defer allocator.free(normalized);
    if (std.mem.startsWith(u8, normalized, "/")) return failPattern(
        allocator,
        diagnostics,
        path,
        line_number,
        error.InvalidRootAnchor,
    );
    var segments = std.mem.splitScalar(u8, normalized, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return failPattern(
                allocator,
                diagnostics,
                path,
                line_number,
                error.RelativePathSegment,
            );
        }
    }

    var compiled = (matching.Pattern{ .glob = without_anchor }).compile(allocator) catch |failure| {
        if (failure == error.OutOfMemory) {
            return diagnostics.failTechnical(
                .out_of_memory,
                "project.parse_archignore",
                path,
                failure,
            );
        }
        return failPattern(allocator, diagnostics, path, line_number, failure);
    };
    compiled.deinit();
}

fn failPattern(
    allocator: Allocator,
    diagnostics: *common_error.ErrorContext,
    path: []const u8,
    line_number: usize,
    cause: anyerror,
) common_error.ArchUnitError {
    const subject = std.fmt.allocPrint(allocator, "{s}:{d}", .{ path, line_number }) catch {
        return diagnostics.failTechnical(
            .out_of_memory,
            "project.parse_archignore",
            path,
            error.OutOfMemory,
        );
    };
    defer allocator.free(subject);
    return diagnostics.failUser(.invalid_pattern, "project.parse_archignore", subject, cause);
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

test "missing policy is an owned absent snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    var policy = try load(std.testing.allocator, std.testing.io, root, &diagnostics);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expect(!policy.present);
    try std.testing.expectEqual(@as(usize, 0), policy.patterns().len);
    try std.testing.expect(std.mem.endsWith(u8, policy.path, "/.archignore"));
}

test "comments whitespace CRLF and literal inline hashes parse deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "  # root policy\r\n\r\n src/** \r\nnested\\generated\\**\nfile#literal.zig\n",
    });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    var policy = try load(std.testing.allocator, std.testing.io, root, &diagnostics);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expect(policy.present);
    try std.testing.expectEqual(@as(usize, 3), policy.patterns().len);
    try std.testing.expectEqualStrings("src/**", policy.patterns()[0]);
    try std.testing.expectEqualStrings("nested\\generated\\**", policy.patterns()[1]);
    try std.testing.expectEqualStrings("file#literal.zig", policy.patterns()[2]);
    try std.testing.expect(!std.mem.allEqual(u8, &policy.fingerprint, 0));
}

fn expectInvalid(contents: []const u8, expected_cause: anyerror) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = contents });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.InvalidPattern,
        load(std.testing.allocator, std.testing.io, root, &diagnostics),
    );
    try std.testing.expectEqualStrings("project.parse_archignore", diagnostics.diagnostic.?.operation);
    try std.testing.expect(std.mem.endsWith(u8, diagnostics.diagnostic.?.subject.?, "/.archignore:2"));
    try std.testing.expectEqual(expected_cause, diagnostics.diagnostic.?.cause.?);
}

test "unsupported negation and malformed project-relative globs fail closed" {
    try expectInvalid("# policy\n!generated/**\n", error.UnsupportedNegation);
    try expectInvalid("# policy\n/\n", error.EmptyPattern);
    try expectInvalid("# policy\nsrc/../private/**\n", error.RelativePathSegment);
    try expectInvalid("# policy\n[z-a].zig\n", error.InvalidCharRange);
    try expectInvalid("# policy\nembedded\x00nul\n", error.NulByte);
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    var diagnostics = common_error.ErrorContext.init(allocator);
    defer diagnostics.deinit();
    var policy = try load(allocator, std.testing.io, root, &diagnostics);
    defer policy.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), policy.patterns().len);
}

test "policy loading cleans up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "generated/**\nsrc/**/*_generated.zig\n",
    });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
