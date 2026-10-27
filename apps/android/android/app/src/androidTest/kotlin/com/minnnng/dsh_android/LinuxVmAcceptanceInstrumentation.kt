package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Executes the packaged Linux kernel through the production native owner; it has no launcher Activity. */
class LinuxVmAcceptanceInstrumentation : Instrumentation() {
    private var selected = "boot"
    private var retainedSession: String? = null
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        selected = arguments?.getString("suite") ?: "boot"
        retainedSession = arguments?.getString("sessionId")
        start()
    }

    override fun onStart() {
        val results = JSONArray()
        var failure: String? = null
        try {
            if (selected == "publisher") {
                LinuxVmFilePublisherAcceptance.run(targetContext, results)
                finish(Activity.RESULT_OK, Bundle().apply {
                    putString("suite", selected); putString("results", results.toString())
                })
                return
            }
            if (selected == "build-alpine") {
                LinuxVmImageBuildAcceptance.run(targetContext, context, results)
                finish(Activity.RESULT_OK, Bundle().apply {
                    putString("suite", selected); putString("results", results.toString())
                })
                return
            }
            val session = if (selected == "verify-workspace") {
                requireNotNull(retainedSession).also {
                    require(it.startsWith("linux-acceptance-")
                        && UUID.fromString(it.removePrefix("linux-acceptance-")).toString() == it.removePrefix("linux-acceptance-"))
                }
            } else "linux-acceptance-${UUID.randomUUID()}"
            LinuxVmManager(targetContext).use { owner ->
                fun run(command: String, timeout: Long = 120_000): JSONObject {
                    val begin = System.nanoTime()
                    val result = owner.execute(JSONObject().put("id", UUID.randomUUID().toString())
                        .put("sessionId", session).put("command", command).put("timeoutMs", timeout).put("persistChanges", true))
                    results.put(JSONObject(result.toString()).put("elapsedMs", (System.nanoTime() - begin) / 1_000_000))
                    return result
                }
                fun completed(value: JSONObject) {
                    check(value.getString("status") == "completed") { value.toString() }
                    check(value.getBoolean("retirementConfirmed") && value.getBoolean("diskCommitted"))
                    check(value.getInt("guestUid") != android.os.Process.myUid())
                }
                if (selected == "verify-workspace") {
                    val retained = run("cat /workspace/probe.txt; printf '\\n'; sha256sum /workspace/probe.txt")
                    completed(retained)
                    check(retained.getInt("exitCode") == 0 && retained.getString("output").startsWith("persistent\n"))
                    val manifest = JSONObject(targetContext.assets.open("linux-vm/manifest.json").bufferedReader().use { it.readText() })
                    results.put(JSONObject().put("baseImage", manifest.getJSONObject("disk").getString("sha256")))
                    return@use
                }
                val boot = run("uname -srm; printf 'dsh-linux-works\\n'; printf persistent > /workspace/probe.txt; id; pwd")
                completed(boot)
                check(boot.getString("output").contains("Linux") && boot.getString("output").contains("riscv64"))
                check(boot.getString("output").contains("dsh-linux-works") && boot.getInt("exitCode") == 0)
                if (selected == "full") {
                    val persistence = run("cat /workspace/probe.txt; printf '\\n'; exit 7")
                    completed(persistence)
                    check(persistence.getString("output").contains("persistent") && persistence.getInt("exitCode") == 7)
                    val timeout = run("while :; do :; done", 10_000)
                    check(timeout.getString("status") == "timed_out" && timeout.getBoolean("timedOut"))
                    check(timeout.getBoolean("retirementConfirmed") && !timeout.getBoolean("diskCommitted"))
                    val id = UUID.randomUUID().toString()
                    val pending = CompletableFuture.supplyAsync {
                        owner.execute(JSONObject().put("id", id).put("sessionId", session)
                            .put("command", "sleep 100").put("timeoutMs", 120_000).put("persistChanges", true))
                    }
                    // Cancellation-before-dispatch is a supported real race;
                    // the timeout test above separately exercises a live VM.
                    val cancel = owner.cancel(JSONObject().put("id", id))
                    check(cancel.getBoolean("settled"))
                    try {
                        val result = pending.get(15, TimeUnit.SECONDS)
                        results.put(result)
                        check(result.getString("status") == "cancelled" && !result.getBoolean("diskCommitted"))
                    } catch (failure: java.util.concurrent.ExecutionException) {
                        check(failure.cause is IllegalStateException && failure.cause?.message?.contains("cancelled before admission") == true)
                    }
                }
            }
        } catch (error: Throwable) { failure = "${error.javaClass.simpleName}: ${error.message}" }
        finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("suite", selected); putString("results", results.toString()); putString("failure", failure)
        })
    }
}
