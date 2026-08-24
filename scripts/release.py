#!/usr/bin/env python3
"""Validate release metadata and smoke-test a public Zig package archive."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_METADATA = ROOT / "release" / "v0.0.1.json"
REPOSITORY = "LukasNiessen/ArchUnitZig"


@dataclass(frozen=True)
class ReleaseMetadata:
    schema_version: int
    package_name: str
    version: str
    tag: str
    zig_version: str
    license: str
    archive_url: str
    package_hash: str
    release_notes: str


def load_metadata(path: Path) -> ReleaseMetadata:
    raw = json.loads(path.read_text(encoding="utf-8"))
    expected = set(ReleaseMetadata.__annotations__)
    if set(raw) != expected:
        raise ValueError(f"release metadata fields differ: expected {sorted(expected)}, got {sorted(raw)}")
    metadata = ReleaseMetadata(**raw)
    if metadata.schema_version != 1:
        raise ValueError("unsupported release metadata schema")
    return metadata


def require(source: str, value: str, errors: list[str], subject: str) -> None:
    if value not in source:
        errors.append(f"{subject} is missing {value!r}")


def validate(root: Path, metadata_path: Path, expected_tag: str | None = None) -> ReleaseMetadata:
    metadata = load_metadata(metadata_path)
    errors: list[str] = []
    expected_archive = f"https://github.com/{REPOSITORY}/archive/refs/tags/{metadata.tag}.tar.gz"
    if metadata.package_name != "archunit":
        errors.append("package_name must remain archunit")
    if metadata.tag != f"v{metadata.version}":
        errors.append("tag must be v followed by the package version")
    if expected_tag is not None and metadata.tag != expected_tag:
        errors.append(f"workflow tag {expected_tag!r} does not match metadata tag {metadata.tag!r}")
    if metadata.archive_url != expected_archive:
        errors.append("archive_url must pin the canonical GitHub tag archive")
    hash_pattern = rf"archunit-{re.escape(metadata.version)}-[A-Za-z0-9_-]{{40,}}"
    if re.fullmatch(hash_pattern, metadata.package_hash) is None:
        errors.append("package_hash is not a canonical Zig package hash for this name/version")
    if metadata.zig_version != "0.16.0":
        errors.append("v0.0.1 supports exactly Zig 0.16.0")
    if metadata.license != "MIT":
        errors.append("v0.0.1 package license must be MIT")

    zon = (root / "build.zig.zon").read_text(encoding="utf-8")
    for value in (
        ".name = .archunit",
        f'.version = "{metadata.version}"',
        f'.minimum_zig_version = "{metadata.zig_version}"',
        '"CHANGELOG.md"',
        '"LICENSE"',
        '"README.md"',
        '"THIRD_PARTY_LICENSES.md"',
    ):
        require(zon, value, errors, "build.zig.zon")

    readme = (root / "README.md").read_text(encoding="utf-8")
    require(readme, metadata.archive_url, errors, "README.md")
    require(readme, "release/v0.0.1.md", errors, "README.md")
    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    require(changelog, f"## [{metadata.version}]", errors, "CHANGELOG.md")
    require(changelog, metadata.zig_version, errors, "CHANGELOG.md")
    license_text = (root / "LICENSE").read_text(encoding="utf-8")
    require(license_text, "Permission is hereby granted", errors, "LICENSE")

    notes_path = root / metadata.release_notes
    if not notes_path.is_file():
        errors.append(f"release notes do not exist: {metadata.release_notes}")
    else:
        notes = notes_path.read_text(encoding="utf-8")
        for value in (
            metadata.archive_url,
            metadata.package_hash,
            metadata.zig_version,
            metadata.license,
            "## Limitations",
            "## Rollback",
        ):
            require(notes, value, errors, metadata.release_notes)

    workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    for value in (
        "contents: read",
        "contents: write",
        "cancel-in-progress: false",
        "ubuntu-latest",
        "windows-latest",
        "macos-latest",
        "zig build test -Doptimize=Debug",
        "zig build test -Doptimize=ReleaseSafe",
        "zig build docs -Doptimize=ReleaseSafe",
        "zig build benchmark-check",
        "scripts/release.py smoke",
        "gh release create",
        "--draft",
        "gh release edit",
        "--draft=false",
        "gh release verify",
    ):
        require(workflow, value, errors, ".github/workflows/release.yml")
    if "continue-on-error" in workflow:
        errors.append("release gates must not use continue-on-error")

    if errors:
        raise ValueError("release validation failed:\n- " + "\n- ".join(errors))
    return metadata


def consumer_build_zig() -> str:
    return """const std = @import(\"std\");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const archunit = b.dependency(\"archunit\", .{ .target = target, .optimize = optimize });

    const architecture = b.createModule(.{
        .root_source_file = b.path(\"test/architecture.zig\"),
        .target = target,
        .optimize = optimize,
    });
    architecture.addImport(\"archunit\", archunit.module(\"archunit\"));
    const tests = b.addTest(.{ .root_module = architecture });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(\".\"));

    const test_step = b.step(\"test\", \"Run external architecture test\");
    test_step.dependOn(&run_tests.step);
}
"""


def consumer_zon() -> str:
    return """.{
    .name = .archunit_release_consumer,
    .version = \"0.0.0\",
    .fingerprint = 0x1c2d2db2de015cbb,
    .minimum_zig_version = \"0.16.0\",
    .dependencies = .{},
    .paths = .{ \"build.zig\", \"build.zig.zon\", \"src\", \"test\" },
}
"""


def architecture_test() -> str:
    return """const std = @import(\"std\");
const archunit = @import(\"archunit\");

test \"fresh consumer architecture is acyclic\" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var production = try files.inPath(&.{.{ .glob = \"src/**/*.zig\" }});
    defer production.deinit();
    var should = try production.should();
    defer should.deinit();
    var rule = try should.haveNoCycles();
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
"""


def smoke(metadata: ReleaseMetadata, zig: str) -> None:
    with tempfile.TemporaryDirectory(prefix="archunitzig-release-consumer-") as raw_directory:
        directory = Path(raw_directory)
        (directory / "src" / "domain").mkdir(parents=True)
        (directory / "test").mkdir()
        (directory / "build.zig").write_text(consumer_build_zig(), encoding="utf-8")
        (directory / "build.zig.zon").write_text(consumer_zon(), encoding="utf-8")
        (directory / "src" / "main.zig").write_text(
            'const domain = @import("domain/root.zig");\npub fn main() void { domain.run(); }\n',
            encoding="utf-8",
        )
        (directory / "src" / "domain" / "root.zig").write_text(
            "pub fn run() void {}\n", encoding="utf-8"
        )
        (directory / "test" / "architecture.zig").write_text(architecture_test(), encoding="utf-8")

        subprocess.run(
            [zig, "fetch", "--save-exact=archunit", metadata.archive_url],
            cwd=directory,
            check=True,
            env=os.environ.copy(),
        )
        resolved_zon = (directory / "build.zig.zon").read_text(encoding="utf-8")
        if metadata.archive_url not in resolved_zon or metadata.package_hash not in resolved_zon:
            raise ValueError("zig fetch did not record the reviewed archive URL and package hash")
        if re.search(r"\.path\s*=", resolved_zon) is not None:
            raise ValueError("external consumer unexpectedly uses a path dependency")
        subprocess.run([zig, "build", "test"], cwd=directory, check=True, env=os.environ.copy())
        print(f"external consumer passed: {metadata.archive_url} ({metadata.package_hash})")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "smoke"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--tag")
    parser.add_argument("--zig", default="zig")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    metadata_path = args.metadata if args.metadata.is_absolute() else args.root / args.metadata
    metadata = validate(args.root.resolve(), metadata_path.resolve(), args.tag)
    if args.command == "smoke":
        smoke(metadata, args.zig)
    else:
        print(f"release metadata validated: {metadata.tag} ({metadata.package_hash})")


if __name__ == "__main__":
    main()
