# Implementation roadmap

The GitHub issues are the executable backlog. Work is intentionally sequential: one issue branch,
one pull request, one merge, then a clean `main` before the next issue.

## v0.1 — kernel and extraction

Foundation and Zig-specific risk first:

- [#1](https://github.com/LukasNiessen/ArchUnitZig/issues/1) project skeleton and decisions
- [#2–#7](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.1%20%E2%80%94%20kernel%20and%20extraction%22%20label%3A%22phase%3A%20foundation%22) graph, patterns, violations, checks, and errors
- [#8–#15](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.1%20%E2%80%94%20kernel%20and%20extraction%22%20label%3A%22phase%3A%20extraction%22) project discovery, syntax, resolution, classification, normalisation, cache, and ignores
- [#16–#18](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.1%20%E2%80%94%20kernel%20and%20extraction%22%20label%3A%22phase%3A%20projection%22) shared projections and cycle algorithms

Exit criterion: deterministic, leak-free dependency graphs for realistic Zig 0.16 fixture projects.

## v0.2 — architecture rules

- [#19–#26](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.2%20%E2%80%94%20architecture%20rules%22) fluent file rules and empty-test protection
- [#27–#28](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.2%20%E2%80%94%20architecture%20rules%22%20Testing) formatting and `std.testing` helpers
- [#29](https://github.com/LukasNiessen/ArchUnitZig/issues/29) named layers

Exit criterion: useful architecture tests can run inside an ordinary external `zig test` suite.

## v0.3 — reports and advanced rules

- [#30–#31](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.3%20%E2%80%94%20reports%20and%20advanced%20rules%22%20Graph) graph snapshots and six renderers
- [#32–#33](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.3%20%E2%80%94%20reports%20and%20advanced%20rules%22%20Slices) slices and PlantUML
- [#34–#38](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.3%20%E2%80%94%20reports%20and%20advanced%20rules%22%20Metrics) Zig-native metrics and reports
- [#39](https://github.com/LukasNiessen/ArchUnitZig/issues/39) selector exclusions
- [#40](https://github.com/LukasNiessen/ArchUnitZig/issues/40) explicit logging

Exit criterion: the core sibling product surface exists where it has an honest Zig meaning.

## v0.4 — release quality

- [#41](https://github.com/LukasNiessen/ArchUnitZig/issues/41) end-to-end fixture projects
- [#42](https://github.com/LukasNiessen/ArchUnitZig/issues/42) dogfooding
- [#43–#45](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.4%20%E2%80%94%20release%20quality%22%20documentation%20OR%20CI) user docs, Pages, and CI
- [#46](https://github.com/LukasNiessen/ArchUnitZig/issues/46) performance evidence
- [#47–#48](https://github.com/LukasNiessen/ArchUnitZig/issues?q=is%3Aissue%20milestone%3A%22v0.4%20%E2%80%94%20release%20quality%22%20Extraction) `.archignore` and workspace hardening
- [#49](https://github.com/LukasNiessen/ArchUnitZig/issues/49) tag and external-consumer verification

Exit criterion: a pinned release archive/hash installs in a fresh Zig 0.16 consumer and its complete
quality suite is green on supported operating systems.
