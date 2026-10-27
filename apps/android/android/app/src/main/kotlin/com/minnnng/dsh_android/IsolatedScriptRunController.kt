package com.minnnng.dsh_android

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.system.Os
import android.system.OsConstants
import java.io.IOException
import java.io.File
import java.nio.file.Path
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executor
import java.util.function.BooleanSupplier

/** App-owned run controller. This is an internal compute primitive, never a model tool. */
internal object IsolatedScriptRunController {
    data class Result(
        val runId: String,
        val state: IsolatedScriptReceipt.State,
        val outputJson: String?,
        val logsJson: String?,
        val guestUid: Int?,
        val detail: String?,
    )

    private val runLock = Any()
    private val approvedOwners = IdentityHashMap<IsolatedExecutionPolicyOwner, IsolatedExecutionApprovalStore>()
    private val approvedRunIds = IdentityHashMap<IsolatedExecutionPolicyOwner, String>()
    private var restartRecovered = false

    /** A receipt admitted before an IPC reply; only this in-process owner may consume it. */
    class Reservation private constructor(
        val runId: String, private val appPath: String,
    ) {
        private val consumed = AtomicBoolean(false)

        internal fun consume(context: Context, expectedRunId: String) {
            check(runId == expectedRunId && appPath == context.filesDir.canonicalPath &&
                consumed.compareAndSet(false, true)) { "Script reservation is not owned or was already consumed" }
        }

        /** Retire an admitted run which never reached guest binding. */
        fun cancelBeforeExecution(context: Context) {
            consume(context.applicationContext, runId)
            IsolatedScriptReceipt(context.filesDir.toPath(), ::syncDirectory).finish(
                IsolatedScriptReceipt.Entry(runId, IsolatedScriptReceipt.State.CANCELLED, null, null),
            )
        }

        /** Preserve an uncertain result when binding or receipt publication throws. */
        fun markUnconfirmed(context: Context) {
            val receipts = IsolatedScriptReceipt(context.filesDir.toPath(), ::syncDirectory)
            if (receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED) {
                receipts.finish(IsolatedScriptReceipt.Entry(runId,
                    IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED, null,
                    "Script execution failed before retirement was confirmed"))
            }
        }

        companion object {
            internal fun create(context: Context, runId: String) =
                Reservation(runId, context.filesDir.canonicalPath)
        }
    }

    /** A policy lease and script receipt admitted together before the IPC response. */
    class ApprovedReservation internal constructor(
        val runId: String, private val appPath: String,
        val owner: IsolatedExecutionPolicyOwner,
        val lease: IsolatedExecutionPolicyOwner.Lease,
    ) {
        private val consumed = AtomicBoolean(false)
        internal fun consume(context: Context, expectedRunId: String) {
            check(runId == expectedRunId && appPath == context.filesDir.canonicalPath &&
                consumed.compareAndSet(false, true) && lease.active(lease.policy().version())) {
                "Approved script reservation is absent, spent, or revoked"
            }
        }
        fun cancelBeforeExecution(context: Context) {
            check(consumed.compareAndSet(false, true)) { "Approved reservation already consumed" }
            try {
                IsolatedScriptReceipt(context.filesDir.toPath(), ::syncDirectory).finish(
                    IsolatedScriptReceipt.Entry(runId, IsolatedScriptReceipt.State.CANCELLED, null, null))
            } finally { owner.revoke(runId) }
        }
        fun markUnconfirmed(context: Context) {
            try {
                val receipts = IsolatedScriptReceipt(context.filesDir.toPath(), ::syncDirectory)
                if (receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED)
                    receipts.finish(IsolatedScriptReceipt.Entry(runId,
                        IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED, null,
                        "Approved execution failed before retirement was confirmed"))
            } finally { owner.revoke(runId) }
        }
    }

