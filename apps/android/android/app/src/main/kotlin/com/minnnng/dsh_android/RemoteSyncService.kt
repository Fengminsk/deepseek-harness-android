package com.minnnng.dsh_android

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import org.json.JSONObject
import java.util.UUID

/**
 * 主进程的前台同步服务：App 退到后台时保持进程与 Flutter UI isolate 存活，
 * 让远程连接的 WebSocket、`session.follow` 与 `remote.*` 通知继续运行。
 *
 * 服务本身不持连接、不解析协议：连接由 Dart 侧 `RemoteBackgroundSync` 维护；这里只
 * 负责「常驻通知 + 进程保活 + 诊断状态」。Dart 在应用级连接需要后台运行时通过
 * `remote.sync.start` 启动（前台启动限制要求调用时界面可见），并用
 * `remote.sync.heartbeat` 每 30 秒报到；连接终止、用户关闭后台同步或界面主动停止时
 * 调 `remote.sync.stop`。
 *
 * 保活加固（不能绕过 OEM / ANR 限制，只减少被系统当作「空闲」回收的机会）：
 * - 前台期间持有 `PARTIAL_WAKE_LOCK`（30 分钟超时，watchdog 与心跳续期）；服务销毁、
 *   降级为「同步已中断」时释放。唤醒锁不防止主线程 ANR 被杀，只避免 CPU 休眠后
 *   socket 停止收帧。
 * - `onTaskRemoved` 不立即停止：心跳新鲜时继续同步；心跳超时说明 Dart isolate 已不在，
 *   改成可点按恢复的通知，不假装仍在同步。
 * - `START_STICKY` 重启时没有界面/引擎：同样显示可点按恢复的通知，等用户打开 App 后
 *   Dart 重新建连并心跳恢复。
 *
 * 诊断状态写入 SharedPreferences `remote-sync-state`：进程被系统杀死（含 ANR）时
 * `onDestroy` 不会执行，下一次进程启动可以据此报告「上次运行异常结束」，设置页与
 * `adb` 排查都读同一份数据。
 *
 * 通知渠道 `remote-sync` 为 IMPORTANCE_LOW：不响铃、不弹横幅，只在通知栏里说明后台
 * 同步正在运行。点击通知回到 App（MainActivity）。
 */
