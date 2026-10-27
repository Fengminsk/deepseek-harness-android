package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.function.BooleanSupplier

/** Device-only probes with dedicated sessions. An interrupted probe is retained, never acknowledged. */
internal object LinuxVmLifecycleAcceptance {
    fun run(instrumentation: Instrumentation, phase: String, arguments: Bundle) {
        val report = Bundle()
        try {
            val token = checkNotNull(arguments.getString("token"))
            require(UUID.fromString(token).toString() == token)
            check(Application.getProcessName() == instrumentation.targetContext.packageName + ":agent")
            val hidden = AtomicBoolean()
            val activeProbe = AtomicReference<Probe?>()
            AcceptanceCarrierLease.open(instrumentation, arguments, report, 180_000) {
                hidden.set(true)
                activeProbe.get()?.cancelHiddenRun()
            }.use { foreground ->
                val probe = Probe(instrumentation, token, hidden, report) { foreground.checkActive() }
                activeProbe.set(probe)
                val result = when (phase) {
                    "cancel" -> probe.cancel()
                    "death-prepare" -> probe.prepareDeath()
                    "death-recover" -> probe.recoverDeath()
                    "upgrade-seed" -> probe.seedUpgrade()
                    "upgrade-verify" -> probe.verifyUpgrade()
                    else -> error("Unknown Linux lifecycle phase")
                }
                foreground.checkActive()
                report.putString("nativeOwnersClosed", "true")
                report.putString("lifecycle", result.put("schema", 1).put("phase", phase)
                    .put("token", token).put("sessionId", probe.session).put("pid", Process.myPid())
                    .put("appUid", Process.myUid()).put("versionCode", probe.version()).toString())
            }
            instrumentation.finish(-1, report)
        } catch (failure: Throwable) {
            report.putString("failed", describeFailure(failure))
            instrumentation.finish(0, report)
        }
    }

    /** Initialization/linkage failures often have no outer message; retain a bounded cause chain. */
    private fun describeFailure(failure: Throwable): String {
        val text = StringBuilder()
        var current: Throwable? = failure
        var depth = 0
        while (current != null && depth < 4) {
            if (depth > 0) text.append(" <- ")
            val type = current.javaClass.name
            val message = current.message ?: ""
            text.append(type.substring(0, minOf(type.length, 160))).append(": ")
                .append(message.substring(0, minOf(message.length, 384)))
            val next = current.cause
            if (next === current) break
            current = next
            depth++
        }
        return text.toString().take(2200)
    }

