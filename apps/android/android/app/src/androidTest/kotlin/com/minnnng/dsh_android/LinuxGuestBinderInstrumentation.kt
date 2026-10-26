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
import android.os.Process
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Device-only UID/nonce handshake check. It never launches Linux or asks for a broker call. */
class LinuxGuestBinderInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val app = targetContext.applicationContext
        val runId = UUID.randomUUID().toString()
        val nonce = UUID.randomUUID().toString()
        val finished = CountDownLatch(1)
        val outcome = AtomicReference<String?>()
        val remote = AtomicReference<Messenger?>()
        val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
            val observed = try {
                val data = message.data
                if (message.what == IsolatedLinuxGuestBinderService.HELLO &&
                    message.sendingUid > 0 && message.sendingUid != Process.myUid() &&
                    data.getInt(IsolatedLinuxGuestBinderService.UID, -1) == message.sendingUid &&
                    data.getBoolean(IsolatedLinuxGuestBinderService.ISOLATED, false) &&
                    data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                    data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce) "pass"
                    else "Isolated Binder UID or nonce was invalid"
            } catch (_: Exception) { "Isolated Binder envelope was invalid" }
            outcome.compareAndSet(null, observed)
            finished.countDown()
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    val guest = Messenger(binder)
                    remote.set(guest)
                    guest.send(Message.obtain(null, IsolatedLinuxGuestBinderService.OPEN).apply {
                        replyTo = reply
                        data = Bundle().apply {
                            putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                            putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                        }
                    })
                } catch (_: Exception) {
                    outcome.compareAndSet(null, "Could not send Binder OPEN")
                    finished.countDown()
                }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                outcome.compareAndSet(null, "Isolated Binder service disconnected")
                finished.countDown()
            }
        }
        var bound = false
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        try {
            val intent = Intent(app, IsolatedLinuxGuestBinderService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "binder_probe_" + nonce.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound && finished.await(5, TimeUnit.SECONDS)) { "Isolated Binder handshake timed out" }
            check(outcome.get() == "pass") { outcome.get() ?: "Isolated Binder handshake failed" }
            code = Activity.RESULT_OK
            result.putString("result", "linux-guest-binder-handshake-pass")
        } catch (failure: Exception) {
            result.putString("result", "linux-guest-binder-handshake-fail")
            result.putString("detail", failure.message?.take(160) ?: "Handshake failed")
        } finally {
            runCatching {
                remote.get()?.send(Message.obtain(null, IsolatedLinuxGuestBinderService.CANCEL).apply {
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    }
                })
            }
            if (bound) runCatching { app.unbindService(connection) }
            finish(code, result)
        }
    }
}
