package com.minnnng.dsh_android

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Alarm delivery starts the existing runtime; only the original schedule domain submits work. */
class ScheduleWakeupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try { receive(context, intent) }
        catch (_: Exception) { android.util.Log.w("PocketHarness", "Schedule wake reception was not confirmed") }
    }

    private fun receive(context: Context, intent: Intent) {
        val owner = ScheduleWakeup.get(context)
        if (intent.action == ScheduleWakeup.ACTION_WAKE) {
            val uri = intent.data ?: return
            if (uri.scheme != "dsh-schedule" || uri.authority != "wake" || uri.pathSegments.size != 1 ||
                uri.query != null || uri.fragment != null) return
            owner.wake(uri.pathSegments.single())
        } else if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
            owner.restore()
        }
    }
}
