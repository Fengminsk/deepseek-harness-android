package com.minnnng.dsh_android

import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Looper
import android.os.PowerManager
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Owns one black acceptance window; never wakes or unlocks the phone. */
class AcceptanceForegroundLease private constructor(
    private val instrumentation: Instrumentation,
    private val onHidden: ((Throwable) -> Unit)?,
) : Closeable {
    private val app = instrumentation.targetContext.applicationContext
    private val token = UUID.randomUUID().toString()
    private val permission = "${app.packageName}.permission.RUNTIME_ACCEPTANCE"
    private val ready = CompletableFuture<Boolean>()
    private val closed = CompletableFuture<Boolean>()
    private val registered = AtomicBoolean(false)
    private val closing = AtomicBoolean(false)
    private val failure = AtomicReference<IllegalStateException?>()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getStringExtra("token") != token) return
            when (intent.getStringExtra("state")) {
                "ready" -> ready.complete(true)
                "hidden", "closed" -> {
                    if (intent.getStringExtra("state") == "closed") closed.complete(true)
                    if (!closing.get()) {
                        val error = IllegalStateException("The black acceptance window is no longer visible")
                        if (failure.compareAndSet(null, error)) {
                            ready.completeExceptionally(error)
                            onHidden?.invoke(error)
                        }
                    }
                }
            }
        }
    }

    private fun start() {
        val filter = IntentFilter("${app.packageName}.acceptance.foreground.status")
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, permission,
            null, Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(receiver, filter, permission, null)
        registered.set(true)
        instrumentation.uiAutomation.adoptShellPermissionIdentity("android.permission.START_ACTIVITIES_FROM_BACKGROUND")
        try {
            app.startActivity(Intent().setClassName(app.packageName, "${app.packageName}.RuntimeAcceptanceActivity")
                .putExtra("token", token)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK))
        } finally { instrumentation.uiAutomation.dropShellPermissionIdentity() }
        ready.get(20, TimeUnit.SECONDS)
        checkActive()
        verifyBlackPixels()
    }

    /** Checks the composed screen, including system bars, without saving other screen content. */
    fun verifyBlackPixels(): Pair<Int, Int> {
        checkActive()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot()) {
            "Unable to verify black screen pixels"
        }
        try {
            val row = IntArray(bitmap.width)
            for (y in 0 until bitmap.height) {
                bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
                check(row.all { (it and 0x00ffffff) == 0 }) {
                    "The composed screen contains visible pixels; acceptance has not started"
                }
            }
            checkActive()
            return Pair(bitmap.width, bitmap.height)
        } finally { bitmap.recycle() }
    }

    fun checkActive() {
        failure.get()?.let { throw it }
        check(!closing.get() && !closed.isDone) { "The black acceptance window has closed" }
    }

    @Synchronized
    override fun close() {
        if (registered.get()) {
            try {
                if (closing.compareAndSet(false, true)) app.sendBroadcast(
                    Intent("${app.packageName}.acceptance.foreground.close").setPackage(app.packageName)
                        .putExtra("token", token), permission)
                check(closed.get(2, TimeUnit.SECONDS)) { "Black acceptance window closure was not confirmed" }
            } finally {
                if (registered.compareAndSet(true, false)) app.unregisterReceiver(receiver)
            }
        }
        failure.get()?.let { throw it }
    }

    companion object {
        fun open(instrumentation: Instrumentation, onHidden: ((Throwable) -> Unit)? = null): AcceptanceForegroundLease {
            check(Looper.myLooper() != Looper.getMainLooper()) { "Acceptance must run off the UI thread" }
            val app = instrumentation.targetContext.applicationContext
            check(!app.getSystemService(KeyguardManager::class.java).isKeyguardLocked &&
                app.getSystemService(PowerManager::class.java).isInteractive) {
                "Unlock the phone before starting black-screen acceptance; no wake or unlock was requested"
            }
            val lease = AcceptanceForegroundLease(instrumentation, onHidden)
            try { lease.start(); return lease }
            catch (error: Throwable) {
                try { lease.close() } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                throw error
            }
        }
    }
}
