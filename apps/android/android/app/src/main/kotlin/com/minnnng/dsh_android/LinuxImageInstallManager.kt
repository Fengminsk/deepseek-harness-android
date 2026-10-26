package com.minnnng.dsh_android

import android.content.Context
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.function.BooleanSupplier
import javax.net.ssl.HttpsURLConnection

/** Explicit App operation: download the reviewed image as inert data. Never called by an Agent tool. */
internal object LinuxImageInstallManager {
    private const val TRANSFER_DEADLINE_MS = 90_000L

    fun inspect(context: Context): PinnedLinuxImageStore.Installed? =
        PinnedLinuxImageStore(context.noBackupFilesDir.toPath()).inspect()

    fun install(context: Context, cancelled: BooleanSupplier): PinnedLinuxImageStore.Installed {
        val store = PinnedLinuxImageStore(context.noBackupFilesDir.toPath())
        store.inspect()?.let { return it }
        if (cancelled.getAsBoolean()) throw IOException("Linux image installation cancelled")
        val endpoint = URL(PinnedLinuxImageStore.SOURCE_URL)
        val connection = endpoint.openConnection() as HttpsURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 10_000
        connection.readTimeout = 15_000
        connection.setRequestProperty("Accept-Encoding", "identity")
        try {
            if (connection.responseCode != HttpsURLConnection.HTTP_OK ||
                connection.url.toExternalForm() != PinnedLinuxImageStore.SOURCE_URL) {
                throw IOException("Pinned Linux image source returned an unexpected response")
            }
            val statedBytes = connection.contentLengthLong
            if (statedBytes >= 0 && statedBytes != LinuxImageLeaseOwner.ARCHIVE_BYTES) {
                throw IOException("Pinned Linux image source size changed")
            }
            val started = System.nanoTime()
            connection.inputStream.use { stream ->
                val bounded = object : FilterInputStream(stream) {
                    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                        if (cancelled.getAsBoolean() || Thread.currentThread().isInterrupted) {
                            throw IOException("Linux image installation cancelled")
                        }
                        if (TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) >=
                            TRANSFER_DEADLINE_MS) {
                            throw IOException("Pinned Linux image transfer timed out")
                        }
                        return super.read(bytes, offset, length)
                    }

                    override fun read(): Int {
                        val one = ByteArray(1)
                        val count = read(one, 0, 1)
                        return if (count < 0) -1 else one[0].toInt() and 0xff
                    }
                }
                return store.install(bounded)
            }
        } finally {
            connection.disconnect()
        }
    }
}
