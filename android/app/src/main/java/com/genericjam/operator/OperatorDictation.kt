package com.genericjam.operator

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Typeface
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat

/**
 * The composer's mic chip, a `Mob.UI.native_view` registered as
 * "Operator_Core_DictationButton" (driven by `Operator.Core.DictationButton`).
 *
 * It only reports the gesture; the recognition runs in Elixir
 * (`MobSpeech` with the offline whisper engine, `mob_whisper`), because
 * Android's `SpeechRecognizer` depends on the Google app's language packs and
 * returns nothing on phones without them.
 *
 * Hold to talk. Events: `press` {} (finger down, microphone permission held),
 * `release` {} (finger up after at least 300 ms), `cancel` {} (up sooner:
 * too short to say anything), `needs_permission` {} (RECORD_AUDIO not
 * granted; the screen asks through Mob.Permissions).
 *
 * Props: `phase` ("idle" | "listening" | "processing", from the screen) sets
 * the label after release ("…" while transcribing); `text_color`,
 * `active_color`, `background` (ARGB), `text_size` (sp), `font` (an Android
 * font resource name).
 */
object OperatorDictation {
    const val NAME = "Operator_Core_DictationButton"

    fun register() {
        MobNativeViewRegistry.register(NAME) { props, send -> OperatorDictationButton(props, send) }
    }
}

@Composable
fun OperatorDictationButton(props: Map<String, Any?>, send: MobNativeSend) {
    val context = LocalContext.current
    val currentSend by rememberUpdatedState(send)
    // The finger is down (shown as recording before the screen's state arrives).
    var held by remember { mutableStateOf(false) }

    fun color(key: String, default: Long) = Color(((props[key] as? Number)?.toLong() ?: default).toInt())
    val textColor = color("text_color", 0xFFE6E6E6)
    val activeColor = color("active_color", 0xFFFF6B6B)
    val background = color("background", 0xFF161B22)
    val textSize = (props["text_size"] as? Number)?.toFloat() ?: 15f
    val phase = props["phase"] as? String ?: "idle"
    val family = remember(props["font"]) {
        val name = props["font"] as? String ?: ""
        val id = if (name.isEmpty()) 0 else context.resources.getIdentifier(name, "font", context.packageName)
        val face: Typeface? = if (id != 0) ResourcesCompat.getFont(context, id) else null
        if (face != null) FontFamily(face) else FontFamily.Monospace
    }

    val label = when {
        held || phase == "listening" -> "● rec"
        phase == "processing" -> "…"
        else -> "mic"
    }

    Box(
        modifier = Modifier
            .background(background)
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            currentSend("needs_permission", emptyMap())
                        } else {
                            held = true
                            val pressedAt = System.currentTimeMillis()
                            currentSend("press", emptyMap())
                            tryAwaitRelease()
                            held = false
                            val event = if (System.currentTimeMillis() - pressedAt < 300) "cancel" else "release"
                            currentSend(event, emptyMap())
                        }
                    },
                )
            }
            .padding(horizontal = 10.dp, vertical = 12.dp),
    ) {
        Text(
            text = label,
            color = if (label == "mic") textColor else activeColor,
            fontSize = textSize.sp,
            fontFamily = family,
        )
    }
}
