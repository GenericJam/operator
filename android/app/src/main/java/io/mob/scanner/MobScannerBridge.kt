// mob_scanner plugin — Android bridge (QR/barcode scanner).
//
// Extracted from mob-core's MobBridge scanner_scan / handleScanResult
// (MobBridge.kt.eex:1359-1375) plus MainActivity's scannerLauncher /
// launchQrScanner (MainActivity.kt.eex:51-64). Lives in the plugin's own
// package; MobPluginBootstrap.registerAll() calls register() at startup and
// hands it the Activity (MobActivityAware). It is NOT a
// MobPermissionProvider — the :camera runtime permission is owned by the
// mob_camera plugin (activate mob_camera alongside mob_scanner).
//
// The native thunks (nativeRegister + the two deliver hooks) are exported
// directly from the sibling zig NIF mob_scanner_nif.zig.
//
// DESIGN NOTE vs core: core pre-registered the scanner launcher in
// MainActivity's onCreate via registerForActivityResult
// (MainActivity.kt.eex:54-59) and the bridge delegated to
// MainActivity.launchQrScanner() (MobBridge.kt.eex:1363), with the result
// handed back through the static MobBridge.handleScanResult
// (MainActivity.kt.eex:58). A late-bound plugin can't reference the
// generated MainActivity class, and registerForActivityResult must run
// before the host reaches STARTED — so this bridge registers directly on
// the ComponentActivity's ActivityResultRegistry (register(key, contract,
// callback) is callable any time), launches the plugin-owned
// MobScannerActivity Intent itself, handles the Intent extras in the
// callback, and unregisters — self-contained, no host MainActivity changes.
// (Same pattern as mob_camera's MobCameraBridge / mob_photos'
// MobPhotosBridge.) The pid travels through the closure instead of core's
// pendingScanPid static (MobBridge.kt.eex:1362).
package io.mob.scanner

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong
import android.os.Bundle
import android.util.Size
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import androidx.annotation.OptIn
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

object MobScannerBridge : io.mob.plugin.MobActivityAware {
    private const val TAG = "MobScanner"

    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:scan, :cancelled}
    @JvmStatic external fun nativeDeliverScanCancelled(pid: Long)

    // {:scan, :not_available} — the scanner Activity could not be launched.
    @JvmStatic external fun nativeDeliverScanNotAvailable(pid: Long)

    // {:scan, :permission_denied} — :camera refused.
    @JvmStatic external fun nativeDeliverScanPermissionDenied(pid: Long)

    // {:mob_file_result, "scan", "result", json} — decoded by core
    // Mob.Screen into {:scan, :result, %{type: atom, value: binary}}
    // (lib/mob/screen.ex:382-384)
    @JvmStatic external fun nativeDeliverScanResult(
        pid: Long,
        json: String,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private val scanSeq = AtomicLong(0L)

    // ── Scan ──────────────────────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V.
    // PARITY: formatsJson is accepted but ignored, exactly like core
    // (MobBridge.kt.eex:1361-1365) — MobScannerActivity scans all ML Kit
    // formats regardless.
    //
    // Called on a BEAM scheduler thread. Everything past the activity lookup
    // hops to the UI thread: ActivityResultRegistry.register()/launch() belong
    // there (same as mob_camera's launchCapture), and an exception thrown on
    // the NIF thread is uncaught and kills the whole process (MOB-293).
    @JvmStatic
    fun scanner_scan(
        pid: Long,
        formatsJson: String,
    ) {
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverScanCancelled(pid)
                return
            }
        activity.runOnUiThread {
            val owner =
                activity as? ActivityResultRegistryOwner ?: run {
                    nativeDeliverScanCancelled(pid)
                    return@runOnUiThread
                }
            val granted =
                ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
            if (granted) {
                launchScanner(activity, owner, pid)
            } else {
                requestCameraThenScan(activity, owner, pid)
            }
        }
    }

    // MOB-292 parity with iOS: an undecided :camera permission is requested
    // here instead of opening a preview CameraX can't feed. A permanently
    // denied permission resolves to granted=false without showing a dialog.
    private fun requestCameraThenScan(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
    ) {
        launchForResult(
            activity,
            owner,
            pid,
            ActivityResultContracts.RequestPermission(),
            Manifest.permission.CAMERA,
        ) { granted ->
            if (granted) {
                launchScanner(activity, owner, pid)
            } else {
                Log.w(TAG, "scan: android.permission.CAMERA denied")
                nativeDeliverScanPermissionDenied(pid)
            }
        }
    }

    private fun launchScanner(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
    ) {
        launchForResult(
            activity,
            owner,
            pid,
            ActivityResultContracts.StartActivityForResult(),
            Intent(activity, MobScannerActivity::class.java),
        ) { result ->
            // Same extras contract as core (MainActivity.kt.eex:55-58):
            // MobScannerActivity returns scan_value/scan_type Intent
            // extras on RESULT_OK, nothing on RESULT_CANCELED.
            val value = result.data?.getStringExtra("scan_value")
            val type = result.data?.getStringExtra("scan_type") ?: "qr"
            handleScanResult(pid, value, type)
        }
    }

    // Registers a one-shot launcher, launches it, and unregisters it after the
    // result has been dispatched. Unregistering inline from the callback would
    // run inside ActivityResultRegistry.doDispatch, before the key leaves
    // mLaunchedKeys, and unregister() then keeps the request-code/key mapping
    // (it lingers in the registry and its saved state) — so the unregister is
    // posted to run once dispatch has unwound. A launch that throws
    // (ActivityNotFoundException when the
    // <activity> isn't in the host manifest, IllegalStateException, a
    // SecurityException, ...) is terminal for this scan, never for the app:
    // the launcher is unregistered, the cause goes to logcat, and the caller
    // gets {:scan, :not_available} (MOB-293).
    //
    // The launch runs from a posted UI-thread block (or a result callback), so
    // the Activity captured at scanner_scan time may be finishing, destroyed,
    // or replaced by then. Its registry would never dispatch a result — the
    // scan would get no terminal message — so it is rejected before anything
    // is registered, with the same {:scan, :not_available}.
    private fun <I, O> launchForResult(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
        contract: ActivityResultContract<I, O>,
        input: I,
        onResult: (O) -> Unit,
    ) {
        if (activity.isFinishing || activity.isDestroyed || activityRef?.get() !== activity) {
            Log.w(TAG, "scan: host Activity finishing/destroyed/replaced, delivering {:scan, :not_available}")
            nativeDeliverScanNotAvailable(pid)
            return
        }
        val key = "mob_scanner_${scanSeq.incrementAndGet()}"
        var launcher: ActivityResultLauncher<I>? = null
        try {
            launcher =
                owner.activityResultRegistry.register(key, contract) { output ->
                    val done = launcher
                    Handler(Looper.getMainLooper()).post { done?.unregister() }
                    onResult(output)
                }
            launcher.launch(input)
        } catch (e: RuntimeException) {
            launcher?.unregister()
            Log.e(TAG, "scan: launching $key failed, delivering {:scan, :not_available}", e)
            nativeDeliverScanNotAvailable(pid)
        }
    }

    // Result processing copied from core MobBridge.handleScanResult
    // (MobBridge.kt.eex:1368-1375): null value -> cancelled; otherwise a
    // single-item JSON array [{"type","value"}] with quote escaping,
    // delivered through the {:mob_file_result, ...} path.
    internal fun handleScanResult(
        pid: Long,
        value: String?,
        type: String?,
    ) {
        if (value == null) {
            nativeDeliverScanCancelled(pid)
            return
        }
        val safeValue = value.replace("\"", "\\\"")
        val safeType = (type ?: "qr").replace("\"", "\\\"")
        val json = """[{"type":"$safeType","value":"$safeValue"}]"""
        nativeDeliverScanResult(pid, json)
    }
}