    /** Trusted App approval only; admission and receipt publication share the run lock. */
    fun reserveApproved(context: Context, runId: String, handle: ApprovalHandle): ApprovedReservation {
        check(Looper.myLooper() != Looper.getMainLooper())
        val app = context.applicationContext
        check(Application.getProcessName() == app.packageName + ":agent")
        val scope = handle.approvedScopeForRun(runId)
        check(scope.readablePaths().isNotEmpty() || scope.exactHosts().isNotEmpty())
        synchronized(runLock) {
            val receipts = IsolatedScriptReceipt(app.filesDir.toPath(), ::syncDirectory)
            if (!restartRecovered) {
                receipts.recoverInterrupted()
                restartRecovered = true
            }
            val lease = handle.owner.admit(runId)
            try {
                check(lease.runId() == runId && lease.policy() === scope &&
                    lease.active(scope.version()) &&
                    receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED)
                return ApprovedReservation(runId, app.filesDir.canonicalPath, handle.owner, lease)
            } catch (failure: Exception) {
                handle.owner.revoke(runId)
                throw failure
            }
        }
    }

    /** Persist one fresh run ID before any guest execution or IPC admission response. */
    fun reserve(context: Context, runId: String): Reservation {
        check(Looper.myLooper() != Looper.getMainLooper())
        val app = context.applicationContext
        check(Application.getProcessName() == app.packageName + ":agent")
        synchronized(runLock) {
            val receipts = IsolatedScriptReceipt(app.filesDir.toPath(), ::syncDirectory)
            if (!restartRecovered) {
                receipts.recoverInterrupted()
                restartRecovered = true
            }
            receipts.admit(runId)
            return Reservation.create(app, runId)
        }
    }

    /** Read the durable terminal state after a failed or cancelled dispatch. */
    fun readReceipt(context: Context, runId: String): IsolatedScriptReceipt.Entry =
        IsolatedScriptReceipt(context.applicationContext.filesDir.toPath(), ::syncDirectory).read(runId)

    /** An App plan cannot be installed after this ID was already admitted as denied. */
    fun requireFreshRunId(context: Context, runId: String) {
        synchronized(runLock) {
            check(!IsolatedScriptReceipt(context.applicationContext.filesDir.toPath(),
                ::syncDirectory).hasEverAdmitted(runId)) { "Run ID was already admitted" }
        }
    }

    /** Burn a removed App approval even when validation fails before a lease can be reserved. */
    fun retireRejectedApprovedPlan(context: Context, runId: String) {
        check(Looper.myLooper() != Looper.getMainLooper())
        val app = context.applicationContext
        check(Application.getProcessName() == app.packageName + ":agent")
        synchronized(runLock) {
            val receipts = IsolatedScriptReceipt(app.filesDir.toPath(), ::syncDirectory)
            if (!restartRecovered) {
                receipts.recoverInterrupted()
                restartRecovered = true
            }
            if (!receipts.hasEverAdmitted(runId)) {
                receipts.admit(runId)
                receipts.finish(IsolatedScriptReceipt.Entry(runId,
                    IsolatedScriptReceipt.State.CANCELLED, null,
                    "App-approved plan was rejected before guest execution"))
            } else if (receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED) {
                // A failed owner admission may have written the receipt before it threw.
                // Treat that partial path as uncertain; never claim a guest was retired.
                receipts.finish(IsolatedScriptReceipt.Entry(runId,
                    IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED, null,
                    "App-approved plan admission failed before retirement was confirmed"))
            }
        }
    }

    private data class Admission(
        val receipts: IsolatedScriptReceipt,
        val lease: IsolatedExecutionPolicyOwner.Lease?,
        val cancelled: BooleanSupplier,
        val host: IsolatedScriptCallbacks?,
    )

