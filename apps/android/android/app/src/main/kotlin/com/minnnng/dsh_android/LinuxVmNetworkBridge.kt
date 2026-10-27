package com.minnnng.dsh_android

import android.content.Context
import android.os.Bundle
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.BooleanSupplier

/** App-owned network worker for one already admitted Linux run; JSON requests cannot create a grant. */
internal class LinuxVmNetworkHostBridge(
    context: Context, val id: String, sessionId: String,
    private val lease: IsolatedExecutionPolicyOwner.Lease,
    approvedRoute: org.json.JSONObject,
) : AutoCloseable {
    val nonce: String = UUID.randomUUID().toString()
    val callLimit: Int = lease.policy().networkCallLimit()
    private val gate = Any()
    private val revoked = AtomicBoolean()
    private val closed = AtomicBoolean()
    private var pendingSequence: Int? = null
    private var attachedUid = -1
    private val preferences = NetworkProxyPreferences(context)
    private val route = preferences.route()
    private val exchange: LinuxVmHttpsBrokerExchange
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-linux-https").apply { isDaemon = true }
    }
    private var routeWatch: AutoCloseable? = null

    init {
        val scope = lease.policy()
        require(lease.runId() == id && scope.sessionId() == sessionId && lease.active(scope.version()))
        require(scope.readablePaths().isEmpty() && scope.writablePaths().isEmpty() && scope.fileCallLimit() == 0)
        require(scope.appPrivateRoot() == null && scope.workspaceRoot() == null)
        require(callLimit in 1..IsolatedNetworkBroker.MAX_CALLS && scope.exactHosts().isNotEmpty())
        require(route.toString() == approvedRoute.toString()) { "Linux HTTPS proxy changed after approval" }
        val transport = when (route.getString("mode")) {
            "system" -> IsolatedNetworkBroker.PinnedTlsTransport(LinuxVmHttpsMailbox.MAX_BODY_BYTES)
            "local" -> {
                val endpoint = java.net.URI(route.getString("url"))
                require(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port in 1..65535)
                IsolatedNetworkBroker.PinnedTlsTransport.throughLocalHttpProxy(LinuxVmHttpsMailbox.MAX_BODY_BYTES, endpoint.port)
            }
            else -> error("Linux HTTPS proxy route is invalid")
        }
        exchange = LinuxVmHttpsBrokerExchange(lease, AndroidNetworkJournal.open(context), AndroidDeadlineResolver(context), transport)
        try {
            lease.onRevoked { invalidate() }
            routeWatch = preferences.observeRoute(route) { invalidate() }
            check(active()) { "Linux HTTPS grant was revoked during admission" }
        } catch (failure: Throwable) {
            invalidate(); routeWatch?.close(); worker.shutdownNow(); throw failure
        }
    }

    fun active(): Boolean = !closed.get() && authorized()

    /** Closing a completed transport does not revoke the grant while its disk receipt settles. */
    fun authorized(): Boolean {
        if (revoked.get() || !lease.active(lease.policy().version())) return false
        val same = try { preferences.route().toString() == route.toString() } catch (_: Exception) { false }
        if (!same) invalidate()
        return same
    }
    fun idle(): Boolean = synchronized(gate) { pendingSequence == null }

    /** Runner has already matched the actual Binder UID to its started isolated Service. */
    fun dispatch(message: Message, remote: Messenger, cancelled: BooleanSupplier, reject: () -> Unit) {
        try {
            val data = message.data
            require(data.keySet() == setOf("id", "uid", "isolated", "nonce", "sequence", "callId", "url"))
            val sequence = data.getInt("sequence", -1)
            val call = requireNotNull(data.getString("callId"))
            val url = requireNotNull(data.getString("url"))
            require(data.getString("id") == id && data.getString("nonce") == nonce)
            require(UUID.fromString(call).toString() == call && url.length in 1..IsolatedNetworkBroker.MAX_URL_BYTES)
            synchronized(gate) {
                check(active() && pendingSequence == null && !cancelled.asBoolean)
                if (attachedUid < 0) attachedUid = message.sendingUid
                check(attachedUid == message.sendingUid && attachedUid != Process.myUid())
                pendingSequence = sequence
            }
            worker.execute {
                try {
                    val bytes = exchange.request(sequence, id, call, url)
                    synchronized(gate) {
                        check(active() && !cancelled.asBoolean)
                        pendingSequence = null
                        remote.send(Message.obtain(null, IsolatedLinuxVmService.NETWORK_RESULT).apply {
                            this.data = Bundle().apply {
                                putString("id", id); putString("nonce", nonce)
                                putInt("sequence", sequence); putByteArray("reply", bytes)
                            }
                        })
                    }
                } catch (_: Exception) { invalidate(); reject() }
                finally { synchronized(gate) {
                    // A fast guest may already have admitted its next sequence after the
                    // reply. This worker must never clear that successor's ownership.
                    if (pendingSequence == sequence) pendingSequence = null
                } }
            }
        } catch (_: Exception) { invalidate(); reject() }
    }

    /** Revocation may run on the main thread; closing the transport interrupts its bounded worker. */
    fun invalidate() { revoked.set(true); exchange.close() }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        exchange.close(); routeWatch?.close(); worker.shutdownNow()
        check(worker.awaitTermination(3500, TimeUnit.MILLISECONDS)) { "Linux HTTPS worker retirement is unconfirmed" }
    }
}