// ── MobScannerActivity ─────────────────────────────────────────────────
// Lives in this file because the build's bridge_kt channel copies exactly
// ONE Kotlin file per plugin into the host sourceSet — Kotlin allows
// multiple top-level classes per file. (A multi-file `android.kotlin_files`
// manifest capability is the systemic alternative if a plugin ever
// genuinely needs separate files.)
//
// Copied faithfully from the mob_new template
// (priv/templates/mob.new/android/app/src/main/java/MobScannerActivity.kt.eex),
// repackaged from the generated app package into the plugin-owned
// io.mob.scanner. Launched by MobScannerBridge via an explicit Intent;
// returns the scanned value/type as scan_value / scan_type Intent extras
// (RESULT_OK) or RESULT_CANCELED.
//
// The AndroidManifest declaration comes from this plugin's manifest
// (android.manifest_application_snippets in priv/mob_plugin.exs), spliced
// into the host <application> by `mix mob.deploy --native`. The AppCompat
// theme it sets is required: this extends AppCompatActivity (CameraX + ML
// Kit need it), which throws IllegalStateException at setContentView when
// the activity's theme isn't AppCompat-derived.
class MobScannerActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var scanHandled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val container = FrameLayout(this)
        setContentView(container)

        val previewView = PreviewView(this).also {
            it.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            container.addView(it)
        }

        // Cancel button
        val cancelBtn = ImageButton(this).also {
            it.setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            it.layoutParams = FrameLayout.LayoutParams(128, 128).apply { setMargins(32, 80, 0, 0) }
            it.setOnClickListener { setResult(Activity.RESULT_CANCELED); finish() }
            container.addView(it)
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val imageAnalyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { analysis ->
                    val scanner = BarcodeScanning.getClient()
                    analysis.setAnalyzer(executor) { imageProxy ->
                        @OptIn(ExperimentalGetImage::class)
                        val mediaImage = imageProxy.image
                        if (mediaImage != null && !scanHandled) {
                            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                            scanner.process(image)
                                .addOnSuccessListener { barcodes ->
                                    barcodes.firstOrNull()?.rawValue?.let { value ->
                                        if (!scanHandled) {
                                            scanHandled = true
                                            val type = when (barcodes.first().format) {
                                                Barcode.FORMAT_QR_CODE -> "qr"
                                                Barcode.FORMAT_EAN_13 -> "ean13"
                                                Barcode.FORMAT_EAN_8 -> "ean8"
                                                Barcode.FORMAT_CODE_128 -> "code128"
                                                Barcode.FORMAT_CODE_39 -> "code39"
                                                Barcode.FORMAT_PDF417 -> "pdf417"
                                                Barcode.FORMAT_AZTEC -> "aztec"
                                                Barcode.FORMAT_DATA_MATRIX -> "data_matrix"
                                                else -> "qr"
                                            }
                                            val result = Intent().apply {
                                                putExtra("scan_value", value)
                                                putExtra("scan_type", type)
                                            }
                                            setResult(Activity.RESULT_OK, result)
                                            finish()
                                        }
                                    }
                                }
                                .addOnCompleteListener { imageProxy.close() }
                        } else {
                            imageProxy.close()
                        }
                    }
                }
            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageAnalyzer)
            } catch (e: Exception) {
                setResult(Activity.RESULT_CANCELED); finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}
