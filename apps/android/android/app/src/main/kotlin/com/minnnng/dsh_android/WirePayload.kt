package com.minnnng.dsh_android

import android.os.Bundle
import android.os.SharedMemory
import android.system.OsConstants

/** Large transcripts and configuration pages travel by read-only shared memory, not Binder's transaction buffer. */
object WirePayload {
    fun encode(raw: String): Bundle {
        val bytes = raw.toByteArray(Charsets.UTF_8)
        require(bytes.size <= 32 * 1024 * 1024) { "响应超过 32 MiB，请缩小读取范围" }
        if (bytes.size < 32 * 1024) return Bundle().apply { putString("json", raw) }
        val memory = SharedMemory.create("pocket-harness-rpc", bytes.size)
        try {
            val buffer = memory.mapReadWrite()
            try { buffer.put(bytes) } finally { SharedMemory.unmap(buffer) }
            check(memory.setProtect(OsConstants.PROT_READ)) { "Cannot protect IPC payload" }
            return Bundle().apply { putParcelable("payload", memory) }
        } catch (error: Throwable) { memory.close(); throw error }
    }

    @Suppress("DEPRECATION")
    fun decode(bundle: Bundle): String {
        bundle.getString("json")?.let { return it }
        val memory = bundle.getParcelable<SharedMemory>("payload") ?: error("Missing IPC payload")
        return memory.use {
            require(it.size <= 32 * 1024 * 1024) { "IPC payload too large" }
            val buffer = it.mapReadOnly()
            try { Charsets.UTF_8.decode(buffer).toString() } finally { SharedMemory.unmap(buffer) }
        }
    }

    @Suppress("DEPRECATION")
    fun close(bundle: Bundle) { bundle.getParcelable<SharedMemory>("payload")?.close() }
}
