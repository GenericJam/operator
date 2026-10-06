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
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference
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

    // audio_capture_start return codes, mapped to atoms by the zig.
    private const val START_PENDING = 0 // consent dialog launched; outcome arrives as a message
    private const val START_BUSY = 1 // another request's consent is still pending
    private const val START_DENIED = 2 // refused before any dialog (API < 29, no RECORD_AUDIO, no activity)

    // Carries the request token from the consent result to AudioCaptureService.
    internal const val EXTRA_TOKEN = "io.mob.audiocapture.TOKEN"

    private val defaultUsages = listOf(
        AudioAttributes.USAGE_MEDIA,
        AudioAttributes.USAGE_GAME,
        AudioAttributes.USAGE_UNKNOWN,
    )

    @Volatile private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverPermission(pid: Long, granted: Boolean)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        // Swap the activity and read pending under one lock, which narrows the window in
        // which a concurrent start() could launch on an activity this call replaces.
        val (req, ownerGone) = synchronized(lock) {
            activityRef = WeakReference(activity)
            val req = pending?.takeIf { it.data == null && it.activity.get() !== activity } ?: return
            req to (req.activity.get() == null)
        }
        // A new activity while the consent dialog is up (typically the old one was
        // recreated). Its result may be dispatched to this activity's registry, which
        // restores the request key but not our callback; register it again under the same
        // key so the result reaches us instead of parking there until stop().
        val owner = activity as? ActivityResultRegistryOwner ?: run {
            Log.w(TAG, "new activity is not an ActivityResultRegistryOwner; consent token=${req.token} not re-registered")
            // With the original activity gone too, nothing can receive the result.
            if (ownerGone) failPending(req)
            return
        }
        try {
            registerConsentCallback(owner, req)
            synchronized(lock) { req.activity = WeakReference(activity) }
            Log.i(TAG, "new activity; consent token=${req.token} re-registered")
        } catch (e: Throwable) {
            Log.e(TAG, "consent re-register failed: ${e.message}")
            failPending(req)
        }
    }

    // One start() call: the pid that asked, its capture config, the activity whose
    // registry holds its consent callback and, once the user grants consent, the
    // projection result. The token matches a late consent result or service start
    // against the request that is still current.
    private class CaptureRequest(
        val token: Long,
        val pid: Long,
        val usages: List<Int>,
        var activity: WeakReference<Activity>,
    ) {
        var resultCode: Int = 0
        var data: Intent? = null
    }

    // ── Capture session state (guarded by lock) ────────────────────────────
    private val lock = Any()
    private var tokenSeq = 0L

    // Per-process nonce in the consent registry key: tokens restart at 1 in every process,
    // and a restored registry can hold a parked result from a dead process under an old key.
    private val consentKeyPrefix = "mob_audio_capture_consent_${java.util.UUID.randomUUID()}_"

    // The request between start() and capture begin (consent dialog, then service start).
    // At most one; stop() clears it, which makes its consent result stale.
    private var pending: CaptureRequest? = null
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var captureThread: Thread? = null
    private var serviceRef: WeakReference<Service>? = null

    @Volatile private var running = false
    @Volatile private var lastRmsDb = FLOOR_DB
    @Volatile private var lastPeakDb = FLOOR_DB

    // ── NIF entry points (called from zig) ─────────────────────────────────

    @JvmStatic
    fun audio_capture_start(pid: Long, configJson: String): Int =
        try {
            startRequest(pid, configJson)
        } catch (e: Throwable) {
            // Never leave a Java exception pending on the NIF thread.
            Log.e(TAG, "start failed: ${e.message}", e)
            START_DENIED
        }

    private fun startRequest(pid: Long, configJson: String): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return START_DENIED // AudioPlaybackCapture is API 29+
        // The caller must request RECORD_AUDIO at runtime first.
        if (!hasRecordAudio()) return START_DENIED

        val (req, activity, owner) = synchronized(lock) {
            pending?.let {
                Log.w(TAG, "start rejected: consent token=${it.token} is still pending")
                return START_BUSY
            }
            val activity = activityRef?.get() ?: run {
                Log.e(TAG, "no activity for the MediaProjection consent")
                return START_DENIED
            }
            val owner = activity as? ActivityResultRegistryOwner ?: run {
                Log.e(TAG, "activity is not an ActivityResultRegistryOwner")
                return START_DENIED
            }
            if (projection != null) stopLocked()
            val req = CaptureRequest(++tokenSeq, pid, parseUsages(configJson), WeakReference(activity))
            pending = req
            Triple(req, activity, owner)
        }

        return try {
            val mpm =
                activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            registerConsentCallback(owner, req).launch(mpm.createScreenCaptureIntent())
            Log.i(TAG, "consent requested token=${req.token}")
            START_PENDING
        } catch (e: Throwable) {
            Log.e(TAG, "consent launch failed: ${e.message}")
            synchronized(lock) { if (pending === req) pending = null }
            START_DENIED
        }
    }

    private fun registerConsentCallback(
        owner: ActivityResultRegistryOwner,
        req: CaptureRequest,
    ): ActivityResultLauncher<Intent> {
        var launcher: ActivityResultLauncher<Intent>? = null
        launcher = owner.activityResultRegistry.register(
            consentKeyPrefix + req.token,
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            launcher?.unregister()
            onConsentResult(req, result.resultCode, result.data)
        }
        return launcher
    }

    @JvmStatic
    fun audio_capture_stop() = synchronized(lock) { stopLocked() }

    // Returns float[2] = [rms_db, peak_db] while capturing, else a length-1 error code.
    @JvmStatic
    fun audio_capture_level(): FloatArray {
        if (!hasRecordAudio()) return floatArrayOf(CODE_NEEDS_RECORD_AUDIO)
        if (!running) return floatArrayOf(CODE_NOT_CAPTURING)
        return floatArrayOf(lastRmsDb, lastPeakDb)
    }

    private fun parseUsages(configJson: String): List<Int> {
        val arr = try {
            JSONObject(configJson).optJSONArray("usages")
        } catch (_: Throwable) {
            null
        } ?: return defaultUsages
        val parsed = mutableListOf<Int>()
        for (i in 0 until arr.length()) {
            when (arr.optString(i)) {
                "media" -> parsed.add(AudioAttributes.USAGE_MEDIA)
                "game" -> parsed.add(AudioAttributes.USAGE_GAME)
                "unknown" -> parsed.add(AudioAttributes.USAGE_UNKNOWN)
            }
        }
        return parsed.ifEmpty { defaultUsages }
    }

    // ── Consent → foreground service → AudioRecord ─────────────────────────

    // Consent answered (main thread). A result for a request that is no longer pending
    // (stop() ran, or it was already resolved) is dropped: its projection token is
    // never redeemed, so no MediaProjection is created for it.
    //
    // Granted: getMediaProjection() is illegal until a mediaProjection-typed foreground
    // service is running. Keep the result on the request and start AudioCaptureService
    // with the token; it foregrounds itself and calls beginCaptureFromService.
    //
    // Outcome messages are sent while holding lock, so once stop() returns, no outcome
    // for the request it cancelled can still arrive (enif_send does not block).
    private fun onConsentResult(req: CaptureRequest, resultCode: Int, data: Intent?) {
        val granted = resultCode == Activity.RESULT_OK && data != null
        synchronized(lock) {
            if (pending !== req) {
                Log.i(TAG, "dropping stale consent result token=${req.token} granted=$granted; projection not acquired")
                return
            }
            if (!granted) {
                pending = null
                nativeDeliverPermission(req.pid, false)
                return
            }
            req.resultCode = resultCode
            req.data = data
        }
        val activity = activityRef?.get()
        if (activity == null) {
            Log.e(TAG, "no activity to start the capture service")
            failPending(req)
            return
        }
        try {
            val svc = Intent(activity, AudioCaptureService::class.java).putExtra(EXTRA_TOKEN, req.token)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(svc)
            } else {
                activity.startService(svc)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "failed to start capture service: ${e.message}", e)
            failPending(req)
        }
    }

    private fun failPending(req: CaptureRequest) = synchronized(lock) {
        if (pending === req) {
            pending = null
            nativeDeliverPermission(req.pid, false)
        }
    }

    // Called from AudioCaptureService.onStartCommand once it is foregrounded as type
    // mediaProjection, so getMediaProjection is now legal. A start whose token no longer
    // matches the pending request is stale: stop that service start and acquire nothing.
    @RequiresApi(Build.VERSION_CODES.Q)
    internal fun beginCaptureFromService(service: Service, token: Long, startId: Int) {
        synchronized(lock) {
            val req = pending
            val data = req?.data
            if (req == null || req.token != token || data == null) {
                Log.i(TAG, "dropping stale capture-service start token=$token; projection not acquired")
                service.stopSelf(startId)
                return
            }
            pending = null
            nativeDeliverPermission(req.pid, startCaptureLocked(service, req, data))
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startCaptureLocked(service: Service, req: CaptureRequest, data: Intent): Boolean {
        serviceRef = WeakReference(service)
        try {
            val mpm =
                service.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val proj = mpm.getMediaProjection(req.resultCode, data) ?: run {
                stopLocked()
                return false
            }
            projection = proj
            proj.registerCallback(
                object : MediaProjection.Callback() {
                    // Only tear down if this projection is still the live one; a late
                    // onStop from an earlier session must not cancel a newer request.
                    override fun onStop() = synchronized(lock) {
                        if (projection === proj) stopLocked()
                    }
                },
                null,
            )
            if (!startRecord(service, proj, req.usages)) {
                Log.e(TAG, "RECORD_AUDIO not granted; capture not started")
                stopLocked()
                return false
            }
            Log.i(TAG, "capture started token=${req.token}")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "capture setup failed: ${e.message}", e)
            stopLocked()
            return false
        }
    }

    // Returns false (nothing started) when RECORD_AUDIO is not granted.
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startRecord(context: Context, proj: MediaProjection, usages: List<Int>): Boolean {
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
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
        return true
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

    // Tear everything down and invalidate the pending request, so its consent result or
    // service start (if still in flight) is dropped as stale. Caller holds lock.
    private fun stopLocked() {
        pending?.let { Log.i(TAG, "stop: invalidated pending consent token=${it.token}") }
        pending = null
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
        val proj = projection
        projection = null
        if (proj != null) {
            try {
                proj.stop()
            } catch (_: Throwable) {
            }
            Log.i(TAG, "projection released")
        }
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
        return ContextCompat.checkSelfPermission(activity, android.Manifest.permission.RECORD_AUDIO) ==
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
        val token = intent?.getLongExtra(MobAudioCaptureBridge.EXTRA_TOKEN, -1L) ?: -1L
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MobAudioCaptureBridge.beginCaptureFromService(this, token, startId)
        } else {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }
}
