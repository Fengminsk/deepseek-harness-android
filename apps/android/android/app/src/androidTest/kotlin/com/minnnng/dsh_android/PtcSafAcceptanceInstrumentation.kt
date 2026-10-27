package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.content.Intent
import android.content.ComponentName
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.os.ResultReceiver
import org.json.JSONObject
import java.io.Closeable
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch

/** Owns only the synthetic provider grant; the pre-existing grants are compared on release. */
class PtcSafAcceptanceFixture private constructor(private val instrumentation: Instrumentation) : Closeable {
    private val context = instrumentation.targetContext.applicationContext
    private val resolver = context.contentResolver
    private val before = permissions()
    val caseId: String = UUID.randomUUID().toString()
    private lateinit var uri: Uri
    lateinit var root: String
        private set
    private var removed = false

    private fun permissions() = resolver.persistedUriPermissions.map {
        "${it.uri}|${it.isReadPermission}|${it.isWritePermission}"
    }.sorted()

    private fun control(method: String): Bundle {
        val done = CountDownLatch(1)
        var resultCode = 0
        var result: Bundle? = null
        val reply = object : ResultReceiver(null) {
            override fun onReceiveResult(code: Int, data: Bundle?) {
                resultCode = code; result = data; done.countDown()
            }
        }
        context.sendBroadcast(Intent().setComponent(ComponentName("${context.packageName}.test",
            PtcSafAcceptanceControlReceiver::class.java.name)).putExtra("method", method)
            .putExtra("caseId", caseId).putExtra("reply", reply),
            "${context.packageName}.permission.RUNTIME_ACCEPTANCE")
        check(done.await(10, TimeUnit.SECONDS)) { "Test provider control did not reply" }
        check(resultCode == 1) { result?.getString("failure") ?: "Test provider control failed" }
        return requireNotNull(result)
    }

    fun armBlockedRead() { control("ptc.arm") }
    fun readEntered(): Boolean = control("ptc.state").getBoolean("entered")

    fun revoke(searches: DocumentSearchManager): JSONObject {
        val result = DocumentAccess(context).revoke(root)
        check(searches.revokeRoot(root)) { "Revoked search owner has not stopped" }
        control("ptc.revoke")
        check(permissions() == before) { "Revocation changed another persisted grant" }
        return result
    }

    override fun close() {
        if (removed) return
        try {
            if (::uri.isInitialized && resolver.persistedUriPermissions.any { it.uri == uri })
                resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } finally {
            control("ptc.remove")
            removed = true
            check(permissions() == before) { "SAF acceptance changed a pre-existing grant" }
        }
    }

    companion object {
        fun open(instrumentation: Instrumentation): PtcSafAcceptanceFixture {
            val fixture = PtcSafAcceptanceFixture(instrumentation)
            val created = fixture.control("ptc.create")
            try {
                fixture.uri = Uri.parse(requireNotNull(created.getString("uri")))
                check(fixture.uri == android.provider.DocumentsContract.buildTreeDocumentUri(
                    PtcSafAcceptanceProvider.AUTHORITY, fixture.caseId))
                fixture.resolver.takePersistableUriPermission(fixture.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                fixture.root = MessageDigest.getInstance("SHA-256").digest(fixture.uri.toString().toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                check(DocumentAccess(fixture.context).hasGrant(fixture.root))
                return fixture
            } catch (failure: Throwable) {
                try { fixture.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
                throw failure
            }
        }
    }
}

/** Real persisted grant, bounded provider search and in-flight revocation, without user documents. */
class PtcSafAcceptanceInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val output = Bundle()
        try {
            check(Application.getProcessName() == targetContext.packageName + ":agent")
            AcceptanceForegroundLease.open(this).use {
                PtcSafAcceptanceFixture.open(this).use { fixture ->
                    val searches = DocumentSearchManager(targetContext)
                    val worker = Executors.newSingleThreadExecutor()
                    try {
                        val baseline = search(searches, fixture.root)
                        check(baseline.getBoolean("complete") && baseline.getJSONArray("matches").length() == 1)
                        check(baseline.getJSONArray("matches").getJSONObject(0).getString("path") == "alpha.txt")
                        fixture.armBlockedRead()
                        val running = worker.submit<JSONObject> { search(searches, fixture.root) }
                        val deadline = SystemClock.elapsedRealtime() + 10_000
                        while (!fixture.readEntered() && !running.isDone && SystemClock.elapsedRealtime() < deadline)
                            Thread.sleep(20)
                        check(fixture.readEntered()) { "Search never entered the controlled provider" }
                        fixture.revoke(searches)
                        var rejected = false
                        try { running.get(5, TimeUnit.SECONDS) }
                        catch (failure: java.util.concurrent.ExecutionException) {
                            check(failure.cause is java.util.concurrent.CancellationException ||
                                failure.cause is SecurityException || failure.cause is android.os.OperationCanceledException) {
                                "Search failed for an unrelated reason: ${failure.cause}"
                            }
                            rejected = true
                        }
                        check(rejected) { "Revoked in-flight search returned content" }
                        rejected = false
                        try { search(searches, fixture.root) } catch (failure: SecurityException) { rejected = true }
                        check(rejected) { "Search reused a revoked persisted grant" }
                        rejected = false
                        try { DocumentAccess(targetContext).read(fixture.root, "alpha.txt", 0) }
                        catch (failure: SecurityException) { rejected = true }
                        check(rejected) { "Read reused a revoked persisted grant" }
                        output.putString("root", fixture.root)
                    } finally {
                        searches.close(); worker.shutdownNow()
                        check(worker.awaitTermination(5, TimeUnit.SECONDS)) { "Search worker did not retire" }
                    }
                }
            }
            output.putString("passed", "controlled-saf-search-and-inflight-revocation")
            finish(-1, output)
        } catch (failure: Throwable) {
            output.putString("failure", (failure.javaClass.name + ": " + failure.message).take(2000))
            finish(0, output)
        }
    }

    private fun search(searches: DocumentSearchManager, root: String): JSONObject {
        val id = UUID.randomUUID().toString()
        searches.prepare(id)
        try {
            return searches.run(JSONObject().put("id", id).put("root", root).put("path", "")
                .put("query", "needle").put("caseSensitive", true).put("limits", JSONObject()
                    .put("fileBytes", 4096).put("totalBytes", 8192).put("maxEntries", 8).put("maxFiles", 4)
                    .put("maxDepth", 4).put("maxMatches", 8).put("previewChars", 512).put("maxDurationMs", 15000)))
        } finally { check(searches.cancel(id).getBoolean("cancelled")) }
    }
}
