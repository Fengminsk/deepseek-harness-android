package com.minnnng.dsh_android

import android.content.Context
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.BooleanSupplier

/** Native RPC owner for a whole Linux guest. The model cannot name host files, images, or credentials. */
internal class LinuxVmManager(private val context: Context) : AutoCloseable {
    init {
        check(BuildConfig.LINUX_VM_ENABLED) { "Linux virtual machine is not included in this build" }
    }
    private val admission = LinuxCommandAdmission()
    private val busy = AtomicBoolean()
    private val images = LinuxVmImageStore(context)
    private val publication = Any()

    fun inspect(params: JSONObject): JSONObject {
        require(params.keys().asSequence().toSet() in setOf(setOf("sessionId"), setOf("sessionId", "id"))) {
            "Invalid Linux inspection fields"
        }
        require(params.opt("sessionId") is String && (!params.has("id") || params.opt("id") is String)) {
            "Invalid Linux inspection identity"
        }
        return images.inspect(params.getString("sessionId"), if (params.has("id")) params.getString("id") else null)
    }

    fun execute(params: JSONObject): JSONObject = executeCommand(params, null, null)

    /** Only the App approval coordinator supplies this exact admitted lease and reviewed route. */
    fun executeApprovedNetwork(params: JSONObject, lease: IsolatedExecutionPolicyOwner.Lease,
        approvedRoute: JSONObject): JSONObject = executeCommand(params, lease, approvedRoute)

    private fun executeCommand(params: JSONObject, lease: IsolatedExecutionPolicyOwner.Lease?,
        approvedRoute: JSONObject?): JSONObject {
        val fields = setOf("id", "sessionId", "command", "timeoutMs", "persistChanges")
        require(params.keys().asSequence().toSet() == fields) { "Invalid Linux VM request fields" }
        require(listOf("id", "sessionId", "command").all { params.opt(it) is String }) {
            "Invalid Linux VM request text"
        }
        val id = params.getString("id")
        val sessionId = params.getString("sessionId")
        IsolatedScriptWire.requireSessionId(sessionId)
        val command = params.getString("command")
        require(command.isNotBlank() && command.indexOf('\u0000') < 0
            && command.toByteArray(Charsets.UTF_8).size <= LinuxVmConsole.MAX_COMMAND_BYTES) {
            "Linux VM command exceeds its limit"
        }
        require(params.opt("persistChanges") is Boolean) { "Linux VM persistence policy is required" }
        val timeoutMs = timeout(params)
        if (lease == null) return run(id, sessionId, command, timeoutMs, params.getBoolean("persistChanges"))
        val network = LinuxVmNetworkHostBridge(context, id, sessionId, lease, requireNotNull(approvedRoute))
        var receipt: JSONObject? = null
        try {
            val client = context.assets.open("linux-vm-network/dsh-fetch.py").use {
                val bytes = it.readBytes()
                require(bytes.size in 1..12 * 1024) { "Linux HTTPS client is invalid" }
                java.util.Base64.getEncoder().encodeToString(bytes)
            }
            val networkCommand = "printf '%s' '$client' | base64 -d > /tmp/dsh-fetch\n" +
                "chmod 700 /tmp/dsh-fetch\nexport PATH=/tmp:\$PATH DSH_HTTPS_RUN_ID='$id' DSH_HTTPS_DEVICE=/dev/vdd\n" + command
            require(networkCommand.toByteArray(Charsets.UTF_8).size <= LinuxVmConsole.MAX_COMMAND_BYTES) {
                "Linux command plus HTTPS client exceeds its limit"
            }
            receipt = run(id, sessionId, networkCommand, timeoutMs, params.getBoolean("persistChanges"), network = network)
        } finally {
            try { network.close() }
            catch (cleanup: Exception) {
                admission.close()
                if (receipt == null) throw cleanup
                receipt.put("status", "outcome_uncertain")
                    .put("detail", "Linux HTTPS worker retirement is unconfirmed; no command may be replayed")
            }
        }
        return checkNotNull(receipt)
    }

    fun importFile(params: JSONObject): JSONObject {
        return transferFile(params, false)
    }

    fun exportFile(params: JSONObject): JSONObject {
        return transferFile(params, true)
    }

