package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger

/** Drives the shipped Android profile through its public RPC and a local scripted model. */
internal class ProductionProfileAcceptanceScenario(
    private val home: File,
    private val workspace: File,
    private val runtime: File,
    private val fixtureId: String,
    private val expectWorkflow: Boolean = false,
) : Closeable {
    private val ready = CompletableFuture<Unit>()
    private val ended = CompletableFuture<JSONObject>()
    private val sessionId = "android-acceptance-production-$fixtureId"
    private fun secret(): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(
        ByteArray(32).also { SecureRandom().nextBytes(it) })
    private val key = secret()
    private val closeToken = secret()
    private val records = mutableMapOf("refs/DEEPSEEK_API_KEY" to key)
    private val proofFile = File(home, "production-profile-proof.json")
    private val startedNanos = System.nanoTime()
    @Volatile private var currentStage = "created"
    @Volatile private var stageStartedNanos = startedNanos
    @Volatile private var currentRequest: String? = null
    @Volatile private var lastNativeMethod: String? = null
    @Volatile private var lastNotification: String? = null
    @Volatile private var runtimeStatusPhase: String? = null
    @Volatile private var runtimeStatusErrorCode: String? = null
    private val nativeCalls = AtomicInteger()
    private val notifications = AtomicInteger()

    private fun mark(stage: String, request: String? = null) {
        currentStage = stage
        currentRequest = request
        stageStartedNanos = System.nanoTime()
    }

    /** Fixed diagnostic fields only: never RPC parameters, credentials, prompts or model bodies. */
    fun diagnostics(): JSONObject {
        val result = JSONObject().put("stage", currentStage).put("request", currentRequest ?: JSONObject.NULL)
            .put("elapsedMs", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedNanos))
            .put("stageElapsedMs", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - stageStartedNanos))
            .put("nativeCalls", nativeCalls.get()).put("notifications", notifications.get())
            .put("lastNativeMethod", lastNativeMethod ?: JSONObject.NULL)
            .put("lastNotification", lastNotification ?: JSONObject.NULL)
            .put("runtimeStatusPhase", runtimeStatusPhase ?: JSONObject.NULL)
            .put("runtimeStatusErrorCode", runtimeStatusErrorCode ?: JSONObject.NULL)
            .put("readyObserved", ready.isDone && !ready.isCompletedExceptionally).put("turnEndObserved", ended.isDone)
        val startup = File(home, "production-profile-startup.jsonl")
        result.put("startupFilePresent", startup.isFile).put("modelProofPresent", proofFile.isFile)
        result.put("bootstrapArtifacts", JSONObject()
            .put("profileManifest", File(home, "profiles/android/package.json").isFile)
            .put("workspaceSettings", File(home, "profiles/android/pnpm-workspace.yaml").isFile)
            .put("packageManagerState", File(home, "profiles/android/android-package-manager.json").isFile)
            .put("nodeLauncher", File(home, "package-manager/bin/node").exists()))
        try {
            if (startup.isFile && startup.length() in 1..32768) {
                val events = JSONArray()
                startup.readLines().takeLast(16).forEach { line ->
                    val row = JSONObject(line)
                    val safe = JSONObject()
                    for (field in listOf("stage", "elapsedMs", "errorName", "errorCode", "frames")) {
                        if (row.has(field)) safe.put(field, row.get(field))
                    }
                    events.put(safe)
                }
                result.put("startup", events)
            }
            if (proofFile.isFile && proofFile.length() in 1..65536) {
                val proof = JSONObject(proofFile.readText())
                val summary = JSONObject()
                for (field in listOf("agentCalls", "titleCalls", "childCalls", "ptcRead", "linuxPython", "closed", "lastRequestStage", "failureStage",
                    "lastSocketPeer", "failedSocketPeer", "lastPeerAddressCheck", "lastAuthenticatedRequest", "failedRequest",
                    "unownedRequestCount", "lastUnownedRequest")) {
                    if (proof.has(field)) summary.put(field, proof.get(field))
                }
                summary.put("failed", !proof.isNull("failure"))
                result.put("model", summary)
            }
        } catch (failure: Throwable) { result.put("diagnosticReadFailureType", failure.javaClass.name) }
        return result
    }

    /** Class names and bounded stack locations omit exception messages that could contain RPC values. */
    fun failureDiagnostics(failure: Throwable): JSONObject {
        val causes = JSONArray()
        var current: Throwable? = failure
        repeat(4) {
            current?.let { error ->
                causes.put(JSONObject().put("type", error.javaClass.name)
                    .put("frames", JSONArray(error.stackTrace.take(10).map { it.toString().take(240) }))
                    .put("suppressedTypes", JSONArray(error.suppressed.take(4).map { it.javaClass.name })))
                current = error.cause
            }
        }
        return diagnostics().put("causes", causes)
    }

    init {
        require(UUID.fromString(fixtureId).toString() == fixtureId && UUID.fromString(fixtureId).version() == 4)
        require(home.name == fixtureId && home.parentFile?.name == "native-runtime-acceptance")
        require(workspace.name == ".device-acceptance-$fixtureId")
        // The native test owner creates a fresh App-private home. No credential value goes to proof or diagnostics.
        val authentication = JSONObject().put("schema", 1).put("caseId", fixtureId).put("modelKey", key).put("closeToken", closeToken)
        Files.write(File(home, "production-profile-auth.json").toPath(), authentication.toString().toByteArray(Charsets.UTF_8),
            StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
    }

    fun handlesNative(method: String): Boolean = method.startsWith("native.credentials.") || method in setOf(
        "native.storage.root", "native.web.preferences", "native.network.addresses", "native.documents.roots",
        "native.attachments.directory", "native.attachmentFiles.directory", "native.exports.directory",
    )

    @Synchronized fun handleNative(method: String, params: JSONObject): Any? {
        lastNativeMethod = method
        nativeCalls.incrementAndGet()
        return when (method) {
        "native.credentials.get" -> {
            val name = params.getString("name")
            require(name.length in 1..256)
            records[name]
        }
        "native.credentials.names" -> JSONArray(records.keys.toList())
        "native.credentials.set" -> {
            val name = params.getString("name")
            val value = params.getString("value")
            when (name) {
                "refs/DEEPSEEK_API_KEY" -> require(value == key) { "Only the synthetic model key may be stored" }
                "records/client-connection/browser-session" -> {
                    require(value.length in 1..512) { "Invalid fixture browser credential size" }
                    val record = JSONObject(value)
                    require(record.keys().asSequence().toSet() == setOf("kind", "payload") && record.getString("kind") == "grant")
                    val payload = record.getJSONObject("payload")
                    require(payload.keys().asSequence().toSet() == setOf("version", "secret") && payload.getInt("version") == 1)
                    val secret = payload.getString("secret")
                    require(secret.matches(Regex("[A-Za-z0-9_-]{43}")) && java.util.Base64.getUrlDecoder().decode(secret).size == 32)
                }
                else -> error("Production fixture refuses account or unrelated credential writes")
            }
            records[name] = value
            true
        }
        "native.credentials.remove" -> error("Production acceptance credentials cannot be removed")
        "native.storage.root" -> home.canonicalPath
        "native.web.preferences" -> JSONObject().put("enabled", false).put("scope", "local").put("port", 3080)
        "native.network.addresses" -> JSONObject().put("addresses", JSONArray())
        "native.documents.roots" -> JSONArray()
        "native.attachments.directory", "native.attachmentFiles.directory", "native.exports.directory" -> {
            val folder = File(home, "fixture-files/${method.substringAfter("native.").substringBefore('.')}")
            check(folder.mkdirs() || folder.isDirectory)
            folder.canonicalPath
        }
        else -> error("Unsupported isolated production fixture RPC: $method")
        }
    }

    fun onNotification(method: String, params: JSONObject) {
        lastNotification = method.take(80)
        notifications.incrementAndGet()
        if (method == "runtime.status") {
            runtimeStatusPhase = params.optString("phase").takeIf { it.matches(Regex("[a-z-]{1,48}")) }
            runtimeStatusErrorCode = Regex("\\b(?:ERR_[A-Z_]+|EACCES|EPERM|ENOENT|EIO)\\b")
                .find(params.optString("error"))?.value
            if (runtimeStatusPhase == "failed") ready.completeExceptionally(IllegalStateException("Runtime reported failed initialization"))
        }
        if (method == "runtime.ready") ready.complete(Unit)
        if (method == "session.event" && params.optString("sessionId") == sessionId) {
            val event = params.getJSONObject("event")
            if (event.optString("type") == "turn/end") ended.complete(event)
        }
    }

    fun run(request: (String, JSONObject, Long) -> JSONObject): JSONObject {
        val started = System.nanoTime()
        var submitted = false
        fun call(method: String, params: JSONObject, timeout: Long): JSONObject {
            mark("rpc-wait", method)
            return request(method, params, timeout).also { mark("rpc-complete", method) }
        }
        try {
            mark("runtime-ready-wait")
            ready.get(90, TimeUnit.SECONDS)
            val info = call("runtime.info", JSONObject(), 15000)
            check(info.getString("profile") == "android" && info.getString("platform") == "android")
            check(File(info.getString("workspace")).canonicalFile == workspace.canonicalFile)
            val permissions = call("runtime.permissions", JSONObject(), 15000).getJSONObject("programmaticTools")
            check(permissions.getJSONObject("modelPtc").getBoolean("available"))
            check(permissions.getJSONObject("modelWorkflow").getBoolean("available") == expectWorkflow)
            val created = call("session.ensure", JSONObject().put("sessionId", sessionId), 15000)
            check(created.getString("sessionId") == sessionId && created.getBoolean("created"))
            val accepted = call("session.send", JSONObject().put("sessionId", sessionId)
                .put("requestId", "production-$fixtureId").put("text", "Read the dedicated acceptance file, then run the offline Python check." +
                    if (expectWorkflow) " Then use a workflow to ask one child Agent for the supplied marker." else "")
                .put("provider", "deepseek-official").put("model", "deepseek-flash").put("selectModel", true), 15000)
            check(accepted.getBoolean("accepted"))
            submitted = true
            mark("turn-end-wait")
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(if (expectWorkflow) 240 else 150)
            var end: JSONObject? = null
            while (end == null) {
                requireHealthyProof()
                check(System.nanoTime() < deadline) { "Production profile turn did not end" }
                try { end = ended.get(250, TimeUnit.MILLISECONDS) } catch (_: TimeoutException) { /* Observe proof errors while the actual turn runs. */ }
            }
            check(end.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed") { "Production profile turn did not complete: $end" }
            val history = call("session.read", JSONObject().put("sessionId", sessionId).put("offset", 0), 15000)
            val historyText = history.getJSONArray("events").toString()
            check(historyText.contains("production-profile-complete-$fixtureId")) { "Final model response is absent from Session history" }
            val proof = requireHealthyProof()
            check(proof.getInt("agentCalls") == (if (expectWorkflow) 4 else 3) && proof.getBoolean("ptcRead") && proof.getBoolean("linuxPython"))
            check(proof.getBoolean("expectWorkflow") == expectWorkflow && proof.getBoolean("workflowCompleted") == expectWorkflow &&
                proof.getInt("childCalls") == (if (expectWorkflow) 1 else 0))
            check(proof.getBoolean("retirementConfirmed") && proof.getInt("guestUid") != info.getInt("uid"))
            val inputs = proof.getJSONObject("inputs")
            for (name in listOf("bootstrap.mjs", "node_modules/@minnnng/dsh-android-runtime/index.mjs")) {
                check(inputs.getString(name) == hash(File(runtime, name).readBytes())) { "Shipped runtime input changed: $name" }
            }
            mark("durable-session-wait")
            val logs = awaitDurableSession(proof)
            close()
            requireHealthyProof()
            mark("completed")
            val checks = JSONArray().put(JSONObject().put("name", "shipped-android-profile-model-ptc-and-offline-linux")
                .put("status", "passed").put("profile", "android").put("sessionId", sessionId)
                .put("caseId", fixtureId).put("appUid", info.getInt("uid"))
                .put("modelCalls", proof.getInt("agentCalls")).put("ptcRead", true).put("linuxPython", true)
                .put("expectWorkflow", expectWorkflow).put("workflowCompleted", expectWorkflow).put("childCalls", proof.getInt("childCalls"))
                .put("childSessionId", proof.opt("childSessionId"))
                .put("networkSchemaAbsent", true).put("guestUid", proof.getInt("guestUid"))
                .put("retirementConfirmed", true).put("modelServerClosed", true)
                .put("sessionFiles", logs).put("runtimeInputs", inputs)
                .put("toolSchemaSha256", proof.getString("toolSchemaSha256"))
                .put("elapsedMs", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)))
            return JSONObject().put("passed", true).put("complete", true).put("reports", JSONArray()
                .put(JSONObject().put("suite", "production-profile").put("checks", checks)))
        } catch (failure: Throwable) {
            val observed = failureDiagnostics(failure)
            if (submitted && !ended.isDone) {
                try {
                    call("session.cancel", JSONObject().put("sessionId", sessionId), 15000)
                    ended.get(30, TimeUnit.SECONDS)
                } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            }
            throw IllegalStateException("Production profile failed: $observed", failure)
        }
    }

    private fun requireHealthyProof(): JSONObject {
        check(proofFile.isFile && proofFile.length() in 1..65536) { "Production model evidence is absent or oversized" }
        val proof = JSONObject(proofFile.readText())
        check(proof.getInt("schema") == 1 && proof.getString("caseId") == fixtureId)
        check(proof.isNull("failure")) { "Production model rejected the turn: ${proof.optString("failure")}" }
        return proof
    }

    private fun awaitDurableSession(proof: JSONObject): JSONArray {
        val directory = File(home, "sessions")
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        do {
            val files = directory.walkTopDown().maxDepth(5).filter { it.isFile && it.name.endsWith(".jsonl") }.take(9).toList()
            check(files.size <= 8) { "Unexpected Session files in the isolated production fixture" }
            val evidence = JSONArray()
            var found = false
            var childFound = !expectWorkflow
            for (file in files) {
                check(file.length() in 1..8 * 1024 * 1024)
                val bytes = file.readBytes()
                val text = bytes.toString(Charsets.UTF_8)
                if (text.contains("production-profile-complete-$fixtureId") && text.contains("tool/ptc-dispatch-start") &&
                    text.contains("linux_exec") && text.contains("turn/end")) {
                    if (expectWorkflow) {
                        val events = text.lineSequence().filter { it.isNotBlank() }.map { JSONObject(it) }.toList()
                        val starts = events.filter { it.optString("type") == "tool-workflow/agent-start" }
                        val ends = events.filter { it.optString("type") == "tool-workflow/agent-end" }
                        val runs = events.filter { it.optString("type") == "tool-workflow/run-end" }
                        check(starts.size == 1 && ends.size == 1 && runs.size == 1)
                        val start = starts[0].getJSONObject("data")
                        val end = ends[0].getJSONObject("data")
                        val run = runs[0].getJSONObject("data")
                        check(start.getString("childId") == proof.getString("childSessionId"))
                        check(end.getString("runId") == start.getString("runId") && end.getInt("seq") == start.getInt("seq") &&
                            end.getString("outcome") == "completed")
                        check(run.getString("runId") == start.getString("runId") && run.getString("stopReason") == "completed")
                    }
                    found = true
                }
                if (expectWorkflow && file.parentFile?.name == proof.getString("childSessionId") &&
                    text.contains("production-child-$fixtureId") && text.contains("turn/end")) childFound = true
                evidence.put(JSONObject().put("path", file.relativeTo(home).invariantSeparatorsPath)
                    .put("bytes", bytes.size).put("sha256", hash(bytes)))
            }
            if (found && childFound) return evidence
            Thread.sleep(50)
        } while (System.nanoTime() < deadline)
        error("The completed PTC/Linux turn is absent from the dedicated durable Session")
    }

    @Synchronized override fun close() {
        mark("model-close")
        check(proofFile.isFile) { "Model listener closure is unconfirmed: proof absent; ${diagnostics()}" }
        check(proofFile.length() in 1..65536) { "Model closure proof is empty or oversized" }
        val proof = JSONObject(proofFile.readText())
        if (proof.optBoolean("closed")) return
        val port = proof.getInt("port")
        check(proof.getString("caseId") == fixtureId && port in 1..65535) { "Model closure identity or port is invalid" }
        val connection = URL("http://127.0.0.1:$port/acceptance/close").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Authorization", "Bearer $closeToken")
            connection.setRequestProperty("X-Dsh-Acceptance-Case", fixtureId)
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(0)
            connection.outputStream.use { }
            check(connection.responseCode == 200) { "Model close HTTP status=${connection.responseCode}; ${diagnostics()}" }
            connection.inputStream.use { it.readBytes() }
        } finally { connection.disconnect() }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!JSONObject(proofFile.readText()).optBoolean("closed")) {
            check(System.nanoTime() < deadline) { "Production model listener did not close" }
            Thread.sleep(25)
        }
    }

    private fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
}
