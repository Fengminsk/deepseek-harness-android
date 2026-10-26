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
import android.os.SharedMemory
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Debug-variant-only, synthetic storage observation. Never executes a guest archive or model text. */
class DebugGuestStorageProbeService : Service() {
    companion object {
        const val REQUEST = 1
        const val RESULT = 2
        const val ID = "probeId"
        const val FD = "readOnlyFd"
        const val DIRECTORY_FD = "readOnlyDirectoryFd"
        const val MEMORY = "sealedMemory"
        const val UID = "uid"
        const val ISOLATED = "isolated"
        const val STATE = "state"
        const val PRIVATE_READ = "privateRead"
        const val PRIVATE_WRITE = "privateWrite"
        const val FD_READ = "fdRead"
        const val FD_WRITE = "fdWrite"
        const val DIRECTORY_CHILD_READ = "directoryChildRead"
        const val DIRECTORY_CHILD_WRITE = "directoryChildWrite"
        const val MEMORY_READ = "memoryRead"
        const val MEMORY_WRITE = "memoryWrite"
        const val TEMP_WRITE = "tempWrite"
        const val TEMP_READ = "tempRead"
        const val TEMP_EXEC = "tempExec"
        const val TEMP_EXEC_MAP = "tempExecMap"
        const val ALLOWED = "allowed"
        const val DENIED = "denied"
        const val UNTESTED = "untested"
    }

