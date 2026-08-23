const std = @import("std");

const assertion = @import("../common/assertion.zig");
const extraction = @import("../common/extraction.zig");
const matching = @import("../common/matching.zig");
const projection = @import("../common/projection.zig");

const Allocator = std.mem.Allocator;
pub const Violation = assertion.Violation;
pub const FormatError = Allocator.Error || error{InvalidRuleSentence};

/// Owned prose for one structured violation. `sort_key` is always plain text and never includes
/// ANSI escapes, so result ordering cannot change with colour policy.
pub const FormattedViolation = struct {
    heading: []const u8,
    details: []const u8,
    sort_key: []const u8,

    pub fn clone(self: FormattedViolation, allocator: Allocator) Allocator.Error!FormattedViolation {
        const heading = try allocator.dupe(u8, self.heading);
        errdefer allocator.free(heading);
        const details = try allocator.dupe(u8, self.details);
        errdefer allocator.free(details);
        return .{
            .heading = heading,
            .details = details,
            .sort_key = try allocator.dupe(u8, self.sort_key),
        };
    }

    pub fn deinit(self: *FormattedViolation, allocator: Allocator) void {
        allocator.free(self.heading);
        allocator.free(self.details);
        allocator.free(self.sort_key);
        self.* = undefined;
    }

    pub fn eql(self: FormattedViolation, other: FormattedViolation) bool {
        return std.mem.eql(u8, self.heading, other.heading) and
            std.mem.eql(u8, self.details, other.details) and
            std.mem.eql(u8, self.sort_key, other.sort_key);
    }
};

pub const ViolationFactory = struct {
    /// Exhaustive conversion for the closed violation union. Adding a new union tag intentionally
    /// fails compilation here until its presentation is designed.
    pub fn fromViolation(
        allocator: Allocator,
        violation: Violation,
        rule_sentence: []const u8,
    ) FormatError!FormattedViolation {
        if (!containsNonWhitespace(rule_sentence)) return error.InvalidRuleSentence;
        return switch (violation) {
            .cycle => |value| formatCycle(allocator, value, rule_sentence),
            .custom_file => |value| formatCustomFile(allocator, value, rule_sentence),
            .empty_test => |value| formatEmptyTest(allocator, value, rule_sentence),
            .external_module_dependency => |value| formatExternalDependency(allocator, value, rule_sentence),
            .file_dependency => |value| formatFileDependency(allocator, value, rule_sentence),
            .matching => |value| formatMatching(allocator, value, rule_sentence),
        };
    }

    /// Deterministic fallback for opaque adapter or plugin inputs which are not values of the
    /// closed `Violation` union. Known union values always use `fromViolation` above.
    pub fn formatUnknown(
        allocator: Allocator,
        type_name: []const u8,
        summary: []const u8,
        rule_sentence: []const u8,
    ) FormatError!FormattedViolation {
        if (!containsNonWhitespace(rule_sentence)) return error.InvalidRuleSentence;
        const safe_type = if (containsNonWhitespace(type_name)) type_name else "unknown";
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
        output.writer.print("\nType: {s}\nDetails: {s}", .{ safe_type, summary }) catch
            return error.OutOfMemory;
        return finish(allocator, "Architecture violation", "unknown", safe_type, &output);
    }
};

fn formatEmptyTest(
    allocator: Allocator,
    value: assertion.EmptyTestViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.print("\nRule id: {s}\nReason: no files matched the rule scope", .{value.rule_id}) catch
        return error.OutOfMemory;
    if (value.scope.len == 0) {
        output.writer.writeAll("\nSelectors: unfiltered project scope") catch return error.OutOfMemory;
    } else {
        output.writer.writeAll("\nSelectors: ") catch return error.OutOfMemory;
        writeScope(&output.writer, value.scope) catch return error.OutOfMemory;
    }
    return finish(allocator, "Empty test violation", "empty_test", value.rule_id, &output);
}

fn formatMatching(
    allocator: Allocator,
    value: assertion.MatchingViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nFile: ") catch return error.OutOfMemory;
    writeLocatedPath(&output.writer, value.subject_path, null) catch return error.OutOfMemory;
    output.writer.print(
        "\nReason: {s} {s} {s} \"{f}\" ({s})",
        .{
            targetName(value.target),
            if (value.mood.isNegated()) "matches forbidden" else "does not match required",
            @tagName(value.syntax),
            std.zig.fmtString(value.expression),
            @tagName(value.matching_mode),
        },
    ) catch return error.OutOfMemory;
    return finish(allocator, "File pattern violation", "matching", value.subject_path, &output);
}

