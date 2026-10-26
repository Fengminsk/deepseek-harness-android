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
import android.os.SharedMemory
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Separate-UID guest for echo diagnostics and read-only image verification, never script execution. */
class IsolatedGuestService : Service() {
    companion object {
        const val REQUEST = 1
        const val BROKER_CALL = 2
        const val BROKER_RESULT = 3
        const val COMPLETE = 4
        const val CANCEL = 5
        const val IMAGE_OFFER = 6
        const val IMAGE_CLAIM = 7
        const val IMAGE_SNAPSHOT = 8
        const val IMAGE_RESULT = 9
        const val IMAGE_CANCEL = 10
        const val ID = "requestId"
        const val CALL_ID = "callId"
        const val JSON = "json"
        const val STATUS = "status"
        const val ERROR = "error"
        const val UID = "uid"
        const val TOKEN = "token"
        const val DIGEST = "sha256"
        const val VERSION = "version"
        const val ABI = "abi"
        const val BYTES = "bytes"
        const val EXPIRES = "expiresAtMillis"
        const val IMAGE = "image"
        const val ISOLATED = "isolated"
    }

    private data class Active(val id: String, val callId: String, val reply: Messenger)
    private data class ImageActive(
        val id: String, val callId: String, val token: String, val digest: String,
        val version: String, val abi: String, val bytes: Long, val expires: Long,
        val reply: Messenger, val cancelled: AtomicBoolean = AtomicBoolean(false),
        var claimed: Boolean = false,
    )
    // Binder callbacks and onDestroy run on the main thread.
    private var active: Active? = null
    private var imageActive: ImageActive? = null
    private val messenger: Messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        try {
        if (message.sendingUid != applicationInfo.uid) return@Handler true
        val data = message.data
        when (message.what) {
            REQUEST -> {
                val reply = message.replyTo ?: return@Handler true
                val id = data.getString(ID)
                val raw = data.getString(JSON)
                if (id == null || !validId(id) || raw == null || active != null || imageActive != null) {
                    send(reply, id, "error", error = "Invalid or concurrent guest request")
                    return@Handler true
                }
                try { GuestEchoFrame.request(raw) }
                    catch (_: Exception) {
                        send(reply, id, "error", error = "Guest request rejected")
                        return@Handler true
                    }
                val request = Active(id, UUID.randomUUID().toString(), reply)
                active = request
                try {
                    reply.send(Message.obtain(null, BROKER_CALL).apply {
                        replyTo = messenger
                        this.data = Bundle().apply {
                            putString(ID, id)
                            putString(CALL_ID, request.callId)
                            putString(JSON, raw)
                            putInt(UID, Process.myUid())
                        }
                    })
                } catch (_: Exception) { active = null }
            }
            BROKER_RESULT -> {
                val request = active ?: return@Handler true
                if (data.getString(ID) != request.id || data.getString(CALL_ID) != request.callId) return@Handler true
                val text = try { GuestEchoFrame.brokerResult(checkNotNull(data.getString(JSON))) }
                    catch (_: Exception) {
                        active = null
                        send(request.reply, request.id, "error", error = "Guest broker result rejected")
                        return@Handler true
                    }
                active = null
                send(request.reply, request.id, "completed", GuestEchoFrame.completionForText(text))
            }
            CANCEL -> {
                val request = active ?: return@Handler true
                if (data.getString(ID) == request.id) {
                    active = null
                    send(request.reply, request.id, "cancelled")
                }
            }
            IMAGE_OFFER -> {
                val reply = message.replyTo ?: return@Handler true
                val id = data.getString(ID)
                val token = data.getString(TOKEN)
                val digest = data.getString(DIGEST)
                val version = data.getString(VERSION)
                val abi = data.getString(ABI)
                val bytes = data.getLong(BYTES, -1)
                val expires = data.getLong(EXPIRES, -1)
                val now = TimeUnit.NANOSECONDS.toMillis(System.nanoTime())
                if (id == null || !validId(id) || token == null || !validId(token) ||
                    digest == null || !digest.matches(Regex("[0-9a-f]{64}")) ||
                    version == null || !version.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")) ||
                    abi != LinuxImageLeaseOwner.ABI || bytes !in 1..(8L * 1024 * 1024) ||
                    expires <= now || expires - now > 60_000 ||
                    active != null || imageActive != null || !Process.isIsolated()) {
                    sendImage(reply, id, null, "error", error = "Image offer rejected")
                    return@Handler true
                }
                val offer = ImageActive(id, UUID.randomUUID().toString(), token, digest,
                    version, abi, bytes, expires, reply)
                imageActive = offer
                try {
                    reply.send(Message.obtain(null, IMAGE_CLAIM).apply {
                        replyTo = messenger
                        this.data = Bundle().apply {
                            putString(ID, offer.id)
                            putString(CALL_ID, offer.callId)
                            putString(TOKEN, offer.token)
                            putInt(UID, Process.myUid())
                        }
                    })
                } catch (_: Exception) { imageActive = null }
            }
            IMAGE_SNAPSHOT -> {
                val offer = imageActive ?: return@Handler true
                if (offer.claimed || data.getString(ID) != offer.id ||
                    data.getString(CALL_ID) != offer.callId) return@Handler true
                offer.claimed = true
                data.classLoader = SharedMemory::class.java.classLoader
                val snapshot = data.getParcelable<SharedMemory>(IMAGE)
                if (snapshot == null) {
                    imageActive = null
                    sendImage(offer.reply, offer.id, offer.callId, "error", error = "Image descriptor missing")
                    return@Handler true
                }
                try {
                    Thread({
                        val result = try {
                            verifyImageSnapshot(snapshot, offer)
                            null
                        } catch (failure: Exception) { failure.message ?: "Image descriptor rejected" }
                        finally { snapshot.close() }
                        Handler(Looper.getMainLooper()).post {
                            if (imageActive === offer && !offer.cancelled.get()) {
                                imageActive = null
                                sendImage(offer.reply, offer.id, offer.callId,
                                    if (result == null) "verified" else "error",
                                    if (result == null) offer.digest else null, result,
                                    offer.version, offer.abi, offer.bytes)
                            }
                        }
                    }, "isolated-image-verify").apply { isDaemon = true; start() }
                } catch (failure: Exception) {
                    snapshot.close()
                    imageActive = null
                    sendImage(offer.reply, offer.id, offer.callId, "error",
                        error = "Image verifier could not start")
                }
            }
            IMAGE_CANCEL -> {
                val offer = imageActive ?: return@Handler true
                if (data.getString(ID) == offer.id) {
                    offer.cancelled.set(true)
                    imageActive = null
                }
            }
        }
        } catch (_: Exception) {
            if (message.what == REQUEST) {
                message.replyTo?.let { send(it, null, "error", error = "Guest request envelope rejected") }
            } else if (message.what == IMAGE_OFFER || message.what == IMAGE_SNAPSHOT) {
                imageActive?.let { offer ->
                    offer.cancelled.set(true)
                    imageActive = null
                    sendImage(offer.reply, offer.id, offer.callId, "error", error = "Image envelope rejected")
                }
            } else {
                active?.let { request ->
                    active = null
                    send(request.reply, request.id, "error", error = "Guest callback envelope rejected")
                }
            }
        }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        active = null
        imageActive?.cancelled?.set(true)
        imageActive = null
        super.onDestroy()
    }

    private fun verifyImageSnapshot(image: SharedMemory, offer: ImageActive) {
        check(Process.isIsolated()) { "Image guest is not isolated" }
        check(!offer.cancelled.get()) { "Image request cancelled" }
        check(image.size.toLong() == offer.bytes) { "Image byte count changed" }
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) < offer.expires) { "Image lease expired" }
        var writable = false
        try {
            val mapping = image.mapReadWrite()
            writable = true
            SharedMemory.unmap(mapping)
        } catch (_: Exception) { /* A sealed descriptor rejects a writable mapping. */ }
        check(!writable) { "Image descriptor permits writing" }
        val mapped: ByteBuffer = image.mapReadOnly()
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            while (mapped.hasRemaining()) {
                check(!offer.cancelled.get()) { "Image request cancelled" }
                val count = minOf(buffer.size, mapped.remaining())
                mapped.get(buffer, 0, count)
                digest.update(buffer, 0, count)
            }
            check(ImageDigestHex.encode(digest.digest()) == offer.digest) {
                "Image snapshot digest changed"
            }
            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) < offer.expires) {
                "Image lease expired during verification"
            }
        } finally { SharedMemory.unmap(mapped) }
    }

    private fun sendImage(reply: Messenger, id: String?, callId: String?, status: String,
                          digest: String? = null, error: String? = null, version: String? = null,
                          abi: String? = null, bytes: Long = -1) {
        try {
            reply.send(Message.obtain(null, IMAGE_RESULT).apply {
                data = Bundle().apply {
                    putString(ID, id)
                    putString(CALL_ID, callId)
                    putString(STATUS, status)
                    putString(DIGEST, digest)
                    putString(ERROR, error)
                    putString(VERSION, version)
                    putString(ABI, abi)
                    putLong(BYTES, bytes)
                    putBoolean(ISOLATED, Process.isIsolated())
                    putInt(UID, Process.myUid())
                }
            })
        } catch (_: Exception) { /* An App process that died cannot consume this receipt. */ }
    }

    private fun send(reply: Messenger, id: String?, status: String, json: String? = null, error: String? = null) {
        try {
            reply.send(Message.obtain(null, COMPLETE).apply {
                data = Bundle().apply {
                    putString(ID, id)
                    putString(STATUS, status)
                    putString(JSON, json)
                    putString(ERROR, error)
                    putInt(UID, Process.myUid())
                }
            })
        } catch (_: Exception) { /* A dead or rejecting App process cannot consume this result. */ }
    }

    private fun validId(id: String): Boolean = try { UUID.fromString(id).toString() == id }
        catch (_: IllegalArgumentException) { false }
}
