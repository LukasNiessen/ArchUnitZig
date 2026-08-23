const std = @import("std");

const extraction = @import("../../common/extraction.zig");
const projection = @import("../../common/projection.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const ProjectedEdge = projection.ProjectedEdge;

pub const DiagramError = Allocator.Error || error{InvalidPlantUmlComponentName};
pub const RenderError = DiagramError;
pub const ExportError = RenderError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || error{
    InvalidOutputPath,
};

pub const PlantUmlDependency = struct {
    source: []u8,
    target: []u8,

    pub fn init(
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
    ) DiagramError!PlantUmlDependency {
        try validateComponentName(source);
        try validateComponentName(target);
        const owned_source = try allocator.dupe(u8, std.mem.trim(u8, source, whitespace));
        errdefer allocator.free(owned_source);
        return .{
            .source = owned_source,
            .target = try allocator.dupe(u8, std.mem.trim(u8, target, whitespace)),
        };
    }

    pub fn clone(self: PlantUmlDependency, allocator: Allocator) DiagramError!PlantUmlDependency {
        return init(allocator, self.source, self.target);
    }

    pub fn deinit(self: *PlantUmlDependency, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.target);
        self.* = undefined;
    }

    pub fn eql(self: PlantUmlDependency, other: PlantUmlDependency) bool {
        return std.mem.eql(u8, self.source, other.source) and
            std.mem.eql(u8, self.target, other.target);
    }
};

/// Owned canonical component names and allowed directed relationships.
pub const PlantUmlDiagram = struct {
    components: std.ArrayList([]u8) = .empty,
    dependencies: std.ArrayList(PlantUmlDependency) = .empty,

    pub fn deinit(self: *PlantUmlDiagram, allocator: Allocator) void {
        for (self.components.items) |name| allocator.free(name);
        self.components.deinit(allocator);
        for (self.dependencies.items) |*dependency| dependency.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const PlantUmlDiagram, allocator: Allocator) DiagramError!PlantUmlDiagram {
        var result: PlantUmlDiagram = .{};
        errdefer result.deinit(allocator);
        try result.components.ensureTotalCapacity(allocator, self.components.items.len);
        for (self.components.items) |name| {
            result.components.appendAssumeCapacity(try allocator.dupe(u8, name));
        }
        try result.dependencies.ensureTotalCapacity(allocator, self.dependencies.items.len);
        for (self.dependencies.items) |dependency| {
            result.dependencies.appendAssumeCapacity(try dependency.clone(allocator));
        }
        return result;
    }

    pub fn componentItems(self: *const PlantUmlDiagram) []const []const u8 {
        return self.components.items;
    }

    pub fn dependencyItems(self: *const PlantUmlDiagram) []const PlantUmlDependency {
        return self.dependencies.items;
    }

    pub fn containsComponent(self: *const PlantUmlDiagram, name: []const u8) bool {
        for (self.components.items) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return true;
        }
        return false;
    }

    pub fn allows(self: *const PlantUmlDiagram, source: []const u8, target: []const u8) bool {
        for (self.dependencies.items) |dependency| {
            if (std.mem.eql(u8, dependency.source, source) and
                std.mem.eql(u8, dependency.target, target)) return true;
        }
        return false;
    }

    fn appendComponent(self: *PlantUmlDiagram, allocator: Allocator, name: []const u8) DiagramError!void {
        try validateComponentName(name);
        const trimmed = std.mem.trim(u8, name, whitespace);
        if (self.containsComponent(trimmed)) return;
        const owned = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(owned);
        try self.components.append(allocator, owned);
    }

    fn appendDependency(
        self: *PlantUmlDiagram,
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
    ) DiagramError!void {
        if (self.allows(source, target)) return;
        var dependency = try PlantUmlDependency.init(allocator, source, target);
        self.dependencies.append(allocator, dependency) catch |failure| {
            dependency.deinit(allocator);
            return failure;
        };
    }

    fn sort(self: *PlantUmlDiagram) void {
        std.mem.sort([]u8, self.components.items, {}, stringBefore);
        std.mem.sort(PlantUmlDependency, self.dependencies.items, {}, dependencyBefore);
    }
};

pub const PlantUmlDiagnosticKind = enum {
    empty_diagram,
    missing_start,
    duplicate_start,
    missing_end,
    duplicate_end,
    statement_outside_diagram,
    malformed_component,
    duplicate_component,
    invalid_alias,
    duplicate_alias,
    malformed_relationship,
    unresolved_alias,
    unsupported_statement,
};

