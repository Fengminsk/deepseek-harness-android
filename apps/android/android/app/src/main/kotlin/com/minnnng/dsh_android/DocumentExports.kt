package com.minnnng.dsh_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** System Save As for one prepared DSH ZIP. Neither Flutter nor Node supplies a source path. */
class DocumentExports(private val activity: Activity) : AutoCloseable {
    private class Save(val id: String, val filename: String, val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        @Volatile var output: OutputStream? = null
        var destinationChosen = false
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Save? = null
    private var pickerOutstanding = false
    private var closed = false

    fun save(id: String, filename: String, result: MethodChannel.Result) {
        if (closed || pending != null || pickerOutstanding) {
            result.error("export-busy", "已有导出正在保存，请稍后重试", null)
            return
        }
        try {
            SessionExportFiles.source(directory(activity), id)
            require(filename.endsWith(".zip") && filename.length <= 240 &&
                filename.none { it == '/' || it == '\\' || it.code < 32 }) { "导出文件名无效" }
            pending = Save(id, filename, result)
            pickerOutstanding = true
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE).setType("application/zip")
                .putExtra(Intent.EXTRA_TITLE, filename), EXPORT_REQUEST)
        } catch (failure: Exception) {
            pending = null
            pickerOutstanding = false
            result.error("export-target", failure.message ?: "无法打开系统保存位置，请重试", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != EXPORT_REQUEST) return false
        pickerOutstanding = false
        val save = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            finish(save, JSONObject().put("status", "cancelled"), null)
            return true
        }
        val destination = data?.data
        if (destination == null || destination.scheme != "content") {
            finish(save, null, "系统未返回可写入的文件，请重新选择保存位置")
            return true
        }
        save.destinationChosen = true
        worker.execute {
            try {
                val source = SessionExportFiles.source(directory(activity), save.id)
                val stream = activity.contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("文件提供方无法打开保存位置")
                save.output = stream
                val bytes = stream.use { SessionExportFiles.copy(source, it) { save.cancelled.get() } }
                save.output = null
                main.post { finish(save, JSONObject().put("status", "saved")
                    .put("filename", save.filename).put("bytes", bytes), null) }
            } catch (failure: Exception) {
                save.output = null
                main.post { finish(save, null,
                    "保存未完成，可重新选择位置重试。所选位置可能已留下不完整的 ZIP 文件。") }
            }
        }
        return true
    }

    private fun finish(save: Save, value: JSONObject?, error: String?) {
        if (pending !== save) return
        pending = null
        if (error == null) save.result.success(value.toString())
        else save.result.error("export-save", error, null)
    }

    fun cancel(id: String) {
        val save = pending?.takeIf { it.id == id } ?: return
        save.cancelled.set(true)
        try { save.output?.close() }
        catch (failure: Exception) { /* Provider close failed; the worker reports the incomplete write. */ }
        finish(save, JSONObject().put("status", "cancelled")
            .put("partialDestination", save.destinationChosen), null)
    }

    override fun close() {
        closed = true
        pending?.id?.let { cancel(it) }
        worker.shutdownNow()
    }

    companion object {
        private const val EXPORT_REQUEST = 5252

        /** Shared with Node through native.exports.directory, never inferred from another process's tmpdir. */
        fun directory(context: Context): File {
            val cache = context.cacheDir.canonicalFile
            val directory = File(cache, "pocket-session-exports")
            check(directory.mkdirs() || directory.isDirectory) { "无法创建导出缓存目录" }
            check(directory.canonicalFile == directory.absoluteFile) { "导出缓存目录无效" }
            return directory.canonicalFile
        }
    }
}
