package com.minnnng.dsh_android

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** Fixed-argv command bridge. Model text may be supplied only as bounded stdin or a literal. */
internal object IsolatedLinuxCommandRunner {
    data class Result(
        val kind: GuestTerminal.Kind,
        val command: IsolatedLinuxCommandPolicy.Command,
        val output: String,
        val exitCode: Int,
        val guestUid: Int?,
        val detail: String?,
        val retirementConfirmed: Boolean = false,
    ) {
        val completed: Boolean get() = kind == GuestTerminal.Kind.COMPLETED
    }

    fun run(
        context: Context,
        command: IsolatedLinuxCommandPolicy.Command,
        cancelled: BooleanSupplier,
    ): Result = run(context, IsolatedLinuxCommandPolicy.Request.of(command, null, ByteArray(0)), cancelled)

    fun run(
        context: Context,
        request: IsolatedLinuxCommandPolicy.Request,
        cancelled: BooleanSupplier,
    ): Result = run(context, request, cancelled, null)

    /** onStarted runs on the main looper only after a matching isolated-UID child-start receipt. */
    fun run(
        context: Context,
        request: IsolatedLinuxCommandPolicy.Request,
        cancelled: BooleanSupplier,
        onStarted: ((Int) -> Unit)?,
    ): Result {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Isolated command cannot block the main thread" }
        val app = context.applicationContext
        val command = request.command
        if (command.isTestOnly && (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
            return Result(GuestTerminal.Kind.ERROR, command, "", -1, null, "Test command unavailable")
        }
        val id = UUID.randomUUID().toString()
        val finished = CountDownLatch(1)
        val outcome = AtomicReference<Result?>()
        val active = AtomicBoolean(true)
        val started = AtomicBoolean(false)
        val remote = AtomicReference<Messenger?>()
        val deathLink = AtomicReference<Pair<IBinder, IBinder.DeathRecipient>?>()
        val sendLock = Any()

        fun requestStop(worker: Messenger) {
            worker.send(Message.obtain(null, IsolatedLinuxCommandService.CANCEL).apply {
                data = Bundle().apply { putString(IsolatedLinuxCommandService.ID, id) }
            })
        }

        fun result(kind: GuestTerminal.Kind, detail: String,
            retirementConfirmed: Boolean = false) =
            Result(kind, command, "", -1, null, detail, retirementConfirmed)
        fun finish(value: Result) {
            if (outcome.compareAndSet(null, value)) finished.countDown()
        }

        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                if (!active.get() || outcome.get() != null ||
                    (message.what != IsolatedLinuxCommandService.STARTED &&
                        message.what != IsolatedLinuxCommandService.COMPLETE)) return@Handler true
                val data = message.data
                val sender = message.sendingUid
                val reported = data.getInt(IsolatedLinuxCommandService.UID, -1)
                if (data.getString(IsolatedLinuxCommandService.ID) != id ||
                    data.getString(IsolatedLinuxCommandService.COMMAND) != command.wireName ||
                    sender < 0 || sender == Process.myUid() || sender != reported ||
                    !data.getBoolean(IsolatedLinuxCommandService.ISOLATED, false) ||
                    !data.getBoolean(IsolatedLinuxCommandService.PRIVATE_DENIED, false) ||
                    !data.getBoolean(IsolatedLinuxCommandService.NETWORK_DENIED, false) ||
                    (Build.VERSION.SDK_INT >= 34 && !Process.isIsolatedUid(sender))) {
                    finish(result(GuestTerminal.Kind.ERROR, "Isolated command evidence rejected"))
                    return@Handler true
                }
                if (message.what == IsolatedLinuxCommandService.STARTED) {
                    if (!started.compareAndSet(false, true)) {
                        finish(result(GuestTerminal.Kind.ERROR, "Duplicate isolated command start"))
                    } else {
                        onStarted?.invoke(sender)
                    }
                    return@Handler true
                }
                val kind = GuestTerminal.Kind.valueOf(data.getString(IsolatedLinuxCommandService.KIND) ?: "ERROR")
                val output = data.getString(IsolatedLinuxCommandService.OUTPUT) ?: ""
                val exitCode = data.getInt(IsolatedLinuxCommandService.EXIT_CODE, -1)
                val retired = data.getBoolean(IsolatedLinuxCommandService.RETIRED, false)
                if (!retired) {
                    finish(result(GuestTerminal.Kind.ERROR,
                        "Isolated command child retirement unconfirmed"))
                    return@Handler true
                }
                val emptyFilter = command == IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL &&
                    exitCode == 1 && output.isEmpty()
                if (output.toByteArray(StandardCharsets.UTF_8).size > IsolatedLinuxCommandPolicy.MAX_OUTPUT_BYTES ||
                    (kind == GuestTerminal.Kind.COMPLETED && !started.get()) ||
                    (kind == GuestTerminal.Kind.COMPLETED && exitCode != 0 && !emptyFilter)) {
                    finish(result(GuestTerminal.Kind.ERROR, "Isolated command output rejected"))
                    return@Handler true
                }
                // A cancellation racing a clean completion must never release
                // that completion to the caller. The guest receipt still proves
                // that the direct child was reaped first.
                if (cancelled.getAsBoolean() && kind == GuestTerminal.Kind.COMPLETED) {
                    finish(Result(GuestTerminal.Kind.CANCELLED, command, "", -1, sender,
                        "Isolated command cancelled during completion", true))
                } else {
                    finish(Result(kind, command, output, exitCode, sender,
                        data.getString(IsolatedLinuxCommandService.ERROR), true))
                }
            } catch (_: Exception) {
                finish(result(GuestTerminal.Kind.ERROR, "Isolated command Binder envelope rejected"))
            }
            true
        })

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    synchronized(sendLock) {
                        if (!active.get() || outcome.get() != null) return
                        val death = IBinder.DeathRecipient {
                            finish(result(GuestTerminal.Kind.WORKER_DIED, "Isolated command process died"))
                        }
                        binder.linkToDeath(death, 0)
                        deathLink.set(binder to death)
                        if (outcome.get() != null) return
                        val worker = Messenger(binder)
                        remote.set(worker)
                        worker.send(Message.obtain(null, IsolatedLinuxCommandService.REQUEST).apply {
                            replyTo = replies
                            data = Bundle().apply {
                                putString(IsolatedLinuxCommandService.ID, id)
                                putString(IsolatedLinuxCommandService.COMMAND, command.wireName)
                                putString(IsolatedLinuxCommandService.ARGUMENT, request.argument)
                                putByteArray(IsolatedLinuxCommandService.INPUT, request.input())
                            }
                        })
                    }
                } catch (e: Exception) {
                    finish(result(GuestTerminal.Kind.ERROR, e.message ?: "Isolated command binding failed"))
                }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                finish(result(GuestTerminal.Kind.WORKER_DIED, "Isolated command disconnected"))
            }
            override fun onBindingDied(name: ComponentName) {
                finish(result(GuestTerminal.Kind.WORKER_DIED, "Isolated command binding died"))
            }
            override fun onNullBinding(name: ComponentName) {
                finish(result(GuestTerminal.Kind.ERROR, "Isolated command returned no binder"))
            }
        }

        var bound = false
        try {
            val intent = Intent(app, IsolatedLinuxCommandService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "linux_command_" + id.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Could not bind isolated command service" }
            val deadline = System.nanoTime() +
                TimeUnit.MILLISECONDS.toNanos(IsolatedLinuxCommandPolicy.HOST_DEADLINE_MS)
            var stopSent = false
            while (outcome.get() == null) {
                if (cancelled.getAsBoolean() && !stopSent) {
                    stopSent = true
                    synchronized(sendLock) {
                        val worker = remote.get()
                        if (worker == null) {
                            // No REQUEST could have been sent yet; there is no
                            // child to retire and cancellation is definite.
                            finish(result(GuestTerminal.Kind.CANCELLED,
                                "Isolated command cancelled before dispatch", true))
                        } else {
                            try { requestStop(worker) }
                            catch (_: Exception) {
                                finish(result(GuestTerminal.Kind.WORKER_DIED,
                                    "Isolated command cancellation outcome unconfirmed"))
                            }
                        }
                    }
                }
                if (outcome.get() != null) break
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) {
                    // A missing guest retirement receipt is not a confirmed
                    // timeout terminal: the child might still be running.
                    finish(result(GuestTerminal.Kind.WORKER_DIED,
                        "Isolated command host deadline; child retirement unconfirmed"))
                    break
                }
                finished.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            finish(result(GuestTerminal.Kind.CANCELLED, "Isolated command caller interrupted"))
        } catch (e: Exception) {
            finish(result(GuestTerminal.Kind.ERROR, e.message ?: "Isolated command request failed"))
        } finally {
            synchronized(sendLock) {
                active.set(false)
                if (outcome.get()?.kind != GuestTerminal.Kind.COMPLETED) {
                    try {
                        remote.get()?.let { requestStop(it) }
                    } catch (_: Exception) { /* The worker is already terminal. */ }
                }
                deathLink.getAndSet(null)?.let { (binder, death) -> binder.unlinkToDeath(death, 0) }
            }
            if (bound) app.unbindService(connection)
        }
        return checkNotNull(outcome.get())
    }
}
