#!/usr/bin/env python3
"""Fetch and verify the exact Alpine minirootfs corresponding-source inputs.

This is a source inventory/build artifact, not a license or runtime approval.
No fetched code is executed or extracted. --fetch only writes its owned cache.
"""

from __future__ import annotations

import argparse
import hashlib
import html.parser
import json
import os
import re
import stat
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[4]
TOOL = Path(__file__).resolve().parent
ROOTFS = REPO / ".cache/android/linux-rootfs-prototype/alpine-minirootfs-3.24.3-aarch64.tar.gz"
CACHE = REPO / ".cache/android/linux-guest-source-bundle"
LOCK = TOOL / "SOURCE-BUNDLE-LOCK.json"
ROOTFS_SHA256 = "4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50"
ROOTFS_BYTES = 4029999
EXPECTED_ORIGINS = frozenset({"alpine-baselayout", "alpine-keys", "alpine-base", "apk-tools",
                             "busybox", "ca-certificates", "openssl", "musl", "pax-utils", "zlib"})
MAX_FILE = 90 * 1024 * 1024
MAX_NEW_BYTES = 250 * 1024 * 1024
OFFICIAL_UPSTREAM_FALLBACKS = {
    # The Alpine distfiles proxy stalled mid-transfer for this exact large file.
    # OpenSSL's official release URL serves identical bytes, checked against
    # the SHA-512 in Alpine's fixed-commit APKBUILD before entering the cache.
    "openssl-3.5.9.tar.gz": "https://www.openssl.org/source/openssl-3.5.9.tar.gz",
}


def digest_file(path: Path, algorithm: str = "sha256") -> tuple[int, str]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f"not an ordinary source file: {path}")
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    after = path.lstat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError(f"source changed while hashing: {path}")
    return before.st_size, digest.hexdigest()


def installed_origins(rootfs: Path) -> tuple[list[dict], dict[str, dict]]:
    if digest_file(rootfs) != (ROOTFS_BYTES, ROOTFS_SHA256):
        raise ValueError("pinned Alpine rootfs changed")
    with tarfile.open(rootfs, "r:gz") as archive:
        member = archive.getmember("./lib/apk/db/installed")
        if not member.isfile() or member.size > 131072:
            raise ValueError("Alpine installed database changed")
        database = archive.extractfile(member).read().decode("utf-8")
    packages: list[dict] = []
    origins: dict[str, dict] = {}
    for block in re.split(r"\n\s*\n", database):
        fields = dict(line.split(":", 1) for line in block.splitlines()
                      if len(line) > 1 and line[1] == ":")
        if "P" not in fields:
            continue
        if not all(key in fields for key in ("V", "o", "c", "L")):
            raise ValueError("Alpine package version, origin, source commit, or license missing")
        origin, commit = fields["o"], fields["c"]
        if not re.fullmatch(r"[a-z0-9-]+", origin) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("Alpine package origin or commit invalid")
        entry = {"name": fields["P"], "version": fields["V"], "origin": origin,
                 "aportsCommit": commit, "licenseMetadata": fields["L"]}
        packages.append(entry)
        prior = origins.setdefault(origin, {"version": fields["V"], "commit": commit})
        if prior != {"version": fields["V"], "commit": commit}:
            raise ValueError(f"subpackages disagree on source revision: {origin}")
    if len(packages) != 16 or set(origins) != EXPECTED_ORIGINS:
        raise ValueError("Alpine rootfs package inventory changed")
    return sorted(packages, key=lambda item: item["name"]), origins


class CgitTree(html.parser.HTMLParser):
    def __init__(self, origin: str, commit: str):
        super().__init__(convert_charrefs=True)
        self.prefix = f"/aports/tree/main/{origin}/"
        self.commit = commit
        self.names: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        attributes = dict(attrs)
        if "ls-blob" not in (attributes.get("class") or "").split():
            return
        href = attributes.get("href") or ""
        parsed = urllib.parse.urlparse(href)
        if not parsed.path.startswith(self.prefix):
            return
        if urllib.parse.parse_qs(parsed.query) != {"id": [self.commit]}:
            raise ValueError("cgit file link changed revision")
        name = urllib.parse.unquote(parsed.path[len(self.prefix):])
        if not name or "/" in name or "\\" in name or name in {".", ".."}:
            raise ValueError("unsafe aports file name")
        self.names.add(name)


def checked_name(name: str) -> str:
    if not name or name in {".", ".."} or "/" in name or "\\" in name or "\x00" in name:
        raise ValueError(f"unsafe source filename: {name!r}")
    return name


