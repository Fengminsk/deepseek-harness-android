package com.minnnng.dsh_android

import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Serves original Markdown fileMediaUrl requests without opening Java files or a network listener.
 * Call intercept only on WebView's resource worker; Binder sends and replies remain on the main looper.
 * One instance is permanently bound to a Session. close cancels calls, revokes leases and rejects late work.
 */
class DocumentPreviewMedia(
    private val sessionId: String,
    private val send: (JSONObject, MethodChannel.Result) -> Unit,
) : AutoCloseable {
    private class MediaFailure(val status: Int, val code: String) : IOException(code)
    private class Pending(val requestId: String?) {
        val result = CompletableFuture<JSONObject>()
        var lease: String? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefix = UUID.randomUUID().toString() + ":media:"
    private val lock = Any()
    private val pending = mutableSetOf<Pending>()
    private val leases = mutableSetOf<String>()
    private val streams = mutableMapOf<String, DocumentPreviewMediaStream>()
    private var closed = false

    init { require(sessionId.isNotBlank() && sessionId.length <= 200) }

    /** Null means this is not the file route; the caller's asset policy still handles or refuses it. */
    fun intercept(request: WebResourceRequest): WebResourceResponse? {
        val url = request.url.toString()
        if (!DocumentPreviewMediaPolicy.targetsRoute(url)) return null
        if (Looper.myLooper() == Looper.getMainLooper()) return errorResponse(503, "document-media/worker-required", request.method == "HEAD")
        return try {
            val parsed = DocumentPreviewMediaPolicy.parse(url, request.method)
            ensureOpen()
            val policy = rpc("document.mediaPolicy", JSONObject().put("path", parsed.path()))
            val maximum = number(policy, "maxBytes")
            DocumentPreviewMediaPolicy.requireSize(0, maximum)
            val stat = call("stat", parsed.path())
            // workspaceFiles.stat admits regular files and returns bytes, not fs.stat's size/type fields.
            val size = if (stat.has("bytes")) number(stat, "bytes") else null
            if (size != null) DocumentPreviewMediaPolicy.requireSize(size, maximum)
            val absolutePath = stat.getString("absolutePath")
            val resolvedPolicy = if (absolutePath == parsed.path()) policy
                else rpc("document.mediaPolicy", JSONObject().put("path", absolutePath))
            val mimeType = resolvedPolicy.getString("mimeType")
            if (parsed.head()) {
                ensureOpen()
                response(200, mimeType, DocumentPreviewMediaPolicy.headers(mimeType, size), ByteArrayInputStream(ByteArray(0)))
            } else serveBytes(parsed.path(), mimeType, maximum)
        } catch (failure: DocumentPreviewMediaPolicy.Rejected) {
            errorResponse(failure.status, "document-media/request-refused", request.method == "HEAD")
        } catch (failure: MediaFailure) {
            errorResponse(failure.status, failure.code, request.method == "HEAD")
        } catch (failure: Exception) {
            // Do not log authored paths, content or exception messages containing either.
            Log.w("PocketDocumentMedia", "Media response failed: ${failure.javaClass.simpleName}")
            errorResponse(502, "document-media/invalid-response", request.method == "HEAD")
        }
    }

    private fun serveBytes(path: String, mimeType: String, maximum: Long): WebResourceResponse {
        val read = call("readBytes", path)
        val data = read.getJSONObject("data")
        val lease = data.getString("id")
        try {
            require(data.getString("encoding") == "android-byte-lease")
            val length = number(data, "length")
            DocumentPreviewMediaPolicy.requireSize(length, maximum)
            require(number(read, "offset") == 0L && read.getBoolean("eof"))
            val headers = DocumentPreviewMediaPolicy.headers(mimeType, length)
            val stream = DocumentPreviewMediaStream(length, { offset, count ->
                ensureWorker()
                val chunk = rpc("document.bytes", JSONObject().put("id", lease).put("offset", offset).put("length", count))
                if (number(chunk, "offset") != offset || chunk.getBoolean("eof") != (offset + count == length))
                    throw MediaFailure(502, "document-media/invalid-byte-frame")
                val encoded = chunk.getString("data")
                if (encoded.length > ((count + 2) / 3) * 4) throw MediaFailure(502, "document-media/oversized-byte-frame")
                Base64.decode(encoded, Base64.NO_WRAP)
            }, { release(lease) })
            synchronized(lock) {
                if (closed) { stream.close(); throw MediaFailure(499, "gateway/cancelled") }
                if (leases.contains(lease)) streams[lease] = stream
            }
            return response(200, mimeType, headers, stream)
        } catch (failure: Exception) {
            release(lease)
            throw failure
        }
    }

    private fun call(method: String, path: String): JSONObject {
        val id = prefix + UUID.randomUUID().toString()
        return rpc("document.call", JSONObject().put("requestId", id).put("sessionId", sessionId)
            .put("namespace", "workspaceFiles").put("method", method).put("args", JSONObject().put("path", path)))
    }

    /** Materializes one Session-scoped original file for a user-initiated system open. Worker thread only. */
    fun copyFile(path: String, output: OutputStream, maximum: Long): Long {
        ensureWorker()
        require(path.isNotBlank() && path.length <= 8192 && path.none { it.code < 32 || it.code == 127 })
        val initial = call("stat", path)
        val size = number(initial, "bytes")
        if (size > maximum) throw MediaFailure(413, "file-open/too-large")
        val version = initial.getString("version")
        val absolute = initial.getString("absolutePath")
        var offset = 0L
        var window = 128 * 1024
        while (offset < size || offset == 0L) {
            ensureWorker()
            var length: Int
            var page: JSONObject
            while (true) {
                length = minOf(window.toLong(), maxOf(1L, size - offset)).toInt()
                val request = JSONObject().put("requestId", prefix + UUID.randomUUID().toString())
                    .put("sessionId", sessionId).put("namespace", "workspaceFiles").put("method", "readBytes")
                    .put("args", JSONObject().put("path", path)
                        .put("options", JSONObject().put("range", JSONObject().put("offset", offset).put("length", length))))
                try {
                    page = rpc("document.call", request)
                    break
                } catch (failure: MediaFailure) {
                    if (failure.code != "workspace-file/too-large" || window == 1) throw failure
                    window = maxOf(1, window / 2)
                }
            }
            val data = page.getJSONObject("data")
            val lease = data.getString("id")
            try {
                if (data.getString("encoding") != "android-byte-lease" ||
                    page.getString("version") != version || page.getString("absolutePath") != absolute ||
                    number(page, "bytes") != size || number(page, "offset") != offset) {
                    throw MediaFailure(409, "file-open/changed")
                }
                val count = number(data, "length")
                if (count > length || count == 0L && offset < size || page.getBoolean("eof") != (offset + count == size)) {
                    throw MediaFailure(502, "file-open/invalid-window")
                }
                var consumed = 0L
                while (consumed < count) {
                    val chunkSize = minOf(64 * 1024L, count - consumed).toInt()
                    val frame = rpc("document.bytes", JSONObject().put("id", lease)
                        .put("offset", consumed).put("length", chunkSize))
                    val bytes = Base64.decode(frame.getString("data"), Base64.NO_WRAP)
                    if (number(frame, "offset") != consumed || bytes.size != chunkSize ||
                        frame.getBoolean("eof") != (consumed + chunkSize == count)) {
                        throw MediaFailure(502, "file-open/invalid-byte-frame")
                    }
                    output.write(bytes)
                    consumed += bytes.size
                }
                offset += count
            } finally { release(lease) }
            if (offset == size) break
        }
        val final = call("stat", path)
        if (number(final, "bytes") != size || final.getString("version") != version ||
            final.getString("absolutePath") != absolute) throw MediaFailure(409, "file-open/changed")
        return size
    }

    private fun ensureOpen() { synchronized(lock) { if (closed) throw MediaFailure(499, "gateway/cancelled") } }
    private fun ensureWorker() {
        if (Looper.myLooper() == Looper.getMainLooper()) throw MediaFailure(503, "document-media/worker-required")
        ensureOpen()
    }

    private fun number(value: JSONObject, field: String): Long {
        val candidate = value.get(field)
        if (candidate !is Number || candidate.toDouble() < 0 || candidate.toDouble() > 9007199254740991.0
            || candidate.toDouble() != candidate.toLong().toDouble()) throw MediaFailure(502, "document-media/invalid-number")
        return candidate.toLong()
    }

    private fun rpc(method: String, params: JSONObject): JSONObject {
        ensureWorker()
        val entry = Pending(if (method == "document.call") params.getString("requestId") else null)
        synchronized(lock) {
            if (closed) throw MediaFailure(499, "gateway/cancelled")
            pending.add(entry)
        }
        val posted = main.post {
            val active = synchronized(lock) { !closed && pending.contains(entry) }
            if (!active) entry.result.completeExceptionally(MediaFailure(499, "gateway/cancelled"))
            else try {
                send(JSONObject().put("method", method).put("params", params), object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        try {
                            val envelope = JSONTokener(result as String).nextValue() as JSONObject
                            if (!envelope.getBoolean("ok")) {
                                val code = envelope.getJSONObject("error").getString("code")
                                entry.result.completeExceptionally(MediaFailure(DocumentPreviewMediaPolicy.statusFor(code), code))
                                return
                            }
                            val value = envelope.getJSONObject("value")
                            val data = value.optJSONObject("data")
                            val lease = if (data?.optString("encoding") == "android-byte-lease") data.optString("id") else null
                            synchronized(lock) {
                                if (!closed && pending.contains(entry) && !entry.result.isDone) {
                                    if (!lease.isNullOrEmpty()) { leases.add(lease); entry.lease = lease }
                                    entry.result.complete(value)
                                } else if (!lease.isNullOrEmpty()) dispatchCleanup("document.release", JSONObject().put("id", lease))
                            }
                        } catch (failure: Exception) {
                            entry.result.completeExceptionally(MediaFailure(502, "document-media/invalid-response"))
                        }
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        entry.result.completeExceptionally(MediaFailure(503, "document-media/disconnected"))
                    }
                    override fun notImplemented() {
                        entry.result.completeExceptionally(MediaFailure(503, "gateway/invocation-unavailable"))
                    }
                })
            } catch (failure: Exception) {
                entry.result.completeExceptionally(MediaFailure(503, "document-media/disconnected"))
            }
        }
        if (!posted) entry.result.completeExceptionally(MediaFailure(503, "document-media/disconnected"))
        try {
            // A transport watchdog, longer than the runtime's maximum configured call timeout (300s).
            return entry.result.get(310, TimeUnit.SECONDS)
        } catch (failure: TimeoutException) {
            abandon(entry)
            throw MediaFailure(504, "document-preview/timeout")
        } catch (failure: InterruptedException) {
            abandon(entry)
            Thread.currentThread().interrupt()
            throw MediaFailure(499, "gateway/cancelled")
        } catch (failure: ExecutionException) {
            throw failure.cause as? MediaFailure ?: MediaFailure(502, "document-media/invalid-response")
        } finally { synchronized(lock) { pending.remove(entry) } }
    }

    private fun abandon(entry: Pending) {
        synchronized(lock) { pending.remove(entry); entry.result.completeExceptionally(MediaFailure(499, "gateway/cancelled")) }
        entry.lease?.let(::release)
        entry.requestId?.let { dispatchCleanup("document.cancel", JSONObject().put("requestId", it)) }
    }

    private fun release(lease: String) {
        if (synchronized(lock) { streams.remove(lease); leases.remove(lease) }) dispatchCleanup("document.release", JSONObject().put("id", lease))
    }

    private fun dispatchCleanup(method: String, params: JSONObject) {
        main.post {
            try {
                send(JSONObject().put("method", method).put("params", params), object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val succeeded = runCatching { JSONObject(result as String).getBoolean("ok") }.getOrDefault(false)
                        if (!succeeded) Log.w("PocketDocumentMedia", "Media cleanup was not acknowledged: $method")
                    }
                    override fun error(code: String, message: String?, details: Any?) { Log.w("PocketDocumentMedia", "Media cleanup disconnected: $method") }
                    override fun notImplemented() { Log.w("PocketDocumentMedia", "Media cleanup unavailable: $method") }
                })
            } catch (failure: Exception) { Log.w("PocketDocumentMedia", "Media cleanup failed: $method") }
        }
    }

    /** Nonblocking on the main looper; owner disconnect/lease expiry remain cleanup backstops. */
    override fun close() {
        val calls: List<Pending>
        val opened: List<DocumentPreviewMediaStream>
        val retained: List<String>
        synchronized(lock) {
            if (closed) return
            closed = true
            calls = pending.toList(); pending.clear()
            opened = streams.values.toList(); streams.clear()
            retained = leases.toList(); leases.clear()
        }
        calls.forEach {
            it.result.completeExceptionally(MediaFailure(499, "gateway/cancelled"))
            it.requestId?.let { id -> dispatchCleanup("document.cancel", JSONObject().put("requestId", id)) }
        }
        opened.forEach { it.close() }
        retained.forEach { dispatchCleanup("document.release", JSONObject().put("id", it)) }
    }

    private fun response(status: Int, mime: String, headers: Map<String, String>, body: java.io.InputStream) =
        WebResourceResponse(mime, null, status, if (status == 200) "OK" else "Media unavailable", headers, body)

    private fun errorResponse(status: Int, code: String, head: Boolean): WebResourceResponse {
        Log.w("PocketDocumentMedia", "Media unavailable: $status $code")
        val body = if (head) ByteArray(0) else code.toByteArray(Charsets.UTF_8)
        return response(status, "text/plain", DocumentPreviewMediaPolicy.headers("text/plain", body.size.toLong()), ByteArrayInputStream(body))
    }
}
