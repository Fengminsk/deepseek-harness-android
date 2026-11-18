package com.minnnng.dsh_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * 主进程的前台同步服务：App 退到后台时保持进程与 Flutter UI isolate 存活，
 * 让远程连接的 WebSocket、`session.follow` 与 `remote.*` 通知继续运行。
 *
 * 服务本身不持连接、不解析协议：连接由 Dart 侧 `RemoteConnectionController`
 * 维护；这里只声明「正在与电脑保持同步」的低优先级常驻通知，避免系统在后台
 * 回收主进程。Dart 在远程连接 ready 且会话页仍打开时通过 `remote.sync.start`
 * 启动，页面销毁/连接终止时 `remote.sync.stop`。
 *
 * 通知渠道 `remote-sync` 为 IMPORTANCE_LOW：不响铃、不弹横幅，只在通知栏里
 * 说明后台同步正在运行。点击通知回到 App（MainActivity）。
 */
class RemoteSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "与电脑保持同步", NotificationManager.IMPORTANCE_LOW).apply {
                description = "App 退到后台时保持远程连接，以便接收任务完成与审批提问通知"
                setShowBadge(false)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 进程被系统回收后 START_STICKY 可能在没有 FlutterEngine/Dart isolate 的
        // 情况下重启服务：此时没有连接可保持，留着「同步中」通知只会误导用户。
        // 直接退出，用户下次打开 App 后由 Dart 在连接 ready 时重新启动。
        if (!MainActivity.uiAlive) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        startForeground(NOTIFICATION_ID, notification())
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.pocket_mark)
            .setContentTitle("Pocket Harness")
            .setContentText("与电脑保持同步")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        return builder.build()
    }

    companion object {
        /** 通知渠道 id；与 Dart 侧没有耦合，只用于系统通知栏分组。 */
        const val CHANNEL_ID = "remote-sync"

        /** 常驻通知 id；后台同步只允许一条。 */
        const val NOTIFICATION_ID = 2

        private const val ACTION_STOP = "com.minnnng.dsh_android.remote.sync.STOP"

        /** 服务是否由本进程启动过；MainActivity 的 `remote.sync.status` 读它。 */
        @Volatile
        var running: Boolean = false
            private set

        /** 前台启动服务；必须从 Activity/前台上下文调用（Android 12+ 后台启动限制）。 */
        fun start(context: Context) {
            context.startForegroundService(Intent(context, RemoteSyncService::class.java))
        }

        /** 请求停止服务并移除常驻通知。 */
        fun stop(context: Context) {
            context.stopService(Intent(context, RemoteSyncService::class.java).setAction(ACTION_STOP))
        }
    }
}
