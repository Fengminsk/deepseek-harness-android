package com.minnnng.dsh_android

import android.content.Context
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.BooleanSupplier

/** Private Node-to-App admission. Grants require an exact App-owned approved plan. */
internal class IsolatedRunNativeBridge(
    context: Context,
    private val toolTransport: IsolatedScriptToolBridge.Transport? = null,
    private val capabilityJournal: () -> IsolatedCapabilityJournal = {
        IsolatedCapabilityWorkspace.journal(context)
    },
    private val beforeReceiptRetirement: () -> Unit = {},
) {
    private val app = context.applicationContext
    private val runs = ConcurrentHashMap<String, Run>()
    private val approved = ConcurrentHashMap<String, ApprovedPlan>()
    private val admissions = Any()
    private val abandonedAdmissions = Executors.newSingleThreadScheduledExecutor()

    /** Used only when AgentService stops without a process exit. */
    fun close() {
        abandonedAdmissions.shutdownNow()
        runs.values.forEach { it.cancelled.set(true) }
        synchronized(admissions) {
            val pending = approved.values.toList()
            approved.clear()
            pending.forEach { try { it.handle.close() } catch (_: Exception) {} }
        }
    }

    private data class ApprovedPlan(
        val runId: String, val sessionId: String, val workspaceId: String?,
        val scope: IsolatedExecutionPolicyOwner.Scope,
        val handle: IsolatedScriptRunController.ApprovalHandle,
        val program: String, val inputJson: String, val deadlineMillis: Int,
    )

    /** Called only by AgentService after its native approval confirmation commits. */
    internal fun installApprovedPlan(
        runId: String, sessionId: String, workspaceId: String?,
        scope: IsolatedExecutionPolicyOwner.Scope,
        handle: IsolatedScriptRunController.ApprovalHandle,
        program: String, inputJson: String, deadlineMillis: Int,
    ) {
        IsolatedScriptWire.requireUuid(runId)
        IsolatedScriptWire.requireSessionId(sessionId)
        check(scope === handle.approvedScopeForRun(runId) && scope.sessionId() == sessionId)
        check(scope.readablePaths().isNotEmpty() || scope.exactHosts().isNotEmpty())
        // Directory grants remain scoped to the approved slash-suffixed root.
        // The broker requires an explicit child name for each operation, and
        // WorkspaceOps opens it through descriptor-anchored no-follow traversal.
        check(scope.readablePaths().size <= IsolatedCapabilityBroker.MAX_GRANTS)
        if (scope.readablePaths().isNotEmpty()) {
            checkNotNull(workspaceId).also(IsolatedScriptWire::requireUuid)
            check(scope.workspaceRoot() != null && scope.appPrivateRoot() != null)
        } else check(workspaceId == null)
        require(deadlineMillis in 1..PtcScriptEngine.MAX_DEADLINE_MILLIS)
        check(scope.leaseMillis() >= deadlineMillis)
        PtcScriptEngine.validate(program, inputJson, deadlineMillis)
        synchronized(admissions) {
            check(scope === handle.approvedScopeForRun(runId))
            IsolatedScriptRunController.requireFreshRunId(app, runId)
            check(approved.putIfAbsent(runId, ApprovedPlan(runId, sessionId, workspaceId,
                scope, handle, program, inputJson, deadlineMillis)) == null)
        }
    }

    /** Native denial/expiry removes an unadmitted plan; repeated removal is harmless. */
    internal fun discardApprovedPlan(runId: String) {
        synchronized(admissions) { approved.remove(runId)?.handle?.close() }
    }

    private enum class Phase { RESERVED, RUNNING, TERMINAL }
    private class Run(
        val token: String, val runId: String, val kind: String,
        val reservation: IsolatedScriptRunController.Reservation?,
        val approvedReservation: IsolatedScriptRunController.ApprovedReservation?,
        val approvedPlan: ApprovedPlan?,
        val filePolicy: IsolatedScriptHostBridge.Policy?,
        val networkPolicy: IsolatedScriptHostBridge.NetworkPolicy?,
        val program: String, val inputJson: String, val deadlineMillis: Int,
    ) {
        fun cancelBeforeExecution(app: Context, beforeReceiptRetirement: () -> Unit) {
            beforeReceiptRetirement()
            if (reservation != null) reservation.cancelBeforeExecution(app)
            else checkNotNull(approvedReservation).cancelBeforeExecution(app)
        }
        fun markUnconfirmed(app: Context) {
            if (reservation != null) reservation.markUnconfirmed(app)
            else checkNotNull(approvedReservation).markUnconfirmed(app)
        }
        fun closeApproval() { approvedPlan?.handle?.close() }
        val monitor = java.lang.Object()
        val cancelled = AtomicBoolean(false)
        var phase = Phase.RESERVED
        var result: IsolatedScriptRunController.Result? = null
        var expiry: ScheduledFuture<*>? = null
        var toolBound = false
    }

    private fun whole(value: Any): Long {
        require(value is Number)
        val number = value.toLong()
        require(value.toDouble() == number.toDouble()) { "Isolated run budget must be an integer" }
        return number
    }

    /** Durable admission precedes this reply. Any timeout has an unknown, non-retryable outcome. */
    fun admit(params: JSONObject): JSONObject {
        require(params.keys().asSequence().toSet() == setOf(
            "kind", "runId", "sessionId", "program", "inputJson", "deadlineMillis", "scope"))
        require(params.get("kind") is String && params.get("runId") is String &&
            params.get("sessionId") is String && params.get("program") is String &&
            params.get("inputJson") is String && params.get("deadlineMillis") is Number)
        val kind = params.getString("kind")
        require(kind in setOf("script", "ptc")) { "Execution requires a script or reviewed PTC admission" }
        val runId = params.getString("runId")
        val sessionId = params.getString("sessionId")
        IsolatedScriptWire.requireUuid(runId)
        IsolatedScriptWire.requireSessionId(sessionId)
        val scope = params.getJSONObject("scope")
        require(scope.keys().asSequence().toSet() == setOf(
            "ownerId", "sessionId", "version", "workspaceId", "readablePaths",
            "writablePaths", "exactHosts", "fileCallLimit", "networkCallLimit", "leaseMillis"))
        require(scope.get("ownerId") is String && scope.get("sessionId") is String &&
            scope.get("version") is Number && scope.get("fileCallLimit") is Number &&
            scope.get("networkCallLimit") is Number && scope.get("leaseMillis") is Number)
        require(scope.getString("sessionId") == sessionId &&
            scope.getString("ownerId").matches(Regex("[A-Za-z0-9._:-]{1,128}")) &&
            whole(scope.get("version")) > 0)
        val program = params.getString("program")
        val inputJson = params.getString("inputJson")
        val deadline = whole(params.get("deadlineMillis"))
        val maximumDeadline = if (kind == "ptc") PtcScriptEngine.MAX_PTC_DEADLINE_MILLIS
            else PtcScriptEngine.MAX_DEADLINE_MILLIS
        require(deadline in 1..maximumDeadline.toLong())
        val deadlineMillis = deadline.toInt()
        if (kind == "ptc") PtcScriptEngine.validatePtc(program, inputJson, deadlineMillis)
        else PtcScriptEngine.validate(program, inputJson, deadlineMillis)
        require(whole(scope.get("leaseMillis")) in deadlineMillis.toLong()..300_000L)
        return synchronized(admissions) {
            require(runs.size < IsolatedExecutionPolicyOwner.MAX_ACTIVE_LEASES) { "Too many isolated runs" }
            val denied = scope.isNull("workspaceId") &&
                scope.getJSONArray("readablePaths").length() == 0 &&
                scope.getJSONArray("writablePaths").length() == 0 &&
                scope.getJSONArray("exactHosts").length() == 0 &&
                whole(scope.get("fileCallLimit")) == 0L && whole(scope.get("networkCallLimit")) == 0L
            require(kind != "ptc" || denied) { "PTC accepts no native file or network grants" }
            check(!denied || !approved.containsKey(runId)) {
                "This run already belongs to an App-approved capability plan"
            }
            val plan = if (denied) null else requireNotNull(approved.remove(runId)) {
                "Granted scope has no exact App-approved run"
            }
            var approvedReservation: IsolatedScriptRunController.ApprovedReservation? = null
            val reservation: IsolatedScriptRunController.Reservation?
            val filePolicy: IsolatedScriptHostBridge.Policy?
            val networkPolicy: IsolatedScriptHostBridge.NetworkPolicy?
            try {
                if (plan == null) {
                    reservation = IsolatedScriptRunController.reserve(app, runId)
                    filePolicy = null
                    networkPolicy = null
                } else {
                    // Claim the one-use approval and its durable run ID before checking the
                    // supplied script/scope. A mismatch must leave a terminal receipt, not
                    // free this ID for an unrelated empty-scope admission.
                    approvedReservation = IsolatedScriptRunController.reserveApproved(app, runId, plan.handle)
                    check(plan.program == program && plan.inputJson == inputJson &&
                        plan.deadlineMillis == deadlineMillis && plan.sessionId == sessionId)
                    val readable = scopeNames(scope, "readablePaths")
                    val writable = scopeNames(scope, "writablePaths")
                    val hosts = scopeNames(scope, "exactHosts")
                    val approvedScope = plan.scope
                    IsolatedApprovedRunScope.verify(approvedScope, plan.sessionId,
                        plan.workspaceId, sessionId,
                        if (scope.isNull("workspaceId")) null else scope.getString("workspaceId"),
                        scope.getString("ownerId"), whole(scope.get("version")),
                        readable, writable, hosts,
                        whole(scope.get("fileCallLimit")), whole(scope.get("networkCallLimit")),
                        whole(scope.get("leaseMillis")))
                    check(approvedScope === plan.handle.approvedScopeForRun(runId))
                    filePolicy = if (readable.isEmpty()) null else {
                        // Consume no approved run until the App-private audit has
                        // been rechecked. A previous uncertain write cannot be
                        // made safe by opening a fresh Node or Binder session.
                        val journal = capabilityJournal().also { it.requireCleanAdmission() }
                        val grants = readable.sorted().map { name ->
                            val actions = if (name in writable)
                                setOf(IsolatedCapabilityBroker.Action.READ,
                                    IsolatedCapabilityBroker.Action.SEARCH,
                                    IsolatedCapabilityBroker.Action.EDIT,
                                    IsolatedCapabilityBroker.Action.WRITE)
                            else setOf(IsolatedCapabilityBroker.Action.READ,
                                IsolatedCapabilityBroker.Action.SEARCH)
                            IsolatedCapabilityBroker.GrantSpec(name, actions)
                        }
                        IsolatedScriptHostBridge.Policy(
                            checkNotNull(approvedScope.workspaceRoot()).toFile(), approvedScope.ownerId(),
                            journal, grants,
                            IsolatedCapabilityBroker.SandboxPolicy(readable, writable))
                    }
                    networkPolicy = if (hosts.isEmpty()) null else
                        IsolatedScriptHostBridge.NetworkPolicy.forAndroid(app, hosts)
                    reservation = null
                }
            } catch (failure: Exception) {
                if (plan != null) {
                    try {
                        if (approvedReservation == null)
                            IsolatedScriptRunController.retireRejectedApprovedPlan(app, runId)
                        else approvedReservation.cancelBeforeExecution(app)
                    } catch (retirement: Exception) { failure.addSuppressed(retirement) }
                    finally { plan.handle.close() }
                }
                throw failure
            }
            val token = UUID.randomUUID().toString()
            val run = Run(token, runId, kind, reservation, approvedReservation, plan,
                filePolicy, networkPolicy, program, inputJson, deadlineMillis)
            runs[token] = run
            try { run.expiry = abandonedAdmissions.schedule({
                // A lost IPC reply leaves an admitted receipt. Retire only if
                // execute never consumed the token; a running guest retains it.
                synchronized(run.monitor) {
                    if (run.phase == Phase.RESERVED) try {
                        run.cancelled.set(true)
                        cancelBeforeExecution(run)
                        run.phase = Phase.TERMINAL
                        run.monitor.notifyAll()
                        runs.remove(token, run)
                        run.closeApproval()
                    } catch (_: Exception) {
                        try { run.markUnconfirmed(app) } catch (_: Exception) { /* Cold recovery inspects it. */ }
                        run.phase = Phase.TERMINAL
                        run.monitor.notifyAll()
                        runs.remove(token, run)
                        run.closeApproval()
                    }
                }
            }, 15, TimeUnit.SECONDS) }
            catch (failure: Exception) {
                runs.remove(token, run)
                try { cancelBeforeExecution(run) }
                catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
                finally { run.closeApproval() }
                throw failure
            }
            JSONObject().put("runId", runId).put("token", token)
        }
    }

    private fun scopeNames(scope: JSONObject, key: String): Set<String> {
        val values = scope.getJSONArray(key)
        check(values.length() <= IsolatedCapabilityBroker.MAX_GRANTS)
        val names = (0 until values.length()).map { values.getString(it) }
        check(names.size == names.toSet().size)
        return names.toSet()
    }

    /** A bound Node port must stop accepting calls before a pre-execution CANCELLED receipt. */
    private fun cancelBeforeExecution(run: Run) {
        if (run.toolBound) {
            checkNotNull(toolTransport) { "Bound tool transport disappeared" }
            check(toolTransport.close(run.runId, run.token, 3000L)) {
                "Isolated tool callback retirement is unconfirmed"
            }
        }
        run.cancelBeforeExecution(app, beforeReceiptRetirement)
    }

    /** One already admitted, ungranted run may use a trusted Node-owned tool port. */
    fun bindTools(params: JSONObject): Boolean {
        val run = owned(params)
        checkNotNull(toolTransport) { "Isolated tool transport is unavailable" }
        synchronized(run.monitor) {
            check(run.phase == Phase.RESERVED && !run.cancelled.get() && !run.toolBound &&
                run.approvedPlan == null && run.filePolicy == null && run.networkPolicy == null) {
                "Tool port is not eligible for this isolated admission"
            }
            run.toolBound = true
        }
        return true
    }

    /** Blocks until the guest and Binder retirement are classified by the run controller. */
    fun execute(params: JSONObject): Boolean {
        val run = owned(params)
        synchronized(run.monitor) {
            if (run.phase == Phase.TERMINAL) return true
            check(run.phase == Phase.RESERVED) { "Run was already started" }
            check(run.kind != "ptc" || run.toolBound) { "PTC requires a reviewed ToolRuntime callback port" }
            run.phase = Phase.RUNNING
            run.expiry?.cancel(false)
        }
        try {
            run.result = IsolatedScriptRunController.run(app, run.runId,
                run.program, run.inputJson, run.deadlineMillis,
                BooleanSupplier { run.cancelled.get() }, hostPolicy = run.filePolicy,
                policyOwner = run.approvedPlan?.handle?.owner,
                networkPolicy = run.networkPolicy,
                toolTransport = if (run.toolBound) toolTransport else null,
                toolToken = if (run.toolBound) run.token else null,
                readOnlyPtc = run.kind == "ptc",
                reservation = run.reservation,
                approvedReservation = run.approvedReservation)
        } catch (failure: Exception) {
            run.cancelled.set(true)
            run.markUnconfirmed(app)
            throw failure
        } finally {
            synchronized(run.monitor) {
                run.phase = Phase.TERMINAL
                run.monitor.notifyAll()
            }
        }
        return true
    }

    /** Cancellation is joined before a terminal receipt or release can be observed. */
    fun cancel(params: JSONObject): Boolean {
        val run = owned(params)
        run.cancelled.set(true)
        synchronized(run.monitor) {
            if (run.phase == Phase.RESERVED) {
                run.expiry?.cancel(false)
                try { cancelBeforeExecution(run) }
                catch (failure: Exception) {
                    try { run.markUnconfirmed(app) }
                    catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
                    runs.remove(run.token, run)
                    run.closeApproval()
                    throw failure
                } finally {
                    run.phase = Phase.TERMINAL
                    run.monitor.notifyAll()
                }
            } else waitForTerminal(run)
        }
        return true
    }

    fun settle(params: JSONObject): JSONObject {
        val run = owned(params)
        synchronized(run.monitor) { check(run.phase == Phase.TERMINAL) { "Run is still active" } }
        val result = run.result
        val receipt = if (result == null) {
            // Pre-execution cancellation has no guest UID. All other missing results
            // are read from the durable terminal record after a failed dispatch.
            IsolatedScriptRunController.readReceipt(app, run.runId)
        } else null
        check(receipt?.state() != IsolatedScriptReceipt.State.ADMITTED) {
            "Isolated run admission has no durable terminal receipt"
        }
        return JSONObject().put("runId", run.runId)
            .put("state", result?.state?.name ?: receipt!!.state().name)
            .put("outputJson", result?.outputJson ?: JSONObject.NULL)
            .put("logsJson", result?.logsJson ?: receipt?.logsJson() ?: JSONObject.NULL)
            .put("detail", result?.detail ?: receipt?.detail() ?: JSONObject.NULL)
            .put("guestUid", result?.guestUid ?: JSONObject.NULL)
    }

    /** A released token cannot start or reveal the run again. */
    fun release(params: JSONObject): Boolean {
        val run = owned(params)
        cancel(params)
        synchronized(run.monitor) { check(run.phase == Phase.TERMINAL) }
        val terminal = run.result?.state ?: IsolatedScriptRunController.readReceipt(app, run.runId).state()
        check(terminal != IsolatedScriptReceipt.State.ADMITTED &&
            terminal != IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED &&
            terminal != IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED) {
            "Isolated guest retirement still needs inspection"
        }
        check(runs.remove(run.token, run)) { "Run ownership changed during release" }
        run.expiry?.cancel(false)
        run.closeApproval()
        return true
    }

    private fun owned(params: JSONObject): Run {
        require(params.keys().asSequence().toSet() == setOf("runId", "token"))
        val token = params.getString("token")
        val run = checkNotNull(runs[token]) { "Isolated run owner is absent" }
        check(run.runId == params.getString("runId")) { "Isolated run identity changed" }
        return run
    }

    private fun waitForTerminal(run: Run) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(11)
        while (run.phase != Phase.TERMINAL) {
            val left = end - System.nanoTime()
            check(left > 0) { "Isolated guest retirement is unconfirmed" }
            run.monitor.wait(minOf(250L, maxOf(1L, TimeUnit.NANOSECONDS.toMillis(left))))
        }
    }
}
