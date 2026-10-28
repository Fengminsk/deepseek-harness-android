package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import org.json.JSONObject
import java.io.Closeable
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

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
    private var created = false
    private val bound = AtomicBoolean()
    private val closed = AtomicBoolean()
    private val failure = AtomicReference<Throwable?>()
    private val connected = CompletableFuture<Messenger>()
    private val nextRequest = AtomicInteger()
    private data class Request(val id: Int, val method: String, val result: CompletableFuture<Bundle>)
    private val pending = AtomicReference<Request?>()
    private val component = ComponentName("${context.packageName}.test", PtcSafAcceptanceControlService::class.java.name)
    private val expectedUid = instrumentation.context.applicationInfo.uid
    var controlUid = -1
        private set
    var controlPid = -1
        private set
    private fun fail(error: Throwable) {
        failure.compareAndSet(null, error)
        connected.completeExceptionally(error)
        pending.get()?.result?.completeExceptionally(error)
    }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (name != component) { fail(IllegalStateException("Unexpected SAF control component")); return }
            if (!closed.get()) connected.complete(Messenger(binder))
        }
        override fun onServiceDisconnected(name: ComponentName) { fail(IllegalStateException("SAF control service disconnected")) }
        override fun onBindingDied(name: ComponentName) { fail(IllegalStateException("SAF control binding died")) }
        override fun onNullBinding(name: ComponentName) { fail(IllegalStateException("SAF control binding rejected")) }
    }
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        val request = pending.get()
        if (request != null && message.arg1 == request.id) {
            try {
                val value = message.data
                check(message.sendingUid == expectedUid && expectedUid != Process.myUid()) { "SAF control reply is not from the test UID" }
                check(value.getInt("schema") == 1 && value.getString("caseId") == caseId &&
                    value.getString("method") == request.method && value.getInt("controlUid") == expectedUid &&
                    value.getInt("controlPid") > 0) { "SAF control reply identity mismatch" }
                check(controlPid == -1 || controlPid == value.getInt("controlPid")) { "SAF control process changed" }
                controlUid = expectedUid
                controlPid = value.getInt("controlPid")
                check(message.what == 1) { value.getString("failure") ?: "Test provider control failed" }
                request.result.complete(checkNotNull(value.getBundle("result")))
            } catch (error: Throwable) { fail(error) }
        }
        true
    })

    private fun bind() {
        check(Looper.myLooper() != Looper.getMainLooper())
        check(instrumentation.context.packageName == component.packageName) { "Unexpected instrumentation package" }
        check(expectedUid != Process.myUid()) { "SAF acceptance requires a separate test APK UID" }
        val accepted = context.bindService(Intent().setComponent(component)
            .setAction(PtcSafAcceptanceControlService.ACTION_PREFIX + caseId).putExtra("caseId", caseId),
            connection, Context.BIND_AUTO_CREATE)
        bound.set(accepted)
        check(accepted) { "SAF control service binding was refused" }
        try { connected.get(10, TimeUnit.SECONDS) }
        catch (error: Throwable) { throw IllegalStateException("SAF control service did not connect", error) }
    }

    private fun permissions() = resolver.persistedUriPermissions.map {
        "${it.uri}|${it.isReadPermission}|${it.isWritePermission}"
    }.sorted()

    private fun control(method: String): Bundle {
        check(!closed.get()) { "SAF control fixture is closed" }
        failure.get()?.let { throw it }
        val request = Request(nextRequest.incrementAndGet(), method, CompletableFuture())
        check(pending.compareAndSet(null, request)) { "Overlapping SAF control requests" }
        try {
            connected.get(10, TimeUnit.SECONDS).send(Message.obtain().apply {
                what = 1
                arg1 = request.id
                replyTo = replies
                data = Bundle().apply { putString("method", method); putString("caseId", caseId) }
            })
            return request.result.get(10, TimeUnit.SECONDS)
        } catch (error: Throwable) {
            val described = IllegalStateException("SAF bound control failed: $method", error)
            fail(described)
            throw described
        } finally { pending.compareAndSet(request, null) }
    }

    private fun unbind() {
        closed.set(true)
        if (bound.compareAndSet(true, false)) context.unbindService(connection)
        pending.get()?.result?.completeExceptionally(IllegalStateException("SAF control fixture closed"))
    }

    private fun reportControl() {
        instrumentation.sendStatus(1, Bundle().apply {
            putString("safControl", JSONObject().put("schema", 1).put("caseId", caseId)
                .put("transport", "bound-service").put("appUid", Process.myUid())
                .put("controlUid", controlUid).put("controlPid", controlPid).toString())
        })
    }

    fun armBlockedRead() { control("ptc.arm") }
    fun readEntered(): Boolean = control("ptc.state").getBoolean("entered")
    fun readSignalPresent(): Boolean = control("ptc.state").getBoolean("signalPresent")

    fun revoke(searches: DocumentSearchManager): JSONObject {
        val result = DocumentAccess(context).revoke(root)
        check(searches.revokeRoot(root)) { "Revoked search owner has not stopped" }
        control("ptc.revoke")
        check(permissions() == before) { "Revocation changed another persisted grant" }
        return result
    }

    override fun close() {
        if (closed.get()) { failure.get()?.let { throw it }; return }
        try {
            try {
                if (::uri.isInitialized && resolver.persistedUriPermissions.any { it.uri == uri })
                    resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } finally {
                if (created && !removed) { control("ptc.remove"); removed = true }
                check(permissions() == before) { "SAF acceptance changed a pre-existing grant" }
            }
        } catch (error: Throwable) { fail(error); throw error }
        finally { unbind() }
    }

    companion object {
        fun open(instrumentation: Instrumentation): PtcSafAcceptanceFixture {
            val fixture = PtcSafAcceptanceFixture(instrumentation)
            try {
                fixture.bind()
                val created = fixture.control("ptc.create")
                fixture.created = true
                fixture.reportControl()
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
    private var arguments = Bundle()
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        this.arguments = arguments?.let { Bundle(it) } ?: Bundle()
        start()
    }
    override fun onStart() {
        val output = Bundle()
        try {
            check(Application.getProcessName() == targetContext.packageName + ":agent")
            val ownerLock = Any()
            var activeSearches: DocumentSearchManager? = null
            var activeReads: DocumentTextReads? = null
            var cancellation: CompletableFuture<Void>? = null
            AcceptanceCarrierLease.open(this, arguments, output, 90_000) {
                synchronized(ownerLock) {
                    val owner = activeSearches
                    val reader = activeReads
                    if ((owner != null || reader != null) && cancellation == null)
                        cancellation = CompletableFuture.runAsync {
                            try { owner?.close() } finally { reader?.close() }
                        }
                }
            }.use { foreground ->
                DocumentTextReadAcceptance.run(this, output, { foreground.checkActive() }) {
                    synchronized(ownerLock) { activeReads = it }
                }
                PtcSafAcceptanceFixture.open(this).use { fixture ->
                    val searches = DocumentSearchManager(targetContext)
                    val worker = Executors.newSingleThreadExecutor()
                    var primaryFailure: Throwable? = null
                    try {
                        synchronized(ownerLock) { activeSearches = searches }
                        foreground.checkActive()
                        val baseline = search(searches, fixture.root)
                        check(baseline.getBoolean("complete") && baseline.getJSONArray("matches").length() == 1)
                        check(baseline.getJSONArray("matches").getJSONObject(0).getString("path") == "alpha.txt")
                        fixture.armBlockedRead()
                        foreground.checkActive()
                        val running = worker.submit<JSONObject> { search(searches, fixture.root) }
                        val deadline = SystemClock.elapsedRealtime() + 10_000
                        while (!fixture.readEntered() && !running.isDone && SystemClock.elapsedRealtime() < deadline) {
                            foreground.checkActive()
                            Thread.sleep(20)
                        }
                        foreground.checkActive()
                        check(fixture.readEntered()) { "Search never entered the controlled provider" }
                        output.putString("openDocumentSignalPresent", fixture.readSignalPresent().toString())
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
                        check(output.getString("openDocumentSignalPresent") == "true") { "Provider received no search cancellation signal" }
                        rejected = false
                        try { search(searches, fixture.root) } catch (failure: SecurityException) { rejected = true }
                        check(rejected) { "Search reused a revoked persisted grant" }
                        rejected = false
                        try { DocumentAccess(targetContext).read(fixture.root, "alpha.txt", 0) }
                        catch (failure: SecurityException) { rejected = true }
                        check(rejected) { "Read reused a revoked persisted grant" }
                        foreground.checkActive()
                        output.putString("root", fixture.root)
                        output.putString("safControlUid", fixture.controlUid.toString())
                        output.putString("safControlPid", fixture.controlPid.toString())
                    } catch (failure: Throwable) {
                        primaryFailure = failure
                        throw failure
                    } finally {
                        val pending = synchronized(ownerLock) { activeSearches = null; cancellation }
                        var cleanupFailure: Throwable? = null
                        try {
                            if (pending == null) searches.close() else pending.get(10, TimeUnit.SECONDS)
                        } catch (failure: Throwable) { cleanupFailure = failure }
                        try {
                            worker.shutdownNow()
                            check(worker.awaitTermination(5, TimeUnit.SECONDS)) { "Search worker did not retire" }
                        } catch (failure: Throwable) {
                            if (cleanupFailure == null) cleanupFailure = failure else cleanupFailure.addSuppressed(failure)
                        }
                        cleanupFailure?.let { if (primaryFailure == null) throw it else primaryFailure.addSuppressed(it) }
                    }
                }
                foreground.checkActive()
                output.putString("nativeOwnersClosed", "true")
            }
            output.putString("passed", "controlled-saf-search-and-inflight-revocation")
            finish(-1, output)
        } catch (failure: Throwable) {
            output.putString("failure", (failure.javaClass.name + ": " + failure.message).take(2000))
            output.putString("failureDetails", failure.stackTraceToString().take(6000))
            finish(0, output)
        }
    }

    private fun search(searches: DocumentSearchManager, root: String): JSONObject {
        val id = UUID.randomUUID().toString()
        searches.prepare(id)
        var primaryFailure: Throwable? = null
        try {
            return searches.run(JSONObject().put("id", id).put("root", root).put("path", "")
                .put("query", "needle").put("caseSensitive", true).put("limits", JSONObject()
                    .put("fileBytes", 4096).put("totalBytes", 8192).put("maxEntries", 8).put("maxFiles", 4)
                    .put("maxDepth", 4).put("maxMatches", 8).put("previewChars", 512).put("maxDurationMs", 15000)))
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try { check(searches.cancel(id).getBoolean("cancelled")) { "Search cancellation did not complete" } }
            catch (cleanup: Throwable) { if (primaryFailure == null) throw cleanup else primaryFailure.addSuppressed(cleanup) }
        }
    }
}
