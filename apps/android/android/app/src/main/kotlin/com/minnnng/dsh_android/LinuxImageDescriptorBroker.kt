package com.minnnng.dsh_android

import android.content.Context
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import java.io.FileDescriptor
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** App-side, data-only transport. No guest, model, Shell, or PRoot entry point is connected. */
internal class LinuxImageDescriptorBroker(context: Context) : AutoCloseable {
    private val owner = LinuxImageLeaseOwner(
        context.noBackupFilesDir.toPath().resolve("linux-userland"),
    )
    private val snapshotSlots = Semaphore(2)

    class Descriptor internal constructor(
        val image: SharedMemory,
        val sha256: String,
        val version: String,
        val abi: String,
        val bytes: Long,
        val expiresAtMillis: Long,
        private val releaseSlot: () -> Unit,
    ) : AutoCloseable {
        private val closed = AtomicBoolean(false)
        override fun close() {
            if (closed.compareAndSet(false, true)) {
                image.close()
                releaseSlot()
            }
        }
    }

    fun issue(runId: String, leaseMillis: Long): LinuxImageLeaseOwner.Offer =
        owner.issue(runId, leaseMillis)

    /** A claim consumes its token even when snapshot creation fails. */
    fun claim(runId: String, token: String): Descriptor {
        val claimed = owner.claim(runId, token)
        if (!snapshotSlots.tryAcquire()) throw IOException("Image snapshot capacity reached")
        try {
            val raw = Os.open(claimed.archive().toString(),
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
            val image = try {
                LinuxImageImmutableSnapshot.copyAndSeal(raw, claimed.bytes(),
                    claimed.sha256(), claimed.expiresAtMillis())
            } finally {
                Os.close(raw)
            }
            return Descriptor(image, claimed.sha256(), LinuxImageLeaseOwner.VERSION,
                LinuxImageLeaseOwner.ABI, claimed.bytes(), claimed.expiresAtMillis()) {
                snapshotSlots.release()
            }
        } catch (failure: Exception) {
            snapshotSlots.release()
            throw failure
        }
    }

    fun revoke(runId: String) = owner.revoke(runId)

    override fun close() = owner.close()
}

/**
 * Copy into anonymous SharedMemory, remove the only writable mapping, then
 * downgrade the FD before it can escape. setProtect affects future mappings,
 * not old ones, so the unmap ordering is a security requirement.
 */
internal object LinuxImageImmutableSnapshot {
    private const val MAX_BYTES = 8 * 1024 * 1024

    fun copyAndSeal(
        source: FileDescriptor,
        expectedBytes: Long,
        expectedSha256: String,
        expiresAtMillis: Long,
    ): SharedMemory {
        if (expectedBytes <= 0 || expectedBytes > MAX_BYTES) {
            throw IOException("Image snapshot exceeds bounded capacity")
        }
        val before = Os.fstat(source)
        if ((before.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFREG ||
            before.st_size != expectedBytes) throw IOException("Image source identity changed")
        val snapshot = SharedMemory.create("pocket-linux-image", expectedBytes.toInt())
        try {
            var writable: ByteBuffer? = null
            try {
                writable = snapshot.mapReadWrite()
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                var copied = 0L
                while (copied < expectedBytes) {
                    val read = Os.read(source, buffer, 0,
                        minOf(buffer.size.toLong(), expectedBytes - copied).toInt())
                    if (read <= 0) throw IOException("Image source ended during snapshot")
                    writable.put(buffer, 0, read)
                    digest.update(buffer, 0, read)
                    copied += read
                }
                val after = Os.fstat(source)
                if (Os.read(source, buffer, 0, 1) != 0 ||
                    before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
                    before.st_size != after.st_size || before.st_mtime != after.st_mtime ||
                    before.st_ctime != after.st_ctime ||
                    ImageDigestHex.encode(digest.digest()) != expectedSha256 ||
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= expiresAtMillis) {
                    throw IOException("Image source or lease changed during snapshot")
                }
            } finally {
                writable?.let { SharedMemory.unmap(it) }
            }
            if (!snapshot.setProtect(OsConstants.PROT_READ)) {
                throw IOException("Image snapshot could not be protected")
            }
            val readable = snapshot.mapReadOnly()
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                while (readable.hasRemaining()) {
                    val length = minOf(buffer.size, readable.remaining())
                    readable.get(buffer, 0, length)
                    digest.update(buffer, 0, length)
                }
                if (ImageDigestHex.encode(digest.digest()) != expectedSha256) {
                    throw IOException("Protected image snapshot digest changed")
                }
            } finally {
                SharedMemory.unmap(readable)
            }
            return snapshot
        } catch (failure: Exception) {
            snapshot.close()
            throw failure
        }
    }
}
