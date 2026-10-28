package com.minnnng.dsh_android

import android.content.ContentProviderClient
import android.content.ContentResolver
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private val root = "a".repeat(64)
private fun request(path: String = "fixture") = JSONObject().put("id", UUID.randomUUID().toString())
    .put("root", root).put("path", path).put("timeoutMs", 30000)
private fun latch(latch: CountDownLatch) = check(latch.await(5, TimeUnit.SECONDS)) { "Fixture barrier did not release" }
private fun rejects(block: () -> Unit): Throwable {
    try { block() } catch (failure: Throwable) { return failure }
    error("Expected failure")
}

fun main() {
    var checks = 0
    val calls = AtomicInteger()
    DocumentTextReads { _, _, _ -> calls.incrementAndGet(); JSONObject() }.use { owner ->
        val input = request()
        owner.prepare(input)
        check(owner.cancel(input.getString("id")).getBoolean("cancelled"))
        rejects { owner.run(input) }
        check(calls.get() == 0)
        checks++
    }
    // The actual provider opener and two-pass snapshot writer run behind the production owner.
    for (mode in listOf("cancel-open", "revoke-open", "deadline-open", "cancel-stream", "uncooperative")) {
        val cache = Files.createTempDirectory("document-text-host-")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val providerCloses = AtomicInteger()
        val pool = Executors.newFixedThreadPool(2)
        val uri = Uri.parse("content://fixture/document/owned")
        val owner = DocumentTextReads { params, signal, job ->
            val source = object : DocumentSnapshotStore.Source {
                override fun check() { job.check(); signal.throwIfCanceled() }
                override fun open(): InputStream {
                    if (params.getString("path") == "normal") return ByteArrayInputStream("normal text".toByteArray())
                    val provider = object : ContentProviderClient() {
                        override fun openAssetFile(uri: Uri, access: String, received: CancellationSignal): AssetFileDescriptor {
                            check(received === signal)
                            if (mode.endsWith("open")) {
                                received.setOnCancelListener { release.countDown() }
                                entered.countDown()
                                latch(release)
                                received.throwIfCanceled()
                            }
                            return object : AssetFileDescriptor() {
                                override fun createInputStream() = object : InputStream() {
                                    override fun read(): Int {
                                        entered.countDown()
                                        check(release.await(20, TimeUnit.SECONDS)) { "Provider fixture release missing" }
                                        return -1
                                    }
                                    override fun close() { if (mode != "uncooperative") release.countDown() }
                                }
                                override fun close() {}
                            }
                        }
                        override fun close() { providerCloses.incrementAndGet() }
                    }
                    val resolver = object : ContentResolver() {
                        override fun acquireUnstableContentProviderClient(uri: Uri): ContentProviderClient = provider
                    }
                    val stream = DocumentProviderRead.open(resolver, uri, signal)
                    job.attach(stream)
                    return object : java.io.FilterInputStream(stream) {
                        override fun close() { try { super.close() } finally { job.detach() } }
                    }
                }
            }
            val snapshot = DocumentSnapshotStore(cache.toFile()).create(
                if (params.getString("path") == "normal") "c".repeat(64) else root, "b".repeat(64), source)
            job.check()
            JSONObject().put("text", Files.readString(snapshot.file.toPath()))
        }
        try {
            val input = request()
            if (mode == "deadline-open") input.put("timeoutMs", 100)
            owner.prepare(input)
            val reading = pool.submit<JSONObject> { owner.run(input) }
            if (mode != "deadline-open") latch(entered)
            if (mode == "uncooperative") {
                check(!owner.cancel(input.getString("id")).getBoolean("cancelled"))
                val normal = request("normal")
                owner.prepare(normal)
                val independent = pool.submit<JSONObject> { owner.run(normal) }
                check(independent.get(5, TimeUnit.SECONDS).getString("text") == "normal text")
                check(owner.cancel(normal.getString("id")).getBoolean("cancelled"))
                check(!reading.isDone) { "Uncooperative provider retired without its barrier" }
                release.countDown()
            } else if (mode == "revoke-open") {
                check(owner.revokeRoot(root))
            } else if (mode != "deadline-open") {
                check(owner.cancel(input.getString("id")).getBoolean("cancelled"))
            }
            check(rejects { reading.get(5, TimeUnit.SECONDS) } is java.util.concurrent.ExecutionException)
            check(owner.cancel(input.getString("id")).getBoolean("cancelled"))
            check(providerCloses.get() == if (mode == "deadline-open" && entered.count > 0) 0 else 1)
            if (Files.exists(cache.resolve("document-read-snapshots"))) Files.list(cache.resolve("document-read-snapshots")).use { files ->
                check(files.noneMatch { it.fileName.toString().startsWith(".part-") })
            }
            checks++
        } finally {
            release.countDown()
            owner.close()
            pool.shutdownNow()
            check(pool.awaitTermination(5, TimeUnit.SECONDS))
            Files.walk(cache).use { files -> files.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
        }
    }
    println("DocumentTextReads host checks passed: $checks (explicit Android API doubles; no device claim)")
}
