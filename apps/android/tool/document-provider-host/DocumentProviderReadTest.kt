package com.minnnng.dsh_android

import android.content.ContentProviderClient
import android.content.ContentResolver
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import android.os.RemoteException
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private val uri = Uri.parse("content://test/tree/fixture/document/fixture:alpha")
private class Provider(val open: (CancellationSignal?) -> AssetFileDescriptor?) : ContentProviderClient() {
    var closes = 0
    var closeFailure: RuntimeException? = null
    override fun openAssetFile(uri: Uri, mode: String, signal: CancellationSignal?): AssetFileDescriptor? {
        check(mode == "r")
        return open(signal)
    }
    override fun close() { closes++; closeFailure?.let { throw it } }
}
private fun resolver(provider: Provider) = object : ContentResolver() {
    override fun acquireUnstableContentProviderClient(uri: Uri): ContentProviderClient = provider
}
private class Asset(val stream: () -> InputStream) : AssetFileDescriptor() {
    var closes = 0
    var closeFailure: IOException? = null
    override fun createInputStream(): InputStream = stream()
    override fun close() { closes++; closeFailure?.let { throw it } }
}
private fun failure(work: () -> Unit): Throwable {
    try { work() } catch (error: Throwable) { return error }
    error("Expected failure")
}

fun main() {
    var checks = 0
    val signal = CancellationSignal()
    val bytes = "prefixneedleSUFFIX".toByteArray()
    val assets = mutableListOf<Asset>()
    val provider = Provider { received ->
        check(received === signal)
        Asset { ByteArrayInputStream(bytes, 6, 6) }.also { assets.add(it) }
    }
    val source = object : DocumentBinaryReadAccess.Source {
        override fun check() = signal.throwIfCanceled()
        override fun open(): InputStream = DocumentProviderRead.open(resolver(provider), uri, signal)
    }
    val binary = DocumentBinaryReadAccess.read(source, 100)
    check(String(binary.bytes) == "needle" && assets.size == 2 && assets.all { it.closes == 1 } && provider.closes == 2)
    checks++ // The real two-pass image reader reopens the bounded asset and excludes surrounding bytes.

    val missing = Provider { null }
    check(failure { DocumentProviderRead.open(resolver(missing), uri, signal) } is IOException && missing.closes == 1)
    checks++
    val remote = Provider { throw RemoteException() }
    check(failure { DocumentProviderRead.open(resolver(remote), uri, signal) }.cause is RemoteException && remote.closes == 1)
    checks++
    val invalid = Provider { error("must not open") }
    check(failure { DocumentProviderRead.open(resolver(invalid), Uri.parse("file:///tmp/private"), signal) } is IllegalArgumentException)
    check(invalid.closes == 0)
    checks++

    val duringOpen = CancellationSignal()
    val unopenedStream = Asset { error("Cancelled open must not construct a stream") }
    val cancelledProvider = Provider { duringOpen.cancel(); unopenedStream }
    check(failure { DocumentProviderRead.open(resolver(cancelledProvider), uri, duringOpen) } is CancellationException)
    check(unopenedStream.closes == 1 && cancelledProvider.closes == 1)
    checks++

    val clientCloseFailure = IllegalStateException("Provider release failed")
    val closedAsset = Asset { ByteArrayInputStream(byteArrayOf(1)) }
    val failedClose = Provider { closedAsset }.also { it.closeFailure = clientCloseFailure }
    check(failure { DocumentProviderRead.withStream(resolver(failedClose), uri, signal) { it.read() } } === clientCloseFailure)
    check(closedAsset.closes == 1 && failedClose.closes == 1)
    checks++

    var streamCloses = 0
    val once = Asset { object : ByteArrayInputStream(byteArrayOf(1)) { override fun close() { streamCloses++ } } }
    val onceProvider = Provider { once }
    val onceStream = DocumentProviderRead.open(resolver(onceProvider), uri, signal)
    onceStream.close()
    onceStream.close()
    check(streamCloses == 1 && once.closes == 1 && onceProvider.closes == 1)
    checks++

    val openingFailure = IOException("stream construction failed")
    val broken = Asset { throw openingFailure }
    val brokenProvider = Provider { broken }
    check(failure { DocumentProviderRead.open(resolver(brokenProvider), uri, signal) } === openingFailure)
    check(broken.closes == 1 && brokenProvider.closes == 1)
    checks++

    val original = IOException("reading failed")
    val closingFailure = IOException("stream close failed")
    val both = Asset { object : ByteArrayInputStream(byteArrayOf(1)) {
        override fun close() { throw closingFailure }
    } }.also { it.closeFailure = IOException("asset close failed") }
    val bothProvider = Provider { both }
    check(failure { DocumentProviderRead.withStream(resolver(bothProvider), uri, signal) { throw original } } === original)
    check(original.suppressed.single() === closingFailure && closingFailure.suppressed.single() === both.closeFailure)
    check(both.closes == 1 && bothProvider.closes == 1)
    checks++

    val entered = CountDownLatch(1)
    val cancelled = CountDownLatch(1)
    val openingSignal = CancellationSignal()
    val blocked = Provider { received ->
        check(received === openingSignal)
        received.setOnCancelListener { cancelled.countDown() }
        entered.countDown()
        check(cancelled.await(5, TimeUnit.SECONDS)) { "Provider did not receive cancellation" }
        received.throwIfCanceled()
        error("Cancelled open returned")
    }
    val job = DocumentSearchJob { openingSignal.cancel() }
    check(job.start())
    val outcome = AtomicReference<Throwable?>()
    val worker = Thread {
        try { DocumentProviderRead.withStream(resolver(blocked), uri, openingSignal) { job.attach(it) } }
        catch (error: Throwable) { outcome.set(error) }
        finally { job.finish() }
    }
    try {
        worker.start()
        check(entered.await(5, TimeUnit.SECONDS))
        check(!job.awaitStopped(0))
        job.requestCancel()
        check(job.awaitStopped(5000))
        worker.join(5000)
        check(!worker.isAlive && outcome.get() is CancellationException && blocked.closes == 1)
        checks++
    } finally { openingSignal.cancel(); worker.join(5000); check(!worker.isAlive) }

    val alreadyCancelled = CancellationSignal().also { it.cancel() }
    check(failure { DocumentProviderRead.open(resolver(invalid), uri, alreadyCancelled) } is CancellationException)
    check(invalid.closes == 0)
    checks++
    println("DocumentProviderRead host checks passed: $checks (Android API transport simulated)")
}
