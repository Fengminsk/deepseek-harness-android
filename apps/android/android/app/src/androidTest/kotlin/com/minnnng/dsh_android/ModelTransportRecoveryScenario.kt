package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** One real model request is interrupted only after the shipped App reports its consumed text. */
internal class ModelTransportRecoveryScenario(
    private val home: File,
    private val workspace: File,
    private val runtime: File,
    private val fixtureId: String,
) : Closeable {
    // Reuse the exact isolated credentials, startup-native allowlist and authenticated listener closure.
    private val profile = ProductionProfileAcceptanceScenario(home, workspace, runtime, fixtureId)
    private val sessionId = "android-acceptance-transport-$fixtureId"
    private val ready = CompletableFuture<Unit>()
    private val partial = CompletableFuture<Unit>()
    private val ended = CompletableFuture<JSONObject>()
    private val proofFile = File(home, "production-profile-proof.json")
    @Volatile private var stage = "created"

    fun handlesNative(method: String): Boolean = profile.handlesNative(method)
    fun handleNative(method: String, params: JSONObject): Any? = profile.handleNative(method, params)
    fun diagnostics(): JSONObject = transportDiagnostics(profile.diagnostics())
    fun failureDiagnostics(failure: Throwable): JSONObject = transportDiagnostics(profile.failureDiagnostics(failure))

    private fun transportDiagnostics(result: JSONObject): JSONObject {
        result.remove("model")
        result.put("transportStage", stage)
            .put("partialConsumed", partial.isDone && !partial.isCompletedExceptionally)
            .put("transportTurnEnded", ended.isDone)
        try {
            if (proofFile.isFile) {
                check(proofFile.length() in 1..65536)
                result.put("transportModel", modelDiagnostics(JSONObject(proofFile.readText()), fixtureId))
            }
        } catch (_: Throwable) { result.put("transportModelDiagnosticInvalid", true) }
        return result
    }

    companion object {
        private val requestStages = setOf("none", "authenticate", "peer", "method", "body", "control-authentication",
            "disconnect", "verify", "close", "model-authentication", "model-json", "auxiliary-response",
            "agent-identity", "request-shape", "retry-continuation", "partial-response", "retry-response")
        private val failureReasons = setOf("method", "control-credential", "control-case", "control-path", "model-path",
            "model-credential", "agent-session", "agent-prompt", "model-call-limit", "retry-before-disconnect",
            "request-continuation", "evidence-validation", "listener-close", "validation-or-io")
        private val requestFields = setOf("model", "stream", "messages", "max_tokens", "thinking", "output_config", "system",
            "temperature", "stop_sequences", "tools", "metadata", "tool_choice", "dsh_session_log", "dsh_plugin_packages", "other")
        private fun digest(value: Any): String {
            check(value is String && value.matches(Regex("[0-9a-f]{64}")))
            return value
        }
        private fun fieldShape(value: JSONObject): JSONObject {
            val name = value.get("name"); check(name is String && name in requestFields)
            val type = value.get("type"); check(type is String && type in setOf("null", "array", "object", "string", "number", "boolean"))
            val bytes = value.get("bytes"); check(bytes is Int && bytes in 0..2 * 1024 * 1024)
            val entries = value.get("entries")
            check(entries == JSONObject.NULL || entries is Int && entries in 0..2 * 1024 * 1024)
            return JSONObject().put("name", name).put("type", type).put("bytes", bytes).put("entries", entries)
                .put("nameSha256", digest(value.get("nameSha256"))).put("sha256", digest(value.get("sha256")))
                .put("semanticSha256", digest(value.get("semanticSha256")))
        }

        /** Bounded typed facts only; request bodies, headers and exception messages never leave the private proof. */
        internal fun modelDiagnostics(proof: JSONObject, caseId: String): JSONObject {
            check(proof.get("schema") is Int && proof.getInt("schema") == 1 && proof.getString("caseId") == caseId &&
                proof.getString("sessionId") == "android-acceptance-transport-$caseId")
            val result = JSONObject()
            for (field in listOf("modelCalls", "titleCalls", "disconnects", "unauthenticatedRequests")) {
                val value = proof.get(field)
                check(value is Int && value in 0..1000000)
                result.put(field, value)
            }
            for (field in listOf("partialFlushed", "verified", "closed")) {
                val value = proof.get(field)
                check(value is Boolean)
                result.put(field, value)
            }
            for ((field, values) in listOf("lastRequestStage" to requestStages, "failureStage" to requestStages,
                "failureReason" to failureReasons)) {
                val value = proof.get(field)
                check(value == JSONObject.NULL || value is String && value in values)
                if (field == "lastRequestStage") check(value is String)
                result.put(field, value)
            }
            for (field in listOf("requestHashes", "connectionIds")) {
                val values = proof.getJSONArray(field)
                check(values.length() <= 2)
                val projected = JSONArray()
                for (i in 0 until values.length()) {
                    val value = values.get(i)
                    check(if (field == "requestHashes") value is String && value.matches(Regex("[0-9a-f]{64}"))
                        else value is Int && value in 1..1000000)
                    projected.put(value)
                }
                result.put(field, projected)
            }
            if (!proof.isNull("requestDifference")) {
                val difference = proof.getJSONObject("requestDifference")
                val safe = JSONObject()
                for (field in listOf("rawBodyEqual", "nonMessageFieldsEqual", "semanticNonMessageFieldsEqual", "stableFieldsEqual", "existingBlocksEqual")) {
                    val value = difference.get(field); check(value is Boolean); safe.put(field, value)
                }
                for (field in listOf("firstBlocks", "retryBlocks")) {
                    val value = difference.get(field); check(value is Int && value in 0..256); safe.put(field, value)
                }
                val changes = difference.getJSONArray("changedFields"); check(changes.length() <= 64)
                val fields = JSONArray()
                for (i in 0 until changes.length()) {
                    val change = changes.getJSONObject(i)
                    val name = change.get("name"); check(name is String && name in requestFields)
                    val nameHash = digest(change.get("nameSha256"))
                    val changed = change.get("semanticChanged"); check(changed is Boolean)
                    val entry = JSONObject().put("name", name).put("nameSha256", nameHash).put("semanticChanged", changed)
                    check(!change.isNull("before") || !change.isNull("after"))
                    for (side in listOf("before", "after")) {
                        val shape = if (change.isNull(side)) JSONObject.NULL else fieldShape(change.getJSONObject(side)).also {
                            check(it.getString("name") == name && it.getString("nameSha256") == nameHash)
                        }
                        entry.put(side, shape)
                    }
                    fields.put(entry)
                }
                safe.put("changedFields", fields)
                result.put("requestDifference", safe)
            }
            check(proof.has("failure"))
            val failed = !proof.isNull("failure")
            result.put("failed", failed)
            if (failed) {
                val failure = proof.getJSONObject("failure")
                val name = failure.optString("errorName")
                val code = failure.optString("errorCode")
                result.put("errorName", if (name in setOf("AssertionError", "Error", "TypeError", "SyntaxError",
                    "RangeError", "AggregateError", "AbortError")) name else "Error")
                result.put("errorCode", if (code in setOf("ERR_ASSERTION", "ECONNRESET", "EPIPE", "ETIMEDOUT",
                    "ERR_STREAM_PREMATURE_CLOSE", "ABORT_ERR")) code else JSONObject.NULL)
            }
            return result
        }
    }

    fun onNotification(method: String, params: JSONObject) {
        profile.onNotification(method, params)
        if (method == "runtime.ready") ready.complete(Unit)
        if (method == "runtime.status" && params.optString("phase") == "failed") {
            ready.completeExceptionally(IllegalStateException("Shipped runtime initialization failed"))
        }
        if (params.optString("sessionId") != sessionId) return
        if (method == "session.live") {
            val value = params.optJSONObject("value") ?: return
            val content = value.optJSONArray("content") ?: return
            val text = (0 until content.length()).map { content.getJSONObject(it) }
                .filter { it.optString("type") == "text" }.joinToString("") { it.getString("text") }
            if (text == "transport-partial-$fixtureId" && value.getInt("turn") == 1 && value.getInt("step") == 1) {
                partial.complete(Unit)
            }
        }
        if (method == "session.event") {
            val event = params.getJSONObject("event")
            if (event.optString("type") == "turn/end") ended.complete(event)
        }
    }

    fun run(request: (String, JSONObject, Long) -> JSONObject): JSONObject {
        val started = System.nanoTime()
        var submitted = false
        try {
            stage = "ready-wait"
            ready.get(90, TimeUnit.SECONDS)
            val info = request("runtime.info", JSONObject(), 15000)
            check(info.getString("profile") == "android" && info.getString("platform") == "android")
            check(File(info.getString("workspace")).canonicalFile == workspace.canonicalFile)
            val created = request("session.ensure", JSONObject().put("sessionId", sessionId), 15000)
            check(created.getBoolean("created") && created.getString("sessionId") == sessionId)
            stage = "send-once"
            val accepted = request("session.send", JSONObject().put("sessionId", sessionId)
                .put("requestId", "transport-$fixtureId").put("text", "Return transport-recovered-$fixtureId.")
                .put("provider", "deepseek-official").put("model", "deepseek-flash").put("selectModel", true), 15000)
            check(accepted.getBoolean("accepted"))
            submitted = true
            stage = "partial-consumed-wait"
            awaitHealthy(partial, 30)
            stage = "disconnect"
            val disconnected = control("disconnect")
            check(disconnected.getBoolean("disconnected") && disconnected.getString("mode") == "reset")
            stage = "retry-completion-wait"
            val end = awaitHealthy(ended, 30)
            check(end.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed")
            val events = request("session.read", JSONObject().put("sessionId", sessionId).put("offset", 0), 15000)
                .getJSONArray("events")
            stage = "durable-session-wait"
            val (durable, logs) = durableSession()
            stage = "verify-original-retry"
            val evidence = control("verify", JSONObject().put("events", events).put("durableEvents", durable))
            check(evidence.getBoolean("partialConsumed") && evidence.getBoolean("durableRetryMatched"))
            val proof = healthyProof()
            check(proof.getBoolean("verified") && proof.getInt("modelCalls") == 2 && proof.getInt("disconnects") == 1)
            val inputs = proof.getJSONObject("inputs")
            for (name in listOf("bootstrap.mjs", "node_modules/@minnnng/dsh-android-runtime/index.mjs")) {
                check(inputs.getString(name) == hash(File(runtime, name).readBytes())) { "Shipped runtime input changed" }
            }
            val live = request("runtime.live", JSONObject(), 15000)
            check(!live.getJSONObject("streaming").has(sessionId))
            check(!live.getJSONObject("errors").has(sessionId))
            val finalInfo = request("runtime.info", JSONObject(), 15000)
            for (field in listOf("node", "platform", "arch", "uid", "workspace", "profile")) {
                check(finalInfo.get(field) == info.get(field)) { "Runtime metadata changed during recovery" }
            }
            close()
            check(healthyProof().getBoolean("closed"))
            stage = "completed"
            val check = JSONObject().put("name", "shipped-android-profile-active-model-transport-recovery")
                .put("status", "passed").put("profile", "android").put("caseId", fixtureId).put("sessionId", sessionId)
                .put("appUid", info.getInt("uid")).put("sendCount", 1).put("modelServerClosed", true)
                .put("evidence", evidence).put("sessionFiles", logs).put("runtimeInputs", inputs)
                .put("elapsedMs", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started))
            return JSONObject().put("passed", true).put("complete", true).put("reports", JSONArray().put(
                JSONObject().put("suite", "model-transport-recovery").put("checks", JSONArray().put(check))))
        } catch (failure: Throwable) {
            val observed = failureDiagnostics(failure)
            if (submitted && !ended.isDone) {
                try {
                    request("session.cancel", JSONObject().put("sessionId", sessionId), 15000)
                    ended.get(15, TimeUnit.SECONDS)
                } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            }
            throw IllegalStateException("Model transport recovery failed: $observed", failure)
        }
    }

    private fun <T> awaitHealthy(future: CompletableFuture<T>, seconds: Long): T {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (true) {
            healthyProof()
            check(System.nanoTime() < deadline) { "Transport observation did not arrive: $stage" }
            try { return future.get(100, TimeUnit.MILLISECONDS) } catch (_: TimeoutException) { }
        }
    }

    private fun healthyProof(): JSONObject {
        check(proofFile.isFile && proofFile.length() in 1..65536)
        return JSONObject(proofFile.readText()).also {
            check(it.getInt("schema") == 1 && it.getString("caseId") == fixtureId && it.getString("sessionId") == sessionId)
            check(it.isNull("failure")) { "Local model rejected the recovery request" }
        }
    }

    private fun control(action: String, body: JSONObject? = null): JSONObject {
        check(action in setOf("disconnect", "verify"))
        val proof = healthyProof()
        val port = proof.getInt("port")
        check(port in 1..65535)
        val auth = JSONObject(File(home, "production-profile-auth.json").readText())
        check(auth.getString("caseId") == fixtureId)
        val bytes = (body?.toString() ?: "").toByteArray(Charsets.UTF_8)
        check(bytes.size <= 2 * 1024 * 1024)
        val connection = URL("http://127.0.0.1:$port/acceptance/$action").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Authorization", "Bearer ${auth.getString("closeToken")}")
            connection.setRequestProperty("X-Dsh-Acceptance-Case", fixtureId)
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            check(connection.responseCode == 200) { "Transport control did not succeed" }
            val result = connection.inputStream.use { it.readNBytes(65537) }
            check(result.size <= 65536)
            return JSONObject(result.toString(Charsets.UTF_8))
        } finally { connection.disconnect() }
    }

    private fun durableSession(): Pair<JSONArray, JSONArray> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        val directory = File(home, "sessions")
        do {
            val files = directory.walkTopDown().maxDepth(5).filter { it.isFile && it.name.endsWith(".jsonl") }.take(9).toList()
            check(files.size <= 8)
            for (file in files) {
                if (file.parentFile?.name != sessionId) continue
                check(file.length() in 1..1024 * 1024)
                val bytes = file.readBytes()
                val text = bytes.toString(Charsets.UTF_8)
                if (!text.endsWith("\n")) continue
                val rows = text.lineSequence().filter { it.isNotBlank() }.map { JSONObject(it) }.toList()
                check(rows.isNotEmpty())
                val header = rows.first()
                check(header.getString("type") == "session" && header.getInt("version") == 4 && header.getString("id") == sessionId)
                val events = rows.drop(1)
                if (events.none { it.optString("type") == "turn/end" }) continue
                val logs = JSONArray().put(JSONObject().put("path", file.relativeTo(home).invariantSeparatorsPath)
                    .put("bytes", bytes.size).put("sha256", hash(bytes)))
                return JSONArray(events) to logs
            }
            Thread.sleep(25)
        } while (System.nanoTime() < deadline)
        error("Dedicated completed retry was not persisted")
    }

    override fun close() { stage = "model-close"; profile.close() }
    private fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
}
