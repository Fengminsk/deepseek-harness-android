package com.minnnng.dsh_android

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** One-shot device check of separate UID, private-file denial and bounded descriptor delivery. */
object IsolatedWorkerProbe {
    data class Report(val workerUid: Int, val bytes: Int, val sha256: String)
    private data class Outcome(val report: Report? = null, val error: Throwable? = null)

    /** Caller owns [input]; call from a background thread so Service callbacks can run on main. */
    fun inspect(context: Context, input: ParcelFileDescriptor): Report {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated worker probe cannot block the main thread" }
        val app = context.applicationContext
        val token = UUID.randomUUID().toString()
        val marker = File(app.filesDir, "ptc-isolation-$token")
        try {
            marker.writeText(token)
            return inspectBound(app, input, token)
        } finally {
            check(marker.delete() || !marker.exists()) { "Could not remove isolation probe marker" }
        }
    }

    private fun inspectBound(app: Context, input: ParcelFileDescriptor, token: String): Report {
        val finished = CountDownLatch(1)
        val active = AtomicBoolean(true)
        val outcome = AtomicReference<Outcome?>()
        val markerPath = File(app.filesDir, "ptc-isolation-$token").absolutePath
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (message.what == IsolatedWorkerService.RESULT) {
                val data = message.data
                val received = try { Outcome(report = report(data, markerPath, message.sendingUid)) }
                    catch (error: Exception) { Outcome(error = error) }
                outcome.compareAndSet(null, received)
                finished.countDown()
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (!active.get()) return
                try {
                    ParcelFileDescriptor.dup(input.fileDescriptor).use { copy ->
                        val request = Message.obtain(null, IsolatedWorkerService.PROBE)
                        request.replyTo = replies
                        request.data = Bundle().apply {
                            putParcelable(IsolatedWorkerService.INPUT, copy)
                            putString(IsolatedWorkerService.TOKEN, token)
                        }
                        Messenger(binder).send(request)
                    }
                } catch (error: Exception) { fail(error) }
            }

            override fun onServiceDisconnected(name: ComponentName) { fail(IllegalStateException("Isolated worker disconnected")) }
            override fun onBindingDied(name: ComponentName) { fail(IllegalStateException("Isolated worker binding died")) }
            override fun onNullBinding(name: ComponentName) { fail(IllegalStateException("Isolated worker returned no binder")) }

            private fun fail(error: Exception) {
                outcome.compareAndSet(null, Outcome(error = error))
                finished.countDown()
            }
        }
        var bound = false
        try {
            bound = app.bindService(Intent(app, IsolatedWorkerService::class.java), connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated worker" }
            check(finished.await(5, TimeUnit.SECONDS)) { "Isolated worker did not answer within 5 seconds" }
            val result = checkNotNull(outcome.get()) { "Isolated worker returned no outcome" }
            result.error?.let { throw it }
            return checkNotNull(result.report) { "Isolated worker returned no report" }
        } finally {
            active.set(false)
            if (bound) app.unbindService(connection)
        }
    }

    private fun report(data: Bundle, markerPath: String, senderUid: Int): Report {
        val uid = data.getInt(IsolatedWorkerService.UID, -1)
        check(senderUid >= 0 && senderUid == uid && uid != Process.myUid()) {
            "Worker response did not originate from its reported separate UID"
        }
        data.getString(IsolatedWorkerService.ERROR)?.let { throw IllegalStateException(it) }
        check(data.getString(IsolatedWorkerService.PRIVATE_PATH) == markerPath) {
            "Worker checked a different private-file path"
        }
        val privateAccess = data.getString(IsolatedWorkerService.PRIVATE_ACCESS)
        check(privateAccess == "denied") { "Worker private-file check failed: ${privateAccess ?: "no result"}" }
        val bytes = data.getInt(IsolatedWorkerService.BYTES, -1)
        val hash = data.getString(IsolatedWorkerService.SHA256)
        check(bytes in 0..IsolatedWorkerInput.MAX_BYTES && hash?.matches(Regex("[0-9a-f]{64}")) == true) {
            "Isolated worker returned invalid descriptor evidence"
        }
        return Report(uid, bytes, hash)
    }
}
