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
            .custom_metric => |value| formatCustomMetric(allocator, value, rule_sentence),
            .empty_test => |value| formatEmptyTest(allocator, value, rule_sentence),
            .external_module_dependency => |value| formatExternalDependency(allocator, value, rule_sentence),
            .file_dependency => |value| formatFileDependency(allocator, value, rule_sentence),
            .layer_dependency => |value| formatLayerDependency(allocator, value, rule_sentence),
            .matching => |value| formatMatching(allocator, value, rule_sentence),
            .metric => |value| formatMetric(allocator, value, rule_sentence),
            .metric_predicate => |value| formatMetricPredicate(allocator, value, rule_sentence),
            .slice_dependency => |value| formatSliceDependency(allocator, value, rule_sentence),
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

fn formatMetric(
    allocator: Allocator,
    value: assertion.MetricViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.print(
        "\nTarget: {s} ({s})\nMetric: {s}\nMeasured: ",
        .{ value.target_identifier, @tagName(value.target_kind), value.metric_name },
    ) catch return error.OutOfMemory;
    writeMetricValue(&output.writer, value.measured) catch return error.OutOfMemory;
    output.writer.print("\nExpected: {s} ", .{metricComparisonPhrase(value.comparison)}) catch
        return error.OutOfMemory;
    writeMetricValue(&output.writer, value.threshold) catch return error.OutOfMemory;
    return finish(allocator, "Metric threshold violation", "metric", value.target_identifier, &output);
}

fn formatMetricPredicate(
    allocator: Allocator,
    value: assertion.MetricPredicateViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.print(
        "\nTarget: {s} ({s})\nMetric: {s}\nMeasured: ",
        .{ value.target_identifier, @tagName(value.target_kind), value.metric_name },
    ) catch return error.OutOfMemory;
    writeMetricValue(&output.writer, value.measured) catch return error.OutOfMemory;
    output.writer.writeAll("\nExpected: satisfy the metric assertion") catch return error.OutOfMemory;
    return finish(allocator, "Metric predicate violation", "metric_predicate", value.target_identifier, &output);
}

fn formatCustomMetric(
    allocator: Allocator,
    value: assertion.CustomMetricViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.print(
        "\nTarget: {s} ({s})\nMetric: {s}\nDescription: {s}\nMeasured: ",
        .{
            value.target_identifier,
            @tagName(value.target_kind),
            value.metric_name,
            value.metric_description,
        },
    ) catch return error.OutOfMemory;
    writeMetricValue(&output.writer, value.measured) catch return error.OutOfMemory;
    switch (value.expectation) {
        .threshold => |expectation| {
            output.writer.print("\nExpected: {s} ", .{metricComparisonPhrase(expectation.comparison)}) catch
                return error.OutOfMemory;
            writeMetricValue(&output.writer, expectation.threshold) catch return error.OutOfMemory;
        },
        .predicate => output.writer.writeAll("\nExpected: satisfy the custom metric assertion") catch
            return error.OutOfMemory,
    }
    return finish(allocator, "Custom metric violation", "custom_metric", value.target_identifier, &output);
}

fn writeMetricValue(writer: *std.Io.Writer, value: assertion.MetricValue) std.Io.Writer.Error!void {
    switch (value) {
        .signed => |number| try writer.print("{d}", .{number}),
        .unsigned => |number| try writer.print("{d}", .{number}),
        .floating => |number| try writer.print("{d}", .{number}),
    }
}

