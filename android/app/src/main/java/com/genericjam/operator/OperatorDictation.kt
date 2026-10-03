package com.genericjam.operator

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import kotlinx.coroutines.delay

/**
 * The composer's mic: Android's `SpeechRecognizer` behind a chip, a
 * `Mob.UI.native_view` registered as "Operator_Core_DictationButton"
 * (driven by `Operator.Core.DictationButton`).
 *
 * Hold to talk: pressing starts listening (partial results stream into the
 * draft), releasing stops it and the final text lands in the draft to edit
 * and send. A press too short to say anything is cancelled with a hint.
 *
 * Events: `state` {"state": "listening" | "processing" | "idle"},
 * `partial` {"text"}, `final` {"text"}, `hint` {} (released too quickly),
 * `error` {"reason"}, `needs_permission` {} (RECORD_AUDIO not granted; the
 * screen asks through Mob.Permissions, since a native view has no Activity
 * result hook).
 */
object OperatorDictation {
    const val NAME = "Operator_Core_DictationButton"

    fun register() {
        MobNativeViewRegistry.register(NAME) { props, send -> OperatorDictationButton(props, send) }
    }

    internal fun reason(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_speech"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network"
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        SpeechRecognizer.ERROR_CLIENT -> "client"
        12, 13 -> "language" // ERROR_LANGUAGE_NOT_SUPPORTED / _UNAVAILABLE (API 31)
        else -> "error_$code"
    }
}

private enum class Phase { IDLE, LISTENING, PROCESSING }

/** One recognizer per mic, created on first use and destroyed with the view. */
private class Dictation(private val context: Context) {
    var recognizer: SpeechRecognizer? = null
    // Long pauses while the button is held mustn't end the recognition.
    private val holdSilenceMs = 10_000

    fun start(listener: RecognitionListener) {
        val r = recognizer ?: SpeechRecognizer.createSpeechRecognizer(context).also { recognizer = it }
        r.setRecognitionListener(listener)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // Online, explicitly: without the offline language pack (the Moto G
            // 2021 has none for en-CA) it fails at once with LANGUAGE_UNAVAILABLE.
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, holdSilenceMs)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, holdSilenceMs)
        }
        r.startListening(intent)
    }

    fun stop() = recognizer?.stopListening()

    fun cancel() = recognizer?.cancel()

    fun destroy() {
        recognizer?.destroy()
        recognizer = null
    }
}

private fun firstResult(bundle: Bundle?): String =
    bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

