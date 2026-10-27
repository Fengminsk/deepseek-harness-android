package com.minnnng.dsh_android

import org.json.JSONObject
import java.io.File
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

/** Exercises the actual AndroidTest scenario against the SDK's JSON implementation on a JVM. */
fun main(args: Array<String>) {
    val root = File(args.single())
    val id = UUID.randomUUID().toString()
    val home = File(root, "native-runtime-acceptance/$id").apply { mkdirs() }
    val workspace = File(root, ".device-acceptance-$id").apply { mkdirs() }
    val scenario = ProductionProfileAcceptanceScenario(home, workspace, File(root, "runtime"), id)
    val authentication = JSONObject(File(home, "production-profile-auth.json").readText())
    val modelKey = authentication.getString("modelKey")
    var checks = 0
    fun checkCase(action: () -> Unit) { action(); checks++ }
    fun denied(action: () -> Unit): Throwable {
        try { action() } catch (failure: Throwable) { return failure }
        error("Expected rejection")
    }
    fun projection(generation: String, revision: Long = 1) = JSONObject().put("version", 1)
        .put("generation", generation).put("revision", revision).put("state", "ready")
        .put("nextDueAtMs", JSONObject.NULL).put("activeCount", 0).put("reason", JSONObject.NULL)
    checkCase {
        check(scenario.handlesNative("native.scheduleWakeup.begin") && scenario.handlesNative("native.scheduleWakeup.update"))
        val begin = scenario.handleNative("native.scheduleWakeup.begin", JSONObject()) as JSONObject
        val generation = begin.getString("generation")
        check(UUID.fromString(generation).toString() == generation)
        check((scenario.handleNative("native.scheduleWakeup.begin", JSONObject()) as JSONObject).getString("generation") == generation)
        for (revision in listOf(1L, 3L)) {
            val ack = scenario.handleNative("native.scheduleWakeup.update", projection(generation, revision)) as JSONObject
            check(ack.getBoolean("accepted") && ack.getLong("revision") == revision && ack.getString("generation") == generation)
        }
        val observed = scenario.diagnostics().getJSONObject("scheduleWakeupFixture")
        check(observed.getInt("systemAlarmsRegistered") == 0 && observed.getString("kind") == "protocol-only")
        check(observed.getJSONArray("updates").length() == 2 && observed.getInt("beginCalls") == 2)
        observed.getJSONArray("updates").getJSONObject(0).put("prompt", "not retained")
        check(!scenario.diagnostics().getJSONObject("scheduleWakeupFixture").toString().contains("not retained"))
    }
    checkCase {
        val fixture = ProductionScheduleWakeFixture()
        val generation = fixture.request("native.scheduleWakeup.begin", JSONObject()).getString("generation")
        val edits: List<(JSONObject) -> Unit> = listOf(
            { it.put("generation", UUID.randomUUID().toString()) }, { it.put("revision", 0) },
            { it.put("revision", 1.5) }, { it.put("version", 2) }, { it.put("prompt", "private-prompt") },
            { it.put("nextDueAtMs", 1) }, { it.put("activeCount", 1) }, { it.put("activeCount", -1) },
            { it.put("state", "unknown") }, { it.put("reason", "private-error") },
        )
        for (edit in edits) denied { fixture.request("native.scheduleWakeup.update", projection(generation).also(edit)) }
        check(fixture.snapshot().getJSONArray("updates").length() == 0)
        fixture.request("native.scheduleWakeup.update", projection(generation))
        denied { fixture.request("native.scheduleWakeup.update", projection(generation)) }
        denied { fixture.request("native.scheduleWakeup.begin", JSONObject().put("prompt", "private-prompt")) }
    }
    checkCase {
        val fixture = ProductionScheduleWakeFixture()
        val other = ProductionScheduleWakeFixture()
        val generation = fixture.request("native.scheduleWakeup.begin", JSONObject()).getString("generation")
        check(generation != other.snapshot().getString("generation"))
        denied { other.request("native.scheduleWakeup.update", projection(other.snapshot().getString("generation"))) }
        val unavailable = projection(generation).put("state", "unavailable").put("activeCount", JSONObject.NULL)
            .put("reason", "catalog_read_failed")
        fixture.request("native.scheduleWakeup.update", unavailable)
        check(fixture.snapshot().getJSONArray("updates").getJSONObject(0).isNull("activeCount"))
        denied { fixture.request("native.scheduleWakeup.update", unavailable.put("revision", 2).put("activeCount", 0)) }
    }
    val browserName = "records/client-connection/browser-session"
    val secret = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { (it + 1).toByte() })
    val browserRecord = JSONObject().put("kind", "grant").put("payload", JSONObject().put("version", 1).put("secret", secret)).toString()
    checkCase {
        val tick = CountDownLatch(1)
        val time = AtomicLong(1000000)
        val probe = ProductionReadyWaitProbe {
            if (Thread.currentThread().name == "dsh-production-ready-pulse") tick.countDown()
            time.get()
        }
        val failure = denied {
            probe.observe {
                check(tick.await(5, TimeUnit.SECONDS))
                time.addAndGet(TimeUnit.SECONDS.toNanos(287))
                throw TimeoutException("controlled ready timeout")
            }
        }
        check(failure is TimeoutException)
        val snapshot = probe.snapshot()
        check(snapshot.getLong("timeoutAfterMs") == 287000L)
        check(snapshot.getBoolean("samplerStopped") && snapshot.getLong("pulseCount") >= 1)
        check(Thread.getAllStackTraces().keys.none { it.isAlive && it.name == "dsh-production-ready-pulse" })
    }
    checkCase {
        val probe = ProductionReadyWaitProbe()
        probe.observe { }
        check(probe.snapshot().isNull("timeoutAfterMs") && probe.snapshot().getBoolean("samplerStopped"))
        check(Thread.getAllStackTraces().keys.none { it.isAlive && it.name == "dsh-production-ready-pulse" })
        denied { probe.observe { error("A second wait must not be admitted") } }
    }
    checkCase {
        check(authentication.getString("caseId") == id)
        check(modelKey.matches(Regex("[A-Za-z0-9_-]{43}")) && modelKey != id)
        check(authentication.getString("closeToken").matches(Regex("[A-Za-z0-9_-]{43}")))
        check(authentication.getString("closeToken") != modelKey)
        check(!scenario.diagnostics().toString().contains(modelKey))
        check(!scenario.diagnostics().toString().contains(authentication.getString("closeToken")))
    }
    checkCase {
        check(scenario.handleNative("native.credentials.get", JSONObject().put("name", browserName)) == null)
        check(scenario.handleNative("native.credentials.set", JSONObject().put("name", browserName).put("value", browserRecord)) == true)
        check(scenario.handleNative("native.credentials.get", JSONObject().put("name", browserName)) == browserRecord)
        check(!scenario.diagnostics().toString().contains(secret))
    }
    checkCase {
        denied { scenario.handleNative("native.credentials.set", JSONObject().put("name", "records/deepseek-account-platform/default").put("value", browserRecord)) }
        check(scenario.handleNative("native.credentials.get", JSONObject().put("name", "records/deepseek-account-platform/default")) == null)
    }
    checkCase {
        for (value in listOf("{}", "{\"kind\":\"grant\",\"payload\":{\"version\":1,\"secret\":\"short\"}}",
            "{\"kind\":\"grant\",\"payload\":{\"version\":2,\"secret\":\"$secret\"}}")) {
            denied { scenario.handleNative("native.credentials.set", JSONObject().put("name", browserName).put("value", value)) }
            check(scenario.handleNative("native.credentials.get", JSONObject().put("name", browserName)) == browserRecord)
        }
    }
    checkCase {
        denied { scenario.handleNative("native.credentials.set", JSONObject().put("name", "refs/DEEPSEEK_API_KEY").put("value", "another-key")) }
        check(scenario.handleNative("native.credentials.get", JSONObject().put("name", "refs/DEEPSEEK_API_KEY")) == modelKey)
    }
    checkCase {
        val sensitive = "never-print-credential"
        val report = scenario.failureDiagnostics(IllegalStateException(sensitive))
        check(!report.toString().contains(sensitive))
        check(report.getJSONArray("causes").getJSONObject(0).getJSONArray("frames").length() <= 10)
    }
    checkCase {
        val proof = File(home, "production-profile-proof.json")
        proof.writeText(JSONObject().put("failure", JSONObject.NULL).put("unownedRequestCount", 2)
            .put("lastUnownedRequest", JSONObject().put("method", "GET").put("path", "/probe"))
            .put("lastAuthenticatedRequest", JSONObject().put("method", "POST").put("path", "/v1/messages"))
            .put("failedRequest", JSONObject.NULL).put("requestHeaders", modelKey).toString())
        try {
            val model = scenario.diagnostics().getJSONObject("model")
            check(model.getInt("unownedRequestCount") == 2)
            check(model.getJSONObject("lastUnownedRequest").getString("path") == "/probe")
            check(model.getJSONObject("lastAuthenticatedRequest").getString("method") == "POST")
            check(model.isNull("failedRequest") && !model.getBoolean("failed"))
            check(!model.toString().contains(modelKey) && !model.has("requestHeaders"))
        } finally { check(proof.delete()) }
    }
    checkCase {
        scenario.onNotification("runtime.status", JSONObject().put("phase", "failed").put("error", "secret=$secret EACCES"))
        val failure = denied { scenario.run { _, _, _ -> error("No RPC may start after failed initialization") } }
        check(failure.message!!.contains("runtime-ready-wait"))
        check(failure.message!!.contains("EACCES") && !failure.message!!.contains(secret))
        check(scenario.diagnostics().getString("runtimeStatusPhase") == "failed")
        check(scenario.diagnostics().getJSONObject("readyWait").getBoolean("samplerStopped"))
        check(scenario.diagnostics().getJSONObject("readyWait").isNull("timeoutAfterMs"))
    }
    checkCase {
        val failure = denied { scenario.close() }
        check(failure.message!!.contains("proof absent"))
        check(scenario.diagnostics().getString("stage") == "model-close")
    }
    println("Production profile scenario host checks passed: $checks")
}
