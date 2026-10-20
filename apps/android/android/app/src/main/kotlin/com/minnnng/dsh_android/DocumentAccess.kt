package com.minnnng.dsh_android

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction

/** Traversal starts from a currently persisted SAF grant, never an arbitrary URI. */
class DocumentAccess(private val context: Context) {
    private val resolver = context.contentResolver
    private fun id(uri: Uri) = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
        .joinToString("") { "%02x".format(it) }
    fun roots(): JSONArray = JSONArray().apply {
        resolver.persistedUriPermissions.filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }.forEach {
            put(JSONObject().put("id", id(it.uri)).put("name", DocumentsContract.getTreeDocumentId(it.uri)))
        }
    }
    private fun tree(root: String): Uri = resolver.persistedUriPermissions.firstOrNull {
        it.isReadPermission && id(it.uri) == root
    }?.uri ?: throw SecurityException("目录授权不存在或已撤销")
    private fun resolve(tree: Uri, path: String): Uri {
        var document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        if (path.isEmpty()) return document
        val segments = path.split('/')
        require(segments.none { it.isEmpty() || it == "." || it == ".." || it.contains('\\') }) { "Invalid relative path" }
        for (segment in segments) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
            var found: String? = null
            resolver.query(children, arrayOf("document_id", "_display_name"), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) if (cursor.getString(1) == segment) {
                    check(found == null) { "Ambiguous document name" }; found = cursor.getString(0)
                }
            }
            document = DocumentsContract.buildDocumentUriUsingTree(tree, found ?: throw IllegalArgumentException("File not found: $segment"))
        }
        return document
    }
    fun list(root: String, path: String): JSONArray {
        val tree = tree(root)
        val document = resolve(tree, path)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(document))
        return JSONArray().apply {
            resolver.query(children, arrayOf("_display_name", "mime_type", "_size"), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    check(length() < 10000) { "目录超过 10000 项，请选择子目录" }
                    put(JSONObject().put("name", cursor.getString(0)).put("directory", cursor.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR)
                        .put("size", if (cursor.isNull(2)) JSONObject.NULL else cursor.getLong(2)))
                }
            } ?: throw IllegalStateException("Directory provider is unavailable")
        }
    }
    fun read(root: String, path: String, offset: Int): JSONObject {
        require(offset >= 0) { "Invalid byte offset" }
        val document = resolve(tree(root), path)
        val bytes = resolver.openInputStream(document)?.use { stream ->
            var remaining = offset.toLong()
            while (remaining > 0) {
                val skipped = stream.skip(remaining)
                if (skipped == 0L) {
                    require(stream.read() >= 0) { "Byte offset is beyond the end of the file" }
                    remaining--
                } else remaining -= skipped
            }
            // InputStream.readNBytes is unavailable on older supported Android releases.
            val buffer = ByteArray(262148)
            var total = 0
            while (total < buffer.size) {
                val read = stream.read(buffer, total, buffer.size - total)
                if (read < 0) break
                if (read == 0) {
                    val byte = stream.read()
                    if (byte < 0) break
                    buffer[total++] = byte.toByte()
                } else total += read
            }
            buffer.copyOf(total)
        } ?: throw IllegalStateException("File provider is unavailable")
        require(!bytes.contains(0)) { "当前仅支持文本文件" }
        val input = ByteBuffer.wrap(bytes, 0, minOf(bytes.size, 262144))
        val text = CharBuffer.allocate(262144)
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val result = decoder.decode(input, text, bytes.size <= 262144)
        require(!result.isError) { "文件不是有效 UTF-8 文本，或读取位置不在字符边界" }
        val count = input.position()
        text.flip()
        return JSONObject().put("text", text.toString())
            .put("offset", offset).put("nextOffset", offset + count).put("truncated", bytes.size > count)
    }
}
