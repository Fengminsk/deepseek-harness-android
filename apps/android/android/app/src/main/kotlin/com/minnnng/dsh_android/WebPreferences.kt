package com.minnnng.dsh_android

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import org.json.JSONArray
import org.json.JSONObject

/** Native-only access preferences; browser configuration has no reference to this store. */
class WebPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("web-access", Context.MODE_PRIVATE)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    fun get() = JSONObject().put("enabled", preferences.getBoolean("enabled", false))
        .put("scope", preferences.getString("scope", "local")).put("port", preferences.getInt("port", 3080))
    fun save(value: JSONObject): Boolean {
        val scope = value.getString("scope")
        val port = value.getInt("port")
        require(scope == "local" || scope == "lan") { "Invalid Web scope" }
        require(port in 1024..65535) { "Invalid Web port" }
        check(preferences.edit().putBoolean("enabled", value.getBoolean("enabled"))
            .putString("scope", scope).putInt("port", port).commit()) { "Web preferences were not saved" }
        return true
    }
    @Suppress("DEPRECATION")
    fun addresses(): JSONObject {
        val addresses = connectivity.allNetworks.flatMap { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
            if (capabilities == null || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                || !(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))) emptyList()
            else connectivity.getLinkProperties(network)?.linkAddresses.orEmpty().map { it.address }
                .filterIsInstance<Inet4Address>().filter { it.isSiteLocalAddress && !it.isLoopbackAddress }
                .mapNotNull { it.hostAddress }
        }.distinct().sorted()
        return JSONObject().put("addresses", JSONArray(addresses))
    }
}
