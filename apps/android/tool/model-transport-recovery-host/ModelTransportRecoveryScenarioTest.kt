package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Execute the actual scenario's projection using the SDK JSON implementation, with no Android or network substitutes. */
fun main(args: Array<String>) {
    val root = File(args.single())
    val id = UUID.randomUUID().toString()
    val home = File(root, "native-runtime-acceptance/$id").apply { mkdirs() }
    val workspace = File(root, ".device-acceptance-$id").apply { mkdirs() }
    val scenario = ModelTransportRecoveryScenario(home, workspace, File(root, "runtime"), id)
    val secret = "DO_NOT_PRINT_REQUEST_OR_CREDENTIAL"
    fun field() = JSONObject().put("name", "dsh_session_log").put("nameSha256", "c".repeat(64))
        .put("type", "object").put("bytes", 1024).put("entries", 6).put("sha256", "d".repeat(64))
        .put("semanticSha256", "e".repeat(64)).put("value", secret)
    fun change() = JSONObject().put("name", "dsh_session_log").put("nameSha256", "c".repeat(64))
        .put("semanticChanged", true).put("before", field()).put("after", field()).put("raw", secret)
    fun proof() = JSONObject().put("schema", 1).put("caseId", id).put("sessionId", "android-acceptance-transport-$id")
        .put("modelCalls", 2).put("titleCalls", 1).put("disconnects", 1).put("unauthenticatedRequests", 3)
        .put("partialFlushed", true).put("verified", false).put("closed", false)
        .put("lastRequestStage", "retry-continuation").put("failureStage", "retry-continuation")
        .put("failureReason", "request-continuation").put("requestHashes", JSONArray().put("a".repeat(64)).put("b".repeat(64)))
        .put("connectionIds", JSONArray().put(1).put(3)).put("requestDifference", JSONObject()
            .put("rawBodyEqual", false).put("nonMessageFieldsEqual", true).put("existingBlocksEqual", false)
            .put("semanticNonMessageFieldsEqual", false).put("stableFieldsEqual", true)
            .put("changedFields", JSONArray().put(change()))
            .put("firstBlocks", 3).put("retryBlocks", 4).put("rawBody", secret))
        .put("failure", JSONObject().put("errorName", "AssertionError").put("errorCode", "ERR_ASSERTION")
            .put("message", secret).put("frames", JSONArray().put(secret)))
        .put("headers", secret).put("requestBody", secret).put("requestShapes", secret)
    var checks = 0
    fun checkCase(action: () -> Unit) { action(); checks++ }
    checkCase {
        val value = ModelTransportRecoveryScenario.modelDiagnostics(proof(), id)
        check(value.getInt("modelCalls") == 2 && value.getInt("disconnects") == 1)
        check(value.getString("failureReason") == "request-continuation")
        check(value.getString("failureStage") == "retry-continuation")
        check(!value.getJSONObject("requestDifference").getBoolean("existingBlocksEqual"))
        check(value.getJSONArray("requestHashes").length() == 2)
        check(value.getBoolean("failed") && value.getString("errorCode") == "ERR_ASSERTION")
        check(value.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).getString("name") == "dsh_session_log")
        check(!value.toString().contains(secret) && value.toString().length < 4096)
    }
    checkCase {
        val value = proof().put("failure", JSONObject().put("errorName", secret).put("errorCode", secret))
        val report = ModelTransportRecoveryScenario.modelDiagnostics(value, id)
        check(report.getString("errorName") == "Error" && report.isNull("errorCode"))
        check(!report.toString().contains(secret))
    }
    for (mutate in listOf<(JSONObject) -> Unit>(
        { it.put("caseId", UUID.randomUUID().toString()) },
        { it.put("modelCalls", "2") },
        { it.put("modelCalls", -1) },
        { it.put("disconnects", 1000001) },
        { it.put("partialFlushed", "true") },
        { it.put("failureReason", secret) },
        { it.put("failureStage", secret) },
        { it.put("requestHashes", JSONArray().put(secret)) },
        { it.put("connectionIds", JSONArray().put(0)) },
        { it.put("requestHashes", JSONArray().put("a".repeat(64)).put("b".repeat(64)).put("c".repeat(64))) },
        { it.getJSONObject("requestDifference").put("retryBlocks", 257) },
        { it.getJSONObject("requestDifference").put("stableFieldsEqual", "true") },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).put("name", secret) },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).put("semanticChanged", "true") },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).getJSONObject("after").put("bytes", 2097153) },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).getJSONObject("after").put("type", secret) },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).getJSONObject("after").put("sha256", secret) },
        { it.getJSONObject("requestDifference").getJSONArray("changedFields").getJSONObject(0).getJSONObject("after").put("nameSha256", "f".repeat(64)) },
        { it.getJSONObject("requestDifference").put("changedFields", JSONArray().apply { repeat(65) { put(change()) } }) },
    )) checkCase {
        val value = proof(); mutate(value)
        val failed = try { ModelTransportRecoveryScenario.modelDiagnostics(value, id); false } catch (_: Exception) { true }
        check(failed)
    }
    val file = File(home, "production-profile-proof.json")
    checkCase {
        file.writeText(proof().toString())
        val report = scenario.failureDiagnostics(IllegalStateException(secret))
        check(report.has("transportModel") && !report.has("model"))
        check(report.getJSONObject("transportModel").getInt("modelCalls") == 2)
        check(!report.toString().contains(secret))
    }
    checkCase {
        file.writeText(proof().put("failureStage", secret).toString())
        val report = scenario.diagnostics()
        check(report.getBoolean("transportModelDiagnosticInvalid") && !report.has("transportModel"))
        check(!report.toString().contains(secret))
    }
    checkCase {
        file.writeText("x".repeat(65537))
        check(scenario.diagnostics().getBoolean("transportModelDiagnosticInvalid"))
    }
    println("Transport scenario host checks passed: $checks")
}
