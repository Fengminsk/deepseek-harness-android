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
import android.os.SystemClock
import org.json.JSONObject
import org.json.JSONArray
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

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
        val startedAt = SystemClock.elapsedRealtime()
        val startedUptime = SystemClock.uptimeMillis()
        val progressLock = Any()
        val diagnosticsClosed = AtomicBoolean(false)
        var progressStage = "instrumentation-start"
        var progressSequence = 0
        var runtimeSummary: JSONObject? = null
        var runtimeObservedAt: Long? = null
        val lastProgress = AtomicReference<JSONObject?>()
        fun progress(stage: String? = null, runtime: JSONObject? = null) = synchronized(progressLock) {
            if (diagnosticsClosed.get()) return@synchronized
            if (stage != null) progressStage = stage
            if (runtime != null) {
                val background = runtime.getJSONObject("background")
                val summary = JSONObject()
                for (name in listOf("keepAwakeWhileWorking", "wakeLockHeld", "fresh"))
                    summary.put(name, background.getBoolean(name))
                for (name in listOf("running", "queued", "waiting", "failed"))
                    summary.put(name, background.getInt(name))
                for (name in listOf("backgroundJobs", "packageOperations"))
                    summary.put(name, if (background.isNull(name)) JSONObject.NULL else background.getInt(name))
                summary.put("taskState", background.getString("taskState"))
                    .put("powerErrorPresent", !background.isNull("powerError"))
                    .put("notificationErrorPresent", !background.isNull("notificationError"))
                runtimeSummary = JSONObject().put("phase", runtime.getString("phase"))
                    .put("bootStage", runtime.getString("bootStage")).put("nodeStarted", runtime.getBoolean("nodeStarted"))
                    .put("background", summary)
                runtimeObservedAt = SystemClock.elapsedRealtime() - startedAt
            }
            val value = JSONObject().put("schema", 1).put("token", token).put("stage", progressStage)
                .put("sequence", ++progressSequence).put("pid", android.os.Process.myPid())
                .put("elapsedMs", SystemClock.elapsedRealtime() - startedAt)
                .put("uptimeMs", SystemClock.uptimeMillis() - startedUptime)
                .put("runtimeObservedAtMs", runtimeObservedAt ?: JSONObject.NULL)
                .put("runtime", runtimeSummary ?: JSONObject.NULL)
            lastProgress.set(value)
            sendStatus(4, Bundle().apply { putString("progress", value.toString()) })
        }
        val statusProbeId = "recovery-status-$token"
        fun observeRuntime(state: JSONObject) {
            progress(runtime = state)
            if (state.optString("phase") == "ready") ready.complete(state)
            else if (state.optString("phase") == "failed") ready.completeExceptionally(IllegalStateException("Agent runtime failed to start"))
        }
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                val frame = JSONObject(WirePayload.decode(message.data))
                if (frame.optString("id") == statusProbeId) {
                    if (frame.has("result")) observeRuntime(frame.getJSONObject("result"))
                } else if (frame.has("id")) pending[frame.getString("id")]?.complete(frame)
                else if (frame.optString("method") == "runtime.status") {
                    observeRuntime(frame.getJSONObject("params"))
                }
            } catch (failure: Throwable) { completed.completeExceptionally(failure) }
            true
        })
        val probeHandler = Handler(Looper.getMainLooper())
        val probing = AtomicBoolean(false)
        val probe = object : Runnable {
            override fun run() = synchronized(progressLock) {
                if (!probing.get()) return@synchronized
                try {
                    progress()
                    val payload = WirePayload.encode(JSONObject().put("jsonrpc", "2.0").put("id", statusProbeId)
                        .put("method", "runtime.status").put("params", JSONObject()).toString())
                    try { remote!!.send(Message.obtain(null, 2).apply { data = payload; replyTo = replies }) }
                    finally { WirePayload.close(payload) }
                } catch (failure: Throwable) { completed.completeExceptionally(failure) }
                if (probing.get()) probeHandler.postDelayed(this, 5000)
            }
        }
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
                try {
                    service.send(Message.obtain(null, 1).apply { replyTo = replies })
                    progress("connected")
                    connected.complete(service)
                }
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
        val lastObservation = AtomicReference<JSONObject?>()
        try {
            progress("instrumentation-start")
            progress("service-start-requested")
            uiAutomation.adoptShellPermissionIdentity("android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND")
            try { app.startForegroundService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService")) }
            finally { uiAutomation.dropShellPermissionIdentity() }
            progress("service-started")
            progress("bind-requested")
            bound = app.bindService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService"), connection, Context.BIND_AUTO_CREATE)
            check(bound)
            progress("bound")
            connected.get(20, TimeUnit.SECONDS)
            probing.set(true)
            probeHandler.post(probe)
            progress("runtime-ready-wait")
            val startup = ready.get(120, TimeUnit.SECONDS)
            progress("runtime-ready")
            val generation = startup.getString("generation")
            val sessionId = "android-recovery-$token"
            val address = JSONObject().put("sessionId", sessionId)
            progress("session-ensure")
            check(call("session.ensure", address).getBoolean("created")) { "Recovery fixture Session already exists" }
            progress("session-ensured")
            progress("session-rename")
            call("library.sessionRename", JSONObject().put("sessionId", sessionId).put("title", "设备恢复验收 $token"))
            progress("session-renamed")
            progress("session-read")
            val baseline = call("session.read", address).getJSONArray("events")
            check(baseline.length() > 0) { "Recovery fixture has no durable Session event" }
            progress("session-read-complete")
            fun digest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            val expected = digest(baseline.toString())
            val stages = AtomicInteger(0)
            val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            fun networkEvidence(): JSONObject {
                val active = connectivity.activeNetwork
                val networks = connectivity.allNetworks.toMutableList()
                if (active != null && active !in networks) networks.add(active)
                check(networks.size <= 64 && networks.distinct().size == networks.size) { "Network inventory is ambiguous" }
                val facts = ArrayList<RecoveryNetworkEvidence.Fact>()
                val details = JSONArray()
                for (network in networks) {
                    val capabilities = connectivity.getNetworkCapabilities(network)
                    val internet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                    val validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                    val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                    // NetworkCapabilities.getTransportTypes is hidden; enumerate SDK-known codes
                    // through the public predicate. Internet classification never filters by transport.
                    val transports = (0..NetworkCapabilities.TRANSPORT_SATELLITE).filter { capabilities?.hasTransport(it) == true }
                    facts.add(RecoveryNetworkEvidence.Fact(capabilities != null, internet, validated, vpn))
                    details.put(JSONObject().put("handle", network.networkHandle.toString())
                        .put("capabilitiesKnown", capabilities != null).put("internet", internet)
                        .put("validated", validated).put("vpn", vpn).put("appDefault", network == active)
                        .put("notSuspended", capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED) == true)
                        .put("transportTypes", JSONArray(transports)))
                }
                val counts = RecoveryNetworkEvidence.classify(facts.toTypedArray())
                return JSONObject().put("schema", 2)
                    .put("appDefaultNetworkHandle", active?.networkHandle?.toString() ?: JSONObject.NULL)
                    .put("networks", details).put("validatedNetworks", counts.validatedNetworks)
                    .put("validatedInternetNetworks", counts.validatedInternetNetworks)
                    .put("validatedVpnInternetNetworks", counts.validatedVpnInternetNetworks)
                    .put("usableUnderlyingInternetNetworks", counts.usableUnderlyingInternetNetworks)
                    .put("unvalidatedUnderlyingInternetNetworks", counts.unvalidatedUnderlyingInternetNetworks)
                    .put("unknownCapabilityNetworks", counts.unknownCapabilityNetworks)
            }
            fun checkpoint(stage: String): JSONObject {
                progress("checkpoint-$stage")
                val state = call("runtime.status")
                check(state.getString("phase") == "ready" && state.getString("generation") == generation)
                check(call("runtime.info").getString("platform") == "android")
                val history = call("session.read", address).getJSONArray("events")
                check(history.length() == baseline.length() && digest(history.toString()) == expected) { "Dedicated Session changed during connectivity transition" }
                val networks = networkEvidence()
                val interactive = (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
                val locked = (app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
                val result = JSONObject().put("stage", stage).put("generation", generation).put("sessionId", sessionId)
                    .put("eventCount", history.length()).put("eventsSha256", expected).put("networkEvidence", networks)
                    .put("interactive", interactive).put("locked", locked)
                lastObservation.set(result)
                if (stage == "offline") check(networks.getInt("unknownCapabilityNetworks") == 0 &&
                    networks.getInt("usableUnderlyingInternetNetworks") == 0 &&
                    networks.getInt("unvalidatedUnderlyingInternetNetworks") == 0 && !interactive && locked) {
                    "Offline checkpoint requires a locked screen, known capabilities and no underlying INTERNET network, validated or otherwise; evidence=$networks"
                }
                if (stage == "restored") check(networks.getInt("unknownCapabilityNetworks") == 0 &&
                    networks.getInt("usableUnderlyingInternetNetworks") > 0) { "Restored checkpoint lacks usable underlying internet; evidence=$networks" }
                progress("checkpoint-$stage-complete")
                return result
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
                                progress("session-archive")
                                call("library.sessionArchive", JSONObject().put("sessionId", sessionId).put("archived", true))
                                progress("session-archived")
                                completed.complete(result)
                            } else error("Unknown recovery stage")
                        } catch (failure: Throwable) { completed.completeExceptionally(failure) }
                    }
                }
            }
            app.registerReceiver(receiver, IntentFilter("${app.packageName}.acceptance.$token"),
                "android.permission.DUMP", Handler(Looper.getMainLooper()), Context.RECEIVER_EXPORTED)
            registered = true
            progress("ready")
            sendStatus(1, Bundle().apply { putString("ready", JSONObject().put("token", token).put("generation", generation)
                .put("sessionId", sessionId).put("eventsSha256", expected).put("eventCount", baseline.length()).toString()) })
            report.putString("result", completed.get(180, TimeUnit.SECONDS).toString())
            success = true
        } catch (failure: Throwable) {
            report.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}")
            val causes = JSONArray()
            var cause: Throwable? = failure
            repeat(8) {
                val current = cause ?: return@repeat
                causes.put(JSONObject().put("type", current.javaClass.simpleName).put("message", current.message))
                cause = current.cause?.takeUnless { it === current }
            }
            report.putString("failureCauses", causes.toString())
            lastObservation.get()?.let { report.putString("lastObservation", it.toString()) }
        }
        finally {
            synchronized(progressLock) {
                diagnosticsClosed.set(true)
                probing.set(false)
                probeHandler.removeCallbacks(probe)
            }
            if (registered) app.unregisterReceiver(receiver)
            try { remote?.send(Message.obtain(null, 3).apply { replyTo = replies }) } catch (_: Throwable) {}
            if (bound) app.unbindService(connection)
            work.shutdownNow()
        }
        lastProgress.get()?.let { report.putString("lastProgress", it.toString()) }
        report.putString("passed", success.toString())
        finish(if (success) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