fn formatCustomFile(
    allocator: Allocator,
    value: assertion.CustomFileViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nFile: ") catch return error.OutOfMemory;
    writeLocatedPath(&output.writer, value.source_path, null) catch return error.OutOfMemory;
    output.writer.print(
        "\nPolicy: {s}\nReason: {s}\nSummary: {d} bytes, {d} non-blank lines, {d} imports",
        .{
            value.description,
            if (value.mood.isNegated()) "matched the forbidden predicate" else "failed the required predicate",
            value.source_byte_count,
            value.non_blank_line_count,
            value.imports.total,
        },
    ) catch return error.OutOfMemory;
    if (value.top_level_declarations) |counts| {
        output.writer.print(
            "\nDeclarations: total={d}, functions={d}, variables={d}, tests={d}, other={d}",
            .{ counts.total, counts.functions, counts.variables, counts.tests, counts.other },
        ) catch return error.OutOfMemory;
    } else {
        output.writer.writeAll("\nDeclarations: unavailable") catch return error.OutOfMemory;
    }
    return finish(allocator, "Custom file predicate violation", "custom_file", value.source_path, &output);
}

fn formatFileDependency(
    allocator: Allocator,
    value: assertion.FileDependencyViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nFile: ") catch return error.OutOfMemory;
    writePath(&output.writer, value.source_path) catch return error.OutOfMemory;
    output.writer.print(
        "\nReason: {s}\nImports:",
        .{if (value.mood.isNegated())
            "depends on forbidden internal files"
        else
            "depends on files outside the allowed target set"},
    ) catch return error.OutOfMemory;
    try writeProjectedEdges(allocator, &output.writer, value.items(), false);
    return finish(allocator, "File dependency violation", "file_dependency", value.source_path, &output);
}

fn formatExternalDependency(
    allocator: Allocator,
    value: assertion.ExternalModuleDependencyViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nFile: ") catch return error.OutOfMemory;
    writePath(&output.writer, value.source_path) catch return error.OutOfMemory;
    output.writer.print(
        "\nReason: {s}\nImports:",
        .{if (value.mood.isNegated())
            "depends on forbidden external modules"
        else
            "depends on external modules outside the allowlist"},
    ) catch return error.OutOfMemory;
    try writeProjectedEdges(allocator, &output.writer, value.items(), true);
    return finish(
        allocator,
        "External module dependency violation",
        "external_module_dependency",
        value.source_path,
        &output,
    );
}

fn formatCycle(
    allocator: Allocator,
    value: assertion.CycleViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    const edges = value.path.items();
    std.debug.assert(edges.len != 0);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nCycle: ") catch return error.OutOfMemory;
    writePath(&output.writer, edges[0].source_label) catch return error.OutOfMemory;
    for (edges) |edge| {
        output.writer.writeAll(" -> ") catch return error.OutOfMemory;
        writePath(&output.writer, edge.target_label) catch return error.OutOfMemory;
    }
    output.writer.writeAll("\nImports:") catch return error.OutOfMemory;
    for (edges) |edge| try writeProjectedEdge(&output.writer, edge, false);
    return finish(allocator, "Circular dependency detected", "cycle", edges[0].source_label, &output);
}

fn writeProjectedEdges(
    allocator: Allocator,
    writer: *std.Io.Writer,
    edges: []const projection.ProjectedEdge,
    include_classification: bool,
) Allocator.Error!void {
    const pointers = try allocator.alloc(*const projection.ProjectedEdge, edges.len);
    defer allocator.free(pointers);
    for (edges, 0..) |*edge, index| pointers[index] = edge;
    std.mem.sort(*const projection.ProjectedEdge, pointers, {}, struct {
        fn lessThan(_: void, left: *const projection.ProjectedEdge, right: *const projection.ProjectedEdge) bool {
            const source_order = std.mem.order(u8, left.source_label, right.source_label);
            if (source_order != .eq) return source_order == .lt;
            return std.mem.order(u8, left.target_label, right.target_label) == .lt;
        }
    }.lessThan);
    for (pointers) |edge| try writeProjectedEdge(writer, edge.*, include_classification);
}

