package com.minnnng.dsh_android

import android.content.Context
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

/** Publishes an App-created export snapshot; the model never supplies a staging path or private root. */
internal object LinuxVmFilePublisher {
    private const val STAGING = "linux-vm/export-staging"
    private const val MAX_PATH_BYTES = 4096
    private const val UNKNOWN_RENAME_ERRNO_BASE = 65536

    /** null means rename returned EIO; true without directorySynced means moved but not confirmed durable. */
    data class Result(val published: Boolean?, val directorySynced: Boolean, val errno: Int)

    init { System.loadLibrary("pocket_linux_vm") }

    /** The controller creates private temporary files here and syncs their bytes before publish. */
    fun stagingDirectory(context: Context): File = File(context.noBackupFilesDir.canonicalFile, STAGING)

    /**
     * Validation failures precede publication. Native failures return their
     * published state and errno; success moves the source and syncs both rename
     * directories. The caller owns the publication lock, cancellation decision
     * and any later receipt/journal. An existing destination is never replaced.
     */
    fun publish(context: Context, stagedPrivateFile: File, destination: String): Result {
        val root = context.noBackupFilesDir.canonicalFile
        val staging = File(root, STAGING)
        require(staging.canonicalFile == staging.absoluteFile
            && Files.isDirectory(staging.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            "Linux export staging directory is invalid"
        }
        val source = stagedPrivateFile.absoluteFile.toPath().normalize().toFile()
        require(source.parentFile == staging && Files.isRegularFile(source.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            "Linux export requires an App-created regular staging file"
        }
        val sourceBytes = relative(source.name, leaf = true)
        val destinationBytes = relative(destination, leaf = false)
        val rootBytes = root.path.toByteArray(Charsets.UTF_8)
        require(rootBytes.size in 1..MAX_PATH_BYTES && String(rootBytes, Charsets.UTF_8) == root.path) {
            "Linux export private root encoding is invalid"
        }
        val result = publishNative(rootBytes, sourceBytes, destinationBytes)
        return when {
            result == 0 -> Result(published = true, directorySynced = true, errno = 0)
            result > 0 -> Result(published = true, directorySynced = false, errno = result)
            result < -UNKNOWN_RENAME_ERRNO_BASE -> Result(
                published = null, directorySynced = false, errno = -result - UNKNOWN_RENAME_ERRNO_BASE)
            else -> Result(published = false, directorySynced = false, errno = -result)
        }
    }

    private fun relative(value: String, leaf: Boolean): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        require(bytes.size in 1..MAX_PATH_BYTES && String(bytes, Charsets.UTF_8) == value
            && !value.startsWith('/') && !value.contains('\\') && !value.contains(':')
            && value.none { it.code < 32 || it.code == 127 }
            && value.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
            && (!leaf || !value.contains('/'))) {
            "Linux export requires a relative UTF-8 path without parent traversal"
        }
        return bytes
    }

    /** 0: durable; -65536-errno: rename outcome unknown; -errno: no move; +errno: moved, verification/sync failed. */
    private external fun publishNative(root: ByteArray, sourceName: ByteArray, destination: ByteArray): Int
}
