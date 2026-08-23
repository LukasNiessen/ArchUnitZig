# Zig-specific decisions

This log captures choices that should not be rediscovered in each implementation ticket. A decision
may be amended by a pull request that updates its rationale, consequences, tests, and affected issue.

## Accepted

### D001 — Target Zig 0.16.0 first

Zig changes quickly before 1.0. ArchUnitZig starts on the current stable 0.16.0 toolchain and records
that minimum in `build.zig.zon`. Compatibility with another release is a tested change, not an
unverified version range.

Consequence: CI and examples pin 0.16.x; public use of `std.zig.Ast`, `std.Io`, and `std.Build` is
reviewed on every Zig upgrade.

### D002 — Project-relative forward-slash identifiers

All internal identifiers are relative to the analyzed project/package root and use `/` separators.

Consequence: results are portable and readable, while workspace support must preserve a package
identity so two packages cannot collapse equal relative paths.

### D003 — Explicit allocation and ownership

Public work that allocates receives a caller-supplied allocator. Owned results expose an explicit
cleanup path; borrowed views document their lifetime. There is no hidden global allocator.

Consequence: fluent-builder ergonomics require a prototype before being repeated. Convenience never
justifies leaks, dangling AST/source slices, or undocumented transfer of ownership.

### D004 — Data-only tagged-union violations

Zig has no open base class. The planned representation is an owned tagged union whose variants carry
facts. The testing layer exhaustively formats them.

Consequence: adding a fundamentally new violation shape updates the union and formatter. This is a
deliberate Zig trade-off for exhaustive cleanup and safe value semantics.

### D005 — Safe build analysis by default

Analyzing a project does not execute its `build.zig`. Build scripts are arbitrary code and may have
side effects or network behavior.

Consequence: explicit compilation-root/module maps land first. Unresolved aliases remain visible.
Any build execution mode must be opt-in and clearly separated from static analysis.

### D006 — Preserve Zig dependency kinds

Relative `.zig`, `.zon`, named module, `std`, `builtin`, `root`, `@embedFile`, and C-header references
remain distinguishable even when the shared graph also exposes a simple `external` flag.

Consequence: file rules, external-module rules, graph styling, and diagnostics can state what they
actually include instead of conflating compiler, package, code, and resource dependencies.

### D007 — `std.testing` helpers are the native adapter

Zig has no custom matcher registration layer. A small `expectPasses`/`assertPasses` helper is the
idiomatic integration with ordinary `test` blocks.

Consequence: no framework detection or import-time registration. Formatting remains shared so a
future adapter does not duplicate messages.

### D008 — No invented class metrics

Metrics use Zig files, declarations, containers, functions, and dependency graphs. LCOM,
class/interface counts, abstractness, and main-sequence distance are omitted unless a separately
reviewed Zig definition preserves their meaning.

Consequence: initial metrics cover structural counts, afferent/efferent coupling, instability,
coupling factor, and custom callbacks.

## Open decisions

### D009 — Regex backend ([issue #4](https://github.com/LukasNiessen/ArchUnitZig/issues/4))

Zig 0.16 has no standard-library regex engine. Compare a pinned allocator-aware Zig implementation
with a small in-repository linear-time engine. Required properties are capture support, predictable
worst-case behavior, cross-compilation, clear ownership, compatible licensing, and immutable package
hashes.

### D010 — Fluent builder storage ([issue #19](https://github.com/LukasNiessen/ArchUnitZig/issues/19))

Sibling builders are immutable values. Zig needs safe storage for a runtime number of patterns while
keeping an English-like chain and explicit allocation failure. Prototype arena/context-backed stage
views, owned persistent nodes, and a deliberately mutable state machine before choosing.

### D011 — Type-erased checks ([issue #6](https://github.com/LukasNiessen/ArchUnitZig/issues/6))

One concrete rule can use compile-time duck typing. `assertAllPass` needs heterogeneous rules. Design
a borrowed vtable handle or an owned alternative whose lifetime and violation ownership are difficult
to misuse.
