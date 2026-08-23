# AGENTS.md

## What this repository is

ArchUnitZig is the Zig member of the ArchUnitEverything family. It turns a Zig project into a
directed dependency graph and lets users express architecture policy as ordinary `zig test` tests.
Someone familiar with ArchUnitTS, ArchUnitGo, ArchUnitNET, or ArchUnitRuby should recognise the
pipeline and vocabulary without this port fighting Zig's type, allocator, and build models.

This file is strong guidance, not a substitute for evidence. When Zig makes a sibling convention
awkward, choose the idiomatic Zig design, record the deviation in `docs/decisions.md`, and cover it
with tests.

## Mental model

```text
SOURCE -> EXTRACT -> PROJECT -> ASSERT -> REPORT
```

- Source locates the user's project.
- Extract is the only stage that understands Zig syntax, module roots, and the build model.
- Project reshapes raw edges into files, layers, slices, or report nodes.
- Assert is pure and returns data-only violations.
- Report formats violations or renders an artifact.

A rule is a value, not an action. Building a rule performs no filesystem I/O. Only a terminal check
or export may analyze a project.

## Intended layout

```text
src/
  common/
    assertion/     shared violation data
    error/         user and technical diagnostics
    extraction/    Zig dependency extraction
    fluentapi/     check options and type erasure
    matching/      glob/regex patterns and filters
    projection/    graph projection and cycles
    logging/       explicit per-check logging
  files/           file rules
  layers/          named-layer policy
  slices/          grouped component rules and diagrams
  metrics/         Zig structural and dependency metrics
  graph/           graph snapshots and renderers
  testing/         formatting and std.testing helpers
  root.zig         public facade; re-exports only
test/
  fixtures/        real Zig projects, clean and intentionally violating
```

Dependency rules:

1. `common` depends only on the Zig standard library and deliberately approved analysis/pattern
   backends.
2. Domain modules depend on `common`, never on one another.
3. `testing` depends on `common` and domain violation data, not fluent or extraction code.
4. `root.zig` may re-export everything; nothing inside the library imports `root.zig`.

Dogfood these boundaries as soon as the files API can express them.

## Data and ownership

- Stable identifiers are project-relative UTF-8 byte strings with `/` separators.
- Every source file receives an internal self-edge. Downstream edge projections drop self-edges by
  default; node projection uses them.
- Merge parallel `(source, target)` edges and union their import kinds.
- Public owned values expose `deinit(allocator)` or an equally explicit owner cleanup path.
- Never retain slices borrowed from a temporary source buffer, AST, iterator, or builder stage.
- No global allocator. Caches own allocator-backed copies and provide explicit invalidation/cleanup.
- Tests use `std.testing.allocator` unless a test specifically exercises another allocator.

Zig has no open base classes. A data-only tagged union is the expected violation representation;
formatting remains in `testing`. Type erasure may be used for heterogeneous `Checkable` collections,
but borrowed handle lifetimes must be obvious and tested.

## Zig extraction rules

- Use Zig 0.16's tokenizer/AST, not regex scanning, to find builtins and declarations.
- A relative `@import` target ending in `.zig` or `.zon` resolves from the importing file.
- Named module imports are supplied by compilation/build context. Do not guess them by appending a
  file extension.
- `std`, `builtin`, and `root` are distinct compiler-provided aliases. `root` is context-dependent
  when a repository has several compilation roots.
- Track `@embedFile` as a resource dependency and the still-supported but deprecated `@cImport` /
  `@cInclude` form as C dependency data.
- Do not execute an analyzed project's `build.zig` by default. It is arbitrary Zig code. Prefer
  explicit module maps and honest unresolved targets; any execution-based discovery must be opt-in.
- Syntax errors and unresolved targets never silently disappear. Surface a diagnostic or follow a
  documented strictness option.

## Fluent API

Read every chain aloud as an English architecture sentence:

```text
project files, in folder "src/api/**", should not depend on files in folder "src/db/**"
```

Entry, scope, mood, predicate, optional object, terminal. Mood is `should` or `shouldNot`, with no
synonyms. Builders are branchable and lazy in behavior. Zig may need an arena/context, errors at
builder stages, or type erasure to make ownership safe; the public syntax must be prototyped and
tested before it is multiplied across modules.

Zero subject matches produce `EmptyTestViolation` by default. `allow_empty_tests` is an explicit
opt-out. Multiple selector calls combine with AND; patterns in one selector combine with OR.

## Errors and violations

- A violation means the code disagrees with an architecture rule. Return it as data.
- A user error means the rule or options are invalid.
- A technical error means analysis, allocation, parsing policy, or I/O prevented the check.
- Violations carry facts, not final prose. Formatting and colour live in `testing`.

## Metrics

Zig has files, declarations, functions, containers, modules, and dependency graphs—not classes and
interfaces in the sibling sense. Implement counts and coupling metrics over Zig's actual model. Do
not publish LCOM, abstractness, or class/interface metrics under familiar names with unrelated math.

## Quality bar

- Pure algorithms: exhaustive unit tests over hand-built data.
- Extraction and each terminal: integration tests over real fixture projects.
- Parser/resolver: malformed, missing, escaped-root, multi-root, and cross-platform cases.
- Every owned value: leak checks and failure-path cleanup.
- Public diagnostics/renderers: deterministic golden tests and escaping tests.
- Architecture rules: at least one negative test proving each rule can fail.

Run `zig fmt --check build.zig build.zig.zon src` and `zig build test` before every pull request.
Follow `CONTRIBUTING.md`: one issue branch and one merged PR at a time, then return to clean `main`.
