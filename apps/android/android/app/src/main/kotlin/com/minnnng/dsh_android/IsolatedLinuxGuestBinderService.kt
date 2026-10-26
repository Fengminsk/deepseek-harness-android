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
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

/**
 * Dormant Binder endpoint for a future native Linux guest. It can verify and stage a pinned
 * rootfs as data, but never starts PRoot, opens a workspace file or publishes task success.
 */
class IsolatedLinuxGuestBinderService : Service() {
    companion object {
        const val OPEN = 1
        const val HELLO = 2
        const val FRAME = 3
        const val FRAME_REPLY = 4
        const val CANCEL = 5
        const val END = 6
        const val RUN_ID = "runId"
        const val NONCE = "nonce"
        const val UID = "uid"
        const val ISOLATED = "isolated"
        const val BYTES = "frame"
        const val IMAGE_OFFER = 7
        const val IMAGE_CLAIM = 8
        const val IMAGE_SNAPSHOT = 9
        const val IMAGE_STAGED = 10
        const val TOKEN = "imageToken"
        const val CALL_ID = "imageCallId"
        const val DIGEST = "imageDigest"
        const val VERSION = "imageVersion"
        const val ABI = "imageAbi"
        const val LENGTH = "imageLength"
        const val EXPIRES = "imageExpires"
        const val IMAGE = "image"
        const val STATUS = "imageStatus"
    }

