package com.minnnng.dsh_android

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.JsonReader
import android.util.JsonToken
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.StringReader
import java.util.UUID

/** Native recovery exists before libnode and exposes only fixed private files. */
class RecoveryRuntime(private val context: Context, val generation: String = UUID.randomUUID().toString()) {
    val files = RecoveryFiles(context.noBackupFilesDir.toPath(), generation, { directory ->
        try {
            val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
            try {
                if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode))
                    throw IOException("Sync target is not a directory")
                Os.fsync(descriptor)
            } finally { Os.close(descriptor) }
        } catch (error: android.system.ErrnoException) { throw IOException("Directory sync failed", error) }
    }, { id, text ->
        if (id == "profile-manifest") {
            try {
                JsonReader(StringReader(text)).use { reader ->
                    reader.isLenient = false
                    require(reader.peek() == JsonToken.BEGIN_OBJECT)
                    reader.skipValue()
                    require(reader.peek() == JsonToken.END_DOCUMENT)
                }
            }
            catch (_: Exception) {
                throw RecoveryFiles.Failure("recovery/json-invalid", "配置包清单必须是 JSON 对象；草稿未写入")
            }
        }
    })

    fun mode(): Array<String> = files.mode()
    fun setMode(mode: String, token: String) = files.setMode(mode, token)
    fun runtimeHash(): String = context.assets.open("runtime/runtime.sha256").bufferedReader().use {
        it.readText().trim().also { hash ->
            require(hash.matches(Regex("[0-9a-f]{64}"))) { "Invalid packaged runtime hash" }
        }
    }

    fun call(method: String, params: JSONObject, mode: String, nodeStarted: Boolean,
            mutationAllowed: Boolean, stage: String, failure: String?): JSONObject {
        if (method in setOf("write", "restore", "runtimeRepair")) {
            if (mode != "maintenance" || nodeStarted || !mutationAllowed)
                throw files.rejection("recovery/mode-required", "维护静止状态尚未确认，未允许修改配置", params.optString("requestId"))
            if (params.optString("generation") != generation)
                throw files.rejection("recovery/generation-conflict", "服务已更换，请重新读取配置并保留草稿", params.optString("requestId"))
        }
        return when (method) {
            "inspect" -> JSONObject()
                .put("mode", mode).put("generation", generation).put("nodeStarted", nodeStarted)
                .put("mutationAllowed", mutationAllowed)
                .put("files", JSONArray(files.files()))
                .put("backups", JSONArray(files.backups()))
                .put("operations", JSONArray(files.operations()))
                .put("boot", JSONObject().put("stage", stage)
                    .put("error", if (failure == null) JSONObject.NULL else "服务启动或维护检查未完成；可主动查看私有诊断日志")
                    .put("runtimeSha256", try { runtimeHash() } catch (_: Exception) { JSONObject.NULL })
                    .put("logAvailable", File(context.noBackupFilesDir, "dsh/runtime-stderr.log").isFile)).also { result ->
                    try {
                        val selected = this.mode()
                        result.put("preferredMode", selected[0]).put("preferredModeToken", selected[1])
                            .put("preferenceError", JSONObject.NULL)
                    } catch (_: Exception) {
                        result.put("preferredMode", JSONObject.NULL).put("preferredModeToken", JSONObject.NULL)
                            .put("preferenceError", "服务模式偏好无法读取，下次启动将保持维护模式")
                    }
                }
            "read" -> if (params.getString("fileId") == "runtime-log") JSONObject(files.log())
                else JSONObject(files.read(params.getString("fileId")))
            "readBackup" -> JSONObject(files.readBackup(params.getString("backupId")))
            "write" -> JSONObject(files.write(params.getString("fileId"), params.getString("expectedSha256"),
                params.getString("text"), params.getString("requestId")))
            "restore" -> JSONObject(files.restore(params.getString("backupId"), params.getString("expectedSha256"),
                params.getString("requestId")))
            "receipt" -> JSONObject(files.receipt(params.getString("requestId")))
            "runtimeRepair" -> {
                val expected = params.getString("expectedRuntimeSha256")
                if (expected != runtimeHash())
                    throw files.rejection("recovery/runtime-conflict", "安装包运行时版本已变化，请重新核对", params.optString("requestId"))
                JSONObject(files.runtimeRepair(expected, params.getString("requestId")))
            }
            else -> throw RecoveryFiles.Failure("recovery/method-invalid", "不支持的恢复操作")
        }
    }
}
