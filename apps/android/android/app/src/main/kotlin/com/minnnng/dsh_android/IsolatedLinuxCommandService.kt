package com.minnnng.dsh_android

import android.app.Service
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process as AndroidProcess
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** An internal fixed-command guest. The isolated UID, not a shell parser, is its security boundary. */
class IsolatedLinuxCommandService : Service() {
    companion object {
        const val REQUEST = 1
        const val CANCEL = 2
        const val COMPLETE = 3
        const val STARTED = 4
        const val ID = "id"
        const val COMMAND = "command"
        const val ARGUMENT = "argument"
        const val INPUT = "input"
        const val UID = "uid"
        const val ISOLATED = "isolated"
        const val PRIVATE_DENIED = "privateDenied"
        const val NETWORK_DENIED = "networkDenied"
        const val RETIRED = "retired"
        const val OUTPUT = "output"
        const val EXIT_CODE = "exitCode"
        const val KIND = "kind"
        const val ERROR = "error"
    }

    private class Active(
        val id: String,
        val request: IsolatedLinuxCommandPolicy.Request,
        val reply: Messenger,
    ) {
        val cancelled = AtomicBoolean(false)
        @Volatile var process: java.lang.Process? = null
        @Volatile var thread: Thread? = null

        fun cancel() {
            cancelled.set(true)
            process?.destroyForcibly()
            thread?.interrupt()
        }
    }

