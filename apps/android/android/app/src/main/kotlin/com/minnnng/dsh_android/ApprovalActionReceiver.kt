package com.minnnng.dsh_android

import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import org.json.JSONObject

/**
 * Manifest receiver must be exported=false. It binds only an existing Agent
 * service and never starts a new Agent/foreground service to replay an old action.
 */
class ApprovalActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ApprovalNotifications.RESPOND_ACTION) return
        val id = intent.getStringExtra(ApprovalNotifications.ID_EXTRA) ?: return
        val version = intent.getLongExtra(ApprovalNotifications.VERSION_EXTRA, -1)
        val token = intent.getStringExtra(ApprovalNotifications.TOKEN_EXTRA) ?: return
        val action = intent.getStringExtra(ApprovalNotifications.ACTION_EXTRA) ?: return
        if (id.isBlank() || version < 0 || token.isBlank() || action.isBlank()) return
        val uri = intent.data ?: return
        if (uri.scheme != "pocket-harness" || uri.authority != "interaction" ||
            uri.pathSegments != listOf(id, version.toString(), action, token)) return
        val payload = JSONObject().put("id", id).put("version", version)
            .put("token", token).put("actionId", action)
        RemoteInput.getResultsFromIntent(intent)?.getCharSequence(ApprovalNotifications.REPLY_KEY)
            ?.let { payload.put("text", it.toString()) }
        val pending = goAsync()
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        var bound = false
        var finished = false
        var sent = false
        lateinit var connection: ServiceConnection
        lateinit var timeout: Runnable
        fun finish() {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            if (bound) {
                try {
                    app.unbindService(connection)
                } catch (error: IllegalArgumentException) {
                    // The framework already removed this binding after process death.
                }
                bound = false
            }
            pending.finish()
        }
        fun unavailable() {
            if (!sent) showUnavailable(app, id)
            finish()
        }
        timeout = Runnable { unavailable() }
        val reply = Messenger(Handler(Looper.getMainLooper()) {
            // The service updates the notification after its authoritative response;
            // the receiver only owns this short-lived binding.
            finish()
            true
        })
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (finished) return
                if (binder == null) {
                    unavailable()
                    return
                }
                try {
                    val data = WirePayload.encode(payload.toString())
                    try {
                        Messenger(binder).send(Message.obtain(null, ApprovalNotifications.MESSAGE_RESPOND).apply {
                            replyTo = reply
                            this.data = data
                        })
                        sent = true
                    } finally {
                        WirePayload.close(data)
                    }
                } catch (error: RemoteException) {
                    unavailable()
                } catch (error: IllegalArgumentException) {
                    unavailable()
                } catch (error: android.system.ErrnoException) {
                    unavailable()
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) = unavailable()
            override fun onNullBinding(name: ComponentName?) = unavailable()
            override fun onBindingDied(name: ComponentName?) = unavailable()
        }
        // The deadline releases the BroadcastReceiver, not the DSH request or its
        // response. The service continues to await its own core acknowledgement.
        main.postDelayed(timeout, 8000)
        try {
            bound = app.bindService(Intent(app, AgentService::class.java), connection, 0)
            if (!bound) unavailable()
        } catch (error: SecurityException) {
            unavailable()
        } catch (error: IllegalStateException) {
            unavailable()
        }
    }

    private fun showUnavailable(context: Context, id: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val previous = manager.activeNotifications.firstOrNull {
            it.tag == ApprovalNotifications.tag(id) && it.id == ApprovalNotifications.NOTIFICATION_ID
        } ?: return
        previous.notification.actions?.forEach { it.actionIntent?.cancel() }
        val text = "Agent 服务不可用，请打开 App 查看请求状态"
        val notification = Notification.Builder.recoverBuilder(context, previous.notification)
            .setActions()
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOnlyAlertOnce(true)
            .build()
        try {
            manager.notify(previous.tag, previous.id, notification)
        } catch (error: SecurityException) {
            // Revoked notification permission leaves the App as the remaining entry point.
        }
    }
}