def sha512_entries(apkbuild: str) -> dict[str, str]:
    match = re.search(r'(?m)^sha512sums="([\s\S]*?)"', apkbuild)
    if not match:
        return {}
    entries: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if not line.strip():
            continue
        found = re.fullmatch(r"\s*([0-9a-f]{128})\s+(.+?)\s*", line)
        if not found:
            raise ValueError("unexpected APKBUILD sha512sums entry")
        name = checked_name(found.group(2))
        if name in entries:
            raise ValueError("duplicate APKBUILD sha512sums entry")
        entries[name] = found.group(1)
    return entries


def source_expression(apkbuild: str) -> str:
    match = re.search(r'(?m)^source="([\s\S]*?)"', apkbuild)
    return match.group(1) if match else ""


class Fetcher:
    def __init__(self, cache: Path, allow_network: bool):
        self.cache = cache.resolve()
        self.allow_network = allow_network
        self.new_bytes = 0

    def fetch(self, relative: str, url: str, expected_sha512: str | None = None) -> dict:
        path = self.cache / relative
        if path.resolve().parent != path.parent or self.cache not in path.parents:
            raise ValueError("source path escaped cache")
        if path.exists():
            size, sha256 = digest_file(path)
            if expected_sha512 and digest_file(path, "sha512")[1] != expected_sha512:
                raise ValueError(f"cached source checksum mismatch: {relative}")
            return {"path": relative, "bytes": size, "sha256": sha256, "url": url,
                    **({"sha512": expected_sha512} if expected_sha512 else {})}
        if not self.allow_network:
            raise FileNotFoundError(f"source not cached: {relative}")
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=".source-", dir=path.parent)
        temp = Path(temp_name)
        digest256, digest512 = hashlib.sha256(), hashlib.sha512()
        size = 0
        try:
            with os.fdopen(fd, "wb") as output:
                with urllib.request.urlopen(url, timeout=30) as response:
                    if urllib.parse.urlparse(response.geturl()).scheme != "https":
                        raise ValueError("source URL redirected off HTTPS")
                    while block := response.read(65536):
                        size += len(block)
                        if size > MAX_FILE or self.new_bytes + size > MAX_NEW_BYTES:
                            raise ValueError("source download exceeds bounded budget")
                        digest256.update(block)
                        digest512.update(block)
                        output.write(block)
                output.flush()
                os.fsync(output.fileno())
            if expected_sha512 and digest512.hexdigest() != expected_sha512:
                raise ValueError(f"upstream source checksum mismatch: {relative}")
            if path.exists():
                raise ValueError(f"source appeared during download: {relative}")
            os.replace(temp, path)
            self.new_bytes += size
            return {"path": relative, "bytes": size, "sha256": digest256.hexdigest(),
                    "url": url, **({"sha512": expected_sha512} if expected_sha512 else {})}
        finally:
            if temp.exists():
                temp.unlink()


def aports_files(fetcher: Fetcher, origin: str, commit: str) -> list[dict]:
    tree_url = f"https://git.alpinelinux.org/aports/tree/main/{origin}?id={commit}"
    if not fetcher.allow_network:
        raise ValueError("tree discovery requires --fetch; use --verify for a pinned manifest")
    with urllib.request.urlopen(tree_url, timeout=30) as response:
        tree = response.read(1024 * 1024).decode("utf-8")
    parser = CgitTree(origin, commit)
    parser.feed(tree)
    if "APKBUILD" not in parser.names or len(parser.names) > 250:
        raise ValueError(f"aports tree incomplete or oversized: {origin}")
    files = []
    for name in sorted(parser.names):
        relative = f"aports/{origin}/{checked_name(name)}"
        url = f"https://git.alpinelinux.org/aports/plain/main/{origin}/{urllib.parse.quote(name)}?id={commit}"
        files.append(fetcher.fetch(relative, url))
    return files


