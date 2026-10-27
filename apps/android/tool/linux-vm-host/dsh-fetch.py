#!/usr/bin/env python3
"""Host-probe HTTPS client for a dedicated VM mailbox; not a general socket transport."""
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
    """O_DIRECT needs aligned address, length and offset. Avoid the guest block cache."""
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


def fetch(device, run, url, sequence=1):
    call = str(uuid.uuid4())
    payload = (run + call + url).encode("ascii")
    if len(run) != 36 or len(payload) > 72 + 2048:
        raise ValueError("invalid mailbox request")
    header = struct.pack(">4I", MAGIC, 1, sequence, len(payload)) + hashlib.sha256(payload).digest()
    fd = os.open(device, os.O_RDWR | os.O_DIRECT | os.O_SYNC)
    try:
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
                if len(data) != 83 + url_size + type_size + body_size or body_size > 65536:
                    raise RuntimeError("invalid mailbox body length")
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
    result, content = fetch(sys.argv[1], sys.argv[2], sys.argv[3])
    print(json.dumps(result, separators=(",", ":")), flush=True)
    if result["status"] != 0 or result["http"] != 200:
        raise SystemExit(1)
    # The probe checks content inside Linux, not just the host-side broker return value.
    if b"Example Domain" not in content:
        raise RuntimeError("unexpected HTTPS probe body")
    print("DSH_GUEST_HTTPS_OK", flush=True)
