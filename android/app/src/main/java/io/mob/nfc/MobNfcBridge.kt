// MobNfcBridge.kt — plugin-owned Kotlin bridge class for mob_nfc.
//
// Mirrors mob_bluetooth's bridge. Re-homed to the plugin's OWN package
// `io.mob.nfc` so the JNI thunk symbol names
// (`Java_io_mob_nfc_MobNfcBridge_*`) are package-stable and shippable (they
// live in the sibling mob_nfc_jni.c).
//
// Registration: mob_dev copies this file into the app Kotlin sourceSet and
// generates `MobPluginBootstrap.registerAll(activity)` (called from
// MainActivity.onCreate) which invokes `register()` then `setActivity()`.
// `register()` calls the `nativeRegister` thunk (zig NIF), which caches THIS
// class's jclass + nfc_* method ids. The NIF's outbound CallStaticVoidMethod
// uses that cache; the `nativeDeliverNfc*` externs resolve to mob_nfc_jni.c.
//
// NFC reading uses NfcAdapter reader mode (enableReaderMode) — foreground
// dispatch while the activity is resumed. The reader callback fires on a binder
// thread; delivery `nativeDeliverNfc*` → enif_send is thread-safe.
package io.mob.nfc

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.pm.PackageManager
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.nfc.cardemulation.HostApduService
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.os.Bundle
import android.util.Log
import java.lang.ref.WeakReference

object MobNfcBridge : io.mob.plugin.MobActivityAware {

  // ── Bridge-class registration (caches this jclass + nfc_* method ids) ────
  @JvmStatic external fun nativeRegister()

  @JvmStatic
  fun register() {
    nativeRegister()
  }

  private var activityRef: WeakReference<Activity>? = null

  // Tracked from the lifecycle callbacks below: CardEmulation's preferred-service
  // calls throw unless the activity is resumed, and Activity.isResumed() is not
  // public SDK.
  @Volatile private var activityResumed = false
  private var lifecycleRegistered = false

  // Not @JvmStatic: overrides MobActivityAware.setActivity (illegal to be
  // @JvmStatic on an interface override in an object). Called via instance
  // dispatch from the generated bootstrap.
  override fun setActivity(activity: Activity) {
    activityRef = WeakReference(activity)
    activityResumed = false
    // MobActivityAware only hands over the Activity (from onCreate), so pause/
    // resume come from the Application. Registered once: a recreated activity
    // calls setActivity again on the same Application.
    if (!lifecycleRegistered) {
      lifecycleRegistered = true
      activity.application.registerActivityLifecycleCallbacks(lifecycleCallbacks)
    }
  }

  private fun activity(): Activity? = activityRef?.get()