fn metricComparisonPhrase(comparison: assertion.MetricComparison) []const u8 {
    return switch (comparison) {
        .below => "below",
        .above => "above",
        .equal => "equal to",
        .below_or_equal => "below or equal to",
        .above_or_equal => "above or equal to",
    };
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

fn formatLayerDependency(
    allocator: Allocator,
    value: assertion.LayerDependencyViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nDependency: ") catch return error.OutOfMemory;
    writePath(&output.writer, value.dependency.source_label) catch return error.OutOfMemory;
    output.writer.writeAll(" -> ") catch return error.OutOfMemory;
    writePath(&output.writer, value.dependency.target_label) catch return error.OutOfMemory;
    output.writer.writeAll("\nSource layer: ") catch return error.OutOfMemory;
    writeLayerAssignment(&output.writer, value.source_layer) catch return error.OutOfMemory;
    output.writer.writeAll("\nTarget layer: ") catch return error.OutOfMemory;
    writeLayerAssignment(&output.writer, value.target_layer) catch return error.OutOfMemory;
    switch (value.policy) {
        .may_only_depend_on_layers => output.writer.print(
            "\nReason: layer \"{s}\" may only depend on its declared allowlist",
            .{value.source_layer.?},
        ) catch return error.OutOfMemory,
        .may_not_depend_on_layers => output.writer.print(
            "\nReason: layer \"{s}\" may not depend on layer \"{s}\"",
            .{ value.source_layer.?, value.target_layer.? },
        ) catch return error.OutOfMemory,
        .unassigned_endpoint => output.writer.writeAll(
            "\nReason: strict layer assignment requires both internal endpoints to belong to a declared layer",
        ) catch return error.OutOfMemory,
    }
    output.writer.writeAll("\nImports:") catch return error.OutOfMemory;
    try writeProjectedEdge(allocator, &output.writer, value.dependency, false);
    return finish(
        allocator,
        "Layer dependency violation",
        "layer_dependency",
        value.dependency.source_label,
        &output,
    );
}

fn formatSliceDependency(
    allocator: Allocator,
    value: assertion.SliceDependencyViolation,
    rule_sentence: []const u8,
) FormatError!FormattedViolation {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeRule(&output.writer, rule_sentence) catch return error.OutOfMemory;
    output.writer.writeAll("\nDependency: ") catch return error.OutOfMemory;
    writePath(&output.writer, value.source_slice) catch return error.OutOfMemory;
    output.writer.writeAll(" -> ") catch return error.OutOfMemory;
    writePath(&output.writer, value.target_slice) catch return error.OutOfMemory;
    switch (value.rule) {
        .contain_dependency => if (value.mood.isNegated()) {
            output.writer.print(
                "\nReason: slice \"{s}\" may not depend on slice \"{s}\"\nImports:",
                .{ value.source_slice, value.target_slice },
            ) catch return error.OutOfMemory;
            const dependency = value.dependency.?;
            try writeProjectedEdge(
                allocator,
                &output.writer,
                dependency,
                dependency.evidence()[0].external,
            );
        } else {
            output.writer.writeAll("\nReason: required slice dependency is absent") catch
                return error.OutOfMemory;
        },
        .adhere_to_diagram => if (value.dependency) |dependency| {
            output.writer.writeAll("\nReason: actual slice dependency is absent from the PlantUML diagram\nImports:") catch
                return error.OutOfMemory;
            try writeProjectedEdge(
                allocator,
                &output.writer,
                dependency,
                dependency.evidence()[0].external,
            );
        } else {
            output.writer.writeAll("\nReason: PlantUML diagram dependency is absent from the project graph") catch
                return error.OutOfMemory;
        },
    }
    return finish(
        allocator,
        "Slice dependency violation",
        "slice_dependency",
        value.source_slice,
        &output,
    );
}

fn writeLayerAssignment(writer: *std.Io.Writer, value: ?[]const u8) std.Io.Writer.Error!void {
    try writer.writeAll(value orelse "<unassigned>");
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
    for (edges) |edge| try writeProjectedEdge(allocator, &output.writer, edge, false);
    return finish(allocator, "Circular dependency detected", "cycle", edges[0].source_label, &output);
}

fn writeProjectedEdges(
    allocator: Allocator,
    writer: *std.Io.Writer,
    edges: []const projection.ProjectedEdge,
    include_classification: bool,
) Allocator.Error!void {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    for (edges) |edge| try appendProjectedEdgeLines(allocator, &lines, edge, include_classification);
    std.mem.sort([]u8, lines.items, {}, lineLessThan);
    writeImportLines(writer, lines.items) catch return error.OutOfMemory;
}

fn writeProjectedEdge(
    allocator: Allocator,
    writer: *std.Io.Writer,
    edge: projection.ProjectedEdge,
    include_classification: bool,
) Allocator.Error!void {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    try appendProjectedEdgeLines(allocator, &lines, edge, include_classification);
    std.mem.sort([]u8, lines.items, {}, lineLessThan);
    writeImportLines(writer, lines.items) catch return error.OutOfMemory;
}

fn appendProjectedEdgeLines(
    allocator: Allocator,
    lines: *std.ArrayList([]u8),
    edge: projection.ProjectedEdge,
    include_classification: bool,
) Allocator.Error!void {
    for (edge.evidence()) |raw| {
        if (raw.locationItems().len == 0) {
            const line = try formatRawEdge(allocator, raw, null, include_classification);
            errdefer allocator.free(line);
            try lines.append(allocator, line);
            continue;
        }
        for (raw.locationItems()) |location| {
            const line = try formatRawEdge(allocator, raw, location, include_classification);
            errdefer allocator.free(line);
            try lines.append(allocator, line);
        }
    }
}

fn formatRawEdge(
    allocator: Allocator,
    edge: extraction.Edge,
    location: ?extraction.SourceLocation,
    include_classification: bool,
) Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeLocatedPath(&output.writer, edge.source, location) catch return error.OutOfMemory;
    output.writer.writeAll(" -> ") catch return error.OutOfMemory;
    writePath(&output.writer, edge.target) catch return error.OutOfMemory;
    output.writer.writeAll(" [") catch return error.OutOfMemory;
    writeImportKinds(&output.writer, edge.import_kinds) catch return error.OutOfMemory;
    if (include_classification) {
        output.writer.writeAll("; class=") catch return error.OutOfMemory;
        writeEnumSet(&output.writer, extraction.TargetClass, edge.target_classes) catch return error.OutOfMemory;
        output.writer.writeAll("; availability=") catch return error.OutOfMemory;
        writeEnumSet(&output.writer, extraction.TargetAvailability, edge.target_availabilities) catch
            return error.OutOfMemory;
    }
    output.writer.writeByte(']') catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeImportLines(writer: *std.Io.Writer, lines: []const []u8) std.Io.Writer.Error!void {
    for (lines) |line| try writer.print("\n  - {s}", .{line});
}

fn lineLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
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
            if (pattern.is_exclusion) {
                try writer.writeAll(" EXCEPT ");
            } else {
                try writer.writeAll(if (pattern.selector_index == scope[index - 1].selector_index and
                    !scope[index - 1].is_exclusion) " OR " else " AND ");
            }
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
    var key_output: std.Io.Writer.Allocating = .init(allocator);
    defer key_output.deinit();
    key_output.writer.print("{s}:", .{kind}) catch return error.OutOfMemory;
    writePath(&key_output.writer, primary) catch return error.OutOfMemory;
    return .{
        .heading = owned_heading,
        .details = details,
        .sort_key = try key_output.toOwnedSlice(),
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
    try std.testing.expectEqualStrings("matching:src/orders/order.zig", formatted.sort_key);
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

test "empty test formatter preserves exclusion evidence in selector order" {
    var positive = try assertion.ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "src/**" },
        .path,
        .exact,
    );
    defer positive.deinit(std.testing.allocator);
    var generated = try assertion.ScopePattern.initExclusion(
        std.testing.allocator,
        0,
        .{ .regex = "(^|/)generated/" },
        .path_without_filename,
        .exact,
    );
    defer generated.deinit(std.testing.allocator);
    var payload = try assertion.EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_no_cycles",
        &.{ positive, generated },
        false,
    );
    var violation = assertion.Violation.fromEmptyTestMove(&payload);
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "project files in path src/**, except folder regex (^|/)generated/, should have no cycles",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "Rule: project files in path src/**, except folder regex (^|/)generated/, should have no cycles\n" ++
            "Rule id: files.have_no_cycles\n" ++
            "Reason: no files matched the rule scope\n" ++
            "Selectors: path glob \"src/**\" (exact) EXCEPT folder regex \"(^|/)generated/\" (exact)",
        formatted.details,
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

