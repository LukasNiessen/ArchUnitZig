#!/usr/bin/env python3

from __future__ import annotations

from contextlib import contextmanager
from io import BytesIO
from pathlib import Path
import shutil
import tarfile
import unittest
import uuid
import zipfile

from scripts import install_zig


@contextmanager
def scratch_directory():
    root = Path(".zig-cache") / "python-tests" / uuid.uuid4().hex
    root.mkdir(parents=True)
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


class InstallZigTests(unittest.TestCase):
    def test_supported_runner_platforms_have_pinned_artifacts(self) -> None:
        cases = {
            ("Linux", "AMD64"): "x86_64-linux",
            ("Linux", "aarch64"): "aarch64-linux",
            ("Darwin", "x86_64"): "x86_64-macos",
            ("Darwin", "arm64"): "aarch64-macos",
            ("Windows", "x64"): "x86_64-windows",
            ("Windows", "ARM64"): "aarch64-windows",
        }
        for inputs, expected in cases.items():
            with self.subTest(inputs=inputs):
                self.assertEqual(expected, install_zig.platform_key(*inputs))
                artifact = install_zig.select_artifact(install_zig.SUPPORTED_VERSION, *inputs)
                self.assertRegex(artifact.sha256, r"^[0-9a-f]{64}$")
                self.assertIn("/0.16.0/", artifact.url)
                self.assertGreater(artifact.size, 50_000_000)

    def test_unknown_version_and_platform_fail_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported Zig version"):
            install_zig.select_artifact("master", "Linux", "x86_64")
        with self.assertRaisesRegex(ValueError, "unsupported Zig CI platform"):
            install_zig.platform_key("Plan9", "mips")

    def test_size_and_checksum_are_both_verified(self) -> None:
        with scratch_directory() as temporary:
            archive = temporary / "zig.zip"
            archive.write_bytes(b"known bytes")
            valid = install_zig.Artifact(
                "https://example.invalid/zig.zip",
                "25cb6d61356e5cada4238d160f3a77522e550e27a69758da40cd281c7ef2c8dc",
                11,
            )
            install_zig.verify_download(archive, valid)
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                install_zig.verify_download(archive, install_zig.Artifact(valid.url, valid.sha256, 12))
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                install_zig.verify_download(archive, install_zig.Artifact(valid.url, "0" * 64, 11))

    def test_zip_and_tar_extraction_reject_parent_traversal(self) -> None:
        with scratch_directory() as root:
            zip_path = root / "bad.zip"
            with zipfile.ZipFile(zip_path, mode="w") as bundle:
                bundle.writestr("../escape", "bad")
            with self.assertRaisesRegex(ValueError, "leaves extraction root"):
                install_zig.extract_archive(zip_path, root / "zip-output")

            tar_path = root / "bad.tar.xz"
            with tarfile.open(tar_path, mode="w:xz") as bundle:
                payload = b"bad"
                member = tarfile.TarInfo("../escape")
                member.size = len(payload)
                bundle.addfile(member, BytesIO(payload))
            with self.assertRaisesRegex(ValueError, "leaves extraction root"):
                install_zig.extract_archive(tar_path, root / "tar-output")

    def test_safe_archives_extract_under_the_requested_root(self) -> None:
        with scratch_directory() as root:
            zip_path = root / "safe.zip"
            with zipfile.ZipFile(zip_path, mode="w") as bundle:
                bundle.writestr("zig-root/zig.exe", "binary")
            output = root / "output"
            install_zig.extract_archive(zip_path, output)
            self.assertEqual("binary", (output / "zig-root" / "zig.exe").read_text())


if __name__ == "__main__":
    unittest.main()
