package com.minnnng.dsh_android

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
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Trusted App-side, dormant transport for one admitted guest run. A HELLO only proves that a
 * distinct isolated Service is bound; this class has no native launch or success publication.
 */
internal class LinuxGuestBinderBinding(
    context: Context,
    private val runId: String,
    private val lease: IsolatedExecutionPolicyOwner.Lease,
    private val session: LinuxGuestLaunchSession,
    private val bridge: LinuxGuestBinderBridge,
    private val journal: LinuxGuestRunJournal,
    private val imageBroker: LinuxImageDescriptorBroker? = null,
) : AutoCloseable {
    private companion object { const val IMAGE_LEASE_MILLIS = 15_000L }
    private val app = context.applicationContext
    private val nonce = UUID.randomUUID().toString()
    private val handler = Handler(Looper.getMainLooper())
    private val terminated = AtomicBoolean(false)
    private val bindingStarted = AtomicBoolean(false)
    private val ready = AtomicBoolean(false)
    private val workers = ThreadPoolExecutor(2, 2, 0, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(16), { task -> Thread(task, "linux-guest-broker").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy())
    private val sendLock = Any()
    @Volatile private var remote: Messenger? = null
    @Volatile private var deathLink: Pair<IBinder, IBinder.DeathRecipient>? = null
    @Volatile private var bound = false
    @Volatile private var imageOffer: LinuxImageLeaseOwner.Offer? = null
    @Volatile private var imageCallId: String? = null
    @Volatile private var imageClaimed = false
    @Volatile private var imageSent = false
    @Volatile var imageStaged = false
        private set
    private var heldImage: LinuxImageDescriptorBroker.Descriptor? = null
    @Volatile var journalFailure: IOException? = null
        private set

    private val timeout = Runnable { close() }
    private val imageTimeout = Runnable { close() }
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (terminated.get()) return@Handler true
        try {
        val data = message.data
        val sendingUid = message.sendingUid
        if (sendingUid <= 0 || sendingUid == Process.myUid() ||
            data.getInt(IsolatedLinuxGuestBinderService.UID, -1) != sendingUid ||
            data.getString(IsolatedLinuxGuestBinderService.RUN_ID) != runId ||
            data.getString(IsolatedLinuxGuestBinderService.NONCE) != nonce) {
            close()
            return@Handler true
        }
        when (message.what) {
            IsolatedLinuxGuestBinderService.HELLO -> {
                if (!ready.compareAndSet(false, true) ||
                    !bridge.hello(runId, sendingUid, sendingUid, Process.myUid(),
                        data.getBoolean(IsolatedLinuxGuestBinderService.ISOLATED, false))) close()
                else if (imageBroker != null) startImageOffer()
            }
            IsolatedLinuxGuestBinderService.IMAGE_CLAIM -> {
                val offer = imageOffer
                val callId = data.getString(IsolatedLinuxGuestBinderService.CALL_ID)
                if (!ready.get() || imageBroker == null || offer == null ||
                    imageClaimed || !canonicalUuid(callId) ||
                    data.getString(IsolatedLinuxGuestBinderService.TOKEN) != offer.token() ||
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= offer.expiresAtMillis()) {
                    close()
                    return@Handler true
                }
                imageClaimed = true
                imageCallId = callId
                try {
                    workers.execute {
                        try {
                            val descriptor = imageBroker.claim(runId, offer.token())
                            var retained = false
                            try {
                                check(descriptor.sha256 == LinuxImageLeaseOwner.SHA256 &&
                                    descriptor.bytes == LinuxImageLeaseOwner.ARCHIVE_BYTES &&
                                    descriptor.version == LinuxImageLeaseOwner.VERSION &&
                                    descriptor.abi == LinuxImageLeaseOwner.ABI &&
                                    descriptor.expiresAtMillis == offer.expiresAtMillis())
                                synchronized(sendLock) {
                                    if (terminated.get() || !ready.get() || imageSent ||
                                        TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >=
                                        offer.expiresAtMillis()) return@synchronized
                                    heldImage = descriptor
                                    retained = true
                                    imageSent = true
                                    checkNotNull(remote).send(Message.obtain(null,
                                        IsolatedLinuxGuestBinderService.IMAGE_SNAPSHOT).apply {
                                        this.data = Bundle().apply {
                                            putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                                            putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                                            putString(IsolatedLinuxGuestBinderService.CALL_ID, callId)
                                            putParcelable(IsolatedLinuxGuestBinderService.IMAGE,
                                                descriptor.image)
                                        }
                                    })
                                }
                            } finally { if (!retained) descriptor.close() }
                        } catch (_: Exception) { close() }
                    }
                } catch (_: RuntimeException) { close() }
            }
            IsolatedLinuxGuestBinderService.IMAGE_STAGED -> {
                val offer = imageOffer
                if (!ready.get() || offer == null || !imageSent || imageStaged ||
                    data.getString(IsolatedLinuxGuestBinderService.CALL_ID) != imageCallId ||
                    data.getString(IsolatedLinuxGuestBinderService.STATUS) != "staged" ||
                    data.getString(IsolatedLinuxGuestBinderService.DIGEST) != offer.sha256() ||
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= offer.expiresAtMillis()) {
                    close()
                } else {
                    imageStaged = true
                    handler.removeCallbacks(imageTimeout)
                    synchronized(sendLock) { heldImage?.close(); heldImage = null }
                }
            }
            IsolatedLinuxGuestBinderService.FRAME -> {
                if (!ready.get()) { close(); return@Handler true }
                val frame = data.getByteArray(IsolatedLinuxGuestBinderService.BYTES)
                if (frame == null || frame.isEmpty() ||
                    frame.size > LinuxGuestBrokerWire.MAX_REQUEST_BYTES) {
                    close()
                    return@Handler true
                }
                try {
                    val bytes = frame.clone()
                    workers.execute {
                        val response = bridge.frame(runId, sendingUid, bytes)
                        if (response == null) { close(); return@execute }
                        synchronized(sendLock) {
                            if (terminated.get() || !bridge.active() || !lease.active(lease.policy().version())) {
                                close()
                                return@execute
                            }
                            try {
                                remote?.send(Message.obtain(null,
                                    IsolatedLinuxGuestBinderService.FRAME_REPLY).apply {
                                    this.data = Bundle().apply {
                                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                                        putByteArray(IsolatedLinuxGuestBinderService.BYTES, response)
                                    }
                                }) ?: close()
                            } catch (_: Exception) { close() }
                        }
                    }
                } catch (_: RuntimeException) { close() }
            }
            IsolatedLinuxGuestBinderService.END -> close()
            else -> close()
        }
        } catch (_: Exception) { close() }
        true
    })

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (terminated.get()) return
            try {
                val death = IBinder.DeathRecipient { close() }
                binder.linkToDeath(death, 0)
                deathLink = binder to death
                val guest = Messenger(binder)
                synchronized(sendLock) {
                    if (terminated.get()) {
                        binder.unlinkToDeath(death, 0)
                        deathLink = null
                        return
                    }
                    remote = guest
                    guest.send(Message.obtain(null, IsolatedLinuxGuestBinderService.OPEN).apply {
                        replyTo = replies
                        data = Bundle().apply {
                            putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                            putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                        }
                    })
                }
            } catch (_: Exception) { close() }
        }
        override fun onServiceDisconnected(name: ComponentName) { close() }
        override fun onBindingDied(name: ComponentName) { close() }
        override fun onNullBinding(name: ComponentName) { close() }
    }

    private fun startImageOffer() {
        val broker = imageBroker ?: return
        try {
            workers.execute {
                try {
                    val offer = broker.issue(runId, IMAGE_LEASE_MILLIS)
                    check(offer.runId() == runId &&
                        offer.version() == LinuxImageLeaseOwner.VERSION &&
                        offer.abi() == LinuxImageLeaseOwner.ABI &&
                        offer.sha256() == LinuxImageLeaseOwner.SHA256 &&
                        offer.bytes() == LinuxImageLeaseOwner.ARCHIVE_BYTES)
                    var sent = false
                    synchronized(sendLock) {
                        if (terminated.get() || !bridge.active() || imageOffer != null) return@synchronized
                        imageOffer = offer
                        handler.postDelayed(imageTimeout, IMAGE_LEASE_MILLIS)
                        checkNotNull(remote).send(Message.obtain(null,
                            IsolatedLinuxGuestBinderService.IMAGE_OFFER).apply {
                            data = Bundle().apply {
                                putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                                putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                                putString(IsolatedLinuxGuestBinderService.TOKEN, offer.token())
                                putString(IsolatedLinuxGuestBinderService.DIGEST, offer.sha256())
                                putString(IsolatedLinuxGuestBinderService.VERSION, offer.version())
                                putString(IsolatedLinuxGuestBinderService.ABI, offer.abi())
                                putLong(IsolatedLinuxGuestBinderService.LENGTH, offer.bytes())
                                putLong(IsolatedLinuxGuestBinderService.EXPIRES,
                                    offer.expiresAtMillis())
                            }
                        })
                        sent = true
                    }
                    if (!sent) broker.revoke(runId)
                } catch (_: Exception) { close() }
            }
        } catch (_: RuntimeException) { close() }
    }

    private fun canonicalUuid(value: String?): Boolean = try {
        value != null && UUID.fromString(value).toString() == value
    } catch (_: IllegalArgumentException) { false }

    init {
        require(runId == lease.runId() && session.matchesRunId(runId))
        require(journal.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED) {
            "Linux guest Binder requires a durable admitted run"
        }
        lease.onRevoked { close() }
    }

    /** Explicit App call only; no UI or Agent tool creates this binding. */
    fun bind(): Boolean {
        if (terminated.get() || !bindingStarted.compareAndSet(false, true)) return false
        try {
            val intent = Intent(app, IsolatedLinuxGuestBinderService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "linux_guest_" + nonce.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!bound) { close(); return false }
            if (terminated.get()) {
                app.unbindService(connection)
                bound = false
                return false
            }
            handler.postDelayed(timeout, LinuxGuestLaunchSession.MAX_DEADLINE_MILLIS)
            return true
        } catch (_: Exception) { close(); return false }
    }

    override fun close() {
        if (!terminated.compareAndSet(false, true)) return
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(imageTimeout)
        synchronized(sendLock) {
            runCatching {
                remote?.send(Message.obtain(null, IsolatedLinuxGuestBinderService.CANCEL).apply {
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    }
                })
            }
            remote = null
            heldImage?.close()
            heldImage = null
        }
        runCatching { imageBroker?.revoke(runId) }
        deathLink?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
        deathLink = null
        if (bound) { runCatching { app.unbindService(connection) }; bound = false }
        workers.shutdownNow()
        bridge.close()
        try { journal.serviceDied(session, runId) }
        catch (failure: Exception) {
            journalFailure = if (failure is IOException) failure
                else IOException("Linux guest failure receipt could not be stored", failure)
        }
    }
}