    private val active = AtomicReference<Active?>()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.sendingUid != applicationInfo.uid) return@Handler true
        try {
            when (message.what) {
                REQUEST -> {
                    val reply = message.replyTo ?: return@Handler true
                    val id = message.data.getString(ID)
                    val request = IsolatedLinuxCommandPolicy.Request.fromWire(
                        message.data.getString(COMMAND),
                        message.data.getString(ARGUMENT),
                        message.data.getByteArray(INPUT),
                    )
                    if (id == null || !validId(id) || request == null ||
                        (request.command.isTestOnly && !debuggable())) return@Handler true
                    val run = Active(id, request, reply)
                    if (!active.compareAndSet(null, run)) return@Handler true
                    run.thread = Thread({ execute(run) }, "isolated-linux-command").also { it.start() }
                }
                CANCEL -> {
                    val run = active.get()
                    // Keep ownership until execute has reaped the child and sent its
                    // terminal receipt. Removing it here made cancellation look settled
                    // while a child could still be running.
                    if (run != null && run.id == message.data.getString(ID)) {
                        run.cancel()
                    }
                }
            }
        } catch (_: Exception) { /* Malformed Binder data never starts a command. */ }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun debuggable(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    override fun onDestroy() {
        active.getAndSet(null)?.let { run ->
            run.cancel()
            // Normal Service destruction gets one bounded chance to join the
            // command thread. A killed process never calls onDestroy; the App
            // must keep binder death as an unconfirmed outcome.
            try { run.thread?.join(350) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        }
        super.onDestroy()
    }

    private fun execute(run: Active) {
        var kind = GuestTerminal.Kind.ERROR
        var output = ""
        var exitCode = -1
        var error: String? = null
        var privateDenied = false
        var networkDenied = false
        var retired = true
        try {
            check(AndroidProcess.isIsolated()) { "Command service is not an isolated process" }
            privateDenied = File(applicationInfo.dataDir).list() == null
            check(privateDenied) { "Isolated guest can read App private data" }
            networkDenied = try {
                val socket = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
                Os.close(socket)
                false
            } catch (e: ErrnoException) {
                if (e.errno != OsConstants.EACCES && e.errno != OsConstants.EPERM) throw e
                true
            }
            check(networkDenied) { "Isolated guest can create a network socket" }
            check(!run.cancelled.get() && active.get() === run) { "Command cancelled before start" }
            if (run.request.command == IsolatedLinuxCommandPolicy.Command.TEST_SERVICE_DEATH) {
                check(debuggable()) { "Test command is unavailable in this package" }
                AndroidProcess.killProcess(AndroidProcess.myPid())
                throw IllegalStateException("Isolated test worker failed to terminate")
            }
            val argv = PackagedLinuxUtility.argv(run.request, applicationInfo.nativeLibraryDir)
            retired = false // start() may fork before it returns or throws.
            val child = ProcessBuilder(argv)
                .redirectErrorStream(true).apply {
                    directory(File("/"))
                    environment().clear()
                    environment()["LC_ALL"] = "C"
                }.start()
            run.process = child
            try {
                // Sent only after a real child exists; Binder preserves this
                // message's order relative to COMPLETE for the same reply.
                run.reply.send(Message.obtain(null, STARTED).apply {
                    data = Bundle().apply {
                        putString(ID, run.id)
                        putString(COMMAND, run.request.command.wireName)
                        putInt(UID, AndroidProcess.myUid())
                        putBoolean(ISOLATED, AndroidProcess.isIsolated())
                        putBoolean(PRIVATE_DENIED, privateDenied)
                        putBoolean(NETWORK_DENIED, networkDenied)
                    }
                })
                val captured = ByteArrayOutputStream()
                val overflow = AtomicBoolean(false)
                val captureError = AtomicReference<Exception?>()
                val inputError = AtomicReference<Exception?>()
                val collector = Thread({
                    try {
                        child.inputStream.use { stream ->
                            val buffer = ByteArray(256)
                            while (true) {
                                val count = stream.read(buffer)
                                if (count < 0) break
                                val remaining = IsolatedLinuxCommandPolicy.MAX_OUTPUT_BYTES - captured.size()
                                if (count > remaining) {
                                    overflow.set(true)
                                    child.destroyForcibly()
                                }
                                if (remaining > 0) captured.write(buffer, 0, minOf(count, remaining))
                            }
                        }
                    } catch (e: Exception) { captureError.set(e) }
                }, "isolated-linux-command-output").apply { isDaemon = true; start() }
                val writer = Thread({
                    try { child.outputStream.use { it.write(run.request.input()) } }
                    catch (e: Exception) { inputError.set(e) }
                }, "isolated-linux-command-input").apply { isDaemon = true; start() }
                check(!run.cancelled.get() && active.get() === run) { "Command cancelled during launch" }
                if (!child.waitFor(IsolatedLinuxCommandPolicy.CHILD_DEADLINE_MS, TimeUnit.MILLISECONDS)) {
                    kind = GuestTerminal.Kind.TIMED_OUT
                    throw IllegalStateException("Command deadline exceeded")
                }
                collector.join(250)
                writer.join(250)
                check(!collector.isAlive) { "Command output stream remained open" }
                check(!writer.isAlive) { "Command input stream remained open" }
                check(!overflow.get()) { "Command output exceeded limit" }
                check(captureError.get() == null) { "Command output capture failed" }
                check(inputError.get() == null) { "Command input delivery failed" }
                check(!run.cancelled.get()) { "Command cancelled" }
                exitCode = child.exitValue()
                output = captured.toString(StandardCharsets.UTF_8.name())
                val noMatches = run.request.command == IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL && exitCode == 1
                kind = if (exitCode == 0 || noMatches) GuestTerminal.Kind.COMPLETED else GuestTerminal.Kind.ERROR
            } finally {
                retired = IsolatedLinuxProcessRetirement.stopAndReap(child, 250)
                if (retired) run.process = null
                else {
                    // In particular, never publish stdout from a command whose
                    // child may still be alive after a timeout or cancellation.
                    kind = GuestTerminal.Kind.ERROR
                    output = ""
                    exitCode = -1
                    error = "Fixed command child retirement unconfirmed"
                }
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            kind = GuestTerminal.Kind.CANCELLED
            error = "Command interrupted"
        } catch (e: Exception) {
            if (run.cancelled.get()) kind = GuestTerminal.Kind.CANCELLED
            error = e.javaClass.simpleName + ": " + (e.message ?: "command failed")
        }
        if (!active.compareAndSet(run, null)) return
        try {
            run.reply.send(Message.obtain(null, COMPLETE).apply {
                data = Bundle().apply {
                    putString(ID, run.id)
                    putString(COMMAND, run.request.command.wireName)
                    putInt(UID, AndroidProcess.myUid())
                    putBoolean(ISOLATED, AndroidProcess.isIsolated())
                    putBoolean(PRIVATE_DENIED, privateDenied)
                    putBoolean(NETWORK_DENIED, networkDenied)
                    putBoolean(RETIRED, retired)
                    putString(OUTPUT, output)
                    putInt(EXIT_CODE, exitCode)
                    putString(KIND, kind.name)
                    putString(ERROR, error)
                }
            })
        } catch (_: Exception) { /* Caller cancellation or death is already terminal. */ }
    }

    private fun validId(id: String): Boolean = try { UUID.fromString(id).toString() == id }
        catch (_: IllegalArgumentException) { false }
}
