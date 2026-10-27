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
import android.os.SharedMemory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** App-side binding owns the VM until native return or confirmed death of its sole process. */
internal object LinuxVmRunner {
    data class Result(
        val status: String, val output: String = "", val exitCode: Int? = null,
        val guestUid: Int? = null, val timedOut: Boolean = false, val cancelled: Boolean = false,
        val truncated: Boolean = false, val retirementConfirmed: Boolean = false, val detail: String? = null,
    )

    fun run(context: Context, id: String, command: String, timeoutMs: Long,
        images: LinuxVmImageStore.Lease, cancelled: BooleanSupplier,
        input: SharedMemory? = null, buildOutput: SharedMemory? = null,
        rootDisk: SharedMemory = images.disk, workspaceFresh: Boolean = images.workspaceFresh): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Linux VM cannot block the main thread" }
        val outcome = AtomicReference<Result?>()
        val worker = AtomicReference<Messenger?>()
        val guestUid = AtomicInteger(-1)
        val finished = CountDownLatch(1)
        val accepting = AtomicBoolean(true)
        val sendLock = Any()
        var deathLink: Pair<IBinder, IBinder.DeathRecipient>? = null
        fun finish(result: Result) { if (outcome.compareAndSet(null, result)) finished.countDown() }
        fun stop(remote: Messenger) {
            remote.send(Message.obtain(null, IsolatedLinuxVmService.CANCEL).apply {
                data = Bundle().apply { putString("id", id) }
            })
        }
        fun died() = finish(Result("worker_died", guestUid = guestUid.get().takeIf { it >= 0 },
            cancelled = cancelled.asBoolean, retirementConfirmed = true,
            detail = "Linux VM process exited; this invocation's disk changes were not committed"))
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (!accepting.get() || outcome.get() != null) return@Handler true
            try {
                val data = message.data
                val sender = message.sendingUid
                if (data.getString("id") != id || sender < 0 || sender == Process.myUid()
                    || data.getInt("uid", -1) != sender || !data.getBoolean("isolated", false)
                    || (Build.VERSION.SDK_INT >= 34 && !Process.isIsolatedUid(sender))) {
                    finish(Result("failed", detail = "Linux VM reply identity was rejected"))
                    return@Handler true
                }
                if (guestUid.get() >= 0 && guestUid.get() != sender) {
                    finish(Result("failed", detail = "Linux VM worker identity changed"))
                    return@Handler true
                }
                if (message.what == IsolatedLinuxVmService.STARTED) guestUid.compareAndSet(-1, sender)
                else if (message.what == IsolatedLinuxVmService.COMPLETE) {
                    val status = data.getString("status")
                    val output = data.getString("output") ?: ""
                    val exit = data.getInt("exitCode", -1)
                    require(status in setOf("completed", "cancelled", "timed_out", "failed"))
                    require(output.toByteArray(Charsets.UTF_8).size <= LinuxVmConsole.MAX_OUTPUT_BYTES)
                    require(exit in -1..255)
                    require(status != "completed" || (guestUid.get() == sender && exit >= 0))
                    val stopped = cancelled.asBoolean
                    finish(Result(if (stopped) "cancelled" else status!!, output,
                        if (exit < 0) null else exit, sender,
                        data.getBoolean("timedOut"), stopped || data.getBoolean("cancelled"),
                        data.getBoolean("truncated"), data.getBoolean("retirementConfirmed"),
                        data.getString("detail")?.take(512)))
                }
            } catch (_: Exception) { finish(Result("failed", detail = "Linux VM reply was malformed")) }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                synchronized(sendLock) {
                    if (!accepting.get() || outcome.get() != null) return
                    try {
                        val death = IBinder.DeathRecipient { died() }
                        binder.linkToDeath(death, 0)
                        deathLink = binder to death
                        if (cancelled.asBoolean) {
                            finish(Result("cancelled", cancelled = true, retirementConfirmed = true)); return
                        }
                        val remote = Messenger(binder)
                        worker.set(remote)
                        remote.send(Message.obtain(null, IsolatedLinuxVmService.START).apply {
                            replyTo = replies
                            data = Bundle().apply {
                                putString("id", id); putString("command", command); putLong("timeoutMs", timeoutMs)
                                putParcelable("bios", images.bios); putParcelable("kernel", images.kernel)
                                putParcelable("disk", rootDisk)
                                putParcelable("workspace", images.workspace); putBoolean("workspaceFresh", workspaceFresh)
                                if (input != null) putParcelable("input", input)
                                if (buildOutput != null) putParcelable("buildOutput", buildOutput)
                            }
                        })
                    } catch (_: Exception) { finish(Result("failed", detail = "Linux VM dispatch failed")) }
                }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                if (deathLink?.first?.isBinderAlive == false) died()
                else finish(Result("worker_died", detail = "Linux VM disconnected without process-death evidence"))
            }
            override fun onBindingDied(name: ComponentName) {
                if (deathLink?.first?.isBinderAlive == false) died()
                else finish(Result("worker_died", detail = "Linux VM binding ended without process-death evidence"))
            }
            override fun onNullBinding(name: ComponentName) {
                finish(Result("failed", retirementConfirmed = true, detail = "Linux VM binding returned no service"))
            }
        }
        var bound = false
        try {
            if (cancelled.asBoolean) return Result("cancelled", cancelled = true, retirementConfirmed = true)
            // This durable boundary precedes binding, so no Binder START can outrun admission.
            images.markDispatched()
            val intent = Intent(context, IsolatedLinuxVmService::class.java)
            bound = if (Build.VERSION.SDK_INT >= 29) context.bindIsolatedService(intent,
                Context.BIND_AUTO_CREATE, "linux_vm_" + id.replace("-", ""), context.mainExecutor, connection)
                else context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!bound) return Result("failed", retirementConfirmed = true, detail = "Linux VM service unavailable")
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs + 15_000)
            var stopSent = false
            while (outcome.get() == null) {
                if (cancelled.asBoolean && !stopSent) {
                    synchronized(sendLock) {
                        val remote = worker.get()
                        if (remote == null) finish(Result("cancelled", cancelled = true, retirementConfirmed = true))
                        else try { stop(remote) } catch (_: Exception) { /* Binder death remains authoritative. */ }
                        stopSent = true
                    }
                }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) {
                    finish(Result("failed", guestUid = guestUid.get().takeIf { it >= 0 }, timedOut = true,
                        cancelled = cancelled.asBoolean, detail = "Linux VM retirement was not confirmed"))
                    break
                }
                finished.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)
            }
        } catch (failure: InterruptedException) {
            Thread.currentThread().interrupt()
            finish(Result("cancelled", cancelled = true, detail = "Linux VM caller was interrupted"))
        } catch (failure: Exception) { finish(Result("failed", detail = failure.message?.take(512))) }
        finally {
            synchronized(sendLock) {
                accepting.set(false)
                if (outcome.get()?.retirementConfirmed != true) {
                    try { worker.get()?.let { stop(it) } } catch (_: Exception) { /* No confirmed receipt is published. */ }
                }
                deathLink?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
            }
            if (bound) context.unbindService(connection)
        }
        return checkNotNull(outcome.get())
    }
}
