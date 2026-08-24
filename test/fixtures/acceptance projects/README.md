# Acceptance project fixtures

These two offline Zig 0.16 packages are the external acceptance corpus for ArchUnitZig. The parent
directory deliberately contains a space. `test/acceptance.zig` analyzes each package with `.` as the
project locator and this directory as `CheckOptions.working_directory`, so path resolution is tested
without changing the process working directory.

## Twin contract

| Project | Reachable build | Architecture facts |
| --- | --- | --- |
| `clean` | passes | presentation → application → domain; infrastructure → domain |
| `violating` | passes | adds presentation → infrastructure and a two-file cycle |

Both packages define app, application, domain, infrastructure, and integration compilation roots.
Their build modules use project aliases plus a source-controlled package-style `vendor_pkg` module;
there are no package URLs or network dependencies. The source corpus also covers `std`, `builtin`,
`root`, `.zig` and `.zon` imports, `@embedFile`, deprecated `@cImport`, test/comptime imports, and an
orphan file.

`testdata/malformed/broken.zig` is intentionally analyzed but never reachable from a build root.
Normal architecture checks exclude `testdata/**`; a dedicated acceptance test analyzes the full
tree and verifies exact strict failure plus permissive ownership. The violating cycle is likewise
valid source that is not reachable from a build root. This separation lets the fixtures prove both
ordinary Zig build health and architecture-tool behavior for code a compiler cannot or should not
link into the passing application.

## Reproduction

The repository's `zig build test` runs the clean build, then the violating build, then the external
acceptance suite. It supplies the same repository-local `.zig-cache/acceptance-global` through both
`--global-cache-dir` and `ZIG_GLOBAL_CACHE_DIR`; the environment form is also required by Zig's
deprecated C-import work. Fixture-local `.zig-cache` directories and the shared cache are ignored
build output, never test input.

When running a fixture directly, set `ZIG_GLOBAL_CACHE_DIR` to a writable isolated directory and
pass that path to `--global-cache-dir`. No developer-global cache or network access is required.
