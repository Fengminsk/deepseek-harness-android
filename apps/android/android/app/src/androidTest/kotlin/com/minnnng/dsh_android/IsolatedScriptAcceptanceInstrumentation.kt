package com.minnnng.dsh_android

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.function.BooleanSupplier

/** Explicit device acceptance for the internal guest, never an App launch or model tool. */
class IsolatedScriptAcceptanceInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        this.arguments = arguments ?: Bundle.EMPTY
        start()
    }

    override fun onStart() {
        val result = Bundle()
        val failures = mutableListOf<String>()
        val passed = mutableListOf<String>()
        val app = targetContext.applicationContext
        try {
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) { "Android 10+ required" }
            check(Application.getProcessName() == app.packageName + ":agent") {
                "Instrumentation did not start in the Agent process"
            }
            check(Looper.myLooper() != Looper.getMainLooper()) { "Tests must not run on the App main thread" }
            when (arguments.getString("phase", "normal")) {
                "normal" -> {
                    test("pure-result-and-receipt", passed, failures) { pureResultAndReceipt(app) }
                    test("native-bridge-admit-execute-settle-release", passed, failures) { nativeBridgeRun(app) }
                    test("native-bridge-tool-only-binder-roundtrip", passed, failures) { nativeBridgeToolRun(app) }
                    test("native-bridge-bound-tool-pre-execution-cancel", passed, failures) { nativeBridgeToolCancel(app) }
                    test("native-bridge-bound-tool-close-uncertain", passed, failures) { nativeBridgeToolCloseUncertain(app) }
                    test("native-bridge-tool-frame-rejection", passed, failures) { nativeBridgeToolFrames() }
                    test("native-bridge-pre-execution-cancel", passed, failures) { nativeBridgeCancel(app) }
                    test("native-bridge-cancel-receipt-failure", passed, failures) { nativeBridgeCancelFailure(app) }
                    test("native-bridge-approved-exact-file", passed, failures) { nativeBridgeApprovedFile(app) }
                    test("native-bridge-rejected-approved-plan-is-terminal", passed, failures) {
                        nativeBridgeRejectedApprovedPlan(app)
                    }
                    test("native-bridge-directory-grant-rejected", passed, failures) {
                        nativeBridgeDirectoryGrantRejected(app)
                    }
                    test("native-bridge-discard-approved-plan", passed, failures) { nativeBridgeDiscardPlan(app) }
                    test("native-bridge-approval-denied-race", passed, failures) { nativeBridgeApprovalRace(app) }
                    test("concurrent-pure-scripts", passed, failures) { concurrentPureScripts(app) }
                    test("no-ambient-js-apis", passed, failures) { noAmbientJsApis(app) }
                    test("infinite-loop-deadline", passed, failures) { infiniteLoopDeadline(app) }
                    test("cancellation", passed, failures) { cancellation(app) }
                    test("main-thread-stall", passed, failures) { mainThreadStall(app) }
                    test("malformed-guest-binder-death", passed, failures) { malformedGuestDeath(app) }
                    test("app-issued-file-grant", passed, failures) { appIssuedFileGrant(app) }
                    test("async-host-promise-queue", passed, failures) { asyncHostPromiseQueue(app) }
                    test("revoked-file-policy", passed, failures) { revokedFilePolicy(app) }
                    test("approval-history-restart-denied", passed, failures) { approvalHistoryRestartDenied(app) }
                    test("max-size-escaped-file-read", passed, failures) { maxSizeEscapedFileRead(app) }
                    test("malformed-file-call-fails", passed, failures) { malformedFileCallFails(app) }
                    test("network-only-policy-and-audit", passed, failures) { networkOnlyPolicyAndAudit(app) }
                    test("private-network-route-denied", passed, failures) { privateNetworkRouteDenied(app) }
                    test("network-revoked-during-dns", passed, failures) { networkRevokedDuringDns(app) }
                }
                "ptc-callback" -> {
                    test("ptc-binder-read-only-callback-isolated-uid", passed, failures) {
                        ptcBinderReadOnlyCallback(app)
                    }
                    test("ptc-binder-cancel-replay-denied", passed, failures) {
                        ptcBinderCancelReplay(app)
                    }
                    test("ptc-binder-invalid-reply-no-success-receipt", passed, failures) {
                        ptcBinderInvalidReply(app)
                    }
                }
                "ptc-readonly-budget" -> {
                    test("ptc-admission-and-tool-action-limits", passed, failures) { ptcAdmissionLimits(app) }
                    test("ptc-callback-wait-exceeds-script-budget", passed, failures) { ptcWaitBudget(app) }
                    test("ptc-busy-loop-cpu-budget", passed, failures) { ptcCpuBudget(app) }
                }
                "kill-agent" -> admitAndKillAgent(app)
                "kill-running-agent" -> killAgentAfterGuestCall(app)
                "recover" -> test("process-death-recovery", passed, failures) { recoverAfterAgentDeath(app) }
                "shell-probe" -> test("isolated-shell-child-uid-private-path-and-network", passed, failures) {
                    val probe = IsolatedShellProbe.inspect(app, BooleanSupplier { false })
                    check(probe.verified) { "${probe.kind}: ${probe.detail ?: "no detail"}" }
                }
                "linux-command" -> {
                    for (command in IsolatedLinuxCommandPolicy.Command.values()) {
                        test("isolated-linux-${command.wireName}", passed, failures) {
                            val run = IsolatedLinuxCommandRunner.run(app, command, BooleanSupplier { false })
                            check(run.completed && run.exitCode == 0 && run.output.isNotBlank() && run.guestUid != null) {
                                "${run.kind}: ${run.detail ?: "no detail"}"
                            }
                        }
                    }
                    test("isolated-linux-cancellation", passed, failures) {
                        val run = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.KERNEL, BooleanSupplier { true })
                        check(run.kind == GuestTerminal.Kind.CANCELLED) { "${run.kind}: ${run.detail ?: "no detail"}" }
                    }
                }
                else -> error("Unknown acceptance phase")
            }
        } catch (failure: Throwable) {
            failures += "setup: ${failure.javaClass.simpleName}: ${failure.message}"
        }
        result.putString("passed", passed.joinToString(","))
        result.putString("failed", failures.joinToString(" | "))
        result.putInt("passedCount", passed.size)
        result.putInt("failedCount", failures.size)
        finish(if (failures.isEmpty()) Activity.RESULT_OK else Activity.RESULT_CANCELED, result)
    }

    private fun test(name: String, passed: MutableList<String>, failures: MutableList<String>, body: () -> Unit) {
        try {
            body()
            passed += name
        } catch (failure: Throwable) {
            failures += "$name: ${failure.javaClass.simpleName}: ${failure.message}"
        }
    }

    private fun run(
        app: Context, program: String, input: String = "null", deadlineMillis: Int = 1000,
        cancelled: BooleanSupplier = BooleanSupplier { false }, runId: String = UUID.randomUUID().toString(),
        hostPolicy: IsolatedScriptHostBridge.Policy? = null,
        networkPolicy: IsolatedScriptHostBridge.NetworkPolicy? = null,
        policyOwner: IsolatedExecutionPolicyOwner? = null,
    ): IsolatedScriptRunController.Result {
        val temporary = if (policyOwner == null) hostPolicy?.let { filePolicyOwner(app, it, runId) }
            ?: networkPolicy?.let { networkPolicyOwner(app, it, runId) } else null
        try {
            return IsolatedScriptRunController.run(app, runId, program, input, deadlineMillis, cancelled,
                hostPolicy, policyOwner ?: temporary?.owner, networkPolicy)
        } finally { temporary?.close() }
    }

    private fun networkPolicyOwner(
        app: Context, policy: IsolatedScriptHostBridge.NetworkPolicy, runId: String,
    ): IsolatedScriptRunController.ApprovalHandle {
        val ownerId = UUID.randomUUID().toString()
        val directory = File(app.filesDir, "network-policy-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val handle = IsolatedScriptRunController.newPolicyOwner(
            app, directory, ownerId, UUID.randomUUID().toString())
        try {
            val owner = handle.owner
            handle.approveTrustedUiChoiceForRun(IsolatedExecutionPolicyOwner.Scope.granted(
                ownerId, owner.current().sessionId(), owner.current().version() + 1, null, null,
                emptySet(), emptySet(), policy.hosts.exactHosts(), 0, 4, 8_000,
            ), UUID.randomUUID().toString(), runId)
            return handle
        } catch (failure: Throwable) {
            handle.close()
            throw failure
        }
    }

    private fun filePolicyOwner(
        app: Context, policy: IsolatedScriptHostBridge.Policy, runId: String,
    ): IsolatedScriptRunController.ApprovalHandle {
        val directory = File(policy.workspaceRoot.parentFile, "approval-${UUID.randomUUID()}")
            .apply { check(mkdirs()) }
        val handle = IsolatedScriptRunController.newPolicyOwner(
            app, directory, policy.ownerId, UUID.randomUUID().toString())
        try {
            val owner = handle.owner
            handle.approveTrustedUiChoiceForRun(IsolatedExecutionPolicyOwner.Scope.granted(
                policy.ownerId, owner.current().sessionId(), owner.current().version() + 1,
                File(app.applicationInfo.dataDir).toPath(), policy.workspaceRoot.toPath(),
                policy.sandbox.readablePaths(), policy.sandbox.writablePaths(),
                emptySet(), IsolatedCapabilityBroker.MAX_CALLS, 0, 8_000,
            ), UUID.randomUUID().toString(), runId)
            return handle
        } catch (failure: Throwable) {
            handle.close()
            throw failure
        }
    }

    private fun filePolicy(app: Context, root: File): IsolatedScriptHostBridge.Policy {
        val workspace = File(root, "workspace").apply { check(mkdirs()) }
        File(workspace, "note.txt").writeText("approved-file")
        val audit = File(root, "audit").apply { check(mkdirs()) }
        val journal = IsolatedCapabilityJournal(audit.toPath()) { directory ->
            val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0)
            try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
        }
        return IsolatedScriptHostBridge.Policy(
            workspace, UUID.randomUUID().toString(), journal,
            listOf(IsolatedCapabilityBroker.GrantSpec("note.txt", setOf(IsolatedCapabilityBroker.Action.READ))),
            IsolatedCapabilityBroker.SandboxPolicy.readOnly(setOf("note.txt")),
        )
    }

    private fun appIssuedFileGrant(app: Context) {
        val root = File(app.filesDir, "script-host-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val input = JSONObject().put("callId", UUID.randomUUID().toString()).toString()
        val program = "(input, host) => { const request={action:'READ',callId:input.callId,grantId:host.grants[0].id}; return {first:host.call(request),repeat:host.call(request)} }"
        val result = run(app, program, input, 3000, hostPolicy = policy)
        check(result.state == IsolatedScriptReceipt.State.COMPLETED) { "State: ${result.state}; ${result.detail}" }
        val complete = JSONObject(result.outputJson!!)
        val answer = complete.getJSONObject("first")
        check(answer.getString("status") == "OK")
        check(complete.getJSONObject("repeat").getString("status") == "DENIED")
        check(answer.getJSONObject("read").getString("text") == "approved-file")
        check(result.guestUid != null && result.guestUid != Process.myUid())
        check(policy.journal.inspect().runs().isEmpty()) { "Capability audit has an unfinished run" }
        try {
            run(app, program, input, 3000, runId = result.runId, hostPolicy = policy)
            error("A completed file-policy run ID was admitted twice")
        } catch (_: IOException) {
            check(receipts(app).read(result.runId).state() == IsolatedScriptReceipt.State.COMPLETED)
        }
        val denied = run(app,
            "(input, host) => host.call({action:'EDIT',callId:input.callId,grantId:host.grants[0].id,expectedRevision:input.revision,needle:'approved',replacement:'changed',maxReplacements:1})",
            JSONObject().put("callId", UUID.randomUUID().toString())
                .put("revision", answer.getJSONObject("read").getString("revision")).toString(),
            3000, hostPolicy = policy)
        check(denied.state == IsolatedScriptReceipt.State.COMPLETED) { "Denied call did not settle" }
        check(JSONObject(denied.outputJson!!).getString("status") == "DENIED")
        check(File(root, "workspace/note.txt").readText() == "approved-file")
    }

    private fun asyncHostPromiseQueue(app: Context) {
        val root = File(app.filesDir, "script-async-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val firstId = UUID.randomUUID().toString()
        val secondId = UUID.randomUUID().toString()
        val input = JSONObject().put("first", firstId).put("second", secondId).toString()
        val result = run(app,
            "async (input, host) => { const grantId=host.grants[0].id; const [first,second]=await Promise.all([host.callAsync({action:'READ',callId:input.first,grantId}),host.callAsync({action:'READ',callId:input.second,grantId})]); return {first,second} }",
            input, 4000, hostPolicy = policy)
        check(result.state == IsolatedScriptReceipt.State.COMPLETED) {
            "Async state: ${result.state}; ${result.detail}"
        }
        val answers = JSONObject(result.outputJson!!)
        check(answers.getJSONObject("first").getString("status") == "OK")
        check(answers.getJSONObject("second").getString("status") == "OK")
        check(answers.getJSONObject("first").getJSONObject("read").getString("text") == "approved-file")
        check(policy.journal.inspect().runs().isEmpty()) { "Async capability audit has an unfinished run" }

        val orphan = run(app,
            "(input, host) => { host.callAsync({action:'READ',callId:input.first,grantId:host.grants[0].id}); return {done:true} }",
            input, 3000, hostPolicy = policy)
        check(orphan.state != IsolatedScriptReceipt.State.COMPLETED) {
            "Fire-and-forget host request was accepted as a successful run"
        }
    }

    private fun revokedFilePolicy(app: Context) {
        val root = File(app.filesDir, "script-host-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val runId = UUID.randomUUID().toString()
        val approval = filePolicyOwner(app, policy, runId)
        val owner = approval.owner
        try {
        val outcome = ArrayBlockingQueue<IsolatedScriptRunController.Result>(1)
        val failed = ArrayBlockingQueue<Throwable>(1)
        val runner = Thread {
            try { outcome.offer(run(app, "() => { while (true) {} }", deadlineMillis = 5000,
                runId = runId, hostPolicy = policy, policyOwner = owner)) }
            catch (error: Throwable) { failed.offer(error) }
        }
        runner.start()
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        var admitted = false
        while (System.nanoTime() < end) {
            try {
                if (receipts(app).read(runId).state() == IsolatedScriptReceipt.State.ADMITTED) {
                    admitted = true
                    break
                }
            } catch (_: IOException) { /* Durable admission is still in progress. */ }
            Thread.sleep(10)
        }
        check(admitted) { "Policy run was never durably admitted" }
        owner.revoke(runId)
        runner.join(6_000)
        check(!runner.isAlive) { "Revoked script did not retire" }
        val result = outcome.poll()
        val terminal = receipts(app).read(runId).state()
        check(terminal != IsolatedScriptReceipt.State.COMPLETED && terminal != IsolatedScriptReceipt.State.ADMITTED)
        if (result == null) {
            // Revocation can beat host admission; the guest is then never bound.
            check(failed.poll() != null && terminal == IsolatedScriptReceipt.State.ERROR)
        } else {
            check(failed.isEmpty() && result.outputJson == null && result.state == terminal)
        }
        } finally { approval.close() }
    }

    private fun approvalHistoryRestartDenied(app: Context) {
        val root = File(app.filesDir, "approval-restart-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val directory = File(root, "approval").apply { check(mkdirs()) }
        val sessionId = UUID.randomUUID().toString()
        val first = IsolatedScriptRunController.newPolicyOwner(app, directory, policy.ownerId, sessionId)
        val grantVersion: Long
        try {
            check(first.owner.current().readablePaths().isEmpty())
            val scope = IsolatedExecutionPolicyOwner.Scope.granted(
                policy.ownerId, sessionId, first.owner.current().version() + 1,
                File(app.applicationInfo.dataDir).toPath(), policy.workspaceRoot.toPath(),
                policy.sandbox.readablePaths(), policy.sandbox.writablePaths(),
                emptySet(), IsolatedCapabilityBroker.MAX_CALLS, 0, 8_000,
            )
            val approvedRunId = UUID.randomUUID().toString()
            first.approveTrustedUiChoiceForRun(scope, UUID.randomUUID().toString(),
                approvedRunId)
            grantVersion = first.owner.current().version()
            check(first.owner.current().readablePaths().isNotEmpty())
            try {
                run(app, "() => 1", runId = UUID.randomUUID().toString(),
                    hostPolicy = policy, policyOwner = first.owner)
                error("An approval for one run authorized another run")
            } catch (expected: IllegalStateException) {
                check(expected.message?.contains("different run") == true)
            }
        } finally { first.close() }
        val reopened = IsolatedScriptRunController.newPolicyOwner(app, directory, policy.ownerId, sessionId)
        try {
            val recovered = reopened.owner.current()
            check(recovered.version() > grantVersion)
            check(recovered.readablePaths().isEmpty() && recovered.writablePaths().isEmpty())
            check(recovered.exactHosts().isEmpty())
            val runId = UUID.randomUUID().toString()
            try {
                run(app, "() => 1", runId = runId, hostPolicy = policy,
                    policyOwner = reopened.owner)
                error("Recovered denied owner admitted a host run")
            } catch (_: IllegalStateException) {
                check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.ERROR) {
                    "Denied host run did not settle its admission"
                }
            }
        } finally { reopened.close() }
        val forged = IsolatedExecutionPolicyOwner(policy.ownerId, sessionId,
            { _, _ -> error("Forged admission was called") },
            { _, _ -> error("Forged transition was called") })
        val forgedRunId = UUID.randomUUID().toString()
        try {
            run(app, "() => 1", runId = forgedRunId, hostPolicy = policy, policyOwner = forged)
            error("Unregistered owner was accepted")
        } catch (_: IllegalStateException) {
            try { receipts(app).read(forgedRunId); error("Forged owner admitted a receipt") }
            catch (_: IOException) { /* Controller rejected it before admission. */ }
        }
    }

    private fun malformedFileCallFails(app: Context) {
        val root = File(app.filesDir, "script-host-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val result = run(app,
            "(input, host) => host.call({action:'READ',callId:input.callId,grantId:host.grants[0].id,path:'/etc/passwd'})",
            JSONObject().put("callId", UUID.randomUUID().toString()).toString(),
            3000, hostPolicy = policy)
        check(result.state != IsolatedScriptReceipt.State.COMPLETED)
        check(result.outputJson == null)
        check(File(root, "workspace/note.txt").readText() == "approved-file")
    }

    /** A valid 64 KiB read can exceed 128 KiB after JSON escaping. */
    private fun maxSizeEscapedFileRead(app: Context) {
        val root = File(app.filesDir, "script-host-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        File(root, "workspace/note.txt").writeText("\u0000".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES))
        val program = "(input, host) => { const result=host.call({action:'READ',callId:input.callId,grantId:host.grants[0].id}); return {status:result.status,length:result.read.text.length} }"
        val result = run(app, program,
            JSONObject().put("callId", UUID.randomUUID().toString()).toString(),
            5000, hostPolicy = policy)
        check(result.state == IsolatedScriptReceipt.State.COMPLETED) { "State: ${result.state}; ${result.detail}" }
        val answer = JSONObject(result.outputJson!!)
        check(answer.getString("status") == "OK")
        check(answer.getInt("length") == IsolatedWorkerInput.MAX_TEXT_BYTES)
        check(policy.journal.inspect().runs().isEmpty())
    }

    /** Synthetic transport tests Binder policy and audit without consuming real network access. */
    private fun networkOnlyPolicyAndAudit(app: Context) {
        val dnsCalls = AtomicInteger()
        val transportCalls = AtomicInteger()
        val network = IsolatedScriptHostBridge.NetworkPolicy(
            IsolatedNetworkBroker.Policy(setOf("api.example.org")),
            AndroidNetworkJournal.open(app),
            IsolatedNetworkBroker.DeadlineResolver { host, _, _ ->
                check(host == "api.example.org")
                dnsCalls.incrementAndGet()
                IsolatedNetworkBroker.Resolution(
                    arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))),
                    IsolatedNetworkBroker.RouteSocketFactory { error("Synthetic transport opened a socket") },
                )
            },
            IsolatedNetworkBroker.PinnedTransport { uri, address, _, _, _ ->
                check(uri.host == "api.example.org" && address.hostAddress == "8.8.8.8")
                transportCalls.incrementAndGet()
                IsolatedNetworkBroker.Hop(200, null, "text/plain",
                    "hello-network".toByteArray(StandardCharsets.UTF_8))
            },
        )
        val callId = UUID.randomUUID().toString()
        val program = "(input,host)=>host.call({action:'HTTPS_GET',callId:input.callId,url:input.url})"
        val allowed = run(app, program,
            JSONObject().put("callId", callId).put("url", "https://api.example.org/data").toString(),
            3000, networkPolicy = network)
        check(allowed.state == IsolatedScriptReceipt.State.COMPLETED) {
            "Network-only run: ${allowed.state}; ${allowed.detail}"
        }
        val value = JSONObject(allowed.outputJson!!)
        check(value.getString("status") == "OK" && value.getString("bodyText") == "hello-network")
        check(value.getString("auditId") == callId && dnsCalls.get() == 1 && transportCalls.get() == 1)
        check(network.journal.read(callId).state() == IsolatedNetworkJournal.State.TERMINAL)
        val denied = run(app, program,
            JSONObject().put("callId", UUID.randomUUID().toString())
                .put("url", "https://other.example.org/data").toString(),
            3000, networkPolicy = network)
        check(denied.state == IsolatedScriptReceipt.State.COMPLETED)
        check(JSONObject(denied.outputJson!!).getString("status") == "POLICY_DENIED")
        check(dnsCalls.get() == 1 && transportCalls.get() == 1)
        val malformed = run(app,
            "(input,host)=>host.call({action:'HTTPS_GET',callId:input.callId,url:input.url,headers:{Cookie:'x'}})",
            JSONObject().put("callId", UUID.randomUUID().toString())
                .put("url", "https://api.example.org/data").toString(),
            3000, networkPolicy = network)
        check(malformed.state != IsolatedScriptReceipt.State.COMPLETED && malformed.outputJson == null)
        check(dnsCalls.get() == 1 && transportCalls.get() == 1)
    }

    /** The App broker must reject private DNS answers before any transport starts. */
    private fun privateNetworkRouteDenied(app: Context) {
        val dnsCalls = AtomicInteger()
        val transportCalls = AtomicInteger()
        val network = IsolatedScriptHostBridge.NetworkPolicy(
            IsolatedNetworkBroker.Policy(setOf("api.example.org")),
            AndroidNetworkJournal.open(app),
            IsolatedNetworkBroker.DeadlineResolver { _, _, _ ->
                dnsCalls.incrementAndGet()
                IsolatedNetworkBroker.Resolution(
                    arrayOf(InetAddress.getByAddress(byteArrayOf(10, 0, 0, 7))),
                    IsolatedNetworkBroker.RouteSocketFactory { error("Private route opened a socket") },
                )
            },
            IsolatedNetworkBroker.PinnedTransport { _, _, _, _, _ ->
                transportCalls.incrementAndGet()
                error("Private route reached transport")
            },
        )
        val program = "(input,host)=>host.call({action:'HTTPS_GET',callId:input.callId,url:input.url})"
        val privateCallId = UUID.randomUUID().toString()
        val denied = run(app, program,
            JSONObject().put("callId", privateCallId)
                .put("url", "https://api.example.org/private").toString(),
            3000, networkPolicy = network)
        check(denied.state == IsolatedScriptReceipt.State.COMPLETED) { denied.detail ?: "No result" }
        check(JSONObject(denied.outputJson!!).getString("status") == "POLICY_DENIED")
        val privateAudit = network.journal.read(privateCallId)
        check(privateAudit.state() == IsolatedNetworkJournal.State.TERMINAL)
        check(privateAudit.status() == IsolatedNetworkBroker.Status.POLICY_DENIED)
        check(!privateAudit.transportEntered() && dnsCalls.get() == 1 && transportCalls.get() == 0)

        val invalidCallId = UUID.randomUUID().toString()
        val invalid = run(app, program,
            JSONObject().put("callId", invalidCallId)
                .put("url", "http://api.example.org/insecure").toString(),
            3000, networkPolicy = network)
        check(invalid.state == IsolatedScriptReceipt.State.COMPLETED) { invalid.detail ?: "No result" }
        check(JSONObject(invalid.outputJson!!).getString("status") == "POLICY_DENIED")
        val invalidAudit = network.journal.read(invalidCallId)
        check(invalidAudit.state() == IsolatedNetworkJournal.State.TERMINAL)
        check(invalidAudit.status() == IsolatedNetworkBroker.Status.POLICY_DENIED)
        check(!invalidAudit.transportEntered() && dnsCalls.get() == 1 && transportCalls.get() == 0)
    }

    /** Revocation during DNS must stop the request before the pinned transport begins. */
    private fun networkRevokedDuringDns(app: Context) {
        val enteredDns = CountDownLatch(1)
        val releaseDns = CountDownLatch(1)
        val transportCalls = AtomicInteger()
        val network = IsolatedScriptHostBridge.NetworkPolicy(
            IsolatedNetworkBroker.Policy(setOf("api.example.org")),
            AndroidNetworkJournal.open(app),
            IsolatedNetworkBroker.DeadlineResolver { _, _, _ ->
                enteredDns.countDown()
                val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
                while (releaseDns.count > 0 && System.nanoTime() < until) {
                    try { releaseDns.await(20, TimeUnit.MILLISECONDS) }
                    catch (_: InterruptedException) {
                        // Cancellation interrupts the host worker; return a DNS result so the
                        // broker can durably settle this admitted call as CANCELLED.
                    }
                }
                check(releaseDns.count == 0L) { "Synthetic DNS was not released" }
                IsolatedNetworkBroker.Resolution(
                    arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))),
                    IsolatedNetworkBroker.RouteSocketFactory { error("Revoked route opened a socket") },
                )
            },
            IsolatedNetworkBroker.PinnedTransport { _, _, _, _, _ ->
                transportCalls.incrementAndGet()
                error("Revoked route reached transport")
            },
        )
        val runId = UUID.randomUUID().toString()
        val approval = networkPolicyOwner(app, network, runId)
        val callId = UUID.randomUUID().toString()
        val outcome = ArrayBlockingQueue<IsolatedScriptRunController.Result>(1)
        val failed = ArrayBlockingQueue<Throwable>(1)
        val runner = Thread {
            try {
                outcome.offer(run(app,
                    "async (input,host)=>await host.callAsync({action:'HTTPS_GET',callId:input.callId,url:input.url})",
                    JSONObject().put("callId", callId)
                        .put("url", "https://api.example.org/revoked").toString(),
                    5000, runId = runId, networkPolicy = network, policyOwner = approval.owner))
            } catch (error: Throwable) { failed.offer(error) }
        }
        try {
            runner.start()
            check(enteredDns.await(4, TimeUnit.SECONDS)) {
                "Network call never reached synthetic DNS: ${failed.poll()}"
            }
            check(network.journal.read(callId).state() == IsolatedNetworkJournal.State.ADMITTED)
            approval.owner.revoke(runId)
            releaseDns.countDown()
            runner.join(6_000)
            check(!runner.isAlive) { "Revoked guest did not retire" }
            check(failed.isEmpty()) { "Run failed: ${failed.poll()}" }
            val result = outcome.poll() ?: error("Revoked run returned no receipt")
            check(result.state != IsolatedScriptReceipt.State.COMPLETED && result.outputJson == null)
            check(receipts(app).read(runId).state() == result.state)
            val audit = network.journal.read(callId)
            check(audit.state() == IsolatedNetworkJournal.State.TERMINAL)
            check(audit.status() == IsolatedNetworkBroker.Status.CANCELLED)
            check(!audit.transportEntered() && transportCalls.get() == 0)
        } finally {
            releaseDns.countDown()
            runner.join(6_000)
            approval.close()
        }
    }

    private fun receipts(app: Context): IsolatedScriptReceipt =
        IsolatedScriptReceipt(app.filesDir.toPath()) { _ -> }

    private fun pureResultAndReceipt(app: Context) {
        val id = UUID.randomUUID().toString()
        val result = run(app, "({n}) => ({n: n + 1})", "{\"n\":41}", 1500, runId = id)
        check(result.state == IsolatedScriptReceipt.State.COMPLETED) { "State: ${result.state}" }
        check(JSONObject(result.outputJson!!).getInt("n") == 42)
        check(result.guestUid != null && result.guestUid != Process.myUid()) {
            "The guest did not report a distinct isolated UID"
        }
        check(receipts(app).read(id).state() == IsolatedScriptReceipt.State.COMPLETED)
        try {
            run(app, "() => 99", deadlineMillis = 1000, runId = id)
            error("A completed run ID was admitted twice")
        } catch (_: IOException) {
            check(receipts(app).read(id).state() == IsolatedScriptReceipt.State.COMPLETED)
        }
    }

    private fun nativeBridgeParams(runId: String, sessionId: String) = JSONObject()
        .put("kind", "script").put("runId", runId).put("sessionId", sessionId)
        .put("program", "({n}) => ({n: n + 1})").put("inputJson", "{\"n\":41}")
        .put("deadlineMillis", 1500)
        .put("scope", JSONObject().put("ownerId", "app").put("sessionId", sessionId)
            .put("version", 1).put("workspaceId", JSONObject.NULL)
            .put("readablePaths", org.json.JSONArray()).put("writablePaths", org.json.JSONArray())
            .put("exactHosts", org.json.JSONArray()).put("fileCallLimit", 0)
            .put("networkCallLimit", 0).put("leaseMillis", 1500))

    private fun nativeBridgeRun(app: Context) {
        val bridge = IsolatedRunNativeBridge(app)
        val runId = UUID.randomUUID().toString()
        val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
        val grant = JSONObject(params.toString())
        grant.getJSONObject("scope").put("readablePaths", org.json.JSONArray().put("note.txt"))
        try {
            bridge.admit(grant)
            error("A caller selected its own file capability")
        } catch (_: IllegalArgumentException) {
            check(runCatching { receipts(app).read(runId) }.isFailure)
        }
        val handle = bridge.admit(params)
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        check(bridge.execute(owner))
        val terminal = bridge.settle(owner)
        check(terminal.getString("state") == "COMPLETED")
        check(JSONObject(terminal.getString("outputJson")).getInt("n") == 42)
        check(terminal.getInt("guestUid") != Process.myUid())
        check(bridge.release(owner))
        check(runCatching { bridge.settle(owner) }.isFailure)
        check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.COMPLETED)
        check(runCatching { bridge.admit(params) }.isFailure)
    }

    private fun nativeBridgeToolRun(app: Context) {
        val calls = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val closes = AtomicInteger()
        val transport = object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(timeoutMillis > 0)
                check(params.keys().asSequence().toSet() ==
                    setOf("runId", "token", "callId", "name", "arguments"))
                check(params.getString("name") == "echo_read_only")
                calls.add(params.getInt("callId"))
                return JSONObject().put("runId", params.getString("runId"))
                    .put("callId", params.getInt("callId"))
                    .put("value", JSONObject().put("received", params.getJSONObject("arguments").getInt("n")))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(timeoutMillis > 0 && runId.isNotBlank() && token.isNotBlank())
                closes.incrementAndGet()
                return true
            }
        }
        val bridge = IsolatedRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
            .put("program", "async (input,host) => { const a=await host.callAsync({action:'TOOL_CALL',callId:1,name:'echo_read_only',arguments:{n:17}}); const b=await host.callAsync({action:'TOOL_CALL',callId:2,name:'echo_read_only',arguments:{n:25}}); return {sum:a.value.received+b.value.received} }")
            .put("deadlineMillis", 3000)
        params.getJSONObject("scope").put("leaseMillis", 3000)
        val handle = bridge.admit(params)
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            check(runCatching { bridge.bindTools(owner) }.isFailure) { "Tool binding was replayable" }
            check(bridge.execute(owner))
            val result = bridge.settle(owner)
            check(result.getString("state") == "COMPLETED") { result.toString() }
            check(JSONObject(result.getString("outputJson")).getInt("sum") == 42)
            check(result.getInt("guestUid") != Process.myUid())
            check(calls == listOf(1, 2)) { "Unexpected tool sequence: $calls" }
            check(closes.get() == 1) { "Node port was not joined once" }
            check(bridge.release(owner))
        } finally { bridge.close() }
    }

    /** Device Binder fixture: the production first-party ToolRuntime review is tested in Node. */
    private fun ptcBinderReadOnlyCallback(app: Context) {
        val calls = AtomicInteger()
        val closes = AtomicInteger()
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(timeoutMillis > 0 && params.keys().asSequence().toSet() ==
                    setOf("runId", "token", "callId", "name", "arguments"))
                check(params.getString("name") == "list_agents")
                check(params.getJSONObject("arguments").keys().asSequence().toSet() == setOf("scope"))
                check(params.getJSONObject("arguments").getString("scope") == "children")
                calls.incrementAndGet()
                return JSONObject().put("runId", params.getString("runId"))
                    .put("callId", params.getInt("callId"))
                    .put("value", JSONObject().put("agents", org.json.JSONArray()))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(runId.isNotBlank() && token.isNotBlank() && timeoutMillis > 0)
                closes.incrementAndGet()
                return true
            }
        })
        val runId = UUID.randomUUID().toString()
        val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
            .put("program", "async (input,host) => { const r=await host.callAsync({action:'TOOL_CALL',callId:1,name:'list_agents',arguments:{scope:'children'}}); return {count:r.value.agents.length} }")
            .put("deadlineMillis", 3000)
        params.getJSONObject("scope").put("leaseMillis", 3000)
        val handle = bridge.admit(params)
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            check(bridge.execute(owner))
            val result = bridge.settle(owner)
            check(result.getString("state") == "COMPLETED") { result.toString() }
            check(result.getInt("guestUid") != Process.myUid())
            check(JSONObject(result.getString("outputJson")).getInt("count") == 0)
            check(calls.get() == 1 && closes.get() == 1)
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.COMPLETED)
            check(bridge.release(owner))
            check(runCatching { bridge.settle(owner) }.isFailure)
        } finally { bridge.close() }
    }

    private fun ptcBinderCancelReplay(app: Context) {
        val calls = AtomicInteger()
        val closes = AtomicInteger()
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                calls.incrementAndGet()
                error("Cancelled guest reached its callback")
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                closes.incrementAndGet()
                return true
            }
        })
        val runId = UUID.randomUUID().toString()
        val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
        val handle = bridge.admit(params)
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            check(bridge.cancel(owner))
            val result = bridge.settle(owner)
            check(result.getString("state") == "CANCELLED" && result.isNull("outputJson"))
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.CANCELLED)
            check(calls.get() == 0 && closes.get() == 1)
            check(bridge.release(owner))
            check(runCatching { bridge.execute(owner) }.isFailure)
            check(runCatching { bridge.admit(params) }.isFailure)
        } finally { bridge.close() }
    }

    private fun ptcBinderInvalidReply(app: Context) {
        val calls = AtomicInteger()
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                calls.incrementAndGet()
                // A transport success with a forged runId must never become guest success.
                return JSONObject().put("runId", UUID.randomUUID().toString())
                    .put("callId", params.getInt("callId"))
                    .put("value", JSONObject().put("agents", org.json.JSONArray()))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = true
        })
        val runId = UUID.randomUUID().toString()
        val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
            .put("program", "async (input,host) => { await host.callAsync({action:'TOOL_CALL',callId:1,name:'list_agents',arguments:{scope:'children'}}); return {forgedSuccess:true} }")
            .put("deadlineMillis", 3000)
        params.getJSONObject("scope").put("leaseMillis", 3000)
        val handle = bridge.admit(params)
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            runCatching { bridge.execute(owner) }
            check(calls.get() == 1)
            val durable = receipts(app).read(runId).state()
            check(durable != IsolatedScriptReceipt.State.COMPLETED &&
                durable != IsolatedScriptReceipt.State.ADMITTED)
            val settled = runCatching { bridge.settle(owner) }.getOrNull()
            check(settled == null || (settled.getString("state") != "COMPLETED" &&
                settled.isNull("outputJson")))
        } finally { bridge.close() }
    }

    private fun nativeBridgeToolCancel(app: Context) {
        val calls = AtomicInteger()
        val closes = AtomicInteger()
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                calls.incrementAndGet()
                error("Pre-execution guest callback was reachable")
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                closes.incrementAndGet()
                return true
            }
        })
        val runId = UUID.randomUUID().toString()
        val handle = bridge.admit(nativeBridgeParams(runId, UUID.randomUUID().toString()))
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            check(bridge.cancel(owner))
            check(bridge.settle(owner).getString("state") == "CANCELLED")
            check(calls.get() == 0 && closes.get() == 1)
            check(bridge.release(owner))
        } finally { bridge.close() }
    }

    private fun nativeBridgeToolCloseUncertain(app: Context) {
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("Pre-execution guest callback was reachable")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = false
        })
        val runId = UUID.randomUUID().toString()
        val handle = bridge.admit(nativeBridgeParams(runId, UUID.randomUUID().toString()))
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        try {
            check(bridge.bindTools(owner))
            check(runCatching { bridge.cancel(owner) }.isFailure)
            check(receipts(app).read(runId).state() ==
                IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED)
            check(runCatching { bridge.settle(owner) }.isFailure)
        } finally { bridge.close() }
    }

    private fun ptcAdmissionLimits(app: Context) {
        val bridge = IsolatedRunNativeBridge(app)
        try {
            val runId = UUID.randomUUID().toString()
            val params = nativeBridgeParams(runId, UUID.randomUUID().toString())
                .put("kind", "ptc").put("deadlineMillis", 120000)
            params.getJSONObject("scope").put("leaseMillis", 120000)
            check(runCatching { bridge.admit(JSONObject(params.toString()).put("kind", "script")) }.isFailure)
            check(runCatching { bridge.admit(JSONObject(params.toString()).put("deadlineMillis", 120001)) }.isFailure)
            val granted = JSONObject(params.toString())
            granted.getJSONObject("scope").put("exactHosts", org.json.JSONArray().put("example.com"))
                .put("networkCallLimit", 1)
            check(runCatching { bridge.admit(granted) }.isFailure)
            val handle = bridge.admit(params)
            check(runCatching { bridge.execute(handle) }.isFailure) { "Unbound PTC ran" }
            check(bridge.cancel(handle) && bridge.release(handle))
            for (name in listOf("read", "glob", "grep", "web_search", "web_fetch", "list_agents", "write", "edit")) {
                IsolatedToolRequest.parse(JSONObject().put("action", "TOOL_CALL").put("callId", 1)
                    .put("name", name).put("arguments", JSONObject()).toString(), true)
            }
            for ((name, actions) in mapOf("android_files" to listOf("roots", "list", "read", "search"),
                "android_attachments" to listOf("list", "read", "materialize", "inspect_archive", "inspect_apk"))) {
                for (action in actions) IsolatedToolRequest.parse(JSONObject().put("action", "TOOL_CALL")
                    .put("callId", 1).put("name", name)
                    .put("arguments", JSONObject().put("action", action)).toString(), true)
                for (action in listOf("write", "read_image", "delete") + if (name == "android_files") listOf("materialize") else emptyList()) check(runCatching {
                    IsolatedToolRequest.parse(JSONObject().put("action", "TOOL_CALL").put("callId", 1)
                        .put("name", name).put("arguments", JSONObject().put("action", action)).toString(), true)
                }.isFailure)
            }
            for (name in listOf("run_code", "workflow", "android_ptc", "read_image", "android_linux", "echo_read_only")) {
                check(runCatching { IsolatedToolRequest.parse(JSONObject().put("action", "TOOL_CALL")
                    .put("callId", 1).put("name", name).put("arguments", JSONObject()).toString(), true) }.isFailure)
            }
        } finally { bridge.close() }
    }

    /** Binder timing fixture only: this transport is not production ToolRuntime evidence. */
    private fun ptcWaitBudget(app: Context) {
        val calls = AtomicInteger()
        val closes = AtomicInteger()
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(params.getString("name") == "read" && timeoutMillis > 6000)
                calls.incrementAndGet()
                Thread.sleep(6100)
                return JSONObject().put("runId", params.getString("runId")).put("callId", params.getInt("callId"))
                    .put("value", JSONObject().put("waited", true))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                closes.incrementAndGet()
                return true
            }
        })
        val params = nativeBridgeParams(UUID.randomUUID().toString(), UUID.randomUUID().toString())
            .put("kind", "ptc").put("deadlineMillis", 20000)
            .put("program", "const r=await host.callAsync({action:'TOOL_CALL',callId:1,name:'read',arguments:{file_path:'fixture.txt'}}); return {waited:r.value.waited,process:typeof process,fetch:typeof fetch}")
        params.getJSONObject("scope").put("leaseMillis", 20000)
        try {
            val handle = bridge.admit(params)
            check(bridge.bindTools(handle) && bridge.execute(handle))
            val result = bridge.settle(handle)
            check(result.getString("state") == "COMPLETED") { result.toString() }
            val value = JSONObject(result.getString("outputJson"))
            check(value.getBoolean("waited") && value.getString("process") == "undefined" && value.getString("fetch") == "undefined")
            check(result.getInt("guestUid") != Process.myUid() && calls.get() == 1 && closes.get() == 1)
            check(bridge.release(handle))
        } finally { bridge.close() }
    }

    private fun ptcCpuBudget(app: Context) {
        val bridge = IsolatedRunNativeBridge(app, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject = error("Busy loop called host")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = true
        })
        val params = nativeBridgeParams(UUID.randomUUID().toString(), UUID.randomUUID().toString())
            .put("kind", "ptc").put("deadlineMillis", 120000).put("program", "while(true) {}")
        params.getJSONObject("scope").put("leaseMillis", 120000)
        try {
            val handle = bridge.admit(params)
            check(bridge.bindTools(handle))
            val start = System.nanoTime()
            check(bridge.execute(handle))
            val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
            val result = bridge.settle(handle)
            check(result.getString("state") == "TIMED_OUT" && result.isNull("outputJson")) { result.toString() }
            check(elapsed < 30000) { "PTC busy loop consumed its 120-second wall allowance: $elapsed" }
            check(bridge.release(handle))
        } finally { bridge.close() }
    }

    private fun nativeBridgeToolFrames() {
        check(runCatching { IsolatedToolRequest.parse(
            "{\"action\":\"TOOL_CALL\",\"callId\":1,\"name\":\"run_code\",\"arguments\":{}}")
        }.isFailure)
        for (name in listOf("android_shell", "android_linux", "android_files", "workflow", "android_ptc")) {
            check(runCatching { IsolatedToolRequest.parse(
                "{\"action\":\"TOOL_CALL\",\"callId\":1,\"name\":\"$name\",\"arguments\":{}}")
            }.isFailure)
        }
        check(runCatching { IsolatedToolRequest.parse(
            "{\"action\":\"TOOL_CALL\",\"callId\":1,\"name\":\"echo_read_only\",\"arguments\":{},\"token\":\"forged\"}")
        }.isFailure)
        check(runCatching { IsolatedToolRequest.response(
            JSONObject().put("runId", "wrong").put("callId", 1).put("value", 1), "expected", 1)
        }.isFailure)
        val settledError = JSONObject().put("code", "ANDROID_TOOL_DISPATCH_FAILED")
            .put("message", "invalid input")
        val reply = IsolatedToolRequest.response(JSONObject().put("runId", "expected")
            .put("callId", 1).put("error", settledError), "expected", 1)
        check(JSONObject(reply).getJSONObject("error").getString("code") ==
            "ANDROID_TOOL_DISPATCH_FAILED")
        check(runCatching { IsolatedToolRequest.response(JSONObject().put("runId", "expected")
            .put("callId", 1).put("error", settledError).put("value", 1), "expected", 1)
        }.isFailure)
        check(runCatching { IsolatedToolRequest.response(JSONObject().put("runId", "expected")
            .put("callId", 1).put("error", JSONObject().put("code", "ANDROID_TOOL_DISPATCH_UNCONFIRMED")
                .put("message", "audit failed")), "expected", 1)
        }.isFailure)
        check(runCatching { IsolatedToolRequest.response(JSONObject().put("runId", "expected")
            .put("callId", 1).put("error", JSONObject().put("code", "ANDROID_TOOL_NOT_GRANTED")
                .put("message", "x".repeat(4097))), "expected", 1)
        }.isFailure)
    }

    private fun nativeBridgeCancel(app: Context) {
        val bridge = IsolatedRunNativeBridge(app)
        val runId = UUID.randomUUID().toString()
        val handle = bridge.admit(nativeBridgeParams(runId, UUID.randomUUID().toString()))
        val owner = JSONObject().put("runId", runId).put("token", handle.getString("token"))
        check(bridge.cancel(owner))
        check(bridge.settle(owner).getString("state") == "CANCELLED")
        check(bridge.release(owner))
        check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.CANCELLED)
    }

    private fun nativeBridgeCancelFailure(app: Context) {
        val bridge = IsolatedRunNativeBridge(app) { throw IOException("Injected pre-retirement failure") }
        val runId = UUID.randomUUID().toString()
        try {
            val owner = bridge.admit(nativeBridgeParams(runId, UUID.randomUUID().toString()))
            check(runCatching { bridge.cancel(owner) }.isFailure)
            check(runCatching { bridge.settle(owner) }.isFailure) { "Failed cancellation retained a token" }
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED)
            check(runCatching { bridge.admit(nativeBridgeParams(runId,
                UUID.randomUUID().toString())) }.isFailure) { "Uncertain run ID was replayed" }
        } finally { bridge.close() }
    }

    private fun nativeBridgeDiscardPlan(app: Context) {
        val root = File(app.filesDir, "discard-bridge-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val runId = UUID.randomUUID().toString()
        val handle = filePolicyOwner(app, policy, runId)
        val bridge = IsolatedRunNativeBridge(app)
        try {
            val scope = handle.approvedScopeForRun(runId)
            val workspaceId = UUID.randomUUID().toString()
            bridge.installApprovedPlan(runId, scope.sessionId(), workspaceId,
                scope, handle, "() => 1", "null", 1000)
            bridge.discardApprovedPlan(runId)
            bridge.discardApprovedPlan(runId)
            val request = JSONObject().put("kind", "script").put("runId", runId)
                .put("sessionId", scope.sessionId()).put("program", "() => 1")
                .put("inputJson", "null").put("deadlineMillis", 1000)
                .put("scope", JSONObject().put("ownerId", scope.ownerId())
                    .put("sessionId", scope.sessionId()).put("version", scope.version())
                    .put("workspaceId", workspaceId)
                    .put("readablePaths", org.json.JSONArray().put("note.txt"))
                    .put("writablePaths", org.json.JSONArray())
                    .put("exactHosts", org.json.JSONArray())
                    .put("fileCallLimit", scope.fileCallLimit())
                    .put("networkCallLimit", 0).put("leaseMillis", scope.leaseMillis()))
            check(runCatching { bridge.admit(request) }.isFailure) { "Discarded plan was still usable" }
            check(runCatching { receipts(app).read(runId) }.isFailure)
            // Discard precedes admission: it revokes file authority but does not
            // burn the ID. Record this deliberately narrower lifecycle contract.
            val denied = bridge.admit(nativeBridgeParams(runId, scope.sessionId()))
            check(bridge.cancel(denied))
            check(bridge.release(denied))
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.CANCELLED)
            check(runCatching { bridge.admit(request) }.isFailure) {
                "Discarded file authority was revived by a later empty run"
            }
        } finally { bridge.close(); handle.close() }
    }

    private fun nativeBridgeApprovalRace(app: Context) {
        val root = File(app.filesDir, "approval-race-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val runId = UUID.randomUUID().toString()
        val handle = filePolicyOwner(app, policy, runId)
        val bridge = IsolatedRunNativeBridge(app)
        val gate = CountDownLatch(1)
        val installed = AtomicBoolean(false)
        val admitted = AtomicReference<JSONObject?>()
        val failure = AtomicReference<Throwable?>()
        try {
            val scope = handle.approvedScopeForRun(runId)
            val installer = Thread {
                try {
                    gate.await()
                    bridge.installApprovedPlan(runId, scope.sessionId(), UUID.randomUUID().toString(),
                        scope, handle, "() => 1", "null", 1000)
                    installed.set(true)
                } catch (_: IllegalStateException) { /* Denied admission won first. */ }
                catch (unexpected: Throwable) { failure.compareAndSet(null, unexpected) }
            }
            val denier = Thread {
                try {
                    gate.await()
                    admitted.set(bridge.admit(nativeBridgeParams(runId, scope.sessionId())))
                } catch (_: IllegalStateException) { /* Approved installation won first. */ }
                catch (unexpected: Throwable) { failure.compareAndSet(null, unexpected) }
            }
            installer.start(); denier.start(); gate.countDown()
            installer.join(10_000); denier.join(10_000)
            check(!installer.isAlive && !denier.isAlive && failure.get() == null) {
                "Approval/admission race did not settle: ${failure.get()}" }
            check(installed.get() xor (admitted.get() != null)) {
                "One run ID was both denied-admitted and approved-installed" }
            if (installed.get()) {
                bridge.discardApprovedPlan(runId)
                check(runCatching { receipts(app).read(runId) }.isFailure)
            } else {
                val token = checkNotNull(admitted.get())
                check(bridge.cancel(token))
                check(bridge.release(token))
                check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.CANCELLED)
            }
        } finally { bridge.close(); handle.close() }
    }

    private fun nativeBridgeApprovedFile(app: Context) {
        val root = File(app.filesDir, "approved-bridge-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val runId = UUID.randomUUID().toString()
        val handle = filePolicyOwner(app, policy, runId)
        val bridge = IsolatedRunNativeBridge(app)
        try {
            val approved = handle.approvedScopeForRun(runId)
            val workspaceId = UUID.randomUUID().toString()
            val input = JSONObject().put("callId", UUID.randomUUID().toString()).toString()
            val program = "(input, host) => host.call({action:'READ',callId:input.callId,grantId:host.grants[0].id})"
            bridge.installApprovedPlan(runId, approved.sessionId(), workspaceId,
                approved, handle, program, input, 3000)
            val scope = JSONObject().put("ownerId", approved.ownerId())
                .put("sessionId", approved.sessionId()).put("version", approved.version())
                .put("workspaceId", workspaceId)
                .put("readablePaths", org.json.JSONArray().put("note.txt"))
                .put("writablePaths", org.json.JSONArray())
                .put("exactHosts", org.json.JSONArray())
                .put("fileCallLimit", approved.fileCallLimit())
                .put("networkCallLimit", 0).put("leaseMillis", approved.leaseMillis())
            val request = JSONObject().put("kind", "script").put("runId", runId)
                .put("sessionId", approved.sessionId()).put("program", program)
                .put("inputJson", input).put("deadlineMillis", 3000).put("scope", scope)
            val denied = nativeBridgeParams(runId, approved.sessionId())
            check(runCatching { bridge.admit(denied) }.isFailure) {
                "Denied request bypassed an approved plan for the same run"
            }
            check(runCatching { receipts(app).read(runId) }.isFailure)
            val admission = bridge.admit(request)
            val owner = JSONObject().put("runId", runId).put("token", admission.getString("token"))
            check(bridge.execute(owner))
            val terminal = bridge.settle(owner)
            check(terminal.getString("state") == "COMPLETED") {
                "Approved bridge state: ${terminal.getString("state")}; ${terminal.optString("detail")}" }
            val result = JSONObject(terminal.getString("outputJson"))
            check(result.getString("status") == "OK" &&
                result.getJSONObject("read").getString("text") == "approved-file")
            check(terminal.getInt("guestUid") != Process.myUid())
            check(bridge.release(owner))
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.COMPLETED)
        } finally {
            bridge.close()
            handle.close()
        }
    }

    private fun nativeBridgeRejectedApprovedPlan(app: Context) {
        for (mismatch in listOf("program", "scope", "revoked-owner")) {
            val root = File(app.filesDir, "rejected-approved-$mismatch-${UUID.randomUUID()}")
                .apply { check(mkdirs()) }
            val policy = filePolicy(app, root)
            val runId = UUID.randomUUID().toString()
            val handle = filePolicyOwner(app, policy, runId)
            val bridge = IsolatedRunNativeBridge(app)
            try {
                val approved = handle.approvedScopeForRun(runId)
                val workspaceId = UUID.randomUUID().toString()
                bridge.installApprovedPlan(runId, approved.sessionId(), workspaceId,
                    approved, handle, "() => 1", "null", 1000)
                val scope = JSONObject().put("ownerId", approved.ownerId())
                    .put("sessionId", approved.sessionId()).put("version", approved.version())
                    .put("workspaceId", workspaceId)
                    .put("readablePaths", org.json.JSONArray().put("note.txt"))
                    .put("writablePaths", org.json.JSONArray())
                    .put("exactHosts", org.json.JSONArray())
                    .put("fileCallLimit", approved.fileCallLimit())
                    .put("networkCallLimit", 0).put("leaseMillis", approved.leaseMillis())
                val request = JSONObject().put("kind", "script").put("runId", runId)
                    .put("sessionId", approved.sessionId()).put("program", "() => 1")
                    .put("inputJson", "null").put("deadlineMillis", 1000).put("scope", scope)
                when (mismatch) {
                    "program" -> request.put("program", "() => 2")
                    "scope" -> scope.put("readablePaths", org.json.JSONArray().put("secret.txt"))
                    "revoked-owner" -> handle.close()
                }
                check(runCatching { bridge.admit(request) }.isFailure) {
                    "Rejected approved $mismatch request was admitted"
                }
                val state = receipts(app).read(runId).state()
                check(state == IsolatedScriptReceipt.State.CANCELLED ||
                    (mismatch == "revoked-owner" &&
                        state == IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED)) {
                    "Rejected approved $mismatch plan had no durable terminal receipt: $state"
                }
                check(runCatching { bridge.admit(request) }.isFailure) {
                    "Rejected approved $mismatch plan was reused"
                }
                bridge.close()
                check(receipts(app).recoverInterrupted().none { it.runId() == runId }) {
                    "Rejected approved $mismatch run was reopened by recovery"
                }
                val restarted = IsolatedRunNativeBridge(app)
                val freshHandle = filePolicyOwner(app, policy, runId)
                try {
                    check(runCatching { restarted.admit(nativeBridgeParams(runId,
                        approved.sessionId())) }.isFailure) {
                        "Rejected approved $mismatch run ID became an empty-scope run after Service restart"
                    }
                    val freshScope = freshHandle.approvedScopeForRun(runId)
                    check(runCatching { restarted.installApprovedPlan(runId,
                        freshScope.sessionId(), workspaceId, freshScope, freshHandle,
                        "() => 1", "null", 1000) }.isFailure) {
                        "Rejected approved $mismatch run ID gained a new plan after Service restart"
                    }
                    check(receipts(app).read(runId).state() == state)
                } finally { restarted.close(); freshHandle.close() }
            } finally { bridge.close(); handle.close() }
        }
    }

    private fun nativeBridgeDirectoryGrantRejected(app: Context) {
        val root = File(app.filesDir, "approved-directory-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val workspace = File(root, "workspace").apply { check(mkdirs()) }
        File(workspace, "notes").apply { check(mkdirs()) }
        File(workspace, "notes/child.txt").writeText("inside-directory")
        val journal = IsolatedCapabilityJournal(File(root, "audit").apply { check(mkdirs()) }.toPath()) {
            directory ->
            val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0)
            try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
        }
        val policy = IsolatedScriptHostBridge.Policy(workspace, UUID.randomUUID().toString(), journal,
            listOf(IsolatedCapabilityBroker.GrantSpec("notes/", setOf(
                IsolatedCapabilityBroker.Action.READ))),
            IsolatedCapabilityBroker.SandboxPolicy(setOf("notes/"), emptySet()))
        val runId = UUID.randomUUID().toString()
        val handle = filePolicyOwner(app, policy, runId)
        val bridge = IsolatedRunNativeBridge(app)
        try {
            val approved = handle.approvedScopeForRun(runId)
            val workspaceId = UUID.randomUUID().toString()
            val program = "() => 1"
            bridge.installApprovedPlan(runId, approved.sessionId(), workspaceId,
                approved, handle, program, "null", 1000)
            val scope = JSONObject().put("ownerId", approved.ownerId())
                .put("sessionId", approved.sessionId()).put("version", approved.version())
                .put("workspaceId", workspaceId)
                .put("readablePaths", org.json.JSONArray().put("notes/"))
                .put("writablePaths", org.json.JSONArray())
                .put("exactHosts", org.json.JSONArray())
                .put("fileCallLimit", approved.fileCallLimit())
                .put("networkCallLimit", 0).put("leaseMillis", approved.leaseMillis())
            val request = JSONObject().put("kind", "script").put("runId", runId)
                .put("sessionId", approved.sessionId()).put("program", program)
                .put("inputJson", "null").put("deadlineMillis", 1000).put("scope", scope)
            check(runCatching { bridge.admit(request) }.isFailure) {
                "Directory grant was admitted as an exact-file grant"
            }
            check(receipts(app).read(runId).state() == IsolatedScriptReceipt.State.CANCELLED) {
                "Rejected directory grant did not leave a durable terminal receipt"
            }
            check(journal.inspect().runs().isEmpty())
            check(File(workspace, "notes/child.txt").readText() == "inside-directory")
            val restarted = IsolatedRunNativeBridge(app)
            try {
                check(runCatching { restarted.admit(nativeBridgeParams(runId,
                    approved.sessionId())) }.isFailure) {
                    "Rejected directory run ID became an empty-scope run after bridge restart"
                }
            } finally { restarted.close() }
        } finally { bridge.close(); handle.close() }
    }

    /** A long guest must not monopolize admission and completion of another pure guest. */
    private fun concurrentPureScripts(app: Context) {
        val longId = UUID.randomUUID().toString()
        val longOutcome = ArrayBlockingQueue<IsolatedScriptRunController.Result>(1)
        val longFailure = ArrayBlockingQueue<Throwable>(1)
        val longRunner = Thread {
            try {
                longOutcome.offer(run(app, "() => { while (true) {} }",
                    deadlineMillis = PtcScriptEngine.MAX_DEADLINE_MILLIS, runId = longId))
            } catch (failure: Throwable) { longFailure.offer(failure) }
        }
        try {
            longRunner.start()
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            var admitted = false
            while (System.nanoTime() < until) {
                try {
                    if (receipts(app).read(longId).state() == IsolatedScriptReceipt.State.ADMITTED) {
                        admitted = true
                        break
                    }
                } catch (_: IOException) { /* Admission may still be syncing. */ }
                Thread.sleep(10)
            }
            check(admitted) { "Long script was not durably admitted: ${longFailure.poll()}" }
            val short = run(app, "({value}) => value + 1", "{\"value\":41}",
                deadlineMillis = 1000)
            check(short.state == IsolatedScriptReceipt.State.COMPLETED && short.outputJson == "42") {
                "Short script failed while long script was admitted: ${short.state}; ${short.detail}"
            }
            check(longRunner.isAlive && longOutcome.isEmpty() && longFailure.isEmpty()) {
                "Short script completed only after the long script retired"
            }
        } finally { longRunner.join(9_000) }
        check(!longRunner.isAlive) { "Long script never retired" }
        check(longFailure.isEmpty()) { "Long script failed: ${longFailure.poll()}" }
        val long = longOutcome.poll() ?: error("Long script returned no receipt")
        check(long.state == IsolatedScriptReceipt.State.TIMED_OUT && long.outputJson == null)
        check(receipts(app).read(longId).state() == long.state)
    }

    private fun noAmbientJsApis(app: Context) {
        val pure = run(app, "(_input, host) => typeof host")
        check(pure.state == IsolatedScriptReceipt.State.COMPLETED && pure.outputJson == "\"undefined\"") {
            "Pure guest received a host object"
        }
        val marker = File(app.filesDir, "isolated-acceptance-${UUID.randomUUID()}.txt")
        marker.writeText("private-marker")
        try {
            val path = JSONObject.quote(marker.absolutePath)
            val program = "() => ({file: (() => { try { return require('fs').readFileSync($path, 'utf8') } catch (e) { return e.name } })(), network: (() => { try { return fetch('https://example.com/') } catch (e) { return e.name } })(), process: typeof process, WebSocket: typeof WebSocket, Java: typeof Java})"
            val result = run(app, program)
            check(result.state == IsolatedScriptReceipt.State.COMPLETED) { "State: ${result.state}" }
            val value = JSONObject(result.outputJson!!)
            check(value.getString("file") == "ReferenceError") { "App-private marker was reachable" }
            check(value.getString("network") == "ReferenceError") { "Direct fetch became available" }
            for (name in listOf("process", "WebSocket", "Java")) {
                check(value.getString(name) == "undefined") { "$name became available to guest code" }
            }
        } finally {
            check(marker.delete()) { "Could not remove the acceptance marker" }
        }
    }

    private fun infiniteLoopDeadline(app: Context) {
        val result = run(app, "() => { while (true) {} }", deadlineMillis = 200)
        check(result.state == IsolatedScriptReceipt.State.TIMED_OUT) { "State: ${result.state}" }
        check(result.outputJson == null)
        check(receipts(app).read(result.runId).state() == result.state)
    }

    private fun cancellation(app: Context) {
        val result = run(app, "() => { while (true) {} }", deadlineMillis = 1000,
            cancelled = BooleanSupplier { true })
        check(result.state == IsolatedScriptReceipt.State.CANCELLED) { "State: ${result.state}" }
        check(result.outputJson == null)
        check(receipts(app).read(result.runId).state() == result.state)
    }

    private fun mainThreadStall(app: Context) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        check(Handler(Looper.getMainLooper()).post {
            entered.countDown()
            try { release.await(3600, TimeUnit.MILLISECONDS) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        })
        try {
            check(entered.await(1, TimeUnit.SECONDS)) { "Could not block the main thread" }
            val result = run(app, "() => 7", deadlineMillis = 300)
            check(result.state == IsolatedScriptReceipt.State.COMPLETED) {
                "Main-thread stall delayed guest retirement: ${result.state}"
            }
            check(result.outputJson == "7")
        } finally {
            release.countDown()
        }
    }

    private fun malformedGuestDeath(app: Context) {
        val connected = ArrayBlockingQueue<IBinder>(1)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                connected.offer(binder)
            }
            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        val bound = app.bindIsolatedService(
            Intent(app, IsolatedScriptService::class.java), Context.BIND_AUTO_CREATE,
            "acceptance_${UUID.randomUUID().toString().replace("-", "")}",
            { command -> command.run() }, connection,
        )
        check(bound) { "Could not bind an isolated guest" }
        try {
            val binder = connected.poll(5, TimeUnit.SECONDS) ?: error("Guest binder was not delivered")
            val died = CountDownLatch(1)
            binder.linkToDeath({ died.countDown() }, 0)
            Messenger(binder).send(Message.obtain(null, IsolatedScriptWire.RUN))
            check(died.await(5, TimeUnit.SECONDS)) { "Malformed request did not retire the guest" }
        } finally {
            app.unbindService(connection)
        }
    }

    /** Optional destructive phase: the external test driver must later invoke phase=recover. */
    private fun admitAndKillAgent(app: Context): Nothing {
        val id = requiredRunId("runId")
        val runner = Thread {
            try { run(app, "() => { while (true) {} }", deadlineMillis = 5000, runId = id) }
            catch (_: Throwable) { /* The test driver judges the durable receipt after restart. */ }
        }
        runner.start()
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < end) {
            try {
                if (receipts(app).read(id).state() == IsolatedScriptReceipt.State.ADMITTED) {
                    Process.killProcess(Process.myPid())
                }
            } catch (_: IOException) { /* Admission may not have reached disk yet. */ }
            Thread.sleep(20)
        }
        error("Agent process was not admitted before the kill deadline")
    }

    /** Optional destructive phase: a settled host call confirms that guest code began running. */
    private fun killAgentAfterGuestCall(app: Context): Nothing {
        val id = requiredRunId("runId")
        val root = File(app.filesDir, "running-death-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val policy = filePolicy(app, root)
        val callId = UUID.randomUUID().toString()
        val runner = Thread {
            try {
                run(app,
                    "(input, host) => { host.call({action:'READ',callId:input.callId,grantId:host.grants[0].id}); while(true){} }",
                    JSONObject().put("callId", callId).toString(), 5000, runId = id, hostPolicy = policy)
            } catch (_: Throwable) { /* The test driver judges the durable receipt after restart. */ }
        }
        runner.start()
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < end) {
            val admitted = runCatching {
                receipts(app).read(id).state() == IsolatedScriptReceipt.State.ADMITTED
            }.getOrDefault(false)
            val guestCallSettled = runCatching {
                File(root, "audit/isolated-capabilities.jsonl")
                    .takeIf { it.isFile }?.readText()?.contains("\"phase\":\"CALL_SETTLED\"") == true
            }.getOrDefault(false)
            if (admitted && guestCallSettled) Process.killProcess(Process.myPid())
            Thread.sleep(20)
        }
        error("Guest host call did not settle before the kill deadline")
    }

    private fun recoverAfterAgentDeath(app: Context) {
        val killed = requiredRunId("runId")
        val recoveryId = requiredRunId("recoveryRunId")
        check(killed != recoveryId)
        val result = run(app, "() => 1", deadlineMillis = 1000, runId = recoveryId)
        check(result.state == IsolatedScriptReceipt.State.COMPLETED) { "Recovery run failed: ${result.state}" }
        check(receipts(app).read(killed).state() == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED) {
            "The killed run was not marked uncertain"
        }
        try {
            run(app, "() => 2", runId = killed)
            error("The killed run ID was replayed")
        } catch (_: IOException) { /* The durable admission reserves the original run ID. */ }
    }

    private fun requiredRunId(key: String): String =
        (arguments.getString(key) ?: error("Missing $key")).also(IsolatedScriptWire::requireUuid)
}
