package com.minnnng.dsh_android

import android.app.*
import android.content.Intent
import android.os.*
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkRequest
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.RejectedExecutionException

/** Owns Node and its IPC endpoint; activity destruction does not terminate tasks. */
class AgentService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val lifecycle = RuntimeLifecycle()
    private val workers = Executors.newCachedThreadPool()
    private val networkChanges = NetworkChangeDispatch(lifecycle, workers)
    private val recoveryWorker = Executors.newSingleThreadExecutor()
    private val transitionWrites = Executors.newSingleThreadExecutor()
    private val clients = mutableSetOf<Messenger>()
    private data class AppClient(val owner: String, val death: IBinder.DeathRecipient)
    private val appClients = mutableMapOf<Messenger, AppClient>()
    private val pending = ConcurrentHashMap<String, Messenger>()
    private val isolationProbeBusy = AtomicBoolean(false)
    private val nativePending = mutableMapOf<String, (Result<JSONObject>) -> Unit>()
    @Volatile private var output: RuntimeTransport? = null
    @Volatile private var phase = "starting"
    private var failure: String? = null
    private lateinit var recovery: RecoveryRuntime
    private var mode = "active"
    private var modeToken = ""
    @Volatile private var nodeStarted = false
    @Volatile private var bootStopped = false
    @Volatile private var mutationAllowed = false
    @Volatile private var bootStage = "service-created"
    private var started = false
    private var recoveryBusy = false
    private lateinit var transitions: PackageOperationTransitions
    private lateinit var vault: CredentialVault
    private lateinit var webPreferences: WebPreferences
    private lateinit var approvals: ApprovalNotifications
    private lateinit var taskCompletion: TaskCompletionNotifications
    private lateinit var documentSearch: DocumentSearchManager
    private lateinit var background: BackgroundExecution
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
        background.unavailable()
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
        else if (message.what == TaskCompletionNotifications.MESSAGE_VIEWING) {
            appClients[client]?.let { record ->
                taskCompletion.viewing(record.owner, message.data.getString("sessionId"), message.data.getBoolean("foreground"))
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
                if (reply.accepted()) stopForTransition() else transitionReply(client, token, reply)
            }
        }
        true
    })

    override fun onCreate() {
        super.onCreate()
        recovery = RecoveryRuntime(this)
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
        lifecycle.close()
        try {
            phase = "failed"
            failure = "系统已结束后台运行时段，正在停止任务；重新打开 App 后核对中断记录"
            background.phase(phase)
            broadcast(status())
        } finally {
            try { stopForeground(STOP_FOREGROUND_REMOVE) }
            finally {
                try { stopSelf() }
                finally { Process.killProcess(Process.myPid()) }
            }
        }
    }

    private fun boot() {
        try {
            bootStage = "preparing-assets"
            val runtime = RuntimeAssets.prepare(this)
            bootStage = "preparing-storage"
            attachmentCacheDirectory()
            val home = File(noBackupFilesDir, "dsh").apply { mkdirs() }
            File(home, "workspace").mkdirs()
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
            nodeStarted = true
            val code = NativeRuntime.start(runtime.path, home.path, cacheDir.path, applicationInfo.nativeLibraryDir, pair[1])
            fail("运行时已退出：$code")
        } catch (exception: Throwable) { fail(exception.message ?: exception.javaClass.simpleName) }
        finally { finishAttachmentCache() }
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
                        "native.credentials.get" -> vault.get(params.getString("name"))
                        "native.credentials.set" -> { vault.set(params.getString("name"), params.getString("value")); true }
                        "native.credentials.remove" -> { vault.set(params.getString("name"), null); true }
                        "native.credentials.names" -> org.json.JSONArray(vault.names())
                        "native.web.preferences" -> webPreferences.get()
                        "native.web.save" -> webPreferences.save(params)
                        "native.network.addresses" -> webPreferences.addresses()
                        "native.documents.roots" -> DocumentAccess(this).roots()
                        "native.documents.list" -> DocumentAccess(this).list(params.getString("root"), params.optString("path"))
                        "native.documents.read" -> DocumentAccess(this).read(params.getString("root"), params.getString("path"), DocumentReadAccess.offset(params.opt("offset")))
                        "native.documents.revoke" -> {
                            val root = params.getString("root")
                            DocumentAccess(this).revoke(root).put("searchesStopped", documentSearch.revokeRoot(root))
                        }
                        "native.documents.search.prepare" -> documentSearch.prepare(params.getString("id"))
                        "native.documents.search.run" -> documentSearch.run(params)
                        "native.documents.search.cancel" -> documentSearch.cancel(params.getString("id"))
                        "native.exports.directory" -> DocumentExports.directory(this).canonicalPath
                        "native.attachments.directory" -> AttachmentTransfers.directory(this).canonicalPath
                        "native.attachmentFiles.directory" -> attachmentCacheDirectory()
                        "native.storage.root" -> File(applicationInfo.dataDir).canonicalPath
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
                try { background.observe(frame.getJSONObject("params")) }
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
                            try { background.observe(snapshot) }
                            catch (_: Exception) { background.unavailable() }
                        },
                        onFailure = { background.unavailable() },
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
    private fun stopForTransition() {
        check(Application.getProcessName().endsWith(":agent")) { "Runtime restart requires the dedicated Agent process" }
        lifecycle.close()
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
            return JSONObject().put("workerUid", evidence.workerUid)
                .put("hostUid", Process.myUid()).put("bytes", evidence.bytes)
                .put("sha256", evidence.sha256).put("privateReadDenied", true)
                .put("grantReadVerified", true)
        } finally {
            check(file.delete() || !file.exists()) { "Could not remove isolation probe input" }
        }
    }
    private fun status() = JSONObject().put("method", "runtime.status").put("params",
        JSONObject().put("phase", phase).put("error", failure ?: JSONObject.NULL)
            .put("mode", mode).put("generation", recovery.generation).put("modeToken", modeToken)
            .put("nodeStarted", nodeStarted).put("bootStage", bootStage).put("recoveryBusy", recoveryBusy)
            .put("mutationAllowed", mutationAllowed)
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
            if (!lifecycle.failed()) return@post
            reportFailure(message)
        }
    }
    private fun reportFailure(message: String) {
        phase = "failed"; failure = message
        background.phase(phase)
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        summaryRequest = null
        closeDocumentSearch()
        pending.entries.forEach { send(it.value, error(it.key, message)) }; pending.clear()
        val callbacks = nativePending.values.toList()
        nativePending.clear()
        callbacks.forEach { it(Result.failure(IllegalStateException(message))) }
        transitions.unavailable()
        approvals.close()
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
    override fun onDestroy() {
        lifecycle.close()
        transitions.close()
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        summaryRequest = null
        background.close()
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        closeDocumentSearch()
        output?.close(); workers.shutdownNow()
        transitionWrites.shutdown()
        // Accepted writes own their completion; Activity cancellation never interrupts commits.
        recoveryWorker.shutdown()
        approvals.close()
        taskCompletion.close()
        appClients.keys.toList().forEach { removeClient(it) }
        super.onDestroy()
    }
}
