"""Host checks for the non-executing, non-packaging PRoot preflight."""

from __future__ import annotations

import hashlib
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path


MODULE = Path(__file__).with_name("probe-readiness.py")
SPEC = importlib.util.spec_from_file_location("probe_readiness", MODULE)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def fake_elf(kind: int, *, event_markers: bool = False) -> bytes:
    image = bytearray(512)
    image[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQ", image, 16, kind, 183, 1, 0x1000, 64)
    struct.pack_into("<HHH", image, 52, 64, 56, 1)
    struct.pack_into("<IIQQQQQQ", image, 64,
                     1, 5, 0, 0x1000, 0, 512, 512, 4096)
    if event_markers:
        markers = b"\0".join(probe.EVENT_MARKERS)
        image[128:128 + len(markers)] = markers
    return bytes(image)


class ProbeReadinessTest(unittest.TestCase):
    def test_elf_shape_and_executable_entry(self) -> None:
        probe.inspect_elf(fake_elf(3), 3)
        with self.assertRaisesRegex(ValueError, "type"):
            probe.inspect_elf(fake_elf(2), 3)
        broken = bytearray(fake_elf(3))
        struct.pack_into("<Q", broken, 24, 0x9000)
        with self.assertRaisesRegex(ValueError, "entry point"):
            probe.inspect_elf(bytes(broken), 3)
        broken = bytearray(fake_elf(3))
        struct.pack_into("<H", broken, 18, 62)
        with self.assertRaisesRegex(ValueError, "architecture"):
            probe.inspect_elf(bytes(broken), 3)

    def test_candidate_hash_event_protocol_and_redirects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = fake_elf(3, event_markers=True)
            file = root / probe.PROOT
            file.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            result = probe.inspect_candidate(root, probe.PROOT, digest, 3)
            self.assertEqual(result["sha256"], digest)
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                probe.inspect_candidate(root, probe.PROOT, "0" * 64, 3)
            bare = fake_elf(3)
            file.write_bytes(bare)
            with self.assertRaisesRegex(ValueError, "event-pipe"):
                probe.inspect_candidate(root, probe.PROOT,
                                        hashlib.sha256(bare).hexdigest(), 3)
            file.unlink()
            try:
                file.symlink_to(root / "elsewhere")
            except OSError:
                with self.assertRaisesRegex(ValueError, "missing or redirected"):
                    probe.inspect_candidate(root, probe.PROOT, digest, 3)
            else:
                with self.assertRaisesRegex(ValueError, "redirected"):
                    probe.inspect_candidate(root, probe.PROOT, digest, 3)


if __name__ == "__main__":
    unittest.main()
