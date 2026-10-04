package com.genericjam.operator

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Typeface
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.res.ResourcesCompat

/**
 * The approve chip for self-changes: the system screen-lock prompt behind a
 * chip, a `Mob.UI.native_view` registered as "Operator_Core_ApproveButton"
 * (driven by `Operator.Core.ApproveButton`).
 *
 * Tap: `BiometricPrompt` (props `title`, `subtitle`) accepting a fingerprint
 * or face OR the phone's PIN, pattern or password (API 30+: BIOMETRIC_WEAK |
 * DEVICE_CREDENTIAL; API 29: setDeviceCredentialAllowed). API 28's platform
 * prompt can't offer the PIN, so there it's the keyguard's own credential
 * screen, launched through the Compose activity-result registry.
 *
 * Events: `approved` {}, `failed` {"reason": "canceled" | "lockout" |
 * "timeout" | "error_<code>"}, `unavailable` {} (no screen lock set at all),
 * each tagged with the `request` prop the prompt was opened for; a prompt
 * whose chip moves on to another `request` is dropped and reports nothing.
 */
object OperatorApproval {
    const val NAME = "Operator_Core_ApproveButton"

    fun register() {
        MobNativeViewRegistry.register(NAME) { props, send -> OperatorApproveButton(props, send) }
    }

    internal fun reason(code: Int): String = when (code) {
        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
        BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> "canceled"
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "lockout"
        BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "timeout"
        else -> "error_$code"
    }
}

/**
 * The prompt on screen for this chip, if any; `active` lets one result
 * through, and only from the current `attempt` (a cancelled prompt's late
 * callback must not answer for the next one).
 */
private class Approval {
    var signal: CancellationSignal? = null
    var active = false
    var request = ""
    var attempt = 0

    /** API 28: the attempt whose keyguard credential screen is up (0: none). */
    var keyguardAttempt = 0

    fun cancel() {
        active = false
        keyguardAttempt = 0
        signal?.cancel()
        signal = null
    }
}

@Composable
fun OperatorApproveButton(props: Map<String, Any?>, send: MobNativeSend) {
    val context = LocalContext.current
    val currentSend by rememberUpdatedState(send)
    val approval = remember { Approval() }
    var busy by remember { mutableStateOf(false) }

    val request = props["request"] as? String ?: ""

    // Left the screen, or the chip now stands for another request (a newer
    // proposal), with the prompt up: drop it and report nothing.
    DisposableEffect(request) {
        onDispose {
            approval.cancel()
            busy = false
        }
    }

    fun finish(attempt: Int, event: String, payload: Map<String, Any> = emptyMap()) {
        if (!approval.active || attempt != approval.attempt) return
        approval.active = false
        approval.signal = null
        busy = false
        currentSend(event, payload + ("request" to approval.request))
    }

    // API 28 only: the keyguard's credential screen answers through an activity result.
    val keyguardLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val attempt = approval.keyguardAttempt
        approval.keyguardAttempt = 0
        if (it.resultCode == Activity.RESULT_OK) finish(attempt, "approved")
        else finish(attempt, "failed", mapOf("reason" to "canceled"))
    }

    fun color(key: String, default: Long) = Color(((props[key] as? Number)?.toLong() ?: default).toInt())
    val textColor = color("text_color", 0xFFE6E6E6)
    val background = color("background", 0xFF161B22)
    val textSize = (props["text_size"] as? Number)?.toFloat() ?: 15f
    val label = props["label"] as? String ?: "approve"
    val title = props["title"] as? String ?: "Approve"
    val subtitle = props["subtitle"] as? String ?: ""
    val family = remember(props["font"]) {
        val name = props["font"] as? String ?: ""
        val id = if (name.isEmpty()) 0 else context.resources.getIdentifier(name, "font", context.packageName)
        val face: Typeface? = if (id != 0) ResourcesCompat.getFont(context, id) else null
        if (face != null) FontFamily(face) else FontFamily.Default
    }

    fun prompt() {
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val attempt = ++approval.attempt
        approval.active = true
        approval.request = request
        busy = true

        if (!keyguard.isDeviceSecure) {
            finish(attempt, "unavailable")
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            val intent = keyguard.createConfirmDeviceCredentialIntent(title, subtitle)
            if (intent == null) {
                finish(attempt, "unavailable")
            } else {
                approval.keyguardAttempt = attempt
                keyguardLauncher.launch(intent)
            }
            return
        }

        val builder = BiometricPrompt.Builder(context).setTitle(title)
        if (subtitle.isNotEmpty()) builder.setSubtitle(subtitle)
        // With the device credential allowed there must be no negative button
        // (build() throws); the system prompt brings its own cancel.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                finish(attempt, "approved")
            }

            // onAuthenticationFailed is not terminal: a fingerprint that didn't
            // match, and the prompt stays up for another try.

            override fun onAuthenticationError(code: Int, message: CharSequence) {
                if (code == BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL) finish(attempt, "unavailable")
                else finish(attempt, "failed", mapOf("reason" to OperatorApproval.reason(code)))
            }
        }

        val signal = CancellationSignal()
        approval.signal = signal
        // A prompt the system refuses (a missing permission, a vendor quirk)
        // must fail the approval, not take the app down.
        try {
            builder.build().authenticate(signal, context.mainExecutor, callback)
        } catch (e: RuntimeException) {
            approval.signal = null
            finish(attempt, "failed", mapOf("reason" to "error_${e.javaClass.simpleName}"))
        }
    }

    Box(
        modifier = Modifier
            .background(background)
            .clickable(enabled = !busy) { prompt() }
            .padding(6.dp),
    ) {
        Text(
            text = label,
            color = if (busy) textColor.copy(alpha = 0.5f) else textColor,
            fontSize = textSize.sp,
            fontFamily = family,
        )
    }
}
