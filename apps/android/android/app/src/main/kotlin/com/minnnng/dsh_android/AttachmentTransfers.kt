package com.minnnng.dsh_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One-time user-selected attachment copies; no URI or filesystem path crosses into Flutter. */
class AttachmentTransfers(private val activity: Activity) : AutoCloseable {
    private class Selection(val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        @Volatile var input: InputStream? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Selection? = null
    private var closed = false

    fun pick(result: MethodChannel.Result) {
        if (closed || pending != null) {
            result.error("attachment-busy", "附件选择或导入尚未结束，请稍后重试", null)
            return
        }
        pending = Selection(result)
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), ATTACHMENT_REQUEST)
        } catch (failure: Exception) {
            pending = null
            result.error("attachment-picker", "无法打开系统文件选择器，请重试", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != ATTACHMENT_REQUEST) return false
        val selection = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            finish(selection, JSONObject().put("cancelled", true).put("items", JSONArray()))
            return true
        }
        val uris = mutableListOf<Uri>()
        data?.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        }
        if (uris.isEmpty()) data?.data?.let { uris.add(it) }
        if (uris.isEmpty() || uris.any { it.scheme != "content" }) {
            pending = null
            selection.result.error("attachment-selection", "系统未返回可读取文件，请重新选择", null)
            return true
        }
        worker.execute {
            val items = JSONArray()
            val failures = JSONArray()
            val unpublished = mutableListOf<File>()
            try {
                val root = directory(activity)
                for (uri in uris.distinct()) {
                    if (selection.cancelled.get()) break
                    var name = "附件"
                    val id = UUID.randomUUID().toString()
                    val source = File(root, "$id.bin")
                    val metadata = File(root, "$id.json")
                    var sourceOwned = false
                    var metadataOwned = false
                    try {
                        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) name = cursor.getString(0)?.take(512) ?: name
                        }
                        val mediaType = activity.contentResolver.getType(uri) ?: "application/octet-stream"
                        val input = activity.contentResolver.openInputStream(uri)
                            ?: throw IllegalStateException("文件提供方不能读取该文件")
                        selection.input = input
                        val bytes = input.use { stream ->
                            Files.newOutputStream(source.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                                sourceOwned = true
                                AttachmentCopy.copy(stream, output) { selection.cancelled.get() }
                            }
                        }
                        selection.input = null
                        val item = JSONObject().put("id", id).put("name", name)
                            .put("mediaType", mediaType).put("bytes", bytes)
                        Files.newOutputStream(metadata.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use {
                            metadataOwned = true
                            it.write(item.toString().toByteArray(Charsets.UTF_8))
                        }
                        unpublished.add(source)
                        unpublished.add(metadata)
                        items.put(item)
                    } catch (failure: Exception) {
                        selection.input = null
                        if (sourceOwned) source.delete()
                        if (metadataOwned) metadata.delete()
                        if (!selection.cancelled.get()) failures.put(JSONObject().put("name", name)
                            .put("message", "无法读取所选文件，请检查文件提供方并重新选择。"))
                    }
                }
                main.post {
                    if (selection.cancelled.get() || pending !== selection) {
                        unpublished.forEach { it.delete() }
                    } else {
                        finish(selection, JSONObject().put("cancelled", false)
                            .put("items", items).put("failures", failures))
                    }
                }
            } catch (failure: Exception) {
                unpublished.forEach { it.delete() }
                main.post {
                    if (pending === selection) {
                        pending = null
                        selection.result.error("attachment-import", "附件导入未完成，请检查可用存储空间后重新选择", null)
                    }
                }
            }
        }
        return true
    }

    private fun finish(selection: Selection, value: JSONObject) {
        if (pending !== selection) return
        pending = null
        selection.result.success(value.toString())
    }

    override fun close() {
        closed = true
        pending?.let { selection ->
            selection.cancelled.set(true)
            try { selection.input?.close() }
            catch (failure: Exception) { /* Worker owns incomplete private-file cleanup. */ }
            selection.result.error("attachment-closed", "附件选择已结束，请重新选择", null)
        }
        pending = null
        worker.shutdownNow()
    }

    companion object {
        private const val ATTACHMENT_REQUEST = 5353

        /** Native path shared directly with the Agent process, never supplied by an App request. */
        fun directory(context: Context): File {
            val root = File(context.cacheDir.canonicalFile, "pocket-attachments")
            check(root.mkdirs() || root.isDirectory) { "无法创建附件缓存目录" }
            check(root.canonicalFile == root.absoluteFile) { "附件缓存目录无效" }
            return root.canonicalFile
        }
    }
}
