package com.minnnng.dsh_android

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.Build
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
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** One explicitly admitted real-account request through the existing production service, without settings writes. */
class AgentServiceTaskAcceptanceInstrumentation : Instrumentation() {
    private var admitted = false
    private var exercise = "echo"
    private var token: String? = null
    private var cleanupCaseId: String? = null
    private var diagnosticCaseId: String? = null
    private var originalExercise: String? = null
    private var completionNoticeOption = "false"
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        admitted = arguments?.getString("acceptRealAccountRequest") == "true"
        exercise = arguments?.getString("exercise") ?: "echo"
        token = arguments?.getString("token")
        cleanupCaseId = arguments?.getString("cleanupCaseId")
        diagnosticCaseId = arguments?.getString("diagnosticCaseId")
        originalExercise = arguments?.getString("originalExercise")
        completionNoticeOption = arguments?.getString("requireCompletionNotice") ?: "false"
        start()
    }

    override fun onStart() {
        val app = targetContext.applicationContext
        val cleanupOnly = exercise == "workflow-cleanup"
        val diagnosticOnly = exercise == "workflow-diagnose"
        val previousCaseId = if (diagnosticOnly) diagnosticCaseId else cleanupCaseId
        val caseId = if ((cleanupOnly || diagnosticOnly) && AgentServiceProgrammaticEvidence.validCaseId(previousCaseId)) previousCaseId!! else UUID.randomUUID().toString()
        val sessionId = "android-account-acceptance-$caseId"
        val requestId = "account-request-$caseId"
        val exportId = UUID.randomUUID().toString()
        val began = SystemClock.elapsedRealtime()
        val beganUptime = SystemClock.uptimeMillis()
        var deadline = began + 300_000L
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        val connected = CompletableFuture<Unit>()
        val ended = AtomicReference<JSONObject?>()
        val sessionErrorAt = AtomicLong(0)
        val completion = AtomicReference<JSONObject?>()
        val toolCall = AtomicReference<JSONObject?>()
        val toolResult = AtomicReference<JSONObject?>()
        val radio = exercise == "radio-linux"
        val programmatic = AgentServiceProgrammaticEvidence.supported(exercise)
        val requireCompletionNotice = completionNoticeOption == "true"
        val noticeTag = "pocket-completed:$sessionId"
        val notificationManager = app.getSystemService(NotificationManager::class.java)
        val stages = ConcurrentLinkedQueue<String>()
        var receiver: BroadcastReceiver? = null
        var receiverRegistered = false
        var radioReady = false
        var offlineAt: Long? = null
        var radioRestored = false
        val asynchronousFailure = AtomicReference<Throwable?>()
        var remote: Messenger? = null
        var bound = false
        var created = false
        var submitted = false
        val requestedExports = LinkedHashSet<String>()
        var ownedChildId: String? = null
        var generation: String? = null
        var agentPid: Int? = null
        var success = false
        val cleanup = JSONObject().put("cancelRequested", false).put("taskSettled", false)
            .put("archived", false).put("exportReleased", false).put("disconnected", false)
        val result = JSONObject().put("schema", 1).put("kind", if (diagnosticOnly) "production-account-task-diagnostic" else if (cleanupOnly) "production-account-task-cleanup" else "production-account-task")
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
                .apply { if (radio) put("token", token?.takeIf { it.matches(Regex("[0-9a-f]{32}")) } ?: JSONObject.NULL) }
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
                                if (event.getString("type").startsWith("tool/")) {
                                    if (radio && event.getString("type") == "tool/call") {
                                        AgentServiceTaskEvidence.radioCall(event, caseId)
                                        demand(toolCall.compareAndSet(null, event), "DUPLICATE_TOOL_CALL")
                                    } else if (programmatic && event.getString("type") == "tool/call") {
                                        AgentServiceProgrammaticEvidence.call(event, caseId, exercise)
                                        demand(toolCall.compareAndSet(null, event), "DUPLICATE_TOOL_CALL")
                                    } else if ((radio || programmatic) && event.getString("type") == "tool/result") {
                                        demand(toolResult.compareAndSet(null, event), "DUPLICATE_TOOL_RESULT")
                                    } else if (exercise == "ptc" && event.getString("type") in setOf("tool/ptc-dispatch-start", "tool/ptc-dispatch")) {
                                        // Exact callback identity and count are checked against the flushed parent log.
                                    } else asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("TOOL_INVOKED"))
                                }
                                if (event.getString("type") == "turn/end") {
                                    if (!ended.compareAndSet(null, event))
                                        asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("DUPLICATE_TURN_END"))
                                    val reason = event.getJSONObject("data").getJSONObject("reason")
                                    if (reason.getString("kind") == "error") sessionErrorAt.compareAndSet(0, SystemClock.elapsedRealtime())
                                }
                            }
                            "task.completed" -> completion.compareAndSet(null, params)
                            // The durable turn/end reason carries the bounded failure code; the loop classifies it.
                            "session.error" -> sessionErrorAt.compareAndSet(0, SystemClock.elapsedRealtime())
                        }
                    }
                }
            } catch (error: Throwable) {
                asynchronousFailure.compareAndSet(null, if (error is AgentServiceTaskEvidence.Rejected) error
                    else AgentServiceTaskEvidence.Rejected("REPLY_INVALID"))
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
        fun exportOwnedSession(ownedSession: String, id: String, onHeader: (JSONObject) -> Unit = {}): JSONArray {
            requestedExports.add(id)
            val exported = call("session.export.prepare", JSONObject().put("id", id).put("sessionId", ownedSession)
                .put("includeDescendants", false))
            demand(exported.getString("id") == id && exported.getLong("size") in 1..1024 * 1024, "EXPORT_INVALID")
            val directory = File(app.cacheDir, "pocket-session-exports").canonicalFile
            val file = File(directory, "$id.zip")
            demand(file.canonicalFile.parentFile == directory && Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS), "EXPORT_PATH_INVALID")
            return Files.newInputStream(file.toPath(), LinkOption.NOFOLLOW_LINKS).use {
                AgentServiceTaskEvidence.readExport(it, ownedSession, onHeader)
            }
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
        fun networkEvidence(): JSONObject {
            val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val active = connectivity.activeNetwork
            val networks = connectivity.allNetworks.toMutableList()
            if (active != null && active !in networks) networks.add(active)
            demand(networks.size <= 64 && networks.distinct().size == networks.size, "NETWORK_INVENTORY_INVALID")
            val facts = ArrayList<RecoveryNetworkEvidence.Fact>()
            val details = JSONArray()
            for (network in networks) {
                val capabilities = connectivity.getNetworkCapabilities(network)
                val internet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                val validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                val transports = (0..NetworkCapabilities.TRANSPORT_SATELLITE).filter { capabilities?.hasTransport(it) == true }
                facts.add(RecoveryNetworkEvidence.Fact(capabilities != null, internet, validated, vpn))
                details.put(JSONObject().put("handle", network.networkHandle.toString()).put("capabilitiesKnown", capabilities != null)
                    .put("internet", internet).put("validated", validated).put("vpn", vpn).put("appDefault", network == active)
                    .put("notSuspended", capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED) == true)
                    .put("transportTypes", JSONArray(transports)))
            }
            val counts = RecoveryNetworkEvidence.classify(facts.toTypedArray())
            return JSONObject().put("schema", 2).put("appDefaultNetworkHandle", active?.networkHandle?.toString() ?: JSONObject.NULL)
                .put("networks", details).put("validatedNetworks", counts.validatedNetworks)
                .put("validatedInternetNetworks", counts.validatedInternetNetworks).put("validatedVpnInternetNetworks", counts.validatedVpnInternetNetworks)
                .put("usableUnderlyingInternetNetworks", counts.usableUnderlyingInternetNetworks)
                .put("unvalidatedUnderlyingInternetNetworks", counts.unvalidatedUnderlyingInternetNetworks)
                .put("unknownCapabilityNetworks", counts.unknownCapabilityNetworks)
        }
        fun checkpoint(stage: String): JSONObject {
            val callEvent = toolCall.get() ?: throw AgentServiceTaskEvidence.Rejected("RADIO_CALL_MISSING")
            val facts = AgentServiceTaskEvidence.radioCall(callEvent, caseId)
            val background = observe("")
            demand(AgentServiceTaskEvidence.runningOwnTask(call("tasks.summary"), sessionId), "RADIO_TASK_NOT_RUNNING")
            demand(background.getBoolean("fresh") && background.getInt("running") > 0 && background.getBoolean("wakeLockHeld"),
                "RADIO_BACKGROUND_NOT_ACTIVE")
            val networks = networkEvidence()
            demand(networks.getInt("unknownCapabilityNetworks") == 0, "NETWORK_UNKNOWN")
            demand(toolResult.get() == null, "RADIO_TOOL_FINISHED_EARLY")
            if (stage == "offline") demand(networks.getInt("usableUnderlyingInternetNetworks") == 0 &&
                networks.getInt("unvalidatedUnderlyingInternetNetworks") == 0, "NETWORK_NOT_OFFLINE")
            if (stage in setOf("ready", "restored")) demand(networks.getInt("usableUnderlyingInternetNetworks") > 0, "NETWORK_NOT_RESTORED")
            return facts.put("schema", 1).put("token", token).put("caseId", caseId).put("sessionId", sessionId)
                .put("generation", generation).put("agentPid", agentPid).put("stage", stage)
                .put("locked", true).put("interactive", false).put("networkEvidence", networks)
                .put("ownTaskRunning", true).put("toolPending", true).put("background", background)
                .put("elapsedMs", SystemClock.elapsedRealtime() - began)
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
            if (cause is AgentServiceTaskEvidence.Rejected) (cause as AgentServiceTaskEvidence.Rejected).diagnostic?.let {
                result.put("${field}Diagnostic", it)
            }
            result.put("${field}Type", when (cause) {
                is AgentServiceTaskEvidence.Rejected -> "EvidenceRejected"
                is TimeoutException -> "TimeoutException"
                is org.json.JSONException -> "JSONException"
                is java.io.IOException -> "IOException"
                else -> "RuntimeFailure"
            })
        }
        fun noticePreflight() {
            demand((Build.VERSION.SDK_INT < 33 || app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED) && notificationManager.areNotificationsEnabled(), "NOTICE_PERMISSION_UNAVAILABLE")
            val channel = notificationManager.getNotificationChannel("task-completed")
            demand(channel != null && channel.importance != NotificationManager.IMPORTANCE_NONE, "NOTICE_CHANNEL_UNAVAILABLE")
            demand(notificationManager.activeNotifications.none { it.tag == noticeTag && it.id == 3 }, "NOTICE_ALREADY_PRESENT")
        }
        fun observeCompletionNotice(): JSONObject {
            val until = minOf(deadline, SystemClock.elapsedRealtime() + 8_000)
            while (true) {
                state()
                val matches = notificationManager.activeNotifications.filter { it.tag == noticeTag && it.id == 3 }
                demand(matches.size <= 1, "NOTICE_IDENTITY_MISMATCH")
                if (matches.size == 1) {
                    val posted = matches.single()
                    val notice = posted.notification
                    val intent = notice.contentIntent
                    return AgentServiceTaskEvidence.completionNotice(JSONObject().put("matchingCount", matches.size)
                        .put("tag", posted.tag).put("notificationId", posted.id).put("packageMatches", posted.packageName == app.packageName)
                        .put("preview", notice.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: "")
                        .put("channelId", notice.channelId).put("visibilityPrivate", notice.visibility == Notification.VISIBILITY_PRIVATE)
                        .put("autoCancel", notice.flags and Notification.FLAG_AUTO_CANCEL != 0).put("contentIntentPresent", intent != null)
                        .put("contentIntentCreatorMatches", intent != null && intent.creatorPackage == app.packageName &&
                            intent.creatorUid == app.applicationInfo.uid), caseId)
                }
                if (SystemClock.elapsedRealtime() >= until) throw AgentServiceTaskEvidence.Rejected("NOTICE_NOT_OBSERVED")
                Thread.sleep(100)
            }
        }
        try {
            progress("instrumentation-start")
            diagnosticHandler.postDelayed(diagnosticPulse, 5000)
            if (diagnosticOnly) demand(!admitted && diagnosticCaseId == caseId && cleanupCaseId == null && token == null &&
                !requireCompletionNotice && originalExercise in setOf("workflow", "workflow-linux"), "DIAGNOSTIC_ADMISSION_INVALID")
            else {
                demand(diagnosticCaseId == null && originalExercise == null, "DIAGNOSTIC_OPTION_INVALID")
                if (cleanupOnly) demand(!admitted && cleanupCaseId == caseId && token == null && !requireCompletionNotice, "CLEANUP_ADMISSION_INVALID")
                else demand(admitted && cleanupCaseId == null, "REAL_ACCOUNT_NOT_ADMITTED")
            }
            demand(completionNoticeOption in setOf("true", "false"), "NOTICE_OPTION_INVALID")
            if (requireCompletionNotice) result.put("requireCompletionNotice", true)
            demand((exercise in setOf("echo", "radio-linux", "workflow-cleanup", "workflow-diagnose") || programmatic) && (!radio || token?.matches(Regex("[0-9a-f]{32}")) == true), "EXERCISE_INVALID")
            demand(!programmatic || !requireCompletionNotice, "PROGRAMMATIC_NOTICE_UNSUPPORTED")
            if (radio || programmatic || cleanupOnly || diagnosticOnly) result.put("exercise", exercise)
            if (radio) result.put("token", token)
            if (AgentServiceProgrammaticEvidence.workflow(exercise) || cleanupOnly) cleanup.put("childArchived", false)
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
            if (exercise == "workflow-linux") result.put("appUid", info.getInt("uid"))
            progress("background-preflight")
            observe("Before")
            val summary = call("tasks.summary").getJSONObject("summary")
            for (key in listOf("running", "queued", "waiting", "backgroundJobs", "packageOperations"))
                demand(!summary.isNull(key) && summary.getInt(key) == 0, "OTHER_WORK_ACTIVE_OR_UNKNOWN")
            run task@ {
            if (diagnosticOnly) {
                progress("diagnostic-history-read")
                result.put("diagnostic", AgentServiceProgrammaticDiagnostic.inspect(caseId, originalExercise!!,
                    { method, params -> call(method, params) }, { id ->
                        val document = JSONObject()
                        val events = exportOwnedSession(id, UUID.randomUUID().toString()) { document.put("header", it) }
                        document.put("events", events)
                    }))
                observe("After")
                result.put("generation", generation).put("agentPid", agentPid).put("deviceStateAfter", state())
                success = true
                return@task
            }
            if (cleanupOnly) {
                progress("cleanup-history-read")
                val evidence = AgentServiceProgrammaticEvidence.cleanupWorkflow(caseId,
                    { method, params -> call(method, params) },
                    { id -> exportOwnedSession(id, UUID.randomUUID().toString()) })
                for (key in evidence.keys()) result.put(key, evidence.get(key))
                cleanup.put("childArchived", true)
                observe("After")
                result.put("generation", generation).put("agentPid", agentPid).put("deviceStateAfter", state())
                success = true
                return@task
            }
            if (requireCompletionNotice) noticePreflight()
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
            if (radio) {
                receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        val stage = intent.getStringExtra("stage")
                        if (stage !in setOf("observe", "offline", "restored") || stages.size >= 4)
                            asynchronousFailure.compareAndSet(null, AgentServiceTaskEvidence.Rejected("RADIO_STAGE_INVALID"))
                        else stages.add(stage!!)
                    }
                }
                app.registerReceiver(receiver, IntentFilter("${app.packageName}.acceptance.$token"),
                    "android.permission.DUMP", Handler(Looper.getMainLooper()), Context.RECEIVER_EXPORTED)
                receiverRegistered = true
            }
            val turnBy = SystemClock.elapsedRealtime() + 120_000
            submitted = true
            result.put("submittedCount", 1)
            progress("send-requested")
            val accepted = call("session.send", JSONObject().put("sessionId", sessionId).put("requestId", requestId)
                .put("provider", "deepseek-account").put("model", model).put("selectModel", false)
                .put("text", if (radio) AgentServiceTaskEvidence.radioPrompt(caseId)
                    else if (programmatic) AgentServiceProgrammaticEvidence.prompt(caseId, exercise)
                    else AgentServiceTaskEvidence.prompt(caseId)))
            demand(accepted.getBoolean("accepted"), "SUBMISSION_NOT_ACCEPTED")
            progress("submitted")
            var activeObserved = false
            do {
                asynchronousFailure.get()?.let { throw it }
                val failedAt = sessionErrorAt.get()
                if (failedAt != 0L) {
                    val failedTurn = ended.get()
                    // The live failure precedes the durable turn/end by one dispatch; wait for its bounded reason.
                    if (failedTurn == null && SystemClock.elapsedRealtime() - failedAt < 2_000) {
                        Thread.sleep(100)
                        continue
                    }
                    throw AgentServiceTaskEvidence.sessionFailure(failedTurn)
                }
                val observed = observe("")
                if (observed.getBoolean("fresh") && observed.getInt("running") > 0 &&
                    AgentServiceTaskEvidence.runningOwnTask(call("tasks.summary"), sessionId)) {
                    result.put("backgroundDuring", observed).put("foregroundDuring", true)
                        .put("ownTaskRunningObserved", true)
                    activeObserved = true
                }
                if (radio && !radioReady && toolCall.get() != null && activeObserved) {
                    val ready = checkpoint("ready")
                    radioReady = true
                    sendStatus(1, Bundle().apply { putString("ready", ready.toString()) })
                }
                while (radio && stages.isNotEmpty()) {
                    val stage = stages.remove()
                    demand(radioReady && !radioRestored, "RADIO_STAGE_OUT_OF_ORDER")
                    if (stage == "offline") demand(offlineAt == null, "RADIO_OFFLINE_REPEATED")
                    if (stage == "restored") demand(offlineAt != null && SystemClock.elapsedRealtime() - offlineAt!! >= 15_000,
                        "RADIO_OFFLINE_DWELL_SHORT")
                    val value = checkpoint(stage)
                    if (stage == "offline") offlineAt = SystemClock.elapsedRealtime()
                    if (stage == "restored") {
                        radioRestored = true
                        result.put("radioRestoredObserved", true).put("offlineCheckpointElapsedMs", offlineAt!! - began)
                            .put("restoredCheckpointElapsedMs", SystemClock.elapsedRealtime() - began)
                    }
                    sendStatus(if (stage == "observe") 3 else 2,
                        Bundle().apply { putString(if (stage == "observe") "observation" else "checkpoint", value.toString()) })
                }
                if ((!radio || radioRestored) && ended.get() != null && completion.get() != null) break
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
            val durable = exportOwnedSession(sessionId, exportId)
            val evidence = AgentServiceTaskEvidence.completed(history.getJSONArray("events"), durable, caseId, requestId, model, radio, exercise)
            for (key in evidence.keys()) result.put(key, evidence.get(key))
            demand(evidence.getLong("endSeq") == ended.get()!!.getLong("seq"), "LIVE_END_MISMATCH")
            if (radio) {
                demand(radioRestored && evidence.getLong("toolStartSeq") == toolCall.get()!!.getLong("seq") &&
                    evidence.getLong("toolEndSeq") == toolResult.get()!!.getLong("seq"), "RADIO_LIVE_DURABLE_MISMATCH")
                demand(evidence.getJSONObject("linuxReceipt").getInt("guestUid") != info.getInt("uid"), "RADIO_GUEST_NOT_ISOLATED")
            }
            if (programmatic) demand(evidence.getLong("toolStartSeq") == toolCall.get()!!.getLong("seq") &&
                evidence.getLong("toolEndSeq") == toolResult.get()!!.getLong("seq"), "PROGRAMMATIC_LIVE_DURABLE_MISMATCH")
            if (AgentServiceProgrammaticEvidence.workflow(exercise)) {
                val proof = evidence.getJSONObject("programmatic")
                val childId = proof.getString("childSessionId")
                ownedChildId = childId
                val observed = call("workflow.inspect", JSONObject().put("sessionId", sessionId).put("runId", proof.getString("runId")))
                demand(observed.getString("runId") == proof.getString("runId") && observed.getString("state") == "completed" &&
                    !observed.getBoolean("requiresReview"), "WORKFLOW_INSPECTION_UNCONFIRMED")
                proof.put("inspection", JSONObject().put("runId", observed.getString("runId")).put("state", "completed").put("requiresReview", false))
                val child = call("session.read", JSONObject().put("sessionId", childId))
                demand(!child.has("snapshot"), "CHILD_HISTORY_REQUIRES_PAGING")
                proof.put("child", AgentServiceProgrammaticEvidence.child(child.getJSONArray("events"),
                    exportOwnedSession(childId, UUID.randomUUID().toString()), caseId, childId, model, exercise,
                    if (exercise == "workflow-linux") info.getInt("uid") else null))
            }
            asynchronousFailure.get()?.let { throw it }
            result.put("generation", generation).put("agentPid", agentPid).put("deviceStateAfter", state())
            progress("durable")
            if (requireCompletionNotice) {
                progress("completion-notice-wait")
                result.put("completionNotice", observeCompletionNotice())
                progress("completion-notice-observed")
            }
            success = true
            }
        } catch (error: Throwable) { failure(error, "failureCode") }
        finally {
            deadline = minOf(began + 360_000, SystemClock.elapsedRealtime() + 60_000)
            progress("cleanup")
            synchronized(diagnosticLock) {
                diagnosticsOpen = false
                diagnosticHandler.removeCallbacks(diagnosticPulse)
            }
            if (receiverRegistered) {
                try { app.unregisterReceiver(receiver) }
                catch (error: Throwable) { success = false; failure(error, "receiverCleanupFailureCode") }
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
                    ownedChildId?.let { childId ->
                        try {
                            AgentServiceProgrammaticEvidence.archiveChild(childId) { method, params -> call(method, params, 10_000) }
                            cleanup.put("childArchived", true)
                        } catch (error: Throwable) { success = false; failure(error, "childCleanupFailureCode") }
                    }
                    call("library.sessionArchive", JSONObject().put("sessionId", sessionId).put("archived", true), 10_000)
                    cleanup.put("archived", true); result.put("archived", true)
                } catch (error: Throwable) { success = false; failure(error, "cleanupFailureCode") }
            } else cleanup.put("taskSettled", !submitted)
            try {
                var exportFailure: Throwable? = null
                for (id in requestedExports) {
                    try {
                        val released = call("session.export.release", JSONObject().put("id", id), 10_000)
                        demand(released.getBoolean("released"), "EXPORT_RELEASE_UNCONFIRMED")
                    } catch (error: Throwable) {
                        if (exportFailure == null) exportFailure = error else exportFailure!!.addSuppressed(error)
                    }
                }
                exportFailure?.let { throw it }
                cleanup.put("exportReleased", true)
            } catch (error: Throwable) { success = false; failure(error, "exportCleanupFailureCode") }
            if (requireCompletionNotice) {
                try {
                    notificationManager.cancel(noticeTag, 3)
                    val until = minOf(deadline, SystemClock.elapsedRealtime() + 3_000)
                    while (notificationManager.activeNotifications.any { it.tag == noticeTag && it.id == 3 }) {
                        if (SystemClock.elapsedRealtime() >= until) throw AgentServiceTaskEvidence.Rejected("NOTICE_CLEANUP_UNCONFIRMED")
                        Thread.sleep(50)
                    }
                    cleanup.put("completionNoticeCancelled", true)
                } catch (error: Throwable) { success = false; failure(error, "notificationCleanupFailureCode") }
            }
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
