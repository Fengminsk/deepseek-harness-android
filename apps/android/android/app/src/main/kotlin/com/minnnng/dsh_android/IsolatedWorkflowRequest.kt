package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject

/** Exact guest-to-App frames for a workflow run; the Node port validates each operation further. */
internal data class IsolatedWorkflowRequest(val callId: Int, val action: String, val value: Any) {
    companion object {
        private val actions = setOf("WORKFLOW_BEGIN", "WORKFLOW_START_CHILD",
            "WORKFLOW_CHILD_RESULT", "WORKFLOW_DISPOSE_CHILD", "WORKFLOW_PROGRESS")
        private const val MAX_REPLY_BYTES = 64 * 1024

        fun parse(requestJson: String): IsolatedWorkflowRequest {
            require(IsolatedScriptWire.utf8Bytes(requestJson) <= PtcScriptEngine.MAX_HOST_REQUEST_BYTES)
            val frame = JSONObject(requestJson)
            require(frame.keys().asSequence().toSet() == setOf("action", "callId", "value"))
            val action = frame.get("action")
            val id = frame.get("callId")
            require(action is String && action in actions)
            require(id is Int && id in 1..PtcScriptEngine.MAX_HOST_CALLS)
            val value = frame.get("value")
            require(if (action == "WORKFLOW_PROGRESS") value is JSONArray else value is JSONObject)
            return IsolatedWorkflowRequest(id, action, value)
        }

        fun response(frame: JSONObject, runId: String, callId: Int): String {
            require(frame.keys().asSequence().toSet() == setOf("runId", "callId", "value"))
            require(frame.get("runId") == runId && frame.get("callId") == callId)
            return JSONObject().put("value", frame.get("value")).toString().also {
                require(IsolatedScriptWire.utf8Bytes(it) <= MAX_REPLY_BYTES &&
                    IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_HOST_REPLY_BYTES)
            }
        }
    }
}
