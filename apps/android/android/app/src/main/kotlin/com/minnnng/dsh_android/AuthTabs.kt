package com.minnnng.dsh_android

import android.app.Activity
import android.net.Uri
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import org.json.JSONObject
import java.net.URI

/** Official account pages keep browser-owned credentials separate from Flutter. */
object AuthTabs {
    fun open(activity: Activity, raw: String, dark: Boolean) {
        val uri = URI(raw)
        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null) {
            "账号页面必须使用 HTTPS 地址"
        }
        val browser = CustomTabsClient.getPackageName(activity, null)
            ?: throw IllegalStateException("未找到支持应用内授权页的浏览器，请安装或启用支持 Custom Tabs 的浏览器后重试")
        val tab = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
            .setColorScheme(if (dark) CustomTabsIntent.COLOR_SCHEME_DARK else CustomTabsIntent.COLOR_SCHEME_LIGHT)
            .build()
        tab.intent.setPackage(browser)
        tab.launchUrl(activity, Uri.parse(raw))
    }

    @Suppress("DEPRECATION")
    fun metadata(activity: Activity): String {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return JSONObject()
            .put("version", requireNotNull(info.versionName))
            .put("build", info.longVersionCode)
            .toString()
    }
}
