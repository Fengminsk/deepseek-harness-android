package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.os.Bundle
import android.os.Looper
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Device proof of the private workflow route, including the real isolated Binder guest. */
class NativeWorkflowAcceptanceInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val passed = mutableListOf<String>()
        val failed = mutableListOf<String>()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent")
            check(Looper.myLooper() != Looper.getMainLooper())
            fun test(name: String, block: () -> Unit) {
                try { block(); passed += name }
                catch (failure: Throwable) {
                    failed += "$name: ${failure.javaClass.simpleName}: ${failure.message}"
                }
            }
            test("isolated-callbacks-and-durable-result") { completedWorkflow(app) }
            test("isolated-guest-reported-error-is-durable-failure") { reportedFailureWorkflow(app) }
            test("isolated-malformed-dsl-outcome-needs-review") { malformedOutcomeWorkflow(app) }
            test("isolated-child-reservation-result-and-retirement") { childWorkflow(app) }
            test("admitted-workflow-pre-execution-cancel") { cancelledWorkflow(app) }
            test("bounded-extended-workflow-and-upper-limit") { extendedWorkflow(app) }
            test("in-flight-child-cancel-retirement-and-cold-owner") {
                inFlightChildCancellation(app)
            }
        } catch (failure: Throwable) {
            failed += "setup: ${failure.javaClass.simpleName}: ${failure.message}"
        }
        report.putString("passed", passed.joinToString(","))
        report.putString("failed", failed.joinToString(" | "))
        report.putInt("passedCount", passed.size)
        report.putInt("failedCount", failed.size)
        finish(if (failed.isEmpty()) -1 else 0, report)
    }

    private fun request(runId: String, program: String) = JSONObject()
        .put("kind", "workflow").put("runId", runId)
        .put("sessionId", UUID.randomUUID().toString())
        .put("program", program).put("inputJson", "{}")
        .put("deadlineMillis", 5_000)

    private fun owned(runId: String, admitted: JSONObject) = JSONObject()
        .put("runId", runId).put("token", admitted.getString("token"))

    private fun completedWorkflow(app: android.content.Context) {
        val actions = java.util.Collections.synchronizedList(mutableListOf<String>())
        val closes = AtomicInteger()
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(timeoutMillis > 0)
                check(params.keys().asSequence().toSet() ==
                    setOf("runId", "token", "callId", "action", "value"))
                val action = params.getString("action")
                val callId = params.getInt("callId")
                check((callId == 1 && action == "WORKFLOW_BEGIN") ||
                    (callId == 2 && action == "WORKFLOW_PROGRESS"))
                actions.add(action)
                return JSONObject().put("runId", params.getString("runId"))
                    .put("callId", callId).put("value", JSONObject().put("accepted", true))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(timeoutMillis > 0 && runId.isNotBlank() && token.isNotBlank())
                closes.incrementAndGet()
                return true
            }
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val program = """async (input,host) => {
            const first=await host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}});
            const second=await host.callAsync({action:'WORKFLOW_PROGRESS',callId:2,
                value:[{type:'phase',title:'accepted'}]});
            return {value:{begin:first.value.accepted,progress:second.value.accepted},
                stopReason:'completed',agentsStarted:0};
        }""".trimIndent()
        val token = owned(runId, bridge.admit(request(runId, program)))
        try {
            check(bridge.bindCallbacks(token))
            check(runCatching { bridge.bindCallbacks(token) }.isFailure)
            check(bridge.execute(token))
            val settled = bridge.settle(token)
            check(settled.getString("state") == "COMPLETED") { settled.toString() }
            val output = JSONObject(settled.getString("outputJson"))
            check(output.getJSONObject("value").getBoolean("begin") &&
                output.getJSONObject("value").getBoolean("progress"))
            check(actions == listOf("WORKFLOW_BEGIN", "WORKFLOW_PROGRESS"))
            check(closes.get() == 1)
            val durable = DurableWorkflowOwner(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory).read(runId)
            check(durable.state() == DurableWorkflowOwner.State.COMPLETED)
            check(bridge.release(token))
        } finally { bridge.close() }
    }

    private fun extendedWorkflow(app: android.content.Context) {
        val callbacks = AtomicInteger()
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(params.getString("action") == "WORKFLOW_BEGIN")
                check(timeoutMillis > 0)
                Thread.sleep(5_500)
                callbacks.incrementAndGet()
                return JSONObject().put("runId", params.getString("runId"))
                    .put("callId", params.getInt("callId"))
                    .put("value", JSONObject().put("accepted", true))
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = true
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val program = """async (input,host) => {
            const result=await host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}});
            return {value:result.value.accepted,stopReason:'completed',agentsStarted:0};
        }""".trimIndent()
        try {
            check(runCatching {
                bridge.admit(request(UUID.randomUUID().toString(), program)
                    .put("deadlineMillis", PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS + 1))
            }.isFailure)
            val token = owned(runId, bridge.admit(request(runId, program)
                .put("deadlineMillis", 30_000)))
            check(bridge.bindCallbacks(token))
            check(bridge.execute(token))
            val settled = bridge.settle(token)
            check(settled.getString("state") == "COMPLETED") { settled.toString() }
            check(JSONObject(settled.getString("outputJson")).getBoolean("value"))
            check(callbacks.get() == 1)
            check(bridge.release(token))
        } finally { bridge.close() }
    }

    private fun cancelledWorkflow(app: android.content.Context) {
        val callbacks = AtomicInteger()
        val closes = AtomicInteger()
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                callbacks.incrementAndGet()
                error("Cancelled workflow reached the guest callback")
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                closes.incrementAndGet()
                return true
            }
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val token = owned(runId, bridge.admit(request(runId,
            "async (input,host)=>host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}})")))
        try {
            check(bridge.bindCallbacks(token))
            check(bridge.cancel(token))
            check(bridge.settle(token).getString("state") == "CANCELLED")
            check(callbacks.get() == 0 && closes.get() == 1)
            check(bridge.release(token))
        } finally { bridge.close() }
    }

    private fun reportedFailureWorkflow(app: android.content.Context) {
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("A callback-free reported failure must not call the host")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = true
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val token = owned(runId, bridge.admit(request(runId,
            "async () => ({value:null,stopReason:'error',error:{name:'Error',code:'SCRIPT_ERROR',message:'invalid workflow'},agentsStarted:0})")))
        try {
            check(bridge.bindCallbacks(token))
            check(bridge.execute(token))
            val settled = bridge.settle(token)
            check(settled.getString("state") == "FAILED") { settled.toString() }
            check(settled.isNull("outputJson"))
            val durable = DurableWorkflowOwner(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory).read(runId)
            check(durable.state() == DurableWorkflowOwner.State.FAILED && durable.outputJson() == null)
            check(bridge.release(token))
        } finally { bridge.close() }
    }

    private fun malformedOutcomeWorkflow(app: android.content.Context) {
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("A callback-free malformed outcome must not call the host")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean = true
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val runId = UUID.randomUUID().toString()
        val token = owned(runId, bridge.admit(request(runId,
            "async () => ({value:'misleading',agentsStarted:0})")))
        try {
            check(bridge.bindCallbacks(token))
            check(bridge.execute(token))
            val settled = bridge.settle(token)
            check(settled.getString("state") == "INTERRUPTED_UNCONFIRMED") { settled.toString() }
            check(settled.getBoolean("requiresReview") && settled.isNull("outputJson"))
            val durable = DurableWorkflowOwner(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory).read(runId)
            check(durable.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED
                && durable.outputJson() == null)
            check(runCatching { bridge.release(token) }.isFailure)
        } finally { bridge.close() }
    }

    private fun childWorkflow(app: android.content.Context) {
        val seen = mutableListOf<String>()
        val runId = UUID.randomUUID().toString()
        var reserved = ""
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(timeoutMillis > 0)
                val action = params.getString("action")
                val callId = params.getInt("callId")
                seen += action
                val value: Any = when (action) {
                    "WORKFLOW_BEGIN" -> JSONObject().put("accepted", true)
                    "WORKFLOW_START_CHILD" -> {
                        check(params.keys().asSequence().toSet() ==
                            setOf("runId", "token", "callId", "action", "value", "childId"))
                        reserved = params.getString("childId")
                        val child = DurableWorkflowOwner(app.filesDir.toPath(),
                            IsolatedScriptRunController::syncDirectory).read(runId).children().single()
                        check(child.id() == reserved &&
                            child.state() == DurableWorkflowOwner.ChildState.LAUNCHING)
                        JSONObject().put("callId", 1).put("childId", reserved)
                    }
                    "WORKFLOW_CHILD_RESULT" -> {
                        check(params.getJSONObject("value").getInt("callId") == 1)
                        JSONObject().put("output", org.json.JSONArray().put(JSONObject()
                            .put("type", "text").put("text", "child result")))
                            .put("stopReason", "completed")
                    }
                    "WORKFLOW_DISPOSE_CHILD" -> JSONObject.NULL
                    else -> error("Unexpected child workflow action: $action")
                }
                return JSONObject().put("runId", runId).put("callId", callId).put("value", value)
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(timeoutMillis > 0 && reserved.isNotBlank())
                return true
            }
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val program = """async (input,host) => {
            await host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}});
            const child=await host.callAsync({action:'WORKFLOW_START_CHILD',callId:2,
                value:{prompt:'Inspect only'}});
            const result=await host.callAsync({action:'WORKFLOW_CHILD_RESULT',callId:3,
                value:{callId:child.value.callId}});
            await host.callAsync({action:'WORKFLOW_DISPOSE_CHILD',callId:4,
                value:{callId:child.value.callId}});
            return {value:{childId:child.value.childId,text:result.value.output[0].text},
                stopReason:'completed',agentsStarted:1};
        }""".trimIndent()
        val token = owned(runId, bridge.admit(request(runId, program)))
        try {
            check(bridge.bindCallbacks(token))
            check(bridge.execute(token))
            val settled = bridge.settle(token)
            check(settled.getString("state") == "COMPLETED") { settled.toString() }
            val output = JSONObject(settled.getString("outputJson"))
            check(output.getJSONObject("value").getString("childId") == reserved &&
                output.getJSONObject("value").getString("text") == "child result")
            check(seen == listOf("WORKFLOW_BEGIN", "WORKFLOW_START_CHILD",
                "WORKFLOW_CHILD_RESULT", "WORKFLOW_DISPOSE_CHILD"))
            val child = DurableWorkflowOwner(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory).read(runId).children().single()
            check(child.id() == reserved && child.state() == DurableWorkflowOwner.ChildState.RETIRED)
            check(bridge.release(token))
        } finally { bridge.close() }
    }

    /** A live child result must not turn cancellation into success or replay on owner recovery. */
    private fun inFlightChildCancellation(app: android.content.Context) {
        val runId = UUID.randomUUID().toString()
        val expectedRunId = runId
        val enteredResult = CountDownLatch(1)
        val releaseResult = CountDownLatch(1)
        val childId = AtomicReference<String>()
        val resultCalls = AtomicInteger()
        val closes = AtomicInteger()
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                check(timeoutMillis > 0 && params.getString("runId") == runId)
                val value: Any = when (params.getString("action")) {
                    "WORKFLOW_BEGIN" -> JSONObject().put("accepted", true)
                    "WORKFLOW_START_CHILD" -> {
                        val reserved = params.getString("childId")
                        check(childId.compareAndSet(null, reserved))
                        JSONObject().put("callId", 1).put("childId", reserved)
                    }
                    "WORKFLOW_CHILD_RESULT" -> {
                        resultCalls.incrementAndGet()
                        enteredResult.countDown()
                        // Cancellation interrupts this App callback worker. Even if it races
                        // with release, the old child result may never publish a success.
                        releaseResult.await(20, TimeUnit.SECONDS)
                        JSONObject().put("output", org.json.JSONArray().put(JSONObject()
                            .put("type", "text").put("text", "late child output")))
                            .put("stopReason", "completed")
                    }
                    else -> error("Unexpected in-flight workflow action")
                }
                return JSONObject().put("runId", runId).put("callId", params.getInt("callId"))
                    .put("value", value)
            }
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                check(runId == expectedRunId && token.isNotBlank() && timeoutMillis > 0)
                closes.incrementAndGet()
                return true
            }
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val program = """async (input,host) => {
            await host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}});
            const child=await host.callAsync({action:'WORKFLOW_START_CHILD',callId:2,
                value:{prompt:'Inspect only'}});
            const result=await host.callAsync({action:'WORKFLOW_CHILD_RESULT',callId:3,
                value:{callId:child.value.callId}});
            return {value:result.value,stopReason:'completed',agentsStarted:1};
        }""".trimIndent()
        val token = owned(runId, bridge.admit(request(runId, program)
            .put("deadlineMillis", 30_000)))
        val workers = Executors.newFixedThreadPool(2)
        try {
            check(bridge.bindCallbacks(token))
            val execution = workers.submit<Boolean> { bridge.execute(token) }
            check(enteredResult.await(12, TimeUnit.SECONDS)) { "Child result never entered App callback" }
            val cancellation = workers.submit<Boolean> { bridge.cancel(token) }
            val durable = DurableWorkflowOwner(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory)
            val cancelDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            while (durable.read(runId).state() == DurableWorkflowOwner.State.ADMITTED &&
                System.nanoTime() < cancelDeadline) Thread.sleep(20)
            check(durable.read(runId).state() != DurableWorkflowOwner.State.ADMITTED) {
                "Cancellation did not reach the durable owner before child result release"
            }
            releaseResult.countDown()
            check(cancellation.get(12, TimeUnit.SECONDS))
            val executionOutcome = runCatching { execution.get(12, TimeUnit.SECONDS) }
            val settled = bridge.settle(token)
            val state = settled.getString("state")
            check(state == "CANCELLED" || state == "INTERRUPTED_UNCONFIRMED") {
                settled.toString()
            }
            check(settled.isNull("outputJson") && resultCalls.get() == 1 && closes.get() == 1)
            check(executionOutcome.isSuccess || state == "INTERRUPTED_UNCONFIRMED")
            val child = durable.read(runId).children().single()
            check(child.id() == childId.get() &&
                child.state() == DurableWorkflowOwner.ChildState.RETIRED)
            if (state == "CANCELLED") check(bridge.release(token))
            else check(runCatching { bridge.release(token) }.isFailure)
            val observedCalls = resultCalls.get()
            // Reconstructing the App owner reads the old receipt; it must not
            // restart the script or the retired child after a cold owner start.
            IsolatedWorkflowRunNativeBridge(app, transport).close()
            check(resultCalls.get() == observedCalls && durable.read(runId).state().name == state)
            reservedChildStopAfterCancellation(app)
        } finally {
            releaseResult.countDown()
            workers.shutdownNow()
            bridge.close()
        }
    }

    /** A reserved child has not launched; a joined Node close can retire it after cancellation. */
    private fun reservedChildStopAfterCancellation(app: android.content.Context) {
        val owner = DurableWorkflowOwner(app.filesDir.toPath(),
            IsolatedScriptRunController::syncDirectory)
        owner.recoverInterrupted()
        val runId = UUID.randomUUID().toString()
        // Construct and validate the wire request before writing a durable
        // workflow or child reservation. A malformed fixture must not strand
        // a child in the real App-owned receipt store across test reruns.
        val wire = IsolatedScriptWire.Request(runId, UUID.randomUUID().toString(),
            "async () => null", "{}", 5_000)
        owner.admit(runId)
        val childId = owner.reserveChild(runId)
        val scripts = IsolatedScriptReceipt(app.filesDir.toPath(),
            IsolatedScriptRunController::syncDirectory)
        scripts.admit(runId)
        val closed = AtomicInteger()
        val token = UUID.randomUUID().toString()
        val callback = IsolatedWorkflowCallbackBridge(
            wire,
            token, owner, java.util.function.BooleanSupplier { false },
            object : IsolatedWorkflowCallbackBridge.Transport {
                override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                    error("No guest callback was admitted for the reserved child")
                override fun close(runId: String, token: String, timeoutMillis: Long): Boolean {
                    check(runId.isNotBlank() && token.isNotBlank() && timeoutMillis > 0)
                    closed.incrementAndGet()
                    return true
                }
            },
        )
        check(owner.requestCancel(runId) == listOf(childId))
        check(callback.retire(false) == IsolatedScriptHostBridge.Retirement.FAILED)
        check(closed.get() == 1 && owner.read(runId).children().single().state() ==
            DurableWorkflowOwner.ChildState.RETIRED)
        scripts.finish(IsolatedScriptReceipt.Entry(runId,
            IsolatedScriptReceipt.State.CANCELLED, null, null))
        check(owner.confirmCancelled(runId, scripts).state() == DurableWorkflowOwner.State.CANCELLED)
        val strandedRun = UUID.randomUUID().toString()
        owner.admit(strandedRun)
        val strandedChild = owner.reserveChild(strandedRun)
        owner.markLaunching(strandedRun, strandedChild)
        val cold = IsolatedWorkflowRunNativeBridge(app, object :
            IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("Cold owner replayed the cancelled child")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                error("Cold owner retained a cancelled child callback")
        })
        try {
            check(cold.startupRecovery().unretiredChildren == 1)
            check(owner.read(strandedRun).state() ==
                DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
            val nextRun = UUID.randomUUID().toString()
            val nextRequest = request(nextRun,
                "async () => ({value:null,stopReason:'completed',agentsStarted:0})")
            check(runCatching { cold.admit(nextRequest) }.isFailure)
            check(!scripts.hasEverAdmitted(nextRun))
            // This fixture never launched the stranded child. A real backend
            // must independently prove that it stopped before this transition.
            owner.confirmStoppedChild(strandedRun, strandedChild)
            val next = owned(nextRun, cold.admit(nextRequest))
            check(cold.cancel(next) && cold.settle(next).getString("state") == "CANCELLED")
            check(cold.release(next))
            check(owner.read(runId).state() == DurableWorkflowOwner.State.CANCELLED)
        } finally { cold.close() }
    }
}
