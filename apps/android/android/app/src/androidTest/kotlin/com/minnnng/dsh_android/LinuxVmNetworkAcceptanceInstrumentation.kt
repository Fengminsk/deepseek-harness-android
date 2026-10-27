package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Real isolated Linux/Binder/HTTPS checks with a private test approval, never a user-policy replacement. */
class LinuxVmNetworkAcceptanceInstrumentation : Instrumentation() {
    private var mode = "wrong-host"
    private val activeRevoke = java.util.concurrent.atomic.AtomicReference<Runnable?>()
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        mode = arguments?.getString("mode") ?: "wrong-host"
        start()
    }

    override fun onStart() {
        val results = JSONArray()
        var failure: String? = null
        try {
            require(mode in setOf("wrong-host", "budget", "revoked", "live"))
            AcceptanceForegroundLease.open(this) { activeRevoke.get()?.run() }.use { foreground ->
                runCase(results, foreground)
            }
        } catch (error: Throwable) { failure = error.toString() }
        finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("mode", mode); putString("results", results.toString())
            putBoolean("passed", failure == null); putString("failure", failure)
            putString("approvalEvidence", "dedicated-test-scope-not-model-ui")
        })
    }

    private fun runCase(results: JSONArray, foreground: AcceptanceForegroundLease) {
        val context = targetContext
        check(android.app.Application.getProcessName() == context.packageName + ":agent")
        val run = UUID.randomUUID().toString()
        val session = "linux-network-acceptance-${UUID.randomUUID()}"
        val call = UUID.randomUUID().toString()
        val directory = File(context.filesDir, "linux-network-acceptance-${UUID.randomUUID()}")
        check(directory.mkdir())
        IsolatedScriptRunController.syncDirectory(requireNotNull(directory.parentFile).toPath())
        val store = IsolatedExecutionApprovalStore(File(context.applicationInfo.dataDir).toPath(),
            directory.toPath(), "linux-network-acceptance", session, IsolatedScriptRunController::syncDirectory)
        val policy = store.newOwner { admitted, scope ->
            val file = File(directory, "admission-$admitted.json")
            check(file.createNewFile())
            FileOutputStream(file).use { output ->
                output.write(JSONObject().put("id", admitted).put("sessionId", session)
                    .put("version", scope.version()).toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            IsolatedScriptRunController.syncDirectory(directory.toPath())
        }
        try {
            val calls = if (mode == "budget") 1 else 2
            val scope = IsolatedExecutionPolicyOwner.Scope.granted("linux-network-acceptance", session,
                policy.current().version() + 1, null, null, emptySet(), emptySet(), setOf("example.com"), 0, calls, 125_000)
            store.prepareTrustedUiApproval(scope, UUID.randomUUID().toString())
            policy.replace(scope)
            val lease = policy.admit(run)
            val revoke = Runnable { policy.revoke(run) }
            check(activeRevoke.compareAndSet(null, revoke))
            foreground.checkActive()
            val route = NetworkProxyPreferences(context).route()
            val command = if (mode == "live") {
                "set -eu\ndsh-fetch https://example.com/ > /tmp/response\ngrep -q 'Example Domain' /tmp/response\n" +
                    "sha256sum /tmp/response\nprintf 'DSH_GUEST_HTTPS_OK\\n'"
            } else {
                // A fixed UUID allows the test to observe only its own audit. The real client,
                // virtual block channel, Binder and App broker still perform the request.
                "python3 - <<'PY'\nimport runpy,uuid,os,json,time\n" +
                    "client=runpy.run_path('/tmp/dsh-fetch')\nuuid.uuid4=lambda:uuid.UUID('$call')\n" +
                    "result,body=client['fetch']('/dev/vdd','$run','https://not-approved.example/')\n" +
                    "assert result['status']==1 and body==b''\nprint('DSH_DENIAL_OK',flush=True)\n" +
                    when (mode) {
                        "budget" -> "client['fetch']('/dev/vdd','$run','https://example.com/')\nraise AssertionError('budget bypass')\n"
                        "revoked" -> "time.sleep(100)\nraise AssertionError('revocation did not stop guest')\n"
                        else -> ""
                    } + "PY"
            }
            val request = JSONObject().put("id", run).put("sessionId", session).put("command", command)
                .put("timeoutMs", 120_000).put("persistChanges", false)
            LinuxVmManager(context).use { manager ->
                val pending = CompletableFuture.supplyAsync { manager.executeApprovedNetwork(request, lease, route) }
                try {
                    if (mode == "revoked") {
                        val journal = AndroidNetworkJournal.open(context)
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
                        var observed = false
                        while (!pending.isDone && System.nanoTime() < deadline) {
                            val entry = journal.read(call)
                            if (entry?.state() == IsolatedNetworkJournal.State.TERMINAL) {
                                check(entry.status() == IsolatedNetworkBroker.Status.POLICY_DENIED)
                                observed = true; break
                            }
                            // Poll an actual audit commit; elapsed time never establishes readiness.
                            Thread.sleep(20)
                        }
                        check(observed) { "Dedicated network audit did not reach its terminal denial" }
                        policy.revoke(run)
                    }
                    val result = pending.get(145, TimeUnit.SECONDS)
                    results.put(JSONObject(result.toString()).put("case", mode).put("route", route))
                    check(result.getBoolean("retirementConfirmed") && !result.getBoolean("diskCommitted"))
                    check(result.getInt("guestUid") != Process.myUid())
                    if (mode in setOf("budget", "revoked")) {
                        check(result.getString("status") == "cancelled" && result.getBoolean("cancelled"))
                    } else {
                        check(result.getString("status") == "completed" && result.getInt("exitCode") == 0)
                        check(result.getString("output").contains(if (mode == "live") "DSH_GUEST_HTTPS_OK" else "DSH_DENIAL_OK"))
                    }
                    if (mode != "live") {
                        val entry = AndroidNetworkJournal.open(context).read(call)
                        check(entry?.state() == IsolatedNetworkJournal.State.TERMINAL
                            && entry.status() == IsolatedNetworkBroker.Status.POLICY_DENIED)
                        results.put(JSONObject().put("networkCallId", call).put("auditTerminal", true))
                    }
                } finally {
                    policy.revoke(run)
                    if (!pending.isDone) manager.cancel(JSONObject().put("id", run))
                    pending.get(10, TimeUnit.SECONDS)
                }
            }
        } finally {
            activeRevoke.set(null)
            try { policy.close() } finally { store.close() }
        }
    }
}