/// One-based parser location for the deliberately small supported PlantUML subset.
pub const PlantUmlDiagnostic = struct {
    kind: PlantUmlDiagnosticKind,
    line: usize,
    column: usize,

    pub fn message(self: PlantUmlDiagnostic) []const u8 {
        return switch (self.kind) {
            .empty_diagram => "diagram text is empty",
            .missing_start => "missing @startuml directive",
            .duplicate_start => "duplicate @startuml directive",
            .missing_end => "missing @enduml directive",
            .duplicate_end => "duplicate @enduml directive",
            .statement_outside_diagram => "statement appears outside @startuml/@enduml",
            .malformed_component => "malformed component declaration",
            .duplicate_component => "duplicate component declaration",
            .invalid_alias => "component alias is invalid",
            .duplicate_alias => "component alias is ambiguous",
            .malformed_relationship => "malformed directed relationship",
            .unresolved_alias => "relationship alias is not declared",
            .unsupported_statement => "statement is outside the supported PlantUML subset",
        };
    }
};

pub const PlantUmlParseResult = union(enum) {
    diagram: PlantUmlDiagram,
    invalid: PlantUmlDiagnostic,

    pub fn deinit(self: *PlantUmlParseResult, allocator: Allocator) void {
        switch (self.*) {
            .diagram => |*diagram| diagram.deinit(allocator),
            .invalid => {},
        }
        self.* = undefined;
    }
};

const RawComponent = struct {
    name: []const u8,
    alias: ?[]const u8,
    line: usize,
    column: usize,
};

const EndpointKind = enum { component, alias };

const RawEndpoint = struct {
    value: []const u8,
    kind: EndpointKind,
    line: usize,
    column: usize,
};

const RawDependency = struct {
    source: RawEndpoint,
    target: RawEndpoint,
};

const ParserState = enum { before, inside, after };

/// Parses only the component-diagram subset documented by issue #33. Invalid input is data with a
/// precise source location; allocation failure remains an error.
pub fn parsePlantUml(allocator: Allocator, text: []const u8) Allocator.Error!PlantUmlParseResult {
    if (std.mem.trim(u8, text, whitespace).len == 0) {
        return .{ .invalid = diagnostic(.empty_diagram, 1, 1) };
    }

    var components: std.ArrayList(RawComponent) = .empty;
    defer components.deinit(allocator);
    var dependencies: std.ArrayList(RawDependency) = .empty;
    defer dependencies.deinit(allocator);

    var state: ParserState = .before;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const uncommented = stripComment(raw_line);
        const line = std.mem.trim(u8, uncommented, whitespace);
        if (line.len == 0) continue;
        const statement_column = columnOf(raw_line, line);

        if (directive(line, "@startuml")) {
            if (state != .before) return .{ .invalid = diagnostic(.duplicate_start, line_number, statement_column) };
            state = .inside;
            continue;
        }
        if (directive(line, "@enduml")) {
            if (state == .after) return .{ .invalid = diagnostic(.duplicate_end, line_number, statement_column) };
            if (state == .before) return .{ .invalid = diagnostic(.statement_outside_diagram, line_number, statement_column) };
            if (!std.mem.eql(u8, line, "@enduml")) {
                return .{ .invalid = diagnostic(.unsupported_statement, line_number, statement_column) };
            }
            state = .after;
            continue;
        }
        if (state != .inside) {
            return .{ .invalid = diagnostic(.statement_outside_diagram, line_number, statement_column) };
        }

        if (startsKeyword(line, "component")) {
            const parsed = parseComponent(line, line_number, statement_column);
            switch (parsed) {
                .invalid => |value| return .{ .invalid = value },
                .value => |component| {
                    for (components.items) |earlier| {
                        if (std.mem.eql(u8, earlier.name, component.name)) {
                            return .{ .invalid = diagnostic(.duplicate_component, line_number, component.column) };
                        }
                        if (component.alias != null and earlier.alias != null and
                            std.mem.eql(u8, earlier.alias.?, component.alias.?))
                        {
                            return .{ .invalid = diagnostic(.duplicate_alias, line_number, aliasColumn(line, statement_column)) };
                        }
                    }
                    try components.append(allocator, component);
                },
            }
            continue;
        }

        if (std.mem.indexOf(u8, line, "->") != null or std.mem.indexOf(u8, line, "-->") != null or line[0] == '[') {
            const parsed = parseDependency(line, line_number, statement_column);
            switch (parsed) {
                .invalid => |value| return .{ .invalid = value },
                .value => |dependency| try dependencies.append(allocator, dependency),
            }
            continue;
        }
        return .{ .invalid = diagnostic(.unsupported_statement, line_number, statement_column) };
    }

    return switch (state) {
        .before => .{ .invalid = diagnostic(.missing_start, 1, 1) },
        .inside => .{ .invalid = diagnostic(.missing_end, line_number + 1, 1) },
        .after => buildDiagram(allocator, components.items, dependencies.items),
    };
}

