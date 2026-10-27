package com.minnnng.dsh_android

import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/** Per-run shutdown evidence; stopping never clears an earlier uncertain outcome. */
internal class WorkflowCallbackRetirement {
    private val stopRequested = AtomicBoolean(false)
    private val uncertain = AtomicBoolean(false)

    fun requestStop() { stopRequested.set(true) }

    fun requireActive(externalCancelled: Boolean) {
        if (stopRequested.get() || externalCancelled)
            throw CancellationException("Workflow callback stopped by its owner")
    }

    fun recordFailure(failure: Exception, externalCancelled: Boolean) {
        val expectedInterrupt = (stopRequested.get() || externalCancelled) &&
            (failure is InterruptedException || failure is CancellationException)
        if (!expectedInterrupt) uncertain.set(true)
    }

    fun markUncertain() { uncertain.set(true) }

    fun confirmed(workerExited: Boolean, nodeClosed: Boolean): Boolean =
        stopRequested.get() && workerExited && nodeClosed && !uncertain.get()

    /** Expiry may interrupt an outstanding child wait; successful output may not. */
    fun requireResult(status: PtcScriptEngine.Status, outstanding: Int) {
        require(outstanding >= 0)
        check(!stopRequested.get()) { "Workflow callback is already stopping" }
        check(outstanding == 0 || status == PtcScriptEngine.Status.DEADLINE_EXCEEDED) {
            "Workflow result has outstanding callbacks"
        }
    }
}