fn writeProjectedEdge(
    writer: *std.Io.Writer,
    edge: projection.ProjectedEdge,
    include_classification: bool,
) Allocator.Error!void {
    for (edge.evidence()) |raw| {
        if (raw.locationItems().len == 0) {
            try writeRawEdge(writer, raw, null, include_classification);
            continue;
        }
        for (raw.locationItems()) |location| {
            try writeRawEdge(writer, raw, location, include_classification);
        }
    }
}

fn writeRawEdge(
    writer: *std.Io.Writer,
    edge: extraction.Edge,
    location: ?extraction.SourceLocation,
    include_classification: bool,
) Allocator.Error!void {
    writer.writeAll("\n  - ") catch return error.OutOfMemory;
    writeLocatedPath(writer, edge.source, location) catch return error.OutOfMemory;
    writer.writeAll(" -> ") catch return error.OutOfMemory;
    writePath(writer, edge.target) catch return error.OutOfMemory;
    writer.writeAll(" [") catch return error.OutOfMemory;
    writeImportKinds(writer, edge.import_kinds) catch return error.OutOfMemory;
    if (include_classification) {
        writer.writeAll("; class=") catch return error.OutOfMemory;
        writeEnumSet(writer, extraction.TargetClass, edge.target_classes) catch return error.OutOfMemory;
        writer.writeAll("; availability=") catch return error.OutOfMemory;
        writeEnumSet(writer, extraction.TargetAvailability, edge.target_availabilities) catch return error.OutOfMemory;
    }
    writer.writeByte(']') catch return error.OutOfMemory;
}

fn writeImportKinds(writer: *std.Io.Writer, kinds: extraction.ImportKinds) std.Io.Writer.Error!void {
    var wrote = false;
    inline for (std.meta.fields(extraction.ImportKind)) |field| {
        const kind: extraction.ImportKind = @enumFromInt(field.value);
        if (kinds.contains(kind)) {
            if (wrote) try writer.writeAll(", ");
            try writer.writeAll(field.name);
            wrote = true;
        }
    }
    if (!wrote) try writer.writeAll("none");
}

fn writeEnumSet(writer: *std.Io.Writer, comptime E: type, values: std.EnumSet(E)) std.Io.Writer.Error!void {
    var wrote = false;
    inline for (std.meta.fields(E)) |field| {
        const value: E = @enumFromInt(field.value);
        if (values.contains(value)) {
            if (wrote) try writer.writeByte('|');
            try writer.writeAll(field.name);
            wrote = true;
        }
    }
    if (!wrote) try writer.writeAll("none");
}

fn writeScope(writer: *std.Io.Writer, scope: []const assertion.ScopePattern) std.Io.Writer.Error!void {
    for (scope, 0..) |pattern, index| {
        if (index != 0) {
            try writer.writeAll(if (pattern.selector_index == scope[index - 1].selector_index) " OR " else " AND ");
        }
        try writer.print(
            "{s} {s} \"{f}\" ({s})",
            .{
                targetName(pattern.target),
                @tagName(pattern.syntax),
                std.zig.fmtString(pattern.expression),
                @tagName(pattern.matching),
            },
        );
    }
}

fn writeRule(writer: *std.Io.Writer, rule_sentence: []const u8) std.Io.Writer.Error!void {
    try writer.print("Rule: {s}", .{rule_sentence});
}

fn writeLocatedPath(
    writer: *std.Io.Writer,
    path: []const u8,
    location: ?extraction.SourceLocation,
) std.Io.Writer.Error!void {
    try writePath(writer, path);
    if (location) |value| try writer.print(":{d}:{d}", .{ value.line, value.column }) else try writer.writeAll(":1:1");
}

fn writePath(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    for (path) |byte| try writer.writeByte(if (byte == '\\') '/' else byte);
}

fn targetName(target: matching.PatternTarget) []const u8 {
    return switch (target) {
        .filename => "filename",
        .path_without_filename => "folder",
        .path => "path",
        .declaration_name => "declaration name",
    };
}

