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
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Per-call App-granted text descriptor transport; it does not accept a path or run model code. */
object IsolatedWorkerBridge {
    data class Text(val workerUid: Int, val content: String)
    private data class Outcome(val text: Text? = null, val error: Throwable? = null)

    /** Caller retains [input] and must invoke this from a background thread. */
    fun readText(context: Context, input: ParcelFileDescriptor): Text {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated-worker read cannot block the main thread" }
        val app = context.applicationContext
        val id = UUID.randomUUID().toString()
        val finished = CountDownLatch(1)
        val outcome = AtomicReference<Outcome?>()
        val remote = AtomicReference<Messenger?>()
        val active = AtomicBoolean(true)
        val sendLock = Any()
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (message.what == IsolatedWorkerService.RESULT) {
                val received = try { Outcome(text = parse(message.data, id)) }
                    catch (error: Exception) { Outcome(error = error) }
                if (outcome.compareAndSet(null, received)) finished.countDown()
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val worker = Messenger(binder)
                try {
                    synchronized(sendLock) {
                        remote.set(worker)
                        if (!active.get() || outcome.get() != null) return
                        ParcelFileDescriptor.dup(input.fileDescriptor).use { copy ->
                            val request = Message.obtain(null, IsolatedWorkerService.READ_TEXT)
                            request.replyTo = replies
                            request.data = Bundle().apply {
                                putString(IsolatedWorkerService.REQUEST_ID, id)
                                putParcelable(IsolatedWorkerService.INPUT, copy)
                            }
                            worker.send(request)
                        }
                    }
                } catch (error: Exception) { fail(error) }
            }

            override fun onServiceDisconnected(name: ComponentName) = fail(IllegalStateException("Isolated worker disconnected"))
            override fun onBindingDied(name: ComponentName) = fail(IllegalStateException("Isolated worker binding died"))
            override fun onNullBinding(name: ComponentName) = fail(IllegalStateException("Isolated worker returned no binder"))

            private fun fail(error: Exception) {
                if (outcome.compareAndSet(null, Outcome(error = error))) finished.countDown()
            }
        }
        var bound = false
        var terminal = false
        try {
            bound = app.bindService(Intent(app, IsolatedWorkerService::class.java), connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated worker" }
            check(finished.await(5, TimeUnit.SECONDS)) { "Isolated worker did not answer within 5 seconds" }
            val result = checkNotNull(outcome.get()) { "Isolated worker returned no outcome" }
            result.error?.let { throw it }
            terminal = true
            return checkNotNull(result.text) { "Isolated worker returned no text" }
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (!terminal) {
                    try {
                        remote.get()?.send(Message.obtain(null, IsolatedWorkerService.CANCEL).apply {
                            data = Bundle().apply { putString(IsolatedWorkerService.REQUEST_ID, id) }
                        })
                    } catch (_: Exception) { /* A dead worker cannot keep processing this request. */ }
                }
            }
            if (bound) app.unbindService(connection)
        }
    }

    private fun parse(data: Bundle, id: String): Text {
        check(data.getString(IsolatedWorkerService.REQUEST_ID) == id) { "Isolated worker answered a different request" }
        data.getString(IsolatedWorkerService.ERROR)?.let { throw IllegalStateException(it) }
        val uid = data.getInt(IsolatedWorkerService.UID, -1)
        check(uid >= 0 && uid != Process.myUid()) { "Worker did not run under a separate UID" }
        val text = checkNotNull(data.getString(IsolatedWorkerService.TEXT)) { "Isolated worker returned no text" }
        check(text.toByteArray(Charsets.UTF_8).size <= IsolatedWorkerInput.MAX_TEXT_BYTES) {
            "Isolated worker text exceeds 64 KiB"
        }
        return Text(uid, text)
    }
}
