package com.minnnng.dsh_android

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** Per-call App-granted text descriptor transport; it does not accept a path or run model code. */
object IsolatedWorkerBridge {
    data class Text(val workerUid: Int, val content: String)
    data class SearchHit(val line: Int, val column: Int, val preview: String)
    data class Search(val workerUid: Int, val revision: String, val hits: List<SearchHit>, val truncated: Boolean)
    private data class Reply(
        val workerUid: Int, val content: String? = null,
        val hits: List<SearchHit>? = null, val truncated: Boolean = false,
    )
    private data class Outcome(val reply: Reply? = null, val error: Throwable? = null)

    /** Caller retains [input] and must invoke this from a background thread. */
    fun readText(context: Context, input: ParcelFileDescriptor): Text = readText(context, input, BooleanSupplier { false })

    /** Cancellation is request-specific and closes the worker grant before returning. */
    fun readText(context: Context, input: ParcelFileDescriptor, cancelled: BooleanSupplier): Text {
        val reply = requestWorker(context, input, cancelled, null, null)
        return Text(reply.workerUid, checkNotNull(reply.content))
    }

    private fun requestWorker(
        context: Context, input: ParcelFileDescriptor, cancelled: BooleanSupplier,
        edit: IsolatedWorkerTextEdit.Spec?, search: IsolatedWorkerTextSearch.Spec?,
    ): Reply {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated-worker read cannot block the main thread" }
        check(!cancelled.getAsBoolean()) { "Isolated-worker read cancelled" }
        val app = context.applicationContext
        val id = UUID.randomUUID().toString()
        val finished = CountDownLatch(1)
        val outcome = AtomicReference<Outcome?>()
        val remote = AtomicReference<Messenger?>()
        val active = AtomicBoolean(true)
        val sendLock = Any()
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (message.what == IsolatedWorkerService.RESULT) {
                val received = try { Outcome(reply = parse(message.data, id, message.sendingUid, search != null)) }
                    catch (error: Exception) { Outcome(error = error) }
                if (outcome.compareAndSet(null, received)) finished.countDown()
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val worker = Messenger(binder)
                try {
                    synchronized(sendLock) {
                        remote.set(worker)
                        if (!active.get() || outcome.get() != null) return
                        ParcelFileDescriptor.dup(input.fileDescriptor).use { copy ->
                            val kind = when {
                                edit != null -> IsolatedWorkerService.EDIT_TEXT
                                search != null -> IsolatedWorkerService.SEARCH_TEXT
                                else -> IsolatedWorkerService.READ_TEXT
                            }
                            val request = Message.obtain(null, kind)
                            request.replyTo = replies
                            request.data = Bundle().apply {
                                putString(IsolatedWorkerService.REQUEST_ID, id)
                                putParcelable(IsolatedWorkerService.INPUT, copy)
                                if (edit != null) {
                                    putString(IsolatedWorkerService.EDIT_NEEDLE, edit.needle())
                                    putString(IsolatedWorkerService.EDIT_REPLACEMENT, edit.replacement())
                                    putInt(IsolatedWorkerService.EDIT_MAX_REPLACEMENTS, edit.maxReplacements())
                                }
                                if (search != null) {
                                    putString(IsolatedWorkerService.SEARCH_QUERY, search.query())
                                    putInt(IsolatedWorkerService.SEARCH_MAX_MATCHES, search.maxMatches())
                                }
                            }
                            worker.send(request)
                        }
                    }
                } catch (error: Exception) { fail(error) }
            }

            override fun onServiceDisconnected(name: ComponentName) = fail(IllegalStateException("Isolated worker disconnected"))
            override fun onBindingDied(name: ComponentName) = fail(IllegalStateException("Isolated worker binding died"))
            override fun onNullBinding(name: ComponentName) = fail(IllegalStateException("Isolated worker returned no binder"))

            private fun fail(error: Exception) {
                if (outcome.compareAndSet(null, Outcome(error = error))) finished.countDown()
            }
        }
        var bound = false
        var terminal = false
        try {
            bound = app.bindService(Intent(app, IsolatedWorkerService::class.java), connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated worker" }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (true) {
                check(!cancelled.getAsBoolean()) { "Isolated-worker read cancelled" }
                val remaining = deadline - System.nanoTime()
                check(remaining > 0) { "Isolated worker did not answer within 5 seconds" }
                if (finished.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)) break
            }
            val result = checkNotNull(outcome.get()) { "Isolated worker returned no outcome" }
            result.error?.let { throw it }
            terminal = true
            return checkNotNull(result.reply) { "Isolated worker returned no result" }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw error
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (!terminal) {
                    try {
                        remote.get()?.send(Message.obtain(null, IsolatedWorkerService.CANCEL).apply {
                            data = Bundle().apply { putString(IsolatedWorkerService.REQUEST_ID, id) }
                        })
                    } catch (_: Exception) { /* A dead worker cannot keep processing this request. */ }
                }
            }
            if (bound) app.unbindService(connection)
        }
    }

    /** The App selects a private workspace target and expected revision; the worker only sees [input]. */
    fun writeTextBack(
        context: Context,
        input: ParcelFileDescriptor,
        workspaceRoot: File,
        filename: String,
        expectedSha256: String,
        cancelled: BooleanSupplier,
    ): IsolatedWorkerWriteback.Receipt {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated-worker writeback cannot block the main thread" }
        val app = context.applicationContext
        val writeback = writer(app, workspaceRoot)
        check(writeback.version(filename) == expectedSha256) { "Workspace file changed before writeback" }
        val workerText = readText(app, input, cancelled)
        return writeback.commit(filename, expectedSha256, workerText.content.toByteArray(Charsets.UTF_8), cancelled)
    }

    /** App-selected relative-path edit; the separate-UID worker sees only bounded text and literals. */
    fun replaceWorkspaceText(
        context: Context,
        workspaceRoot: File,
        filename: String,
        expectedSha256: String,
        needle: String,
        replacement: String,
        maxReplacements: Int,
        cancelled: BooleanSupplier,
    ): IsolatedWorkerWriteback.Receipt {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated-worker edit cannot block the main thread" }
        val app = context.applicationContext
        val edit = IsolatedWorkerTextEdit.Spec(needle, replacement, maxReplacements)
        val writeback = writer(app, workspaceRoot)
        val snapshot = writeback.snapshot(filename, cancelled)
        check(snapshot.sha256() == expectedSha256) { "Workspace file changed before worker edit" }
        return withSnapshotGrant(app, snapshot) { input ->
            val workerText = requestWorker(app, input, cancelled, edit, null)
            writeback.commit(filename, expectedSha256,
                checkNotNull(workerText.content).toByteArray(Charsets.UTF_8), cancelled)
        }
    }

    /** Search one App-selected workspace snapshot without disclosing its path to the separate-UID worker. */
    fun searchWorkspaceText(
        context: Context,
        workspaceRoot: File,
        filename: String,
        query: String,
        maxMatches: Int,
        cancelled: BooleanSupplier,
    ): Search {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated-worker search cannot block the main thread" }
        val app = context.applicationContext
        val spec = IsolatedWorkerTextSearch.Spec(query, maxMatches)
        val snapshot = writer(app, workspaceRoot).snapshot(filename, cancelled)
        return withSnapshotGrant(app, snapshot) { input ->
            val reply = requestWorker(app, input, cancelled, null, spec)
            Search(reply.workerUid, snapshot.sha256(), checkNotNull(reply.hits), reply.truncated)
        }
    }

    private fun <T> withSnapshotGrant(
        app: Context, snapshot: IsolatedWorkerWriteback.Snapshot,
        action: (ParcelFileDescriptor) -> T,
    ): T {
        val grant = File.createTempFile("ptc-workspace-grant-", ".txt", app.cacheDir)
        try {
            FileOutputStream(grant).use { output ->
                output.write(snapshot.content())
                output.fd.sync()
            }
            return ParcelFileDescriptor.open(grant, ParcelFileDescriptor.MODE_READ_ONLY).use(action)
        } finally {
            check(grant.delete() || !grant.exists()) { "Could not remove isolated-worker grant" }
        }
    }

    private fun writer(app: Context, workspaceRoot: File): IsolatedWorkerWriteback =
        IsolatedWorkerWriteback(File(app.applicationInfo.dataDir).toPath(), workspaceRoot.toPath()) { directory ->
            try {
                val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0)
                try {
                    check(OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) { "Workspace sync target is not a directory" }
                    Os.fsync(descriptor)
                } finally { Os.close(descriptor) }
            } catch (error: Exception) { throw IOException("Could not sync workspace directory", error) }
        }

    private fun parse(data: Bundle, id: String, senderUid: Int, searchExpected: Boolean): Reply {
        check(data.getString(IsolatedWorkerService.REQUEST_ID) == id) { "Isolated worker answered a different request" }
        val uid = data.getInt(IsolatedWorkerService.UID, -1)
        check(senderUid >= 0 && senderUid == uid && uid != Process.myUid()) {
            "Worker response did not originate from its reported separate UID"
        }
        data.getString(IsolatedWorkerService.ERROR)?.let { throw IllegalStateException(it) }
        if (searchExpected) {
            @Suppress("DEPRECATION")
            val raw = checkNotNull(data.getParcelableArrayList<Bundle>(IsolatedWorkerService.SEARCH_HITS)) {
                "Isolated worker returned no search results"
            }
            check(raw.size <= IsolatedWorkerTextSearch.MAX_MATCHES) { "Isolated worker returned too many search results" }
            val hits = raw.map { hit ->
                val line = hit.getInt(IsolatedWorkerService.SEARCH_LINE, 0)
                val column = hit.getInt(IsolatedWorkerService.SEARCH_COLUMN, 0)
                val preview = checkNotNull(hit.getString(IsolatedWorkerService.SEARCH_PREVIEW)) {
                    "Isolated worker returned a search hit without preview"
                }
                check(line > 0 && column > 0 && preview.codePointCount(0, preview.length) <= IsolatedWorkerTextSearch.MAX_PREVIEW_CHARS) {
                    "Isolated worker returned an invalid search hit"
                }
                SearchHit(line, column, preview)
            }
            return Reply(uid, hits = hits, truncated = data.getBoolean(IsolatedWorkerService.SEARCH_TRUNCATED))
        }
        val text = checkNotNull(data.getString(IsolatedWorkerService.TEXT)) { "Isolated worker returned no text" }
        check(text.toByteArray(Charsets.UTF_8).size <= IsolatedWorkerInput.MAX_TEXT_BYTES) {
            "Isolated worker text exceeds 64 KiB"
        }
        return Reply(uid, content = text)
    }
}
