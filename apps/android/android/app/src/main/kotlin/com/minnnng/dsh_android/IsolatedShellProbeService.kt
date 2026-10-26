package com.minnnng.dsh_android

import android.app.Service
import android.content.Intent
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

/** Internal, fixed-command diagnostic. It has no script, cwd, file, or network broker input. */
class IsolatedShellProbeService : Service() {
    companion object {
        const val REQUEST = 1
        const val CANCEL = 2
        const val COMPLETE = 3
        const val ID = "id"
        const val UID = "uid"
        const val ISOLATED = "isolated"
        const val PRIVATE_PATH = "privatePath"
        const val PRIVATE_READABLE = "privateReadable"
        const val PRIVATE_WRITABLE = "privateWritable"
        const val INET_OPENED = "inetOpened"
        const val SHELL_COMPLETED = "shellCompleted"
        const val OUTPUT = "output"
        const val ERROR = "error"
    }

    private class Active(val id: String, val reply: Messenger) {
        @Volatile var child: java.lang.Process? = null
        @Volatile var thread: Thread? = null
    }

    private val active = AtomicReference<Active?>()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.sendingUid != applicationInfo.uid) return@Handler true
        try {
            when (message.what) {
                REQUEST -> {
                    val reply = message.replyTo ?: return@Handler true
                    val id = message.data.getString(ID)
                    if (id == null || !validId(id)) return@Handler true
                    val request = Active(id, reply)
                    if (!active.compareAndSet(null, request)) return@Handler true
                    request.thread = Thread({ inspect(request) }, "isolated-shell-probe").also { it.start() }
                }
                CANCEL -> {
                    val request = active.get()
                    if (request != null && request.id == message.data.getString(ID) && active.compareAndSet(request, null)) {
                        request.child?.destroyForcibly()
                        request.thread?.interrupt()
                    }
                }
            }
        } catch (_: Exception) { /* Malformed internal Binder request cannot admit or execute work. */ }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        active.getAndSet(null)?.let {
            it.child?.destroyForcibly()
            it.thread?.interrupt()
        }
        super.onDestroy()
    }

    private fun inspect(request: Active) {
        var error: String? = null
        var privateReadable = true
        var privateWritable = true
        var inetOpened = true
        var shellCompleted = false
        var output = ""
        val privatePath = applicationInfo.dataDir
        // This is the only path the child may try to create. It is derived from
        // a validated UUID rather than a caller-supplied path or shell fragment.
        val privateMarker = File(privatePath, ".pocket-shell-probe-${request.id}")
        try {
            check(AndroidProcess.isIsolated()) { "Service is not running with an isolated UID" }
            // Host verifies that this exact directory exists for its own package.
            privateReadable = File(privatePath).list() != null
            inetOpened = try {
                val fd = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
                Os.close(fd)
                true
            } catch (e: ErrnoException) {
                if (e.errno != OsConstants.EACCES && e.errno != OsConstants.EPERM) throw e
                false
            }
            check(active.get() === request) { "Shell probe cancelled before launch" }
            // The path is passed as a positional argument, never interpolated into shell code.
            // The child must prove its own UID and failed direct access. A check made only by
            // the Java service would not establish the child shell's effective boundary.
            val child = ProcessBuilder(
                "/system/bin/sh", "-c",
                "printf '%s\\n' pocket-harness-isolated-shell-probe; " +
                    "/system/bin/id -u; " +
                    "if /system/bin/ls \"\$1\" >/dev/null 2>&1; " +
                    "then printf '%s\\n' private-opened; else printf '%s\\n' private-denied; fi; " +
                    "if { : > \"\$2\"; } 2>/dev/null; then printf '%s\\n' private-write-opened; " +
                    "else printf '%s\\n' private-write-denied; fi",
                "shell-probe", privatePath, privateMarker.absolutePath,
            )
                .redirectErrorStream(true).apply {
                    directory(File("/"))
                    environment().clear()
                    environment()["PATH"] = "/system/bin"
                }.start()
            request.child = child
            try { child.outputStream.close() } catch (e: Exception) {
                child.destroyForcibly()
                request.child = null
                throw e
            }
            val captured = ByteArrayOutputStream()
            val overflow = AtomicBoolean(false)
            val captureError = AtomicReference<Exception?>()
            // Drain while the process runs. Waiting before reading can deadlock
            // on a full pipe, even when the eventual output is rejected.
            val collector = Thread({
                try {
                    child.inputStream.use { stream ->
                        val buffer = ByteArray(256)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            val remaining = ShellProbeEvidence.MAX_OUTPUT_BYTES - captured.size()
                            if (count > remaining) overflow.set(true)
                            if (remaining > 0) captured.write(buffer, 0, minOf(count, remaining))
                        }
                    }
                } catch (e: Exception) { captureError.set(e) }
            }, "isolated-shell-probe-output").apply { isDaemon = true; start() }
            try {
                check(active.get() === request) { "Shell probe cancelled during launch" }
                check(child.waitFor(1500, TimeUnit.MILLISECONDS)) { "Fixed shell probe timed out" }
                collector.join(500)
                check(!collector.isAlive) { "Fixed shell left its output pipe open" }
                check(!overflow.get()) { "Fixed shell output exceeded limit" }
                check(captureError.get() == null) { "Fixed shell output capture failed" }
                output = captured.toString(StandardCharsets.UTF_8.name())
                privateWritable = output.contains("private-write-opened\n")
                shellCompleted = child.exitValue() == 0
            } finally {
                child.destroyForcibly()
                child.inputStream.close()
                request.child = null
            }
        } catch (e: Exception) {
            error = e.javaClass.simpleName + ": " + (e.message ?: "probe failed")
        }
        if (!active.compareAndSet(request, null)) return
        try {
            request.reply.send(Message.obtain(null, COMPLETE).apply {
                data = Bundle().apply {
                    putString(ID, request.id)
                    putInt(UID, AndroidProcess.myUid())
                    putBoolean(ISOLATED, AndroidProcess.isIsolated())
                    putString(PRIVATE_PATH, privatePath)
                    putBoolean(PRIVATE_READABLE, privateReadable)
                    putBoolean(PRIVATE_WRITABLE, privateWritable)
                    putBoolean(INET_OPENED, inetOpened)
                    putBoolean(SHELL_COMPLETED, shellCompleted)
                    putString(OUTPUT, output)
                    putString(ERROR, error)
                }
            })
        } catch (_: Exception) { /* The App may have cancelled or died. */ }
    }

    private fun validId(id: String): Boolean = try { UUID.fromString(id).toString() == id }
        catch (_: IllegalArgumentException) { false }
}