class RemoteSyncService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var watchdogScheduled = false
    private val watchdog = Runnable { checkHealth() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureProcessIdentity(this)
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "与电脑保持同步", NotificationManager.IMPORTANCE_LOW).apply {
                description = "App 退到后台时保持远程连接，以便接收任务完成与审批提问通知"
                setShowBadge(false)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val now = System.currentTimeMillis()
        when (val action = intent?.action) {
            ACTION_STOP -> {
                lastStopReason = intent?.getStringExtra(EXTRA_REASON) ?: "stop-command"
                persistState(action = "stop", now = now)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_HEARTBEAT -> {
                lastHeartbeatAtMillis = now
                persistState(action = "heartbeat", now = now)
                if (!running) {
                    // 进程被系统重启后服务处于「等待恢复」：Dart 已重新连通并报到，
                    // 只有界面/引擎仍在时才恢复常驻同步通知。
                    if (MainActivity.uiAlive) enterRunning("heartbeat-recovered", now)
                } else {
                    renewWakeLockIfNeeded()
                    publishNotification()
                }
                scheduleWatchdog()
                return START_STICKY
            }
            else -> {
                val reason = intent?.getStringExtra(EXTRA_REASON)
                    ?: if (intent == null) "sticky-restart" else "dart-start"
                lastStartReason = reason
                lastHeartbeatAtMillis = if (MainActivity.uiAlive) now else 0L
                // 没有 Flutter 界面/引擎时不可能有连接：不冒充「同步中」，只留可点按
                // 恢复的通知。启动器（START_STICKY 重启）与 Dart 都在这里汇合。
                if (MainActivity.uiAlive) {
                    enterRunning(reason, now)
                } else {
                    enterDegraded("no-ui-after-$reason", now)
                }
                scheduleWatchdog()
                return START_STICKY
            }
        }
    }

    /**
     * 划掉最近任务时系统会问「要不要保留服务」：这里保留。
     *
     * 心跳新鲜说明 Dart isolate 还活着、连接仍在收帧，保持原状；心跳超时说明引擎已经
     * 不在，改成可点按恢复的通知，避免留下一条永远不再同步的「同步中」。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val now = System.currentTimeMillis()
        lastTaskRemovedAtMillis = now
        if (running && !heartbeatFresh(now)) {
            enterDegraded("task-removed-stale-heartbeat", now)
        }
        persistState(action = "task-removed", now = now)
        // 划掉最近任务后 Activity/FlutterEngine 会被销毁：Dart 心跳随后停止。给几秒
        // 宽限后如果界面确实不在了，就如实降级为可点按恢复的通知，不留下「同步中」。
        handler.postDelayed({
            if (instance === this@RemoteSyncService && !MainActivity.uiAlive) {
                enterDegraded("task-removed-no-ui", System.currentTimeMillis())
            }
        }, TASK_REMOVED_GRACE_MS)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        lastStopReason = lastStopReason ?: "destroyed"
        if (running) {
            // 正常停止（用户关掉后台同步/连接终止）走这里；进程被系统杀死不会执行，
            // 下一次启动据持久化的 running=true 报告上次异常结束。
            running = false
        }
        releaseWakeLock("destroyed")
        handler.removeCallbacks(watchdog)
        watchdogScheduled = false
        persistState(action = "destroy", now = System.currentTimeMillis())
        instance = null
        super.onDestroy()
    }

    private fun enterRunning(reason: String, now: Long) {
        if (!running || startedAtMillis <= 0L) startedAtMillis = now
        running = true
        degraded = false
        lastHeartbeatAtMillis = now
        lastStartReason = reason
        if (previousRunAbnormal) {
            // 本轮已经恢复出可用连接，异常记录已经进入诊断历史。
            previousRunAbnormal = false
        }
        acquireWakeLock(reason)
        startForeground(NOTIFICATION_ID, notification(healthy = true))
        persistState(action = "running", now = now)
        Log.i(LOG_TAG, "remote sync running: reason=$reason process=$processInstanceId")
    }

    private fun enterDegraded(reason: String, now: Long) {
        running = false
        degraded = true
        lastStopReason = reason
        releaseWakeLock(reason)
        // 仍然前台：通知要可点按恢复，且不希望进程立刻被回收（用户可能马上回来）。
        startForeground(NOTIFICATION_ID, notification(healthy = false))
        persistState(action = "degraded:$reason", now = now)
        Log.w(LOG_TAG, "remote sync interrupted: $reason")
    }

    private fun heartbeatFresh(now: Long): Boolean {
        val last = lastHeartbeatAtMillis
        return last > 0L && now - last <= HEARTBEAT_STALE_MS
    }

    /** 每 WATCHDOG_INTERVAL_MS 检查心跳与唤醒锁；空闲时不重建通知。 */
    private fun checkHealth() {
        watchdogScheduled = false
        val now = System.currentTimeMillis()
        if (running && !heartbeatFresh(now)) {
            enterDegraded("heartbeat-timeout", now)
        } else if (running) {
            renewWakeLockIfNeeded()
        }
        scheduleWatchdog()
    }

    private fun scheduleWatchdog() {
        if (watchdogScheduled || instance == null) return
        watchdogScheduled = true
        handler.postDelayed(watchdog, WATCHDOG_INTERVAL_MS)
    }

    private fun acquireWakeLock(reason: String) {
        if (wakeLockHeld) return
        try {
            val manager = getSystemService(PowerManager::class.java)
            val lock = wakeLock ?: manager
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$WAKE_LOCK_TAG")
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
            lock.acquire(WAKE_LOCK_TIMEOUT_MS)
            wakeLockHeld = lock.isHeld
            wakeLockExpiries = 0
            Log.i(LOG_TAG, "wake lock acquired: $reason")
        } catch (failure: RuntimeException) {
            // 权限/系统策略拒绝时继续跑前台服务：没有唤醒锁不代表同步失败。
            wakeLockHeld = false
            Log.w(LOG_TAG, "wake lock unavailable", failure)
        }
    }

    private fun renewWakeLockIfNeeded() {
        if (!running) return
        if (wakeLock?.isHeld == true) {
            wakeLockHeld = true
            return
        }
        wakeLockExpiries++
        acquireWakeLock("renewed-after-timeout")
    }

    private fun releaseWakeLock(reason: String) {
        val lock = wakeLock ?: return
        try {
            if (lock.isHeld) {
                lock.release()
                Log.i(LOG_TAG, "wake lock released: $reason")
            }
        } catch (failure: RuntimeException) {
            Log.w(LOG_TAG, "wake lock release failed", failure)
        } finally {
            wakeLockHeld = false
        }
    }

    private fun publishNotification() {
        try {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(healthy = running))
        } catch (_: SecurityException) {
            // 通知权限在运行中被撤销：前台服务状态仍由 startForeground 维持。
        }
    }

    private fun notification(healthy: Boolean): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .setAction(OPEN_HOME_ACTION)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra("pocket.route", "remote-home"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.pocket_mark)
            .setContentTitle("Pocket Harness")
            .setContentText(if (healthy) "与电脑保持同步" else "后台同步已中断 · 点按恢复")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        return builder.build()
    }

    private fun persistState(action: String, now: Long) {
        try {
            val prefs = getSharedPreferences(STATE_PREFERENCES, MODE_PRIVATE)
            prefs.edit()
                .putBoolean(KEY_RUNNING, running)
                .putString(KEY_PROCESS_ID, processInstanceId)
                .putLong(KEY_STARTED_AT, startedAtMillis)
                .putString(KEY_START_REASON, lastStartReason)
                .putString(KEY_STOP_REASON, lastStopReason)
                .putLong(KEY_LAST_HEARTBEAT_AT, lastHeartbeatAtMillis)
                .putLong(KEY_LAST_TASK_REMOVED_AT, lastTaskRemovedAtMillis)
                .putString(KEY_LAST_ACTION, action)
                .putLong(KEY_LAST_ACTION_AT, now)
                .putBoolean(KEY_WAKE_LOCK_HELD, wakeLockHeld)
                .putBoolean(KEY_DEGRADED, degraded)
                .putInt(KEY_WAKE_LOCK_EXPIRIES, wakeLockExpiries)
                .apply()
        } catch (failure: RuntimeException) {
            Log.w(LOG_TAG, "remote sync state could not be saved", failure)
        }
    }

    companion object {
        const val OPEN_HOME_ACTION = "com.minnnng.dsh_android.OPEN_REMOTE_HOME"
        /** 通知渠道 id；与 Dart 侧没有耦合，只用于系统通知栏分组。 */
        const val CHANNEL_ID = "remote-sync"

        /** 常驻通知 id；后台同步只允许一条。 */
        const val NOTIFICATION_ID = 2

        private const val LOG_TAG = "PocketRemoteSync"
        private const val ACTION_STOP = "com.minnnng.dsh_android.remote.sync.STOP"
        private const val ACTION_HEARTBEAT = "com.minnnng.dsh_android.remote.sync.HEARTBEAT"
        private const val EXTRA_REASON = "reason"

        private const val WAKE_LOCK_TAG = "com.minnnng.dsh_android:RemoteSync"
        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val HEARTBEAT_STALE_MS = 90_000L
        private const val WATCHDOG_INTERVAL_MS = 30_000L
        private const val TASK_REMOVED_GRACE_MS = 10_000L

        private const val STATE_PREFERENCES = "remote-sync-state"
        private const val KEY_RUNNING = "running"
        private const val KEY_PROCESS_ID = "processId"
        private const val KEY_STARTED_AT = "startedAt"
        private const val KEY_START_REASON = "startReason"
        private const val KEY_STOP_REASON = "stopReason"
        private const val KEY_LAST_HEARTBEAT_AT = "lastHeartbeatAt"
        private const val KEY_LAST_TASK_REMOVED_AT = "lastTaskRemovedAt"
        private const val KEY_LAST_ACTION = "lastAction"
        private const val KEY_LAST_ACTION_AT = "lastActionAt"
        private const val KEY_WAKE_LOCK_HELD = "wakeLockHeld"
        private const val KEY_DEGRADED = "degraded"
        private const val KEY_WAKE_LOCK_EXPIRIES = "wakeLockExpiries"
        private const val KEY_PREVIOUS_RUN_ABNORMAL = "previousRunAbnormal"
        private const val KEY_PREVIOUS_RUN_STARTED_AT = "previousRunStartedAt"

        /** 服务是否由本进程启动过；`remote.sync.status` 读它。 */
        @Volatile
        var running: Boolean = false
            private set

        /** 前台服务仍在，但没有可用连接（进程重启/心跳超时/划掉任务后引擎不在了）。 */
        @Volatile
        var degraded: Boolean = false
            private set

        /** 当前前台期间是否持有 CPU 唤醒锁。 */
        @Volatile
        var wakeLockHeld: Boolean = false
            private set

        /** 本进程内是否检测到上一次进程在同步运行中被系统杀死（ANR/低内存）。 */
        @Volatile
        var previousRunAbnormal: Boolean = false
            private set

        @Volatile
        private var previousRunStartedAtMillis: Long = 0L

        @Volatile
        private var startedAtMillis: Long = 0L

        @Volatile
        private var lastHeartbeatAtMillis: Long = 0L

        @Volatile
        private var lastTaskRemovedAtMillis: Long = 0L

        @Volatile
        private var lastStartReason: String = "unknown"

        @Volatile
        private var lastStopReason: String? = null

        @Volatile
        private var wakeLockExpiries: Int = 0

        /** 进程标识：服务诊断里区分「同一个进程重启服务」与「进程被系统杀掉后重来」。 */
        private val processInstanceId: String = UUID.randomUUID().toString()

        @Volatile
        private var instance: RemoteSyncService? = null

        /** 读取并记录上次运行是否异常结束；进程内只做一次。 */
        private var processIdentityChecked = false

        @Synchronized
        private fun ensureProcessIdentity(context: Context) {
            if (processIdentityChecked) return
            processIdentityChecked = true
            try {
                val prefs = context.getSharedPreferences(STATE_PREFERENCES, Context.MODE_PRIVATE)
                val storedRunning = prefs.getBoolean(KEY_RUNNING, false)
                val storedProcess = prefs.getString(KEY_PROCESS_ID, null)
                if (storedRunning && storedProcess != null && storedProcess != processInstanceId) {
                    previousRunAbnormal = true
                    previousRunStartedAtMillis = prefs.getLong(KEY_STARTED_AT, 0L)
                    Log.w(
                        LOG_TAG,
                        "previous process ended while syncing (possible ANR/low-memory kill); " +
                            "startedAt=$previousRunStartedAtMillis",
                    )
                }
                prefs.edit()
                    .putString(KEY_PROCESS_ID, processInstanceId)
                    .putBoolean(KEY_RUNNING, false)
                    .putBoolean(KEY_PREVIOUS_RUN_ABNORMAL, previousRunAbnormal)
                    .putLong(KEY_PREVIOUS_RUN_STARTED_AT, previousRunStartedAtMillis)
                    .putString(KEY_LAST_ACTION, "process-start")
                    .putLong(KEY_LAST_ACTION_AT, System.currentTimeMillis())
                    .apply()
            } catch (failure: RuntimeException) {
                Log.w(LOG_TAG, "remote sync process identity could not be recorded", failure)
            }
        }

        /** 前台启动服务；必须从 Activity/前台上下文调用（Android 12+ 后台启动限制）。 */
        fun start(context: Context, reason: String) {
            val intent = Intent(context, RemoteSyncService::class.java)
                .putExtra(EXTRA_REASON, reason)
            context.startForegroundService(intent)
        }

        /** 请求停止服务并移除常驻通知；[reason] 会写进诊断。 */
        fun stop(context: Context, reason: String) {
            lastStopReason = reason
            persistStopReason(context, reason)
            context.stopService(Intent(context, RemoteSyncService::class.java))
        }

        /**
         * Dart 每次心跳报到；不启动服务、不依赖后台启动限制。
         *
         * @return 服务实例是否存活：false 表示进程里没有可用的前台服务，Dart 侧据此
         * 重新 `remote.sync.start`。
         */
        fun recordHeartbeat(): Boolean {
            val now = System.currentTimeMillis()
            lastHeartbeatAtMillis = now
            val service = instance
            if (service != null) {
                service.handler.post {
                    if (instance === service) {
                        if (!running && MainActivity.uiAlive) service.enterRunning("heartbeat", now)
                        else if (running) {
                            service.renewWakeLockIfNeeded()
                            service.publishNotification()
                        }
                        service.scheduleWatchdog()
                    }
                }
                return true
            }
            return false
        }

        /** 诊断快照：设置页、`remote.sync.status` 与 adb 排查共用。 */
        fun statusJson(context: Context, uiAlive: Boolean): JSONObject {
            ensureProcessIdentity(context)
            val now = System.currentTimeMillis()
            val prefs = context.getSharedPreferences(STATE_PREFERENCES, Context.MODE_PRIVATE)
            val power = context.getSystemService(PowerManager::class.java)
            val activity = context.getSystemService(android.app.ActivityManager::class.java)
            val heartbeatAge = if (lastHeartbeatAtMillis <= 0L) -1L else now - lastHeartbeatAtMillis
            return JSONObject()
                .put("running", running)
                .put("degraded", degraded)
                .put("recoveryPending", degraded)
                .put("wakeLockHeld", wakeLockHeld)
                .put("wakeLockExpiries", wakeLockExpiries)
                .put("startedAtMillis", startedAtMillis)
                .put("lastHeartbeatAtMillis", lastHeartbeatAtMillis)
                .put("heartbeatAgeMillis", heartbeatAge)
                .put("lastStartReason", lastStartReason)
                .put("lastStopReason", lastStopReason ?: JSONObject.NULL)
                .put("lastTaskRemovedAtMillis", lastTaskRemovedAtMillis)
                .put("processInstanceId", processInstanceId)
                .put("previousRunAbnormal", previousRunAbnormal)
                .put("previousRunStartedAtMillis", previousRunStartedAtMillis)
                .put("uiAlive", uiAlive)
                .put("batteryOptimizationsIgnored", power.isIgnoringBatteryOptimizations(context.packageName))
                .put("backgroundRestricted", activity.isBackgroundRestricted)
                .put("powerSaveMode", power.isPowerSaveMode)
                .put("storedRunning", prefs.getBoolean(KEY_RUNNING, false))
                .put("storedStopReason", prefs.getString(KEY_STOP_REASON, null) ?: JSONObject.NULL)
                .put("storedLastAction", prefs.getString(KEY_LAST_ACTION, null) ?: JSONObject.NULL)
                .put("storedLastActionAtMillis", prefs.getLong(KEY_LAST_ACTION_AT, 0L))
                .put("storedPreviousRunAbnormal", prefs.getBoolean(KEY_PREVIOUS_RUN_ABNORMAL, false))
                .put("storedPreviousRunStartedAtMillis", prefs.getLong(KEY_PREVIOUS_RUN_STARTED_AT, 0L))
        }

        private fun persistStopReason(context: Context, reason: String) {
            try {
                context.getSharedPreferences(STATE_PREFERENCES, Context.MODE_PRIVATE).edit()
                    .putString(KEY_STOP_REASON, reason)
                    .putString(KEY_LAST_ACTION, "stop-request:$reason")
                    .putLong(KEY_LAST_ACTION_AT, System.currentTimeMillis())
                    .apply()
            } catch (failure: RuntimeException) {
                Log.w(LOG_TAG, "remote sync stop reason could not be saved", failure)
            }
        }
    }
}

