package com.minnnng.dsh_android

import android.content.Context
import android.os.Looper
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.BooleanSupplier

/**
 * App-owned, ungranted workflow admission. The model-facing workflow tool is
 * disabled. In particular, this bridge refuses child callbacks until an
 * App-owned confined child backend can durably account for each child.
 */
internal class IsolatedWorkflowRunNativeBridge(
    context: Context,
    private val transport: IsolatedWorkflowCallbackBridge.Transport,
) {
    private val app = context.applicationContext
    private val lock = Any()
    @Volatile private var closing = false
    private val runs = ConcurrentHashMap<String, Run>()
    private val owner = DurableWorkflowOwner(app.filesDir.toPath(),
        IsolatedScriptRunController::syncDirectory)
    private val processLease = WorkflowProcessLease.current(app.filesDir.toPath(),
        IsolatedScriptRunController::syncDirectory)
    // Reconcile before Node starts, including when one stranded child blocks
    // future workflow admission. The bridge itself remains available for audit.
    private val coldRecovery = owner.recoverInterrupted(processLease)
    data class StartupRecovery(val newlyInterruptedRuns: Int, val unretiredChildren: Int)
    fun startupRecovery() = StartupRecovery(coldRecovery.size,
        coldRecovery.sumOf { it.childIdsToCancel().size })

    private enum class Phase { ADMITTED, RUNNING, TERMINAL }
    private class Run(
        val runId: String, val token: String, val sessionId: String,
        val program: String, val inputJson: String, val deadlineMillis: Int,
        val workflowBody: String?,
        val reservation: IsolatedScriptRunController.Reservation,
    ) {
        val monitor = java.lang.Object()
        val cancelled = AtomicBoolean(false)
        var phase = Phase.ADMITTED
        var bound = false
        var result: IsolatedScriptRunController.Result? = null
    }

    fun admit(params: JSONObject): JSONObject {
        val workflowKeys = if (params.has("workflowBody")) setOf("workflowBody") else emptySet()
        require(params.keys().asSequence().toSet() == setOf(
            "kind", "runId", "sessionId", "program", "inputJson", "deadlineMillis") + workflowKeys)
        require(listOf("kind", "runId", "sessionId", "program", "inputJson")
            .all { params.get(it) is String } && params.get("deadlineMillis") is Int)
        require(params.getString("kind") == "workflow")
        val runId = params.getString("runId").also(IsolatedScriptWire::requireUuid)
        val sessionId = params.getString("sessionId").also(IsolatedScriptWire::requireSessionId)
        val program = params.getString("program")
        val inputJson = params.getString("inputJson")
        val deadline = params.getInt("deadlineMillis")
        val workflowBody = if (params.has("workflowBody")) {
            require(params.get("workflowBody") is String)
            params.getString("workflowBody").also {
                PtcScriptEngine.validateWorkflow(it, "{}", deadline)
                IsolatedScriptWire.utf8Bytes(it)
            }
        } else null
        require(deadline in 1..PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS)
        PtcScriptEngine.validateWorkflow(program, inputJson, deadline)
        synchronized(lock) {
            check(!closing) { "Workflow bridge is closing" }
            check(coldRecovery.all { recovered ->
                val old = owner.read(recovered.runId())
                old.state() != DurableWorkflowOwner.State.ADMITTED &&
                    old.state() != DurableWorkflowOwner.State.CANCEL_REQUESTED && old.children().all {
                    it.state() == DurableWorkflowOwner.ChildState.RETIRED
                }
            }) { "Workflow children require confirmed cold-start retirement" }
            check(runs.size < 4) { "Workflow admission capacity reached" }
            val script = IsolatedScriptRunController.reserve(app, runId)
            try { owner.admit(runId, processLease) }
            catch (failure: Exception) {
                try { script.cancelBeforeExecution(app) }
                catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
                throw failure
            }
            val token = UUID.randomUUID().toString()
            runs[token] = Run(runId, token, sessionId, program, inputJson, deadline, workflowBody, script)
            return JSONObject().put("runId", runId).put("token", token)
        }
    }

    /** Node must first install an exact, bounded callback port under this token. */
    fun bindCallbacks(params: JSONObject): Boolean {
        val run = owned(params)
        synchronized(run.monitor) {
            check(run.phase == Phase.ADMITTED && !run.cancelled.get() && !run.bound &&
                owner.read(run.runId).state() == DurableWorkflowOwner.State.ADMITTED)
            run.bound = true
        }
        return true
    }

    fun execute(params: JSONObject): Boolean {
        val run = owned(params)
        synchronized(run.monitor) {
            check(run.phase == Phase.ADMITTED && run.bound && !run.cancelled.get())
            run.phase = Phase.RUNNING
        }
        try {
            run.result = IsolatedScriptRunController.run(app, run.runId, run.program,
                run.inputJson, run.deadlineMillis, BooleanSupplier { run.cancelled.get() },
                workflowTransport = transport, workflowToken = run.token,
                workflowOwner = owner, reservation = run.reservation, workflowBody = run.workflowBody)
            settleOwner(run)
        } catch (failure: Exception) {
            run.cancelled.set(true)
            try { run.reservation.markUnconfirmed(app) }
            catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
            try { owner.markUnconfirmed(run.runId) }
            catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
            throw failure
        } finally {
            synchronized(run.monitor) {
                run.phase = Phase.TERMINAL
                run.monitor.notifyAll()
            }
        }
        return true
    }

    fun cancel(params: JSONObject): Boolean {
        val run = owned(params)
        synchronized(run.monitor) {
            if (run.phase == Phase.TERMINAL) return true
            owner.requestCancel(run.runId) { run.cancelled.set(true) }
            if (run.phase == Phase.ADMITTED) {
                try {
                    if (run.bound) check(transport.close(run.runId, run.token, 3000L)) {
                        "Workflow callbacks did not retire"
                    }
                    run.reservation.cancelBeforeExecution(app)
                    owner.confirmCancelled(run.runId, scriptReceipts())
                } catch (failure: Exception) {
                    try { run.reservation.markUnconfirmed(app) }
                    catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
                    try { owner.markUnconfirmed(run.runId) }
                    catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
                    throw failure
                } finally {
                    run.phase = Phase.TERMINAL
                    run.monitor.notifyAll()
                }
            } else waitTerminal(run)
        }
        return true
    }

    fun settle(params: JSONObject): JSONObject {
        val run = owned(params)
        synchronized(run.monitor) { check(run.phase == Phase.TERMINAL) }
        val receipt = owner.read(run.runId)
        check(receipt.state() != DurableWorkflowOwner.State.ADMITTED &&
            receipt.state() != DurableWorkflowOwner.State.CANCEL_REQUESTED)
        return JSONObject().put("runId", run.runId).put("sessionId", run.sessionId)
            .put("state", receipt.state().name).put("outputJson", receipt.outputJson() ?: JSONObject.NULL)
            .put("requiresReview", receipt.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
    }

    /** Bounded read of the App-private receipt after a Node or App process restart. */
    fun inspect(params: JSONObject): JSONObject {
        require(params.keys().asSequence().toSet() == setOf("runId"))
        require(params.get("runId") is String)
        val runId = params.getString("runId").also(IsolatedScriptWire::requireUuid)
        val receipt = owner.read(runId)
        val children = org.json.JSONArray()
        receipt.children().forEach { child ->
            children.put(JSONObject().put("childId", child.id())
                .put("state", child.state().name))
        }
        return JSONObject().put("runId", runId).put("state", receipt.state().name)
            .put("children", children)
    }

    fun release(params: JSONObject): Boolean {
        val run = owned(params)
        cancel(params)
        synchronized(run.monitor) { check(run.phase == Phase.TERMINAL) }
        check(owner.read(run.runId).state() != DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED) {
            "Workflow effects still require inspection"
        }
        return runs.remove(run.token, run)
    }

    fun close() {
        val current = synchronized(lock) {
            closing = true
            runs.values.toList().also { entries -> entries.forEach { it.cancelled.set(true) } }
        }
        if (current.isEmpty()) return
        // Service.onDestroy runs on the main thread. Cold recovery preserves any
        // run whose asynchronous cleanup is interrupted by process death.
        Thread({
            current.forEach { run ->
                try { cancel(JSONObject().put("runId", run.runId).put("token", run.token)) }
                catch (_: Exception) { try { owner.markUnconfirmed(run.runId) } catch (_: Exception) {} }
            }
        }, "dsh-workflow-close").apply { isDaemon = true }.start()
    }

    private fun settleOwner(run: Run) {
        when (run.result?.state) {
            IsolatedScriptReceipt.State.COMPLETED -> {
                when (guestOutcome(run.result?.outputJson)) {
                    GuestOutcome.COMPLETED -> owner.complete(run.runId, scriptReceipts())
                    GuestOutcome.FAILED -> owner.confirmGuestReportedFailure(run.runId, scriptReceipts())
                    GuestOutcome.UNCONFIRMED -> owner.markUnconfirmed(run.runId)
                }
            }
            IsolatedScriptReceipt.State.CANCELLED -> {
                if (owner.read(run.runId).state() == DurableWorkflowOwner.State.ADMITTED)
                    owner.requestCancel(run.runId)
                owner.confirmCancelled(run.runId, scriptReceipts())
            }
            IsolatedScriptReceipt.State.ERROR,
            IsolatedScriptReceipt.State.TIMED_OUT,
            IsolatedScriptReceipt.State.WORKER_DIED -> owner.confirmFailed(run.runId, scriptReceipts())
            else -> owner.markUnconfirmed(run.runId)
        }
    }

    private enum class GuestOutcome { COMPLETED, FAILED, UNCONFIRMED }

    /** Only the fixed DSL result shape may become a durable workflow success. */
    private fun guestOutcome(output: String?): GuestOutcome {
        if (output == null) return GuestOutcome.UNCONFIRMED
        val report = try { JSONObject(output) }
        catch (_: Exception) { return GuestOutcome.UNCONFIRMED }
        val base = setOf("value", "stopReason", "agentsStarted")
        val count = report.opt("agentsStarted")
        if (!report.has("value") || count !is Int || count !in 0..128)
            return GuestOutcome.UNCONFIRMED
        return when (report.opt("stopReason")) {
            "completed" -> if (report.keys().asSequence().toSet() == base)
                GuestOutcome.COMPLETED else GuestOutcome.UNCONFIRMED
            "error" -> {
                val error = report.opt("error")
                if (report.keys().asSequence().toSet() != base + "error"
                    || !report.isNull("value") || error !is JSONObject
                    || error.keys().asSequence().toSet() != setOf("name", "code", "message")
                    || listOf("name", "code", "message").any { error.opt(it) !is String }) {
                    GuestOutcome.UNCONFIRMED
                } else GuestOutcome.FAILED
            }
            else -> GuestOutcome.UNCONFIRMED
        }
    }

    private fun scriptReceipts() = IsolatedScriptReceipt(app.filesDir.toPath(),
        IsolatedScriptRunController::syncDirectory)

    private fun owned(params: JSONObject): Run {
        require(params.keys().asSequence().toSet() == setOf("runId", "token"))
        val run = checkNotNull(runs[params.getString("token")]) { "Workflow owner is absent" }
        check(run.runId == params.getString("runId")) { "Workflow run identity changed" }
        return run
    }

    private fun waitTerminal(run: Run) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(11)
        while (run.phase != Phase.TERMINAL) {
            val left = end - System.nanoTime()
            check(left > 0) { "Workflow retirement is unconfirmed" }
            run.monitor.wait(minOf(250L, maxOf(1L, TimeUnit.NANOSECONDS.toMillis(left))))
        }
    }
}
