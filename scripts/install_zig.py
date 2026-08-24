#!/usr/bin/env python3
"""Install a checksum-pinned Zig toolchain on supported CI runners."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile


SUPPORTED_VERSION = "0.16.0"


@dataclass(frozen=True)
class Artifact:
    url: str
    sha256: str
    size: int


ARTIFACTS = {
    "x86_64-linux": Artifact(
        "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz",
        "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
        55_478_392,
    ),
    "aarch64-linux": Artifact(
        "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz",
        "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
        51_211_944,
    ),
    "x86_64-macos": Artifact(
        "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz",
        "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
        57_396_836,
    ),
    "aarch64-macos": Artifact(
        "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz",
        "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
        52_238_004,
    ),
    "x86_64-windows": Artifact(
        "https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip",
        "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e",
        97_217_739,
    ),
    "aarch64-windows": Artifact(
        "https://ziglang.org/download/0.16.0/zig-aarch64-windows-0.16.0.zip",
        "aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef",
        93_109_828,
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    return parser.parse_args()


def platform_key(system: str, machine: str) -> str:
    operating_systems = {"linux": "linux", "darwin": "macos", "windows": "windows"}
    architectures = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "x64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }
    normalized_system = operating_systems.get(system.lower())
    normalized_machine = architectures.get(machine.lower())
    if normalized_system is None or normalized_machine is None:
        raise ValueError(f"unsupported Zig CI platform: {system}/{machine}")
    return f"{normalized_machine}-{normalized_system}"


def select_artifact(version: str, system: str, machine: str) -> Artifact:
    if version != SUPPORTED_VERSION:
        raise ValueError(f"unsupported Zig version {version}; expected {SUPPORTED_VERSION}")
    key = platform_key(system, machine)
    try:
        return ARTIFACTS[key]
    except KeyError as error:
        raise ValueError(f"no pinned Zig artifact for {key}") from error


def download(artifact: Artifact, destination: Path) -> None:
    request = urllib.request.Request(artifact.url, headers={"User-Agent": "ArchUnitZig-CI/1"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output, length=1024 * 1024)


def verify_download(archive: Path, artifact: Artifact) -> None:
    actual_size = archive.stat().st_size
    if actual_size != artifact.size:
        raise ValueError(f"Zig archive size mismatch: expected {artifact.size}, got {actual_size}")
    digest = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_hash = digest.hexdigest()
    if actual_hash != artifact.sha256:
        raise ValueError(f"Zig archive SHA-256 mismatch: expected {artifact.sha256}, got {actual_hash}")


def safe_member_path(root: Path, name: str) -> Path:
    candidate = (root / name).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise ValueError(f"archive member leaves extraction root: {name}") from error
    return candidate


def extract_archive(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                safe_member_path(destination, member.filename)
                file_type = (member.external_attr >> 16) & 0o170000
                if file_type == stat.S_IFLNK:
                    raise ValueError(f"symbolic links are not allowed in Zig archive: {member.filename}")
            bundle.extractall(destination)
        return

    with tarfile.open(archive, mode="r:xz") as bundle:
        for member in bundle.getmembers():
            safe_member_path(destination, member.name)
            if member.issym() or member.islnk() or member.isdev():
                raise ValueError(f"links and devices are not allowed in Zig archive: {member.name}")
        bundle.extractall(destination)


def zig_executable(directory: Path) -> Path:
    return directory / ("zig.exe" if platform.system().lower() == "windows" else "zig")


def verify_installed(directory: Path, version: str) -> None:
    executable = zig_executable(directory)
    if not executable.is_file():
        raise FileNotFoundError(f"installed Zig executable is missing: {executable}")
    actual = subprocess.check_output([str(executable), "version"], text=True).strip()
    if actual != version:
        raise ValueError(f"installed Zig version mismatch: expected {version}, got {actual}")


def add_to_github_path(directory: Path) -> None:
    github_path = os.environ.get("GITHUB_PATH")
    if github_path:
        with Path(github_path).open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"{directory}\n")
    else:
        print(f"Add this directory to PATH: {directory}")


def install(version: str, destination: Path) -> None:
    destination = destination.resolve()
    if destination.exists():
        verify_installed(destination, version)
        add_to_github_path(destination)
        print(f"Reusing checksum-pinned Zig {version} at {destination}")
        return

    artifact = select_artifact(version, platform.system(), platform.machine())
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="archunitzig-zig-", dir=destination.parent) as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / Path(artifact.url).name
        extracted = temporary_root / "extracted"
        print(f"Downloading {artifact.url}")
        download(artifact, archive)
        verify_download(archive, artifact)
        extract_archive(archive, extracted)
        roots = list(extracted.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise ValueError("Zig archive must contain exactly one root directory")
        shutil.move(str(roots[0]), str(destination))

    verify_installed(destination, version)
    add_to_github_path(destination)
    print(f"Installed checksum-pinned Zig {version} at {destination}")


def main() -> None:
    args = parse_args()
    install(args.version, args.destination)


if __name__ == "__main__":
    main()