/** Dart 侧「后台保持与电脑的连接」偏好的原生存储（`remote-sync-preferences`）。 */
object RemoteSyncPreferences {
    private const val PREFERENCES = "remote-sync-preferences"
    private const val KEY_BACKGROUND_SYNC = "backgroundSync"
    private const val KEY_BATTERY_GUIDE_SHOWN = "batteryGuideShown"

    /** 是否在启动后自动保持远程连接与后台服务；默认开启（用户可在设置页关闭）。 */
    fun backgroundSync(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean(KEY_BACKGROUND_SYNC, true)

    fun setBackgroundSync(context: Context, enabled: Boolean): Boolean {
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return prefs.edit().putBoolean(KEY_BACKGROUND_SYNC, enabled).commit()
    }

    /** 电池优化引导是否已经展示/处理过；只展示一次，避免反复打扰。 */
    fun batteryGuideShown(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean(KEY_BATTERY_GUIDE_SHOWN, false)

    /** 消费一次性引导：第一次返回 true，之后返回 false。 */
    fun consumeBatteryGuide(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_BATTERY_GUIDE_SHOWN, false)) return false
        return prefs.edit().putBoolean(KEY_BATTERY_GUIDE_SHOWN, true).commit()
    }
}

/**
 * Android 标准电池优化豁免的读取与请求。
 *
 * 只使用系统设置页：`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 需要 Manifest 声明
 * `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`，部分应用商店不支持直接请求，因此失败时退回
 * 电池优化列表页；两者都由用户自己确认，App 不修改任何策略。
 */