test "dependency evidence is sorted independently of projected and raw insertion order" {
    var later_target = try testProjectedEdge(
        std.testing.allocator,
        "src\\api.zig",
        "src\\zeta.zig",
        false,
        .zig_file,
        .internal,
        .resolved,
        .{ .byte_offset = 30, .line = 4, .column = 2 },
    );
    defer later_target.deinit(std.testing.allocator);
    var earlier_target = try testProjectedEdge(
        std.testing.allocator,
        "src\\api.zig",
        "src\\alpha.zig",
        false,
        .root_module,
        .internal,
        .resolved,
        .{ .byte_offset = 20, .line = 3, .column = 7 },
    );
    defer earlier_target.deinit(std.testing.allocator);
    var earlier_raw = try extraction.Edge.initClassifiedWithLocations(
        std.testing.allocator,
        "src\\api.zig",
        "src\\alpha.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        .internal,
        .resolved,
        &.{.{ .byte_offset = 2, .line = 1, .column = 3 }},
    );
    defer earlier_raw.deinit(std.testing.allocator);
    try earlier_target.appendEvidence(std.testing.allocator, earlier_raw);

    var payload = try assertion.FileDependencyViolation.initClonePointers(
        std.testing.allocator,
        "src\\api.zig",
        &.{ &later_target, &earlier_target },
        .should_not,
    );
    var violation = assertion.Violation.fromFileDependencyMove(&payload);
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "API files should not depend on implementation files",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "Rule: API files should not depend on implementation files\n" ++
            "File: src/api.zig\n" ++
            "Reason: depends on forbidden internal files\n" ++
            "Imports:\n" ++
            "  - src/api.zig:1:3 -> src/alpha.zig [zig_file]\n" ++
            "  - src/api.zig:3:7 -> src/alpha.zig [root_module]\n" ++
            "  - src/api.zig:4:2 -> src/zeta.zig [zig_file]",
        formatted.details,
    );
}

