package com.minnnng.dsh_android

import android.Manifest
import android.app.Application
import android.app.Instrumentation
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Synthetic crash-window proof for committed completion receipts in the Agent process. */
class TaskCompletionCrashInstrumentation : Instrumentation() {
    private lateinit var options: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        options = arguments ?: Bundle.EMPTY
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent")
            check(Looper.myLooper() != Looper.getMainLooper())
            val token = options.getString("token") ?: error("Missing acceptance token")
            require(token.matches(Regex("[0-9a-f]{32}")))
            val phase = options.getString("phase") ?: error("Missing acceptance phase")
            result.putString("phase", phase)
            result.putString("token", token)
            result.putInt("processPid", Process.myPid())
            result.putLong("endSeq", END_SEQUENCE)
            when (phase) {
                "hold" -> {
                    holdAfterCommit(app, token)
                    error("The held Agent process returned without force-stop")
                }
                "verify" -> verifyRecovery(app, token, result)
                "cleanup" -> cleanup(app, token, result)
                else -> error("Unknown acceptance phase")
            }
            result.putString("passed", "true")
            finish(-1, result)
        } catch (failure: Throwable) {
            result.putString("passed", "false")
            result.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}".take(512))
            finish(0, result)
        }
    }

    private fun holdAfterCommit(app: Context, token: String) {
        val prefs = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val manager = app.getSystemService(NotificationManager::class.java)
        val session = session(token)
        check(!prefs.contains("end:$session") && !prefs.contains("pending:$session")) {
            "Acceptance receipt already exists"
        }
        val owner = TaskCompletionNotifications(app)
        check((Build.VERSION.SDK_INT < 33 ||
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            manager.areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE) {
            "Completion notification permission or channel is disabled"
        }
        val entered = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        Handler(Looper.getMainLooper()).post {
            try {
                owner.completed(JSONObject().put("sessionId", session)
                    .put("endSeq", END_SEQUENCE).put("turn", 1).put("preview", PREVIEW))
            } catch (error: Throwable) { failure.set(error) }
            finally { entered.countDown() }
            // The writer may commit, but the queued display cannot run before process death.
            CountDownLatch(1).await()
        }
        check(entered.await(5, TimeUnit.SECONDS)) { "Completion signal did not enter the main thread" }
        failure.get()?.let { throw it }
        until(3_000) {
            prefs.getLong("end:$session", -1) == END_SEQUENCE &&
                TaskCompletionReceipt.decode(prefs.getString("pending:$session", null))
                    ?.matchesWatermark(END_SEQUENCE) == true
        }
        check(manager.activeNotifications.none { it.tag == tag(session) && it.id == NOTIFICATION_ID }) {
            "Notice appeared before the forced process death"
        }
        val stale = staleSession(token)
        val malformed = malformedSession(token)
        check(prefs.edit().putLong("end:$stale", END_SEQUENCE)
            .putString("pending:$stale", TaskCompletionReceipt.encode(END_SEQUENCE + 1, "stale"))
            .putString("pending:$malformed", "invalid").commit()) {
            "Synthetic negative receipts were not committed"
        }
        sendStatus(1, Bundle().apply {
            putString("holdReady", "true")
            putString("token", token)
            putInt("processPid", Process.myPid())
            putString("receiptCommitted", "true")
        })
        CountDownLatch(1).await()
    }

    private fun verifyRecovery(app: Context, token: String, result: Bundle) {
        val prefs = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val manager = app.getSystemService(NotificationManager::class.java)
        val session = session(token)
        check(prefs.getLong("end:$session", -1) == END_SEQUENCE)
        val owner = TaskCompletionNotifications(app)
        try {
            until(8_000) {
                !prefs.contains("pending:$session") &&
                    !prefs.contains("pending:${staleSession(token)}") &&
                    !prefs.contains("pending:${malformedSession(token)}") &&
                    manager.activeNotifications.any { notification ->
                        notification.tag == tag(session) && notification.id == NOTIFICATION_ID &&
                            notification.notification.extras.getCharSequence("android.text")?.toString() == PREVIEW
                    }
            }
            val notices = manager.activeNotifications
            check(notices.count { it.tag == tag(session) && it.id == NOTIFICATION_ID } == 1)
            check(notices.none { it.tag == tag(staleSession(token)) ||
                it.tag == tag(malformedSession(token)) }) {
                "Invalid or interrupted synthetic completion produced a notice"
            }
            check(prefs.getLong("end:$session", -1) == END_SEQUENCE) {
                "Completion watermark changed during notification recovery"
            }
            result.putString("validNotice", "true")
            result.putString("invalidNotices", "false")
            result.putString("receiptsCleared", "true")
        } finally { owner.close() }
    }

    private fun cleanup(app: Context, token: String, result: Bundle) {
        val prefs = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val session = session(token)
        check(prefs.getLong("end:$session", -1) == END_SEQUENCE &&
            !prefs.contains("pending:$session")) { "Verified receipt is absent or not acknowledged" }
        val editor = prefs.edit()
        for (id in listOf(session, staleSession(token), malformedSession(token))) {
            editor.remove("end:$id").remove("pending:$id")
            app.getSystemService(NotificationManager::class.java).cancel(tag(id), NOTIFICATION_ID)
        }
        check(editor.commit()) { "Synthetic completion state could not be removed" }
        check(listOf(session, staleSession(token), malformedSession(token))
            .all { !prefs.contains("end:$it") && !prefs.contains("pending:$it") })
        result.putString("cleaned", "true")
    }

    private fun until(timeoutMillis: Long, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        while (!condition()) {
            check(System.nanoTime() < deadline) { "Completion receipt did not reach the expected state" }
            Thread.sleep(20)
        }
    }

    private fun session(token: String) = "completion-acceptance-$token"
    private fun staleSession(token: String) = "completion-stale-$token"
    private fun malformedSession(token: String) = "completion-malformed-$token"
    private fun tag(sessionId: String) = "pocket-completed:$sessionId"

    companion object {
        private const val PREFERENCES = "task-completion-notices"
        private const val CHANNEL_ID = "task-completed"
        private const val NOTIFICATION_ID = 3
        private const val END_SEQUENCE = 41L
        private const val PREVIEW = "合成任务已完成"
    }
}
