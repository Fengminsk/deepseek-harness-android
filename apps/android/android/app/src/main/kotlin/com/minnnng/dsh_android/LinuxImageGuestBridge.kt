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
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** Delivers one App-authorized, immutable archive snapshot to a separate-UID verifier. */
internal object LinuxImageGuestBridge {
    private const val LEASE_MILLIS = 15_000L

    internal interface Source {
        fun issue(runId: String, leaseMillis: Long): LinuxImageLeaseOwner.Offer
        fun claim(runId: String, token: String): LinuxImageDescriptorBroker.Descriptor
        fun revoke(runId: String)
    }

    data class Result(val verified: Boolean, val sha256: String?, val guestUid: Int?,
                      val detail: String?)

    fun verify(context: Context, broker: LinuxImageDescriptorBroker,
               cancelled: BooleanSupplier): Result = verify(context, object : Source {
        override fun issue(runId: String, leaseMillis: Long) = broker.issue(runId, leaseMillis)
        override fun claim(runId: String, token: String) = broker.claim(runId, token)
        override fun revoke(runId: String) = broker.revoke(runId)
    }, cancelled)

    /** Fixture sources are confined to AndroidTest; production uses the pinned broker. */
    internal fun verify(context: Context, source: Source, cancelled: BooleanSupplier): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) {
            "Image guest verification cannot block the main thread"
        }
        val app = context.applicationContext
        val id = UUID.randomUUID().toString()
        val offer = try { source.issue(id, LEASE_MILLIS) }
        catch (failure: Exception) {
            return Result(false, null, null, failure.message ?: "Image offer failed")
        }
        val completed = CountDownLatch(1)
        val outcome = AtomicReference<Result?>()
        val active = AtomicBoolean(true)
        val claimed = AtomicBoolean(false)
        val snapshotSent = AtomicBoolean(false)
        val expectedCallId = AtomicReference<String?>()
        val heldDescriptor = AtomicReference<LinuxImageDescriptorBroker.Descriptor?>()
        val guestUid = AtomicInteger(-1)
        val remote = AtomicReference<Messenger?>()
        val deathLink = AtomicReference<Pair<IBinder, IBinder.DeathRecipient>?>()
        val sendLock = Any()
        val worker = Executors.newSingleThreadExecutor { task ->
            Thread(task, "linux-image-snapshot-claim").apply { isDaemon = true }
        }

        fun finish(verified: Boolean, detail: String? = null) {
            if (outcome.compareAndSet(null, Result(verified,
                    if (verified) offer.sha256() else null,
                    guestUid.get().takeIf { it >= 0 }, detail))) completed.countDown()
        }

        fun senderValid(message: Message): Boolean {
            val sender = message.sendingUid
            val reported = message.data.getInt(IsolatedGuestService.UID, -1)
            if (sender < 0 || sender == Process.myUid() || sender != reported) return false
            val previous = guestUid.get()
            if (previous >= 0 && previous != sender) return false
            guestUid.compareAndSet(-1, sender)
            return true
        }

        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                if (!active.get() || outcome.get() != null) return@Handler true
                if (message.what != IsolatedGuestService.IMAGE_CLAIM &&
                    message.what != IsolatedGuestService.IMAGE_RESULT) return@Handler true
                val data = message.data
                if (!senderValid(message) || data.getString(IsolatedGuestService.ID) != id) {
                    finish(false, "Image guest identity rejected")
                    return@Handler true
                }
                when (message.what) {
                    IsolatedGuestService.IMAGE_CLAIM -> {
                        val callId = data.getString(IsolatedGuestService.CALL_ID)
                        if (callId == null || !validId(callId) ||
                            data.getString(IsolatedGuestService.TOKEN) != offer.token() ||
                            !claimed.compareAndSet(false, true)) {
                            finish(false, "Image claim rejected")
                            return@Handler true
                        }
                        expectedCallId.set(callId)
                        worker.execute {
                            try {
                                val descriptor = source.claim(id, offer.token())
                                var retained = false
                                try {
                                    check(descriptor.sha256 == offer.sha256() &&
                                        descriptor.bytes == offer.bytes() &&
                                        descriptor.version == offer.version() &&
                                        descriptor.abi == offer.abi() &&
                                        descriptor.expiresAtMillis == offer.expiresAtMillis()) {
                                        "Image claim changed offered metadata"
                                    }
                                    synchronized(sendLock) {
                                        if (active.get() && outcome.get() == null &&
                                            !cancelled.getAsBoolean()) {
                                            check(snapshotSent.compareAndSet(false, true))
                                            heldDescriptor.set(descriptor)
                                            retained = true
                                            checkNotNull(remote.get()).send(
                                                Message.obtain(null, IsolatedGuestService.IMAGE_SNAPSHOT).apply {
                                                    this.data = Bundle().apply {
                                                        putString(IsolatedGuestService.ID, id)
                                                        putString(IsolatedGuestService.CALL_ID, callId)
                                                        putParcelable(IsolatedGuestService.IMAGE, descriptor.image)
                                                    }
                                                },
                                            )
                                        }
                                    }
                                } finally {
                                    if (!retained) descriptor.close()
                                }
                            } catch (failure: Exception) {
                                finish(false, failure.message ?: "Image claim failed")
                            }
                        }
                    }
                    IsolatedGuestService.IMAGE_RESULT -> {
                        if (!claimed.get() || !snapshotSent.get() ||
                            data.getString(IsolatedGuestService.CALL_ID) != expectedCallId.get() ||
                            data.getString(IsolatedGuestService.STATUS) != "verified" ||
                            data.getString(IsolatedGuestService.DIGEST) != offer.sha256() ||
                            data.getString(IsolatedGuestService.VERSION) != offer.version() ||
                            data.getString(IsolatedGuestService.ABI) != offer.abi() ||
                            data.getLong(IsolatedGuestService.BYTES, -1) != offer.bytes() ||
                            !data.getBoolean(IsolatedGuestService.ISOLATED, false) ||
                            TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= offer.expiresAtMillis()) {
                            finish(false, data.getString(IsolatedGuestService.ERROR) ?: "Image receipt rejected")
                        } else finish(true)
                    }
                }
            } catch (_: Exception) { finish(false, "Image Binder envelope rejected") }
            true
        })

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    synchronized(sendLock) {
                        if (!active.get() || outcome.get() != null) return
                        val death = IBinder.DeathRecipient { finish(false, "Image guest died") }
                        binder.linkToDeath(death, 0)
                        deathLink.set(binder to death)
                        if (outcome.get() != null) return
                        val guest = Messenger(binder)
                        remote.set(guest)
                        guest.send(Message.obtain(null, IsolatedGuestService.IMAGE_OFFER).apply {
                            replyTo = replies
                            data = Bundle().apply {
                                putString(IsolatedGuestService.ID, id)
                                putString(IsolatedGuestService.TOKEN, offer.token())
                                putString(IsolatedGuestService.DIGEST, offer.sha256())
                                putString(IsolatedGuestService.VERSION, offer.version())
                                putString(IsolatedGuestService.ABI, offer.abi())
                                putLong(IsolatedGuestService.BYTES, offer.bytes())
                                putLong(IsolatedGuestService.EXPIRES, offer.expiresAtMillis())
                            }
                        })
                    }
                } catch (failure: Exception) {
                    finish(false, failure.message ?: "Image guest binding failed")
                }
            }

            override fun onServiceDisconnected(name: ComponentName) { finish(false, "Image guest disconnected") }
            override fun onBindingDied(name: ComponentName) { finish(false, "Image guest binding died") }
            override fun onNullBinding(name: ComponentName) { finish(false, "Image guest returned no binder") }
        }

        var bound = false
        try {
            val intent = Intent(app, IsolatedGuestService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val instance = "linux_image_" + id.replace("-", "")
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE, instance,
                    app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind image guest" }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(LEASE_MILLIS)
            while (outcome.get() == null) {
                if (cancelled.getAsBoolean()) {
                    finish(false, "Image verification cancelled")
                    break
                }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) {
                    finish(false, "Image guest verification timed out")
                    break
                }
                completed.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)),
                    TimeUnit.NANOSECONDS)
            }
        } catch (failure: InterruptedException) {
            Thread.currentThread().interrupt()
            finish(false, "Image verification interrupted")
        } catch (failure: Exception) {
            finish(false, failure.message ?: "Image verification failed")
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (outcome.get()?.verified != true) {
                    try {
                        remote.get()?.send(Message.obtain(null, IsolatedGuestService.IMAGE_CANCEL).apply {
                            data = Bundle().apply { putString(IsolatedGuestService.ID, id) }
                        })
                    } catch (_: Exception) { /* No further guest work is admitted. */ }
                }
                deathLink.getAndSet(null)?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
                heldDescriptor.getAndSet(null)?.close()
            }
            worker.shutdownNow()
            try { source.revoke(id) }
            finally { if (bound) app.unbindService(connection) }
        }
        return checkNotNull(outcome.get())
    }

    private fun validId(id: String): Boolean = try { UUID.fromString(id).toString() == id }
        catch (_: IllegalArgumentException) { false }
}
