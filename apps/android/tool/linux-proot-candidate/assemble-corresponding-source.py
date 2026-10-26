#!/usr/bin/env python3
"""Assemble and verify the fixed Linux guest candidate's source evidence.

The output is a source-only engineering artifact. It is not distribution
approval, a legal conclusion, an Alpine binary package, or an APK input.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import stat
import tempfile
import zipfile
from pathlib import Path


TOOL = Path(__file__).resolve().parent
REPO = TOOL.parents[3]
CACHE = REPO / ".cache/android/linux-guest-source-bundle"
SOURCE_CACHE = REPO / ".cache/android/linux-proot-source"
LOCK = TOOL / "SOURCE-BUNDLE-LOCK.json"
MANIFEST = TOOL / "CORRESPONDING-SOURCE-MANIFEST.json"
ARCHIVE = CACHE / "corresponding-source.zip"
ROOTFS_SHA256 = "4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50"

PINNED_INPUTS = (
    ("proot", "v5.1.107.96.zip", 489963,
     "75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa",
     "https://github.com/termux/proot/archive/v5.1.107.96.zip"),
    ("talloc", "talloc-2.4.3.tar.gz", 684092,
     "dc46c40b9f46bb34dd97fe41f548b0e8b247b77a918576733c528e83abd854dd",
     "https://ftp.samba.org/pub/talloc/talloc-2.4.3.tar.gz"),
    ("libandroid-shmem", "libandroid-shmem-v0.7.tar.gz", 8891,
     "1e5ff8459bc0a8c229dd8a94b27d119987e09ef3414331c2b5ebfff20b98e867",
     "https://github.com/termux/libandroid-shmem/archive/refs/tags/v0.7.tar.gz"),
)
BUILD_FILES = (
    "build.ps1", "CMakeLists.txt", "generate-loader-info.ps1",
    "patch-proot-events.py", "patch-shmem-private.py",
    "dsh-trace-events.c", "dsh-trace-events.h",
    "verify-distribution.py", "source-bundle.py", "assemble-corresponding-source.py",
    "DISTRIBUTION.md", "DISTRIBUTION.zh.md", "SOURCE-BUNDLE.md",
    "SHMEM.md", "SHMEM.zh.md",
)


def loader():
    spec = importlib.util.spec_from_file_location("source_bundle", TOOL / "source-bundle.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def hash_file(path: Path) -> tuple[int, str]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f"not a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    after = path.lstat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError(f"source changed while hashing: {path}")
    return before.st_size, digest.hexdigest()


def member(name: str, path: Path, expected: tuple[int, str] | None = None,
           url: str | None = None) -> dict:
    if name.startswith("/") or ".." in name.split("/") or "\\" in name:
        raise ValueError(f"unsafe archive member: {name}")
    actual = hash_file(path)
    if expected is not None and actual != expected:
        raise ValueError(f"source checksum differs from pinned input: {name}")
    return {"archivePath": name, "sourcePath": str(path.relative_to(REPO)).replace("\\", "/"),
            "bytes": actual[0], "sha256": actual[1], **({"url": url} if url else {})}


def entries(alpine_lock: dict) -> list[dict]:
    contents = []
    for kind, filename, size, sha256, url in PINNED_INPUTS:
        contents.append(member(f"upstream/{kind}/{filename}", SOURCE_CACHE / filename,
                               (size, sha256), url))
    for origin in sorted(alpine_lock["origins"]):
        source = alpine_lock["origins"][origin]
        for item in source["recipeFiles"] + source["distfiles"]:
            contents.append(member(f"alpine/{item['path']}", CACHE / item["path"],
                                   (item["bytes"], item["sha256"]), item["url"]))
    for name in BUILD_FILES:
        contents.append(member(f"candidate/{name}", TOOL / name))
    contents.append(member("candidate/SOURCE-BUNDLE-LOCK.json", LOCK))
    if len({entry["archivePath"] for entry in contents}) != len(contents):
        raise ValueError("duplicate source archive member")
    return sorted(contents, key=lambda item: item["archivePath"])


def assemble() -> dict:
    if MANIFEST.exists() or ARCHIVE.exists():
        raise ValueError("source archive or manifest already exists; use --verify")
    alpine_lock = json.loads(LOCK.read_text(encoding="utf-8"))
    loader().verify_lock(alpine_lock, loader().ROOTFS, CACHE)
    if alpine_lock.get("missing") or len(alpine_lock["origins"]) != 10:
        raise ValueError("all ten Alpine origins must be complete")
    contents = entries(alpine_lock)
    CACHE.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".corresponding-source-", suffix=".zip", dir=CACHE)
    os.close(fd)
    temp = Path(temp_name)
    try:
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as out:
            for item in contents:
                info = zipfile.ZipInfo(item["archivePath"], date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = 0o100644 << 16
                with (REPO / item["sourcePath"]).open("rb") as source, out.open(info, "w") as target:
                    for chunk in iter(lambda: source.read(65536), b""):
                        target.write(chunk)
        archive_size, archive_hash = hash_file(temp)
        manifest = {"schema": 1, "purpose": "source-only engineering evidence",
                    "distributionApproved": False, "rootfsSha256": ROOTFS_SHA256,
                    "alpineOrigins": len(alpine_lock["origins"]), "entries": contents,
                    "archive": {"path": str(ARCHIVE.relative_to(REPO)).replace("\\", "/"),
                                "bytes": archive_size, "sha256": archive_hash}}
        os.replace(temp, ARCHIVE)
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        verify(manifest)
        return manifest
    finally:
        if temp.exists():
            temp.unlink()


def verify(manifest: dict) -> None:
    if manifest.get("schema") != 1 or manifest.get("distributionApproved") is not False:
        raise ValueError("source manifest schema or gate changed")
    if manifest.get("rootfsSha256") != ROOTFS_SHA256 or manifest.get("alpineOrigins") != 10:
        raise ValueError("source manifest rootfs or origins changed")
    alpine_lock = json.loads(LOCK.read_text(encoding="utf-8"))
    source_bundle = loader()
    source_bundle.verify_lock(alpine_lock, source_bundle.ROOTFS, CACHE)
    actual_entries = entries(alpine_lock)
    if manifest.get("entries") != actual_entries:
        raise ValueError("source manifest members changed")
    if manifest.get("archive", {}).get("path") != str(ARCHIVE.relative_to(REPO)).replace("\\", "/"):
        raise ValueError("source archive path changed")
    if hash_file(ARCHIVE) != (manifest["archive"]["bytes"], manifest["archive"]["sha256"]):
        raise ValueError("source archive bytes changed")
    with zipfile.ZipFile(ARCHIVE) as source_zip:
        if source_zip.namelist() != [item["archivePath"] for item in actual_entries]:
            raise ValueError("source archive member list changed")
        for item in actual_entries:
            info = source_zip.getinfo(item["archivePath"])
            if info.file_size != item["bytes"] or info.compress_type != zipfile.ZIP_STORED:
                raise ValueError(f"source archive member size/compression changed: {item['archivePath']}")
            digest = hashlib.sha256()
            with source_zip.open(info) as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
            if digest.hexdigest() != item["sha256"]:
                raise ValueError(f"source archive member hash changed: {item['archivePath']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--assemble", action="store_true")
    group.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.assemble:
        manifest = assemble()
    else:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        verify(manifest)
    print(json.dumps({"sourceEntries": len(manifest["entries"]),
                      "archiveSha256": manifest["archive"]["sha256"],
                      "archiveBytes": manifest["archive"]["bytes"],
                      "distributionApproved": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
