package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.os.Bundle
import android.os.Looper
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Two-phase, opt-in device probe. The host runner kills the first phase's real process. */
class NativeWorkflowProcessDeathInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        this.arguments = checkNotNull(arguments)
        start()
    }

    override fun onStart() {
        val report = Bundle()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent")
            check(Looper.myLooper() != Looper.getMainLooper())
            val runId = checkNotNull(arguments.getString("runId"))
            IsolatedScriptWire.requireUuid(runId)
            when (arguments.getString("phase")) {
                "prepare" -> prepare(app, runId)
                "recover" -> {
                    check(arguments.getString("processStopConfirmed") == "true") {
                        "The host runner did not confirm that the old Agent and guest PIDs stopped"
                    }
                    recover(app, runId, report)
                    finish(-1, report)
                }
                else -> error("Unknown process-death acceptance phase")
            }
        } catch (failure: Throwable) {
            report.putString("failed", "${failure.javaClass.simpleName}: ${failure.message}")
            finish(0, report)
        }
    }

    private fun marker(app: android.content.Context, runId: String): File =
        File(File(app.filesDir, "workflow-process-death-probe"), "$runId.json")

    private fun writeReady(app: android.content.Context, runId: String, childId: String) {
        val target = marker(app, runId)
        check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs())
        check(!target.exists()) { "A process-death marker already exists for this run" }
        val temporary = File(target.parentFile, "$runId.partial")
        val bytes = JSONObject().put("schema", 1).put("runId", runId)
            .put("childId", childId).put("agentPid", Process.myPid())
            .toString().toByteArray(Charsets.UTF_8)
        FileOutputStream(temporary).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        IsolatedScriptRunController.syncDirectory(target.parentFile!!.toPath())
    }

    private fun prepare(app: android.content.Context, runId: String) {
        val owner = DurableWorkflowOwner(app.filesDir.toPath(),
            IsolatedScriptRunController::syncDirectory)
        val transport = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject {
                val action = params.getString("action")
                val value: Any = when (action) {
                    "WORKFLOW_BEGIN" -> JSONObject().put("accepted", true)
                    "WORKFLOW_START_CHILD" -> JSONObject().put("callId", 1)
                        .put("childId", params.getString("childId"))
                    "WORKFLOW_CHILD_RESULT" -> {
                        val child = owner.read(runId).children().single()
                        check(child.state() == DurableWorkflowOwner.ChildState.LAUNCHING)
                        writeReady(app, runId, child.id())
                        // The runner must kill this process before the callback may return.
                        Thread.sleep(120_000)
                        error("The host did not terminate the pending workflow")
                    }
                    else -> error("Unexpected process-death callback: $action")
                }
                return JSONObject().put("runId", runId)
                    .put("callId", params.getInt("callId")).put("value", value)
            }

            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                error("The pending workflow must be stopped by Android, not by graceful close")
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, transport)
        val program = """async (input,host) => {
            await host.callAsync({action:'WORKFLOW_BEGIN',callId:1,value:{}});
            const child=await host.callAsync({action:'WORKFLOW_START_CHILD',callId:2,
                value:{prompt:'Process-death acceptance fixture'}});
            await host.callAsync({action:'WORKFLOW_CHILD_RESULT',callId:3,
                value:{callId:child.value.callId}});
            return {value:'unexpected',stopReason:'completed',agentsStarted:1};
        }""".trimIndent()
        val request = JSONObject().put("kind", "workflow").put("runId", runId)
            .put("sessionId", UUID.randomUUID().toString())
            .put("program", program).put("inputJson", "{}")
            .put("deadlineMillis", 120_000)
        val admitted = bridge.admit(request)
        val owned = JSONObject().put("runId", runId)
            .put("token", admitted.getString("token"))
        check(bridge.bindCallbacks(owned))
        // The host observes the synced marker while execute is held in the
        // isolated guest callback, then force-stops the entire package.
        bridge.execute(owned)
        error("The process-death workflow returned before the host stopped it")
    }

    private fun recover(app: android.content.Context, runId: String, report: Bundle) {
        val persisted = JSONObject(marker(app, runId).readText())
        check(persisted.keys().asSequence().toSet() ==
            setOf("schema", "runId", "childId", "agentPid"))
        check(persisted.getInt("schema") == 1 && persisted.getString("runId") == runId)
        check(persisted.getInt("agentPid") != Process.myPid()) {
            "Recovery did not start in a different Agent process"
        }
        val childId = persisted.getString("childId")
        IsolatedScriptWire.requireUuid(childId)
        val owner = DurableWorkflowOwner(app.filesDir.toPath(),
            IsolatedScriptRunController::syncDirectory)
        val before = owner.read(runId)
        check(before.state() == DurableWorkflowOwner.State.ADMITTED)
        check(before.children().single().id() == childId &&
            before.children().single().state() == DurableWorkflowOwner.ChildState.LAUNCHING)
        val callbacks = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("A cold owner must not replay the old workflow callback")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                error("A cold owner must not silently close the old child")
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, callbacks)
        try {
            check(bridge.startupRecovery().unretiredChildren >= 1)
            val interrupted = owner.read(runId)
            check(interrupted.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED &&
                interrupted.outputJson() == null)
            check(interrupted.children().single().id() == childId &&
                interrupted.children().single().state() ==
                    DurableWorkflowOwner.ChildState.INTERRUPTED_UNCONFIRMED)
            val nextId = UUID.randomUUID().toString()
            val request = JSONObject().put("kind", "workflow").put("runId", nextId)
                .put("sessionId", UUID.randomUUID().toString())
                .put("program", "async () => ({value:null,stopReason:'completed',agentsStarted:0})")
                .put("inputJson", "{}").put("deadlineMillis", 5_000)
            check(runCatching { bridge.admit(request) }.isFailure)
            val scripts = IsolatedScriptReceipt(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory)
            check(!scripts.hasEverAdmitted(nextId))
            // This is a test-only transition, permitted only after the host
            // observed both old process IDs absent after Android force-stop.
            owner.confirmStoppedChild(runId, childId)
            val admitted = bridge.admit(request)
            val owned = JSONObject().put("runId", nextId)
                .put("token", admitted.getString("token"))
            check(bridge.cancel(owned))
            check(bridge.settle(owned).getString("state") == "CANCELLED")
            check(bridge.release(owned))
            check(owner.read(runId).state() ==
                DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
            check(owner.read(runId).outputJson() == null)
            report.putString("passed", "process-kill-interruption-no-replay-and-guarded-retirement")
            report.putString("oldRunId", runId)
            report.putString("oldChildId", childId)
            report.putInt("oldAgentPid", persisted.getInt("agentPid"))
            report.putInt("newAgentPid", Process.myPid())
        } finally { bridge.close() }
    }
}