test "layer dependency formatter retains assignments policy and import location" {
    var edge = try testProjectedEdge(
        std.testing.allocator,
        "src\\presentation\\api.zig",
        "src\\infrastructure\\db.zig",
        false,
        .zig_file,
        .internal,
        .resolved,
        .{ .byte_offset = 14, .line = 2, .column = 9 },
    );
    defer edge.deinit(std.testing.allocator);
    var payload = try assertion.LayerDependencyViolation.initClone(
        std.testing.allocator,
        edge,
        "presentation",
        "infrastructure",
        .may_not_depend_on_layers,
    );
    var violation = assertion.Violation.fromLayerDependencyMove(&payload);
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "project layers should satisfy named dependency policies",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Layer dependency violation", formatted.heading);
    try std.testing.expectEqualStrings(
        "Rule: project layers should satisfy named dependency policies\n" ++
            "Dependency: src/presentation/api.zig -> src/infrastructure/db.zig\n" ++
            "Source layer: presentation\n" ++
            "Target layer: infrastructure\n" ++
            "Reason: layer \"presentation\" may not depend on layer \"infrastructure\"\n" ++
            "Imports:\n" ++
            "  - src/presentation/api.zig:2:9 -> src/infrastructure/db.zig [zig_file]",
        formatted.details,
    );
}

