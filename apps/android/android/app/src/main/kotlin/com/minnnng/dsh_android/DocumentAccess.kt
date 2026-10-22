package com.minnnng.dsh_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest

/** Traversal starts from a currently persisted SAF grant, never an arbitrary URI. */
class DocumentAccess(private val context: Context) {
    private val resolver = context.contentResolver
    private data class Metadata(val name: String?, val mime: String?, val flags: Int)

    private fun metadata(uri: Uri, cancellation: CancellationSignal? = null): Metadata =
        resolver.query(uri, arrayOf("_display_name", "mime_type", "flags"), null, null, null, cancellation)?.use { cursor ->
            if (!cursor.moveToFirst()) throw FileNotFoundException("文件或目录已移动或删除，请重新选择或重新授权")
            Metadata(cursor.getString(0), cursor.getString(1), if (cursor.isNull(2)) 0 else cursor.getInt(2))
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
        require(path.length <= 4096) { "路径过长，请授权更近的子目录" }
        var document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        if (path.isEmpty()) return document
        val segments = path.split('/')
        require(segments.none { it.isEmpty() || it == "." || it == ".." || it.contains('\\') }) { "相对路径无效，请从授权目录重新选择" }
        for (segment in segments) {
            cancellation?.throwIfCanceled()
            check(metadata(document, cancellation).mime == DocumentsContract.Document.MIME_TYPE_DIR) { "当前项目不是目录，请返回上一级" }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
            var found: String? = null
            resolver.query(children, arrayOf("document_id", "_display_name"), null, null, null, cancellation)?.use { cursor ->
                while (cursor.moveToNext()) {
                    cancellation?.throwIfCanceled()
                    if (cursor.getString(1) == segment) {
                        check(found == null) { "目录中存在同名项目，无法确定要打开哪一个" }; found = cursor.getString(0)
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
        check(metadata(document).mime == DocumentsContract.Document.MIME_TYPE_DIR) { "当前项目不是目录，请返回上一级" }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
        val items = JSONArray().apply {
            resolver.query(children, arrayOf("_display_name", "mime_type", "_size"), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    check(length() < 10000) { "目录超过 10000 项，请选择子目录" }
                    put(JSONObject().put("name", cursor.getString(0)).put("directory", cursor.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR)
                        .put("size", if (cursor.isNull(2)) JSONObject.NULL else cursor.getLong(2)))
                }
            } ?: throw IOException("文件提供方暂不可用，请稍后重试")
        }
        check(hasGrant(root)) { "目录授权已撤销，请重新授权" }
        return items
    }
    fun read(root: String, path: String, offset: Long): JSONObject {
        fun readableDocument(): Uri {
            val uri = document(root, path)
            val info = metadata(uri)
            check(info.mime != DocumentsContract.Document.MIME_TYPE_DIR) { "这是目录，请打开其中的文件" }
            check(info.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0) {
                "文件提供方提供的是虚拟文档，当前无法按原格式读取；请在提供方中导出实体文件后重试"
            }
            return uri
        }
        val page = DocumentReadAccess.read(object : DocumentReadAccess.Source {
            override fun isGranted(root: String): Boolean = hasGrant(root)
            override fun open(root: String, path: String): java.io.InputStream? =
                resolver.openInputStream(readableDocument())

            override fun openAt(root: String, path: String, offset: Long): DocumentReadAccess.Opened {
                if (offset == 0L) return DocumentReadAccess.Opened(open(root, path), 0)
                val uri = readableDocument()
                val descriptor = try {
                    resolver.openFileDescriptor(uri, "r")
                } catch (failure: FileNotFoundException) {
                    // A provider may expose a file sub-section only through openInputStream.
                    return DocumentReadAccess.Opened(resolver.openInputStream(uri), 0)
                }
                    ?: throw IOException("文件提供方暂不可用，请稍后重试")
                try {
                    if (descriptor.statSize >= 0 && offset > descriptor.statSize) {
                        throw IOException("读取位置已超出文件末尾，文件可能已变化")
                    }
                    val position = try {
                        Os.lseek(descriptor.fileDescriptor, offset, OsConstants.SEEK_SET)
                        offset
                    } catch (failure: ErrnoException) {
                        if (failure.errno != OsConstants.ESPIPE) throw IOException("文件提供方无法定位读取位置，请重新打开文件", failure)
                        0L
                    }
                    return DocumentReadAccess.Opened(ParcelFileDescriptor.AutoCloseInputStream(descriptor), position)
                } catch (failure: Exception) {
                    descriptor.close()
                    throw failure
                }
            }
        }, root, path, offset)
        return JSONObject().put("text", page.text).put("offset", page.offset)
            .put("nextOffset", page.nextOffset).put("truncated", page.truncated)
    }
}
