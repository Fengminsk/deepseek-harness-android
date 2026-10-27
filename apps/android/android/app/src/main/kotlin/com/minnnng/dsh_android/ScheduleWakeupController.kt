package com.minnnng.dsh_android

import org.json.JSONObject

/** Serial owner of a durable wake-up hint, never of reminder contents or task delivery. */
class ScheduleWakeupController(private val platform: Platform) {
    interface Platform {
        fun read(): JSONObject?
        /** Atomically replace durable metadata before returning; a thrown write has an unknown outcome. */
        fun write(value: JSONObject)
        fun cancel(token: String)
        fun arm(token: String, atMillis: Long)
        fun allowed(): Boolean
        fun now(): Long
        fun token(): String
    }

    private data class Record(
        val enabled: Boolean = false, val projection: String = "unknown", val count: Int? = null,
        val due: Long? = null, val reason: String? = null, val token: String? = null,
        val cancelling: String? = null, val phase: String = "none", val armedAt: Long? = null,
        val error: String? = null,
    )
    private var record = Record()
    private var fault: String? = null
    private var generation: String? = null
    private var revision = 0L

    init { load() }

    @Synchronized fun bind(generation: String) {
        require(UUID.matches(generation)) { "invalid_generation" }
        if (this.generation != generation) { this.generation = generation; revision = 0 }
    }

    /** A stale service disposer cannot revoke a newer service's RPC generation. */
    @Synchronized fun unbind(generation: String) {
        if (this.generation == generation) { this.generation = null; revision = 0 }
    }

    @Synchronized fun begin(): JSONObject {
        healthy()
        return JSONObject().put("version", 1).put("generation", generation ?: error("service_unbound"))
    }

    /** Accept a newer complete projection; acknowledgement does not claim alarm delivery. */
    @Synchronized fun update(params: JSONObject): JSONObject {
        healthy()
        require(keys(params) == UPDATE_KEYS && integer(params.get("version")) == 1L) { "invalid_projection" }
        val owner = params.get("generation")
        require(owner is String && owner == generation && generation != null) { "stale_generation" }
        val nextRevision = integer(params.get("revision"))
        require(nextRevision in 1..MAX_SAFE && nextRevision > revision) { "stale_revision" }
        val projection = params.get("state")
        require(projection == "ready" || projection == "unavailable") { "invalid_projection" }
        val due = nullableInteger(params, "nextDueAtMs")
        val countValue = nullableInteger(params, "activeCount")
        require(countValue == null || countValue in 0..Int.MAX_VALUE.toLong()) { "invalid_projection" }
        val count = countValue?.toInt()
        val reason = nullableString(params, "reason")
        if (projection == "ready") {
            require(reason == null && count != null && (if (count == 0) due == null else due != null)) { "invalid_projection" }
        } else require(count == null && due == null && reason in CATALOG_ERRORS) { "invalid_projection" }
        replan(record.copy(projection = projection as String, count = count, due = due, reason = reason))
        revision = nextRevision
        return JSONObject().put("version", 1).put("generation", owner).put("revision", nextRevision).put("accepted", true)
    }

    /** Refused authorization never changes the stored enabled preference. */
    @Synchronized fun configure(enabled: Boolean): JSONObject {
        healthy()
        if (enabled) {
            val (allowed, error) = permission()
            check(allowed) { error ?: "exact_alarm_permission_required" }
        }
        replan(record.copy(enabled = enabled))
        return status()
    }

    /** Inspection never writes metadata, registers alarms or changes the preference. */
    @Synchronized fun status(): JSONObject {
        val (allowed, permissionError) = permission()
        val error = fault ?: permissionError ?: record.error ?: record.reason
        val state = when {
            fault != null || permissionError != null -> "error"
            record.enabled && !allowed -> "permission-required"
            record.error != null -> "error"
            !record.enabled -> "disabled"
            record.phase == "scheduled" -> "scheduled"
            record.phase == "waking" -> "waking"
            else -> "waiting"
        }
        return JSONObject().put("enabled", record.enabled && fault == null)
            .put("exactAlarmsAllowed", allowed).put("projectionState", record.projection)
            .put("activeCount", record.count ?: JSONObject.NULL).put("nextDueAtMs", record.due ?: JSONObject.NULL)
            .put("alarmState", state).put("error", error ?: JSONObject.NULL)
            .put("armedAtMs", record.armedAt ?: JSONObject.NULL)
    }

