package com.minnnng.dsh_android

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel

/** Owns one system document picker; only its successful result can persist a read grant. */
class DocumentTransfers(private val activity: Activity) : AutoCloseable {
    private data class Selection(val requestCode: Int, val result: MethodChannel.Result)
    private var pending: Selection? = null

    fun pickDirectory(result: MethodChannel.Result) = pick(true, result)
    fun pickDocument(result: MethodChannel.Result) = pick(false, result)

    private fun pick(directory: Boolean, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "文件选择器已经打开", null)
            return
        }
        val requestCode = if (directory) DIRECTORY_REQUEST else DOCUMENT_REQUEST
        val intent = Intent(if (directory) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        if (directory) intent.addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        else intent.addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        pending = Selection(requestCode, result)
        try {
            activity.startActivityForResult(intent, requestCode)
        } catch (failure: Exception) {
            pending = null
            result.error("picker-unavailable", "无法打开系统文件选择器，请稍后重试", null)
        }
    }

    /** Returns true for this picker's request codes, including abandoned Activity results. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != DIRECTORY_REQUEST && requestCode != DOCUMENT_REQUEST) return false
        val selection = pending?.takeIf { it.requestCode == requestCode } ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            selection.result.success(false)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            selection.result.error("selection-empty", "系统未返回文件，请重新选择", null)
            return true
        }
        try {
            require(uri.scheme == "content") { "请选择系统文件提供方中的文件" }
            require(if (requestCode == DIRECTORY_REQUEST) DocumentsContract.isTreeUri(uri)
                else DocumentsContract.isDocumentUri(activity, uri)) { "所选项目不是可授权的文件或目录" }
            val flags = data.flags
            require(flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 &&
                flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) { "文件提供方未授予持久读取权限，请重新选择" }
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            check(activity.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
                "未能确认文件授权，请重试"
            }
            selection.result.success(true)
        } catch (failure: Exception) {
            selection.result.error("document-permission", failure.message ?: "文件授权失败，请重新选择", null)
        }
        return true
    }

    override fun close() {
        pending?.result?.error("picker-closed", "文件页面已关闭，请重新选择", null)
        pending = null
    }

    private companion object {
        const val DIRECTORY_REQUEST = 4242
        const val DOCUMENT_REQUEST = 4243
    }
}
