package com.minnnng.dsh_android

import android.app.Instrumentation
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.util.UUID

/** Fixed, read-only process observations for two carrier-owned admissions; never executes model text. */
internal class PtcLinuxLifecycleObservation(
    private val packageName: String,
    private val appPid: Int,
    private val shell: (String) -> String,
    private val now: () -> Long,
) {
    constructor(instrumentation: Instrumentation) : this(
        instrumentation.targetContext.packageName, Process.myPid(),
        { command -> LinuxVmObservationReader.read({
            val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
            try { ParcelFileDescriptor.AutoCloseInputStream(descriptor) }
            catch (failure: Throwable) {
                try { descriptor.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
                throw failure
            }
        }, 8000, 1000) }, { SystemClock.elapsedRealtime() },
    )

    private val observed = mutableMapOf<String, Pair<Int, Int>>()

    /** The carrier must first bind both UUIDs to its actual, same-Session native admissions. */
    @Synchronized
    fun observe(params: JSONObject): JSONObject {
        require(params.length() == 2 && params.has("ptcRunId") && params.has("linuxRunId"))
        val ptcId = canonicalUuid(params.getString("ptcRunId"))
        val linuxId = canonicalUuid(params.getString("linuxRunId"))
        require(ptcId != linuxId)
        val key = "$ptcId/$linuxId"
        check(observed.size < 4 || key in observed) { "Lifecycle observation pair limit" }
        val services = shell("dumpsys -t 5 activity services $packageName")
        val pids = livePids(shell("ps -A -o PID"))
        check(appPid in pids) { "The carrier must remain visible in the full process observation" }
        val ptcName = "$packageName:ptc_script:$packageName.IsolatedScriptService:script_${ptcId.replace("-", "")}"
        val linuxName = "$packageName:linux_vm:$packageName.IsolatedLinuxVmService:linux_vm_${linuxId.replace("-", "")}"
        val ptc = LinuxVmGuestObservation.pid(services, ptcName)?.takeIf { it in pids }
        val linux = LinuxVmGuestObservation.pid(services, linuxName)?.takeIf { it in pids }
        val worker = if (linux == null) null else
            LinuxVmGuestObservation.workerCpu(shell("ps -T -p $linux -o TID,CMD,TIME"))
        val previous = observed[key]
        if (previous != null) {
            check(ptc == null || ptc == previous.first) { "PTC process identity changed" }
            check(linux == null || linux == previous.second) { "Linux process identity changed" }
        }
        if (ptc != null && linux != null && worker != null) {
            check(ptc != linux && ptc != appPid && linux != appPid) { "Guest processes are not independent" }
            observed[key] = ptc to linux
        }
        val pair = observed[key]
        return JSONObject().put("schema", 1).put("ptcRunId", ptcId).put("linuxRunId", linuxId)
            .put("appPid", appPid).put("observedAtElapsedMs", now())
            .put("ptcPid", ptc ?: JSONObject.NULL).put("linuxPid", linux ?: JSONObject.NULL)
            .put("workerCpuSeconds", worker?.seconds ?: 0).put("observedPair", pair != null)
            .put("observedPtcPid", pair?.first ?: JSONObject.NULL)
            .put("observedLinuxPid", pair?.second ?: JSONObject.NULL)
            .put("previousPidsGone", pair != null && ptc == null && linux == null &&
                pair.first !in pids && pair.second !in pids)
    }

    private fun canonicalUuid(value: String): String {
        require(UUID.fromString(value).toString() == value)
        return value
    }

    private fun livePids(output: String): Set<Int> {
        require(output.length <= 2 * 1024 * 1024)
        val rows = output.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
        require(rows.firstOrNull() == "PID") { "Expected exact PID column" }
        val pids = rows.drop(1).map {
            val pid = it.toIntOrNull()
            require(pid != null && pid > 0 && pid.toString() == it) { "Malformed process observation" }
            pid
        }
        require(pids.toSet().size == pids.size) { "Duplicate process identity" }
        return pids.toSet()
    }
}
