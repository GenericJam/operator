// mob_biometric plugin — Android bridge (platform android.hardware.biometrics).
//
// Uses the PLATFORM BiometricPrompt (android.hardware.biometrics, API 28+),
// which is built from a Context and works with mob's ComponentActivity host.
// The previous androidx.biometric BiometricPrompt requires a FragmentActivity;
// mob's MainActivity is a ComponentActivity (Compose host), so the androidx path
// always failed its `as? FragmentActivity` cast and delivered :not_available
// regardless of enrollment. minSdk is 28, so the platform API covers the whole
// supported range — no FingerprintManager fallback needed. This mirrors how the
// camera bridge adapts to the ComponentActivity host instead of forcing a
// FragmentActivity.
//
// The native thunks (nativeRegister + nativeDeliverBiometric) are exported
// directly from the sibling zig NIF mob_biometric_nif.zig. MobPluginBootstrap
// .registerAll() calls register() at startup and hands it the Activity
// (MobActivityAware). No MobPermissionProvider: biometric auth has no runtime
// permission dialog — it uses the device's existing enrollment.
package io.mob.biometric

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

object MobBiometricBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // result: "success" | "failure" | "not_available" -> {:biometric, atom}
    @JvmStatic external fun nativeDeliverBiometric(pid: Long, result: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun biometric_authenticate(pid: Long, reason: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverBiometric(pid, "not_available"); return
        }

        // Build + show on the UI thread; results arrive on the main executor.
        activity.runOnUiThread {
            val executor = activity.mainExecutor

            // Exactly one terminal result reaches the BEAM, whichever fires first
            // (success, an error, or the Cancel button).
            val done = AtomicBoolean(false)
            fun deliver(result: String) {
                if (done.compareAndSet(false, true)) nativeDeliverBiometric(pid, result)
            }

            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    deliver("success")
                }

                // onAuthenticationFailed is NON-terminal (a biometric was read but
                // not matched; the prompt stays up to retry) — don't deliver here.

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    // User-dismissed -> :failure. No hardware / none enrolled /
                    // unavailable / lockout -> :not_available (no pre-check needed;
                    // the platform reports it here). The Cancel button is also
                    // handled by the negative-button listener below.
                    val outcome = when (code) {
                        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> "failure"
                        else -> "not_available"
                    }
                    deliver(outcome)
                }
            }

            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("Authenticate")
                .setSubtitle(reason)
                // A negative button (or an allowed device-credential authenticator)
                // is mandatory or build() throws.
                .setNegativeButton("Cancel", executor) { _, _ -> deliver("failure") }
                .build()

            prompt.authenticate(CancellationSignal(), executor, callback)
        }
    }
}