  // While emulating, claim the HCE preferred service for as long as the
  // activity is in the foreground (Android's documented onResume/onPause
  // pattern). Without it, any other installed app registering the same NDEF AID
  // (D2760000850101, category "other") competes for routing and a reader tap
  // lands in the system AID-conflict chooser instead of MobNfcApduService.
  private val lifecycleCallbacks =
      object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
          if (activity !== activity()) return
          activityResumed = true
          if (emulatedNdef != null) claimPreferredService(activity)
        }

        override fun onActivityPaused(activity: Activity) {
          if (activity !== activity()) return
          // Still resumed here (dispatched from inside Activity.onPause), which
          // unsetPreferredService requires.
          releasePreferredService(activity)
          activityResumed = false
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

        override fun onActivityStarted(activity: Activity) {}

        override fun onActivityStopped(activity: Activity) {}

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

        override fun onActivityDestroyed(activity: Activity) {}
      }

  // Null on devices without NFC or without the HCE feature.
  private fun cardEmulation(act: Activity): CardEmulation? {
    if (!act.packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)) {
      return null
    }
    val a = NfcAdapter.getDefaultAdapter(act) ?: return null
    return try {
      CardEmulation.getInstance(a)
    } catch (_: UnsupportedOperationException) {
      null
    }
  }

  // Main-thread only. Set when setPreferredService succeeded, so the release
  // runs even if stop_emulation cleared emulatedNdef before its UI post ran.
  private var preferredClaimed = false

  // Main thread, activity resumed.
  private fun claimPreferredService(act: Activity) {
    val ce = cardEmulation(act) ?: return
    try {
      preferredClaimed =
          ce.setPreferredService(act, ComponentName(act, MobNfcApduService::class.java))
      Log.i(TAG, "HCE setPreferredService -> $preferredClaimed")
    } catch (e: RuntimeException) {
      Log.w(TAG, "HCE setPreferredService failed", e)
    }
  }

  // Main thread, activity resumed.
  private fun releasePreferredService(act: Activity) {
    if (!preferredClaimed) return
    preferredClaimed = false
    val ce = cardEmulation(act) ?: return
    try {
      Log.i(TAG, "HCE unsetPreferredService -> ${ce.unsetPreferredService(act)}")
    } catch (e: RuntimeException) {
      Log.w(TAG, "HCE unsetPreferredService failed", e)
    }
  }

  private const val TAG = "MobNfc"

  // One reader session at a time in this cut.
  @Volatile private var adapter: NfcAdapter? = null

  // Set while a write session is armed; the next tapped tag is written, not read.
  @Volatile private var pendingWrite: ByteArray? = null

  // HCE state (read by MobNfcApduService, which the OS instantiates separately).
  // `emulatedNdef` is the raw NDEF message the emulated tag serves; null = not
  // emulating. `emulationPid` is the BEAM process to notify on a reader read.
  // `emulationWritable` advertises the emulated tag as writable so a reader
  // (e.g. another phone's write_ndef) can UPDATE BINARY into it.
  @Volatile @JvmStatic var emulatedNdef: ByteArray? = null
  @Volatile @JvmStatic var emulationWritable: Boolean = false
  @Volatile private var emulationPid: Long = 0

  // ── Static methods the NIF calls (signatures cached by nativeRegister) ───

  /** True when the device has an NFC radio present and enabled. */
  @JvmStatic
  fun nfc_available(): Boolean {
    val act = activity() ?: return false
    val a = NfcAdapter.getDefaultAdapter(act) ?: return false
    return a.isEnabled
  }

  /** Start reader mode; NDEF/tag events flow back to `pid`. */
  @JvmStatic
  fun nfc_start_reading(pid: Long, optsJson: String?) {
    val act =
        activity()
            ?: run {
              nativeDeliverNfcError(pid, "no_activity")
              return
            }
    val a = NfcAdapter.getDefaultAdapter(act)
    if (a == null) {
      nativeDeliverNfcError(pid, "unavailable")
      return
    }
    if (!a.isEnabled) {
      nativeDeliverNfcError(pid, "disabled")
      return
    }
    adapter = a
    val flags =
        NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
    act.runOnUiThread {
      try {
        a.enableReaderMode(act, { tag -> onTag(pid, tag) }, flags, null)
        nativeDeliverNfcSessionStarted(pid)
      } catch (_: Throwable) {
        nativeDeliverNfcError(pid, "start_failed")
      }
    }
  }

  /** Arm a write session; the next tapped tag gets `optsJson.ndef` (base64). */
  @JvmStatic
  fun nfc_start_writing(pid: Long, optsJson: String?) {
    val bytes =
        try {
          val obj = org.json.JSONObject(optsJson ?: "{}")
          android.util.Base64.decode(obj.optString("ndef", ""), android.util.Base64.DEFAULT)
        } catch (_: Throwable) {
          nativeDeliverNfcError(pid, "write_failed")
          return
        }
    val act =
        activity()
            ?: run {
              nativeDeliverNfcError(pid, "no_activity")
              return
            }
    val a = NfcAdapter.getDefaultAdapter(act)
    if (a == null) {
      nativeDeliverNfcError(pid, "unavailable")
      return
    }
    if (!a.isEnabled) {
      nativeDeliverNfcError(pid, "disabled")
      return
    }
    adapter = a
    pendingWrite = bytes
    val flags =
        NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
    act.runOnUiThread {
      try {
        a.enableReaderMode(act, { tag -> onTag(pid, tag) }, flags, null)
        nativeDeliverNfcSessionStarted(pid)
      } catch (_: Throwable) {
        nativeDeliverNfcError(pid, "start_failed")
      }
    }
  }

  /** Stop the reader session started by `pid`. */
  @JvmStatic
  fun nfc_stop_reading(pid: Long) {
    pendingWrite = null
    val act = activity()
    val a = adapter
    if (act != null && a != null) {
      act.runOnUiThread {
        try {
          a.disableReaderMode(act)
        } catch (_: Throwable) {}
        nativeDeliverNfcSessionEnded(pid, "done")
      }
    } else {
      nativeDeliverNfcSessionEnded(pid, "done")
    }
  }

  /** Begin emulating an NDEF tag serving `optsJson.ndef` (base64). */
  @JvmStatic
  fun nfc_emulate_ndef(pid: Long, optsJson: String?) {
    val obj =
        try {
          org.json.JSONObject(optsJson ?: "{}")
        } catch (_: Throwable) {
          nativeDeliverNfcError(pid, "bad_payload")
          return
        }
    val bytes =
        try {
          android.util.Base64.decode(obj.optString("ndef", ""), android.util.Base64.DEFAULT)
        } catch (_: Throwable) {
          nativeDeliverNfcError(pid, "bad_payload")
          return
        }
    emulatedNdef = bytes
    emulationWritable = obj.optBoolean("writable", false)
    emulationPid = pid
    val act = activity()
    if (act != null) {
      val a = adapter
      act.runOnUiThread {
        // Reader mode and card emulation are mutually exclusive on one NFC
        // controller — if a reader session is active (e.g. auto-armed on
        // mount), drop it so the phone presents purely as an emulated card.
        if (a != null) {
          try {
            a.disableReaderMode(act)
          } catch (_: Throwable) {}
        }
        // Decided from the CURRENT state on the main thread, not this call's:
        // a later stop_emulation may already have cleared emulatedNdef, and a
        // paused activity re-claims from onActivityResumed instead.
        val current = activity()
        if (current != null && emulatedNdef != null && activityResumed) {
          claimPreferredService(current)
        }
      }
    }
    nativeDeliverNfcEmulationStarted(pid)
  }

  /** Stop emulating. */
  @JvmStatic
  fun nfc_stop_emulation(pid: Long) {
    emulatedNdef = null
    emulationWritable = false
    emulationPid = 0
    val act = activity()
    if (act != null) {
      act.runOnUiThread {
        // A newer emulate_ndef may have started before this ran; its session
        // owns the claim, so only release while emulation is still stopped.
        val current = activity()
        if (current != null && emulatedNdef == null && activityResumed) {
          releasePreferredService(current)
        }
      }
    }
    nativeDeliverNfcEmulationStopped(pid)
  }

  // Called by MobNfcApduService when a reader has read the emulated NDEF file.
  @JvmStatic
  fun onHceRead() {
    val pid = emulationPid
    if (pid != 0L) nativeDeliverNfcHceRead(pid)
  }

  // Called by MobNfcApduService when a reader has WRITTEN a new NDEF message
  // into the emulated (writable) tag. Updates what we now serve + notifies.
  @JvmStatic
  fun onHceWritten(bytes: ByteArray) {
    emulatedNdef = bytes
    val pid = emulationPid
    if (pid != 0L) nativeDeliverNfcHceWritten(pid, bytes)
  }

  // Reader callback (binder thread): write if a write session is armed,
  // otherwise read NDEF if present, else report the tag.
  private fun onTag(pid: Long, tag: Tag) {
    val toWrite = pendingWrite
    if (toWrite != null) {
      pendingWrite = null
      writeTag(pid, tag, toWrite)
      return
    }
    val tagId = tag.id?.joinToString("") { "%02x".format(it.toInt() and 0xFF) } ?: ""
    val ndef = Ndef.get(tag)
    if (ndef == null) {
      val tech = tag.techList?.joinToString(",") ?: ""
      nativeDeliverNfcTag(pid, tagId, tech)
      return
    }
    try {
      ndef.connect()
      val msg = ndef.ndefMessage ?: ndef.cachedNdefMessage
      val bytes = msg?.toByteArray() ?: ByteArray(0)
      nativeDeliverNfcNdef(pid, tagId, bytes, ndef.isWritable, ndef.maxSize)
    } catch (_: Throwable) {
      nativeDeliverNfcError(pid, "read_failed")
    } finally {
      try {
        ndef.close()
      } catch (_: Throwable) {}
    }
  }

  // Write path (binder thread): NDEF-formatted tags via Ndef, blank tags via
  // NdefFormatable.format. Reports :read_only / :too_small / :not_ndef /
  // :write_failed, or :written on success.
  private fun writeTag(pid: Long, tag: Tag, bytes: ByteArray) {
    val msg =
        try {
          NdefMessage(bytes)
        } catch (_: Throwable) {
          nativeDeliverNfcError(pid, "write_failed")
          return
        }
    val ndef = Ndef.get(tag)
    if (ndef != null) {
      try {
        ndef.connect()
        if (!ndef.isWritable) {
          nativeDeliverNfcError(pid, "read_only")
          return
        }
        if (ndef.maxSize < bytes.size) {
          nativeDeliverNfcError(pid, "too_small")
          return
        }
        ndef.writeNdefMessage(msg)
        nativeDeliverNfcWritten(pid, bytes.size)
      } catch (_: Throwable) {
        nativeDeliverNfcError(pid, "write_failed")
      } finally {
        try {
          ndef.close()
        } catch (_: Throwable) {}
      }
      return
    }
    // Not yet NDEF-formatted: format-and-write in one shot if the tag supports it.
    val formatable = NdefFormatable.get(tag)
    if (formatable != null) {
      try {
        formatable.connect()
        formatable.format(msg)
        nativeDeliverNfcWritten(pid, bytes.size)
      } catch (_: Throwable) {
        nativeDeliverNfcError(pid, "write_failed")
      } finally {
        try {
          formatable.close()
        } catch (_: Throwable) {}
      }
      return
    }
    nativeDeliverNfcError(pid, "not_ndef")
  }

  // ── delivery externs (resolve to mob_nfc_jni.c thunks) ───────────────────
  @JvmStatic external fun nativeDeliverNfcSessionStarted(pid: Long)

  @JvmStatic
  external fun nativeDeliverNfcNdef(
      pid: Long,
      tagId: String,
      ndef: ByteArray,
      writable: Boolean,
      maxSize: Int
  )

  @JvmStatic external fun nativeDeliverNfcTag(pid: Long, tagId: String, tech: String)

  @JvmStatic external fun nativeDeliverNfcWritten(pid: Long, bytes: Int)

  @JvmStatic external fun nativeDeliverNfcSessionEnded(pid: Long, reason: String)

  @JvmStatic external fun nativeDeliverNfcError(pid: Long, reason: String)

  @JvmStatic external fun nativeDeliverNfcEmulationStarted(pid: Long)

  @JvmStatic external fun nativeDeliverNfcEmulationStopped(pid: Long)

  @JvmStatic external fun nativeDeliverNfcHceRead(pid: Long)

  @JvmStatic external fun nativeDeliverNfcHceWritten(pid: Long, ndef: ByteArray)
}

