package com.minnnng.dsh_android

import android.os.Bundle
import android.os.Message
import android.os.Messenger
import android.os.Process
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.function.BooleanSupplier

/** App-side, one-run Binder relay; the trusted Node host decides which pure/read-only tools exist. */
internal class IsolatedScriptToolBridge(
    private val request: IsolatedScriptWire.Request,
    private val token: String,
    private val cancelled: BooleanSupplier,
    private val transport: Transport,
) : IsolatedScriptCallbacks {
    interface Transport {
        fun call(params: JSONObject, timeoutMillis: Long): JSONObject
        /** Must join the Node ToolRuntime lane before returning true. */
        fun close(runId: String, token: String, timeoutMillis: Long): Boolean
    }

    override val grantsJson = "[]"
    private val gate = Any()
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-script-tool-calls").apply { isDaemon = true }
    }
    private val closer = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-script-tool-close").apply { isDaemon = true }
    }
    private val deadlineNanos = System.nanoTime() +
        TimeUnit.MILLISECONDS.toNanos(request.deadlineMillis().toLong() + 3000L)
    private var attachedUid = -1
    private var lastSequence = 0
    private val outstanding = mutableSetOf<Int>()
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
        val parsed = IsolatedToolRequest.parse(envelope.requestJson())
        synchronized(gate) {
            check(!closed && !cancelled.asBoolean)
            check(sender >= 0 && sender != Process.myUid() &&
                sender == data.getInt(IsolatedScriptWire.KEY_UID, -1))
            if (attachedUid == -1) attachedUid = sender else check(attachedUid == sender)
            check(envelope.sequence() == lastSequence + 1 &&
                envelope.sequence() <= IsolatedToolRequest.MAX_CALLS &&
                parsed.callId == envelope.sequence() &&
                outstanding.size < PtcScriptEngine.MAX_PENDING_HOST_CALLS)
            check(outstanding.add(envelope.sequence()))
            lastSequence = envelope.sequence()
        }
        try {
            worker.execute {
                try {
                    val params = JSONObject().put("runId", request.runId()).put("token", token)
                        .put("callId", parsed.callId).put("name", parsed.name)
                        .put("arguments", parsed.arguments)
                    val response = transport.call(params, remainingMillis())
                    val encoded = IsolatedToolRequest.response(response, request.runId(), parsed.callId)
                    synchronized(gate) {
                        check(!closed && !cancelled.asBoolean && outstanding.remove(parsed.callId))
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
                } catch (_: Exception) {
                    synchronized(gate) { uncertain = true }
                    cancel()
                    reject("Isolated tool outcome needs inspection")
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
            check(!closed && !cancelled.asBoolean && outstanding.isEmpty())
            check(attachedUid == -1 || attachedUid == sender)
            check(sender >= 0 && sender != Process.myUid() && sender == reported)
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
            transport.close(request.runId(), token, remainingMillis())
        }
    }

    private fun remainingMillis(): Long = maxOf(1L,
        TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()))
}
