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

    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }

    /** Both live and flushed records must independently contain a single completed assistant marker. */
    fun completed(history: JSONArray, durable: JSONArray, caseId: String, requestId: String, model: String): JSONObject {
        val types = setOf("user/message", "request/header", "turn/start", "assistant/message", "turn/end")
        fun inspect(events: JSONArray): Pair<JSONObject, String> {
            demand(events.length() in 1..511, "HISTORY_SIZE_INVALID")
            val rows = (0 until events.length()).map { events.getJSONObject(it) }
            var previous = -1L
            for (row in rows) {
                val seq = row.getLong("seq")
                demand(seq > previous, "EVENT_ORDER_INVALID"); previous = seq
                demand(!row.getString("type").startsWith("tool/"), "TOOL_INVOKED")
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
            val expected = JSONArray().put(JSONObject().put("type", "text").put("text", prompt(caseId)))
            demand(canonical(userData.getJSONArray("content")) == canonical(expected), "USER_CONTENT_MISMATCH")
            val headers = all("request/header")
            demand(headers.isNotEmpty(), "MODEL_EVIDENCE_MISSING")
            for (header in headers) {
                val config = header.getJSONObject("data").getJSONObject("header").getJSONObject("config")
                demand(config.getString("provider") == "deepseek-account" && config.getString("model") == model,
                    "MODEL_CHANGED")
            }
            val turn = one("turn/start")
            val assistant = one("assistant/message")
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
                .put("toolCalls", 0).put("turnEndCount", 1).put("completionKind", "completed")
                .put("endSeq", end.getLong("seq")).put("eventCount", events.length())
            val comparison = JSONArray(rows.filter { it.getString("type") in types }.map {
                JSONObject().put("type", it.getString("type")).put("seq", it.getLong("seq")).put("data", it.getJSONObject("data"))
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
