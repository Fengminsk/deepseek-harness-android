package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

private const val FIRST = "00000000-0000-4000-8000-000000000001"
private const val SECOND = "00000000-0000-4000-8000-000000000002"

/** The disk and OS alarm registry survive controller reconstruction independently. */
private class World : ScheduleWakeupController.Platform {
    var disk: JSONObject? = null
    val alarms = mutableMapOf<String, Long>()
    val events = mutableListOf<String>()
    var clock = 1_000L
    var permission = true
    var reads = 0
    var writes = 0
    var tokenIndex = 0
    var readFailure = false
    var permissionFailure = false
    var cancelFailure = false
    var armFailure = false
    var tokenFailure = false
    var writeBefore: ((JSONObject) -> Unit)? = null
    var writeAfter: ((JSONObject) -> Unit)? = null
    var onCancel: (() -> Unit)? = null

    override fun read(): JSONObject? {
        reads++
        check(!readFailure) { "private storage exception must not escape" }
        return disk?.let { JSONObject(it.toString()) }
    }
    override fun write(value: JSONObject) {
        writes++
        writeBefore?.invoke(value)
        disk = JSONObject(value.toString())
        events.add("write:${value.getString("phase")}")
        writeAfter?.invoke(value)
    }
    override fun cancel(token: String) {
        // An already delivered PendingIntent must be rejected even while cancellation blocks/fails.
        check(disk?.optString("token") != token) { "cancel preceded durable invalidation" }
        events.add("cancel")
        onCancel?.invoke()
        check(!cancelFailure) { "alarm manager cancellation failed" }
        alarms.remove(token)
    }
    override fun arm(token: String, atMillis: Long) {
        check(disk?.getString("token") == token && disk?.getString("phase") == "pending")
        events.add("arm")
        alarms[token] = atMillis
        check(!armFailure) { "unknown registration outcome" }
    }
    override fun allowed(): Boolean {
        check(!permissionFailure)
        return permission
    }
    override fun now() = clock
    override fun token(): String {
        check(!tokenFailure)
        return "alarm-token-${++tokenIndex}-0000000000000000"
    }
    fun current(): String = checkNotNull(disk).getString("token")
}

private fun ready(revision: Long = 1L, due: Long? = 5_000L, count: Int = if (due == null) 0 else 1,
    generation: String = FIRST): JSONObject = JSONObject().put("version", 1).put("generation", generation)
    .put("revision", revision).put("state", "ready").put("nextDueAtMs", due ?: JSONObject.NULL)
    .put("activeCount", count).put("reason", JSONObject.NULL)

private fun configured(world: World = World()): Pair<World, ScheduleWakeupController> {
    val controller = ScheduleWakeupController(world)
    controller.bind(FIRST)
    controller.update(ready())
    controller.configure(true)
    check(controller.status().getString("alarmState") == "scheduled")
    return world to controller
}

private fun fails(code: String? = null, block: () -> Unit) {
    val error = try { block(); null } catch (error: Exception) { error }
    check(error != null) { "operation unexpectedly succeeded" }
    if (code != null) check(error.message == code) { "Expected $code, got ${error.message}" }
}

private fun state(controller: ScheduleWakeupController, expected: String, error: String? = null) {
    val status = controller.status()
    check(status.getString("alarmState") == expected) { status.toString() }
    if (error != null) check(status.getString("error") == error) { status.toString() }
}

