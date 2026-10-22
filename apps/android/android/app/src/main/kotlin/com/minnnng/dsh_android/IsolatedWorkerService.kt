package com.minnnng.dsh_android

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.RemoteException
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Separate-UID descriptor bridge for proving Android worker isolation before PTC is enabled. */
class IsolatedWorkerService : Service() {
    companion object {
        const val PROBE = 1
        const val RESULT = 2
        const val INPUT = "input"
        const val TOKEN = "token"
        const val UID = "uid"
        const val BYTES = "bytes"
        const val SHA256 = "sha256"
        const val PRIVATE_ACCESS = "privateAccess"
        const val PRIVATE_PATH = "privatePath"
        const val ERROR = "error"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what != PROBE) return@Handler true
        val reply = message.replyTo ?: return@Handler true
        val data = message.data
        val descriptor = @Suppress("DEPRECATION") (data.getParcelable<ParcelFileDescriptor>(INPUT))
        val token = data.getString(TOKEN)
        if (descriptor == null || token == null || !Regex("[0-9a-f-]{36}").matches(token)) {
            descriptor?.close()
            send(reply, Bundle().apply { putString(ERROR, "Invalid isolated-worker probe") })
            return@Handler true
        }
        if (!busy.compareAndSet(false, true)) {
            descriptor.close()
            send(reply, Bundle().apply { putString(ERROR, "Isolated worker is busy") })
            return@Handler true
        }
        try { worker.execute {
            val result = Bundle()
            try {
                descriptor.use { fd ->
                    val stat = Os.fstat(fd.fileDescriptor)
                    require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 0..IsolatedWorkerInput.MAX_BYTES.toLong()) {
                        "Isolated-worker input must be a regular file of at most 256 KiB"
                    }
                    val digest = ParcelFileDescriptor.AutoCloseInputStream(fd).use { IsolatedWorkerInput.digest(it) }
                    result.putInt(UID, Process.myUid())
                    result.putInt(BYTES, digest.bytes())
                    result.putString(SHA256, digest.sha256())
                    val privateProbe = File(applicationInfo.dataDir, "files/ptc-isolation-$token")
                    result.putString(PRIVATE_PATH, privateProbe.absolutePath)
                    val privateAccess = try {
                        Os.close(Os.open(privateProbe.absolutePath, OsConstants.O_RDONLY, 0))
                        "readable"
                    } catch (error: ErrnoException) {
                        when (error.errno) {
                            OsConstants.EACCES, OsConstants.EPERM -> "denied"
                            OsConstants.ENOENT -> "missing"
                            else -> "errno:${error.errno}"
                        }
                    }
                    result.putString(PRIVATE_ACCESS, privateAccess)
                }
            } catch (error: Exception) {
                result.putString(ERROR, error.message ?: "Isolated-worker probe failed")
            } finally {
                busy.set(false)
            }
            send(reply, result)
        } } catch (_: RejectedExecutionException) {
            busy.set(false)
            descriptor.close()
            send(reply, Bundle().apply { putString(ERROR, "Isolated worker is stopping") })
        }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun send(reply: Messenger, data: Bundle) {
        try { reply.send(Message.obtain(null, RESULT).apply { this.data = data }) }
        catch (_: RemoteException) { /* Caller death closes its descriptor and owns the timeout. */ }
    }
}
