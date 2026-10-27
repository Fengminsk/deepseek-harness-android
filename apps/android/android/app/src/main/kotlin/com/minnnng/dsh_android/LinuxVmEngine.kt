package com.minnnng.dsh_android

import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/** Pure RISC-V interpreter: no host paths, sockets, shell subprocess, or Node runtime. */
internal class LinuxVmEngine {
    companion object {
        const val SHUT_DOWN = 0
        const val TIMED_OUT = 1
        const val CANCELLED = 2
        init { System.loadLibrary("pocket_linux_vm") }
    }

    /** Returns only after every virtual CPU and device has stopped accessing the supplied buffers. */
    external fun run(
        bios: ByteBuffer, kernel: ByteBuffer, disks: Array<ByteBuffer>,
        console: LinuxVmConsole, cancelled: AtomicBoolean, timeoutMs: Long,
    ): Int
}
