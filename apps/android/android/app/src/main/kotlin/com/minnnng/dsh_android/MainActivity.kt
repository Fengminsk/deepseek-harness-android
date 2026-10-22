package com.minnnng.dsh_android

import android.Manifest
import android.content.*
import android.os.*
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.util.UUID

/** Flutter talks to the service over Binder; no HTTP listener is needed by the App. */
class MainActivity : FlutterActivity() {
    private var service: Messenger? = null
    private var events: EventChannel.EventSink? = null
    private var documentPreviews: DocumentPreviewFactory? = null
    private val transfers by lazy { DocumentTransfers(this) }
    private val exports by lazy { DocumentExports(this) }
    private val attachmentFiles by lazy {
        AttachmentFileSaves(this) { id, complete ->
            sendCall(JSONObject().put("method", "session.attachmentFile.info")
                .put("params", JSONObject().put("id", id)), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    try { complete(JSONObject(result as String), null) }
                    catch (_: Exception) { complete(null, "附件状态无法确认，请重新打开") }
                }
                override fun error(code: String, message: String?, details: Any?) {
                    complete(null, "附件副本已失效，请重新打开")
                }
                override fun notImplemented() { complete(null, "附件保存服务尚未就绪") }
            })
        }
    }
    private val attachments by lazy { AttachmentTransfers(this) }
    private val externalFiles by lazy { ExternalFileOpening(this) { frame, result -> sendCall(frame, result); Unit } }
    private val configurationTransfers by lazy { ConfigurationTransfers(this) }
    private var bound = false
    private var connection: ServiceConnection? = null
    private var foreground = false
    private var notificationSessionId: String? = null
    private var runtimeRequested = false
    private var notificationPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private var restarting: MethodChannel.Result? = null
    private val recoveryControl by lazy { RecoveryRuntime(this) }
    private var restartTargetMode = "active"
    private var restartModeToken: String? = null
    private var restartReturnsState = false
    private var restartAwaitingNewStatus = false
    private var restartModePersisting = false
    private var restartModePersisted = false
    private var replacementStarted = false
    private var restartBinder: IBinder? = null
    private var restartDeath: IBinder.DeathRecipient? = null
    private var restartAwaitingOldConnection = false
    private val restartTimeout = Runnable {
        val result = restarting ?: return@Runnable
        clearRestartObserver()
        abortTransition()
        restarting = null
        restartAwaitingOldConnection = false
        result.error("restart-timeout", "无法确认旧运行时退出或新模式生效；请重新读取状态，未确认退出时不会启动第二个实例。", null)
    }
    private val pending = mutableMapOf<String, MethodChannel.Result>()
    private val bindingHandshake by lazy { RuntimeBindingHandshake(object : RuntimeBindingHandshake.Host {
        override fun foreground() = foreground
        override fun transitioning() = restarting != null
        override fun alive() = service?.binder?.isBinderAlive == true
        override fun ensureStarted() {
            // AgentService alone reads the persisted active/maintenance mode.
            // Its started guard prevents a second Node boot in a live process.
            startForegroundService(Intent(this@MainActivity, AgentService::class.java))
        }
        override fun bind() = bindRuntime()
        override fun probe(completion: RuntimeBindingHandshake.Completion): Runnable {
            val peer = service
            val id = sendCall(JSONObject().put("method", "runtime.status").put("params", JSONObject()),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (peer == null || service?.binder !== peer.binder || !peer.binder.isBinderAlive) {
                            completion.finish("disconnected", "本地服务连接已变化，请重新核对")
                            return
                        }
                        try {
                            check(JSONObject(result as String).optString("phase").isNotEmpty())
                            completion.finish(null, null)
                        } catch (_: Exception) {
                            completion.finish("binding-failed", "本地服务未返回有效状态，请重试连接")
                        }
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        completion.finish(code, message)
                    }
                    override fun notImplemented() {
                        completion.finish("binding-failed", "本地服务未提供运行状态")
                    }
                })
            return Runnable { if (id != null) pending.remove(id) }
        }
    }, object : RuntimeBindingHandshake.Scheduler {
        override fun schedule(task: Runnable, milliseconds: Long) { main.postDelayed(task, milliseconds) }
        override fun cancel(task: Runnable) { main.removeCallbacks(task) }
    }) }
    private var replies = createReplies(0)
    private fun createReplies(generation: Long) = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (!bindingHandshake.accepts(generation)) {
            WirePayload.close(message.data)
            return@Handler true
        }
        val raw = WirePayload.decode(message.data)
        val frame = JSONObject(raw)
        if (frame.has("id")) {
            pending.remove(frame.getString("id"))?.let { result ->
                if (frame.has("error")) {
                    val error = frame.getJSONObject("error")
                    val code = error.opt("code")
                    val details = error.optJSONObject("details")
                    val proof = if (details?.optString("outcome") == "not-started")
                        mapOf("outcome" to "not-started", "requestId" to details.optString("requestId")) else null
                    result.error(if (code is String) code else "runtime", error.optString("message"), proof)
                }
                else result.success((frame.opt("result") ?: JSONObject.NULL).toString())
            }
        } else if (frame.optString("method") == "runtime.transition") {
            transitionAccepted(frame.getJSONObject("params"))
        } else {
            if (frame.optString("method") == "runtime.status") {
                val state = frame.getJSONObject("params")
                if (restarting != null && restartAwaitingNewStatus &&
                    state.optString("modeToken") == restartModeToken &&
                    state.optString("phase") == "maintenance-blocked") {
                    val result = restarting
                    restarting = null
                    restartAwaitingNewStatus = false
                    clearRestartObserver()
                    restartModeToken = null
                    result?.error("recovery/maintenance-blocked", "维护模式无法确认遗留进程已停止，配置仍为只读", null)
                }
                if (restarting != null && restartAwaitingNewStatus &&
                    state.optString("modeToken") == restartModeToken &&
                    state.optString("mode") == restartTargetMode &&
                    (restartTargetMode != "maintenance" ||
                        state.optString("phase") == "maintenance" && !state.optBoolean("nodeStarted", true)
                            && state.optBoolean("mutationAllowed"))) {
                    val result = restarting
                    restarting = null
                    restartAwaitingNewStatus = false
                    clearRestartObserver()
                    if (restartReturnsState) result?.success(state.toString()) else result?.success(null)
                    restartModeToken = null
                }
            }
            documentPreviews?.receive(frame)
            events?.success(raw)
        }
        true
    })
    private fun ensureBinding(result: MethodChannel.Result? = null, opening: Boolean = false) {
        bindingHandshake.ensure({ code, message ->
            if (code == null) {
                result?.success(null)
                try { service?.send(Message.obtain(null, 5).apply { replyTo = replies }) }
                catch (_: RemoteException) { /* The subsequent status read reports loss. */ }
            } else result?.error(code, message, null)
        }, opening)
    }
    private fun failPending(code: String, message: String) {
        val requests = pending.values.toList()
        pending.clear()
        requests.forEach { it.error(code, message, null) }
    }
    private fun releaseBinding(code: String = "disconnected", message: String = "运行时连接已变化，操作结果需重新核对") {
        documentPreviews?.disconnected()
        attachmentFiles.cancelCurrent()
        val previous = connection
        connection = null
        bindingHandshake.invalidateBinding()
        if (bound && previous != null) {
            try { service?.send(Message.obtain(null, 3).apply { replyTo = replies }) }
            catch (_: RemoteException) { /* Already stopped. */ }
            try { unbindService(previous) }
            catch (_: IllegalArgumentException) { /* Framework already removed the dead binding. */ }
        }
        bound = false
        service = null
        failPending(code, message)
    }
    private fun bindRuntime() {
        releaseBinding()
        val generation = bindingHandshake.newBinding()
        replies = createReplies(generation)
        val next = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (!bindingHandshake.accepts(generation) || connection !== this) return
                if (binder == null) { lostBinding(this); return }
                service = Messenger(binder)
                try { service!!.send(Message.obtain(null, 1).apply { replyTo = replies }) }
                catch (_: RemoteException) { lostBinding(this); return }
                publishNotificationView()
                if (restartAwaitingOldConnection) {
                    restartAwaitingOldConnection = false
                    prepareTransition()
                    return
                }
                bindingHandshake.connected()
            }
            override fun onServiceDisconnected(name: ComponentName?) { lostBinding(this) }
            override fun onBindingDied(name: ComponentName?) { lostBinding(this) }
            override fun onNullBinding(name: ComponentName?) { lostBinding(this) }
        }
        connection = next
        try {
            bound = bindService(Intent(this, AgentService::class.java), next, Context.BIND_AUTO_CREATE)
            check(bound) { "Cannot bind Agent service" }
        } catch (failure: Exception) {
            if (connection === next) {
                connection = null
                bound = false
                bindingHandshake.invalidateBinding()
            }
            throw failure
        }
    }
    private fun lostBinding(lost: ServiceConnection) {
        if (connection !== lost) return
        bindingHandshake.disconnected()
        releaseBinding()
        if (restarting != null) return
        events?.success(JSONObject().put("method", "runtime.status").put("params",
            JSONObject().put("phase", "failed").put("connection", "disconnected")
                .put("error", "运行时进程已停止，任务可能已中断")).toString())
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        externalFiles // Schedule bounded staging-cache cleanup on each Activity start.
        documentPreviews = DocumentPreviewFactory(engine.dartExecutor.binaryMessenger) { frame, result -> sendCall(frame, result); Unit }.also {
            engine.platformViewsController.registry.registerViewFactory("dsh/document-preview", it)
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "dsh/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink; deliverNavigation() }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(engine.dartExecutor.binaryMessenger, "dsh/runtime").setMethodCallHandler { call, result ->
            when (call.method) {
                "app.metadata" -> result.success(AuthTabs.metadata(this))
                "attachment.pick" -> attachments.pick(result)
                "configurationTransfer.pick" -> configurationTransfers.pick(call.argument<String>("id") ?: "", result)
                "configurationTransfer.save" -> configurationTransfers.save(
                    call.argument<String>("id") ?: "", call.argument<String>("text") ?: "",
                    call.argument<String>("filename") ?: "", result)
                "configurationTransfer.cancel" -> {
                    configurationTransfers.cancel(call.argument<String>("id") ?: "")
                    result.success(null)
                }
                "background.systemStatus" -> {
                    val power = getSystemService(PowerManager::class.java)
                    val activity = getSystemService(android.app.ActivityManager::class.java)
                    result.success(JSONObject()
                        .put("batteryOptimizationsIgnored", power.isIgnoringBatteryOptimizations(packageName))
                        .put("backgroundRestricted", activity.isBackgroundRestricted)
                        .put("powerSaveMode", power.isPowerSaveMode).toString())
                }
                "background.openSystemSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null)))
                        result.success(null)
                    } catch (failure: Exception) { result.error("settings", "无法打开系统应用设置", null) }
                }
                "background.overlay.openPermission" -> {
                    try {
                        startActivity(TaskOverlayWindow.permissionIntent(this))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("overlay-permission", "无法打开悬浮窗授权页面，请在系统设置中查找", null)
                    }
                }
                "account.openPage" -> {
                    try {
                        AuthTabs.open(this, call.argument<String>("url") ?: "", call.argument<Boolean>("dark") ?: false)
                        result.success(null)
                    } catch (exception: Exception) { result.error("account-page", exception.message, null) }
                }
                "sessionExport.save" -> exports.save(call.argument<String>("id") ?: "", call.argument<String>("filename") ?: "", result)
                "sessionExport.cancel" -> {
                    exports.cancel(call.argument<String>("id") ?: "")
                    result.success(null)
                }
                "attachmentFile.save" -> attachmentFiles.save(call.argument<String>("id") ?: "",
                    call.argument<String>("filename") ?: "", result)
                "attachmentFile.cancelSave" -> attachmentFiles.cancel(call.argument<String>("id") ?: "") {
                    result.success(null)
                }
                "notifications.status" -> result.success(ApprovalNotifications.status(this).toString())
                "notifications.viewing" -> {
                    val sessionId = call.argument<String>("sessionId")
                    if (sessionId != null && (sessionId.isBlank() || sessionId.length > 512)) {
                        result.error("notification-session", "无效的会话标识", null)
                    } else {
                        notificationSessionId = sessionId
                        publishNotificationView()
                        result.success(null)
                    }
                }
                "notifications.settings" -> {
                    startActivity(ApprovalNotifications.settingsIntent(this))
                    result.success(null)
                }
                "notifications.request" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        if (notificationPermission != null) result.error("busy", "通知权限请求已经打开", null)
                        else {
                            notificationPermission = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 43)
                        }
                    } else result.success(null)
                }
                "restart" -> restartRuntime(result)
                "runtime.ensureBound" -> ensureBinding(result)
                "recovery.enter", "recovery.resume" -> {
                    val id = call.argument<String>("requestId") ?: ""
                    try {
                        RecoveryFiles.requestId(id)
                        restartRuntime(result, if (call.method == "recovery.enter") "maintenance" else "active", true, id)
                    } catch (_: Exception) {
                        result.error("recovery/request-invalid", "恢复操作标识无效", null)
                    }
                }
                "recovery.call" -> {
                    try {
                        val request = JSONObject(call.arguments as String)
                        sendCall(JSONObject().put("method", "recovery.call").put("params", request), result)
                    } catch (_: Exception) { result.error("recovery/request-invalid", "恢复请求无法读取", null) }
                }
                "appearance.load" -> result.success(getSharedPreferences("appearance", MODE_PRIVATE).getString("value", "{}"))
                "appearance.save" -> {
                    try {
                        val raw = call.arguments as String
                        require(raw.length < 4096) { "Theme settings too large" }
                        val value = JSONObject(raw)
                        require(value.getString("mode") in setOf("system", "light", "dark"))
                        require(value.getString("glass") in setOf("none", "standard", "ultra"))
                        require(value.getString("style") in setOf("vivid", "tinted", "soft", "monochrome"))
                        require(value.getDouble("textScale") == 0.0 || value.getDouble("textScale") in 0.8..1.5)
                        check(getSharedPreferences("appearance", MODE_PRIVATE).edit().putString("value", value.toString()).commit()) { "Theme settings could not be saved" }
                        result.success(null)
                    } catch (exception: Exception) { result.error("preferences", exception.message, null) }
                }
                "start" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
                    }
                    runtimeRequested = true
                    ensureBinding(result, opening = true)
                }
                "call" -> {
                    sendCall(JSONObject(call.arguments as String), result)
                }
                "pickDirectory" -> transfers.pickDirectory(result)
                "pickDocument" -> transfers.pickDocument(result)
                "file.openDocument" -> externalFiles.document(call.argument<String>("requestId") ?: "",
                    call.argument<String>("root") ?: "", call.argument<String>("path") ?: "", result)
                "file.openWorkspace" -> externalFiles.workspace(call.argument<String>("requestId") ?: "",
                    call.argument<String>("path") ?: "", result)
                "file.openSession" -> externalFiles.session(call.argument<String>("requestId") ?: "",
                    call.argument<String>("sessionId") ?: "", call.argument<String>("path") ?: "", result)
                "file.launchPrepared" -> externalFiles.launchPrepared(call.argument<String>("requestId") ?: "", result)
                "file.cancelOpen" -> externalFiles.cancel(call.argument<String>("requestId") ?: "", result)
                "shareText" -> {
                    val text = call.arguments as? String
                    if (text.isNullOrBlank() || text.toByteArray(Charsets.UTF_8).size > 512 * 1024) {
                        result.error("share", "内容为空或过长，无法分享", null)
                    } else try {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                        }
                        startActivity(Intent.createChooser(intent, "分享回复"))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("share", "暂时无法打开系统分享", null)
                    }
                }
                "openUrl" -> {
                    val uri = Uri.parse(call.arguments as String)
                    if (uri.scheme != "http" && uri.scheme != "https") result.error("url", "不支持的链接", null) else {
                        startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null)
                    }
                }
                "browser.open" -> {
                    try {
                        val target = BrowserUrlPolicy.parse(call.arguments as? String, null, null)
                        CustomTabsIntent.Builder().setShowTitle(true).build()
                            .launchUrl(this, Uri.parse(target))
                        result.success(null)
                    } catch (_: IllegalArgumentException) {
                        result.error("browser/address", "请输入有效的远程网页地址。", null)
                    } catch (_: ActivityNotFoundException) {
                        result.error("browser/unavailable", "未找到可打开网页的浏览器。", null)
                    } catch (_: SecurityException) {
                        result.error("browser/unavailable", "浏览器无法打开此网页。", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun sendCall(frame: JSONObject, result: MethodChannel.Result): String? {
        val peer = service
        if (peer == null) { result.error("starting", "正在连接本地服务", null); return null }
        val id = UUID.randomUUID().toString()
        frame.put("jsonrpc", "2.0").put("id", id)
        pending[id] = result
        try {
            val payload = WirePayload.encode(frame.toString())
            try { peer.send(Message.obtain(null, 2).apply { replyTo = replies; data = payload }) }
            finally { WirePayload.close(payload) }
        } catch (_: Exception) {
            pending.remove(id)
            result.error("disconnected", "服务连接中断，操作结果未确认，请重新读取状态", null)
        }
        return id
    }
    private fun clearRestartObserver() {
        val binder = restartBinder
        val death = restartDeath
        if (binder != null && death != null && binder.isBinderAlive) binder.unlinkToDeath(death, 0)
        restartBinder = null
        restartDeath = null
        main.removeCallbacks(restartTimeout)
    }
    private fun restartRuntime(result: MethodChannel.Result, mode: String? = null,
                               returnState: Boolean = false, token: String = UUID.randomUUID().toString()) {
        if (restarting != null) { result.error("busy", "正在重启 Agent 服务", null); return }
        restarting = result
        bindingHandshake.transitionStarted()
        restartTargetMode = mode ?: try { recoveryControl.mode()[0] } catch (_: Exception) { "maintenance" }
        restartModeToken = token
        restartReturnsState = returnState
        restartAwaitingNewStatus = false
        restartModePersisting = false
        restartModePersisted = false
        replacementStarted = false
        main.postDelayed(restartTimeout, 20_000)
        val peer = service
        if (peer == null) {
            restartAwaitingOldConnection = true
            startReplacement()
            return
        }
        prepareTransition()
    }
    private fun prepareTransition() {
        val peer = service ?: return
        val token = restartModeToken ?: return
        val binder = peer.binder
        val death = IBinder.DeathRecipient { main.post {
            if (restarting == null || restartBinder !== binder) return@post
            if (restartModePersisted) replacementAfterDeath()
            else persistModeAndContinue(token, null)
        } }
        restartBinder = binder
        restartDeath = death
        try {
            binder.linkToDeath(death, 0)
            peer.send(Message.obtain(null, 6).apply {
                replyTo = replies
                data = Bundle().apply { putString("token", token) }
            })
        } catch (failure: RemoteException) {
            if (!binder.isBinderAlive) {
                clearRestartObserver()
                main.postDelayed(restartTimeout, 20_000)
                // There is no live process to reserve. Persist the target before its replacement.
                persistModeAndContinue(token, null)
            } else {
                val result = restarting
                clearRestartObserver()
                restarting = null
                result?.error("restart-failed", "未能请求旧服务退出，请稍后重试", null)
            }
        }
    }
    private fun transitionAccepted(params: JSONObject) {
        val token = restartModeToken ?: return
        if (restarting == null || params.optString("token") != token) return
        if (!params.optBoolean("accepted")) {
            val result = restarting
            restarting = null
            clearRestartObserver()
            restartModeToken = null
            result?.error(params.optString("code", "recovery/busy"),
                params.optString("message", "恢复操作仍在执行，未切换服务；请等待操作结果"), null)
            return
        }
        persistModeAndContinue(token, service)
    }
    private fun persistModeAndContinue(token: String, peer: Messenger?) {
        if (restartModePersisting || restarting == null || restartModeToken != token) return
        restartModePersisting = true
        val mode = restartTargetMode
        RecoveryModeQueue.execute {
            try {
                recoveryControl.setMode(mode, token)
                main.post {
                    if (restarting == null || restartModeToken != token) return@post
                    restartModePersisting = false
                    restartModePersisted = true
                    if (peer == null || !peer.binder.isBinderAlive) {
                        replacementAfterDeath()
                    } else {
                        try {
                            peer.send(Message.obtain(null, 8).apply {
                                replyTo = replies
                                data = Bundle().apply { putString("token", token) }
                            })
                        } catch (_: RemoteException) {
                            // Binder death owns replacement startup; timeout leaves the outcome explicit.
                        }
                    }
                }
            } catch (_: Exception) {
                main.post {
                    if (restarting == null || restartModeToken != token) return@post
                    restartModePersisting = false
                    val result = restarting
                    restarting = null
                    abortTransition()
                    clearRestartObserver()
                    result?.error("recovery/mode-unconfirmed", "模式偏好保存未确认，旧服务未被主动停止；请重新读取状态", null)
                }
            }
        }
    }
    private fun replacementAfterDeath() {
        if (replacementStarted || restarting == null) return
        replacementStarted = true
        clearRestartObserver()
        main.postDelayed(restartTimeout, 20_000)
        restartAwaitingNewStatus = true
        startReplacement()
    }
    private fun abortTransition() {
        val token = restartModeToken ?: return
        try { service?.send(Message.obtain(null, 9).apply {
            replyTo = replies
            data = Bundle().apply { putString("token", token) }
        }) } catch (_: RemoteException) { /* A dead process cannot retain a transition reservation. */ }
        restartModeToken = null
    }
    private fun startReplacement() {
        releaseBinding()
        val intent = Intent(this, AgentService::class.java)
        try {
            startForegroundService(intent)
            bindRuntime()
        } catch (failure: Exception) {
            val result = restarting
            restarting = null
            restartAwaitingOldConnection = false
            clearRestartObserver()
            result?.error("restart-failed", "Agent 服务重新启动失败，请重新打开恢复页面核对状态", null)
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNavigation()
    }
    private fun deliverNavigation() {
        val sink = events ?: return
        if (AccountReturnLink.accepts(intent.action, intent.dataString)) {
            intent.data = null
            sink.success(JSONObject().put("method", "navigation.open").put("params",
                JSONObject().put("route", "account")).toString())
            return
        }
        if (intent.getStringExtra("pocket.route") == "tasks") {
            intent.removeExtra("pocket.route")
            sink.success(JSONObject().put("method", "navigation.open").put("params",
                JSONObject().put("route", "tasks")).toString())
            return
        }
        if (intent.getStringExtra("pocket.route") == "session" && intent.action == TaskCompletionNotifications.OPEN_ACTION) {
            val sessionId = intent.getStringExtra("pocket.sessionId")
            intent.removeExtra("pocket.route")
            intent.removeExtra("pocket.sessionId")
            intent.data = null
            if (!sessionId.isNullOrBlank() && sessionId.length <= 512) {
                sink.success(JSONObject().put("method", "navigation.open").put("params",
                    JSONObject().put("route", "session").put("sessionId", sessionId)).toString())
            }
            return
        }
        if (intent.getStringExtra("pocket.route") != "approval") return
        val id = intent.getStringExtra("pocket.requestId") ?: return
        val version = intent.getLongExtra("pocket.requestVersion", -1)
        val params = JSONObject().put("route", "approval").put("requestId", id)
            .put("requestVersion", version).put("sessionId", intent.getStringExtra("pocket.sessionId"))
        sink.success(JSONObject().put("method", "navigation.open").put("params", params).toString())
        listOf("pocket.route", "pocket.requestId", "pocket.requestVersion", "pocket.sessionId").forEach { intent.removeExtra(it) }
    }
    override fun onResume() {
        super.onResume()
        foreground = true
        publishNotificationView()
        if (runtimeRequested && restarting == null) ensureBinding()
    }
    override fun onPause() {
        foreground = false
        publishNotificationView()
        bindingHandshake.backgrounded()
        super.onPause()
    }
    private fun publishNotificationView() {
        try {
            service?.send(Message.obtain(null, TaskCompletionNotifications.MESSAGE_VIEWING).apply {
                replyTo = replies
                data = Bundle().apply {
                    putString("sessionId", notificationSessionId)
                    putBoolean("foreground", foreground)
                }
            })
        } catch (error: RemoteException) {
            // Binder death releases this Activity's visible-session claim in AgentService.
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 43) {
            notificationPermission?.success(null)
            notificationPermission = null
        }
        if (requestCode == 41 || requestCode == 43) {
            try { service?.send(Message.obtain(null, 5).apply { replyTo = replies }) }
            catch (_: RemoteException) { /* Service disconnect is reported by ServiceConnection. */ }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (exports.onActivityResult(requestCode, resultCode, data)) return
        if (attachmentFiles.onActivityResult(requestCode, resultCode, data)) return
        if (attachments.onActivityResult(requestCode, resultCode, data)) return
        if (configurationTransfers.onActivityResult(requestCode, resultCode, data)) return
        transfers.onActivityResult(requestCode, resultCode, data)
    }
    override fun onDestroy() {
        documentPreviews?.close()
        documentPreviews = null
        bindingHandshake.close()
        // Release a pending transition while its original client still exists.
        abortTransition()
        releaseBinding("closed", "界面已关闭")
        notificationPermission?.error("closed", "界面已关闭", null)
        notificationPermission = null
        transfers.close()
        exports.close()
        attachmentFiles.close()
        externalFiles.close()
        attachments.close()
        configurationTransfers.close()
        restarting?.error("closed", "重启期间界面已关闭，请重新打开 App 查看运行时状态", null)
        restarting = null
        clearRestartObserver()
        super.onDestroy()
    }
}
