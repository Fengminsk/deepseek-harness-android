package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.Base64

/** JSON values crossing the guest callback; App roots stay private, child names are rechecked by the broker. */
internal object IsolatedScriptHostCodec {
    const val NETWORK_ACTION = "HTTPS_GET"
    data class NetworkCall(val callId: String, val url: String)

    fun action(requestJson: String): String {
        boundedDepth(requestJson)
        return exactString(JSONObject(requestJson), "action")
    }

    fun parseNetwork(requestJson: String): NetworkCall {
        boundedDepth(requestJson)
        val value = JSONObject(requestJson)
        require(value.keys().asSequence().toSet() == setOf("action", "callId", "url"))
        require(exactString(value, "action") == NETWORK_ACTION)
        val callId = exactString(value, "callId")
        IsolatedNetworkJournal.requireCallId(callId)
        val url = exactString(value, "url")
        IsolatedNetworkBroker.checkedUri(url)
        return NetworkCall(callId, url)
    }

    fun grants(handles: List<IsolatedCapabilityBroker.GrantHandle>): String = JSONArray().apply {
        for (handle in handles) put(JSONObject().apply {
            put("id", handle.id())
            put("actions", JSONArray(handle.actions().map { it.name }.sorted()))
            if (handle.directory()) put("directory", true)
        })
    }.toString().also {
        require(IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_GRANTS_BYTES)
    }

    fun parse(requestJson: String, runId: String): IsolatedCapabilityBroker.Call {
        boundedDepth(requestJson)
        val value = JSONObject(requestJson)
        val action = IsolatedCapabilityBroker.Action.valueOf(exactString(value, "action"))
        val child = value.has("relativePath")
        val base = setOf("action", "callId", "grantId") +
            (if (child) setOf("relativePath") else emptySet())
        val fields = when (action) {
            IsolatedCapabilityBroker.Action.READ -> base
            IsolatedCapabilityBroker.Action.SEARCH -> base + setOf("query", "maxMatches")
            IsolatedCapabilityBroker.Action.EDIT -> base + setOf(
                "expectedRevision", "needle", "replacement", "maxReplacements",
            )
            IsolatedCapabilityBroker.Action.WRITE -> base + setOf("expectedRevision", "text")
        }
        require(value.keys().asSequence().toSet() == fields) { "Unexpected host request fields" }
        val callId = exactString(value, "callId")
        val grantId = exactString(value, "grantId")
        val relativePath = if (child) exactString(value, "relativePath") else null
        return when (action) {
            IsolatedCapabilityBroker.Action.READ -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.read(runId, callId, grantId)
            else IsolatedCapabilityBroker.Call.readChild(runId, callId, grantId, relativePath)
            IsolatedCapabilityBroker.Action.SEARCH -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.search(runId, callId, grantId,
                    exactString(value, "query"), exactInt(value, "maxMatches"))
            else IsolatedCapabilityBroker.Call.searchChild(runId, callId, grantId, relativePath,
                exactString(value, "query"), exactInt(value, "maxMatches"))
            IsolatedCapabilityBroker.Action.EDIT -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.edit(runId, callId, grantId,
                    exactString(value, "expectedRevision"), exactString(value, "needle"),
                    exactString(value, "replacement"), exactInt(value, "maxReplacements"))
            else IsolatedCapabilityBroker.Call.editChild(runId, callId, grantId, relativePath,
                exactString(value, "expectedRevision"), exactString(value, "needle"),
                exactString(value, "replacement"), exactInt(value, "maxReplacements"))
            IsolatedCapabilityBroker.Action.WRITE -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.write(runId, callId, grantId,
                    exactString(value, "expectedRevision"), exactString(value, "text"))
            else IsolatedCapabilityBroker.Call.writeChild(runId, callId, grantId, relativePath,
                exactString(value, "expectedRevision"), exactString(value, "text"))
        }
    }

    fun response(value: IsolatedCapabilityBroker.CallResult): String {
        val json = JSONObject().put("status", value.status().name)
        value.detail()?.let { json.put("detail", it) }
        value.read()?.let { json.put("read", JSONObject().put("revision", it.revision()).put("text", it.text())) }
        value.search()?.let { search ->
            json.put("search", JSONObject().put("revision", search.revision())
                .put("truncated", search.truncated()).put("hits", JSONArray().apply {
                    for (hit in search.hits()) put(JSONObject().put("line", hit.line())
                        .put("column", hit.column()).put("preview", hit.preview()))
                }))
        }
        value.edit()?.let { json.put("edit", JSONObject().put("previousRevision", it.previousRevision())
            .put("revision", it.revision()).put("bytes", it.bytes())) }
        return json.toString().also {
            require(IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_HOST_REPLY_BYTES)
        }
    }

    /** The broker has already audited the result and capped the body to 64 KiB. */
    fun networkResponse(value: IsolatedNetworkBroker.Result): String {
        val json = JSONObject().put("status", value.status().name)
            .put("httpStatus", value.statusCode())
            .put("redirects", value.redirects())
        value.auditId()?.let { json.put("auditId", it) }
        value.finalUrl()?.let { json.put("finalUrl", it) }
        value.contentType()?.let { json.put("contentType", it) }
        val body = value.body()
        require(body.size <= IsolatedWorkerInput.MAX_TEXT_BYTES)
        if (body.isNotEmpty()) {
            try { json.put("bodyText", IsolatedWorkerInput.readUtf8(ByteArrayInputStream(body))) }
            catch (_: IOException) { json.put("bodyBase64", Base64.getEncoder().encodeToString(body)) }
        }
        return json.toString().also {
            require(IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_HOST_REPLY_BYTES)
        }
    }

    private fun exactString(value: JSONObject, key: String): String =
        (value.get(key) as? String) ?: throw IllegalArgumentException("Expected text field: $key")

    private fun exactInt(value: JSONObject, key: String): Int =
        (value.get(key) as? Int) ?: throw IllegalArgumentException("Expected integer field: $key")

    private fun boundedDepth(json: String) {
        var depth = 0
        var quoted = false
        var escaped = false
        for (char in json) {
            if (quoted) {
                if (escaped) escaped = false
                else if (char == '\\') escaped = true
                else if (char == '"') quoted = false
            } else when (char) {
                '"' -> quoted = true
                '{', '[' -> { depth++; require(depth <= 32) { "Host JSON nesting exceeds limit" } }
                '}', ']' -> { depth--; require(depth >= 0) { "Invalid host JSON nesting" } }
            }
        }
        require(!quoted && depth == 0) { "Invalid host JSON nesting" }
    }
}
