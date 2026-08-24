from __future__ import annotations

import json
import unittest
from unittest import mock

from scripts import release


class ReleaseContractTests(unittest.TestCase):
    def test_repository_release_metadata_is_complete(self) -> None:
        metadata = release.validate(release.ROOT, release.DEFAULT_METADATA, "v0.0.1")
        self.assertEqual("0.0.1", metadata.version)
        self.assertEqual("0.16.0", metadata.zig_version)
        self.assertTrue(metadata.archive_url.endswith("/v0.0.1.tar.gz"))
        self.assertTrue(metadata.package_hash.startswith("archunit-0.0.1-"))

    def test_external_consumer_templates_use_only_public_package_wiring(self) -> None:
        self.assertIn('b.dependency("archunit"', release.consumer_build_zig())
        self.assertIn('archunit.module("archunit")', release.consumer_build_zig())
        self.assertIn("haveNoCycles", release.architecture_test())
        self.assertNotIn(".path =", release.consumer_zon())

    def test_unknown_metadata_fields_fail_closed(self) -> None:
        source = json.loads(release.DEFAULT_METADATA.read_text(encoding="utf-8"))
        source["unexpected"] = True
        with mock.patch.object(release.Path, "read_text", return_value=json.dumps(source)):
            with self.assertRaisesRegex(ValueError, "fields differ"):
                release.load_metadata(release.DEFAULT_METADATA)


if __name__ == "__main__":
    unittest.main()
