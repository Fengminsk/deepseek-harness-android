package com.minnnng.dsh_android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Size
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * 扫码配对的应用内相机页：连续取景、逐帧用 ZXing 解二维码，解出后立即返回。
 *
 * 相机用 CameraX 在应用内完成，不把拍照结果交给系统相机应用：
 * - 连续取景：预览 + ImageAnalysis 逐帧解码，用户只需把二维码放进取景框；
 * - 拍照识别：ImageCapture 抓一张高分辨率照片再解码，屏幕反光/距离不合适时手动
 *   拍一张往往比实时帧更容易识别；
 * - 从相册选择：复用同一套图片解码（[PairingQrDecoder.decodeUri]）；
 * - 手电筒：设备有闪光灯时提供开关，低光下照亮屏幕。
 *
 * 结果经 Activity Result 回到 `MainActivity`，由 `PairingQrScan` 转成
 * `dsh/runtime` 的扫码回执：成功写 [EXTRA_TEXT]，取消是 `RESULT_CANCELED`，相机
 * 不可用/没有权限则以 `RESULT_FIRST_USER` + [EXTRA_ERROR_CODE]/[EXTRA_ERROR_MESSAGE]
 * 说明原因（相机不可用时 `PairingQrScan` 还会退回系统相机拍照识别）。
 */
