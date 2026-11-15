package com.minnnng.dsh_android

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Immutable runtime payloads are verified before a complete directory is published. */
object RuntimeAssets {
    private const val COPY_BUFFER_BYTES = 64 * 1024
    /** Large single files must also advance the startup watchdog, not only entry boundaries. */
    private const val PROGRESS_INTERVAL_BYTES = 8L * 1024 * 1024

    fun prepare(context: Context, onProgress: (() -> Unit)? = null): File {
        val expected = context.assets.open("runtime/runtime.sha256").bufferedReader().use { it.readText().trim() }
        require(expected.matches(Regex("[0-9a-f]{64}"))) { "Invalid runtime checksum" }
        val parent = File(context.noBackupFilesDir, "runtimes").apply { mkdirs() }
        val target = File(parent, expected)
        if (File(target, ".complete").isFile) return target
        val archive = File(context.cacheDir, "runtime-$expected.zip")
        val digest = MessageDigest.getInstance("SHA-256")
        var sinceProgress = 0L
        context.assets.open("runtime/runtime.zip").use { source ->
            archive.outputStream().use { destination ->
                val buffer = ByteArray(COPY_BUFFER_BYTES)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                    destination.write(buffer, 0, count)
                    sinceProgress += count
                    if (sinceProgress >= PROGRESS_INTERVAL_BYTES) {
                        sinceProgress = 0
                        onProgress?.invoke()
                    }
                }
            }
        }
        check(digest.digest().joinToString("") { "%02x".format(it) } == expected) { "Runtime checksum mismatch" }
        val staging = File(parent, "$expected-${System.nanoTime()}").apply { mkdirs() }
        val prefix = staging.canonicalPath + File.separator
        ZipInputStream(archive.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val file = File(staging, entry.name)
                require(file.canonicalPath.startsWith(prefix)) { "Runtime archive path escapes its directory" }
                if (entry.isDirectory) file.mkdirs() else {
                    file.parentFile!!.mkdirs()
                    file.outputStream().use { output ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            val count = zip.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            sinceProgress += count
                            if (sinceProgress >= PROGRESS_INTERVAL_BYTES) {
                                sinceProgress = 0
                                onProgress?.invoke()
                            }
                        }
                    }
                }
                zip.closeEntry()
                onProgress?.invoke()
            }
        }
        File(staging, ".complete").writeText(expected)
        check(staging.renameTo(target)) { "Cannot publish verified runtime" }
        archive.delete()
        return target
    }
}
