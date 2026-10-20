package com.minnnng.dsh_android

import android.Manifest
import android.content.*
import android.os.*
import android.net.Uri
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
    private val transfers by lazy { DocumentTransfers(this) }
    private val exports by lazy { DocumentExports(this) }
    private val attachments by lazy { AttachmentTransfers(this) }
    private var bound = false
    private var notificationPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private var restarting: MethodChannel.Result? = null
    private var restartBinder: IBinder? = null
    private var restartDeath: IBinder.DeathRecipient? = null
    private var restartAwaitingOldConnection = false
    private val restartTimeout = Runnable {
        val result = restarting ?: return@Runnable
        clearRestartObserver()
        restarting = null
        restartAwaitingOldConnection = false
        result.error("restart-timeout", "无法确认旧运行时已退出或新服务已连接，请稍后重试。未启动第二个运行时实例。", null)
    }
    private val pending = mutableMapOf<String, MethodChannel.Result>()
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        val raw = WirePayload.decode(message.data)
        val frame = JSONObject(raw)
        if (frame.has("id")) {
            pending.remove(frame.getString("id"))?.let { result ->
                if (frame.has("error")) result.error("runtime", frame.getJSONObject("error").optString("message"), null)
                else result.success((frame.opt("result") ?: JSONObject.NULL).toString())
            }
        } else events?.success(raw)
        true
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = Messenger(binder)
            service!!.send(Message.obtain(null, 1).apply { replyTo = replies })
            if (restartAwaitingOldConnection) {
                restartAwaitingOldConnection = false
                val result = restarting
                restarting = null
                clearRestartObserver()
                if (result != null) restartRuntime(result)
                return
            }
            if (restartBinder == null) {
                restarting?.success(null)
                restarting = null
                main.removeCallbacks(restartTimeout)
            }
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            pending.values.forEach { it.error("disconnected", "运行时连接中断", null) }; pending.clear()
            if (restarting != null) return
            events?.success(JSONObject().put("method", "runtime.status").put("params",
                JSONObject().put("phase", "failed").put("error", "运行时进程已停止，任务可能已中断")).toString())
        }
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        EventChannel(engine.dartExecutor.binaryMessenger, "dsh/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink; deliverNavigation() }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(engine.dartExecutor.binaryMessenger, "dsh/runtime").setMethodCallHandler { call, result ->
            when (call.method) {
                "app.metadata" -> result.success(AuthTabs.metadata(this))
                "attachment.pick" -> attachments.pick(result)
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
                "notifications.status" -> result.success(ApprovalNotifications.status(this).toString())
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
                    val intent = Intent(this, AgentService::class.java)
                    startForegroundService(intent)
                    if (!bound) bound = bindService(intent, connection, Context.BIND_AUTO_CREATE)
                    result.success(null)
                }
                "call" -> {
                    val peer = service
                    if (peer == null) result.error("starting", "正在连接本地运行时", null) else {
                        val id = UUID.randomUUID().toString()
                        val frame = JSONObject(call.arguments as String).put("jsonrpc", "2.0").put("id", id)
                        pending[id] = result
                        try {
                            val payload = WirePayload.encode(frame.toString())
                            try { peer.send(Message.obtain(null, 2).apply { replyTo = replies; data = payload }) }
                            finally { WirePayload.close(payload) }
                        } catch (exception: Exception) { pending.remove(id); result.error("disconnected", exception.message, null) }
                    }
                }
                "pickDirectory" -> transfers.pickDirectory(result)
                "pickDocument" -> transfers.pickDocument(result)
                "openUrl" -> {
                    val uri = Uri.parse(call.arguments as String)
                    if (uri.scheme != "http" && uri.scheme != "https") result.error("url", "不支持的链接", null) else {
                        startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun clearRestartObserver() {
        val binder = restartBinder
        val death = restartDeath
        if (binder != null && death != null && binder.isBinderAlive) binder.unlinkToDeath(death, 0)
        restartBinder = null
        restartDeath = null
        main.removeCallbacks(restartTimeout)
    }
    private fun restartRuntime(result: MethodChannel.Result) {
        if (restarting != null) { result.error("busy", "正在重启 Agent 服务", null); return }
        restarting = result
        main.postDelayed(restartTimeout, 10000)
        val peer = service
        if (peer == null) {
            restartAwaitingOldConnection = true
            startReplacement()
            return
        }
        val binder = peer.binder
        val death = IBinder.DeathRecipient { main.post {
            if (restarting == null || restartBinder !== binder) return@post
            clearRestartObserver()
            main.postDelayed(restartTimeout, 10000)
            startReplacement()
        } }
        restartBinder = binder
        restartDeath = death
        try {
            binder.linkToDeath(death, 0)
            peer.send(Message.obtain(null, 6).apply { replyTo = replies })
        } catch (failure: RemoteException) {
            if (!binder.isBinderAlive) {
                clearRestartObserver()
                main.postDelayed(restartTimeout, 10000)
                startReplacement()
            } else {
                clearRestartObserver()
                restarting = null
                result.error("restart-failed", "未能请求旧服务退出，请稍后重试", null)
            }
        }
    }
    private fun startReplacement() {
        if (bound) {
            unbindService(connection)
            bound = false
        }
        service = null
        val intent = Intent(this, AgentService::class.java)
        try {
            startForegroundService(intent)
            bound = bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Cannot bind replacement Agent service" }
        } catch (failure: Exception) {
            val result = restarting
            restarting = null
            restartAwaitingOldConnection = false
            clearRestartObserver()
            result?.error("restart-failed", "Agent 服务重新启动失败：${failure.message}", null)
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
        try { service?.send(Message.obtain(null, 5).apply { replyTo = replies }) }
        catch (_: RemoteException) { /* Service disconnect is reported by ServiceConnection. */ }
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
        if (attachments.onActivityResult(requestCode, resultCode, data)) return
        transfers.onActivityResult(requestCode, resultCode, data)
    }
    override fun onDestroy() {
        if (bound) {
            try { service?.send(Message.obtain(null, 3).apply { replyTo = replies }) } catch (_: RemoteException) { /* Service already exited. */ }
            unbindService(connection)
        }
        pending.values.forEach { it.error("closed", "界面已关闭", null) }; pending.clear()
        notificationPermission?.error("closed", "界面已关闭", null)
        notificationPermission = null
        transfers.close()
        exports.close()
        attachments.close()
        restarting?.error("closed", "重启期间界面已关闭，请重新打开 App 查看运行时状态", null)
        restarting = null
        clearRestartObserver()
        super.onDestroy()
    }
}
