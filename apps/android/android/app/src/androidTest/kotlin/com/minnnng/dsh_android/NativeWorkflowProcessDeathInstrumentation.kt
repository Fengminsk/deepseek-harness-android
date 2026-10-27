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
            val phase = arguments.getString("phase")
            if (phase == "inspect-legacy") {
                inspectLegacy(app, report)
                finish(-1, report)
                return
            }
            val runId = checkNotNull(arguments.getString("runId"))
            IsolatedScriptWire.requireUuid(runId)
            when (phase) {
                "prepare" -> prepare(app, runId)
                "retire-legacy" -> {
                    retireLegacy(app, runId, report)
                    finish(-1, report)
                }
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

    /** Read only identities after normal startup reconciliation, never user messages or tool output. */
    private fun inspectLegacy(app: android.content.Context, report: Bundle) {
        val owner = DurableWorkflowOwner(app.filesDir.toPath(), IsolatedScriptRunController::syncDirectory)
        val lease = WorkflowProcessLease.current(app.filesDir.toPath(), IsolatedScriptRunController::syncDirectory)
        val legacy = owner.recoverInterrupted(lease).map { owner.read(it.runId()) }
            .filter { it.processLeaseId() == null && it.children().any { child ->
                child.state() != DurableWorkflowOwner.ChildState.RETIRED } }
        val entries = org.json.JSONArray()
        legacy.take(32).forEach { entry ->
            entries.put(JSONObject().put("runId", entry.runId()).put("childIds", org.json.JSONArray(
                entry.children().filter { it.state() != DurableWorkflowOwner.ChildState.RETIRED }.map { it.id() })))
        }
        report.putString("legacy", entries.toString())
        report.putInt("legacyCount", legacy.size)
        report.putInt("agentPid", Process.myPid())
    }

    /** Explicit operator migration for one pre-lease receipt; not available through production RPC. */
    private fun retireLegacy(app: android.content.Context, runId: String, report: Bundle) {
        check(arguments.getString("processStopConfirmed") == "true")
        val stopped = checkNotNull(arguments.getString("stoppedAgentPids")).split(',')
            .filter { it.isNotEmpty() }.map { it.toInt() }
        check(stopped.isNotEmpty() && stopped.all { it > 0 } && stopped.distinct() == stopped &&
            Process.myPid() !in stopped) { "Legacy retirement needs old Agent process-stop evidence" }
        val owner = DurableWorkflowOwner(app.filesDir.toPath(), IsolatedScriptRunController::syncDirectory)
        val lease = WorkflowProcessLease.current(app.filesDir.toPath(), IsolatedScriptRunController::syncDirectory)
        owner.recoverInterrupted(lease)
        val entry = owner.read(runId)
        check(entry.processLeaseId() == null &&
            entry.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED && entry.outputJson() == null)
        val children = entry.children().filter { it.state() != DurableWorkflowOwner.ChildState.RETIRED }
        check(children.isNotEmpty()) { "No legacy children need retirement" }
        val directory = File(app.filesDir, "workflow-legacy-retirement")
        check(directory.isDirectory || directory.mkdirs())
        val target = File(directory, "$runId.json")
        // Preserve the first audit even if an earlier migration stopped halfway.
        if (!target.exists()) {
            val temporary = File(directory, "$runId.partial")
            val audit = JSONObject().put("schema", 1).put("runId", runId)
                .put("childIds", org.json.JSONArray(children.map { it.id() }))
                .put("stoppedAgentPids", org.json.JSONArray(stopped))
                .put("newAgentPid", Process.myPid()).put("processLeaseId", lease.id())
                .put("confirmedBy", "explicit-host-force-stop-and-pid-observation")
                .put("timestampMillis", System.currentTimeMillis()).toString()
            FileOutputStream(temporary).use { output ->
                output.write(audit.toByteArray(Charsets.UTF_8)); output.fd.sync()
            }
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
            IsolatedScriptRunController.syncDirectory(directory.toPath())
        } else {
            val audit = JSONObject(target.readText())
            check(audit.getInt("schema") == 1 && audit.getString("runId") == runId)
            val audited = audit.getJSONArray("childIds")
            check(children.all { child -> (0 until audited.length()).any { audited.getString(it) == child.id() } })
        }
        children.forEach { owner.confirmStoppedChild(runId, it.id()) }
        val after = owner.read(runId)
        check(after.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED && after.outputJson() == null &&
            after.children().all { it.state() == DurableWorkflowOwner.ChildState.RETIRED })
        report.putString("passed", "explicit-legacy-retirement")
        report.putString("oldRunId", runId)
        report.putInt("retiredCount", children.size)
        report.putString("audit", target.relativeTo(app.filesDir).path)
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
        // Instrumentation status works with the release target. The marker is
        // already durable, and recovery still reads it from App-private storage.
        sendStatus(1, Bundle().apply { putString("ready", bytes.toString(Charsets.UTF_8)) })
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
        // The host observes the synced marker status while execute is held in the
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
        check(before.processLeaseId() != null)
        val callbacks = object : IsolatedWorkflowCallbackBridge.Transport {
            override fun call(params: JSONObject, timeoutMillis: Long): JSONObject =
                error("A cold owner must not replay the old workflow callback")
            override fun close(runId: String, token: String, timeoutMillis: Long): Boolean =
                error("A cold owner must not silently close the old child")
        }
        val bridge = IsolatedWorkflowRunNativeBridge(app, callbacks)
        try {
            check(bridge.startupRecovery().newlyInterruptedRuns >= 1)
            val interrupted = owner.read(runId)
            check(interrupted.state() == DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED &&
                interrupted.outputJson() == null)
            check(interrupted.children().single().id() == childId &&
                interrupted.children().single().state() ==
                    DurableWorkflowOwner.ChildState.RETIRED)
            check(WorkflowProcessLease.current(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory).confirmsStopped(before.processLeaseId()))
            val nextId = UUID.randomUUID().toString()
            val request = JSONObject().put("kind", "workflow").put("runId", nextId)
                .put("sessionId", UUID.randomUUID().toString())
                .put("program", "async () => ({value:null,stopReason:'completed',agentsStarted:0})")
                .put("inputJson", "{}").put("deadlineMillis", 5_000)
            val scripts = IsolatedScriptReceipt(app.filesDir.toPath(),
                IsolatedScriptRunController::syncDirectory)
            check(!scripts.hasEverAdmitted(nextId))
            // Production recovery proved the old lease free and retired its
            // in-process child. The test must not perform that transition itself.
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
