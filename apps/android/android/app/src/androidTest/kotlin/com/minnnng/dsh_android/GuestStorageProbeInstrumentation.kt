package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Fixed synthetic data only; this instrumentation does not install or run a Linux rootfs. */
class GuestStorageProbeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val id = UUID.randomUUID().toString()
        val root = targetContext.noBackupFilesDir.toPath().resolve("guest-storage-probe-$id")
        var report = Bundle()
        var outcome = Activity.RESULT_CANCELED
        try {
            Files.createDirectory(root)
            val marker = "pocket-probe-$id".toByteArray(Charsets.US_ASCII)
            val fixture = root.resolve("fixture.txt")
            Files.write(fixture, marker)
            val rawDirectory = Os.open(root.toString(),
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
            try {
                check(OsConstants.S_ISDIR(Os.fstat(rawDirectory).st_mode)) {
                    "Synthetic directory FD did not refer to a directory"
                }
                ParcelFileDescriptor.dup(rawDirectory).use { directory ->
                    ParcelFileDescriptor.open(fixture.toFile(), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                        SharedMemory.create("guest-storage-probe", marker.size).use { memory ->
                            val mapped = memory.mapReadWrite()
                            try { mapped.put(marker) } finally { SharedMemory.unmap(mapped) }
                            check(memory.setProtect(OsConstants.PROT_READ)) {
                                "Could not seal synthetic shared memory"
                            }
                            report = runProbe(id, fd, directory, memory)
                        }
                    }
                }
            } finally { Os.close(rawDirectory) }
            check(Files.readAllBytes(fixture).contentEquals(marker)) {
                "Read-only fixture changed during isolated probe"
            }
            val required = arrayOf(DebugGuestStorageProbeService.PRIVATE_READ to DebugGuestStorageProbeService.DENIED,
                DebugGuestStorageProbeService.PRIVATE_WRITE to DebugGuestStorageProbeService.DENIED,
                DebugGuestStorageProbeService.FD_READ to DebugGuestStorageProbeService.ALLOWED,
                DebugGuestStorageProbeService.FD_WRITE to DebugGuestStorageProbeService.DENIED,
                DebugGuestStorageProbeService.DIRECTORY_CHILD_READ to DebugGuestStorageProbeService.DENIED,
                DebugGuestStorageProbeService.DIRECTORY_CHILD_WRITE to DebugGuestStorageProbeService.DENIED,
                DebugGuestStorageProbeService.MEMORY_READ to DebugGuestStorageProbeService.ALLOWED,
                DebugGuestStorageProbeService.MEMORY_WRITE to DebugGuestStorageProbeService.DENIED)
            check(required.all { (key, expected) -> report.getString(key) == expected }) {
                "Isolation or read-only transfer requirement was not observed"
            }
            for (key in arrayOf(DebugGuestStorageProbeService.TEMP_WRITE,
                    DebugGuestStorageProbeService.TEMP_READ,
                    DebugGuestStorageProbeService.TEMP_EXEC,
                    DebugGuestStorageProbeService.TEMP_EXEC_MAP)) {
                check(report.getString(key) in arrayOf(DebugGuestStorageProbeService.ALLOWED,
                    DebugGuestStorageProbeService.DENIED,
                    DebugGuestStorageProbeService.UNTESTED)) { "Missing temp observation" }
            }
            outcome = Activity.RESULT_OK
            report.putString("result", "guest-storage-probe-pass")
        } catch (failure: Throwable) {
            report.putString("result", "guest-storage-probe-fail")
            report.putString("detail", failure.message?.take(160) ?: "Probe failed")
        } finally {
            try {
                Files.deleteIfExists(targetContext.cacheDir.toPath().resolve("guest-storage-probe-$id.txt"))
                Files.deleteIfExists(targetContext.cacheDir.toPath().resolve("guest-storage-probe-$id.sh"))
                Files.deleteIfExists(root.resolve("guest-created.txt"))
                Files.deleteIfExists(root.resolve("fixture.txt"))
                Files.deleteIfExists(root)
            } catch (_: Exception) {
                outcome = Activity.RESULT_CANCELED
                report.putString("result", "guest-storage-probe-fail")
                report.putString("detail", "Synthetic fixture cleanup failed")
            }
            finish(outcome, report)
        }
    }

    private fun runProbe(id: String, fd: ParcelFileDescriptor,
                         directory: ParcelFileDescriptor, memory: SharedMemory): Bundle {
        val app = targetContext.applicationContext
        val latch = CountDownLatch(1)
        val answer = AtomicReference<Bundle?>()
        val failure = AtomicReference<String?>()
        var bound = false
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (message.what == DebugGuestStorageProbeService.RESULT &&
                message.data.getString(DebugGuestStorageProbeService.ID) == id &&
                message.sendingUid >= 0 && message.sendingUid != Process.myUid() &&
                message.sendingUid == message.data.getInt(DebugGuestStorageProbeService.UID, -1) &&
                message.data.getBoolean(DebugGuestStorageProbeService.ISOLATED, false)) {
                answer.set(Bundle(message.data))
            } else failure.set("Isolated probe identity or reply was invalid")
            latch.countDown()
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    Messenger(binder).send(Message.obtain(null,
                        DebugGuestStorageProbeService.REQUEST).apply {
                        replyTo = replies
                        data = Bundle().apply {
                            putString(DebugGuestStorageProbeService.ID, id)
                            putParcelable(DebugGuestStorageProbeService.FD, fd)
                            putParcelable(DebugGuestStorageProbeService.DIRECTORY_FD, directory)
                            putParcelable(DebugGuestStorageProbeService.MEMORY, memory)
                        }
                    })
                } catch (_: Exception) {
                    failure.set("Could not submit synthetic probe")
                    latch.countDown()
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                failure.set("Isolated probe disconnected")
                latch.countDown()
            }
        }
        try {
            val intent = Intent(app, DebugGuestStorageProbeService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "storage_" + id.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated storage probe" }
            check(latch.await(15, TimeUnit.SECONDS)) { "Isolated storage probe timed out" }
            check(failure.get() == null) { failure.get() ?: "Probe failure" }
            val result = checkNotNull(answer.get()) { "Probe produced no result" }
            check(result.getString(DebugGuestStorageProbeService.STATE) == "observed") {
                "Probe did not observe storage capabilities"
            }
            return result
        } finally {
            if (bound) app.unbindService(connection)
        }
    }
}
