package com.minnnng.dsh_android

import org.json.JSONObject

/** Host execution of the real JSON parser; Binder sender identity is a device concern. */
object IsolatedToolRequestTest {
    @JvmStatic fun main(args: Array<String>) {
        fun request(name: String, callId: Int = 1) = JSONObject().put("action", "TOOL_CALL")
            .put("name", name).put("callId", callId).put("arguments", JSONObject()).toString()
        fun rejects(block: () -> Unit) { check(runCatching(block).isFailure) }
        for (name in listOf("linux_exec", "linux_import", "linux_export", "linux_inspect")) {
            val parsed = IsolatedToolRequest.parse(request(name), true)
            check(parsed.name == name && parsed.callId == 1)
            rejects { IsolatedToolRequest.parse(request(name), false) }
            rejects { IsolatedToolRequest.parse(request(name, 33), true) }
        }
        for (name in listOf("android_shell", "android_linux", "workflow", "android_ptc", "run_code", "linux_arbitrary")) {
            rejects { IsolatedToolRequest.parse(request(name), true) }
        }
        val extras = JSONObject(request("linux_exec")).put("approved", true)
        rejects { IsolatedToolRequest.parse(extras.toString(), true) }
        val malformed = JSONObject(request("linux_exec")).put("arguments", "a shell command")
        rejects { IsolatedToolRequest.parse(malformed.toString(), true) }
        val receipt = JSONObject().put("status", "completed").put("diskCommitted", true)
            .put("retirementConfirmed", true).put("cancelRequested", true)
        val reply = JSONObject(IsolatedToolRequest.response(JSONObject().put("runId", "owner")
            .put("callId", 1).put("value", receipt), "owner", 1)).getJSONObject("value")
        check(reply.getBoolean("diskCommitted") && reply.getBoolean("cancelRequested") && reply.getBoolean("retirementConfirmed"))
        rejects { IsolatedToolRequest.response(JSONObject().put("runId", "other").put("callId", 1).put("value", receipt), "owner", 1) }
        println("PASS: reviewed PTC admits four Linux tool names; ordinary guests, ambient names, malformed frames and mismatched replies are refused; receipt facts remain unchanged.")
    }
}
