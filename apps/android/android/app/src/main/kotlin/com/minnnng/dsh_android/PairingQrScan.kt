package com.minnnng.dsh_android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * 扫码配对的 MethodChannel 接线：打开应用内连续扫码页 [PairingScanActivity]，把
 * 扫到的文本交回 Flutter；相机不可用时退回系统相机拍照并用 ZXing 识别。
 *
 * 首选路径是连续取景：`PairingScanActivity` 在应用内用 CameraX 预览并逐帧解码，
 * 用户对准电脑屏幕即可自动识别，不需要按快门，也不受系统相机回执只有缩略图的
 * 影响；识别慢时还可以在扫码页「拍照识别」或从相册选图。应用内相机无法启动
 * （缺少相机硬件、驱动失败）时才退回 `MediaStore.ACTION_IMAGE_CAPTURE` 的一次性
 * 拍照；权限被拒绝则不自动改拍照，直接把原因交回页面。
 *
 * 这里只把二维码内容变成文本：配对协议、CA 指纹校验与设备信任语义都在 Dart 侧
 * （`remote_pairing.dart` / `remote_pairing_flow.dart`），本类不解析链接。
 *
 * 调试构建额外提供两个验收入口（release 由 [BuildConfig.DEBUG] 门控在编译期折叠）：
 * MethodChannel 的 `remote.pairing.scanImage`，以及启动 Intent 的
 * `dshPairingScanImage` extra（解码结果只写 logcat 标签 [LOG_TAG]）。
 */
