package com.minnnng.dsh_android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max

/**
 * 二维码解码：应用内相机预览的实时帧、系统相册选中的图片，以及调试验收用的图片
 * 文件共用同一套 ZXing 提示（只认二维码、困难模式、反色也试）。
 *
 * 相机帧走进 [decodeRgbaFrame]：ImageAnalysis 以 RGBA_8888 输出，这里只把每个
 * 像素折算成灰度，再交给 ZXing。二维码本身与取景旋转无关，实时帧不做旋转尝试，
 * 以便在连拍帧上保持解码速度；图片文件可能带方向信息，所以 [decodeBitmap] 会
 * 依次尝试 0/90/180/270 度，并在整图未命中时再解中心裁切。
 *
 * 所有方法都返回二维码文本或 null；异常一律视为“这张图/这一帧没有二维码”。
 */
object PairingQrDecoder {
    /** 第一遍采样图的最长边；相机原图远大于它，先降采样保证解码速度。 */
    private const val PREFERRED_MAX_DIMENSION = 1600

    /** 采样图失败后的第二遍最长边（仍对内存设上限）。 */
    private const val MAX_MAX_DIMENSION = 4096

    /** 单张图片参与解码的像素上限，避免超大照片把手机撑爆。 */
    private const val MAX_PIXELS = 4096L * 4096L

    /** 整图未命中时按这些比例解中心裁切；二维码常被拍在画面中央。 */
    private val CENTER_CROP_FRACTIONS = doubleArrayOf(0.66, 0.5)

    /** 只认二维码的提示；`ALSO_INVERTED` 让深色底浅色码也能解。 */
    private val SCAN_HINTS: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.CHARACTER_SET to "UTF-8",
        DecodeHintType.ALSO_INVERTED to true,
    )

    /**
     * 解一帧相机 RGBA_8888 图像。
     *
     * @param buffer 图像平面，像素按 RGBA 排列。
     * @param rowStride 每行字节数（可能大于 `width * pixelStride`）。
     * @param pixelStride 相邻像素的字节步长（RGBA 为 4）。
     * @param width 图像宽（像素）。
     * @param height 图像高（像素）。
     * @return 二维码文本，未命中返回 null。
     */
    fun decodeRgbaFrame(buffer: ByteBuffer, rowStride: Int, pixelStride: Int, width: Int, height: Int): String? {
        if (width < 16 || height < 16 || pixelStride < 3) return null
        val data = ByteArray(width * height)
        val row = ByteArray(rowStride.coerceAtLeast(width * pixelStride))
        buffer.rewind()
        var written = 0
        for (y in 0 until height) {
            val available = buffer.remaining()
            if (available <= 0) break
            val length = minOf(row.size, available)
            buffer.get(row, 0, length)
            var source = 0
            val target = written
            for (x in 0 until width) {
                if (source + 2 >= length) break
                val red = row[source].toInt() and 0xFF
                val green = row[source + 1].toInt() and 0xFF
                val blue = row[source + 2].toInt() and 0xFF
                data[target + x] = ((77 * red + 150 * green + 29 * blue) shr 8).toByte()
                source += pixelStride
            }
            written += width
        }
        val source = PlanarYUVLuminanceSource(data, width, height, 0, 0, width, height, false)
        return decodeSource(source)
    }

    /**
     * 解一张图片：依次尝试 0/90/180/270 度，整图未命中再解中心裁切。
     *
     * @param bitmap 已解码的位图。
     * @return 二维码文本，未命中返回 null。
     */
    fun decodeBitmap(bitmap: Bitmap): String? {
        decodeRotations(bitmap)?.let { return it }
        for (fraction in CENTER_CROP_FRACTIONS) {
            val cropped = centerCrop(bitmap, fraction) ?: continue
            try {
                decodeRotations(cropped)?.let { return it }
            } finally {
                cropped.recycle()
            }
        }
        return null
    }

    /**
     * 解一张图片文件：先按 [PREFERRED_MAX_DIMENSION] 采样，未命中再按更大上限试一次。
     *
     * @param file 可读的图片文件。
     * @return 二维码文本，未命中返回 null。
     */
    fun decodePhoto(file: File): String? {
        if (!file.isFile || file.length() <= 0) return null
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

    /**
     * 解一张系统相册选中的图片。
     *
     * @param context 用于打开 `content://` 输入流。
     * @param uri 相册返回的图片 URI。
     * @return 二维码文本，未命中返回 null。
     */
    fun decodeUri(context: Context, uri: Uri): String? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, bounds)
        } ?: return null
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(width, height, PREFERRED_MAX_DIMENSION)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = context.contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, options)
        } ?: return null
        return try {
            decodeBitmap(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    /** 依次尝试 0/90/180/270 度（图片可能带方向）；任一方向解出即返回。 */
    private fun decodeRotations(bitmap: Bitmap): String? {
        for (degrees in intArrayOf(0, 90, 180, 270)) {
            val candidate = if (degrees == 0) bitmap else rotated(bitmap, degrees) ?: continue
            try {
                decodeBitmapOnce(candidate)?.let { return it }
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

    /** 裁出画面中央的 `fraction` 比例；与整图相同的小图不值得再解一遍。 */
    private fun centerCrop(bitmap: Bitmap, fraction: Double): Bitmap? {
        val width = (bitmap.width * fraction).toInt()
        val height = (bitmap.height * fraction).toInt()
        if (width < 16 || height < 16) return null
        if (width == bitmap.width && height == bitmap.height) return null
        val left = (bitmap.width - width) / 2
        val top = (bitmap.height - height) / 2
        return try {
            Bitmap.createBitmap(bitmap, left, top, width, height)
        } catch (_: Throwable) {
            null
        }
    }

    /** 一次 ZXing 解码：QR 专用提示 + TRY_HARDER + 反色也试。 */
    private fun decodeBitmapOnce(bitmap: Bitmap): String? {
        val width = bitmap.width
        val height = bitmap.height
        if (width < 16 || height < 16 || width.toLong() * height > MAX_PIXELS) return null
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        return decodeSource(RGBLuminanceSource(width, height, pixels))
    }

    /** 对灰度源做一次解码并复位共享提示；未命中与解析错误都返回 null。 */
    private fun decodeSource(source: LuminanceSource): String? {
        val reader = MultiFormatReader()
        reader.setHints(SCAN_HINTS)
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))?.text
        } catch (_: ReaderException) {
            null
        } finally {
            reader.reset()
        }
    }

    private fun loadBitmap(path: String, width: Int, height: Int, maxDimension: Int): Bitmap? = try {
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
}
