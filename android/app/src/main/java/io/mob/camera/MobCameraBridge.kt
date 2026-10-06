// mob_camera plugin — Android bridge (CameraX).
//
// Extracted from mob-core's MobBridge camera_* methods. Lives in the plugin's
// own package; MobPluginBootstrap.registerAll() calls register() at startup,
// hands it the Activity (MobActivityAware), and records it as a permission
// provider (MobPermissionProvider, :camera -> CAMERA).
//
// The native thunks (nativeRegister + the deliver hooks) are exported directly
// from the sibling zig NIF mob_camera_nif.zig.
//
// DESIGN NOTE vs core: capture (TakePicture/CaptureVideo) needs an
// ActivityResultLauncher. core registered it in MainActivity.onCreate via
// registerForActivityResult, but that convenience API must run before the host
// reaches STARTED — a late-bound plugin can't meet that. mob's MainActivity is
// a ComponentActivity (Compose host), not a FragmentActivity, so a headless
// Fragment can't attach either. Instead this bridge registers directly on the
// ComponentActivity's ActivityResultRegistry (register(key, contract, callback)
// is callable any time) and unregisters in the callback — self-contained, no
// host MainActivity changes.
//
// The live PREVIEW component (MobCameraPreview) is NOT here yet: it's a Compose
// native-view bound to this bridge's observable state, which needs the plugin
// Compose native-view path (cf. mob_demo_signature_pad). See EXTRACTION.md.
package io.mob.camera

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

object MobCameraBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // Frame delivery: {:camera, :frame, %{...}}
    @JvmStatic external fun nativeDeliverCameraFrame(
        pid: Long,
        bytes: ByteArray,
        width: Int,
        height: Int,
        format: String,
        timestampMs: Long,
        dropped: Long,
    )

    // Capture result: path -> {:camera, :photo|:video, %{path,...}}; kind=="cancelled" -> {:camera, :cancelled}
    // width/height are the decoded photo bounds (0 for a video call); durationSeconds
    // is the video length (0.0 for a photo call). One signature covers both kinds —
    // the Zig side picks which fields to include in the map based on `kind`.
    @JvmStatic external fun nativeDeliverCameraFile(
        pid: Long,
        kind: String,
        path: String,
        width: Int,
        height: Int,
        durationSeconds: Double,
    )

    @JvmStatic external fun nativeDeliverCameraCancelled(pid: Long)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    override fun permissionsFor(cap: String): Array<String>? = if (cap == "camera") arrayOf(android.Manifest.permission.CAMERA) else null

    // ── Capture (photo / video) ───────────────────────────────────────────
    private var pendingPid: Long = 0L

    @JvmStatic
    fun camera_capture_photo(
        pid: Long,
        quality: String,
    ) = launchCapture(pid, video = false)

    @JvmStatic
    fun camera_capture_video(
        pid: Long,
        maxDuration: String,
    ) = launchCapture(pid, video = true)

    private val captureSeq = AtomicLong(0L)

    private fun launchCapture(
        pid: Long,
        video: Boolean,
    ) {
        pendingPid = pid
        // mob's MainActivity is a ComponentActivity (Compose host), NOT a
        // FragmentActivity, so a headless Fragment can't attach. ComponentActivity
        // is an ActivityResultRegistryOwner, so register against its registry
        // directly. The register(key, contract, callback) overload (no
        // LifecycleOwner) is callable any time — unlike registerForActivityResult,
        // which must run before the host reaches STARTED, a constraint a late-bound
        // plugin can't meet. We unregister inside the callback.
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverCameraCancelled(pid)
                return
            }
        // ActivityResultRegistry.register() and launcher.launch() must run on the
        // Android main thread. launchCapture is invoked from the camera NIF on a BEAM
        // scheduler thread, so registering/launching directly here throws
        // IllegalStateException (or wedges the UI toolkit). Hop to the UI thread for
        // the registration + launch.
        activity.runOnUiThread {
            val owner =
                activity as? ActivityResultRegistryOwner ?: run {
                    nativeDeliverCameraCancelled(pid)
                    return@runOnUiThread
                }
            val outUri = captureUri(activity, video)
            val contract =
                if (video) {
                    ActivityResultContracts.CaptureVideo()
                } else {
                    ActivityResultContracts.TakePicture()
                }
            val key = "mob_camera_capture_${captureSeq.incrementAndGet()}"
            var launcher: ActivityResultLauncher<Uri>? = null
            launcher =
                owner.activityResultRegistry.register(key, contract) { ok: Boolean ->
                    onCaptureResult(if (ok) outUri else null, video)
                    launcher?.unregister()
                }
            launcher.launch(outUri)
        }
    }

    internal fun onCaptureResult(
        uri: Uri?,
        video: Boolean,
    ) {
        val pid = pendingPid
        val activity = activityRef?.get()
        if (uri == null || activity == null) {
            nativeDeliverCameraCancelled(pid)
            return
        }
        Thread {
            try {
                val ext = if (video) "mp4" else "jpg"
                val tmp = File(activity.cacheDir, "mob_cam_${System.currentTimeMillis()}.$ext")
                activity.contentResolver.openInputStream(uri)?.use { it.copyTo(tmp.outputStream()) }
                if (video) {
                    val durationSeconds = videoDurationSeconds(tmp.absolutePath)
                    nativeDeliverCameraFile(pid, "video", tmp.absolutePath, 0, 0, durationSeconds)
                } else {
                    val (w, h) = photoDimensions(tmp.absolutePath)
                    nativeDeliverCameraFile(pid, "photo", tmp.absolutePath, w, h, 0.0)
                }
            } catch (e: Exception) {
                nativeDeliverCameraCancelled(pid)
            }
        }.start()
    }

    // BitmapFactory.Options.inJustDecodeBounds reads only the image header, not the
    // pixel data — cheap even for a large photo. Falls back to 0x0 rather than
    // throwing if the file is somehow undecodable; the caller still gets its path.
    private fun photoDimensions(path: String): Pair<Int, Int> {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, opts)
        return Pair(opts.outWidth.coerceAtLeast(0), opts.outHeight.coerceAtLeast(0))
    }

    // MediaMetadataRetriever.METADATA_KEY_DURATION is milliseconds as a string;
    // "duration" everywhere else in this bridge (and on iOS) is seconds.
    private fun videoDurationSeconds(path: String): Double {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            ms / 1000.0
        } catch (e: Exception) {
            0.0
        } finally {
            retriever.release()
        }
    }

    internal fun captureUri(
        activity: Activity,
        video: Boolean,
    ): Uri {
        val ext = if (video) "mp4" else "jpg"
        val f = File(activity.cacheDir, "mob_cam_out_${System.currentTimeMillis()}.$ext")
        return FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", f)
    }

    // ── Live frame stream ─────────────────────────────────────────────────
    // The MobCameraPreview Compose native-view (plugin component, pending)
    // observes this state and binds CameraX ImageAnalysis with deliverFrame.
    internal val frameStreamRev = AtomicLong(0L)
    internal var frameStreamActive = false
    internal var frameStreamPid: Long = 0L
    internal var frameStreamWidth = 640
    internal var frameStreamHeight = 640

    // width/height both JSON null (Elixir `width: nil, height: nil`): deliver
    // the analysis frame at its own (rotated) size, no crop/scale.
    internal var frameStreamNative = false
    internal var frameStreamFormat = "rgb_f32"
    internal var frameStreamThrottleMs = 0
    private var lastDeliveryMs = 0L
    private var droppedCount = 0L
    internal var previewFacing: String? = null
    internal val analysisExecutor = Executors.newSingleThreadExecutor()

    @JvmStatic
    fun camera_start_preview(
        pid: Long,
        optsJson: String,
    ) {
        previewFacing =
            try {
                JSONObject(optsJson).optString("facing", "back")
            } catch (_: Exception) {
                "back"
            }
        frameStreamRev.incrementAndGet()
    }

    @JvmStatic
    fun camera_stop_preview() {
        previewFacing = null
        frameStreamRev.incrementAndGet()
    }

    @JvmStatic
    fun camera_start_frame_stream(
        pid: Long,
        optsJson: String,
    ) {
        try {
            val o = JSONObject(optsJson)
            frameStreamPid = pid
            frameStreamNative = o.has("width") && o.isNull("width") && o.has("height") && o.isNull("height")
            frameStreamWidth = o.optInt("width", 640).coerceIn(1, 4096)
            frameStreamHeight = o.optInt("height", 640).coerceIn(1, 4096)
            frameStreamFormat = o.optString("format", "rgb_f32")
            frameStreamThrottleMs = o.optInt("throttle_ms", 0)
            if (previewFacing != o.optString("facing", "back")) previewFacing = o.optString("facing", "back")
            lastDeliveryMs = 0L
            droppedCount = 0L
            frameStreamActive = true
            frameStreamRev.incrementAndGet()
        } catch (e: Exception) {
            Log.e("MobCamera", "start_frame_stream failed: ${e.message}")
        }
    }

    @JvmStatic
    fun camera_stop_frame_stream() {
        frameStreamActive = false
        frameStreamRev.incrementAndGet()
    }

    // Called from the CameraX analyzer thread. Public + @JvmStatic so the
    // camera-preview native view (in the app module) can hand it each frame
    // without a compile-time dependency on this plugin. Self-gates on
    // frameStreamActive, so binding an ImageAnalysis unconditionally is safe:
    // frames are dropped (and the image closed) until start_frame_stream runs.
    @JvmStatic fun deliverFrame(image: ImageProxy) {
        try {
            if (!frameStreamActive) return
            val now = System.currentTimeMillis()
            if (frameStreamThrottleMs > 0 && (now - lastDeliveryMs) < frameStreamThrottleMs.toLong()) {
                droppedCount++
                return
            }
            val rotated = rotateIfNeeded(image.toBitmap(), image.imageInfo.rotationDegrees)
            val cropped = if (frameStreamNative) capPixels(rotated) else centerCropAndScale(rotated, frameStreamWidth, frameStreamHeight)
            val bytes = if (frameStreamFormat == "bgra_u8") bitmapToBgraU8(cropped) else bitmapToRgbF32(cropped)
            nativeDeliverCameraFrame(frameStreamPid, bytes, cropped.width, cropped.height, frameStreamFormat, now, droppedCount)
            lastDeliveryMs = now
            droppedCount = 0L
        } catch (e: Throwable) {
            Log.e("MobCamera", "deliverFrame failed: ${e.message}")
        } finally {
            image.close()
        }
    }

    private fun rotateIfNeeded(
        bm: Bitmap,
        deg: Int,
    ): Bitmap {
        if (deg == 0) return bm
        val m = Matrix().apply { postRotate(deg.toFloat()) }
        return Bitmap.createBitmap(bm, 0, 0, bm.width, bm.height, m, true)
    }

    // Native frames keep their aspect ratio; only past ~4 MP (the iOS cap) are
    // they downscaled, to keep the BEAM mailbox bounded.
    private fun capPixels(bm: Bitmap): Bitmap {
        val pixels = bm.width.toDouble() * bm.height
        val max = 4.0 * 1024 * 1024
        if (pixels <= max) return bm
        val s = Math.sqrt(max / pixels)
        return Bitmap.createScaledBitmap(bm, maxOf(1, (bm.width * s).toInt()), maxOf(1, (bm.height * s).toInt()), true)
    }

    private fun centerCropAndScale(
        src: Bitmap,
        w: Int,
        h: Int,
    ): Bitmap {
        val srcAspect = src.width.toDouble() / src.height
        val dstAspect = w.toDouble() / h
        val (cropX, cropY, cropW, cropH) =
            when {
                srcAspect > dstAspect -> {
                    val cw = (src.height * dstAspect).toInt()
                    arrayOf((src.width - cw) / 2, 0, cw, src.height)
                }

                srcAspect < dstAspect -> {
                    val ch = (src.width / dstAspect).toInt()
                    arrayOf(0, (src.height - ch) / 2, src.width, ch)
                }

                else -> {
                    arrayOf(0, 0, src.width, src.height)
                }
            }
        val cropped = Bitmap.createBitmap(src, cropX, cropY, cropW, cropH)
        return if (cropped.width != w || cropped.height != h) {
            Bitmap.createScaledBitmap(cropped, w, h, true)
        } else {
            cropped
        }
    }

    private fun bitmapToRgbF32(bm: Bitmap): ByteArray {
        val w = bm.width
        val h = bm.height
        val pixels = IntArray(w * h)
        bm.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 3 * 4)
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until w * h) {
            val px = pixels[i]
            bb.putFloat(((px shr 16) and 0xff) / 255f)
            bb.putFloat(((px shr 8) and 0xff) / 255f)
            bb.putFloat((px and 0xff) / 255f)
        }
        return out
    }

    private fun bitmapToBgraU8(bm: Bitmap): ByteArray {
        val w = bm.width
        val h = bm.height
        val pixels = IntArray(w * h)
        bm.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 4)
        for (i in 0 until w * h) {
            val px = pixels[i]
            out[i * 4 + 0] = (px and 0xff).toByte()
            out[i * 4 + 1] = ((px shr 8) and 0xff).toByte()
            out[i * 4 + 2] = ((px shr 16) and 0xff).toByte()
            out[i * 4 + 3] = ((px shr 24) and 0xff).toByte()
        }
        return out
    }

    // ── Headless still capture (snap) ─────────────────────────────────────
    // {:camera, :snapped, %{path, width, height, facing}}
    @JvmStatic external fun nativeDeliverSnapped(
        pid: Long,
        path: String,
        width: Int,
        height: Int,
        facing: String,
    )

    // {:camera, :snap_error, reason}: `reason` becomes an atom when isAtom
    // (no_camera / permission / busy / background), else a binary carrying the
    // platform error text.
    @JvmStatic external fun nativeDeliverSnapError(
        pid: Long,
        reason: String,
        isAtom: Boolean,
    )

    // One snap at a time; cleared once the camera is unbound again.
    private val snapInFlight = AtomicBoolean(false)

    // Replies that don't need a session. This runs on the BEAM scheduler
    // thread that called the NIF, and enif_send with a NULL env is only for
    // non-ERTS threads, so the reply goes out from the main looper.
    private fun snapErrorLater(
        pid: Long,
        reason: String,
        atom: Boolean,
    ) {
        Handler(Looper.getMainLooper()).post { nativeDeliverSnapError(pid, reason, atom) }
    }

    @JvmStatic
    fun camera_snap(
        pid: Long,
        optsJson: String,
    ) {
        val opts =
            try {
                SnapOptions.parse(optsJson)
            } catch (e: Exception) {
                return snapErrorLater(pid, "invalid snap options: ${e.message}", false)
            }
        if (!snapInFlight.compareAndSet(false, true)) return snapErrorLater(pid, "busy", true)
        val activity = activityRef?.get()
        if (activity == null) {
            snapInFlight.set(false)
            return snapErrorLater(pid, "no activity attached to the camera bridge", false)
        }
        // LifecycleRegistry and bindToLifecycle are main-thread only.
        ContextCompat.getMainExecutor(activity).execute {
            SnapSession(activity, pid, opts) { snapInFlight.set(false) }.start()
        }
    }
}

