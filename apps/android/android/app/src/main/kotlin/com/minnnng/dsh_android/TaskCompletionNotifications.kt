package com.minnnng.dsh_android

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Private one-line completion notices. This owner never starts, restores, or retries a task. */
class TaskCompletionNotifications(private val context: Context) : AutoCloseable {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("task-completion-notices", Context.MODE_PRIVATE)
    private val state = TaskCompletionState()
    private val delivery = TaskCompletionDelivery()
    private val writer = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var closed = false

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "任务完成", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "后台任务完成后的简短提醒"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        // A process can die after the watermark commits but before main.post delivers the notice.
        // The pending receipt is committed in the same edit and replayed only as a notification.
        writer.execute {
            try {
                val plan = TaskCompletionRecovery.inspect(preferences.all)
                removeInvalidPending(plan.invalidKeys)
                if (plan.candidates.isNotEmpty()) main.post { restorePending(plan.candidates, 0) }
            } catch (error: RuntimeException) {
                // A damaged preference store must not crash Service creation or invent a task result.
                Log.w("PocketTaskNotice", "Pending completion recovery could not be read", error)
            }
        }
    }

    /** Receives only live successful-driver signals; no historical event or idle snapshot reaches this method. */
    fun completed(signal: JSONObject) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed) return
        val sessionId = signal.getString("sessionId")
        val rawSeq = signal.get("endSeq")
        val rawTurn = signal.get("turn")
        require(rawSeq is Number && rawSeq.toDouble() == rawSeq.toLong().toDouble() && rawSeq.toLong() >= 0)
        require(rawTurn is Number && rawTurn.toDouble() == rawTurn.toLong().toDouble() && rawTurn.toLong() >= 0)
        val endSeq = rawSeq.toLong()
        val preview = signal.optString("preview").replace(Regex("[\\p{Cntrl}]"), " ")
            .trim().take(100).takeIf { it.isNotEmpty() }
        val key = "end:$sessionId"
        if (!state.claim(sessionId, endSeq, preferences.getLong(key, -1))) return
        val eligible = state.shouldAlert(sessionId) && allowed()
        val ticket = delivery.add(sessionId, endSeq, preview, eligible)
        // Commit the watermark and pending notice atomically. A crash never restarts a task.
        writer.execute {
            val saved = try {
                val edit = preferences.edit().putLong(key, endSeq)
                if (eligible) edit.putString(pendingKey(sessionId), TaskCompletionReceipt.encode(endSeq, preview))
                else edit.remove(pendingKey(sessionId))
                edit.commit()
            }
            catch (error: Exception) { false }
            ticket.finish(saved)
            main.post {
                delivery.delivered(ticket)
                if (!closed) deliver(ticket)
            }
        }
    }

    fun viewing(owner: String, sessionId: String?, foreground: Boolean) {
        state.viewing(owner, sessionId, foreground)
        if (foreground && sessionId != null) manager.cancel(tag(sessionId), NOTIFICATION_ID)
    }

    fun disconnected(owner: String) = state.disconnected(owner)

    private fun allowed(): Boolean = (Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        manager.areNotificationsEnabled() &&
        manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE

    /** True only after Android accepts the notice; a failed post keeps the durable receipt. */
    private fun show(sessionId: String, preview: String?): Boolean {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(OPEN_ACTION)
            .setData(Uri.Builder().scheme("pocket-notification").authority("completed").appendPath(sessionId).build())
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("pocket.route", "session").putExtra("pocket.sessionId", sessionId)
        val open = PendingIntent.getActivity(context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.pocket_mark)
            .setContentTitle("Pocket Harness")
            .setContentText(preview ?: "本轮任务已完成，轻点查看回复。")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT >= 29) notice.setAllowSystemGeneratedContextualActions(false)
        try { manager.notify(tag(sessionId), NOTIFICATION_ID, notice.build()) }
        catch (error: SecurityException) {
            // Permission can be revoked after allowed() and before notify().
            Log.w("PocketTaskNotice", "Completion notification permission changed", error)
            return false
        } catch (error: RuntimeException) {
            Log.w("PocketTaskNotice", "Completion notification could not be posted", error)
            return false
        }
        return true
    }

    private fun deliver(ticket: TaskCompletionDelivery.Ticket) {
        if (!ticket.isPersisted) {
            Log.w("PocketTaskNotice", "Completion notification state could not be saved")
            return
        }
        val shouldAck = try {
            val required = ticket.eligible && state.isCurrentClaim(ticket.sessionId, ticket.endSeq)
                && state.shouldAlert(ticket.sessionId) && allowed()
            val posted = required && show(ticket.sessionId, ticket.preview)
            TaskCompletionDelivery.shouldAcknowledge(true, required, posted)
        } catch (error: RuntimeException) {
            // Keep the committed receipt for the next Service generation.
            Log.w("PocketTaskNotice", "Completion delivery could not be confirmed", error)
            false
        }
        if (shouldAck) acknowledge(ticket.sessionId, ticket.endSeq)
    }

    private fun restorePending(candidates: List<TaskCompletionRecovery.Candidate>, offset: Int) {
        if (closed) return
        val next = minOf(offset + RESTORE_BATCH_SIZE, candidates.size)
        for (index in offset until next) {
            val candidate = candidates[index]
            val sessionId = candidate.sessionId
            val receipt = candidate.receipt
            var acknowledged = true
            try {
                if (state.claim(sessionId, receipt.endSeq, -1L) && state.shouldAlert(sessionId) && allowed()) {
                    acknowledged = show(sessionId, receipt.preview)
                }
            } catch (invalid: IllegalArgumentException) {
                Log.w("PocketTaskNotice", "Invalid pending completion receipt")
            } catch (failure: RuntimeException) {
                // Retain the receipt for a later Service generation, without replaying the task.
                acknowledged = false
                Log.w("PocketTaskNotice", "Pending completion delivery failed", failure)
            }
            if (acknowledged) acknowledge(sessionId, receipt.endSeq)
        }
        if (next < candidates.size) main.post { restorePending(candidates, next) }
    }

    private fun removeInvalidPending(keys: List<String>) {
        if (keys.isEmpty()) return
        try {
            val edit = preferences.edit()
            keys.forEach { edit.remove(it) }
            if (!edit.commit()) Log.w("PocketTaskNotice", "Invalid completion receipts could not be cleared")
        } catch (error: RuntimeException) {
            Log.w("PocketTaskNotice", "Invalid completion receipts could not be cleared", error)
        }
    }

    private fun acknowledge(sessionId: String, endSeq: Long) {
        if (!writer.isShutdown) {
            writer.execute { acknowledgePersisted(sessionId, endSeq) }
            return
        }
        // close() already shut down the writer and has only its bounded teardown window left.
        acknowledgePersisted(sessionId, endSeq)
    }

    private fun acknowledgePersisted(sessionId: String, endSeq: Long) {
        val key = pendingKey(sessionId)
        val receipt = try { TaskCompletionReceipt.decode(preferences.getString(key, null)) }
        catch (invalid: ClassCastException) { null }
        if (receipt?.endSeq == endSeq) removePending(key)
    }

    private fun removePending(key: String) {
        try {
            if (!preferences.edit().remove(key).commit())
                Log.w("PocketTaskNotice", "Completion notice acknowledgement could not be saved")
        } catch (error: RuntimeException) {
            Log.w("PocketTaskNotice", "Completion notice acknowledgement could not be saved", error)
        }
    }

    override fun close() {
        if (closed) return
        // Service transition and unexpected Node exit may kill this process immediately afterwards.
        // Give accepted writes a bounded chance to commit, then deliver only committed notices.
        writer.shutdown()
        try { writer.awaitTermination(SHUTDOWN_DRAIN_MS, TimeUnit.MILLISECONDS) }
        catch (error: InterruptedException) { Thread.currentThread().interrupt() }
        delivery.persistedAtShutdown().forEach { deliver(it) }
        val unfinished = delivery.unfinishedCount()
        if (unfinished > 0) Log.w("PocketTaskNotice", "$unfinished completion watermark write(s) did not finish before shutdown")
        delivery.clear()
        closed = true
        state.close()
    }

    private fun tag(sessionId: String) = "pocket-completed:$sessionId"
    private fun pendingKey(sessionId: String) = "$PENDING_PREFIX$sessionId"

    companion object {
        const val MESSAGE_VIEWING = 10
        const val OPEN_ACTION = "com.minnnng.dsh_android.OPEN_COMPLETED_TASK"
        private const val CHANNEL_ID = "task-completed"
        private const val PENDING_PREFIX = "pending:"
        private const val NOTIFICATION_ID = 3
        private const val RESTORE_BATCH_SIZE = 8
        private const val SHUTDOWN_DRAIN_MS = 250L
    }
}