fn finish(
    allocator: Allocator,
    heading: []const u8,
    kind: []const u8,
    primary: []const u8,
    output: *std.Io.Writer.Allocating,
) Allocator.Error!FormattedViolation {
    const owned_heading = try allocator.dupe(u8, heading);
    errdefer allocator.free(owned_heading);
    const details = try output.toOwnedSlice();
    errdefer allocator.free(details);
    return .{
        .heading = owned_heading,
        .details = details,
        .sort_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind, primary }),
    };
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "matching formatter normalizes Windows paths and owns rule prose" {
    var evidence = try assertion.ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "*_service.zig" },
        .filename,
        .exact,
    );
    defer evidence.deinit(std.testing.allocator);
    var payload = try assertion.MatchingViolation.initFromEvidence(
        std.testing.allocator,
        "src\\orders\\order.zig",
        evidence,
        .should,
    );
    var violation = assertion.Violation{ .matching = payload };
    payload = undefined;
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "project files should have name *_service.zig",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("File pattern violation", formatted.heading);
    try std.testing.expectEqualStrings(
        "Rule: project files should have name *_service.zig\n" ++
            "File: src/orders/order.zig:1:1\n" ++
            "Reason: filename does not match required glob \"*_service.zig\" (exact)",
        formatted.details,
    );
    var cloned = try formatted.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expect(formatted.eql(cloned));
}

test "unknown formatter is explicit stable fallback for opaque inputs" {
    var formatted = try ViolationFactory.formatUnknown(
        std.testing.allocator,
        "plugin.future_violation",
        "opaque structured evidence",
        "project files should satisfy plugin policy",
    );
    defer formatted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Architecture violation", formatted.heading);
    try std.testing.expectEqualStrings(
        "Rule: project files should satisfy plugin policy\n" ++
            "Type: plugin.future_violation\n" ++
            "Details: opaque structured evidence",
        formatted.details,
    );
}

fn testProjectedEdge(
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
    external: bool,
    kind: extraction.ImportKind,
    class: extraction.TargetClass,
    availability: extraction.TargetAvailability,
    location: extraction.SourceLocation,
) !projection.ProjectedEdge {
    var raw = try extraction.Edge.initClassifiedWithLocations(
        allocator,
        source,
        target,
        external,
        extraction.ImportKinds.initOne(kind),
        class,
        availability,
        &.{location},
    );
    defer raw.deinit(allocator);
    return projection.ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
}

