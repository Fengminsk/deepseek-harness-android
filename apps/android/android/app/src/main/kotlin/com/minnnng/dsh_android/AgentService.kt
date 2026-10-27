package com.minnnng.dsh_android

import android.app.*
import android.content.Intent
import android.os.*
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkRequest
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.CompletableFuture

/** Owns Node and its IPC endpoint; activity destruction does not terminate tasks. */
class AgentService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val lifecycle = RuntimeLifecycle()
    private val nodeStartLock = Any()
    private val workers = Executors.newCachedThreadPool()
    private val networkChanges = NetworkChangeDispatch(lifecycle, workers)
    private val recoveryWorker = Executors.newSingleThreadExecutor()
    private val transitionWrites = Executors.newSingleThreadExecutor()
    private val clients = mutableSetOf<Messenger>()
    private data class AppClient(val owner: String, val death: IBinder.DeathRecipient)
    private val appClients = mutableMapOf<Messenger, AppClient>()
    private val foregroundAppClients = mutableSetOf<Messenger>()
    private val pending = ConcurrentHashMap<String, Messenger>()
    private val isolationProbeBusy = AtomicBoolean(false)
    private val isolatedApprovals = IsolatedExecutionApprovalInbox()
    private val isolatedApprovalExpiry = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var capabilityJournal: IsolatedCapabilityJournal? = null
    private val isolatedRunsDelegate = lazy { IsolatedRunNativeBridge(this,
        toolTransport = object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                requestIsolatedTool("native.toolCallback", params, timeoutMillis)

            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                requestIsolatedTool("native.toolCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis)
                    .optBoolean("closed", false)
        }, capabilityJournal = {
            capabilityJournal ?: throw IllegalStateException("Capability audit is unavailable; file grants are blocked")
        }) }
    private val isolatedRuns get() = isolatedRunsDelegate.value
    private val workflowRunsDelegate = lazy { IsolatedWorkflowRunNativeBridge(this,
        object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                requestIsolatedTool("native.workflowCallback", params, timeoutMillis)

            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                requestIsolatedTool("native.workflowCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis)
                    .optBoolean("closed", false)
        }) }
    private val workflowRuns get() = workflowRunsDelegate.value
    private val linuxCommandsDelegate = lazy { LinuxCommandManager(this) }
    private val linuxCommands get() = linuxCommandsDelegate.value
    private val linuxVmDelegate = lazy { LinuxVmManager(this) }
    private val linuxVm get() = linuxVmDelegate.value
    private val linuxNetworkApprovalsDelegate = lazy { LinuxVmNetworkApprovalCoordinator(
        File(applicationInfo.dataDir).canonicalFile.toPath(),
        File(filesDir, "linux-network-approvals").canonicalFile.toPath(), isolatedApprovals,
        currentRoute = { NetworkProxyPreferences(this).route() },
        observeRoute = { route, changed -> NetworkProxyPreferences(this).observeRoute(route, changed) },
        execute = { params, lease, route -> linuxVm.executeApprovedNetwork(params, lease, route) },
        cancelExecution = { id -> if (linuxVmDelegate.isInitialized()) { linuxVm.cancel(JSONObject().put("id", id)); } },
        offer = ::offerLinuxNetworkReview,
        dismiss = { requestId -> main.post { broadcast(JSONObject().put("method", "runtime.linuxNetworkReview.closed")
            .put("params", JSONObject().put("requestId", requestId))) } },
        sync = IsolatedScriptRunController::syncDirectory,
    ) }
    private val linuxNetworkApprovals get() = linuxNetworkApprovalsDelegate.value
    private val documentImagesDelegate = lazy { DocumentImageReads(this) }
    private val documentImages get() = documentImagesDelegate.value
    private data class ManualRun(
        val runId: String, val selection: ManualIsolatedScriptRequest.Selection,
        val ownerId: String, val version: Long,
        @Volatile var stage: String = "preparing",
        @Volatile var reviewId: String? = null,
        @Volatile var challenge: String? = null,
        @Volatile var token: String? = null,
        @Volatile var cancelRequested: Boolean = false,
        @Volatile var receipt: JSONObject? = null,
    )
    private val manualRuns = ConcurrentHashMap<String, ManualRun>()
    private val nativePending = mutableMapOf<String, (Result<JSONObject>) -> Unit>()
    @Volatile private var output: RuntimeTransport? = null
    @Volatile private var phase = "starting"
    private var failure: String? = null
    private lateinit var recovery: RecoveryRuntime
    private var mode = "active"
    private var modeToken = ""
    @Volatile private var nodeStarted = false
    @Volatile private var appliedProxy: JSONObject? = null
    @Volatile private var runtimeLease: RuntimeProcessLease? = null
    @Volatile private var bootStopped = false
    @Volatile private var mutationAllowed = false
    @Volatile private var bootStage = "service-created"
    @Volatile private var workflowRecovery = JSONObject().put("state", "checking")
    private var started = false
    private var recoveryBusy = false
    private lateinit var transitions: PackageOperationTransitions
    private lateinit var vault: CredentialVault
    private lateinit var webPreferences: WebPreferences
    private lateinit var approvals: ApprovalNotifications
    private lateinit var taskCompletion: TaskCompletionNotifications
    private lateinit var documentSearch: DocumentSearchManager
    private lateinit var background: BackgroundExecution
    private lateinit var scheduleWakeup: ScheduleWakeup
    private var summaryRequest: String? = null
    // This process runs Node once. Never release its cache lease merely because Android destroys the Service.
    private var attachmentCache: AttachmentCacheLease? = null
    @Synchronized private fun attachmentCacheDirectory(): String {
        check(!bootStopped) { "附件运行时已停止" }
        val current = attachmentCache ?: AttachmentCacheLease.create(AttachmentFileSaves.directory(this)).also {
            attachmentCache = it
        }
        return current.directory().canonicalPath
    }
    @Synchronized private fun finishAttachmentCache() {
        bootStopped = true
        try { attachmentCache?.close() }
        catch (_: Exception) { /* A retained OS lock is safer than collecting a still-owned directory. */ }
        attachmentCache = null
    }
    private val summaryTimeout = Runnable {
        val id = summaryRequest
        summaryRequest = null
        if (id != null) nativePending.remove(id)
        background.pollUnavailable()
    }
    private val summaryPoll = object : Runnable {
        override fun run() {
            if (phase != "ready") return
            requestTaskSummary()
            main.postDelayed(this, 30_000)
        }
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLost(network: Network) = networkChanged()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = networkChanged()
    }
    private fun networkChanged() {
        networkChanges.changed {
            try {
                if (output != null) write(JSONObject().put("jsonrpc", "2.0")
                    .put("method", "native.networkChanged").put("params", JSONObject()))
            } catch (exception: Exception) {
                if (phase == "ready") fail(exception.message ?: "Network notification failed")
            }
        }
    }
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        val client = message.replyTo
        if (message.what == 1) {
            if (!appClients.containsKey(client)) {
                val death = IBinder.DeathRecipient { main.post { removeClient(client) } }
                try {
                    client.binder.linkToDeath(death, 0)
                    appClients[client] = AppClient(UUID.randomUUID().toString(), death)
                } catch (_: RemoteException) { return@Handler true }
            }
            clients.add(client)
            send(client, status())
        } else if (message.what == 2) {
            val raw = WirePayload.decode(message.data)
            val frame = JSONObject(raw)
            val id = frame.getString("id")
            if (frame.getString("method") in setOf("api.subscribe", "api.ack", "api.unsubscribe",
                    "documents.search", "documents.search.cancel", "session.attachmentFile.prepare",
                    "session.attachmentFile.info", "session.attachmentFile.read",
                    "session.attachmentFile.cancel", "session.attachmentFile.release",
                    "document.call", "document.bytes", "document.cancel", "document.release", "document.mediaPolicy",
                    "references.list", "references.cancel",
                    "workspaceChanges.summary", "workspaceChanges.diff", "workspaceChanges.cancel")) {
                val owner = appClients[client]?.owner
                if (owner == null) {
                    send(client, error(id, "App stream owner is disconnected"))
                    return@Handler true
                }
                val params = frame.optJSONObject("params") ?: JSONObject()
                params.put("owner", owner)
                frame.put("params", params)
            }
            if (frame.getString("method") == "session.send") {
                val params = frame.optJSONObject("params") ?: JSONObject()
                params.put("clientTimeZone", java.time.ZoneId.systemDefault().id)
                frame.put("params", params)
            }
            if (frame.getString("method") == "recovery.call") {
                val request = frame.optJSONObject("params") ?: JSONObject()
                val method = request.optString("method")
                val params = request.optJSONObject("params") ?: JSONObject()
                val mutation = method in setOf("write", "restore", "runtimeRepair")
                if (!appClients.containsKey(client)) {
                    send(client, recoveryError(id, "recovery/disconnected", "恢复连接已断开，请重新打开页面"))
                } else if (mutation && (recoveryBusy || transitions.busy())) {
                    send(client, recoveryError(id, "recovery/busy", "恢复操作仍在执行，不能重复提交或切换服务"))
                } else {
                    if (mutation) recoveryBusy = true
                    recoveryWorker.execute {
                        try {
                            val result = recovery.call(method, params, mode, nodeStarted, mutationAllowed, bootStage, failure)
                            main.post { send(client, JSONObject().put("id", id).put("result", result)) }
                        } catch (error: RecoveryFiles.Failure) {
                            main.post { send(client, recoveryError(id, error.code, error.message ?: "恢复操作未完成", error.notStartedRequestId)) }
                        } catch (_: Exception) {
                            main.post { send(client, recoveryError(id, "recovery/unconfirmed", "恢复操作结果未确认，请查看操作记录；原始内容不会显示在错误信息中")) }
                        } finally {
                            if (mutation) main.post { recoveryBusy = false }
                        }
                    }
                }
            } else if (frame.getString("method") == "runtime.status") {
                send(client, JSONObject().put("id", id).put("result", status().getJSONObject("params")))
            } else if (frame.getString("method") == "runtime.capabilityAudit") {
                if (!appClients.containsKey(client)) send(client, error(id, "App capability audit viewer is disconnected"))
                else workers.execute {
                    try {
                        val params = frame.optJSONObject("params") ?: JSONObject()
                        val result = capabilityAuditPage(params)
                        main.post { send(client, JSONObject().put("id", id).put("result", result)) }
                    } catch (_: Exception) {
                        main.post { send(client, error(id, "隔离执行审计已变化或暂时无法读取，请刷新后核对")) }
                    }
                }
            } else if (frame.getString("method") == "runtime.linuxNetworkReview.unavailable") {
                if (!appClients.containsKey(client)) send(client, error(id, "App approval viewer is disconnected"))
                else workers.execute {
                    try {
                        val params = frame.getJSONObject("params")
                        require(params.length() == 1 && params.opt("requestId") is String)
                        if (linuxNetworkApprovalsDelegate.isInitialized()) linuxNetworkApprovals.unavailable(params.getString("requestId"))
                        main.post { send(client, JSONObject().put("id", id).put("result", true)) }
                    } catch (_: Exception) { main.post { send(client, error(id, "联网授权已失效")) } }
                }
            } else if (frame.getString("method") == "runtime.isolatedApprovals.list") {
                if (!appClients.containsKey(client)) send(client, error(id, "App approval viewer is disconnected"))
                else workers.execute {
                    try {
                        val rows = JSONArray().apply {
                            isolatedApprovals.list().forEach { put(isolatedApprovalView(it, false)) }
                        }
                        main.post { send(client, JSONObject().put("id", id).put("result", rows)) }
                    } catch (_: Exception) {
                        main.post { send(client, error(id, "无法确认隔离脚本授权状态")) }
                    }
                }
            } else if (frame.getString("method") == "runtime.isolatedApprovals.detail") {
                if (!appClients.containsKey(client)) send(client, error(id, "App approval viewer is disconnected"))
                else try {
                    val params = frame.getJSONObject("params")
                    require(params.length() == 1)
                    val requestId = params.getString("requestId")
                    workers.execute {
                        try {
                            val review = isolatedApprovals.list().firstOrNull { it.id() == requestId }
                                ?: throw IllegalArgumentException("Approval request expired")
                            main.post { send(client, JSONObject().put("id", id)
                                .put("result", isolatedApprovalView(review, true))) }
                        } catch (_: Exception) {
                            main.post { send(client, error(id, "授权请求已变化，请刷新页面")) }
                        }
                    }
                } catch (_: Exception) { send(client, error(id, "无效的授权请求")) }
            } else if (frame.getString("method") == "runtime.isolatedApprovals.deny") {
                if (!appClients.containsKey(client)) send(client, error(id, "App approval viewer is disconnected"))
                else try {
                    val params = frame.getJSONObject("params")
                    require(params.length() == 2)
                    val requestId = params.getString("requestId")
                    val challenge = params.getString("challenge")
                    workers.execute {
                        try {
                            isolatedApprovals.deny(requestId, challenge)
                            main.post { send(client, JSONObject().put("id", id).put("result", true)) }
                        } catch (_: Exception) {
                            main.post { send(client, error(id, "拒绝状态未确认，请重新读取授权请求")) }
                        }
                    }
                } catch (_: Exception) { send(client, error(id, "无效的授权请求")) }
            } else if (frame.getString("method") == "runtime.isolation.probe") {
                if (!appClients.containsKey(client)) {
                    send(client, error(id, "App isolation probe owner is disconnected"))
                } else if (!isolationProbeBusy.compareAndSet(false, true)) {
                    send(client, error(id, "Isolated worker probe is already running"))
                } else {
                    try { workers.execute {
                        try {
                            val evidence = isolationProbe()
                            main.post { send(client, JSONObject().put("id", id).put("result", evidence)) }
                        } catch (exception: Exception) {
                            main.post { send(client, error(id, exception.message ?: "Isolated worker probe failed")) }
                        } finally { isolationProbeBusy.set(false) }
                    } } catch (_: RejectedExecutionException) {
                        isolationProbeBusy.set(false)
                        send(client, error(id, "Isolated worker probe host is stopping"))
                    }
                }
            } else if (frame.getString("method").startsWith("runtime.transition.")) {
                send(client, error(id, "服务切换必须通过原生维护入口执行"))
            } else if (frame.getString("method") == "runtime.proxy.status") {
                if (!appClients.containsKey(client)) send(client, error(id, "代理状态连接已断开"))
                else send(client, JSONObject().put("id", id).put("result", JSONObject()
                    .put("phase", phase).put("generation", recovery.generation)
                    .put("configuration", appliedProxy ?: JSONObject.NULL)))
            } else if (frame.getString("method") in setOf("runtime.scheduleWake.status", "runtime.scheduleWake.configure")) {
                if (!appClients.containsKey(client)) send(client, error(id, "定时唤醒连接已断开"))
                else workers.execute {
                    try {
                        val value = if (frame.getString("method") == "runtime.scheduleWake.status") scheduleWakeup.status()
                        else {
                            val params = frame.getJSONObject("params")
                            require(params.length() == 1 && params.get("enabled") is Boolean)
                            scheduleWakeup.configure(params.getBoolean("enabled"))
                        }
                        main.post { send(client, JSONObject().put("id", id).put("result", value)) }
                    } catch (_: Exception) {
                        main.post { send(client, error(id, "定时唤醒状态未确认，请核对闹钟权限并刷新")) }
                    }
                }
            } else if (frame.getString("method") == "runtime.background.configure") {
                try {
                    val value = frame.getJSONObject("params").get("keepAwakeWhileWorking")
                    require(value is Boolean) { "后台运行选项必须是布尔值" }
                    send(client, JSONObject().put("id", id).put("result", background.configure(value)))
                    broadcast(status())
                } catch (exception: Exception) {
                    send(client, error(id, exception.message ?: "无法保存后台运行设置"))
                }
            } else if (frame.getString("method") == "runtime.background.overlay.configure") {
                try {
                    val params = frame.getJSONObject("params")
                    require(params.length() == 1 && params.get("enabled") is Boolean) {
                        "悬浮窗选项必须是布尔值"
                    }
                    send(client, JSONObject().put("id", id).put("result",
                        background.configureOverlay(params.getBoolean("enabled"))))
                    broadcast(status())
                } catch (_: Exception) {
                    send(client, error(id, "悬浮窗设置未确认，请刷新后核对"))
                }
            } else if (frame.getString("method") == "notifications.draft") {
                val params = frame.getJSONObject("params")
                send(client, JSONObject().put("id", id).put("result", JSONObject().put("text",
                    approvals.draft(params.getString("id"), params.getLong("version")) ?: JSONObject.NULL)))
            } else if (phase != "ready") {
                send(client, error(id, failure ?: "运行时正在启动，请稍后重试"))
            } else {
                pending[id] = client
                workers.execute {
                    try { write(frame) }
                    catch (exception: Exception) {
                        pending.remove(id)
                        main.post { send(client, error(id, exception.message ?: "Runtime disconnected")) }
                    }
                }
            }
        } else if (message.what == 3) removeClient(client)
        else if (message.what == 12) {
            // Only MainActivity's native confirmation callback sends this Binder message.
            // A normal Flutter/Node JSON-RPC call cannot reach the grant operation.
            val frame = try { JSONObject(WirePayload.decode(message.data)) } catch (_: Exception) { null }
            val id = frame?.optString("id") ?: ""
            if (id.isEmpty()) return@Handler true
            if (!appClients.containsKey(client)) send(client, error(id, "App approval viewer is disconnected"))
            else try {
                require(frame != null && frame.length() == 4)
                val requestId = frame.getString("requestId")
                val challenge = frame.getString("challenge")
                val snapshotSha256 = frame.getString("snapshotSha256")
                workers.execute {
                    try {
                        isolatedApprovals.approve(requestId, challenge, snapshotSha256)
                        main.post { send(client, JSONObject().put("id", id).put("result", true)) }
                    } catch (_: Exception) {
                        main.post { send(client, error(id, "授权状态未确认，请重新读取授权请求")) }
                    }
                }
            } catch (_: Exception) { send(client, error(id, "无效的授权请求")) }
        }
        else if (message.what in 13..15) {
            // Distinct native Binder entry points. The generic JSON-RPC route cannot prepare
            // a grant, execute a manual run, or claim a terminal receipt.
            val frame = try { JSONObject(WirePayload.decode(message.data)) } catch (_: Exception) { null }
            val id = frame?.optString("id") ?: ""
            if (id.isEmpty()) return@Handler true
            if (!appClients.containsKey(client)) send(client, error(id, "App 手动运行连接已断开"))
            else try { workers.execute {
                try {
                    val value = when (message.what) {
                        13 -> prepareManualRun(checkNotNull(frame).getJSONObject("params"))
                        14 -> manualRunStatus(checkNotNull(frame).getString("runId"))
                        else -> JSONObject().put("cancelled", cancelManualRun(checkNotNull(frame).getString("runId")))
                    }
                    main.post { send(client, JSONObject().put("id", id).put("result", value)) }
                } catch (_: Exception) {
                    main.post { send(client, error(id, "隔离运行状态未确认，请读取运行回执；不要重新提交脚本")) }
                }
            } } catch (_: RejectedExecutionException) { send(client, error(id, "隔离运行服务正在停止")) }
        }
        else if (message.what == TaskCompletionNotifications.MESSAGE_VIEWING) {
            appClients[client]?.let { record ->
                taskCompletion.viewing(record.owner, message.data.getString("sessionId"), message.data.getBoolean("foreground"))
                if (message.data.getBoolean("foreground")) {
                    foregroundAppClients.add(client)
                    if (linuxNetworkApprovalsDelegate.isInitialized()) linuxNetworkApprovals.pending().firstOrNull()?.let {
                        send(client, linuxNetworkReviewOffer(it))
                    }
                } else foregroundAppClients.remove(client)
            }
        }
        else if (message.what == ApprovalNotifications.MESSAGE_RESPOND) {
            try {
                approvals.handle(JSONObject(WirePayload.decode(message.data))) { ack -> send(client, ack) }
            } catch (exception: Exception) {
                send(client, JSONObject().put("accepted", false).put("requestStillPending", false))
            }
        } else if (message.what == 5) approvals.refresh()
        else if (message.what == 6 && appClients.containsKey(client)) {
            val token = message.data.getString("token") ?: ""
            if (recoveryBusy) transitionReply(client, token, PackageOperationTransitions.denied(
                "recovery/busy", "恢复操作仍在执行，未切换服务；请等待操作结果"))
            else transitions.reserve(token, client, transitionAvailability()) { reply -> transitionReply(client, token, reply) }
        }
        else if (message.what == 9 && appClients.containsKey(client)) {
            transitions.release(message.data.getString("token") ?: "", client)
        }
        else if (message.what == 8 && appClients.containsKey(client)) {
            val token = message.data.getString("token") ?: ""
            if (recoveryBusy) {
                transitions.release(token, client)
                transitionReply(client, token, PackageOperationTransitions.denied(
                    "recovery/busy", "恢复操作仍在执行，旧服务未被主动停止"))
            } else transitions.commit(token, client) { reply ->
                if (reply.accepted()) stopForTransition(client, token) else transitionReply(client, token, reply)
            }
        }
        true
    })

    override fun onCreate() {
        super.onCreate()
        // Inspect the App-private audit before starting Node. A failed read
        // must keep every later file-granted admission closed for this process.
        try { capabilityJournal = IsolatedCapabilityWorkspace.journal(this) }
        catch (_: Exception) { /* A failed audit scan blocks later file-granted admission. */ }
        recovery = RecoveryRuntime(this)
        scheduleWakeup = ScheduleWakeup.get(this)
        scheduleWakeup.bind(recovery.generation)
        vault = CredentialVault(this)
        webPreferences = WebPreferences(this)
        documentSearch = DocumentSearchManager(this)
        background = BackgroundExecution(this)
        taskCompletion = TaskCompletionNotifications(this)
        transitions = PackageOperationTransitions(PackageOperationTransitions.Rpc { method, token, epoch, completion ->
            requestTransition(method, token, epoch) { completion.accept(it) }
        }, object : PackageOperationTransitions.Scheduler {
            override fun schedule(callback: Runnable, milliseconds: Long) { main.postDelayed(callback, milliseconds) }
            override fun cancel(callback: Runnable) { main.removeCallbacks(callback) }
        })
        approvals = ApprovalNotifications(this) { params, completion ->
            if (phase != "ready") {
                completion(Result.failure(IllegalStateException("Agent service is unavailable")))
            } else {
                val id = "native-interaction-${UUID.randomUUID()}"
                nativePending[id] = completion
                workers.execute {
                    try {
                        write(JSONObject().put("jsonrpc", "2.0").put("id", id)
                            .put("method", "interactions.reply").put("params", params))
                    } catch (exception: Exception) {
                        main.post { nativePending.remove(id)?.invoke(Result.failure(exception)) }
                    }
                }
            }
        }
        getSystemService(ConnectivityManager::class.java).registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)
        background.start()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ScheduleWakeup.ACTION_WAKE &&
            !scheduleWakeup.acceptWake(intent.getStringExtra(ScheduleWakeup.EXTRA_TOKEN) ?: "")) {
            if (!started) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (!started) {
            started = true
            try {
                val selected = recovery.mode()
                mode = selected[0]
                modeToken = selected[1]
            } catch (_: Exception) {
                mode = "maintenance"
                failure = "服务模式记录无法读取；已停留在维护模式，请重新选择启动方式"
            }
            if (mode == "maintenance") {
                workflowRecovery = JSONObject().put("state", "not-checked")
                phase = "maintenance-checking"
                bootStage = "checking-app-processes"
                background.phase(phase)
                broadcast(status())
                recoveryWorker.execute {
                    try {
                        RecoveryProcessHost(this).quiesce()
                        main.post {
                            mutationAllowed = true
                            phase = "maintenance"
                            bootStage = "maintenance"
                            background.phase(phase)
                            broadcast(status())
                        }
                    } catch (_: Exception) {
                        main.post {
                            mutationAllowed = false
                            phase = "maintenance-blocked"
                            bootStage = "process-check-blocked"
                            failure = "无法确认本应用遗留进程已停止，配置仍为只读；请停止应用后重新打开维护页"
                            background.phase(phase)
                            broadcast(status())
                        }
                    }
                }
            } else {
                broadcast(status())
                workers.execute { boot() }
            }
        }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onTimeout(startId: Int, fgsType: Int) {
        // The current specialUse declaration has no fixed quota. A future
        // service type timeout must stop this dedicated Node process before
        // Android's grace period expires. Detached children need separate
        // process-group supervision after an abrupt process death.
        lifecycle.stopTimedOutProcess(
            { stopForeground(STOP_FOREGROUND_REMOVE) },
            { stopSelf() },
            {
                phase = "failed"
                failure = "系统已结束后台运行时段，正在停止任务；重新打开 App 后核对中断记录"
                if (!persistInterruption(RuntimeInterruptionRecord.SERVICE_TIMEOUT)) {
                    failure += "；本地中断摘要未能保存"
                }
                background.close()
                if (::taskCompletion.isInitialized) taskCompletion.close()
                broadcast(status())
            },
            { Process.killProcess(Process.myPid()) },
        )
    }

    private fun boot() {
        try {
            bootStage = "preparing-assets"
            val runtime = RuntimeAssets.prepare(this)
            bootStage = "preparing-storage"
            attachmentCacheDirectory()
            val home = File(noBackupFilesDir, "dsh").apply { mkdirs() }
            File(home, "workspace").mkdirs()
            // Recovery may mark an old run interrupted. Prove that no prior
            // Agent process still owns Node before touching its receipts.
            synchronized(nodeStartLock) {
                if (!lifecycle.acceptsFrames()) return
                runtimeLease = RuntimeProcessLease.start(noBackupFilesDir,
                    System.currentTimeMillis())
            }
            bootStage = "recovering-workflows"
            workflowRecovery = try {
                val recovered = workflowRuns.startupRecovery()
                JSONObject().put("state", when {
                    recovered.unretiredChildren > 0 -> "blocked"
                    recovered.newlyInterruptedRuns > 0 -> "review"
                    else -> "ready"
                }).put("newlyInterruptedRuns", recovered.newlyInterruptedRuns)
                    .put("unretiredChildren", recovered.unretiredChildren)
            } catch (_: Exception) {
                // A damaged receipt closes only workflow admission. Keep the
                // rest of the local runtime available for inspection.
                JSONObject().put("state", "unreadable")
            }
            val pair = NativeRuntime.socketPair()
            val socket = ParcelFileDescriptor.adoptFd(pair[0])
            val readSocket = ParcelFileDescriptor.dup(socket.fileDescriptor)
            output = RuntimeTransport(lifecycle, ParcelFileDescriptor.AutoCloseOutputStream(socket).bufferedWriter())
            workers.execute {
                try {
                    ParcelFileDescriptor.AutoCloseInputStream(readSocket).bufferedReader().useLines { lines ->
                        lines.forEach { line -> handle(JSONObject(line)) }
                    }
                    fail("运行时连接已关闭，任务可能已中断")
                } catch (exception: Exception) { fail(exception.message ?: "Runtime connection failed") }
            }
            bootStage = "starting-node"
            appliedProxy = NetworkProxyPreferences(this).installEnvironment()
            synchronized(nodeStartLock) {
                if (!lifecycle.acceptsFrames()) return
                nodeStarted = true
            }
            val code = NativeRuntime.start(runtime.path, home.path, cacheDir.path, applicationInfo.nativeLibraryDir, pair[1])
            fail("运行时已退出：$code")
        } catch (exception: Throwable) { fail(exception.message ?: exception.javaClass.simpleName) }
        finally {
            if (!nodeStarted) {
                // Reconciliation without Node admission must not look like a
                // crashed runtime generation on the next service boot.
                try { runtimeLease?.closePlanned() } catch (_: Exception) {}
            }
            finishAttachmentCache()
        }
    }
    private fun handle(frame: JSONObject) {
        if (!lifecycle.acceptsFrames()) return
        if (frame.has("method") && frame.has("id")) {
            workers.execute {
                if (!lifecycle.acceptsFrames()) return@execute
                val id = frame.getString("id")
                try {
                    val method = frame.getString("method")
                    val params = frame.optJSONObject("params") ?: JSONObject()
                    val value: Any? = when (method) {
                        "native.scheduleWakeup.begin" -> {
                            require(params.length() == 0)
                            scheduleWakeup.begin()
                        }
                        "native.scheduleWakeup.update" -> scheduleWakeup.update(params).also {
                            main.post { requestTaskSummary() }
                        }
                        "native.credentials.get" -> vault.get(params.getString("name"))
                        "native.credentials.set" -> { vault.set(params.getString("name"), params.getString("value")); true }
                        "native.credentials.remove" -> { vault.set(params.getString("name"), null); true }
                        "native.credentials.names" -> org.json.JSONArray(vault.names())
                        "native.web.preferences" -> webPreferences.get()
                        "native.web.save" -> webPreferences.save(params)
                        "native.network.addresses" -> webPreferences.addresses()
                        "native.documents.roots" -> DocumentAccess(this).roots()
                        "native.documents.list" -> DocumentAccess(this).list(params.getString("root"), params.optString("path"))
                        "native.documents.read" -> DocumentAccess(this).read(params.getString("root"), params.getString("path"), DocumentReadAccess.offset(params.opt("offset")), params.optString("version").takeIf { it.isNotEmpty() })
                        "native.documents.image.read" -> documentImages.read(params)
                        "native.documents.image.cancel" -> documentImages.cancel(params)
                        "native.documents.revoke" -> {
                            val root = params.getString("root")
                            val result = DocumentAccess(this).revoke(root)
                            if (documentImagesDelegate.isInitialized()) documentImages.revokeRoot(root)
                            result.put("searchesStopped", documentSearch.revokeRoot(root))
                        }
                        "native.documents.search.prepare" -> documentSearch.prepare(params.getString("id"))
                        "native.documents.search.run" -> documentSearch.run(params)
                        "native.documents.search.cancel" -> documentSearch.cancel(params.getString("id"))
                        "native.exports.directory" -> DocumentExports.directory(this).canonicalPath
                        "native.attachments.directory" -> AttachmentTransfers.directory(this).canonicalPath
                        "native.attachmentFiles.directory" -> attachmentCacheDirectory()
                        "native.storage.root" -> File(applicationInfo.dataDir).canonicalPath
                        "native.linuxCommand.execute" -> linuxCommands.execute(params)
                        "native.linuxCommand.cancel" -> linuxCommands.cancel(params)
                        "native.linuxVm.execute" -> linuxVm.execute(params)
                        "native.linuxVm.inspect" -> linuxVm.inspect(params)
                        "native.linuxVm.importFile" -> linuxVm.importFile(params)
                        "native.linuxVm.exportFile" -> linuxVm.exportFile(params)
                        "native.linuxVm.cancel" -> linuxVm.cancel(params)
                        "native.linuxVm.network.review" -> linuxNetworkApprovals.review(params)
                        "native.linuxVm.network.cancelReview" -> linuxNetworkApprovals.cancelReview(params)
                        "native.linuxVm.executeNetwork" -> linuxNetworkApprovals.executeNetwork(params)
                        "native.isolated.admit" -> isolatedRuns.admit(params)
                        "native.isolated.bindTools" -> isolatedRuns.bindTools(params)
                        "native.isolated.execute" -> isolatedRuns.execute(params)
                        "native.isolated.cancel" -> isolatedRuns.cancel(params)
                        "native.isolated.settle" -> isolatedRuns.settle(params)
                        "native.isolated.release" -> isolatedRuns.release(params)
                        "native.workflow.admit" -> workflowRuns.admit(params)
                        "native.workflow.bindCallbacks" -> workflowRuns.bindCallbacks(params)
                        "native.workflow.execute" -> workflowRuns.execute(params)
                        "native.workflow.cancel" -> workflowRuns.cancel(params)
                        "native.workflow.settle" -> workflowRuns.settle(params)
                        "native.workflow.inspect" -> workflowRuns.inspect(params)
                        "native.workflow.release" -> workflowRuns.release(params)
                        else -> throw IllegalArgumentException("Unsupported native method: $method")
                    }
                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", value ?: JSONObject.NULL))
                } catch (exception: Exception) { write(error(id, exception.message ?: "Native operation failed")) }
            }
        } else main.post {
            if (!lifecycle.acceptsFrames()) return@post
            if (frame.optString("method") == "api.stream") {
                val params = frame.getJSONObject("params")
                val owner = params.getString("owner")
                params.remove("owner")
                appClients.entries.firstOrNull { it.value.owner == owner }?.let { send(it.key, frame) }
                return@post
            }
            if (frame.optString("method") == "runtime.status" && frame.getJSONObject("params").optString("phase") == "failed") {
                fail(frame.getJSONObject("params").getString("error"))
                return@post
            }
            if (frame.optString("method") == "runtime.ready") {
                bootStage = "ready"
                phase = "ready"
                background.phase(phase)
                main.removeCallbacks(summaryPoll)
                summaryPoll.run()
                broadcast(status())
            }
            if (frame.optString("method") == "runtime.tasks.changed") {
                try {
                    background.observe(frame.getJSONObject("params"))
                    scheduleWakeup.observeBackground(background.status())
                }
                catch (_: Exception) { background.unavailable() }
            }
            if (frame.optString("method") == "task.completed") {
                try { taskCompletion.completed(frame.getJSONObject("params")) }
                catch (exception: Exception) {
                    broadcast(JSONObject().put("method", "notifications.error").put("params",
                        JSONObject().put("message", "任务完成提醒不可用，请在会话中查看结果")))
                }
            }
            if (frame.optString("method") == "interactions.changed") {
                try { approvals.sync(frame.getJSONObject("params")) }
                catch (exception: Exception) {
                    broadcast(JSONObject().put("method", "notifications.error").put("params",
                        JSONObject().put("message", "通知状态更新失败，请在 App 内处理待办")))
                }
            }
            if (frame.has("id")) {
                val id = frame.getString("id")
                val callback = nativePending.remove(id)
                if (callback != null) {
                    if (frame.has("error")) callback(Result.failure(IllegalStateException(
                        frame.getJSONObject("error").optString("message", "Interaction result is unknown"))))
                    else callback(Result.success(frame.getJSONObject("result")))
                } else pending.remove(id)?.let { send(it, frame) }
            } else broadcast(frame)
        }
    }
    private fun requestTaskSummary() {
        if (phase != "ready" || summaryRequest != null || workers.isShutdown) return
        val id = "native-background-${UUID.randomUUID()}"
        summaryRequest = id
        nativePending[id] = { result ->
            if (summaryRequest == id) {
                summaryRequest = null
                main.removeCallbacks(summaryTimeout)
                if (phase == "ready") {
                    result.fold(
                        onSuccess = { snapshot ->
                            try {
                                background.observe(snapshot)
                                scheduleWakeup.observeBackground(background.status())
                            }
                            catch (_: Exception) { background.pollUnavailable() }
                        },
                        onFailure = { background.pollUnavailable() },
                    )
                }
            }
        }
        main.postDelayed(summaryTimeout, 10_000)
        workers.execute {
            try {
                write(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", "tasks.summary").put("params", JSONObject()))
            } catch (exception: Exception) {
                main.post { nativePending.remove(id)?.invoke(Result.failure(exception)) }
            }
        }
    }
    private fun transitionAvailability(): PackageOperationTransitions.Availability = when {
        !lifecycle.acceptsFrames() -> PackageOperationTransitions.Availability.UNKNOWN
        phase == "ready" && !bootStopped -> PackageOperationTransitions.Availability.RUNNING
        bootStopped || mode == "maintenance" && phase == "maintenance" && mutationAllowed ->
            PackageOperationTransitions.Availability.STOPPED
        else -> PackageOperationTransitions.Availability.UNKNOWN
    }
    private fun transitionReply(client: Messenger, token: String, reply: PackageOperationTransitions.Reply) {
        send(client, JSONObject().put("method", "runtime.transition").put("params",
            JSONObject().put("token", token).put("accepted", reply.accepted())
                .put("code", reply.code() ?: JSONObject.NULL).put("message", reply.message() ?: JSONObject.NULL)))
    }
    private fun requestTransition(method: String, token: String, epoch: String?,
                                  completion: (PackageOperationTransitions.Reply) -> Unit) {
        val id = "native-transition-${UUID.randomUUID()}"
        val timeout = Runnable {
            nativePending.remove(id)?.invoke(Result.failure(IllegalStateException("服务切换确认超时")))
        }
        nativePending[id] = { result ->
            main.removeCallbacks(timeout)
            val reply = try {
                val value = result.getOrThrow()
                check(value.getString("token") == token)
                if (method == "release") {
                    PackageOperationTransitions.Reply(value.getBoolean("released"), value.getString("epoch"), null, null, null)
                } else {
                    val accepted = value.get("accepted")
                    check(accepted is Boolean)
                    PackageOperationTransitions.Reply(accepted, value.getString("epoch"),
                        if (accepted) value.getString("state") else null,
                        if (accepted) null else value.getString("code"),
                        if (accepted) null else value.getString("message"))
                }
            } catch (_: Exception) {
                PackageOperationTransitions.denied("runtime/transition-unconfirmed",
                    "无法确认插件管理操作状态，旧服务未被主动停止；请重新读取状态")
            }
            completion(reply)
        }
        main.postDelayed(timeout, 10_000)
        val params = JSONObject().put("token", token)
        if (epoch != null) params.put("epoch", epoch)
        try {
            // Preserve reserve/release order even when their callbacks time out or the Activity disconnects.
            transitionWrites.execute {
                try {
                    write(JSONObject().put("jsonrpc", "2.0").put("id", id)
                        .put("method", "runtime.transition.$method").put("params", params))
                } catch (exception: Exception) {
                    main.post { nativePending.remove(id)?.invoke(Result.failure(exception)) }
                }
            }
        } catch (exception: java.util.concurrent.RejectedExecutionException) {
            nativePending.remove(id)?.invoke(Result.failure(exception))
        }
    }
    private fun stopForTransition(client: Messenger, token: String) {
        check(Application.getProcessName().endsWith(":agent")) { "Runtime restart requires the dedicated Agent process" }
        if (!lifecycle.closeForProcessExit()) {
            transitionReply(client, token, PackageOperationTransitions.denied(
                "runtime/transition-unconfirmed", "运行时连接已中断，服务切换结果未确认；重新打开后检查中断记录"))
            return
        }
        try { runtimeLease?.preparePlannedProcessExit() }
        catch (_: Exception) {
            // Keep the marker: cold recovery must report an uncertain stop instead of silently trusting it.
        }
        phase = "restarting"
        background.phase(phase)
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        broadcast(status())
        approvals.close()
        taskCompletion.close()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        // libnode starts only once per process. The committed Node gate remains sealed until this process exits.
        main.post {
            try { Process.killProcess(Process.myPid()) }
            catch (_: Exception) {
                reportFailure("旧运行时停止未确认，插件管理仍暂停；请在系统设置中停止应用后重新打开")
            }
        }
    }
    private fun write(frame: JSONObject) {
        val stream = output ?: throw IllegalStateException("Runtime is not connected")
        stream.write(frame.toString())
    }
    private fun isolationProbe(): JSONObject {
        val payload = "PTC isolation probe".toByteArray(Charsets.UTF_8)
        val file = File.createTempFile("ptc-isolation-input-", ".bin", cacheDir)
        try {
            file.writeBytes(payload)
            val evidence = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use {
                IsolatedWorkerProbe.inspect(this, it)
            }
            val hash = MessageDigest.getInstance("SHA-256").digest(payload).joinToString("") {
                (it.toInt() and 0xff).toString(16).padStart(2, '0')
            }
            check(evidence.bytes == payload.size && evidence.sha256 == hash) {
                "Isolated worker changed the granted descriptor content"
            }
            val granted = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use {
                IsolatedWorkerBridge.readText(this, it)
            }
            check(granted.workerUid != Process.myUid() && granted.content == payload.toString(Charsets.UTF_8)) {
                "Isolated worker did not return the granted text"
            }
            val guest = IsolatedGuestBackend.inspect(this, java.util.function.BooleanSupplier { false })
            check(guest.kind == GuestTerminal.Kind.COMPLETED &&
                guest.workerUid != null && guest.workerUid != Process.myUid() &&
                guest.json == GuestEchoFrame.completionForText("pocket-harness-isolated-guest")) {
                "Isolated guest diagnostic did not complete: ${guest.kind}"
            }
            val workspace = File(filesDir, "ptc-isolation-workspace-${java.util.UUID.randomUUID()}")
            check(workspace.mkdir()) { "Could not create isolation workspace" }
            val nested = File(workspace, "nested")
            check(nested.mkdir()) { "Could not create nested isolation workspace" }
            val source = File(nested, "probe.txt")
            try {
                source.writeBytes(payload)
                val search = IsolatedWorkerBridge.searchWorkspaceText(
                    this, workspace, "nested/probe.txt", "isolation", 4,
                    java.util.function.BooleanSupplier { false },
                )
                check(search.workerUid != Process.myUid() && search.revision == hash &&
                    search.hits.size == 1 && search.hits[0].line == 1 && search.hits[0].column == 5 &&
                    !search.truncated
                ) { "Isolated worker did not search the selected nested workspace file" }
                val edit = IsolatedWorkerBridge.replaceWorkspaceText(
                    this, workspace, "nested/probe.txt", hash, "isolation", "worker", 1,
                    java.util.function.BooleanSupplier { false },
                )
                check(edit.previousSha256() == hash && source.readText() == "PTC worker probe") {
                    "Isolated worker edit was not committed to the selected workspace file"
                }
            } finally {
                check(source.delete() || !source.exists()) { "Could not remove isolation workspace file" }
                check(nested.delete() || !nested.exists()) { "Could not remove nested isolation workspace" }
                check(workspace.delete() || !workspace.exists()) { "Could not remove isolation workspace" }
            }
            return JSONObject().put("workerUid", evidence.workerUid)
                .put("hostUid", Process.myUid()).put("bytes", evidence.bytes)
                .put("sha256", evidence.sha256).put("privateReadDenied", true)
                .put("grantReadVerified", true).put("workspaceSearchVerified", true)
                .put("workspaceEditVerified", true).put("guestEchoVerified", true)
        } finally {
            check(file.delete() || !file.exists()) { "Could not remove isolation probe input" }
        }
    }
    /** App-only, bounded view of retained facts. It never settles or erases a call. */
    private fun capabilityAuditPage(params: JSONObject): JSONObject {
        require(params.keys().asSequence().all { it in setOf("offset", "runId", "expectedBytes") })
        val offset = if (params.has("offset")) {
            val value = params.get("offset")
            require(value is Number && value.toDouble() == value.toLong().toDouble()
                && value.toLong() in 0L..4096L)
            value.toInt()
        } else 0
        val runId = if (params.has("runId")) params.getString("runId").also {
            IsolatedScriptWire.requireUuid(it)
        } else null
        val journal = capabilityJournal
        val report = try { journal?.inspect() } catch (_: Exception) { null }
        if (report == null) return JSONObject().put("state", "unavailable")
            .put("startupBlocked", true).put("admissionBlocked", true)
            .put("runs", JSONArray()).put("nextOffset", JSONObject.NULL)
        checkNotNull(journal)
        if (params.has("expectedBytes")) {
            val expected = params.get("expectedBytes")
            require(expected is Number && expected.toLong() == report.bytes()
                && expected.toDouble() == expected.toLong().toDouble())
        }
        val blocked = try { journal.requireCleanAdmission(); false } catch (_: Exception) { true }
        val result = JSONObject().put("state", when {
            journal.startupReport().requiresInspection() || report.requiresInspection() -> "review"
            blocked -> "blocked"
            else -> "ready"
        }).put("startupBlocked", !journal.startupReport().canAppend())
            .put("admissionBlocked", blocked)
            .put("bytes", report.bytes()).put("damaged", report.damaged())
            .put("capacityReached", report.capacityReached())
            .put("truncated", report.truncated()).put("runCount", report.runs().size)
        if (runId == null) {
            val rows = report.runs().drop(offset).take(16)
            result.put("runs", JSONArray().apply {
                rows.forEach { run -> put(JSONObject().put("ownerId", run.ownerId())
                    .put("runId", run.runId()).put("unfinished", run.unfinished())
                    .put("auditUncertain", run.auditUncertain())
                    .put("callCount", run.calls().size)) }
            })
            result.put("nextOffset", if (offset + rows.size < report.runs().size) offset + rows.size else JSONObject.NULL)
        } else {
            val run = report.runs().firstOrNull { it.runId() == runId }
                ?: throw IllegalArgumentException("Capability audit run changed")
            val rows = run.calls().drop(offset).take(16)
            result.put("runId", runId).put("ownerId", run.ownerId())
                .put("unfinished", run.unfinished()).put("auditUncertain", run.auditUncertain())
                .put("callCount", run.calls().size)
                .put("calls", JSONArray().apply { rows.forEach { call ->
                    put(JSONObject().put("callId", call.callId())
                        .put("action", call.action().name).put("target", call.target())
                        .put("expectedRevision", call.expectedRevision() ?: JSONObject.NULL)
                        .put("resultRevision", call.resultRevision() ?: JSONObject.NULL)
                        .put("reason", call.reason()))
                } })
                .put("nextOffset", if (offset + rows.size < run.calls().size) offset + rows.size else JSONObject.NULL)
        }
        return result
    }
    private fun status() = JSONObject().put("method", "runtime.status").put("params",
        JSONObject().put("phase", phase).put("error", failure ?: JSONObject.NULL)
            .put("mode", mode).put("generation", recovery.generation).put("modeToken", modeToken)
            .put("nodeStarted", nodeStarted).put("bootStage", bootStage).put("recoveryBusy", recoveryBusy)
            .put("mutationAllowed", mutationAllowed)
            .put("workflowRecovery", workflowRecovery)
            .put("background", background.status()))
    private fun recoveryError(id: String, code: String, message: String, notStarted: String? = null) =
        JSONObject().put("id", id).put("error", JSONObject().put("code", code).put("message", message).also {
            if (notStarted != null) it.put("details", JSONObject().put("outcome", "not-started").put("requestId", notStarted))
        })
    private fun error(id: String, message: String) = JSONObject().put("jsonrpc", "2.0").put("id", id)
        .put("error", JSONObject().put("code", -32603).put("message", message))
    private fun fail(message: String) {
        if (!lifecycle.fail()) return
        main.post {
            lifecycle.stopFailedProcess(
                {
                    val stored = persistInterruption(RuntimeInterruptionRecord.RUNTIME_LOST)
                    reportFailure(if (stored) message else "$message；本地中断摘要未能保存")
                },
                { stopForeground(STOP_FOREGROUND_REMOVE) },
                { stopSelf() },
                { Process.killProcess(Process.myPid()) },
            )
        }
    }
    private fun persistInterruption(kind: String): Boolean = try {
        val now = System.currentTimeMillis()
        RuntimeInterruptionRecord.write(noBackupFilesDir, kind, runtimeLease?.interruptionTime(now) ?: now)
        true
    } catch (failure: Exception) {
        // IPC teardown must still stop Node if private storage is unavailable.
        false
    }
    /** Internal producer only. No JSON-RPC route may create a review or construct its scope. */
    internal fun prepareIsolatedScriptApproval(
        runId: String, scope: IsolatedExecutionPolicyOwner.Scope,
        handle: IsolatedScriptRunController.ApprovalHandle,
        workspaceId: String?, program: String, inputJson: String, deadlineMillis: Int,
        onApproved: (() -> Unit)? = null, onDenied: (() -> Unit)? = null,
    ): IsolatedExecutionApprovalInbox.Review {
        val current = handle.owner.current()
        check(scope.ownerId() == current.ownerId() && scope.sessionId() == current.sessionId()
            && scope.version() == current.version() + 1)
        val review = isolatedApprovals.prepare(runId, scope, program, inputJson,
            deadlineMillis, object : IsolatedExecutionApprovalInbox.Decision {
            override fun approve(
                approved: IsolatedExecutionPolicyOwner.Scope, namedRunId: String, approvalId: String,
            ) {
                handle.approveTrustedUiChoiceForRun(approved, approvalId, namedRunId)
                isolatedRuns.installApprovedPlan(namedRunId, approved.sessionId(), workspaceId,
                    approved, handle, program, inputJson, deadlineMillis)
                onApproved?.invoke()
            }

            override fun deny(namedRunId: String) {
                try {
                    val state = handle.owner.current()
                    handle.owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(
                        state.ownerId(), state.sessionId(), state.version() + 1,
                    ))
                } finally {
                    if (isolatedRunsDelegate.isInitialized())
                        isolatedRuns.discardApprovedPlan(namedRunId)
                    handle.close()
                    onDenied?.invoke()
                }
            }
        })
        // A review and its short run lease retire even when the UI never reopens.
        try {
            isolatedApprovalExpiry.schedule({ isolatedApprovals.list() },
                IsolatedExecutionApprovalInbox.REVIEW_MILLIS, TimeUnit.MILLISECONDS)
            isolatedApprovalExpiry.schedule({ isolatedApprovals.list() },
                IsolatedExecutionApprovalInbox.REVIEW_MILLIS + scope.leaseMillis(),
                TimeUnit.MILLISECONDS)
        } catch (failure: RejectedExecutionException) {
            try { isolatedApprovals.deny(review.id(), review.challenge()) }
            catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
            throw failure
        }
        return review
    }

    private fun manualCatalog(): JSONObject {
        check(phase == "ready") { "Agent runtime unavailable" }
        val id = "native-manual-${UUID.randomUUID()}"
        val future = CompletableFuture<JSONObject>()
        main.post {
            nativePending[id] = { result -> result.fold(
                onSuccess = { future.complete(it) },
                onFailure = { future.completeExceptionally(it) },
            ) }
            try { workers.execute {
                try { write(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", "library.catalog").put("params", JSONObject())) }
                catch (failure: Exception) { main.post {
                    nativePending.remove(id)?.invoke(Result.failure(failure))
                } }
            } } catch (failure: Exception) {
                nativePending.remove(id)?.invoke(Result.failure(failure))
            }
        }
        try { return future.get(8, TimeUnit.SECONDS) }
        finally { main.post { nativePending.remove(id) } }
    }

    /** A guest tool call remains owned by the admitted isolated run, including its reply lease. */
    private fun requestIsolatedTool(method: String, params: JSONObject, timeoutMillis: Long): JSONObject {
        check(method == "native.toolCallback" || method == "native.toolCallback.cancel" ||
            method == "native.workflowCallback" || method == "native.workflowCallback.cancel")
        check(phase == "ready" && lifecycle.acceptsFrames() && !bootStopped) {
            "Agent runtime unavailable"
        }
        check(timeoutMillis > 0)
        val id = "native-isolated-tool-${UUID.randomUUID()}"
        val future = CompletableFuture<JSONObject>()
        // nativePending is confined to main; register before a worker writes the request.
        check(main.post {
            if (phase != "ready" || !lifecycle.acceptsFrames() || bootStopped) {
                future.completeExceptionally(IllegalStateException("Agent runtime unavailable"))
                return@post
            }
            nativePending[id] = { result -> result.fold(
                onSuccess = { future.complete(it) },
                onFailure = { future.completeExceptionally(it) },
            ) }
            try { workers.execute {
                try { write(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", method).put("params", params)) }
                catch (failure: Exception) { main.post {
                    nativePending.remove(id)?.invoke(Result.failure(failure))
                } }
            } } catch (failure: Exception) {
                nativePending.remove(id)?.invoke(Result.failure(failure))
            }
        }) { "Agent service main loop is unavailable" }
        try { return future.get(timeoutMillis, TimeUnit.MILLISECONDS) }
        finally { main.post { nativePending.remove(id) } }
    }

    private fun prepareManualRun(params: JSONObject): JSONObject {
        val selected = ManualIsolatedScriptRequest.select(params, manualCatalog(),
            File(applicationInfo.dataDir), File(noBackupFilesDir, "dsh/workspace"))
        val runId = UUID.randomUUID().toString()
        IsolatedScriptRunController.requireFreshRunId(this, runId)
        val ownerId = "manual-$runId"
        val preferences = getSharedPreferences("manual-isolated-run", MODE_PRIVATE)
        val previousLatest = preferences.getString("latest", null)
        var handle: IsolatedScriptRunController.ApprovalHandle? = null
        try {
            if (selected.needsApproval) {
                val policyDirectory = File(filesDir, "manual-script-policies/$runId")
                check(policyDirectory.mkdirs()) { "Cannot create policy history" }
                handle = IsolatedScriptRunController.newPolicyOwner(this, policyDirectory,
                    ownerId, selected.sessionId)
                val version = handle.owner.current().version() + 1
                val run = ManualRun(runId, selected, ownerId, version, "awaiting-approval")
                rememberManualRun(run)
                check(preferences.edit()
                    .putString("latest", runId).commit()) { "Run history could not be saved" }
                val scope = selected.scope(ownerId, version, File(applicationInfo.dataDir).toPath())
                val review = prepareIsolatedScriptApproval(runId, scope, handle,
                    selected.workspaceId, selected.program, selected.inputJson, selected.deadlineMillis,
                    onApproved = {
                        run.stage = "running"
                        workers.execute { executeManualRun(run) }
                    }, onDenied = {
                        if (run.stage == "awaiting-approval") {
                            run.stage = "denied"
                            getSharedPreferences("manual-isolated-run", MODE_PRIVATE).edit()
                                .putString("deniedId", runId).commit()
                        }
                    })
                run.reviewId = review.id()
                run.challenge = review.challenge()
                return JSONObject().put("runId", runId).put("stage", run.stage)
                    .put("requestId", review.id())
            }
            val run = ManualRun(runId, selected, ownerId, 1, "running")
            rememberManualRun(run)
            check(preferences.edit()
                .putString("latest", runId).commit()) { "Run history could not be saved" }
            workers.execute { executeManualRun(run) }
            return JSONObject().put("runId", runId).put("stage", "running")
        } catch (failure: Exception) {
            manualRuns.remove(runId)
            if (preferences.getString("latest", null) == runId) {
                preferences.edit().putString("latest", previousLatest).commit()
            }
            try { handle?.close() } catch (close: Exception) { failure.addSuppressed(close) }
            throw failure
        }
    }

    private fun rememberManualRun(run: ManualRun) = synchronized(manualRuns) {
        val latest = getSharedPreferences("manual-isolated-run", MODE_PRIVATE).getString("latest", null)
        ManualRunHistory.makeRoom(manualRuns, latest) { it.stage }
        check(manualRuns.putIfAbsent(run.runId, run) == null)
    }

    private fun executeManualRun(run: ManualRun) {
        var token: String? = null
        try {
            val currentSelection = try {
                ManualIsolatedScriptRequest.select(run.selection.request(), manualCatalog(),
                    File(applicationInfo.dataDir), File(noBackupFilesDir, "dsh/workspace"))
            } catch (_: Exception) { null }
            if (currentSelection == null || !run.selection.sameIdentity(currentSelection)) {
                // Logical ownership or the selected file changed while native review was open.
                // Revoke the approved plan first, then consume this run ID with a durable
                // pre-execution cancellation instead of running a stale grant.
                val reviewId = run.reviewId
                val challenge = run.challenge
                if (reviewId != null && challenge != null) try {
                    isolatedApprovals.deny(reviewId, challenge)
                } catch (_: Exception) { /* The review may already have expired. */ }
                isolatedRuns.discardApprovedPlan(run.runId)
                IsolatedScriptRunController.reserve(this, run.runId).cancelBeforeExecution(this)
                val entry = IsolatedScriptRunController.readReceipt(this, run.runId)
                run.receipt = JSONObject().put("runId", run.runId).put("state", entry.state().name)
                    .put("outputJson", JSONObject.NULL)
                    .put("logsJson", JSONObject.NULL)
                    .put("detail", "选择的会话、工作区或文件已变化，运行前取消")
                run.stage = "terminal"
                return
            }
            // Even a cancellation before admission creates a durable, one-use CANCELLED
            // receipt. Skipping admit would leave an approved plan and no recovery proof.
            val admitted = isolatedRuns.admit(run.selection.admission(run.runId, run.ownerId, run.version))
            token = admitted.getString("token")
            run.token = token
            val identity = JSONObject().put("runId", run.runId).put("token", token)
            if (run.cancelRequested) isolatedRuns.cancel(identity)
            else isolatedRuns.execute(identity)
            run.receipt = isolatedRuns.settle(identity)
            run.stage = "terminal"
            try { isolatedRuns.release(identity) } catch (_: Exception) {
                // Keep the durable receipt; a failed release never turns into a retry.
            }
        } catch (_: Exception) {
            run.stage = "unconfirmed"
            if (token != null) try { isolatedRuns.cancel(JSONObject()
                .put("runId", run.runId).put("token", token)) } catch (_: Exception) { }
            try {
                val entry = IsolatedScriptRunController.readReceipt(this, run.runId)
                if (entry.state() != IsolatedScriptReceipt.State.ADMITTED) {
                    run.receipt = JSONObject().put("runId", run.runId)
                        .put("state", entry.state().name).put("detail", entry.detail() ?: JSONObject.NULL)
                        .put("outputJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                            entry.outputJson() else JSONObject.NULL)
                        .put("logsJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                            entry.logsJson() else JSONObject.NULL)
                    run.stage = "terminal"
                }
            } catch (_: Exception) { /* An absent receipt is still unconfirmed. */ }
        }
    }

    private fun manualRunStatus(runId: String): JSONObject {
        val actualId = runId.ifBlank { getSharedPreferences("manual-isolated-run", MODE_PRIVATE)
            .getString("latest", null) ?: return JSONObject().put("stage", "none") }
        IsolatedScriptWire.requireUuid(actualId)
        val run = manualRuns[actualId]
        if (run != null) {
            if (run.stage == "unconfirmed") try {
                val entry = IsolatedScriptRunController.readReceipt(this, actualId)
                if (entry.state() != IsolatedScriptReceipt.State.ADMITTED) {
                    run.receipt = JSONObject().put("runId", actualId)
                        .put("state", entry.state().name)
                        .put("detail", entry.detail() ?: JSONObject.NULL)
                        .put("outputJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                            entry.outputJson() else JSONObject.NULL)
                        .put("logsJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                            entry.logsJson() else JSONObject.NULL)
                    run.stage = "terminal"
                }
            } catch (_: Exception) { }
            val value = JSONObject().put("runId", actualId).put("stage", run.stage)
            if (run.reviewId != null) value.put("requestId", run.reviewId)
            if (run.receipt != null) value.put("receipt", run.receipt)
            return value
        }
        return try {
            val entry = IsolatedScriptRunController.readReceipt(this, actualId)
            val receipt = JSONObject().put("runId", actualId).put("state", entry.state().name)
                .put("detail", entry.detail() ?: JSONObject.NULL)
                .put("outputJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                    entry.outputJson() else JSONObject.NULL)
                .put("logsJson", if (entry.state() == IsolatedScriptReceipt.State.COMPLETED)
                    entry.logsJson() else JSONObject.NULL)
            JSONObject().put("runId", actualId).put("stage", if (entry.state() ==
                IsolatedScriptReceipt.State.ADMITTED) "unconfirmed" else "terminal")
                .put("receipt", receipt)
        } catch (_: Exception) {
            val denied = getSharedPreferences("manual-isolated-run", MODE_PRIVATE)
                .getString("deniedId", null)
            JSONObject().put("runId", actualId).put("stage",
                if (denied == actualId) "denied" else "unconfirmed")
        }
    }

    private fun cancelManualRun(runId: String): Boolean {
        IsolatedScriptWire.requireUuid(runId)
        val run = manualRuns[runId] ?: return false
        if (run.stage == "awaiting-approval") {
            val reviewId = run.reviewId ?: return false
            val challenge = run.challenge ?: return false
            isolatedApprovals.deny(reviewId, challenge)
            return true
        }
        val token = run.token ?: run {
            if (run.stage == "terminal" || run.stage == "denied" || run.stage == "cancelled")
                return false
            run.cancelRequested = true
            run.stage = "cancelling"
            return true
        }
        if (run.stage == "terminal" || run.stage == "cancelled") return false
        run.stage = "cancelling"
        return isolatedRuns.cancel(JSONObject().put("runId", runId).put("token", token))
    }

    private fun isolatedApprovalView(review: IsolatedExecutionApprovalInbox.Review,
        includeProgram: Boolean) = JSONObject()
        .put("requestId", review.id())
        .put("challenge", review.challenge())
        .put("runId", review.runId())
        .put("sessionId", review.sessionId())
        .put("expiresAtMillis", review.expiresAtMillis())
        .put("active", review.active())
        .apply { if (includeProgram) put("program", review.program()) }
        .put("programSha256", review.programSha256())
        .put("snapshotSha256", review.snapshotSha256())
        .put("workspacePath", review.workspacePath() ?: JSONObject.NULL)
        .put("readablePaths", JSONArray(review.readablePaths()))
        .put("writablePaths", JSONArray(review.writablePaths()))
        .put("exactHosts", JSONArray(review.exactHosts()))
        .put("fileCallLimit", review.fileCallLimit())
        .put("networkCallLimit", review.networkCallLimit())
        .put("leaseMillis", review.leaseMillis())
        .apply { if (linuxNetworkApprovalsDelegate.isInitialized()) linuxNetworkApprovals.decorate(review, this) }

    private fun linuxNetworkReviewOffer(review: IsolatedExecutionApprovalInbox.Review) = JSONObject()
        .put("method", "runtime.linuxNetworkReview.available").put("params", JSONObject()
            .put("requestId", review.id()).put("snapshotSha256", review.snapshotSha256()))

    private fun offerLinuxNetworkReview(review: IsolatedExecutionApprovalInbox.Review): Boolean {
        val offered = CompletableFuture<Boolean>()
        main.post {
            val client = foregroundAppClients.firstOrNull { appClients.containsKey(it) && it.binder.isBinderAlive }
            if (client == null || phase != "ready" || !lifecycle.acceptsFrames()) offered.complete(false)
            else { send(client, linuxNetworkReviewOffer(review)); offered.complete(true) }
        }
        return try { offered.get(2, TimeUnit.SECONDS) } catch (_: Exception) { false }
    }

    private fun closeLinuxNetworkApprovals() {
        if (!linuxNetworkApprovalsDelegate.isInitialized()) return
        linuxNetworkApprovals.stopAccepting()
        Thread({
            try { linuxNetworkApprovals.close() }
            catch (_: Exception) { android.util.Log.e("DSH", "Linux network approval cleanup remains unconfirmed") }
        }, "linux-network-approval-close").start()
    }

    private fun reportFailure(message: String) {
        phase = "failed"; failure = message
        scheduleWakeup.runtimeFailed(recovery.generation)
        background.phase(phase)
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        summaryRequest = null
        closeDocumentSearch()
        closeDocumentImages()
        pending.entries.forEach { send(it.value, error(it.key, message)) }; pending.clear()
        val callbacks = nativePending.values.toList()
        nativePending.clear()
        callbacks.forEach { it(Result.failure(IllegalStateException(message))) }
        transitions.unavailable()
        approvals.close()
        closeLinuxNetworkApprovals()
        isolatedApprovals.close()
        isolatedApprovalExpiry.shutdownNow()
        if (linuxCommandsDelegate.isInitialized()) linuxCommands.close()
        if (linuxVmDelegate.isInitialized()) linuxVm.close()
        taskCompletion.close()
        broadcast(status())
    }
    private fun broadcast(frame: JSONObject) { clients.toList().forEach { send(it, frame) } }
    private fun send(client: Messenger, frame: JSONObject) {
        try {
            val payload = WirePayload.encode(frame.toString())
            try { client.send(Message.obtain(null, 2).apply { data = payload }) }
            finally { WirePayload.close(payload) }
        }
        catch (_: RemoteException) { removeClient(client) }
    }
    private fun removeClient(client: Messenger) {
        clients.remove(client)
        foregroundAppClients.remove(client)
        val record = appClients.remove(client) ?: return
        taskCompletion.disconnected(record.owner)
        client.binder.unlinkToDeath(record.death, 0)
        transitions.disconnect(client)
        if (phase != "ready" || workers.isShutdown) return
        workers.execute {
            try {
                write(JSONObject().put("jsonrpc", "2.0").put("method", "native.appDisconnected")
                    .put("params", JSONObject().put("owner", record.owner)))
            } catch (exception: Exception) {
                // A closed Node process owns no remaining observations. Its exit is reported by boot().
            }
        }
    }
    private fun closeDocumentSearch() {
        // Provider cancellation and pipe close can block; never run either on
        // the main thread. The search owner remains responsible for final close.
        Thread({
            try { documentSearch.close() }
            catch (exception: InterruptedException) { Thread.currentThread().interrupt() }
        }, "document-search-close").start()
    }
    private fun closeDocumentImages() {
        if (!documentImagesDelegate.isInitialized()) return
        // A provider cancellation callback may block; lifecycle teardown must not wait on the main thread.
        Thread({ documentImages.close() }, "document-image-close").start()
    }
    override fun onDestroy() {
        if (::scheduleWakeup.isInitialized) scheduleWakeup.unbind(recovery.generation)
        closeLinuxNetworkApprovals()
        val plannedProcessExit = lifecycle.processExitRequired()
        val unexpectedNodeStop = synchronized(nodeStartLock) {
            !plannedProcessExit && lifecycle.closeUnexpected() && nodeStarted
        }
        if (plannedProcessExit || unexpectedNodeStop) {
            try {
                synchronized(nodeStartLock) {
                    // A pre-Node lease was only protecting receipt recovery.
                    if (!nodeStarted) try { runtimeLease?.closePlanned() } catch (_: Exception) {}
                }
                if (unexpectedNodeStop) persistInterruption(RuntimeInterruptionRecord.RUNTIME_LOST)
                if (linuxCommandsDelegate.isInitialized()) linuxCommands.close()
                if (linuxVmDelegate.isInitialized()) linuxVm.close()
                closeDocumentImages()
            }
            finally {
                try {
                    try { if (::taskCompletion.isInitialized) taskCompletion.close() }
                    finally { super.onDestroy() }
                }
                finally {
                    // Keep the lease until process death; in-process Node/IPC cleanup can block.
                    Process.killProcess(Process.myPid())
                }
            }
            return
        }
        try {
            if (linuxCommandsDelegate.isInitialized()) linuxCommands.close()
            if (linuxVmDelegate.isInitialized()) linuxVm.close()
            closeDocumentImages()
            transitions.close()
            main.removeCallbacks(summaryPoll)
            main.removeCallbacks(summaryTimeout)
            summaryRequest = null
            background.close()
            getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
            closeDocumentSearch()
            output?.close(); workers.shutdownNow()
            try {
                runtimeLease?.let { if (nodeStarted) it.close() else it.closePlanned() }
            } catch (_: Exception) { /* Process exit releases its lock. */ }
            transitionWrites.shutdown()
            // Accepted writes own their completion; Activity cancellation never interrupts commits.
            recoveryWorker.shutdown()
            approvals.close()
            isolatedApprovals.close()
            isolatedApprovalExpiry.shutdownNow()
            if (isolatedRunsDelegate.isInitialized()) isolatedRuns.close()
            if (workflowRunsDelegate.isInitialized()) workflowRuns.close()
            taskCompletion.close()
            appClients.keys.toList().forEach { removeClient(it) }
        } finally { super.onDestroy() }
    }
}
