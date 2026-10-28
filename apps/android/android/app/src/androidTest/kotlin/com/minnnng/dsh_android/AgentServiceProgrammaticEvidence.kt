package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject

/** Fixed real-account exercises; this validator never dispatches tools or accesses user files. */
object AgentServiceProgrammaticEvidence {
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private fun demand(value: Boolean, code: String) = AgentServiceTaskEvidence.demand(value, code)
    fun workflow(exercise: String) = exercise in setOf("workflow", "workflow-linux")
    fun supported(exercise: String) = exercise == "ptc" || workflow(exercise)
    fun validCaseId(value: String?) = value != null && uuid.matches(value)
    /** Archive only the validated dedicated child through the original workspace owner; active work still rejects. */
    fun archiveChild(childId: String, call: (String, JSONObject) -> JSONObject) {
        demand(uuid.matches(childId), "WORKFLOW_CHILD_ID_INVALID")
        val result = call("api.call", JSONObject().put("namespace", "workspace").put("method", "archiveSession")
            .put("args", JSONObject().put("request", JSONObject().put("sessionId", childId))))
        val archived = result.optJSONArray("archivedSessionIds")
        demand(!result.has("_pocket_error") && archived != null &&
            (0 until archived.length()).any { archived.opt(it) == childId }, "CHILD_ARCHIVE_UNCONFIRMED")
    }
    /** Revalidate the original completed parent and sole child before the only mutation, without submitting a turn. */
    fun cleanupWorkflow(caseId: String, call: (String, JSONObject) -> JSONObject, exported: (String) -> JSONArray): JSONObject {
        demand(validCaseId(caseId), "CLEANUP_CASE_INVALID")
        val parentId = "android-account-acceptance-$caseId"
        fun read(id: String): JSONArray {
            val value = call("session.read", JSONObject().put("sessionId", id))
            demand(!value.has("snapshot") && !value.has("_pocket_error"), "CLEANUP_HISTORY_UNAVAILABLE")
            return value.getJSONArray("events")
        }
        val parent = read(parentId)
        val header = (0 until parent.length()).map { parent.getJSONObject(it) }
            .firstOrNull { it.getString("type") == "request/header" }
        demand(header != null, "MODEL_EVIDENCE_MISSING")
        val model = header!!.getJSONObject("data").getJSONObject("header").getJSONObject("config").getString("model")
        val evidence = AgentServiceTaskEvidence.completed(parent, exported(parentId), caseId,
            "account-request-$caseId", model, false, "workflow")
        val proof = evidence.getJSONObject("programmatic")
        val childId = proof.getString("childSessionId")
        val observed = call("workflow.inspect", JSONObject().put("sessionId", parentId).put("runId", proof.getString("runId")))
        demand(observed.getString("runId") == proof.getString("runId") && observed.getString("state") == "completed" &&
            !observed.getBoolean("requiresReview"), "WORKFLOW_INSPECTION_UNCONFIRMED")
        proof.put("inspection", JSONObject().put("runId", observed.getString("runId")).put("state", "completed").put("requiresReview", false))
        proof.put("child", child(read(childId), exported(childId), caseId, childId, model))
        archiveChild(childId, call)
        return evidence.put("provider", "deepseek-account").put("model", model)
    }
    fun childMarker(caseId: String) = "account-child-$caseId"
    fun childResponse(caseId: String, exercise: String = "workflow") =
        if (exercise == "workflow-linux") AgentServiceChildLinuxEvidence.response(caseId) else childMarker(caseId)
    /** Fixed prose of the child prompt; the Linux exercise appends its tool arguments as JSON text. */
    fun childPromptIntro(caseId: String, exercise: String = "workflow") =
        if (exercise == "workflow-linux") AgentServiceChildLinuxEvidence.promptIntro(caseId)
        else "请只回复这一行：${childMarker(caseId)}。不要调用任何工具，不要读取文件，不要添加解释。"
    /** Child tool arguments the prompt must carry; the plain workflow exercise carries none. */
    fun childArguments(caseId: String, exercise: String = "workflow"): JSONObject? =
        if (exercise == "workflow-linux") AgentServiceChildLinuxEvidence.arguments(caseId) else null
    fun childPrompt(caseId: String, exercise: String = "workflow"): String {
        val intro = childPromptIntro(caseId, exercise)
        return childArguments(caseId, exercise)?.let { "$intro\n$it" } ?: intro
    }

