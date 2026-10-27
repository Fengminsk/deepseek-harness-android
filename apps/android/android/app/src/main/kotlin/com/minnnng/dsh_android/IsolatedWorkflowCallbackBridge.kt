package com.minnnng.dsh_android

import android.os.Bundle
import android.os.Message
import android.os.Messenger
import android.os.Process
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.CancellationException
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.function.BooleanSupplier

/**
 * App-side Binder relay for one separately admitted workflow. Construction and
 * binding are deliberately absent from the script admission path: the caller
 * must first own a durable workflow receipt and a confined child backend.
 */
internal class IsolatedWorkflowCallbackBridge(
    private val request: IsolatedScriptWire.Request,
    private val token: String,
    private val workflowOwner: DurableWorkflowOwner,
    private val cancelled: BooleanSupplier,
    private val transport: Transport,
) : IsolatedScriptCallbacks {
    interface Transport {
        fun call(params: JSONObject, timeoutMillis: Long): JSONObject
        /** Must join Node child retirement before returning true. */
        fun close(runId: String, token: String, timeoutMillis: Long): Boolean
    }

    override val grantsJson = "[]"
    init {
        IsolatedScriptWire.requireUuid(token)
        check(workflowOwner.read(request.runId()).state() == DurableWorkflowOwner.State.ADMITTED) {
            "Workflow callback needs a durable admitted owner"
        }
    }
    private val gate = Any()
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-workflow-guest-callback").apply { isDaemon = true }
    }
    private val closer = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-workflow-guest-close").apply { isDaemon = true }
    }
    private val deadlineNanos = System.nanoTime() +
        TimeUnit.MILLISECONDS.toNanos(request.deadlineMillis().toLong() + 3000L)
    private var attachedUid = -1
    private var lastSequence = 0
    private val outstanding = mutableSetOf<Int>()
    /** Node child call ID to the App's durable, single-use child identity. */
    private val childCalls = mutableMapOf<Int, String>()
    private var closed = false
    private var uncertain = false
    private var closeFuture: Future<Boolean>? = null

    override fun call(message: Message, guest: Messenger, reject: (String) -> Unit) {
        val sender = message.sendingUid
        val data = message.data
        require(data.keySet() == setOf(
            IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN,
            IsolatedScriptWire.KEY_NONCE, IsolatedScriptWire.KEY_HOST_SEQUENCE,
            IsolatedScriptWire.KEY_HOST_REQUEST, IsolatedScriptWire.KEY_UID,
        ))
        require(data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION)
        val envelope = IsolatedScriptWire.HostRequest(
            checkNotNull(data.getString(IsolatedScriptWire.KEY_RUN)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_NONCE)),
            data.getInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, -1),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_HOST_REQUEST)),
        )
        require(envelope.runId() == request.runId() && envelope.nonce() == request.nonce())
        val parsed = IsolatedWorkflowRequest.parse(envelope.requestJson())
        synchronized(gate) {
            check(!closed && !cancelled.asBoolean && withinDeadline() &&
                workflowOwner.read(request.runId()).state() == DurableWorkflowOwner.State.ADMITTED)
            check(sender >= 0 && sender != Process.myUid() &&
                sender == data.getInt(IsolatedScriptWire.KEY_UID, -1))
            if (attachedUid == -1) attachedUid = sender else check(attachedUid == sender)
            check(envelope.sequence() == lastSequence + 1 &&
                parsed.callId == envelope.sequence() &&
                outstanding.size < PtcScriptEngine.MAX_PENDING_HOST_CALLS)
            check(outstanding.add(envelope.sequence()))
            lastSequence = envelope.sequence()
        }
        try {
            worker.execute {
                try {
                    val childId = synchronized(gate) {
                        requireActive()
                        check(withinDeadline())
                        if (parsed.action == "WORKFLOW_START_CHILD") {
                            workflowOwner.reserveChild(request.runId()).also {
                                workflowOwner.markLaunching(request.runId(), it)
                            }
                        } else null
                    }
                    val childCallId = when (parsed.action) {
                        "WORKFLOW_CHILD_RESULT", "WORKFLOW_DISPOSE_CHILD" -> {
                            val childRequest = parsed.value as JSONObject
                            require(childRequest.keys().asSequence().toSet() == setOf("callId"))
                            val id = childRequest.getInt("callId")
                            check(childCalls.containsKey(id)) { "Workflow child call is not owned" }
                            id
                        }
                        else -> null
                    }
                    val params = JSONObject().put("runId", request.runId()).put("token", token)
                        .put("callId", parsed.callId).put("action", parsed.action)
                        .put("value", parsed.value)
                    if (childId != null) params.put("childId", childId)
                    val reply = transport.call(params, remainingMillis())
                    check(withinDeadline()) { "Workflow callback exceeded its deadline" }
                    if (IsolatedWorkflowRequest.isPreActivationRouteDenial(
                            reply, request.runId(), parsed.callId, childId)) {
                        // No child handle was published for this exact reservation.
                        // Failed retirement, malformed replies and RPC failures still
                        // remain uncertain; close must join all siblings and persist
                        // their retirement before a known failure can be published.
                        cancel()
                        reject("Workflow child model route was denied before activation")
                        return@execute
                    }
                    if (childId != null) {
                        val published = reply.getJSONObject("value")
                        val call = published.getInt("callId")
                        check(call in 1..128 && !childCalls.containsKey(call) &&
                            published.getString("childId") == childId) {
                            "Workflow child publication changed its App reservation"
                        }
                        childCalls[call] = childId
                    }
                    if (childCallId != null && parsed.action == "WORKFLOW_DISPOSE_CHILD") {
                        workflowOwner.confirmChildRetired(request.runId(),
                            checkNotNull(childCalls.remove(childCallId)))
                    }
                    val encoded = IsolatedWorkflowRequest.response(reply, request.runId(), parsed.callId)
                    synchronized(gate) {
                        requireActive()
                        requireDurableAdmission()
                        check(withinDeadline() && outstanding.remove(parsed.callId))
                        guest.send(Message.obtain(null, IsolatedScriptWire.HOST_RESULT).apply {
                            this.data = Bundle().apply {
                                putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                                putString(IsolatedScriptWire.KEY_RUN, request.runId())
                                putString(IsolatedScriptWire.KEY_NONCE, request.nonce())
                                putInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, parsed.callId)
                                putString(IsolatedScriptWire.KEY_HOST_REPLY, encoded)
                            }
                        })
                    }
                } catch (failure: Exception) {
                    synchronized(gate) {
                        // A requested cancel interrupts the callback worker. That is
                        // expected control flow, not evidence of unjoined effects:
                        // retire still requires both worker exit and Node close.
                        if (!cancelled.asBoolean ||
                            (failure !is InterruptedException && failure !is CancellationException))
                            uncertain = true
                    }
                    cancel()
                    reject("Workflow callback outcome needs inspection")
                } finally {
                    synchronized(gate) { outstanding.remove(parsed.callId) }
                }
            }
        } catch (failure: Exception) {
            synchronized(gate) { outstanding.remove(parsed.callId); uncertain = true }
            cancel()
            throw failure
        }
    }

    override fun proposedResult(sender: Int, reported: Int) {
        synchronized(gate) {
            check(!closed && !cancelled.asBoolean && withinDeadline() && outstanding.isEmpty() &&
                workflowOwner.read(request.runId()).state() == DurableWorkflowOwner.State.ADMITTED)
            check(sender >= 0 && sender != Process.myUid() && sender == reported)
            check(attachedUid == -1 || attachedUid == sender)
        }
    }

    override fun cancel() {
        synchronized(gate) { closed = true; startClose() }
        worker.shutdownNow()
    }

    override fun retire(scriptCompleted: Boolean): IsolatedScriptHostBridge.Retirement {
        synchronized(gate) { closed = true; startClose() }
        worker.shutdownNow()
        val quiet = try { worker.awaitTermination(remainingMillis(), TimeUnit.MILLISECONDS) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
        val settled = try { closeFuture?.get(remainingMillis(), TimeUnit.MILLISECONDS) == true }
        catch (_: Exception) { false }
        closer.shutdownNow()
        return when {
            !quiet || !settled || uncertain -> IsolatedScriptHostBridge.Retirement.UNCONFIRMED
            scriptCompleted -> IsolatedScriptHostBridge.Retirement.COMPLETED
            else -> IsolatedScriptHostBridge.Retirement.FAILED
        }
    }

    private fun startClose() {
        if (closeFuture == null) closeFuture = closer.submit<Boolean> {
            if (!transport.close(request.runId(), token, remainingMillis())) return@submit false
            // A successful Node close joins every published child and every
            // pending start before it acknowledges retirement. Only then may
            // the App's durable receipt release remaining launch reservations.
            val pending = workflowOwner.read(request.runId()).children()
                .filter { it.state() != DurableWorkflowOwner.ChildState.RETIRED }
            for (child in pending) {
                val state = workflowOwner.read(request.runId()).state()
                if (state == DurableWorkflowOwner.State.CANCEL_REQUESTED ||
                    state == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
                    workflowOwner.confirmStoppedChild(request.runId(), child.id())
                else workflowOwner.confirmChildRetired(request.runId(), child.id())
            }
            true
        }
    }

    private fun remainingMillis(): Long = maxOf(1L,
        TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()))

    /** Caller holds gate; only explicit cancellation uses this exception. */
    private fun requireActive() {
        if (cancelled.asBoolean) throw CancellationException("Workflow callback cancelled")
        check(!closed) { "Workflow callback is closed" }
    }

    private fun requireDurableAdmission() {
        val state = workflowOwner.read(request.runId()).state()
        if (state == DurableWorkflowOwner.State.CANCEL_REQUESTED)
            throw CancellationException("Workflow callback cancelled durably")
        check(state == DurableWorkflowOwner.State.ADMITTED)
    }

    private fun withinDeadline(): Boolean = System.nanoTime() - deadlineNanos < 0L
}
