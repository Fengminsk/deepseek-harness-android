package com.minnnng.dsh_android

import android.Manifest
import android.app.Activity
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
    private var picker: MethodChannel.Result? = null
    private var bound = false
    private var notificationPermission: MethodChannel.Result? = null
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
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            pending.values.forEach { it.error("disconnected", "运行时连接中断", null) }; pending.clear()
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
                "pickDirectory" -> {
                    if (picker != null) result.error("busy", "文件选择器已经打开", null) else {
                        picker = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), 42)
                    }
                }
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
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNavigation()
    }
    private fun deliverNavigation() {
        val sink = events ?: return
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
        if (requestCode != 42) return
        val result = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            result.success(true)
        } catch (exception: Exception) { result.error("permission", exception.message, null) }
    }
    override fun onDestroy() {
        if (bound) {
            try { service?.send(Message.obtain(null, 3).apply { replyTo = replies }) } catch (_: RemoteException) { /* Service already exited. */ }
            unbindService(connection)
        }
        pending.values.forEach { it.error("closed", "界面已关闭", null) }; pending.clear()
        notificationPermission?.error("closed", "界面已关闭", null)
        notificationPermission = null
        super.onDestroy()
    }
}
