package com.minnnng.dsh_android

import android.app.AppOpsManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import org.json.JSONObject

/** Agent-process window ownership. No Activity, touch, focus, screen wake, or service restart. */
class TaskOverlayWindow(private val service: Service, initialEnabled: Boolean) {
    companion object {
        fun permissionIntent(context: Context): Intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.fromParts("package", context.packageName, null))
    }

    private val manager = service.getSystemService(WindowManager::class.java)
    private val appOps = service.getSystemService(AppOpsManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var window: View? = null
    private var enabled = initialEnabled
    private var working = false
    private var granted: Boolean? = null
    private var closed = false
    private var watching = false
    private var watchRemovalUnconfirmed = false
    private var monitorError: String? = null
    private val lease = OverlayLease(object : OverlayLease.WindowHost {
        override fun attach(observer: OverlayLease.Attachment) {
            check(window == null)
            val view = View(service).apply {
                setBackgroundColor(Color.TRANSPARENT)
                isFocusable = false
                isClickable = false
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                    override fun onViewAttachedToWindow(view: View) = observer.attached()
                    override fun onViewDetachedFromWindow(view: View) = observer.detached()
                })
            }
            window = view
            val params = WindowManager.LayoutParams(
                1, 1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT).apply {
                gravity = Gravity.TOP or Gravity.START
                x = 0
                y = 0
                alpha = 0f
                dimAmount = 0f
                windowAnimations = 0
                softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN or
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
                setTitle("Pocket Harness task overlay")
            }
            manager.addView(view, params)
        }

        override fun remove() {
            val view = window ?: return
            try {
                manager.removeViewImmediate(view)
            } catch (_: IllegalArgumentException) {
                // addView may have failed before WindowManager took ownership.
                check(!view.isAttachedToWindow) { "Overlay removal not confirmed" }
            }
            window = null
        }
    })
    private val permissionChanged = AppOpsManager.OnOpChangedListener { op, packageName ->
        if ((op == null || op == AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW) &&
            (packageName == null || packageName == service.packageName)) {
            main.post { if (!closed) refresh() }
        }
    }

    init {
        if (enabled) observePermission()
        refresh()
    }

    private fun observePermission() {
        if (watching || closed) return
        if (watchRemovalUnconfirmed) {
            try {
                appOps.stopWatchingMode(permissionChanged)
                watchRemovalUnconfirmed = false
            } catch (_: Exception) {
                monitorError = "permission-monitor-unavailable"
                return
            }
        }
        try {
            appOps.startWatchingMode(AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW,
                service.packageName, permissionChanged)
            watching = true
            monitorError = null
        } catch (_: Exception) {
            // Without revocation observation no optional window is created.
            monitorError = "permission-monitor-unavailable"
        }
    }

    private fun stopObservingPermission() {
        if (!watching && !watchRemovalUnconfirmed) return
        try {
            appOps.stopWatchingMode(permissionChanged)
            watching = false
            watchRemovalUnconfirmed = false
            monitorError = null
        } catch (_: Exception) {
            // Unknown registration state must not authorize a new window.
            watching = false
            watchRemovalUnconfirmed = true
            monitorError = "permission-monitor-unavailable"
        }
    }

    fun configure(value: Boolean) {
        if (closed) return
        val retry = enabled && value
        enabled = value
        if (value) observePermission()
        else stopObservingPermission()
        refresh()
        if (retry) lease.retry()
    }

    fun update(activeWork: Boolean) {
        if (closed) return
        working = activeWork
        refresh()
    }

    private fun refresh() {
        granted = try { Settings.canDrawOverlays(service) } catch (_: Exception) { null }
        lease.update(enabled, granted == true && watching, working)
    }

    fun status(): JSONObject {
        if (!closed) refresh()
        return JSONObject()
            .put("enabled", enabled)
            .put("permissionGranted", granted ?: JSONObject.NULL)
            .put("activeWork", working)
            .put("attached", lease.attached())
            .put("state", if ((monitorError != null || granted == null) && enabled) "failed" else lease.status())
            .put("error", monitorError ?: if (granted == null) "permission-check-unavailable"
                else lease.failure() ?: JSONObject.NULL)
    }

    fun close() {
        if (closed) return
        closed = true
        stopObservingPermission()
        // A late permission callback is fenced by closed; teardown must still run.
        lease.close()
    }
}