object BatteryOptimizationSettings {
    /** 当前是否已豁免；读取失败按未豁免处理（只影响提示，不阻塞同步）。 */
    fun ignored(context: Context): Boolean = try {
        context.getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(context.packageName)
    } catch (_: RuntimeException) {
        false
    }

    /**
     * 打开系统的电池优化请求页。
     *
     * @return `"request"`：直接请求本应用豁免；`"list"`：电池优化列表（用户在列表里
     * 手动选择）；`null`：两者都不存在，调用方应退回应用详情页。
     */
    fun request(activity: Activity): String? {
        if (ignored(activity)) return "already-ignored"
        val packageUri = Uri.parse("package:${activity.packageName}")
        val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            activity.startActivity(request)
            return "request"
        } catch (_: ActivityNotFoundException) {
            // 部分 ROM 移除了直接请求入口。
        } catch (_: SecurityException) {
            // 没有 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 时系统抛 SecurityException。
        }
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            activity.startActivity(list)
            "list"
        } catch (_: ActivityNotFoundException) {
            null
        }
    }
}

/**
 * 厂商（OEM）后台策略设置页的启发式跳转。
 *
 * ColorOS/EMUI/MIUI 等系统把「自启动」「耗电管理」放在各自的设置应用里，App 无法读取
 * 这些策略，只能尽量打开对应页面；入口名称与位置随机型和系统版本变化，因此每个候选
 * 都先 `resolveActivity` 再启动，全部失败时退回系统应用详情页（用户可自行找到
 * 「耗电管理 / 自启动」）。返回实际命中的候选名，便于设置页给出可读反馈。
 */
