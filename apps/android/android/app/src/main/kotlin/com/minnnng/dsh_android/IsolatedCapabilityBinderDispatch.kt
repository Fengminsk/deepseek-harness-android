package com.minnnng.dsh_android

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.BooleanSupplier

/** App-owned Binder adapter for a future separate-UID executor; never send it workspace paths. */
internal class IsolatedCapabilityBinderDispatch private constructor(
    private val session: IsolatedCapabilitySession,
    private val guest: Messenger,
    private val releaseBinding: () -> Unit,
    leaseMillis: Long,
) : AutoCloseable {
    private val outstanding = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val offered = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-capability-dispatch").apply { isDaemon = true }
    }
    private val retirement = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-capability-retire").apply { isDaemon = true }
    }
    private val leaseTimer = ScheduledThreadPoolExecutor(1) { task ->
        Thread(task, "dsh-capability-binding-deadline").apply { isDaemon = true }
    }
    private val transportThread = HandlerThread("dsh-capability-binder").apply { start() }
    private val transport = Handler(transportThread.looper)
    private val callbacks = Messenger(Handler(transportThread.looper) { message ->
        receive(message)
        true
    })
    private val guestBinder = guest.binder
    private val deathRecipient = IBinder.DeathRecipient { transport.post { onBinderDeath() } }

    init {
        try {
            guestBinder.linkToDeath(deathRecipient, 0)
            leaseTimer.setRemoveOnCancelPolicy(true)
            leaseTimer.schedule({ session.timeout(); close() }, leaseMillis, TimeUnit.MILLISECONDS)
        } catch (failure: Exception) {
            guestBinder.unlinkToDeath(deathRecipient, 0)
            leaseTimer.shutdownNow()
            worker.shutdownNow()
            retirement.shutdownNow()
            transportThread.quitSafely()
            throw failure
        }
    }

    companion object {
        const val OFFER = 41
        const val HELLO = 42
        const val CALL = 43
        const val RESULT = 44
        const val FINISH = 45
        const val STOPPING = 46

        private const val RUN = "runId"
        private const val NONCE = "nonce"
        private const val UID = "uid"
        private const val GRANTS = "grants"
        private const val CALL_ID = "callId"
        private const val GRANT_ID = "grantId"
        private const val RELATIVE_PATH = "relativePath"
        private const val ACTION = "action"
        private const val QUERY = "query"
        private const val MAX_MATCHES = "maxMatches"
        private const val EXPECTED_REVISION = "expectedRevision"
        private const val NEEDLE = "needle"
        private const val REPLACEMENT = "replacement"
        private const val MAX_REPLACEMENTS = "maxReplacements"
        private const val STATUS = "status"
        private const val DETAIL = "detail"
        private const val REVISION = "revision"
        private const val TEXT = "text"
        private const val HITS = "hits"
        private const val TRUNCATED = "truncated"
        private const val PREVIOUS_REVISION = "previousRevision"
        private const val BYTES = "bytes"
        private const val MAX_REQUEST_BYTES = 96 * 1024

        /** The App selects grants and workspace before binding a fresh isolated guest instance. */
        fun open(
            context: Context, workspaceRoot: File, ownerId: String,
            journal: IsolatedCapabilityJournal,
            grants: List<IsolatedCapabilityBroker.GrantSpec>,
            policy: IsolatedCapabilityBroker.SandboxPolicy,
            leaseMillis: Long, guest: Messenger, releaseBinding: () -> Unit,
        ): IsolatedCapabilityBinderDispatch {
            checkNotMainThread()
            val app = context.applicationContext
            val workspace = IsolatedCapabilityWorkspace(app, workspaceRoot)
            val session = IsolatedCapabilitySession(
                ownerId, workspace, journal, grants, policy, leaseMillis, Process.myUid(),
            )
            return try { IsolatedCapabilityBinderDispatch(session, guest, releaseBinding, leaseMillis) }
            catch (failure: Exception) { session.workerDied(); throw failure }
        }

        private fun checkNotMainThread() {
            check(Looper.myLooper() != Looper.getMainLooper()) {
                "Capability admission and audit must run off the Android main thread"
            }
        }
    }

    /** Send after ServiceConnection has established the isolated Binder; replyTo is this App dispatcher. */
    fun sendOffer() {
        checkNotMainThread()
        check(!closed.get()) { "Capability session is closed" }
        check(offered.compareAndSet(false, true)) { "Capability offer was already sent" }
        val offer = session.offer()
        val handles = ArrayList(offer.grants().map { handle ->
            Bundle().apply {
                putString(GRANT_ID, handle.id())
                putStringArrayList("actions", ArrayList(handle.actions().map { it.name }))
                if (handle.directory()) putBoolean("directory", true)
            }
        })
        try {
            guest.send(Message.obtain(null, OFFER).apply {
                replyTo = callbacks
                data = Bundle().apply {
                    putString(RUN, offer.runId())
                    putString(NONCE, offer.nonce())
                    putParcelableArrayList(GRANTS, handles)
                }
            })
        } catch (failure: Exception) {
            session.workerDied()
            close()
            throw failure
        }
    }

    /** Ambiguous binding loss fails closed; a proposed FINISH awaits Binder death or its deadline. */
    fun bindingLost() {
        checkNotMainThread()
        if (session.finishProposed()) return
        session.workerDied()
        close()
    }

    /** A null binding has no Binder death receipt and can never confirm success. */
    fun bindingFailed() { checkNotMainThread(); session.workerDied(); close() }

    fun terminal(): IsolatedCapabilityBroker.Terminal? = session.terminal()

    fun cancel() {
        checkNotMainThread()
        session.cancel()
        close()
    }

    private fun receive(message: Message) {
        if (closed.get()) return
        try {
            val data = message.data
            val sender = message.sendingUid
            val reported = data.getInt(UID, -1)
            val run = data.getString(RUN)
            val nonce = data.getString(NONCE)
            when (message.what) {
                HELLO -> {
                    require(data.keySet() == setOf(RUN, NONCE, UID))
                    require(session.attach(sender, reported, run, nonce))
                }
                CALL -> {
                    require(outstanding.compareAndSet(false, true))
                    try {
                        val request = parseCall(data)
                        worker.execute {
                            try {
                                val result = session.dispatch(sender, reported, request, BooleanSupplier { closed.get() })
                                outstanding.set(false)
                                sendResult(request.call().callId(), result)
                                if (session.terminal() != null) close()
                            } catch (_: Exception) {
                                session.fail()
                                close()
                            }
                            finally { outstanding.set(false) }
                        }
                    } catch (failure: Exception) {
                        outstanding.set(false)
                        throw failure
                    }
                }
                FINISH -> {
                    require(data.keySet() == setOf(RUN, NONCE, UID))
                    require(!outstanding.get())
                    require(session.proposeFinish(sender, reported, run, nonce))
                    guest.send(Message.obtain(null, STOPPING).apply {
                        this.data = Bundle().apply { putString(RUN, run) }
                    })
                }
                else -> throw IllegalArgumentException("Unknown capability message")
            }
        } catch (_: Exception) {
            session.fail()
            close()
        }
    }

    @Suppress("DEPRECATION")
    private fun parseCall(data: Bundle): IsolatedCapabilitySession.Request {
        val action = IsolatedCapabilityBroker.Action.valueOf(checkNotNull(data.getString(ACTION)))
        val child = data.containsKey(RELATIVE_PATH)
        val base = setOf(RUN, NONCE, UID, CALL_ID, GRANT_ID, ACTION) +
            (if (child) setOf(RELATIVE_PATH) else emptySet())
        val expected = when (action) {
            IsolatedCapabilityBroker.Action.READ -> base
            IsolatedCapabilityBroker.Action.SEARCH -> base + setOf(QUERY, MAX_MATCHES)
            IsolatedCapabilityBroker.Action.EDIT -> base + setOf(
                EXPECTED_REVISION, NEEDLE, REPLACEMENT, MAX_REPLACEMENTS,
            )
            IsolatedCapabilityBroker.Action.WRITE -> base + setOf(EXPECTED_REVISION, TEXT)
        }
        require(data.keySet() == expected) { "Capability call contains unexpected fields" }
        var bytes = 0
        for (key in expected) {
            val value = data.get(key)
            if (key == UID || key == MAX_MATCHES || key == MAX_REPLACEMENTS) {
                require(value is Int) { "Capability numeric field has wrong type" }
            } else {
                require(value is String) { "Capability text field has wrong type" }
                bytes += value.toByteArray(StandardCharsets.UTF_8).size
            }
        }
        require(bytes <= MAX_REQUEST_BYTES) { "Capability call exceeds Binder input limit" }
        val run = checkNotNull(data.getString(RUN))
        val callId = checkNotNull(data.getString(CALL_ID))
        val grantId = checkNotNull(data.getString(GRANT_ID))
        val relativePath = if (child) checkNotNull(data.getString(RELATIVE_PATH)) else null
        val call = when (action) {
            IsolatedCapabilityBroker.Action.READ -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.read(run, callId, grantId)
            else IsolatedCapabilityBroker.Call.readChild(run, callId, grantId, relativePath)
            IsolatedCapabilityBroker.Action.SEARCH -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.search(run, callId, grantId,
                    checkNotNull(data.getString(QUERY)), data.getInt(MAX_MATCHES))
            else IsolatedCapabilityBroker.Call.searchChild(run, callId, grantId, relativePath,
                checkNotNull(data.getString(QUERY)), data.getInt(MAX_MATCHES))
            IsolatedCapabilityBroker.Action.EDIT -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.edit(run, callId, grantId,
                    checkNotNull(data.getString(EXPECTED_REVISION)), checkNotNull(data.getString(NEEDLE)),
                    checkNotNull(data.getString(REPLACEMENT)), data.getInt(MAX_REPLACEMENTS))
            else IsolatedCapabilityBroker.Call.editChild(run, callId, grantId, relativePath,
                checkNotNull(data.getString(EXPECTED_REVISION)), checkNotNull(data.getString(NEEDLE)),
                checkNotNull(data.getString(REPLACEMENT)), data.getInt(MAX_REPLACEMENTS))
            IsolatedCapabilityBroker.Action.WRITE -> if (relativePath == null)
                IsolatedCapabilityBroker.Call.write(run, callId, grantId,
                    checkNotNull(data.getString(EXPECTED_REVISION)), checkNotNull(data.getString(TEXT)))
            else IsolatedCapabilityBroker.Call.writeChild(run, callId, grantId, relativePath,
                checkNotNull(data.getString(EXPECTED_REVISION)), checkNotNull(data.getString(TEXT)))
        }
        return IsolatedCapabilitySession.Request(checkNotNull(data.getString(NONCE)), call)
    }

    private fun sendResult(callId: String, result: IsolatedCapabilityBroker.CallResult) {
        if (closed.get()) return
        try {
            guest.send(Message.obtain(null, RESULT).apply {
                data = Bundle().apply {
                    putString(CALL_ID, callId)
                    putString(STATUS, result.status().name)
                    result.detail()?.let { putString(DETAIL, it) }
                    result.read()?.let { putString(REVISION, it.revision()); putString(TEXT, it.text()) }
                    result.search()?.let { search ->
                        putString(REVISION, search.revision())
                        putBoolean(TRUNCATED, search.truncated())
                        putParcelableArrayList(HITS, ArrayList(search.hits().map { hit ->
                            Bundle().apply {
                                putInt("line", hit.line()); putInt("column", hit.column())
                                putString("preview", hit.preview())
                            }
                        }))
                    }
                    result.edit()?.let {
                        putString(PREVIOUS_REVISION, it.previousRevision())
                        putString(REVISION, it.revision())
                        putInt(BYTES, it.bytes())
                    }
                }
            })
        } catch (_: Exception) { bindingFailed() }
    }

    /** Only Binder death followed by successful App-owned unbind/cleanup may commit COMPLETED. */
    private fun onBinderDeath() {
        if (!closed.compareAndSet(false, true)) return
        if (!session.finishProposed()) session.workerDied()
        leaseTimer.shutdownNow()
        worker.shutdownNow()
        transportThread.quitSafely()
        try { retirement.execute {
            try {
                releaseBinding()
                session.retiredAfterCleanup()
            } catch (_: Exception) { session.workerDied() }
            finally {
                retirement.shutdown()
                guestBinder.unlinkToDeath(deathRecipient, 0)
            }
        } } catch (_: Exception) {
            session.workerDied()
            retirement.shutdownNow()
            guestBinder.unlinkToDeath(deathRecipient, 0)
        }
    }

    override fun close() {
        checkNotMainThread()
        if (closed.compareAndSet(false, true)) {
            session.close()
            worker.shutdownNow()
            leaseTimer.shutdownNow()
            transportThread.quitSafely()
            guestBinder.unlinkToDeath(deathRecipient, 0)
            try { retirement.execute {
                try { releaseBinding() } catch (_: Exception) { /* Run is already terminal. */ }
                finally { retirement.shutdown() }
            } } catch (_: Exception) { retirement.shutdownNow() }
        }
    }
}
