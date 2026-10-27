package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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
        val workers = Executors.newCachedThreadPool()
        val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
        val done = CompletableFuture<JSONObject>()
        var workflow: IsolatedWorkflowRunNativeBridge? = null
        var isolated: IsolatedRunNativeBridge? = null
        var linux: LinuxVmManager? = null
        var socket: ParcelFileDescriptor? = null
        var readSocket: ParcelFileDescriptor? = null
        try {
            val app = targetContext.applicationContext
            val runtime = RuntimeAssets.prepare(app)
            val fixtureId = UUID.randomUUID().toString()
            val home = File(app.noBackupFilesDir, "native-runtime-acceptance/$fixtureId")
            check(File(home, "workspace").mkdirs())
            val appWorkspaceRoot = File(app.noBackupFilesDir, "dsh/workspace")
            val workspace = File(appWorkspaceRoot, ".device-acceptance-$fixtureId").apply { check(mkdirs()) }
            val fixture = File(home, "fixture").apply { check(mkdirs()) }
            for (name in listOf("bootstrap.mjs", "index.mjs", "report.mjs", "workflow.mjs", "ptc.mjs", "linux.mjs",
                "python-analysis.mjs", "python-analysis.py", "apk-fixture.json", "apk-overflow-fixture.json")) {
                context.assets.open(name).use { source -> File(fixture, name).outputStream().use { source.copyTo(it) } }
            }
            File(fixture, "configuration.json").writeText(JSONObject().put("runtime", runtime.absolutePath)
                .put("workspace", workspace.absolutePath).put("appWorkspaceRoot", appWorkspaceRoot.absolutePath)
                .put("suite", suite).toString())
            val pair = NativeRuntime.socketPair()
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
            val workflowOwner = IsolatedWorkflowRunNativeBridge(app, object : IsolatedWorkflowCallbackBridge.Transport {
                override fun call(params: JSONObject, timeoutMillis: Long) = request("native.workflowCallback", params, timeoutMillis)
                override fun close(runId: String, token: String, timeoutMillis: Long) = request("native.workflowCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis).optBoolean("closed", false)
            })
            workflow = workflowOwner
            val isolatedOwner = IsolatedRunNativeBridge(app, toolTransport = object : IsolatedScriptToolBridge.Transport {
                override fun call(params: JSONObject, timeoutMillis: Long) = request("native.toolCallback", params, timeoutMillis)
                override fun close(runId: String, token: String, timeoutMillis: Long) = request("native.toolCallback.cancel",
                    JSONObject().put("runId", runId).put("token", token), timeoutMillis).optBoolean("closed", false)
            })
            isolated = isolatedOwner
            val linuxOwner by lazy { LinuxVmManager(app).also { linux = it } }
            val input = ParcelFileDescriptor.AutoCloseInputStream(readSocket).bufferedReader()
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
                } catch (failure: Throwable) { done.completeExceptionally(failure) }
            }
            workers.execute {
                try {
                    val code = NativeRuntime.start(fixture.absolutePath, home.absolutePath, app.cacheDir.absolutePath,
                        app.applicationInfo.nativeLibraryDir, pair[1])
                    if (!done.isDone) done.completeExceptionally(IllegalStateException("Node exited before acceptance: $code"))
                } catch (failure: Throwable) { done.completeExceptionally(failure) }
            }
            try {
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
                if (diagnostics.isFile) report.putString("diagnostics", diagnostics.readText().takeLast(6000))
                report.putString("home", home.absolutePath)
            }
        } catch (failure: Throwable) {
            report.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}")
        } finally {
            try { workflow?.close() } catch (failure: Throwable) { passed = false; report.putString("workflowCloseFailure", failure.toString()) }
            try { isolated?.close() } catch (failure: Throwable) { passed = false; report.putString("isolatedCloseFailure", failure.toString()) }
            try { linux?.close() } catch (failure: Throwable) { passed = false; report.putString("linuxCloseFailure", failure.toString()) }
            try { socket?.close() } catch (_: Throwable) {}
            try { readSocket?.close() } catch (_: Throwable) {}
            workers.shutdownNow()
        }
        report.putString("suite", suite)
        finish(if (passed) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
