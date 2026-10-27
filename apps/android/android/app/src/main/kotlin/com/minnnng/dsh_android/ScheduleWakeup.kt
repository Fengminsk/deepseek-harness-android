package com.minnnng.dsh_android

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.UserManager
import org.json.JSONObject
import java.util.UUID

/** One owner in :agent; the main Activity never reads or writes this projection. */
class ScheduleWakeup private constructor(private val context: Context) {
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val preferences = context.getSharedPreferences("schedule-wakeup", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val lease = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PocketHarness:schedule-handoff")
        .apply { setReferenceCounted(false) }
    private var leaseToken: String? = null
    private var serviceGeneration: String? = null
    private var background: JSONObject? = null
    private val controller = ScheduleWakeupController(object : ScheduleWakeupController.Platform {
        override fun read(): JSONObject? = preferences.getString("state", null)?.let {
            require(it.length <= 8192) { "schedule_state_too_large" }
            JSONObject(it)
        }
        override fun write(value: JSONObject) {
            check(preferences.edit().putString("state", value.toString()).commit()) { "schedule_state_not_saved" }
        }
        override fun cancel(token: String) {
            val pending = PendingIntent.getBroadcast(context, 0, alarmIntent(context, token),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
            alarms.cancel(pending)
            pending.cancel()
        }
        override fun arm(token: String, atMillis: Long) {
            val pending = PendingIntent.getBroadcast(context, 0, alarmIntent(context, token),
                PendingIntent.FLAG_IMMUTABLE)
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        }
        override fun allowed(): Boolean = permissionGranted(context)
        override fun now(): Long = System.currentTimeMillis()
        override fun token(): String = UUID.randomUUID().toString()
    })
    private val expire = Runnable {
        synchronized(this) {
            try { leaseToken?.let { recordWakeFailure(it, "handoff_timeout") } }
            finally { releaseLease() }
        }
    }

    @Synchronized fun bind(generation: String) {
        serviceGeneration = generation
        background = null
        controller.bind(generation)
    }

    @Synchronized fun unbind(generation: String) {
        controller.unbind(generation)
        if (serviceGeneration == generation) {
            serviceGeneration = null
            try { leaseToken?.let { recordWakeFailure(it, "service_stopped") } }
            finally { releaseLease() }
        }
    }

    @Synchronized fun begin(): JSONObject = controller.begin()

    /** Terminal runtime failure settles this generation's handoff before process teardown. */
    @Synchronized fun runtimeFailed(generation: String) {
        ScheduleWakeupHandoff.fail(generation, serviceGeneration, leaseToken,
            { token -> recordWakeFailure(token, "runtime_unavailable") }, ::releaseLease)
    }

    @Synchronized fun update(params: JSONObject): JSONObject {
        return controller.update(params)
    }

    @Synchronized fun status(): JSONObject = controller.status()
        .put("handoffWakeLockHeld", lease.isHeld)

    @Synchronized fun configure(enabled: Boolean): JSONObject {
        val result = controller.configure(enabled)
        if (!enabled) releaseLease()
        return result.put("handoffWakeLockHeld", lease.isHeld)
    }

    @Synchronized fun restore() {
        if (context.getSystemService(UserManager::class.java).isUserUnlocked) controller.restore()
    }

    /** Called only by the immutable alarm receiver, never by a model-facing RPC. */
    @Synchronized fun wake(token: String) {
        if (!context.getSystemService(UserManager::class.java).isUserUnlocked) return
        if (!controller.claim(token)) return
        try {
            check(RecoveryRuntime(context).mode()[0] == "active") { "maintenance_mode" }
            releaseLease()
            leaseToken = token
            lease.acquire(HANDOFF_MILLIS)
            main.postDelayed(expire, HANDOFF_MILLIS)
            context.startForegroundService(Intent(context, AgentService::class.java)
                .setAction(ACTION_WAKE).putExtra(EXTRA_TOKEN, token))
        } catch (_: Exception) {
            try { recordWakeFailure(token, "service_start_failed") }
            finally { releaseLease() }
        }
    }

    @Synchronized fun acceptWake(token: String): Boolean {
        val accepted = controller.acceptWake(token) &&
            try { RecoveryRuntime(context).mode()[0] == "active" } catch (_: Exception) { false }
        if (!accepted && leaseToken == token) releaseLease()
        return accepted
    }

    /** Do not release the startup lease before the normal task CPU lease is observed. */
    @Synchronized fun observeBackground(value: JSONObject) {
        background = value
        settleLease()
    }

    private fun settleLease() {
        if (leaseToken == null) return
        val state = controller.status()
        val taskState = background ?: return
        if (!taskState.optBoolean("fresh")) return
        if (state.optString("projectionState") != "ready") return
        val stillDue = !state.isNull("nextDueAtMs") && state.getLong("nextDueAtMs") <= System.currentTimeMillis()
        if (stillDue) return
        // A queued/running task can proceed only under its own configured lease.
        // An idle summary means the original scheduler no longer owes a due task.
        if (taskState.optBoolean("wakeLockHeld") || taskState.optString("taskState") in setOf("idle", "attention")) {
            releaseLease()
        }
    }

    private fun releaseLease() {
        main.removeCallbacks(expire)
        leaseToken = null
        if (lease.isHeld) lease.release()
    }

    private fun recordWakeFailure(token: String, reason: String) {
        try { controller.wakeFailed(token, reason) }
        catch (_: Exception) { android.util.Log.w("PocketHarness", "Schedule wake failure could not be persisted") }
    }

    companion object {
        const val ACTION_WAKE = "com.minnnng.dsh_android.SCHEDULE_WAKE"
        const val EXTRA_TOKEN = "scheduleToken"
        private const val HANDOFF_MILLIS = 120_000L
        @Volatile private var instance: ScheduleWakeup? = null
        fun get(context: Context): ScheduleWakeup = instance ?: synchronized(this) {
            instance ?: ScheduleWakeup(context.applicationContext).also { instance = it }
        }
        fun permissionGranted(context: Context): Boolean = Build.VERSION.SDK_INT < 31 ||
            context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
        fun permissionIntent(context: Context): Intent = Intent(
            android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
            Uri.fromParts("package", context.packageName, null))
        private fun alarmIntent(context: Context, token: String) = Intent(context, ScheduleWakeupReceiver::class.java)
            .setAction(ACTION_WAKE).setData(Uri.Builder().scheme("dsh-schedule").authority("wake").appendPath(token).build())
    }
}
