#!/usr/bin/env python3
"""Bounded HTTPS GET through an App-approved Linux mailbox; no general socket access."""
import fcntl
import hashlib
import json
import mmap
import os
import struct
import sys
import time
import uuid

SECTOR = 512
REPLY_OFFSET = 4096
MAGIC = 0x4453484D


def io_at(fd, offset, data=None, size=SECTOR):
    """Use aligned direct I/O so the guest block cache cannot hide mailbox replies."""
    with mmap.mmap(-1, size) as aligned:
        os.lseek(fd, offset, os.SEEK_SET)
        if data is not None:
            aligned[:len(data)] = data
            count = os.writev(fd, [aligned])
        else:
            count = os.readv(fd, [aligned])
        if count != size:
            raise RuntimeError("short mailbox block I/O")
        return bytes(aligned)


def fetch(device, run, url):
    """Return response metadata and up to 64 KiB of bytes, or raise on a malformed reply."""
    if str(uuid.UUID(run)) != run:
        raise ValueError("invalid mailbox run")
    call = str(uuid.uuid4())
    payload = (run + call + url).encode("ascii")
    if not url or len(payload) > 72 + 2048 or any(item < 32 or item > 126 for item in payload):
        raise ValueError("invalid mailbox request")
    fd = os.open(device, os.O_RDWR | os.O_DIRECT | os.O_SYNC)
    try:
        # Independent clients in one shell command share the device sequence.
        # Do not permit two writers to overwrite an outstanding request frame.
        fcntl.flock(fd, fcntl.LOCK_EX)
        previous = io_at(fd, 0)
        magic, version, last_sequence, _ = struct.unpack_from(">4I", previous)
        if last_sequence and (magic != MAGIC or version != 1):
            raise RuntimeError("invalid previous mailbox request")
        sequence = last_sequence + 1
        if sequence > 64:
            raise RuntimeError("mailbox call budget exceeded")
        header = struct.pack(">4I", MAGIC, 1, sequence, len(payload)) + hashlib.sha256(payload).digest()
        size = ((len(payload) + SECTOR - 1) // SECTOR) * SECTOR
        io_at(fd, SECTOR, payload, size)
        io_at(fd, 0, header)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            reply = io_at(fd, REPLY_OFFSET)
            magic, version, response_sequence, length = struct.unpack_from(">4I", reply)
            if response_sequence == sequence:
                if magic != MAGIC or version != 1 or not 83 <= length <= 131072 - SECTOR:
                    raise RuntimeError("invalid mailbox response")
                size = ((length + SECTOR - 1) // SECTOR) * SECTOR
                data = io_at(fd, REPLY_OFFSET + SECTOR, size=size)[:length]
                if hashlib.sha256(data).digest() != reply[16:48] or data[:72] != (run + call).encode():
                    raise RuntimeError("mailbox response identity or digest changed")
                status, http, url_size, type_size, body_size = struct.unpack_from(">BHHHI", data, 72)
                if (len(data) != 83 + url_size + type_size + body_size or body_size > 65536
                        or url_size > 2048 or type_size > 1024 or status > 6
                        or (status == 0 and not 100 <= http <= 599)
                        or (status != 0 and (http != 0 or body_size != 0))):
                    raise RuntimeError("invalid mailbox response fields")
                cursor = 83
                final_url = data[cursor:cursor + url_size].decode("ascii")
                cursor += url_size
                mime = data[cursor:cursor + type_size].decode("utf8")
                body = data[cursor + type_size:]
                return {"callId": call, "status": status, "http": http, "url": final_url,
                        "contentType": mime, "bytes": len(body),
                        "sha256": hashlib.sha256(body).hexdigest()}, body
            time.sleep(0.01)
        raise TimeoutError("VM HTTPS mailbox deadline expired")
    finally:
        os.close(fd)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: dsh-fetch https://approved-host/path")
    try:
        result, content = fetch(os.environ["DSH_HTTPS_DEVICE"], os.environ["DSH_HTTPS_RUN_ID"], sys.argv[1])
        print(json.dumps(result, separators=(",", ":")), file=sys.stderr, flush=True)
        if result["status"] != 0:
            raise SystemExit(1)
        sys.stdout.buffer.write(content)
        if not 200 <= result["http"] <= 299:
            raise SystemExit(22)
    except (KeyError, OSError, ValueError, RuntimeError, TimeoutError) as error:
        print("dsh-fetch: " + str(error), file=sys.stderr)
        raise SystemExit(1)
