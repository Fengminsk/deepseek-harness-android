package com.minnnng.dsh_android

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
import android.os.Process
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** App-side diagnostic broker for one admitted echo request; no model script reaches this backend. */
internal object IsolatedGuestBackend {
    private const val DEADLINE_SECONDS = 5L
    private const val DIAGNOSTIC_TEXT = "pocket-harness-isolated-guest"

    data class Result(
        val kind: GuestTerminal.Kind,
        val json: String?,
        val workerUid: Int?,
        val detail: String?,
    )

    /** Runs only off the main thread. A finished request ignores all later Binder callbacks. */
    fun inspect(context: Context, cancelled: BooleanSupplier): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Guest broker cannot block the main thread" }
        val requestJson = GuestEchoFrame.requestForText(DIAGNOSTIC_TEXT)
        val text = GuestEchoFrame.request(requestJson)
        val expectedCompletion = GuestEchoFrame.completionForText(text)
        val app = context.applicationContext
        val id = UUID.randomUUID().toString()
        val terminal = GuestTerminal()
        val finished = CountDownLatch(1)
        val active = AtomicBoolean(true)
        val remote = AtomicReference<Messenger?>()
        val deathLink = AtomicReference<Pair<IBinder, IBinder.DeathRecipient>?>()
        val workerUid = AtomicInteger(-1)
        val brokerUsed = AtomicBoolean(false)
        val sendLock = Any()

        fun finish(kind: GuestTerminal.Kind, json: String? = null, detail: String? = null) {
            if (terminal.finish(GuestTerminal.Outcome(kind, json, detail))) finished.countDown()
        }

        fun checkSender(message: Message): Boolean {
            val sender = message.sendingUid
            val reported = message.data.getInt(IsolatedGuestService.UID, -1)
            if (sender < 0 || sender == Process.myUid() || sender != reported) return false
            val previous = workerUid.get()
            if (previous >= 0 && previous != sender) return false
            workerUid.compareAndSet(-1, sender)
            return true
        }

        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
            if (!active.get() || terminal.outcome() != null) return@Handler true
            if (message.what != IsolatedGuestService.BROKER_CALL && message.what != IsolatedGuestService.COMPLETE) {
                return@Handler true
            }
            if (!checkSender(message) || message.data.getString(IsolatedGuestService.ID) != id) {
                finish(GuestTerminal.Kind.ERROR, detail = "Guest response failed identity validation")
                return@Handler true
            }
            when (message.what) {
                IsolatedGuestService.BROKER_CALL -> {
                    if (!brokerUsed.compareAndSet(false, true)) {
                        finish(GuestTerminal.Kind.ERROR, detail = "Guest requested a second broker call")
                        return@Handler true
                    }
                    val callId = message.data.getString(IsolatedGuestService.CALL_ID)
                    val call = message.data.getString(IsolatedGuestService.JSON)
                    try {
                        check(callId != null && UUID.fromString(callId).toString() == callId)
                        val echoed = GuestEchoFrame.request(checkNotNull(call))
                        check(echoed == text) { "Guest changed echo request" }
                        val brokerJson = GuestEchoFrame.brokerResultForText(echoed)
                        synchronized(sendLock) {
                            if (active.get() && terminal.outcome() == null) {
                                checkNotNull(remote.get()).send(Message.obtain(null, IsolatedGuestService.BROKER_RESULT).apply {
                                    data = Bundle().apply {
                                        putString(IsolatedGuestService.ID, id)
                                        putString(IsolatedGuestService.CALL_ID, callId)
                                        putString(IsolatedGuestService.JSON, brokerJson)
                                    }
                                })
                            }
                        }
                    } catch (_: Exception) {
                        finish(GuestTerminal.Kind.ERROR, detail = "Guest broker call rejected")
                    }
                }
                IsolatedGuestService.COMPLETE -> {
                    val data = message.data
                    when (data.getString(IsolatedGuestService.STATUS)) {
                        "completed" -> try {
                            check(brokerUsed.get()) { "Guest skipped broker call" }
                            val echoed = GuestEchoFrame.completion(checkNotNull(data.getString(IsolatedGuestService.JSON)))
                            check(echoed == text) { "Guest returned a different echo result" }
                            finish(GuestTerminal.Kind.COMPLETED, expectedCompletion)
                        } catch (_: Exception) {
                            finish(GuestTerminal.Kind.ERROR, detail = "Guest completion rejected")
                        }
                        "cancelled" -> finish(GuestTerminal.Kind.CANCELLED)
                        else -> finish(GuestTerminal.Kind.ERROR, detail = data.getString(IsolatedGuestService.ERROR) ?: "Guest failed")
                    }
                }
            }
            } catch (_: Exception) {
                finish(GuestTerminal.Kind.ERROR, detail = "Guest Binder envelope rejected")
            }
            true
        })

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    synchronized(sendLock) {
                        if (!active.get() || terminal.outcome() != null) return
                        val death = IBinder.DeathRecipient { finish(GuestTerminal.Kind.WORKER_DIED, detail = "Guest process died") }
                        binder.linkToDeath(death, 0)
                        deathLink.set(binder to death)
                        if (terminal.outcome() != null) return
                        val worker = Messenger(binder)
                        remote.set(worker)
                        worker.send(Message.obtain(null, IsolatedGuestService.REQUEST).apply {
                            replyTo = replies
                            data = Bundle().apply {
                                putString(IsolatedGuestService.ID, id)
                                putString(IsolatedGuestService.JSON, requestJson)
                            }
                        })
                    }
                } catch (error: Exception) { finish(GuestTerminal.Kind.ERROR, detail = error.message ?: "Guest binding failed") }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                finish(GuestTerminal.Kind.WORKER_DIED, detail = "Guest disconnected")
            }
            override fun onBindingDied(name: ComponentName) {
                finish(GuestTerminal.Kind.WORKER_DIED, detail = "Guest binding died")
            }
            override fun onNullBinding(name: ComponentName) {
                finish(GuestTerminal.Kind.ERROR, detail = "Guest returned no binder")
            }
        }

        var bound = false
        try {
            val intent = Intent(app, IsolatedGuestService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val instance = "guest_" + UUID.randomUUID().toString().replace("-", "")
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE, instance, app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind diagnostic guest" }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(DEADLINE_SECONDS)
            while (terminal.outcome() == null) {
                if (cancelled.getAsBoolean()) {
                    finish(GuestTerminal.Kind.CANCELLED)
                    break
                }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) {
                    finish(GuestTerminal.Kind.TIMED_OUT, detail = "Guest did not answer within 5 seconds")
                    break
                }
                finished.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            finish(GuestTerminal.Kind.CANCELLED, detail = "Guest caller interrupted")
        } catch (error: Exception) {
            finish(GuestTerminal.Kind.ERROR, detail = error.message ?: "Guest request failed")
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (terminal.outcome()?.kind != GuestTerminal.Kind.COMPLETED) {
                    try {
                        remote.get()?.send(Message.obtain(null, IsolatedGuestService.CANCEL).apply {
                            data = Bundle().apply { putString(IsolatedGuestService.ID, id) }
                        })
                    } catch (_: Exception) { /* Dead or unbound guest cannot continue this diagnostic operation. */ }
                }
                deathLink.getAndSet(null)?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
            }
            if (bound) app.unbindService(connection)
        }
        val outcome = checkNotNull(terminal.outcome())
        return Result(outcome.kind(), outcome.json(), workerUid.get().takeIf { it >= 0 }, outcome.detail())
    }
}
