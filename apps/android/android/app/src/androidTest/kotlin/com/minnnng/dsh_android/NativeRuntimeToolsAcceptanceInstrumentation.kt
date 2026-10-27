package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
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
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        suite = arguments?.getString("suite") ?: "workflow"
        require(suite in setOf("workflow", "ptc", "linux", "all"))
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
        val fixtureId = UUID.randomUUID().toString()
        val home = File(app.noBackupFilesDir, "native-runtime-acceptance/$fixtureId")
        report.putString("home", home.absolutePath)
        val done = CompletableFuture<JSONObject>()
        val foregroundToken = UUID.randomUUID().toString()
        val foregroundPermission = "${app.packageName}.permission.RUNTIME_ACCEPTANCE"
        val foregroundReady = CompletableFuture<Boolean>()
        val foregroundClosed = CompletableFuture<Boolean>()
        val foregroundRegistered = AtomicBoolean(false)
        val foregroundClosing = AtomicBoolean(false)
        val foregroundUserClosed = AtomicBoolean(false)
        val foregroundReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.getStringExtra("token") != foregroundToken) return
                when (intent.getStringExtra("state")) {
                    "ready" -> foregroundReady.complete(true)
                    "closed" -> {
                        foregroundClosed.complete(true)
                        if (!foregroundClosing.get()) {
                            foregroundUserClosed.set(true)
                            val failure = IllegalStateException("Acceptance foreground page was closed")
                            foregroundReady.completeExceptionally(failure)
                            done.completeExceptionally(failure)
                        }
                    }
                }
            }
        }
        fun closeForeground(): Boolean {
            if (!foregroundRegistered.get()) return true
            try {
                if (foregroundClosing.compareAndSet(false, true)) app.sendBroadcast(
                    Intent("${app.packageName}.acceptance.foreground.close").setPackage(app.packageName)
                        .putExtra("token", foregroundToken), foregroundPermission)
                return foregroundClosed.get(2, TimeUnit.SECONDS)
            } finally {
                if (foregroundRegistered.compareAndSet(true, false)) app.unregisterReceiver(foregroundReceiver)
            }
        }
        fun stage(value: String) {
            phase.set(value)
            sendStatus(1, Bundle().apply {
                putString("stage", value)
                putString("suite", suite)
                putString("home", home.absolutePath)
            })
        }
        fun startingStage(value: String) {
            check(!startupTimedOut.get()) { "Acceptance startup already timed out" }
            check(!foregroundClosed.isDone) { "Acceptance foreground page was closed" }
            stage(value)
        }
        val startupWatchdog = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "dsh-acceptance-startup-watchdog").apply { isDaemon = true }
        }
        val startupFailure = Bundle()
        startupFailure.putString("suite", suite)
        startupFailure.putString("home", home.absolutePath)
        startupFailure.putString("cleanupConfirmed", "false")
        val startupTimeout = startupWatchdog.schedule(Runnable {
            var ownsFinish = false
            try {
                if (!startupSettled.compareAndSet(false, true)) return@Runnable
                startupTimedOut.set(true)
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
        var socket: ParcelFileDescriptor? = null
        var readSocket: ParcelFileDescriptor? = null
        try {
            startingStage("foreground-starting")
            val foregroundFilter = IntentFilter("${app.packageName}.acceptance.foreground.status")
            if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(foregroundReceiver, foregroundFilter,
                foregroundPermission, null, Context.RECEIVER_NOT_EXPORTED)
            else app.registerReceiver(foregroundReceiver, foregroundFilter, foregroundPermission, null)
            foregroundRegistered.set(true)
            uiAutomation.adoptShellPermissionIdentity("android.permission.START_ACTIVITIES_FROM_BACKGROUND")
            try {
                app.startActivity(Intent().setClassName(app.packageName, "${app.packageName}.RuntimeAcceptanceActivity")
                    .putExtra("token", foregroundToken)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK))
            } finally { uiAutomation.dropShellPermissionIdentity() }
            foregroundReady.get(20, TimeUnit.SECONDS)
            startingStage("foreground-ready")
            startingStage("runtime-prepare-start")
            val runtime = RuntimeAssets.prepare(app)
            startingStage("runtime-prepared")
            check(File(home, "workspace").mkdirs())
            val appWorkspaceRoot = File(app.noBackupFilesDir, "dsh/workspace")
            val workspace = File(appWorkspaceRoot, ".device-acceptance-$fixtureId").apply { check(mkdirs()) }
            val fixture = File(home, "fixture").apply { check(mkdirs()) }
            for (name in listOf("bootstrap.mjs", "index.mjs", "report.mjs", "workflow.mjs", "ptc.mjs", "linux.mjs", "callback-routing.mjs",
                "python-analysis.mjs", "python-analysis.py", "apk-fixture.json", "apk-overflow-fixture.json")) {
                context.assets.open(name).use { source -> File(fixture, name).outputStream().use { source.copyTo(it) } }
            }
            File(fixture, "configuration.json").writeText(JSONObject().put("runtime", runtime.absolutePath)
                .put("workspace", workspace.absolutePath).put("appWorkspaceRoot", appWorkspaceRoot.absolutePath)
                .put("suite", suite).toString())
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
                    check(!foregroundClosed.isDone) { "Acceptance foreground page was closed before Node dispatch" }
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
                // Eight parent boots and three child boots each retain the
                // production 120-second limit plus 30 seconds for retirement.
                val linuxBudgetSeconds = 11L * (120L + 30L) + 120L
                val budgetSeconds = when (suite) {
                    "linux" -> linuxBudgetSeconds
                    "all" -> linuxBudgetSeconds + 2L * 240L
                    else -> 240L
                }
                val result = done.get(budgetSeconds, TimeUnit.SECONDS)
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
            startupSettled.compareAndSet(false, true)
            startupTimeout.cancel(false)
            startupWatchdog.shutdownNow()
            stage("cleanup-workflow")
            try { workflow?.close() } catch (failure: Throwable) { passed = false; report.putString("workflowCloseFailure", failure.toString()) }
            stage("cleanup-isolated")
            try { isolated?.close() } catch (failure: Throwable) { passed = false; report.putString("isolatedCloseFailure", failure.toString()) }
            stage("cleanup-linux")
            try { linux?.close() } catch (failure: Throwable) { passed = false; report.putString("linuxCloseFailure", failure.toString()) }
            stage("cleanup-socket")
            try { socket?.close() } catch (_: Throwable) {}
            stage("cleanup-read-socket")
            try { readSocket?.close() } catch (_: Throwable) {}
            stage("cleanup-workers")
            workers.shutdownNow()
            stage("cleanup-foreground")
            try { report.putString("foregroundClosed", closeForeground().toString()) }
            catch (failure: Throwable) { passed = false; report.putString("foregroundCloseFailure", failure.toString()) }
        }
        report.putString("suite", suite)
        if (foregroundUserClosed.get()) {
            passed = false
            report.putString("failure", "Acceptance foreground page was closed by the user")
        }
        stage("finish")
        if (finished.compareAndSet(false, true)) finish(if (passed) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
