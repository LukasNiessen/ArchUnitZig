# ArchUnitZig

Architecture tests for Zig projects.

This repository is being bootstrapped as the Zig member of the
[ArchUnitTS](https://github.com/LukasNiessen/ArchUnitTS) family. The first usable release will turn a
Zig project into a dependency graph and let users express file, module, layer, slice, and graph rules
as ordinary `zig test` tests.

The public API is not ready yet. The implementation is tracked in the
[ordered roadmap](docs/roadmap.md), while [architecture](docs/architecture.md) and
[Zig-specific decisions](docs/decisions.md) explain how and why this port differs from its siblings.

## Slice example

The pre-release slice API turns one captured path segment into a component and checks direct
component dependencies inside an ordinary Zig test:

```zig
const std = @import("std");
const archunit = @import("archunit");

test "API does not reach into retrieval" {
    var project = try archunit.projectSlices(std.testing.allocator, .{});
    defer project.deinit();
    var features = try project.definedBy("src/features/(**)/");
    defer features.deinit();
    var mood = try features.shouldNot();
    defer mood.deinit();
    var rule = try mood.containDependency("api", "retrieval");
    defer rule.deinit(std.testing.allocator);

    try archunit.expectPasses(
        &rule,
        archunit.AssertionOptions.init(
            archunit.CheckOptions.init(std.testing.allocator, std.testing.io),
        ),
    );
}
```

Use `should().containDependency(...)` for a required edge. Explicit regex capture, file-suffix,
and identity projections are also available; their ownership and orphan/external semantics are
recorded in [D036](docs/decisions.md#d036--slices-are-single-label-projections-with-explicit-orphan-and-external-semantics).

A checked-in component diagram can be a strict architecture contract:

```zig
const diagram =
    "@startuml\n" ++
    "component [api] as A\n" ++
    "component [services] as S\n" ++
    "A --> S\n" ++
    "@enduml\n";

var positive = try features.should();
defer positive.deinit();
var internal_only = try positive.ignoringExternalSlices();
defer internal_only.deinit();
var diagram_rule = try internal_only.adhereToDiagram(diagram);
defer diagram_rule.deinit(std.testing.allocator);
```

`adhereToDiagramInFile(path)` reads only when checked. `features.toPlantUml(options)` and
`features.exportAsPlantUml(options, path)` generate the reverse diagram deterministically. The
supported subset and strict missing/extra relationship behavior are recorded in
[D037](docs/decisions.md#d037--plantuml-validation-is-a-strict-diagnosable-component-subset).

## Structural metrics example

Zig metrics describe files and declarations instead of pretending containers are classes. This
rule limits immediate function declarations in every declaration-bound container under `src`:

```zig
var project = try archunit.metrics(std.testing.allocator, .{});
defer project.deinit();
var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
defer source.deinit();
var containers = try source.forContainersMatching(&.{.{ .glob = "*" }});
defer containers.deinit();
var counts = try containers.count();
defer counts.deinit();
var functions = try counts.functions();
defer functions.deinit();
var rule = try functions.shouldBeBelowOrEqual(12);
defer rule.deinit(std.testing.allocator);

try archunit.expectPasses(
    &rule,
    archunit.AssertionOptions.init(
        archunit.CheckOptions.init(std.testing.allocator, std.testing.io),
    ),
);
```

The same count builder exposes declarations, tests, constants, variables, fields, each named Zig
container kind, anonymous container syntax, imports, statements, tokens, source lines, and
non-blank lines. File, declaration, and container measurements can also be consumed directly with
`measure`, `summary`, and `analyze`. The precise AST and identity contract is recorded in
[D038](docs/decisions.md#d038--structural-metrics-use-declaration-bound-container-identities).

## Development

ArchUnitZig currently targets Zig 0.16.0.

```console
zig build test
zig fmt --check build.zig build.zig.zon src
```

The test build uses Zig's leak-detecting testing allocator as implementation work lands. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the branch, commit, pull-request, and quality workflow.

## License

[MIT](LICENSE)
