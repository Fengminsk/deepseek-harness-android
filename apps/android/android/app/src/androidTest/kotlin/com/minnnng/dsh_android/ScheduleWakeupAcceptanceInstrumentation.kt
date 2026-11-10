package com.minnnng.dsh_android

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Phase entry for --no-restart instrumentation; no phase starts a service, Activity or CPU lease. */
class ScheduleWakeupAcceptanceInstrumentation : Instrumentation() {
    private var options = Bundle()
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); options = arguments ?: Bundle(); start() }
    @Suppress("DEPRECATION")
    override fun onStart() {
        val app = targetContext.applicationContext
        val phase = options.getString("phase") ?: "status"
        val caseId = options.getString("caseId") ?: ""
        val expectedMain = options.getString("mainPid")?.toIntOrNull()
        val began = SystemClock.elapsedRealtime()
        var deadline = began + if (phase == "prepare") 240_000 else 150_000
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        val connected = CompletableFuture<Unit>()
        var remote: Messenger? = null
        var bound = false
        var exported: String? = null
        var record: JSONObject? = null
        var detached = false
        var success = false
        val cancelled = AtomicBoolean(false)
        var finishing = false
        var receiverRegistered = false
        var failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.PHASE
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { cancelled.set(true) }
        }
        val result = JSONObject().put("schema", 1).put("kind", "natural-schedule-wake").put("phase", phase)
            .put("caseId", caseId).put("mainPid", android.os.Process.myPid()).put("testCpuLease", false)
            .put("serviceStartedByFixture", false).put("bindingAutoCreate", false)
        fun demand(value: Boolean, code: String) = ScheduleWakeupAcceptanceEvidence.demand(value, code)
        fun state(): JSONObject {
            val locked = app.getSystemService(KeyguardManager::class.java).isKeyguardLocked
            val interactive = app.getSystemService(PowerManager::class.java).isInteractive
            demand(locked && !interactive, "DEVICE_NOT_LOCKED")
            return JSONObject().put("locked", locked).put("interactive", interactive)
        }
        fun progress(stage: String) = sendStatus(1, Bundle().apply { putString("scheduleWakeProgress",
            JSONObject().put("schema", 1).put("phase", phase).put("caseId", caseId).put("stage", stage)
                .put("elapsedMs", SystemClock.elapsedRealtime() - began).toString()) })
        fun service() = app.getSystemService(ActivityManager::class.java).getRunningServices(128)
            .singleOrNull { it.service.className == "${app.packageName}.AgentService" && it.process == "${app.packageName}:agent" }
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                val frame = JSONObject(WirePayload.decode(message.data))
                if (frame.has("id")) pending[frame.getString("id")]?.complete(frame)
            } catch (error: Throwable) { pending.values.forEach { it.completeExceptionally(error) } }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    remote = Messenger(binder)
                    remote!!.send(Message.obtain(null, 1).apply { replyTo = replies })
                    connected.complete(Unit)
                } catch (error: Throwable) { connected.completeExceptionally(error) }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                pending.values.forEach { it.completeExceptionally(IllegalStateException("SERVICE_DISCONNECTED")) }
            }
        }
        fun disconnect() {
            remote?.send(Message.obtain(null, 3).apply { replyTo = replies })
            if (bound) app.unbindService(connection)
            bound = false; detached = true; remote = null
        }
        fun call(method: String, params: JSONObject = JSONObject(), timeout: Long = 15_000): JSONObject {
            demand(finishing || !cancelled.get(), "CANCELLED")
            val budget = minOf(timeout, deadline - SystemClock.elapsedRealtime())
            demand(budget > 0, "DEADLINE_EXCEEDED")
            val id = UUID.randomUUID().toString()
            val reply = CompletableFuture<JSONObject>(); pending[id] = reply
            try {
                val payload = WirePayload.encode(JSONObject().put("jsonrpc", "2.0").put("id", id)
                    .put("method", method).put("params", params).toString())
                try { remote!!.send(Message.obtain(null, 2).apply { data = payload; replyTo = replies }) }
                finally { WirePayload.close(payload) }
                val frame = reply.get(budget, TimeUnit.MILLISECONDS)
                demand(!frame.has("error"), "RPC_FAILED")
                val value = frame.optJSONObject("result") ?: JSONObject().put("value", frame.opt("result") ?: JSONObject.NULL)
                demand(!value.has("_pocket_error"), "DOMAIN_FAILED")
                return value
            } finally { pending.remove(id) }
        }
        fun schedule(method: String, request: JSONObject? = null) = call("api.call", JSONObject()
            .put("namespace", "schedule").put("method", method)
            .put("args", if (request == null) JSONObject() else JSONObject().put("request", request)))
        fun catalog(): JSONArray = schedule("catalog").getJSONArray("value")
        fun idle() = ScheduleWakeupAcceptanceEvidence.idle(call("tasks.summary").getJSONObject("summary"))
        val sessionId = ScheduleWakeupAcceptanceEvidence.session(caseId)
        val address = JSONObject().put("sessionId", sessionId)
        val directory = File(app.noBackupFilesDir, "schedule-wake-acceptance")
        val file = File(directory, "$caseId.json")
        fun save(value: JSONObject) {
            demand(directory.isDirectory && !Files.isSymbolicLink(directory.toPath()), "FIXTURE_DIRECTORY_INVALID")
            val temporary = File.createTempFile("$caseId-", ".tmp", directory)
            try {
                FileOutputStream(temporary).use { it.write(value.toString().toByteArray()); it.fd.sync() }
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                val fd = android.system.Os.open(directory.path, android.system.OsConstants.O_RDONLY, 0)
                try {
                    demand(android.system.OsConstants.S_ISDIR(android.system.Os.fstat(fd).st_mode), "FIXTURE_DIRECTORY_INVALID")
                    android.system.Os.fsync(fd)
                } finally { android.system.Os.close(fd) }
            } finally { temporary.delete() }
            record = value
        }
        fun load(): JSONObject {
            demand(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.length() in 1..32768, "FIXTURE_RECORD_MISSING")
            val value = JSONObject(file.readText())
            demand(value.getString("caseId") == caseId && value.getString("sessionId") == sessionId, "FIXTURE_IDENTITY_MISMATCH")
            record = value; return value
        }
        fun owned(catalog: JSONArray): List<JSONObject> = (0 until catalog.length()).map { catalog.getJSONObject(it) }
            .filter { it.getString("sessionId") == sessionId }
        fun events() = call("session.read", address).getJSONArray("events")
        fun exportEvents(): JSONArray {
            val id = UUID.randomUUID().toString(); exported = id
            val receipt = call("session.export.prepare", JSONObject().put("id", id).put("sessionId", sessionId).put("includeDescendants", false))
            demand(receipt.getString("id") == id && receipt.getLong("size") in 1..1024 * 1024, "EXPORT_INVALID")
            val parent = File(app.cacheDir, "pocket-session-exports").canonicalFile
            val zip = File(parent, "$id.zip")
            demand(zip.canonicalFile.parentFile == parent && Files.isRegularFile(zip.toPath(), LinkOption.NOFOLLOW_LINKS), "EXPORT_PATH_INVALID")
            return Files.newInputStream(zip.toPath(), LinkOption.NOFOLLOW_LINKS).use { AgentServiceTaskEvidence.readExport(it, sessionId) }
        }
        try {
            demand(phase in setOf("status", "prepare", "observe", "cleanup") &&
                caseId.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")), "OPTIONS_INVALID")
            demand(expectedMain == android.os.Process.myPid() && options.getString("noRestart") == "true", "PREEXISTING_MAIN_REQUIRED")
            app.registerReceiver(receiver, IntentFilter("${app.packageName}.scheduleAcceptance.$caseId"),
                "android.permission.DUMP", Handler(Looper.getMainLooper()), Context.RECEIVER_EXPORTED)
            receiverRegistered = true
            result.put("deviceStateBefore", state()); progress("existing-service-bind")
            val original = service()
            if (original == null && phase == "status") {
                result.put("needsUserAction", true).put("reason", "existing-service-required")
            } else {
                demand(original != null && original.pid > 0 && original.uid == android.os.Process.myUid(), "EXISTING_SERVICE_REQUIRED")
                val originalPid = original!!.pid
                result.put("agentPid", originalPid)
                bound = app.bindService(Intent().setClassName(app.packageName, "${app.packageName}.AgentService"), connection, 0)
                demand(bound, "BIND_FAILED"); connected.get(15, TimeUnit.SECONDS)
                val readyBy = minOf(deadline, SystemClock.elapsedRealtime() + 120_000)
                var runtime = call("runtime.status")
                while (runtime.getString("phase") != "ready") {
                    demand(runtime.getString("phase") != "failed" && SystemClock.elapsedRealtime() < readyBy, "RUNTIME_NOT_READY")
                    Thread.sleep(500); runtime = call("runtime.status")
                }
                demand(service()?.pid == originalPid, "SERVICE_CHANGED")
                val generation = runtime.getString("generation")
                result.put("generation", generation)
                val wake = call("runtime.scheduleWake.status")
                result.put("wake", wake)
                if (phase == "status") {
                    result.put("needsUserAction", !wake.getBoolean("enabled") || !wake.getBoolean("exactAlarmsAllowed"))
                } else if (phase == "prepare") {
                    demand(options.getString("acceptRealAccountRequest") == "true", "REAL_ACCOUNT_NOT_ADMITTED")
                    demand(wake.getBoolean("enabled") && wake.getBoolean("exactAlarmsAllowed") && wake.isNull("error"), "WAKE_PERMISSION_REQUIRED")
                    idle()
                    val before = catalog()
                    demand((0 until before.length()).none { before.getJSONObject(it).getString("status") == "active" }, "OTHER_ACTIVE_REMINDER")
                    demand(!file.exists() && (directory.isDirectory || directory.mkdirs()), "FIXTURE_ALREADY_EXISTS")
                    save(JSONObject().put("schema", 1).put("caseId", caseId).put("sessionId", sessionId).put("stage", "reserved"))
                    val info = call("runtime.info")
                    demand(info.getString("platform") == "android" && info.getString("profile") == "android", "PROFILE_MISMATCH")
                    val model = AgentServiceTaskEvidence.model(call("api.call", JSONObject().put("namespace", "session")
                        .put("method", "modelCatalog").put("args", JSONObject())))
                    val ensured = call("session.ensure", address)
                    demand(ensured.getBoolean("created"), "SESSION_NOT_NEW")
                    val saved = record!!.put("created", true).put("model", model).put("generation", generation).put("oldAgentPid", originalPid)
                    save(saved)
                    progress("schedule-create-request")
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SAVE
                    save(saved.put("submitted", true))
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SEND
                    call("session.send", JSONObject().put("sessionId", sessionId).put("requestId", "schedule-create-$caseId")
                        .put("provider", "deepseek-account").put("model", model).put("selectModel", false)
                        .put("text", ScheduleWakeupAcceptanceEvidence.prompt(caseId)))
                    var history: JSONArray
                    val turnBy = minOf(deadline, SystemClock.elapsedRealtime() + 120_000)
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_HISTORY
                    while (true) {
                        history = events()
                        if (ScheduleWakeupAcceptanceEvidence.rows(history).any { it.getString("type") == "turn/end" }) break
                        demand(SystemClock.elapsedRealtime() < turnBy, "CREATE_TURN_TIMEOUT"); Thread.sleep(500)
                    }
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_IDLE
                    idle()
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_CATALOG
                    val records = owned(catalog())
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RECORD
                    demand(records.size == 1 && records.single().getString("status") == "active", "REMINDER_NOT_CREATED")
                    val reminder = records.single()
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_EVIDENCE
                    val creation = ScheduleWakeupAcceptanceEvidence.created(history, reminder, caseId, model)
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_DUE
                    val due = ScheduleWakeupAcceptanceEvidence.ownRecord(reminder, caseId)
                    val armedBy = SystemClock.elapsedRealtime() + 10_000
                    var armed: JSONObject
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_WAIT
                    while (true) {
                        armed = call("runtime.scheduleWake.status")
                        if (armed.optString("alarmState") == "scheduled" && armed.optLong("nextDueAtMs") == due) break
                        demand(SystemClock.elapsedRealtime() < armedBy, "ALARM_NOT_ARMED"); Thread.sleep(100)
                    }
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_CHECK
                    ScheduleWakeupAcceptanceEvidence.armed(armed, due, System.currentTimeMillis())
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_SAVE
                    for (key in creation.keys()) saved.put(key, creation.get(key))
                    save(saved.put("reminderId", reminder.getString("id")).put("dueAtMs", due).put("stage", "armed"))
                    // Recheck idle and exact identity immediately before removing our binding and killing only this PID.
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_IDLE
                    idle(); state()
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_RUNTIME
                    demand(call("runtime.status").getString("generation") == generation && service()?.pid == originalPid, "SERVICE_CHANGED")
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_DISCONNECT
                    val originalEndpoint = remote!!.binder
                    disconnect()
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_SAVE
                    save(saved.put("stage", "kill-requested"))
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_IDENTITY
                    // Keep the original Binder identity after unbinding; a restarted service cannot satisfy this probe.
                    val originalEndpointAlive = originalEndpoint.pingBinder()
                    val processRows = app.getSystemService(ActivityManager::class.java).runningAppProcesses
                    val currentService = service()
                    demand(processRows != null && currentService != null, "KILL_TARGET_CHANGED")
                    ScheduleWakeupAcceptanceEvidence.retirementTarget(JSONArray(processRows!!.map {
                        JSONObject().put("pid", it.pid).put("uid", it.uid).put("processName", it.processName)
                    }), JSONObject().put("pid", currentService!!.pid).put("uid", currentService.uid)
                        .put("processName", currentService.process), originalPid, android.os.Process.myUid(),
                        "${app.packageName}:agent", originalEndpointAlive)
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_SIGNAL
                    android.os.Process.killProcess(originalPid)
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_WAIT
                    val goneBy = SystemClock.elapsedRealtime() + 10_000
                    while (true) {
                        val errno = try { android.system.Os.kill(originalPid, 0); null }
                            catch (error: android.system.ErrnoException) { error.errno }
                        if (ScheduleWakeupAcceptanceEvidence.signalProbeGone(errno, android.system.OsConstants.ESRCH)) break
                        demand(SystemClock.elapsedRealtime() < goneBy, "OLD_AGENT_NOT_RETIRED"); Thread.sleep(50)
                    }
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_WAIT_SAVE
                    save(saved.put("stage", "waiting"))
                    failureStep = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_RECEIPT
                    result.put("sessionId", sessionId).put("dueAtMs", due).put("armedAtMs", armed.getLong("armedAtMs"))
                        .put("oldAgentPid", originalPid).put("oldAgentRetired", true).put("bindingReleasedBeforeKill", true)
                        .put("recordSha256", AgentServiceTaskEvidence.hash(file.readBytes()))
                        .put("reminderIdSha256", AgentServiceTaskEvidence.hash(reminder.getString("id").toByteArray()))
                    progress("waiting-without-carrier")
                } else {
                    val saved = load()
                    if (phase == "observe") {
                        demand(saved.getString("stage") == "waiting" && originalPid != saved.getInt("oldAgentPid") &&
                            generation != saved.getString("generation") && System.currentTimeMillis() >= saved.getLong("dueAtMs"), "NATURAL_RESTART_NOT_OBSERVED")
                        progress("natural-delivery-wait")
                        var history: JSONArray
                        while (true) {
                            history = events()
                            if (ScheduleWakeupAcceptanceEvidence.rows(history).count { it.getString("type") == "turn/end" } >= 2) break
                            demand(SystemClock.elapsedRealtime() < deadline - 15_000, "DELIVERY_TIMEOUT"); Thread.sleep(500)
                        }
                        idle()
                        val records = owned(catalog()); demand(records.size == 1, "REMINDER_COUNT_CHANGED")
                        val deliveries = schedule("history", JSONObject().put("sessionId", sessionId).put("id", saved.getString("reminderId")).put("limit", 20))
                        val evidence = ScheduleWakeupAcceptanceEvidence.delivered(history, exportEvents(), records.single(), deliveries, saved)
                        result.put("sessionId", sessionId).put("delivery", evidence).put("oldAgentPid", saved.getInt("oldAgentPid"))
                            .put("dueAtMs", saved.getLong("dueAtMs"))
                        save(saved.put("stage", "observed").put("observedAgentPid", originalPid).put("observedGeneration", generation))
                    } else {
                        progress("owned-reminder-cleanup")
                        if (saved.optBoolean("created")) {
                            call("session.ensure", address)
                            val active = call("tasks.summary").getJSONArray("active")
                            val ownActive = (0 until active.length()).map { active.getJSONObject(it) }.any {
                                it.getString("sessionId") == sessionId && (it.getString("status") in setOf("running", "queued", "waiting") ||
                                    it.getInt("queued") > 0 || it.getInt("blockingRequests") > 0)
                            }
                            if (ownActive) call("session.cancel", address)
                            val until = SystemClock.elapsedRealtime() + 15_000
                            while (true) {
                                val rows = call("tasks.summary").getJSONArray("active")
                                val pendingOwn = (0 until rows.length()).map { rows.getJSONObject(it) }.any { it.getString("sessionId") == sessionId &&
                                    (it.getString("status") in setOf("running", "queued", "waiting") || it.getInt("queued") > 0 || it.getInt("blockingRequests") > 0) }
                                if (!pendingOwn) break
                                demand(SystemClock.elapsedRealtime() < until, "OWN_TASK_NOT_SETTLED"); Thread.sleep(100)
                            }
                            for (entry in owned(catalog())) {
                                ScheduleWakeupAcceptanceEvidence.ownRecord(entry, caseId)
                                demand(schedule("delete", JSONObject().put("sessionId", sessionId).put("id", entry.getString("id"))).getBoolean("deleted"), "REMINDER_DELETE_UNCONFIRMED")
                            }
                            demand(owned(catalog()).isEmpty(), "REMINDER_CLEANUP_UNCONFIRMED")
                            call("library.sessionArchive", JSONObject().put("sessionId", sessionId).put("archived", true))
                            app.getSystemService(NotificationManager::class.java).cancel("pocket-completed:$sessionId", 3)
                        }
                        save(saved.put("stage", "cleaned"))
                        result.put("ownTaskSettled", true).put("ownReminderDeleted", true).put("ownSessionArchived", saved.optBoolean("created"))
                            .put("preferencesChanged", false).put("permissionsChanged", false)
                    }
                }
            }
            demand(!cancelled.get(), "CANCELLED")
            success = true
        } catch (error: Throwable) {
            result.put("failureCode", ScheduleWakeupAcceptanceEvidence.failureCode(error, failureStep))
                .put("failureType", error.javaClass.simpleName.take(80))
        } finally {
            finishing = true
            deadline = SystemClock.elapsedRealtime() + 15_000
            if (receiverRegistered) {
                try { app.unregisterReceiver(receiver) }
                catch (_: Throwable) { success = false; result.put("receiverCleanupFailureCode", "RECEIVER_RELEASE_UNCONFIRMED") }
            }
            try {
                exported?.let { demand(call("session.export.release", JSONObject().put("id", it)).getBoolean("released"), "EXPORT_RELEASE_UNCONFIRMED") }
                if (!detached) disconnect()
                result.put("bindingReleased", true)
            } catch (_: Throwable) { success = false; result.put("cleanupFailureCode", "DISCONNECT_OR_EXPORT_UNCONFIRMED") }
            try { result.put("deviceStateAfter", state()) }
            catch (_: Throwable) { success = false; result.put("screenFailureCode", "DEVICE_NOT_LOCKED") }
        }
        result.put("passed", success).put("elapsedMs", SystemClock.elapsedRealtime() - began)
            .put("deviceWallMs", System.currentTimeMillis())
        finish(if (success) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply { putString("result", result.toString()) })
    }
}
