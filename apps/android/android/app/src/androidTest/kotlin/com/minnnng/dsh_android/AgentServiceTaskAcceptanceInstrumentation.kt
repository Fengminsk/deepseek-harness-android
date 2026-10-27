package com.minnnng.dsh_android

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.PowerManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicReference

/** One explicitly admitted real-account request through the existing production service, without settings writes. */
class AgentServiceTaskAcceptanceInstrumentation : Instrumentation() {
    private var admitted = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        admitted = arguments?.getString("acceptRealAccountRequest") == "true"
        start()
    }

    override fun onStart() {
        val app = targetContext.applicationContext
        val caseId = UUID.randomUUID().toString()
        val sessionId = "android-account-acceptance-$caseId"
        val requestId = "account-request-$caseId"
        val exportId = UUID.randomUUID().toString()
        val began = SystemClock.elapsedRealtime()
        val beganUptime = SystemClock.uptimeMillis()
        var deadline = began + 300_000L
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        val connected = CompletableFuture<Unit>()
        val ended = AtomicReference<JSONObject?>()
        val completion = AtomicReference<JSONObject?>()
        val asynchronousFailure = AtomicReference<Throwable?>()
        var remote: Messenger? = null
        var bound = false
        var created = false
        var submitted = false
        var exportRequested = false
        var generation: String? = null
        var agentPid: Int? = null
        var success = false
        val cleanup = JSONObject().put("cancelRequested", false).put("taskSettled", false)
            .put("archived", false).put("exportReleased", false).put("disconnected", false)
        val result = JSONObject().put("schema", 1).put("kind", "production-account-task")
            .put("caseId", caseId).put("sessionId", sessionId).put("requestId", requestId)
            .put("submittedCount", 0).put("archived", false)
            .put("markerSha256", AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.marker(caseId).toByteArray()))
        fun demand(value: Boolean, code: String) = AgentServiceTaskEvidence.demand(value, code)
        val diagnosticLock = Any()
        var diagnosticsOpen = true
        var lastStage = "instrumentation-start"
        var progressSequence = 0
        var runtimeObservedAt: Long? = null
        var safeRuntime: JSONObject? = null
        fun observeRuntime(value: JSONObject) = synchronized(diagnosticLock) {
            val phase = value.optString("phase")
            val boot = value.optString("bootStage")
            safeRuntime = JSONObject()
                .put("phase", phase.takeIf { it in setOf("starting", "ready", "failed", "restarting", "maintenance",
                    "maintenance-checking", "maintenance-blocked") } ?: "unknown")
                .put("bootStage", boot.takeIf { it in setOf("service-created", "checking-app-processes", "maintenance",
                    "process-check-blocked", "preparing-assets", "preparing-storage", "recovering-workflows",
                    "starting-node", "ready") } ?: "unknown")
                .put("nodeStarted", value.opt("nodeStarted").takeIf { it is Boolean } ?: JSONObject.NULL)
            runtimeObservedAt = SystemClock.elapsedRealtime() - began
        }
        fun progress(stage: String? = null) = synchronized(diagnosticLock) {
            if (!diagnosticsOpen) return@synchronized
            if (stage != null) lastStage = stage
            val value = JSONObject().put("schema", 1).put("kind", "production-account-task").put("caseId", caseId)
                .put("stage", lastStage).put("lastStage", lastStage).put("pulse", stage == null)
                .put("sequence", ++progressSequence).put("pid", android.os.Process.myPid())
                .put("elapsedMs", SystemClock.elapsedRealtime() - began).put("uptimeMs", SystemClock.uptimeMillis() - beganUptime)
                .put("runtimeObservedAtMs", runtimeObservedAt ?: JSONObject.NULL).put("runtime", safeRuntime ?: JSONObject.NULL)
                .toString()
            demand(value.toByteArray(Charsets.UTF_8).size <= 1024, "PROGRESS_OVERSIZED")
            sendStatus(1, Bundle().apply { putString("progress", value) })
        }
        val diagnosticHandler = Handler(Looper.getMainLooper())
        val diagnosticPulse = object : Runnable {
            override fun run() = synchronized(diagnosticLock) {
                if (!diagnosticsOpen) return@synchronized
                progress()
                diagnosticHandler.postDelayed(this, 5000)
                Unit
            }
        }
        fun state(): JSONObject {
            val value = JSONObject().put("locked", (app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked)
                .put("interactive", (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive)
            demand(value.getBoolean("locked") && !value.getBoolean("interactive"), "DEVICE_INTERACTIVE")
            return value
        }
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                val frame = JSONObject(WirePayload.decode(message.data))
                if (frame.has("id")) pending[frame.getString("id")]?.complete(frame)
                else {
                    val params = frame.optJSONObject("params")
                    if (frame.optString("method") == "runtime.status" && params != null) observeRuntime(params)
                    if (params?.optString("sessionId") == sessionId) {
                        when (frame.optString("method")) {
                            "session.event" -> {
                                val event = params.getJSONObject("event")
                                if (event.getString("type").startsWith("tool/"))
                                    asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("TOOL_INVOKED"))
                                if (event.getString("type") == "turn/end") {
                                    if (!ended.compareAndSet(null, event))
                                        asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("DUPLICATE_TURN_END"))
                                }
                            }
                            "task.completed" -> completion.compareAndSet(null, params)
                            "session.error" -> asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("SESSION_FAILED"))
                        }
                    }
                }
            } catch (_: Throwable) {
                asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("REPLY_INVALID"))
            }
            true
        })
        fun call(method: String, params: JSONObject = JSONObject(), budget: Long = 15_000): JSONObject {
            val remaining = minOf(budget, deadline - SystemClock.elapsedRealtime())
            if (remaining <= 0) throw TimeoutException()
            val id = UUID.randomUUID().toString()
            val reply = CompletableFuture<JSONObject>()
            pending[id] = reply
            try {
                val payload = WirePayload.encode(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", method).put("params", params).toString())
                try { remote!!.send(Message.obtain(null, 2).apply { data = payload; replyTo = replies }) }
                finally { WirePayload.close(payload) }
                val frame = reply.get(remaining, TimeUnit.MILLISECONDS)
                demand(!frame.has("error"), "RPC_FAILED")
                val value = frame.optJSONObject("result") ?: JSONObject().put("value", frame.opt("result") ?: JSONObject.NULL)
                demand(!value.has("_pocket_error"), "DOMAIN_FAILED")
                if (method == "runtime.status") observeRuntime(value)
                return value
            } finally { pending.remove(id) }
        }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    remote = Messenger(binder)
                    remote!!.send(Message.obtain(null, 1).apply { replyTo = replies })
                    progress("connected")
                    connected.complete(Unit)
                } catch (error: Throwable) { connected.completeExceptionally(error) }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("SERVICE_DISCONNECTED"))
            }
        }
        @Suppress("DEPRECATION")
        fun observe(label: String): JSONObject {
            val runtime = call("runtime.status")
            demand(runtime.getString("phase") == "ready" && runtime.getString("generation") == generation,
                "GENERATION_CHANGED")
            val service = (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getRunningServices(128)
                .singleOrNull { it.service.className == "${app.packageName}.AgentService" }
                ?: throw AgentServiceTaskEvidence.Rejected("SERVICE_NOT_RUNNING")
            demand(service.pid > 0 && service.process == "${app.packageName}:agent" && service.foreground,
                "SERVICE_NOT_FOREGROUND")
            if (agentPid == null) agentPid = service.pid
            demand(service.pid == agentPid, "SERVICE_PID_CHANGED")
            state()
            val background = runtime.getJSONObject("background")
            val safe = JSONObject()
            for (key in listOf("keepAwakeWhileWorking", "wakeLockHeld", "fresh")) safe.put(key, background.getBoolean(key))
            for (key in listOf("running", "queued", "waiting", "failed", "backgroundJobs", "packageOperations"))
                safe.put(key, background.opt(key) ?: JSONObject.NULL)
            safe.put("taskState", background.getString("taskState"))
                .put("powerErrorPresent", !background.isNull("powerError"))
                .put("notificationErrorPresent", !background.isNull("notificationError"))
            if (label.isNotEmpty()) result.put("background$label", safe).put("foreground$label", true)
            return safe
        }
        fun ownSettled(): Boolean {
            val active = call("tasks.summary").getJSONArray("active")
            return (0 until active.length()).map { active.getJSONObject(it) }.none {
                it.getString("sessionId") == sessionId && (it.getString("status") in setOf("running", "queued", "waiting") ||
                    it.getInt("queued") > 0 || it.getInt("blockingRequests") > 0)
            }
        }
        fun awaitSettled(limit: Long) {
            val until = minOf(deadline, SystemClock.elapsedRealtime() + limit)
            while (!ownSettled()) {
                if (SystemClock.elapsedRealtime() >= until) throw AgentServiceTaskEvidence.Rejected("TASK_NOT_SETTLED")
                Thread.sleep(100)
            }
            cleanup.put("taskSettled", true)
        }
        fun failure(error: Throwable, field: String) {
            var cause = error
            repeat(5) { cause.cause?.let { if (it !== cause) cause = it } }
            val code = when (cause) {
                is AgentServiceTaskEvidence.Rejected -> (cause as AgentServiceTaskEvidence.Rejected).code
                is TimeoutException -> "DEADLINE_EXCEEDED"
                else -> "EVIDENCE_UNCONFIRMED"
            }
            result.put(field, code)
            result.put("${field}Type", when (cause) {
                is AgentServiceTaskEvidence.Rejected -> "EvidenceRejected"
                is TimeoutException -> "TimeoutException"
                is org.json.JSONException -> "JSONException"
                is java.io.IOException -> "IOException"
                else -> "RuntimeFailure"
            })
        }
        try {
            progress("instrumentation-start")
            diagnosticHandler.postDelayed(diagnosticPulse, 5000)
            demand(admitted, "REAL_ACCOUNT_NOT_ADMITTED")
            result.put("deviceStateBefore", state())
            progress("service-start-requested")
            uiAutomation.adoptShellPermissionIdentity("android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND")
            try { app.startForegroundService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService")) }
            finally { uiAutomation.dropShellPermissionIdentity() }
            progress("service-started")
            progress("bind-requested")
            bound = app.bindService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService"), connection, Context.BIND_AUTO_CREATE)
            demand(bound, "BIND_FAILED")
            progress("bound")
            connected.get(20, TimeUnit.SECONDS)
            val readyBy = began + 120_000
            progress("runtime-ready-wait")
            while (true) {
                val runtime = call("runtime.status", budget = minOf(15_000, readyBy - SystemClock.elapsedRealtime()))
                if (runtime.optString("phase") == "ready") { generation = runtime.getString("generation"); break }
                demand(runtime.optString("phase") != "failed", "RUNTIME_FAILED")
                if (SystemClock.elapsedRealtime() >= readyBy) throw TimeoutException()
                Thread.sleep(500)
            }
            progress("runtime-ready")
            progress("runtime-info")
            val info = call("runtime.info")
            demand(info.getString("platform") == "android" && info.getString("profile") == "android", "PROFILE_MISMATCH")
            progress("background-preflight")
            observe("Before")
            val summary = call("tasks.summary").getJSONObject("summary")
            for (key in listOf("running", "queued", "waiting", "backgroundJobs", "packageOperations"))
                demand(!summary.isNull(key) && summary.getInt(key) == 0, "OTHER_WORK_ACTIVE_OR_UNKNOWN")
            fun catalog() = call("api.call", JSONObject().put("namespace", "session").put("method", "modelCatalog").put("args", JSONObject()))
            progress("catalog-read")
            val model = AgentServiceTaskEvidence.model(catalog())
            result.put("provider", "deepseek-account").put("model", model)
            val address = JSONObject().put("sessionId", sessionId)
            progress("session-ensure")
            val ensured = call("session.ensure", address)
            demand(ensured.getBoolean("created") && ensured.getString("sessionId") == sessionId, "SESSION_NOT_NEW")
            created = true
            progress("session-rename")
            call("library.sessionRename", JSONObject().put("sessionId", sessionId).put("title", "账号任务验收 $caseId"))
            progress("catalog-recheck")
            demand(AgentServiceTaskEvidence.model(catalog()) == model, "DEFAULT_CHANGED")
            progress("ready")
            val turnBy = SystemClock.elapsedRealtime() + 120_000
            submitted = true
            result.put("submittedCount", 1)
            progress("send-requested")
            val accepted = call("session.send", JSONObject().put("sessionId", sessionId).put("requestId", requestId)
                .put("provider", "deepseek-account").put("model", model).put("selectModel", false)
                .put("text", AgentServiceTaskEvidence.prompt(caseId)))
            demand(accepted.getBoolean("accepted"), "SUBMISSION_NOT_ACCEPTED")
            progress("submitted")
            var activeObserved = false
            do {
                asynchronousFailure.get()?.let { throw it }
                val observed = observe("")
                if (observed.getBoolean("fresh") && observed.getInt("running") > 0 &&
                    AgentServiceTaskEvidence.runningOwnTask(call("tasks.summary"), sessionId)) {
                    result.put("backgroundDuring", observed).put("foregroundDuring", true)
                        .put("ownTaskRunningObserved", true)
                    activeObserved = true
                }
                if (ended.get() != null && completion.get() != null) break
                if (SystemClock.elapsedRealtime() >= turnBy) throw TimeoutException()
                Thread.sleep(250)
            } while (true)
            demand(activeObserved, "ACTIVE_BACKGROUND_NOT_OBSERVED")
            demand(ended.get()!!.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed", "TURN_NOT_COMPLETED")
            demand(completion.get()!!.getLong("endSeq") == ended.get()!!.getLong("seq") && completion.get()!!.getInt("turn") == 1,
                "COMPLETION_SIGNAL_MISMATCH")
            awaitSettled(15_000)
            observe("After")
            progress("completed")
            val history = call("session.read", address)
            demand(!history.has("snapshot"), "HISTORY_REQUIRES_PAGING")
            exportRequested = true
            val exported = call("session.export.prepare", JSONObject().put("id", exportId).put("sessionId", sessionId)
                .put("includeDescendants", false))
            demand(exported.getString("id") == exportId && exported.getLong("size") in 1..1024 * 1024, "EXPORT_INVALID")
            val directory = File(app.cacheDir, "pocket-session-exports").canonicalFile
            val file = File(directory, "$exportId.zip")
            demand(file.canonicalFile.parentFile == directory && Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS),
                "EXPORT_PATH_INVALID")
            val durable = Files.newInputStream(file.toPath(), LinkOption.NOFOLLOW_LINKS).use {
                AgentServiceTaskEvidence.readExport(it, sessionId)
            }
            val evidence = AgentServiceTaskEvidence.completed(history.getJSONArray("events"), durable, caseId, requestId, model)
            for (key in evidence.keys()) result.put(key, evidence.get(key))
            demand(evidence.getLong("endSeq") == ended.get()!!.getLong("seq"), "LIVE_END_MISMATCH")
            asynchronousFailure.get()?.let { throw it }
            result.put("generation", generation).put("agentPid", agentPid).put("deviceStateAfter", state())
            progress("durable")
            success = true
        } catch (error: Throwable) { failure(error, "failureCode") }
        finally {
            deadline = minOf(began + 360_000, SystemClock.elapsedRealtime() + 60_000)
            progress("cleanup")
            synchronized(diagnosticLock) {
                diagnosticsOpen = false
                diagnosticHandler.removeCallbacks(diagnosticPulse)
            }
            if (created) {
                try {
                    if (submitted && !cleanup.getBoolean("taskSettled")) {
                        // AppSessions admission ordering prevents a timed-out send from starting after its cancellation.
                        call("session.ensure", JSONObject().put("sessionId", sessionId), 10_000)
                        cleanup.put("cancelRequested", true)
                        call("session.cancel", JSONObject().put("sessionId", sessionId), 10_000)
                    }
                    awaitSettled(15_000)
                    call("library.sessionArchive", JSONObject().put("sessionId", sessionId).put("archived", true), 10_000)
                    cleanup.put("archived", true); result.put("archived", true)
                } catch (error: Throwable) { success = false; failure(error, "cleanupFailureCode") }
            } else cleanup.put("taskSettled", !submitted)
            try {
                if (exportRequested) {
                    val released = call("session.export.release", JSONObject().put("id", exportId), 10_000)
                    demand(released.getBoolean("released"), "EXPORT_RELEASE_UNCONFIRMED")
                }
                cleanup.put("exportReleased", true)
            } catch (error: Throwable) { success = false; failure(error, "exportCleanupFailureCode") }
            try {
                remote?.send(Message.obtain(null, 3).apply { replyTo = replies })
                if (bound) app.unbindService(connection)
                cleanup.put("disconnected", true)
            } catch (error: Throwable) { success = false; failure(error, "disconnectFailureCode") }
            try { result.put("deviceStateAfter", state()) }
            catch (error: Throwable) { success = false; failure(error, "screenFailureCode") }
        }
        result.put("cleanup", cleanup).put("elapsedMs", SystemClock.elapsedRealtime() - began).put("passed", success)
        finish(if (success) Activity.RESULT_OK else Activity.RESULT_CANCELED,
            Bundle().apply { putString("passed", success.toString()); putString("result", result.toString()) })
    }
}