test "layer dependency formatter explains sealed allowlists and strict unassigned endpoints" {
    var edge = try testProjectedEdge(
        std.testing.allocator,
        "src/application/service.zig",
        "src/support/logger.zig",
        false,
        .zig_file,
        .internal,
        .resolved,
        .{ .byte_offset = 44, .line = 2, .column = 16 },
    );
    defer edge.deinit(std.testing.allocator);

    var allow_payload = try assertion.LayerDependencyViolation.initClone(
        std.testing.allocator,
        edge,
        "application",
        "support",
        .may_only_depend_on_layers,
    );
    var allow_violation = assertion.Violation.fromLayerDependencyMove(&allow_payload);
    defer allow_violation.deinit(std.testing.allocator);
    var allow_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        allow_violation,
        "project layers should satisfy named dependency policies",
    );
    defer allow_formatted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        allow_formatted.details,
        "Reason: layer \"application\" may only depend on its declared allowlist",
    ) != null);

    var strict_payload = try assertion.LayerDependencyViolation.initClone(
        std.testing.allocator,
        edge,
        "application",
        null,
        .unassigned_endpoint,
    );
    var strict_violation = assertion.Violation.fromLayerDependencyMove(&strict_payload);
    defer strict_violation.deinit(std.testing.allocator);
    var strict_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        strict_violation,
        "project layers should satisfy named dependency policies",
    );
    defer strict_formatted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project layers should satisfy named dependency policies\n" ++
            "Dependency: src/application/service.zig -> src/support/logger.zig\n" ++
            "Source layer: application\n" ++
            "Target layer: <unassigned>\n" ++
            "Reason: strict layer assignment requires both internal endpoints to belong to a declared layer\n" ++
            "Imports:\n" ++
            "  - src/application/service.zig:2:16 -> src/support/logger.zig [zig_file]",
        strict_formatted.details,
    );
}

test "slice dependency formatter distinguishes forbidden evidence from a required missing edge" {
    var raw = try extraction.Edge.initClassifiedWithLocations(
        std.testing.allocator,
        "src\\features\\api\\root.zig",
        "src\\features\\retrieval\\repository.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        .internal,
        .resolved,
        &.{.{ .byte_offset = 25, .line = 2, .column = 21 }},
    );
    defer raw.deinit(std.testing.allocator);
    var edge = try projection.ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "api", .target_label = "retrieval" },
        raw,
    );
    defer edge.deinit(std.testing.allocator);

    var forbidden_payload = try assertion.SliceDependencyViolation.initClone(
        std.testing.allocator,
        "api",
        "retrieval",
        .should_not,
        edge,
    );
    var forbidden = assertion.Violation.fromSliceDependencyMove(&forbidden_payload);
    defer forbidden.deinit(std.testing.allocator);
    var forbidden_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        forbidden,
        "project slices should not contain dependency api -> retrieval",
    );
    defer forbidden_formatted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project slices should not contain dependency api -> retrieval\n" ++
            "Dependency: api -> retrieval\n" ++
            "Reason: slice \"api\" may not depend on slice \"retrieval\"\n" ++
            "Imports:\n" ++
            "  - src/features/api/root.zig:2:21 -> src/features/retrieval/repository.zig [zig_file]",
        forbidden_formatted.details,
    );

    var required_payload = try assertion.SliceDependencyViolation.initClone(
        std.testing.allocator,
        "models",
        "api",
        .should,
        null,
    );
    var required = assertion.Violation.fromSliceDependencyMove(&required_payload);
    defer required.deinit(std.testing.allocator);
    var required_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        required,
        "project slices should contain dependency models -> api",
    );
    defer required_formatted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Rule: project slices should contain dependency models -> api\n" ++
            "Dependency: models -> api\n" ++
            "Reason: required slice dependency is absent",
        required_formatted.details,
    );

    var unexpected_payload = try assertion.SliceDependencyViolation.initDiagramClone(
        std.testing.allocator,
        "api",
        "retrieval",
        edge,
    );
    var unexpected = assertion.Violation.fromSliceDependencyMove(&unexpected_payload);
    defer unexpected.deinit(std.testing.allocator);
    var unexpected_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        unexpected,
        "project slices should adhere to the PlantUML diagram",
    );
    defer unexpected_formatted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        unexpected_formatted.details,
        "Reason: actual slice dependency is absent from the PlantUML diagram\nImports:",
    ) != null);

    var missing_payload = try assertion.SliceDependencyViolation.initDiagramClone(
        std.testing.allocator,
        "services",
        "models",
        null,
    );
    var missing = assertion.Violation.fromSliceDependencyMove(&missing_payload);
    defer missing.deinit(std.testing.allocator);
    var missing_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        missing,
        "project slices should adhere to the PlantUML diagram",
    );
    defer missing_formatted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        missing_formatted.details,
        "Reason: PlantUML diagram dependency is absent from the project graph",
    ) != null);
}

