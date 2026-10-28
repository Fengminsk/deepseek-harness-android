package com.minnnng.dsh_android

import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/** Owner-initiated shutdown and confirmed callback closure never erase unrelated uncertainty. */
internal class IsolatedToolCallbackRetirement {
    private val stopping = AtomicBoolean(false)
    private val uncertain = AtomicBoolean(false)
    private val parentCancelled = AtomicBoolean(false)

    fun requestStop() { stopping.set(true) }
    fun parentCancellationRequested(): Boolean = parentCancelled.get()

    fun requireActive(externalCancelled: Boolean) {
        if (stopping.get() || externalCancelled)
            throw CancellationException("Isolated tool callback stopped by its owner")
    }

    /** The caller has validated the exact privately confirmed run/call reply. */
    fun confirmedClosure(cancelRequested: Boolean, externalCancelled: Boolean) {
        check(cancelRequested || stopping.get() || externalCancelled) {
            "Callback closure has no matching owner shutdown"
        }
        if (cancelRequested) parentCancelled.set(true)
        requestStop()
    }

    fun recordFailure(failure: Exception, externalCancelled: Boolean) {
        val expected = (stopping.get() || externalCancelled) &&
            (failure is InterruptedException || failure is CancellationException)
        if (!expected) uncertain.set(true)
    }

    fun markUncertain() { uncertain.set(true) }
    fun confirmed(workerExited: Boolean, nodeClosed: Boolean): Boolean =
        stopping.get() && workerExited && nodeClosed && !uncertain.get()

    fun requireResult(status: PtcScriptEngine.Status, outstanding: Int, reviewedPtc: Boolean) {
        require(outstanding >= 0)
        check(!stopping.get()) { "Tool callback is already stopping" }
        check(outstanding == 0 || reviewedPtc && status == PtcScriptEngine.Status.DEADLINE_EXCEEDED) {
            "Tool result has outstanding callbacks"
        }
    }
}
