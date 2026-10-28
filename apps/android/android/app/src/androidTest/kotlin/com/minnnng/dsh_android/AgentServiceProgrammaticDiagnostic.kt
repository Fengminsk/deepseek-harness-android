package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject

/** Read-only diagnostics for a named acceptance Session; never return model text or unknown field names. */
object AgentServiceProgrammaticDiagnostic {
    private fun demand(value: Boolean, code: String) = AgentServiceTaskEvidence.demand(value, code)
    private fun canonical(value: Any?) = AgentServiceTaskEvidence.canonical(value)
    private fun hash(value: String) = AgentServiceTaskEvidence.hash(value.toByteArray(Charsets.UTF_8))
    private fun fingerprint(present: Boolean, value: Any?): JSONObject {
        val type = if (!present) "missing" else when (value) {
            null, JSONObject.NULL -> "null"
            is String -> "string"
            is JSONObject -> "object"
            is JSONArray -> "array"
            is Boolean -> "boolean"
            is Number -> "number"
            else -> "unknown"
        }
        val bytes = if (!present) null else (if (value is String) value else canonical(value)).toByteArray(Charsets.UTF_8)
        return JSONObject().put("present", present).put("type", type).put("bytes", bytes?.size ?: 0)
            .put("sha256", bytes?.let { AgentServiceTaskEvidence.hash(it) } ?: JSONObject.NULL)
    }

    /** Exact equality remains required; fingerprints explain differences without retaining raw arguments. */
    fun arguments(raw: String, caseId: String, exercise: String): JSONObject {
        val expected = AgentServiceProgrammaticEvidence.arguments(caseId, exercise)
        demand(raw.toByteArray(Charsets.UTF_8).size <= 262144, "PROGRAMMATIC_ARGUMENTS_OVERSIZED")
        val actual = try { JSONObject(raw) } catch (error: org.json.JSONException) { null }
        val fields = if (exercise == "ptc") listOf("code", "description") else listOf("script", "meta", "meta.name", "meta.description")
        fun locate(objectValue: JSONObject?, path: String): Pair<Boolean, Any?> {
            val parts = path.split('.')
            val owner = if (parts.size == 1) objectValue else objectValue?.optJSONObject(parts[0])
            return (owner?.has(parts.last()) == true) to owner?.opt(parts.last())
        }
        val rows = JSONArray()
        for (field in fields) {
            val (wanted, value) = locate(expected, field)
            val (present, observed) = locate(actual, field)
            rows.put(JSONObject().put("field", field).put("expected", fingerprint(wanted, value))
                .put("actual", fingerprint(present, observed)).put("matches", wanted == present && canonical(value) == canonical(observed)))
        }
        val allowed = if (exercise == "ptc") setOf("code", "description") else setOf("script", "meta")
        val extras = actual?.keys()?.asSequence()?.count { it !in allowed } ?: 0
        val nested = actual?.optJSONObject("meta")?.keys()?.asSequence()?.count { it !in setOf("name", "description") } ?: 0
        return JSONObject().put("schema", 1).put("exercise", exercise).put("parsed", actual != null)
            .put("matches", actual != null && canonical(actual) == canonical(expected))
            .put("rawBytes", raw.toByteArray(Charsets.UTF_8).size).put("rawSha256", hash(raw))
            .put("expectedSha256", hash(canonical(expected))).put("actualSha256", actual?.let { hash(canonical(it)) } ?: JSONObject.NULL)
            .put("unexpectedFields", extras).put("unexpectedMetaFields", nested).put("fields", rows)
    }

    private fun rows(events: JSONArray): List<JSONObject> {
        demand(events.length() in 1..511, "DIAGNOSTIC_HISTORY_SIZE_INVALID")
        val rows = (0 until events.length()).map { events.getJSONObject(it) }
        var previous = -1L
        for (row in rows) { demand(row.getLong("seq") > previous, "DIAGNOSTIC_EVENT_ORDER_INVALID"); previous = row.getLong("seq") }
        return rows
    }
    private fun stable(events: List<JSONObject>): String = canonical(JSONArray(events.map { row ->
        JSONObject().put("seq", row.getLong("seq")).put("type", row.getString("type")).put("data", row.getJSONObject("data"))
            .put("sourceEventSeqs", row.optJSONArray("sourceEventSeqs") ?: JSONObject.NULL)
    }))

