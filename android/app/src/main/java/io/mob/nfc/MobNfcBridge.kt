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
  //
  // Emulation is foreground-only: when the activity pauses (backgrounded,
  // screen off/locked, a dialog-themed/permission activity on top, a config
  // change that recreates the activity) emulation is STOPPED, not suspended —
  // the payload is dropped, the preference released, the service refuses
  // further APDUs, and the owner gets {:nfc, :emulation_stopped}. Nothing
  // re-arms it here: the app calls emulate_ndef again (e.g. on Mob.Device's
  // :did_become_active).
  private val lifecycleCallbacks =
      object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
          if (activity !== activity()) return
          activityResumed = true
        }

        override fun onActivityPaused(activity: Activity) {
          if (activity !== activity()) return
          // No generation bump: a start queued behind this pause fails on
          // !activityResumed and still answers its caller.
          val pid = synchronized(emuLock) { takeEmulationLocked() }
          // Still resumed here (dispatched from inside Activity.onPause), which
          // unsetPreferredService requires.
          releasePreferredService(activity)
          activityResumed = false
          if (pid != 0L) {
            Log.i(TAG, "HCE stopped: activity paused")
            nativeDeliverNfcEmulationStopped(pid)
          }
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
    } catch (_: RuntimeException) {
      // UnsupportedOperationException (no HCE) or a flaky NFC service.
      null
    }
  }

  // Main-thread only. Set when setPreferredService succeeded, so the release
  // runs even if stop_emulation cleared the emulation before its UI post ran.
  private var preferredClaimed = false

  // Main thread, activity resumed. True when this app now owns HCE routing.
  // A failed re-claim leaves preferredClaimed as it was (the OS may still hold
  // the earlier preference); callers release with force on failure.
  private fun claimPreferredService(act: Activity): Boolean {
    val ce = cardEmulation(act) ?: return false
    val ok =
        try {
          ce.setPreferredService(act, ComponentName(act, MobNfcApduService::class.java))
        } catch (e: RuntimeException) {
          Log.w(TAG, "HCE setPreferredService failed", e)
          false
        }
    Log.i(TAG, "HCE setPreferredService -> $ok")
    if (ok) preferredClaimed = true
    return ok
  }

  // Main thread, activity resumed. `force` unsets even when no successful claim
  // is recorded (failure paths, where the OS state is uncertain).
  private fun releasePreferredService(act: Activity, force: Boolean = false) {
    if (!preferredClaimed && !force) return
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
  // One immutable snapshot — the raw NDEF message the emulated tag serves,
  // whether a reader may UPDATE BINARY into it, and the BEAM process to notify —
  // replaced wholesale so the service sees a consistent view per APDU.
  class Emulation(val ndef: ByteArray, val writable: Boolean, val pid: Long)

  // Null = not emulating. Written only under emuLock; read lock-free.
  @Volatile
  @JvmStatic
  var emulation: Emulation? = null
    private set

  // Guards `emulation` writes and `emulationGen`. BEAM threads (emulate/stop)
  // and the main thread (start/pause/APDU writes) both mutate them.
  private val emuLock = Any()

  // Bumped by every emulate_ndef / stop_emulation call so a main-thread start
  // can tell — at its checks AND at publish time — that it was superseded.
  private var emulationGen = 0

  // Largest NDEF message the emulated tag can serve: MobNfcApduService's CC
  // advertises a 1024-byte NDEF file, 2 bytes of which are NLEN. Mirrors
  // MobNfc.Hce.max_message_size/0.
  private const val MAX_NDEF_MESSAGE = 1022

  // Under emuLock: end the current emulation; returns its owner pid (0 = none).
  private fun takeEmulationLocked(): Long {
    val pid = emulation?.pid ?: 0L
    emulation = null
    return pid
  }

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

  /**
   * Begin emulating an NDEF tag serving `optsJson.ndef` (base64). Emits
   * emulation_started only once emulation is live (HCE feature, adapter
   * present + enabled, activity resumed, preferred-service routing granted);
   * otherwise one error (bad_payload / too_large / no_activity / unavailable /
   * disabled). A call superseded by a later emulate/stop before it took effect
   * gets no reply of its own.
   */
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
    if (bytes.size > MAX_NDEF_MESSAGE) {
      nativeDeliverNfcError(pid, "too_large")
      return
    }
    val writable = obj.optBoolean("writable", false)
    val gen = synchronized(emuLock) { ++emulationGen }
    val act =
        activity()
            ?: run {
              nativeDeliverNfcError(pid, "no_activity")
              return
            }
    act.runOnUiThread { startEmulation(pid, bytes, writable, gen) }
  }

  private fun superseded(gen: Int): Boolean = synchronized(emuLock) { emulationGen != gen }

  // Main thread. Gate on hardware + routing, THEN publish the payload.
  private fun startEmulation(pid: Long, bytes: ByteArray, writable: Boolean, gen: Int) {
    // A later emulate_ndef / stop_emulation already decided the state.
    if (superseded(gen)) return
    val act = activity() ?: return failStart(null, pid, gen, "no_activity")
    val a = NfcAdapter.getDefaultAdapter(act)
    val hce = act.packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)
    if (a == null || !hce) {
      Log.i(TAG, "HCE unavailable: adapter=${a != null} hceFeature=$hce")
      return failStart(act, pid, gen, "unavailable")
    }
    if (!a.isEnabled) return failStart(act, pid, gen, "disabled")
    // setPreferredService needs a resumed activity; a backgrounded app must not
    // emulate at all (see the pause handler).
    if (!activityResumed || !claimPreferredService(act)) {
      Log.i(TAG, "HCE unavailable: resumed=$activityResumed, routing not granted")
      return failStart(act, pid, gen, "unavailable")
    }
    // Re-check under the lock: a stop_emulation may have landed while the
    // claim's binder call ran. Its queued release (posted after this runnable)
    // then sees no emulation and unsets the claim we just made.
    var prevPid = 0L
    val published =
        synchronized(emuLock) {
          if (emulationGen != gen) {
            false
          } else {
            prevPid = emulation?.pid ?: 0L
            emulation = Emulation(bytes, writable, pid)
            true
          }
        }
    if (!published) return
    // Reader mode and card emulation are mutually exclusive on one NFC
    // controller — if a reader session is active (e.g. auto-armed on mount),
    // drop it so the phone presents purely as an emulated card. Only once
    // emulation is actually live, so a failed emulate leaves reading intact.
    try {
      a.disableReaderMode(act)
    } catch (_: Throwable) {}
    // Another process's emulation was replaced.
    if (prevPid != 0L && prevPid != pid) nativeDeliverNfcEmulationStopped(prevPid)
    nativeDeliverNfcEmulationStarted(pid)
  }

  // Main thread. A failed emulate request ends any previous emulation (it was
  // asking to replace it), releases routing, tells the previous owner — even
  // when that is the caller — and reports `reason` to the caller.
  private fun failStart(act: Activity?, pid: Long, gen: Int, reason: String) {
    val prevPid =
        synchronized(emuLock) {
          if (emulationGen != gen) return
          takeEmulationLocked()
        }
    if (act != null && activityResumed) releasePreferredService(act, force = true)
    if (prevPid != 0L) nativeDeliverNfcEmulationStopped(prevPid)
    nativeDeliverNfcError(pid, reason)
  }

  /** Stop emulating. Always acknowledges the caller with emulation_stopped. */
  @JvmStatic
  fun nfc_stop_emulation(pid: Long) {
    synchronized(emuLock) {
      emulationGen++
      takeEmulationLocked()
    }
    val act = activity()
    if (act != null) {
      act.runOnUiThread {
        // A newer emulate_ndef may have started before this ran; its session
        // owns the claim, so only release while emulation is still stopped.
        val current = activity()
        if (current != null && emulation == null && activityResumed) {
          releasePreferredService(current)
        }
      }
    }
    nativeDeliverNfcEmulationStopped(pid)
  }

  // Called by MobNfcApduService when a reader has read the emulated NDEF file
  // served from snapshot `emu`; notifies that emulation's owner.
  @JvmStatic
  fun onHceRead(emu: Emulation) {
    nativeDeliverNfcHceRead(emu.pid)
  }

  // Called by MobNfcApduService when a reader has WRITTEN a new NDEF message
  // into the emulated (writable) tag `expected`. Serves it from now on and
  // notifies — only if `expected` is still the live emulation, so a write begun
  // against one emulation never lands in a newer (possibly read-only) one or
  // resurrects a stopped one. Returns the new snapshot, or null if dropped.
  @JvmStatic
  fun onHceWritten(expected: Emulation, bytes: ByteArray): Emulation? {
    val next =
        synchronized(emuLock) {
          if (emulation !== expected) return null
          Emulation(bytes, expected.writable, expected.pid).also { emulation = it }
        }
    nativeDeliverNfcHceWritten(expected.pid, bytes)
    return next
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
// NDEF app AID D2760000850101, presenting MobNfcBridge.emulation as a tag.
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

  // The emulation snapshot the previous APDU was answered from. A different
  // one (stop + restart, or another emulate) resets the selection and any
  // half-written buffer, so one emulation's transaction can't continue into
  // the next.
  private var lastEmu: MobNfcBridge.Emulation? = null

  override fun processCommandApdu(apdu: ByteArray?, extras: Bundle?): ByteArray {
    // One snapshot per APDU. Not emulating (never started, stop_emulation, or
    // the app was paused): refuse everything so a reader can't even select the
    // NDEF application. Mirrors MobNfc.Hce.handle_apdu/2 on a stopped responder.
    val emu = MobNfcBridge.emulation
    if (emu !== lastEmu) {
      selectedFile = 0
      writeBuf = null
      lastEmu = emu
    }
    if (emu == null) return SW_FILE_NOT_FOUND
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
            1 -> capabilityContainer(emu.writable)
            2 -> ndefFile(emu.ndef)
            else -> return SW_FILE_NOT_FOUND
          }
      if (offset > file.size) return SW_ERROR
      val end = minOf(offset + le, file.size)
      val slice = file.copyOfRange(offset, end)
      // Notify once the NDEF file has been read to its end.
      if (selectedFile == 2 && end >= file.size) MobNfcBridge.onHceRead(emu)
      return slice + SW_OK
    }

    // UPDATE BINARY (00 D6 <off_hi> <off_lo> <lc> <data…>) — a reader writing
    // into the emulated NDEF file. Only honoured for a writable emulation and
    // only against the NDEF file (E104).
    if (apdu[0].toInt() and 0xFF == 0x00 && ins == 0xD6) {
      if (!emu.writable || selectedFile != 2) return SW_FILE_NOT_FOUND
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
        // Our own swap to the written message must not reset the session.
        lastEmu = MobNfcBridge.onHceWritten(emu, msg)
        // Emulation was stopped/replaced mid-write: nothing was stored, so
        // don't tell the writer it succeeded.
        if (lastEmu == null) return SW_FILE_NOT_FOUND
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
  private fun ndefFile(msg: ByteArray): ByteArray {
    val nlen = msg.size
    return byteArrayOf((nlen shr 8).toByte(), (nlen and 0xFF).toByte()) + msg
  }

  // Capability Container: CCLEN=000F, ver=2.0, MLe=00FB, MLc=00FF, then the
  // NDEF File Control TLV (T=04 L=06 fid=E104 maxsize=0400 read=00 write access).
  // Write access is 00 (writable) when emulating a writable tag, else FF (RO).
  private fun capabilityContainer(writable: Boolean): ByteArray {
    val write = if (writable) 0x00.toByte() else 0xFF.toByte()
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
