package com.minnnng.dsh_android

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import java.util.UUID

/** Release-acceptance source set only: no Flutter engine, AgentService or Node startup. */
class RuntimeAcceptanceActivity : Activity() {
    private var token: String? = null
    private var registered = false
    private val permission get() = "$packageName.permission.RUNTIME_ACCEPTANCE"
    private val closeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "$packageName.acceptance.foreground.close" &&
                intent.getStringExtra("token") == token) finishAndRemoveTask()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val supplied = intent.getStringExtra("token")
        if (supplied == null || try { UUID.fromString(supplied).toString() != supplied } catch (_: Exception) { true }) {
            finishAndRemoveTask()
            return
        }
        token = supplied
        val filter = IntentFilter("$packageName.acceptance.foreground.close")
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(closeReceiver, filter, permission, null, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(closeReceiver, filter, permission, null)
        registered = true
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.attributes = window.attributes.apply {
            screenBrightness = 0f
            layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= 30)
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        setContentView(View(this).apply { setBackgroundColor(Color.BLACK) })
        hideSystemBars()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        if (token != null) status("ready")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.apply {
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsets.Type.systemBars())
            }
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    override fun onDestroy() {
        if (registered) unregisterReceiver(closeReceiver)
        if (token != null) status("closed")
        super.onDestroy()
    }

    private fun status(state: String) {
        sendBroadcast(Intent("$packageName.acceptance.foreground.status").setPackage(packageName)
            .putExtra("token", token).putExtra("state", state), permission)
    }
}
