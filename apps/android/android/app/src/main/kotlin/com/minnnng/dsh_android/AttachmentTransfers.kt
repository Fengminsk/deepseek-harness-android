package com.minnnng.dsh_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** One-time user-selected attachment copies; no URI or filesystem path crosses into Flutter. */
class AttachmentTransfers(private val activity: Activity) : AutoCloseable {
    private class Selection(val result: MethodChannel.Result) {
        val lifecycle = AttachmentImportLifecycle()
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val closer = Executors.newSingleThreadExecutor()
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
                    if (selection.lifecycle.isCancelled) break
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
                        val bytes = try {
                            selection.lifecycle.attach(input)
                            input.use { stream ->
                                Files.newOutputStream(source.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                                    sourceOwned = true
                                    AttachmentCopy.copy(stream, output) { selection.lifecycle.isCancelled }
                                }
                            }
                        } finally {
                            selection.lifecycle.detach(input)
                        }
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
                        if (sourceOwned) source.delete()
                        if (metadataOwned) metadata.delete()
                        if (!selection.lifecycle.isCancelled) failures.put(JSONObject().put("name", name)
                            .put("message", "无法读取所选文件，请检查文件提供方并重新选择。"))
                    }
                }
                main.post {
                    if (selection.lifecycle.isCancelled || pending !== selection) {
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

    /**
     * 分页读取一条已选附件的私有副本，供远程宿主通过反向请求 `native.attachments.read` 拉取。
     *
     * 只服务 `<cacheDir>/pocket-attachments/<uuid>.bin`：id 先过 uuid 正则，再比较
     * `canonicalFile` 的父目录，Flutter 侧永远拿不到路径（远程附件上行，设计 §3.4.6）。
     * 返回 `{data(base64), nextOffset, size, eof}`；`size` 是设备侧 stat 的权威大小。
     */
    fun read(id: String?, offset: Number?, length: Number?, result: MethodChannel.Result) {
        val parsed = id?.takeIf { ATTACHMENT_ID.matches(it) }
        if (parsed == null) {
            result.error("attachment-file/invalid-request", "附件标识不正确", null)
            return
        }
        val position = offset?.toLong()
        val page = length?.toLong()
        if (position == null || page == null || position < 0 || page < 1 || page > READ_PAGE_BYTES) {
            result.error("attachment-file/invalid-request", "读取范围不正确", null)
            return
        }
        if (closed) {
            result.error("attachment-file/cancelled", "设备正在断开连接。", null)
            return
        }
        try {
            worker.execute {
                try {
                    val root = directory(activity)
                    val source = File(root, "$parsed.bin")
                    if (!source.isFile || source.canonicalFile.parentFile != root) {
                        main.post { result.error("attachment-file/not-found", "文件已不在手机上，请重新选择", null) }
                        return@execute
                    }
                    val size = source.length()
                    if (position > size) {
                        main.post { result.error("attachment-file/invalid-request", "读取位置已超出文件末尾", null) }
                        return@execute
                    }
                    val wanted = minOf(page, size - position).toInt()
                    val data = ByteArray(wanted)
                    FileInputStream(source).use { stream ->
                        stream.channel.position(position)
                        var read = 0
                        while (read < wanted) {
                            val count = stream.read(data, read, wanted - read)
                            if (count <= 0) break
                            read += count
                        }
                        if (read != wanted || source.length() != size) {
                            main.post { result.error("attachment-file/not-found", "文件已变化，请重新选择", null) }
                            return@execute
                        }
                    }
                    val nextOffset = position + wanted
                    val reply = JSONObject().put("data", Base64.encodeToString(data, Base64.NO_WRAP))
                        .put("nextOffset", nextOffset).put("size", size).put("eof", nextOffset >= size)
                    main.post { result.success(reply.toString()) }
                } catch (_: Exception) {
                    // 读取失败时按「文件已不可用」应答：手机上的副本只服务本次上传，
                    // 重新选择即可恢复（宿主侧对应 attachment-file/not-found）。
                    main.post { result.error("attachment-file/not-found", "文件已不在手机上，请重新选择", null) }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("attachment-file/cancelled", "设备正在断开连接。", null)
        }
    }

    /**
     * 删除一条附件的私有副本（`.bin` 与 `.json`），幂等。
     *
     * 远程宿主 `attachments.release` 受理后由 App 调用：宿主没有副本，手机上的
     * 一次性缓存到此结束（设计 §3.4.4）。
     */
    fun discard(id: String?, result: MethodChannel.Result) {
        val parsed = id?.takeIf { ATTACHMENT_ID.matches(it) }
        if (parsed == null) {
            result.error("attachment-file/invalid-request", "附件标识不正确", null)
            return
        }
        if (closed) {
            result.success(null)
            return
        }
        try {
            worker.execute {
                try {
                    val root = directory(activity)
                    File(root, "$parsed.bin").delete()
                    File(root, "$parsed.json").delete()
                } catch (_: Exception) {
                    // 清理是幂等的尽力动作：删除失败（例如目录已清理）不阻塞 release。
                }
                main.post { result.success(null) }
            }
        } catch (_: RejectedExecutionException) {
            result.success(null)
        }
    }

    private fun finish(selection: Selection, value: JSONObject) {
        if (pending !== selection) return
        pending = null
        selection.result.success(value.toString())
    }

    override fun close() {
        closed = true
        val selection = pending
        pending = null
        try {
            selection?.let {
                selection.lifecycle.requestCancel(closer)
                selection.result.error("attachment-closed", "附件选择已结束，请重新选择", null)
            }
        } finally {
            worker.shutdownNow()
            closer.shutdown()
        }
    }

    companion object {
        private const val ATTACHMENT_REQUEST = 5353

        /** 远程宿主一页最多拉取的字节数（设计 §3.4.2：base64 后远低于 1 MiB 上行帧）。 */
        private const val READ_PAGE_BYTES = 262144

        /** `attachment.pick` 生成的小写 UUID v4；其它 id 一律拒绝。 */
        private val ATTACHMENT_ID = Regex(
            "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        )

        /** Native path shared directly with the Agent process, never supplied by an App request. */
        fun directory(context: Context): File {
            val root = File(context.cacheDir.canonicalFile, "pocket-attachments")
            check(root.mkdirs() || root.isDirectory) { "无法创建附件缓存目录" }
            check(root.canonicalFile == root.absoluteFile) { "附件缓存目录无效" }
            return root.canonicalFile
        }
    }
}
