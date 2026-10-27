package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.PowerManager
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Observes the real started AgentService and a dedicated, credential-free Session.
 * The host owns temporary device connectivity/display changes and restores them.
 * This proves service/Session availability, not a paid model request retry.
 */
class AgentServiceRecoveryInstrumentation : Instrumentation() {
    private lateinit var token: String
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        token = arguments?.getString("token") ?: error("Missing recovery token")
        require(token.matches(Regex("[0-9a-f]{32}")))
        start()
    }

    override fun onStart() {
        val app = targetContext.applicationContext
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        val connected = CompletableFuture<Messenger>()
        val ready = CompletableFuture<JSONObject>()
        val completed = CompletableFuture<JSONObject>()
        val work = Executors.newSingleThreadExecutor()
        var remote: Messenger? = null
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                val frame = JSONObject(WirePayload.decode(message.data))
                if (frame.has("id")) pending[frame.getString("id")]?.complete(frame)
                else if (frame.optString("method") == "runtime.status") {
                    val state = frame.getJSONObject("params")
                    if (state.optString("phase") == "ready") ready.complete(state)
                    else if (state.optString("phase") == "failed") ready.completeExceptionally(IllegalStateException("Agent runtime failed to start"))
                }
            } catch (failure: Throwable) { completed.completeExceptionally(failure) }
            true
        })
        fun call(method: String, params: JSONObject = JSONObject()): JSONObject {
            val id = UUID.randomUUID().toString()
            val response = CompletableFuture<JSONObject>()
            pending[id] = response
            try {
                val payload = WirePayload.encode(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", method).put("params", params).toString())
                try { remote!!.send(Message.obtain(null, 2).apply { data = payload; replyTo = replies }) }
                finally { WirePayload.close(payload) }
                val frame = response.get(30, TimeUnit.SECONDS)
                check(!frame.has("error")) { "Recovery RPC failed: $method" }
                val result = frame.optJSONObject("result") ?: JSONObject().put("value", frame.opt("result") ?: JSONObject.NULL)
                check(!result.has("_pocket_error")) { "Recovery domain call failed: $method" }
                return result
            } finally { pending.remove(id) }
        }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val service = Messenger(binder)
                remote = service
                try { service.send(Message.obtain(null, 1).apply { replyTo = replies }); connected.complete(service) }
                catch (failure: Throwable) { connected.completeExceptionally(failure) }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                completed.completeExceptionally(IllegalStateException("Production AgentService disconnected during recovery acceptance"))
            }
        }
        var registered = false
        var bound = false
        val report = Bundle()
        var receiver: BroadcastReceiver? = null
        var success = false
        try {
            uiAutomation.adoptShellPermissionIdentity("android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND")
            try { app.startForegroundService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService")) }
            finally { uiAutomation.dropShellPermissionIdentity() }
            bound = app.bindService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService"), connection, Context.BIND_AUTO_CREATE)
            check(bound)
            connected.get(20, TimeUnit.SECONDS)
            val startup = ready.get(120, TimeUnit.SECONDS)
            val generation = startup.getString("generation")
            val sessionId = "android-recovery-$token"
            val address = JSONObject().put("sessionId", sessionId)
            check(call("session.ensure", address).getBoolean("created")) { "Recovery fixture Session already exists" }
            call("library.sessionRename", JSONObject().put("sessionId", sessionId).put("title", "设备恢复验收 $token"))
            val baseline = call("session.read", address).getJSONArray("events")
            check(baseline.length() > 0) { "Recovery fixture has no durable Session event" }
            fun digest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            val expected = digest(baseline.toString())
            val stages = AtomicInteger(0)
            val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            fun checkpoint(stage: String): JSONObject {
                val state = call("runtime.status")
                check(state.getString("phase") == "ready" && state.getString("generation") == generation)
                check(call("runtime.info").getString("platform") == "android")
                val history = call("session.read", address).getJSONArray("events")
                check(history.length() == baseline.length() && digest(history.toString()) == expected) { "Dedicated Session changed during connectivity transition" }
                val validated = connectivity.allNetworks.count {
                    connectivity.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                }
                val interactive = (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
                val locked = (app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
                if (stage == "offline") check(validated == 0 && !interactive && locked) { "Offline checkpoint requires a locked screen and no validated network" }
                if (stage == "restored") check(validated > 0) { "Restored checkpoint has no validated network" }
                return JSONObject().put("stage", stage).put("generation", generation).put("sessionId", sessionId)
                    .put("eventCount", history.length()).put("eventsSha256", expected).put("validatedNetworks", validated)
                    .put("interactive", interactive).put("locked", locked)
            }
            receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val stage = intent.getStringExtra("stage")
                    work.execute {
                        try {
                            if (stage == "observe") {
                                sendStatus(3, Bundle().apply { putString("observation", checkpoint("observe").toString()) })
                            } else if (stage == "offline") {
                                check(stages.compareAndSet(0, 1))
                                val result = checkpoint("offline")
                                sendStatus(2, Bundle().apply { putString("checkpoint", result.toString()) })
                            } else if (stage == "restored") {
                                check(stages.compareAndSet(1, 2))
                                val result = checkpoint("restored")
                                call("library.sessionArchive", JSONObject().put("sessionId", sessionId).put("archived", true))
                                completed.complete(result)
                            } else error("Unknown recovery stage")
                        } catch (failure: Throwable) { completed.completeExceptionally(failure) }
                    }
                }
            }
            app.registerReceiver(receiver, IntentFilter("${app.packageName}.acceptance.$token"),
                "android.permission.DUMP", Handler(Looper.getMainLooper()), Context.RECEIVER_EXPORTED)
            registered = true
            sendStatus(1, Bundle().apply { putString("ready", JSONObject().put("token", token).put("generation", generation)
                .put("sessionId", sessionId).put("eventsSha256", expected).put("eventCount", baseline.length()).toString()) })
            report.putString("result", completed.get(180, TimeUnit.SECONDS).toString())
            success = true
        } catch (failure: Throwable) { report.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}") }
        finally {
            if (registered) app.unregisterReceiver(receiver)
            try { remote?.send(Message.obtain(null, 3).apply { replyTo = replies }) } catch (_: Throwable) {}
            if (bound) app.unbindService(connection)
            work.shutdownNow()
        }
        report.putString("passed", success.toString())
        finish(if (success) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
