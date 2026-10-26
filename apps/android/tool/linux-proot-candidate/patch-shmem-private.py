#!/usr/bin/env python3
"""Patch only the locked PRoot/libandroid-shmem candidate for private keyed IPC.

This is a build experiment. It neither grants an Android storage path nor
enables shared-memory mode in the App or the shipped APK.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


SHMEM_SHA256 = "c39d2d41c62749e4f450adbf1ca0247f96668337e263198a5e5c2bffe228e5f6"
PROOT_SHA256 = "9ff9e6deb845c9201ff62f04c47e8b000f9c132f98d4c1811b09c9941434883f"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"{label}: expected exactly one locked source marker")
    return text.replace(old, new, 1)


def patch(proot_root: Path, shmem_root: Path) -> None:
    shmem_path = shmem_root / "shmem.c"
    proot_path = proot_root / "src/extension/sysvipc/sysvipc.c"
    inputs = ((shmem_path, SHMEM_SHA256), (proot_path, PROOT_SHA256))
    for path, expected in inputs:
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"locked source changed: {path.name}")

    shmem = shmem_path.read_text(encoding="utf-8")
    proot = proot_path.read_text(encoding="utf-8")
    shmem = replace_once(shmem, "#include <sys/socket.h>\n", "#include <sys/socket.h>\n#include <sys/stat.h>\n", "stat include")
    shmem = replace_once(
        shmem,
        '#define ASHV_KEY_SYMLINK_PATH _PATH_TMP "ashv_key_%d"\n',
        '''/* Keyed IPC is disabled unless a future trusted launcher supplies a private 0700
 * directory writable by its isolated UID. IPC_PRIVATE needs no key path. */
static int dsh_key_symlink_path(char *output, size_t capacity, key_t key)
{
    const char *root = getenv("DSH_SHMEM_KEY_DIR");
    struct stat info;
    if (root == NULL || root[0] != '/' || strlen(root) > 160 ||
        lstat(root, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 077) != 0) {
        errno = EACCES;
        return -1;
    }
    int length = snprintf(output, capacity, "%s/ashv_key_%d", root, key);
    if (length < 0 || (size_t) length >= capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}
''',
        "private key directory",
    )
    shmem = replace_once(
        shmem,
        "\t\tsprintf(symlink_path, ASHV_KEY_SYMLINK_PATH, key);\n",
        "\t\tif (dsh_key_symlink_path(symlink_path, sizeof(symlink_path), key) != 0) {\n"
        "\t\t\tpthread_mutex_unlock(&mutex);\n\t\t\treturn -1;\n\t\t}\n",
        "private key path call",
    )
    shmem = replace_once(
        shmem,
        "\t\twhile (true) {\n\t\t\tint path_length = readlink(symlink_path, path_buffer, sizeof(path_buffer) - 1);",
        "\t\tbool key_linked = false;\n\t\tfor (int attempt = 0; attempt < 32; ++attempt) {\n"
        "\t\t\tint path_length = readlink(symlink_path, path_buffer, sizeof(path_buffer) - 1);",
        "bounded key retry",
    )
    shmem = replace_once(
        shmem,
        "\t\t\tif (symlink(num_buffer, symlink_path) == 0) break;\n\t\t}\n",
        "\t\t\tif (symlink(num_buffer, symlink_path) == 0) { key_linked = true; break; }\n"
        "\t\t\tif (errno != EEXIST) break;\n\t\t}\n"
        "\t\tif (!key_linked) {\n\t\t\tint failure = errno == 0 ? EAGAIN : errno;\n"
        "\t\t\tpthread_mutex_unlock(&mutex);\n\t\t\terrno = failure;\n\t\t\treturn -1;\n\t\t}\n",
        "key failure",
    )
    proot = replace_once(
        proot,
        'if (!getenv("PROOT_DONT_SHARE_LIBANDROID_SHMEM")) {',
        'if (getenv("DSH_ENABLE_LIBANDROID_SHMEM") &&\n'
        '\t\t\tgetenv("DSH_SHMEM_KEY_DIR") &&\n'
        '\t\t\t!getenv("PROOT_DONT_SHARE_LIBANDROID_SHMEM")) {',
        "opt-in shared IPC",
    )

    shmem_path.write_text(shmem, encoding="utf-8")
    proot_path.write_text(proot, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch-shmem-private.py PROOT_SOURCE SHMEM_SOURCE")
    patch(Path(sys.argv[1]), Path(sys.argv[2]))
