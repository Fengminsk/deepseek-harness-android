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
    fun programRows(exercise: String): JSONArray {
        val base = rows()
        base.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0)
            .put("text", AgentServiceProgrammaticEvidence.prompt(id, exercise))
        val tool = if (exercise == "ptc") "android_ptc" else "workflow"
        val out = JSONArray((0..4).map { base.getJSONObject(it) })
            .put(event(5, "assistant/message", JSONObject().put("turn", 1).put("step", 1).put("message", JSONObject()
                .put("content", JSONArray().put(JSONObject().put("type", "tool-call").put("id", "program-call").put("name", tool))))))
            .put(event(6, "tool/call", JSONObject().put("turn", 1).put("step", 1).put("callId", "program-call").put("name", tool)
                .put("arguments", AgentServiceProgrammaticEvidence.arguments(id, exercise).toString())))
        val resultText: String
        if (exercise == "ptc") {
            val audit = JSONObject().put("rootCallId", "program-call").put("parentCallId", "program-call")
                .put("subCallId", "program-call:ptc:1").put("name", "list_agents").put("arguments", JSONObject().put("scope", "children"))
            out.put(event(7, "tool/ptc-dispatch-start", audit))
                .put(event(8, "tool/ptc-dispatch", JSONObject(audit.toString()).put("isError", false)
                    .put("content", JSONArray().put(text("(no subagents)")))))
            resultText = JSONObject().put("marker", AgentServiceTaskEvidence.marker(id)).put("children", 0).toString()
        } else {
            val runId = "b0000000-0000-4000-8000-000000000002"
            out.put(event(7, "tool-workflow/run-start", JSONObject().put("runId", runId).put("name", "account-child")))
                .put(event(8, "tool-workflow/agent-start", JSONObject().put("runId", runId).put("seq", 1)
                    .put("childId", "c0000000-0000-4000-8000-000000000003").put("label", "Dedicated child")))
                .put(event(9, "tool-workflow/agent-end", JSONObject().put("runId", runId).put("seq", 1).put("outcome", "completed")))
                .put(event(10, "tool-workflow/run-end", JSONObject().put("runId", runId).put("stopReason", "completed")))
            resultText = "workflow \"account-child\" completed (1 agent).\nReturn value:\n${JSONObject.quote(AgentServiceProgrammaticEvidence.childResponse(id, exercise))}"
        }
        val resultMessage = JSONObject(File(args[0], "tool-result-message.json").readText()).put("toolCallId", "program-call")
            .put("content", JSONArray().put(text(resultText)))
        out.put(event(out.length(), "tool/result", JSONObject().put("turn", 1).put("step", 1).put("message", resultMessage))
            .put("surfaceOp", "append").put("sourceEventSeqs", JSONArray().put(6)))
        out.put(base.getJSONObject(5).put("seq", out.length()))
        out.put(base.getJSONObject(6).put("seq", out.length()))
        return out
    }
    fun verifyProgram(exercise: String, live: JSONArray = programRows(exercise), durable: JSONArray = programRows(exercise)) =
        AgentServiceTaskEvidence.completed(live, durable, id, request, model, false, exercise)
    val nativeContracts = JSONObject().put("caseId", id)
    for (exercise in listOf("ptc", "workflow", "workflow-linux")) case {
        val result = verifyProgram(exercise)
        check(result.getInt("toolCalls") == 1 && result.getLong("toolStartSeq") == 6L)
        check(result.getJSONObject("programmatic").getString("exercise") == exercise)
        check(!result.toString().contains(AgentServiceTaskEvidence.marker(id)))
        nativeContracts.put(exercise, result)
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(6).getJSONObject("data").put("arguments",
            AgentServiceProgrammaticEvidence.arguments(id, "ptc").put("code", "return 1").toString())
        rejects("PROGRAMMATIC_ARGUMENTS_CHANGED") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(8).getJSONObject("data").put("isError", true)
        rejects("PTC_CALLBACK_FAILED") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(7).getJSONObject("data").put("parentCallId", "other")
        rejects("PTC_CALLBACK_IDENTITY_MISMATCH") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(8).put("type", "hidden-callback")
        rejects("PROGRAMMATIC_EVENT_COUNT_INVALID") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(9).put("sourceEventSeqs", JSONArray().put(5))
        rejects("PROGRAMMATIC_RESULT_SOURCE_MISMATCH") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(9).getJSONObject("data").getJSONObject("message").put("isError", true)
        rejects("PROGRAMMATIC_TOOL_FAILED") { verifyProgram("ptc", value) }
    }
    case {
        val value = programRows("ptc"); value.getJSONObject(4).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", "Changed context")
        rejects("DURABLE_MISMATCH") { verifyProgram("ptc", durable = value) }
    }
    case {
        val value = programRows("workflow"); value.getJSONObject(9).getJSONObject("data").put("runId", "d0000000-0000-4000-8000-000000000004")
        rejects("WORKFLOW_RUN_MISMATCH") { verifyProgram("workflow", value) }
    }
    case {
        val value = programRows("workflow"); value.getJSONObject(9).getJSONObject("data").put("outcome", "failed")
        rejects("WORKFLOW_NOT_COMPLETED") { verifyProgram("workflow", value) }
    }
    case {
        val value = programRows("workflow"); value.getJSONObject(8).getJSONObject("data").put("childId", session)
        rejects("WORKFLOW_ID_INVALID") { verifyProgram("workflow", value) }
    }
    case {
        val value = programRows("workflow"); value.getJSONObject(6).getJSONObject("data").put("arguments",
            AgentServiceProgrammaticEvidence.arguments(id, "workflow").put("run_in_background", true).toString())
        rejects("PROGRAMMATIC_ARGUMENTS_CHANGED") { verifyProgram("workflow", value) }
    }
    fun childRows(): JSONArray {
        val value = rows()
        value.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0)
            .put("text", AgentServiceProgrammaticEvidence.childPrompt(id))
        value.getJSONObject(5).getJSONObject("data").getJSONObject("message").put("content",
            JSONArray().put(text(AgentServiceProgrammaticEvidence.childMarker(id))))
        return value
    }
    fun verifyChild(live: JSONArray = childRows(), durable: JSONArray = childRows()) =
        AgentServiceProgrammaticEvidence.child(live, durable, id, "c0000000-0000-4000-8000-000000000003", model)
    val cleanupChild = "c0000000-0000-4000-8000-000000000003"
    fun linuxChildRows(): JSONArray {
        val base = childRows()
        base.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0)
            .put("text", AgentServiceProgrammaticEvidence.childPrompt(id, "workflow-linux"))
        val out = JSONArray((0..4).map { base.getJSONObject(it) })
            .put(event(5, "assistant/message", JSONObject().put("turn", 1).put("step", 1).put("message", JSONObject()
                .put("content", JSONArray().put(JSONObject().put("type", "tool-call").put("id", "child-linux-call").put("name", "linux_exec"))))))
            .put(event(6, "tool/call", JSONObject().put("turn", 1).put("step", 1).put("callId", "child-linux-call").put("name", "linux_exec")
                .put("arguments", AgentServiceChildLinuxEvidence.arguments(id).toString())))
        val native = JSONObject().put("id", "e0000000-0000-4000-8000-000000000005").put("sessionId", cleanupChild)
            .put("status", "completed").put("exitCode", 0).put("retirementConfirmed", true).put("guestUid", 99001)
            .put("cancelled", false).put("timedOut", false).put("truncated", false).put("cancelRequested", false).put("diskCommitted", true)
            .put("output", JSONObject().put("marker", AgentServiceProgrammaticEvidence.childMarker(id))
                .put("sha256", AgentServiceChildLinuxEvidence.payloadHash(id)).put("bytes", AgentServiceChildLinuxEvidence.payload(id).toByteArray().size)
                .put("archiveEntries", 1).put("cleaned", true).toString())
        val message = JSONObject(File(args[0], "tool-result-message.json").readText()).put("toolCallId", "child-linux-call")
            .put("content", JSONArray().put(text(native.toString())))
        out.put(event(7, "tool/result", JSONObject().put("turn", 1).put("step", 1).put("message", message))
            .put("sourceEventSeqs", JSONArray().put(6)))
        out.put(base.getJSONObject(5).put("seq", 8).apply {
            getJSONObject("data").getJSONObject("message").put("content", JSONArray().put(text(AgentServiceChildLinuxEvidence.response(id))))
        })
        out.put(base.getJSONObject(6).put("seq", 9))
        return out
    }
    fun verifyLinuxChild(live: JSONArray = linuxChildRows(), durable: JSONArray = linuxChildRows()) =
        AgentServiceProgrammaticEvidence.child(live, durable, id, cleanupChild, model, "workflow-linux", 10496)
    fun modifyLinuxReceipt(events: JSONArray, change: (JSONObject) -> Unit) {
        val block = events.getJSONObject(7).getJSONObject("data").getJSONObject("message").getJSONArray("content").getJSONObject(0)
        val native = JSONObject(block.getString("text")); change(native); block.put("text", native.toString())
    }
    case { nativeContracts.put("linuxChild", verifyLinuxChild()) }
    case {
        val live = linuxChildRows(); val durable = linuxChildRows()
        modifyLinuxReceipt(live) { it.put("diskCommitted", false) }; modifyLinuxReceipt(durable) { it.put("diskCommitted", false) }
        check(!verifyLinuxChild(live, durable).getJSONObject("linuxReceipt").getBoolean("diskCommitted"))
    }
    for ((key, value) in listOf("retirementConfirmed" to false, "cancelled" to true, "timedOut" to true,
        "truncated" to true, "cancelRequested" to true, "exitCode" to 1)) case {
        val events = linuxChildRows(); modifyLinuxReceipt(events) { it.put(key, value) }
        rejects("CHILD_LINUX_EXECUTION_UNCONFIRMED") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); modifyLinuxReceipt(events) { it.put("guestUid", 10496) }
        rejects("CHILD_LINUX_UID_NOT_ISOLATED") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); modifyLinuxReceipt(events) { it.put("sessionId", session) }
        rejects("CHILD_LINUX_SESSION_MISMATCH") { verifyLinuxChild(events) }
    }
    for ((key, value) in listOf("cleaned" to false, "bytes" to 1, "sha256" to "bad", "archiveEntries" to 2)) case {
        val events = linuxChildRows(); modifyLinuxReceipt(events) {
            it.put("output", JSONObject(it.getString("output")).put(key, value).toString())
        }
        rejects("CHILD_LINUX_FILE_RESULT_INVALID") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); events.getJSONObject(6).getJSONObject("data").put("arguments", "{\"command\":\"ls /\",\"timeoutMs\":120000}")
        rejects("CHILD_LINUX_ARGUMENTS_CHANGED") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); events.getJSONObject(7).put("sourceEventSeqs", JSONArray().put(5))
        rejects("CHILD_LINUX_RESULT_MISMATCH") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); events.put(event(10, "tool/call", events.getJSONObject(6).getJSONObject("data")))
        rejects("CHILD_LINUX_TOOL_COUNT_INVALID") { verifyLinuxChild(events) }
    }
    case {
        val events = linuxChildRows(); modifyLinuxReceipt(events) { it.put("diskCommitted", false) }
        rejects("CHILD_DURABLE_MISMATCH") { verifyLinuxChild(durable = events) }
    }
    case {
        var calls = 0
        AgentServiceProgrammaticEvidence.archiveChild(cleanupChild) { method, params ->
            calls++
            check(method == "api.call")
            check(AgentServiceTaskEvidence.canonical(params) ==
                "{\"args\":{\"request\":{\"sessionId\":\"$cleanupChild\"}},\"method\":\"archiveSession\",\"namespace\":\"workspace\"}")
            JSONObject().put("archivedSessionIds", JSONArray().put(session).put(cleanupChild))
        }
        check(calls == 1)
    }
    for (receipt in listOf(JSONObject(), JSONObject().put("archivedSessionIds", JSONArray().put(session)),
        JSONObject().put("archivedSessionIds", cleanupChild), JSONObject().put("_pocket_error", JSONObject().put("code", "workspace/session-active")))) case {
        rejects("CHILD_ARCHIVE_UNCONFIRMED") { AgentServiceProgrammaticEvidence.archiveChild(cleanupChild) { _, _ -> receipt } }
    }
    case {
        rejects("WORKFLOW_CHILD_ID_INVALID") {
            AgentServiceProgrammaticEvidence.archiveChild(session) { _, _ -> error("Must not dispatch an unrelated parent identity") }
        }
    }
    case {
        val refused = AgentServiceTaskEvidence.Rejected("DOMAIN_FAILED")
        try {
            AgentServiceProgrammaticEvidence.archiveChild(cleanupChild) { _, _ -> throw refused }
            error("A refused child archive must remain failed")
        } catch (actual: AgentServiceTaskEvidence.Rejected) { check(actual === refused) }
    }
    fun cleanupWorkflow(parent: JSONArray = programRows("workflow"), child: JSONArray = childRows(),
        review: Boolean = false, onCall: (String) -> Unit = {}): JSONObject = AgentServiceProgrammaticEvidence.cleanupWorkflow(id,
        { method, params ->
            onCall(method)
            when (method) {
                "session.read" -> JSONObject().put("events", when (params.getString("sessionId")) {
                    session -> parent
                    cleanupChild -> child
                    else -> error("Unrelated Session read")
                })
                "workflow.inspect" -> {
                    check(params.getString("sessionId") == session)
                    JSONObject().put("runId", params.getString("runId")).put("state", "completed").put("requiresReview", review)
                }
                "api.call" -> {
                    check(params.getString("namespace") == "workspace" && params.getString("method") == "archiveSession")
                    check(AgentServiceTaskEvidence.canonical(params.getJSONObject("args")) == "{\"request\":{\"sessionId\":\"$cleanupChild\"}}")
                    JSONObject().put("archivedSessionIds", JSONArray().put(cleanupChild))
                }
                else -> error("Cleanup must not dispatch $method")
            }
        }, { target -> when (target) {
            session -> programRows("workflow")
            cleanupChild -> childRows()
            else -> error("Unrelated Session export")
        } })
    case {
        val calls = ArrayList<String>()
        nativeContracts.put("cleanup", cleanupWorkflow(onCall = { calls.add(it) }))
        check(calls == listOf("session.read", "workflow.inspect", "session.read", "api.call"))
    }
    case {
        val parent = programRows("workflow")
        parent.getJSONObject(1).getJSONObject("data").getJSONObject("source").put("rpcId", "unrelated")
        rejects("REQUEST_ID_MISMATCH") { cleanupWorkflow(parent = parent, onCall = { check(it != "api.call") }) }
    }
    case {
        val child = childRows()
        child.getJSONObject(5).getJSONObject("data").getJSONObject("message").put("content", JSONArray().put(text("unrelated")))
        rejects("CHILD_MARKER_MISMATCH") { cleanupWorkflow(child = child, onCall = { check(it != "api.call") }) }
    }
    case {
        rejects("WORKFLOW_INSPECTION_UNCONFIRMED") { cleanupWorkflow(review = true, onCall = { check(it != "api.call") }) }
    }
    case {
        rejects("CLEANUP_CASE_INVALID") {
            AgentServiceProgrammaticEvidence.cleanupWorkflow("unrelated", { _, _ -> error("Must not call") }, { error("Must not export") })
        }
    }
    case { nativeContracts.put("child", verifyChild()) }
    case {
        val value = childRows(); value.getJSONObject(3).getJSONObject("data").getJSONObject("header").getJSONObject("config").put("provider", "deepseek-official")
        rejects("CHILD_MODEL_CHANGED") { verifyChild(value) }
    }
    case {
        val value = childRows(); value.put(event(7, "tool/call", JSONObject()))
        rejects("CHILD_TOOL_INVOKED") { verifyChild(value) }
    }
    case {
        val value = childRows(); value.getJSONObject(5).getJSONObject("data").getJSONObject("message").put("content", JSONArray().put(text("wrong")))
        rejects("CHILD_MARKER_MISMATCH") { verifyChild(value) }
    }
    case {
        val value = childRows(); value.getJSONObject(4).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", "Changed child context")
        rejects("CHILD_DURABLE_MISMATCH") { verifyChild(durable = value) }
    }
    case {
        val value = childRows(); value.getJSONObject(6).getJSONObject("data").getJSONObject("reason").put("kind", "cancelled")
        rejects("CHILD_TURN_NOT_COMPLETED") { verifyChild(value) }
    }
    case {
        val stored = childRows(); stored.put(event(7, "session/title", JSONObject().put("title", "Late dedicated title")))
        check(verifyChild(durable = stored).getInt("eventCount") == 8)
    }
    fun changedParent(): JSONArray = programRows("workflow-linux").apply {
        getJSONObject(6).getJSONObject("data").put("arguments", AgentServiceProgrammaticEvidence.arguments(id, "workflow-linux")
            .apply { getJSONObject("meta").put("description", "private credential-like fixture never print") }.toString())
    }
    fun diagnose(parent: JSONArray = changedParent(), stored: JSONArray = parent,
        childHeaderParent: String = session, childHeaderOrigin: String = "subagent", failChild: Boolean = false,
        calls: MutableList<String> = ArrayList()): JSONObject = AgentServiceProgrammaticDiagnostic.inspect(id, "workflow-linux",
        { method, params ->
            calls.add(method)
            check(method == "session.read")
            val target = params.getString("sessionId")
            check(target in setOf(session, cleanupChild))
            if (failChild && target == cleanupChild) throw AgentServiceTaskEvidence.Rejected("DOMAIN_FAILED")
            JSONObject().put("events", if (target == session) parent else linuxChildRows())
        }, { target ->
            check(target in setOf(session, cleanupChild))
            val header = JSONObject().put("type", "session").put("version", 4).put("id", target)
            if (target == cleanupChild) header.put("origin", childHeaderOrigin).put("parentSession", childHeaderParent)
            JSONObject().put("header", header).put("events", if (target == session) stored else linuxChildRows())
        })
    case {
        val methods = ArrayList<String>()
        val proof = diagnose(calls = methods)
        check(methods == listOf("session.read", "session.read"))
        check(!proof.getBoolean("cleanupAuthorized") && proof.getJSONObject("lineage").getString("state") == "verified")
        check(!proof.getJSONObject("arguments").getBoolean("matches"))
        check(!proof.toString().contains("private credential-like fixture") && !proof.toString().contains("python3"))
        nativeContracts.put("diagnostic", proof)
    }
    case {
        val raw = changedParent().getJSONObject(6).getJSONObject("data").getString("arguments")
        try { AgentServiceProgrammaticEvidence.call(changedParent().getJSONObject(6), id, "workflow-linux"); error("Must reject") }
        catch (error: AgentServiceTaskEvidence.Rejected) {
            check(error.code == "PROGRAMMATIC_ARGUMENTS_CHANGED")
            check(error.diagnostic!!.getString("rawSha256") == AgentServiceTaskEvidence.hash(raw.toByteArray()))
            val fields = error.diagnostic!!.getJSONArray("fields")
            check(fields.getJSONObject(0).getBoolean("matches") && !fields.getJSONObject(3).getBoolean("matches"))
        }
    }
    for (exercise in listOf("ptc", "workflow", "workflow-linux")) case {
        val raw = AgentServiceProgrammaticEvidence.arguments(id, exercise).toString()
        check(AgentServiceProgrammaticDiagnostic.arguments(raw, id, exercise).getBoolean("matches"))
    }
    for (raw in listOf("{private-secret", "{\"script\":null}", "{\"script\":12,\"meta\":[]}",
        "{\"private-secret-key\":\"private-secret-value\",\"meta\":{\"credential\":\"private-secret-token\"}}")) case {
        val proof = AgentServiceProgrammaticDiagnostic.arguments(raw, id, "workflow-linux")
        check(!proof.getBoolean("matches") && !proof.toString().contains("private-secret") && !proof.toString().contains("credential"))
    }
    case {
        val proof = AgentServiceProgrammaticDiagnostic.arguments("{\"script\":\"字\",\"meta\":{}}", id, "workflow-linux")
        check(proof.getJSONArray("fields").getJSONObject(0).getJSONObject("actual").getInt("bytes") == 3)
    }
    case { rejects("PROGRAMMATIC_ARGUMENTS_OVERSIZED") { AgentServiceProgrammaticDiagnostic.arguments("x".repeat(262145), id, "workflow-linux") } }
    case {
        val parent = changedParent(); parent.getJSONObject(1).getJSONObject("data").getJSONObject("source").put("rpcId", "other-request")
        rejects("REQUEST_ID_MISMATCH") { diagnose(parent) }
    }
    case {
        val parent = changedParent(); parent.getJSONObject(1).getJSONObject("data").getJSONArray("content").getJSONObject(0).put("text", "other-user")
        rejects("USER_CONTENT_MISMATCH") { diagnose(parent) }
    }
    case {
        val stored = changedParent(); stored.getJSONObject(6).getJSONObject("data").put("arguments", "{}")
        rejects("DIAGNOSTIC_DURABLE_MISMATCH") { diagnose(stored = stored) }
    }
    for ((parent, origin) in listOf("other-parent" to "subagent", session to "user")) case {
        check(diagnose(childHeaderParent = parent, childHeaderOrigin = origin).getJSONObject("lineage").getString("state") == "unconfirmed")
    }
    case { check(diagnose(failChild = true).getJSONObject("lineage").getString("state") == "child_read_unconfirmed") }
    case {
        val parent = changedParent(); parent.getJSONObject(8).put("type", "other-event")
        val calls = ArrayList<String>()
        check(diagnose(parent, calls = calls).getJSONObject("lineage").getString("state") == "no_member_record")
        check(calls == listOf("session.read"))
    }
    case {
        val parent = changedParent(); parent.getJSONObject(8).getJSONObject("data").put("childId", "existing-user-session")
        val calls = ArrayList<String>()
        check(diagnose(parent, calls = calls).getJSONObject("lineage").getString("state") == "unconfirmed")
        check(calls == listOf("session.read"))
    }
    case {
        rejects("DIAGNOSTIC_CASE_INVALID") { AgentServiceProgrammaticDiagnostic.inspect("other", "workflow-linux",
            { _, _ -> error("No RPC allowed") }, { error("No export allowed") }) }
    }
    File(args[0], "programmatic-native-contract.json").writeText(nativeContracts.toString())
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
