package com.minnnng.dsh_android

import android.content.Context
import android.os.CancellationSignal
import android.os.SystemClock
import org.json.JSONObject

/** Owns cancellable SAF image reads for the lifetime of one Agent Service. */
class DocumentImageReads(private val context: Context) {
    private val requests = DocumentImageReadRequests(SystemClock::elapsedRealtime)

    fun read(params: JSONObject): JSONObject {
        val id = id(params.getString("id"))
        val root = params.getString("root")
        val path = params.optString("path")
        val limit = DocumentBinaryReadAccess.limit(params.get("maxBytes"))
        val signal = CancellationSignal()
        requests.begin(id, root, signal::cancel)
        try { return DocumentAccess(context).readImage(root, path, limit, signal) }
        finally { requests.finish(id) }
    }

    fun cancel(params: JSONObject): JSONObject {
        val id = id(params.getString("id"))
        requests.cancel(id)
        return JSONObject().put("cancelled", true)
    }

    fun revokeRoot(root: String) {
        requests.revokeRoot(root)
    }

    fun close() {
        requests.close()
    }

    private fun id(value: String): String {
        require(value.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))) {
            "无效的图片读取请求标识"
        }
        return value
    }
}
