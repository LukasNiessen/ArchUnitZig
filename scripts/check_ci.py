#!/usr/bin/env python3
"""Fail when the reviewed CI security and coverage contract drifts."""

from __future__ import annotations

from pathlib import Path
import re

try:
    from scripts import install_zig
except ModuleNotFoundError:
    import install_zig


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def require(source: str, value: str, errors: list[str]) -> None:
    if value not in source:
        errors.append(f"missing CI contract: {value}")


def main() -> None:
    source = WORKFLOW.read_text(encoding="utf-8")
    errors: list[str] = []

    for value in (
        "push:",
        "pull_request:",
        "workflow_dispatch:",
        "contents: read",
        "cancel-in-progress: true",
        "fail-fast: false",
        "ubuntu-latest",
        "windows-latest",
        "macos-latest",
        "zig fmt --check",
        "zig build test -Doptimize=Debug",
        "zig build test -Doptimize=ReleaseSafe",
        "zig build docs -Doptimize=ReleaseSafe",
        "pages: write",
        "id-token: write",
        "needs:",
        "- compatibility",
        "- quality",
    ):
        require(source, value, errors)

    if "continue-on-error" in source:
        errors.append("supported CI gates must not use continue-on-error")
    if "actions/cache" in source:
        errors.append("CI caches require a separately reviewed Zig/ZON-complete key")

    action_pattern = re.compile(r"^\s*uses:\s*([^\s#]+)(?:\s+#\s*(\S+))?", re.MULTILINE)
    actions = action_pattern.findall(source)
    if not actions:
        errors.append("CI workflow has no external action references")
    for reference, comment in actions:
        if reference.startswith("./"):
            continue
        if not re.search(r"@[0-9a-f]{40}$", reference):
            errors.append(f"action is not pinned to an immutable commit: {reference}")
        if not re.fullmatch(r"v\d+(?:\.\d+){0,2}", comment):
            errors.append(f"action pin is missing its reviewed release tag comment: {reference}")

    version_match = re.search(r'^\s*ZIG_VERSION:\s*"([^"]+)"', source, re.MULTILINE)
    workflow_version = version_match.group(1) if version_match else None
    zon_source = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    zon_match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon_source)
    zon_version = zon_match.group(1) if zon_match else None
    if workflow_version != install_zig.SUPPORTED_VERSION or zon_version != install_zig.SUPPORTED_VERSION:
        errors.append(
            "workflow, installer, and build.zig.zon must pin the same exact supported Zig version"
        )

    if len(install_zig.ARTIFACTS) != 6:
        errors.append("installer must pin x86_64 and aarch64 artifacts for all three runner families")
    for key, artifact in install_zig.ARTIFACTS.items():
        if not artifact.url.startswith(f"https://ziglang.org/download/{install_zig.SUPPORTED_VERSION}/"):
            errors.append(f"toolchain URL is not an exact official release URL: {key}")
        if not re.fullmatch(r"[0-9a-f]{64}", artifact.sha256):
            errors.append(f"toolchain SHA-256 is malformed: {key}")
        if artifact.size <= 0:
            errors.append(f"toolchain byte size is missing: {key}")

    if errors:
        raise SystemExit("CI contract validation failed:\n- " + "\n- ".join(errors))
    print(f"CI contract validation passed: {len(actions)} immutable actions, 6 Zig archives")


if __name__ == "__main__":
    main()
