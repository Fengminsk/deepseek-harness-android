package com.minnnng.dsh_android

import android.app.ActivityManager
import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException

/** Only this app UID can be terminated. No command arguments are retained or returned. */
class RecoveryProcessHost(private val context: Context) : RecoveryProcesses.Host {
    private val uid = Process.myUid()
    private val proc = File("/proc")

    private fun readIdentity(pid: Int): RecoveryProcesses.Identity? {
        val directory = File(proc, pid.toString())
        try {
            // proc inode ownership can change for a nondumpable process; it is not
            // sufficient evidence that a process belongs to another UID.
            val status = File(directory, "status").readText()
            val fields = status.lineSequence().firstOrNull { it.startsWith("Uid:") }
                ?.substringAfter(':')?.trim()?.split(Regex("\\s+"))
                ?.map { it.toInt() } ?: throw IOException("Process ownership unavailable")
            if (fields.size != 4) throw IOException("Process ownership malformed")
            if (fields.none { it == uid }) return RecoveryProcesses.Identity(pid, fields[0], 0, '?', "")
            if (fields.any { it != uid }) throw IOException("Process ownership changed")
            val stat = File(directory, "stat").readText()
            val values = stat.substringAfterLast(") ").trim().split(Regex("\\s+"))
            if (values.size < 20 || values[0].length != 1) throw IOException("Process identity unavailable")
            val start = values[19].toLong()
            val state = values[0][0]
            val executable = if (state == 'Z' || state == 'X' || state == 'x') "" else
                File(directory, "cmdline").inputStream().use { input ->
                    val bytes = java.io.ByteArrayOutputStream()
                    while (bytes.size() < 4096) {
                        val next = input.read()
                        if (next <= 0) break
                        bytes.write(next)
                    }
                    bytes.toString(Charsets.UTF_8.name())
                }
            return RecoveryProcesses.Identity(pid, uid, start, state, executable)
        } catch (error: Exception) {
            // Only a confirmed disappearance can be ignored. Access denied is
            // unknown, including when the kernel hides some process details.
            try { Os.stat(directory.path) }
            catch (gone: android.system.ErrnoException) {
                if (gone.errno == OsConstants.ENOENT || gone.errno == OsConstants.ESRCH) return null
            }
            throw IOException("Cannot verify process ownership", error)
        }
    }

    override fun snapshot(): List<RecoveryProcesses.Identity> {
        val entries = proc.list() ?: throw IOException("Process enumeration unavailable")
        return entries.mapNotNull { name -> name.toIntOrNull()?.let { readIdentity(it) } }
    }

    override fun terminate(expected: RecoveryProcesses.Identity) {
        if (expected.uid != uid || expected.pid == Process.myPid()) throw IOException("Process outside recovery scope")
        val current = readIdentity(expected.pid) ?: return
        if (!expected.same(current)) throw IOException("Process identity changed before termination")
        if (current.active()) {
            // Kernel UID permission checks remain in force; this app has no root.
            try { Os.kill(current.pid, OsConstants.SIGKILL) }
            catch (error: android.system.ErrnoException) {
                if (error.errno != OsConstants.ESRCH) throw IOException("Cannot terminate app process", error)
            }
        }
    }

    override fun elapsedMillis(): Long = SystemClock.elapsedRealtime()
    override fun pause(millis: Long) {
        try { Thread.sleep(millis) }
        catch (error: InterruptedException) { Thread.currentThread().interrupt(); throw IOException("Recovery interrupted", error) }
    }

    fun quiesce() {
        val candidates = context.getSystemService(ActivityManager::class.java).runningAppProcesses
            ?.filter { it.uid == uid && it.processName == context.packageName }
            ?: throw IOException("Main process unavailable")
        if (candidates.size != 1) throw IOException("Main process ambiguous")
        val main = readIdentity(candidates.single().pid) ?: throw IOException("Main process exited")
        val service = readIdentity(Process.myPid()) ?: throw IOException("Maintenance process unavailable")
        RecoveryProcesses.quiesce(this, uid, main, service, context.packageName)
    }
}
