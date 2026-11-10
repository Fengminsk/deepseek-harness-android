package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

/** Original schedule and LLM serializers supply the messages; lifecycle rows are explicit host fixtures. */
fun main(args: Array<String>) {
    val directory = File(args.single())
    val original = JSONObject(File(directory, "original-messages.json").readText())
    val id = "42b1d2e3-1234-4567-8abc-123456789012"
    val model = "deepseek-flash"
    val record = original.getJSONObject("record").put("sessionId", ScheduleWakeupAcceptanceEvidence.session(id))
        .put("status", "active")
    val due = Instant.parse(record.getString("scheduledAt")).toEpochMilli()
    var checks = 0
    fun case(action: () -> Unit) { action(); checks++ }
    fun rejects(code: String, action: () -> Unit) {
        try { action() } catch (failure: AgentServiceTaskEvidence.Rejected) { check(failure.code == code) { "Expected $code, got ${failure.code}" }; return }
        error("Expected rejection $code")
    }
    fun row(seq: Int, type: String, data: JSONObject) = JSONObject().put("seq", seq).put("type", type).put("time", seq).put("data", data)
    fun text(value: String) = JSONObject().put("type", "text").put("text", value)
    fun header() = JSONObject().put("header", JSONObject().put("config", JSONObject().put("provider", "deepseek-account").put("model", model)))
    fun creation() = JSONArray()
        .put(row(0, "user/message", JSONObject().put("source", JSONObject().put("kind", "user").put("rpcId", "schedule-create-$id"))
            .put("content", JSONArray().put(text(ScheduleWakeupAcceptanceEvidence.prompt(id))))))
        .put(row(1, "turn/start", JSONObject().put("turn", 1)))
        .put(row(2, "request/header", header()))
        .put(row(3, "user/message", JSONObject().put("source", JSONObject().put("kind", "runtime-context"))
            .put("content", JSONArray().put(text("Synthetic context")))))
        .put(row(4, "tool/call", JSONObject().put("turn", 1).put("step", 1).put("callId", "create-call").put("name", "schedule_create")
            .put("arguments", JSONObject().put("title", record.getString("title")).put("prompt", record.getString("prompt")).put("after_seconds", 180).toString())))
        .put(row(5, "tool/result", JSONObject().put("turn", 1).put("message", original.getJSONObject("result"))))
        .put(row(6, "assistant/message", JSONObject().put("turn", 1).put("message", JSONObject().put("content", JSONArray().put(text("created-$id"))))))
        .put(row(7, "turn/end", JSONObject().put("turn", 1).put("reason", JSONObject().put("kind", "completed"))))
    fun saved() = ScheduleWakeupAcceptanceEvidence.created(creation(), record, id, model)
        .put("caseId", id).put("model", model).put("reminderId", record.getString("id")).put("dueAtMs", due)
    fun receipt() = JSONObject().put("messageId", original.getJSONObject("input").getString("id"))
        .put("prompt", record.getString("prompt")).put("scheduledAt", record.getString("scheduledAt")).put("deliveredAt", record.getString("scheduledAt"))
    fun inactive() = JSONObject(record.toString()).put("status", "inactive").put("lastDelivery", receipt())
    fun history() = JSONObject().put("id", record.getString("id")).put("records", JSONArray().put(receipt()))
    fun delivered() = creation()
        .put(row(8, "agent/inbox/spliced", JSONObject().put("inserted", JSONArray().put(original.getJSONObject("input")))))
        .put(row(9, "turn/start", JSONObject().put("turn", 2)))
        .put(row(10, "request/header", header()))
        .put(row(11, "user/message", JSONObject().put("source", JSONObject().put("kind", "runtime-context"))
            .put("content", JSONArray().put(text("New synthetic context")))))
        .put(row(12, "assistant/message", JSONObject().put("turn", 2).put("message", JSONObject().put("content", JSONArray().put(text(ScheduleWakeupAcceptanceEvidence.marker(id)))))))
        .put(row(13, "turn/end", JSONObject().put("turn", 2).put("reason", JSONObject().put("kind", "completed"))))
    fun verify(rows: JSONArray = delivered(), durable: JSONArray = rows, metadata: JSONObject = saved(), task: JSONObject = inactive(), deliveries: JSONObject = history()) =
        ScheduleWakeupAcceptanceEvidence.delivered(rows, durable, task, deliveries, metadata)
    case { check(ScheduleWakeupAcceptanceEvidence.framedReminder(record) == original.getJSONObject("input").getJSONArray("content").getJSONObject(0).getString("text")) }
    case { check(saved().getInt("createEndSeq") == 7) }
    case { check(verify().getInt("completedTurns") == 2) }
    case { rejects("REMINDER_IDENTITY_MISMATCH") { ScheduleWakeupAcceptanceEvidence.ownRecord(JSONObject(record.toString()).put("sessionId", "someone-else"), id) } }
    case { rejects("SCHEDULE_CALL_CHANGED") {
        val rows = creation(); rows.getJSONObject(4).getJSONObject("data").put("arguments", JSONObject().put("title", record.getString("title"))
            .put("prompt", record.getString("prompt")).put("after_seconds", 181).toString())
        ScheduleWakeupAcceptanceEvidence.created(rows, record, id, model)
    } }
    case { rejects("SCHEDULE_TOOL_FAILED") {
        val rows = creation(); rows.getJSONObject(5).getJSONObject("data").put("message", JSONObject(original.getJSONObject("result").toString()).put("isError", true))
        ScheduleWakeupAcceptanceEvidence.created(rows, record, id, model)
    } }
    case { rejects("MODEL_CHANGED") { val rows = delivered(); rows.getJSONObject(10).getJSONObject("data").getJSONObject("header").getJSONObject("config").put("model", "other"); verify(rows) } }
    case { rejects("DURABLE_HISTORY_MISMATCH") { verify(durable = creation()) } }
    case { rejects("CREATION_HISTORY_CHANGED") { verify(metadata = saved().put("createHistorySha256", "0".repeat(64))) } }
    case { rejects("REMINDER_NOT_RETIRED") { verify(task = record) } }
    case { rejects("DELIVERY_COUNT_INVALID") { verify(deliveries = history().put("records", JSONArray().put(receipt()).put(receipt()))) } }
    case { rejects("DELIVERY_RECEIPT_MISMATCH") { verify(deliveries = history().put("records", JSONArray().put(receipt().put("prompt", "other")))) } }
    case { rejects("SCHEDULE_INPUT_CHANGED") {
        val rows = delivered(); val input = JSONObject(original.getJSONObject("input").toString()).put("content", JSONArray().put(text(record.getString("prompt"))))
        rows.getJSONObject(8).getJSONObject("data").put("inserted", JSONArray().put(input)); verify(rows)
    } }
    case { rejects("SCHEDULE_INPUT_MISMATCH") { val rows = delivered(); rows.getJSONObject(8).getJSONObject("data").put("inserted", JSONArray()); verify(rows) } }
    case { rejects("FINAL_MARKER_MISMATCH") {
        val rows = delivered(); rows.getJSONObject(12).getJSONObject("data").getJSONObject("message").put("content", JSONArray().put(text("created-$id"))); verify(rows)
    } }
    case { rejects("DELIVERY_TURN_FAILED") { val rows = delivered(); rows.getJSONObject(13).getJSONObject("data").getJSONObject("reason").put("kind", "cancelled"); verify(rows) } }
    case { rejects("EVENT_ORDER_INVALID") { val rows = delivered(); rows.getJSONObject(13).put("seq", 12); verify(rows) } }
    fun armed() = JSONObject().put("enabled", true).put("exactAlarmsAllowed", true).put("error", JSONObject.NULL)
        .put("projectionState", "ready").put("activeCount", 1).put("alarmState", "scheduled").put("nextDueAtMs", due).put("armedAtMs", due)
    case { ScheduleWakeupAcceptanceEvidence.armed(armed(), due, due - 60_000) }
    for ((field, bad) in listOf("enabled" to false, "exactAlarmsAllowed" to false, "activeCount" to 2, "projectionState" to "unknown", "armedAtMs" to due + 1)) case {
        rejects("ALARM_NOT_ARMED_WITH_MARGIN") { ScheduleWakeupAcceptanceEvidence.armed(armed().put(field, bad), due, due - 60_000) }
    }
    case { rejects("ALARM_NOT_ARMED_WITH_MARGIN") { ScheduleWakeupAcceptanceEvidence.armed(armed(), due, due - 59_999) } }
    val summary = JSONObject().put("running", 0).put("queued", 0).put("waiting", 0).put("backgroundJobs", 0).put("packageOperations", 0)
    case { ScheduleWakeupAcceptanceEvidence.idle(summary) }
    case { rejects("OTHER_WORK_ACTIVE_OR_UNKNOWN") { ScheduleWakeupAcceptanceEvidence.idle(JSONObject(summary.toString()).put("running", 1)) } }
    case { val missing = JSONObject(summary.toString()); missing.remove("running"); rejects("OTHER_WORK_ACTIVE_OR_UNKNOWN") { ScheduleWakeupAcceptanceEvidence.idle(missing) } }
    fun processIdentity(pid: Int = 20203, uid: Int = 10496, name: String = "com.minnnng.dsh_android:agent") =
        JSONObject().put("pid", pid).put("uid", uid).put("processName", name)
    fun retireTarget(rows: JSONArray = JSONArray().put(processIdentity()), service: JSONObject = processIdentity(),
        originalEndpointAlive: Boolean = true) =
        ScheduleWakeupAcceptanceEvidence.retirementTarget(rows, service, 20203, 10496, "com.minnnng.dsh_android:agent", originalEndpointAlive)
    case { retireTarget() }
    case { rejects("KILL_TARGET_CHANGED") { retireTarget(originalEndpointAlive = false) } }
    case { rejects("KILL_TARGET_CHANGED") { retireTarget(JSONArray()) } }
    case { rejects("KILL_TARGET_CHANGED") { retireTarget(JSONArray().put(processIdentity()).put(processIdentity())) } }
    for (changed in arrayOf(processIdentity(pid = 20204), processIdentity(uid = 10497), processIdentity(name = "other:agent"))) {
        case { rejects("KILL_TARGET_CHANGED") { retireTarget(JSONArray().put(changed)) } }
        case { rejects("KILL_TARGET_CHANGED") { retireTarget(service = changed) } }
    }
    case { check(!ScheduleWakeupAcceptanceEvidence.signalProbeGone(null, 3)) }
    case { check(ScheduleWakeupAcceptanceEvidence.signalProbeGone(3, 3)) }
    case { rejects("OLD_AGENT_SIGNAL_PROBE_FAILED") { ScheduleWakeupAcceptanceEvidence.signalProbeGone(1, 3) } }
    case { rejects("OLD_AGENT_SIGNAL_PROBE_FAILED") { ScheduleWakeupAcceptanceEvidence.signalProbeGone(5, 3) } }
    val step = ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_EVIDENCE
    val privateText = "private-account-token-and-session-text"
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(org.json.JSONException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_JSON_INVALID") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(java.util.concurrent.ExecutionException(org.json.JSONException(privateText)), step) == "SCHEDULE_CREATE_EVIDENCE_JSON_INVALID") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(java.util.concurrent.CompletionException(AgentServiceTaskEvidence.Rejected("SCHEDULE_TOOL_FAILED")), step) == "SCHEDULE_TOOL_FAILED") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(java.util.concurrent.TimeoutException(privateText), ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SEND) == "SCHEDULE_CREATE_SEND_TIMEOUT") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(java.io.IOException(privateText), ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SAVE) == "SCHEDULE_CREATE_SAVE_IO_FAILED") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(SecurityException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_SECURITY_DENIED") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(InterruptedException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_INTERRUPTED") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(IllegalArgumentException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_ARGUMENT_INVALID") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(IllegalStateException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_STATE_INVALID") }
    case { check(ScheduleWakeupAcceptanceEvidence.failureCode(RuntimeException(privateText), step) == "SCHEDULE_CREATE_EVIDENCE_UNEXPECTED") }
    case {
        var nested: Throwable = org.json.JSONException(privateText)
        repeat(8) { nested = java.util.concurrent.ExecutionException(nested) }
        check(ScheduleWakeupAcceptanceEvidence.failureCode(nested, step) == "SCHEDULE_CREATE_EVIDENCE_UNEXPECTED")
    }
    case {
        for (current in arrayOf(
            ScheduleWakeupAcceptanceEvidence.PhaseStep.PHASE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SAVE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_SEND,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_HISTORY,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_IDLE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_CATALOG,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RECORD,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_EVIDENCE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_DUE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_WAIT,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_CHECK,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_ARM_SAVE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_IDLE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_RUNTIME,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_DISCONNECT,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_IDENTITY,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_SAVE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_SIGNAL,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_WAIT,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_WAIT_SAVE,
            ScheduleWakeupAcceptanceEvidence.PhaseStep.CREATE_RETIRE_RECEIPT,
        )) {
            val code = ScheduleWakeupAcceptanceEvidence.failureCode(org.json.JSONException(privateText), current)
            check(code.matches(Regex("[A-Z_]{1,80}")) && !code.contains(privateText))
        }
    }
    File(directory, "report.json").writeText(JSONObject().put("passed", true).put("checks", checks).put("deviceTested", false).toString(2) + "\n")
    println("Natural-wake evidence: $checks host checks passed; no device or account used")
}