object OemBackgroundSettings {
    private class Candidate(val label: String, val component: ComponentName)

    private val candidates = listOf(
        // OPPO / ColorOS / realme（用户设备为 ColorOS）。
        Candidate("OPPO 自启动管理", ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
        Candidate("OPPO 自启动管理（旧版）", ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
        Candidate("OPPO 自启动管理（oplus）", ComponentName("com.oplus.safecenter", "com.oplus.safecenter.permission.startup.StartupAppListActivity")),
        Candidate("OPPO 耗电管理", ComponentName("com.coloros.powermanager.fuelgaue", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity")),
        Candidate("OPPO 后台管理", ComponentName("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity")),
        // 华为 / 荣耀。
        Candidate("华为自启动管理", ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
        Candidate("荣耀自启动管理", ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
        // 小米 / 红米。
        Candidate("小米自启动管理", ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
        // vivo / iQOO。
        Candidate("vivo 后台启动管理", ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
        Candidate("iQOO 自启动管理", ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
        // 三星。
        Candidate("三星电池管理", ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity")),
        // 一加。
        Candidate("一加自启动管理", ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity")),
    )

    /**
     * 打开第一个可用的厂商后台设置页。
     *
     * @return 命中的候选名；全部不可用时打开应用详情页并返回 `"app-details"`；连应用
     * 详情页都打不开时返回 null。
     */
    fun open(activity: Activity): String? {
        for (candidate in candidates) {
            val intent = Intent().setComponent(candidate.component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                if (intent.resolveActivity(activity.packageManager) == null) continue
                activity.startActivity(intent)
                return candidate.label
            } catch (_: ActivityNotFoundException) {
                continue
            } catch (_: SecurityException) {
                continue
            }
        }
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", activity.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            activity.startActivity(details)
            "app-details"
        } catch (_: ActivityNotFoundException) {
            null
        }
    }
}