const ComponentParse = union(enum) { value: RawComponent, invalid: PlantUmlDiagnostic };

fn parseComponent(
    line: []const u8,
    line_number: usize,
    statement_column: usize,
) ComponentParse {
    var index: usize = "component".len;
    if (index >= line.len or !std.ascii.isWhitespace(line[index])) {
        return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + index) };
    }
    skipWhitespace(line, &index);
    if (index >= line.len or line[index] != '[') {
        return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + index) };
    }
    const open = index;
    const closing_relative = std.mem.indexOfScalar(u8, line[open + 1 ..], ']') orelse
        return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + open) };
    const closing = open + 1 + closing_relative;
    const name = std.mem.trim(u8, line[open + 1 .. closing], whitespace);
    if (!validComponentName(name)) {
        return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + open + 1) };
    }
    index = closing + 1;
    skipWhitespace(line, &index);
    var component_alias: ?[]const u8 = null;
    if (index < line.len) {
        if (!startsKeyword(line[index..], "as")) {
            return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + index) };
        }
        index += 2;
        if (index >= line.len or !std.ascii.isWhitespace(line[index])) {
            return .{ .invalid = diagnostic(.invalid_alias, line_number, statement_column + index) };
        }
        skipWhitespace(line, &index);
        const alias_start = index;
        while (index < line.len and !std.ascii.isWhitespace(line[index])) index += 1;
        component_alias = line[alias_start..index];
        if (!validAlias(component_alias.?)) {
            return .{ .invalid = diagnostic(.invalid_alias, line_number, statement_column + alias_start) };
        }
        skipWhitespace(line, &index);
        if (index != line.len) {
            return .{ .invalid = diagnostic(.malformed_component, line_number, statement_column + index) };
        }
    }
    return .{ .value = .{
        .name = name,
        .alias = component_alias,
        .line = line_number,
        .column = statement_column + open + 1,
    } };
}

const DependencyParse = union(enum) { value: RawDependency, invalid: PlantUmlDiagnostic };
const EndpointParse = union(enum) {
    value: struct { endpoint: RawEndpoint, next: usize },
    invalid: PlantUmlDiagnostic,
};

fn parseDependency(
    line: []const u8,
    line_number: usize,
    statement_column: usize,
) DependencyParse {
    const source_result = parseEndpoint(line, 0, line_number, statement_column);
    const source = switch (source_result) {
        .invalid => |value| return .{ .invalid = value },
        .value => |value| value,
    };
    var index = source.next;
    skipWhitespace(line, &index);
    if (std.mem.startsWith(u8, line[index..], "-->")) {
        index += 3;
    } else if (std.mem.startsWith(u8, line[index..], "->")) {
        index += 2;
    } else {
        return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + index) };
    }
    skipWhitespace(line, &index);
    const target_result = parseEndpoint(line, index, line_number, statement_column);
    const target = switch (target_result) {
        .invalid => |value| return .{ .invalid = value },
        .value => |value| value,
    };
    index = target.next;
    skipWhitespace(line, &index);
    if (index != line.len) {
        return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + index) };
    }
    return .{ .value = .{ .source = source.endpoint, .target = target.endpoint } };
}

fn parseEndpoint(
    line: []const u8,
    start_index: usize,
    line_number: usize,
    statement_column: usize,
) EndpointParse {
    var index = start_index;
    if (index >= line.len) {
        return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + index) };
    }
    if (line[index] == '[') {
        const open = index;
        const closing_relative = std.mem.indexOfScalar(u8, line[open + 1 ..], ']') orelse
            return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + open) };
        const closing = open + 1 + closing_relative;
        const name = std.mem.trim(u8, line[open + 1 .. closing], whitespace);
        if (!validComponentName(name)) {
            return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + open + 1) };
        }
        return .{ .value = .{
            .endpoint = .{
                .value = name,
                .kind = .component,
                .line = line_number,
                .column = statement_column + open + 1,
            },
            .next = closing + 1,
        } };
    }
    const alias_start = index;
    while (index < line.len and !std.ascii.isWhitespace(line[index]) and line[index] != '-') index += 1;
    const value = line[alias_start..index];
    if (!validAlias(value)) {
        return .{ .invalid = diagnostic(.malformed_relationship, line_number, statement_column + alias_start) };
    }
    return .{ .value = .{
        .endpoint = .{
            .value = value,
            .kind = .alias,
            .line = line_number,
            .column = statement_column + alias_start,
        },
        .next = index,
    } };
}

