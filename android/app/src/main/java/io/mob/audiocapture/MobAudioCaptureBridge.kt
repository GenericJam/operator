package io.mob.audiocapture

// Device-audio capture bridge for the mob_audio_capture plugin.
//
// Captures the device OUTPUT MIX (audio other apps / native players produce) via
// MediaProjection + AudioPlaybackCapture (API 29+) — the capability a normal app
// cannot get from a session-0 Visualizer. A capture thread reads PCM from an
// AudioRecord and keeps the latest RMS/peak (dBFS); audio_capture_level() returns it.
//
// Integration: implements io.mob.plugin.MobActivityAware so mob hands it the host
// Activity. The native thunks (nativeRegister + nativeDeliverPermission) are exported
// from priv/native/jni/mob_audio_capture_nif.zig and linked into the host .so.
//
// NOTE: AudioPlaybackCapture must run inside a foreground service of type
// mediaProjection — the host AndroidManifest must declare AudioCaptureService (see the
// plugin manifest's :host_requirements).

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.log10
import kotlin.math.min
import kotlin.math.sqrt
import org.json.JSONObject

object MobAudioCaptureBridge : io.mob.plugin.MobActivityAware {
    private const val TAG = "MobAudioCapture"
    private const val SAMPLE_RATE = 44100
    private const val FLOOR_DB = -160f

    // Error codes returned to the NIF as a length-1 float[] (see the zig).
    private const val CODE_NEEDS_RECORD_AUDIO = 2f
    private const val CODE_NOT_CAPTURING = 4f

    private var activityRef: WeakReference<Activity>? = null
    private val consentSeq = AtomicLong(0L)

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverPermission(pid: Long, granted: Boolean)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // ── Capture session state ──────────────────────────────────────────────
    private var capturePid: Long = 0L
    private var usages: List<Int> = listOf(
        AudioAttributes.USAGE_MEDIA,
        AudioAttributes.USAGE_GAME,
        AudioAttributes.USAGE_UNKNOWN,
    )
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var captureThread: Thread? = null

    @Volatile private var running = false
    @Volatile private var lastRmsDb = FLOOR_DB
    @Volatile private var lastPeakDb = FLOOR_DB

    private var pendingResultCode: Int = 0
    private var pendingData: Intent? = null
    private var serviceRef: WeakReference<Service>? = null

    // ── NIF entry points (called from zig) ─────────────────────────────────

    @JvmStatic
    fun audio_capture_start(pid: Long, configJson: String) {
        if (running) stopInternal()
        capturePid = pid
        try {
            val cfg = JSONObject(configJson)
            val arr = cfg.optJSONArray("usages")
            if (arr != null) {
                val parsed = mutableListOf<Int>()
                for (i in 0 until arr.length()) {
                    when (arr.optString(i)) {
                        "media" -> parsed.add(AudioAttributes.USAGE_MEDIA)
                        "game" -> parsed.add(AudioAttributes.USAGE_GAME)
                        "unknown" -> parsed.add(AudioAttributes.USAGE_UNKNOWN)
                    }
                }
                if (parsed.isNotEmpty()) usages = parsed
            }
        } catch (_: Throwable) {
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            nativeDeliverPermission(pid, false) // AudioPlaybackCapture is API 29+
            return
        }
        if (!hasRecordAudio()) {
            // The caller must request RECORD_AUDIO at runtime first.
            nativeDeliverPermission(pid, false)
            return
        }

        val activity = activityRef?.get() ?: run {
            Log.e(TAG, "no activity for the MediaProjection consent")
            nativeDeliverPermission(pid, false)
            return
        }
        val owner = activity as? ActivityResultRegistryOwner ?: run {
            Log.e(TAG, "activity is not an ActivityResultRegistryOwner")
            nativeDeliverPermission(pid, false)
            return
        }
        try {
            val mpm =
                activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val key = "mob_audio_capture_consent_${consentSeq.incrementAndGet()}"
            var launcher: ActivityResultLauncher<Intent>? = null
            launcher = owner.activityResultRegistry.register(
                key,
                ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                if (result.resultCode == Activity.RESULT_OK && result.data != null) {
                    onProjectionResult(result.resultCode, result.data)
                } else {
                    nativeDeliverPermission(pid, false)
                }
                launcher?.unregister()
            }
            launcher.launch(mpm.createScreenCaptureIntent())
        } catch (e: Throwable) {
            Log.e(TAG, "consent launch failed: ${e.message}")
            nativeDeliverPermission(pid, false)
        }
    }

    @JvmStatic
    fun audio_capture_stop() = stopInternal()

    // Returns float[2] = [rms_db, peak_db] while capturing, else a length-1 error code.
    @JvmStatic
    fun audio_capture_level(): FloatArray {
        if (!hasRecordAudio()) return floatArrayOf(CODE_NEEDS_RECORD_AUDIO)
        if (!running) return floatArrayOf(CODE_NOT_CAPTURING)
        return floatArrayOf(lastRmsDb, lastPeakDb)
    }

