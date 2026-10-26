package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** Device acceptance for source replacement and post-seal write rejection. */
class LinuxImageSnapshotInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val source = File(targetContext.cacheDir, "linux-image-snapshot-test-${System.nanoTime()}")
        try {
            val original = ByteArray(4096) { (it % 239).toByte() }
            source.writeBytes(original)
            val hash = MessageDigest.getInstance("SHA-256").digest(original)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val fd = Os.open(source.absolutePath,
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
            val snapshot = try {
                LinuxImageImmutableSnapshot.copyAndSeal(fd, original.size.toLong(), hash,
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) + 30_000)
            } finally {
                Os.close(fd)
            }
            try {
                // The App-owned archive may still be replaced after claim.
                source.writeBytes(ByteArray(original.size) { 0x5a.toByte() })
                val mapped = snapshot.mapReadOnly()
                try {
                    val observed = ByteArray(original.size)
                    mapped.get(observed)
                    check(observed.contentEquals(original)) {
                        "Source mutation changed the detached image snapshot"
                    }
                } finally {
                    SharedMemory.unmap(mapped)
                }
                var writableMapped = false
                try {
                    val writable = snapshot.mapReadWrite()
                    writableMapped = true
                    SharedMemory.unmap(writable)
                } catch (_: Exception) {
                    // The protected descriptor must reject any new write mapping.
                }
                check(!writableMapped) { "Protected image still permits writable mapping" }
            } finally {
                snapshot.close()
            }
            finish(Activity.RESULT_OK, Bundle().apply { putString("result", "snapshot-immutable-pass") })
        } catch (failure: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "snapshot-immutable-fail: ${failure.message}")
            })
        } finally {
            source.delete()
        }
    }
}