// ── Host Card Emulation service (OS-instantiated, NOT via the bootstrap) ──────
//
// Rides in this same .kt file so mob_dev's single-`bridge_kt` copy delivers it.
// The OS creates it from the AndroidManifest <service> declaration (see the
// plugin manifest's android.manifest_application_snippets); it serves the NFC Forum Type-4 Tag command set
// (SELECT AID / SELECT CC / SELECT NDEF / READ BINARY / UPDATE BINARY) over the
// NDEF app AID D2760000850101, presenting MobNfcBridge.emulatedNdef as a tag.
//
// This is a faithful mirror of the pure `MobNfc.Hce` Elixir module
// (lib/mob_nfc/hce.ex), which is the TESTED reference for this state machine
// (test/hce_test.exs) — a HostApduService must answer readers even when the
// BEAM isn't running, so it can't delegate there at runtime. Keep the two in
// sync: same CC bytes, same SELECT/READ/UPDATE handling, same completion rule.
class MobNfcApduService : HostApduService() {
  // 0 = none selected, 1 = Capability Container (E103), 2 = NDEF file (E104).
  private var selectedFile = 0

  // When emulating a WRITABLE tag, a reader's UPDATE BINARY commands accumulate
  // here (the NDEF file image: [NLEN hi][NLEN lo][message…]). Null until the
  // first write; reset after a completed write / on deactivation.
  private var writeBuf: ByteArray? = null

