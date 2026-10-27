package com.minnnng.dsh_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.IOException
import java.io.FileInputStream
import java.io.InterruptedIOException
import java.security.MessageDigest

/** Traversal starts from a currently persisted SAF grant, never an arbitrary URI. */
class DocumentAccess(private val context: Context) {
    private val resolver = context.contentResolver
    private data class Metadata(
        val name: String?, val mime: String?, val flags: Int, val size: Long?, val modified: Long?,
    )

    private fun metadata(uri: Uri, cancellation: CancellationSignal? = null): Metadata =
        resolver.query(uri, arrayOf("_display_name", "mime_type", "flags", "_size", "last_modified"), null, null, null, cancellation)?.use { cursor ->
            if (!cursor.moveToFirst()) throw FileNotFoundException("文件或目录已移动或删除，请重新选择或重新授权")
            fun index(column: String) = cursor.getColumnIndex(column).takeIf { it >= 0 && !cursor.isNull(it) }
            Metadata(index("_display_name")?.let(cursor::getString), index("mime_type")?.let(cursor::getString),
                index("flags")?.let(cursor::getInt) ?: 0,
                index("_size")?.let(cursor::getLong), index("last_modified")?.let(cursor::getLong))
        } ?: throw IOException("文件提供方暂不可用，请稍后重试")