    // ── Consent → foreground service → AudioRecord ─────────────────────────

    // Consent granted, but getMediaProjection().start() is illegal until a
    // mediaProjection-typed foreground service is running. Stash the result and start
    // AudioCaptureService; it foregrounds itself and calls beginCaptureFromService.
    internal fun onProjectionResult(resultCode: Int, data: Intent?) {
        if (data == null) return
        val activity = activityRef?.get() ?: run {
            Log.e(TAG, "no activity to start the capture service")
            nativeDeliverPermission(capturePid, false)
            return
        }
        pendingResultCode = resultCode
        pendingData = data
        try {
            val svc = Intent(activity, AudioCaptureService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(svc)
            } else {
                activity.startService(svc)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "failed to start capture service: ${e.message}", e)
            nativeDeliverPermission(capturePid, false)
        }
    }

    // Called from AudioCaptureService.onStartCommand once it is foregrounded as type
    // mediaProjection. getMediaProjection is now legal.
    internal fun beginCaptureFromService(service: Service) {
        serviceRef = WeakReference(service)
        val data = pendingData ?: return
        try {
            val mpm =
                service.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val proj = mpm.getMediaProjection(pendingResultCode, data) ?: run {
                nativeDeliverPermission(capturePid, false)
                return
            }
            projection = proj
            proj.registerCallback(
                object : MediaProjection.Callback() {
                    override fun onStop() = stopInternal()
                },
                null,
            )
            startRecord(proj)
            nativeDeliverPermission(capturePid, true)
        } catch (e: Throwable) {
            Log.e(TAG, "capture setup failed: ${e.message}", e)
            nativeDeliverPermission(capturePid, false)
            stopInternal()
        }
    }

    private fun startRecord(proj: MediaProjection) {
        val configBuilder = AudioPlaybackCaptureConfiguration.Builder(proj)
        for (u in usages) configBuilder.addMatchingUsage(u)
        val config = configBuilder.build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufSize = if (minBuf > 0) minBuf * 2 else SAMPLE_RATE

        val rec = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufSize)
            .setAudioPlaybackCaptureConfig(config)
            .build()
        record = rec
        rec.startRecording()
        running = true

        val buf = ShortArray(bufSize / 2)
        captureThread = Thread {
            while (running) {
                val n = try {
                    rec.read(buf, 0, buf.size)
                } catch (e: Throwable) {
                    Log.w(TAG, "read failed: ${e.message}")
                    break
                }
                if (n > 0) updateLevels(buf, n)
            }
        }.also { it.start() }
    }

    private fun updateLevels(buf: ShortArray, n: Int) {
        var sumSq = 0.0
        var peak = 0
        for (i in 0 until n) {
            val s = buf[i].toInt()
            sumSq += (s * s).toDouble()
            val a = if (s < 0) -s else s
            if (a > peak) peak = a
        }
        val rms = sqrt(sumSq / n)
        lastRmsDb = toDb(rms / 32768.0)
        lastPeakDb = toDb(peak / 32768.0)
    }

    private fun toDb(ratio: Double): Float {
        if (ratio <= 0.0) return FLOOR_DB
        val db = (20.0 * log10(ratio)).toFloat()
        return if (db < FLOOR_DB) FLOOR_DB else min(db, 0f)
    }

    private fun stopInternal() {
        running = false
        try {
            captureThread?.join(200)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        captureThread = null
        try {
            record?.stop()
        } catch (_: Throwable) {
        }
        try {
            record?.release()
        } catch (_: Throwable) {
        }
        record = null
        try {
            projection?.stop()
        } catch (_: Throwable) {
        }
        projection = null
        lastRmsDb = FLOOR_DB
        lastPeakDb = FLOOR_DB
        try {
            serviceRef?.get()?.stopSelf()
        } catch (_: Throwable) {
        }
        serviceRef = null
    }

    private fun hasRecordAudio(): Boolean {
        val activity = activityRef?.get() ?: return false
        return activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    internal fun notificationFor(service: Service): Notification {
        val channelId = "mob_audio_capture"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Audio capture", NotificationManager.IMPORTANCE_LOW),
            )
        }
        return Notification.Builder(service, channelId)
            .setContentTitle("Capturing device audio")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .build()
    }
}

// Foreground service that hosts the MediaProjection-based AudioRecord. Must be declared
// in the host AndroidManifest with android:foregroundServiceType="mediaProjection".
class AudioCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = MobAudioCaptureBridge.notificationFor(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(1, notification)
        }
        MobAudioCaptureBridge.beginCaptureFromService(this)
        return START_NOT_STICKY
    }
}
