package com.minnnng.dsh_android

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Native presentation of the core's pending DSH interactions. The service owns
 * this instance; core snapshots decide request lifetime and response semantics.
 */
class ApprovalNotifications(
    private val context: Context,
    private val dispatch: (JSONObject, (Result<JSONObject>) -> Unit) -> Unit,
) : AutoCloseable {
    private data class Action(
        val id: String,
        val label: String,
        val response: Any,
        val questionId: String? = null,
    )

    private data class Request(
        val id: String,
        val version: Long,
        val sessionId: String,
        val title: String,
        val body: String,
        val actions: List<Action>,
    )

    private data class Entry(
        val request: Request,
        var offer: ApprovalActionLedger.Offer,
        val intents: MutableSet<PendingIntent> = linkedSetOf(),
        var draft: String? = null,
        var notice: String? = null,
        var resolved: Boolean = false,
    )

    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val keyguard = context.getSystemService(KeyguardManager::class.java)
    private val ledger = ApprovalActionLedger(SystemClock::elapsedRealtime, { UUID.randomUUID().toString() }, TOKEN_LIFETIME_MS)
    private val entries = linkedMapOf<String, Entry>()
    private var snapshotRevision = -1L
    private var closed = false
    private val renewTokens = Runnable { renewExpiredTokens() }

    init {
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "任务授权与提问", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "处理 DSH 的待审批操作和提问"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        // A replaced Agent process cannot service old PendingIntents.
        notifications.activeNotifications.filter { it.tag?.startsWith(TAG_PREFIX) == true }
            .forEach { notifications.cancel(it.tag, it.id) }
    }

    /**
     * Snapshot: {revision, requests:[{id, version, sessionId, kind, ...DSH fields}]}.
     * A missing request is withdrawn. No native timer resolves or rejects it.
     */
    fun sync(snapshot: JSONObject) = onMain {
        if (closed) return@onMain
        val revision = snapshot.getLong("revision")
        if (revision <= snapshotRevision) return@onMain
        val array = snapshot.getJSONArray("requests")
        val next = linkedMapOf<String, Request>()
        for (index in 0 until array.length()) {
            val request = parse(array.getJSONObject(index))
            require(next.put(request.id, request) == null) { "Duplicate pending interaction" }
        }
        for (id in entries.keys.filter { it !in next }) remove(id)
        for ((id, request) in next) {
            val previous = entries[id]
            if (previous != null && previous.request.version > request.version) continue
            if (previous == null || previous.request.version != request.version) {
                previous?.let { cancelIntents(it) }
                val offer = ledger.offer(id, request.version, request.actions.map { it.id }.toSet())
                entries[id] = Entry(request, offer)
            }
            if (previous == null || previous.request.version != request.version) {
                entries[id]?.let { show(it) }
            }
        }
        snapshotRevision = revision
        scheduleRenewal()
    }

    /** Re-post still-pending items after the user changes notification permission/channel settings. */
    fun refresh() = onMain {
        if (closed) return@onMain
        renewExpiredTokens()
        entries.values.forEach { show(it) }
    }

    /** Current notification draft only; the App can recover text after a failed direct reply. */
    fun draft(id: String, version: Long): String? {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Read notification drafts on the service handler" }
        return entries[id]?.takeIf { it.request.version == version }?.draft
    }

    /**
     * Handle only the explicit receiver's payload. The response passed to dispatch
     * is the original DSH outcome or AskUserQuestionAnswer, never a native policy.
     */
    fun handle(payload: JSONObject, reply: (JSONObject) -> Unit) = onMain {
        if (closed) {
            reply(result(false, "service-unavailable"))
            return@onMain
        }
        val id = payload.optString("id")
        val version = payload.optLong("version", -1)
        val entry = entries[id]
        val action = entry?.request?.actions?.firstOrNull { it.id == payload.optString("actionId") }
        if (entry == null || entry.resolved || entry.request.version != version || action == null) {
            reply(result(false, "stale"))
            return@onMain
        }
        if (!ledger.canClaim(id, version, payload.optString("token"), action.id)) {
            renewExpiredTokens()
            reply(result(false, "stale"))
            return@onMain
        }
        val text = if (action.questionId == null) null else payload.opt("text") as? String
        if (text != null) entry.draft = text
        if (keyguard.isDeviceLocked) {
            entry.notice = "请先解锁设备，再处理此请求"
            show(entry)
            reply(result(false, "locked"))
            return@onMain
        }
        if (action.questionId != null && (text == null || text.length > MAX_REPLY_CHARS)) {
            entry.notice = "请在 App 中填写并提交"
            show(entry)
            reply(result(false, "input-required"))
            return@onMain
        }
        if (!ledger.claim(id, version, payload.optString("token"), action.id)) {
            renewExpiredTokens()
            reply(result(false, "stale"))
            return@onMain
        }
        entry.notice = "正在提交，请稍候"
        cancelIntents(entry)
        show(entry)
        val response = if (action.questionId == null) action.response else JSONObject().put(
            "answers", JSONArray().put(
                JSONObject().put("id", action.questionId).put("selected", JSONArray()).put("custom", text),
            ),
        )
        val request = JSONObject().put("id", id).put("version", version).put("response", response)
        try {
            dispatch(request) { outcome ->
                onMain {
                    if (closed || entries[id] !== entry) {
                        reply(result(false, "stale"))
                        return@onMain
                    }
                    val ack = outcome.getOrNull()
                    if (ack?.optBoolean("accepted") == true) {
                        entry.resolved = true
                        entry.draft = null
                        cancelIntents(entry)
                        notifications.cancel(tag(id), NOTIFICATION_ID)
                        reply(result(true, "accepted"))
                    } else {
                        // Unknown outcomes remain consumed. Only an explicit unapplied
                        // response may issue another token for the still-pending request.
                        if (ack?.opt("accepted") == false &&
                            ack.optBoolean("requestStillPending")) {
                            ledger.retryUnapplied(id, version)?.let { entry.offer = it }
                            entry.notice = "未能提交，可重试；填写内容已保留在 App"
                        } else {
                            entry.notice = "尚未确认处理结果，请在 App 中查看"
                        }
                        show(entry)
                        reply(result(false, "not-confirmed"))
                    }
                    scheduleRenewal()
                }
            }
        } catch (error: Exception) {
            // Dispatch may have crossed IPC already; never retry an unknown result automatically.
            entry.notice = "尚未确认处理结果，请在 App 中查看"
            show(entry)
            reply(result(false, "not-confirmed"))
        }
    }

    private fun parse(value: JSONObject): Request {
        val id = value.getString("id")
        val version = value.getLong("version")
        val sessionId = value.optString("sessionId")
        require(id.isNotBlank() && id.length <= 512 && version >= 0) { "Invalid pending interaction" }
        return when (value.getString("kind")) {
            "approval" -> {
                val tool = value.getString("toolName")
                val localized = value.optJSONObject("displayReason")
                val reason = localized?.optString("zh")?.takeIf { it.isNotBlank() }
                    ?: value.optString("reason").takeIf { it.isNotBlank() }
                    ?: "工具 $tool 请求审批"
                val arguments = value.optJSONObject("toolCall")?.opt("arguments")
                    ?.takeUnless { it === JSONObject.NULL }?.toString()
                val command = if (tool == "android_shell" && arguments != null) {
                    runCatching { JSONObject(arguments).opt("command") as? String }.getOrNull()
                } else null
                val cwd = if (tool == "android_shell") {
                    value.optJSONObject("executionContext")?.opt("cwd") as? String
                } else null
                val body = ApprovalNotificationText.format(tool, reason, arguments, command, cwd)
                Request(id, version, sessionId, "${tool.take(80)} · 等待审批", body, listOf(
                    Action("allowed-once", "允许一次", "allowed-once"),
                    Action("rejected", "拒绝", "rejected"),
                ))
            }
            "question" -> {
                val questions = value.getJSONArray("questions")
                val question = questions.optJSONObject(0)
                val options = question?.optJSONArray("options") ?: JSONArray()
                val compactOptions = (0 until options.length()).all {
                    val option = options.getJSONObject(it)
                    option.optString("description").isBlank() && option.getString("label").length <= 40
                }
                val simple = questions.length() == 1 && question != null &&
                    !question.optBoolean("multiSelect") && !question.has("intent") &&
                    question.optString("detail").isBlank() &&
                    question.optString("question").length <= 1000 &&
                    options.length() <= 2 && compactOptions
                val actions = mutableListOf<Action>()
                if (simple) {
                    val item = checkNotNull(question)
                    val questionId = item.getString("id")
                    for (index in 0 until options.length()) {
                        val label = options.getJSONObject(index).getString("label")
                        val answer = JSONObject().put("answers", JSONArray().put(
                            JSONObject().put("id", questionId).put("selected", JSONArray().put(label)),
                        ))
                        actions.add(Action("option-$index", label, answer))
                    }
                    actions.add(Action("custom", "填写", JSONObject.NULL, questionId))
                }
                val body = question?.optString("question")?.takeIf { it.isNotBlank() }
                    ?: "请在 App 中查看并回答"
                Request(id, version, sessionId, "任务需要你的回答", body.take(1000), actions)
            }
            else -> Request(id, version, sessionId, "任务需要你处理", "请在 App 中查看详情", emptyList())
        }
    }

    private fun show(entry: Entry) {
        if (closed || entry.resolved || !status(context).getBoolean("enabled")) return
        val request = entry.request
        val public = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Pocket Harness")
            .setContentText("有一个任务需要你处理")
            .build()
        val body = ApprovalNotificationText.withNotice(request.body, entry.notice)
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(request.title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setContentIntent(openIntent(entry))
        if (Build.VERSION.SDK_INT >= 29) builder.setAllowSystemGeneratedContextualActions(false)
        if (!entry.offer.isClaimed) {
            for (action in request.actions) {
                val button = Notification.Action.Builder(
                    Icon.createWithResource(context, android.R.drawable.ic_menu_send),
                    action.label,
                    actionIntent(entry, action),
                ).setAllowGeneratedReplies(false)
                if (action.questionId != null) {
                    button.addRemoteInput(RemoteInput.Builder(REPLY_KEY).setLabel("填写回答").build())
                }
                if (Build.VERSION.SDK_INT >= 31) button.setAuthenticationRequired(true)
                builder.addAction(button.build())
            }
        }
        try {
            notifications.notify(tag(request.id), NOTIFICATION_ID, builder.build())
        } catch (error: SecurityException) {
            // Permission may change between status() and notify(); the App keeps the pending item.
        }
    }

    private fun openIntent(entry: Entry): PendingIntent {
        val request = entry.request
        val intent = Intent(context, MainActivity::class.java)
            .setAction(OPEN_ACTION)
            .setData(uri(request, "open", ""))
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(ROUTE_EXTRA, "approval")
            .putExtra(ID_EXTRA, request.id)
            .putExtra(VERSION_EXTRA, request.version)
            .putExtra(SESSION_EXTRA, request.sessionId)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            .also { entry.intents.add(it) }
    }

    private fun actionIntent(entry: Entry, action: Action): PendingIntent {
        val intent = Intent(context, ApprovalActionReceiver::class.java)
            .setAction(RESPOND_ACTION)
            .setData(uri(entry.request, action.id, entry.offer.token))
            .putExtra(ID_EXTRA, entry.request.id)
            .putExtra(VERSION_EXTRA, entry.request.version)
            .putExtra(TOKEN_EXTRA, entry.offer.token)
            .putExtra(ACTION_EXTRA, action.id)
        val mutable = action.questionId != null
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (mutable && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE
            else if (mutable) 0 else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, 0, intent, flags).also { entry.intents.add(it) }
    }

    private fun uri(request: Request, action: String, token: String): Uri = Uri.Builder()
        .scheme("pocket-harness").authority("interaction").appendPath(request.id)
        .appendPath(request.version.toString()).appendPath(action).appendPath(token).build()

    private fun renewExpiredTokens() {
        if (closed) return
        for ((id, entry) in entries) {
            if (!entry.resolved && !entry.offer.isClaimed && SystemClock.elapsedRealtime() >= entry.offer.tokenExpiresAt) {
                ledger.renew(id, entry.request.version)?.let {
                    cancelIntents(entry)
                    entry.offer = it
                    show(entry)
                }
            }
        }
        scheduleRenewal()
    }

    private fun scheduleRenewal() {
        main.removeCallbacks(renewTokens)
        val next = entries.values.filter { !it.resolved && !it.offer.isClaimed }
            .minOfOrNull { it.offer.tokenExpiresAt } ?: return
        main.postDelayed(renewTokens, (next - SystemClock.elapsedRealtime()).coerceAtLeast(1))
    }

    private fun cancelIntents(entry: Entry) {
        entry.intents.forEach { it.cancel() }
        entry.intents.clear()
    }

    private fun remove(id: String) {
        entries.remove(id)?.let { cancelIntents(it) }
        ledger.remove(id)
        notifications.cancel(tag(id), NOTIFICATION_ID)
    }

    override fun close() = onMain {
        closed = true
        main.removeCallbacks(renewTokens)
        entries.keys.toList().forEach { remove(it) }
        ledger.clear()
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post(action)
    }

    companion object {
        const val CHANNEL_ID = "agent-requests"
        const val RESPOND_ACTION = "com.minnnng.dsh_android.RESPOND_INTERACTION"
        const val OPEN_ACTION = "com.minnnng.dsh_android.OPEN_INTERACTION"
        const val ROUTE_EXTRA = "pocket.route"
        const val ID_EXTRA = "pocket.requestId"
        const val VERSION_EXTRA = "pocket.requestVersion"
        const val SESSION_EXTRA = "pocket.sessionId"
        const val TOKEN_EXTRA = "pocket.actionToken"
        const val ACTION_EXTRA = "pocket.actionId"
        const val REPLY_KEY = "pocket.reply"
        const val MESSAGE_RESPOND = 4
        const val NOTIFICATION_ID = 1
        private const val TAG_PREFIX = "pocket-interaction:"
        private const val TOKEN_LIFETIME_MS = 30 * 60 * 1000L
        private const val MAX_REPLY_CHARS = 16384

        fun tag(id: String): String = TAG_PREFIX + id
        private fun result(accepted: Boolean, reason: String): JSONObject =
            JSONObject().put("accepted", accepted).put("reason", reason)

        fun status(context: Context): JSONObject {
            val manager = context.getSystemService(NotificationManager::class.java)
            val reason = when {
                Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED -> "permission"
                !manager.areNotificationsEnabled() -> "app-disabled"
                manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE -> "channel-disabled"
                else -> "enabled"
            }
            return JSONObject().put("enabled", reason == "enabled").put("reason", reason).put("channelId", CHANNEL_ID)
        }

        fun settingsIntent(context: Context): Intent {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channelExists = manager.getNotificationChannel(CHANNEL_ID) != null
            return Intent(if (channelExists) Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS else Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .apply { if (channelExists) putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID) }
        }
    }
}