    /** Holds the durable policy writer for one App-owned Session; close revokes every live lease. */
    class ApprovalHandle internal constructor(
        val owner: IsolatedExecutionPolicyOwner,
        private val store: IsolatedExecutionApprovalStore,
    ) : AutoCloseable {
        /** Only the exact App-approved run may consume this durable policy. */
        fun approvedScopeForRun(runId: String): IsolatedExecutionPolicyOwner.Scope {
            synchronized(approvedOwners) {
                check(approvedOwners[owner] === store && approvedRunIds[owner] == runId) {
                    "No App-owned approval for this isolated run"
                }
                return owner.current()
            }
        }
        /** The only grant API binds one exact run before exposing any capability. */
        fun approveTrustedUiChoiceForRun(
            next: IsolatedExecutionPolicyOwner.Scope, approvalId: String, runId: String,
        ) {
            IsolatedScriptWire.requireUuid(runId)
            synchronized(approvedOwners) {
                check(approvedOwners[owner] === store && !approvedRunIds.containsKey(owner))
                approvedRunIds[owner] = runId
            }
            store.prepareTrustedUiApproval(next, approvalId)
            owner.replace(next)
        }

        override fun close() {
            try { store.close() }
            finally { synchronized(approvedOwners) {
                approvedOwners.remove(owner)
                approvedRunIds.remove(owner)
            } }
        }
    }

    /** Open a previously selected App-private history; restart recovers only a denied policy. */
    fun newPolicyOwner(
        context: Context, directory: File, ownerId: String, sessionId: String,
    ): ApprovalHandle {
        val app = context.applicationContext
        val store = IsolatedExecutionApprovalStore(
            File(app.applicationInfo.dataDir).toPath(), directory.toPath(),
            ownerId, sessionId, ::syncDirectory,
        )
        try {
            val owner = store.newOwner(IsolatedExecutionPolicyOwner.DurableAdmission { runId, _ ->
                IsolatedScriptReceipt(app.filesDir.toPath(), ::syncDirectory).admit(runId)
            })
            synchronized(approvedOwners) { approvedOwners[owner] = store }
            return ApprovalHandle(owner, store)
        } catch (failure: Exception) {
            try { store.close() } catch (close: Exception) { failure.addSuppressed(close) }
            throw failure
        }
    }

