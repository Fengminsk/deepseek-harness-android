package com.minnnng.dsh_android

import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/** Real JVM worker interruptions test the production state owner, not Binder or V8. */
object WorkflowCallbackRetirementTest {
    private fun checkCase(name: String, run: () -> Unit) { run(); println("PASS: $name") }
    private fun rejects(run: () -> Unit) {
        try { run() } catch (_: Exception) { return }
        error("Expected rejection")
    }

    @JvmStatic fun main(args: Array<String>) {
        checkCase("local retirement joins a blocked worker with external cancellation false") {
            val state = WorkflowCallbackRetirement()
            val entered = CountDownLatch(1)
            val external = AtomicBoolean(false)
            val worker = Executors.newSingleThreadExecutor()
            try {
                val task = worker.submit {
                    entered.countDown()
                    try { CountDownLatch(1).await() }
                    catch (failure: InterruptedException) { state.recordFailure(failure, external.get()) }
                }
                check(entered.await(3, TimeUnit.SECONDS))
                check(!state.confirmed(true, true))
                state.requestStop()
                worker.shutdownNow()
                task.get(3, TimeUnit.SECONDS)
                check(!external.get())
                check(state.confirmed(worker.awaitTermination(3, TimeUnit.SECONDS), true))
            } finally { worker.shutdownNow(); check(worker.awaitTermination(3, TimeUnit.SECONDS)) }
        }
        checkCase("external cancellation remains expected but still requires local retirement") {
            val state = WorkflowCallbackRetirement()
            state.recordFailure(InterruptedException(), true)
            check(!state.confirmed(true, true))
            state.requestStop()
            check(state.confirmed(true, true))
        }
        checkCase("unsolicited interruption or cancellation stays uncertain after later stop") {
            for (failure in listOf(InterruptedException(), CancellationException())) {
                val state = WorkflowCallbackRetirement()
                state.recordFailure(failure, false)
                state.requestStop()
                check(!state.confirmed(true, true))
            }
        }
        checkCase("late dispatch after local stop is cancellation, not a protocol failure") {
            val state = WorkflowCallbackRetirement()
            state.requireActive(false)
            state.requestStop()
            try { state.requireActive(false); error("Stopped dispatch was admitted") }
            catch (failure: CancellationException) { state.recordFailure(failure, false) }
            check(state.confirmed(true, true))
        }
        checkCase("RPC timeout, I/O, malformed reply and wrapped interruption remain uncertain") {
            for (failure in listOf(TimeoutException(), IOException(), IllegalArgumentException(),
                ExecutionException(InterruptedException()))) {
                val state = WorkflowCallbackRetirement()
                state.requestStop()
                state.recordFailure(failure, true)
                check(!state.confirmed(true, true))
            }
        }
        checkCase("an expected shutdown never clears an earlier uncertain outcome") {
            val state = WorkflowCallbackRetirement()
            state.markUncertain()
            state.requestStop()
            state.recordFailure(InterruptedException(), false)
            check(!state.confirmed(true, true))
        }
        checkCase("deadline alone may propose retirement while a callback is outstanding") {
            for (status in PtcScriptEngine.Status.values()) {
                val state = WorkflowCallbackRetirement()
                state.requireResult(status, 0)
                if (status == PtcScriptEngine.Status.DEADLINE_EXCEEDED) state.requireResult(status, 1)
                else rejects { state.requireResult(status, 1) }
            }
            val stopped = WorkflowCallbackRetirement()
            stopped.requestStop()
            rejects { stopped.requireResult(PtcScriptEngine.Status.DEADLINE_EXCEEDED, 1) }
        }
        checkCase("Node close cannot substitute for an unjoined real worker") {
            val state = WorkflowCallbackRetirement()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val worker = Executors.newSingleThreadExecutor()
            try {
                worker.submit {
                    entered.countDown()
                    while (release.count > 0) {
                        try { release.await() } catch (failure: InterruptedException) {
                            state.recordFailure(failure, false)
                        }
                    }
                }
                check(entered.await(3, TimeUnit.SECONDS))
                state.requestStop(); worker.shutdownNow()
                check(!state.confirmed(worker.awaitTermination(25, TimeUnit.MILLISECONDS), true))
                release.countDown()
                check(worker.awaitTermination(3, TimeUnit.SECONDS))
                check(!state.confirmed(true, false))
                check(state.confirmed(true, true))
            } finally { release.countDown(); worker.shutdownNow(); check(worker.awaitTermination(3, TimeUnit.SECONDS)) }
        }
        checkCase("callback retirement alone cannot attest guest death or binding cleanup") {
            val state = WorkflowCallbackRetirement()
            state.requestStop()
            check(state.confirmed(true, true))
            check(IsolatedScriptRetirement.classify(true, true, true, true, false, false,
                PtcScriptEngine.Status.DEADLINE_EXCEEDED) == IsolatedScriptReceipt.State.TIMED_OUT)
            for ((dead, cleaned) in listOf(false to true, true to false)) {
                check(IsolatedScriptRetirement.classify(true, true, dead, cleaned, false, false,
                    PtcScriptEngine.Status.DEADLINE_EXCEEDED) == IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED)
            }
        }
    }
}
