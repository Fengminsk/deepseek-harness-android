import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "verify_distribution", Path(__file__).with_name("verify-distribution.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DistributionGateTest(unittest.TestCase):
    def test_known_guest_payload_fails_apk_gate(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/arm64-v8a/libdsh_proot_candidate.so", b"ELF")
            self.assertEqual(
                MODULE.guest_payload_entries(apk),
                ["lib/arm64-v8a/libdsh_proot_candidate.so"],
            )

    def test_unrelated_native_utility_is_allowed(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/arm64-v8a/libdsh_linux_utility.so", b"ELF")
            self.assertEqual(MODULE.guest_payload_entries(apk), [])

    def test_pinned_file_rejects_changed_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.zip"
            path.write_bytes(b"wrong")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                MODULE.verify_file(path, 5, "0" * 64)


if __name__ == "__main__":
    unittest.main()