def bundle_manifest(fetcher: Fetcher, rootfs: Path, skipped: frozenset[str] = frozenset()) -> dict:
    packages, origins = installed_origins(rootfs)
    output = {"schema": 1, "rootfsSha256": ROOTFS_SHA256, "rootfsBytes": ROOTFS_BYTES,
              "packages": packages, "origins": {}, "missing": {}}
    for origin in sorted(origins):
        if origin in skipped:
            output["missing"][origin] = "skipped for bounded source fetch; still required"
            continue
        print(f"source-bundle: {origin}", file=sys.stderr, flush=True)
        try:
            commit = origins[origin]["commit"]
            files = aports_files(fetcher, origin, commit)
            apkbuild_path = fetcher.cache / f"aports/{origin}/APKBUILD"
            apkbuild = apkbuild_path.read_text(encoding="utf-8")
            if not re.search(r"(?m)^pkgver=" + re.escape(origins[origin]["version"].split("-r")[0]) + r"$", apkbuild):
                raise ValueError(f"APKBUILD version disagrees with binary package: {origin}")
            sums = sha512_entries(apkbuild)
            local_names = {item["path"].split("/")[-1] for item in files}
            distfiles = []
            for name, sha512 in sorted(sums.items()):
                if name in local_names:
                    local = next(item for item in files if item["path"].endswith("/" + name))
                    if digest_file(fetcher.cache / local["path"], "sha512")[1] != sha512:
                        raise ValueError(f"APKBUILD local input changed: {origin}/{name}")
                    continue
                url = OFFICIAL_UPSTREAM_FALLBACKS.get(
                    name, f"https://distfiles.alpinelinux.org/distfiles/v3.24/{urllib.parse.quote(name)}")
                distfiles.append(fetcher.fetch(f"distfiles/{name}", url, sha512))
            output["origins"][origin] = {"version": origins[origin]["version"], "commit": commit,
                                         "treeUrl": f"https://git.alpinelinux.org/aports/tree/main/{origin}?id={commit}",
                                         "sourceExpression": source_expression(apkbuild),
                                         "recipeFiles": files, "distfiles": distfiles}
        except (OSError, ValueError, UnicodeError) as error:
            output["missing"][origin] = f"{type(error).__name__}: {error}"
            print(f"source-bundle: {origin} incomplete: {error}", file=sys.stderr, flush=True)
    return output


def verify_lock(lock: dict, rootfs: Path, cache: Path) -> None:
    packages, origins = installed_origins(rootfs)
    if lock.get("schema") != 1 or lock.get("packages") != packages or set(lock.get("origins", {})) != set(origins):
        raise ValueError("source lock does not match pinned rootfs")
    for name, origin in lock["origins"].items():
        if (origin["version"], origin["commit"]) != (origins[name]["version"], origins[name]["commit"]):
            raise ValueError(f"source lock revision changed: {name}")
        for item in origin["recipeFiles"] + origin["distfiles"]:
            relative = item["path"]
            parts = relative.split("/")
            if len(parts) != 3 and not (len(parts) == 2 and parts[0] == "distfiles"):
                raise ValueError("unexpected source lock path")
            for part in parts:
                checked_name(part)
            if digest_file(cache / relative) != (item["bytes"], item["sha256"]):
                raise ValueError(f"source lock checksum mismatch: {relative}")
            if "sha512" in item and digest_file(cache / relative, "sha512")[1] != item["sha512"]:
                raise ValueError(f"APKBUILD source checksum mismatch: {relative}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="fetch fixed-commit aports files and SHA512-verified distfiles")
    parser.add_argument("--verify", action="store_true", help="verify the pinned lock against local source cache")
    parser.add_argument("--rootfs", type=Path, default=ROOTFS)
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--skip-origin", action="append", choices=sorted(EXPECTED_ORIGINS),
                        default=[], help="record an unavailable origin and continue the others")
    args = parser.parse_args()
    if args.fetch == args.verify:
        parser.error("choose exactly one of --fetch or --verify")
    cache = args.cache.resolve()
    if not cache.is_relative_to(REPO / ".cache"):
        raise ValueError("source cache must stay under the repository .cache")
    if args.verify:
        lock = json.loads(args.lock.read_text(encoding="utf-8"))
        verify_lock(lock, args.rootfs, cache)
        print(json.dumps({"verifiedOrigins": len(lock["origins"]),
                          "sourceFiles": sum(len(v["recipeFiles"]) + len(v["distfiles"])
                                             for v in lock["origins"].values()),
                          "distributionApproved": False}))
    else:
        if args.lock.exists():
            raise ValueError("source lock already exists; verify it instead of replacing it")
        lock = bundle_manifest(Fetcher(cache, True), args.rootfs, frozenset(args.skip_origin))
        if lock["missing"]:
            partial = cache / "partial.json"
            partial.parent.mkdir(parents=True, exist_ok=True)
            partial.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(json.dumps({"fetchedOrigins": len(lock["origins"]),
                              "missing": lock["missing"], "distributionApproved": False}), file=sys.stderr)
            return 2
        args.lock.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        verify_lock(lock, args.rootfs, cache)
        print(json.dumps({"fetchedOrigins": len(lock["origins"]),
                          "newBytes": sum(i["bytes"] for o in lock["origins"].values()
                                          for i in o["recipeFiles"] + o["distfiles"]),
                          "distributionApproved": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
