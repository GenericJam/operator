// MobScreencastBridge — the plugin-owned Android bridge for mob_screencast.
//
// Captures the device screen with MediaProjection, encodes it to H264 with a
// MediaCodec AVC encoder fed by a VirtualDisplay, and pushes each Annex-B access unit
// to the BEAM via the zig NIF's nativeDeliverScreencastFrame. The native thunks
// (nativeRegister + nativeDeliverScreencastFrame) are exported from
// priv/native/jni/mob_screencast_nif.zig.
//
// Implements MobActivityAware so it can reach the host Activity for the one-time
// MediaProjection consent dialog, launched via the ComponentActivity's
// ActivityResultRegistry (mob's MainActivity is a Compose ComponentActivity, not a
// FragmentActivity — same as mob_camera). NOTE: on Android 14+ (API 34) a MediaProjection
// capture must run inside a
// foreground service of type mediaProjection — an AndroidManifest <service> the plugin
// manifest can't yet contribute (see PLAN.md). This first cut targets API <= 33 (the
// Moto G is API 30), where MediaProjection runs directly.
package io.mob.screencast

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.os.Build
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.view.Surface
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

object MobScreencastBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:screencast, :frame, %{bytes, width, height, format: :h264, timestamp_ms, keyframe}}
    @JvmStatic external fun nativeDeliverScreencastFrame(
        pid: Long, bytes: ByteArray, width: Int, height: Int, timestampMs: Long, keyframe: Int,
    )

    // {:screencast, :permission, :granted | :denied}
    // Sent from the MediaProjection consent callback in both branches; a caller
    // of MobScreencast.start_stream/1 gets a definitive answer before deciding
    // whether to wait for frames. See MOB-87.
    @JvmStatic external fun nativeDeliverScreencastPermission(pid: Long, granted: Int)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // ── Capture session state ──────────────────────────────────────────────
    private var streamPid: Long = 0L
    private var bitrate = 2_000_000
    private var fps = 30
    private var keyframeIntervalMs = 2_000
    private var maxSize = 0 // 0 = native resolution

    private var projection: MediaProjection? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null
    @Volatile private var running = false
    private var drainThread: Thread? = null
    private var csd: ByteArray? = null // SPS/PPS (Annex-B), prepended to keyframes

    // ── NIF entry points (called from zig) ─────────────────────────────────

    @JvmStatic
    fun screencast_start_stream(pid: Long, configJson: String) {
        if (running) stopInternal()
        streamPid = pid
        try {
            val cfg = JSONObject(configJson)
            bitrate = cfg.optInt("bitrate", 2_000_000)
            fps = cfg.optInt("fps", 30)
            keyframeIntervalMs = cfg.optInt("keyframe_interval_ms", 2_000)
            maxSize = cfg.optInt("max_size", 0)
        } catch (_: Throwable) {
        }

        // mob's MainActivity is a ComponentActivity (Compose host), NOT a
        // FragmentActivity — so register against its ActivityResultRegistry directly
        // (the no-LifecycleOwner register overload is callable any time), exactly like
        // mob_camera. Launch the MediaProjection consent intent and unregister in the
        // callback.
        val activity = activityRef?.get() ?: run {
            Log.e("MobScreencast", "no activity for the MediaProjection consent")
            return
        }
        val owner = activity as? ActivityResultRegistryOwner ?: run {
            Log.e("MobScreencast", "activity is not an ActivityResultRegistryOwner")
            return
        }
        try {
            val mpm =
                activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val key = "mob_screencast_consent_${consentSeq.incrementAndGet()}"
            var launcher: ActivityResultLauncher<Intent>? = null
            launcher = owner.activityResultRegistry.register(
                key, ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                val ok = result.resultCode == Activity.RESULT_OK
                // MOB-87: signal the outcome BEFORE the async begin-capture
                // chain. A denied consent used to be completely silent;
                // callers who awaited the {:screencast, :permission, ...}
                // event blocked forever.
                // A link failure (stale .so missing the new export) must not
                // block onProjectionResult on the grant path.
                try {
                    nativeDeliverScreencastPermission(streamPid, if (ok) 1 else 0)
                } catch (_: Throwable) {
                }
                if (ok) {
                    onProjectionResult(result.resultCode, result.data)
                }
                launcher?.unregister()
            }
            launcher.launch(mpm.createScreenCaptureIntent())
        } catch (e: Throwable) {
            Log.e("MobScreencast", "consent launch failed: ${e.message}")
        }
    }

    private val consentSeq = AtomicLong(0L)

    @JvmStatic
    fun screencast_stop_stream() = stopInternal()

    @JvmStatic
    fun screencast_request_keyframe() {
        try {
            encoder?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (_: Throwable) {
        }
    }

    // ── MediaProjection result → foreground service → encoder ──────────────

    // Consent granted. We CANNOT obtain the projection here: getMediaProjection ->
    // MediaProjection.start() throws unless a foreground service of type
    // mediaProjection is already running (enforced on API 30+ on this hardware). So
    // stash the result and start ScreencastService; it foregrounds itself and then
    // calls beginCaptureFromService below.
    private var pendingResultCode: Int = 0
    private var pendingData: Intent? = null

    internal fun onProjectionResult(resultCode: Int, data: Intent?) {
        if (data == null) return
        val activity = activityRef?.get() ?: run {
            Log.e("MobScreencast", "no activity to start the capture service")
            return
        }
        pendingResultCode = resultCode
        pendingData = data
        try {
            val svc = Intent(activity, ScreencastService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(svc)
            } else {
                activity.startService(svc)
            }
        } catch (e: Throwable) {
            Log.e("MobScreencast", "failed to start capture service: ${e.message}", e)
        }
    }

    private var serviceRef: WeakReference<Service>? = null

    // Called from ScreencastService.onStartCommand once it is foregrounded as type
    // mediaProjection. Now getMediaProjection is legal.
    internal fun beginCaptureFromService(service: Service) {
        serviceRef = WeakReference(service)
        val data = pendingData
        val resultCode = pendingResultCode
        // Wrap the whole setup: a MediaCodec/VirtualDisplay misconfiguration must log +
        // clean up, not crash the host app.
        try {
            val activity = activityRef?.get()
            if (activity == null || data == null) return
            val mpm =
                service.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val proj = mpm.getMediaProjection(resultCode, data) ?: return
            projection = proj
            // API 34 requires a registered callback; harmless earlier.
            proj.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() = stopInternal()
            }, null)

            val dm = activity.resources.displayMetrics
            val (w, h) = captureSize(dm.widthPixels, dm.heightPixels, maxSize)

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                )
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                // Seconds; the integer form is the broadly-accepted one (the float
                // overload is rejected by some encoders on older API levels).
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, maxOf(1, keyframeIntervalMs / 1000))
            }

            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = codec.createInputSurface()
            codec.start()
            encoder = codec
            inputSurface = surface

            virtualDisplay = proj.createVirtualDisplay(
                "mob_screencast", w, h, dm.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
            )

            running = true
            drainThread = Thread { drainLoop(codec, w, h) }.also { it.start() }
            Log.i("MobScreencast", "capturing ${w}x${h} @ ${bitrate}bps")
        } catch (e: Throwable) {
            Log.e("MobScreencast", "projection setup failed: ${e.message}", e)
            stopInternal()
        }
    }

    private fun drainLoop(codec: MediaCodec, w: Int, h: Int) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val idx = codec.dequeueOutputBuffer(info, 10_000)
                if (idx < 0) continue
                val buf = codec.getOutputBuffer(idx)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buf.get(bytes)

                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    if (isConfig) {
                        csd = bytes // SPS/PPS, already Annex-B
                    } else {
                        // Prepend SPS/PPS to keyframes so a freshly-joined decoder starts.
                        val out = if (isKey) (csd ?: ByteArray(0)) + bytes else bytes
                        nativeDeliverScreencastFrame(
                            streamPid, out, w, h, System.currentTimeMillis(), if (isKey) 1 else 0,
                        )
                    }
                }
                codec.releaseOutputBuffer(idx, false)
            }
        } catch (e: Throwable) {
            Log.e("MobScreencast", "drain failed: ${e.message}")
        }
    }

    @Synchronized
    private fun stopInternal() {
        running = false
        try { drainThread?.join(500) } catch (_: Throwable) {}
        drainThread = null
        try { virtualDisplay?.release() } catch (_: Throwable) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Throwable) {}
        try { inputSurface?.release() } catch (_: Throwable) {}
        try { projection?.stop() } catch (_: Throwable) {}
        virtualDisplay = null; encoder = null; inputSurface = null; projection = null; csd = null
        try {
            serviceRef?.get()?.let { svc ->
                @Suppress("DEPRECATION")
                svc.stopForeground(true)
                svc.stopSelf()
            }
        } catch (_: Throwable) {}
        serviceRef = null
    }

    // Cap the longer edge to maxSize (if set), preserve aspect, round to even (H264).
    private fun captureSize(w: Int, h: Int, max: Int): Pair<Int, Int> {
        if (max <= 0 || (w <= max && h <= max)) return even(w) to even(h)
        val scale = max.toDouble() / maxOf(w, h)
        return even((w * scale).toInt()) to even((h * scale).toInt())
    }

    private fun even(n: Int): Int = if (n % 2 == 0) n else n - 1
}

