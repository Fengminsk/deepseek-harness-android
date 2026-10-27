package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

private const val CURRENT = "00000000-0000-4000-8000-000000000001"
private const val NEXT = "00000000-0000-4000-8000-000000000002"

private class HandoffWorld : ScheduleWakeupController.Platform {
    var disk: JSONObject? = null
    val alarms = mutableMapOf<String, Long>()
    var failWrite = false
    var clock = 1_000L
    override fun read() = disk?.let { JSONObject(it.toString()) }
    override fun write(value: JSONObject) {
        check(!failWrite) { "storage write failed" }
        disk = JSONObject(value.toString())
    }
    override fun cancel(token: String) { alarms.remove(token) }
    override fun arm(token: String, atMillis: Long) { alarms[token] = atMillis }
    override fun allowed() = true
    override fun now() = clock
    override fun token() = UUID.randomUUID().toString()
}

private fun projection(revision: Int, due: Long) = JSONObject()
    .put("version", 1).put("generation", CURRENT).put("revision", revision)
    .put("state", "ready").put("nextDueAtMs", due).put("activeCount", 1)
    .put("reason", JSONObject.NULL)

private class HandoffFixture {
    val world = HandoffWorld()
    val controller = ScheduleWakeupController(world)
    val events = mutableListOf<String>()
    var leaseToken: String?
    var leaseHeld = true

    init {
        controller.bind(CURRENT)
        controller.update(projection(1, 5_000))
        controller.configure(true)
        leaseToken = world.disk!!.getString("token")
        world.clock = 5_000
        check(world.alarms.remove(leaseToken) == 5_000L)
        check(controller.claim(leaseToken!!))
    }

    fun fail(expected: String = CURRENT, current: String = CURRENT) {
        ScheduleWakeupHandoff.fail(expected, current, leaseToken, { token ->
            events.add("mark-failed")
            controller.wakeFailed(token, "runtime_unavailable")
        }, {
            events.add("release")
            leaseToken = null
            leaseHeld = false
        })
    }
}

fun main(args: Array<String>) {
    val checks = JSONArray()
    fun test(name: String, body: () -> Unit) {
        body()
        checks.put(JSONObject().put("name", name).put("passed", true))
        println("PASS $name")
    }

    test("terminal runtime failure records and releases before stopping the service and process") {
        val f = HandoffFixture()
        val lifecycle = RuntimeLifecycle()
        check(lifecycle.fail())
        check(lifecycle.stopFailedProcess(
            { f.fail(); f.events.add("report") },
            { check(!f.leaseHeld); f.events.add("stop-foreground") },
            { f.events.add("stop-service") },
            { f.events.add("kill") },
        ))
        check(f.events == listOf("mark-failed", "release", "report", "stop-foreground", "stop-service", "kill"))
        check(f.world.disk!!.getString("error") == "runtime_unavailable")
        check(f.world.disk!!.getString("phase") == "error" && f.world.alarms.isEmpty())
        val cold = ScheduleWakeupController(f.world).status()
        check(cold.getString("alarmState") == "error" && cold.getString("error") == "runtime_unavailable")
        check(!lifecycle.acceptsFrames())
        check(!lifecycle.stopFailedProcess({ error("duplicate report") }, {}, {}, {}))
    }

    test("an old service generation cannot release or fail a newer handoff") {
        val f = HandoffFixture()
        f.controller.bind(NEXT)
        val before = f.world.disk.toString()
        f.fail(CURRENT, NEXT)
        check(f.leaseHeld && f.leaseToken != null && f.events.isEmpty())
        check(f.world.disk.toString() == before)
    }

    test("failure of an old handoff leaves a newer future alarm registered") {
        val f = HandoffFixture()
        val oldToken = f.leaseToken
        f.controller.update(projection(2, 9_000))
        val nextToken = f.world.disk!!.getString("token")
        check(nextToken != oldToken)
        val before = f.world.disk.toString()
        f.fail()
        check(!f.leaseHeld && f.leaseToken == null)
        check(f.world.alarms == mapOf(nextToken to 9_000L))
        check(f.world.disk.toString() == before)
        check(f.controller.status().getString("alarmState") == "scheduled")
    }

    test("failed persistence still releases and does not interrupt process retirement") {
        val f = HandoffFixture()
        f.world.failWrite = true
        val lifecycle = RuntimeLifecycle()
        check(lifecycle.fail())
        val failure = try {
            lifecycle.stopFailedProcess({ f.fail() },
                { f.events.add("stop-foreground") }, { f.events.add("stop-service") }, { f.events.add("kill") })
            null
        } catch (error: IllegalStateException) { error }
        check(failure?.message == "storage_write_failed")
        check(!f.leaseHeld && f.leaseToken == null)
        check(f.events == listOf("mark-failed", "release", "stop-foreground", "stop-service", "kill"))
        check(f.controller.status().getString("error") == "storage_write_failed")
        check(f.world.disk!!.getString("phase") == "waking")
    }

    test("absence of an active handoff does not change a future alarm") {
        val f = HandoffFixture()
        f.controller.update(projection(2, 9_000))
        f.leaseToken = null
        f.leaseHeld = false
        val before = f.world.disk.toString()
        val alarms = f.world.alarms.toMap()
        f.fail()
        check(f.events.isEmpty() && f.world.disk.toString() == before && f.world.alarms == alarms)
    }

    val report = JSONObject().put("scope", "controller-and-runtime-lifecycle-host")
        .put("passed", true).put("checks", checks)
    File(args.single()).writeText(report.toString(2))
    println("Schedule handoff host checks: ${checks.length()} passed")
}
