package com.minnnng.dsh_android

import android.os.Bundle
import android.os.Message
import android.os.Messenger
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.ExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private const val RUN = "11111111-1111-4111-8111-111111111111"
private const val NONCE = "22222222-2222-4222-8222-222222222222"
private const val UID = 99001
private fun latch(latch: CountDownLatch) { check(latch.await(3, TimeUnit.SECONDS)) { "Barrier not reached" } }
private fun closure(parent: Boolean) = JSONObject().put("runId", RUN).put("callId", 1)
    .put("closed", true).put("cancelRequested", parent)
private fun valid() = JSONObject().put("runId", RUN).put("callId", 1).put("value", JSONObject().put("ok", true))
private fun awaitIgnoringInterrupts(latch: CountDownLatch) {
    while (latch.count > 0) try { latch.await() } catch (_: InterruptedException) { /* Test barrier owns release. */ }
}
private class Fixture(
    call: () -> JSONObject,
    close: () -> Boolean = { true },
) {
    val cancelled = AtomicBoolean(false)
    val sent = AtomicInteger()
    val rejected = CountDownLatch(1)
    val replied = CountDownLatch(1)
    val closed = AtomicInteger()
    val bridge = IsolatedScriptToolBridge(IsolatedScriptWire.Request(RUN, NONCE, "(input)=>input", "{}", 5000),
        "private-native-token", { cancelled.get() }, object : IsolatedScriptToolBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(params.getString("runId") == RUN && params.getInt("callId") == 1)
                check(timeoutMillis in 1..8000)
                return call()
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(runId == RUN && token == "private-native-token")
                closed.incrementAndGet()
                return close()
            }
        }, true)
    fun start() {
        val message = Message.obtain(null, IsolatedScriptWire.HOST_CALL)
        message.sendingUid = UID
        message.data = Bundle().apply {
            putInt(IsolatedScriptWire.KEY_VERSION, IsolatedScriptWire.VERSION)
            putString(IsolatedScriptWire.KEY_RUN, RUN); putString(IsolatedScriptWire.KEY_NONCE, NONCE)
            putInt(IsolatedScriptWire.KEY_HOST_SEQUENCE, 1); putInt(IsolatedScriptWire.KEY_UID, UID)
            putString(IsolatedScriptWire.KEY_HOST_REQUEST,
                "{\"action\":\"TOOL_CALL\",\"callId\":1,\"name\":\"linux_exec\",\"arguments\":{\"command\":\"fixture\"}}")
        }
        bridge.call(message, Messenger { sent.incrementAndGet(); replied.countDown() }) { rejected.countDown() }
    }
}