fun main(args: Array<String>) {
    val results = JSONArray()
    fun test(name: String, body: () -> Unit) {
        body()
        results.put(JSONObject().put("name", name).put("passed", true))
        println("PASS $name")
    }

    test("default and status inspection never arm or persist") {
        val world = World()
        val controller = ScheduleWakeupController(world)
        repeat(3) { state(controller, "disabled") }
        check(world.events.isEmpty() && world.disk == null)
        fails("service_unbound") { controller.begin() }
        controller.bind(FIRST)
        check(controller.begin().toString() == JSONObject().put("version", 1).put("generation", FIRST).toString())
        check(world.events.isEmpty())
    }
    test("projection remains dormant until explicitly enabled") {
        val world = World()
        val controller = ScheduleWakeupController(world)
        controller.bind(FIRST)
        val ack = controller.update(ready(count = 3))
        check(ack.getLong("revision") == 1L && ack.getBoolean("accepted"))
        check(world.alarms.isEmpty())
        state(controller, "disabled")
        controller.configure(true)
        check(world.alarms == mapOf(world.current() to 5_000L))
        check(controller.status().getInt("activeCount") == 3)
    }
    test("permission refusal does not save enabled preference") {
        val world = World().apply { permission = false }
        val controller = ScheduleWakeupController(world)
        fails("exact_alarm_permission_required") { controller.configure(true) }
        check(world.disk == null && world.writes == 0)
        state(controller, "disabled")
        world.permissionFailure = true
        fails("permission_check_failed") { controller.configure(true) }
        state(controller, "error", "permission_check_failed")
        check(world.writes == 0)
    }
    test("new generation invalidates RPCs without deleting future alarm") {
        val (world, controller) = configured()
        val token = world.current()
        val writes = world.writes
        controller.bind(SECOND)
        controller.unbind(FIRST)
        check(controller.begin().getString("generation") == SECOND)
        fails("stale_generation") { controller.update(ready(2)) }
        check(world.current() == token && world.writes == writes)
        controller.unbind(SECOND)
        fails("service_unbound") { controller.begin() }
        check(world.alarms.containsKey(token))
        controller.bind(SECOND)
        controller.update(ready(1, generation = SECOND))
        fails("stale_revision") { controller.update(ready(1, generation = SECOND)) }
        check(!controller.claim(token))
    }
    test("wire parser rejects malformed complete projections without side effects") {
        val (world, controller) = configured()
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("revision", 0) }, { it.put("revision", 9_007_199_254_740_992L) },
            { it.put("revision", 2.5) }, { it.put("revision", "2") },
            { it.put("version", "1") }, { it.put("extra", "not metadata") },
            { it.remove("reason") }, { it.put("activeCount", -1) },
            { it.put("activeCount", 2_147_483_648L) }, { it.put("activeCount", 0) },
            { it.put("nextDueAtMs", -1) }, { it.put("nextDueAtMs", JSONObject.NULL) },
            { it.put("reason", "private failure") }, { it.put("state", "unknown") },
            { it.put("generation", SECOND) },
        )
        val before = world.disk.toString()
        val writes = world.writes
        mutations.forEach { mutation -> fails { controller.update(ready(2).also(mutation)) } }
        check(world.disk.toString() == before && world.writes == writes)
        controller.update(ready(9_007_199_254_740_991L))
        fails("stale_revision") { controller.update(ready(2)) }
    }
    test("replanning cancels old intent before admitting new token") {
        val (world, controller) = configured()
        val old = world.current()
        controller.update(ready(2, due = 8_000L))
        val current = world.current()
        check(current != old && world.alarms == mapOf(current to 8_000L))
        world.clock = 9_000
        check(!controller.claim(old) && controller.claim(current))
        check(!controller.claim(current) && controller.acceptWake(current))
        check(world.disk?.getString("phase") == "waking")
    }
    test("receiver-to-service handoff rechecks cancellation and permission") {
        val (world, controller) = configured()
        val old = world.current()
        world.clock = 5_000
        check(controller.claim(old))
        world.permission = false
        check(!controller.acceptWake(old))
        world.permission = true
        controller.configure(false)
        check(!controller.acceptWake(old) && world.alarms.isEmpty())
        state(controller, "disabled")
    }
    test("service intent cannot replace receiver claim on a scheduled alarm") {
        val (world, controller) = configured()
        val token = world.current()
        world.clock = 5_000
        val writes = world.writes
        check(!controller.acceptWake(token) && world.writes == writes)
        check(world.disk?.getString("phase") == "scheduled")
        check(controller.claim(token) && controller.acceptWake(token))
        check(!controller.claim(token))
    }
    test("concurrent cancel prevents a blocked receiver from claiming obsolete token") {
        val (world, controller) = configured()
        val old = world.current()
        world.clock = 5_000
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val receiverStarted = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        val claimed = AtomicReference<Boolean?>()
        world.onCancel = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val cancel = thread(name = "test-cancel") { try { controller.configure(false) } catch (error: Throwable) { failure.set(error) } }
        var receiver: Thread? = null
        try {
            check(entered.await(5, TimeUnit.SECONDS))
            receiver = thread(name = "test-receiver") {
                receiverStarted.countDown()
                try { claimed.set(controller.claim(old)) } catch (error: Throwable) { failure.set(error) }
            }
            check(receiverStarted.await(5, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            cancel.join(5_000)
            receiver?.join(5_000)
            check(!cancel.isAlive && receiver?.isAlive != true) { "test owners did not retire" }
        }
        failure.get()?.let { throw it }
        check(claimed.get() == false && world.alarms.isEmpty())
    }
    test("failed cancellation leaves obsolete alarm unable to claim and can recover") {
        val (world, controller) = configured()
        val old = world.current()
        world.cancelFailure = true
        controller.configure(false)
        world.clock = 10_000
        check(world.alarms.containsKey(old) && !controller.claim(old))
        state(controller, "error", "alarm_cancel_failed")
        world.cancelFailure = false
        val restored = ScheduleWakeupController(world)
        restored.restore()
        check(world.alarms.isEmpty())
        state(restored, "disabled")
    }
    test("write failure before invalidation never calls cancel or arm") {
        val (world, controller) = configured()
        val old = world.current()
        val events = world.events.size
        world.writeBefore = { throw IllegalStateException("disk full") }
        fails("storage_write_failed") { controller.configure(false) }
        check(world.events.size == events && world.current() == old)
        world.clock = 10_000
        check(!controller.claim(old) && !controller.status().getBoolean("enabled"))
        state(controller, "error", "storage_write_failed")
        world.writeBefore = null
        controller.restore()
        check(world.current() != old && world.alarms.size == 1)
    }
    test("unknown write outcome is not acknowledged and recovery follows durable desired state") {
        val (world, controller) = configured()
        val old = world.current()
        world.writeAfter = { throw IllegalStateException("commit result unavailable") }
        fails("storage_write_failed") { controller.configure(false) }
        check(world.disk?.getBoolean("enabled") == false && world.alarms.containsKey(old))
        world.clock = 10_000
        check(!controller.acceptWake(old))
        world.writeAfter = null
        ScheduleWakeupController(world).restore()
        check(world.alarms.isEmpty())
    }
    test("registration with unknown outcome is quarantined until explicit restore") {
        val world = World().apply { armFailure = true }
        val controller = ScheduleWakeupController(world)
        controller.bind(FIRST)
        controller.update(ready())
        controller.configure(true)
        val old = world.current()
        state(controller, "error", "alarm_arm_failed")
        world.clock = 10_000
        check(world.alarms.containsKey(old) && !controller.claim(old))
        world.armFailure = false
        val restored = ScheduleWakeupController(world)
        check(!restored.claim(old) && !restored.acceptWake(old))
        restored.restore()
        check(world.alarms.size == 1 && !world.alarms.containsKey(old))
        check(restored.claim(world.current()))
    }
    test("cold receiver claims a delivered pending alarm without manual restore") {
        val world = World()
        val controller = ScheduleWakeupController(world)
        controller.bind(FIRST)
        controller.update(ready())
        world.writeBefore = { value -> if (value.getString("phase") == "scheduled") error("power loss") }
        fails("storage_write_failed") { controller.configure(true) }
        val old = world.current()
        check(world.disk?.getString("phase") == "pending" && world.alarms.containsKey(old))
        world.writeBefore = null
        val restarted = ScheduleWakeupController(world)
        check(!restarted.claim(old))
        world.clock = 5_000
        world.permission = false
        check(!restarted.claim(old))
        world.permission = true
        val writes = world.writes
        check(!restarted.acceptWake(old) && world.writes == writes)
        // Model AlarmManager's one-shot delivery: this is the only existing alarm, now consumed.
        check(world.alarms.remove(old) == 5_000L && world.alarms.isEmpty())
        val armCount = world.events.count { it == "arm" }
        check(restarted.claim(old) && restarted.acceptWake(old))
        check(!restarted.claim(old) && world.disk?.getString("phase") == "waking")
        check(world.current() == old && world.events.count { it == "arm" } == armCount)
    }
    test("cold receiver cannot claim a cancellation-pending record without current token") {
        val (world, controller) = configured()
        val old = world.current()
        world.writeAfter = { value ->
            if (value.getString("phase") == "pending" && value.isNull("token")) error("power loss before cancel")
        }
        fails("storage_write_failed") { controller.update(ready(2, due = 6_000)) }
        check(world.disk?.getString("phase") == "pending" && world.disk?.isNull("token") == true)
        check(world.disk?.getString("cancellingToken") == old && world.disk?.getBoolean("enabled") == true)
        world.writeAfter = null
        world.clock = 10_000
        val restarted = ScheduleWakeupController(world)
        val writes = world.writes
        check(!restarted.claim(old) && !restarted.acceptWake(old) && world.writes == writes)
        check(world.alarms.containsKey(old))
    }
    test("permission revocation blocks claim before reconciliation and grant creates a fresh token") {
        val (world, controller) = configured()
        val old = world.current()
        val writes = world.writes
        world.permission = false
        world.clock = 5_000
        state(controller, "permission-required")
        check(!controller.claim(old) && world.writes == writes)
        controller.restore()
        check(world.alarms.isEmpty() && controller.status().getBoolean("enabled"))
        state(controller, "permission-required", "exact_alarm_permission_required")
        world.permission = true
        controller.restore()
        check(world.current() != old && controller.claim(world.current()))
    }
    test("corrupt persistence contains only the feature and never overwrites the original") {
        val (source, _) = configured()
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("version", 2) }, { it.put("prompt", "not supported") },
            { it.put("enabled", "true") }, { it.put("projectionState", "unknown") },
            { it.put("activeCount", 0) }, { it.put("armedAtMs", 1) },
            { it.put("token", "short") }, { it.put("phase", "other") },
            { it.put("reason", "private message") }, { it.remove("error") },
            { it.put("error", "arbitrary exception") },
            { it.put("cancellingToken", "old-alarm-token-000000000") },
        )
        mutations.forEach { mutation ->
            val world = World().apply { disk = JSONObject(source.disk.toString()).also(mutation) }
            val before = world.disk.toString()
            val controller = ScheduleWakeupController(world)
            state(controller, "error", "storage_corrupt")
            check(!controller.status().getBoolean("enabled"))
            fails("storage_corrupt") { controller.configure(true) }
            controller.bind(FIRST)
            fails("storage_corrupt") { controller.update(ready()) }
            controller.restore()
            check(world.writes == 0 && world.disk.toString() == before)
        }
    }
    test("storage read failure does not abort construction or overwrite data") {
        val world = World().apply { readFailure = true }
        val controller = ScheduleWakeupController(world)
        state(controller, "error", "storage_read_failed")
        controller.restore()
        check(world.writes == 0)
        world.readFailure = false
        controller.restore()
        state(controller, "disabled")
    }
    test("unavailable catalog cancels stale hint and reports fixed reason") {
        val (world, controller) = configured()
        val unavailable = ready(2).put("state", "unavailable").put("nextDueAtMs", JSONObject.NULL)
            .put("activeCount", JSONObject.NULL).put("reason", "catalog_read_failed")
        controller.update(unavailable)
        check(world.alarms.isEmpty())
        check(controller.status().getString("projectionState") == "unavailable")
        check(controller.status().getString("error") == "catalog_read_failed")
        controller.update(ready(3, due = null))
        state(controller, "waiting")
        check(controller.status().isNull("error") && world.alarms.isEmpty())
    }
    test("backwards clock cannot claim before due or the persisted arm instant") {
        val (world, controller) = configured()
        val first = world.current()
        world.clock = 500
        check(!controller.claim(first))
        world.clock = 10_000
        controller.restore()
        val second = world.current()
        check(world.alarms[second] == 10_000L)
        world.clock = 6_000
        check(!controller.claim(second))
        controller.restore()
        check(world.current() != second && world.alarms[world.current()] == 6_000L)
        check(controller.claim(world.current()))
    }
    test("late failure cannot cancel another wake and a current failure is recoverable") {
        val (world, controller) = configured()
        val old = world.current()
        controller.update(ready(2))
        val current = world.current()
        val writes = world.writes
        controller.wakeFailed(old, "service_start_failed")
        check(world.writes == writes && world.current() == current)
        world.clock = 5_000
        check(controller.claim(current))
        controller.wakeFailed(current, "handoff_timeout")
        check(world.alarms.isEmpty() && !controller.acceptWake(current))
        state(controller, "error", "handoff_timeout")
        controller.restore()
        check(world.current() != current && controller.claim(world.current()))
    }
    test("token allocation failure never registers an untracked alarm") {
        val world = World().apply { tokenFailure = true }
        val controller = ScheduleWakeupController(world)
        controller.bind(FIRST)
        controller.update(ready())
        controller.configure(true)
        state(controller, "error", "token_failed")
        check(world.alarms.isEmpty())
        world.tokenFailure = false
        controller.restore()
        state(controller, "scheduled")
    }
    test("claim commit failure cannot grant receiver ownership") {
        val (world, controller) = configured()
        val token = world.current()
        world.clock = 5_000
        world.writeAfter = { value -> if (value.getString("phase") == "waking") error("commit response lost") }
        check(!controller.claim(token) && !controller.acceptWake(token))
        state(controller, "error", "storage_write_failed")
        check(world.disk?.getString("phase") == "waking")
        world.writeAfter = null
        val restarted = ScheduleWakeupController(world)
        check(!restarted.claim(token))
        restarted.restore()
        check(!restarted.acceptWake(token) && restarted.claim(world.current()))
    }
    val report = JSONObject().put("scope", "pure-controller-host").put("passed", true).put("checks", results)
    File(args.single()).writeText(report.toString(2))
    println("Schedule wake-up host checks: ${results.length()} passed")
}
