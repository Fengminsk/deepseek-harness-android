package com.minnnng.dsh_android

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/** One V8 call in a fresh isolated UID; optional file calls use only an App reply Binder. */
class IsolatedScriptService : Service() {
    private data class Active(
        val request: IsolatedScriptWire.Request,
        val reply: Messenger,
        val death: IBinder.DeathRecipient,
        val hostGrantsJson: String?,
        @Volatile var engine: PtcScriptEngine? = null,
    ) {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(request.deadlineMillis().toLong())
        val hostMonitor = java.lang.Object()
        var hostSequence = 0
        var hostWaiting = 0
        var hostReply: IsolatedScriptWire.HostReply? = null
        val asyncPending = mutableSetOf<Int>()
        @Volatile var cancelled = false

        fun stop() {
            cancelled = true
            engine?.cancel()
            synchronized(hostMonitor) { hostMonitor.notifyAll() }
        }
    }

    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "dsh-script-guest") }
    // Messenger callbacks and Service destruction are serialized on the guest main thread.
    @Volatile private var active: Active? = null
    private val main = Handler(Looper.getMainLooper())
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        try {
            if (message.sendingUid != applicationInfo.uid) return@Handler true
            when (message.what) {
                IsolatedScriptWire.RUN -> accept(message)
                IsolatedScriptWire.RETIRE -> retire(message)
                IsolatedScriptWire.CANCEL -> cancel(message)
                IsolatedScriptWire.HOST_RESULT -> hostResult(message)
            }
        } catch (_: Exception) {
            // A malformed App-owned message cannot keep an isolated execution alive.
            active?.stop()
            Process.killProcess(Process.myPid())
        }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun accept(message: Message) {
        val reply = message.replyTo ?: return
        val data = message.data
        val base = setOf(
            IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN,
            IsolatedScriptWire.KEY_NONCE, IsolatedScriptWire.KEY_PROGRAM,
            IsolatedScriptWire.KEY_INPUT, IsolatedScriptWire.KEY_DEADLINE,
        )
        val hostGrantsJson = if (data.containsKey(IsolatedScriptWire.KEY_HOST_GRANTS)) {
            require(data.keySet() == base + IsolatedScriptWire.KEY_HOST_GRANTS)
            checkNotNull(data.getString(IsolatedScriptWire.KEY_HOST_GRANTS)).also {
                require(IsolatedScriptWire.utf8Bytes(it) <= PtcScriptEngine.MAX_GRANTS_BYTES)
                require(org.json.JSONArray(it).length() <= IsolatedCapabilityBroker.MAX_GRANTS)
            }
        } else {
            require(data.keySet() == base)
            null
        }
        require(data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION)
        require(active == null) { "Isolated script instance already has a run" }
        val request = IsolatedScriptWire.Request(
            checkNotNull(data.getString(IsolatedScriptWire.KEY_RUN)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_NONCE)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_PROGRAM)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_INPUT)),
            data.getInt(IsolatedScriptWire.KEY_DEADLINE, -1),
        )
        val death = IBinder.DeathRecipient {
            active?.stop()
            Process.killProcess(Process.myPid())
        }
        reply.binder.linkToDeath(death, 0)
        val run = Active(request, reply, death, hostGrantsJson)
        active = run
        try { worker.execute { execute(run) } }
        catch (_: RejectedExecutionException) {
            active = null
            reply.binder.unlinkToDeath(death, 0)
            Process.killProcess(Process.myPid())
        }
    }

    private fun execute(run: Active) {
        val result = try {
            PtcScriptEngine().use { engine ->
                run.engine = engine
                if (run.hostGrantsJson == null) {
                    engine.run(run.request.program(), run.request.inputJson(), run.request.deadlineMillis())
                } else {
                    engine.run(run.request.program(), run.request.inputJson(),
                        run.request.deadlineMillis(), object : PtcScriptEngine.HostCall {
                            override fun call(requestJson: String): String = requestHost(run, requestJson)
                            override fun submit(requestJson: String): Int = submitHost(run, requestJson)
                        }, run.hostGrantsJson)
                }
            }
        } catch (_: Exception) { null }
        catch (_: LinkageError) { null }
        finally { run.engine = null }
        main.post {
            if (active !== run) return@post
            try {
                val status = result?.status ?: PtcScriptEngine.Status.ENGINE_UNAVAILABLE
                val reply = IsolatedScriptWire.Reply(
                    run.request.runId(), run.request.nonce(), status,
                    result?.outputJson, result?.logsJson,
                    if (result == null) "Script engine unavailable" else null,
                )
                run.reply.send(Message.obtain(null, IsolatedScriptWire.RESULT).apply {
                    data = Bundle().apply {
                        putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                        putString(IsolatedScriptWire.KEY_RUN, reply.runId())
                        putString(IsolatedScriptWire.KEY_NONCE, reply.nonce())
                        putString(IsolatedScriptWire.KEY_STATUS, reply.status().name)
                        putString(IsolatedScriptWire.KEY_OUTPUT, reply.outputJson())
                        putString(IsolatedScriptWire.KEY_LOGS, reply.logsJson())
                        putString(IsolatedScriptWire.KEY_DETAIL, reply.detail())
                        putInt(IsolatedScriptWire.KEY_UID, Process.myUid())
                    }
                })
            } catch (_: Exception) {
                Process.killProcess(Process.myPid())
            }
        }
    }

    private fun requestHost(run: Active, requestJson: String): String {
        synchronized(run.hostMonitor) {
            check(active === run && !run.cancelled && run.hostWaiting == 0 &&
                run.asyncPending.size < PtcScriptEngine.MAX_PENDING_HOST_CALLS)
            val request = IsolatedScriptWire.HostRequest(
                run.request.runId(), run.request.nonce(), ++run.hostSequence, requestJson,
            )
            run.hostWaiting = request.sequence()
            run.hostReply = null
            sendHost(run, request)
            try {
                while (run.hostReply == null && !run.cancelled) {
                    val left = run.deadlineNanos - System.nanoTime()
                    check(left > 0) { "Host response exceeded guest deadline" }
                    run.hostMonitor.wait(minOf(50L, maxOf(1L, TimeUnit.NANOSECONDS.toMillis(left))))
                }
                check(!run.cancelled) { "Guest call was cancelled" }
                return checkNotNull(run.hostReply).replyJson()
            } finally {
                run.hostWaiting = 0
                run.hostReply = null
            }
        }
    }

    private fun submitHost(run: Active, requestJson: String): Int = synchronized(run.hostMonitor) {
        check(active === run && !run.cancelled &&
            run.asyncPending.size + (if (run.hostWaiting != 0) 1 else 0) <
                PtcScriptEngine.MAX_PENDING_HOST_CALLS)
        val request = IsolatedScriptWire.HostRequest(
            run.request.runId(), run.request.nonce(), ++run.hostSequence, requestJson,
        )
        check(run.asyncPending.add(request.sequence()))
        try { sendHost(run, request) }
        catch (failure: Exception) { run.asyncPending.remove(request.sequence()); throw failure }
        request.sequence()
    }

    private fun sendHost(run: Active, request: IsolatedScriptWire.HostRequest) {
        run.reply.send(Message.obtain(null, IsolatedScriptWire.HOST_CALL).apply {
            data = Bundle().apply {
                putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                putString(IsolatedScriptWire.KEY_RUN, request.runId())
                putString(IsolatedScriptWire.KEY_NONCE, request.nonce())
                putInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, request.sequence())
                putString(IsolatedScriptWire.KEY_HOST_REQUEST, request.requestJson())
                putInt(IsolatedScriptWire.KEY_UID, Process.myUid())
            }
        })
    }

    private fun hostResult(message: Message) {
        val run = active ?: error("No active guest")
        require(run.hostGrantsJson != null)
        val data = message.data
        require(data.keySet() == setOf(
            IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN,
            IsolatedScriptWire.KEY_NONCE, IsolatedScriptWire.KEY_HOST_SEQUENCE,
            IsolatedScriptWire.KEY_HOST_REPLY,
        ))
        require(data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION)
        val reply = IsolatedScriptWire.HostReply(
            checkNotNull(data.getString(IsolatedScriptWire.KEY_RUN)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_NONCE)),
            data.getInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, -1),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_HOST_REPLY)),
        )
        require(reply.runId() == run.request.runId() && reply.nonce() == run.request.nonce())
        synchronized(run.hostMonitor) {
            require(!run.cancelled)
            if (run.hostWaiting == reply.sequence()) {
                require(run.hostReply == null)
                run.hostReply = reply
                run.hostMonitor.notifyAll()
            } else {
                require(run.asyncPending.remove(reply.sequence()))
                checkNotNull(run.engine).also {
                    check(it.deliverReply(reply.sequence(), reply.replyJson()))
                }
            }
        }
    }

    private fun retire(message: Message) {
        val run = active ?: return
        require(identityMatches(run, message.data))
        run.stop()
        Process.killProcess(Process.myPid())
    }

    private fun cancel(message: Message) {
        val run = active ?: run {
            // The App may cancel after binding but before the RUN message was sent.
            Process.killProcess(Process.myPid())
            return
        }
        require(identityMatches(run, message.data))
        run.stop()
        Process.killProcess(Process.myPid())
    }

    private fun identityMatches(run: Active, data: Bundle): Boolean =
        data.keySet() == setOf(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN, IsolatedScriptWire.KEY_NONCE) &&
            data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION &&
            data.getString(IsolatedScriptWire.KEY_RUN) == run.request.runId() &&
            data.getString(IsolatedScriptWire.KEY_NONCE) == run.request.nonce()

    override fun onDestroy() {
        active?.let { run ->
            run.stop()
            run.reply.binder.unlinkToDeath(run.death, 0)
        }
        active = null
        worker.shutdownNow()
        super.onDestroy()
    }
}
