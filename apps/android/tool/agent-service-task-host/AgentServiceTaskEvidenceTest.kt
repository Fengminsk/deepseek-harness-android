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
