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
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** Host-side, internal-only boundary probe. A pass is diagnostic evidence, never Shell admission. */
internal object IsolatedShellProbe {
    private const val DEADLINE_MS = 5_000L

    data class Result(val kind: GuestTerminal.Kind, val workerUid: Int?, val detail: String?) {
        val verified: Boolean get() = kind == GuestTerminal.Kind.COMPLETED
    }

    /** Must be called off the UI thread. No caller-controlled script, path, or socket is accepted. */
    fun inspect(context: Context, cancelled: BooleanSupplier): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Shell probe cannot block the main thread" }
        val app = context.applicationContext
        val privatePath = app.applicationInfo.dataDir
        if (!File(privatePath).isDirectory) return Result(GuestTerminal.Kind.ERROR, null, "App private directory unavailable")
        val id = UUID.randomUUID().toString()
        val privateMarker = File(privatePath, ".pocket-shell-probe-$id")
        if (privateMarker.exists()) return Result(GuestTerminal.Kind.ERROR, null, "Shell probe marker already exists")
        val finished = CountDownLatch(1)
        val outcome = AtomicReference<Result?>()
        val active = AtomicBoolean(true)
        val remote = AtomicReference<Messenger?>()
        val deathLink = AtomicReference<Pair<IBinder, IBinder.DeathRecipient>?>()
        val sendLock = Any()

        fun finish(result: Result) {
            if (outcome.compareAndSet(null, result)) finished.countDown()
        }

        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                if (!active.get() || outcome.get() != null || message.what != IsolatedShellProbeService.COMPLETE) return@Handler true
                val data = message.data
                val sender = message.sendingUid
                val reported = data.getInt(IsolatedShellProbeService.UID, -1)
                if (data.getString(IsolatedShellProbeService.ID) != id ||
                    data.getString(IsolatedShellProbeService.PRIVATE_PATH) != privatePath) {
                    finish(Result(GuestTerminal.Kind.ERROR, null, "Shell probe response identity/path mismatch"))
                    return@Handler true
                }
                val error = data.getString(IsolatedShellProbeService.ERROR)
                val rejection = ShellProbeEvidence.rejection(
                    Process.myUid(), sender, reported,
                    data.getBoolean(IsolatedShellProbeService.ISOLATED, false),
                    data.getBoolean(IsolatedShellProbeService.PRIVATE_READABLE, true),
                    data.getBoolean(IsolatedShellProbeService.PRIVATE_WRITABLE, true),
                    privateMarker.exists(),
                    data.getBoolean(IsolatedShellProbeService.INET_OPENED, true),
                    data.getBoolean(IsolatedShellProbeService.SHELL_COMPLETED, false),
                    data.getString(IsolatedShellProbeService.OUTPUT),
                )
                val apiUidCheck = if (Build.VERSION.SDK_INT >= 34 && !Process.isIsolatedUid(sender))
                    "Android did not classify the sender UID as isolated" else null
                val detail = error ?: apiUidCheck ?: rejection
                finish(Result(if (detail == null) GuestTerminal.Kind.COMPLETED else GuestTerminal.Kind.ERROR,
                    sender.takeIf { it >= 0 }, detail))
            } catch (_: Exception) {
                finish(Result(GuestTerminal.Kind.ERROR, null, "Shell probe Binder envelope rejected"))
            }
            true
        })

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    synchronized(sendLock) {
                        if (!active.get() || outcome.get() != null) return
                        val death = IBinder.DeathRecipient {
                            finish(Result(GuestTerminal.Kind.WORKER_DIED, null, "Shell probe process died"))
                        }
                        binder.linkToDeath(death, 0)
                        deathLink.set(binder to death)
                        if (outcome.get() != null) return
                        val worker = Messenger(binder)
                        remote.set(worker)
                        worker.send(Message.obtain(null, IsolatedShellProbeService.REQUEST).apply {
                            replyTo = replies
                            data = Bundle().apply { putString(IsolatedShellProbeService.ID, id) }
                        })
                    }
                } catch (e: Exception) {
                    finish(Result(GuestTerminal.Kind.ERROR, null, e.message ?: "Shell probe binding failed"))
                }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                finish(Result(GuestTerminal.Kind.WORKER_DIED, null, "Shell probe disconnected"))
            }
            override fun onBindingDied(name: ComponentName) {
                finish(Result(GuestTerminal.Kind.WORKER_DIED, null, "Shell probe binding died"))
            }
            override fun onNullBinding(name: ComponentName) {
                finish(Result(GuestTerminal.Kind.ERROR, null, "Shell probe returned no binder"))
            }
        }

        var bound = false
        try {
            val intent = Intent(app, IsolatedShellProbeService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "shell_probe_" + UUID.randomUUID().toString().replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated Shell probe" }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DEADLINE_MS)
            while (outcome.get() == null) {
                if (cancelled.getAsBoolean()) {
                    finish(Result(GuestTerminal.Kind.CANCELLED, null, "Shell probe cancelled"))
                    break
                }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) {
                    finish(Result(GuestTerminal.Kind.TIMED_OUT, null, "Shell probe exceeded five seconds"))
                    break
                }
                finished.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            finish(Result(GuestTerminal.Kind.CANCELLED, null, "Shell probe caller interrupted"))
        } catch (e: Exception) {
            finish(Result(GuestTerminal.Kind.ERROR, null, e.message ?: "Shell probe request failed"))
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (outcome.get()?.kind != GuestTerminal.Kind.COMPLETED) {
                    try {
                        remote.get()?.send(Message.obtain(null, IsolatedShellProbeService.CANCEL).apply {
                            data = Bundle().apply { putString(IsolatedShellProbeService.ID, id) }
                        })
                    } catch (_: Exception) { /* Death/timeout is already terminal. */ }
                }
                deathLink.getAndSet(null)?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
            }
            if (bound) app.unbindService(connection)
            // Only this randomly named diagnostic marker is ever cleaned up;
            // a failed isolation check must not leave it in the App workspace.
            if (privateMarker.exists()) privateMarker.delete()
        }
        return checkNotNull(outcome.get())
    }
}