class PairingQrScan(private val activity: Activity) : AutoCloseable {
    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "dsh-pairing-scan") }
    private var pending: MethodChannel.Result? = null
    private var pendingFile: File? = null
    private var closed = false

    init {
        // 上一次进程被杀时留在 cache 里的照片由这里回收；解码只在本次扫码期间发生。
        try {
            directory()?.listFiles()?.forEach { file ->
                if (System.currentTimeMillis() - file.lastModified() > STALE_MILLIS) file.delete()
            }
        } catch (_: Exception) {
            // 清理失败不阻塞扫码：缓存目录最终由系统回收。
        }
    }

    /** 打开应用内连续扫码页；结果经 `onActivityResult` 回到 [onActivityResult]。 */
    fun scan(result: MethodChannel.Result) {
        if (closed) {
            result.error(ERROR_CANCELLED, "界面已关闭，请重新扫码或粘贴配对链接。", null)
            return
        }
        if (pending != null) {
            result.error(ERROR_BUSY, "上一次扫码还没有结束，请稍候。", null)
            return
        }
        pending = result
        val live = Intent(activity, PairingScanActivity::class.java)
        try {
            activity.startActivityForResult(live, REQUEST_LIVE_SCAN)
        } catch (_: ActivityNotFoundException) {
            pending = null
            startSystemCamera(result)
        } catch (_: Exception) {
            pending = null
            result.error(ERROR_CAMERA, "无法打开扫码页面，请改为粘贴配对链接。", null)
        }
    }

    /** 系统相机拍照识别：应用内相机不可用时的兜底。 */
    private fun startSystemCamera(result: MethodChannel.Result) {
        val directory = directory()
        if (directory == null) {
            result.error(ERROR_CAMERA, "无法准备扫码缓存目录，请改为粘贴配对链接。", null)
            return
        }
        val target = File(directory, "scan-${UUID.randomUUID()}.jpg")
        val output = try {
            FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", target)
        } catch (_: Exception) {
            result.error(ERROR_CAMERA, "无法准备相机输出位置，请改为粘贴配对链接。", null)
            return
        }
        val capture = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, output)
            clipData = ClipData.newRawUri("pairing-scan", output)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (capture.resolveActivity(activity.packageManager) == null) {
            result.error(ERROR_CAMERA, "这台手机上没有可用的相机应用，请改为粘贴配对链接。", null)
            return
        }
        pending = result
        pendingFile = target
        try {
            activity.startActivityForResult(capture, REQUEST_SCAN)
        } catch (_: ActivityNotFoundException) {
            clearPendingFile()
            pending = null
            result.error(ERROR_CAMERA, "这台手机上没有可用的相机应用，请改为粘贴配对链接。", null)
        } catch (_: Exception) {
            clearPendingFile()
            pending = null
            result.error(ERROR_CAMERA, "无法打开相机，请改为粘贴配对链接。", null)
        }
    }

    /** 转发扫码/拍照页面的返回；返回 false 表示这个 requestCode 不属于扫码。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean = when (requestCode) {
        REQUEST_LIVE_SCAN -> {
            handleLiveScanResult(resultCode, data)
            true
        }
        REQUEST_SCAN -> {
            handleSystemCameraResult(resultCode, data)
            true
        }
        else -> false
    }

    /** 应用内连续扫码的返回：成功回传文本，取消按取消处理，相机失败退回拍照。 */
    private fun handleLiveScanResult(resultCode: Int, data: Intent?) {
        val result = pending
        pending = null
        if (result == null) return
        when (resultCode) {
            Activity.RESULT_OK -> {
                val text = data?.getStringExtra(PairingScanActivity.EXTRA_TEXT)
                if (text.isNullOrBlank()) {
                    result.error(ERROR_DECODE, "扫码没有返回结果，请重试或改为粘贴配对链接。", null)
                } else {
                    result.success(JSONObject().put("text", text).toString())
                }
            }
            Activity.RESULT_FIRST_USER -> {
                val code = data?.getStringExtra(PairingScanActivity.EXTRA_ERROR_CODE) ?: ERROR_DECODE
                val message = data?.getStringExtra(PairingScanActivity.EXTRA_ERROR_MESSAGE)
                    ?: "扫码页面启动失败，请改为粘贴配对链接。"
                if (code == ERROR_CAMERA) {
                    // 应用内相机不可用（无相机硬件/驱动失败）：退回系统相机拍照。
                    startSystemCamera(result)
                } else {
                    result.error(code, message, null)
                }
            }
            else -> result.success(JSONObject().put("cancelled", true).toString())
        }
    }

    /** 系统相机拍照的返回：解码 EXTRA_OUTPUT 照片，少数相机只回缩略图时解缩略图。 */
    private fun handleSystemCameraResult(resultCode: Int, data: Intent?) {
        val result = pending
        val photo = pendingFile
        pending = null
        pendingFile = null
        if (result == null) {
            // Activity 被重建后原来的 Result 已经不存在：照片是本次扫码的一次性文件。
            photo?.delete()
            return
        }
        if (resultCode != Activity.RESULT_OK) {
            photo?.delete()
            result.success(JSONObject().put("cancelled", true).toString())
            return
        }
        // 少数相机应用忽略 EXTRA_OUTPUT，把缩略图放进 `data` extra；两路都试。
        @Suppress("DEPRECATION")
        val thumbnail = data?.getParcelableExtra<Bitmap>("data")
        val photoFile = if (photo != null && photo.isFile && photo.length() > 0) photo else null
        val hasPhoto = photoFile != null
        try {
            worker.execute {
                val text = try {
                    when {
                        photoFile != null -> PairingQrDecoder.decodePhoto(photoFile)
                        thumbnail != null -> PairingQrDecoder.decodeBitmap(thumbnail)
                        else -> null
                    }
                } catch (_: Throwable) {
                    // 照片损坏、内存不足都按「没解出二维码」返回，页面提示重拍。
                    null
                } finally {
                    thumbnail?.recycle()
                    photo?.delete()
                }
                activity.runOnUiThread {
                    val failure = if (!hasPhoto && thumbnail == null) {
                        "没有拿到相机拍摄的照片，请重试或改为粘贴配对链接。"
                    } else {
                        "照片里没有识别到配对二维码。请对准电脑上的二维码重拍，或改为粘贴配对链接。"
                    }
                    if (text.isNullOrBlank()) result.error(ERROR_DECODE, failure, null)
                    else result.success(JSONObject().put("text", text).toString())
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error(ERROR_CANCELLED, "扫码已结束，请重新扫码。", null)
        }
    }

    /**
     * 调试构建：解码一张本机图片里的二维码，供真机验收脚本使用。
     *
     * 只接受 `<cacheDir>/pairing-scan/`、本包 `files/` 与 `<externalFilesDir>/` 下
     * 的普通文件（canonical 校验，`files/` 是验收脚本 `adb push` 的落点）。release
     * 编译期本方法体被折叠，包内不存在从图片文件解码的能力。
     */
    fun decodeFile(path: String?, result: MethodChannel.Result) {
        if (!BuildConfig.DEBUG) {
            result.error(ERROR_DECODE, "当前版本不支持从图片文件解码。", null)
            return
        }
        if (closed) {
            result.error(ERROR_CANCELLED, "界面已关闭，请重新扫码。", null)
            return
        }
        if (path.isNullOrBlank()) {
            result.error(ERROR_DECODE, "没有给出图片路径。", null)
            return
        }
        val file = acceptedFile(path)
        if (file == null) {
            result.error(
                ERROR_DECODE,
                "图片路径不在允许的目录内（仅 cache/pairing-scan 或本应用 files 之下）。",
                null,
            )
            return
        }
        try {
            worker.execute {
                val text = try {
                    PairingQrDecoder.decodePhoto(file)
                } catch (_: Throwable) {
                    null
                }
                activity.runOnUiThread {
                    if (text.isNullOrBlank()) {
                        result.error(ERROR_DECODE, "图片里没有识别到二维码。", null)
                    } else {
                        result.success(JSONObject().put("text", text).toString())
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error(ERROR_CANCELLED, "界面已关闭，请重新扫码。", null)
        }
    }

    /**
     * 调试构建：把启动 Intent 的 `dshPairingScanImage` 路径解码成二维码文本。
     *
     * 结果只写 logcat（[LOG_TAG]），供 `tool/acceptance-pairing-scan.mjs` 断言
     * ZXing 解码链路；相机流程本身需要人手持无法自动化。release 编译期折叠。
     */
    fun decodeLaunchImage(intent: Intent) {
        if (!BuildConfig.DEBUG) return
        val raw = intent.getStringExtra(EXTRA_SCAN_IMAGE) ?: return
        intent.removeExtra(EXTRA_SCAN_IMAGE)
        val path = raw.trim()
        if (path.isEmpty()) return
        val file = acceptedFile(path)
        try {
            worker.execute {
                val text = try {
                    file?.let { PairingQrDecoder.decodePhoto(it) }
                } catch (_: Throwable) {
                    null
                }
                if (text.isNullOrBlank()) {
                    Log.i(LOG_TAG, "pairing-scan-image error code=$ERROR_DECODE path=$path")
                } else {
                    Log.i(LOG_TAG, "pairing-scan-image ok text=$text")
                }
            }
        } catch (_: RejectedExecutionException) {
            Log.i(LOG_TAG, "pairing-scan-image error code=$ERROR_CANCELLED path=$path")
        }
    }

    /** 取消未完成的扫码（Activity 收到新 Intent 或销毁时调用），并回复取消错误。 */
    fun cancelPending() {
        val result = pending ?: return
        pending = null
        clearPendingFile()
        result.error(ERROR_CANCELLED, "扫码已取消。", null)
    }

    override fun close() {
        cancelPending()
        closed = true
        worker.shutdownNow()
    }

    private fun clearPendingFile() {
        pendingFile?.delete()
        pendingFile = null
    }

    private fun directory(): File? = try {
        val root = File(activity.cacheDir, SCAN_DIRECTORY)
        if (!root.mkdirs() && !root.isDirectory) null else root.canonicalFile.takeIf { it.isDirectory }
    } catch (_: Exception) {
        null
    }

    /** 验收脚本 `adb push` 的落点（本包外部 files 目录）与内部 files 目录。 */
    private fun acceptedRoots(): List<File> = listOfNotNull(
        directory(),
        activity.filesDir,
        activity.getExternalFilesDir(null),
    ).mapNotNull { root -> try { root.canonicalFile } catch (_: Exception) { null } }

    /** 只接受应用私有目录下、canonical 校验通过的图片文件。 */
    private fun acceptedFile(path: String): File? {
        val candidate = File(path)
        if (!candidate.isAbsolute) return null
        val canonical = try { candidate.canonicalFile } catch (_: Exception) { return null }
        if (!canonical.isFile) return null
        if (canonical.length() > MAX_IMAGE_BYTES) return null
        val accepted = acceptedRoots().any { root ->
            canonical == root || canonical.path.startsWith(root.path + File.separator)
        }
        return canonical.takeIf { accepted }
    }

    companion object {
        /** 应用内连续扫码页的 requestCode。 */
        private const val REQUEST_LIVE_SCAN = 5355

        /** 系统相机拍照兜底的 requestCode。 */
        private const val REQUEST_SCAN = 5354
        private const val SCAN_DIRECTORY = "pairing-scan"

        /** 启动 Intent 的调试解码参数；只有 debug 构建读取（release 不生效）。 */
        private const val EXTRA_SCAN_IMAGE = "dshPairingScanImage"

        /** 验收脚本读取的 logcat 标签。 */
        private const val LOG_TAG = "DshPairingScan"

        /** 调试解码通道的图片上限。 */
        private const val MAX_IMAGE_BYTES = 32L * 1024 * 1024

        /** 上次进程残留照片的保留时长。 */
        private const val STALE_MILLIS = 24L * 60 * 60 * 1000

        /** 用户取消扫码（native 侧主动取消或页面关闭）。 */
        const val ERROR_CANCELLED = "pairing/scan-cancelled"

        /** 没有可用的相机应用 / 无法启动相机。 */
        const val ERROR_CAMERA = "pairing/camera-unavailable"

        /** 照片读不到或其中没有可解码的二维码。 */
        const val ERROR_DECODE = "pairing/decode-failed"

        /** 上一次扫码尚未结束（Dart 页面已禁重入，这里是防御）。 */
        private const val ERROR_BUSY = "pairing/scan-busy"
    }
}
