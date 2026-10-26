package com.minnnng.dsh_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Settings
import android.system.Os
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** App-process preferences; each replacement Agent reads a fresh process snapshot. */
class NetworkProxyPreferences(private val context: Context) {
    private val preferences = context.getSharedPreferences("network-proxy", Context.MODE_PRIVATE)

    private fun checked(value: JSONObject): JSONObject {
        val mode = value.getString("mode")
        val rawPort = value.get("port")
        require(rawPort is Int) { "代理端口须为整数" }
        NetworkProxyPolicy.validate(mode, rawPort)
        val tool = value.optString("tool", "")
        require(tool.length <= 256 && (tool.isEmpty() || Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+").matches(tool)))
        return JSONObject().put("mode", mode).put("port", rawPort).put("tool", tool)
    }

    private fun configuration(): JSONObject {
        val raw = preferences.getString("value", null)
        return if (raw == null) JSONObject().put("mode", "system").put("port", 7890).put("tool", "")
        else checked(JSONObject(raw))
    }

    fun read(): JSONObject = resolve(configuration()).put("tools", tools())
    fun route(): JSONObject = resolve(configuration()).getJSONObject("route")

    fun save(value: JSONObject): JSONObject {
        val config = checked(value)
        check(preferences.edit().putString("value", config.toString()).commit()) { "代理配置未保存" }
        return resolve(config).put("tools", tools())
    }

    private fun resolve(config: JSONObject): JSONObject {
        val mode = config.getString("mode")
        val route = JSONObject().put("mode", mode)
        if (mode == "local") {
            route.put("url", NetworkProxyPolicy.localUrl(config.getInt("port")))
        } else {
            // No App HTTP override. Android still routes these sockets through an active VPN.
            route.put("url", JSONObject.NULL)
        }
        return JSONObject(config.toString()).put("route", route)
    }

    /** Captured once before Node launch, never mutated underneath active tasks. */
    fun installEnvironment(): JSONObject {
        val snapshot = resolve(configuration())
        val route = snapshot.getJSONObject("route")
        check(!route.has("error")) { route.optString("error") }
        val url = route.optString("url").takeIf { it.isNotEmpty() && it != "null" }
        NetworkProxyPolicy.environment(url).forEach { (name, value) -> Os.setenv(name, value, true) }
        return snapshot
    }

    @Suppress("DEPRECATION")
    private fun tools(): JSONArray {
        val manager = context.packageManager
        // VPN intent discovery omits private services and also matches unrelated
        // apps. Package-scoped visibility admits only the supported launchers.
        val values = NetworkProxyPolicy.supportedTools().mapNotNull { id ->
            try {
                if (manager.getLaunchIntentForPackage(id) == null) return@mapNotNull null
                val app = manager.getApplicationInfo(id, 0)
                JSONObject().put("id", id).put("name", app.loadLabel(manager).toString().take(100))
                    .apply { toolIcon(app)?.let { put("icon", it) } }
            } catch (_: PackageManager.NameNotFoundException) { null }
        }
        return JSONArray().apply { values.forEach { put(it) } }
    }

    /** Small, local launcher images; no URI or network request crosses the bridge. */
    private fun toolIcon(app: ApplicationInfo): String? {
        val image = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        return try {
            val drawable = app.loadIcon(context.packageManager)
            drawable.setBounds(0, 0, image.width, image.height)
            drawable.draw(Canvas(image))
            val encoded = ByteArrayOutputStream()
            if (!image.compress(Bitmap.CompressFormat.PNG, 100, encoded) || encoded.size() > 65536) null
            else Base64.encodeToString(encoded.toByteArray(), Base64.NO_WRAP)
        } catch (_: RuntimeException) { null }
        finally { image.recycle() }
    }

    fun openTool(activity: Activity, packageName: String) {
        if (packageName.isEmpty()) {
            activity.startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
            return
        }
        require(packageName in NetworkProxyPolicy.supportedTools()) {
            "该代理工具已卸载或无法打开，请重新选择"
        }
        val launch = context.packageManager.getLaunchIntentForPackage(packageName)
            ?: throw IllegalStateException("该代理工具已卸载或无法打开，请重新选择")
        activity.startActivity(launch)
    }

    fun test(value: JSONObject): JSONObject {
        val route = resolve(checked(value)).getJSONObject("route")
        check(!route.has("error")) { route.optString("error") }
        val url = route.optString("url").takeIf { it.isNotEmpty() && it != "null" }
        val proxy = if (url == null) Proxy.NO_PROXY else URIProxy(url)
        val start = System.nanoTime()
        val connection = URL("https://www.gstatic.com/generate_204").openConnection(proxy) as HttpURLConnection
        try {
            connection.connectTimeout = 7000
            connection.readTimeout = 7000
            connection.instanceFollowRedirects = false
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", "PocketHarness-NetworkCheck")
            val status = connection.responseCode
            check(status == 204) { "HTTPS 测试返回 $status，未确认连接可用" }
            return JSONObject().put("milliseconds", (System.nanoTime() - start) / 1_000_000)
                .put("host", "www.gstatic.com").put("route", route)
        } finally { connection.disconnect() }
    }

    private fun URIProxy(url: String): Proxy {
        val parsed = java.net.URI(url)
        return Proxy(Proxy.Type.HTTP, InetSocketAddress(parsed.host, parsed.port))
    }

    companion object {
        // Probes cannot occupy the serialized local preference writer.
        private val probe = Executors.newSingleThreadExecutor { task -> Thread(task, "dsh-proxy-test") }
        private val main = Handler(Looper.getMainLooper())
        fun testAsync(context: Context, value: JSONObject, result: MethodChannel.Result) {
            probe.execute {
                try {
                    val checked = NetworkProxyPreferences(context).test(value)
                    main.post { result.success(checked.toString()) }
                } catch (failure: Exception) {
                    main.post { result.error("proxy-test", failure.message ?: "连接测试失败", null) }
                }
            }
        }
    }
}
