"""Extract the runtime carried by an APK for host upgrade acceptance only."""

import hashlib
import json
import stat
import sys
import zipfile
from pathlib import Path


def extract(apk_path: Path, destination: Path) -> dict:
    if destination.exists():
        raise ValueError(f"Refusing to replace an existing extraction: {destination}")
    destination.mkdir(parents=True)
    archive_path = destination.parent / f"{destination.name}.zip"
    if archive_path.exists():
        raise ValueError(f"Refusing to replace an existing runtime ZIP: {archive_path}")

    with zipfile.ZipFile(apk_path) as apk:
        expected = apk.read("assets/runtime/runtime.sha256").decode("ascii").strip().lower()
        if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise ValueError("Invalid APK runtime digest")
        digest = hashlib.sha256()
        with apk.open("assets/runtime/runtime.zip") as source, archive_path.open("xb") as target:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
                target.write(chunk)
        if digest.hexdigest() != expected:
            raise ValueError("APK runtime ZIP does not match its embedded digest")

    total = 0
    count = 0
    seen = set()
    with zipfile.ZipFile(archive_path) as runtime:
        for entry in runtime.infolist():
            raw = entry.filename.removesuffix("/")
            parts = raw.split("/")
            if not raw or any(part in ("", ".", "..") or ":" in part or "\\" in part for part in parts):
                raise ValueError(f"Unsafe runtime entry: {entry.filename}")
            normalized = raw.casefold()
            if normalized in seen:
                raise ValueError(f"Duplicate runtime entry: {entry.filename}")
            seen.add(normalized)
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError(f"Runtime ZIP contains a link: {entry.filename}")
            total += entry.file_size
            if total > 2 * 1024 * 1024 * 1024 or entry.file_size > 256 * 1024 * 1024:
                raise ValueError("Runtime extraction exceeds the acceptance bound")
            target = destination.joinpath(*parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with runtime.open(entry) as source, target.open("xb") as output:
                    while chunk := source.read(1024 * 1024):
                        output.write(chunk)
            count += 1
    if not (destination / "bootstrap.mjs").is_file():
        raise ValueError("Runtime ZIP has no Android bootstrap")
    archive_path.unlink()
    return {"sha256": expected, "entries": count, "expandedBytes": total}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: extract-apk-runtime.py APK DESTINATION")
    print(json.dumps(extract(Path(sys.argv[1]), Path(sys.argv[2]))))
