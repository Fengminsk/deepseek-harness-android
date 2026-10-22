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
    private data class Outcome(val text: Text? = null, val error: Throwable? = null)

    /** Caller retains [input] and must invoke this from a background thread. */
    fun readText(context: Context, input: ParcelFileDescriptor): Text = readText(context, input, BooleanSupplier { false })

    /** Cancellation is request-specific and closes the worker grant before returning. */
    fun readText(context: Context, input: ParcelFileDescriptor, cancelled: BooleanSupplier): Text =
        requestText(context, input, cancelled, null)

    private fun requestText(
        context: Context, input: ParcelFileDescriptor, cancelled: BooleanSupplier,
        edit: IsolatedWorkerTextEdit.Spec?,
    ): Text {
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
                val received = try { Outcome(text = parse(message.data, id, message.sendingUid)) }
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
                            val request = Message.obtain(null,
                                if (edit == null) IsolatedWorkerService.READ_TEXT else IsolatedWorkerService.EDIT_TEXT)
                            request.replyTo = replies
                            request.data = Bundle().apply {
                                putString(IsolatedWorkerService.REQUEST_ID, id)
                                putParcelable(IsolatedWorkerService.INPUT, copy)
                                if (edit != null) {
                                    putString(IsolatedWorkerService.EDIT_NEEDLE, edit.needle())
                                    putString(IsolatedWorkerService.EDIT_REPLACEMENT, edit.replacement())
                                    putInt(IsolatedWorkerService.EDIT_MAX_REPLACEMENTS, edit.maxReplacements())
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
            return checkNotNull(result.text) { "Isolated worker returned no text" }
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

    /** App-selected direct-child edit; the separate-UID worker sees only a bounded text descriptor and literals. */
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
        val grant = File.createTempFile("ptc-workspace-grant-", ".txt", app.cacheDir)
        try {
            FileOutputStream(grant).use { output ->
                output.write(snapshot.content())
                output.fd.sync()
            }
            val workerText = ParcelFileDescriptor.open(grant, ParcelFileDescriptor.MODE_READ_ONLY).use { input ->
                requestText(app, input, cancelled, edit)
            }
            return writeback.commit(filename, expectedSha256, workerText.content.toByteArray(Charsets.UTF_8), cancelled)
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

    private fun parse(data: Bundle, id: String, senderUid: Int): Text {
        check(data.getString(IsolatedWorkerService.REQUEST_ID) == id) { "Isolated worker answered a different request" }
        val uid = data.getInt(IsolatedWorkerService.UID, -1)
        check(senderUid >= 0 && senderUid == uid && uid != Process.myUid()) {
            "Worker response did not originate from its reported separate UID"
        }
        data.getString(IsolatedWorkerService.ERROR)?.let { throw IllegalStateException(it) }
        val text = checkNotNull(data.getString(IsolatedWorkerService.TEXT)) { "Isolated worker returned no text" }
        check(text.toByteArray(Charsets.UTF_8).size <= IsolatedWorkerInput.MAX_TEXT_BYTES) {
            "Isolated worker text exceeds 64 KiB"
        }
        return Text(uid, text)
    }
}
