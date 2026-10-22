package com.minnnng.dsh_android

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.webkit.*
import android.widget.FrameLayout
import android.widget.TextView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayInputStream
import java.util.UUID

/** A document surface, not a browser: no listener, file URLs, external network or unrestricted JS interface. */
class DocumentPreviewFactory(
    private val send: (JSONObject, MethodChannel.Result) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private val views = mutableSetOf<DocumentPreviewView>()
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val options = JSONObject(args as? Map<*, *> ?: emptyMap<Any, Any>())
        return DocumentPreviewView(context, options, send) { views.remove(it) }.also { views.add(it) }
    }
    fun receive(frame: JSONObject) { views.toList().forEach { it.receive(frame) } }
    fun disconnected() { views.toList().forEach { it.disconnected() } }
    fun close() { views.toList().forEach { it.dispose() }; views.clear() }
}

private class DocumentPreviewView(
    context: Context,
    private val options: JSONObject,
    private val send: (JSONObject, MethodChannel.Result) -> Unit,
    private val onDispose: (DocumentPreviewView) -> Unit,
) : PlatformView {
    private val container = FrameLayout(context)
    private val web = WebView(context)
    private val prefix = UUID.randomUUID().toString() + ":"
    private val requests = mutableSetOf<String>()
    private val leases = mutableSetOf<String>()
    private val requestLeases = mutableMapOf<String, String>()
    private val subscriptions = mutableMapOf<String, JavaScriptReplyProxy>()
    private var destroyed = false
    private var failed = false
    private var webDestroyed = false
    private var listenerRegistered = false
    private val session = options.getString("sessionId")
    private val media = DocumentPreviewMedia(session, send)
    private val assets = WebViewAssetLoader.AssetsPathHandler(context)
    private val loader = WebViewAssetLoader.Builder()
        .addPathHandler("/document/") { path -> assets.handle("document-preview/$path") }.build()

    init {
        require(session.isNotBlank() && session.length <= 256)
        require(options.getString("path").length <= 8192)
        web.setBackgroundColor(runCatching { Color.parseColor(options.optString("background")) }.getOrDefault(Color.TRANSPARENT))
        container.addView(web, FrameLayout.LayoutParams(-1, -1))
        web.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
            domStorageEnabled = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
        web.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        }
        web.setDownloadListener { _, _, _, _, _ -> /* Export uses the native user-selected destination flow. */ }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                media.intercept(request)?.let { return it }
                if (!DocumentPreviewPolicy.asset(request.url.toString())) return denied()
                return loader.shouldInterceptRequest(request.url) ?: denied()
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.isForMainFrame && request.url.toString() != DocumentPreviewPolicy.ENTRY
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                showFailure("文档预览进程已退出，请返回后重新打开。", rendererGone = true)
                return true
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) showFailure("文档组件无法载入，请重新打开或更新应用。")
            }
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            showFailure("系统 WebView 版本不支持文档预览，请更新 Android System WebView。")
        } else {
            WebViewCompat.addWebMessageListener(web, "PocketDocument", setOf(DocumentPreviewPolicy.ORIGIN)) {
                    _, message, origin, mainFrame, reply ->
                if (!destroyed && !failed && DocumentPreviewPolicy.trustedOrigin(origin.toString(), mainFrame)) {
                    val raw = message.data
                    if (raw != null && raw.length <= 65536) accept(raw, reply)
                }
            }
            listenerRegistered = true
            web.loadUrl(DocumentPreviewPolicy.ENTRY)
        }
    }

    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    private fun reply(proxy: JavaScriptReplyProxy, value: JSONObject) {
        if (!destroyed && !failed) runCatching { proxy.postMessage(value.toString()) }
    }
    private fun error(proxy: JavaScriptReplyProxy, id: String, message: String) =
        reply(proxy, JSONObject().put("id", id).put("error", JSONObject().put("code", "document/bridge").put("message", message)))

    private fun accept(raw: String, proxy: JavaScriptReplyProxy) {
        var id = ""
        try {
            val message = JSONObject(raw)
            id = message.getString("id")
            require(DocumentPreviewPolicy.identity(id)) { "Invalid document request identity" }
            when (message.getString("kind")) {
                "ready" -> reply(proxy, JSONObject().put("id", id).put("result", options))
                "external" -> {
                    val url = message.getString("url")
                    require(DocumentPreviewPolicy.external(url)) { "Unsupported external document link" }
                    try {
                        container.context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .addCategory(Intent.CATEGORY_BROWSABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        reply(proxy, JSONObject().put("id", id).put("result", JSONObject().put("opened", true)))
                    } catch (failure: android.content.ActivityNotFoundException) {
                        android.widget.Toast.makeText(container.context, "没有可打开此链接的浏览器", android.widget.Toast.LENGTH_SHORT).show()
                        error(proxy, id, "没有可打开此链接的浏览器")
                    }
                }
                "call" -> {
                    val namespace = message.getString("namespace")
                    val method = message.getString("method")
                    require(DocumentPreviewPolicy.callable(namespace, method)) { "Unsupported document operation" }
                    val args = boundArgs(message.optJSONObject("args") ?: JSONObject(), removeScope = true)
                    require(requests.size < 32 && requests.add(id)) { "Too many or duplicate document requests" }
                    invoke("document.call", JSONObject().put("requestId", prefix + id).put("sessionId", session)
                        .put("namespace", namespace).put("method", method).put("args", args)) { value, failure ->
                        val active = requests.remove(id)
                        val lease = (value as? JSONObject)?.optJSONObject("value")?.optJSONObject("data")
                            ?.takeIf { it.optString("encoding") == "android-byte-lease" }?.optString("id")
                        if (!lease.isNullOrEmpty()) {
                            if (!active || destroyed || failed) release(lease) else {
                                leases.add(lease)
                                requestLeases[id] = lease
                            }
                        }
                        if (active) deliver(proxy, id, value, failure)
                    }
                }
                "cancel" -> {
                    val target = message.getString("requestId")
                    require(DocumentPreviewPolicy.identity(target))
                    requests.remove(target)
                    requestLeases.remove(target)?.let { leases.remove(it) }
                    // The result may already be queued to JS when its AbortSignal
                    // fires. Runtime cancellation also revokes that completed lease.
                    invoke("document.cancel", JSONObject().put("requestId", prefix + target)) { value, failure ->
                        deliver(proxy, id, value, failure)
                    }
                }
                "bytes" -> {
                    val lease = message.getString("leaseId")
                    require(leases.contains(lease)) { "Document bytes are no longer available" }
                    val length = message.getInt("length")
                    val offset = message.getLong("offset")
                    require(length in 1..262144 && offset >= 0)
                    invoke("document.bytes", JSONObject().put("id", lease).put("offset", offset).put("length", length)) { value, failure ->
                        deliver(proxy, id, value, failure)
                    }
                }
                "release" -> {
                    val lease = message.getString("leaseId")
                    requestLeases.entries.removeAll { it.value == lease }
                    if (leases.remove(lease)) release(lease)
                    reply(proxy, JSONObject().put("id", id).put("result", JSONObject().put("ok", true).put("value", JSONObject().put("released", true))))
                }
                "subscribe" -> subscribe(id, message, proxy)
                "unsubscribe" -> {
                    unsubscribe(message.getString("requestId"))
                    reply(proxy, JSONObject().put("id", id).put("result", JSONObject().put("closed", true)))
                }
                "ack" -> {
                    val target = message.getString("requestId")
                    if (subscriptions.containsKey(target)) invoke("api.ack", JSONObject().put("subscriptionId", prefix + target)
                        .put("generation", message.getString("generation")).put("sequence", message.getLong("sequence"))) { _, _ -> }
                    reply(proxy, JSONObject().put("id", id).put("result", JSONObject().put("accepted", true)))
                }
                else -> error(proxy, id, "Unsupported document message")
            }
        } catch (failure: Exception) { error(proxy, id, failure.message ?: "Invalid document request") }
    }

    private fun boundArgs(input: JSONObject, removeScope: Boolean): JSONObject {
        val args = JSONObject(input.toString())
        for (key in listOf("workspaceFileScopeId", "sessionId")) {
            if (args.has(key)) require(args.getString(key) == session) { "Document belongs to another Session" }
            args.remove(key)
        }
        if (!removeScope) args.put("workspaceFileScopeId", session)
        return args
    }

    private fun subscribe(id: String, message: JSONObject, proxy: JavaScriptReplyProxy) {
        require(message.getString("namespace") == "workspaceFiles" && message.getString("method") == "changes")
        val args = boundArgs(message.optJSONObject("args") ?: JSONObject(), removeScope = false)
        require(args.keys().asSequence().all { it == "path" || it == "workspaceFileScopeId" })
        require(subscriptions.size < 16 && !subscriptions.containsKey(id))
        subscriptions[id] = proxy
        invoke("api.subscribe", JSONObject().put("subscriptionId", prefix + id).put("namespace", "workspaceFiles")
            .put("method", "changes").put("args", args)) { value, failure ->
            if (destroyed || failed || !subscriptions.containsKey(id)) {
                invoke("api.unsubscribe", JSONObject().put("subscriptionId", prefix + id)) { _, _ -> }
            } else if (failure != null) {
                subscriptions.remove(id)
                error(proxy, id, failure)
            } else reply(proxy, JSONObject().put("id", id).put("subscribed", value))
        }
    }

    fun receive(frame: JSONObject) {
        if (destroyed || failed || frame.optString("method") != "api.stream") return
        val value = frame.optJSONObject("params") ?: return
        val remoteId = value.optString("subscriptionId")
        if (!remoteId.startsWith(prefix)) return
        val id = remoteId.removePrefix(prefix)
        val proxy = subscriptions[id] ?: return
        when (value.optString("type")) {
            "item" -> reply(proxy, JSONObject().put("id", id).put("event", value.get("value"))
                .put("generation", value.getString("generation")).put("sequence", value.getLong("sequence")))
            "end" -> { subscriptions.remove(id); reply(proxy, JSONObject().put("id", id).put("done", true)) }
            "error" -> { subscriptions.remove(id); reply(proxy, JSONObject().put("id", id).put("error", value.get("error"))) }
        }
    }

    private fun invoke(method: String, params: JSONObject, complete: (Any?, String?) -> Unit) {
        send(JSONObject().put("method", method).put("params", params), object : MethodChannel.Result {
            override fun success(result: Any?) {
                val value = runCatching { JSONTokener(result as String).nextValue() }
                if (value.isSuccess) complete(value.getOrNull(), null) else complete(null, "文档服务返回了无法识别的内容")
            }
            override fun error(code: String, message: String?, details: Any?) { complete(null, message ?: code) }
            override fun notImplemented() { complete(null, "文档服务尚未就绪") }
        })
    }
    private fun deliver(proxy: JavaScriptReplyProxy, id: String, value: Any?, failure: String?) {
        if (failure != null) error(proxy, id, failure)
        else reply(proxy, JSONObject().put("id", id).put("result", value ?: JSONObject.NULL))
    }
    private fun release(id: String) { invoke("document.release", JSONObject().put("id", id)) { _, _ -> } }
    private fun unsubscribe(id: String) {
        if (subscriptions.remove(id) != null) invoke("api.unsubscribe", JSONObject().put("subscriptionId", prefix + id)) { _, _ -> }
    }
    private fun cancelAll() {
        media.close()
        requests.toList().forEach { invoke("document.cancel", JSONObject().put("requestId", prefix + it)) { _, _ -> } }
        requests.clear()
        subscriptions.keys.toList().forEach(::unsubscribe)
        leases.toList().forEach(::release)
        leases.clear()
        requestLeases.clear()
    }
    private fun destroyWeb(rendererGone: Boolean = false) {
        if (webDestroyed) return
        webDestroyed = true
        container.removeView(web)
        // A terminated renderer must be destroyed, never used for another load.
        if (!rendererGone) {
            if (listenerRegistered) WebViewCompat.removeWebMessageListener(web, "PocketDocument")
            web.stopLoading()
        }
        web.destroy()
    }
    private fun showFailure(message: String, rendererGone: Boolean = false) {
        if (destroyed || failed) return
        failed = true
        cancelAll()
        destroyWeb(rendererGone)
        container.addView(TextView(container.context).apply {
            text = message
            setTextColor(runCatching { Color.parseColor(options.optString("foreground")) }.getOrDefault(Color.DKGRAY))
            textSize = 16f
            gravity = android.view.Gravity.CENTER
            setPadding(24, 24, 24, 24)
        }, FrameLayout.LayoutParams(-1, -1))
    }
    fun disconnected() { showFailure("本地服务连接已变化，请返回后重新打开文档。") }
    override fun getView(): View = container
    override fun dispose() {
        if (destroyed) return
        destroyed = true
        cancelAll()
        destroyWeb()
        container.removeAllViews()
        onDispose(this)
    }
}
