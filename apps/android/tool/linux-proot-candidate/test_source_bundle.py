"""Offline source-lock tests; no network, extraction, or APK packaging."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOL / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load("source_bundle_test", "source-bundle.py")
assemble = load("assemble_source_test", "assemble-corresponding-source.py")


class SourceBundleTest(unittest.TestCase):
    def test_pinned_package_inventory_and_commits(self):
        packages, origins = source.installed_origins(source.ROOTFS)
        self.assertEqual(len(packages), 16)
        self.assertEqual(set(origins), source.EXPECTED_ORIGINS)
        self.assertTrue(all(len(item["commit"]) == 40 for item in origins.values()))

    def test_aports_tree_must_match_exact_revision(self):
        commit = "a" * 40
        parser = source.CgitTree("musl", commit)
        parser.feed(f'<a class="ls-blob" href="/aports/tree/main/musl/APKBUILD?id={commit}">x</a>')
        self.assertEqual(parser.names, {"APKBUILD"})
        with self.assertRaisesRegex(ValueError, "changed revision"):
            parser.feed('<a class="ls-blob" href="/aports/tree/main/musl/patch?id=' +
                        "b" * 40 + '">x</a>')

    def test_checksum_parser_rejects_path_and_duplicate(self):
        sha = "a" * 128
        self.assertEqual(source.sha512_entries(f'sha512sums="{sha}  source.tar.gz"'),
                         {"source.tar.gz": sha})
        with self.assertRaisesRegex(ValueError, "unsafe"):
            source.sha512_entries(f'sha512sums="{sha}  ../outside"')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            source.sha512_entries(f'sha512sums="{sha}  file\n{sha}  file"')

    def test_hash_rejects_symlink_and_wrong_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = folder / "source"
            original.write_bytes(b"sample")
            self.assertEqual(assemble.hash_file(original)[0], 6)
            with self.assertRaisesRegex(ValueError, "checksum differs"):
                assemble.member("source", original, (6, "0" * 64))
            linked = folder / "linked"
            try:
                linked.symlink_to(original)
            except OSError:
                return  # Windows Developer Mode can disallow symlink creation.
            with self.assertRaisesRegex(ValueError, "regular file"):
                assemble.hash_file(linked)

    def test_existing_full_lock_if_present(self):
        if not source.LOCK.exists():
            self.skipTest("source fetch not yet complete")
        lock = json.loads(source.LOCK.read_text(encoding="utf-8"))
        source.verify_lock(lock, source.ROOTFS, source.CACHE)

    def test_source_archive_excludes_rootfs_and_binaries(self):
        if not assemble.MANIFEST.exists():
            self.skipTest("source archive not yet assembled")
        manifest = json.loads(assemble.MANIFEST.read_text(encoding="utf-8"))
        names = {entry["archivePath"] for entry in manifest["entries"]}
        self.assertEqual(manifest["alpineOrigins"], 10)
        self.assertFalse(manifest["distributionApproved"])
        self.assertIn("upstream/proot/v5.1.107.96.zip", names)
        self.assertIn("upstream/talloc/talloc-2.4.3.tar.gz", names)
        self.assertIn("candidate/patch-proot-events.py", names)
        self.assertIn("candidate/generate-loader-info.ps1", names)
        self.assertTrue(all(not name.endswith((".apk", ".so")) and "rootfs" not in name.lower()
                            for name in names))


if __name__ == "__main__":
    unittest.main()
