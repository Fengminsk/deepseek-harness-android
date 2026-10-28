package com.minnnng.dsh_android

import android.app.Instrumentation
import android.os.Bundle
import android.os.SystemClock
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real separate-UID provider reads using only this helper's generated grant and files. */
internal object DocumentTextReadAcceptance {
    fun run(instrumentation: Instrumentation, output: Bundle, checkActive: () -> Unit,
        onOwner: (DocumentTextReads?) -> Unit) {
        PtcSafAcceptanceFixture.open(instrumentation).use { fixture ->
            val reads = DocumentTextReads { params, signal, job ->
                DocumentAccess(instrumentation.targetContext).read(params.getString("root"), params.getString("path"),
                    DocumentReadAccess.offset(params.opt("offset")), null, signal, job)
            }
            val workers = Executors.newFixedThreadPool(2)
            var primary: Throwable? = null
            try {
                onOwner(reads)
                checkActive()
                fixture.armBlockedRead()
                fun request(path: String) = JSONObject().put("id", UUID.randomUUID().toString())
                    .put("root", fixture.root).put("path", path).put("offset", 0).put("timeoutMs", 30000)
                val first = request("alpha.txt")
                reads.prepare(first)
                val blocked = workers.submit<JSONObject> { reads.run(first) }
                val deadline = SystemClock.elapsedRealtime() + 10000
                while (!fixture.readEntered() && !blocked.isDone && SystemClock.elapsedRealtime() < deadline) {
                    checkActive()
                    Thread.sleep(20)
                }
                checkActive()
                check(fixture.readEntered() && !blocked.isDone) { "Text read never blocked in provider openDocument" }
                check(fixture.readSignalPresent()) { "Text read provider received no CancellationSignal" }
                output.putString("textReadProviderSignalPresent", "true")
                val second = request("beta.txt")
                reads.prepare(second)
                val normal = workers.submit<JSONObject> { reads.run(second) }.get(10, TimeUnit.SECONDS)
                check(normal.getString("text") == "unmatched fixture\n") { "Independent text page changed" }
                check(!blocked.isDone) { "First read ended before the independent page completed" }
                check(reads.cancel(second.getString("id")).getBoolean("cancelled"))
                output.putString("textReadSecondCompletedWhileFirstPending", "true")
                checkActive()
                check(reads.cancel(first.getString("id")).getBoolean("cancelled")) { "Text read cancellation did not retire its owner" }
                var rejected = false
                try { blocked.get(5, TimeUnit.SECONDS) }
                catch (failure: java.util.concurrent.ExecutionException) {
                    var cause: Throwable? = failure.cause
                    while (cause != null) {
                        if (cause is java.util.concurrent.CancellationException || cause is android.os.OperationCanceledException) rejected = true
                        cause = cause.cause
                    }
                    check(rejected) { "Blocked text read failed for an unrelated reason: ${failure.cause?.javaClass?.simpleName}" }
                }
                check(rejected) { "Cancelled text read returned a late page" }
                output.putString("textReadCancelled", "true")
                output.putString("textReadLateResultRejected", "true")
                checkActive()
            } catch (failure: Throwable) { primary = failure; throw failure }
            finally {
                var cleanup: Throwable? = null
                try { reads.close() }
                catch (failure: Throwable) { cleanup = failure }
                workers.shutdownNow()
                if (!workers.awaitTermination(10, TimeUnit.SECONDS)) {
                    val failure = IllegalStateException("Text read acceptance workers did not retire")
                    if (cleanup == null) cleanup = failure else cleanup.addSuppressed(failure)
                }
                onOwner(null)
                if (cleanup != null) {
                    if (primary == null) throw cleanup else primary.addSuppressed(cleanup)
                } else output.putString("textReadOwnerClosed", "true")
            }
        }
    }
}