    private var occupied = false
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what != REQUEST || message.sendingUid != applicationInfo.uid || occupied) {
            return@Handler true
        }
        val reply = message.replyTo ?: return@Handler true
        val id = message.data.getString(ID)
        if (id == null || !canonicalId(id) || !Process.isIsolated()) {
            send(reply, id, Bundle().apply { putString(STATE, "rejected") })
            return@Handler true
        }
        val descriptor: ParcelFileDescriptor?
        val directory: ParcelFileDescriptor?
        val memory: SharedMemory?
        try {
            message.data.classLoader = ParcelFileDescriptor::class.java.classLoader
            descriptor = message.data.getParcelable(FD)
            directory = message.data.getParcelable(DIRECTORY_FD)
            memory = message.data.getParcelable(MEMORY)
        } catch (_: Exception) {
            send(reply, id, Bundle().apply { putString(STATE, "inconclusive") })
            return@Handler true
        }
        if (descriptor == null || directory == null || memory == null) {
            runCatching { descriptor?.close() }
            runCatching { directory?.close() }
            runCatching { memory?.close() }
            send(reply, id, Bundle().apply { putString(STATE, "rejected") })
            return@Handler true
        }
        occupied = true
        Thread({
            val result = try { inspect(id, descriptor, directory, memory) }
            catch (_: Throwable) { Bundle().apply { putString(STATE, "inconclusive") } }
            finally {
                runCatching { descriptor.close() }
                runCatching { directory.close() }
                runCatching { memory.close() }
            }
            Handler(Looper.getMainLooper()).post {
                occupied = false
                send(reply, id, result)
            }
        }, "debug-guest-storage-probe").apply { isDaemon = true; start() }
        true
    })

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun inspect(id: String, descriptor: ParcelFileDescriptor,
                        directory: ParcelFileDescriptor, memory: SharedMemory): Bundle {
        val expected = "pocket-probe-$id".toByteArray(Charsets.US_ASCII)
        val parent = noBackupFilesDir.resolve("guest-storage-probe-$id")
        val directRead = readPath(parent.resolve("fixture.txt"), expected)
        val directWrite = createFile(parent.resolve("guest-created.txt"), expected)
        val fdRead = readFd(descriptor, expected)
        val fdWrite = try {
            if (Os.write(descriptor.fileDescriptor, byteArrayOf(0x58), 0, 1) == 1) ALLOWED else UNTESTED
        } catch (failure: ErrnoException) { errnoState(failure) }
        catch (_: SecurityException) { DENIED }
        // A transferred directory FD is not a grant to traverse App-private
        // children. JNI uses openat(2) because android.system.Os does not expose it.
        val childProbe = DebugGuestDirectoryProbe()
        val directoryChildRead = errnoCodeState(
            childProbe.probeRead(directory.fd, expected))
        val directoryChildWrite = errnoCodeState(childProbe.probeWrite(directory.fd))
        val memoryRead = try {
            val mapped = memory.mapReadOnly()
            try {
                val content = ByteArray(mapped.remaining())
                mapped.get(content)
                if (content.contentEquals(expected)) ALLOWED else UNTESTED
            } finally { SharedMemory.unmap(mapped) }
        } catch (_: SecurityException) { DENIED }
        catch (_: Exception) { UNTESTED }
        val memoryWrite = try {
            val mapped = memory.mapReadWrite()
            SharedMemory.unmap(mapped)
            ALLOWED
        } catch (_: SecurityException) { DENIED }
        catch (failure: ErrnoException) { errnoState(failure) }
        catch (_: Exception) { UNTESTED }

        var tempWrite = UNTESTED
        var tempRead = UNTESTED
        var tempExec = UNTESTED
        var tempExecMap = UNTESTED
        try {
            val tempBase = cacheDir
            val tempFile = tempBase.resolve("guest-storage-probe-$id.txt")
            val tempScript = tempBase.resolve("guest-storage-probe-$id.sh")
            try {
                tempWrite = createFile(tempFile, expected)
                tempRead = if (tempWrite == ALLOWED) readPath(tempFile, expected) else UNTESTED
                tempExecMap = if (tempWrite == ALLOWED) mapSyntheticExecutable(tempFile, expected.size) else UNTESTED
                tempExec = if (tempWrite == ALLOWED) executeSyntheticScript(tempScript) else UNTESTED
            } finally {
                try { Files.deleteIfExists(tempFile.toPath()) } catch (_: Exception) { /* Owned test file only. */ }
                try { Files.deleteIfExists(tempScript.toPath()) } catch (_: Exception) { /* Owned test file only. */ }
            }
        } catch (_: SecurityException) { tempWrite = DENIED }
        catch (_: Exception) { /* A missing temp directory leaves only these observations untested. */ }
        return Bundle().apply {
            putString(STATE, "observed")
            putString(PRIVATE_READ, directRead)
            putString(PRIVATE_WRITE, directWrite)
            putString(FD_READ, fdRead)
            putString(FD_WRITE, fdWrite)
            putString(DIRECTORY_CHILD_READ, directoryChildRead)
            putString(DIRECTORY_CHILD_WRITE, directoryChildWrite)
            putString(MEMORY_READ, memoryRead)
            putString(MEMORY_WRITE, memoryWrite)
            putString(TEMP_WRITE, tempWrite)
            putString(TEMP_READ, tempRead)
            putString(TEMP_EXEC, tempExec)
            putString(TEMP_EXEC_MAP, tempExecMap)
        }
    }

    private fun readPath(file: File, expected: ByteArray): String = try {
        val fd = Os.open(file.absolutePath, OsConstants.O_RDONLY, 0)
        try { readExact(fd, expected) } finally { Os.close(fd) }
    } catch (failure: ErrnoException) { errnoState(failure) }
    catch (_: SecurityException) { DENIED }
    catch (_: Exception) { UNTESTED }

    private fun readFd(descriptor: ParcelFileDescriptor, expected: ByteArray): String = try {
        readExact(descriptor.fileDescriptor, expected)
    } catch (failure: ErrnoException) { errnoState(failure) }
    catch (_: SecurityException) { DENIED }
    catch (_: Exception) { UNTESTED }

    private fun readExact(fd: java.io.FileDescriptor, expected: ByteArray): String {
        val bytes = ByteArray(expected.size)
        var read = 0
        while (read < bytes.size) {
            val count = Os.read(fd, bytes, read, bytes.size - read)
            if (count <= 0) return UNTESTED
            read += count
        }
        return if (bytes.contentEquals(expected)) ALLOWED else UNTESTED
    }

    private fun createFile(file: File, content: ByteArray): String = try {
        val fd = Os.open(file.absolutePath,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL, 0x180) // 0600
        try {
            var written = 0
            while (written < content.size) {
                val count = Os.write(fd, content, written, content.size - written)
                if (count <= 0) return UNTESTED
                written += count
            }
            ALLOWED
        } finally { Os.close(fd) }
    } catch (failure: ErrnoException) { errnoState(failure) }
    catch (_: SecurityException) { DENIED }
    catch (_: Exception) { UNTESTED }

    private fun executeSyntheticScript(script: File): String {
        val text = "#!/system/bin/sh\nexit 0\n".toByteArray(Charsets.US_ASCII)
        if (createFile(script, text) != ALLOWED || !script.setExecutable(true, true)) return UNTESTED
        return try {
            val child = ProcessBuilder(script.absolutePath).redirectErrorStream(true).start()
            if (!child.waitFor(2, TimeUnit.SECONDS)) {
                child.destroyForcibly()
                child.waitFor(2, TimeUnit.SECONDS)
                UNTESTED
            } else if (child.exitValue() == 0) ALLOWED else UNTESTED
        } catch (failure: IOException) {
            if (failure.message?.contains("Permission denied", ignoreCase = true) == true ||
                failure.message?.contains("EACCES", ignoreCase = true) == true) DENIED else UNTESTED
        } catch (_: Exception) { UNTESTED }
    }

    /** Observes W^X mapping policy without jumping into or interpreting the mapped bytes. */
    private fun mapSyntheticExecutable(file: File, length: Int): String = try {
        val fd = Os.open(file.absolutePath, OsConstants.O_RDONLY, 0)
        try {
            val address = Os.mmap(0L, length.toLong(),
                OsConstants.PROT_READ or OsConstants.PROT_EXEC, OsConstants.MAP_PRIVATE, fd, 0L)
            try { ALLOWED } finally { Os.munmap(address, length.toLong()) }
        } finally { Os.close(fd) }
    } catch (failure: ErrnoException) { errnoState(failure) }
    catch (_: SecurityException) { DENIED }
    catch (_: Exception) { UNTESTED }

    private fun errnoState(failure: ErrnoException): String = when (failure.errno) {
        OsConstants.EACCES, OsConstants.EPERM, OsConstants.EBADF, OsConstants.EROFS -> DENIED
        else -> UNTESTED
    }

    private fun errnoCodeState(code: Int): String = when (code) {
        0 -> ALLOWED
        OsConstants.EACCES, OsConstants.EPERM, OsConstants.EBADF, OsConstants.EROFS -> DENIED
        else -> UNTESTED
    }

    private fun send(reply: Messenger, id: String?, values: Bundle) {
        try {
            reply.send(Message.obtain(null, RESULT).apply {
                data = values.apply {
                    putString(ID, id)
                    putInt(UID, Process.myUid())
                    putBoolean(ISOLATED, Process.isIsolated())
                }
            })
        } catch (_: Exception) { /* A vanished test caller cannot accept a receipt. */ }
    }

    private fun canonicalId(id: String): Boolean = try { UUID.fromString(id).toString() == id }
    catch (_: IllegalArgumentException) { false }
}