    private const val SCRIPT_PREFIX = "return await agent("
    private const val SCRIPT_SUFFIX = ");"

    /** Decoded prompt of the reviewed `return await agent(<string>);` program; null for any other program. */
    private fun scriptPrompt(script: String): String? {
        if (!script.startsWith(SCRIPT_PREFIX) || !script.endsWith(SCRIPT_SUFFIX)) return null
        val literal = script.substring(SCRIPT_PREFIX.length, script.length - SCRIPT_SUFFIX.length)
        if (literal.length < 2 || !literal.startsWith("\"") || !literal.endsWith("\"")) return null
        return try {
            val values = JSONArray("[$literal]")
            if (values.length() == 1) values.getString(0) else null
        } catch (error: org.json.JSONException) {
            null
        }
    }

    /** Parsed child arguments after the fixed intro; JSON escape spelling and trailing whitespace do not matter. */
    private fun promptArguments(prompt: String, intro: String): JSONObject? {
        if (!prompt.startsWith("$intro\n")) return null
        return try {
            val tokener = org.json.JSONTokener(prompt.substring(intro.length + 1))
            val value = tokener.nextValue()
            if (tokener.nextClean() != 0.toChar()) null else value as? JSONObject
        } catch (error: org.json.JSONException) {
            null
        }
    }

