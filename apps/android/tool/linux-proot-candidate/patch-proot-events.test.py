"""Host regression for the pinned PRoot event-feed source modification."""

from __future__ import annotations

import hashlib
import sys
import unittest
import uuid
import zipfile
from pathlib import Path

from importlib.machinery import SourceFileLoader


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
CACHE = REPO / ".cache" / "android" / "linux-proot-source"
ARCHIVE = CACHE / "v5.1.107.96.zip"
SHA = "75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa"
PATCH = SourceFileLoader("patch_proot_events", str(HERE / "patch-proot-events.py")).load_module()


class PinnedPatchTests(unittest.TestCase):
    def setUp(self) -> None:
        if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA:
            self.fail("Pinned PRoot archive is missing or modified")
        self.parent = (CACHE / f"patch-test-{uuid.uuid4()}").resolve()
        if self.parent.parent != CACHE.resolve():
            self.fail("Test path escaped source cache")
        self.extracted = self.parent / "verified-extracted"
        self.source = self.extracted / "proot-5.1.107.96"
        self.source.mkdir(parents=True)
        (self.extracted / ".dsh-proot-candidate-staging").write_text("test")
        with zipfile.ZipFile(ARCHIVE) as archive:
            for relative in PATCH.EXPECTED:
                output = self.source / "src" / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(archive.read(f"proot-5.1.107.96/src/{relative}"))

    def tearDown(self) -> None:
        import shutil
        if self.parent.parent != CACHE.resolve():
            self.fail("Refusing to delete a path outside the source cache")
        shutil.rmtree(self.parent)

    def test_exact_source_is_patched_once(self) -> None:
        PATCH.main(self.source)
        event = (self.source / "src" / "tracee" / "event.c").read_text()
        self.assertIn("dsh_events_reaped(pid, tracee_status);", event)
        self.assertIn("dsh_events_armed(tracee->pid, default_ptrace_options);", event)
        self.assertIn("dsh_events_drained(last_exit_status);", event)
        with self.assertRaisesRegex(ValueError, "digest changed"):
            PATCH.main(self.source)

    def test_tampering_fails_before_any_source_write(self) -> None:
        cli = self.source / "src" / "cli" / "cli.c"
        event = self.source / "src" / "tracee" / "event.c"
        before_event = event.read_bytes()
        cli.write_bytes(cli.read_bytes().replace(b"int main", b"int altered_main", 1))
        with self.assertRaisesRegex(ValueError, "digest changed"):
            PATCH.main(self.source)
        self.assertEqual(event.read_bytes(), before_event)


if __name__ == "__main__":
    unittest.main()