/** Isolated-side IPC endpoint. It has no network permissions, approval owner or App file handles. */
internal class LinuxVmNetworkGuest(
    private val id: String, private val nonce: String, private val host: Messenger,
    private val cancelled: AtomicBoolean, private val deadlineNanos: Long,
) : LinuxVmHttpsExchange {
    private val gate = Any()
    private val closed = AtomicBoolean()
    private class Pending(val sequence: Int) {
        val done = CountDownLatch(1)
        @Volatile var reply: ByteArray? = null
    }
    private var pending: Pending? = null

    override fun active(): Boolean = !closed.get() && !cancelled.get() && System.nanoTime() < deadlineNanos

    override fun request(sequence: Int, runId: String, callId: String, url: String): ByteArray {
        val call = Pending(sequence)
        synchronized(gate) {
            check(active() && pending == null && runId == id)
            pending = call
        }
        try {
            host.send(Message.obtain(null, IsolatedLinuxVmService.NETWORK_CALL).apply {
                data = Bundle().apply {
                    putString("id", id); putInt("uid", Process.myUid()); putBoolean("isolated", Process.isIsolated())
                    putString("nonce", nonce); putInt("sequence", sequence); putString("callId", callId); putString("url", url)
                }
            })
            while (active()) {
                if (call.done.await(25, TimeUnit.MILLISECONDS)) {
                    if (!active()) break
                    return call.reply ?: throw IOException("Linux HTTPS reply is absent")
                }
            }
            throw IOException("Linux HTTPS IPC was cancelled or expired")
        } catch (failure: Exception) {
            close(); throw IOException("Linux HTTPS IPC failed", failure)
        } finally { synchronized(gate) { if (pending === call) pending = null } }
    }

    /** Service accepts only messages whose Binder sender is the App UID before this method. */
    fun receive(data: Bundle) {
        try {
            require(data.keySet() == setOf("id", "nonce", "sequence", "reply"))
            require(data.getString("id") == id && data.getString("nonce") == nonce)
            val bytes = requireNotNull(data.getByteArray("reply"))
            require(bytes.size in 83..LinuxVmHttpsMailbox.RESPONSE_BYTES - LinuxVmHttpsMailbox.SECTOR_BYTES)
            synchronized(gate) {
                val call = checkNotNull(pending)
                check(active() && call.sequence == data.getInt("sequence", -1) && call.reply == null)
                call.reply = bytes; call.done.countDown()
            }
        } catch (_: Exception) { close() }
    }

    override fun close() {
        closed.set(true); cancelled.set(true)
        synchronized(gate) { pending?.done?.countDown() }
    }
}