fn buildDiagram(
    allocator: Allocator,
    declarations: []const RawComponent,
    raw_dependencies: []const RawDependency,
) Allocator.Error!PlantUmlParseResult {
    var diagram: PlantUmlDiagram = .{};
    errdefer diagram.deinit(allocator);
    for (declarations) |component| try appendParsedComponent(&diagram, allocator, component.name);

    for (raw_dependencies) |raw| {
        const source = resolveEndpoint(raw.source, declarations) orelse {
            diagram.deinit(allocator);
            return .{ .invalid = diagnostic(.unresolved_alias, raw.source.line, raw.source.column) };
        };
        const target = resolveEndpoint(raw.target, declarations) orelse {
            diagram.deinit(allocator);
            return .{ .invalid = diagnostic(.unresolved_alias, raw.target.line, raw.target.column) };
        };
        try appendParsedComponent(&diagram, allocator, source);
        try appendParsedComponent(&diagram, allocator, target);
        try appendParsedDependency(&diagram, allocator, source, target);
    }
    diagram.sort();
    return .{ .diagram = diagram };
}

fn appendParsedComponent(
    diagram: *PlantUmlDiagram,
    allocator: Allocator,
    name: []const u8,
) Allocator.Error!void {
    diagram.appendComponent(allocator, name) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPlantUmlComponentName => unreachable,
    };
}

fn appendParsedDependency(
    diagram: *PlantUmlDiagram,
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
) Allocator.Error!void {
    diagram.appendDependency(allocator, source, target) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPlantUmlComponentName => unreachable,
    };
}

fn resolveEndpoint(endpoint: RawEndpoint, declarations: []const RawComponent) ?[]const u8 {
    if (endpoint.kind == .component) return endpoint.value;
    for (declarations) |component| {
        if (component.alias) |value| {
            if (std.mem.eql(u8, value, endpoint.value)) return component.name;
        }
    }
    return null;
}

/// Renders canonical names and projected dependencies in stable lexical order.
pub fn renderPlantUml(
    allocator: Allocator,
    isolated_components: []const []const u8,
    edges: []const ProjectedEdge,
) RenderError![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (isolated_components) |name| try appendBorrowedNameUnique(allocator, &names, name);
    for (edges) |edge| {
        try appendBorrowedNameUnique(allocator, &names, edge.source_label);
        try appendBorrowedNameUnique(allocator, &names, edge.target_label);
    }
    std.mem.sort([]const u8, names.items, {}, borrowedStringBefore);
    const ordered_edges = try allocator.alloc(*const ProjectedEdge, edges.len);
    defer allocator.free(ordered_edges);
    for (edges, ordered_edges) |*edge, *destination| destination.* = edge;
    std.mem.sort(*const ProjectedEdge, ordered_edges, {}, projectedEdgeBefore);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    output.writer.writeAll("@startuml\n") catch return error.OutOfMemory;
    for (names.items) |name| {
        output.writer.print("  component [{s}]\n", .{name}) catch return error.OutOfMemory;
    }
    for (ordered_edges) |edge| {
        output.writer.print("  [{s}] --> [{s}]\n", .{ edge.source_label, edge.target_label }) catch
            return error.OutOfMemory;
    }
    output.writer.writeAll("@enduml\n") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn exportPlantUml(
    allocator: Allocator,
    io: Io,
    isolated_components: []const []const u8,
    edges: []const ProjectedEdge,
    output_path: []const u8,
) ExportError!void {
    if (std.mem.trim(u8, output_path, whitespace).len == 0) return error.InvalidOutputPath;
    const rendered = try renderPlantUml(allocator, isolated_components, edges);
    defer allocator.free(rendered);
    if (std.fs.path.dirname(output_path)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = rendered });
}

fn appendBorrowedNameUnique(
    allocator: Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) RenderError!void {
    try validateComponentName(name);
    const trimmed = std.mem.trim(u8, name, whitespace);
    for (names.items) |candidate| {
        if (std.mem.eql(u8, candidate, trimmed)) return;
    }
    try names.append(allocator, trimmed);
}

