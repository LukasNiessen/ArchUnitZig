const std = @import("std");

const regex_module = @import("regex.zig");

const Allocator = std.mem.Allocator;
const Regex = regex_module.Regex;

pub const GlobError = error{CharacterClassContainsSeparator};
pub const CompileError = Regex.CompileError || GlobError;

/// A borrowed user-facing pattern. Compiling it produces an owned `Regex`.
///
/// Globs are anchored and use `/` as their separator. Regular expressions are an explicit escape
/// hatch and retain their native partial-match behavior unless a filter requests exact matching.
pub const Pattern = union(enum) {
    glob: []const u8,
    regex: []const u8,

    pub fn compile(self: Pattern, allocator: Allocator) CompileError!Regex {
        return switch (self) {
            .glob => |source| compileGlob(allocator, source),
            .regex => |source| Regex.compile(allocator, source),
        };
    }
};

fn compileGlob(allocator: Allocator, glob: []const u8) CompileError!Regex {
    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(allocator);
    try expression.append(allocator, '^');

    var index: usize = 0;
    while (index < glob.len) {
        switch (glob[index]) {
            '*' => try appendStar(allocator, &expression, glob, &index),
            '?' => {
                try expression.appendSlice(allocator, "[^/]");
                index += 1;
            },
            '[' => try appendCharacterClass(allocator, &expression, glob, &index),
            '\\' => {
                try expression.append(allocator, '/');
                index += 1;
            },
            else => {
                try appendEscapedLiteralByte(allocator, &expression, glob[index]);
                index += 1;
            },
        }
    }

    try expression.append(allocator, '$');
    return Regex.compile(allocator, expression.items);
}

fn appendStar(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    glob: []const u8,
    index: *usize,
) Allocator.Error!void {
    if (index.* + 1 >= glob.len or glob[index.* + 1] != '*') {
        try expression.appendSlice(allocator, "[^/]*");
        index.* += 1;
        return;
    }

    index.* += 2;
    while (index.* < glob.len and glob[index.*] == '*') index.* += 1;

    if (index.* < glob.len and isSeparator(glob[index.*])) {
        try expression.appendSlice(allocator, "(?:.*/)?");
        index.* += 1;
    } else {
        try expression.appendSlice(allocator, ".*");
    }
}

fn appendCharacterClass(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    glob: []const u8,
    index: *usize,
) CompileError!void {
    const closing = std.mem.indexOfScalar(u8, glob[index.* + 1 ..], ']') orelse {
        try expression.appendSlice(allocator, "\\[");
        index.* += 1;
        return;
    };
    const closing_index = index.* + 1 + closing;
    const content = glob[index.* + 1 .. closing_index];

    const only_negation = content.len == 1 and content[0] == '!';
    if (content.len == 0 or only_negation) {
        try expression.appendSlice(allocator, "\\[");
        index.* += 1;
        return;
    }
    if (classCanContainSeparator(content)) return error.CharacterClassContainsSeparator;

    const negated = content[0] == '!';
    try expression.append(allocator, '[');
    if (negated) try expression.appendSlice(allocator, "^/");

    for (content[@intFromBool(negated)..]) |byte| {
        if (byte == '[' or byte == ']' or byte == '^' or byte == '\\') {
            try expression.append(allocator, '\\');
        }
        try expression.append(allocator, byte);
    }
    try expression.append(allocator, ']');
    index.* = closing_index + 1;
}

fn classCanContainSeparator(content: []const u8) bool {
    const start: usize = @intFromBool(content[0] == '!');
    const values = content[start..];

    for (values, 0..) |byte, index| {
        if (isSeparator(byte)) return true;
        if (byte != '-' or index == 0 or index + 1 == values.len) continue;

        const range_start = values[index - 1];
        const range_end = values[index + 1];
        if (range_start <= '/' and '/' <= range_end) return true;
    }
    return false;
}

fn appendEscapedLiteralByte(
    allocator: Allocator,
    expression: *std.ArrayList(u8),
    byte: u8,
) Allocator.Error!void {
    if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$", byte) != null) {
        try expression.append(allocator, '\\');
    }
    try expression.append(allocator, byte);
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn expectPatternMatch(pattern: Pattern, input: []const u8, expected: bool) !void {
    var compiled = try pattern.compile(std.testing.allocator);
    defer compiled.deinit();
    try std.testing.expectEqual(expected, try compiled.isMatch(std.testing.allocator, input));
}

test "single star stays within one path segment" {
    try expectPatternMatch(.{ .glob = "*.zig" }, "service.zig", true);
    try expectPatternMatch(.{ .glob = "*.zig" }, "src/service.zig", false);
}

test "double star crosses zero or more path segments" {
    try expectPatternMatch(.{ .glob = "src/**/*.zig" }, "src/service.zig", true);
    try expectPatternMatch(.{ .glob = "src/**/*.zig" }, "src/domain/service.zig", true);
    try expectPatternMatch(.{ .glob = "src/**/*.zig" }, "test/service.zig", false);
}

test "question marks and character classes stay within a segment" {
    try expectPatternMatch(.{ .glob = "service?.[zZ][iI][gG]" }, "service1.zig", true);
    try expectPatternMatch(.{ .glob = "service?.[zZ][iI][gG]" }, "service12.zig", false);
    try expectPatternMatch(.{ .glob = "service[0-9].zig" }, "service7.zig", true);
    try expectPatternMatch(.{ .glob = "service[!0-9].zig" }, "serviceA.zig", true);
    try expectPatternMatch(.{ .glob = "service[!0-9].zig" }, "service7.zig", false);
}

test "empty and unclosed character classes are literal text" {
    try expectPatternMatch(.{ .glob = "literal[].zig" }, "literal[].zig", true);
    try expectPatternMatch(.{ .glob = "literal[.zig" }, "literal[.zig", true);
}

test "glob separators normalize and matching remains case-sensitive" {
    try expectPatternMatch(.{ .glob = "src\\**\\*.zig" }, "src/domain/service.zig", true);
    try expectPatternMatch(.{ .glob = "src\\**\\*.zig" }, "src/domain/Service.ZIG", false);
}

test "glob literals escape regular-expression syntax" {
    try expectPatternMatch(.{ .glob = "src/order[[]legacy].zig" }, "src/order[legacy].zig", true);
    try expectPatternMatch(.{ .glob = "src/file(1)+.zig" }, "src/file(1)+.zig", true);
}

test "malformed ranges and separator-spanning classes are errors" {
    try std.testing.expectError(
        error.InvalidCharRange,
        (Pattern{ .glob = "[z-a].zig" }).compile(std.testing.allocator),
    );
    try std.testing.expectError(
        error.CharacterClassContainsSeparator,
        (Pattern{ .glob = "[.-0].zig" }).compile(std.testing.allocator),
    );
}

test "regex patterns retain partial matching and capture support" {
    var compiled = try (Pattern{ .regex = "src/([^/]+)" }).compile(std.testing.allocator);
    defer compiled.deinit();

    const captures = (try compiled.captures(std.testing.allocator, "prefix/src/domain/model.zig")).?;
    defer captures.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("domain", captures.values[1].?);
}

test "glob wildcards match one Unicode scalar rather than one UTF-8 byte" {
    try expectPatternMatch(.{ .glob = "caf?.zig" }, "café.zig", true);
    try expectPatternMatch(.{ .glob = "file?.zig" }, "file🦎.zig", true);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var compiled = try (Pattern{ .glob = "src/**/*.zig" }).compile(allocator);
    defer compiled.deinit();
    try std.testing.expect(try compiled.isMatch(allocator, "src/domain/model.zig"));
}

test "glob compilation cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
