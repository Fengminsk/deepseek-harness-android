package com.minnnng.dsh_android

import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Looper
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Owns a signature-protected, non-visual acceptance service; no wake, unlock or screenshot API is used. */
class AcceptanceServiceLease private constructor(
    private val instrumentation: Instrumentation,
    private val durationMillis: Long,
    private val onFailure: (Throwable) -> Unit,
) : Closeable {
    private val app = instrumentation.targetContext.applicationContext
    private val token = UUID.randomUUID().toString()
    private val permission = "${app.packageName}.permission.RUNTIME_ACCEPTANCE"
    private val ready = CompletableFuture<Boolean>()
    private val closed = CompletableFuture<Boolean>()
    private val registered = AtomicBoolean(false)
    private val closing = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val failure = AtomicReference<IllegalStateException?>()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getStringExtra("token") != token) return
            if (intent.getIntExtra("pid", -1) != android.os.Process.myPid()) {
                fail("Acceptance service is not in the fixture Agent process")
                return
            }
            when (val state = intent.getStringExtra("state")) {
                "ready" -> if (!closing.get() && failure.get() == null) ready.complete(true)
                "rejected" -> { closed.complete(true); fail(intent.getStringExtra("failure") ?: "Service lease rejected") }
                "failed", "close-failed" -> {
                    fail(intent.getStringExtra("failure") ?: "Acceptance service failed")
                    if (state == "close-failed") closed.completeExceptionally(requireNotNull(failure.get()))
                }
                "closed" -> {
                    val reportedFailure = intent.getStringExtra("failure")
                    if (reportedFailure != null) fail(reportedFailure)
                    else if (!closing.get()) fail("Acceptance service stopped before release")
                    closed.complete(true)
                }
            }
        }
    }

    private fun fail(message: String) {
        val error = IllegalStateException(message)
        if (failure.compareAndSet(null, error)) {
            ready.completeExceptionally(error)
            onFailure(error)
        }
    }

    private fun start() {
        val filter = IntentFilter("${app.packageName}.acceptance.service.status")
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, permission, null, Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(receiver, filter, permission, null)
        registered.set(true)
        // Instrumentation grants only FGS launch eligibility; product permissions and lifecycle are unchanged.
        instrumentation.uiAutomation.adoptShellPermissionIdentity("android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND")
        try {
            checkNotNull(app.startForegroundService(Intent().setClassName(app.packageName,
                "${app.packageName}.RuntimeAcceptanceService").putExtra("token", token)
                .putExtra("durationMillis", durationMillis))) { "Acceptance service did not start" }
            started.set(true)
        } finally { instrumentation.uiAutomation.dropShellPermissionIdentity() }
        check(ready.get(20, TimeUnit.SECONDS))
        checkActive()
    }

    fun checkActive() {
        failure.get()?.let { throw it }
        check(!closing.get() && !closed.isDone) { "Acceptance service lease has closed" }
    }

    @Synchronized
    override fun close() {
        if (registered.get()) {
            try {
                if (started.get()) {
                    if (closing.compareAndSet(false, true) && !closed.isDone) app.sendBroadcast(
                        Intent("${app.packageName}.acceptance.service.close").setPackage(app.packageName)
                            .putExtra("token", token), permission)
                    check(closed.get(10, TimeUnit.SECONDS)) { "Acceptance service destruction was not confirmed" }
                }
            } finally {
                if (registered.compareAndSet(true, false)) app.unregisterReceiver(receiver)
            }
        }
        failure.get()?.let { throw it }
    }

    companion object {
        fun open(instrumentation: Instrumentation, durationMillis: Long, onFailure: (Throwable) -> Unit): AcceptanceServiceLease {
            check(Looper.myLooper() != Looper.getMainLooper()) { "Acceptance must run off the UI thread" }
            require(durationMillis in 1_000..7_080_000)
            val lease = AcceptanceServiceLease(instrumentation, durationMillis, onFailure)
            try { lease.start(); return lease }
            catch (error: Throwable) {
                try { lease.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                throw error
            }
        }

        /** Observed framework state, not proof of OLED pixels or physical panel power. */
        fun deviceState(context: Context): String {
            val keyguard = context.getSystemService(KeyguardManager::class.java)
            return JSONObject().put("interactive", context.getSystemService(PowerManager::class.java).isInteractive)
                .put("keyguardLocked", keyguard.isKeyguardLocked).put("deviceLocked", keyguard.isDeviceLocked)
                .put("displays", JSONArray().apply {
                    context.getSystemService(DisplayManager::class.java).displays.forEach { display ->
                        put(JSONObject().put("id", display.displayId).put("state", display.state))
                    }
                }).toString()
        }
    }
}