fn validateComponentName(name: []const u8) error{InvalidPlantUmlComponentName}!void {
    if (!validComponentName(std.mem.trim(u8, name, whitespace))) {
        return error.InvalidPlantUmlComponentName;
    }
}

fn validComponentName(name: []const u8) bool {
    return name.len != 0 and
        std.mem.indexOfScalar(u8, name, ']') == null and
        std.mem.indexOfScalar(u8, name, '\r') == null and
        std.mem.indexOfScalar(u8, name, '\n') == null;
}

fn validAlias(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.')) return false;
    }
    return true;
}

fn stripComment(line: []const u8) []const u8 {
    var first: usize = 0;
    while (first < line.len and std.ascii.isWhitespace(line[first])) first += 1;
    const trimmed = line[first..];
    if (std.mem.startsWith(u8, trimmed, "'") or std.mem.startsWith(u8, trimmed, "//")) return "";
    const comment = std.mem.indexOfScalar(u8, line, '\'') orelse return line;
    return line[0..comment];
}

fn directive(line: []const u8, keyword: []const u8) bool {
    return std.mem.eql(u8, line, keyword) or
        (line.len > keyword.len and std.mem.eql(u8, line[0..keyword.len], keyword) and
            std.ascii.isWhitespace(line[keyword.len]));
}

fn startsKeyword(line: []const u8, keyword: []const u8) bool {
    if (line.len < keyword.len or !std.ascii.eqlIgnoreCase(line[0..keyword.len], keyword)) return false;
    return line.len == keyword.len or std.ascii.isWhitespace(line[keyword.len]);
}

fn skipWhitespace(line: []const u8, index: *usize) void {
    while (index.* < line.len and std.ascii.isWhitespace(line[index.*])) index.* += 1;
}

fn columnOf(line: []const u8, slice: []const u8) usize {
    return @intFromPtr(slice.ptr) - @intFromPtr(line.ptr) + 1;
}

fn aliasColumn(line: []const u8, statement_column: usize) usize {
    const found = std.mem.indexOf(u8, line, " as ") orelse return statement_column;
    return statement_column + found + 4;
}

fn diagnostic(kind: PlantUmlDiagnosticKind, line: usize, column: usize) PlantUmlDiagnostic {
    return .{ .kind = kind, .line = line, .column = column };
}

fn stringBefore(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn borrowedStringBefore(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn dependencyBefore(_: void, left: PlantUmlDependency, right: PlantUmlDependency) bool {
    const source_order = std.mem.order(u8, left.source, right.source);
    if (source_order != .eq) return source_order == .lt;
    return std.mem.order(u8, left.target, right.target) == .lt;
}

fn projectedEdgeBefore(_: void, left: *const ProjectedEdge, right: *const ProjectedEdge) bool {
    const source_order = std.mem.order(u8, left.source_label, right.source_label);
    if (source_order != .eq) return source_order == .lt;
    return std.mem.order(u8, left.target_label, right.target_label) == .lt;
}

const whitespace = " \t\r\n\x0b\x0c";

fn parseSuccess(allocator: Allocator, text: []const u8) !PlantUmlDiagram {
    var parsed = try parsePlantUml(allocator, text);
    return switch (parsed) {
        .diagram => |diagram| blk: {
            parsed = undefined;
            break :blk diagram;
        },
        .invalid => error.TestExpectedEqual,
    };
}

test "parser resolves aliases both arrows comments directives and implicit components" {
    var diagram = try parseSuccess(std.testing.allocator, "' heading\n" ++
        "@startuml Architecture\n" ++
        "  component [API] as A\n" ++
        "  component [Services] as S\n" ++
        "  A -> S\n" ++
        "  [Services] --> [Models] ' implicit target\n" ++
        "  A -> S\n" ++
        "// footer comment\n" ++
        "@enduml\n");
    defer diagram.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), diagram.componentItems().len);
    try std.testing.expectEqualStrings("API", diagram.componentItems()[0]);
    try std.testing.expectEqualStrings("Models", diagram.componentItems()[1]);
    try std.testing.expectEqualStrings("Services", diagram.componentItems()[2]);
    try std.testing.expectEqual(@as(usize, 2), diagram.dependencyItems().len);
    try std.testing.expect(diagram.allows("API", "Services"));
    try std.testing.expect(diagram.allows("Services", "Models"));
}

