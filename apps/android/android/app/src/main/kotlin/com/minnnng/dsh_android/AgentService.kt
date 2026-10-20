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

/** Owns Node and its IPC endpoint; activity destruction does not terminate tasks. */
class AgentService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()
    private val clients = mutableSetOf<Messenger>()
    private val pending = ConcurrentHashMap<String, Messenger>()
    private var output: BufferedWriter? = null
    private var phase = "starting"
    private var failure: String? = null
    private lateinit var vault: CredentialVault
    private lateinit var webPreferences: WebPreferences
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
            clients.add(client)
            send(client, status())
        } else if (message.what == 2) {
            val raw = WirePayload.decode(message.data)
            val frame = JSONObject(raw)
            val id = frame.getString("id")
            if (frame.getString("method") == "runtime.status") {
                send(client, JSONObject().put("id", id).put("result", status().getJSONObject("params")))
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
        } else if (message.what == 3) clients.remove(client)
        true
    })

    override fun onCreate() {
        super.onCreate()
        vault = CredentialVault(this)
        webPreferences = WebPreferences(this)
        getSystemService(ConnectivityManager::class.java).registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel("agent", "Pocket Harness", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(1, Notification.Builder(this, "agent")
            .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Pocket Harness")
            .setContentText("本地 Agent 服务正在运行").setContentIntent(open).setOngoing(true).build())
        workers.execute { boot() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun boot() {
        try {
            val runtime = RuntimeAssets.prepare(this)
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
                        else -> throw IllegalArgumentException("Unsupported native method: $method")
                    }
                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", value ?: JSONObject.NULL))
                } catch (exception: Exception) { write(error(id, exception.message ?: "Native operation failed")) }
            }
        } else main.post {
            if (frame.optString("method") == "runtime.ready") { phase = "ready"; broadcast(status()) }
            if (frame.has("id")) pending.remove(frame.getString("id"))?.let { send(it, frame) }
            else broadcast(frame)
        }
    }
    @Synchronized private fun write(frame: JSONObject) {
        val stream = output ?: throw IllegalStateException("Runtime is not connected")
        stream.write(frame.toString()); stream.newLine(); stream.flush()
    }
    private fun status() = JSONObject().put("method", "runtime.status").put("params",
        JSONObject().put("phase", phase).put("error", failure ?: JSONObject.NULL))
    private fun error(id: String, message: String) = JSONObject().put("jsonrpc", "2.0").put("id", id)
        .put("error", JSONObject().put("code", -32603).put("message", message))
    private fun fail(message: String) { main.post {
        phase = "failed"; failure = message
        pending.entries.forEach { send(it.value, error(it.key, message)) }; pending.clear()
        broadcast(status())
    } }
    private fun broadcast(frame: JSONObject) { clients.toList().forEach { send(it, frame) } }
    private fun send(client: Messenger, frame: JSONObject) {
        try {
            val payload = WirePayload.encode(frame.toString())
            try { client.send(Message.obtain(null, 2).apply { data = payload }) }
            finally { WirePayload.close(payload) }
        }
        catch (_: RemoteException) { clients.remove(client) }
    }
    override fun onDestroy() {
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        output?.close(); workers.shutdownNow()
        super.onDestroy()
    }
}