    /** Reconcile a persisted desired hint after boot, permission grant or explicit owner recovery. */
    @Synchronized fun restore() {
        if (load()) replan(record)
    }

    /** The first valid alarm atomically becomes waking; duplicate receivers do not own another wake. */
    @Synchronized fun claim(token: String): Boolean {
        // A delivered immutable alarm can outlive the process that armed it, before its final save.
        if (!eligible(token) || record.phase !in setOf("scheduled", "pending")) return false
        return try { save(record.copy(phase = "waking")); true } catch (_: IllegalStateException) { false }
    }

    /** Service handoff must recheck the same token, deadline and authorization after receiver claim. */
    @Synchronized fun acceptWake(token: String): Boolean {
        return record.phase == "waking" && eligible(token)
    }

    /** Reject late failures belonging to an obsolete attempt; retain only a fixed error code. */
    @Synchronized fun wakeFailed(token: String, reason: String) {
        if (fault != null || record.token != token || record.phase !in setOf("scheduled", "waking")) return
        require(reason in WAKE_ERRORS) { "invalid_wake_failure" }
        replan(record, reason)
    }

    private fun eligible(token: String): Boolean {
        if (fault != null || !TOKEN.matches(token) || !record.enabled || record.projection != "ready" ||
            record.token != token || record.cancelling != null || record.error != null) return false
        val due = record.due ?: return false
        val armedAt = record.armedAt ?: return false
        val now = platform.now()
        return now >= due && now >= armedAt && permission().first
    }

    private fun permission(): Pair<Boolean, String?> = try { platform.allowed() to null }
        catch (_: Exception) { false to "permission_check_failed" }

    /** Persist invalidation before touching AlarmManager. A failed cancellation keeps its token for restore. */
    private fun replan(desired: Record, stoppedError: String? = null) {
        healthy()
        val oldToken = record.token ?: record.cancelling
        save(desired.copy(token = null, cancelling = oldToken, phase = "pending", armedAt = null, error = null))
        if (oldToken != null) {
            try { platform.cancel(oldToken) }
            catch (_: Exception) { save(record.copy(phase = "error", error = "alarm_cancel_failed")); return }
            save(record.copy(cancelling = null))
        }
        if (stoppedError != null) { save(record.copy(phase = "error", error = stoppedError)); return }
        if (!record.enabled || record.projection != "ready" || record.due == null) {
            save(record.copy(phase = "none")); return
        }
        val (allowed, permissionError) = permission()
        if (!allowed) {
            save(record.copy(phase = "none", error = permissionError ?: "exact_alarm_permission_required")); return
        }
        val token = try { platform.token().also { check(TOKEN.matches(it) && it != oldToken) } }
            catch (_: Exception) { save(record.copy(phase = "error", error = "token_failed")); return }
        val at = maxOf(record.due!!, platform.now())
        save(record.copy(token = token, phase = "pending", armedAt = at))
        try { platform.arm(token, at) }
        catch (_: Exception) { save(record.copy(phase = "error", error = "alarm_arm_failed")); return }
        save(record.copy(phase = "scheduled"))
    }

    private fun healthy() { check(fault == null) { fault ?: "storage_unavailable" } }

    private fun save(next: Record) {
        try { platform.write(encode(next)) }
        catch (_: Exception) { fault = "storage_write_failed"; throw IllegalStateException("storage_write_failed") }
        record = next
    }

    private fun load(): Boolean {
        val raw = try { platform.read() } catch (_: Exception) {
            fault = "storage_read_failed"; return false
        }
        val value = try { if (raw == null) Record() else decode(raw) }
        catch (_: Exception) { fault = "storage_corrupt"; return false }
        record = value; fault = null
        return true
    }

