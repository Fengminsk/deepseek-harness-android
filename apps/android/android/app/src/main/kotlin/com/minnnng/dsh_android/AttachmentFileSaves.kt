package com.minnnng.dsh_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** System Save As for a file whose original reference and complete bytes the current runtime verified. */
class AttachmentFileSaves(
    private val activity: Activity,
    private val authorize: (String, (JSONObject?, String?) -> Unit) -> Unit,
) : AutoCloseable {
    private class Save(val id: String, val requestedName: String, val result: MethodChannel.Result) {
        val lifetime = AttachmentSaveLifecycle()
        var filename = ""
        var bytes = 0L
        var attachmentId = ""
        var cache: AttachmentCacheLease? = null
        var destinationChosen = false
        var copying = false
        val cancelledCallbacks = mutableListOf<() -> Unit>()
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val canceller = Executors.newSingleThreadExecutor()
    private var pending: Save? = null
    private var pickerOutstanding = false
    private var closed = false

    fun save(id: String, filename: String, result: MethodChannel.Result) {
        if (closed || pending != null || pickerOutstanding) {
            result.error("attachment-save-busy", "已有附件正在保存，请稍后重试", null)
            return
        }
        try {
            AttachmentFileCache.validateId(id)
            AttachmentFileCache.validateFilename(filename)
        } catch (_: Exception) {
            result.error("attachment-save-invalid", "附件保存请求无效，请重新打开附件", null)
            return
        }
        val save = Save(id, filename, result)
        pending = save
        // Reserve before asynchronous authorization so an early cancellation cannot open a late picker.
        authorize(id) { information, error ->
            if (pending !== save || closed || save.lifetime.isCancelled) return@authorize
            if (information == null || error != null) {
                finish(save, null, error ?: "附件副本已失效，请重新打开")
                return@authorize
            }
            try {
                check(information.getString("id") == id)
                save.filename = information.getString("filename")
                save.bytes = information.getLong("size")
                save.attachmentId = information.getString("attachmentId")
                AttachmentFileCache.validateAttachmentId(save.attachmentId)
                check(save.filename == save.requestedName)
                AttachmentFileCache.validateFilename(save.filename)
                save.cache = AttachmentCacheLease.acquire(directory(activity), information.getString("cacheInstance"))
                AttachmentFileCache.source(save.cache!!.directory(), id, save.bytes)
                pickerOutstanding = true
                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream")
                    .putExtra(Intent.EXTRA_TITLE, save.filename), SAVE_REQUEST)
            } catch (_: Exception) {
                pickerOutstanding = false
                finish(save, null, "无法打开附件保存位置，请重新打开附件后重试")
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        pickerOutstanding = false
        val save = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            finish(save, JSONObject().put("status", "cancelled"), null)
            return true
        }
        val destination = data?.data
        if (destination == null || destination.scheme != "content") {
            finish(save, null, "系统未返回可写入的位置，请重新保存")
            return true
        }
        save.destinationChosen = true
        save.copying = true
        worker.execute {
            try {
                check(!save.lifetime.isCancelled)
                val source = AttachmentFileCache.source(save.cache!!.directory(), save.id, save.bytes)
                val stream = activity.contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("文件提供方无法写入")
                val bytes = try {
                    stream.use {
                        save.lifetime.attach(it)
                        AttachmentFileCache.copy(source, save.bytes, save.attachmentId, it) { save.lifetime.isCancelled }
                    }
                } finally {
                    save.lifetime.detach(stream)
                }
                main.post { finish(save, JSONObject().put("status", "saved")
                    .put("filename", save.filename).put("bytes", bytes), null) }
            } catch (_: Exception) {
                main.post { finish(save, null, "保存未完成，可重新选择位置重试。所选位置可能已留下不完整的附件文件。") }
            }
        }
        return true
    }

    private fun finish(save: Save, value: JSONObject?, error: String?) {
        if (pending !== save) return
        pending = null
        try { save.cache?.close() }
        catch (_: Exception) { /* A failed lease close keeps the OS lock until process death; never claim file cleanup. */ }
        save.cache = null
        if (save.lifetime.isCancelled) save.result.success(JSONObject().put("status", "cancelled")
            .put("partialDestination", save.destinationChosen).toString())
        else if (error == null) save.result.success(value.toString())
        else save.result.error("attachment-save-failed", error, null)
        save.cancelledCallbacks.forEach { it() }
        save.cancelledCallbacks.clear()
    }

    fun cancel(id: String, complete: () -> Unit = {}) {
        val save = pending?.takeIf { it.id == id }
        if (save == null) { complete(); return }
        save.cancelledCallbacks.add(complete)
        save.lifetime.requestCancel(canceller)
        if (save.copying) {
            // The worker closes both streams before posting finish and completing cancellation.
        } else finish(save, null, null)
    }

    fun cancelCurrent() { pending?.id?.let { cancel(it) } }

    override fun close() {
        closed = true
        cancelCurrent()
        worker.shutdown()
        canceller.shutdown()
    }

    companion object {
        private const val SAVE_REQUEST = 5256

        fun directory(context: Context): File {
            val directory = File(context.cacheDir.canonicalFile, "pocket-attachment-files")
            check(directory.mkdirs() || directory.isDirectory) { "无法创建附件缓存目录" }
            check(directory.canonicalFile == directory.absoluteFile) { "附件缓存目录无效" }
            return directory.canonicalFile
        }
    }
}
