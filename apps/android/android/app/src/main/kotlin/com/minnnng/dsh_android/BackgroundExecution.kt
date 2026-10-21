package com.minnnng.dsh_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import org.json.JSONObject

/** Foreground presentation and bounded CPU ownership, driven only by verified core snapshots. */
class BackgroundExecution(private val service: Service) {
    companion object {
        const val NOTIFICATION_ID = 1
        private const val SNAPSHOT_LIFETIME_MS = 45_000L
        private const val WAKE_LEASE_MS = 90_000L
    }

    private val preferences = service.getSharedPreferences("background_execution", Service.MODE_PRIVATE)
    private val state = BackgroundTaskState(preferences.getBoolean("keepAwakeWhileWorking", true))
    private val notifications = service.getSystemService(NotificationManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val wakeLock = service.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "com.minnnng.dsh_android:AgentTasks")
        .apply { setReferenceCounted(false) }
    private var closed = false
    private var notificationText: String? = null
    private var powerError: String? = null
    private var notificationError: String? = null
    private val expire = Runnable {
        if (!closed) {
            state.stale()
            render()
        }
    }

    fun start() {
        notifications.createNotificationChannel(NotificationChannel(
            "agent", "后台运行状态", NotificationManager.IMPORTANCE_LOW))
        val text = text()
        service.startForeground(NOTIFICATION_ID, notification(text))
        notificationText = text
    }

    fun phase(value: String) {
        if (closed) return
        state.phase(value)
        main.removeCallbacks(expire)
        render()
    }

    fun observe(snapshot: JSONObject) {
        if (closed) return
        val counts = snapshot.getJSONObject("summary")
        val jobs = if (counts.isNull("backgroundJobs")) null else count(counts, "backgroundJobs")
        val packages = if (counts.isNull("packageOperations")) null else count(counts, "packageOperations")
        val rawRevision = snapshot.get("revision")
        require(rawRevision is Number && rawRevision.toDouble().isFinite()
            && rawRevision.toDouble() == rawRevision.toLong().toDouble() && rawRevision.toLong() >= 0)
        val revision = rawRevision.toLong()
        if (state.accept(snapshot.getString("epoch"), revision,
                count(counts, "running"), count(counts, "queued"),
                count(counts, "waiting"), count(counts, "failed"), jobs, packages)) {
            main.removeCallbacks(expire)
            main.postDelayed(expire, SNAPSHOT_LIFETIME_MS)
            render()
        }
    }

    private fun count(value: JSONObject, name: String): Int {
        val raw = value.get(name)
        require(raw is Number && raw.toDouble().isFinite()
            && raw.toDouble() == raw.toInt().toDouble() && raw.toInt() >= 0) {
            "Invalid task summary count"
        }
        return raw.toInt()
    }

    fun unavailable() {
        if (closed) return
        state.stale()
        main.removeCallbacks(expire)
        render()
    }

    fun configure(enabled: Boolean): JSONObject {
        check(!closed) { "后台服务已经关闭" }
        check(preferences.edit().putBoolean("keepAwakeWhileWorking", enabled).commit()) {
            "后台运行设置未保存"
        }
        state.keepAwake(enabled)
        render()
        return status()
    }

    fun status(): JSONObject = JSONObject()
        .put("keepAwakeWhileWorking", state.keepAwake())
        .put("wakeLockHeld", wakeLock.isHeld)
        .put("taskState", state.presentation())
        .put("fresh", state.fresh())
        .put("running", state.running())
        .put("queued", state.queued())
        .put("waiting", state.waiting())
        .put("failed", state.failed())
        .put("backgroundJobs", state.backgroundJobs() ?: JSONObject.NULL)
        .put("packageOperations", state.packageOperations() ?: JSONObject.NULL)
        .put("powerError", powerError ?: JSONObject.NULL)
        .put("notificationError", notificationError ?: JSONObject.NULL)

    private fun text(): String = when (state.presentation()) {
        "starting" -> "正在启动本地 Agent"
        "restarting" -> "正在重启服务，核对任务恢复状态"
        "maintenance" -> "维护模式 · Agent 已停止，可在 App 修复启动配置"
        "maintenance-checking" -> "维护检查 · 正在确认本应用遗留进程已停止"
        "maintenance-blocked" -> "维护受阻 · 无法确认遗留进程状态，配置保持只读"
        "failed" -> "服务异常，任务可能已中断；打开 App 查看"
        "stopped" -> "本地服务已停止"
        "unconfirmed" -> "任务状态尚未确认；打开 App 查看"
        "partial" -> "Agent 暂无运行任务，后台作业或插件管理操作状态尚未确认"
        "running" -> buildList {
            if (state.running() > 0) add("${state.running()} 个任务运行中")
            if ((state.backgroundJobs() ?: 0) > 0) add("${state.backgroundJobs()} 个后台作业")
            if ((state.packageOperations() ?: 0) > 0) add("${state.packageOperations()} 项插件管理操作")
            if (state.waiting() > 0) add("${state.waiting()} 项等待处理")
            if (state.queued() > 0) add("${state.queued()} 条输入排队")
        }.joinToString(" · ")
        "packages" -> "${state.packageOperations()} 项插件管理操作进行中"
        "waiting" -> "${state.waiting()} 项等待授权或答复"
        "queued" -> "${state.queued()} 条输入等待处理"
        "attention" -> "${state.failed()} 个会话的最近任务失败；打开 App 查看"
        else -> "本地 Agent 已就绪，当前没有运行任务"
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(service, 44,
            Intent(service, MainActivity::class.java).putExtra("pocket.route", "tasks"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(service, "agent")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Pocket Harness").setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setShowWhen(false).setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        if (state.presentation() in setOf("running", "packages")) builder.setProgress(0, 0, true)
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun render() {
        try {
            if (state.shouldHoldWakeLock()) wakeLock.acquire(WAKE_LEASE_MS)
            else if (wakeLock.isHeld) wakeLock.release()
            powerError = null
        } catch (_: SecurityException) {
            powerError = "系统未允许维持任务执行，请检查应用电池设置"
        }
        val current = text()
        if (current != notificationText || notificationError != null) {
            try {
                notifications.notify(NOTIFICATION_ID, notification(current))
                notificationText = current
                notificationError = null
            } catch (_: SecurityException) {
                notificationError = "运行通知不可用，请检查系统通知权限"
            }
        }
    }

    fun close() {
        if (closed) return
        closed = true
        main.removeCallbacks(expire)
        state.phase("stopped")
        if (wakeLock.isHeld) wakeLock.release()
    }
}