    private fun encode(value: Record): JSONObject = JSONObject().put("version", 1)
        .put("enabled", value.enabled).put("projectionState", value.projection)
        .put("activeCount", value.count ?: JSONObject.NULL).put("nextDueAtMs", value.due ?: JSONObject.NULL)
        .put("reason", value.reason ?: JSONObject.NULL).put("token", value.token ?: JSONObject.NULL)
        .put("cancellingToken", value.cancelling ?: JSONObject.NULL).put("phase", value.phase)
        .put("armedAtMs", value.armedAt ?: JSONObject.NULL).put("error", value.error ?: JSONObject.NULL)

    private fun decode(value: JSONObject): Record {
        require(keys(value) == RECORD_KEYS && integer(value.get("version")) == 1L)
        val enabled = value.get("enabled"); require(enabled is Boolean)
        val projection = value.get("projectionState"); require(projection in setOf("unknown", "ready", "unavailable"))
        val countValue = nullableInteger(value, "activeCount")
        require(countValue == null || countValue in 0..Int.MAX_VALUE.toLong())
        val count = countValue?.toInt(); val due = nullableInteger(value, "nextDueAtMs")
        val reason = nullableString(value, "reason")
        when (projection) {
            "unknown" -> require(count == null && due == null && reason == null)
            "ready" -> require(count != null && reason == null && (if (count == 0) due == null else due != null))
            "unavailable" -> require(count == null && due == null && reason in CATALOG_ERRORS)
        }
        val token = nullableString(value, "token"); require(token == null || TOKEN.matches(token))
        val cancelling = nullableString(value, "cancellingToken"); require(cancelling == null || TOKEN.matches(cancelling))
        val phase = value.get("phase"); require(phase in setOf("none", "pending", "scheduled", "waking", "error"))
        val armedAt = nullableInteger(value, "armedAtMs")
        val error = nullableString(value, "error"); require(error == null || error in STORED_ERRORS)
        require((token == null) == (armedAt == null) && !(token != null && cancelling != null))
        if (token != null) require(enabled && projection == "ready" && due != null && armedAt!! >= due)
        if (phase == "scheduled" || phase == "waking") require(token != null && error == null)
        if (phase == "none") require(token == null && cancelling == null)
        if (phase == "error") require(error != null)
        return Record(enabled, projection as String, count, due, reason, token, cancelling, phase as String, armedAt, error)
    }

    companion object {
        private const val MAX_SAFE = 9_007_199_254_740_991L
        private val UUID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        private val TOKEN = Regex("[A-Za-z0-9_-]{16,128}")
        private val CATALOG_ERRORS = setOf("catalog_read_failed", "invalid_catalog")
        private val WAKE_ERRORS = setOf("service_start_failed", "runtime_unavailable", "wake_timeout", "handoff_timeout", "service_stopped")
        private val STORED_ERRORS = WAKE_ERRORS + setOf("alarm_cancel_failed", "alarm_arm_failed", "token_failed",
            "permission_check_failed", "exact_alarm_permission_required")
        private val UPDATE_KEYS = setOf("version", "generation", "revision", "state", "nextDueAtMs", "activeCount", "reason")
        private val RECORD_KEYS = setOf("version", "enabled", "projectionState", "activeCount", "nextDueAtMs", "reason",
            "token", "cancellingToken", "phase", "armedAtMs", "error")
        private fun keys(value: JSONObject): Set<String> = value.keys().asSequence().toSet()
        private fun integer(value: Any): Long {
            require(value is Number)
            val result = when (value) {
                is Byte, is Short, is Int, is Long -> value.toLong()
                is Float, is Double -> {
                    val number = value.toDouble()
                    require(number.isFinite() && number >= 0 && number < 9_223_372_036_854_775_808.0 && number % 1.0 == 0.0)
                    number.toLong()
                }
                else -> throw IllegalArgumentException("invalid_integer")
            }
            require(result >= 0)
            return result
        }
        private fun nullableInteger(value: JSONObject, key: String): Long? = if (value.get(key) === JSONObject.NULL) null else integer(value.get(key))
        private fun nullableString(value: JSONObject, key: String): String? {
            val raw = value.get(key)
            if (raw === JSONObject.NULL) return null
            require(raw is String)
            return raw
        }
    }
}
