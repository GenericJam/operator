// mob_vision plugin — Android bridge (on-device OCR / text recognition).
//
// Runs ML Kit `text-recognition` on an image FILE (InputImage.fromFilePath) —
// no camera, no activity, no runtime permission. MobPluginBootstrap.registerAll()
// calls register() at startup and hands it the Activity (MobActivityAware) so we
// have a Context for InputImage. The native thunks (nativeRegister + the two
// deliver hooks) are exported from the sibling zig NIF mob_vision_nif.zig.
//
// ML Kit's recognizer.process() is already async (returns a Task and calls back
// on the main thread), so no explicit executor is needed — the NIF fires this
// and returns immediately; the result is delivered from the success/failure
// callback.
package io.mob.vision

import android.app.Activity
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
import java.lang.ref.WeakReference
import org.json.JSONObject

object MobVisionBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:vision, :text, binary}
    @JvmStatic external fun nativeDeliverVisionText(pid: Long, text: String)

    // {:vision, :error, binary}
    @JvmStatic external fun nativeDeliverVisionError(pid: Long, reason: String)

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // ── Recognize text in an image file ────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V.
    // reqJson is {"path": "...", "languages": [...]} — languages are ignored by
    // the default Latin recognizer (accepted for a future multi-script option).
    @JvmStatic
    fun recognize_text(
        pid: Long,
        reqJson: String,
    ) {
        val context =
            activityRef?.get() ?: run {
                nativeDeliverVisionError(pid, "no_activity")
                return
            }

        val path =
            try {
                JSONObject(reqJson).getString("path")
            } catch (_: Throwable) {
                nativeDeliverVisionError(pid, "bad_request")
                return
            }

        val file = File(path)
        if (!file.exists() || !file.canRead()) {
            nativeDeliverVisionError(pid, "no_image")
            return
        }

        val image =
            try {
                InputImage.fromFilePath(context, Uri.fromFile(file))
            } catch (e: Exception) {
                nativeDeliverVisionError(pid, e.message ?: "no_image")
                return
            }

        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer
            .process(image)
            .addOnSuccessListener { visionText ->
                nativeDeliverVisionText(pid, visionText.text)
            }.addOnFailureListener { e ->
                nativeDeliverVisionError(pid, e.message ?: "recognition_failed")
            }.addOnCompleteListener {
                recognizer.close()
            }
    }
}