// ScreencastService — the foreground service a MediaProjection capture must run inside.
//
// Android requires MediaProjection.start() (called by getMediaProjection) to happen
// while a foreground service of type mediaProjection is running — enforced even on
// API 30 (Android 11) on this hardware (verified: Moto G power 2021). So the bridge
// can't obtain the projection straight from the Activity consent callback.
//
// onProjectionResult stashes the consent result and starts this service;
// onStartCommand foregrounds it as type mediaProjection, then hands control back to
// MobScreencastBridge.beginCaptureFromService to obtain the projection + start the
// encoder. The matching <service android:foregroundServiceType="mediaProjection">
// element lives in the host AndroidManifest (the plugin manifest contributes the
// uses-permission entries but not a <service> yet — see PLAN.md known gap). This class
// lives in the bridge_kt file because the plugin merge copies only that one Kotlin
// source per plugin.
class ScreencastService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        // Now a foreground service of type mediaProjection — getMediaProjection is legal.
        MobScreencastBridge.beginCaptureFromService(this)
        return START_NOT_STICKY
    }

    private fun startForegroundCompat() {
        val channelId = "mob_screencast"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm != null && nm.getNotificationChannel(channelId) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        channelId, "Screen capture", NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val notif: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
                .setContentTitle("Screen capture active")
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    companion object {
        private const val NOTIF_ID = 8731
    }
}
