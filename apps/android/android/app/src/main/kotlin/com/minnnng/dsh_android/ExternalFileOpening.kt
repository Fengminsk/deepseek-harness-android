package com.minnnng.dsh_android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

/** Grants a selected file to another app; callers cannot provide a filesystem root or content URI. */
class ExternalFileOpening(
    private val activity: Activity,
    private val send: (JSONObject, MethodChannel.Result) -> Unit,
) : AutoCloseable {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private class Opening(val id: String, val reply: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        @Volatile var job: Future<*>? = null
        @Volatile var staged: File? = null
        @Volatile var media: DocumentPreviewMedia? = null
        var uri: Uri? = null
        var mime: String? = null
        var prepared = false
    }
    @Volatile private var active: Opening? = null // Mutated only on the main thread.
    private var closed = false
    private val maintenance = object : Runnable {
        override fun run() {
            if (closed) return
            worker.execute {
                try { ExternalStageCache.prune(ExternalStageCache.root(activity.cacheDir),
                    System.currentTimeMillis(), active?.staged) }
                catch (_: Exception) { /* A later attempt retries; user files are never deleted broadly. */ }
            }
            main.postDelayed(this, MAINTENANCE_INTERVAL_MS)
        }
    }

    init { main.post(maintenance) }

    private fun start(id: String, result: MethodChannel.Result): Opening? {
        if (!id.matches(UUID_PATTERN)) { result.error("file-open/request", "文件打开请求无效", null); return null }
        if (closed || active != null) {
            result.error("file-open/busy", "已有文件正在准备，或文件页面已关闭", null)
            return null
        }
        return Opening(id, result).also { active = it }
    }

    private fun checkActive(opening: Opening) {
        if (opening.cancelled.get() || Thread.currentThread().isInterrupted)
            throw InterruptedException("file-open/cancelled")
    }

    private fun prepared(opening: Opening, uri: Uri, mime: String) {
        main.post {
            if (closed || active !== opening || opening.cancelled.get()) {
                cleanup(opening)
                return@post
            }
            opening.uri = uri
            opening.mime = mime
            opening.prepared = true
            opening.reply.success(null)
        }
    }

    private fun failed(opening: Opening, code: String, message: String) {
        main.post {
            cleanup(opening)
            if (active === opening) {
                active = null
                if (!opening.prepared) opening.reply.error(code, message, null)
            }
        }
    }

    private fun cleanup(opening: Opening) {
        opening.staged?.let { staged ->
            try { ExternalStageCache.delete(ExternalStageCache.root(activity.cacheDir), staged) }
            catch (_: Exception) { /* Periodic cache maintenance retries incomplete copies. */ }
        }
        opening.staged = null
    }

    fun launchPrepared(id: String, result: MethodChannel.Result) {
        val opening = active
        if (closed || opening?.id != id || !opening.prepared || opening.cancelled.get()) {
            result.error("file-open/cancelled", "文件打开请求已取消", null)
            return
        }
        active = null
        try {
            launch(checkNotNull(opening.uri), checkNotNull(opening.mime))
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            cleanup(opening)
            result.error("file-open/no-app", "设备上没有可打开此文件的应用", null)
        } catch (_: Exception) {
            cleanup(opening)
            result.error("file-open/launch", "无法交给其他应用打开，请重试", null)
        }
    }

    fun cancel(id: String, result: MethodChannel.Result) {
        val opening = active
        if (opening?.id != id) { result.success(false); return }
        active = null
        opening.cancelled.set(true)
        opening.signal.cancel()
        opening.media?.close()
        opening.job?.cancel(true)
        cleanup(opening)
        if (!opening.prepared) opening.reply.error("file-open/cancelled", "文件打开请求已取消", null)
        result.success(true)
    }

    fun document(id: String, root: String, path: String, result: MethodChannel.Result) {
        val opening = start(id, result) ?: return
        opening.job = worker.submit {
            try {
                val access = DocumentAccess(activity)
                val uri = access.document(root, path, opening.signal)
                checkActive(opening)
                var mediaType: String? = null
                var name: String? = null
                val row = activity.contentResolver.query(uri,
                    arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
                    opening.signal)
                check(row != null) { "文件提供方暂不可用" }
                row.use { cursor ->
                    check(cursor.moveToFirst()) { "文件已移动或不存在" }
                    if (!cursor.isNull(0)) mediaType = cursor.getString(0)
                    if (!cursor.isNull(1)) name = cursor.getString(1)
                }
                checkActive(opening)
                require(mediaType != DocumentsContract.Document.MIME_TYPE_DIR) { "目录不能作为文件打开" }
                check(access.hasGrant(root)) { "文件授权已撤销，请重新授权" }
                prepared(opening, uri, mediaType ?: mime(name ?: path))
            } catch (_: Exception) {
                failed(opening, "file-open/document", "无法打开授权文件，请检查授权和文件是否仍存在")
            }
        }
    }

    fun workspace(id: String, path: String, result: MethodChannel.Result) {
        val opening = start(id, result) ?: return
        val parts = try { ExternalFilePolicy.segments(path) }
        catch (failure: IllegalArgumentException) {
            active = null
            result.error("file-open/path", failure.message, null)
            return
        }
        opening.job = worker.submit {
            try {
                val cache = ExternalStageCache.root(activity.cacheDir)
                ExternalStageCache.prune(cache, System.currentTimeMillis(), null)
                checkActive(opening)
                val stage = ExternalStageCache.create(cache, parts.last())
                opening.staged = stage
                stagingOutput(stage).use { output -> copyWorkspace(parts, output, opening) }
                checkActive(opening)
                ExternalStageCache.prune(cache, System.currentTimeMillis(), stage)
                checkActive(opening)
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.selectedfiles", stage)
                prepared(opening, uri, mime(stage.name))
            } catch (failure: Exception) {
                failed(opening, "file-open/workspace", failure.message ?: "无法准备文件，请重试")
            }
        }
    }

    fun session(id: String, sessionId: String, path: String, result: MethodChannel.Result) {
        val opening = start(id, result) ?: return
        if (sessionId.isBlank() || sessionId.length > 200 || path.isBlank() || path.length > 8192 ||
            path.any { it.code < 32 || it.code == 127 }) {
            active = null
            result.error("file-open/path", "会话文件链接无效，请重新选择", null)
            return
        }
        val name = try { ExternalFilePolicy.displayName(path.split('/', '\\').last()) }
        catch (failure: IllegalArgumentException) {
            active = null
            result.error("file-open/path", failure.message, null)
            return
        }
        opening.job = worker.submit {
            try {
                val cache = ExternalStageCache.root(activity.cacheDir)
                ExternalStageCache.prune(cache, System.currentTimeMillis(), null)
                checkActive(opening)
                val stage = ExternalStageCache.create(cache, name)
                opening.staged = stage
                DocumentPreviewMedia(sessionId, send).use { source ->
                    opening.media = source
                    stagingOutput(stage).use { output -> source.copyFile(path, output, MAX_OPEN_BYTES) }
                }
                opening.media = null
                checkActive(opening)
                ExternalStageCache.prune(cache, System.currentTimeMillis(), stage)
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.selectedfiles", stage)
                prepared(opening, uri, mime(name))
            } catch (_: Exception) {
                failed(opening, "file-open/session", "会话文件无法完整读取，或读取期间发生变化，请重试")
            } finally {
                opening.media = null
            }
        }
    }

    private data class Ancestor(val file: File, val stat: StructStat)

    private fun stagingOutput(stage: File): FileOutputStream {
        val descriptor = Os.open(stage.path,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 384)
        return FileOutputStream(descriptor)
    }

    private fun sameIdentity(left: StructStat, right: StructStat) =
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
            left.st_mode == right.st_mode

    private fun sameVersion(left: StructStat, right: StructStat) = sameIdentity(left, right) &&
        left.st_size == right.st_size &&
        left.st_mtim.tv_sec == right.st_mtim.tv_sec && left.st_mtim.tv_nsec == right.st_mtim.tv_nsec &&
        left.st_ctim.tv_sec == right.st_ctim.tv_sec && left.st_ctim.tv_nsec == right.st_ctim.tv_nsec

    /** Mirrors AppWorkspaceFiles.withFile: no-follow open, opened inode, ancestors, and final version. */
    private fun copyWorkspace(parts: Array<String>, output: FileOutputStream, opening: Opening) {
        val root = File(activity.noBackupFilesDir, "dsh/workspace").absoluteFile
        var cursor = root
        val ancestry = mutableListOf<Ancestor>()
        val rootStat = Os.lstat(root.path)
        check(OsConstants.S_ISDIR(rootStat.st_mode) && !OsConstants.S_ISLNK(rootStat.st_mode) &&
            root.canonicalFile == root) { "工作区根目录已变化" }
        ancestry.add(Ancestor(root, rootStat))
        for (part in parts) {
            checkActive(opening)
            cursor = File(cursor, part)
            val stat = Os.lstat(cursor.path)
            check(!OsConstants.S_ISLNK(stat.st_mode) && cursor.canonicalFile == cursor.absoluteFile &&
                cursor.absolutePath.startsWith(root.absolutePath + File.separator)) { "文件已离开工作区" }
            ancestry.add(Ancestor(cursor, stat))
        }
        val expected = ancestry.last().stat
        check(OsConstants.S_ISREG(expected.st_mode) && expected.st_size in 0..MAX_OPEN_BYTES) {
            "文件不是普通文件，或超过打开大小上限"
        }
        val descriptor = Os.open(cursor.path,
            OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        FileInputStream(descriptor).use { input ->
            fun verify() {
                checkActive(opening)
                val opened = Os.fstat(descriptor)
                check(OsConstants.S_ISREG(opened.st_mode) && sameVersion(opened, expected)) {
                    "文件在打开时已变化，请重试"
                }
                for (entry in ancestry) {
                    val now = Os.lstat(entry.file.path)
                    check(!OsConstants.S_ISLNK(now.st_mode) && sameIdentity(now, entry.stat) &&
                        entry.file.canonicalFile == entry.file.absoluteFile) { "文件路径在读取期间已变化" }
                }
                check(sameVersion(Os.lstat(cursor.path), expected)) { "文件内容在读取期间已变化" }
            }
            verify()
            val buffer = ByteArray(64 * 1024)
            var copied = 0L
            while (true) {
                checkActive(opening)
                val count = input.read(buffer)
                if (count < 0) break
                copied += count
                check(copied <= MAX_OPEN_BYTES) { "文件超过打开大小上限" }
                output.write(buffer, 0, count)
            }
            check(copied == expected.st_size) { "文件在读取期间发生变化" }
            verify()
        }
    }

    private fun launch(uri: Uri, mime: String) {
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            clipData = ClipData.newRawUri("file", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(view, "使用其他应用打开").apply {
            clipData = ClipData.newRawUri("file", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(chooser)
    }

    private fun mime(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: when (extension) {
                "md" -> "text/markdown"
                "json" -> "application/json"
                "log", "txt" -> "text/plain"
                else -> "application/octet-stream"
            }
    }

    override fun close() {
        main.removeCallbacks(maintenance)
        closed = true
        active?.let { opening -> cancel(opening.id, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        }) }
        worker.shutdownNow()
    }

    companion object {
        private const val MAX_OPEN_BYTES = 256L * 1024 * 1024
        private const val MAINTENANCE_INTERVAL_MS = 6L * 60 * 60 * 1000
        private val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}