    /** Only official reads and owned export callbacks occur; incomplete lineage is never archive permission. */
    fun inspect(caseId: String, exercise: String, call: (String, JSONObject) -> JSONObject,
                exported: (String) -> JSONObject): JSONObject {
        demand(AgentServiceProgrammaticEvidence.validCaseId(caseId) && AgentServiceProgrammaticEvidence.workflow(exercise), "DIAGNOSTIC_CASE_INVALID")
        val parentId = "android-account-acceptance-$caseId"
        fun read(id: String): List<JSONObject> {
            val value = call("session.read", JSONObject().put("sessionId", id))
            demand(!value.has("snapshot") && !value.has("_pocket_error"), "DIAGNOSTIC_HISTORY_UNAVAILABLE")
            return rows(value.getJSONArray("events"))
        }
        fun verifyExport(id: String, history: List<JSONObject>): JSONObject {
            val document = exported(id)
            val header = document.getJSONObject("header")
            demand(header.getString("type") == "session" && header.getInt("version") == 4 && header.getString("id") == id,
                "EXPORT_SESSION_MISMATCH")
            demand(stable(history) == stable(rows(document.getJSONArray("events"))), "DIAGNOSTIC_DURABLE_MISMATCH")
            return header
        }
        val parent = read(parentId)
        verifyExport(parentId, parent)
        val users = parent.filter { it.getString("type") == "user/message" && it.getJSONObject("data").optJSONObject("source")?.optString("kind") == "user" }
        demand(users.size == 1, "DIAGNOSTIC_USER_COUNT_INVALID")
        val user = users.single().getJSONObject("data")
        demand(user.getJSONObject("source").getString("rpcId") == "account-request-$caseId", "REQUEST_ID_MISMATCH")
        demand(canonical(user.getJSONArray("content")) == canonical(JSONArray().put(JSONObject().put("type", "text")
            .put("text", AgentServiceProgrammaticEvidence.prompt(caseId, exercise)))), "USER_CONTENT_MISMATCH")
        val calls = parent.filter { it.getString("type") == "tool/call" }
        demand(calls.size == 1, "DIAGNOSTIC_CALL_COUNT_INVALID")
        val invocation = calls.single()
        val data = invocation.getJSONObject("data")
        demand(data.getString("name") == "workflow" && data.getInt("turn") == 1 && invocation.getLong("seq") > users.single().getLong("seq"), "PROGRAMMATIC_TOOL_INVALID")
        val result = JSONObject().put("schema", 1).put("originalExercise", exercise).put("parentEventCount", parent.size)
            .put("parentHistorySha256", hash(stable(parent))).put("toolStartSeq", invocation.getLong("seq"))
            .put("arguments", arguments(data.getString("arguments"), caseId, exercise))
            .put("cleanupAuthorized", false)
        val starts = parent.filter { it.getString("type") == "tool-workflow/run-start" }
        val members = parent.filter { it.getString("type") == "tool-workflow/agent-start" }
        val lineage = JSONObject().put("state", "unconfirmed").put("runCount", starts.size).put("memberCount", members.size)
        result.put("lineage", lineage)
        if (members.isEmpty()) return result.apply { lineage.put("state", "no_member_record") }
        if (starts.size != 1 || members.size != 1) return result
        val start = starts.single(); val member = members.single()
        val runId = start.getJSONObject("data").optString("runId")
        val childId = member.getJSONObject("data").optString("childId")
        if (!AgentServiceProgrammaticEvidence.validCaseId(runId) || !AgentServiceProgrammaticEvidence.validCaseId(childId) ||
            member.getJSONObject("data").optString("runId") != runId || member.getJSONObject("data").optInt("seq") != 1 ||
            start.getLong("seq") <= invocation.getLong("seq") || member.getLong("seq") <= start.getLong("seq")) return result
        val child: List<JSONObject>
        val childHeader: JSONObject
        try {
            child = read(childId)
            childHeader = verifyExport(childId, child)
        } catch (error: Exception) {
            // The parent argument evidence remains useful; unavailable child evidence never grants cleanup authority.
            return result.apply { lineage.put("state", "child_read_unconfirmed") }
        }
        if (childHeader.optString("origin") != "subagent" || childHeader.optString("parentSession") != parentId) return result
        val turnEnds = child.filter { it.getString("type") == "turn/end" }
        val terminal = if (turnEnds.size == 1) turnEnds.single().getJSONObject("data").optJSONObject("reason")?.optString("kind") else null
        val fixedTerminal = terminal?.takeIf { it in setOf("completed", "cancelled", "error", "aborted") } ?: "unconfirmed"
        lineage.put("state", "verified").put("runId", runId).put("childSessionId", childId)
            .put("childEventCount", child.size).put("childHistorySha256", hash(stable(child))).put("childTerminal", fixedTerminal)
        return result
    }
}
