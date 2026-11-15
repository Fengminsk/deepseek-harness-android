package com.minnnng.dsh_android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.max

/**
 * 扫码配对的原生侧：系统相机拍一张照片，ZXing 解出其中的二维码文本并交回 Flutter。
 *
 * 相机 intent 用 `MediaStore.ACTION_IMAGE_CAPTURE` + `EXTRA_OUTPUT` 把照片写进
 * `<cacheDir>/pairing-scan/` 下的一次性文件（FileProvider 授权 URI），因此不需要
 * CAMERA 权限。解码在单个 worker 线程上执行；所有结果与错误都在主线程回给
 * MethodChannel，错误码是 `pairing/scan-cancelled` / `pairing/camera-unavailable` /
 * `pairing/decode-failed`。
 *
 * 这里只把二维码内容变成文本：配对协议、CA 指纹校验与设备信任语义都在 Dart 侧
 * （`remote_pairing.dart` / `remote_pairing_flow.dart`），本类不解析链接。
 *
 * 调试构建额外提供两个验收入口（release 由 [BuildConfig.DEBUG] 门控在编译期折叠）：
 * MethodChannel 的 `remote.pairing.scanImage`，以及启动 Intent 的
 * `dshPairingScanImage` extra（解码结果只写 logcat 标签 [LOG_TAG]）。
 */
class PairingQrScan(private val activity: Activity) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
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

    /** 启动系统相机拍二维码；结果经 `onActivityResult` 回到 [onActivityResult]。 */
    fun scan(result: MethodChannel.Result) {
        if (closed) {
            result.error(ERROR_CANCELLED, "界面已关闭，请重新扫码或粘贴配对链接。", null)
            return
        }
        if (pending != null) {
            result.error(ERROR_BUSY, "上一次扫码还没有结束，请稍候。", null)
            return
        }
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

    /** 转发系统相机的返回；返回 false 表示这个 requestCode 不属于扫码。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SCAN) return false
        val result = pending
        val photo = pendingFile
        pending = null
        pendingFile = null
        if (result == null) {
            // Activity 被重建后原来的 Result 已经不存在：照片是本次扫码的一次性文件。
            photo?.delete()
            return true
        }
        if (resultCode != Activity.RESULT_OK) {
            photo?.delete()
            result.success(JSONObject().put("cancelled", true).toString())
            return true
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
                        photoFile != null -> decodePhoto(photoFile)
                        thumbnail != null -> decodeBitmap(thumbnail)
                        else -> null
                    }
                } catch (_: Throwable) {
                    // 照片损坏、内存不足都按「没解出二维码」返回，页面提示重拍。
                    null
                } finally {
                    thumbnail?.recycle()
                    photo?.delete()
                }
                main.post {
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
        return true
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
                    decodePhoto(file)
                } catch (_: Throwable) {
                    null
                }
                main.post {
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
                    file?.let { decodePhoto(it) }
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

    /** 解一张照片：先采样到可读尺寸，失败再按上限尺寸试一次（含 90/180/270 旋转）。 */
    private fun decodePhoto(file: File): String? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null
        val preferred = loadBitmap(file.absolutePath, width, height, PREFERRED_MAX_DIMENSION)
            ?: return null
        try {
            decodeBitmap(preferred)?.let { return it }
        } finally {
            preferred.recycle()
        }
        if (max(width, height) <= PREFERRED_MAX_DIMENSION) return null
        val full = loadBitmap(file.absolutePath, width, height, MAX_MAX_DIMENSION) ?: return null
        try {
            return decodeBitmap(full)
        } finally {
            full.recycle()
        }
    }

    private fun loadBitmap(path: String, width: Int, height: Int, maxDimension: Int): Bitmap? =
        try {
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
                inSampleSize = sampleSize(width, height, maxDimension)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            })
        } catch (_: Throwable) {
            null
        }

    private fun sampleSize(width: Int, height: Int, maxDimension: Int): Int {
        var sample = 1
        while (max(width, height) / sample > maxDimension) sample *= 2
        return sample
    }

    /** 依次尝试 0/90/180/270 度（相机照片可能带方向）；任一方向解出即返回。 */
    private fun decodeBitmap(bitmap: Bitmap): String? {
        for (degrees in intArrayOf(0, 90, 180, 270)) {
            val candidate = if (degrees == 0) bitmap else rotated(bitmap, degrees) ?: continue
            try {
                val text = decodeOnce(candidate)
                if (!text.isNullOrBlank()) return text
            } catch (_: Exception) {
                // 该方向解不出属于正常未命中，继续下一个方向。
            } catch (_: OutOfMemoryError) {
                return null
            } finally {
                if (candidate !== bitmap) candidate.recycle()
            }
        }
        return null
    }

    private fun rotated(bitmap: Bitmap, degrees: Int): Bitmap? = try {
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    } catch (_: Throwable) {
        null
    }

    /** 一次 ZXing 解码：QR 专用提示 + TRY_HARDER + 反色也试。 */
    private fun decodeOnce(bitmap: Bitmap): String? {
        val width = bitmap.width
        val height = bitmap.height
        if (width < 16 || height < 16 || width.toLong() * height > MAX_PIXELS) return null
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val binary = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, height, pixels)))
        val reader = MultiFormatReader()
        reader.setHints(SCAN_HINTS)
        return try {
            reader.decodeWithState(binary)?.text
        } finally {
            reader.reset()
        }
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
        private const val REQUEST_SCAN = 5354
        private const val SCAN_DIRECTORY = "pairing-scan"

        /** 启动 Intent 的调试解码参数；只有 debug 构建读取（release 不生效）。 */
        private const val EXTRA_SCAN_IMAGE = "dshPairingScanImage"

        /** 验收脚本读取的 logcat 标签。 */
        private const val LOG_TAG = "DshPairingScan"

        /** 第一遍采样的最长边；手机相机原图远大于它，先降采样保证 TRY_HARDER 的速度。 */
        private const val PREFERRED_MAX_DIMENSION = 1600

        /** 采样图失败后的第二遍最长边（仍对内存设上限）。 */
        private const val MAX_MAX_DIMENSION = 4096
        private const val MAX_PIXELS = 4096L * 4096L

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

        /** QR 专用解码提示：只认二维码，困难模式，并尝试黑白反色。 */
        private val SCAN_HINTS: MutableMap<DecodeHintType, Any> = hashMapOf(
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            DecodeHintType.TRY_HARDER to true,
            DecodeHintType.CHARACTER_SET to "UTF-8",
            DecodeHintType.ALSO_INVERTED to true,
        )
    }
}
