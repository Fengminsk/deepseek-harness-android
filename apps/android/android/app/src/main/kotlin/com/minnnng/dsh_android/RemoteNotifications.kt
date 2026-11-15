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
import android.util.Log

/**
 * 远程宿主推送（protocol §8.2 `remote.taskCompleted`、§8.3 `remote.approvalPending`）
 * 在系统通知栏上的呈现。
 *
 * 只做「弹一条 / 取消全部」，不持连接、不解释 DSH 状态：去重（同一 interactionId、
 * 同一 sessionId+turn 只提醒一次）由 Dart 侧 `RemoteNotificationDispatcher` 判定；
 * 这里只用协议 id 当 notification tag，让同一对象的重复 show 覆盖而不是叠加。
 *
 * ## 渠道
 *
 * 复用本地模式的两个渠道 id：`task-completed`「任务完成」与 `agent-requests`
 * 「任务授权与提问」。`createNotificationChannel` 对已存在的渠道是幂等的（只会同步
 * 名称/描述），用户在系统设置里对渠道的开关与重要性保持不变；因此远程通知与本地
 * 通知在设置里是同一组偏好，不会多出第三个渠道。
 *
 * ## 点击路由
 *
 * 复用 MainActivity 既有的通知点击 extra 约定（`pocket.route` / `pocket.sessionId`）。
 * 远程会话的深链路由尚未落地，`deliverNavigation` 目前不识别 `route = "remote"`，
 * 因此点击只会把 App 带到前台（Intent 里带着 sessionId / 远程通知种类，供后续加
 * 深链时直接使用，不改变通知负载）。
 *
 * ## Android 13+ 通知权限
 *
 * 不新增权限弹窗：权限入口仍是 MainActivity 既有的 `notifications.request` /
 * `start` 流程。这里只在权限/通知被关闭时静默降级（不 post、返回 false），
 * 与 `TaskCompletionNotifications` 的处理一致。
 */
class RemoteNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        // 幂等：渠道已存在时只会更新名称与描述，不重置用户改过的重要性/开关。
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_TASK_COMPLETED, "任务完成", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "后台任务完成后的简短提醒"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_AGENT_REQUESTS, "任务授权与提问", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "处理 DSH 的待审批操作和提问"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    /**
     * 弹一条远程系统通知。
     *
     * @param kind `taskCompleted` / `approvalPending`（Dart 侧 `RemoteNotificationKind.name`）。
     * @param tag 协议 id（任务 `taskId`、审批 `interactionId`），只做 tag 与去重键。
     * @param sessionId 点击通知时随 Intent 带出的会话 id；可空。
     * @return 是否真的交给系统；权限关闭/渠道路径不合法时返回 false，不抛异常。
     */
    fun show(kind: String?, title: String?, body: String?, tag: String?, sessionId: String?): Boolean {
        val channel = when (kind) {
            KIND_TASK_COMPLETED -> CHANNEL_TASK_COMPLETED
            KIND_APPROVAL_PENDING -> CHANNEL_AGENT_REQUESTS
            else -> return false
        }
        if (title.isNullOrBlank() || tag.isNullOrBlank()) return false
        if (!allowed(channel)) return false
        val safeTag = normalize(tag, MAX_ID_CHARS)
        if (safeTag.isEmpty()) return false
        val text = body.orEmpty().take(MAX_BODY_CHARS).ifBlank { "轻点查看详情" }
        val intent = Intent(context, MainActivity::class.java)
            .setAction(OPEN_ACTION)
            .setData(Uri.Builder().scheme("pocket-harness").authority("remote")
                .appendPath(kind).appendPath(safeTag).build())
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(ROUTE_EXTRA, "remote")
            .putExtra(KIND_EXTRA, kind)
            .putExtra(TAG_EXTRA, safeTag)
            .putExtra(SESSION_EXTRA, normalize(sessionId.orEmpty(), MAX_SESSION_CHARS))
        val open = PendingIntent.getActivity(
            context,
            safeTag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.pocket_mark)
            .setContentTitle(title.take(MAX_TITLE_CHARS))
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 29) builder.setAllowSystemGeneratedContextualActions(false)
        return try {
            manager.notify(notificationTag(kind, safeTag), notificationId(kind), builder.build())
            true
        } catch (error: SecurityException) {
            // 权限可能在 allowed() 与 notify() 之间被撤销。
            Log.w(LOG_TAG, "Remote notification permission changed", error)
            false
        } catch (error: RuntimeException) {
            Log.w(LOG_TAG, "Remote notification could not be posted", error)
            false
        }
    }

    /**
     * 取消全部远程通知。
     *
     * 只按远程 tag 前缀过滤逐个取消：本地模式的 tag（`pocket-completed:` /
     * `pocket-interaction:`）不受影响，由各自的本地通知所有者管理。
     */
    fun cancelAll() {
        try {
            for (active in manager.activeNotifications) {
                val tag = active.tag ?: continue
                if (!tag.startsWith(TAG_PREFIX)) continue
                manager.cancel(tag, active.id)
            }
        } catch (error: RuntimeException) {
            Log.w(LOG_TAG, "Remote notifications could not be cleared", error)
        }
    }

    /** 与本地通知一致的权限/渠道判定；关闭时静默降级。 */
    private fun allowed(channel: String): Boolean = (Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        manager.areNotificationsEnabled() &&
        manager.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE

    /** 协议字段可能带控制字符；tag 只保留普通字符并截到上限。 */
    private fun normalize(value: String, maxChars: Int): String =
        value.replace(Regex("[\\p{Cntrl}]"), " ").trim().take(maxChars)

    companion object {
        private const val LOG_TAG = "PocketRemoteNotice"

        /** 与 `TaskCompletionNotifications` 相同的渠道 id；远程/本地共用设置偏好。 */
        const val CHANNEL_TASK_COMPLETED = "task-completed"

        /** 与 `ApprovalNotifications.CHANNEL_ID` 相同的渠道 id。 */
        const val CHANNEL_AGENT_REQUESTS = "agent-requests"

        /** Dart 侧 `notifications.remote.show` 的 kind 取值。 */
        const val KIND_TASK_COMPLETED = "taskCompleted"
        const val KIND_APPROVAL_PENDING = "approvalPending"

        /** 远程通知专用 tag 前缀；`cancelAll` 只清这个前缀。 */
        private const val TAG_PREFIX = "pocket-remote:"

        /** 点击打开 App 的 action；与本地通知的 action 区分，便于后续加远程深链。 */
        const val OPEN_ACTION = "com.minnnng.dsh_android.OPEN_REMOTE_NOTIFICATION"

        /** 与 `ApprovalNotifications` / `TaskCompletionNotifications` 相同的点击 extra 约定。 */
        private const val ROUTE_EXTRA = "pocket.route"
        private const val SESSION_EXTRA = "pocket.sessionId"
        private const val KIND_EXTRA = "pocket.remoteKind"
        private const val TAG_EXTRA = "pocket.remoteTag"

        /** 远程通知 id：与本地通知的 3（任务完成）/ 1（审批）错开。 */
        private const val NOTIFICATION_ID_TASK_COMPLETED = 21
        private const val NOTIFICATION_ID_APPROVAL_PENDING = 22

        private const val MAX_ID_CHARS = 128
        private const val MAX_SESSION_CHARS = 128
        private const val MAX_TITLE_CHARS = 200
        private const val MAX_BODY_CHARS = 1024

        private fun notificationTag(kind: String, id: String): String = "$TAG_PREFIX$kind:$id"

        private fun notificationId(kind: String): Int = when (kind) {
            KIND_TASK_COMPLETED -> NOTIFICATION_ID_TASK_COMPLETED
            KIND_APPROVAL_PENDING -> NOTIFICATION_ID_APPROVAL_PENDING
            else -> NOTIFICATION_ID_TASK_COMPLETED
        }
    }
}