    private fun transferFile(params: JSONObject, export: Boolean): JSONObject {
        require(params.keys().asSequence().toSet() == setOf("id", "sessionId", "source", "destination", "timeoutMs")) {
            "Invalid Linux import request fields"
        }
        require(listOf("id", "sessionId", "source", "destination").all { params.opt(it) is String }) {
            "Invalid Linux import request text"
        }
        val sessionId = params.getString("sessionId")
        IsolatedScriptWire.requireSessionId(sessionId)
        return run(params.getString("id"), sessionId, "", timeout(params), !export,
            params.getString("source"), params.getString("destination"), export)
    }

    private fun timeout(params: JSONObject): Long {
        val timeout = params.opt("timeoutMs")
        require(timeout is Int || timeout is Long) { "Linux VM timeout must be an integer" }
        val timeoutMs = (timeout as Number).toLong()
        require(timeoutMs in 1000..120_000) { "Linux VM timeout exceeds its limit" }
        return timeoutMs
    }

    private fun run(id: String, sessionId: String, command: String, timeoutMs: Long,
        persistChanges: Boolean, source: String? = null, destination: String? = null, export: Boolean = false,
        network: LinuxVmNetworkHostBridge? = null): JSONObject {
        val ticket = try { admission.admit(id) }
        catch (_: LinuxCommandAdmission.CancelledBeforeAdmission) {
            return result(id, sessionId, LinuxVmRunner.Result("cancelled", cancelled = true, retirementConfirmed = true), false)
                .apply { if (export) put("filePublished", false) }
        }
        var retired = true
        var ownsCapacity = false
        var executed: LinuxVmRunner.Result? = null
        var input: LinuxVmFileInput? = null
        var output: LinuxVmFileOutput? = null
        var exportPublished: Boolean? = false
        var openingImages = false
        fun cancelled() = ticket.isCancelled || (network != null && !network.authorized())
        try {
            ownsCapacity = busy.compareAndSet(false, true)
            check(ownsCapacity) { "Linux VM is already executing a command" }
            if (cancelled()) return result(id, sessionId, LinuxVmRunner.Result("cancelled",
                cancelled = true, retirementConfirmed = true), false).apply { if (export) put("filePublished", false) }
            if (source != null) {
                if (export) output = LinuxVmFileOutput(context, source, requireNotNull(destination))
                else input = LinuxVmFileInput.open(context, source, requireNotNull(destination),
                    BooleanSupplier { ticket.isCancelled })
            }
            openingImages = true
            return images.open(sessionId, id, if (export) "export" else if (source != null) "import" else "execute").use { lease ->
                retired = false
                val execution = LinuxVmRunner.run(context, id, input?.command() ?: output?.command() ?: command,
                    timeoutMs, lease, BooleanSupplier { cancelled() }, input?.memory ?: output?.input, output?.memory,
                    network = network)
                executed = execution
                retired = execution.retirementConfirmed
                if (retired) lease.markRetired(execution.status, execution.exitCode)
                // Quiesce the App network worker before publishing disks or releasing capacity.
                network?.close()
                val commit = persistChanges && retired && execution.status == "completed" && !cancelled()
                    && (input == null || execution.exitCode == 0)
                // An aborted waiter cannot commit a disk even if shutdown won
                // the race in the isolated process.
                val committed = lease.finish(execution.status, commit, BooleanSupplier { cancelled() }) { publish ->
                    synchronized(publication) {
                        if (cancelled()) false else { publish(); true }
                    }
                }
                var settled = if (!retired) execution.copy(status = "outcome_uncertain",
                    detail = "Linux worker retirement is unconfirmed; inspect this run before continuing")
                else if (!committed && cancelled())
                    execution.copy(status = "cancelled", cancelled = true) else execution
                val exportFields = JSONObject().put("filePublished", false)
                output?.let { snapshot ->
                    exportFields.put("source", snapshot.source).put("destination", snapshot.destination)
                    if (settled.status == "completed" && settled.exitCode == 0 && retired) {
                        try {
                            snapshot.stage(settled.output, BooleanSupplier { ticket.isCancelled }).use { staged ->
                                exportFields.put("bytes", staged.bytes).put("sha256", staged.sha256)
                                lease.prepareExport()
                                exportFields.put("filePublished", JSONObject.NULL)
                                images.recordExport(sessionId, id, "prepared", exportFields)
                                val published = synchronized(publication) {
                                    if (ticket.isCancelled) null else {
                                        // From this point a thrown native call has an unknown publication outcome.
                                        exportPublished = null
                                        LinuxVmFilePublisher.publish(context, staged.file, snapshot.destination)
                                    }
                                }
                                if (published == null) {
                                    exportPublished = false
                                    exportFields.put("filePublished", false)
                                    settled = settled.copy(status = "cancelled", cancelled = true)
                                } else {
                                    exportPublished = published.published
                                    exportFields.put("filePublished", published.published ?: JSONObject.NULL)
                                    if (published.published != false && !published.directorySynced) {
                                        admission.close()
                                        settled = settled.copy(status = "outcome_uncertain",
                                            detail = "Linux file was exported but directory durability was not confirmed")
                                    } else if (published.published == false) {
                                        settled = settled.copy(status = "failed",
                                            detail = "Linux export could not create the destination (errno ${published.errno})")
                                    }
                                }
                                images.recordExport(sessionId, id, settled.status, exportFields)
                            }
                        } catch (failure: java.util.concurrent.CancellationException) {
                            if (!ticket.isCancelled) throw failure
                            settled = settled.copy(status = "cancelled", cancelled = true)
                        }
                    }
                }
                if (export && retired) {
                    exportFields.put("filePublished", exportPublished ?: JSONObject.NULL)
                    lease.settleExport(settled.status, exportPublished)
                }
                result(id, sessionId, settled, if (retired) committed else null).apply {
                    input?.let { snapshot ->
                        put("source", source); put("destination", destination)
                        put("bytes", snapshot.bytes); put("sha256", snapshot.sha256)
                    }
                    if (export) exportFields.keys().asSequence().forEach { put(it, exportFields.get(it)) }
                }
            }
        } catch (failure: Exception) {
            val execution = executed
            if (openingImages) {
                // Local variables cannot establish whether dispatch or a rename crossed its durable boundary.
                // Inspect after use{} released the lease; never overwrite an uncertain journal during cleanup.
                val inspection = images.inspect(sessionId, id)
                val record = inspection.getJSONArray("records").optJSONObject(0)
                val knownRetired = record?.opt("retirementConfirmed") as? Boolean
                val knownDisk = record?.opt("diskCommitted") as? Boolean
                val knownFile = record?.opt("filePublished") as? Boolean
                retired = knownRetired == true
                admission.close()
                return result(id, sessionId, (execution ?: LinuxVmRunner.Result("outcome_uncertain"))
                    .copy(status = "outcome_uncertain", retirementConfirmed = retired,
                        detail = "Linux recovery requires inspection; no command is replayed and this owner is closed"), knownDisk)
                    .apply { if (export) put("filePublished", knownFile ?: JSONObject.NULL) }
            }
            if (execution == null && cancelled()) {
                return result(id, sessionId, LinuxVmRunner.Result("cancelled", cancelled = true,
                    retirementConfirmed = retired), false).apply { if (export) put("filePublished", false) }
            }
            if (execution != null) {
                admission.close()
                return result(id, sessionId, execution.copy(status = "outcome_uncertain",
                    detail = "Linux publication could not be confirmed; this execution owner is closed"), if (export) false else null)
                    .apply { if (export) put("filePublished", exportPublished ?: JSONObject.NULL) }
            }
            throw failure
        } finally {
            try { input?.close() }
            finally {
                try { output?.close() }
                finally {
                    if (ownsCapacity) busy.set(false)
                    ticket.close(retired)
                }
            }
        }
    }

    private fun result(id: String, sessionId: String, run: LinuxVmRunner.Result, committed: Boolean?) =
        JSONObject().put("id", id).put("sessionId", sessionId).put("status", run.status)
            .put("output", run.output).put("exitCode", run.exitCode ?: JSONObject.NULL)
            .put("guestUid", run.guestUid ?: JSONObject.NULL).put("timedOut", run.timedOut)
            .put("cancelled", run.cancelled).put("truncated", run.truncated)
            .put("diskCommitted", committed ?: JSONObject.NULL).put("retirementConfirmed", run.retirementConfirmed)
            .put("detail", run.detail ?: JSONObject.NULL)

    fun cancel(params: JSONObject): JSONObject {
        require(params.length() == 1 && params.opt("id") is String) { "Invalid Linux VM cancellation" }
        synchronized(publication) { admission.cancel(params.getString("id")) }
        val cancelled = admission.cancelAndWait(params.getString("id"), 5_000)
        return JSONObject().put("cancelRequested", cancelled.requested()).put("settled", cancelled.settled())
    }

    override fun close() { synchronized(publication) { admission.close() } }
}
