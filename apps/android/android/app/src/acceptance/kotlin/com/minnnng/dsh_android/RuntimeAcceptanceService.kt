package com.minnnng.dsh_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock

/** Acceptance source set only. Holds CPU scheduling without opening a window or starting a runtime. */
class RuntimeAcceptanceService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wake: PowerManager.WakeLock? = null
    private var registered = false
    private val permission get() = "$packageName.permission.RUNTIME_ACCEPTANCE"
    private val owner = AcceptanceServiceOwner(object : AcceptanceServiceOwner.Port {
        override fun startForeground() {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "运行时验收", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null); enableVibration(false); enableLights(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            })
            val notification = Notification.Builder(this@RuntimeAcceptanceService, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setContentTitle("运行时验收中").setOngoing(true).setOnlyAlertOnce(true)
                .setShowWhen(false).setCategory(Notification.CATEGORY_SERVICE)
                .setVisibility(Notification.VISIBILITY_SECRET).build()
            if (Build.VERSION.SDK_INT >= 34)
                startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            else startForeground(NOTIFICATION, notification)
        }
        override fun acquireCpu(timeoutMillis: Long) {
            val acquired = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:runtime-acceptance")
            wake = acquired
            acquired.setReferenceCounted(false)
            acquired.acquire(timeoutMillis)
        }
        override fun cpuHeld() = wake?.isHeld == true
        override fun releaseCpu() { wake?.let { if (it.isHeld) it.release() } }
        override fun stopForeground() { stopForeground(STOP_FOREGROUND_REMOVE) }
        override fun requestStop() { handler.removeCallbacksAndMessages(null); stopSelf() }
        override fun status(token: String, state: String, failure: String?) {
            sendBroadcast(Intent("$packageName.acceptance.service.status").setPackage(packageName)
                .putExtra("token", token).putExtra("state", state).putExtra("failure", failure)
                .putExtra("pid", android.os.Process.myPid()), permission)
        }
    })
    private val deadlineCheck = object : Runnable {
        override fun run() { owner.checkDeadline(SystemClock.elapsedRealtime()) }
    }
    private val closeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "$packageName.acceptance.service.close")
                intent.getStringExtra("token")?.let { owner.release(it) }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter("$packageName.acceptance.service.close")
        if (Build.VERSION.SDK_INT >= 33)
            registerReceiver(closeReceiver, filter, permission, null, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(closeReceiver, filter, permission, null)
        registered = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val duration = intent?.getLongExtra("durationMillis", 0) ?: 0
            owner.start(requireNotNull(intent?.getStringExtra("token")), duration, SystemClock.elapsedRealtime())
            handler.postDelayed(deadlineCheck, duration)
            handler.postDelayed(deadlineCheck, duration + AcceptanceServiceOwner.CLEANUP_GRACE_MILLIS)
        } catch (failure: Throwable) { owner.forceStop("Invalid acceptance service start: $failure") }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) { owner.forceStop("Android timed out the acceptance foreground service") }
    override fun onTimeout(startId: Int, fgsType: Int) { owner.forceStop("Android timed out acceptance foreground type $fgsType") }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (registered) { unregisterReceiver(closeReceiver); registered = false }
        super.onDestroy()
        owner.destroyed()
    }

    companion object {
        private const val CHANNEL = "runtime-acceptance"
        private const val NOTIFICATION = 0x445348
    }
}
