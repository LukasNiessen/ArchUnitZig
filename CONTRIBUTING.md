# Contributing to ArchUnitZig

ArchUnitZig is built as a sequence of small, reviewable changes. The issue tracker is the backlog;
the repository documentation records decisions that outlive an individual ticket.

## Workflow

1. Start from an up-to-date `main`.
2. Take one issue and create one conventionally named branch:
   - `feature/<short-name>` for user-facing behavior;
   - `fix/<short-name>` for a correction;
   - `chore/<short-name>` for foundations, tooling, or maintenance;
   - `docs/<short-name>` for documentation-only work.
3. Commit coherent progress early. Use imperative conventional subjects such as
   `feat: add dependency edge model` or `test: cover parallel import merging`.
4. Run the proportional quality checks. At minimum:

   ```console
   zig fmt --check build.zig build.zig.zon src
   zig build test
   ```

   Documentation, public API, CI installer, and release-oriented changes also run:

   ```console
   python -B -m unittest scripts.test_install_zig scripts.test_release
   python -B scripts/check_ci.py
   python -B scripts/release.py validate
   zig build test -Doptimize=ReleaseSafe
   zig build docs -Doptimize=ReleaseSafe
   zig build benchmark-check
   ```

5. Open a pull request that links the issue, explains Zig-specific trade-offs, and records the exact
   checks run.
6. Review the complete diff and checks, merge the pull request, delete the branch, and return to a
   clean, updated `main` before starting the next issue.

Keep only one implementation pull request open at a time. The repository began empty, so its minimal
README/license root commit is the one unavoidable exception to the pull-request rule.

## Design expectations

- Follow the shared ArchUnit pipeline: source -> extract -> project -> assert -> report.
- Prefer Zig's language and standard-library tools for Zig analysis.
- Make allocation, ownership, borrowing, and `deinit` responsibilities explicit.
- Keep extraction language-specific and projection/assertion pure.
- Return architecture violations as values. Reserve errors for invalid API use, analysis failure,
  I/O, and allocation failure.
- Keep builders lazy: creating a rule must not touch the filesystem or execute `build.zig`.
- Preserve deterministic ordering in public results and rendered output.
- Write fast unit tests over hand-built graphs and at least one public-API integration test over a
  real fixture project for each rule.
- Use `std.testing.allocator` in tests so leaks fail the suite.

## Pull-request checklist

- [ ] The PR addresses one issue and contains no unrelated cleanup.
- [ ] Public names read as an architecture sentence.
- [ ] Ownership and error behavior are documented where they are not obvious.
- [ ] Unit, integration, negative, and leak tests are proportional to the change.
- [ ] `zig fmt --check` passes.
- [ ] `zig build test` passes.
- [ ] Documentation and decisions match the implementation.

## Continuous integration

CI runs Debug tests on current GitHub-hosted Linux, Windows, and macOS runners. A Linux quality job
checks formatting, reruns the complete suite in `ReleaseSafe`, builds the documentation site and Zig
API docs, runs the deterministic extraction benchmark, and uploads both validated artifacts. The
complete test command includes unit tests,
acceptance fixtures, executable dogfood rules, and the standalone README consumer.

Zig 0.16.0 is installed by `scripts/install_zig.py` from exact official archive URLs. The script
checks both the published byte size and SHA-256 before extraction. External workflow actions are
pinned to immutable commits with their reviewed release tag in a comment. CI deliberately uses no
dependency or build cache; adding one requires a key containing the Zig version and all relevant ZON
hash/lock inputs.

Version tags are annotated and never moved or reused. A `v*.*.*` tag runs the complete matrix again,
then a fresh external project fetches the public archive and verified Zig content hash before the
workflow publishes a GitHub prerelease. Workflow permissions default to `contents: read`; only the
final publish job receives `contents: write`. Enable GitHub immutable releases before pushing a tag.
If a release is defective, fix forward with a new version and let consumers restore a previously
reviewed URL/hash pair; never rewrite published evidence.

Performance work starts with evidence. `zig build benchmark` generates the versioned fixture and
writes `zig-out/benchmark/results.json`; `zig build benchmark-check` also enforces the broad budgets
recorded in `benchmark/budgets.json`. Update those budgets only from an uncached hosted Linux CI run,
and preserve substantial headroom for shared-runner variance. Correctness, deterministic graph
output, cache behavior, and zero live tracked allocations remain hard gates in both modes.