    /** Caller persists runId before calling; reusing it after any outcome is refused. */
    @Throws(IOException::class)
    fun run(
        context: Context, runId: String, program: String, inputJson: String,
        deadlineMillis: Int, cancelled: BooleanSupplier,
        hostPolicy: IsolatedScriptHostBridge.Policy? = null,
        policyOwner: IsolatedExecutionPolicyOwner? = null,
        networkPolicy: IsolatedScriptHostBridge.NetworkPolicy? = null,
        toolTransport: IsolatedScriptToolBridge.Transport? = null,
        toolToken: String? = null,
        workflowTransport: IsolatedWorkflowCallbackBridge.Transport? = null,
        workflowToken: String? = null,
        workflowOwner: DurableWorkflowOwner? = null,
        reservation: Reservation? = null,
        approvedReservation: ApprovedReservation? = null,
        reviewedPtc: Boolean = false,
        workflowBody: String? = null,
    ): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Script binding and audit must run off the main thread" }
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Per-run isolated service instances require Android 10 or newer"
        }
        val app = context.applicationContext
        check(Application.getProcessName() == app.packageName + ":agent") {
            "Script runs and receipt recovery belong to the agent process"
        }
        check(!reviewedPtc || (toolTransport != null && toolToken != null &&
            workflowTransport == null && workflowToken == null && workflowOwner == null &&
            hostPolicy == null && networkPolicy == null && policyOwner == null && approvedReservation == null)) {
            "Android PTC requires only its reviewed ToolRuntime callbacks"
        }
        check(workflowBody == null || workflowTransport != null) {
            "A separate workflow body requires its App-owned callback owner"
        }
        if (reviewedPtc) PtcScriptEngine.validatePtc(program, inputJson, deadlineMillis)
        else if (workflowTransport != null) PtcScriptEngine.validateWorkflow(program, inputJson, deadlineMillis)
        else PtcScriptEngine.validate(program, inputJson, deadlineMillis)
        val request = IsolatedScriptWire.Request(
            runId, UUID.randomUUID().toString(), program, inputJson, deadlineMillis,
            if (workflowBody != null) IsolatedScriptWire.WORKFLOW_DRIVER
            else if (reviewedPtc) IsolatedScriptWire.FUNCTION_BODY else IsolatedScriptWire.FUNCTION_EXPRESSION,
            workflowBody,
        )
        check((hostPolicy != null || networkPolicy != null) == (policyOwner != null) &&
            (toolTransport == null) == (toolToken == null) &&
            (workflowTransport == null) == (workflowToken == null && workflowOwner == null) &&
            (toolTransport == null || (hostPolicy == null && networkPolicy == null && policyOwner == null)) &&
            (workflowTransport == null || (toolTransport == null && hostPolicy == null &&
                networkPolicy == null && policyOwner == null))) {
            "Host capabilities require an App-owned execution policy lease"
        }
        check(reservation == null || policyOwner == null)
        check(approvedReservation == null || (reservation == null && approvedReservation.owner === policyOwner))
        if (policyOwner != null) synchronized(approvedOwners) {
            check(approvedOwners.containsKey(policyOwner)) {
                "Host capabilities require a controller-owned durable approval history"
            }
            check(approvedRunIds[policyOwner] == runId) {
                "Approved host capability belongs to a different run"
            }
        }
        // Recovery and durable admission are serialized. Binding and waiting for this
        // guest must not hold the admission lock: independent workflow children can run
        // concurrently and each service instance has its own callback thread and UID.
        val admission = synchronized(runLock) {
            val receipts = IsolatedScriptReceipt(app.filesDir.toPath(), ::syncDirectory)
            if (!restartRecovered) {
                receipts.recoverInterrupted()
                restartRecovered = true
            }
            val lease = if (approvedReservation != null) {
                approvedReservation.consume(app, runId)
                check(receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED)
                approvedReservation.lease
            } else if (policyOwner == null) {
                if (reservation == null) receipts.admit(runId)
                else {
                    reservation.consume(app, runId)
                    check(receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED)
                }
                null
            } else {
                policyOwner.admit(runId).let { admitted ->
                    try {
                        check(admitted.runId() == runId && admitted.active(admitted.policy().version()))
                        // A caller-provided owner cannot substitute an in-memory admission callback.
                        check(receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED) {
                            "Policy admission did not durably reserve the script receipt"
                        }
                    } catch (failure: Exception) {
                        policyOwner.revoke(runId)
                        throw failure
                    }
                    admitted
                }
            }
            val effectiveCancelled = BooleanSupplier {
                cancelled.asBoolean || (lease != null && !lease.active(lease.policy().version()))
            }
            val host = try {
                if (workflowTransport != null)
                    IsolatedWorkflowCallbackBridge(request, checkNotNull(workflowToken),
                        checkNotNull(workflowOwner), effectiveCancelled, workflowTransport)
                else if (toolTransport != null)
                    IsolatedScriptToolBridge(request, checkNotNull(toolToken), effectiveCancelled,
                        toolTransport, reviewedPtc)
                else if (hostPolicy != null || networkPolicy != null)
                    IsolatedScriptHostBridge(app, request, hostPolicy, networkPolicy,
                        checkNotNull(lease), effectiveCancelled)
                else null
            } catch (failure: Exception) {
                try { receipts.finish(IsolatedScriptReceipt.Entry(
                    runId, IsolatedScriptReceipt.State.ERROR, null, "Host capability admission failed",
                )) } finally { policyOwner?.revoke(runId) }
                throw failure
            }
            Admission(receipts, lease, effectiveCancelled, host)
        }
        try {
            return execute(app, request, admission.receipts, admission.cancelled,
                admission.host, policyOwner, admission.lease)
        } finally { policyOwner?.revoke(runId) }
    }

    private class Pending(
        val request: IsolatedScriptWire.Request,
        val host: IsolatedScriptCallbacks?,
    ) {
        val monitor = java.lang.Object()
        var bound = false
        var active = true
        var guest: Messenger? = null
        var binder: IBinder? = null
        var death: IBinder.DeathRecipient? = null
        var dead = false
        var rejected: String? = null
        var proposal: IsolatedScriptWire.Reply? = null
        var guestUid: Int? = null
        var cancelled = false
        var cancelSent = false

        fun signal() = monitor.notifyAll()
    }

    private fun execute(
        app: Context, request: IsolatedScriptWire.Request,
        receipts: IsolatedScriptReceipt, cancelled: BooleanSupplier,
        host: IsolatedScriptCallbacks?,
        policyOwner: IsolatedExecutionPolicyOwner?,
        policyLease: IsolatedExecutionPolicyOwner.Lease?,
    ): Result {
        val pending = Pending(request, host)
        val callbackThread = HandlerThread("isolated-script-${request.runId()}")
        callbackThread.start()
        val callbackHandler = Handler(callbackThread.looper)
        val callbackExecutor = Executor { command -> callbackHandler.post(command) }
        val reply = Messenger(Handler(callbackThread.looper) { message ->
            synchronized(pending.monitor) {
                if (!pending.active) return@Handler true
                try {
                    check(message.what == IsolatedScriptWire.RESULT ||
                        message.what == IsolatedScriptWire.HOST_CALL)
                    val data = message.data
                    check(data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION)
                    val sender = message.sendingUid
                    val claimed = data.getInt(IsolatedScriptWire.KEY_UID, -1)
                    check(sender >= 0 && sender != Process.myUid() && sender == claimed)
                    check(pending.guestUid == null || pending.guestUid == sender)
                    check(pending.proposal == null && !pending.dead && pending.rejected == null)
                    if (message.what == IsolatedScriptWire.HOST_CALL) {
                        val boundGuest = checkNotNull(pending.guest)
                        val fileHost = checkNotNull(pending.host) { "Script has no file capability lease" }
                        fileHost.call(message, boundGuest) { detail ->
                            synchronized(pending.monitor) {
                                if (pending.active) {
                                    pending.rejected = detail
                                    try { sendControl(pending, IsolatedScriptWire.CANCEL) }
                                    catch (_: Exception) { /* Binder death remains the retirement signal. */ }
                                    pending.signal()
                                }
                            }
                        }
                        pending.guestUid = sender
                        return@Handler true
                    }
                    check(data.keySet() == setOf(
                        IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN,
                        IsolatedScriptWire.KEY_NONCE, IsolatedScriptWire.KEY_STATUS,
                        IsolatedScriptWire.KEY_OUTPUT, IsolatedScriptWire.KEY_LOGS,
                        IsolatedScriptWire.KEY_DETAIL,
                        IsolatedScriptWire.KEY_UID,
                    ))
                    val status = PtcScriptEngine.Status.valueOf(checkNotNull(data.getString(IsolatedScriptWire.KEY_STATUS)))
                    val proposal = IsolatedScriptWire.Reply(
                        checkNotNull(data.getString(IsolatedScriptWire.KEY_RUN)),
                        checkNotNull(data.getString(IsolatedScriptWire.KEY_NONCE)), status,
                        data.getString(IsolatedScriptWire.KEY_OUTPUT),
                        data.getString(IsolatedScriptWire.KEY_LOGS),
                        data.getString(IsolatedScriptWire.KEY_DETAIL),
                    )
                    check(proposal.runId() == request.runId() && proposal.nonce() == request.nonce())
                    pending.host?.proposedResult(sender, claimed)
                    pending.guestUid = sender
                    pending.proposal = proposal
                    sendControl(pending, IsolatedScriptWire.RETIRE)
                } catch (_: Exception) {
                    pending.rejected = "Guest result or retirement request was rejected"
                    pending.host?.cancel()
                    try { sendControl(pending, IsolatedScriptWire.CANCEL) }
                    catch (_: Exception) { /* The bound guest may already be gone. */ }
                }
                pending.signal()
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                synchronized(pending.monitor) {
                    if (!pending.active) return
                    try {
                        val death = IBinder.DeathRecipient {
                            synchronized(pending.monitor) {
                                pending.dead = true
                                pending.signal()
                            }
                        }
                        pending.binder = binder
                        binder.linkToDeath(death, 0)
                        pending.death = death
                        if (pending.cancelled) {
                            pending.guest = Messenger(binder)
                            pending.cancelSent = true
                            sendControl(pending, IsolatedScriptWire.CANCEL)
                        } else {
                            pending.guest = Messenger(binder)
                            pending.guest?.send(Message.obtain(null, IsolatedScriptWire.RUN).apply {
                                replyTo = reply
                                data = Bundle().apply {
                                    putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                                    putString(IsolatedScriptWire.KEY_RUN, request.runId())
                                    putString(IsolatedScriptWire.KEY_NONCE, request.nonce())
                                    putString(IsolatedScriptWire.KEY_PROGRAM, request.program())
                                    putString(IsolatedScriptWire.KEY_PROGRAM_FORMAT, request.programFormat())
                                    request.workflowBody()?.let {
                                        putString(IsolatedScriptWire.KEY_WORKFLOW_BODY, it)
                                    }
                                    putString(IsolatedScriptWire.KEY_INPUT, request.inputJson())
                                    putInt(IsolatedScriptWire.KEY_DEADLINE, request.deadlineMillis())
                                    pending.host?.let {
                                        putString(IsolatedScriptWire.KEY_HOST_GRANTS, it.grantsJson)
                                    }
                                }
                            })
                        }
                    } catch (_: Exception) {
                        pending.rejected = "Could not start isolated guest"
                        if (!binder.isBinderAlive) pending.dead = true
                    }
                    pending.signal()
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                synchronized(pending.monitor) {
                    if (!pending.dead && pending.proposal == null) {
                        pending.rejected = "Guest disconnected before confirmed retirement"
                    }
                    pending.signal()
                }
            }
            override fun onBindingDied(name: ComponentName) {
                synchronized(pending.monitor) {
                    if (!pending.dead && pending.proposal == null) pending.rejected = "Guest binding died"
                    pending.signal()
                }
            }
            override fun onNullBinding(name: ComponentName) {
                synchronized(pending.monitor) {
                    pending.rejected = "Guest returned no Binder"
                    pending.signal()
                }
            }
        }

        val end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(request.deadlineMillis().toLong() + 3000L)
        var cleanupFailure: String? = null
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw IllegalStateException("Per-run isolated service instances require Android 10 or newer")
            }
            val instance = "script_" + request.runId().replace("-", "")
            pending.bound = app.bindIsolatedService(
                Intent(app, IsolatedScriptService::class.java), Context.BIND_AUTO_CREATE,
                instance, callbackExecutor, connection,
            )
            if (!pending.bound) pending.rejected = "Isolated guest binding was refused"
            synchronized(pending.monitor) {
                while (pending.bound && !pending.dead && !(pending.rejected != null && pending.binder == null)) {
                    if (cancelled.asBoolean || Thread.currentThread().isInterrupted) {
                        pending.cancelled = true
                        pending.host?.cancel()
                        if (!pending.cancelSent && pending.guest != null) {
                            pending.cancelSent = true
                            try { sendControl(pending, IsolatedScriptWire.CANCEL) }
                            catch (_: Exception) { /* Binder death remains the retirement signal. */ }
                        }
                    }
                    val left = end - System.nanoTime()
                    if (left <= 0) {
                        pending.rejected = pending.rejected ?: "Guest exceeded total bind, execution and retirement deadline"
                        pending.host?.cancel()
                        try { sendControl(pending, IsolatedScriptWire.CANCEL) }
                        catch (_: Exception) { /* Unbind below remains mandatory. */ }
                        break
                    }
                    pending.monitor.wait(minOf(50L, maxOf(1L, TimeUnit.NANOSECONDS.toMillis(left))))
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            synchronized(pending.monitor) {
                pending.cancelled = true
                pending.host?.cancel()
                try { sendControl(pending, IsolatedScriptWire.CANCEL) }
                catch (_: Exception) { /* Unbind below remains mandatory. */ }
            }
        } catch (_: Exception) {
            synchronized(pending.monitor) { pending.rejected = "Isolated guest request failed" }
        } finally {
            synchronized(pending.monitor) { pending.active = false }
            if (pending.bound) try { app.unbindService(connection) }
            catch (_: Exception) { cleanupFailure = "Guest binding cleanup failed" }
            val binder = pending.binder
            val death = pending.death
            if (binder != null && death != null) binder.unlinkToDeath(death, 0)
            callbackThread.quitSafely()
            try { callbackThread.join(1000L) }
            catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                cleanupFailure = "Guest callback cleanup was interrupted"
            }
            if (callbackThread.isAlive) cleanupFailure = "Guest callback cleanup did not finish"
        }

        val state: IsolatedScriptReceipt.State
        val output: String?
        val logs: String?
        val detail: String?
        synchronized(pending.monitor) {
            val proposal = pending.proposal
            state = IsolatedScriptRetirement.classify(
                pending.bound, pending.binder != null, pending.dead, cleanupFailure == null,
                pending.cancelled, pending.rejected != null, proposal?.status(),
            )
            output = if (state == IsolatedScriptReceipt.State.COMPLETED) proposal?.outputJson() else null
            logs = if (state == IsolatedScriptReceipt.State.COMPLETED) proposal?.logsJson() else null
            detail = when {
                cleanupFailure != null -> cleanupFailure
                state == IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED -> "Guest death was not confirmed"
                pending.rejected != null -> pending.rejected
                state == IsolatedScriptReceipt.State.ERROR -> proposal?.status()?.name ?: "Guest did not complete"
                else -> null
            }
        }
        val hostRetirement = try {
            host?.retire(state == IsolatedScriptReceipt.State.COMPLETED)
                ?: IsolatedScriptHostBridge.Retirement.COMPLETED
        } catch (_: Exception) {
            IsolatedScriptHostBridge.Retirement.UNCONFIRMED
        }
        val finalState = when {
            hostRetirement == IsolatedScriptHostBridge.Retirement.UNCONFIRMED ->
                IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED
            state == IsolatedScriptReceipt.State.COMPLETED &&
                hostRetirement != IsolatedScriptHostBridge.Retirement.COMPLETED ->
                IsolatedScriptReceipt.State.ERROR
            else -> state
        }
        val finalOutput = if (finalState == IsolatedScriptReceipt.State.COMPLETED) output else null
        val finalLogs = if (finalState == IsolatedScriptReceipt.State.COMPLETED) logs else null
        val finalDetail = when {
            hostRetirement == IsolatedScriptHostBridge.Retirement.UNCONFIRMED ->
                "Host callback or capability audit did not settle; inspect run effects"
            finalState != state -> "Host callback or capability cleanup was not confirmed"
            else -> detail
        }
        // Policy replacement and final durable result publication share the owner's monitor.
        // A revoked lease never publishes a successful result, including during this last sync.
        return synchronized(policyOwner ?: runLock) {
            val active = policyLease?.active(policyLease.policy().version()) ?: true
            val stateForReceipt = if (!active && finalState == IsolatedScriptReceipt.State.COMPLETED)
                IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED else finalState
            val outputForReceipt = if (stateForReceipt == IsolatedScriptReceipt.State.COMPLETED)
                finalOutput else null
            val logsForReceipt = if (stateForReceipt == IsolatedScriptReceipt.State.COMPLETED)
                finalLogs else null
            val detailForReceipt = if (stateForReceipt != finalState)
                "Execution policy changed before result publication; inspect file effects" else finalDetail
            // This write is the completion barrier; failure leaves ADMITTED for recovery.
            receipts.finish(IsolatedScriptReceipt.Entry(
                request.runId(), stateForReceipt, outputForReceipt, logsForReceipt, detailForReceipt,
            ))
            Result(request.runId(), stateForReceipt, outputForReceipt, logsForReceipt,
                pending.guestUid, detailForReceipt)
        }
    }

    private fun sendControl(pending: Pending, what: Int) {
        pending.guest?.send(Message.obtain(null, what).apply {
            data = Bundle().apply {
                putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                putString(IsolatedScriptWire.KEY_RUN, pending.request.runId())
                putString(IsolatedScriptWire.KEY_NONCE, pending.request.nonce())
            }
        })
    }

    internal fun syncDirectory(directory: Path) {
        try {
            val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0)
            try {
                check(OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode))
                Os.fsync(descriptor)
            } finally { Os.close(descriptor) }
        } catch (failure: Exception) { throw IOException("Could not sync isolated script receipts", failure) }
    }
}
