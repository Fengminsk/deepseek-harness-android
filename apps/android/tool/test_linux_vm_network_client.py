"""Exercise the shipped guest client's frame parser without requiring a kernel or Android device."""
import importlib.util
import struct
import sys
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

CLIENT = Path(__file__).resolve().parents[1] / "android/app/src/main/assets/linux-vm-network/dsh-fetch.py"


class LinuxNetworkClientTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("dsh_fetch_under_test", CLIENT)
        self.client = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"fcntl": types.SimpleNamespace(LOCK_EX=2, flock=lambda *_: None)}):
            spec.loader.exec_module(self.client)
        self.disk = bytearray(135168)
        self.run = str(uuid.uuid4())
        self.sequences = []
        self.mutation = lambda data: data
        self.opened = []
        self.closed = []
        self.patchers = [patch.object(self.client, "io_at", self.io_at),
                         patch.object(self.client.os, "open", self.open),
                         patch.object(self.client.os, "close", lambda fd: self.closed.append(fd)),
                         patch.object(self.client.os, "O_DIRECT", 0, create=True),
                         patch.object(self.client.os, "O_SYNC", 0, create=True)]
        for item in self.patchers:
            item.start()
            self.addCleanup(item.stop)

    def open(self, path, flags):
        self.opened.append((path, flags))
        return 37

    def io_at(self, fd, offset, data=None, size=512):
        self.assertEqual(fd, 37)
        self.assertEqual(offset % 512, 0)
        self.assertEqual(size % 512, 0)
        if data is not None:
            self.disk[offset:offset + size] = data + bytes(size - len(data))
            if offset == 0:
                magic, version, sequence, length = struct.unpack_from(">4I", data)
                self.assertEqual((magic, version), (self.client.MAGIC, 1))
                self.sequences.append(sequence)
                payload = bytes(self.disk[512:512 + length])
                self.assertEqual(data[16:48], self.client.hashlib.sha256(payload).digest())
                url, mime, body = b"https://example.com/", b"text/plain", b"test body"
                response = payload[:72] + struct.pack(">BHHHI", 0, 200, len(url), len(mime), len(body)) + url + mime + body
                response = self.mutation(response)
                self.disk[4608:4608 + len(response)] = response
                self.disk[4096:4144] = struct.pack(">4I", self.client.MAGIC, 1, sequence, len(response)) + self.client.hashlib.sha256(response).digest()
        return bytes(self.disk[offset:offset + size])

    def test_response_bytes_and_sequential_cli_calls_share_budget(self):
        for _ in range(2):
            result, body = self.client.fetch("/dev/vdd", self.run, "https://example.com/")
            self.assertEqual(body, b"test body")
            self.assertEqual(result["sha256"], self.client.hashlib.sha256(body).hexdigest())
        self.assertEqual(self.sequences, [1, 2])
        self.assertEqual(self.closed, [37, 37])

    def test_wrong_run_reply_rejected_and_descriptor_closed(self):
        self.mutation = lambda response: str(uuid.uuid4()).encode() + response[36:]
        with self.assertRaisesRegex(RuntimeError, "identity"):
            self.client.fetch("/dev/vdd", self.run, "https://example.com/")
        self.assertEqual(self.closed, [37])

    def test_bad_response_sizes_and_status_rejected(self):
        for offset, value in [(72, b"\x09"), (73, b"\x00\x00"), (79, struct.pack(">I", 65537))]:
            with self.subTest(offset=offset):
                self.mutation = lambda response: response[:offset] + value + response[offset + len(value):]
                with self.assertRaisesRegex(RuntimeError, "fields"):
                    self.client.fetch("/dev/vdd", self.run, "https://example.com/")
        self.assertEqual(len(self.closed), 3)

    def test_bad_request_is_rejected_before_open(self):
        for url in ["", "https://example.com/\nInjected", "https://example.com/" + "x" * 2048, "https://例子.test/"]:
            with self.subTest(url=url[:30]), self.assertRaises((ValueError, UnicodeError)):
                self.client.fetch("/dev/vdd", self.run, url)
        self.assertEqual(self.opened, [])


if __name__ == "__main__":
    unittest.main()
