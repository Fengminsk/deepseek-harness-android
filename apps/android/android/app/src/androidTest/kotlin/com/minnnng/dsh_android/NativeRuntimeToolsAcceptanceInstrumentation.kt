package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Real packaged Android Node -> ToolRuntime -> production native owners.
 * This test profile has its own private home and a scripted, credential-free model.
 * It does not replace the user's profile, change product gates, or emulate UI startup.
 */
class NativeRuntimeToolsAcceptanceInstrumentation : Instrumentation() {
    private var suite = "workflow"
    private var foregroundCarrier = "activity"
    private var ptcPhase: String? = null
    private var ptcCaseId: String? = null
    private var processStopConfirmed = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        suite = arguments?.getString("suite") ?: "workflow"
        foregroundCarrier = arguments?.getString("foregroundCarrier") ?: "activity"
        require(foregroundCarrier in setOf("activity", "service"))
        require(suite in setOf("workflow", "ptc", "linux", "all", "ptc-process-death", "ptc-saf"))
        if (suite == "ptc-process-death") {
            ptcPhase = arguments?.getString("phase")
            require(ptcPhase in setOf("prepare", "recover"))
            ptcCaseId = requireNotNull(arguments?.getString("caseId"))
            require(UUID.fromString(ptcCaseId).toString() == ptcCaseId && UUID.fromString(ptcCaseId).version() == 4)
            processStopConfirmed = arguments?.getString("processStopConfirmed") == "true"
            require(processStopConfirmed == (ptcPhase == "recover"))
        }
        start()
    }

    override fun onStart() {
        val report = Bundle()
        var passed = false
        val instrumentationThread = Thread.currentThread()
        val phase = AtomicReference("starting")
        val finished = AtomicBoolean(false)
        // A startup timeout and Node dispatch compete for this one admission.
        // If the timeout wins, a queued worker must never start Node afterwards.
        val startupSettled = AtomicBoolean(false)
        val startupTimedOut = AtomicBoolean(false)
        val app = targetContext.applicationContext
        report.putString("foregroundCarrier", foregroundCarrier)
        report.putString("deviceStateBefore", AcceptanceServiceLease.deviceState(app))
        val linuxBudgetSeconds = 11L * (120L + 30L) + 120L
        val workflowBudgetSeconds = 14L * (120L + 30L) + 120L
        val budgetSeconds = when (suite) {
            "linux" -> linuxBudgetSeconds
            "workflow" -> workflowBudgetSeconds
            "ptc" -> 360L
            "all" -> linuxBudgetSeconds + workflowBudgetSeconds + 360L
            else -> 240L
        }
        val fixtureId = ptcCaseId ?: UUID.randomUUID().toString()
        val home = File(app.noBackupFilesDir, "native-runtime-acceptance/$fixtureId")
        report.putString("home", home.absolutePath)
        val done = CompletableFuture<JSONObject>()
        val foreground = AtomicReference<AcceptanceForegroundLease?>()
        val serviceForeground = AtomicReference<AcceptanceServiceLease?>()
        fun checkForeground() {
            foreground.get()?.checkActive()
            serviceForeground.get()?.checkActive()
        }
        fun closeForeground(): Boolean {
            val acquired = foreground.get() != null || serviceForeground.get() != null
            foreground.get()?.close()
            serviceForeground.get()?.close()
            return acquired
        }
        fun stage(value: String) {
            phase.set(value)
            sendStatus(1, Bundle().apply {
                putString("stage", value)
                putString("suite", suite)
                putString("home", home.absolutePath)
                putString("foregroundCarrier", foregroundCarrier)
            })
        }
        fun startingStage(value: String) {
            check(!startupTimedOut.get()) { "Acceptance startup already timed out" }
            checkForeground()
            stage(value)
        }
        val startupWatchdog = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "dsh-acceptance-startup-watchdog").apply { isDaemon = true }
        }
        val startupFailure = Bundle()
        startupFailure.putString("suite", suite)
        startupFailure.putString("home", home.absolutePath)
        startupFailure.putString("cleanupConfirmed", "false")
        startupFailure.putString("foregroundCarrier", foregroundCarrier)
        val startupTimeout = startupWatchdog.schedule(Runnable {
            var ownsFinish = false
            try {
                if (!startupSettled.compareAndSet(false, true)) return@Runnable
                startupTimedOut.set(true)
                if (foregroundCarrier == "service") {
                    val failure = IllegalStateException("Acceptance startup exceeded 120 seconds at ${phase.get()}")
                    done.completeExceptionally(failure)
                    startupFailure.putString("stage", "startup-timeout")
                    startupFailure.putString("failure", failure.toString())
                    sendStatus(1, startupFailure)
                    // The instrumentation thread retains cleanup ownership. Never report retirement from cancellation.
                    return@Runnable
                }
                if (!finished.compareAndSet(false, true)) return@Runnable
                ownsFinish = true
                val timedOutPhase = phase.get()
                startupFailure.putString("stage", "startup-timeout")
                startupFailure.putString("startupPhase", timedOutPhase)
                startupFailure.putString("failure", "StartupTimeoutException: acceptance startup exceeded 120 seconds at $timedOutPhase")
                // Publish the timeout before stack inspection, which can itself
                // wait on ART. Never let that diagnostic silence the watchdog.
                sendStatus(1, startupFailure)
                val stack = CompletableFuture<String>()
                val stackReader = Thread(Runnable {
                    try {
                        val text = StringBuilder()
                        for (element in instrumentationThread.stackTrace) {
                            text.append(element.toString()).append('\n')
                            if (text.length >= 6000) break
                        }
                        stack.complete(if (text.length > 6000) text.substring(0, 6000) else text.toString())
                    } catch (failure: Throwable) { stack.completeExceptionally(failure) }
                }, "dsh-acceptance-startup-stack")
                stackReader.isDaemon = true
                stackReader.start()
                try { startupFailure.putString("startupStack", stack.get(2, TimeUnit.SECONDS)) }
                catch (failure: Throwable) {
                    val cause = failure.cause ?: failure
                    startupFailure.putString("startupStackFailure", cause.javaClass.name + ": " + cause.message)
                }
            } catch (failure: Throwable) {
                startupFailure.putString("watchdogFailure", failure.javaClass.name + ": " + failure.message)
            } finally {
                if (ownsFinish) {
                    try { startupFailure.putString("foregroundClosed", closeForeground().toString()) }
                    catch (failure: Throwable) { startupFailure.putString("foregroundCloseFailure", failure.toString()) }
                    try { finish(Activity.RESULT_CANCELED, startupFailure) }
                    catch (failure: Throwable) {
                        android.util.Log.e("DSHAcceptance", "Startup watchdog could not finish instrumentation", failure)
                    }
                }
            }
        }, 120, TimeUnit.SECONDS)
        val workers = Executors.newCachedThreadPool()
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        var workflow: IsolatedWorkflowRunNativeBridge? = null
        var isolated: IsolatedRunNativeBridge? = null
        var linux: LinuxVmManager? = null
        var searches: DocumentSearchManager? = null
        var saf: PtcSafAcceptanceFixture? = null
        val deathReady = AtomicBoolean(false)
        var socket: ParcelFileDescriptor? = null
        var readSocket: ParcelFileDescriptor? = null
        try {
            startingStage("foreground-starting")
            if (foregroundCarrier == "service")
                serviceForeground.set(AcceptanceServiceLease.open(this, (budgetSeconds + 180L) * 1000L) {
                    done.completeExceptionally(it)
                })
            else foreground.set(AcceptanceForegroundLease.open(this) { done.completeExceptionally(it) })
            startingStage("foreground-ready")
            report.putString("deviceStateReady", AcceptanceServiceLease.deviceState(app))
            startingStage("runtime-prepare-start")
            val runtime = RuntimeAssets.prepare(app)
            startingStage("runtime-prepared")
            val recovering = ptcPhase == "recover"
            if (recovering) check(home.isDirectory && File(home, "ptc-death-ready.json").isFile)
            else check(File(home, "workspace").mkdirs())
            val appWorkspaceRoot = File(app.noBackupFilesDir, "dsh/workspace")
            val workspace = File(appWorkspaceRoot, if (ptcCaseId != null) ".ptc-death-$fixtureId"
                else ".device-acceptance-$fixtureId").apply { check(if (recovering) isDirectory else mkdirs()) }
            val preparedFixture = File(home, "fixture")
            if (recovering) {
                val oldConfiguration = File(preparedFixture, "configuration.json")
                check(oldConfiguration.isFile && oldConfiguration.length() in 1..16_384)
                val original = JSONObject(oldConfiguration.readText())
                check(original.getString("suite") == suite &&
                    original.getString("workspace") == workspace.absolutePath &&
                    original.getString("appWorkspaceRoot") == appWorkspaceRoot.absolutePath &&
                    original.getString("runtime") == runtime.absolutePath)
                val originalPhase = original.getJSONObject("ptcDeath")
                check(originalPhase.getString("phase") == "prepare" &&
                    originalPhase.getString("caseId") == fixtureId && !originalPhase.getBoolean("processStopConfirmed"))
            }
            val fixture = File(home, if (recovering) "recovery-fixture" else "fixture").apply { check(mkdirs()) }
            for (name in listOf("bootstrap.mjs", "index.mjs", "report.mjs", "workflow.mjs", "ptc.mjs", "linux.mjs", "callback-routing.mjs",
                "python-analysis.mjs", "python-analysis.py", "apk-fixture.json", "apk-overflow-fixture.json",
                "ptc-process-death.mjs", "ptc-saf.mjs", "ptc-linux.mjs", "workflow-checks.mjs", "workflow-model-fixture.mjs")) {
                val bytes = context.assets.open(name).use { it.readBytes() }
                if (recovering) check(File(preparedFixture, name).readBytes().contentEquals(bytes)) {
                    "Recovery fixture differs from the prepared APK assets"
                }
                File(fixture, name).writeBytes(bytes)
            }
            if (suite == "ptc-saf") saf = PtcSafAcceptanceFixture.open(this)
            File(fixture, "configuration.json").writeText(JSONObject().put("runtime", runtime.absolutePath)
                .put("workspace", workspace.absolutePath).put("appWorkspaceRoot", appWorkspaceRoot.absolutePath)
                .put("suite", suite).apply {
                    if (ptcCaseId != null) put("ptcDeath", JSONObject().put("phase", ptcPhase)
                        .put("caseId", ptcCaseId).put("processStopConfirmed", processStopConfirmed))
                    saf?.let { put("saf", JSONObject().put("root", it.root).put("caseId", it.caseId)) }
                }.toString())
            startingStage("fixture-home-ready")
            startingStage("socket-pair-start")
            val pair = NativeRuntime.socketPair()
            startingStage("socket-pair-ready")
            socket = ParcelFileDescriptor.adoptFd(pair[0])
            readSocket = ParcelFileDescriptor.dup(socket.fileDescriptor)
            val output = ParcelFileDescriptor.AutoCloseOutputStream(socket).bufferedWriter()
            val outputLock = Any()
            fun write(value: JSONObject) = synchronized(outputLock) { output.write(value.toString()); output.newLine(); output.flush() }
            fun request(method: String, params: JSONObject, timeout: Long): JSONObject {
                val id = UUID.randomUUID().toString()
                val result = CompletableFuture<JSONObject>()
                check(pending.putIfAbsent(id, result) == null)
                try {
                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("method", method).put("params", params))
                    return result.get(timeout, TimeUnit.MILLISECONDS)
                } finally { pending.remove(id) }
            }
            startingStage("workflow-owner-start")
            val workflowOwner = IsolatedWorkflowRunNativeBridge(app, object : IsolatedWorkflowCallbackBridge.Transport {
                override fun call(params: JSONObject, timeoutMillis: Long) = request("native.workflowCallback", params, timeoutMillis)
                override fun close(runId: String, token: String, timeoutMillis: Long) = request("native.workflowCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis).optBoolean("closed", false)
            })
            workflow = workflowOwner
            startingStage("workflow-owner-ready")
            startingStage("isolated-owner-start")
            val isolatedOwner = IsolatedRunNativeBridge(app, toolTransport = object : IsolatedScriptToolBridge.Transport {
                override fun call(params: JSONObject, timeoutMillis: Long) = request("native.toolCallback", params, timeoutMillis)
                override fun close(runId: String, token: String, timeoutMillis: Long) = request("native.toolCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis).optBoolean("closed", false)
            })
            isolated = isolatedOwner
            startingStage("isolated-owner-ready")
            val linuxOwner by lazy { LinuxVmManager(app).also { linux = it } }
            val searchOwner by lazy { DocumentSearchManager(app).also { searches = it } }
            val input = ParcelFileDescriptor.AutoCloseInputStream(readSocket).bufferedReader()
            startingStage("reader-starting")
            workers.execute {
                try {
                    input.useLines { lines -> lines.forEach { line ->
                        val frame = JSONObject(line)
                        if (frame.has("method") && frame.has("id")) {
                            workers.execute {
                                val id = frame.getString("id")
                                try {
                                    val params = frame.optJSONObject("params") ?: JSONObject()
                                    val value: Any? = when (val method = frame.getString("method")) {
                                        "native.workflow.admit" -> workflowOwner.admit(params)
                                        "native.workflow.bindCallbacks" -> workflowOwner.bindCallbacks(params)
                                        "native.workflow.execute" -> workflowOwner.execute(params)
                                        "native.workflow.cancel" -> workflowOwner.cancel(params)
                                        "native.workflow.settle" -> workflowOwner.settle(params)
                                        "native.workflow.inspect" -> workflowOwner.inspect(params)
                                        "native.workflow.release" -> workflowOwner.release(params)
                                        "native.isolated.admit" -> isolatedOwner.admit(params)
                                        "native.isolated.bindTools" -> isolatedOwner.bindTools(params)
                                        "native.isolated.execute" -> isolatedOwner.execute(params)
                                        "native.isolated.cancel" -> isolatedOwner.cancel(params)
                                        "native.isolated.settle" -> isolatedOwner.settle(params)
                                        "native.isolated.release" -> isolatedOwner.release(params)
                                        "native.documents.roots" -> DocumentAccess(app).roots()
                                        "native.storage.root" -> File(app.applicationInfo.dataDir).canonicalPath
                                        "native.documents.read" -> DocumentAccess(app).read(params.getString("root"),
                                            params.getString("path"), DocumentReadAccess.offset(params.opt("offset")),
                                            params.optString("version").takeIf { it.isNotEmpty() })
                                        "native.documents.search.prepare" -> searchOwner.prepare(params.getString("id"))
                                        "native.documents.search.run" -> searchOwner.run(params)
                                        "native.documents.search.cancel" -> searchOwner.cancel(params.getString("id"))
                                        "acceptance.saf.revoke" -> {
                                            val controlled = checkNotNull(saf)
                                            check(suite == "ptc-saf" && params.getString("root") == controlled.root)
                                            controlled.revoke(searchOwner)
                                        }
                                        "native.linuxVm.execute" -> linuxOwner.execute(params)
                                        "native.linuxVm.cancel" -> linuxOwner.cancel(params)
                                        "native.linuxVm.importFile" -> linuxOwner.importFile(params)
                                        "native.linuxVm.exportFile" -> linuxOwner.exportFile(params)
                                        "native.linuxVm.inspect" -> linuxOwner.inspect(params)
                                        else -> error("Unexpected acceptance native method: $method")
                                    }
                                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", value ?: JSONObject.NULL))
                                } catch (failure: Throwable) {
                                    write(JSONObject().put("jsonrpc", "2.0").put("id", id).put("error", JSONObject()
                                        .put("code", -32603).put("message", "${failure.javaClass.simpleName}: ${failure.message}")))
                                }
                            }
                        } else if (frame.has("id")) {
                            val waiter = pending[frame.getString("id")]
                            if (frame.has("error")) waiter?.completeExceptionally(IllegalStateException(frame.getJSONObject("error").toString()))
                            else waiter?.complete(frame.getJSONObject("result"))
                        } else if (frame.optString("method") == "acceptance.result") {
                            done.complete(frame.getJSONObject("params"))
                        } else if (frame.optString("method") == "acceptance.ptcDeathReady") {
                            check(ptcPhase == "prepare" && deathReady.compareAndSet(false, true))
                            val marker = frame.getJSONObject("params")
                            check(marker.keys().asSequence().toSet() == setOf("schema", "caseId", "runId", "agentPid", "fileSha256"))
                            check(marker.getInt("schema") == 1 && marker.getString("caseId") == fixtureId &&
                                marker.getInt("agentPid") == android.os.Process.myPid())
                            IsolatedScriptWire.requireUuid(marker.getString("runId"))
                            check(marker.getString("fileSha256").matches(Regex("[0-9a-f]{64}")))
                            val receipt = IsolatedScriptRunController.readReceipt(app, marker.getString("runId"))
                            check(receipt.state() == IsolatedScriptReceipt.State.ADMITTED && receipt.outputJson() == null)
                            sendStatus(1, Bundle().apply { putString("ready", marker.toString()) })
                        }
                    } }
                    if (!done.isDone) done.completeExceptionally(IllegalStateException("Acceptance IPC ended before a result"))
                } catch (failure: Throwable) { done.completeExceptionally(failure) }
            }
            startingStage("reader-started")
            startingStage("node-queued")
            workers.execute {
                try {
                    check(startupSettled.compareAndSet(false, true)) { "Acceptance startup ended before Node dispatch" }
                    checkForeground()
                    startupTimeout.cancel(false)
                    startupWatchdog.shutdown()
                    stage("node-starting")
                    val code = NativeRuntime.start(fixture.absolutePath, home.absolutePath, app.cacheDir.absolutePath,
                        app.applicationInfo.nativeLibraryDir, pair[1])
                    if (!done.isDone) done.completeExceptionally(IllegalStateException("Node exited before acceptance: $code"))
                } catch (failure: Throwable) { done.completeExceptionally(failure) }
            }
            try {
                startingStage("waiting-result")
                val result = done.get(budgetSeconds, TimeUnit.SECONDS)
                result.put("foregroundCarrier", foregroundCarrier)
                if (ptcPhase == "recover" && result.optBoolean("passed")) {
                    val evidence = result.getJSONArray("reports").getJSONObject(0).getJSONArray("checks").getJSONObject(0)
                    val receipt = IsolatedScriptRunController.readReceipt(app, evidence.getString("runId"))
                    check(receipt.state() in setOf(IsolatedScriptReceipt.State.ADMITTED,
                        IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED) && receipt.outputJson() == null)
                    result.put("nativeReceiptState", receipt.state().name).put("nativeOutputAbsent", true)
                }
                report.putString("result", result.toString())
                passed = result.getBoolean("passed")
            } finally {
                val diagnostics = File(home, "runtime-stderr.log")
                if (diagnostics.isFile) RandomAccessFile(diagnostics, "r").use { log ->
                    val size = log.length()
                    val tail = ByteArray(minOf(size, 6000L).toInt())
                    log.seek(size - tail.size)
                    log.readFully(tail)
                    report.putString("diagnostics", tail.toString(Charsets.UTF_8))
                }
            }
        } catch (failure: Throwable) {
            passed = false
            report.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}")
            report.putString("failureStage", phase.get())
        } finally {
            var nativeOwnersClosed = true
            startupSettled.compareAndSet(false, true)
            startupTimeout.cancel(false)
            startupWatchdog.shutdownNow()
            stage("cleanup-workflow")
            try { workflow?.close() } catch (failure: Throwable) { nativeOwnersClosed = false; passed = false; report.putString("workflowCloseFailure", failure.toString()) }
            stage("cleanup-isolated")
            try { isolated?.close() } catch (failure: Throwable) { nativeOwnersClosed = false; passed = false; report.putString("isolatedCloseFailure", failure.toString()) }
            stage("cleanup-linux")
            try { linux?.close() } catch (failure: Throwable) { nativeOwnersClosed = false; passed = false; report.putString("linuxCloseFailure", failure.toString()) }
            stage("cleanup-searches")
            try { searches?.close() } catch (failure: Throwable) { nativeOwnersClosed = false; passed = false; report.putString("searchCloseFailure", failure.toString()) }
            try { saf?.close() } catch (failure: Throwable) { passed = false; report.putString("safCloseFailure", failure.toString()) }
            stage("cleanup-socket")
            try { socket?.close() } catch (_: Throwable) {}
            stage("cleanup-read-socket")
            try { readSocket?.close() } catch (_: Throwable) {}
            stage("cleanup-workers")
            workers.shutdownNow()
            report.putString("nativeOwnersClosed", nativeOwnersClosed.toString())
            // NativeRuntime.start has no stop API. The host guard owns final package stop and whole-process checks.
            report.putString("nodeProcessRetired", "false")
            stage("cleanup-foreground")
            try { report.putString("foregroundClosed", closeForeground().toString()) }
            catch (failure: Throwable) { passed = false; report.putString("foregroundCloseFailure", failure.toString()) }
            report.putString("deviceStateAfter", AcceptanceServiceLease.deviceState(app))
        }
        report.putString("suite", suite)
        stage("finish")
        if (finished.compareAndSet(false, true)) finish(if (passed) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
