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
