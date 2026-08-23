const std = @import("std");

const common_error = @import("../error.zig");
const source_location = @import("source_location.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
pub const SourceLocation = source_location.SourceLocation;

const ParseDirectiveError = Allocator.Error || error{
    MissingDirectiveColon,
    ExpectedIgnoreKeyword,
    MissingTargetAfterComma,
};

const Directive = struct {
    location: SourceLocation,
    trailing: bool,
    targets: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Directive, allocator: Allocator) void {
        self.targets.deinit(allocator);
        self.* = undefined;
    }

    fn appliesTo(self: Directive, target: []const u8, start_line: usize, end_line: usize) bool {
        const line_applies = if (self.trailing)
            self.location.line >= start_line and self.location.line <= end_line
        else
            start_line == self.location.line + 1;
        if (!line_applies) return false;
        if (self.targets.items.len == 0) return true;
        for (self.targets.items) |ignored_target| {
            if (std.mem.eql(u8, ignored_target, target)) return true;
        }
        return false;
    }
};

/// Borrowed target slices backed by the parsed source plus owned directive-list storage.
pub const IgnoreDirectives = struct {
    items: std.ArrayList(Directive) = .empty,

    pub fn deinit(self: *IgnoreDirectives, allocator: Allocator) void {
        for (self.items.items) |*directive| directive.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn ignores(
        self: *const IgnoreDirectives,
        target: []const u8,
        start_line: usize,
        end_line: usize,
    ) bool {
        for (self.items.items) |directive| {
            if (directive.appliesTo(target, start_line, end_line)) return true;
        }
        return false;
    }
};

/// Finds anchored ArchUnit directives only in ordinary line-comment gaps between Zig tokens.
pub fn parseIgnoreDirectives(
    allocator: Allocator,
    source_path: []const u8,
    source: []const u8,
    tree: *const Ast,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!IgnoreDirectives {
    var directives: IgnoreDirectives = .{};
    errdefer directives.deinit(allocator);

    var line_start: usize = 0;
    var line_number: usize = 1;
    while (line_start < source.len) : (line_number += 1) {
        const newline = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const content_end = if (newline > line_start and source[newline - 1] == '\r') newline - 1 else newline;
        const line = source[line_start..content_end];
        if (ordinaryCommentStart(tree, line, line_start)) |comment_start| {
            const body_start = comment_start - line_start + 2;
            const body = trimWhitespace(line[body_start..]);
            const parsed = parseComment(allocator, body, .{
                .byte_offset = @intCast(comment_start),
                .line = line_number,
                .column = comment_start - line_start + 1,
            }, hasNonWhitespace(line[0 .. comment_start - line_start])) catch |failure| switch (failure) {
                error.OutOfMemory => return diagnostics.failTechnical(
                    .out_of_memory,
                    "zig.parse_ignore_directive",
                    source_path,
                    failure,
                ),
                else => return failMalformedDirective(
                    allocator,
                    diagnostics,
                    source_path,
                    line_number,
                    comment_start - line_start + 1,
                    failure,
                ),
            };
            if (parsed) |value| {
                var owned = value;
                directives.items.append(allocator, owned) catch {
                    owned.deinit(allocator);
                    return diagnostics.failTechnical(
                        .out_of_memory,
                        "zig.parse_ignore_directive",
                        source_path,
                        error.OutOfMemory,
                    );
                };
            }
        }
        if (newline == source.len) break;
        line_start = newline + 1;
    }
    return directives;
}

fn parseComment(
    allocator: Allocator,
    body: []const u8,
    location: SourceLocation,
    trailing: bool,
) ParseDirectiveError!?Directive {
    if (!looksLikeDirective(body)) return null;
    var rest = body["archunit".len..];
    if (rest.len == 0 or rest[0] != ':') return error.MissingDirectiveColon;
    rest = trimWhitespace(rest[1..]);
    if (!std.mem.startsWith(u8, rest, "ignore")) return error.ExpectedIgnoreKeyword;
    rest = rest["ignore".len..];
    if (rest.len != 0 and !isWhitespace(rest[0])) return error.ExpectedIgnoreKeyword;
    rest = trimWhitespace(rest);

    var directive = Directive{ .location = location, .trailing = trailing };
    errdefer directive.deinit(allocator);
    var cursor: usize = 0;
    var saw_target = false;
    var comma_requires_target = false;
    while (cursor < rest.len) {
        while (cursor < rest.len and isWhitespace(rest[cursor])) cursor += 1;
        if (cursor == rest.len) break;
        if (rest[cursor] == ',') {
            if (!saw_target or comma_requires_target) return error.MissingTargetAfterComma;
            comma_requires_target = true;
            cursor += 1;
            continue;
        }
        const start = cursor;
        while (cursor < rest.len and !isWhitespace(rest[cursor]) and rest[cursor] != ',') cursor += 1;
        try directive.targets.append(allocator, rest[start..cursor]);
        saw_target = true;
        comma_requires_target = false;
    }
    if (comma_requires_target) return error.MissingTargetAfterComma;
    return directive;
}

fn looksLikeDirective(body: []const u8) bool {
    if (!std.mem.startsWith(u8, body, "archunit")) return false;
    if (body.len == "archunit".len) return true;
    return body["archunit".len] == ':' or isWhitespace(body["archunit".len]);
}

fn ordinaryCommentStart(tree: *const Ast, line: []const u8, line_start: usize) ?usize {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_from, "//")) |relative_start| {
        const absolute_start = line_start + relative_start;
        if (!insideToken(tree, absolute_start)) return absolute_start;
        search_from = relative_start + 2;
    }
    return null;
}

