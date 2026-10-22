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

/** Private one-line completion notices. This owner never starts, restores, or retries a task. */
class TaskCompletionNotifications(private val context: Context) : AutoCloseable {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("task-completion-notices", Context.MODE_PRIVATE)
    private val state = TaskCompletionState()
    private val writer = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var closed = false

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "任务完成", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "后台任务完成后的简短提醒"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
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
        val key = "end:$sessionId"
        if (!state.claim(sessionId, endSeq, preferences.getLong(key, -1))) return
        val eligible = state.shouldAlert(sessionId) && allowed()
        // Durable claim precedes delivery. A crash can omit a notice, but never replay it or a task.
        writer.execute {
            val saved = try { preferences.edit().putLong(key, endSeq).commit() }
            catch (error: Exception) { false }
            main.post {
                if (!saved) Log.w("PocketTaskNotice", "Completion notification state could not be saved")
                else if (!closed && eligible && state.shouldAlert(sessionId) && allowed()) show(sessionId)
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

    private fun show(sessionId: String) {
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
            .setContentText("本轮任务已完成，轻点查看回复。")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(false)
        if (Build.VERSION.SDK_INT >= 29) notice.setAllowSystemGeneratedContextualActions(false)
        try { manager.notify(tag(sessionId), NOTIFICATION_ID, notice.build()) }
        catch (error: SecurityException) {
            // The user can revoke notification permission after allowed(); the result remains in its Session.
            Log.w("PocketTaskNotice", "Completion notification permission changed")
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        state.close()
        writer.shutdown()
    }

    private fun tag(sessionId: String) = "pocket-completed:$sessionId"

    companion object {
        const val MESSAGE_VIEWING = 10
        const val OPEN_ACTION = "com.minnnng.dsh_android.OPEN_COMPLETED_TASK"
        private const val CHANNEL_ID = "task-completed"
        private const val NOTIFICATION_ID = 3
    }
}