class PairingScanActivity : ComponentActivity() {
    private lateinit var previewView: PreviewView
    private lateinit var hintView: TextView
    private lateinit var photoButton: Button
    private lateinit var torchButton: Button
    private lateinit var galleryButton: Button
    private lateinit var cancelButton: Button
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-pairing-scan-live")
    }
    private var lastAttemptAt = 0L
    private var finished = false

    /** 拍照识别进行中：按钮禁点，避免连拍与重复解码。 */
    private var photoBusy = false
    private var torchOn = false

    /** 正在写入/解码的一次性照片；取消或销毁时删除。 */
    private var pendingPhoto: File? = null

    private val requestCameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            startCamera()
        } else {
            finishWithError(
                ERROR_PERMISSION,
                "没有相机权限，无法在应用内连续扫码。请改为粘贴配对链接，或在系统设置里允许相机权限后重试。",
            )
        }
    }

    private val pickImage = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri == null || finished) return@registerForActivityResult
        decodePickedImage(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(buildContentView())
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) startCamera() else requestCameraPermission.launch(Manifest.permission.CAMERA)
    }

    /** 取景框 + 底部提示、「拍照识别」主按钮与手电筒/相册/取消。 */
    private fun buildContentView(): ViewGroup {
        val root = FrameLayout(this)
        previewView = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        root.addView(previewView)

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(48, 0, 48, 64)
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.BOTTOM }
        }
        hintView = TextView(this).apply {
            text = "把电脑上的配对二维码放进取景框；识别慢时可点「拍照识别」或从相册选择"
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setShadowLayer(6f, 0f, 1f, Color.BLACK)
            setPadding(0, 0, 0, 24)
        }
        overlay.addView(hintView)

        photoButton = actionButton("拍照识别", primary = true) { capturePhoto() }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = 20 }
        }
        overlay.addView(photoButton)

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        torchButton = actionButton("手电筒", small = true) { toggleTorch() }.apply {
            visibility = View.GONE
            layoutParams = rowButtonParams(first = true)
        }
        galleryButton = actionButton("从相册选择", small = true) { pickImage.launch("image/*") }.apply {
            layoutParams = rowButtonParams(first = torchButton.visibility == View.GONE)
        }
        cancelButton = actionButton("取消", small = true) { finishCancelled() }.apply {
            layoutParams = rowButtonParams(first = false)
        }
        actions.addView(torchButton)
        actions.addView(galleryButton)
        actions.addView(cancelButton)
        overlay.addView(actions)
        root.addView(overlay)
        return root
    }

    /** 底部操作行的一格：等分宽度，窄屏也不会把按钮挤出屏幕。 */
    private fun rowButtonParams(first: Boolean): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginStart = if (first) 0 else 12
        }

    private fun actionButton(
        label: String,
        primary: Boolean = false,
        small: Boolean = false,
        action: () -> Unit,
    ): Button = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = if (small) 13f else 15f
        isAllCaps = false
        background = GradientDrawable().apply {
            setColor(if (primary) Color.argb(224, 0, 96, 200) else Color.argb(168, 0, 0, 0))
            cornerRadius = 48f
        }
        setPadding(if (small) 16 else 48, 12, if (small) 16 else 48, 12)
        setOnClickListener { action() }
    }

    /** 绑定后置相机的预览、逐帧分析与拍照；任何相机初始化失败都报 camera-unavailable。 */
    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = try {
                future.get()
            } catch (failure: Throwable) {
                finishWithError(ERROR_CAMERA, "相机启动失败：${failure.message ?: "未知原因"}。请改为粘贴配对链接。")
                return@addListener
            }
            cameraProvider = provider
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
            // 分析帧用 1280x720，保证屏幕上的二维码有足够像素；默认 640x480 对
            // 屏幕取景偏小，容易在反光/远距离时解不出来。
            val resolution = ResolutionSelector.Builder()
                .setResolutionStrategy(
                    ResolutionStrategy(
                        Size(1280, 720),
                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                    ),
                )
                .build()
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setResolutionSelector(resolution)
                .build()
            analysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }
            val capture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                .setFlashMode(ImageCapture.FLASH_MODE_OFF)
                .build()
            val bound = try {
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis, capture)
            } catch (_: Throwable) {
                // 少数设备不支持「预览+分析+拍照」三路同时绑定：退化为连续取景并
                // 隐藏拍照按钮；相机初始化彻底失败才由 PairingQrScan 退回系统相机。
                provider.unbindAll()
                try {
                    provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                } catch (failure: Throwable) {
                    finishWithError(ERROR_CAMERA, "相机不可用：${failure.message ?: "未知原因"}。请改为粘贴配对链接。")
                    return@addListener
                } finally {
                    hidePhotoCapture()
                }
                null
            }
            if (bound != null) {
                camera = bound
                imageCapture = capture
                updateTorchAvailability()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    /** 设备没有闪光灯时隐藏手电筒按钮；有闪光灯才允许用户打开。 */
    private fun updateTorchAvailability() {
        val hasFlash = camera?.cameraInfo?.hasFlashUnit() == true
        torchButton.visibility = if (hasFlash) View.VISIBLE else View.GONE
        // 「从相册选择」在拍照可用时不位于行首，与手电筒的显示状态保持对齐。
        galleryButton.layoutParams = rowButtonParams(first = !hasFlash)
    }

    /** 三路绑定失败时隐藏拍照按钮并说明原因；连续取景仍然可用。 */
    private fun hidePhotoCapture() {
        imageCapture = null
        photoButton.visibility = View.GONE
        hintView.text = "这台手机的相机不支持应用内拍照识别；请把二维码放进取景框自动识别，或从相册选择图片"
    }

    /** 打开/关闭手电筒；没有闪光灯或失败时保持原状态并给出说明。 */
    private fun toggleTorch() {
        val controls = camera?.cameraControl ?: return
        if (camera?.cameraInfo?.hasFlashUnit() != true) return
        val next = !torchOn
        try {
            controls.enableTorch(next)
            torchOn = next
            torchButton.text = if (next) "关闭手电筒" else "手电筒"
            torchButton.background = GradientDrawable().apply {
                setColor(if (next) Color.argb(224, 255, 176, 0) else Color.argb(168, 0, 0, 0))
                cornerRadius = 48f
            }
        } catch (_: Throwable) {
            torchOn = false
            if (!finished) hintView.text = "手电筒不可用，请改用拍照识别或相册图片。"
        }
    }

    /** 单帧分析：限速后解 QR；命中就回传，未命中继续下一帧。 */
    private fun analyze(image: ImageProxy) {
        try {
            if (finished || photoBusy) return
            val now = SystemClock.elapsedRealtime()
            if (now - lastAttemptAt < FRAME_INTERVAL_MS) return
            lastAttemptAt = now
            val plane = image.planes.firstOrNull() ?: return
            val text = PairingQrDecoder.decodeRgbaFrame(
                plane.buffer,
                plane.rowStride,
                plane.pixelStride,
                image.width,
                image.height,
            ) ?: return
            runOnUiThread { finishWithText(text) }
        } catch (_: Throwable) {
            // 单帧解码失败属于正常未命中（模糊、反光）；继续等下一帧。
        } finally {
            image.close()
        }
    }

    /**
     * 用 ImageCapture 拍一张高分辨率照片，再走图片解码。
     *
     * 照片写进 `<cacheDir>/pairing-scan/` 的一次性文件；解码成功立即回传，失败
     * 删除照片并提示重拍/换相册图片。
     */
    private fun capturePhoto() {
        if (finished || photoBusy) return
        val capture = imageCapture
        if (capture == null) {
            hintView.text = "当前相机不支持拍照识别，请用连续取景或从相册选择图片。"
            return
        }
        val file = try {
            val directory = File(cacheDir, PHOTO_DIRECTORY)
            if (!directory.mkdirs() && !directory.isDirectory) null else File(directory, "photo-${UUID.randomUUID()}.jpg")
        } catch (_: Throwable) {
            null
        }
        if (file == null) {
            hintView.text = "无法准备照片文件，请改用相册图片。"
            return
        }
        photoBusy = true
        pendingPhoto = file
        setControlsEnabled(false)
        hintView.text = "正在拍照…"
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        try {
            capture.takePicture(options, ContextCompat.getMainExecutor(this), object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    if (finished) {
                        file.delete()
                        pendingPhoto = null
                        return
                    }
                    hintView.text = "正在识别照片里的二维码…"
                    decodeCapturedPhoto(file)
                }

                override fun onError(exception: ImageCaptureException) {
                    file.delete()
                    pendingPhoto = null
                    photoBusy = false
                    setControlsEnabled(true)
                    if (!finished) {
                        hintView.text = "拍照失败：${exception.message ?: "未知原因"}。请重试或改用相册图片。"
                    }
                }
            })
        } catch (failure: Throwable) {
            file.delete()
            pendingPhoto = null
            photoBusy = false
            setControlsEnabled(true)
            hintView.text = "无法启动拍照：${failure.message ?: "未知原因"}。请重试或改用相册图片。"
        }
    }

    /** 后台解刚拍的照片；无论成功失败都删除一次性文件。 */
    private fun decodeCapturedPhoto(file: File) {
        try {
            analysisExecutor.execute {
                val text = try {
                    PairingQrDecoder.decodePhoto(file)
                } catch (_: Throwable) {
                    null
                } finally {
                    file.delete()
                }
                runOnUiThread {
                    if (finished) return@runOnUiThread
                    pendingPhoto = null
                    photoBusy = false
                    setControlsEnabled(true)
                    if (text.isNullOrBlank()) {
                        hintView.text = "照片里没有识别到二维码，请靠近一点、保持对焦再拍一张，或改用相册图片。"
                    } else {
                        finishWithText(text)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            file.delete()
            pendingPhoto = null
            photoBusy = false
            finishWithError(ERROR_CANCELLED, "扫码页面已关闭，请重新扫码。")
        }
    }

    /** 相册图片走和图片文件一样的多方向/多尺度解码。 */
    private fun decodePickedImage(uri: Uri) {
        if (finished || photoBusy) return
        photoBusy = true
        setControlsEnabled(false)
        hintView.text = "正在识别图片里的二维码…"
        try {
            analysisExecutor.execute {
                val text = try {
                    PairingQrDecoder.decodeUri(this, uri)
                } catch (_: Throwable) {
                    null
                }
                runOnUiThread {
                    if (finished) return@runOnUiThread
                    photoBusy = false
                    setControlsEnabled(true)
                    if (text.isNullOrBlank()) {
                        hintView.text = "图片里没有识别到二维码。请换一张图片，或把镜头对准电脑屏幕上的二维码。"
                    } else {
                        finishWithText(text)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            // 页面已经销毁：没有可回传的结果。
        }
    }

    /** 拍照/解码期间禁用重复操作；取消仍可点，避免卡在识别中。 */
    private fun setControlsEnabled(enabled: Boolean) {
        photoButton.isEnabled = enabled
        galleryButton.isEnabled = enabled
        torchButton.isEnabled = enabled
        cancelButton.isEnabled = true
    }

    private fun finishWithText(text: String) {
        if (finished) return
        finished = true
        cleanupPhoto()
        setResult(RESULT_OK, Intent().putExtra(EXTRA_TEXT, text))
        finish()
    }

    private fun finishWithError(code: String, message: String) {
        if (finished) return
        finished = true
        cleanupPhoto()
        setResult(
            RESULT_FIRST_USER,
            Intent().putExtra(EXTRA_ERROR_CODE, code).putExtra(EXTRA_ERROR_MESSAGE, message),
        )
        finish()
    }

    private fun finishCancelled() {
        if (finished) return
        finished = true
        cleanupPhoto()
        setResult(RESULT_CANCELED)
        finish()
    }

    private fun cleanupPhoto() {
        pendingPhoto?.delete()
        pendingPhoto = null
    }

    override fun onDestroy() {
        finished = true
        cleanupPhoto()
        cameraProvider?.unbindAll()
        analysisExecutor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        /** 成功结果里的二维码文本。 */
        const val EXTRA_TEXT = "dsh.pairing.scan.text"

        /** 失败结果里的原生错误码。 */
        const val EXTRA_ERROR_CODE = "dsh.pairing.scan.error.code"

        /** 失败结果里的可展示中文原因。 */
        const val EXTRA_ERROR_MESSAGE = "dsh.pairing.scan.error.message"

        /** 相机初始化失败；`PairingQrScan` 收到后回退系统相机拍照。 */
        const val ERROR_CAMERA = "pairing/camera-unavailable"

        /** 相机权限被拒绝；直接回到页面说明原因，不自动改用拍照。 */
        const val ERROR_PERMISSION = "pairing/permission-denied"

        /** 页面关闭后仍在进行的拍照/解码（罕见）：按取消回给页面。 */
        private const val ERROR_CANCELLED = "pairing/scan-cancelled"

        /** 两次解码尝试的最小间隔：连续取景时给 CPU 留出预览与对焦时间。 */
        private const val FRAME_INTERVAL_MS = 350L

        /** 拍照识别的临时目录；`PairingQrScan` 启动时会清理过期照片。 */
        private const val PHOTO_DIRECTORY = "pairing-scan"
    }
}
