package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Runs the actual AndroidTest evidence validator against SDK JSON, without an account or Android service. */
fun main(args: Array<String>) {
    val id = "a0000000-0000-4000-8000-000000000001"
    val session = "android-account-acceptance-$id"
    val request = "account-request-$id"
    val model = "deepseek-flash"
    var checks = 0
    fun case(action: () -> Unit) { action(); checks++ }
    fun rejects(code: String, action: () -> Unit) {
        try { action() } catch (failure: AgentServiceTaskEvidence.Rejected) { check(failure.code == code); return }
        error("Expected rejection $code")
    }
    fun catalog(provider: String = "deepseek-account", listed: String = model): JSONObject = JSONObject()
        .put("default", JSONObject().put("provider", provider).put("model", model))
        .put("groups", JSONArray().put(JSONObject().put("id", "deepseek-account")
            .put("models", JSONArray().put(JSONObject().put("id", listed)))))
    fun event(seq: Int, type: String, data: JSONObject) = JSONObject().put("seq", seq).put("type", type).put("time", seq).put("data", data)
    fun text(value: String) = JSONObject().put("type", "text").put("text", value)
    fun rows(): JSONArray = JSONArray()
        .put(event(0, "session/title", JSONObject().put("title", "Synthetic title")))
        .put(event(1, "user/message", JSONObject().put("source", JSONObject().put("kind", "user").put("rpcId", request))
            .put("content", JSONArray().put(text(AgentServiceTaskEvidence.prompt(id))))))
        .put(event(2, "turn/start", JSONObject().put("turn", 1)))
        .put(event(3, "request/header", JSONObject().put("header", JSONObject().put("config",
            JSONObject().put("provider", "deepseek-account").put("model", model)))))
        .put(event(4, "user/message", JSONObject().put("source", JSONObject().put("kind", "runtime-context"))
            .put("content", JSONArray().put(text("Synthetic context")))))
        .put(event(5, "assistant/message", JSONObject().put("turn", 1).put("step", 1)
            .put("message", JSONObject().put("content", JSONArray()
                .put(JSONObject().put("type", "reasoning").put("text", "Synthetic reasoning"))
                .put(text(AgentServiceTaskEvidence.marker(id)))))))
        .put(event(6, "turn/end", JSONObject().put("turn", 1).put("reason", JSONObject().put("kind", "completed"))))
    fun verify(rows: JSONArray, durable: JSONArray = rows()) = AgentServiceTaskEvidence.completed(rows, durable, id, request, model)
    case { check(AgentServiceTaskEvidence.model(catalog()) == model) }
    case { rejects("DEFAULT_NOT_ACCOUNT") { AgentServiceTaskEvidence.model(catalog("deepseek-official")) } }
    case { rejects("MODEL_UNAVAILABLE") { AgentServiceTaskEvidence.model(catalog(listed = "other")) } }
    case { rejects("ACCOUNT_UNAVAILABLE") { AgentServiceTaskEvidence.model(catalog().put("groups", JSONArray())) } }
    fun notice() = JSONObject().put("matchingCount", 1).put("tag", "pocket-completed:$session").put("notificationId", 3)
        .put("packageMatches", true).put("preview", AgentServiceTaskEvidence.marker(id)).put("channelId", "task-completed")
        .put("visibilityPrivate", true).put("autoCancel", true).put("contentIntentPresent", true).put("contentIntentCreatorMatches", true)
    case {
        val proof = AgentServiceTaskEvidence.completionNotice(notice(), id)
        check(proof.getBoolean("observed") && proof.getInt("matchingCount") == 1)
        check(proof.getString("previewSha256") == AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.marker(id).toByteArray()))
        check(!proof.toString().contains(AgentServiceTaskEvidence.marker(id)) && !proof.toString().contains(session))
    }
    for ((field, bad) in listOf("matchingCount" to 0, "matchingCount" to 2, "tag" to "pocket-completed:other-session",
            "notificationId" to 4, "packageMatches" to false)) case {
        rejects("NOTICE_IDENTITY_MISMATCH") { AgentServiceTaskEvidence.completionNotice(notice().put(field, bad), id) }
    }
    case { rejects("NOTICE_PREVIEW_MISMATCH") { AgentServiceTaskEvidence.completionNotice(notice().put("preview", "Private unrelated message"), id) } }
    for ((field, bad) in listOf("channelId" to "background", "visibilityPrivate" to false, "autoCancel" to false)) case {
        rejects("NOTICE_PRESENTATION_MISMATCH") { AgentServiceTaskEvidence.completionNotice(notice().put(field, bad), id) }
    }
    for (field in listOf("contentIntentPresent", "contentIntentCreatorMatches")) case {
        rejects("NOTICE_INTENT_MISMATCH") { AgentServiceTaskEvidence.completionNotice(notice().put(field, false), id) }
    }
    case {
        fun active(id: String, status: String) = JSONObject().put("active", JSONArray().put(
            JSONObject().put("sessionId", id).put("status", status)))
        check(AgentServiceTaskEvidence.runningOwnTask(active(session, "running"), session))
        check(!AgentServiceTaskEvidence.runningOwnTask(active("someone-else", "running"), session))
        check(!AgentServiceTaskEvidence.runningOwnTask(active(session, "waiting"), session))
    }
    case {
        val result = verify(rows())
        check(result.getInt("userMessageCount") == 1 && result.getInt("assistantMarkerMatches") == 1)
        check(result.getInt("eventCount") == 7 && result.getInt("endSeq") == 6)
        check(result.getString("historySha256").matches(Regex("[0-9a-f]{64}")))
        check(!result.toString().contains(AgentServiceTaskEvidence.marker(id)))
    }
    case {
        val value = rows(); value.getJSONObject(5).getJSONObject("data").getJSONObject("message")
            .put("content", JSONArray().put(text("Unrelated response")))
        rejects("ASSISTANT_MARKER_MISMATCH") { verify(value) }
    }
    case {
        val value = rows(); value.remove(5)
        rejects("EVENT_COUNT_INVALID") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(5).getJSONObject("data").put("interrupted", true)
        rejects("ASSISTANT_INTERRUPTED") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(6).getJSONObject("data").getJSONObject("reason").put("kind", "error")
        rejects("TURN_NOT_COMPLETED") { verify(value) }
    }
    case {
        val value = rows(); value.put(event(7, "tool/start", JSONObject()))
        rejects("TOOL_INVOKED") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(5).getJSONObject("data").getJSONObject("message").getJSONArray("content")
            .put(JSONObject().put("type", "tool-call").put("name", "read"))
        rejects("ASSISTANT_BLOCK_INVALID") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(1).getJSONObject("data").getJSONObject("source").put("rpcId", "wrong")
        rejects("REQUEST_ID_MISMATCH") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", "Other input")
        rejects("USER_CONTENT_MISMATCH") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(3).getJSONObject("data").getJSONObject("header").getJSONObject("config").put("model", "other")
        rejects("MODEL_CHANGED") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(6).getJSONObject("data").put("turn", 2)
        rejects("TURN_CHANGED") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(5).put("seq", 1)
        rejects("EVENT_ORDER_INVALID") { verify(value) }
    }
    case {
        val value = rows(); value.put(event(7, "turn/end", JSONObject().put("turn", 1).put("reason", JSONObject().put("kind", "completed"))))
        rejects("EVENT_COUNT_INVALID") { verify(value) }
    }
    case {
        val value = rows(); value.getJSONObject(4).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", "Changed context")
        rejects("DURABLE_MISMATCH") { verify(rows(), value) }
    }
    fun archive(name: String, content: String, extra: Boolean = false): ByteArray {
        val buffer = ByteArrayOutputStream()
        ZipOutputStream(buffer).use { zip ->
            zip.putNextEntry(ZipEntry(name)); zip.write(content.toByteArray()); zip.closeEntry()
            if (extra) { zip.putNextEntry(ZipEntry("media/private.txt")); zip.write(1); zip.closeEntry() }
        }
        return buffer.toByteArray()
    }
    fun log(id: String = session): String = JSONObject().put("type", "session").put("version", 4).put("id", id).toString() + "\n" +
        (0 until rows().length()).joinToString("\n") { rows().getJSONObject(it).toString() } + "\n"
    fun read(bytes: ByteArray) = AgentServiceTaskEvidence.readExport(ByteArrayInputStream(bytes), session)
    case { check(verify(rows(), read(archive("session.v4.jsonl", log()))).getInt("assistantMarkerMatches") == 1) }
    case { rejects("EXPORT_SESSION_MISMATCH") { read(archive("session.v4.jsonl", log("other-session"))) } }
    case { rejects("EXPORT_TRUNCATED") { read(archive("session.v4.jsonl", log().trimEnd())) } }
    case { rejects("EXPORT_UNEXPECTED_ENTRY") { read(archive("session.v4.jsonl", log(), true)) } }
    case { rejects("EXPORT_ENTRY_INVALID") { read(archive("../session.v4.jsonl", log())) } }
    case { rejects("EXPORT_OVERSIZED") { read(archive("session.v4.jsonl", "x".repeat(1024 * 1024 + 1))) } }
    fun radioRows(): JSONArray {
        val base = rows()
        base.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", AgentServiceTaskEvidence.radioPrompt(id))
        val receipt = JSONObject().put("id", "b0000000-0000-4000-8000-000000000002").put("sessionId", session)
            .put("status", "completed").put("exitCode", 0).put("retirementConfirmed", true)
            .put("cancelled", false).put("timedOut", false).put("truncated", false).put("cancelRequested", false)
            .put("diskCommitted", true).put("guestUid", 99001).put("output", JSONObject()
                .put("marker", AgentServiceTaskEvidence.marker(id)).put("sha256", AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.marker(id).toByteArray()))
                .put("waitMs", 40000).toString())
        val resultMessage = JSONObject(File(args[0], "tool-result-message.json").readText())
        check(resultMessage.getString("toolCallId") == "radio-call" && resultMessage.getJSONObject("source").getString("kind") == "tool")
        resultMessage.put("content", JSONArray().put(text(receipt.toString())))
        return JSONArray((0..4).map { base.getJSONObject(it) })
            .put(event(5, "assistant/message", JSONObject().put("turn", 1).put("step", 1).put("message", JSONObject()
                .put("content", JSONArray().put(JSONObject().put("type", "tool-call").put("id", "radio-call").put("name", "linux_exec"))))))
            .put(event(6, "tool/call", JSONObject().put("turn", 1).put("step", 1).put("callId", "radio-call").put("name", "linux_exec")
                .put("arguments", JSONObject().put("command", AgentServiceTaskEvidence.radioCommand(id)).put("timeoutMs", 120000).toString())))
            .put(event(7, "tool/result", JSONObject().put("turn", 1).put("step", 1).put("message", resultMessage))
                .put("surfaceOp", "append").put("sourceEventSeqs", JSONArray().put(6)))
            .put(base.getJSONObject(5).put("seq", 8)).put(base.getJSONObject(6).put("seq", 9))
    }
    fun verifyRadio(value: JSONArray, durable: JSONArray = radioRows()) =
        AgentServiceTaskEvidence.completed(value, durable, id, request, model, true)
    fun changeReceipt(rows: JSONArray, change: (JSONObject) -> Unit) {
        val text = rows.getJSONObject(7).getJSONObject("data").getJSONObject("message").getJSONArray("content").getJSONObject(0)
        val receipt = JSONObject(text.getString("text")); change(receipt); text.put("text", receipt.toString())
    }
    case {
        val result = verifyRadio(radioRows())
        check(result.getInt("toolCalls") == 1 && result.getLong("toolStartSeq") == 6L && result.getLong("toolEndSeq") == 7L)
        check(result.getJSONObject("linuxReceipt").getLong("waitMs") == 40000L)
        check(!result.toString().contains(AgentServiceTaskEvidence.marker(id)))
    }
    case {
        val value = radioRows(); value.getJSONObject(6).getJSONObject("data").put("arguments",
            JSONObject().put("command", "sleep 40").put("timeoutMs", 120000).toString())
        rejects("RADIO_ARGUMENTS_CHANGED") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); value.getJSONObject(6).getJSONObject("data").put("arguments",
            JSONObject().put("command", AgentServiceTaskEvidence.radioCommand(id)).put("timeoutMs", 120000).put("networkHosts", JSONArray().put("example.com")).toString())
        rejects("RADIO_ARGUMENTS_CHANGED") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); value.getJSONObject(7).getJSONObject("data").getJSONObject("message").put("toolCallId", "wrong")
        rejects("RADIO_TOOL_FAILED") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); value.getJSONObject(7).put("sourceEventSeqs", JSONArray().put(5))
        rejects("RADIO_RESULT_SOURCE_MISMATCH") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); changeReceipt(value) { it.put("cancelRequested", true) }
        rejects("RADIO_EXECUTION_FAILED") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); changeReceipt(value) { it.put("sessionId", "another-session") }
        rejects("RADIO_RECEIPT_SESSION_MISMATCH") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); changeReceipt(value) { val output = JSONObject(it.getString("output")); output.put("waitMs", 1000); it.put("output", output.toString()) }
        rejects("RADIO_OUTPUT_MISMATCH") { verifyRadio(value) }
    }
    case {
        val value = radioRows(); value.put(JSONObject(value.getJSONObject(6).toString()).put("seq", 10))
        rejects("EVENT_COUNT_INVALID") { verifyRadio(value) }
    }
    case {
        val stored = radioRows(); changeReceipt(stored) { val output = JSONObject(it.getString("output")); output.put("waitMs", 41000); it.put("output", output.toString()) }
        rejects("DURABLE_MISMATCH") { verifyRadio(radioRows(), stored) }
    }
    if (args.size == 3) case {
        // Optional unchanged shipped-profile log and original exporter output; no account content is printed.
        val raw = File(args[1]).readLines().filter { it.isNotBlank() }.map { JSONObject(it) }
        val header = raw.first()
        val actual = File(args[2]).inputStream().use { AgentServiceTaskEvidence.readExport(it, header.getString("id")) }
        check(header.getString("type") == "session" && header.getInt("version") == 4)
        check(actual.length() == raw.size - 1)
        check((0 until actual.length()).all { actual.getJSONObject(it).getLong("seq") == raw[it + 1].getLong("seq") })
        val events = (0 until actual.length()).map { actual.getJSONObject(it) }
        val user = events.single { it.getString("type") == "user/message" && it.getJSONObject("data").getJSONObject("source").getString("kind") == "user" }
        check(user.getJSONObject("data").getJSONObject("source").getString("rpcId").isNotBlank())
        check(events.single { it.getString("type") == "turn/end" }.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed")
        check(events.single { it.getString("type") == "assistant/message" }.getJSONObject("data").getJSONObject("message").getJSONArray("content").length() > 0)
        println("Original profile JSONL and original exporter: header, sequence, rpcId, assistant and completed end matched")
    }
    println("AgentServiceTaskEvidence: $checks checks passed")
}
