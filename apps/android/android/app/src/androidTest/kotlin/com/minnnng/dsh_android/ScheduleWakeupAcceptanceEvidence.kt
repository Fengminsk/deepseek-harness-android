package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Checks only the UUID-owned reminder and its actual Session events. */
object ScheduleWakeupAcceptanceEvidence {
    const val DELAY_SECONDS = 180
    // Compile-time strings keep test-only diagnostics independent of enum helpers stripped from the release App.
    object PhaseStep {
        const val PHASE = "PHASE"
        const val CREATE_SAVE = "CREATE_SAVE"
        const val CREATE_SEND = "CREATE_SEND"
        const val CREATE_HISTORY = "CREATE_HISTORY"
        const val CREATE_IDLE = "CREATE_IDLE"
        const val CREATE_CATALOG = "CREATE_CATALOG"
        const val CREATE_RECORD = "CREATE_RECORD"
        const val CREATE_EVIDENCE = "CREATE_EVIDENCE"
        const val CREATE_DUE = "CREATE_DUE"
        const val CREATE_ARM_WAIT = "CREATE_ARM_WAIT"
        const val CREATE_ARM_CHECK = "CREATE_ARM_CHECK"
        const val CREATE_ARM_SAVE = "CREATE_ARM_SAVE"
        const val CREATE_RETIRE_IDLE = "CREATE_RETIRE_IDLE"
        const val CREATE_RETIRE_RUNTIME = "CREATE_RETIRE_RUNTIME"
        const val CREATE_RETIRE_DISCONNECT = "CREATE_RETIRE_DISCONNECT"
        const val CREATE_RETIRE_IDENTITY = "CREATE_RETIRE_IDENTITY"
        const val CREATE_RETIRE_SAVE = "CREATE_RETIRE_SAVE"
        const val CREATE_RETIRE_SIGNAL = "CREATE_RETIRE_SIGNAL"
        const val CREATE_RETIRE_WAIT = "CREATE_RETIRE_WAIT"
        const val CREATE_RETIRE_WAIT_SAVE = "CREATE_RETIRE_WAIT_SAVE"
        const val CREATE_RETIRE_RECEIPT = "CREATE_RETIRE_RECEIPT"
    }
    /** Fixed codes survive the host driver's redaction; no exception prose or Session content escapes. */
    fun failureCode(error: Throwable, step: String): String {
        var cause = error
        repeat(4) {
            if ((cause is java.util.concurrent.ExecutionException || cause is java.util.concurrent.CompletionException) &&
                cause.cause != null && cause.cause !== cause) cause = cause.cause!!
        }
        if (cause is AgentServiceTaskEvidence.Rejected) return (cause as AgentServiceTaskEvidence.Rejected).code
        val kind = when (cause) {
            is org.json.JSONException -> "JSON_INVALID"
            is java.util.concurrent.TimeoutException -> "TIMEOUT"
            is InterruptedException -> "INTERRUPTED"
            is SecurityException -> "SECURITY_DENIED"
            is java.io.IOException -> "IO_FAILED"
            is IllegalArgumentException -> "ARGUMENT_INVALID"
            is IllegalStateException -> "STATE_INVALID"
            else -> "UNEXPECTED"
        }
        return "SCHEDULE_${step}_$kind"
    }
    fun demand(value: Boolean, code: String) = AgentServiceTaskEvidence.demand(value, code)
    /** Require the same live App-owned process in both framework inventories before signalling it. */
    fun retirementTarget(processes: JSONArray, service: JSONObject, pid: Int, uid: Int, processName: String,
        originalEndpointAlive: Boolean) {
        val matching = (0 until processes.length()).map { processes.getJSONObject(it) }.filter { it.getInt("pid") == pid }
        demand(originalEndpointAlive && pid > 0 && uid >= 0 && matching.size == 1 && matching.single().getInt("uid") == uid &&
            matching.single().getString("processName") == processName && service.getInt("pid") == pid &&
            service.getInt("uid") == uid && service.getString("processName") == processName, "KILL_TARGET_CHANGED")
    }
    /** Only ESRCH establishes absence; permission denial or another failed probe remains unconfirmed. */
    fun signalProbeGone(errno: Int?, noSuchProcess: Int): Boolean {
        if (errno == null) return false
        demand(errno == noSuchProcess, "OLD_AGENT_SIGNAL_PROBE_FAILED")
        return true
    }
    fun session(caseId: String) = "android-schedule-acceptance-$caseId"
    fun marker(caseId: String) = "schedule-delivered-$caseId"
    fun title(caseId: String) = "schedule-acceptance-$caseId"
    fun reminder(caseId: String) = "请只回复这一行：${marker(caseId)}。不要调用工具，不要读取文件，不要添加解释。"
    fun framedReminder(record: JSONObject) = listOf("[SCHEDULE REMINDER]", "This is a scheduled message from the user",
        "schedule_id_json: ${JSONObject.quote(record.getString("id"))}", "occurrence_at: ${record.getString("scheduledAt")}",
        "reminder_prompt_json: ${JSONObject.quote(record.getString("prompt"))}").joinToString("\n")
    fun prompt(caseId: String) = "这是一次定时唤醒验收。只调用一次 schedule_create，参数必须严格为 " +
        JSONObject().put("title", title(caseId)).put("prompt", reminder(caseId)).put("after_seconds", DELAY_SECONDS).toString() +
        "。不调用其他工具，不修改其他提醒。工具成功后只回复 created-$caseId。"
    fun rows(events: JSONArray): List<JSONObject> {
        demand(events.length() in 1..511, "HISTORY_SIZE_INVALID")
        val rows = (0 until events.length()).map { events.getJSONObject(it) }
        var seq = -1L
        for (row in rows) { demand(row.getLong("seq") > seq, "EVENT_ORDER_INVALID"); seq = row.getLong("seq") }
        return rows
    }
    fun hash(events: JSONArray) = AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.canonical(events).toByteArray())
    fun ownRecord(record: JSONObject, caseId: String): Long {
        demand(record.getString("sessionId") == session(caseId) && record.getString("title") == title(caseId) &&
            record.getString("prompt") == reminder(caseId) && record.getString("kind") == "after" &&
            record.getInt("afterSeconds") == DELAY_SECONDS, "REMINDER_IDENTITY_MISMATCH")
        demand(record.getString("id").matches(Regex("[A-Za-z0-9_-]{1,128}")), "REMINDER_ID_INVALID")
        return Instant.parse(record.getString("scheduledAt")).toEpochMilli()
    }
    fun idle(summary: JSONObject) {
        for (key in listOf("running", "queued", "waiting", "backgroundJobs", "packageOperations"))
            demand(!summary.isNull(key) && summary.getInt(key) == 0, "OTHER_WORK_ACTIVE_OR_UNKNOWN")
    }
    fun created(events: JSONArray, record: JSONObject, caseId: String, model: String): JSONObject {
        ownRecord(record, caseId)
        val rows = rows(events)
        val users = rows.filter { it.getString("type") == "user/message" &&
            it.getJSONObject("data").getJSONObject("source").getString("kind") == "user" }
        demand(users.size == 1, "USER_COUNT_INVALID")
        val user = users.single().getJSONObject("data")
        demand(user.getJSONObject("source").getString("kind") == "user" &&
            user.getJSONObject("source").getString("rpcId") == "schedule-create-$caseId", "REQUEST_ID_MISMATCH")
        val content = user.getJSONArray("content")
        demand(content.length() == 1 && content.getJSONObject(0).getString("type") == "text" &&
            content.getJSONObject(0).getString("text") == prompt(caseId), "USER_CONTENT_MISMATCH")
        val calls = rows.filter { it.getString("type") == "tool/call" }
        demand(calls.size == 1, "TOOL_COUNT_INVALID")
        val call = calls.single().getJSONObject("data")
        val args = JSONObject(call.getString("arguments"))
        demand(call.getString("name") == "schedule_create" && call.getInt("turn") == 1 &&
            args.keys().asSequence().toSet() == setOf("title", "prompt", "after_seconds") &&
            args.getString("title") == title(caseId) && args.getString("prompt") == reminder(caseId) &&
            args.getInt("after_seconds") == DELAY_SECONDS, "SCHEDULE_CALL_CHANGED")
        val results = rows.filter { it.getString("type") == "tool/result" }
        demand(results.size == 1, "TOOL_RESULT_COUNT_INVALID")
        val message = results.single().getJSONObject("data").getJSONObject("message")
        demand(message.getString("toolCallId") == call.getString("callId") && !message.getBoolean("isError"), "SCHEDULE_TOOL_FAILED")
        val headers = rows.filter { it.getString("type") == "request/header" }
        demand(headers.isNotEmpty(), "MODEL_EVIDENCE_MISSING")
        for (header in headers) {
            val config = header.getJSONObject("data").getJSONObject("header").getJSONObject("config")
            demand(config.getString("provider") == "deepseek-account" && config.getString("model") == model, "MODEL_CHANGED")
        }
        val ends = rows.filter { it.getString("type") == "turn/end" }
        demand(ends.size == 1 && ends.single().getJSONObject("data").getInt("turn") == 1 &&
            ends.single().getJSONObject("data").getJSONObject("reason").getString("kind") == "completed", "CREATE_TURN_FAILED")
        return JSONObject().put("createEventCount", events.length()).put("createHistorySha256", hash(events))
            .put("toolStartSeq", calls.single().getLong("seq")).put("createEndSeq", ends.single().getLong("seq"))
    }
    fun armed(status: JSONObject, due: Long, now: Long) {
        demand(status.getBoolean("enabled") && status.getBoolean("exactAlarmsAllowed") && status.isNull("error") &&
            status.getString("projectionState") == "ready" && status.getInt("activeCount") == 1 &&
            status.getString("alarmState") == "scheduled" && status.getLong("nextDueAtMs") == due &&
            status.getLong("armedAtMs") == due && due - now >= 60_000, "ALARM_NOT_ARMED_WITH_MARGIN")
    }
    fun delivered(events: JSONArray, durable: JSONArray, record: JSONObject, history: JSONObject, saved: JSONObject): JSONObject {
        val caseId = saved.getString("caseId")
        demand(hash(events) == hash(durable), "DURABLE_HISTORY_MISMATCH")
        val rows = rows(durable)
        val prefix = JSONArray(rows.take(saved.getInt("createEventCount")))
        demand(hash(prefix) == saved.getString("createHistorySha256"), "CREATION_HISTORY_CHANGED")
        demand(ownRecord(record, caseId) == saved.getLong("dueAtMs") && record.getString("id") == saved.getString("reminderId") &&
            record.getString("status") == "inactive", "REMINDER_NOT_RETIRED")
        val receipts = history.getJSONArray("records")
        demand(history.getString("id") == saved.getString("reminderId") && receipts.length() == 1, "DELIVERY_COUNT_INVALID")
        val receipt = receipts.getJSONObject(0)
        demand(receipt.getString("prompt") == reminder(caseId) &&
            record.getJSONObject("lastDelivery").getString("messageId") == receipt.getString("messageId"), "DELIVERY_RECEIPT_MISMATCH")
        val inserted = rows.filter { it.getString("type") == "agent/inbox/spliced" }.flatMap { row ->
            val messages = row.getJSONObject("data").getJSONArray("inserted")
            (0 until messages.length()).map { row to messages.getJSONObject(it) }
        }.filter { it.second.getJSONObject("source").optString("kind") == "schedule" }
        demand(inserted.size == 1 && inserted.single().second.getString("id") == receipt.getString("messageId"), "SCHEDULE_INPUT_MISMATCH")
        val message = inserted.single().second
        val blocks = message.getJSONArray("content")
        demand(blocks.length() == 1 && blocks.getJSONObject(0).getString("type") == "text" &&
            blocks.getJSONObject(0).getString("text") == framedReminder(record), "SCHEDULE_INPUT_CHANGED")
        demand(rows.count { it.getString("type") == "user/message" &&
            it.getJSONObject("data").getJSONObject("source").getString("kind") == "user" } == 1 &&
            rows.count { it.getString("type") == "tool/call" } == 1, "UNEXPECTED_SUBMISSION_OR_TOOL")
        val headers = rows.filter { it.getString("type") == "request/header" && it.getLong("seq") > saved.getLong("createEndSeq") }
        demand(headers.isNotEmpty(), "MODEL_EVIDENCE_MISSING")
        for (header in headers) {
            val config = header.getJSONObject("data").getJSONObject("header").getJSONObject("config")
            demand(config.getString("provider") == "deepseek-account" && config.getString("model") == saved.getString("model"), "MODEL_CHANGED")
        }
        val ends = rows.filter { it.getString("type") == "turn/end" }
        demand(ends.size == 2 && ends.all { it.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed" } &&
            ends.last().getJSONObject("data").getInt("turn") == 2, "DELIVERY_TURN_FAILED")
        val finals = rows.filter { it.getString("type") == "assistant/message" && it.getJSONObject("data").getInt("turn") == 2 }
        demand(finals.size == 1, "FINAL_COUNT_INVALID")
        val finalData = finals.single().getJSONObject("data")
        val finalBlocks = finalData.getJSONObject("message").getJSONArray("content")
        val texts = (0 until finalBlocks.length()).map { finalBlocks.getJSONObject(it) }
        demand(texts.all { it.getString("type") in setOf("text", "reasoning") } &&
            texts.filter { it.getString("type") == "text" }.joinToString("") { it.getString("text") }.trim() == marker(caseId) &&
            !finalData.optBoolean("interrupted", false), "FINAL_MARKER_MISMATCH")
        demand(inserted.single().first.getLong("seq") < finals.single().getLong("seq") &&
            finals.single().getLong("seq") < ends.last().getLong("seq"), "DELIVERY_EVENT_ORDER_INVALID")
        return JSONObject().put("deliveryCount", 1).put("humanSubmissions", 1).put("toolCalls", 1).put("completedTurns", 2)
            .put("assistantMarkerMatches", 1).put("historySha256", hash(durable)).put("eventCount", durable.length())
            .put("deliveryInputSeq", inserted.single().first.getLong("seq")).put("finalSeq", finals.single().getLong("seq"))
            .put("endSeq", ends.last().getLong("seq")).put("markerSha256", AgentServiceTaskEvidence.hash(marker(caseId).toByteArray()))
    }
}
