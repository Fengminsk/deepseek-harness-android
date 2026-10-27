package com.minnnng.dsh_android

import android.content.Context
import android.os.SharedMemory
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.function.BooleanSupplier

/** Builds and boots a candidate image inside the real Linux guest; never used by model RPC. */
internal object LinuxVmImageBuildAcceptance {
    fun run(target: Context, tests: Context, results: JSONArray) {
        val manifest = JSONObject(tests.assets.open("linux-image-build/manifest.json").bufferedReader().use { it.readText() })
        val bytes = manifest.getInt("bytes")
        check(bytes in 1..64 * 1024 * 1024)
        val input = SharedMemory.create("linux-image-build-input", (bytes + 511) / 512 * 512)
        val output = SharedMemory.create("linux-image-build-output", 128 * 1024 * 1024)
        val snapshot = SharedMemory.create("linux-image-build-snapshot", 128 * 1024 * 1024)
        try {
            val mapped = input.mapReadWrite()
            val digest = MessageDigest.getInstance("SHA-256")
            try {
                tests.assets.open("linux-image-build/input.tar").use { stream ->
                    val buffer = ByteArray(65536)
                    var total = 0
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        check(total + count <= bytes)
                        mapped.put(buffer, 0, count); digest.update(buffer, 0, count); total += count
                    }
                    check(total == bytes && hex(digest.digest()) == manifest.getString("sha256"))
                }
            } finally { SharedMemory.unmap(mapped) }
            check(input.setProtect(OsConstants.PROT_READ))
            val session = "linux-image-build-${UUID.randomUUID()}"
            LinuxVmImageStore(target).open(session, UUID.randomUUID().toString()).use { lease ->
                var freshWorkspace = true
                fun record(command: String, root: SharedMemory, source: SharedMemory?, resultDisk: SharedMemory?): LinuxVmRunner.Result {
                    val begin = System.nanoTime()
                    val result = LinuxVmRunner.run(target, UUID.randomUUID().toString(), command, 120_000,
                        lease, BooleanSupplier { false }, source, resultDisk, root, freshWorkspace)
                    freshWorkspace = false
                    results.put(JSONObject().put("status", result.status).put("exitCode", result.exitCode)
                        .put("retirementConfirmed", result.retirementConfirmed).put("output", result.output)
                        .put("elapsedMs", (System.nanoTime() - begin) / 1_000_000))
                    check(result.status == "completed" && result.exitCode == 0 && result.retirementConfirmed) { results.toString() }
                    return result
                }
                record("""
                    set -e
                    busybox --list | grep -E 'mke2fs|mkfs.ext2|tar|chroot'
                    busybox mke2fs -F /dev/vdd
                    mkdir -p /mnt/image
                    mount -t ext2 /dev/vdd /mnt/image
                    mkdir -p /mnt/image/build-input
                    tar -xf /dev/vdc -C /mnt/image/build-input
                    tar -xzf /mnt/image/build-input/rootfs.tar.gz -C /mnt/image
                    mkdir -p /mnt/image/build-input/tools /mnt/image/build-input/e2fs
                    tar -xf /mnt/image/build-input/tools.tar -C /mnt/image/build-input/tools
                    tar -xf /mnt/image/build-input/e2fs.tar -C /mnt/image/build-input/e2fs
                    mount -t devtmpfs devtmpfs /mnt/image/dev
                    mount -t proc proc /mnt/image/proc
                    chroot /mnt/image /bin/sh -c 'apk --no-network add /build-input/tools/packages/*.apk /build-input/e2fs/packages/*.apk'
                    umount /mnt/image/proc
                    umount /mnt/image/dev
                    rm -rf /mnt/image/build-input
                    mkdir -p /mnt/image/workspace /mnt/image/dev /mnt/image/proc /mnt/image/sys
                    sync
                    umount /mnt/image
                    printf 'DSH_ALPINE_IMAGE_BUILT\n'
                """.trimIndent(), lease.disk, input, output)
                val sourceMap = output.mapReadOnly()
                val snapshotMap = snapshot.mapReadWrite()
                try { snapshotMap.put(sourceMap) }
                finally { SharedMemory.unmap(sourceMap); SharedMemory.unmap(snapshotMap) }
                check(snapshot.setProtect(OsConstants.PROT_READ))
                val probe = record("""
                    set -e
                    uname -srm
                    cat /etc/alpine-release
                    python3 -c 'import sys,ssl,sqlite3,subprocess,hashlib,zipfile; print(sys.version); assert subprocess.check_output(["/bin/sh","-c","printf linux-child"]) == b"linux-child"; print(hashlib.sha256(b"DSH").hexdigest()); print(sqlite3.sqlite_version); print(ssl.OPENSSL_VERSION)'
                    timeout 8 python3 -c 'import os,threading,time; print(os.urandom(16).hex()); t=threading.Thread(target=lambda: print(time.monotonic())); t.start(); t.join()'
                    git --version
                    curl --version | head -n 2
                    printf agent-file > /workspace/agent-test.txt
                    python3 -c 'from pathlib import Path; assert Path("/workspace/agent-test.txt").read_text()=="agent-file"; print("DSH_PYTHON_FILES_OK")'
                    rm -f /workspace/agent-test.txt /tmp/dsh-command.sh /tmp/dsh-command.b64
                    sync
                    printf 'DSH_ALPINE_RUNTIME_OK\n'
                """.trimIndent(), output, null, null)
                check(probe.output.contains("DSH_ALPINE_RUNTIME_OK"))
                val filesystem = record("""
                    set -e
                    e2fsck -fn /dev/vdc
                    printf 'DSH_ALPINE_FILESYSTEM_OK\n'
                """.trimIndent(), output, snapshot, null)
                check(filesystem.output.contains("DSH_ALPINE_FILESYSTEM_OK"))
                val directory = File(target.getExternalFilesDir(null), "linux-acceptance")
                check(directory.mkdirs() || directory.isDirectory)
                val artifact = File(directory, "alpine-riscv64-${UUID.randomUUID()}.ext2")
                check(artifact.createNewFile())
                val disk = snapshot.mapReadOnly()
                val diskDigest = MessageDigest.getInstance("SHA-256")
                try {
                    FileOutputStream(artifact).use { stream ->
                        val buffer = ByteArray(65536)
                        while (disk.hasRemaining()) {
                            val count = minOf(buffer.size, disk.remaining())
                            disk.get(buffer, 0, count); diskDigest.update(buffer, 0, count); stream.write(buffer, 0, count)
                        }
                        stream.fd.sync()
                    }
                } finally { SharedMemory.unmap(disk) }
                results.put(JSONObject().put("artifact", artifact.path).put("bytes", artifact.length())
                    .put("sha256", hex(diskDigest.digest())).put("inputSha256", manifest.getString("sha256")))
                lease.finish("completed", false)
            }
        } finally { input.close(); output.close(); snapshot.close() }
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
}
