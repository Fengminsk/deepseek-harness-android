"""Boundary checks for the APK-to-host acceptance extractor."""

import hashlib
import io
import json
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("extract-apk-runtime.py")
ROOT = Path(__file__).resolve().parents[3] / ".cache" / "android"


class ExtractApkRuntimeTest(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True)
        self.allocation = tempfile.TemporaryDirectory(prefix="extract-apk-test-", dir=ROOT)
        self.addCleanup(self.allocation.cleanup)
        self.home = Path(self.allocation.name)

    def invoke(self, entries, digest=None):
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, "w", zipfile.ZIP_DEFLATED) as runtime:
            for name, content in entries:
                runtime.writestr(name, content)
        value = nested.getvalue()
        apk = self.home / "fixture.apk"
        with zipfile.ZipFile(apk, "w", zipfile.ZIP_STORED) as outer:
            outer.writestr("assets/runtime/runtime.zip", value)
            outer.writestr("assets/runtime/runtime.sha256", digest or hashlib.sha256(value).hexdigest())
        return subprocess.run([sys.executable, str(SCRIPT), str(apk), str(self.home / "unpacked")],
                              capture_output=True, text=True, check=False)

    def test_valid_carrier_is_extracted(self):
        result = self.invoke([("bootstrap.mjs", "export {};"), ("node_modules/example/index.mjs", "export {}; ")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["entries"], 2)
        self.assertTrue((self.home / "unpacked" / "bootstrap.mjs").is_file())
        self.assertFalse((self.home / "unpacked.zip").exists())

    def test_corrupt_runtime_digest_fails_before_extraction(self):
        result = self.invoke([("bootstrap.mjs", "export {}; ")], "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)

    def test_traversal_is_rejected(self):
        result = self.invoke([("bootstrap.mjs", "export {};"), ("../outside.txt", "bad")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe runtime entry", result.stderr)
        self.assertFalse((self.home / "outside.txt").exists())

    def test_case_folded_duplicate_is_rejected(self):
        result = self.invoke([("bootstrap.mjs", "export {};"), ("A.txt", "a"), ("a.txt", "b")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate runtime entry", result.stderr)

    def test_link_is_rejected(self):
        link = zipfile.ZipInfo("nested/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        result = self.invoke([("bootstrap.mjs", "export {};"), (link, "../../outside.txt")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains a link", result.stderr)


if __name__ == "__main__":
    unittest.main()
