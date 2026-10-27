package com.minnnng.dsh_android

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.security.MessageDigest
import java.util.function.BooleanSupplier

/** One immutable input snapshot, opened beneath the App workspace and passed as a read-only guest disk. */
internal class LinuxVmFileInput private constructor(
    val memory: SharedMemory, val bytes: Long, val sha256: String, val guestPath: String,
) : AutoCloseable {
    fun command(): String {
        val target = quote(guestPath)
        val parent = quote(guestPath.substringBeforeLast('/'))
        return "if [ -e $target ] || [ -L $target ]; then printf 'Destination already exists\\n' >&2; exit 73; fi\n" +
            "umask 077\nmkdir -p $parent || exit 74\n" +
            "head -c $bytes /dev/vdc > $target || exit 74\n" +
            "dsh_hash=\$(sha256sum $target)\n" +
            "[ \"\${dsh_hash%% *}\" = '$sha256' ] || { rm -f $target; exit 74; }\n" +
            "printf '%s\\n' \"\$dsh_hash\"\n"
    }

    override fun close() { memory.close() }

    companion object {
        const val MAX_BYTES = 64 * 1024 * 1024
        internal fun relative(value: String): String {
            require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 4096
                && !value.startsWith('/') && !value.contains('\\') && !value.contains(':')
                && value.none { it.code < 32 || it.code == 127 }
                && value.split('/').all { it.isNotEmpty() && it != "." && it != ".." }) {
                "Linux import requires a relative file path without parent traversal"
            }
            return value
        }

        fun open(context: Context, source: String, destination: String,
            cancelled: BooleanSupplier = BooleanSupplier { false }): LinuxVmFileInput {
            val root = File(context.noBackupFilesDir, "dsh/workspace").canonicalFile
            val candidate = File(root, relative(source))
            val guestPath = "/workspace/" + relative(destination)
            // A FIFO must not block before its fstat/type check or cancellation.
            val openedFd = Os.open(candidate.path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_CLOEXEC, 0)
            val descriptor = try { ParcelFileDescriptor.dup(openedFd) } finally { Os.close(openedFd) }
            var memory: SharedMemory? = null
            try {
                // Verify the opened descriptor, not just the earlier pathname.
                // A parent symlink cannot redirect a read into credentials.
                val opened = File(Os.readlink("/proc/self/fd/${descriptor.fd}")).canonicalPath
                require(opened.startsWith(root.path + File.separator)) { "Linux import is outside the App workspace" }
                val before = Os.fstat(descriptor.fileDescriptor)
                require(OsConstants.S_ISREG(before.st_mode) && before.st_size in 0..MAX_BYTES.toLong()) {
                    "Linux import must be a regular file no larger than 64 MiB"
                }
                val size = maxOf(512, ((before.st_size + 511) / 512 * 512).toInt())
                val snapshot = SharedMemory.create("dsh-linux-input", size)
                memory = snapshot
                val mapped = snapshot.mapReadWrite()
                val digest = MessageDigest.getInstance("SHA-256")
                try {
                    val buffer = ByteArray(65536)
                    var remaining = before.st_size
                    while (remaining > 0) {
                        check(!cancelled.asBoolean) { "Linux import was cancelled" }
                        val count = Os.read(descriptor.fileDescriptor, buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                        require(count > 0) { "Linux import file changed while reading" }
                        mapped.put(buffer, 0, count); digest.update(buffer, 0, count); remaining -= count
                    }
                    val after = Os.fstat(descriptor.fileDescriptor)
                    require(before.st_size == after.st_size && before.st_mtim == after.st_mtim
                        && before.st_ctim == after.st_ctim) { "Linux import file changed while reading" }
                } finally { SharedMemory.unmap(mapped) }
                check(snapshot.setProtect(OsConstants.PROT_READ)) { "Cannot seal Linux import snapshot" }
                return LinuxVmFileInput(snapshot, before.st_size,
                    digest.digest().joinToString("") { "%02x".format(it) }, guestPath)
            } catch (failure: Exception) { memory?.close(); throw failure }
            finally { descriptor.close() }
        }

        private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
    }
}
