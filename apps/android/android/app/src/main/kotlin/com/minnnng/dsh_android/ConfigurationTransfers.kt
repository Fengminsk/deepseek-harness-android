package com.minnnng.dsh_android

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One-shot SAF JSON transfer. No paths, persistable grants or credential-vault reads. */
class ConfigurationTransfers(private val activity: Activity) : AutoCloseable {
    private class Operation(
        val id: String,
        val result: MethodChannel.Result,
        val content: ByteArray? = null,
        val filename: String? = null,
    ) {
        val cancelled = AtomicBoolean(false)
        @Volatile var stream: Closeable? = null
        var destinationChosen = false
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Operation? = null
    private var pickerOutstanding = false
    private var closed = false

    fun pick(id: String, result: MethodChannel.Result) {
        begin(Operation(id, result), Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    fun save(id: String, text: String, filename: String, result: MethodChannel.Result) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES || !filename.endsWith(".json") || filename.length > 120 ||
            filename.any { it == '/' || it == '\\' || it.code < 32 }) {
            result.error("configuration-file", "文件必须是最多 1 MiB 的 JSON，且名称不能包含路径", null)
            return
        }
        begin(Operation(id, result, bytes, filename), Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE).setType("application/json")
            .putExtra(Intent.EXTRA_TITLE, filename))
    }

    private fun begin(operation: Operation, intent: Intent) {
        if (closed || pending != null || pickerOutstanding) {
            operation.result.error("configuration-busy", "已有文件操作尚未结束，请稍后重试", null)
            return
        }
        if (!ID.matches(operation.id)) {
            operation.result.error("configuration-id", "文件操作标识无效", null)
            return
        }
        pending = operation
        pickerOutstanding = true
        try { activity.startActivityForResult(intent, REQUEST) }
        catch (failure: Exception) {
            pending = null
            pickerOutstanding = false
            operation.result.error("configuration-picker", "无法打开系统文件选择器，请重试", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        pickerOutstanding = false
        val operation = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            finish(operation, JSONObject().put("status", "cancelled"), null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            finish(operation, null, "系统未返回可访问的文档，请重新选择")
            return true
        }
        operation.destinationChosen = operation.content != null
        worker.execute {
            try {
                val value = if (operation.content == null) {
                    val stream = activity.contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法读取文档")
                    operation.stream = stream
                    val output = ByteArrayOutputStream()
                    stream.use {
                        val buffer = ByteArray(8192)
                        while (true) {
                            check(!operation.cancelled.get()) { "cancelled" }
                            val count = it.read(buffer)
                            if (count < 0) break
                            check(output.size() + count <= MAX_BYTES) { "too-large" }
                            output.write(buffer, 0, count)
                        }
                    }
                    val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(output.toByteArray())).toString()
                    JSONObject().put("status", "selected").put("text", text.removePrefix("\uFEFF"))
                } else {
                    val stream = activity.contentResolver.openOutputStream(uri, "w")
                        ?: throw IllegalStateException("无法写入文档")
                    operation.stream = stream
                    stream.use {
                        for (offset in operation.content.indices step 8192) {
                            check(!operation.cancelled.get()) { "cancelled" }
                            it.write(operation.content, offset, minOf(8192, operation.content.size - offset))
                        }
                        it.flush()
                    }
                    JSONObject().put("status", "saved").put("filename", operation.filename)
                        .put("bytes", operation.content.size)
                }
                operation.stream = null
                main.post { finish(operation, value, null) }
            } catch (failure: Exception) {
                operation.stream = null
                main.post { finish(operation, null, if (operation.content == null)
                    "读取未完成，请选择最多 1 MiB 的 UTF-8 JSON 文件。当前配置未改变。"
                    else "保存未完成，可重新选择位置重试；目标位置可能留下不完整的 JSON 文件。") }
            }
        }
        return true
    }

    private fun finish(operation: Operation, value: JSONObject?, error: String?) {
        if (pending !== operation) return
        pending = null
        if (error == null) operation.result.success(value.toString())
        else operation.result.error("configuration-file", error, null)
    }

    fun cancel(id: String) {
        val operation = pending?.takeIf { it.id == id } ?: return
        operation.cancelled.set(true)
        try { operation.stream?.close() }
        catch (failure: Exception) { /* Worker reports incomplete reads/writes; no other document is removed. */ }
        finish(operation, JSONObject().put("status", "cancelled")
            .put("partialDestination", operation.destinationChosen), null)
    }

    override fun close() {
        closed = true
        pending?.id?.let { cancel(it) }
        worker.shutdownNow()
    }

    companion object {
        private const val REQUEST = 5554
        private const val MAX_BYTES = 1048576
        private val ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    }
}
