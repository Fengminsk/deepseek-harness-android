package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Pure checks for one dedicated real-account submission; failures never include model or account text. */
object AgentServiceTaskEvidence {
    class Rejected(val code: String) : IllegalStateException(code)
    fun demand(value: Boolean, code: String) { if (!value) throw Rejected(code) }
    fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    fun marker(caseId: String) = "account-acceptance-$caseId"
    fun prompt(caseId: String) = "请只回复这一行：${marker(caseId)}。不要调用任何工具，不要读取文件，不要添加解释。"

    /** Validate only this Session's Android notice; retain hashes instead of notification text. */
    fun completionNotice(facts: JSONObject, caseId: String): JSONObject {
        val expectedTag = "pocket-completed:android-account-acceptance-$caseId"
        demand(facts.getInt("matchingCount") == 1 && facts.getString("tag") == expectedTag &&
            facts.getInt("notificationId") == 3 && facts.getBoolean("packageMatches"), "NOTICE_IDENTITY_MISMATCH")
        demand(facts.getString("preview") == marker(caseId), "NOTICE_PREVIEW_MISMATCH")
        demand(facts.getString("channelId") == "task-completed" && facts.getBoolean("visibilityPrivate") &&
            facts.getBoolean("autoCancel"), "NOTICE_PRESENTATION_MISMATCH")
        demand(facts.getBoolean("contentIntentPresent") && facts.getBoolean("contentIntentCreatorMatches"), "NOTICE_INTENT_MISMATCH")
        return JSONObject().put("schema", 1).put("observed", true).put("matchingCount", 1).put("notificationId", 3)
            .put("channelId", "task-completed").put("tagSha256", hash(expectedTag.toByteArray(Charsets.UTF_8)))
            .put("previewSha256", hash(marker(caseId).toByteArray(Charsets.UTF_8))).put("visibilityPrivate", true)
            .put("autoCancel", true).put("contentIntentPresent", true).put("contentIntentCreatorMatches", true)
    }

    fun radioCommand(caseId: String): String = listOf("python3 - <<'PY'", "import hashlib,json,time",
        "marker='${marker(caseId)}'", "started=time.monotonic()", "time.sleep(40)",
        "print(json.dumps({'marker':marker,'sha256':hashlib.sha256(marker.encode()).hexdigest(),'waitMs':int((time.monotonic()-started)*1000)}))", "PY").joinToString("\n")
    fun radioPrompt(caseId: String) = "这是本地任务的断网恢复验收。请只调用一次 linux_exec，timeoutMs 为 120000，command 必须原样使用以下代码，不添加其他参数，不调用其他工具，不读取或修改文件。工具成功后只回复 ${marker(caseId)}。\n" + radioCommand(caseId)

    /** The durable call precedes dispatch; the final native receipt must separately confirm execution. */
    fun radioCall(event: JSONObject, caseId: String): JSONObject {
        demand(event.getString("type") == "tool/call", "RADIO_CALL_INVALID")
        val data = event.getJSONObject("data")
        demand(data.getString("name") == "linux_exec" && data.getInt("turn") == 1, "RADIO_TOOL_INVALID")
        val args = JSONObject(data.getString("arguments"))
        demand(args.keys().asSequence().toSet() == setOf("command", "timeoutMs") &&
            args.getString("command") == radioCommand(caseId) && args.getInt("timeoutMs") == 120000, "RADIO_ARGUMENTS_CHANGED")
        val callId = data.getString("callId")
        demand(callId.isNotBlank() && callId.length <= 256, "RADIO_CALL_ID_INVALID")
        return JSONObject().put("callId", callId).put("toolStartSeq", event.getLong("seq"))
            .put("commandSha256", hash(radioCommand(caseId).toByteArray(Charsets.UTF_8)))
    }