    private class Probe(private val instrumentation: Instrumentation, private val token: String,
        private val hidden: AtomicBoolean,
        private val carrierReport: Bundle,
        private val checkForeground: () -> Unit) {
        private val app = instrumentation.targetContext.applicationContext
        val session = "linux-lifecycle-$token"
        private val marker = File(app.noBackupFilesDir, "linux-lifecycle-acceptance/$token.json")
        private val guestPath = "/workspace/lifecycle-$token.txt"
        private val content = "DSH Linux lifecycle $token\n"
        private val contentHash = sha(content.toByteArray(Charsets.UTF_8))
        private val cancellationLock = Any()
        private var activeCancellation: (() -> Unit)? = null
        private var cancellationTask: CompletableFuture<Unit>? = null

        /** The broadcast runs on the UI thread; native cancellation and its retirement wait must not. */
        fun cancelHiddenRun() {
            synchronized(cancellationLock) {
                val cancel = activeCancellation ?: return
                if (cancellationTask != null) return
                val pending = CompletableFuture<Unit>()
                cancellationTask = pending
                try {
                    Thread({
                        try { cancel(); pending.complete(Unit) }
                        catch (failure: Throwable) { pending.completeExceptionally(failure) }
                    }, "linux-acceptance-cancel").start()
                } catch (failure: Throwable) { pending.completeExceptionally(failure) }
            }
        }

        private fun execute(owner: LinuxVmManager, params: JSONObject): JSONObject {
            checkForeground()
            synchronized(cancellationLock) {
                check(!hidden.get()) { "The acceptance carrier is no longer active" }
                check(activeCancellation == null)
                activeCancellation = { owner.cancel(JSONObject().put("id", params.getString("id"))); Unit }
            }
            try {
                checkForeground()
                val result = owner.execute(params)
                checkForeground()
                return result
            } finally {
                val pending = synchronized(cancellationLock) {
                    activeCancellation = null
                    cancellationTask
                }
                // The actual execute call above owns native retirement; a cancelled Future is not evidence.
                pending?.get(10, TimeUnit.SECONDS)
            }
        }

        fun version(): Long = app.packageManager.getPackageInfo(app.packageName, 0).longVersionCode
        private fun request(id: String, command: String, persist: Boolean = false) = JSONObject()
            .put("id", id).put("sessionId", session).put("command", command)
            .put("timeoutMs", 120_000).put("persistChanges", persist)
        private fun inspect(owner: LinuxVmManager, id: String? = null) = owner.inspect(JSONObject()
            .put("sessionId", session).apply { if (id != null) put("id", id) })
        private fun fresh() {
            check(!marker.exists()) { "This acceptance token was already used; preserve it and choose a new token" }
            LinuxVmManager(app).use { check(inspect(it).getString("status") == "absent") }
        }
        private fun completed(result: JSONObject, committed: Boolean) {
            check(result.getString("status") == "completed" && result.getInt("exitCode") == 0) { result.toString() }
            check(result.getBoolean("retirementConfirmed") && result.getBoolean("diskCommitted") == committed)
            check(result.getInt("guestUid") != Process.myUid())
        }
        private fun writeMarker(value: JSONObject) {
            check(marker.parentFile!!.isDirectory || marker.parentFile!!.mkdirs())
            check(Files.isDirectory(marker.parentFile!!.toPath(), LinkOption.NOFOLLOW_LINKS))
            check(!marker.exists())
            val temporary = File(marker.parentFile, "$token.partial")
            check(temporary.createNewFile())
            FileOutputStream(temporary).use { output ->
                output.write(value.put("schema", 1).put("token", token).put("sessionId", session)
                    .put("pid", Process.myPid()).put("versionCode", version()).toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            Files.move(temporary.toPath(), marker.toPath(), StandardCopyOption.ATOMIC_MOVE)
            IsolatedScriptRunController.syncDirectory(marker.parentFile!!.toPath())
            IsolatedScriptRunController.syncDirectory(app.noBackupFilesDir.toPath())
        }
        private fun readMarker(kind: String): JSONObject {
            check(Files.isRegularFile(marker.toPath(), LinkOption.NOFOLLOW_LINKS) && marker.length() in 1..16_384)
            return JSONObject(marker.readText()).also {
                check(it.getInt("schema") == 1 && it.getString("kind") == kind &&
                    it.getString("token") == token && it.getString("sessionId") == session)
                IsolatedScriptWire.requireUuid(it.getString("runId"))
            }
        }
        private fun baseImage() = JSONObject(app.assets.open("linux-vm/manifest.json")
            .bufferedReader().use { it.readText() }).getJSONObject("disk").getString("sha256")

        fun cancel(): JSONObject {
            fresh()
            val id = UUID.randomUUID().toString()
            LinuxVmManager(app).use { owner ->
                val pending = CompletableFuture.supplyAsync {
                    execute(owner, request(id, "while :; do sleep 1; done", true))
                }
                var guestPid: Int? = null
                var identityReported = false
                try {
                    val deadline = SystemClock.elapsedRealtime() + 120_000
                    stage("waiting-for-identity", id)
                    while (guestPid == null && !pending.isDone && SystemClock.elapsedRealtime() < deadline) {
                        checkForeground()
                        val observedPid = liveGuestPid(id)
                        if (observedPid != null) {
                            if (!identityReported) {
                                stage("first-identity", id, JSONObject().put("guestPid", observedPid))
                                identityReported = true
                            }
                            if (workerHasRun(observedPid, id)) guestPid = observedPid
                        }
                        if (guestPid == null) SystemClock.sleep(100)
                    }
                    stage("readiness-ended", id, JSONObject().put("guestObserved", guestPid != null)
                        .put("executionReturned", pending.isDone))
                    check(guestPid != null && !pending.isDone) { "No live isolated worker observed before cancellation" }
                    val active = inspect(owner, id)
                    check(active.getString("status") == "active" && active.getBoolean("blocked"))
                    check(active.getJSONArray("records").getJSONObject(0).getString("state") == "running")
                    stage("cancel-before", id)
                    val cancellation = owner.cancel(JSONObject().put("id", id))
                    stage("cancel-after", id, JSONObject().put("cancelRequested", cancellation.getBoolean("cancelRequested"))
                        .put("settled", cancellation.getBoolean("settled")))
                    val result = pending.get(20, TimeUnit.SECONDS)
                    stage("execution-returned", id, JSONObject().put("status", result.getString("status"))
                        .put("retirementConfirmed", result.getBoolean("retirementConfirmed")))
                    check(cancellation.getBoolean("cancelRequested") && cancellation.getBoolean("settled"))
                    check(result.getString("status") == "cancelled" && result.getBoolean("cancelled") &&
                        result.getBoolean("retirementConfirmed") && !result.getBoolean("diskCommitted"))
                    check(result.getInt("guestUid") != Process.myUid())
                    return JSONObject().put("passed", true).put("runId", id).put("liveGuestPid", guestPid)
                        .put("workerCpuObserved", true).put("activeInspection", active)
                        .put("receipt", result).put("inspection", inspect(owner, id))
                        .put("guestProcessStillListed", liveGuestPid(id) != null)
                } finally {
                    if (!pending.isDone) {
                        stage("cleanup-cancel-before", id)
                        val cancellation = owner.cancel(JSONObject().put("id", id))
                        stage("cleanup-cancel-after", id, JSONObject().put("cancelRequested", cancellation.getBoolean("cancelRequested"))
                            .put("settled", cancellation.getBoolean("settled")))
                        // Failure to retire remains a failure; do not relabel this session as clean.
                        pending.get(20, TimeUnit.SECONDS)
                        stage("cleanup-execution-returned", id)
                    }
                }
            }
        }

        private fun shell(command: String): String {
            carrierReport.putString("linuxObservationCommand", command.take(240))
            return LinuxVmObservationReader.read({
                val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
                try { ParcelFileDescriptor.AutoCloseInputStream(descriptor) }
                catch (failure: Throwable) {
                    try { descriptor.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
                    throw failure
                }
            }, 8000, 1000)
        }
        private fun liveGuestPid(id: String): Int? {
            val expected = app.packageName + ":linux_vm:" + app.packageName +
                ".IsolatedLinuxVmService:linux_vm_" + id.replace("-", "")
            val pid = try {
                LinuxVmGuestObservation.pid(shell("dumpsys -t 5 activity services ${app.packageName}"), expected)
            } catch (failure: LinuxVmGuestObservation.ObservationFailure) {
                carrierReport.putString("linuxGuestObservation", JSONObject().put("runId", id)
                    .put("expectedProcess", expected).put("records", failure.diagnostic).toString())
                throw failure
            } ?: return null
            val live = shell("ps -A -o PID").lineSequence().drop(1).map { it.trim() }.toSet()
            return pid.takeIf { it.toString() in live }
        }
        private fun workerHasRun(pid: Int, id: String): Boolean {
            val worker = LinuxVmGuestObservation.workerCpu(shell("ps -T -p $pid -o TID,CMD,TIME")) ?: return false
            stage("worker-cpu", id, JSONObject().put("guestPid", pid).put("tid", worker.tid)
                .put("command", worker.command).put("cpuTime", worker.time).put("cpuSeconds", worker.seconds))
            return true
        }

        private fun stage(name: String, id: String, details: JSONObject = JSONObject()) {
            instrumentation.sendStatus(1, Bundle().apply {
                putString("linuxCancelStage", details.put("stage", name).put("runId", id)
                    .put("elapsedRealtimeMs", SystemClock.elapsedRealtime()).toString())
            })
        }

        fun prepareDeath(): Nothing {
            fresh()
            val source = "linux-lifecycle-acceptance/$token.txt"
            val sourceFile = File(app.noBackupFilesDir, "dsh/workspace/$source")
            check(sourceFile.parentFile!!.isDirectory || sourceFile.parentFile!!.mkdirs())
            check(Files.isDirectory(sourceFile.parentFile!!.toPath(), LinkOption.NOFOLLOW_LINKS))
            check(sourceFile.parentFile!!.canonicalFile.parentFile ==
                File(app.noBackupFilesDir, "dsh/workspace").canonicalFile)
            check(sourceFile.createNewFile())
            FileOutputStream(sourceFile).use { it.write(content.toByteArray(Charsets.UTF_8)); it.fd.sync() }
            IsolatedScriptRunController.syncDirectory(sourceFile.parentFile!!.toPath())
            val id = UUID.randomUUID().toString()
            LinuxVmFileInput.open(app, source, guestPath.removePrefix("/workspace/"),
                BooleanSupplier { hidden.get() }).use { input ->
                check(input.sha256 == contentHash)
                LinuxVmImageStore(app).open(session, id, "import").use { lease ->
                    val result = LinuxVmRunner.run(app, id, input.command(), 120_000, lease,
                        BooleanSupplier { hidden.get() }, input.memory)
                    if (result.retirementConfirmed) lease.markRetired(result.status, result.exitCode)
                    if (result.retirementConfirmed &&
                        (result.status != "completed" || result.exitCode != 0 || hidden.get())) {
                        lease.finish(if (hidden.get()) "cancelled" else result.status, false)
                    }
                    check(result.status == "completed" && result.exitCode == 0 && result.retirementConfirmed)
                    check(result.guestUid != null && result.guestUid != Process.myUid())
                    check(result.output.trim().split(Regex("\\s+"))[0] == contentHash)
                    // Match Manager.run ordering: real native return and retired journal precede publication.
                    checkForeground()
                    val ready = JSONObject().put("kind", "import-retired-before-publication")
                        .put("runId", id).put("source", source).put("sha256", contentHash)
                        .put("appUid", Process.myUid())
                        .put("guestUid", result.guestUid).put("retirementConfirmed", true).put("diskCommitted", false)
                    writeMarker(ready)
                    checkForeground()
                    instrumentation.sendStatus(1, Bundle(carrierReport).apply {
                        putString("linuxDeathReady", ready.toString())
                    })
                    // Actual Android process death, before lease.finish captures or publishes disk blocks.
                    Process.killProcess(Process.myPid())
                    error("Android process termination returned")
                }
            }
        }

        fun recoverDeath(): JSONObject {
            val before = readMarker("import-retired-before-publication")
            check(before.getInt("pid") != Process.myPid()) { "Recovery requires a different Android process" }
            val source = File(app.noBackupFilesDir, "dsh/workspace/linux-lifecycle-acceptance/$token.txt")
            check(before.getString("source") == "linux-lifecycle-acceptance/$token.txt")
            check(Files.isRegularFile(source.toPath(), LinkOption.NOFOLLOW_LINKS) &&
                source.length() == content.toByteArray(Charsets.UTF_8).size.toLong())
            check(sha(source.readBytes()) == contentHash && before.getString("sha256") == contentHash)
            val journals = File(app.noBackupFilesDir, "linux-vm/${sha(session.toByteArray(Charsets.UTF_8))}/runs-v2")
            fun journalHashes() = checkNotNull(journals.listFiles()).sortedBy { it.name }
                .associate {
                    check(Files.isRegularFile(it.toPath(), LinkOption.NOFOLLOW_LINKS) && it.length() in 1..4096)
                    it.name to sha(it.readBytes())
                }
            val original = journalHashes()
            check(original.keys == setOf(before.getString("runId") + ".bin"))
            LinuxVmManager(app).use { owner ->
                val recovered = inspect(owner, before.getString("runId"))
                check(recovered.getString("status") == "ready" && recovered.getBoolean("needsReview") &&
                    !recovered.getBoolean("blocked") && !recovered.getBoolean("automaticReplay"))
                val record = recovered.getJSONArray("records").getJSONObject(0)
                check(record.getString("state") == "interrupted" && record.getString("operation") == "import" &&
                    record.getBoolean("retirementConfirmed") && !record.getBoolean("diskCommitted"))
                val refused = execute(owner, request(UUID.randomUUID().toString(), "printf unexpected-replay", true))
                check(refused.getString("status") == "outcome_uncertain" && refused.isNull("guestUid"))
                check(journalHashes() == original) { "Recovery admitted a successor or changed the old journal" }
                check(inspect(owner, before.getString("runId")).toString() == recovered.toString())
                return JSONObject().put("passed", true).put("oldPid", before.getInt("pid"))
                    .put("runId", before.getString("runId")).put("sha256", contentHash)
                    .put("window", before.getString("kind")).put("inspection", recovered)
                    .put("successor", refused).put("journalUnchanged", true)
            }
        }

        fun seedUpgrade(): JSONObject {
            fresh()
            val id = UUID.randomUUID().toString()
            LinuxVmManager(app).use { owner ->
                val result = execute(owner, request(id, "printf 'DSH Linux lifecycle $token\\n' > '$guestPath'; sha256sum '$guestPath'", true))
                completed(result, true)
                check(result.getString("output").trim().split(Regex("\\s+"))[0] == contentHash)
                writeMarker(JSONObject().put("kind", "upgrade-workspace").put("runId", id)
                    .put("sha256", contentHash).put("baseImage", baseImage()))
                return JSONObject().put("passed", true).put("runId", id).put("sha256", contentHash)
                    .put("baseImage", baseImage()).put("receipt", result)
            }
        }

        fun verifyUpgrade(): JSONObject {
            val before = readMarker("upgrade-workspace")
            check(version() > before.getLong("versionCode")) { "An ordinary upgrade must increase versionCode" }
            check(before.getString("sha256") == contentHash)
            LinuxVmManager(app).use { owner ->
                val existing = inspect(owner, before.getString("runId"))
                check(!existing.getBoolean("blocked") && !existing.getBoolean("needsReview"))
                val original = existing.getJSONArray("records").getJSONObject(0)
                check(original.getBoolean("diskCommitted") && original.getBoolean("retirementConfirmed"))
                val result = execute(owner, request(UUID.randomUUID().toString(), "sha256sum '$guestPath'; cat '$guestPath'"))
                completed(result, false)
                check(result.getString("output").trim().split(Regex("\\s+"))[0] == contentHash)
                check(result.getString("output").endsWith(content))
                return JSONObject().put("passed", true).put("runId", before.getString("runId"))
                    .put("sha256", contentHash).put("beforeVersionCode", before.getLong("versionCode"))
                    .put("beforeBaseImage", before.getString("baseImage")).put("baseImage", baseImage())
                    .put("receipt", result).put("inspection", existing)
            }
        }
    }

    private fun sha(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
}
