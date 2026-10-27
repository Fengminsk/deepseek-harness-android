#!/usr/bin/env python3
"""Audit fixed Linux guest inputs and reject premature APK inclusion.

This is a technical source-lock/pre-distribution gate, not legal approval.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import tarfile
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[4]
SOURCES = (
    ("proot", "v5.1.107.96.zip", 489963,
     "75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa"),
    ("talloc", "talloc-2.4.3.tar.gz", 684092,
     "dc46c40b9f46bb34dd97fe41f548b0e8b247b77a918576733c528e83abd854dd"),
    ("libandroid-shmem", "libandroid-shmem-v0.7.tar.gz", 8891,
     "1e5ff8459bc0a8c229dd8a94b27d119987e09ef3414331c2b5ebfff20b98e867"),
)
ROOTFS = ("alpine-minirootfs-3.24.3-aarch64.tar.gz", 4029999,
          "4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50")


def verify_file(path: Path, expected_size: int, expected_sha256: str) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size != expected_size:
        raise ValueError(f"source is missing, linked or changed in size: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
        after = path.stat()
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
            info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns
        ):
            raise ValueError(f"source changed during verification: {path}")
    if digest.hexdigest() != expected_sha256:
        raise ValueError(f"source SHA-256 mismatch: {path}")


def require_archive_notice(path: Path, kind: str) -> None:
    if kind == "proot":
        with zipfile.ZipFile(path) as archive:
            data = archive.read("proot-5.1.107.96/COPYING")
        if b"GNU GENERAL PUBLIC LICENSE" not in data or b"Version 2" not in data:
            raise ValueError("PRoot COPYING text missing or changed")
    else:
        member_name = {
            "talloc": "talloc-2.4.3/LICENSE",
            "libandroid-shmem": "libandroid-shmem-0.7/LICENSE",
        }[kind]
        with tarfile.open(path, "r:gz") as archive:
            member = archive.getmember(member_name)
            if not member.isfile() or member.size > 65536:
                raise ValueError(f"license file missing or oversized: {member_name}")
            data = archive.extractfile(member).read()
        expected = (b"LESSER GENERAL PUBLIC LICENSE" if kind == "talloc"
                    else b"Redistribution and use in source and binary forms")
        if expected not in data:
            raise ValueError(f"license text missing or changed: {member_name}")


def rootfs_packages(path: Path) -> list[dict[str, str]]:
    with tarfile.open(path, "r:gz") as archive:
        member = archive.getmember("./lib/apk/db/installed")
        if not member.isfile() or member.size > 131072:
            raise ValueError("Alpine installed package database missing or oversized")
        raw = archive.extractfile(member).read().decode("utf-8")
    packages = []
    for block in re.split(r"\n\s*\n", raw):
        fields = {line[0]: line[2:] for line in block.splitlines()
                  if len(line) >= 2 and line[1] == ":"}
        if "P" in fields:
            if not all(key in fields for key in ("V", "L", "o")):
                raise ValueError(f"package version, license, or origin missing: {fields['P']}")
            packages.append({"name": fields["P"], "version": fields["V"],
                             "license": fields["L"], "origin": fields["o"]})
    if len(packages) != 16:
        raise ValueError(f"unexpected Alpine package inventory: {len(packages)}")
    return packages


def guest_payload_entries(apk: Path) -> list[str]:
    """Find known candidate filenames; absence is not proof against renamed payloads."""
    with zipfile.ZipFile(apk) as archive:
        names = [info.filename for info in archive.infolist() if not info.is_dir()]
    pattern = re.compile(
        r"(?:^|/)(?:libdsh_proot(?:_loader)?_candidate\.so|"
        r"libpocket_proot\.so|alpine-minirootfs[^/]*|"
        r"(?:lib)?proot(?:[-_.][^/]*)?\.so|rootfs\.tar(?:\.gz)?)$",
        re.IGNORECASE,
    )
    return sorted(name for name in names if pattern.search(name))


def audit(source_cache: Path, rootfs: Path, apk: Path | None) -> dict:
    verified = []
    for kind, filename, size, digest in SOURCES:
        path = source_cache / filename
        verify_file(path, size, digest)
        require_archive_notice(path, kind)
        verified.append({"name": kind, "sha256": digest, "bytes": size})
    verify_file(rootfs, ROOTFS[1], ROOTFS[2])
    packages = rootfs_packages(rootfs)
    payload = guest_payload_entries(apk) if apk is not None else []
    if payload:
        raise ValueError("known Linux guest payload entered APK before distribution review: "
                         + ", ".join(payload))
    return {"sourceLocksVerified": verified,
            "rootfs": {"sha256": ROOTFS[2], "bytes": ROOTFS[1], "packages": packages},
            "apkChecked": str(apk) if apk is not None else None,
            "knownGuestPayloadInApk": False if apk is not None else None,
            "distributionApproved": False,
            "reason": "Corresponding sources, notices, license compatibility and runtime gates remain open"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-cache", type=Path,
                        default=REPO / ".cache/android/linux-proot-source")
    parser.add_argument("--rootfs", type=Path,
                        default=REPO / ".cache/android/linux-rootfs-prototype" / ROOTFS[0])
    parser.add_argument("--apk", type=Path, help="check that no known guest payload entered an APK")
    args = parser.parse_args()
    try:
        print(json.dumps(audit(args.source_cache, args.rootfs, args.apk),
                         ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f"Linux distribution input check failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