    fun radioReceipt(call: JSONObject, result: JSONObject, caseId: String): JSONObject {
        val facts = radioCall(call, caseId)
        demand(result.getString("type") == "tool/result" && result.getLong("seq") > call.getLong("seq"), "RADIO_RESULT_INVALID")
        val data = result.getJSONObject("data")
        val message = data.getJSONObject("message")
        demand(data.getInt("turn") == 1 && message.getString("toolCallId") == facts.getString("callId") &&
            !message.getBoolean("isError"), "RADIO_TOOL_FAILED")
        val sources = result.getJSONArray("sourceEventSeqs")
        demand(sources.length() == 1 && sources.getLong(0) == call.getLong("seq"), "RADIO_RESULT_SOURCE_MISMATCH")
        val content = message.getJSONArray("content")
        demand(content.length() == 1 && content.getJSONObject(0).getString("type") == "text", "RADIO_RECEIPT_INVALID")
        val receipt = JSONObject(content.getJSONObject(0).getString("text"))
        demand(receipt.getString("sessionId") == "android-account-acceptance-$caseId", "RADIO_RECEIPT_SESSION_MISMATCH")
        demand(receipt.getString("status") == "completed" && receipt.getInt("exitCode") == 0 &&
            receipt.getBoolean("retirementConfirmed") && !receipt.getBoolean("cancelled") &&
            !receipt.getBoolean("timedOut") && !receipt.getBoolean("truncated") && !receipt.optBoolean("cancelRequested", false), "RADIO_EXECUTION_FAILED")
        val output = receipt.getString("output").trim()
        demand(output.length <= 1024, "RADIO_OUTPUT_OVERSIZED")
        val value = JSONObject(output)
        demand(value.keys().asSequence().toSet() == setOf("marker", "sha256", "waitMs") && value.getString("marker") == marker(caseId) &&
            value.getString("sha256") == hash(marker(caseId).toByteArray(Charsets.UTF_8)) && value.getLong("waitMs") in 39000..120000,
            "RADIO_OUTPUT_MISMATCH")
        val id = receipt.getString("id")
        demand(id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")), "RADIO_RUN_ID_INVALID")
        demand(receipt.getInt("guestUid") > 0, "RADIO_GUEST_INVALID")
        return facts.put("toolEndSeq", result.getLong("seq")).put("linuxReceipt", JSONObject()
            .put("id", id).put("status", "completed").put("exitCode", 0).put("retirementConfirmed", true)
            .put("cancelled", false).put("timedOut", false).put("truncated", false).put("cancelRequested", false)
            .put("diskCommitted", receipt.getBoolean("diskCommitted")).put("guestUid", receipt.getInt("guestUid"))
            .put("waitMs", value.getLong("waitMs")).put("outputSha256", hash(output.toByteArray(Charsets.UTF_8))))
    }

    fun runningOwnTask(snapshot: JSONObject, sessionId: String): Boolean {
        val active = snapshot.getJSONArray("active")
        return (0 until active.length()).map { active.getJSONObject(it) }.count {
            it.getString("sessionId") == sessionId && it.getString("status") == "running"
        } == 1
    }

    /** A missing or unavailable current account model is a refusal, never a fallback. */
    fun model(catalog: JSONObject): String {
        val selection = catalog.getJSONObject("default")
        demand(selection.getString("provider") == "deepseek-account", "DEFAULT_NOT_ACCOUNT")
        val model = selection.getString("model")
        demand(model.matches(Regex("[A-Za-z0-9._:/-]{1,128}")), "MODEL_ID_INVALID")
        val groups = catalog.getJSONArray("groups")
        val account = (0 until groups.length()).map { groups.getJSONObject(it) }
            .filter { it.getString("id") == "deepseek-account" }
        demand(account.size == 1, "ACCOUNT_UNAVAILABLE")
        val models = account.single().getJSONArray("models")
        demand((0 until models.length()).count { models.getJSONObject(it).getString("id") == model } == 1,
            "MODEL_UNAVAILABLE")
        return model
    }

    /** Only the owned plain Session log may occur; no extraction or arbitrary path reads occur. */
    fun readExport(input: InputStream, sessionId: String): JSONArray {
        val text = ZipInputStream(input).use { zip ->
            val entry = zip.nextEntry ?: throw Rejected("EXPORT_EMPTY")
            demand(entry.name == "session.v4.jsonl" && !entry.isDirectory, "EXPORT_ENTRY_INVALID")
            val bytes = zip.readNBytes(1024 * 1024 + 1)
            demand(bytes.size in 1..1024 * 1024, "EXPORT_OVERSIZED")
            zip.closeEntry()
            demand(zip.nextEntry == null, "EXPORT_UNEXPECTED_ENTRY")
            bytes.toString(Charsets.UTF_8)
        }
        demand(text.endsWith("\n"), "EXPORT_TRUNCATED")
        val rows = text.lineSequence().filter { it.isNotBlank() }.take(513).map { JSONObject(it) }.toList()
        demand(rows.size in 2..512, "EXPORT_EVENTS_INVALID")
        val header = rows.first()
        demand(header.getString("type") == "session" && header.getInt("version") == 4 &&
            header.getString("id") == sessionId, "EXPORT_SESSION_MISMATCH")
        return JSONArray(rows.drop(1))
    }

    internal fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }

    /** Both live and flushed records must independently contain a single completed assistant marker. */
    fun completed(history: JSONArray, durable: JSONArray, caseId: String, requestId: String, model: String,
                  radio: Boolean = false, exercise: String = if (radio) "radio-linux" else "echo"): JSONObject {
        val programmatic = AgentServiceProgrammaticEvidence.supported(exercise)
        demand(exercise in setOf("echo", "radio-linux", "ptc", "workflow") && radio == (exercise == "radio-linux"), "EXERCISE_INVALID")
        val toolExercise = radio || programmatic
        val types = setOf("user/message", "request/header", "turn/start", "assistant/message", "turn/end", "tool/call", "tool/result",
            "tool/ptc-dispatch-start", "tool/ptc-dispatch", "tool-workflow/run-start", "tool-workflow/run-end",
            "tool-workflow/agent-start", "tool-workflow/agent-end")
        fun inspect(events: JSONArray): Pair<JSONObject, String> {
            demand(events.length() in 1..511, "HISTORY_SIZE_INVALID")
            val rows = (0 until events.length()).map { events.getJSONObject(it) }
            var previous = -1L
            for (row in rows) {
                val seq = row.getLong("seq")
                demand(seq > previous, "EVENT_ORDER_INVALID"); previous = seq
                val allowedTools = if (exercise == "ptc") setOf("tool/call", "tool/result", "tool/ptc-dispatch-start", "tool/ptc-dispatch")
                    else setOf("tool/call", "tool/result")
                demand(!row.getString("type").startsWith("tool/") || toolExercise && row.getString("type") in allowedTools, "TOOL_INVOKED")
                demand(!row.getString("type").startsWith("tool-workflow/") || exercise == "workflow", "UNEXPECTED_WORKFLOW")
            }
            fun all(type: String) = rows.filter { it.getString("type") == type }
            fun one(type: String): JSONObject {
                val found = all(type); demand(found.size == 1, "EVENT_COUNT_INVALID"); return found.single()
            }
            val users = all("user/message").filter { it.getJSONObject("data").getJSONObject("source").getString("kind") == "user" }
            demand(users.size == 1, "USER_COUNT_INVALID")
            val user = users.single()
            val userData = user.getJSONObject("data")
            demand(userData.getJSONObject("source").getString("rpcId") == requestId, "REQUEST_ID_MISMATCH")
            val expectedPrompt = if (radio) radioPrompt(caseId) else if (programmatic) AgentServiceProgrammaticEvidence.prompt(caseId, exercise) else prompt(caseId)
            val expected = JSONArray().put(JSONObject().put("type", "text").put("text", expectedPrompt))
            demand(canonical(userData.getJSONArray("content")) == canonical(expected), "USER_CONTENT_MISMATCH")
            val headers = all("request/header")
            demand(headers.isNotEmpty(), "MODEL_EVIDENCE_MISSING")
            for (header in headers) {
                val config = header.getJSONObject("data").getJSONObject("header").getJSONObject("config")
                demand(config.getString("provider") == "deepseek-account" && config.getString("model") == model,
                    "MODEL_CHANGED")
            }
            val turn = one("turn/start")
            val assistant = if (!toolExercise) one("assistant/message") else {
                val finals = all("assistant/message").filter { row ->
                    val content = row.getJSONObject("data").getJSONObject("message").getJSONArray("content")
                    (0 until content.length()).map { content.getJSONObject(it) }.filter { it.getString("type") == "text" }
                        .joinToString("") { it.getString("text") }.trim() == marker(caseId)
                }
                demand(finals.size == 1, "ASSISTANT_MARKER_MISMATCH"); finals.single()
            }
            val data = assistant.getJSONObject("data")
            val blocks = data.getJSONObject("message").getJSONArray("content")
            val texts = ArrayList<String>()
            for (i in 0 until blocks.length()) {
                val block = blocks.getJSONObject(i)
                when (block.getString("type")) {
                    "text" -> texts.add(block.getString("text"))
                    "reasoning" -> Unit
                    else -> throw Rejected("ASSISTANT_BLOCK_INVALID")
                }
            }
            demand(texts.joinToString("").trim() == marker(caseId), "ASSISTANT_MARKER_MISMATCH")
            demand(!data.optBoolean("interrupted", false), "ASSISTANT_INTERRUPTED")
            val end = one("turn/end")
            demand(end.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed",
                "TURN_NOT_COMPLETED")
            demand(turn.getJSONObject("data").getInt("turn") == 1 && data.getInt("turn") == 1 &&
                end.getJSONObject("data").getInt("turn") == 1, "TURN_CHANGED")
            demand(user.getLong("seq") < assistant.getLong("seq") && turn.getLong("seq") < assistant.getLong("seq") &&
                assistant.getLong("seq") < end.getLong("seq"), "COMPLETION_ORDER_INVALID")
            val summary = JSONObject().put("userMessageCount", 1).put("assistantMarkerMatches", 1)
                .put("toolCalls", if (toolExercise) 1 else 0).put("turnEndCount", 1).put("completionKind", "completed")
                .put("endSeq", end.getLong("seq")).put("eventCount", events.length())
            if (radio) {
                val call = one("tool/call"); val returned = one("tool/result")
                val receipt = radioReceipt(call, returned, caseId)
                demand(returned.getLong("seq") < assistant.getLong("seq"), "RADIO_FINAL_BEFORE_RESULT")
                for (key in receipt.keys()) summary.put(key, receipt.get(key))
                summary.put("retryEventCount", all("llm/retry").size)
            }
            if (programmatic) {
                val receipt = AgentServiceProgrammaticEvidence.receipt(rows, caseId, exercise)
                demand(receipt.getLong("toolEndSeq") < assistant.getLong("seq"), "PROGRAMMATIC_FINAL_BEFORE_RESULT")
                for (key in receipt.keys()) summary.put(key, receipt.get(key))
            }
            val comparison = JSONArray(rows.filter { it.getString("type") in types }.map {
                JSONObject().put("type", it.getString("type")).put("seq", it.getLong("seq")).put("data", it.getJSONObject("data"))
                    .put("sourceEventSeqs", it.opt("sourceEventSeqs") ?: JSONObject.NULL)
            })
            return summary to canonical(comparison)
        }
        val (result, live) = inspect(history)
        val (stored, persisted) = inspect(durable)
        demand(live == persisted && result.getLong("endSeq") == stored.getLong("endSeq"), "DURABLE_MISMATCH")
        return result.put("historySha256", hash(canonical(durable).toByteArray(Charsets.UTF_8)))
            .put("eventCount", durable.length())
    }
}
