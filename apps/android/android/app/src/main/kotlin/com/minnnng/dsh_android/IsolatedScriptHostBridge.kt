package com.minnnng.dsh_android

import android.content.Context
import android.os.Bundle
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.function.BooleanSupplier

/** One App-owned, policy-leased host bridge for file and optional HTTPS calls. */
internal class IsolatedScriptHostBridge(
    context: Context,
    private val request: IsolatedScriptWire.Request,
    policy: Policy?,
    networkPolicy: NetworkPolicy?,
    private val policyLease: IsolatedExecutionPolicyOwner.Lease,
    private val cancelled: BooleanSupplier,
) : IsolatedScriptCallbacks {
    enum class Retirement { COMPLETED, FAILED, UNCONFIRMED }

    class Policy(
        val workspaceRoot: File,
        val ownerId: String,
        val journal: IsolatedCapabilityJournal,
        grants: List<IsolatedCapabilityBroker.GrantSpec>,
        val sandbox: IsolatedCapabilityBroker.SandboxPolicy,
    ) {
        val grants: List<IsolatedCapabilityBroker.GrantSpec> = AndroidJava28.copyList(grants)
    }

    class NetworkPolicy(
        val hosts: IsolatedNetworkBroker.Policy,
        val journal: IsolatedNetworkJournal,
        val resolver: IsolatedNetworkBroker.DeadlineResolver,
        val transport: IsolatedNetworkBroker.PinnedTransport,
    ) {
        companion object {
            /** Trusted App factory; a nonempty scope still requires an approved policy lease. */
            fun forAndroid(context: Context, exactHosts: Set<String>): NetworkPolicy = NetworkPolicy(
                IsolatedNetworkBroker.Policy(exactHosts), AndroidNetworkJournal.open(context),
                AndroidDeadlineResolver(context),
                IsolatedNetworkBroker.PinnedTlsTransport(IsolatedWorkerInput.MAX_TEXT_BYTES),
            )
        }
    }

    private val gate = Any()
    private val publishGate = IsolatedWorkerWriteback.PublishGate()
    private val policyVersion = policyLease.policy().version()
    private val fileCallLimit = policyLease.policy().fileCallLimit()
    private val networkCallLimit = policyLease.policy().networkCallLimit()
    init {
        val scope = policyLease.policy()
        check(policy != null || networkPolicy != null) { "Host bridge needs an explicit capability" }
        check(policyLease.runId() == request.runId() && policyLease.active(policyVersion))
        if (policy != null) {
            check(scope.ownerId() == policy.ownerId && fileCallLimit in 1..IsolatedCapabilityBroker.MAX_CALLS)
            check(scope.appPrivateRoot() == File(context.applicationInfo.dataDir).canonicalFile.toPath())
            check(scope.workspaceRoot() == policy.workspaceRoot.canonicalFile.toPath())
            val scoped = IsolatedCapabilityBroker.SandboxPolicy(scope.readablePaths(), scope.writablePaths())
            check(policy.grants.all(scoped::permits)) { "File grant exceeds active execution policy" }
        }
        if (networkPolicy != null) {
            check(networkCallLimit in 1..IsolatedNetworkBroker.MAX_CALLS)
            check(networkPolicy.hosts.exactHosts().isNotEmpty())
            check(scope.exactHosts().containsAll(networkPolicy.hosts.exactHosts())) {
                "Network host exceeds active execution policy"
            }
        }
    }
    private val session = policy?.let {
        IsolatedCapabilitySession(
            it.ownerId, IsolatedCapabilityWorkspace(context, it.workspaceRoot, publishGate),
            it.journal, it.grants, it.sandbox,
            request.deadlineMillis().toLong() + 3000L, Process.myUid(),
        )
    }
    private val offer = session?.offer()
    private val network = networkPolicy?.let {
        IsolatedNetworkBroker(it.hosts, it.resolver, it.transport, it.journal,
            request.deadlineMillis(), IsolatedWorkerInput.MAX_TEXT_BYTES,
            policyLease.deadlineNanos())
    }
    init {
        try {
            // Revoke network sockets and the file publication gate in the same owner
            // transition, instead of waiting for the controller's cancellation poll.
            policyLease.onRevoked {
                publishGate.cancel()
                network?.revoke()
            }
            check(policyLease.active(policyVersion)) { "Execution policy was revoked during host admission" }
        } catch (failure: Throwable) {
            // The file session already has a durable RUN_OPENED audit at this point.
            // A revoked constructor must settle it before RunController loses this reference.
            publishGate.cancel()
            network?.revoke()
            try { session?.fail() }
            catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            throw failure
        }
    }
    override val grantsJson: String = try { IsolatedScriptHostCodec.grants(offer?.grants() ?: emptyList()) }
        catch (failure: Exception) { session?.fail(); network?.revoke(); throw failure }
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-script-host-capability").apply { isDaemon = true }
    }
    private var attached = false
    private var attachedUid = -1
    // Binder accepts a small bounded queue; the single capability worker preserves journal order.
    private val outstanding = mutableSetOf<Int>()
    private var closed = false
    private var lastSequence = 0
    private var fileCalls = 0
    private var networkCalls = 0
    @Volatile private var networkOutcomeUnconfirmed = false

    /** Binder sender UID is authoritative; the guest's UID field only corroborates it. */
    override fun call(message: Message, guest: Messenger, reject: (String) -> Unit) {
        val data = message.data
        val sender = message.sendingUid
        val reported = data.getInt(IsolatedScriptWire.KEY_UID, -1)
        require(data.keySet() == setOf(
            IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.KEY_RUN,
            IsolatedScriptWire.KEY_NONCE, IsolatedScriptWire.KEY_HOST_SEQUENCE,
            IsolatedScriptWire.KEY_HOST_REQUEST, IsolatedScriptWire.KEY_UID,
        ))
        require(data.getInt(IsolatedScriptWire.KEY_VERSION, -1) == IsolatedScriptWire.VERSION)
        val call = IsolatedScriptWire.HostRequest(
            checkNotNull(data.getString(IsolatedScriptWire.KEY_RUN)),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_NONCE)),
            data.getInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, -1),
            checkNotNull(data.getString(IsolatedScriptWire.KEY_HOST_REQUEST)),
        )
        require(call.runId() == request.runId() && call.nonce() == request.nonce())
        val action = IsolatedScriptHostCodec.action(call.requestJson())
        val networkCall = action == IsolatedScriptHostCodec.NETWORK_ACTION
        synchronized(gate) {
            check(!closed && outstanding.size < PtcScriptEngine.MAX_PENDING_HOST_CALLS &&
                !cancelled.asBoolean && policyLease.active(policyVersion)
                && call.sequence() == lastSequence + 1)
            if (networkCall) check(network != null && ++networkCalls <= networkCallLimit)
            else check(session != null && ++fileCalls <= fileCallLimit)
            attach(sender, reported)
            check(outstanding.add(call.sequence()))
            lastSequence = call.sequence()
        }
        try {
            worker.execute {
                var networkDispatched = false
                try {
                    val encoded = if (networkCall) {
                        val brokerCall = IsolatedScriptHostCodec.parseNetwork(call.requestJson())
                        networkDispatched = true
                        val result = checkNotNull(network).get(brokerCall.callId, brokerCall.url)
                        if (result.status() == IsolatedNetworkBroker.Status.AUDIT_UNCERTAIN) {
                            networkOutcomeUnconfirmed = true
                            session?.fail()
                            reject("Network call outcome needs inspection")
                            return@execute
                        }
                        IsolatedScriptHostCodec.networkResponse(result)
                    } else {
                        val fileSession = checkNotNull(session)
                        val fileOffer = checkNotNull(offer)
                        val brokerCall = IsolatedScriptHostCodec.parse(call.requestJson(), fileOffer.runId())
                        val result = fileSession.dispatch(sender, reported,
                            IsolatedCapabilitySession.Request(fileOffer.nonce(), brokerCall),
                            BooleanSupplier { cancelled.asBoolean || !policyLease.active(policyVersion)
                                || synchronized(gate) { closed } })
                        if (result.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN) {
                            fileSession.fail()
                            reject("File edit outcome needs inspection")
                            return@execute
                        }
                        IsolatedScriptHostCodec.response(result)
                    }
                    synchronized(gate) {
                        check(!closed && !cancelled.asBoolean && policyLease.active(policyVersion)
                            && session?.terminal() == null)
                        check(outstanding.remove(call.sequence()))
                        guest.send(Message.obtain(null, IsolatedScriptWire.HOST_RESULT).apply {
                            this.data = Bundle().apply {
                                putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
                                putString(IsolatedScriptWire.KEY_RUN, request.runId())
                                putString(IsolatedScriptWire.KEY_NONCE, request.nonce())
                                putInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, call.sequence())
                                putString(IsolatedScriptWire.KEY_HOST_REPLY, encoded)
                            }
                        })
                    }
                } catch (_: Exception) {
                    if (networkDispatched) {
                        networkOutcomeUnconfirmed = true
                        network?.revoke()
                    }
                    session?.fail()
                    reject("Script host capability failed")
                } finally {
                    // Each queued request owns its own sequence, even if a later call was admitted.
                    synchronized(gate) {
                        outstanding.remove(call.sequence())
                    }
                }
            }
        } catch (failure: Exception) {
            synchronized(gate) { outstanding.remove(call.sequence()) }
            session?.fail()
            throw failure
        }
    }

    /** Called before RETIRE. No file or network call may remain in flight. */
    override fun proposedResult(sender: Int, reported: Int) {
        synchronized(gate) {
            check(!closed && outstanding.isEmpty() && policyLease.active(policyVersion))
            attach(sender, reported)
            if (session != null) {
                val fileOffer = checkNotNull(offer)
                check(session.proposeFinish(sender, reported, fileOffer.runId(), fileOffer.nonce()))
            }
        }
    }

    /** Cancellation revokes the lease immediately; later file results cannot become success. */
    override fun cancel() {
        synchronized(gate) { closed = true }
        publishGate.cancel()
        network?.revoke()
        session?.cancel()
        worker.shutdownNow()
    }

    /** Only confirmed guest death, settled calls and successful binding cleanup can finish the lease. */
    override fun retire(scriptCompleted: Boolean): Retirement {
        synchronized(gate) { closed = true }
        val policyActive = policyLease.active(policyVersion)
        publishGate.cancel()
        network?.revoke()
        worker.shutdownNow()
        val quiet = try { worker.awaitTermination(1000, TimeUnit.MILLISECONDS) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
        if (!quiet || publishGate.outcomeUnconfirmed() || networkOutcomeUnconfirmed || !policyActive) {
            session?.workerDied()
            return Retirement.UNCONFIRMED
        }
        if (!scriptCompleted) {
            session?.workerDied()
            return Retirement.FAILED
        }
        return if (session == null || session.retiredAfterCleanup() == IsolatedCapabilityBroker.Terminal.COMPLETED)
            Retirement.COMPLETED else Retirement.FAILED
    }

    private fun attach(sender: Int, reported: Int) {
        if (!attached) {
            check(sender >= 0 && sender != Process.myUid() && sender == reported)
            if (session != null) {
                val fileOffer = checkNotNull(offer)
                check(session.attach(sender, reported, fileOffer.runId(), fileOffer.nonce()))
            }
            attachedUid = sender
            attached = true
        } else {
            check(sender == attachedUid && sender != Process.myUid() && sender == reported)
        }
    }
}
