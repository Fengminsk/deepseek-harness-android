package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject

/** Fixed offline file work in a fresh child guest; no Android file import or network access. */
object AgentServiceChildLinuxEvidence {
    private fun demand(value: Boolean, code: String) = AgentServiceTaskEvidence.demand(value, code)
    fun payload(caseId: String) = "${AgentServiceProgrammaticEvidence.childMarker(caseId)}\n7,11,13\n"
    fun payloadHash(caseId: String) = AgentServiceTaskEvidence.hash(payload(caseId).toByteArray(Charsets.UTF_8))
    fun response(caseId: String) = "${AgentServiceProgrammaticEvidence.childMarker(caseId)} sha256=${payloadHash(caseId)} bytes=${payload(caseId).toByteArray(Charsets.UTF_8).size}"
    fun command(caseId: String): String {
        demand(AgentServiceProgrammaticEvidence.validCaseId(caseId), "CHILD_LINUX_CASE_INVALID")
        return listOf("python3 - <<'PY'", "import hashlib,json,pathlib,tempfile,zipfile",
            "marker='${AgentServiceProgrammaticEvidence.childMarker(caseId)}'", "payload=(marker+'\\n7,11,13\\n').encode()",
            "with tempfile.TemporaryDirectory(prefix=marker+'-',dir='/workspace') as root:",
            "    source=pathlib.Path(root)/'input.txt'", "    archive=pathlib.Path(root)/'result.zip'", "    source.write_bytes(payload)",
            "    with zipfile.ZipFile(archive,'w') as z: z.writestr('input.txt',source.read_bytes())",
            "    with zipfile.ZipFile(archive) as z:", "        assert z.namelist()==['input.txt']", "        readback=z.read('input.txt')",
            "    assert readback==payload", "    digest=hashlib.sha256(readback).hexdigest()",
            "assert not pathlib.Path(root).exists()",
            "print(json.dumps({'marker':marker,'sha256':digest,'bytes':len(readback),'archiveEntries':1,'cleaned':True}))", "PY").joinToString("\n")
    }
    fun arguments(caseId: String) = JSONObject().put("command", command(caseId)).put("timeoutMs", 120000)
    fun prompt(caseId: String) = "请只调用一次 linux_exec，原样使用以下 JSON 参数。仅在自己的 Linux /workspace 临时目录中执行这段离线文件任务，不访问网络、不导入或读取用户文件、不调用其他工具。" +
        "成功且 cleaned 为 true 后只回复这一行：${response(caseId)}。\n${arguments(caseId)}"

    /** Bind native execution, its output and the persisted source link to this exact child Session. */
    fun receipt(rows: List<JSONObject>, caseId: String, childId: String, appUid: Int): JSONObject {
        demand(appUid > 0, "CHILD_LINUX_APP_UID_INVALID")
        fun one(type: String): JSONObject {
            val found = rows.filter { it.getString("type") == type }
            demand(found.size == 1, "CHILD_LINUX_TOOL_COUNT_INVALID"); return found.single()
        }
        val invoked = one("tool/call"); val returned = one("tool/result")
        val data = invoked.getJSONObject("data")
        val callId = data.getString("callId")
        demand(data.getString("name") == "linux_exec" && data.getInt("turn") == 1 && callId.isNotBlank() && callId.length <= 256,
            "CHILD_LINUX_TOOL_INVALID")
        demand(AgentServiceTaskEvidence.canonical(JSONObject(data.getString("arguments"))) ==
            AgentServiceTaskEvidence.canonical(arguments(caseId)), "CHILD_LINUX_ARGUMENTS_CHANGED")
        val result = returned.getJSONObject("data"); val message = result.getJSONObject("message")
        val sources = returned.getJSONArray("sourceEventSeqs")
        demand(result.getInt("turn") == 1 && returned.getLong("seq") > invoked.getLong("seq") &&
            sources.length() == 1 && sources.getLong(0) == invoked.getLong("seq") &&
            message.getString("toolCallId") == callId && !message.getBoolean("isError"), "CHILD_LINUX_RESULT_MISMATCH")
        val blocks = message.getJSONArray("content")
        demand(blocks.length() == 1 && blocks.getJSONObject(0).getString("type") == "text", "CHILD_LINUX_RECEIPT_INVALID")
        val text = blocks.getJSONObject(0).getString("text")
        demand(text.length <= 8192, "CHILD_LINUX_RECEIPT_OVERSIZED")
        val native = JSONObject(text)
        demand(native.getString("sessionId") == childId && AgentServiceProgrammaticEvidence.validCaseId(native.getString("id")), "CHILD_LINUX_SESSION_MISMATCH")
        demand(native.getString("status") == "completed" && native.getInt("exitCode") == 0 && native.getBoolean("retirementConfirmed") &&
            !native.getBoolean("cancelled") && !native.getBoolean("timedOut") && !native.getBoolean("truncated") &&
            !native.getBoolean("cancelRequested"), "CHILD_LINUX_EXECUTION_UNCONFIRMED")
        val guestUid = native.getInt("guestUid")
        demand(guestUid > 0 && guestUid != appUid, "CHILD_LINUX_UID_NOT_ISOLATED")
        val output = native.getString("output").trim()
        demand(output.length <= 1024, "CHILD_LINUX_OUTPUT_OVERSIZED")
        val value = JSONObject(output)
        demand(value.keys().asSequence().toSet() == setOf("marker", "sha256", "bytes", "archiveEntries", "cleaned") &&
            value.getString("marker") == AgentServiceProgrammaticEvidence.childMarker(caseId) && value.getString("sha256") == payloadHash(caseId) &&
            value.getInt("bytes") == payload(caseId).toByteArray(Charsets.UTF_8).size && value.getInt("archiveEntries") == 1 &&
            value.getBoolean("cleaned"), "CHILD_LINUX_FILE_RESULT_INVALID")
        return JSONObject().put("id", native.getString("id")).put("sessionId", childId).put("callId", callId)
            .put("toolStartSeq", invoked.getLong("seq")).put("toolEndSeq", returned.getLong("seq"))
            .put("commandSha256", AgentServiceTaskEvidence.hash(command(caseId).toByteArray(Charsets.UTF_8)))
            .put("status", "completed").put("exitCode", 0).put("retirementConfirmed", true).put("guestUid", guestUid).put("appUid", appUid)
            .put("cancelled", false).put("timedOut", false).put("truncated", false).put("cancelRequested", false)
            .put("diskCommitted", native.getBoolean("diskCommitted")).put("outputSha256", AgentServiceTaskEvidence.hash(output.toByteArray(Charsets.UTF_8)))
            .put("fileSha256", value.getString("sha256")).put("fileBytes", value.getInt("bytes")).put("archiveEntries", 1).put("cleaned", true)
    }
}