test "parser returns precise diagnostics for duplicate malformed unresolved and structural input" {
    const cases = [_]struct {
        text: []const u8,
        kind: PlantUmlDiagnosticKind,
        line: usize,
    }{
        .{ .text = "", .kind = .empty_diagram, .line = 1 },
        .{ .text = "component [api]", .kind = .statement_outside_diagram, .line = 1 },
        .{ .text = "@startuml\ncomponent [api]\ncomponent [api]\n@enduml", .kind = .duplicate_component, .line = 3 },
        .{ .text = "@startuml\ncomponent [api] as A\ncomponent [services] as A\n@enduml", .kind = .duplicate_alias, .line = 3 },
        .{ .text = "@startuml\ncomponent api\n@enduml", .kind = .malformed_component, .line = 2 },
        .{ .text = "@startuml\nA -> [api]\n@enduml", .kind = .unresolved_alias, .line = 2 },
        .{ .text = "@startuml\n[api] -- [services]\n@enduml", .kind = .malformed_relationship, .line = 2 },
        .{ .text = "@startuml\nskinparam componentStyle rectangle\n@enduml", .kind = .unsupported_statement, .line = 2 },
        .{ .text = "@startuml\ncomponent [api]", .kind = .missing_end, .line = 3 },
    };
    for (cases) |case| {
        var parsed = try parsePlantUml(std.testing.allocator, case.text);
        defer parsed.deinit(std.testing.allocator);
        switch (parsed) {
            .diagram => return error.TestExpectedEqual,
            .invalid => |value| {
                try std.testing.expectEqual(case.kind, value.kind);
                try std.testing.expectEqual(case.line, value.line);
                try std.testing.expect(value.column >= 1);
                try std.testing.expect(value.message().len != 0);
            },
        }
    }
}

fn testProjectedEdge(
    allocator: Allocator,
    source_label: []const u8,
    target_label: []const u8,
    external: bool,
) !ProjectedEdge {
    var raw = try extraction.Edge.init(
        allocator,
        "src/source.zig",
        if (external) target_label else "src/target.zig",
        external,
        extraction.ImportKinds.initOne(if (external) .named_module else .zig_file),
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(
        allocator,
        .{ .source_label = source_label, .target_label = target_label },
        raw,
    );
}

test "renderer retains isolated and external components in stable round-trippable output" {
    var later = try testProjectedEdge(std.testing.allocator, "services", "models", false);
    defer later.deinit(std.testing.allocator);
    var earlier = try testProjectedEdge(std.testing.allocator, "api", "json", true);
    defer earlier.deinit(std.testing.allocator);
    const rendered = try renderPlantUml(
        std.testing.allocator,
        &.{"orphan"},
        &.{ later, earlier },
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "@startuml\n" ++
            "  component [api]\n" ++
            "  component [json]\n" ++
            "  component [models]\n" ++
            "  component [orphan]\n" ++
            "  component [services]\n" ++
            "  [api] --> [json]\n" ++
            "  [services] --> [models]\n" ++
            "@enduml\n",
        rendered,
    );
    var parsed = try parseSuccess(std.testing.allocator, rendered);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.allows("api", "json"));
    try std.testing.expect(parsed.containsComponent("orphan"));
}

test "renderer validates component names and export creates parent directories" {
    try std.testing.expectError(
        error.InvalidPlantUmlComponentName,
        renderPlantUml(std.testing.allocator, &.{"bad]name"}, &.{}),
    );
    try std.testing.expectError(
        error.InvalidOutputPath,
        exportPlantUml(std.testing.allocator, std.testing.io, &.{}, &.{}, " "),
    );
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "architecture.puml" });
    defer std.testing.allocator.free(path);
    try exportPlantUml(std.testing.allocator, std.testing.io, &.{"orphan"}, &.{}, path);
    const actual = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "component [orphan]") != null);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    const text = "@startuml\ncomponent [api] as A\ncomponent [services] as S\nA --> S\n@enduml";
    var parsed = try parsePlantUml(allocator, text);
    defer parsed.deinit(allocator);
    const diagram = switch (parsed) {
        .diagram => |*value| value,
        .invalid => return error.TestExpectedEqual,
    };
    var edge = try testProjectedEdge(allocator, "api", "services", false);
    defer edge.deinit(allocator);
    const rendered = try renderPlantUml(allocator, diagram.componentItems(), &.{edge});
    defer allocator.free(rendered);
}

test "PlantUML parsing and rendering clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
