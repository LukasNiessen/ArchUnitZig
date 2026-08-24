from __future__ import annotations

import json
import re
import unittest
from unittest import mock

from scripts import release


class ReleaseContractTests(unittest.TestCase):
    def test_repository_release_metadata_is_complete(self) -> None:
        metadata = release.validate(release.ROOT, release.DEFAULT_METADATA, "v0.0.1")
        self.assertEqual("0.0.1", metadata.version)
        self.assertEqual("0.16.0", metadata.zig_version)
        self.assertTrue(metadata.archive_url.endswith("/v0.0.1.tar.gz"))
        self.assertEqual(
            "archunit-0.0.1-7Czg3AZHGQBbO-ej1RHt71ZUIRQ9HxG6O6tHl4w0r8LN",
            metadata.package_hash,
        )

    def test_external_consumer_templates_use_only_public_package_wiring(self) -> None:
        self.assertIn('b.dependency("archunit"', release.consumer_build_zig())
        self.assertIn('archunit.module("archunit")', release.consumer_build_zig())
        self.assertIn("haveNoCycles", release.architecture_test())
        self.assertNotIn(".path =", release.consumer_zon())
        self.assertIn(".fingerprint = 0x1c2d2db2de015cbb", release.consumer_zon())

    def test_resolved_dependency_requires_the_reviewed_url_and_hash(self) -> None:
        metadata = release.load_metadata(release.DEFAULT_METADATA)
        resolved = f'.url = "{metadata.archive_url}",\n.hash = "{metadata.package_hash}",\n'
        release.validate_resolved_dependency(resolved, metadata)

        with self.assertRaisesRegex(ValueError, re.escape(metadata.package_hash)):
            release.validate_resolved_dependency(
                resolved.replace(metadata.package_hash, "stale"), metadata
            )

    def test_resolved_dependency_rejects_path_wiring(self) -> None:
        metadata = release.load_metadata(release.DEFAULT_METADATA)
        resolved = (
            f'.url = "{metadata.archive_url}",\n'
            f'.hash = "{metadata.package_hash}",\n'
            '.path = "../archunit",\n'
        )
        with self.assertRaisesRegex(ValueError, "path dependency"):
            release.validate_resolved_dependency(resolved, metadata)

    def test_unknown_metadata_fields_fail_closed(self) -> None:
        source = json.loads(release.DEFAULT_METADATA.read_text(encoding="utf-8"))
        source["unexpected"] = True
        with mock.patch.object(release.Path, "read_text", return_value=json.dumps(source)):
            with self.assertRaisesRegex(ValueError, "fields differ"):
                release.load_metadata(release.DEFAULT_METADATA)


if __name__ == "__main__":
    unittest.main()