internal class SnapOptions(
    val front: Boolean,
    val flashMode: Int,
    val maxSize: Int?,
    val quality: Int,
) {
    val facing: String get() = if (front) "front" else "back"

    companion object {
        // Defaults mirror MobCamera.snap_opts/1, which always sends every key.
        fun parse(json: String): SnapOptions {
            val o = JSONObject(json)
            val flash =
                when (o.optString("flash", "off")) {
                    "on" -> ImageCapture.FLASH_MODE_ON
                    "auto" -> ImageCapture.FLASH_MODE_AUTO
                    else -> ImageCapture.FLASH_MODE_OFF
                }
            val maxSize = if (o.has("max_size") && o.isNull("max_size")) null else o.optInt("max_size", 1600).coerceAtLeast(1)
            return SnapOptions(
                front = o.optString("facing", "back") == "front",
                flashMode = flash,
                maxSize = maxSize,
                quality = o.optInt("quality", 85).coerceIn(1, 100),
            )
        }
    }
}

// One headless still: ImageCapture plus a small frame-dropping ImageAnalysis
// stream for 3A metering (no Preview), bound to this session's own
// LifecycleOwner, so the activity's lifecycle and any preview bound to it are
// left alone (CameraX hands the camera back to the activity's owner once this
// one is destroyed). Flow, on the main thread unless noted:
//   start -> provider -> bind (RESUMED) -> wait for 3A to settle -> takePicture
//   -> (worker) decode -> release (unbind, DESTROYED) -> (worker) rotate/scale/
//   write JPEG -> deliver (main, after release).
// `settled` is claimed exactly once — by the shot, an error or the timeout —
// so the caller always gets exactly one message.
@androidx.annotation.OptIn(markerClass = [ExperimentalCamera2Interop::class])
private class SnapSession(
    private val activity: Activity,
    private val pid: Long,
    private val opts: SnapOptions,
    private val onReleased: () -> Unit,
) : LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val settled = AtomicBoolean(false)
    private val settledFrames = AtomicInteger(0)
    private var provider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var meterUseCase: ImageAnalysis? = null
    private var lastCameraError: CameraState.StateError? = null
    private var shotRequested = false
    private var released = false
    private var orientationListener: OrientationEventListener? = null

    // Device tilt in degrees (0..359) from the accelerometer, or UNKNOWN when
    // the phone lies flat or there's no sensor.
    @Volatile private var deviceDegrees = OrientationEventListener.ORIENTATION_UNKNOWN

    private val timeout = Runnable { timedOut() }
    private val settleCap = Runnable { shoot("settle cap reached, last 3A $last3A") }

    // "ae/af/awb" states of the newest metering result, for the settle-cap log.
    @Volatile private var last3A = "none"

    fun start() {
        registry.currentState = Lifecycle.State.CREATED
        main.postDelayed(timeout, TIMEOUT_MS)
        // Android refuses the camera to an app with no started activity
        // (the camera service reports it as disabled), so say so up front.
        if (!hostStarted()) return fail("background", true)
        try {
            val future = ProcessCameraProvider.getInstance(activity)
            future.addListener({
                try {
                    provider = future.get()
                    bind()
                } catch (e: Exception) {
                    fail("camera provider unavailable: ${e.message}", false)
                }
            }, ContextCompat.getMainExecutor(activity))
        } catch (e: Exception) {
            fail("camera provider unavailable: ${e.message}", false)
        }
    }

    private fun hostStarted(): Boolean {
        val state = (activity as? LifecycleOwner)?.lifecycle?.currentState ?: return true
        return state.isAtLeast(Lifecycle.State.STARTED)
    }

    private fun bind() {
        if (settled.get()) return
        val p = provider ?: return
        val selector = if (opts.front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val hasCamera =
            try {
                p.hasCamera(selector)
            } catch (e: Exception) {
                false
            }
        if (!hasCamera) return fail("no_camera", true)
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return fail("permission", true)
        }

        // Upright follows gravity, like iOS, not the display: a
        // portrait-locked app held sideways still gets an upright photo.
        orientationListener =
            object : OrientationEventListener(activity) {
                override fun onOrientationChanged(orientation: Int) {
                    deviceDegrees = orientation
                }
            }.also { if (it.canDetectOrientation()) it.enable() }

        val captureBuilder =
            ImageCapture
                .Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                .setFlashMode(opts.flashMode)
                .setTargetRotation(displayRotation())
        // Capture the smallest size that still covers max_size rather than
        // the full sensor, then scale down; nil keeps CameraX's maximum.
        opts.maxSize?.let { max ->
            captureBuilder.setResolutionSelector(
                ResolutionSelector
                    .Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(max, maxOf(1, max * 3 / 4)), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                    ).build(),
            )
        }
        val capture = captureBuilder.build()
        // A small analysis stream is the repeating request 3A runs on; its
        // results carry the AE/AF/AWB states we wait on before shooting. (A
        // capture callback on ImageCapture itself never sees repeating
        // results: CameraX only wires repeating callbacks of active use
        // cases, and ImageCapture never becomes active.) Frames are dropped.
        val meterBuilder =
            ImageAnalysis
                .Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setResolutionSelector(
                    ResolutionSelector
                        .Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER),
                        ).build(),
                )
        Camera2Interop.Extender(meterBuilder).setSessionCaptureCallback(
            object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    if (!converged(result)) {
                        settledFrames.set(0)
                    } else if (settledFrames.incrementAndGet() == SETTLED_FRAMES) {
                        main.post { shoot("3A converged") }
                    }
                }
            },
        )
        val meter = meterBuilder.build().also { it.setAnalyzer(worker) { image -> image.close() } }
        imageCapture = capture
        meterUseCase = meter
        val camera =
            try {
                p.bindToLifecycle(this, selector, capture, meter)
            } catch (e: Exception) {
                return fail("could not bind the camera: ${e.message}", false)
            }
        camera.cameraInfo.cameraState.observe(this) { onCameraState(it) }
        registry.currentState = Lifecycle.State.RESUMED
        main.postDelayed(settleCap, SETTLE_MAX_MS)
    }

    private fun displayRotation(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }

    // The Surface rotation that makes the shot upright for how the phone is
    // held (CameraX's documented OrientationEventListener mapping); the display
    // rotation when the phone lies flat or tilt is unknown.
    private fun uprightRotation(): Int {
        val degrees = deviceDegrees
        return when {
            degrees == OrientationEventListener.ORIENTATION_UNKNOWN -> displayRotation()
            degrees in 45 until 135 -> Surface.ROTATION_270
            degrees in 135 until 225 -> Surface.ROTATION_180
            degrees in 225 until 315 -> Surface.ROTATION_90
            else -> Surface.ROTATION_0
        }
    }

    // AE/AWB converged (or locked, or not reported) and AF not mid-scan. In a
    // continuous AF mode the first passive scan must also have finished
    // (INACTIVE there means it hasn't started yet). AF_MODE_AUTO only scans
    // on a trigger, which takePicture sends itself, so INACTIVE is settled.
    private fun converged(r: CaptureResult): Boolean {
        val ae = r.get(CaptureResult.CONTROL_AE_STATE)
        val aeOk =
            ae == null ||
                ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
                ae == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED ||
                ae == CaptureResult.CONTROL_AE_STATE_LOCKED
        val awb = r.get(CaptureResult.CONTROL_AWB_STATE)
        val awbOk = awb == null || awb == CaptureResult.CONTROL_AWB_STATE_CONVERGED || awb == CaptureResult.CONTROL_AWB_STATE_LOCKED
        val afMode = r.get(CaptureResult.CONTROL_AF_MODE)
        val af = r.get(CaptureResult.CONTROL_AF_STATE)
        val afScanning = af == CaptureResult.CONTROL_AF_STATE_PASSIVE_SCAN || af == CaptureResult.CONTROL_AF_STATE_ACTIVE_SCAN
        val continuousAf =
            afMode == CaptureResult.CONTROL_AF_MODE_CONTINUOUS_PICTURE ||
                afMode == CaptureResult.CONTROL_AF_MODE_CONTINUOUS_VIDEO
        val afOk = !afScanning && !(continuousAf && af == CaptureResult.CONTROL_AF_STATE_INACTIVE)
        last3A = "ae=$ae af=$af(mode $afMode) awb=$awb"
        return aeOk && awbOk && afOk
    }

    // Recoverable errors (camera in use, too many cameras open) are retried
    // by CameraX; they only name the reason if the timeout fires first.
    private fun onCameraState(state: CameraState) {
        val err = state.error ?: return
        lastCameraError = err
        when {
            err.code == CameraState.ERROR_CAMERA_DISABLED && !hostStarted() -> fail("background", true)
            err.type == CameraState.ErrorType.CRITICAL -> fail("camera error ${err.code}", false)
        }
    }

    private fun timedOut() {
        val code = lastCameraError?.code
        when {
            !hostStarted() -> fail("background", true)
            code == CameraState.ERROR_CAMERA_IN_USE || code == CameraState.ERROR_MAX_CAMERAS_IN_USE -> fail("busy", true)
            else -> fail("timed out after ${TIMEOUT_MS / 1000} s waiting for the camera", false)
        }
    }

    private fun shoot(why: String) {
        if (shotRequested || settled.get()) return
        val capture = imageCapture ?: return
        shotRequested = true
        main.removeCallbacks(settleCap)
        capture.targetRotation = uprightRotation()
        Log.i(TAG, "snap: taking picture (${opts.facing}, $why, tilt $deviceDegrees)")
        capture.takePicture(
            worker,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) = onCaptured(image)

                override fun onError(exception: ImageCaptureException) {
                    fail("capture failed: ${exception.message}", false)
                }
            },
        )
    }

    // Worker thread.
    private fun onCaptured(image: ImageProxy) {
        val rotation = image.imageInfo.rotationDegrees
        val decoded =
            try {
                decode(image)
            } catch (e: Throwable) {
                image.close()
                return fail("could not decode the photo: ${e.message}", false)
            }
        image.close()
        if (!settled.compareAndSet(false, true)) return
        // Release now; the result is posted to the same main looper later, so
        // the camera is always unbound before the caller hears back.
        main.post { release() }
        val deliver: () -> Unit =
            try {
                val upright = uprightScaled(decoded, rotation, opts.maxSize)
                if (upright !== decoded) decoded.recycle()
                val file = File(activity.cacheDir, "mob_snap_${System.currentTimeMillis()}_${SEQ.incrementAndGet()}.jpg")
                val written =
                    try {
                        file.outputStream().use { upright.compress(Bitmap.CompressFormat.JPEG, opts.quality, it) }
                    } catch (e: Throwable) {
                        file.delete()
                        throw e
                    }
                if (!written) {
                    file.delete()
                    error("JPEG encoder failed")
                }
                stampOrientationNormal(file)
                Log.i(TAG, "snap: wrote ${upright.width}x${upright.height} ${file.absolutePath}")
                ({ MobCameraBridge.nativeDeliverSnapped(pid, file.absolutePath, upright.width, upright.height, opts.facing) })
            } catch (e: Throwable) {
                ({ MobCameraBridge.nativeDeliverSnapError(pid, "could not write the photo: ${e.message}", false) })
            }
        main.post { deliver() }
    }

    // Bitmap.compress writes no EXIF (orientation 1 by default); the explicit
    // tag is for readers that want to see it. Its failure doesn't spoil a
    // good photo.
    private fun stampOrientationNormal(file: File) {
        try {
            ExifInterface(file.absolutePath).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
                saveAttributes()
            }
        } catch (e: Exception) {
            Log.w(TAG, "snap: could not tag EXIF orientation: ${e.message}")
        }
    }

    // JPEG (the ImageCapture default) is decoded with a power-of-two sample
    // size that stays at or above maxSize, so a 12 MP sensor never inflates
    // to a full-size bitmap just to be scaled down.
    private fun decode(image: ImageProxy): Bitmap {
        if (image.format != ImageFormat.JPEG) return image.toBitmap()
        val buf = image.planes[0].buffer
        val jpeg = ByteArray(buf.remaining()).also { buf.get(it) }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        var sample = 1
        val max = opts.maxSize
        if (max != null) {
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            while (longest / (sample * 2) >= max) sample *= 2
        }
        val o = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, o) ?: error("BitmapFactory returned null")
    }

    private fun uprightScaled(
        bm: Bitmap,
        rotation: Int,
        maxSize: Int?,
    ): Bitmap {
        val longest = maxOf(bm.width, bm.height)
        val scale = if (maxSize != null && longest > maxSize) maxSize.toFloat() / longest else 1f
        if (scale == 1f && rotation % 360 == 0) return bm
        val m =
            Matrix().apply {
                postScale(scale, scale)
                postRotate(rotation.toFloat())
            }
        return Bitmap.createBitmap(bm, 0, 0, bm.width, bm.height, m, true)
    }

    // Any thread. Releases the camera before the caller hears about the
    // failure, so a retry on receipt never sees :busy.
    private fun fail(
        reason: String,
        atom: Boolean,
    ) {
        if (!settled.compareAndSet(false, true)) return
        main.post {
            release()
            Log.w(TAG, "snap failed: $reason")
            MobCameraBridge.nativeDeliverSnapError(pid, reason, atom)
        }
    }

    // Main thread. Idempotent: unbinds the snap's use cases (never unbindAll,
    // which would drop the activity's preview), destroys the lifecycle owner
    // and frees the single-snap slot.
    private fun release() {
        if (released) return
        released = true
        main.removeCallbacks(timeout)
        main.removeCallbacks(settleCap)
        orientationListener?.disable()
        try {
            meterUseCase?.clearAnalyzer()
            val bound = listOfNotNull(imageCapture, meterUseCase)
            if (bound.isNotEmpty()) provider?.unbind(*bound.toTypedArray())
        } catch (e: Exception) {
            Log.w(TAG, "snap: unbind failed: ${e.message}")
        } finally {
            try {
                // Destroying the owner unbinds its use cases too.
                registry.currentState = Lifecycle.State.DESTROYED
            } catch (e: Exception) {
                Log.w(TAG, "snap: lifecycle teardown failed: ${e.message}")
            }
            worker.shutdown()
            // A stuck slot would make every later snap :busy.
            onReleased()
        }
    }

    companion object {
        private const val TAG = "MobCamera"
        private const val TIMEOUT_MS = 10_000L

        // Shoot anyway if 3A never reports convergence (or the HAL reports no
        // states at all) within this long of binding.
        private const val SETTLE_MAX_MS = 3_000L

        // Consecutive converged frames required: a single converged result
        // straight after open can precede the real exposure search.
        private const val SETTLED_FRAMES = 4
        private val SEQ = AtomicLong(0L)
    }
}