    private class PendingImage(val token: String, val callId: String, val expires: Long) {
        var claimed = false
    }
    private class Active(val runId: String, val nonce: String, val app: Messenger) {
        val cancelled = AtomicBoolean(false)
        var pendingImage: PendingImage? = null
        var staged: LinuxGuestRootfsStager.Staged? = null
        var stagingParent: Path? = null
    }
    private var active: Active? = null
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.sendingUid != applicationInfo.uid || !Process.isIsolated()) return@Handler true
        try {
            when (message.what) {
                OPEN -> {
                    if (active != null) return@Handler true
                    val runId = message.data.getString(RUN_ID)
                    val nonce = message.data.getString(NONCE)
                    val app = message.replyTo
                    if (!canonicalUuid(runId) || !canonicalUuid(nonce) || app == null) return@Handler true
                    val request = Active(runId!!, nonce!!, app)
                    active = request
                    try {
                        app.send(Message.obtain(null, HELLO).apply {
                            data = Bundle().apply {
                                putString(RUN_ID, request.runId)
                                putString(NONCE, request.nonce)
                                putInt(UID, Process.myUid())
                                putBoolean(ISOLATED, Process.isIsolated())
                            }
                        })
                    } catch (_: Exception) { active = null }
                }
                CANCEL -> {
                    val request = active ?: return@Handler true
                    if (message.data.getString(RUN_ID) == request.runId &&
                        message.data.getString(NONCE) == request.nonce) retire(request)
                }
                IMAGE_OFFER -> {
                    val request = active ?: return@Handler true
                    val data = message.data
                    val now = TimeUnit.NANOSECONDS.toMillis(System.nanoTime())
                    val token = data.getString(TOKEN)
                    val expires = data.getLong(EXPIRES, -1)
                    if (data.getString(RUN_ID) != request.runId ||
                        data.getString(NONCE) != request.nonce || request.pendingImage != null ||
                        request.staged != null || !canonicalUuid(token) ||
                        data.getString(DIGEST) != LinuxImageLeaseOwner.SHA256 ||
                        data.getString(VERSION) != LinuxImageLeaseOwner.VERSION ||
                        data.getString(ABI) != LinuxImageLeaseOwner.ABI ||
                        data.getLong(LENGTH, -1) != LinuxImageLeaseOwner.ARCHIVE_BYTES ||
                        expires <= now || expires - now > 15_000) {
                        retire(request)
                        return@Handler true
                    }
                    // Reject an unusable cache before the App claims and copies the 4 MB image.
                    // The staging thread repeats this check immediately before writing.
                    if (runCatching {
                            LinuxGuestStagingPreflight.requireEmptyWritableParent(cacheDir.toPath())
                        }.isFailure) {
                        runCatching {
                            request.app.send(Message.obtain(null, END).apply {
                                this.data = Bundle().apply {
                                    putString(RUN_ID, request.runId)
                                    putString(NONCE, request.nonce)
                                    putInt(UID, Process.myUid())
                                }
                            })
                        }
                        retire(request)
                        return@Handler true
                    }
                    val pending = PendingImage(token!!, UUID.randomUUID().toString(), expires)
                    request.pendingImage = pending
                    try {
                        request.app.send(Message.obtain(null, IMAGE_CLAIM).apply {
                            this.data = Bundle().apply {
                                putString(RUN_ID, request.runId)
                                putString(NONCE, request.nonce)
                                putString(TOKEN, pending.token)
                                putString(CALL_ID, pending.callId)
                                putInt(UID, Process.myUid())
                            }
                        })
                    } catch (_: Exception) { retire(request) }
                }
                IMAGE_SNAPSHOT -> {
                    val data = message.data
                    data.classLoader = SharedMemory::class.java.classLoader
                    val image = data.getParcelable<SharedMemory>(IMAGE)
                    val request = active
                    val pending = request?.pendingImage
                    if (request == null || pending == null) {
                        image?.close()
                        return@Handler true
                    }
                    if (pending.claimed || data.getString(RUN_ID) != request.runId ||
                        data.getString(NONCE) != request.nonce ||
                        data.getString(CALL_ID) != pending.callId ||
                        TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= pending.expires) {
                        image?.close()
                        retire(request)
                        return@Handler true
                    }
                    pending.claimed = true
                    if (image == null) { retire(request); return@Handler true }
                    try { Thread({
                        var staged: LinuxGuestRootfsStager.Staged? = null
                        var parent: Path? = null
                        val error = try {
                            check(Process.isIsolated() && !request.cancelled.get())
                            check(image.size.toLong() == LinuxImageLeaseOwner.ARCHIVE_BYTES)
                            var writable = false
                            try {
                                val map = image.mapReadWrite()
                                writable = true
                                SharedMemory.unmap(map)
                            } catch (_: Exception) { /* A sealed snapshot denies a writable map. */ }
                            check(!writable) { "Linux image descriptor permits writing" }
                            val cache = cacheDir.toPath()
                            LinuxGuestStagingPreflight.requireEmptyWritableParent(cache)
                            val mapped = image.mapReadOnly()
                            try {
                                val stageParent = Files.createDirectory(
                                    cache.resolve("linux-guest-root-" + request.runId))
                                parent = stageParent
                                staged = LinuxGuestRootfsStager.stagePinned(mapped, stageParent,
                                    request.runId) {
                                    request.cancelled.get() ||
                                        TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) >= pending.expires
                                }
                            } finally { SharedMemory.unmap(mapped) }
                            check(!request.cancelled.get() &&
                                TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) < pending.expires)
                            null
                        } catch (failure: Exception) {
                            failure.message?.take(160) ?: "Linux image staging rejected"
                        } finally { image.close() }
                        val completedStage = staged
                        val createdParent = parent
                        val posted = Handler(Looper.getMainLooper()).post {
                            if (active !== request || request.cancelled.get() || error != null) {
                                closeStage(completedStage, createdParent)
                                if (active === request) {
                                    sendImageState(request, pending, false)
                                    retire(request)
                                }
                            } else {
                                request.staged = completedStage
                                request.stagingParent = createdParent
                                request.pendingImage = null
                                // This acknowledges data staging only. It is never a run result.
                                sendImageState(request, pending, true)
                            }
                        }
                        if (!posted) closeStage(completedStage, createdParent)
                    }, "isolated-linux-image-stage").apply { isDaemon = true; start() }
                    } catch (_: Exception) {
                        image.close()
                        retire(request)
                    }
                }
                FRAME_REPLY -> {
                    // There is no native guest to consume a reply yet. Reject it and
                    // retire the channel instead of pretending that a command ran.
                    active?.let { request ->
                        runCatching {
                            request.app.send(Message.obtain(null, END).apply {
                                data = Bundle().apply {
                                    putString(RUN_ID, request.runId)
                                    putString(NONCE, request.nonce)
                                    putInt(UID, Process.myUid())
                                }
                            })
                        }
                    }
                    retire(active)
                }
                else -> retire(active)
            }
        } catch (_: Exception) { retire(active) }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        retire(active)
        super.onDestroy()
    }

    private fun sendImageState(request: Active, pending: PendingImage, staged: Boolean) {
        try {
            request.app.send(Message.obtain(null, IMAGE_STAGED).apply {
                data = Bundle().apply {
                    putString(RUN_ID, request.runId)
                    putString(NONCE, request.nonce)
                    putString(CALL_ID, pending.callId)
                    putString(DIGEST, if (staged) LinuxImageLeaseOwner.SHA256 else null)
                    putString(STATUS, if (staged) "staged" else "rejected")
                    putInt(UID, Process.myUid())
                }
            })
        } catch (_: Exception) { retire(request) }
    }

    private fun closeStage(stage: LinuxGuestRootfsStager.Staged?, parent: Path?) {
        runCatching { stage?.close() }
        if (parent != null) runCatching { Files.deleteIfExists(parent) }
    }

    private fun retire(request: Active?) {
        if (request == null) return
        request.cancelled.set(true)
        closeStage(request.staged, request.stagingParent)
        request.staged = null
        request.stagingParent = null
        if (active === request) active = null
    }

    private fun canonicalUuid(value: String?): Boolean = try {
        value != null && UUID.fromString(value).toString() == value
    } catch (_: IllegalArgumentException) { false }
}
