package com.minnnng.dsh_android

import org.json.JSONObject

private const val PACKAGE = "com.minnnng.dsh_android"
private const val PTC = "11111111-1111-4111-8111-111111111111"
private const val LINUX = "22222222-2222-4222-8222-222222222222"
private fun params() = JSONObject().put("ptcRunId", PTC).put("linuxRunId", LINUX)
private fun service(kind: String, id: String, pid: Int): String {
    val name = if (kind == "ptc") "$PACKAGE:ptc_script:$PACKAGE.IsolatedScriptService:script_${id.replace("-", "")}" else
        "$PACKAGE:linux_vm:$PACKAGE.IsolatedLinuxVmService:linux_vm_${id.replace("-", "")}"
    return "  * ServiceRecord{abc$pid u0 $PACKAGE/.${kind}Service}\n    processName=$name\n    app=ProcessRecord{abc $pid:$name/u0ai5}\n"
}
private class Fixture {
    var services = service("ptc", PTC, 200) + service("linux", LINUX, 300)
    var pids = "PID\n100\n200\n300\n"
    var cpu = "TID CMD TIME\n301 isolated-linux- 00:00:01\n"
    var clock = 0L
    var failure = false
    val commands = mutableListOf<String>()
    val owner = PtcLinuxLifecycleObservation(PACKAGE, 100, { command ->
        commands += command
        check(!failure) { "Shell read failed" }
        when (command) {
            "dumpsys -t 5 activity services $PACKAGE" -> services
            "ps -A -o PID" -> pids
            "ps -T -p 300 -o TID,CMD,TIME" -> cpu
            else -> error("Unexpected command")
        }
    }, { ++clock })
}

fun main() {
    var checks = 0
    fun verify(name: String, body: () -> Unit) { body(); checks++; println("PASS $name") }
    fun denied(body: () -> Unit) { check(runCatching(body).isFailure) }
    verify("exact live pair, independent process and observed worker CPU") {
        val fixture = Fixture(); val result = fixture.owner.observe(params())
        check(result.getBoolean("observedPair")); check(!result.getBoolean("previousPidsGone"))
        check(result.getInt("ptcPid") == 200 && result.getInt("linuxPid") == 300)
        check(result.getLong("workerCpuSeconds") == 1L)
        check(fixture.commands.size == 3)
    }
    verify("two full observations retain original identities after processes disappear") {
        val fixture = Fixture(); fixture.owner.observe(params()); fixture.services = "ACTIVITY MANAGER SERVICES\n"; fixture.pids = "PID\n100\n"
        val first = fixture.owner.observe(params()); val second = fixture.owner.observe(params())
        check(first.getBoolean("previousPidsGone") && second.getBoolean("previousPidsGone"))
        check(first.isNull("ptcPid") && first.isNull("linuxPid"))
        check(first.getInt("observedPtcPid") == 200 && first.getInt("observedLinuxPid") == 300)
        check(second.getLong("observedAtElapsedMs") > first.getLong("observedAtElapsedMs"))
    }
    verify("missing service records do not retire still-visible guest PIDs") {
        val fixture = Fixture(); fixture.owner.observe(params()); fixture.services = ""
        check(!fixture.owner.observe(params()).getBoolean("previousPidsGone"))
    }
    verify("a never-observed pair cannot become retirement evidence") {
        val fixture = Fixture(); fixture.services = ""; fixture.pids = "PID\n100\n"
        check(!fixture.owner.observe(params()).getBoolean("previousPidsGone"))
    }
    verify("zero CPU does not establish actual running worker") {
        val fixture = Fixture(); fixture.cpu = "TID CMD TIME\n301 isolated-linux- 00:00:00\n"
        check(!fixture.owner.observe(params()).getBoolean("observedPair"))
    }
    verify("changed process identity under one run is refused") {
        val fixture = Fixture(); fixture.owner.observe(params())
        fixture.services = service("ptc", PTC, 201) + service("linux", LINUX, 300); fixture.pids += "201\n"
        denied { fixture.owner.observe(params()) }
    }
    verify("empty or partial full process list cannot certify disappearance") {
        val fixture = Fixture(); fixture.owner.observe(params()); fixture.pids = "PID\n"
        denied { fixture.owner.observe(params()) }
    }
    for (invalid in listOf("", "PID\n100\n100\n", "PID\n100\nerror\n", "PID CMD\n100 app\n")) {
        verify("malformed PID observation ${checks + 1}") { val fixture = Fixture(); fixture.pids = invalid; denied { fixture.owner.observe(params()) } }
    }
    verify("shell failures remain unknown") {
        val fixture = Fixture(); fixture.owner.observe(params()); fixture.failure = true
        denied { fixture.owner.observe(params()) }
    }
    verify("no shell command accepts unbound model text or extra fields") {
        val fixture = Fixture()
        denied { fixture.owner.observe(params().put("command", "anything")) }
        denied { fixture.owner.observe(params().put("linuxRunId", "invalid")) }
        denied { fixture.owner.observe(params().put("linuxRunId", PTC)) }
        check(fixture.commands.isEmpty())
    }
    println("PTC Linux lifecycle observation checks: $checks")
}