test "empty and custom file formatters produce stable golden details" {
    var scope = try assertion.ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "missing/**" },
        .path_without_filename,
        .exact,
    );
    defer scope.deinit(std.testing.allocator);
    var empty_payload = try assertion.EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_no_cycles",
        &.{scope},
        false,
    );
    var empty = assertion.Violation.fromEmptyTestMove(&empty_payload);
    defer empty.deinit(std.testing.allocator);
    var formatted_empty = try ViolationFactory.fromViolation(
        std.testing.allocator,
        empty,
        "project files in folder missing/** should have no cycles",
    );
    defer formatted_empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project files in folder missing/** should have no cycles\n" ++
            "Rule id: files.have_no_cycles\n" ++
            "Reason: no files matched the rule scope\n" ++
            "Selectors: folder glob \"missing/**\" (exact)",
        formatted_empty.details,
    );

    var custom_payload = try assertion.CustomFileViolation.init(
        std.testing.allocator,
        "src\\legacy.zig",
        "source stays small",
        42,
        3,
        .{},
        null,
        .should_not,
    );
    var custom = assertion.Violation.fromCustomFileMove(&custom_payload);
    defer custom.deinit(std.testing.allocator);
    var formatted_custom = try ViolationFactory.fromViolation(
        std.testing.allocator,
        custom,
        "project files should not adhere to source stays small",
    );
    defer formatted_custom.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project files should not adhere to source stays small\n" ++
            "File: src/legacy.zig:1:1\n" ++
            "Policy: source stays small\n" ++
            "Reason: matched the forbidden predicate\n" ++
            "Summary: 42 bytes, 3 non-blank lines, 0 imports\n" ++
            "Declarations: unavailable",
        formatted_custom.details,
    );
}

test "file and external dependencies include deterministic locations kinds and classification" {
    const location = extraction.SourceLocation{ .byte_offset = 12, .line = 2, .column = 5 };
    var internal_edge = try testProjectedEdge(
        std.testing.allocator,
        "src\\api.zig",
        "src\\db.zig",
        false,
        .zig_file,
        .internal,
        .resolved,
        location,
    );
    defer internal_edge.deinit(std.testing.allocator);
    var file_payload = try assertion.FileDependencyViolation.initClonePointers(
        std.testing.allocator,
        "src\\api.zig",
        &.{&internal_edge},
        .should_not,
    );
    var file_violation = assertion.Violation.fromFileDependencyMove(&file_payload);
    defer file_violation.deinit(std.testing.allocator);
    var formatted_file = try ViolationFactory.fromViolation(
        std.testing.allocator,
        file_violation,
        "API files should not depend on database files",
    );
    defer formatted_file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: API files should not depend on database files\n" ++
            "File: src/api.zig\n" ++
            "Reason: depends on forbidden internal files\n" ++
            "Imports:\n" ++
            "  - src/api.zig:2:5 -> src/db.zig [zig_file]",
        formatted_file.details,
    );

    var external_edge = try testProjectedEdge(
        std.testing.allocator,
        "src\\client.zig",
        "http_client",
        true,
        .named_module,
        .external,
        .resolved,
        location,
    );
    defer external_edge.deinit(std.testing.allocator);
    var external_payload = try assertion.ExternalModuleDependencyViolation.initClonePointers(
        std.testing.allocator,
        "src\\client.zig",
        &.{&external_edge},
        .should,
    );
    var external_violation = assertion.Violation.fromExternalModuleDependencyMove(&external_payload);
    defer external_violation.deinit(std.testing.allocator);
    var formatted_external = try ViolationFactory.fromViolation(
        std.testing.allocator,
        external_violation,
        "client files should depend on approved external modules",
    );
    defer formatted_external.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: client files should depend on approved external modules\n" ++
            "File: src/client.zig\n" ++
            "Reason: depends on external modules outside the allowlist\n" ++
            "Imports:\n" ++
            "  - src/client.zig:2:5 -> http_client [named_module; class=external; availability=resolved]",
        formatted_external.details,
    );
}

test "cycle formatter preserves traversal and renders each concrete import" {
    var forward = try testProjectedEdge(
        std.testing.allocator,
        "src\\a.zig",
        "src\\b.zig",
        false,
        .zig_file,
        .internal,
        .resolved,
        .{ .byte_offset = 3, .line = 1, .column = 4 },
    );
    defer forward.deinit(std.testing.allocator);
    var reverse = try testProjectedEdge(
        std.testing.allocator,
        "src\\b.zig",
        "src\\a.zig",
        false,
        .root_module,
        .internal,
        .resolved,
        .{ .byte_offset = 20, .line = 4, .column = 2 },
    );
    defer reverse.deinit(std.testing.allocator);
    var cycle = try projection.ProjectedCycle.initClone(std.testing.allocator, &.{ forward, reverse });
    defer cycle.deinit(std.testing.allocator);
    var cycle_payload = try assertion.CycleViolation.initClone(std.testing.allocator, cycle);
    var cycle_violation = assertion.Violation.fromCycleMove(&cycle_payload);
    defer cycle_violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        cycle_violation,
        "project files should have no cycles",
    );
    defer formatted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project files should have no cycles\n" ++
            "Cycle: src/a.zig -> src/b.zig -> src/a.zig\n" ++
            "Imports:\n" ++
            "  - src/a.zig:1:4 -> src/b.zig [zig_file]\n" ++
            "  - src/b.zig:4:2 -> src/a.zig [root_module]",
        formatted.details,
    );
}

fn exerciseFormattingAllocationFailures(allocator: Allocator) !void {
    var edge = try testProjectedEdge(
        allocator,
        "src/client.zig",
        "http_client",
        true,
        .named_module,
        .external,
        .resolved,
        .{ .byte_offset = 1, .line = 1, .column = 2 },
    );
    defer edge.deinit(allocator);
    var payload = try assertion.ExternalModuleDependencyViolation.initClonePointers(
        allocator,
        "src/client.zig",
        &.{&edge},
        .should_not,
    );
    var violation = assertion.Violation.fromExternalModuleDependencyMove(&payload);
    defer violation.deinit(allocator);
    var formatted = try ViolationFactory.fromViolation(
        allocator,
        violation,
        "client files should not depend on http_client",
    );
    defer formatted.deinit(allocator);
    var cloned = try formatted.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(formatted.eql(cloned));
}

test "violation formatting and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFormattingAllocationFailures,
        .{},
    );
}
