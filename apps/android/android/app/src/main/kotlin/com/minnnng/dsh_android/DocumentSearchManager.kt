package com.minnnng.dsh_android

import android.content.Context
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.os.SystemClock
import android.provider.DocumentsContract
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.nio.charset.CharacterCodingException
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledFuture

/** Searches only persisted SAF grants. Caller cancellation waits for the scanning owner to finish. */
class DocumentSearchManager(private val context: Context) {
    private data class Job(val signal: CancellationSignal, val lifecycle: DocumentSearchJob, @Volatile var root: String? = null)
    private val jobs = ConcurrentHashMap<String, Job>()
    private val closers = Executors.newCachedThreadPool()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closed = AtomicBoolean()
    private val access = DocumentAccess(context)
    private val resolver = context.contentResolver

    fun prepare(id: String): JSONObject {
        require(id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))) { "无效的搜索标识" }
        synchronized(jobs) {
            check(!closed.get()) { "文件搜索服务已关闭" }
            check(jobs.size < 4) { "搜索任务过多，请等待已有搜索结束" }
            val signal = CancellationSignal()
            check(jobs.putIfAbsent(id, Job(signal, DocumentSearchJob { signal.cancel() })) == null) { "搜索标识已使用" }
        }
        return JSONObject().put("prepared", true)
    }

    fun cancel(id: String): JSONObject {
        val job = jobs[id] ?: return JSONObject().put("cancelled", true)
        job.lifecycle.requestCancel(closers)
        val stopped = job.lifecycle.awaitStopped(5000)
        if (stopped) jobs.remove(id, job)
        return JSONObject().put("cancelled", stopped).put("stopping", !stopped)
    }

    /** Called after the persisted grant is released; no scanned content is returned afterward. */
    fun revokeRoot(root: String): Boolean {
        val snapshot = jobs.filterValues { it.root == root }
        snapshot.values.forEach { it.lifecycle.requestCancel(closers) }
        val deadline = SystemClock.elapsedRealtime() + 5000
        var stopped = true
        for ((id, job) in snapshot) {
            if (job.lifecycle.awaitStopped((deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0))) jobs.remove(id, job)
            else stopped = false
        }
        return stopped
    }

    /** Called off the Android main thread. A non-cooperating provider is not reported as stopped. */
    fun close() {
        synchronized(jobs) { if (!closed.compareAndSet(false, true)) return }
        timer.shutdownNow()
        val snapshot = jobs.toMap()
        snapshot.values.forEach { job -> job.lifecycle.requestCancel(closers) }
        val deadline = SystemClock.elapsedRealtime() + 5000
        for ((id, job) in snapshot) {
            if (job.lifecycle.awaitStopped((deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0))) jobs.remove(id, job)
        }
        closers.shutdown()
    }

    private data class Limits(
        val fileBytes: Long, val totalBytes: Long, val maxEntries: Int, val maxFiles: Int,
        val maxDepth: Int, val maxMatches: Int, val previewChars: Int, val maxDurationMs: Long,
    ) {
        companion object {
            fun read(json: JSONObject) = Limits(
                json.getLong("fileBytes"), json.getLong("totalBytes"), json.getInt("maxEntries"),
                json.getInt("maxFiles"), json.getInt("maxDepth"), json.getInt("maxMatches"),
                json.getInt("previewChars"), json.getLong("maxDurationMs"),
            ).also {
                require(it.fileBytes in 1L..67108864L && it.totalBytes in it.fileBytes..268435456L &&
                    it.maxEntries in 1..10000 && it.maxFiles in 1..10000 && it.maxDepth in 1..64 &&
                    it.maxMatches in 1..1000 && it.previewChars in 512..2000 && it.maxDurationMs in 100L..300000L) { "无效的搜索限制" }
            }
        }
    }
    private data class Entry(val uri: Uri, val path: String, val name: String, val mime: String,
                             val size: Long?, val modified: Long?, val virtual: Boolean, val depth: Int) {
        val directory get() = mime == DocumentsContract.Document.MIME_TYPE_DIR
        fun same(other: Entry) = uri == other.uri && name == other.name && mime == other.mime &&
            size == other.size && modified == other.modified
    }
    private class Budget(val reason: String) : RuntimeException(reason)

    fun run(params: JSONObject): JSONObject {
        val id = params.getString("id")
        val job = jobs[id] ?: throw CancellationException("搜索已取消或不存在")
        if (!job.lifecycle.start()) {
            jobs.remove(id, job)
            throw CancellationException("搜索已取消")
        }
        val expired = AtomicBoolean()
        var timeout: ScheduledFuture<*>? = null
        try {
            val root = params.getString("root")
            require(root.matches(Regex("[0-9a-f]{64}"))) { "无效的授权标识" }
            job.root = root
            val path = params.getString("path")
            require(path.length <= 4096) { "搜索相对路径过长，请重新授权更近的子目录" }
            val query = params.getString("query")
            require(query.isNotEmpty() && query.length <= 256 && query.none { it == '\n' || it == '\r' || it == '\u0000' }) { "请输入 1–256 个单行字符" }
            val sensitive = params.getBoolean("caseSensitive")
            val limits = Limits.read(params.getJSONObject("limits"))
            val deadline = SystemClock.elapsedRealtime() + limits.maxDurationMs
            timeout = timer.schedule({
                expired.set(true)
                job.lifecycle.requestCancel(closers)
            }, limits.maxDurationMs, TimeUnit.MILLISECONDS)
            fun checkProgress() {
                job.lifecycle.check()
                job.signal.throwIfCanceled()
                if (SystemClock.elapsedRealtime() > deadline) throw Budget("duration")
            }
            fun checkAccess() {
                checkProgress()
                if (!access.hasGrant(root)) throw SecurityException("文件授权已撤销，请重新授权")
            }
            val projection = arrayOf("document_id", "_display_name", "mime_type", "_size", "last_modified", "flags")
            fun info(uri: Uri, relative: String, depth: Int): Entry {
                checkAccess()
                val result = resolver.query(uri, projection, null, null, null, job.signal)?.use { cursor ->
                    if (!cursor.moveToFirst()) throw IOException("Document moved or deleted")
                    Entry(uri, relative, cursor.getString(1) ?: "", cursor.getString(2) ?: "",
                        if (cursor.isNull(3)) null else cursor.getLong(3),
                        if (cursor.isNull(4)) null else cursor.getLong(4),
                        !cursor.isNull(5) && cursor.getInt(5) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0, depth)
                } ?: throw IOException("Document provider unavailable")
                checkAccess()
                return result
            }
            val matches = JSONArray()
            val skipped = JSONArray()
            var scannedFiles = 0
            var bytesRead = 0L
            var entriesSeen = 0
            var skippedCount = 0
            var stoppedReason: String? = null
            fun skipPath(relative: String, reason: String) {
                skippedCount++
                // Bound diagnostic output independently from traversal and match limits.
                if (skipped.length() < 100) skipped.put(JSONObject().put("path", relative).put("reason", reason))
            }
            fun skip(entry: Entry, reason: String) = skipPath(entry.path, reason)
            val queue = java.util.ArrayDeque<Entry>()
            val seen = HashSet<String>()
            try {
                checkAccess()
                queue.add(info(access.document(root, path, job.signal), path, 0))
                while (queue.isNotEmpty()) {
                    checkAccess()
                    val entry = queue.removeFirst()
                    if (!seen.add(entry.uri.toString())) { skip(entry, "duplicate_document"); continue }
                    if (entry.directory) {
                        if (entry.depth >= limits.maxDepth) { skip(entry, "depth"); continue }
                        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(entry.uri, DocumentsContract.getDocumentId(entry.uri))
                        val children = mutableListOf<Entry>()
                        resolver.query(childrenUri, projection, null, null, null, job.signal)?.use { cursor ->
                            while (cursor.moveToNext()) {
                                checkAccess()
                                if (++entriesSeen > limits.maxEntries) throw Budget("entries")
                                val name = cursor.getString(1) ?: ""
                                if (name.isEmpty() || name.length > 1024 || name == "." || name == ".." ||
                                    name.contains('/') || name.contains('\\')) { skipPath(entry.path, "unsupported_name"); continue }
                                val childPath = if (entry.path.isEmpty()) name else "${entry.path}/$name"
                                if (childPath.length > 4096) { skipPath(entry.path, "path_length"); continue }
                                val child = Entry(DocumentsContract.buildDocumentUriUsingTree(entry.uri, cursor.getString(0)),
                                    childPath, name, cursor.getString(2) ?: "",
                                    if (cursor.isNull(3)) null else cursor.getLong(3),
                                    if (cursor.isNull(4)) null else cursor.getLong(4),
                                    !cursor.isNull(5) && cursor.getInt(5) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0, entry.depth + 1)
                                children.add(child)
                            }
                        } ?: throw IOException("Directory provider unavailable")
                        val counts = children.groupingBy { it.name }.eachCount()
                        for (child in children) {
                            if (counts[child.name] != 1) skip(child, "ambiguous_name") else queue.add(child)
                        }
                        continue
                    }
                    if (scannedFiles >= limits.maxFiles) throw Budget("files")
                    if (entry.virtual) { skip(entry, "virtual_document"); continue }
                    if (entry.size != null && entry.size > limits.fileBytes) { skip(entry, "file_bytes"); continue }
                    val allowance = minOf(limits.fileBytes, limits.totalBytes - bytesRead)
                    if (allowance < 1) throw Budget("total_bytes")
                    scannedFiles++
                    try {
                        val before = info(entry.uri, entry.path, entry.depth)
                        if (!entry.same(before)) { skip(entry, "changed"); continue }
                        val descriptor = resolver.openAssetFileDescriptor(entry.uri, "r", job.signal)
                            ?: throw IOException("File provider unavailable")
                        val result = descriptor.use {
                            val stream = it.createInputStream()
                            try {
                                job.lifecycle.attach(stream)
                                DocumentTextSearch.scan(stream, query, sensitive, allowance,
                                    limits.maxMatches - matches.length(), limits.previewChars,
                                    object : DocumentTextSearch.Check {
                                        override fun check() = checkProgress()
                                        override fun beforeRead() = checkAccess()
                                        override fun read(bytes: Int) { bytesRead += bytes }
                                    })
                            } finally {
                                try { stream.close() } finally { job.lifecycle.detach() }
                            }
                        }
                        if (!before.same(info(entry.uri, entry.path, entry.depth))) { skip(entry, "changed"); continue }
                        for (match in result.matches) matches.put(JSONObject()
                            .put("path", entry.path).put("lineNumber", match.lineNumber)
                            .put("line", match.line).put("previewTruncated", match.previewTruncated))
                        if (result.matchedLines > result.matches.size ||
                            matches.length() >= limits.maxMatches && queue.isNotEmpty()) throw Budget("matches")
                    } catch (failure: DocumentTextSearch.LimitException) {
                        skip(entry, if (allowance < limits.fileBytes) "total_bytes" else "file_bytes")
                        if (allowance < limits.fileBytes) throw Budget("total_bytes")
                    } catch (failure: DocumentTextSearch.BinaryException) {
                        skip(entry, "binary")
                    } catch (failure: CharacterCodingException) {
                        skip(entry, "not_utf8")
                    } catch (failure: IOException) {
                        checkAccess()
                        skip(entry, "unavailable")
                    }
                }
            } catch (failure: Budget) { stoppedReason = failure.reason }
            checkAccessExceptBudget(job, root)
            return JSONObject().put("matches", matches).put("complete", stoppedReason == null && skippedCount == 0)
                .put("scannedFiles", scannedFiles).put("skipped", skipped).put("bytesRead", bytesRead)
                .put("skippedCount", skippedCount).put("skippedTruncated", skippedCount > skipped.length())
                .put("stoppedReason", stoppedReason ?: JSONObject.NULL).put("limits", params.getJSONObject("limits"))
                .put("consistency", "provider-metadata")
        } catch (failure: OperationCanceledException) {
            if (expired.get()) throw IllegalStateException("搜索超过时限，文件扫描未完成；请缩小范围重试")
            throw CancellationException("搜索已取消")
        } catch (failure: CancellationException) {
            if (expired.get()) throw IllegalStateException("搜索超过时限，文件扫描未完成；请缩小范围重试")
            throw failure
        } finally {
            timeout?.cancel(false)
            job.lifecycle.finish()
            jobs.remove(id, job)
        }
    }

    private fun checkAccessExceptBudget(job: Job, root: String) {
        job.lifecycle.check()
        job.signal.throwIfCanceled()
        if (!access.hasGrant(root)) throw SecurityException("文件授权已撤销，请重新授权")
    }
}
