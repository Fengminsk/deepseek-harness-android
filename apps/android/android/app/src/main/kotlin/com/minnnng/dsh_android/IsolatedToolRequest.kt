package com.minnnng.dsh_android

import org.json.JSONObject

/** Exact guest and Node JSON frames for one tool-only isolated run. */
internal data class IsolatedToolRequest(
    val callId: Int,
    val name: String,
    val arguments: JSONObject,
) {
    companion object {
        const val MAX_CALLS = 32
        private const val MAX_RESULT_BYTES = 64 * 1024
        private const val MAX_ERROR_BYTES = 4 * 1024
        private val toolName = Regex("[A-Za-z][A-Za-z0-9_./:-]{0,127}")
        private val guestErrors = setOf("ANDROID_TOOL_NOT_GRANTED",
            "ANDROID_TOOL_DISPATCH_FAILED", "ANDROID_TOOL_RESULT_UNSUPPORTED")

        fun parse(requestJson: String, reviewedPtc: Boolean = false): IsolatedToolRequest {
            require(IsolatedScriptWire.utf8Bytes(requestJson) <= PtcScriptEngine.MAX_HOST_REQUEST_BYTES)
            val value = JSONObject(requestJson)
            require(value.keys().asSequence().toSet() == setOf("action", "callId", "name", "arguments"))
            require(value.get("action") == "TOOL_CALL")
            val id = value.get("callId")
            require(id is Int && id in 1..MAX_CALLS)
            val name = value.get("name")
            require(name is String && toolName.matches(name))
            val arguments = value.get("arguments")
            require(arguments is JSONObject)
            if (reviewedPtc) {
                require(name in setOf("list_agents", "read", "glob", "grep", "web_search",
                    "web_fetch", "android_files", "android_attachments", "write", "edit"))
                if (name == "android_files") require(arguments.opt("action") in
                    setOf("roots", "list", "read", "search"))
                if (name == "android_attachments") require(arguments.opt("action") in
                    setOf("list", "read", "materialize", "inspect_archive", "inspect_apk"))
            } else require(name !in setOf("run_code", "android_shell", "android_linux", "android_files",
                "android_attachments", "read", "read_image", "write", "edit", "str_replace_editor", "workflow", "android_ptc"))
            return IsolatedToolRequest(id, name, arguments)
        }

        fun response(value: JSONObject, runId: String, callId: Int): String {
            val fields = value.keys().asSequence().toSet()
            require(fields == setOf("runId", "callId", "value") ||
                fields == setOf("runId", "callId", "error"))
            require(value.get("runId") == runId && value.get("callId") == callId)
            val reply = if (fields.contains("error")) {
                val error = value.getJSONObject("error")
                require(error.keys().asSequence().toSet() == setOf("code", "message"))
                val code = error.get("code")
                val message = error.get("message")
                require(code is String && code in guestErrors)
                require(message is String && message.isNotEmpty() &&
                    IsolatedScriptWire.utf8Bytes(message) <= MAX_ERROR_BYTES)
                JSONObject().put("error", error)
            } else JSONObject().put("value", value.get("value"))
            return reply.toString().also {
                require(IsolatedScriptWire.utf8Bytes(it) <= MAX_RESULT_BYTES &&
                    IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_HOST_REPLY_BYTES)
            }
        }
    }
}