    private fun argumentsDigest(value: JSONObject?) =
        value?.let { AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.canonical(it).toByteArray(Charsets.UTF_8)) }

    /**
     * Semantic evidence for a model-generated workflow script: the reviewed wrapper, the decoded intro
     * and the parsed child arguments. An equivalent JSON escape spelling changes bytes, not these facts.
     * Only digests and counts leave this function.
     */
    internal fun scriptEvidence(script: String, caseId: String, exercise: String): JSONObject {
        val intro = childPromptIntro(caseId, exercise)
        val expected = childArguments(caseId, exercise)
        val decoded = scriptPrompt(script)
        val prompt = decoded ?: ""
        val promptBytes = prompt.toByteArray(Charsets.UTF_8)
        val expectedBytes = childPrompt(caseId, exercise).toByteArray(Charsets.UTF_8)
        val proseMatches = decoded != null && prompt.startsWith(intro)
        val parsed = if (decoded == null) null else promptArguments(prompt, intro)
        val argumentsMatches = when {
            decoded == null -> false
            expected == null -> prompt == intro
            else -> parsed != null && AgentServiceTaskEvidence.canonical(parsed) == AgentServiceTaskEvidence.canonical(expected)
        }
        return JSONObject().put("wrapperMatches", decoded != null)
            .put("promptBytes", promptBytes.size)
            .put("promptSha256", if (decoded == null) JSONObject.NULL else AgentServiceTaskEvidence.hash(promptBytes))
            .put("expectedPromptBytes", expectedBytes.size)
            .put("expectedPromptSha256", AgentServiceTaskEvidence.hash(expectedBytes))
            .put("proseMatches", proseMatches)
            .put("argumentsMatches", argumentsMatches)
            .put("argumentsSha256", argumentsDigest(parsed) ?: JSONObject.NULL)
            .put("expectedArgumentsSha256", argumentsDigest(expected) ?: JSONObject.NULL)
            .put("matches", decoded != null && proseMatches && argumentsMatches)
    }

    /** Whether a recorded child prompt carries the exact reviewed intro and parsed child arguments. */
    fun childPromptMatches(prompt: String, caseId: String, exercise: String = "workflow"): Boolean {
        val intro = childPromptIntro(caseId, exercise)
        if (!prompt.startsWith(intro)) return false
        val expected = childArguments(caseId, exercise) ?: return prompt == intro
        val parsed = promptArguments(prompt, intro) ?: return false
        return AgentServiceTaskEvidence.canonical(parsed) == AgentServiceTaskEvidence.canonical(expected)
    }
    fun arguments(caseId: String, exercise: String): JSONObject {
        demand(uuid.matches(caseId) && supported(exercise), "PROGRAMMATIC_EXERCISE_INVALID")
        return if (exercise == "ptc") JSONObject().put("code",
            "const children = await tools.list_agents({scope:\"children\"}); return {marker:${JSONObject.quote(AgentServiceTaskEvidence.marker(caseId))},children:children.length};")
            .put("description", "Check this dedicated Session's child catalog")
        else JSONObject().put("script", "return await agent(${JSONObject.quote(childPrompt(caseId, exercise))});")
            .put("meta", JSONObject().put("name", "account-child").put("description", "One dedicated account acceptance child"))
    }
    fun prompt(caseId: String, exercise: String): String =
        "这是实际账号的${if (exercise == "ptc") "PTC" else "工作流及子 Agent"}验收。请只调用一次 ${if (exercise == "ptc") "android_ptc" else "workflow"}，" +
            "必须原样使用以下 JSON 参数。不要额外调用工具，" +
            (if (exercise == "workflow-linux") "除子 Agent 的专用 Linux 文件任务外，不要读取或修改文件。" else "不要读取或修改文件。") +
            "工具成功后只回复这一行：${AgentServiceTaskEvidence.marker(caseId)}。\n" + arguments(caseId, exercise)

    fun call(event: JSONObject, caseId: String, exercise: String): JSONObject {
        demand(event.getString("type") == "tool/call", "PROGRAMMATIC_CALL_INVALID")
        val data = event.getJSONObject("data")
        demand(data.getString("name") == (if (exercise == "ptc") "android_ptc" else "workflow") &&
            data.getInt("turn") == 1, "PROGRAMMATIC_TOOL_INVALID")
        val diagnostic = AgentServiceProgrammaticDiagnostic.arguments(data.getString("arguments"), caseId, exercise)
        if (!diagnostic.getBoolean("matches")) throw AgentServiceTaskEvidence.Rejected("PROGRAMMATIC_ARGUMENTS_CHANGED", diagnostic)
        val actual = JSONObject(data.getString("arguments"))
        val callId = data.getString("callId")
        demand(callId.isNotBlank() && callId.length <= 256, "PROGRAMMATIC_CALL_ID_INVALID")
        return JSONObject().put("callId", callId).put("toolStartSeq", event.getLong("seq"))
            .put("argumentsSha256", AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.canonical(actual).toByteArray(Charsets.UTF_8)))
    }

    /** Validate the one parent result and the recorded callback/member lifecycle, independently of final text. */
    fun receipt(rows: List<JSONObject>, caseId: String, exercise: String): JSONObject {
        fun one(type: String): JSONObject {
            val found = rows.filter { it.getString("type") == type }
            demand(found.size == 1, "PROGRAMMATIC_EVENT_COUNT_INVALID"); return found.single()
        }
        val invoked = one("tool/call")
        val facts = call(invoked, caseId, exercise)
        val returned = one("tool/result")
        val data = returned.getJSONObject("data")
        val message = data.getJSONObject("message")
        demand(returned.getLong("seq") > invoked.getLong("seq") && data.getInt("turn") == 1 &&
            message.getString("toolCallId") == facts.getString("callId") && !message.getBoolean("isError"), "PROGRAMMATIC_TOOL_FAILED")
        val sources = returned.getJSONArray("sourceEventSeqs")
        demand(sources.length() == 1 && sources.getLong(0) == invoked.getLong("seq"), "PROGRAMMATIC_RESULT_SOURCE_MISMATCH")
        val content = message.getJSONArray("content")
        demand(content.length() == 1 && content.getJSONObject(0).getString("type") == "text", "PROGRAMMATIC_RESULT_INVALID")
        val text = content.getJSONObject(0).getString("text")
        demand(text.length <= 2048, "PROGRAMMATIC_RESULT_OVERSIZED")
        val proof = JSONObject().put("exercise", exercise).put("tool", if (exercise == "ptc") "android_ptc" else "workflow")
            .put("callId", facts.getString("callId")).put("argumentsSha256", facts.getString("argumentsSha256"))
            .put("resultSha256", AgentServiceTaskEvidence.hash(text.toByteArray(Charsets.UTF_8)))
        fun inside(event: JSONObject) = event.getLong("seq") > invoked.getLong("seq") && event.getLong("seq") < returned.getLong("seq")
        if (exercise == "ptc") {
            val value = JSONObject(text)
            demand(value.keys().asSequence().toSet() == setOf("marker", "children") &&
                value.getString("marker") == AgentServiceTaskEvidence.marker(caseId) && value.getInt("children") == 0,
                "PTC_RESULT_MISMATCH")
            val started = one("tool/ptc-dispatch-start"); val settled = one("tool/ptc-dispatch")
            demand(inside(started) && inside(settled) && started.getLong("seq") < settled.getLong("seq"), "PTC_CALLBACK_ORDER_INVALID")
            val subCallId = "${facts.getString("callId")}:ptc:1"
            for (event in listOf(started, settled)) {
                val callback = event.getJSONObject("data")
                demand(callback.getString("name") == "list_agents" && callback.getString("parentCallId") == facts.getString("callId") &&
                    callback.getString("rootCallId") == facts.getString("callId") && callback.getString("subCallId") == subCallId &&
                    AgentServiceTaskEvidence.canonical(callback.getJSONObject("arguments")) == "{\"scope\":\"children\"}", "PTC_CALLBACK_IDENTITY_MISMATCH")
            }
            val callback = settled.getJSONObject("data")
            val callbackContent = callback.getJSONArray("content")
            demand(!callback.getBoolean("isError") && !callback.has("error") && callbackContent.length() == 1 &&
                callbackContent.getJSONObject(0).getString("type") == "text" &&
                callbackContent.getJSONObject(0).getString("text") == "(no subagents)", "PTC_CALLBACK_FAILED")
            demand(rows.none { it.getString("type").startsWith("tool-workflow/") }, "UNEXPECTED_WORKFLOW")
            proof.put("reviewedCallbacks", 1).put("callbackName", "list_agents").put("callbackStartSeq", started.getLong("seq"))
                .put("callbackEndSeq", settled.getLong("seq")).put("children", 0)
        } else {
            demand(text == "workflow \"account-child\" completed (1 agent).\nReturn value:\n${JSONObject.quote(childResponse(caseId, exercise))}",
                "WORKFLOW_RESULT_MISMATCH")
            val start = one("tool-workflow/run-start"); val end = one("tool-workflow/run-end")
            val member = one("tool-workflow/agent-start"); val memberEnd = one("tool-workflow/agent-end")
            val runId = start.getJSONObject("data").getString("runId")
            val childId = member.getJSONObject("data").getString("childId")
            demand(uuid.matches(runId) && uuid.matches(childId), "WORKFLOW_ID_INVALID")
            demand(start.getJSONObject("data").getString("name") == "account-child", "WORKFLOW_NAME_CHANGED")
            for (event in listOf(start, member, memberEnd, end)) demand(inside(event) &&
                event.getJSONObject("data").getString("runId") == runId, "WORKFLOW_RUN_MISMATCH")
            demand(start.getLong("seq") < member.getLong("seq") && member.getLong("seq") < memberEnd.getLong("seq") &&
                memberEnd.getLong("seq") < end.getLong("seq"), "WORKFLOW_EVENT_ORDER_INVALID")
            demand(member.getJSONObject("data").getInt("seq") == 1 && memberEnd.getJSONObject("data").getInt("seq") == 1 &&
                memberEnd.getJSONObject("data").getString("outcome") == "completed" && end.getJSONObject("data").getString("stopReason") == "completed",
                "WORKFLOW_NOT_COMPLETED")
            demand(rows.count { it.getString("type").startsWith("tool-workflow/") } == 4, "WORKFLOW_EXTRA_EVENT")
            proof.put("runId", runId).put("childSessionId", childId).put("memberCount", 1).put("runEndCount", 1)
                .put("runStartSeq", start.getLong("seq")).put("runEndSeq", end.getLong("seq"))
        }
        return facts.put("toolEndSeq", returned.getLong("seq")).put("programmatic", proof)
    }

    /** Check only a child identified by the validated parent's sole completed workflow member. */
    fun child(history: JSONArray, durable: JSONArray, caseId: String, childId: String, model: String,
              exercise: String = "workflow", appUid: Int? = null): JSONObject {
        demand(uuid.matches(childId), "WORKFLOW_CHILD_ID_INVALID")
        demand(workflow(exercise), "PROGRAMMATIC_EXERCISE_INVALID")
        val linux = exercise == "workflow-linux"
        fun inspect(events: JSONArray): JSONObject? {
            demand(events.length() in 1..511, "CHILD_HISTORY_SIZE_INVALID")
            val rows = (0 until events.length()).map { events.getJSONObject(it) }
            var previous = -1L
            for (row in rows) {
                demand(row.getLong("seq") > previous, "CHILD_EVENT_ORDER_INVALID"); previous = row.getLong("seq")
                demand((!row.getString("type").startsWith("tool/") || linux && row.getString("type") in setOf("tool/call", "tool/result")) &&
                    !row.getString("type").startsWith("tool-workflow/"), "CHILD_TOOL_INVOKED")
            }
            fun all(type: String) = rows.filter { it.getString("type") == type }
            demand(all("turn/start").size == 1 && all("turn/end").size == 1 && (linux || all("assistant/message").size == 1),
                "CHILD_EVENT_COUNT_INVALID")
            val header = all("request/header")
            demand(header.isNotEmpty(), "CHILD_MODEL_EVIDENCE_MISSING")
            for (row in header) {
                val config = row.getJSONObject("data").getJSONObject("header").getJSONObject("config")
                demand(config.getString("provider") == "deepseek-account" && config.getString("model") == model, "CHILD_MODEL_CHANGED")
            }
            val input = all("user/message").flatMap { row ->
                val blocks = row.getJSONObject("data").getJSONArray("content")
                (0 until blocks.length()).map { blocks.getJSONObject(it) }
            }.count { it.optString("type") == "text" && childPromptMatches(it.optString("text"), caseId, exercise) }
            demand(input == 1, "CHILD_PROMPT_MISMATCH")
            val finals = all("assistant/message").filter { row ->
                val content = row.getJSONObject("data").getJSONObject("message").getJSONArray("content")
                (0 until content.length()).map { content.getJSONObject(it) }.filter { it.getString("type") == "text" }
                    .joinToString("") { it.getString("text") }.trim() == childResponse(caseId, exercise)
            }
            demand(finals.size == 1, "CHILD_MARKER_MISMATCH")
            val assistant = finals.single()
            val blocks = assistant.getJSONObject("data").getJSONObject("message").getJSONArray("content")
            val text = ArrayList<String>()
            for (i in 0 until blocks.length()) {
                val block = blocks.getJSONObject(i)
                when (block.getString("type")) {
                    "text" -> text.add(block.getString("text"))
                    "reasoning" -> Unit
                    else -> throw AgentServiceTaskEvidence.Rejected("CHILD_ASSISTANT_BLOCK_INVALID")
                }
            }
            val ended = all("turn/end").single()
            demand(text.joinToString("").trim() == childResponse(caseId, exercise) && !assistant.getJSONObject("data").optBoolean("interrupted", false),
                "CHILD_MARKER_MISMATCH")
            demand(all("turn/start").single().getJSONObject("data").getInt("turn") == 1 &&
                assistant.getJSONObject("data").getInt("turn") == 1 && ended.getJSONObject("data").getInt("turn") == 1 &&
                ended.getJSONObject("data").getJSONObject("reason").getString("kind") == "completed" &&
                all("turn/start").single().getLong("seq") < assistant.getLong("seq") && assistant.getLong("seq") < ended.getLong("seq"),
                "CHILD_TURN_NOT_COMPLETED")
            if (!linux) return null
            val receipt = AgentServiceChildLinuxEvidence.receipt(rows, caseId, childId, appUid ?: 0)
            demand(receipt.getLong("toolStartSeq") > all("turn/start").single().getLong("seq") &&
                receipt.getLong("toolEndSeq") < assistant.getLong("seq"), "CHILD_LINUX_FINAL_BEFORE_RESULT")
            return receipt
        }
        val linuxReceipt = inspect(history); inspect(durable)
        fun evidence(events: JSONArray): String {
            val types = setOf("user/message", "request/header", "turn/start", "assistant/message", "turn/end", "tool/call", "tool/result")
            return AgentServiceTaskEvidence.canonical(JSONArray((0 until events.length()).map { events.getJSONObject(it) }
                .filter { it.getString("type") in types }.map {
                    JSONObject().put("type", it.getString("type")).put("seq", it.getLong("seq")).put("data", it.getJSONObject("data"))
                        .put("sourceEventSeqs", it.opt("sourceEventSeqs") ?: JSONObject.NULL)
                }))
        }
        demand(evidence(history) == evidence(durable), "CHILD_DURABLE_MISMATCH")
        val result = JSONObject().put("sessionId", childId).put("eventCount", durable.length()).put("toolCalls", if (linux) 1 else 0)
            .put("assistantMarkerMatches", 1).put("turnEndCount", 1).put("completionKind", "completed")
            .put("historySha256", AgentServiceTaskEvidence.hash(AgentServiceTaskEvidence.canonical(durable).toByteArray(Charsets.UTF_8)))
        if (linuxReceipt != null) result.put("linuxReceipt", linuxReceipt)
        return result
    }
}