fun main() {
    var checks = 0
    fun verify(name: String, body: () -> Unit) { body(); checks++; println("PASS $name") }
    verify("native cancellation interrupts RPC but waits for the original Node close barrier") {
        val entered = CountDownLatch(1); val closeEntered = CountDownLatch(1); val settle = CountDownLatch(1)
        val fixture = Fixture({ entered.countDown(); CountDownLatch(1).await(); valid() },
            { closeEntered.countDown(); latch(settle); true })
        val waiter = Executors.newSingleThreadExecutor()
        try {
            fixture.start(); latch(entered); fixture.cancelled.set(true); fixture.bridge.cancel(); latch(closeEntered)
            val retiring = waiter.submit<IsolatedScriptHostBridge.Retirement> { fixture.bridge.retire(false) }
            Thread.sleep(20); check(!retiring.isDone) { "Close cannot settle before the nested callback" }
            settle.countDown()
            check(retiring.get(3, TimeUnit.SECONDS) == IsolatedScriptHostBridge.Retirement.FAILED)
            check(fixture.sent.get() == 0 && fixture.closed.get() == 1)
        } finally { settle.countDown(); fixture.bridge.cancel(); waiter.shutdownNow(); check(waiter.awaitTermination(3, TimeUnit.SECONDS)) }
    }
    verify("privately confirmed parent-cancel reply may arrive before native cancel RPC") {
        val fixture = Fixture({ closure(true) })
        fixture.start(); latch(fixture.rejected)
        check(!fixture.cancelled.get()); check(fixture.bridge.parentCancellationRequested)
        check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.FAILED)
        check(fixture.sent.get() == 0)
        check(IsolatedScriptRetirement.classify(true, true, true, true,
            fixture.bridge.parentCancellationRequested, false, null) == IsolatedScriptReceipt.State.CANCELLED)
    }
    verify("confirmed cancellation cannot replace a failed Node close") {
        val fixture = Fixture({ closure(true) }, { false })
        fixture.start(); latch(fixture.rejected)
        check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.UNCONFIRMED)
    }
    verify("late valid result is withheld after local cancellation without inventing uncertainty") {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val fixture = Fixture({ entered.countDown(); awaitIgnoringInterrupts(release); valid() })
        try {
            fixture.start(); latch(entered); fixture.bridge.cancel(); release.countDown(); latch(fixture.rejected)
            check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.FAILED)
            check(fixture.sent.get() == 0)
        } finally { release.countDown(); fixture.bridge.cancel() }
    }
    verify("native PTC deadline may retire an outstanding call without becoming user cancellation") {
        val entered = CountDownLatch(1)
        val fixture = Fixture({ entered.countDown(); CountDownLatch(1).await(); valid() })
        fixture.start(); latch(entered)
        fixture.bridge.proposedResult(UID, UID, PtcScriptEngine.Status.DEADLINE_EXCEEDED)
        check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.FAILED)
        check(!fixture.bridge.parentCancellationRequested && !fixture.cancelled.get())
        check(IsolatedScriptRetirement.classify(true, true, true, true, false, false,
            PtcScriptEngine.Status.DEADLINE_EXCEEDED) == IsolatedScriptReceipt.State.TIMED_OUT)
    }
    verify("successful output still rejects an outstanding callback") {
        val entered = CountDownLatch(1)
        val fixture = Fixture({ entered.countDown(); CountDownLatch(1).await(); valid() })
        fixture.start(); latch(entered)
        check(runCatching { fixture.bridge.proposedResult(UID, UID) }.isFailure)
        fixture.bridge.cancel(); check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.FAILED)
    }
    for (failure in listOf(IOException("rpc"), TimeoutException("rpc"), ExecutionException(InterruptedException()))) {
        verify("${failure.javaClass.simpleName} stays uncertain despite requested cancellation and successful close") {
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val fixture = Fixture({ entered.countDown(); awaitIgnoringInterrupts(release); throw failure })
            try {
                fixture.start(); latch(entered); fixture.cancelled.set(true); fixture.bridge.cancel(); release.countDown(); latch(fixture.rejected)
                check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.UNCONFIRMED)
            } finally { release.countDown(); fixture.bridge.cancel() }
        }
    }
    for ((name, response) in listOf(
        "foreign-run" to closure(true).put("runId", NONCE),
        "foreign-call" to closure(true).put("callId", 2),
        "unconfirmed" to closure(true).put("closed", false),
        "text-boolean" to closure(true).put("cancelRequested", "true"),
        "extra-value" to closure(true).put("value", JSONObject()),
        "unrequested-retirement" to closure(false),
    )) verify("$name cannot attest callback retirement") {
        val fixture = Fixture({ response }); fixture.start(); latch(fixture.rejected)
        check(fixture.bridge.retire(false) == IsolatedScriptHostBridge.Retirement.UNCONFIRMED)
    }
    verify("ordinary script cannot propose deadline with outstanding calls") {
        val owner = IsolatedToolCallbackRetirement()
        check(runCatching { owner.requireResult(PtcScriptEngine.Status.DEADLINE_EXCEEDED, 1, false) }.isFailure)
        owner.markUncertain(); owner.requestStop(); owner.recordFailure(InterruptedException(), true)
        check(!owner.confirmed(true, true))
    }
    verify("callback closure never replaces guest Binder death or unbinding") {
        for ((dead, cleaned) in listOf(false to true, true to false)) {
            check(IsolatedScriptRetirement.classify(true, true, dead, cleaned, true, false, null) ==
                IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED)
        }
    }
    println("Isolated tool callback checks: $checks")
}
