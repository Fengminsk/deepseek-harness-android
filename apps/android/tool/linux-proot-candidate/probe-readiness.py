"""Host-only identity/ELF preflight for the unpackaged ARM64 PRoot candidate.

This tool never invokes either ELF and never approves APK inclusion. It is an
input check for a later, separately reviewed debug device probe.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


PROOT = "libdsh_proot_candidate.so"
LOADER = "libdsh_proot_loader_candidate.so"
PINNED = {
    PROOT: ("c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f", 3),
    LOADER: ("c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf", 2),
}
EVENT_MARKERS = (b"DSH_TRACEE_EVENT_FD", b"DSH_TRACEE_RUN_ID", b"PROOT_LOADER")


def inspect_elf(data: bytes, expected_type: int) -> None:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or data[6] != 1:
        raise ValueError("Not a little-endian ELF64 image")
    e_type, machine, elf_version, entry, phoff = struct.unpack_from("<HHIQQ", data, 16)
    ehsize, phentsize, phnum = struct.unpack_from("<HHH", data, 52)
    if e_type != expected_type or machine != 183 or elf_version != 1:
        raise ValueError("Candidate ELF type, architecture or version changed")
    if ehsize != 64 or phentsize != 56 or phnum < 1 or phnum > 128:
        raise ValueError("Candidate program header shape changed")
    if phoff < 64 or phoff + phnum * phentsize > len(data):
        raise ValueError("Candidate program headers are outside the file")
    executable = False
    for index in range(phnum):
        header = struct.unpack_from("<IIQQQQQQ", data, phoff + index * phentsize)
        p_type, flags, file_offset, vaddr, _, file_size, mem_size, _ = header
        if file_offset + file_size > len(data) or file_size > mem_size:
            raise ValueError("Candidate program segment is invalid")
        if p_type == 1 and flags & 1 and vaddr <= entry < vaddr + mem_size:
            executable = True
    if not executable:
        raise ValueError("Candidate entry point is outside an executable LOAD segment")


def inspect_candidate(directory: Path, name: str, sha256: str, elf_type: int) -> dict[str, object]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Candidate directory is missing or redirected")
    path = directory / name
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Candidate file is missing or redirected: {name}")
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha256:
        raise ValueError(f"Candidate SHA-256 mismatch: {name}")
    inspect_elf(data, elf_type)
    if name == PROOT and not all(marker in data for marker in EVENT_MARKERS):
        raise ValueError("Candidate lacks the required event-pipe and loader protocol")
    return {"name": name, "bytes": len(data), "sha256": actual,
            "elfType": "ET_DYN" if elf_type == 3 else "ET_EXEC", "machine": "AArch64"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        binaries = [inspect_candidate(args.candidate_dir, name, *PINNED[name])
                    for name in (PROOT, LOADER)]
        print(json.dumps({"hostIdentityAndElfReady": True,
                          "distributionApproved": False,
                          "apkPayloadAllowed": False,
                          "deviceExecutionProven": False,
                          "binaries": binaries}, sort_keys=True))
        return 0
    except (OSError, ValueError) as failure:
        print(json.dumps({"hostIdentityAndElfReady": False,
                          "distributionApproved": False,
                          "apkPayloadAllowed": False,
                          "deviceExecutionProven": False,
                          "error": str(failure)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