  override fun processCommandApdu(apdu: ByteArray?, extras: Bundle?): ByteArray {
    if (apdu == null || apdu.size < 4) return SW_ERROR
    val ins = apdu[1].toInt() and 0xFF

    // SELECT (00 A4 ...)
    if (apdu[0].toInt() and 0xFF == 0x00 && ins == 0xA4) {
      val p1 = apdu[2].toInt() and 0xFF
      return when (p1) {
        // SELECT by name (AID) — the NDEF Tag Application.
        0x04 -> {
          selectedFile = 0
          SW_OK
        }
        // SELECT by file id (P1=00, P2=0C, Lc=02, file id follows).
        0x00 -> {
          if (apdu.size < 7) return SW_ERROR
          val fid = ((apdu[5].toInt() and 0xFF) shl 8) or (apdu[6].toInt() and 0xFF)
          selectedFile =
              when (fid) {
                0xE103 -> 1
                0xE104 -> 2
                else -> 0
              }
          if (selectedFile != 0) SW_OK else SW_FILE_NOT_FOUND
        }
        else -> SW_ERROR
      }
    }

    // READ BINARY (00 B0 <off_hi> <off_lo> <le>)
    if (apdu[0].toInt() and 0xFF == 0x00 && ins == 0xB0) {
      val offset = ((apdu[2].toInt() and 0xFF) shl 8) or (apdu[3].toInt() and 0xFF)
      val le = if (apdu.size >= 5) apdu[4].toInt() and 0xFF else 0
      val file =
          when (selectedFile) {
            1 -> capabilityContainer()
            2 -> ndefFile()
            else -> return SW_FILE_NOT_FOUND
          }
      if (offset > file.size) return SW_ERROR
      val end = minOf(offset + le, file.size)
      val slice = file.copyOfRange(offset, end)
      // Notify once the NDEF file has been read to its end.
      if (selectedFile == 2 && end >= file.size) MobNfcBridge.onHceRead()
      return slice + SW_OK
    }

    // UPDATE BINARY (00 D6 <off_hi> <off_lo> <lc> <data…>) — a reader writing
    // into the emulated NDEF file. Only honoured for a writable emulation and
    // only against the NDEF file (E104).
    if (apdu[0].toInt() and 0xFF == 0x00 && ins == 0xD6) {
      if (!MobNfcBridge.emulationWritable || selectedFile != 2) return SW_FILE_NOT_FOUND
      if (apdu.size < 5) return SW_ERROR
      val offset = ((apdu[2].toInt() and 0xFF) shl 8) or (apdu[3].toInt() and 0xFF)
      val lc = apdu[4].toInt() and 0xFF
      if (apdu.size < 5 + lc) return SW_ERROR
      val buf = writeBuf ?: ByteArray(NDEF_CAPACITY).also { writeBuf = it }
      if (offset + lc > buf.size) return SW_ERROR
      System.arraycopy(apdu, 5, buf, offset, lc)
      // A non-zero NLEN at offset 0 means the message is fully written.
      val nlen = ((buf[0].toInt() and 0xFF) shl 8) or (buf[1].toInt() and 0xFF)
      if (nlen in 1..(buf.size - 2)) {
        val msg = buf.copyOfRange(2, 2 + nlen)
        writeBuf = null
        MobNfcBridge.onHceWritten(msg)
      }
      return SW_OK
    }

    return SW_INS_NOT_SUPPORTED
  }

