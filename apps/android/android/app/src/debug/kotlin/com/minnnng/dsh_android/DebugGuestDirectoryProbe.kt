package com.minnnng.dsh_android

/** Debug-only JNI syscall probe; fixed child name and bounded expected bytes. */
internal class DebugGuestDirectoryProbe {
    external fun probeRead(directoryFd: Int, expected: ByteArray): Int
    external fun probeWrite(directoryFd: Int): Int

    companion object {
        init { System.loadLibrary("pocket_guest_storage_probe") }
    }
}