@Composable
fun OperatorDictationButton(props: Map<String, Any?>, send: MobNativeSend) {
    val context = LocalContext.current
    val currentSend by rememberUpdatedState(send)
    val dictation = remember { Dictation(context) }
    var phase by remember { mutableStateOf(Phase.IDLE) }

    DisposableEffect(Unit) { onDispose { dictation.destroy() } }

    fun color(key: String, default: Long) = Color(((props[key] as? Number)?.toLong() ?: default).toInt())
    val textColor = color("text_color", 0xFFE6E6E6)
    val activeColor = color("active_color", 0xFFFF6B6B)
    val background = color("background", 0xFF161B22)
    val textSize = (props["text_size"] as? Number)?.toFloat() ?: 15f
    val family = remember(props["font"]) {
        val name = props["font"] as? String ?: ""
        val id = if (name.isEmpty()) 0 else context.resources.getIdentifier(name, "font", context.packageName)
        val face: Typeface? = if (id != 0) ResourcesCompat.getFont(context, id) else null
        if (face != null) FontFamily(face) else FontFamily.Monospace
    }

    // The Google recognizer sometimes streams partials, then ends with an empty
    // final (or ERROR_NO_MATCH): the last partial is then the transcript.
    var lastPartial by remember { mutableStateOf("") }
    // The finger is down: the recognizer's own end-of-speech doesn't end a hold.
    var held by remember { mutableStateOf(false) }
    // Bumped per press, so a stale watchdog can't end a later session.
    var session by remember { mutableStateOf(0) }

    val listener = remember {
        object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                phase = Phase.LISTENING
                currentSend("state", mapOf("state" to "listening"))
            }

            override fun onEndOfSpeech() {
                if (held) return
                phase = Phase.PROCESSING
                currentSend("state", mapOf("state" to "processing"))
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val text = firstResult(partialResults)
                if (text.isNotEmpty()) {
                    lastPartial = text
                    currentSend("partial", mapOf("text" to text))
                }
            }

            override fun onResults(results: Bundle?) {
                phase = Phase.IDLE
                val text = firstResult(results).ifEmpty { lastPartial }
                lastPartial = ""
                currentSend("final", mapOf("text" to text))
                currentSend("state", mapOf("state" to "idle"))
            }

            override fun onError(error: Int) {
                // A press released too soon was cancelled (and hinted) already.
                if (phase == Phase.IDLE) return
                phase = Phase.IDLE
                val heard = lastPartial
                lastPartial = ""
                if (heard.isNotEmpty() &&
                    (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT)
                ) {
                    currentSend("final", mapOf("text" to heard))
                    currentSend("state", mapOf("state" to "idle"))
                    return
                }
                // Holding RECORD_AUDIO and still refused: the recognition
                // service (the Google app) has no microphone access itself.
                val reason =
                    if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED
                    ) "service_permission" else OperatorDictation.reason(error)
                currentSend("error", mapOf("reason" to reason))
                currentSend("state", mapOf("state" to "idle"))
            }

            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        }
    }

    fun begin(): Boolean =
        when {
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED -> {
                currentSend("needs_permission", emptyMap())
                false
            }
            !SpeechRecognizer.isRecognitionAvailable(context) -> {
                currentSend("error", mapOf("reason" to "unavailable"))
                false
            }
            else -> {
                phase = Phase.LISTENING
                lastPartial = ""
                dictation.start(listener)
                true
            }
        }

    val label = when (phase) {
        Phase.IDLE -> "mic"
        Phase.LISTENING -> "● rec"
        Phase.PROCESSING -> "…"
    }

    Box(
        modifier = Modifier
            .background(background)
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        if (phase == Phase.IDLE && begin()) {
                            val mine = ++session
                            held = true
                            val pressedAt = System.currentTimeMillis()
                            tryAwaitRelease()
                            held = false
                            // The recognizer may have finished (or failed) while held.
                            if (phase != Phase.IDLE) {
                                if (System.currentTimeMillis() - pressedAt < 300) {
                                    phase = Phase.IDLE
                                    dictation.cancel()
                                    currentSend("hint", emptyMap())
                                    currentSend("state", mapOf("state" to "idle"))
                                } else {
                                    phase = Phase.PROCESSING
                                    currentSend("state", mapOf("state" to "processing"))
                                    dictation.stop()
                                    // stopListening can take 10-20 s to report back (the
                                    // Google service waits out its own silence timer):
                                    // give the final 2 s, then end with what was heard.
                                    delay(2_000)
                                    if (session == mine && phase == Phase.PROCESSING) {
                                        phase = Phase.IDLE
                                        dictation.cancel()
                                        val heard = lastPartial
                                        lastPartial = ""
                                        if (heard.isNotEmpty()) {
                                            currentSend("final", mapOf("text" to heard))
                                        } else {
                                            currentSend("error", mapOf("reason" to "no_speech"))
                                        }
                                        currentSend("state", mapOf("state" to "idle"))
                                    }
                                }
                            }
                        }
                    },
                )
            }
            .padding(horizontal = 10.dp, vertical = 12.dp),
    ) {
        Text(
            text = label,
            color = if (phase == Phase.IDLE) textColor else activeColor,
            fontSize = textSize.sp,
            fontFamily = family,
        )
    }
}