test "metric formatter preserves target value comparison and threshold" {
    var payload = try assertion.MetricViolation.init(
        std.testing.allocator,
        "src/model.zig:Order",
        .container,
        "functions",
        .{ .unsigned = 7 },
        .below_or_equal,
        .{ .unsigned = 5 },
    );
    var violation = assertion.Violation.fromMetricMove(&payload);
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "selected Zig containers count functions should be below or equal to 5",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Metric threshold violation", formatted.heading);
    try std.testing.expectEqualStrings(
        "Rule: selected Zig containers count functions should be below or equal to 5\n" ++
            "Target: src/model.zig:Order (container)\n" ++
            "Metric: functions\n" ++
            "Measured: 7\n" ++
            "Expected: below or equal to 5",
        formatted.details,
    );
}

test "metric predicate formatter preserves target and measured value without fake threshold data" {
    var payload = try assertion.MetricPredicateViolation.init(
        std.testing.allocator,
        "src/model.zig:Order",
        .declaration,
        "tokens",
        .{ .signed = -3 },
    );
    var violation = assertion.Violation.fromMetricPredicateMove(&payload);
    defer violation.deinit(std.testing.allocator);
    var formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        violation,
        "selected Zig declarations count tokens should satisfy its metric assertion",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Metric predicate violation", formatted.heading);
    try std.testing.expectEqualStrings("metric_predicate:src/model.zig:Order", formatted.sort_key);
    try std.testing.expectEqualStrings(
        "Rule: selected Zig declarations count tokens should satisfy its metric assertion\n" ++
            "Target: src/model.zig:Order (declaration)\n" ++
            "Metric: tokens\n" ++
            "Measured: -3\n" ++
            "Expected: satisfy the metric assertion",
        formatted.details,
    );
}

test "custom metric formatter preserves the user description and expectation kind" {
    var threshold_payload = try assertion.CustomMetricViolation.initThreshold(
        std.testing.allocator,
        "domain",
        .module,
        "change_risk",
        "weighted incoming and outgoing dependency risk",
        .{ .floating = 0.75 },
        .below,
        .{ .floating = 0.5 },
    );
    var threshold_violation = assertion.Violation.fromCustomMetricMove(&threshold_payload);
    defer threshold_violation.deinit(std.testing.allocator);
    var threshold_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        threshold_violation,
        "projected Zig modules custom metric change_risk should be below 0.5",
    );
    defer threshold_formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Custom metric violation", threshold_formatted.heading);
    try std.testing.expectEqualStrings("custom_metric:domain", threshold_formatted.sort_key);
    try std.testing.expectEqualStrings(
        "Rule: projected Zig modules custom metric change_risk should be below 0.5\n" ++
            "Target: domain (module)\n" ++
            "Metric: change_risk\n" ++
            "Description: weighted incoming and outgoing dependency risk\n" ++
            "Measured: 0.75\n" ++
            "Expected: below 0.5",
        threshold_formatted.details,
    );

    var predicate_payload = try assertion.CustomMetricViolation.initPredicate(
        std.testing.allocator,
        "orders",
        .slice,
        "coherent_boundary",
        "slice-specific coherence policy",
        .{ .signed = -1 },
    );
    var predicate_violation = assertion.Violation.fromCustomMetricMove(&predicate_payload);
    defer predicate_violation.deinit(std.testing.allocator);
    var predicate_formatted = try ViolationFactory.fromViolation(
        std.testing.allocator,
        predicate_violation,
        "projected Zig slices custom metric coherent_boundary should satisfy its assertion",
    );
    defer predicate_formatted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(
        u8,
        predicate_formatted.details,
        "Measured: -1\nExpected: satisfy the custom metric assertion",
    ));
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
