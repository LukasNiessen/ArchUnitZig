# Changelog

All notable changes to ArchUnitZig are recorded here. Versions follow semantic versioning, while
the `0.x` series remains explicitly pre-stable.

## [0.0.1] - 2026-08-24

First honest preview release for Zig 0.16.0.

### Added

- AST-backed extraction for Zig, ZON, embedded resources, C imports, named modules, compilation
  roots, nested packages, and explicit/discovered workspaces.
- Fluent file, layer, slice, metric, dependency, cycle, and graph-report rules with structured
  violations and `std.testing` integration.
- Deterministic caches, `.archignore`, logging, six graph/report renderers, executable README
  examples, end-to-end fixtures, and architecture dogfood tests.
- Cross-platform Debug CI, ReleaseSafe documentation/formatting gates, hosted performance budgets,
  and an immutable tag-release workflow with a fresh external-consumer smoke test.

### Compatibility

- Supported toolchain: exactly Zig 0.16.0.
- License: MIT; the regex dependency retains its separately documented Apache-2.0/BSD notices.
- Public APIs are preview quality and may change before a stable release.

[0.0.1]: https://github.com/LukasNiessen/ArchUnitZig/releases/tag/v0.0.1
