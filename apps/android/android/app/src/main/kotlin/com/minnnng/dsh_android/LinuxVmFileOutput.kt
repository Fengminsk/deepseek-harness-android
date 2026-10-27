package com.minnnng.dsh_android

import android.content.Context
import android.os.SharedMemory
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.function.BooleanSupplier

/** Receives a bounded guest file into memory; only the App can publish it in its authorized workspace. */
internal class LinuxVmFileOutput(private val context: Context, source: String, destination: String) : AutoCloseable {
    val source = LinuxVmFileInput.relative(source)
    val destination = LinuxVmFileInput.relative(destination)
    private val marker = "DSH_EXPORT_${UUID.randomUUID().toString().replace("-", "")}:"
    val input = SharedMemory.create("dsh-linux-export-padding", 512)
    val memory: SharedMemory

    init {
        try {
            check(input.setProtect(OsConstants.PROT_READ))
            memory = SharedMemory.create("dsh-linux-export", LinuxVmFileInput.MAX_BYTES)
        } catch (failure: Throwable) { input.close(); throw failure }
    }

    fun command(): String {
        val file = quote("/workspace/$source")
        return "set -e\n[ -f $file ] || exit 75\n" +
            "dsh_size=\$(stat -c %s $file)\n" +
            "case \"\$dsh_size\" in ''|*[!0-9]*) exit 75;; esac\n" +
            "[ \"\$dsh_size\" -le ${LinuxVmFileInput.MAX_BYTES} ] || exit 75\n" +
            "dd if=$file of=/dev/vdd bs=65536 2>/dev/null\n" +
            "dsh_hash=\$(sha256sum $file)\n" +
            "printf '$marker%s:%s\\n' \"\$dsh_size\" \"\${dsh_hash%% *}\"\n"
    }

    class Staged(val file: File, val bytes: Int, val sha256: String) : AutoCloseable {
        override fun close() { java.nio.file.Files.deleteIfExists(file.toPath()) }
    }

    fun stage(output: String, cancelled: BooleanSupplier): Staged {
        val receipt = output.lineSequence().filter { it.startsWith(marker) }.toList().single()
        val fields = receipt.removePrefix(marker).split(':')
        require(fields.size == 2 && fields[0].matches(Regex("0|[1-9][0-9]{0,7}"))) { "Invalid Linux export length" }
        val bytes = fields[0].toInt()
        require(bytes in 0..LinuxVmFileInput.MAX_BYTES && fields[1].matches(Regex("[0-9a-f]{64}"))) {
            "Invalid Linux export identity"
        }
        val directory = LinuxVmFilePublisher.stagingDirectory(context)
        check(directory.mkdirs() || directory.isDirectory) { "Cannot create Linux export staging directory" }
        val file = File.createTempFile("export-", ".pending", directory)
        try {
            val mapped = memory.mapReadOnly()
            val digest = MessageDigest.getInstance("SHA-256")
            try {
                mapped.limit(bytes)
                FileOutputStream(file).use { stream ->
                    val buffer = ByteArray(65536)
                    while (mapped.hasRemaining()) {
                        if (cancelled.asBoolean) throw CancellationException("Linux export cancelled")
                        val count = minOf(buffer.size, mapped.remaining())
                        mapped.get(buffer, 0, count); digest.update(buffer, 0, count); stream.write(buffer, 0, count)
                    }
                    check(digest.digest().joinToString("") { "%02x".format(it) } == fields[1]) {
                        "Linux export content checksum differs"
                    }
                    stream.fd.sync()
                }
            } finally { SharedMemory.unmap(mapped) }
            return Staged(file, bytes, fields[1])
        } catch (failure: Throwable) { java.nio.file.Files.deleteIfExists(file.toPath()); throw failure }
    }

    override fun close() { try { input.close() } finally { memory.close() } }
    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}