fn insideToken(tree: *const Ast, byte_offset: usize) bool {
    var index: usize = 0;
    while (index < tree.tokens.len) : (index += 1) {
        const token: Ast.TokenIndex = @intCast(index);
        const start = tree.tokenStart(token);
        if (byte_offset < start) return false;
        if (byte_offset < start + tree.tokenSlice(token).len) return true;
    }
    return false;
}

fn hasNonWhitespace(value: []const u8) bool {
    for (value) |byte| if (!isWhitespace(byte)) return true;
    return false;
}

fn trimWhitespace(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn failMalformedDirective(
    allocator: Allocator,
    diagnostics: *common_error.ErrorContext,
    source_path: []const u8,
    line: usize,
    column: usize,
    cause: anyerror,
) common_error.ArchUnitError {
    const subject = std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ source_path, line, column }) catch {
        return diagnostics.failTechnical(.out_of_memory, "zig.parse_ignore_directive", source_path, error.OutOfMemory);
    };
    defer allocator.free(subject);
    return diagnostics.failUser(
        .invalid_ignore_directive,
        "zig.parse_ignore_directive",
        subject,
        cause,
    );
}

test "scanner recognizes ordinary comments but not strings or documentation comments" {
    const source: [:0]const u8 =
        "const text = \"// archunit: ignore\";\r\n" ++
        "/// archunit: ignore\r\n" ++
        "const kept = @import(\"kept.zig\");\r\n" ++
        "const ignored = @import(\"ignored.zig\"); // archunit: ignore ignored.zig\r\n";
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var directives = try parseIgnoreDirectives(
        std.testing.allocator,
        "src/main.zig",
        source,
        &tree,
        &context,
    );
    defer directives.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), directives.items.items.len);
    try std.testing.expect(!directives.ignores("kept.zig", 3, 3));
    try std.testing.expect(directives.ignores("ignored.zig", 4, 4));
}

test "malformed intended directives return located user diagnostics" {
    const source: [:0]const u8 = "  // archunit ignore\nconst dependency = @import(\"dep.zig\");\n";
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    try std.testing.expectError(
        error.InvalidIgnoreDirective,
        parseIgnoreDirectives(std.testing.allocator, "src/main.zig", source, &tree, &context),
    );
    try std.testing.expectEqual(common_error.ErrorCategory.user, context.diagnostic.?.category());
    try std.testing.expectEqualStrings("zig.parse_ignore_directive", context.diagnostic.?.operation);
    try std.testing.expectEqualStrings("src/main.zig:1:3", context.diagnostic.?.subject.?);
    try std.testing.expectEqual(error.MissingDirectiveColon, context.diagnostic.?.cause.?);
}
