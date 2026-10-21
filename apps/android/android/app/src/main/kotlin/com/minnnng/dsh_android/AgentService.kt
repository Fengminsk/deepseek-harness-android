package com.minnnng.dsh_android

import android.app.*
import android.content.Intent
import android.os.*
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkRequest
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID

/** Owns Node and its IPC endpoint; activity destruction does not terminate tasks. */
class AgentService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()
    private val recoveryWorker = Executors.newSingleThreadExecutor()
    private val clients = mutableSetOf<Messenger>()
    private data class AppClient(val owner: String, val death: IBinder.DeathRecipient)
    private val appClients = mutableMapOf<Messenger, AppClient>()
    private val pending = ConcurrentHashMap<String, Messenger>()
    private val nativePending = mutableMapOf<String, (Result<JSONObject>) -> Unit>()
    private var output: BufferedWriter? = null
    @Volatile private var phase = "starting"
    private var failure: String? = null
    private lateinit var recovery: RecoveryRuntime
    private var mode = "active"
    private var modeToken = ""
    @Volatile private var nodeStarted = false
    @Volatile private var mutationAllowed = false
    @Volatile private var bootStage = "service-created"
    private var started = false
    private var recoveryBusy = false
    private var transitionToken: String? = null
    private val transitionExpired = Runnable { transitionToken = null }
    private lateinit var vault: CredentialVault
    private lateinit var webPreferences: WebPreferences
    private lateinit var approvals: ApprovalNotifications
    private lateinit var documentSearch: DocumentSearchManager
    private lateinit var background: BackgroundExecution
    private var summaryRequest: String? = null
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
        workers.execute {
            try { if (output != null) write(JSONObject().put("jsonrpc", "2.0").put("method", "native.networkChanged").put("params", JSONObject())) }
            catch (exception: Exception) { if (phase == "ready") fail(exception.message ?: "Network notification failed") }
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
                    "documents.search", "documents.search.cancel")) {
                val owner = appClients[client]?.owner
                if (owner == null) {
                    send(client, error(id, "App stream owner is disconnected"))
                    return@Handler true
                }
                val params = frame.optJSONObject("params") ?: JSONObject()
                params.put("owner", owner)
                frame.put("params", params)
            }
            if (frame.getString("method") == "recovery.call") {
                val request = frame.optJSONObject("params") ?: JSONObject()
                val method = request.optString("method")
                val params = request.optJSONObject("params") ?: JSONObject()
                val mutation = method in setOf("write", "restore", "runtimeRepair")
                if (!appClients.containsKey(client)) {
                    send(client, recoveryError(id, "recovery/disconnected", "恢复连接已断开，请重新打开页面"))
                } else if (mutation && (recoveryBusy || transitionToken != null)) {
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
            } else if (frame.getString("method") == "runtime.background.configure") {
                try {
                    val value = frame.getJSONObject("params").get("keepAwakeWhileWorking")
                    require(value is Boolean) { "后台运行选项必须是布尔值" }
                    send(client, JSONObject().put("id", id).put("result", background.configure(value)))
                    broadcast(status())
                } catch (exception: Exception) {
                    send(client, error(id, exception.message ?: "无法保存后台运行设置"))
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
        else if (message.what == ApprovalNotifications.MESSAGE_RESPOND) {
            try {
                approvals.handle(JSONObject(WirePayload.decode(message.data))) { ack -> send(client, ack) }
            } catch (exception: Exception) {
                send(client, JSONObject().put("accepted", false).put("requestStillPending", false))
            }
        } else if (message.what == 5) approvals.refresh()
        else if (message.what == 6 && appClients.containsKey(client)) {
            val token = message.data.getString("token") ?: ""
            val accepted = !recoveryBusy && transitionToken == null &&
                token.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))
            if (accepted) {
                transitionToken = token
                main.removeCallbacks(transitionExpired)
                main.postDelayed(transitionExpired, 15_000)
            }
            send(client, JSONObject().put("method", "runtime.transition").put("params",
                JSONObject().put("token", token).put("accepted", accepted)))
        }
        else if (message.what == 9 && appClients.containsKey(client)) {
            if (message.data.getString("token") == transitionToken) {
                transitionToken = null
                main.removeCallbacks(transitionExpired)
            }
        }
        else if (message.what == 8 && appClients.containsKey(client) &&
            transitionToken != null && message.data.getString("token") == transitionToken && !recoveryBusy) {
            check(Application.getProcessName().endsWith(":agent")) { "Runtime restart requires the dedicated Agent process" }
            main.removeCallbacks(transitionExpired)
            phase = "restarting"
            background.phase(phase)
            main.removeCallbacks(summaryPoll)
            main.removeCallbacks(summaryTimeout)
            broadcast(status())
            approvals.close()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            // libnode can start only once per process. The Activity waits for Binder
            // death before creating the replacement; durable data stays untouched.
            main.post { Process.killProcess(Process.myPid()) }
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

    private fun boot() {
        try {
            bootStage = "preparing-assets"
            val runtime = RuntimeAssets.prepare(this)
            bootStage = "preparing-storage"
            val home = File(noBackupFilesDir, "dsh").apply { mkdirs() }
            File(home, "workspace").mkdirs()
            val pair = NativeRuntime.socketPair()
            val socket = ParcelFileDescriptor.adoptFd(pair[0])
            val readSocket = ParcelFileDescriptor.dup(socket.fileDescriptor)
            output = ParcelFileDescriptor.AutoCloseOutputStream(socket).bufferedWriter()
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
    }
    private fun handle(frame: JSONObject) {
        if (frame.has("method") && frame.has("id")) {
            workers.execute {
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
                        "native.documents.read" -> DocumentAccess(this).read(params.getString("root"), params.getString("path"), params.optInt("offset", 0))
                        "native.documents.revoke" -> {
                            val root = params.getString("root")
                            DocumentAccess(this).revoke(root).put("searchesStopped", documentSearch.revokeRoot(root))
                        }
                        "native.documents.search.prepare" -> documentSearch.prepare(params.getString("id"))
                        "native.documents.search.run" -> documentSearch.run(params)
                        "native.documents.search.cancel" -> documentSearch.cancel(params.getString("id"))
                        "native.exports.directory" -> DocumentExports.directory(this).canonicalPath
                        "native.attachments.directory" -> AttachmentTransfers.directory(this).canonicalPath
                        "native.storage.root" -> File(applicationInfo.dataDir).canonicalPath
                        else -> throw IllegalArgumentException("Unsupported native method: $method")
                    }
                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", value ?: JSONObject.NULL))
                } catch (exception: Exception) { write(error(id, exception.message ?: "Native operation failed")) }
            }
        } else main.post {
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
    @Synchronized private fun write(frame: JSONObject) {
        val stream = output ?: throw IllegalStateException("Runtime is not connected")
        stream.write(frame.toString()); stream.newLine(); stream.flush()
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
    private fun fail(message: String) { main.post {
        phase = "failed"; failure = message
        background.phase(phase)
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        summaryRequest = null
        closeDocumentSearch()
        pending.entries.forEach { send(it.value, error(it.key, message)) }; pending.clear()
        nativePending.values.toList().forEach { it(Result.failure(IllegalStateException(message))) }
        nativePending.clear()
        approvals.close()
        broadcast(status())
    } }
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
        client.binder.unlinkToDeath(record.death, 0)
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
        main.removeCallbacks(transitionExpired)
        main.removeCallbacks(summaryPoll)
        main.removeCallbacks(summaryTimeout)
        summaryRequest = null
        background.close()
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        closeDocumentSearch()
        output?.close(); workers.shutdownNow()
        // Accepted writes own their completion; Activity cancellation never interrupts commits.
        recoveryWorker.shutdown()
        approvals.close()
        appClients.keys.toList().forEach { removeClient(it) }
        super.onDestroy()
    }
}
