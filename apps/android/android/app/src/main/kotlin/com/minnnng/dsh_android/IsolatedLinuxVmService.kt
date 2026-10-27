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
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Runs one complete Linux machine in an isolated Android UID with memory-backed disks only. */
class IsolatedLinuxVmService : Service() {
    companion object {
        const val START = 1
        const val CANCEL = 2
        const val COMPLETE = 3
        const val STARTED = 4
        const val NETWORK_CALL = 5
        const val NETWORK_RESULT = 6
    }
    private class Run(val id: String, val reply: Messenger, val cancelled: AtomicBoolean = AtomicBoolean()) {
        @Volatile var thread: Thread? = null
        @Volatile var network: LinuxVmNetworkGuest? = null
        var networkCallLimit = 0
    }
    private val owned = AtomicReference<Run?>()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.sendingUid != applicationInfo.uid || !Process.isIsolated()) return@Handler true
        if (message.what == NETWORK_RESULT) {
            owned.get()?.network?.receive(message.data)
            return@Handler true
        }
        if (message.what == CANCEL) {
            owned.get()?.let { run ->
                if (run.id == message.data.getString("id")) {
                    run.cancelled.set(true)
                    run.network?.close()
                    Handler(Looper.getMainLooper()).postDelayed({
                        if (owned.get() === run) Process.killProcess(Process.myPid())
                    }, 2000)
                }
            }
            return@Handler true
        }
        if (message.what != START) return@Handler true
        val data = message.data
        data.classLoader = SharedMemory::class.java.classLoader
        val images = ArrayList<SharedMemory>()
        var accepted = false
        try {
            val id = data.getString("id") ?: return@Handler true
            require(UUID.fromString(id).toString() == id)
            val reply = message.replyTo ?: return@Handler true
            val command = data.getString("command") ?: return@Handler true
            val timeoutMs = data.getLong("timeoutMs", 0)
            require(timeoutMs in 1000..120_000)
            val console = LinuxVmConsole(command, true, data.getBoolean("workspaceFresh", false))
            for (name in listOf("bios", "kernel", "disk", "workspace"))
                images.add(requireNotNull(data.getParcelable<SharedMemory>(name)))
            require(images[3].size == LinuxVmImageStore.WORKSPACE_BYTES)
            val input = data.getParcelable<SharedMemory>("input")
            val buildOutput = data.getParcelable<SharedMemory>("buildOutput")
            if (input != null) images.add(input)
            if (buildOutput != null) images.add(buildOutput)
            if (input != null) {
                require(input.size in 512..64 * 1024 * 1024 && input.size % 512 == 0)
            }
            if (buildOutput != null) {
                require(input != null && buildOutput.size in 512..256 * 1024 * 1024 && buildOutput.size % 512 == 0)
            }
            require(images[0].size in 1..2 * 1024 * 1024
                && images[1].size in 1..32 * 1024 * 1024
                && images[2].size in 512..256 * 1024 * 1024 && images[2].size % 512 == 0)
            val run = Run(id, reply)
            val networkNonce = data.getString("networkNonce")
            if (networkNonce != null) {
                require(UUID.fromString(networkNonce).toString() == networkNonce && input == null && buildOutput == null)
                run.networkCallLimit = data.getInt("networkCallLimit", 0)
                require(run.networkCallLimit in 1..IsolatedNetworkBroker.MAX_CALLS)
                run.network = LinuxVmNetworkGuest(id, networkNonce, reply, run.cancelled,
                    System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(timeoutMs))
            } else require(!data.containsKey("networkCallLimit"))
            check(owned.compareAndSet(null, run)) { "Linux VM worker already owns a run" }
            Handler(Looper.getMainLooper()).postDelayed({
                if (owned.get() === run) {
                    run.cancelled.set(true)
                    run.network?.close()
                    // All virtual CPUs are in this process; there are no host
                    // subprocesses. Binder death then confirms their retirement.
                    Handler(Looper.getMainLooper()).postDelayed({
                        if (owned.get() === run) Process.killProcess(Process.myPid())
                    }, 2000)
                }
            }, timeoutMs + 1000)
            run.thread = Thread({ execute(run, images, console, timeoutMs) }, "isolated-linux-vm")
            try { run.thread!!.start(); accepted = true }
            catch (failure: Throwable) { owned.compareAndSet(run, null); throw failure }
        } catch (_: Exception) {
            // The caller's bounded deadline detects rejected or malformed messages.
        } finally { if (!accepted) images.forEach { it.close() } }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun execute(run: Run, images: List<SharedMemory>, console: LinuxVmConsole, timeoutMs: Long) {
        var status = "failed"
        var detail: String? = null
        var timedOut = false
        var retired = true
        var isolated = false
        var cancelledAtRetirement = false
        try {
            check(Process.isIsolated()) { "Linux VM requires an isolated UID" }
            check(File(applicationInfo.dataDir).list() == null) { "Linux VM can read App private storage" }
            val networkDenied = try {
                val fd = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
                Os.close(fd); false
            } catch (failure: ErrnoException) {
                if (failure.errno !in listOf(OsConstants.EACCES, OsConstants.EPERM)) throw failure
                true
            }
            check(networkDenied) { "Linux VM has ambient network access" }
            isolated = true
            val bios = images[0].mapReadOnly()
            try {
                val kernel = images[1].mapReadOnly()
                try {
                    val disk = images[2].mapReadWrite()
                    val extra = ArrayList<java.nio.ByteBuffer>()
                    try {
                        extra.add(images[3].mapReadWrite())
                        if (images.size >= 5) extra.add(images[4].mapReadOnly())
                        if (images.size == 6) extra.add(images[5].mapReadWrite())
                        val network = run.network
                        if (network != null) {
                            // These two buffers are owned only by this interpreter. The App exchanges
                            // bounded Binder byte arrays; it never races a guest block write.
                            val mailboxDisk = java.nio.ByteBuffer.allocateDirect(LinuxVmHttpsMailbox.DISK_BYTES)
                            val mailbox = LinuxVmHttpsMailbox(mailboxDisk, run.id, run.networkCallLimit, network, run.cancelled)
                            console.attachInterpreterPoll { mailbox.poll() }
                            extra.add(java.nio.ByteBuffer.allocateDirect(512).asReadOnlyBuffer())
                            extra.add(mailboxDisk)
                        }
                        run.reply.send(Message.obtain(null, STARTED).apply {
                            data = Bundle().apply {
                                putString("id", run.id); putInt("uid", Process.myUid())
                                putBoolean("isolated", true)
                            }
                        })
                        val engine = LinuxVmEngine()
                        retired = false
                        val result = try {
                            engine.run(bios, kernel, (listOf(disk) + extra).toTypedArray(),
                                console, run.cancelled, timeoutMs)
                        } finally { retired = true }
                        timedOut = result == LinuxVmEngine.TIMED_OUT
                        status = when {
                            run.cancelled.get() || result == LinuxVmEngine.CANCELLED -> "cancelled"
                            timedOut -> "timed_out"
                            result == LinuxVmEngine.SHUT_DOWN && console.exitCode() != null -> "completed"
                            else -> "failed"
                        }
                        if (status == "failed") detail = "Linux guest stopped without a command completion record"
                    } finally {
                        // Only the initial entries came from SharedMemory. The optional mailbox
                        // and vdc placeholder are ordinary direct buffers, retired with this call.
                        extra.take(images.size - 3).forEach { SharedMemory.unmap(it) }
                        SharedMemory.unmap(disk)
                    }
                } finally { SharedMemory.unmap(kernel) }
            } finally { SharedMemory.unmap(bios) }
        } catch (failure: Exception) { detail = failure.message?.take(512) ?: "Linux VM execution failed" }
        catch (failure: LinkageError) { detail = "Linux VM native provider is unavailable: ${failure.javaClass.simpleName}" }
        finally {
            cancelledAtRetirement = run.cancelled.get()
            run.network?.close()
            images.forEach { it.close() }
        }
        // API 28 may reuse this bound service. The old VM has retired and its
        // mappings are closed before the caller can dispatch a successor.
        owned.compareAndSet(run, null)
        try {
            run.reply.send(Message.obtain(null, COMPLETE).apply {
                data = Bundle().apply {
                    putString("id", run.id); putInt("uid", Process.myUid())
                    putBoolean("isolated", isolated); putString("status", status)
                    putString("output", console.output()); putBoolean("truncated", console.truncated())
                    putInt("exitCode", console.exitCode() ?: -1)
                    putBoolean("timedOut", timedOut); putBoolean("cancelled", cancelledAtRetirement || status == "cancelled")
                    putBoolean("retirementConfirmed", retired); putString("detail", detail)
                }
            })
        } catch (_: Exception) { /* A dead App cannot receive or publish this memory-only disk. */ }
        finally { owned.compareAndSet(run, null) }
    }

    override fun onDestroy() {
        owned.get()?.let { run ->
            run.cancelled.set(true)
            run.network?.close()
            try { run.thread?.join(400) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        }
        super.onDestroy()
    }
}