  override fun onDeactivated(reason: Int) {
    selectedFile = 0
    writeBuf = null
  }

  // NDEF file = 2-byte NLEN (message length) + the NDEF message.
  private fun ndefFile(): ByteArray {
    val msg = MobNfcBridge.emulatedNdef ?: ByteArray(0)
    val nlen = msg.size
    return byteArrayOf((nlen shr 8).toByte(), (nlen and 0xFF).toByte()) + msg
  }

  // Capability Container: CCLEN=000F, ver=2.0, MLe=00FB, MLc=00FF, then the
  // NDEF File Control TLV (T=04 L=06 fid=E104 maxsize=0400 read=00 write access).
  // Write access is 00 (writable) when emulating a writable tag, else FF (RO).
  private fun capabilityContainer(): ByteArray {
    val write = if (MobNfcBridge.emulationWritable) 0x00.toByte() else 0xFF.toByte()
    return byteArrayOf(
        0x00, 0x0F, 0x20, 0x00, 0xFB.toByte(), 0x00, 0xFF.toByte(),
        0x04, 0x06, 0xE1.toByte(), 0x04, 0x04, 0x00, 0x00, write)
  }

  companion object {
    // Max NDEF file size advertised in the CC (0x0400 = 1024, incl. 2-byte NLEN).
    private const val NDEF_CAPACITY = 1024
    private val SW_OK = byteArrayOf(0x90.toByte(), 0x00)
    private val SW_FILE_NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
    private val SW_INS_NOT_SUPPORTED = byteArrayOf(0x6D, 0x00)
    private val SW_ERROR = byteArrayOf(0x6F, 0x00)
  }
}
