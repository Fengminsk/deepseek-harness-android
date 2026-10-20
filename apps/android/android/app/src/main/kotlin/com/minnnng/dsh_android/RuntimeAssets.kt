package com.minnnng.dsh_android

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Immutable runtime payloads are verified before a complete directory is published. */
object RuntimeAssets {
    fun prepare(context: Context): File {
        val expected = context.assets.open("runtime/runtime.sha256").bufferedReader().use { it.readText().trim() }
        require(expected.matches(Regex("[0-9a-f]{64}"))) { "Invalid runtime checksum" }
        val parent = File(context.noBackupFilesDir, "runtimes").apply { mkdirs() }
        val target = File(parent, expected)
        if (File(target, ".complete").isFile) return target
        val archive = File(context.cacheDir, "runtime-$expected.zip")
        val digest = MessageDigest.getInstance("SHA-256")
        context.assets.open("runtime/runtime.zip").use { source ->
            archive.outputStream().use { destination ->
                val buffer = ByteArray(65536)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                    destination.write(buffer, 0, count)
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
                    file.outputStream().use { zip.copyTo(it) }
                }
                zip.closeEntry()
            }
        }
        File(staging, ".complete").writeText(expected)
        check(staging.renameTo(target)) { "Cannot publish verified runtime" }
        archive.delete()
        return target
    }
}
