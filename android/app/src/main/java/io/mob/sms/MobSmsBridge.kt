// mob_sms plugin — Android bridge.
//
// Two surfaces:
//
// 1. **sms_compose** (0.1.x, this shape) — Intent.ACTION_SENDTO with smsto:.
//    Opens the user's default SMS app pre-filled with recipient + body.
//    Cannot observe the outcome — Android hands off to a separate activity
//    and most SMS apps do not set an activity result, so the plugin delivers
//    :composer_opened once the composer is up and stops there. The asymmetry
//    vs iOS's inline sheet is documented in MobSms's @moduledoc.
//
// 2. **arm_one_time_code** (0.2.x) — Google Play Services SMS Retriever.
//    Server sends an SMS in the `<body>\n\n<11-char hash>` format; GMS
//    routes it to this app based on the hash and this plugin's
//    BroadcastReceiver extracts the body and delivers it as {:sms_otp, code}
//    to the calling pid. No permission, no user dialog, five-minute window.
//    Requires Google Play Services (99%+ of Play-installed devices).
//
// Both surfaces use the same native thunks pattern — nativeRegister at
// startup caches jclass + method ids, inbound thunks (nativeDeliverSms,
// nativeDeliverSmsCode) send tuples back to a Long-encoded pid.
//
// Android 11+ package-visibility: no <queries> block is required for
// sms_compose. That system gates PackageManager.resolveActivity /
// queryIntentActivities but NOT startActivity itself for ACTION_SENDTO.
// The bridge catches ActivityNotFoundException as the "no SMS app
// installed" signal and delivers :not_available.
package io.mob.sms

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import java.lang.ref.WeakReference

object MobSmsBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    // Track the live retriever alongside its caller pid. A second
    // arm_one_time_code call replaces the first (SmsRetriever is a per-app
    // singleton — startSmsRetriever replaces the prior arm) and delivers
    // {:sms_otp, ""} to the previous caller so its handle_info doesn't
    // wait forever for a message that can no longer come. All mutations to
    // `active` happen on the UI thread (arm) or in onReceive (which
    // registerReceiver(..., scheduler=null) dispatches on the main thread
    // too) so the field is effectively single-threaded — no lock needed.
    private data class ActiveArm(val receiver: BroadcastReceiver, val pid: Long)
    private var active: ActiveArm? = null

    @JvmStatic external fun nativeRegister()

    // result: "composer_opened" | "not_available" -> {:sms, atom}. See the
    // MobSms @moduledoc for why Android cannot deliver :sent or :cancelled.
    @JvmStatic external fun nativeDeliverSms(pid: Long, result: String)

    // code: the extracted verification code from the SMS body -> {:sms_otp, "123456"}.
    // "" (empty) is delivered on timeout / GMS failure — the caller sees an
    // empty code atom and treats it as "no code arrived, user must retype."
    @JvmStatic external fun nativeDeliverSmsCode(pid: Long, code: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun sms_compose(pid: Long, to: String, body: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverSms(pid, "not_available"); return
        }

        activity.runOnUiThread {
            // smsto:PHONE (URL-encoded) if we have a recipient, else bare
            // smsto: — Google Messages and the popular third-party SMS apps
            // both interpret bare smsto: as "open composer, no recipient
            // chosen." Body rides as the sms_body extra (the widely
            // supported extra key across SMS apps; the URI ?body= form
            // works on Messages but not everywhere).
            val uri = if (to.isEmpty()) {
                Uri.parse("smsto:")
            } else {
                Uri.parse("smsto:${Uri.encode(to)}")
            }
            val intent = Intent(Intent.ACTION_SENDTO, uri).apply {
                if (body.isNotEmpty()) putExtra("sms_body", body)
                // FLAG_ACTIVITY_NEW_TASK — the SMS app runs in its own task
                // stack, so returning to our app via Back does not first
                // clear the composer. Also needed if the activity ref points
                // at a non-Activity context (shouldn't happen here, but the
                // flag is safe when it does).
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            try {
                activity.startActivity(intent)
                nativeDeliverSms(pid, "composer_opened")
            } catch (e: ActivityNotFoundException) {
                nativeDeliverSms(pid, "not_available")
            }
        }
    }

    // Arm the Google Play Services SMS Retriever. Registers a BroadcastReceiver
    // scoped to the GMS SEND permission (so ONLY GMS can broadcast to it — no
    // random app can spoof an OTP delivery), then calls
    // SmsRetrieverClient.startSmsRetriever() to tell GMS to route matching
    // SMSes here. Delivers the extracted code as {:sms_otp, "123456"} on
    // arrival, or {:sms_otp, ""} on GMS timeout / start failure.
    //
    // A second arm_one_time_code call replaces the first: the previous
    // receiver is unregistered AND the previous caller pid is delivered
    // {:sms_otp, ""} so its handle_info doesn't wait forever. SmsRetriever
    // is a per-app singleton — startSmsRetriever inherently replaces any
    // in-flight arm — so keeping two receivers around would double-deliver
    // (or worse, lose one to the other) when the SMS finally arrives.
    @JvmStatic
    fun arm_one_time_code(pid: Long) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverSmsCode(pid, ""); return
        }

        activity.runOnUiThread {
            // Replace path: unblock the previous caller. deliverCodeAndUnregister
            // was the intended target; here we skip THAT because the current
            // pid is different — instead, deliver "" to the OLD pid and drop
            // its receiver.
            evictAndUnblock(activity.applicationContext)

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    // Idempotency guard — a queued broadcast that fires
                    // AFTER we unregistered this receiver would double-
                    // deliver. Compare identity, not just presence.
                    if (active?.receiver !== this) return
                    if (intent.action != SmsRetriever.SMS_RETRIEVED_ACTION) return
                    val extras: Bundle = intent.extras ?: run {
                        deliverCodeAndUnregister(context, pid, "")
                        return
                    }
                    val status = extras.get(SmsRetriever.EXTRA_STATUS) as? Status
                    when (status?.statusCode) {
                        CommonStatusCodes.SUCCESS -> {
                            val body = extras.getString(SmsRetriever.EXTRA_SMS_MESSAGE).orEmpty()
                            deliverCodeAndUnregister(context, pid, extractCode(body))
                        }
                        // TIMEOUT (5 min) or any other status — deliver "" so
                        // the caller unblocks and can re-arm or retype.
                        else -> deliverCodeAndUnregister(context, pid, "")
                    }
                }
            }
            active = ActiveArm(receiver, pid)

            val filter = IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION)
            // GMS SEND permission — only GMS can broadcast to our receiver.
            val gmsSendPermission = "com.google.android.gms.auth.api.phone.permission.SEND"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.applicationContext.registerReceiver(
                    receiver,
                    filter,
                    gmsSendPermission,
                    null,
                    Context.RECEIVER_EXPORTED
                )
            } else {
                @Suppress("DEPRECATION", "UnspecifiedRegisterReceiverFlag")
                activity.applicationContext.registerReceiver(
                    receiver,
                    filter,
                    gmsSendPermission,
                    null
                )
            }

            // Start the retriever. Task is async; success just means GMS
            // accepted the arm — the SMS itself arrives via the receiver.
            // GMS-absent devices (aftermarket ROMs) can throw synchronously
            // from getClient or startSmsRetriever, so wrap the whole block.
            // Failure listener catches the async case; try/catch catches the
            // sync case. Both bail with {:sms_otp, ""}.
            try {
                SmsRetriever.getClient(activity.applicationContext)
                    .startSmsRetriever()
                    .addOnFailureListener {
                        deliverCodeAndUnregister(activity.applicationContext, pid, "")
                    }
            } catch (t: Throwable) {
                deliverCodeAndUnregister(activity.applicationContext, pid, "")
            }
        }
    }

    // Called by onReceive on the success/timeout path — delivers to the
    // pid that arm_one_time_code was called with, then drops the receiver.
    private fun deliverCodeAndUnregister(context: Context, pid: Long, code: String) {
        unregisterActive(context)
        nativeDeliverSmsCode(pid, code)
    }

    // Called by a replacing arm_one_time_code — evicts the previous
    // receiver AND delivers "" to its pid so it doesn't hang forever.
    // No-op if no prior arm is active.
    private fun evictAndUnblock(context: Context) {
        val previous = active ?: return
        unregisterActive(context)
        nativeDeliverSmsCode(previous.pid, "")
    }

    private fun unregisterActive(context: Context) {
        active?.let { arm ->
            try {
                context.applicationContext.unregisterReceiver(arm.receiver)
            } catch (e: IllegalArgumentException) {
                // Already unregistered (e.g. receiver was never registered
                // because of an early-return path). Safe to swallow.
            }
        }
        active = null
    }

    // Extract the OTP from an SMS body. SMS Retriever's format tucks the
    // 11-char app-hash suffix on its own line after a blank line, so we
    // trim that off if present and look for the code in the body proper.
    //
    // Prefer the LAST 4-8-digit run in the trimmed body — the app name may
    // legitimately contain digits ("MyApp2024 code is 123456") and Google's
    // own template puts the code near the end of the sentence. Matches
    // Google's canonical extractor behaviour in their sample repo.
    //
    // 4-digit minimum matches OTP norms (4-8 digits typically). Alphanumeric
    // codes would need a different pattern; add when a caller asks.
    private val CODE_REGEX = "\\d{4,8}".toRegex()

    private fun extractCode(smsBody: String): String {
        // Google's SMS Retriever format puts the 11-char hash on its own
        // line separated by a blank line. Everything up to that separator
        // is body; anything after is transport metadata that shouldn't be
        // parsed for code content.
        val body = smsBody.substringBefore("\n\n")
        return CODE_REGEX.findAll(body).lastOrNull()?.value.orEmpty()
    }
}
