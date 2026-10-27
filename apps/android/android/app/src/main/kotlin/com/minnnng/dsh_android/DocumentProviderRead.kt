package com.minnnng.dsh_android

import android.content.ContentResolver
import android.content.ContentProviderClient
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import android.os.RemoteException
import java.io.IOException
import java.io.InputStream
import java.io.FilterInputStream

/** Raw SAF opens receive cancellation; each returned stream owns its asset range and provider client. */
internal object DocumentProviderRead {
    private class OwnedStream(stream: InputStream, private val asset: AssetFileDescriptor,
                              private val provider: ContentProviderClient) : FilterInputStream(stream) {
        private var closed = false
        @Synchronized override fun close() {
            if (closed) return
            closed = true
            provider.use { asset.use { super.close() } }
        }
    }

    fun open(resolver: ContentResolver, uri: Uri, cancellation: CancellationSignal): InputStream {
        require(uri.scheme == ContentResolver.SCHEME_CONTENT) { "Document reads require a content URI" }
        cancellation.throwIfCanceled()
        val provider = resolver.acquireUnstableContentProviderClient(uri)
            ?: throw IOException("File provider unavailable")
        var descriptor: AssetFileDescriptor? = null
        var stream: InputStream? = null
        try {
            // Resolver's read-only typed conversion loses this signal in DocumentsProvider's */* path.
            descriptor = try { provider.openAssetFile(uri, "r", cancellation) }
                catch (failure: RemoteException) { throw IOException("File provider unavailable", failure) }
                ?: throw IOException("File provider unavailable")
            cancellation.throwIfCanceled()
            stream = descriptor.createInputStream()
            return OwnedStream(stream, descriptor, provider)
        } catch (failure: Throwable) {
            try { stream?.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            try { descriptor?.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            try { provider.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            throw failure
        }
    }

    fun <T> withStream(resolver: ContentResolver, uri: Uri, cancellation: CancellationSignal,
                       read: (InputStream) -> T): T {
        return open(resolver, uri, cancellation).use(read)
    }
}
