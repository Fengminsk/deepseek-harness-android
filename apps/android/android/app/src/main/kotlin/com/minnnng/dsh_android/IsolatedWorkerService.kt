package com.minnnng.dsh_android

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.RemoteException
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Separate-UID descriptor bridge for proving Android worker isolation before PTC is enabled. */
class IsolatedWorkerService : Service() {
    companion object {
        const val PROBE = 1
        const val RESULT = 2
        const val READ_TEXT = 3
        const val CANCEL = 4
        const val EDIT_TEXT = 5
        const val SEARCH_TEXT = 6
        const val INPUT = "input"
        const val REQUEST_ID = "requestId"
        const val TEXT = "text"
        const val TOKEN = "token"
        const val UID = "uid"
        const val BYTES = "bytes"
        const val SHA256 = "sha256"
        const val PRIVATE_ACCESS = "privateAccess"
        const val PRIVATE_PATH = "privatePath"
        const val ERROR = "error"
        const val EDIT_NEEDLE = "editNeedle"
        const val EDIT_REPLACEMENT = "editReplacement"
        const val EDIT_MAX_REPLACEMENTS = "editMaxReplacements"
        const val SEARCH_QUERY = "searchQuery"
        const val SEARCH_MAX_MATCHES = "searchMaxMatches"
        const val SEARCH_HITS = "searchHits"
        const val SEARCH_TRUNCATED = "searchTruncated"
        const val SEARCH_LINE = "searchLine"
        const val SEARCH_COLUMN = "searchColumn"
        const val SEARCH_PREVIEW = "searchPreview"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private data class TextOperation(
        val id: String,
        val descriptor: ParcelFileDescriptor,
        val reply: Messenger,
        val edit: IsolatedWorkerTextEdit.Spec?,
        val search: IsolatedWorkerTextSearch.Spec?,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
    )
    // Handler callbacks, including onDestroy, own this reference on the main thread.
    private var activeText: TextOperation? = null
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.sendingUid != applicationInfo.uid) {
            @Suppress("DEPRECATION")
            (message.data.getParcelable<ParcelFileDescriptor>(INPUT))?.close()
            return@Handler true
        }
        if (message.what == CANCEL) {
            val id = message.data.getString(REQUEST_ID)
            val current = activeText
            if (current != null && current.id == id && current.cancelled.compareAndSet(false, true)) {
                activeText = null
                try { current.descriptor.close() } catch (_: Exception) { /* Worker reports its own terminal read failure. */ }
                send(current.reply, Bundle().apply {
                    putString(REQUEST_ID, current.id)
                    putString(ERROR, "Isolated-worker read cancelled")
                })
            }
            return@Handler true
        }
        if (message.what == READ_TEXT || message.what == EDIT_TEXT || message.what == SEARCH_TEXT) {
            val reply = message.replyTo ?: return@Handler true
            val data = message.data
            val descriptor = @Suppress("DEPRECATION") (data.getParcelable<ParcelFileDescriptor>(INPUT))
            val id = data.getString(REQUEST_ID)
            if (descriptor == null || id == null || !validRequestId(id)) {
                descriptor?.close()
                send(reply, Bundle().apply { putString(ERROR, "Invalid isolated-worker read") })
                return@Handler true
            }
            val edit = try {
                if (message.what == EDIT_TEXT) IsolatedWorkerTextEdit.Spec(
                    checkNotNull(data.getString(EDIT_NEEDLE)),
                    checkNotNull(data.getString(EDIT_REPLACEMENT)),
                    data.getInt(EDIT_MAX_REPLACEMENTS, -1),
                ) else null
            } catch (_: Exception) {
                descriptor.close()
                send(reply, Bundle().apply { putString(REQUEST_ID, id); putString(ERROR, "Invalid isolated-worker text edit") })
                return@Handler true
            }
            val search = try {
                if (message.what == SEARCH_TEXT) IsolatedWorkerTextSearch.Spec(
                    checkNotNull(data.getString(SEARCH_QUERY)),
                    data.getInt(SEARCH_MAX_MATCHES, -1),
                ) else null
            } catch (_: Exception) {
                descriptor.close()
                send(reply, Bundle().apply { putString(REQUEST_ID, id); putString(ERROR, "Invalid isolated-worker search") })
                return@Handler true
            }
            if (!busy.compareAndSet(false, true)) {
                descriptor.close()
                send(reply, Bundle().apply { putString(REQUEST_ID, id); putString(ERROR, "Isolated worker is busy") })
                return@Handler true
            }
            val operation = TextOperation(id, descriptor, reply, edit, search)
            activeText = operation
            try { worker.execute { readText(operation) } }
            catch (_: RejectedExecutionException) {
                activeText = null
                busy.set(false)
                descriptor.close()
                send(reply, Bundle().apply { putString(REQUEST_ID, id); putString(ERROR, "Isolated worker is stopping") })
            }
            return@Handler true
        }
        if (message.what != PROBE) return@Handler true
        val reply = message.replyTo ?: return@Handler true
        val data = message.data
        val descriptor = @Suppress("DEPRECATION") (data.getParcelable<ParcelFileDescriptor>(INPUT))
        val token = data.getString(TOKEN)
        if (descriptor == null || token == null || !Regex("[0-9a-f-]{36}").matches(token)) {
            descriptor?.close()
            send(reply, Bundle().apply { putString(ERROR, "Invalid isolated-worker probe") })
            return@Handler true
        }
        if (!busy.compareAndSet(false, true)) {
            descriptor.close()
            send(reply, Bundle().apply { putString(ERROR, "Isolated worker is busy") })
            return@Handler true
        }
        try { worker.execute {
            val result = Bundle()
            try {
                descriptor.use { fd ->
                    val stat = Os.fstat(fd.fileDescriptor)
                    require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 0..IsolatedWorkerInput.MAX_BYTES.toLong()) {
                        "Isolated-worker input must be a regular file of at most 256 KiB"
                    }
                    val digest = ParcelFileDescriptor.AutoCloseInputStream(fd).use { IsolatedWorkerInput.digest(it) }
                    result.putInt(UID, Process.myUid())
                    result.putInt(BYTES, digest.bytes())
                    result.putString(SHA256, digest.sha256())
                    val privateProbe = File(applicationInfo.dataDir, "files/ptc-isolation-$token")
                    result.putString(PRIVATE_PATH, privateProbe.absolutePath)
                    val privateAccess = try {
                        Os.close(Os.open(privateProbe.absolutePath, OsConstants.O_RDONLY, 0))
                        "readable"
                    } catch (error: ErrnoException) {
                        when (error.errno) {
                            OsConstants.EACCES, OsConstants.EPERM -> "denied"
                            OsConstants.ENOENT -> "missing"
                            else -> "errno:${error.errno}"
                        }
                    }
                    result.putString(PRIVATE_ACCESS, privateAccess)
                }
            } catch (error: Exception) {
                result.putString(ERROR, error.message ?: "Isolated-worker probe failed")
            } finally {
                busy.set(false)
            }
            send(reply, result)
        } } catch (_: RejectedExecutionException) {
            busy.set(false)
            descriptor.close()
            send(reply, Bundle().apply { putString(ERROR, "Isolated worker is stopping") })
        }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        activeText?.let { current ->
            current.cancelled.set(true)
            try { current.descriptor.close() } catch (_: Exception) { /* Service is stopping. */ }
        }
        activeText = null
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun readText(operation: TextOperation) {
        val result = Bundle().apply { putString(REQUEST_ID, operation.id) }
        try {
            check(!operation.cancelled.get()) { "Isolated-worker read cancelled" }
            operation.descriptor.use { descriptor ->
                val stat = Os.fstat(descriptor.fileDescriptor)
                require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 0..IsolatedWorkerInput.MAX_TEXT_BYTES.toLong()) {
                    "Isolated-worker text must be a regular file of at most 64 KiB"
                }
                require((Os.fcntlInt(descriptor.fileDescriptor, OsConstants.F_GETFL, 0) and OsConstants.O_ACCMODE) == OsConstants.O_RDONLY) {
                    "Isolated-worker text descriptor must be read-only"
                }
                val input = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { IsolatedWorkerInput.readUtf8(it) }
                check(!operation.cancelled.get()) { "Isolated-worker read cancelled" }
                result.putInt(UID, Process.myUid())
                if (operation.search != null) {
                    val matches = IsolatedWorkerTextSearch.search(input, operation.search)
                    check(!operation.cancelled.get()) { "Isolated-worker search cancelled" }
                    result.putParcelableArrayList(SEARCH_HITS, ArrayList(matches.hits().map { hit ->
                        Bundle().apply {
                            putInt(SEARCH_LINE, hit.line())
                            putInt(SEARCH_COLUMN, hit.column())
                            putString(SEARCH_PREVIEW, hit.preview())
                        }
                    }))
                    result.putBoolean(SEARCH_TRUNCATED, matches.truncated())
                } else {
                    val text = operation.edit?.let { IsolatedWorkerTextEdit.replace(input, it) } ?: input
                    check(!operation.cancelled.get()) { "Isolated-worker read cancelled" }
                    result.putString(TEXT, text)
                }
            }
        } catch (error: Exception) {
            result.putString(ERROR, error.message ?: "Isolated-worker read failed")
        } finally {
            Handler(Looper.getMainLooper()).post {
                if (activeText === operation) {
                    activeText = null
                    send(operation.reply, result)
                }
                busy.set(false)
            }
        }
    }

    private fun validRequestId(id: String): Boolean = try {
        UUID.fromString(id).toString() == id
    } catch (_: IllegalArgumentException) { false }

    private fun send(reply: Messenger, data: Bundle) {
        if (!data.containsKey(UID)) data.putInt(UID, Process.myUid())
        try { reply.send(Message.obtain(null, RESULT).apply { this.data = data }) }
        catch (_: RemoteException) { /* Caller death closes its descriptor and owns the timeout. */ }
    }
}
