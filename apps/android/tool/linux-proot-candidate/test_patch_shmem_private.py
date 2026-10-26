"""Host-only checks for the pinned optional shared-memory source patch."""

import importlib.util
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


TOOL = Path(__file__).resolve().parent
REPO = TOOL.parents[3]
CACHE = REPO / ".cache/android"
SOURCE = CACHE / "linux-proot-source"
SPEC = importlib.util.spec_from_file_location("patch_shmem_private", TOOL / "patch-shmem-private.py")
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)


class PatchShmemPrivateTest(unittest.TestCase):
    def setUp(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="shmem-patch-test-", dir=CACHE)
        root = Path(self.temp.name).resolve()
        if not root.is_relative_to(CACHE.resolve()):
            raise AssertionError("temporary fixture escaped Android cache")
        self.proot = root / "proot"
        self.shmem = root / "shmem"
        proot_target = self.proot / "src/extension/sysvipc/sysvipc.c"
        proot_target.parent.mkdir(parents=True)
        shmem_target = self.shmem / "shmem.c"
        self.shmem.mkdir()
        with zipfile.ZipFile(SOURCE / "v5.1.107.96.zip") as archive:
            proot_target.write_bytes(archive.read(
                "proot-5.1.107.96/src/extension/sysvipc/sysvipc.c"))
        with tarfile.open(SOURCE / "libandroid-shmem-v0.7.tar.gz", "r:gz") as archive:
            member = archive.getmember("libandroid-shmem-0.7/shmem.c")
            shmem_target.write_bytes(archive.extractfile(member).read())

    def tearDown(self):
        self.temp.cleanup()

    def test_patch_is_opt_in_bounded_and_private(self):
        PATCH.patch(self.proot, self.shmem)
        proot = (self.proot / "src/extension/sysvipc/sysvipc.c").read_text()
        shmem = (self.shmem / "shmem.c").read_text()
        self.assertIn('getenv("DSH_ENABLE_LIBANDROID_SHMEM")', proot)
        self.assertIn('getenv("DSH_SHMEM_KEY_DIR")', proot)
        self.assertNotIn("ASHV_KEY_SYMLINK_PATH", shmem)
        self.assertIn("info.st_uid != geteuid()", shmem)
        self.assertIn("(info.st_mode & 077) != 0", shmem)
        self.assertIn("attempt < 32", shmem)
        with self.assertRaisesRegex(ValueError, "locked source changed"):
            PATCH.patch(self.proot, self.shmem)

    def test_tampering_rejected_before_either_file_changes(self):
        source = self.shmem / "shmem.c"
        source.write_bytes(source.read_bytes() + b"tamper\n")
        before = (self.proot / "src/extension/sysvipc/sysvipc.c").read_bytes()
        with self.assertRaisesRegex(ValueError, "locked source changed"):
            PATCH.patch(self.proot, self.shmem)
        self.assertEqual(before, (self.proot / "src/extension/sysvipc/sysvipc.c").read_bytes())


if __name__ == "__main__":
    unittest.main()
