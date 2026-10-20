package com.minnnng.dsh_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Traversal starts from a currently persisted SAF grant, never an arbitrary URI. */
class DocumentAccess(private val context: Context) {
    private val resolver = context.contentResolver
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
                resolver.query(document, arrayOf("_display_name", "mime_type"), null, null, null)?.use { cursor ->
                    check(cursor.moveToFirst()) { "文件或目录已移动或删除，请重新授权" }
                    item.put("name", cursor.getString(0) ?: item.getString("name"))
                    item.put("available", true)
                } ?: throw IllegalStateException("文件提供方暂不可用，请重试")
            } catch (failure: Exception) {
                item.put("available", false).put("error", "无法访问此授权项目；请重试，或撤销后重新授权。")
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
        var document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        if (path.isEmpty()) return document
        val segments = path.split('/')
        require(segments.none { it.isEmpty() || it == "." || it == ".." || it.contains('\\') }) { "Invalid relative path" }
        for (segment in segments) {
            cancellation?.throwIfCanceled()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
            var found: String? = null
            resolver.query(children, arrayOf("document_id", "_display_name"), null, null, null, cancellation)?.use { cursor ->
                while (cursor.moveToNext()) {
                    cancellation?.throwIfCanceled()
                    if (cursor.getString(1) == segment) {
                        check(found == null) { "Ambiguous document name" }; found = cursor.getString(0)
                    }
                }
            }
            document = DocumentsContract.buildDocumentUriUsingTree(tree, found ?: throw IllegalArgumentException("File not found: $segment"))
        }
        return document
    }
    fun list(root: String, path: String): JSONArray {
        val tree = grant(root)
        require(DocumentsContract.isTreeUri(tree)) { "这是单文件授权，不能列出目录" }
        val document = resolve(tree, path)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
        val items = JSONArray().apply {
            resolver.query(children, arrayOf("_display_name", "mime_type", "_size"), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    check(length() < 10000) { "目录超过 10000 项，请选择子目录" }
                    put(JSONObject().put("name", cursor.getString(0)).put("directory", cursor.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR)
                        .put("size", if (cursor.isNull(2)) JSONObject.NULL else cursor.getLong(2)))
                }
            } ?: throw IllegalStateException("Directory provider is unavailable")
        }
        check(hasGrant(root)) { "目录授权已撤销，请重新授权" }
        return items
    }
    fun read(root: String, path: String, offset: Int): JSONObject {
        val page = DocumentReadAccess.read(object : DocumentReadAccess.Source {
            override fun isGranted(root: String): Boolean = hasGrant(root)
            override fun open(root: String, path: String) = resolver.openInputStream(document(root, path))
        }, root, path, offset)
        return JSONObject().put("text", page.text).put("offset", page.offset)
            .put("nextOffset", page.nextOffset).put("truncated", page.truncated)
    }
}