    private fun id(uri: Uri) = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
        .joinToString("") { "%02x".format(it) }
    /** Lists only existing persisted read grants; inaccessible providers remain visible for recovery. */
    fun roots(): JSONArray = JSONArray().apply {
        resolver.persistedUriPermissions.filter { it.isReadPermission }.forEach { permission ->
            val uri = permission.uri
            val directory = DocumentsContract.isTreeUri(uri)
            val item = JSONObject().put("id", id(uri)).put("directory", directory)
                .put("name", if (directory) "已授权目录" else "已授权文件")
            try {
                val document = if (directory) DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri)) else uri
                val info = metadata(document)
                item.put("name", info.name ?: item.getString("name"))
                item.put("mediaType", info.mime ?: JSONObject.NULL)
                item.put("available", true)
            } catch (failure: FileNotFoundException) {
                item.put("available", false).put("error", failure.message)
            } catch (failure: SecurityException) {
                item.put("available", false).put("error", "授权已失效，请撤销后重新授权")
            } catch (failure: Exception) {
                item.put("available", false).put("error", "文件提供方暂不可用，请稍后重试；若项目已移动，请重新授权")
            }
            put(item)
        }
    }

    internal fun grant(root: String): Uri = resolver.persistedUriPermissions.firstOrNull {
        it.isReadPermission && id(it.uri) == root
    }?.uri ?: throw SecurityException("文件授权不存在或已撤销，请重新授权")

    internal fun hasGrant(root: String): Boolean = resolver.persistedUriPermissions.any {
        it.isReadPermission && id(it.uri) == root
    }

    /** Releases only the grant represented by an existing opaque id; repeat removal is harmless. */
    fun revoke(root: String): JSONObject {
        require(root.matches(Regex("[0-9a-f]{64}"))) { "无效的文件授权标识" }
        for (permission in resolver.persistedUriPermissions.filter { id(it.uri) == root }) {
            val flags = (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
            resolver.releasePersistableUriPermission(permission.uri, flags)
        }
        check(resolver.persistedUriPermissions.none { id(it.uri) == root }) { "未能确认授权已撤销，请刷新后重试" }
        return JSONObject().put("revoked", true)
    }

    internal fun document(root: String, path: String, cancellation: CancellationSignal? = null): Uri {
        val uri = grant(root)
        if (DocumentsContract.isTreeUri(uri)) return resolve(uri, path, cancellation)
        require(path.isEmpty()) { "单文件授权不能访问其他路径，请单独授权所需文件" }
        return uri
    }
    private fun resolve(tree: Uri, path: String, cancellation: CancellationSignal? = null): Uri {
        val segments = DocumentTraversalBudget.segments(path)
        var document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        for (segment in segments) {
            cancellation?.throwIfCanceled()
            check(metadata(document, cancellation).mime == DocumentsContract.Document.MIME_TYPE_DIR) { "当前项目不是目录，请返回上一级" }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
            var found: String? = null
            val budget = DocumentTraversalBudget()
            resolver.query(children, arrayOf("document_id", "_display_name"), null, null, null, cancellation)?.use { cursor ->
                val columns = DocumentColumns(cursor.columnNames)
                val idColumn = columns.required("document_id")
                val nameColumn = columns.required("_display_name")
                while (cursor.moveToNext()) {
                    cancellation?.throwIfCanceled()
                    budget.nextChild()
                    if (cursor.isNull(idColumn) || cursor.isNull(nameColumn)) {
                        throw IOException("文件提供方返回的目录项目缺少标识或名称，请重新选择")
                    }
                    if (cursor.getString(nameColumn) == segment) {
                        check(found == null) { "目录中存在同名项目，无法确定要打开哪一个" }; found = cursor.getString(idColumn)
                    }
                }
            } ?: throw IOException("文件提供方暂不可用，请重试")
            document = DocumentsContract.buildDocumentUriUsingTree(tree,
                found ?: throw FileNotFoundException("文件或目录已移动、重命名或删除，请刷新列表后重试"))
        }
        return document
    }
    fun list(root: String, path: String): JSONArray {
        val tree = grant(root)
        require(DocumentsContract.isTreeUri(tree)) { "这是单文件授权，不能列出目录" }
        val document = resolve(tree, path)
        val before = metadata(document)
        check(before.mime == DocumentsContract.Document.MIME_TYPE_DIR) { "当前项目不是目录，请返回上一级" }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
        val listing = DocumentDirectoryListing(path)
        resolver.query(children, arrayOf("document_id", "_display_name", "mime_type", "_size"), null, null, null)?.use { cursor ->
            val columns = DocumentColumns(cursor.columnNames)
            val idColumn = columns.required("document_id")
            val nameColumn = columns.required("_display_name")
            val mimeColumn = columns.required("mime_type")
            val sizeColumn = columns.optional("_size")
            while (cursor.moveToNext()) {
                listing.add(
                    if (cursor.isNull(idColumn)) null else cursor.getString(idColumn),
                    if (cursor.isNull(nameColumn)) null else cursor.getString(nameColumn),
                    if (cursor.isNull(mimeColumn)) null else cursor.getString(mimeColumn),
                    if (sizeColumn < 0 || cursor.isNull(sizeColumn)) null else cursor.getLong(sizeColumn),
                )
            }
        } ?: throw IOException("文件提供方暂不可用，请稍后重试")
        check(hasGrant(root)) { "目录授权已撤销，请重新授权" }
        val current = resolve(tree, path)
        if (current != document || metadata(current) != before) {
            throw IOException("目录在读取期间已移动或变化，请刷新后重试")
        }
        check(hasGrant(root)) { "目录授权已撤销，请重新授权" }
        return JSONArray().apply {
            listing.entries().forEach { entry ->
                put(JSONObject().put("name", entry.name)
                    .put("mediaType", entry.mime)
                    .put("directory", entry.mime == DocumentsContract.Document.MIME_TYPE_DIR)
                    .put("size", entry.size ?: JSONObject.NULL))
            }
        }
    }
    /** Each page comes from one immutable bounded snapshot; revoked/moved grants invalidate it. */
    fun read(root: String, path: String, offset: Long, expectedVersion: String? = null): JSONObject {
        val uri = document(root, path)
        val before = metadata(uri)
        check(before.mime != DocumentsContract.Document.MIME_TYPE_DIR) { "这是目录，请打开其中的文件" }
        check(before.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0) {
            "文件提供方提供的是虚拟文档，当前无法按原格式读取；请在提供方中导出实体文件后重试"
        }
        if (before.size != null && before.size > DocumentSnapshotStore.MAX_FILE_BYTES) {
            throw IOException("文件超过 256 MiB 稳定阅读上限，请选择较小的文件")
        }
        fun checkStable() {
            val current = document(root, path)
            if (current != uri || metadata(current) != before) {
                throw IOException("文件在读取期间已移动或变化，请重新从头读取")
            }
        }
        val identity = DocumentRevision.token(root, path, uri.toString(), null, null)
        val metadataVersion = DocumentRevision.token(uri.toString(), before.name, before.mime, before.size, before.modified)
        val store = DocumentSnapshotStore(context.cacheDir)
        checkStable()
        val snapshot = if (offset == 0L) {
            store.create(identity, metadataVersion, object : DocumentSnapshotStore.Source {
                override fun check() {
                    if (Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException("文件读取已停止")
                    if (!hasGrant(root)) throw SecurityException("文件授权已撤销，请重新授权")
                }
                override fun open(): java.io.InputStream? {
                    checkStable()
                    return resolver.openInputStream(uri)
                }
            })
        } else {
            check(!expectedVersion.isNullOrEmpty()) { "继续读取需要上一段的文件版本，请从头重新读取" }
            store.get(identity, metadataVersion, expectedVersion)
        }
        checkStable()
        val page = store.withPinnedSnapshot(snapshot) { DocumentReadAccess.read(object : DocumentReadAccess.Source {
            override fun isGranted(root: String): Boolean = hasGrant(root)
            override fun open(root: String, path: String): java.io.InputStream? {
                checkStable()
                return FileInputStream(snapshot.file)
            }

            override fun openAt(root: String, path: String, offset: Long): DocumentReadAccess.Opened {
                checkStable()
                if (offset > snapshot.file.length()) throw IOException("读取位置已超出文件末尾，请从头重新读取")
                val stream = FileInputStream(snapshot.file)
                try { stream.channel.position(offset) }
                catch (failure: Exception) { stream.close(); throw failure }
                return DocumentReadAccess.Opened(stream, offset)
            }
        }, root, path, offset) }
        checkStable()
        return JSONObject().put("text", page.text).put("offset", page.offset)
            .put("nextOffset", page.nextOffset).put("truncated", page.truncated)
            .put("version", snapshot.version)
    }

    /** Return one verified, bounded image candidate without exposing its content URI as a path. */
    fun readImage(root: String, path: String, maxBytes: Int, cancellation: CancellationSignal): JSONObject {
        DocumentBinaryReadAccess.limit(maxBytes)
        val uri = document(root, path, cancellation)
        val before = metadata(uri, cancellation)
        check(before.mime != DocumentsContract.Document.MIME_TYPE_DIR) { "这是目录，请打开其中的图片" }
        check(before.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0) {
            "文件提供方提供的是虚拟文档，请先导出实体图片"
        }
        if (before.size != null && before.size > maxBytes) {
            throw IOException("图片超过当前模型或传输允许的大小，请选择较小的图片")
        }
        fun checkStable() {
            cancellation.throwIfCanceled()
            val current = document(root, path, cancellation)
            if (current != uri || metadata(current, cancellation) != before) {
                throw IOException("文件在读取期间已移动或变化，请重新读取图片")
            }
        }
        val source = object : DocumentBinaryReadAccess.Source {
            override fun check() {
                if (Thread.currentThread().isInterrupted) throw InterruptedIOException("图片读取已停止")
                cancellation.throwIfCanceled()
                if (!hasGrant(root)) throw SecurityException("文件授权已撤销，请重新授权")
            }
            override fun open(): java.io.InputStream {
                checkStable()
                return DocumentProviderRead.open(resolver, uri, cancellation)
            }
        }
        checkStable()
        val result = DocumentBinaryReadAccess.read(source, maxBytes)
        checkStable()
        val metadataVersion = DocumentRevision.token(uri.toString(), before.name, before.mime,
            before.size, before.modified)
        val version = DocumentRevision.token(metadataVersion, result.sha256, null,
            result.bytes.size.toLong(), null)
        return JSONObject().put("data", Base64.encodeToString(result.bytes, Base64.NO_WRAP))
            .put("bytes", result.bytes.size).put("sha256", result.sha256)
            .put("version", version).put("name", before.name ?: "图片")
            .put("mimeType", before.mime ?: JSONObject.NULL)
    }
}
