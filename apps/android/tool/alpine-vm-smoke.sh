#!/bin/sh
# Device-only smoke for the offline guest; writes only its private temporary directory.
set -eu
test "$(uname -m)" = riscv64
python3 --version
git --version
curl --version
test -x /sbin/e2fsck
test -r /etc/ssl/certs/ca-certificates.crt
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import ssl
import stat
import subprocess
import tempfile
import threading
import time
import zipfile

assert json.loads(json.dumps({"ok": [1, True, "DSH"]})) == {"ok": [1, True, "DSH"]}
assert hashlib.sha256(b"abc").hexdigest() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
event = threading.Event()
worker = threading.Thread(target=event.set)
worker.start()
worker.join(2)
assert not worker.is_alive() and event.is_set()
assert time.monotonic() >= 0 and time.time() > 1_600_000_000
assert subprocess.check_output(["/bin/sh", "-c", "printf child-ok"]) == b"child-ok"
with tempfile.TemporaryDirectory(prefix="dsh-smoke-", dir="/workspace") as folder:
    root = Path(folder)
    source = root / "source.bin"
    source.write_bytes(bytes(range(256)))
    source.chmod(0o700)
    link = root / "link.bin"
    link.symlink_to("source.bin")
    assert link.read_bytes() == source.read_bytes()
    assert stat.S_IMODE(source.stat().st_mode) == 0o700
    archive = root / "sample.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as writer:
        writer.write(source, "source.bin")
    with zipfile.ZipFile(archive) as reader:
        assert reader.read("source.bin") == source.read_bytes()
    with sqlite3.connect(root / "sample.db") as connection:
        connection.execute("create table smoke(value text)")
        connection.execute("insert into smoke values (?)", ("ok",))
        assert connection.execute("select value from smoke").fetchone() == ("ok",)
assert ssl.create_default_context().get_ca_certs()
print("DSH_ALPINE_FILES_THREADS_LIBS_OK", flush=True)
# A bounded parent invocation must detect missing guest entropy, not mask it with a fixed seed.
assert len(os.urandom(16)) == 16
print("DSH_ALPINE_RANDOM_OK", flush=True)
PY
printf 'DSH_ALPINE_TOOLS_OK\n'
