package com.minnnng.dsh_android

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.util.function.BooleanSupplier

/** App-owned Node RPC for fixed isolated commands; no model tool is registered here. */
internal class LinuxCommandManager(private val context: Context) : AutoCloseable {
    private val admission = LinuxCommandAdmission()

    fun execute(params: JSONObject): JSONObject {
        val allowed = setOf("id", "command", "argument", "stdinBase64")
        val keys = params.keys().asSequence().toSet()
        require(keys.all { it in allowed } && keys.containsAll(listOf("id", "command"))) {
            "Invalid Linux command request fields"
        }
        require(params.opt("id") is String && params.opt("command") is String) {
            "Linux command ID and name must be strings"
        }
        val id = params.getString("id")
        val command = IsolatedLinuxCommandPolicy.fromWire(params.getString("command"))
            ?: throw IllegalArgumentException("Unknown Linux command")
        require(!command.isTestOnly()) { "Test Linux commands are unavailable over Node RPC" }
        val argument = if (params.has("argument")) {
            require(params.opt("argument") is String) { "Linux command argument must be a string" }
            params.getString("argument")
        } else ""
        val encoded = if (params.has("stdinBase64")) {
            require(params.opt("stdinBase64") is String) { "Linux command input must be base64 text" }
            params.getString("stdinBase64")
        } else ""
        require(encoded.length <= ((IsolatedLinuxCommandPolicy.MAX_STDIN_BYTES + 2) / 3) * 4) {
            "Linux command input exceeds limit"
        }
        val input = try { Base64.decode(encoded, Base64.NO_WRAP) }
            catch (_: IllegalArgumentException) { throw IllegalArgumentException("Invalid Linux command input") }
        require(Base64.encodeToString(input, Base64.NO_WRAP) == encoded) {
            "Noncanonical Linux command input"
        }
        val request = IsolatedLinuxCommandPolicy.Request.of(command, argument, input)
        val ticket = admission.admit(id)
        var retired = false
        return try {
            val result = IsolatedLinuxCommandRunner.run(context, request,
                BooleanSupplier { ticket.isCancelled() })
            retired = result.retirementConfirmed
            JSONObject().put("id", id).put("command", command.wireName)
                .put("kind", result.kind.name).put("output", result.output)
                .put("exitCode", result.exitCode)
                .put("retirementConfirmed", result.retirementConfirmed)
                .put("guestUid", result.guestUid ?: JSONObject.NULL)
                .put("detail", result.detail ?: JSONObject.NULL)
        } finally { ticket.close(retired) }
    }

    fun cancel(params: JSONObject): JSONObject {
        require(params.length() == 1 && params.opt("id") is String) {
            "Invalid Linux command cancellation"
        }
        val outcome = admission.cancelAndWait(params.getString("id"), 4_500)
        return JSONObject().put("cancelRequested", outcome.requested())
            .put("settled", outcome.settled())
    }

    override fun close() { admission.close() }
}
