// MobBluetoothBridge.kt — plugin-owned Kotlin bridge class for mob_bluetooth.
//
// Extracted wholesale from mob-core's app `MobBridge.kt` (the bt suite): the 16
// implemented `bt_*` methods (BluetoothAdapter / socket / HFP / SCO code), the
// 32 `nativeDeliverBt*` externals, and the bt companion state. Re-homed to the
// plugin's OWN package `io.mob.bluetooth` so the JNI thunk symbol names
// (`Java_io_mob_bluetooth_MobBluetoothBridge_*`) are package-stable and
// shippable (they live in the sibling mob_bluetooth_jni.c).
//
// Registration: mob_dev copies this file into the app Kotlin sourceSet at build
// time and generates `MobPluginBootstrap.registerAll(activity)` (called from
// MainActivity.onCreate) which invokes `register()`. `register()` calls the
// `nativeRegister` thunk (in the zig NIF), which receives THIS class as its
// `cls` arg and caches the jclass + bt_* method ids — no FindClass, no
// classloader problem. The NIF's outbound CallStaticVoidMethod uses that cache;
// these methods' inbound nativeDeliverBt* externs resolve to the plugin's own
// JNI thunks.
//
// Activity access: the bt methods need an Android Activity. mob-core's
// MobBridge holds a private `activityRef` set from `init(activity)`. This
// plugin class can't see that private field (different package), so it keeps
// its OWN `activityRef`. It opts into the generic handoff by implementing
// `io.mob.plugin.MobActivityAware`; the generated bootstrap calls
// `setActivity(activity)` right after `register()`. No plugin-specific wiring
// in the host (see mob_dev decisions/2026-05-31-plugin-activity-handoff.md).
package io.mob.bluetooth

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray
import org.json.JSONObject

object MobBluetoothBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {

  // ── Bridge-class registration (caches this jclass + bt_* method ids) ─────
  @JvmStatic external fun nativeRegister()

  @JvmStatic
  fun register() {
    nativeRegister()
  }

  // ── Activity reference (see NOTE in the file header) ─────────────────────
  private var activityRef: WeakReference<Activity>? = null

  /**
   * Supplied by the generated MobPluginBootstrap.registerAll(activity) at
   * startup (MobActivityAware contract). Held weakly to avoid leaking the
   * Activity across its lifecycle.
   */
  // Not @JvmStatic: it overrides MobActivityAware.setActivity, and @JvmStatic
  // is illegal on an interface override in an object. Called via the interface
  // (instance dispatch) from the generated bootstrap's handOff, so no static
  // accessor is needed.
  override fun setActivity(activity: Activity) {
    // MOB-61: Activity swap requires unregistering lifecycle-owned
    // receivers from the outgoing Context BEFORE nulling the fields —
    // otherwise the old receiver stays wired to the old Activity while
    // the next connect allocates a fresh one on the new Activity, and
    // every event fires twice against the same shared maps. Discovery
    // cancel (`btDiscoveryReceiver?.let { ... }`) would also silently
    // no-op because the reference was nulled while the actual receiver
    // still lived on the old Context. Pre-merge review caught this on
    // the MOB-61 PR. mob's MainActivity is app-lifetime today so this
    // is mostly defensive, but the receivers are what makes the path
    // executable — do it correctly.
    val previous = activityRef?.get()
    if (previous != null) {
      listOfNotNull(
          btPairingRequestReceiver,
          btBondReceiver,
          btHfpConnectionReceiver,
          btHfpVendorReceiver,
          btDiscoveryReceiver,
          bleNameReceiver,
      ).forEach { r ->
        try {
          previous.unregisterReceiver(r)
        } catch (_: Throwable) {
          // "receiver not registered" if the Activity teardown already
          // pulled it — either way we drop the reference below.
        }
      }
    }
    btPairingRequestReceiver = null
    btBondReceiver = null
    // MOB-320: with the bond receiver gone, these waiters' terminal events
    // can't arrive. Give each its one terminal message now (and drop their
    // PINs) so a later pair() for the same device starts a fresh bond
    // instead of joining one nobody is listening to.
    for ((address, waiter) in btBondWaiters.drainAll()) {
      btBondPins.remove(address)
      nativeDeliverBtPairFailed(waiter, address, "activity_replaced")
    }
    btHfpConnectionReceiver = null
    btHfpVendorReceiver = null
    btDiscoveryReceiver = null
    bleNameReceiver = null
    activityRef = WeakReference(activity)
  }

  // MobPermissionProvider: route the :bluetooth_connect capability to every
  // runtime permission the plugin's surface needs on THIS device, so one
  // Mob.Permissions.request grants discovery, pairing, profiles and
  // advertising together. The generated MobPluginBootstrap records this
  // provider at registerAll; core's request_permission consults it, and
  // replies :granted only when every returned permission is granted — so the
  // list must never contain a permission the running SDK doesn't define
  // (API <= 30 would report :denied forever). See
  // MobBluetoothPolicy.bluetoothConnectPermissions for the per-API list.
  override fun permissionsFor(cap: String): Array<String>? =
      if (cap == "bluetooth_connect") {
        MobBluetoothPolicy.bluetoothConnectPermissions(Build.VERSION.SDK_INT, scanDisavowsLocation())
      } else {
        null
      }

  // MOB-319: true when the host's merged AndroidManifest declares
  // BLUETOOTH_SCAN with android:usesPermissionFlags="neverForLocation" (API
  // 31+). Only then does Android 12+ discovery work without location access.
  // mob_dev's plugin manifest schema can't carry that attribute today, so a
  // host opts in by hand-declaring the tag; read the installed package's
  // flags rather than assuming either way.
  private fun scanDisavowsLocation(): Boolean {
      if (Build.VERSION.SDK_INT < 31) return false
      val ctx = activityRef?.get() ?: return false
      return try {
          @Suppress("DEPRECATION")
          val info = ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_PERMISSIONS)
          val names = info.requestedPermissions ?: return false
          val flags = info.requestedPermissionsFlags ?: return false
          val i = names.indexOf(android.Manifest.permission.BLUETOOTH_SCAN)
          i in flags.indices &&
              (flags[i] and PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0
      } catch (_: Exception) {
          false
      }
  }

  // ── Mob.Bt — typed delivery externs (resolve to mob_bluetooth_jni.c) ─────
  @JvmStatic external fun nativeDeliverBtDiscoveryStarted(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscoveryFinished(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscoveryCancelled(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscovered(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPaired(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPairFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtUnpaired(pid: Long, address: String)
  @JvmStatic external fun nativeDeliverBtError(pid: Long, reason: String)
  @JvmStatic external fun nativeDeliverBtPairedListBegin(pid: Long)
  @JvmStatic external fun nativeDeliverBtPairedListEntry(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPairedListFinish(pid: Long)
  @JvmStatic external fun nativeDeliverBtHfpConnecting(pid: Long, session: Int, address: String)
  @JvmStatic external fun nativeDeliverBtHfpConnected(pid: Long, session: Int, address: String, name: String)
  @JvmStatic external fun nativeDeliverBtHfpConnectFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtHfpDisconnected(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtHfpVendorSubscribed(pid: Long, session: Int)
  @JvmStatic external fun nativeDeliverBtHfpVendorAt(pid: Long, session: Int, cmd: String, cmdType: Int, args: String, address: String)
  @JvmStatic external fun nativeDeliverBtHfpScoStarted(pid: Long, session: Int, address: String)
  @JvmStatic external fun nativeDeliverBtHfpScoStopped(pid: Long, session: Int)
  @JvmStatic external fun nativeDeliverBtHfpError(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtSppConnected(pid: Long, session: Int, address: String, name: String)
  @JvmStatic external fun nativeDeliverBtSppConnectFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtSppDisconnected(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtSppData(pid: Long, session: Int, data: ByteArray)
  @JvmStatic external fun nativeDeliverBtSppWritten(pid: Long, session: Int, size: Int)
  @JvmStatic external fun nativeDeliverBtSppError(pid: Long, session: Int, reason: String)

  // ── Mob.Bt — BLE (Low Energy) GATT-peripheral delivery externs ───────────
  // Resolve to the same sibling mob_bluetooth_jni.c thunks; each posts back to
  // the {:bt_le, ...} channel via the zig mob_deliver_ble_* exports.
  @JvmStatic external fun nativeDeliverBleAdvertisingStarted(pid: Long)
  @JvmStatic external fun nativeDeliverBleAdvertisingFailed(pid: Long, reason: String)
  @JvmStatic external fun nativeDeliverBleCentralConnected(pid: Long, central: Int)
  @JvmStatic external fun nativeDeliverBleCentralDisconnected(pid: Long, central: Int)
  @JvmStatic external fun nativeDeliverBleSubscribed(pid: Long, characteristic: String)
  @JvmStatic external fun nativeDeliverBleUnsubscribed(pid: Long, characteristic: String)
  @JvmStatic external fun nativeDeliverBleWrite(pid: Long, characteristic: String, bytes: ByteArray)

  // ── BT companion state ───────────────────────────────────────────────────
  private val btSessionMap = ConcurrentHashMap<Int, BluetoothDevice>()
  private val btSessionCounter = AtomicInteger(1)
  private var btDiscoveryReceiver: BroadcastReceiver? = null
  private var btDiscoveryPid: Long = 0
  private var btBondReceiver: BroadcastReceiver? = null
  // MOB-320: every pair() caller waiting on a device's bond, so a second
  // pair() while that bond is in flight joins it instead of tearing it down.
  private val btBondWaiters = BondWaiters()
  // MOB-61: caller-supplied PINs, keyed by device MAC. The
  // ACTION_PAIRING_REQUEST receiver reads this map and, when the
  // system asks the app to answer a PIN prompt for a device we have
  // a PIN for, calls `device.setPin(pin)` — auto-answering without
  // showing the system dialog. Cleared when the bond transitions
  // to BONDED or NONE.
  private val btBondPins = ConcurrentHashMap<String, String>()
  // One-shot receiver for the plugin lifetime; only fires when at
  // least one entry is in `btBondPins`.
  private var btPairingRequestReceiver: BroadcastReceiver? = null
  private var btHfpProxy: BluetoothHeadset? = null
  private val btHfpVendorPids = ConcurrentHashMap<Int, Long>()
  private var btHfpVendorReceiver: BroadcastReceiver? = null
  // MOB-64: pid to notify when a device's HFP profile finishes connecting.
  // Keyed by session id (which is 1:1 with device address inside btSessionMap).
  // Also used to route :bt_hfp, :disconnected events (MOB-63) — a bt_disconnect
  // caller updates the pid so the disconnect event lands with them, not the
  // original connect requester.
  private val btHfpSessionPids = ConcurrentHashMap<Int, Long>()
  // MOB-63: sessions we asked to disconnect locally. The state-change
  // receiver consumes the marker to emit :disconnected with reason "local"
  // instead of the "peer" default (which would lie to the caller who
  // explicitly asked for the disconnect).
  private val btHfpLocalDisconnects: MutableSet<Int> =
      java.util.concurrent.ConcurrentHashMap.newKeySet()
  // MOB-63/64: one receiver for the whole plugin lifetime, tracking every
  // HFP state transition so :bt_hfp, :connected fires for newly-initiated
  // connects and :bt_hfp, :disconnected fires whether the disconnect was
  // local (via bt_disconnect) or remote (peer turned off).
  private var btHfpConnectionReceiver: BroadcastReceiver? = null
  private val btSppSockets = ConcurrentHashMap<Int, BluetoothSocket>()
  // Serialises SPP socket ownership with session retirement (bt_disconnect
  // vs. the read thread's remote-close cleanup vs. a reconnect's re-pin), so
  // each SPP connection yields exactly one :disconnected.
  private val btSppLock = Any()
  private val btSppReadThreads = ConcurrentHashMap<Int, Thread>()

  private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

  // ── BLE (Low Energy) GATT-peripheral state ───────────────────────────────
  // Some Android BLE calls (openGattServer / advertiser start) misbehave off
  // the main thread on certain OEM stacks, so GATT-server setup + advertising
  // start run on `main`, mirroring the sibling mob_midi plugin.
  private val main = Handler(Looper.getMainLooper())

  // Standard Client Characteristic Configuration Descriptor — a central writes
  // this to subscribe/unsubscribe to notifications/indications.
  private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

  private var bleGattServer: BluetoothGattServer? = null
  private var bleAdvertiser: BluetoothLeAdvertiser? = null
  private var bleAdvertiseCallback: AdvertiseCallback? = null
  private var bleAdvertisingPid: Long = 0
  // MOB-321: the adapter's own name while start_advertising(local_name:) has
  // replaced it; put back by bleTeardown and on advertise failure. Touched
  // only on `main` (start/stop post there; AdvertiseCallback runs there).
  private val bleNameGuard = AdapterNameGuard()
  // Feeds ACTION_LOCAL_NAME_CHANGED into bleNameGuard.observe — the only way
  // a rename / restore of ours counts as landed — and (MOB-360) releases a
  // start bleStartGate holds once the guard settles. Registered on the first
  // rename; runs on main like the guard's other users.
  private var bleNameReceiver: BroadcastReceiver? = null
  // MOB-360: holds startAdvertising while a rename / restore of ours is in
  // flight, and tells callbacks whether their start is still the current
  // one. Main only.
  private val bleStartGate = AdvertStartGate()
  // Characteristics built for the running service, keyed by uppercase UUID
  // string, so ble_notify can look them up to push a new value.
  private val bleCharacteristics = ConcurrentHashMap<String, BluetoothGattCharacteristic>()
  // Connected centrals: device.address -> opaque incrementing Int handle.
  private val bleCentrals = ConcurrentHashMap<String, Int>()
  // Reverse: address -> BluetoothDevice, so notify can target each central.
  private val bleDevices = ConcurrentHashMap<String, BluetoothDevice>()
  private val bleCentralCounter = AtomicInteger(1)

  private fun btAdapter(): BluetoothAdapter? {
      val ctx = activityRef?.get() ?: return null
      val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
      return mgr?.adapter
  }

  private fun btSessionFor(device: BluetoothDevice): Int {
      for ((id, dev) in btSessionMap) {
          if (dev.address == device.address) return id
      }
      val id = btSessionCounter.getAndIncrement()
      btSessionMap[id] = device
      return id
  }

  private fun btSafeName(device: BluetoothDevice): String =
      try { device.name ?: device.address } catch (_: SecurityException) { device.address }

  // ── Discovery / pair / list paired ──────────────────────────────────────

  @JvmStatic
  fun bt_list_paired(pid: Long) {
      val adapter = btAdapter() ?: run { Log.d("MobBT", "no_adapter"); nativeDeliverBtError(pid, "no_adapter"); Log.d("MobBT", "after no_adapter delivery"); return }
      if (!adapter.isEnabled) { Log.d("MobBT", "adapter_disabled"); nativeDeliverBtError(pid, "adapter_disabled"); Log.d("MobBT", "after adapter_disabled delivery"); return }
      try {
          nativeDeliverBtPairedListBegin(pid)
          for (dev in adapter.bondedDevices ?: emptySet()) {
              nativeDeliverBtPairedListEntry(pid,
                  dev.address,
                  btSafeName(dev),
                  dev.bondState == BluetoothDevice.BOND_BONDED)
          }
          nativeDeliverBtPairedListFinish(pid)
      } catch (e: SecurityException) {
          nativeDeliverBtError(pid, "permission_denied")
      }
  }

  @JvmStatic
  fun bt_start_discovery(pid: Long) {
      Log.d("MobBT", "bt_start_discovery entered, pid=$pid")
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get() ?: run { Log.d("MobBT", "no_activity"); nativeDeliverBtError(pid, "no_activity"); Log.d("MobBT", "after no_activity delivery"); return }
      if (!adapter.isEnabled) { nativeDeliverBtError(pid, "adapter_disabled"); return }

      Log.d("MobBT", "step1: about to unregister old receiver if exists")
      clearDiscovery(activity)
      Log.d("MobBT", "step2: setting btDiscoveryPid")

      btDiscoveryPid = pid
      Log.d("MobBT", "step3: about to create receiver")
      val receiver = object : BroadcastReceiver() {
          // MOB-322: a run started here ends with exactly one
          // :discovery_finished, after which the receiver retires itself so a
          // later system discovery stop (createBond cancels discovery) can't
          // deliver a stray one. The FINISHED broadcast from cancelling an
          // already-running discovery (below) predates our STARTED, so it's
          // ignored rather than ending our run early.
          private var started = false

          override fun onReceive(ctx: Context, intent: Intent) {
              val deliveryPid = btDiscoveryPid
              if (deliveryPid == 0L || btDiscoveryReceiver !== this) return
              when (intent.action) {
                  BluetoothAdapter.ACTION_DISCOVERY_STARTED -> started = true
                  BluetoothDevice.ACTION_FOUND -> {
                      val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                          intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                      else
                          @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                      if (device != null) {
                          // bondState needs BLUETOOTH_CONNECT on 31+, which
                          // discovery (BLUETOOTH_SCAN) doesn't: an app holding
                          // SCAN without CONNECT would throw here, on the main
                          // thread, for every device found. Report it unbonded
                          // (unknown) instead, as btSafeName falls back to the
                          // address.
                          val bonded = try {
                              device.bondState == BluetoothDevice.BOND_BONDED
                          } catch (_: SecurityException) { false }
                          nativeDeliverBtDiscovered(deliveryPid,
                              device.address,
                              btSafeName(device),
                              bonded)
                      }
                  }
                  BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                      if (!started) return
                      nativeDeliverBtDiscoveryFinished(deliveryPid)
                      clearDiscovery(activity)
                  }
              }
          }
      }
      Log.d("MobBT", "step4: assigning receiver")
      btDiscoveryReceiver = receiver
      Log.d("MobBT", "step5: building filter")
      val filter = IntentFilter().apply {
          addAction(BluetoothDevice.ACTION_FOUND)
          addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
          addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
      }
      Log.d("MobBT", "step6: registering receiver, SDK=${Build.VERSION.SDK_INT}")
      try {
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(receiver, filter)
          }
          Log.d("MobBT", "step7: receiver registered OK")
      } catch (e: Exception) {
          Log.e("MobBT", "registerReceiver threw: ${e.javaClass.simpleName}: ${e.message}", e)
          clearDiscovery(activity)
          nativeDeliverBtError(pid, "register_failed")
          return
      }

      try {
          Log.d("MobBT", "step8: checking isDiscovering")
          if (adapter.isDiscovering) {
              Log.d("MobBT", "step9: already discovering, cancelling")
              adapter.cancelDiscovery()
          }
          Log.d("MobBT", "step10: calling adapter.startDiscovery()")
          val result = adapter.startDiscovery()
          Log.d("MobBT", "step11: startDiscovery returned $result")
          if (!result) {
              // MOB-319: the platform refuses discovery (false, no throw)
              // when it wants location access the app doesn't have.
              val reason = discoveryStartFailureReason(activity)
              Log.d("MobBT", "step12: startDiscovery refused: $reason")
              clearDiscovery(activity)
              nativeDeliverBtError(pid, reason)
              return
          }
          Log.d("MobBT", "step13: calling nativeDeliverBtDiscoveryStarted, pid=$pid")
          nativeDeliverBtDiscoveryStarted(pid)
          Log.d("MobBT", "step14: nativeDeliverBtDiscoveryStarted returned")
      } catch (e: SecurityException) {
          Log.e("MobBT", "SecurityException: ${e.message}", e)
          clearDiscovery(activity)
          nativeDeliverBtError(pid, "permission_denied")
      } catch (e: Exception) {
          Log.e("MobBT", "Unexpected exception: ${e.javaClass.simpleName}: ${e.message}", e)
          clearDiscovery(activity)
          nativeDeliverBtError(pid, "exception")
      }
  }

  // MOB-322: drop the discovery receiver and its pid. Every start_discovery
  // failure path runs this, so a later system discovery stop (createBond
  // cancels discovery) can't deliver a stray :discovery_finished to the pid
  // whose discovery never started.
  private fun clearDiscovery(ctx: Context?) {
      btDiscoveryPid = 0
      val receiver = btDiscoveryReceiver ?: return
      btDiscoveryReceiver = null
      try { ctx?.unregisterReceiver(receiver) } catch (_: Exception) {}
  }

  // MOB-319: name the reason startDiscovery() returned false. On API <= 30,
  // and on 31+ unless BLUETOOTH_SCAN disavows location, the platform demands
  // ACCESS_FINE_LOCATION (and, from API 29, location services switched on).
  private fun discoveryStartFailureReason(ctx: Context): String {
      val needsLocation =
          MobBluetoothPolicy.discoveryNeedsLocation(Build.VERSION.SDK_INT, scanDisavowsLocation())
      val fineGranted = try {
          ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
              PackageManager.PERMISSION_GRANTED
      } catch (_: Exception) {
          false
      }
      val locationEnabled = if (Build.VERSION.SDK_INT >= 29) {
          try {
              (ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.isLocationEnabled ?: true
          } catch (_: Exception) {
              true
          }
      } else {
          true
      }
      return MobBluetoothPolicy.discoveryStartFailureReason(needsLocation, fineGranted, locationEnabled)
  }

  @JvmStatic
  fun bt_cancel_discovery(pid: Long) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get()
      try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
      clearDiscovery(activity)
      nativeDeliverBtDiscoveryCancelled(pid)
  }

  // ── Discoverability (advertise) ─────────────────────────────────────────
  // Make the device discoverable to nearby Bluetooth devices for
  // `durationSeconds` (Android caps at 300). Fires ACTION_REQUEST_DISCOVERABLE,
  // which shows the system "make discoverable?" dialog and, on API 31+, REQUIRES
  // the BLUETOOTH_ADVERTISE runtime permission (a SecurityException otherwise).
  // Fire-and-forget: the system dialog is the user-facing result; we don't
  // capture accept/deny (that needs onActivityResult plumbing — a follow-up).
  // Only the existing error thunk is used, so no new delivery thunk is needed.
  @JvmStatic
  fun bt_make_discoverable(pid: Long, durationSeconds: Int) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get() ?: run { nativeDeliverBtError(pid, "no_activity"); return }
      if (!adapter.isEnabled) { nativeDeliverBtError(pid, "adapter_disabled"); return }
      // Launching the system discoverability dialog must happen on the UI thread;
      // the NIF invokes this from a BEAM thread.
      activity.runOnUiThread {
          try {
              val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                  putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, durationSeconds)
              }
              activity.startActivity(intent)
          } catch (e: SecurityException) {
              nativeDeliverBtError(pid, "permission_denied")
          } catch (e: Exception) {
              nativeDeliverBtError(pid, "discoverable_failed")
          }
      }
  }

  @JvmStatic
  fun bt_pair(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get() ?: run { nativeDeliverBtError(pid, "no_activity"); return }
      val parsed = try { JSONObject(json) } catch (_: Exception) { null }
      val mac = parsed?.optString("address")?.takeIf { it.isNotEmpty() }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      // MOB-61: when `:pin` is supplied, arm the ACTION_PAIRING_REQUEST
      // receiver so Android's PIN prompt is auto-answered with the supplied
      // string instead of showing the system dialog. Documented in
      // `MobBluetooth.pair/3` for years but never actually wired.
      val pin = parsed.optString("pin").takeIf { it.isNotEmpty() }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }

      if (btBondReceiver == null) {
          btBondReceiver = object : BroadcastReceiver() {
              override fun onReceive(ctx: Context, intent: Intent) {
                  if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                  val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                  else
                      @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                  if (dev == null) return
                  when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                      BluetoothDevice.BOND_BONDED -> {
                          val waiting = btBondWaiters.takeAll(dev.address)
                          btBondPins.remove(dev.address)
                          for (p in waiting) nativeDeliverBtPaired(p, dev.address, btSafeName(dev), true)
                      }
                      BluetoothDevice.BOND_NONE -> failBondWaiters(dev.address, "bond_none")
                  }
              }
          }
          val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(btBondReceiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(btBondReceiver, filter)
          }
      }

      // MOB-320: a pair() for a device whose bond this plugin already has in
      // flight JOINS it — its pid gets the same terminal :paired /
      // :pair_failed as the first caller's, and it neither calls createBond
      // again (which returns false mid-bond) nor touches the first caller's
      // PIN. Joining happens after the receiver is registered and before the
      // bond-state read, so a bond that lands in between still reaches us.
      if (!btBondWaiters.join(device.address, pid)) return

      // bondState needs BLUETOOTH_CONNECT on API 31+; an unguarded throw
      // here would be cleared by the NIF and leave the caller with no event.
      val bondState = try {
          device.bondState
      } catch (_: SecurityException) {
          failBondWaiters(device.address, "permission_denied")
          return
      }
      if (bondState == BluetoothDevice.BOND_BONDED) {
          for (p in btBondWaiters.takeAll(device.address)) {
              nativeDeliverBtPaired(p, device.address, btSafeName(device), true)
          }
          return
      }

      if (pin != null) {
          armPinPairingResponse(activity, device.address, pin)
      } else {
          // A previous pair attempt that never terminated could have left
          // an entry for this MAC in btBondPins. Clear it — otherwise a
          // pin-less pair for the same device would silently auto-answer
          // with the STALE pin (pre-merge review catch).
          btBondPins.remove(device.address)
      }

      // Already bonding (started from system Settings, another app, or a
      // bond whose waiters were dropped): the receiver delivers its outcome.
      if (bondState == BluetoothDevice.BOND_BONDING) return

      try {
          if (!device.createBond()) failBondWaiters(device.address, "create_bond_failed")
      } catch (e: SecurityException) {
          failBondWaiters(device.address, "permission_denied")
      }
  }

  // Terminal :pair_failed for every pair() caller waiting on [address].
  private fun failBondWaiters(address: String, reason: String) {
      val waiting = btBondWaiters.takeAll(address)
      btBondPins.remove(address)
      for (p in waiting) nativeDeliverBtPairFailed(p, address, reason)
  }

  // MOB-61: register the ACTION_PAIRING_REQUEST receiver (once, plugin
  // lifetime) and stash the PIN. When the receiver fires for our device
  // and Android asks for a PIN variant, it answers with `device.setPin`
  // and aborts the system broadcast so no dialog appears. For other
  // variants (passkey confirmation, out-of-band) we can't answer
  // programmatically — pass through to the system UI and let the user
  // confirm.
  //
  // Requires BLUETOOTH_ADMIN (pre-31) or BLUETOOTH_CONNECT (31+).
  // setPin returns false if either the permission was denied or the
  // remote device rejected the PIN; in either case the bond state
  // receiver will surface :pair_failed with "bond_none" as before.
  private fun armPinPairingResponse(activity: Activity, address: String, pin: String) {
      btBondPins[address] = pin
      if (btPairingRequestReceiver != null) return

      btPairingRequestReceiver = object : BroadcastReceiver() {
          override fun onReceive(ctx: Context, intent: Intent) {
              if (intent.action != BluetoothDevice.ACTION_PAIRING_REQUEST) return
              val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
                  intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
              } else {
                  @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
              }
              if (dev == null) return
              val storedPin = btBondPins[dev.address] ?: return
              val variant = intent.getIntExtra(
                  BluetoothDevice.EXTRA_PAIRING_VARIANT,
                  BluetoothDevice.ERROR,
              )
              if (variant != BluetoothDevice.PAIRING_VARIANT_PIN) return
              try {
                  val ok = dev.setPin(storedPin.toByteArray(Charsets.UTF_8))
                  if (ok) {
                      // Suppress the system PIN dialog for this pairing
                      // request; the bond-state receiver still fires for
                      // the eventual outcome. abortBroadcast() throws
                      // IllegalStateException if some OEM stack delivered
                      // the broadcast as non-ordered — catch below so a
                      // quirky handset can't take the scheduler thread
                      // down.
                      abortBroadcast()
                  } else {
                      Log.w(
                          "MobBluetooth",
                          "setPin returned false for ${dev.address} — falling through to system dialog",
                      )
                  }
              } catch (e: SecurityException) {
                  // Permission denied: fall through to the system dialog;
                  // the bond-state receiver still surfaces the outcome. A
                  // separate clause for lint (see bleGattServerCallback).
                  Log.w(
                      "MobBluetooth",
                      "PIN pairing auto-answer failed for ${dev.address}: ${e.javaClass.simpleName}",
                  )
              } catch (e: RuntimeException) {
                  // IllegalStateException = broadcast wasn't ordered on
                  // some OEM stack. Same fall-through to the
                  // system dialog — the bond-state receiver still
                  // surfaces the outcome. Kept narrower than Throwable so
                  // OOM / StackOverflow etc. still propagate.
                  Log.w(
                      "MobBluetooth",
                      "PIN pairing auto-answer failed for ${dev.address}: ${e.javaClass.simpleName}",
                  )
              }
          }
      }

      val filter = IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST).apply {
          // ACTION_PAIRING_REQUEST is an ordered broadcast — a higher-
          // priority receiver gets it before Android's built-in
          // system-UI receiver, and abortBroadcast() prevents that
          // receiver from ever running (thus no dialog).
          //
          // AOSP's Settings BluetoothPairingRequest receiver ships with
          // `android:priority="1"`, so any positive value beats it. There is
          // no runtime cap on manifestless (runtime-registered) filters, so
          // Int.MAX_VALUE just makes the ordering explicit.
          priority = Int.MAX_VALUE
      }
      if (Build.VERSION.SDK_INT >= 33) {
          activity.registerReceiver(btPairingRequestReceiver, filter, Context.RECEIVER_EXPORTED)
      } else {
          @Suppress("UnspecifiedRegisterReceiverFlag")
          activity.registerReceiver(btPairingRequestReceiver, filter)
      }
  }

  @JvmStatic
  fun bt_unpair(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val mac = try { JSONObject(json).optString("address").takeIf { it.isNotEmpty() } }
                catch (_: Exception) { null }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }
      try {
          val method = device.javaClass.getMethod("removeBond")
          val ok = method.invoke(device) as? Boolean ?: false
          if (ok) nativeDeliverBtUnpaired(pid, device.address)
          else    nativeDeliverBtError(pid, "remove_bond_failed")
      } catch (e: Exception) {
          // Reflection wraps the framework's SecurityException (missing
          // BLUETOOTH_CONNECT) in an InvocationTargetException.
          val denied = e is SecurityException || e.cause is SecurityException
          nativeDeliverBtError(pid, if (denied) "permission_denied" else "remove_bond_unavailable")
      }
  }

  // ── Generic disconnect by session ───────────────────────────────────────

  @JvmStatic
  fun bt_disconnect(pid: Long, session: Int) {
      // The session lookup and the SPP socket claim run under btSppLock, as
      // does the read thread's remote-close cleanup. Either this call takes
      // the socket (and sends the only :disconnected, "local"), or the read
      // thread has already taken it AND retired the session, so the lookup
      // below returns :no_session. Without the lock, a disconnect in the gap
      // would fall through to the synthetic "local" fallback after "remote".
      val device: BluetoothDevice
      val hadSpp: Boolean
      synchronized(btSppLock) {
          device = btSessionMap[session] ?: run {
              nativeDeliverBtError(pid, "no_session")
              return
          }
          // A session id is per-device, so the same session may have SPP AND
          // HFP connections open. We must disconnect each profile that IS
          // actually connected, and emit the correct :disconnected event for
          // each — MOB-63 before the fix only ever emitted the SPP shape.
          // SPP has no broadcast-receiver equivalent, so its event is
          // synchronous; the read thread, whose input.read throws once we
          // close, then finds the socket gone and emits nothing.
          val sock = btSppSockets.remove(session)
          hadSpp = sock != null
          if (sock != null) {
              btSppReadThreads.remove(session)?.interrupt()
              try { sock.close() } catch (_: Exception) {}
              nativeDeliverBtSppDisconnected(pid, session, "local")
          }
      }
      // connectedDevices() requires BLUETOOTH_CONNECT on API 31+; a
      // revoked/missing grant throws SecurityException. Treat that as
      // "no HFP connection to disconnect" so bt_disconnect still cleans
      // up the SPP side rather than crashing the whole call.
      val hadHfp = try {
          btHfpProxy?.connectedDevices?.any { it.address == device.address } == true
      } catch (_: SecurityException) {
          false
      }

      // HFP side: initiate the profile disconnect. The connection-state
      // broadcast receiver (registered by bt_hfp_connect) will pick up the
      // STATE_DISCONNECTED transition and emit :bt_hfp, :disconnected —
      // route it to THIS pid by updating the session-pid map first, and
      // mark the session as a local disconnect so the receiver picks
      // reason "local" instead of the "peer" default.
      var hfpFellBackSync = false
      if (hadHfp) {
          btHfpSessionPids[session] = pid
          btHfpLocalDisconnects.add(session)
          val proxy = btHfpProxy
          if (proxy != null) {
              try {
                  val method = proxy.javaClass.getMethod("disconnect", BluetoothDevice::class.java)
                  method.invoke(proxy, device)
              } catch (_: Exception) {
                  // Emit synchronously as a fallback — the receiver won't fire
                  // for a call that never reached the framework layer.
                  nativeDeliverBtHfpDisconnected(pid, session, "local")
                  btHfpLocalDisconnects.remove(session)
                  btHfpSessionPids.remove(session)
                  hfpFellBackSync = true
              }
          } else {
              nativeDeliverBtHfpDisconnected(pid, session, "local")
              btHfpLocalDisconnects.remove(session)
              btHfpSessionPids.remove(session)
              hfpFellBackSync = true
          }
      }

      // Neither profile was active. Emit an SPP-shaped :disconnected so old
      // callers still see a signal on `bt_disconnect(unknown_session)` — pre-
      // MOB-63 behaviour, kept to avoid a silent no-op.
      if (!hadSpp && !hadHfp) {
          nativeDeliverBtSppDisconnected(pid, session, "local")
      }

      btHfpVendorPids.remove(session)
      // Drop the session entirely when there's no HFP work still in flight
      // to close. `hadHfp` false means nothing to disconnect (SPP-only or
      // truly-dead session); `hfpFellBackSync` means the reflection blew
      // up before reaching the framework so no STATE_DISCONNECTED will
      // arrive to trigger the receiver's cleanup path. In both cases the
      // session id can retire immediately — otherwise leave the map
      // populated so the receiver's terminal :disconnected can still route.
      //
      // MOB-352: retire under btSppLock, like the read thread and the
      // reconnect re-pin, so this can't drop a session that a concurrent
      // bt_spp_connect to the same device just re-pinned with a live socket.
      synchronized(btSppLock) {
          if ((!hadHfp || hfpFellBackSync) && !btSppSockets.containsKey(session)) {
              btSessionMap.remove(session, device)
          }
      }
  }

  // ── HFP profile ────────────────────────────────────────────────────────

  private fun acquireHfpProxy(activity: Activity, onReady: (BluetoothHeadset?) -> Unit) {
      if (btHfpProxy != null) { onReady(btHfpProxy); return }
      val adapter = btAdapter() ?: run { onReady(null); return }
      val listener = object : BluetoothProfile.ServiceListener {
          override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
              if (profile == BluetoothProfile.HEADSET) {
                  btHfpProxy = proxy as? BluetoothHeadset
                  onReady(btHfpProxy)
              }
          }
          override fun onServiceDisconnected(profile: Int) {
              if (profile == BluetoothProfile.HEADSET) btHfpProxy = null
          }
      }
      adapter.getProfileProxy(activity, listener, BluetoothProfile.HEADSET)
  }

  // MOB-64: register a one-time receiver for HFP connection-state
  // transitions so `:bt_hfp, :connected` fires for a newly-initiated
  // connect (which the pre-MOB-64 code never emitted — only the
  // transient :connecting), and `:bt_hfp, :disconnected` fires for
  // remote hang-ups and local `bt_disconnect` calls (MOB-63). The
  // receiver runs for the lifetime of the plugin and routes each event
  // to the pid recorded in btHfpSessionPids for that session.
  private fun ensureHfpConnectionReceiver(activity: Activity) {
      if (btHfpConnectionReceiver != null) return
      btHfpConnectionReceiver = object : BroadcastReceiver() {
          override fun onReceive(ctx: Context, intent: Intent) {
              if (intent.action != BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED) return
              val device = if (Build.VERSION.SDK_INT >= 33) {
                  intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
              } else {
                  @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
              } ?: return
              val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)
              // ACTION_CONNECTION_STATE_CHANGED also fires for headsets
              // paired outside the plugin (system Settings → Bluetooth).
              // Don't allocate phantom sessions here — filter to devices
              // we KNOW about, so `btSessionMap` doesn't grow one entry
              // per system-initiated pair for the lifetime of the app.
              val known = btSessionMap.entries
                  .firstOrNull { it.value.address == device.address }
                  ?: return
              val session = known.key
              val pid = btHfpSessionPids[session] ?: return

              when (state) {
                  BluetoothProfile.STATE_CONNECTED ->
                      nativeDeliverBtHfpConnected(pid, session, device.address, btSafeName(device))

                  BluetoothProfile.STATE_DISCONNECTED -> {
                      val reason =
                          if (btHfpLocalDisconnects.remove(session)) "local" else "peer"
                      nativeDeliverBtHfpDisconnected(pid, session, reason)
                      btHfpSessionPids.remove(session)
                      // The disconnect closes the last active profile on the
                      // device. If there's no SPP socket left either, retire
                      // the session id — future connects allocate a fresh one.
                      // MOB-352: check-and-retire under btSppLock so a
                      // concurrent SPP (re)connect's socket + re-pin can't
                      // land between the check and the remove.
                      synchronized(btSppLock) {
                          if (!btSppSockets.containsKey(session)) btSessionMap.remove(session, known.value)
                      }
                  }
              }
          }
      }
      val filter = IntentFilter(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
      if (Build.VERSION.SDK_INT >= 33) {
          activity.registerReceiver(btHfpConnectionReceiver, filter, Context.RECEIVER_EXPORTED)
      } else {
          @Suppress("UnspecifiedRegisterReceiverFlag")
          activity.registerReceiver(btHfpConnectionReceiver, filter)
      }
  }

  @JvmStatic
  fun bt_hfp_connect(pid: Long, json: String) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtError(pid, "no_activity"); return }
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val mac = try { JSONObject(json).optString("address").takeIf { it.isNotEmpty() } }
                catch (_: Exception) { null }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }

      // Register the connection-state receiver ONCE, up-front — the callback
      // path below emits :bt_hfp, :connecting only, and the receiver is the
      // path that emits :bt_hfp, :connected once the framework finishes.
      ensureHfpConnectionReceiver(activity)

      acquireHfpProxy(activity) { proxy ->
          if (proxy == null) {
              nativeDeliverBtHfpConnectFailed(pid, mac, "hfp_proxy_unavailable")
              return@acquireHfpProxy
          }
          val session = btSessionFor(device)
          // Route future :connected / :disconnected events for this session
          // to the calling pid. bt_disconnect can override before firing its
          // own disconnect (MOB-63).
          btHfpSessionPids[session] = pid
          // connectedDevices needs BLUETOOTH_CONNECT on API 31+. This
          // callback can run on the main thread (onServiceConnected), where
          // an uncaught throw kills the app — guard and fail terminally.
          val connected = try {
              proxy.connectedDevices.any { it.address == device.address }
          } catch (_: SecurityException) {
              btHfpSessionPids.remove(session)
              nativeDeliverBtHfpConnectFailed(pid, device.address, "permission_denied")
              return@acquireHfpProxy
          }
          if (connected) {
              // Already connected before we asked — no state change is coming,
              // so emit the terminal :connected directly.
              nativeDeliverBtHfpConnected(pid, session, device.address, btSafeName(device))
          } else {
              try {
                  val method = proxy.javaClass.getMethod("connect", BluetoothDevice::class.java)
                  val ok = method.invoke(proxy, device) as? Boolean ?: false
                  if (ok) {
                      nativeDeliverBtHfpConnecting(pid, session, device.address)
                      // :connected follows when the receiver sees STATE_CONNECTED.
                  } else {
                      // Reflection said no. `MobBluetooth.hfp_connect/1` promises
                      // exactly one terminal event (`:connected` OR `:connect_failed`),
                      // so clear the pid mapping — a late async STATE_CONNECTED
                      // from a quirky Android HFP stack will still fire, but the
                      // receiver drops it without a pid to route to. That's the
                      // cost of keeping the docstring accurate; not observed in
                      // practice, and filed as a follow-up if it ever bites.
                      btHfpSessionPids.remove(session)
                      nativeDeliverBtHfpConnectFailed(pid, device.address, "hfp_connect_failed")
                  }
              } catch (e: Exception) {
                  // Reflection itself blew up — no framework work started,
                  // safe to drop the pid mapping.
                  btHfpSessionPids.remove(session)
                  val denied = e is SecurityException || e.cause is SecurityException
                  nativeDeliverBtHfpConnectFailed(pid, device.address,
                      if (denied) "permission_denied" else "hfp_connect_unavailable")
              }
          }
      }
  }

  @JvmStatic
  fun bt_hfp_subscribe_vendor_at(pid: Long, session: Int, companyIdsJson: String) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      btHfpVendorPids[session] = pid

      // Parse company_ids from JSON envelope {"company_ids":[int, int, ...]}.
      // Empty list is valid: the receiver registers, but no events route through.
      val companyIds: List<Int> = try {
          val obj = org.json.JSONObject(companyIdsJson)
          val arr = obj.getJSONArray("company_ids")
          (0 until arr.length()).map { arr.getInt(it) }
      } catch (e: Exception) {
          emptyList()
      }

      if (btHfpVendorReceiver == null) {
          btHfpVendorReceiver = object : BroadcastReceiver() {
              override fun onReceive(ctx: Context, intent: Intent) {
                  if (intent.action != BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT) return
                  val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                  else
                      @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                  val cmd = intent.getStringExtra(
                      BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD)
                  val cmdType = intent.getIntExtra(
                      BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD_TYPE, -1)
                  @Suppress("DEPRECATION") val args = intent.getSerializableExtra(
                      "android.bluetooth.headset.extra.VENDOR_SPECIFIC_HEADSET_EVENT_ARGS")
                  if (dev == null || cmd == null) return
                  val devSession = btSessionMap.entries.firstOrNull { it.value.address == dev.address }?.key
                      ?: return
                  val deliveryPid = btHfpVendorPids[devSession] ?: return
                  nativeDeliverBtHfpVendorAt(deliveryPid, devSession,
                      cmd, cmdType,
                      args?.toString() ?: "",
                      dev.address)
              }
          }
          val filter = IntentFilter(BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT).apply {
              // Register only the company IDs the caller asked for.
              // Android's ACTION_VENDOR_SPECIFIC_HEADSET_EVENT is only delivered
              // for explicitly-registered IDs — events from other vendors get dropped.
              for (companyId in companyIds) {
                  addCategory("android.bluetooth.headset.intent.category.companyid.$companyId")
              }
          }
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(btHfpVendorReceiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(btHfpVendorReceiver, filter)
          }
      }
      nativeDeliverBtHfpVendorSubscribed(pid, session)
  }

  @JvmStatic
  fun bt_hfp_send_vendor_at(pid: Long, session: Int, cmd: String, args: String) {
      nativeDeliverBtHfpError(pid, session, "not_supported_by_android_api")
  }

  @JvmStatic
  fun bt_hfp_start_sco(pid: Long, session: Int) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      val proxy = btHfpProxy ?: run { nativeDeliverBtHfpError(pid, session, "hfp_not_connected"); return }
      try {
          val method = proxy.javaClass.getMethod("startScoUsingVirtualVoiceCall", BluetoothDevice::class.java)
          val ok = method.invoke(proxy, device) as? Boolean ?: false
          if (ok) {
              val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
              am.mode = AudioManager.MODE_IN_COMMUNICATION
              nativeDeliverBtHfpScoStarted(pid, session, device.address)
          } else {
              nativeDeliverBtHfpError(pid, session, "sco_start_failed")
          }
      } catch (e: Exception) {
          nativeDeliverBtHfpError(pid, session, "sco_unavailable")
      }
  }

  @JvmStatic
  fun bt_hfp_stop_sco(pid: Long, session: Int) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      val proxy = btHfpProxy ?: run { nativeDeliverBtHfpError(pid, session, "hfp_not_connected"); return }
      try {
          val method = proxy.javaClass.getMethod("stopScoUsingVirtualVoiceCall", BluetoothDevice::class.java)
          method.invoke(proxy, device)
          val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
          am.mode = AudioManager.MODE_NORMAL
          nativeDeliverBtHfpScoStopped(pid, session)
      } catch (e: Exception) {
          nativeDeliverBtHfpError(pid, session, "sco_stop_failed")
      }
  }

  // ── SPP profile ────────────────────────────────────────────────────────

  @JvmStatic
  fun bt_spp_connect(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val opts = try { JSONObject(json) } catch (_: Exception) { JSONObject() }
      val mac = opts.optString("address").takeIf { it.isNotEmpty() }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }
      val uuidStr = opts.optString("uuid").takeIf { it.isNotEmpty() }
      val uuid = try { if (uuidStr != null) UUID.fromString(uuidStr) else SPP_UUID }
                 catch (_: Exception) { SPP_UUID }
      val secure = opts.optBoolean("secure", true)

      val session = btSessionFor(device)
      Thread {
          try {
              try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
              val socket = if (secure) device.createRfcommSocketToServiceRecord(uuid)
                           else device.createInsecureRfcommSocketToServiceRecord(uuid)
              socket.connect()
              synchronized(btSppLock) {
                  btSppSockets[session] = socket
                  // A remote close of an earlier connection to this device
                  // may have retired the session id in between; re-pin it.
                  btSessionMap[session] = device
              }
              nativeDeliverBtSppConnected(pid, session, device.address, btSafeName(device))

              val readThread = Thread {
                  val buf = ByteArray(1024)
                  try {
                      val input = socket.inputStream
                      while (!Thread.currentThread().isInterrupted) {
                          val n = input.read(buf)
                          if (n <= 0) break
                          val slice = buf.copyOfRange(0, n)
                          nativeDeliverBtSppData(pid, session, slice)
                      }
                  } catch (_: Exception) {}
                  // Only emit if bt_disconnect didn't already claim the
                  // socket (it emits "local" itself). Claim, retirement and
                  // event happen under btSppLock so a concurrent disconnect
                  // sees either the socket or no session, never the gap.
                  synchronized(btSppLock) {
                      if (btSppSockets.remove(session, socket)) {
                          btSppReadThreads.remove(session)
                          // Retire the session id unless HFP still uses it or
                          // a newer connection to the same device holds it, so
                          // a later disconnect(sid) gets :no_session.
                          if (!btHfpSessionPids.containsKey(session) && !btSppSockets.containsKey(session)) {
                              btSessionMap.remove(session, device)
                          }
                          nativeDeliverBtSppDisconnected(pid, session, "remote")
                      }
                  }
              }
              btSppReadThreads[session] = readThread
              readThread.start()
          } catch (e: SecurityException) {
              nativeDeliverBtSppConnectFailed(pid, mac, "permission_denied")
          } catch (e: Exception) {
              nativeDeliverBtSppConnectFailed(pid, mac, "spp_connect_failed")
          }
      }.start()
  }

  @JvmStatic
  fun bt_spp_write(pid: Long, session: Int, bytes: ByteArray) {
      val socket = btSppSockets[session] ?: run { nativeDeliverBtSppError(pid, session, "no_session"); return }
      Thread {
          try {
              socket.outputStream.write(bytes)
              socket.outputStream.flush()
              nativeDeliverBtSppWritten(pid, session, bytes.size)
          } catch (e: Exception) {
              nativeDeliverBtSppError(pid, session, "spp_write_failed")
          }
      }.start()
  }

  // ── BLE (Low Energy) GATT peripheral ─────────────────────────────────────
  //
  // Stand up a BluetoothGattServer hosting one service + its characteristics,
  // then advertise the service UUID + local name via BluetoothLeAdvertiser.
  // Central connections, CCCD subscribes, and incoming writes route back to the
  // owning pid through the nativeDeliverBle* thunks. All results are async —
  // these @JvmStatic entrypoints return :ok-equivalent (void) immediately and
  // never throw out (every risky call is wrapped, mirroring the bt_* methods).

  /// Resolve the BluetoothLeAdvertiser, or null with no side effect. Caller is
  /// responsible for delivering the appropriate failure reason.
  private fun bleAdvertiserOrNull(): BluetoothLeAdvertiser? {
      val adapter = btAdapter() ?: return null
      if (!adapter.isEnabled) return null
      return try { adapter.bluetoothLeAdvertiser } catch (_: SecurityException) { null }
  }

  /// Map a property string to its PROPERTY_* flag (0 if unrecognised).
  private fun blePropertyFlag(prop: String): Int = when (prop) {
      "read" -> BluetoothGattCharacteristic.PROPERTY_READ
      "write" -> BluetoothGattCharacteristic.PROPERTY_WRITE
      "write_without_response" -> BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
      "notify" -> BluetoothGattCharacteristic.PROPERTY_NOTIFY
      "indicate" -> BluetoothGattCharacteristic.PROPERTY_INDICATE
      else -> 0
  }

  /// Map a property string to its PERMISSION_* flag (0 if it grants no perm;
  /// notify/indicate are pushed by the server so need no characteristic perm).
  private fun blePermissionFlag(prop: String): Int = when (prop) {
      "read" -> BluetoothGattCharacteristic.PERMISSION_READ
      "write", "write_without_response" -> BluetoothGattCharacteristic.PERMISSION_WRITE
      else -> 0
  }

  /// Map an AdvertiseCallback failure code to a short snake_case reason atom.
  private fun bleAdvertiseFailureReason(errorCode: Int): String = when (errorCode) {
      AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "data_too_large"
      AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too_many_advertisers"
      AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "already_started"
      AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "internal_error"
      AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "feature_unsupported"
      else -> "advertise_failed_$errorCode"
  }

  /// The GATT-server callback: central connect/disconnect, CCCD subscribe, and
  /// characteristic writes. Always answers responseNeeded requests with
  /// GATT_SUCCESS so a central isn't left hanging.
  ///
  /// Lint's MissingPermission only accepts an explicit SecurityException catch,
  /// so the GATT calls here and in setPin/bleTeardown/restoreAdapterName list
  /// one before the broader catch. Don't merge them: lintRelease fails in the
  /// host.
  private fun bleGattServerCallback(pid: Long) = object : BluetoothGattServerCallback() {
      override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
          when (newState) {
              BluetoothProfile.STATE_CONNECTED -> {
                  val central = bleCentrals.getOrPut(device.address) {
                      bleCentralCounter.getAndIncrement()
                  }
                  bleDevices[device.address] = device
                  nativeDeliverBleCentralConnected(pid, central)
              }
              BluetoothProfile.STATE_DISCONNECTED -> {
                  val central = bleCentrals.remove(device.address)
                  bleDevices.remove(device.address)
                  if (central != null) nativeDeliverBleCentralDisconnected(pid, central)
              }
          }
      }

      override fun onDescriptorWriteRequest(
          device: BluetoothDevice,
          requestId: Int,
          descriptor: BluetoothGattDescriptor,
          preparedWrite: Boolean,
          responseNeeded: Boolean,
          offset: Int,
          value: ByteArray?
      ) {
          // Only the CCCD carries subscribe/unsubscribe intent.
          if (descriptor.uuid == CCCD_UUID && value != null) {
              val charUuid = descriptor.characteristic.uuid.toString().uppercase()
              when {
                  value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                      value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE) -> {
                      // Track the subscribed central as a notify target HERE, not
                      // only in onConnectionStateChange — that callback is
                      // unreliable for the server role on some devices, and a
                      // subscribed central is exactly who notify() should reach.
                      bleDevices[device.address] = device
                      bleCentrals.getOrPut(device.address) { bleCentralCounter.getAndIncrement() }
                      nativeDeliverBleSubscribed(pid, charUuid)
                  }
                  value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) ->
                      nativeDeliverBleUnsubscribed(pid, charUuid)
              }
          }
          if (responseNeeded) {
              try {
                  bleGattServer?.sendResponse(device, requestId, android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, value)
              } catch (_: SecurityException) {} catch (_: Exception) {}
          }
      }

      override fun onCharacteristicWriteRequest(
          device: BluetoothDevice,
          requestId: Int,
          characteristic: BluetoothGattCharacteristic,
          preparedWrite: Boolean,
          responseNeeded: Boolean,
          offset: Int,
          value: ByteArray?
      ) {
          val charUuid = characteristic.uuid.toString().uppercase()
          nativeDeliverBleWrite(pid, charUuid, value ?: ByteArray(0))
          if (responseNeeded) {
              try {
                  bleGattServer?.sendResponse(device, requestId, android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, value)
              } catch (_: SecurityException) {} catch (_: Exception) {}
          }
      }
  }

  @JvmStatic
  fun ble_start_advertising(pid: Long, json: String) {
      // Probe for the prerequisites up front so we can deliver a precise reason.
      // This runs on the calling (BEAM) thread, so adapter access — which can
      // throw SecurityException when the Bluetooth permission isn't granted —
      // MUST be guarded, or an uncaught throw kills the whole app process.
      // Failures go through failAdvertisingStart (MOB-360), never straight
      // to the BEAM, so an earlier start still in flight on main is retired.
      val ctx = activityRef?.get()
          ?: run { failAdvertisingStart(pid, "no_adapter"); return }
      val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
          ?: run { failAdvertisingStart(pid, "no_adapter"); return }

      val failure = try {
          val adapter = mgr.adapter
          when {
              adapter == null -> "no_adapter"
              !adapter.isEnabled -> "adapter_disabled"
              !ctx.packageManager.hasSystemFeature(
                  android.content.pm.PackageManager.FEATURE_BLUETOOTH_LE
              ) -> "ble_unsupported"
              else -> null
          }
      } catch (e: SecurityException) {
          "permission_denied"
      } catch (e: Exception) {
          "internal_error"
      }
      if (failure != null) { failAdvertisingStart(pid, failure); return }

      val spec = try { JSONObject(json) } catch (_: Exception) {
          failAdvertisingStart(pid, "bad_spec"); return
      }
      val localName = spec.optString("local_name").takeIf { it.isNotEmpty() }
      val serviceUuidStr = spec.optString("service_uuid").takeIf { it.isNotEmpty() }
          ?: run { failAdvertisingStart(pid, "no_service_uuid"); return }
      val serviceUuid = try { UUID.fromString(serviceUuidStr) } catch (_: Exception) {
          failAdvertisingStart(pid, "bad_service_uuid"); return
      }
      val lowLatency = spec.optBoolean("low_latency", false)

      // Build setup runs on the main thread (see `main` note above).
      main.post {
          try {
              // Re-resolve the adapter here (the prerequisite probe above caught
              // it in its own guarded scope). Safe under this try/catch.
              val adapter = mgr.adapter
                  ?: run { bleTeardown(); nativeDeliverBleAdvertisingFailed(pid, "no_adapter"); return@post }

              // Idempotent: tear down any prior server/advertiser before
              // re-arming. The adapter name stays as-is: a re-advertise keeps
              // the saved original (MOB-321) and renames/restores below, so
              // the original is never re-read while a rename is in flight.
              bleTeardown(restoreName = false)
              bleAdvertisingPid = pid

              val server = mgr.openGattServer(ctx, bleGattServerCallback(pid))
                  ?: run { nativeDeliverBleAdvertisingFailed(pid, "no_gatt_server"); bleTeardown(); return@post }
              bleGattServer = server

              val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
              val chars = spec.optJSONArray("characteristics") ?: JSONArray()
              for (i in 0 until chars.length()) {
                  val cSpec = chars.optJSONObject(i) ?: continue
                  val cUuidStr = cSpec.optString("uuid").takeIf { it.isNotEmpty() } ?: continue
                  val cUuid = try { UUID.fromString(cUuidStr) } catch (_: Exception) { continue }

                  val propsArr = cSpec.optJSONArray("properties") ?: JSONArray()
                  var properties = 0
                  var permissions = 0
                  var notifiable = false
                  for (j in 0 until propsArr.length()) {
                      val prop = propsArr.optString(j)
                      properties = properties or blePropertyFlag(prop)
                      permissions = permissions or blePermissionFlag(prop)
                      if (prop == "notify" || prop == "indicate") notifiable = true
                  }

                  val characteristic = BluetoothGattCharacteristic(cUuid, properties, permissions)
                  // Notify/indicate characteristics need the standard CCCD so a
                  // central can subscribe (read+write the config descriptor).
                  if (notifiable) {
                      val cccd = BluetoothGattDescriptor(
                          CCCD_UUID,
                          BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                      )
                      characteristic.addDescriptor(cccd)
                  }
                  service.addCharacteristic(characteristic)
                  bleCharacteristics[cUuid.toString().uppercase()] = characteristic
              }
              server.addService(service)

              val advertiser = adapter.bluetoothLeAdvertiser
                  ?: run { nativeDeliverBleAdvertisingFailed(pid, "no_advertiser"); bleTeardown(); return@post }
              bleAdvertiser = advertiser

              // Setting the GAP local name makes scanners show the friendly
              // name. It renames the ADAPTER, system-wide and persistently,
              // so (MOB-321) the adapter's own name is saved on the first
              // rename and put back by bleTeardown (stop_advertising and every
              // failure path) and onStartFailure. A spec without local_name
              // advertises under the adapter's own name.
              val setName = { n: String -> try { adapter.setName(n) } catch (_: Exception) { false } }
              val current = try { adapter.name } catch (_: Exception) { null }
              if (localName != null) ensureNameReceiver(ctx)
              val ready = bleNameGuard.prepareAdvert(current, localName, setName)
              // Something of ours is in flight only after a rename, so this
              // is normally registered already; re-arms it after an Activity
              // swap.
              if (!ready) ensureNameReceiver(ctx)

              val settings = AdvertiseSettings.Builder()
                  .setAdvertiseMode(
                      if (lowLatency) AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                      else AdvertiseSettings.ADVERTISE_MODE_BALANCED
                  )
                  .setConnectable(true)
                  .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                  .setTimeout(0)
                  .build()

              // A 128-bit service UUID is 16 bytes, which alone nearly fills the
              // 31-byte advertising packet — adding the device name too overflows
              // it (ADVERTISE_FAILED_DATA_TOO_LARGE). So advertise ONLY the
              // service UUID, and carry the friendly name in the separate 31-byte
              // scan-response packet. (The GAP name set above is what a connected
              // central ultimately reads anyway.)
              val advData = AdvertiseData.Builder()
                  .setIncludeDeviceName(false)
                  .addServiceUuid(ParcelUuid(serviceUuid))
                  .build()

              val scanResponse = AdvertiseData.Builder()
                  .setIncludeDeviceName(true)
                  .build()

              // MOB-360: the scan response packs the name the stack has when
              // startAdvertising runs, and setName is async — so while a
              // rename / restore of ours is in flight, the launch waits
              // (bleStartGate) until ACTION_LOCAL_NAME_CHANGED reports the
              // adapter settled, or ADVERT_NAME_TIMEOUT_MS passes. A start
              // superseded or stopped first delivers no event.
              val t = bleStartGate.begin(ready) { ticket ->
                  launchAdvertising(pid, ticket, advertiser, settings, advData, scanResponse)
              }
              if (bleStartGate.isWaiting(t)) {
                  val wanted = localName ?: "the adapter's own name"
                  main.postDelayed({
                      if (bleStartGate.isWaiting(t)) {
                          Log.w("MobBT", "MOB-360: adapter not settled on $wanted within " +
                              "${ADVERT_NAME_TIMEOUT_MS} ms; advertising anyway")
                          bleStartGate.timeout(t)
                      }
                  }, ADVERT_NAME_TIMEOUT_MS)
              }
          } catch (e: SecurityException) {
              nativeDeliverBleAdvertisingFailed(pid, "permission_denied")
              bleTeardown()
          } catch (e: Exception) {
              Log.e("MobBT", "ble_start_advertising failed: ${e.javaClass.simpleName}: ${e.message}", e)
              nativeDeliverBleAdvertisingFailed(pid, "internal_error")
              bleTeardown()
          }
      }
  }

  /// MOB-360: deadline for the adapter to settle on a start's name.
  private const val ADVERT_NAME_TIMEOUT_MS = 1500L

  /// MOB-360: a start that fails before its main-thread setup. The failure
  /// is delivered on main, after any earlier start's setup, and only once
  /// the teardown has retired every earlier start — so a superseded start
  /// can't launch or report after it — and the adapter name is put back.
  private fun failAdvertisingStart(pid: Long, reason: String) {
      main.post {
          try { bleTeardown() } catch (_: Exception) {}
          nativeDeliverBleAdvertisingFailed(pid, reason)
      }
  }

  /// Start advertising for start [ticket] (run on main, possibly after a
  /// deferral). Its outcome is delivered only while [ticket] is current.
  private fun launchAdvertising(
      pid: Long,
      ticket: Int,
      advertiser: BluetoothLeAdvertiser,
      settings: AdvertiseSettings,
      advData: AdvertiseData,
      scanResponse: AdvertiseData,
  ) {
      val callback = object : AdvertiseCallback() {
          override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
              if (bleStartGate.isCurrent(ticket)) nativeDeliverBleAdvertisingStarted(pid)
          }
          override fun onStartFailure(errorCode: Int) {
              if (!bleStartGate.isCurrent(ticket)) return
              // Nothing is advertising under local_name; give the adapter
              // its own name back.
              restoreAdapterName()
              nativeDeliverBleAdvertisingFailed(pid, bleAdvertiseFailureReason(errorCode))
          }
      }
      try {
          bleAdvertiseCallback = callback
          advertiser.startAdvertising(settings, advData, scanResponse, callback)
      } catch (e: SecurityException) {
          nativeDeliverBleAdvertisingFailed(pid, "permission_denied")
          bleTeardown()
      } catch (e: Exception) {
          Log.e("MobBT", "startAdvertising failed: ${e.javaClass.simpleName}: ${e.message}", e)
          nativeDeliverBleAdvertisingFailed(pid, "internal_error")
          bleTeardown()
      }
  }

  @JvmStatic
  fun ble_stop_advertising(pid: Long) {
      // Idempotent: safe to call with nothing running.
      main.post {
          try { bleTeardown() } catch (_: Exception) {}
      }
  }

  /// Tear down advertiser + GATT server + central state, and (unless a
  /// restart passes restoreName = false) give the adapter its own name back.
  /// Must tolerate being called when nothing is up (idempotent). Run on
  /// `main` by callers. (The SecurityException catches: see
  /// bleGattServerCallback.)
  private fun bleTeardown(restoreName: Boolean = true) {
      bleStartGate.cancel()
      val advertiser = bleAdvertiser
      val callback = bleAdvertiseCallback
      if (advertiser != null && callback != null) {
          try { advertiser.stopAdvertising(callback) } catch (_: SecurityException) {} catch (_: Exception) {}
      }
      bleAdvertiseCallback = null
      bleAdvertiser = null

      bleGattServer?.let { server ->
          // Disconnect any connected centrals, then close.
          for (device in bleDevices.values) {
              try { server.cancelConnection(device) } catch (_: SecurityException) {} catch (_: Exception) {}
          }
          try { server.close() } catch (_: SecurityException) {} catch (_: Exception) {}
      }
      bleGattServer = null
      bleCharacteristics.clear()
      bleCentrals.clear()
      bleDevices.clear()
      bleAdvertisingPid = 0
      if (restoreName) restoreAdapterName()
  }

  /// MOB-321: put back the adapter name start_advertising(local_name:)
  /// replaced. No-op when nothing was renamed; if the adapter is unreachable
  /// or the rename is refused, the saved name is kept for the next attempt.
  /// (The SecurityException catch: see bleGattServerCallback.)
  private fun restoreAdapterName() {
      val adapter = btAdapter() ?: return
      bleNameGuard.restore { n ->
          try { adapter.setName(n) } catch (_: SecurityException) { false } catch (_: Exception) { false }
      }
  }

  /// MOB-321: register (once per Activity) the receiver that reports the
  /// adapter's actual name changes to bleNameGuard, and (MOB-360) releases
  /// a held start once the guard has settled. Best-effort: without it the
  /// saved name is kept (a later broadcast lands everything before it) and a
  /// held start launches at its timeout.
  private fun ensureNameReceiver(ctx: Context) {
      if (bleNameReceiver != null) return
      val receiver = object : BroadcastReceiver() {
          override fun onReceive(c: Context, intent: Intent) {
              if (intent.action != BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED) return
              bleNameGuard.observe(intent.getStringExtra(BluetoothAdapter.EXTRA_LOCAL_NAME))
              if (bleNameGuard.settled) bleStartGate.release()
          }
      }
      val filter = IntentFilter(BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED)
      try {
          if (Build.VERSION.SDK_INT >= 33) {
              ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              ctx.registerReceiver(receiver, filter)
          }
          bleNameReceiver = receiver
      } catch (_: Exception) {}
  }

  @JvmStatic
  fun ble_notify(pid: Long, charUuid: String, bytes: ByteArray) {
      val server = bleGattServer ?: return
      val characteristic = bleCharacteristics[charUuid.uppercase()] ?: return
      if (bleDevices.isEmpty()) return
      val isIndicate =
          (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
      try {
          for (device in bleDevices.values) {
              if (Build.VERSION.SDK_INT >= 33) {
                  // Android 13+ takes the value explicitly (no shared mutable state).
                  server.notifyCharacteristicChanged(device, characteristic, isIndicate, bytes)
              } else {
                  @Suppress("DEPRECATION")
                  characteristic.value = bytes
                  @Suppress("DEPRECATION")
                  server.notifyCharacteristicChanged(device, characteristic, isIndicate)
              }
          }
      } catch (_: SecurityException) {
          // Missing BLUETOOTH_CONNECT — best-effort, drop silently.
      } catch (_: Exception) {
      }
  }
}

// ── Pure policy ──────────────────────────────────────────────────────────────
// Decisions the bridge makes from plain values. Kept free of Android framework
// calls so test/kotlin/ can run them on a desktop JVM (the bridge object itself
// can't load there: its initialiser touches Looper). Permission names are
// compile-time constants, inlined at build time.

internal object MobBluetoothPolicy {
  /// MOB-319: the runtime permissions Mob.Permissions.request(socket,
  /// :bluetooth_connect) asks for. API <= 30 has no Nearby-devices group
  /// (BLUETOOTH / BLUETOOTH_ADMIN are install-time) but classic discovery
  /// needs ACCESS_FINE_LOCATION. API 31+ needs SCAN + CONNECT + ADVERTISE,
  /// plus location unless the host's BLUETOOTH_SCAN declares
  /// neverForLocation; FINE goes with COARSE because Android 12+ ignores a
  /// FINE-only request.
  fun bluetoothConnectPermissions(sdkInt: Int, scanDisavowsLocation: Boolean): Array<String> {
      if (sdkInt <= 30) return arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
      val nearby = arrayOf(
          android.Manifest.permission.BLUETOOTH_CONNECT,
          android.Manifest.permission.BLUETOOTH_SCAN,
          android.Manifest.permission.BLUETOOTH_ADVERTISE,
      )
      return if (scanDisavowsLocation) {
          nearby
      } else {
          nearby + arrayOf(
              android.Manifest.permission.ACCESS_FINE_LOCATION,
              android.Manifest.permission.ACCESS_COARSE_LOCATION,
          )
      }
  }

  /// MOB-319: whether startDiscovery() needs location access on this device.
  fun discoveryNeedsLocation(sdkInt: Int, scanDisavowsLocation: Boolean): Boolean =
      sdkInt <= 30 || !scanDisavowsLocation

  /// MOB-319: the {:bt, :error, %{reason: _}} reason for a startDiscovery()
  /// that returned false.
  fun discoveryStartFailureReason(
      needsLocation: Boolean,
      fineLocationGranted: Boolean,
      locationEnabled: Boolean,
  ): String = when {
      needsLocation && !fineLocationGranted -> "location_permission_required"
      needsLocation && !locationEnabled -> "location_disabled"
      else -> "start_failed"
  }
}

/// MOB-320: pair() callers waiting on each device's bond, in call order.
/// The first waiter for an address starts the bond; later ones join it and
/// receive the same terminal event. Thread-safe (BEAM threads add, the
/// bond-state receiver takes on main).
internal class BondWaiters {
  private val waiters = HashMap<String, MutableList<Long>>()

  /// Record [pid] as waiting on [address]'s bond. True when it is the first
  /// waiter, i.e. no pair() for that address is already in flight.
  @Synchronized
  fun join(address: String, pid: Long): Boolean {
      val list = waiters.getOrPut(address) { mutableListOf() }
      list.add(pid)
      return list.size == 1
  }

  /// Remove and return every pid waiting on [address] (empty if none).
  @Synchronized
  fun takeAll(address: String): List<Long> = waiters.remove(address) ?: emptyList()

  /// Remove and return every (address, pid) waiter, in call order per address.
  @Synchronized
  fun drainAll(): List<Pair<String, Long>> {
      val all = waiters.flatMap { (address, pids) -> pids.map { address to it } }
      waiters.clear()
      return all
  }
}

/// MOB-321: remembers the adapter's own name while LE advertising has renamed
/// it, so stop / failure can put it back. [setName] is BluetoothAdapter.setName,
/// which is asynchronous: getName() keeps reporting earlier names for a while.
///
/// MOB-360: so every accepted setName is tracked as in flight until
/// ACTION_LOCAL_NAME_CHANGED reports it ([observe]). The stack applies them
/// in order, so a broadcast also lands every earlier request (covering a
/// missed broadcast), and a stale broadcast only lands the oldest request
/// with that name. getName() is believed only when nothing is in flight
/// ([settled]); while something is, the adapter will end on the last name
/// requested. The saved name is forgotten only once the adapter is settled
/// back on it — never on a read, or a quick restart could read one of our
/// own pending renames back and save it as the original. Main-thread only.
internal class AdapterNameGuard {
  private var original: String? = null
  // Names handed to setName and not yet reported back, oldest first. Every
  // one changes the name (a request matching the name already headed for is
  // skipped), so each produces a broadcast.
  private val inFlight = ArrayDeque<String>()

  /// No setName of ours is on its way: the adapter carries the last name we
  /// asked for, and getName() can be believed.
  val settled: Boolean get() = inFlight.isEmpty()

  /// ACTION_LOCAL_NAME_CHANGED reported [name].
  fun observe(name: String?) {
      val landed = if (name == null) -1 else inFlight.indexOf(name)
      if (landed < 0) return
      repeat(landed + 1) { inFlight.removeFirst() }
      if (inFlight.isEmpty() && name == original) original = null
  }

  /// Rename the adapter to [wanted]. [current] is the adapter's name as read
  /// now (null if unreadable), used only while [settled]. The first rename
  /// saves the adapter's own name; while it is saved it is kept. Without a
  /// name to restore, the adapter is left alone. Returns whether the adapter
  /// carries, or is headed for, [wanted].
  fun rename(current: String?, wanted: String, setName: (String) -> Boolean): Boolean {
      val own = original
      if (own == null) {
          // Nothing of ours renamed: settled, so [current] is the own name.
          val name = current ?: return false
          if (name == wanted) return true
          if (!request(wanted, setName)) return false
          original = name
          return true
      }
      if ((inFlight.lastOrNull() ?: current) == wanted) return true
      return request(wanted, setName)
  }

  /// Put the saved name back. No-op when nothing is renamed or a restore is
  /// already on its way; a refused rename keeps the saved name for the next
  /// attempt.
  fun restore(setName: (String) -> Boolean) {
      val own = original ?: return
      if (inFlight.lastOrNull() == own) return
      request(own, setName)
  }

  /// MOB-360: put the adapter on the name an advertising start needs —
  /// [wanted], or (null) the adapter's own name — given [current], the name
  /// read now. Returns whether the start may launch now: nothing of ours is
  /// in flight, so the adapter already carries that name.
  fun prepareAdvert(current: String?, wanted: String?, setName: (String) -> Boolean): Boolean {
      if (wanted != null) rename(current, wanted, setName) else restore(setName)
      return settled
  }

  private fun request(name: String, setName: (String) -> Boolean): Boolean {
      if (!setName(name)) return false
      inFlight.addLast(name)
      return true
  }
}

/// MOB-360: holds startAdvertising back until the adapter settles on the
/// name the start asked for (see [AdapterNameGuard.prepareAdvert]). The
/// scan response packs whatever name the stack has when advertising starts,
/// so starting straight after the async rename advertised the PREVIOUS name
/// on API 30 — and an over-long name failed with data_too_large one start
/// late.
///
/// Each start gets a ticket. A held start launches on [release] (the guard
/// settled) or at its deadline ([timeout]). A newer start or [cancel] (stop,
/// or the teardown before a newer start or after a failed one) drops a held
/// start and makes every earlier ticket stale: the bridge delivers no event
/// for a stale ticket, because events carry no start identity and a late one
/// would be read as the newer start's outcome. Main-thread only.
internal class AdvertStartGate {
  private var ticket = 0
  private var launch: ((Int) -> Unit)? = null

  /// A start_advertising: supersedes earlier starts and returns this
  /// start's ticket. Runs [launch] now when [ready], else holds it.
  fun begin(ready: Boolean, launch: (Int) -> Unit): Int {
    val t = ++ticket
    this.launch = null
    if (ready) launch(t) else this.launch = launch
    return t
  }

  /// The adapter's name settled: launch the held start, if any.
  fun release() {
    val l = launch ?: return
    launch = null
    l(ticket)
  }

  /// Start [t]'s deadline passed: launch it anyway. True when it was still
  /// held.
  fun timeout(t: Int): Boolean {
    if (!isWaiting(t)) return false
    release()
    return true
  }

  fun isWaiting(t: Int): Boolean = t == ticket && launch != null

  /// Whether start [t]'s outcome may still be delivered.
  fun isCurrent(t: Int): Boolean = t == ticket

  /// stop_advertising / teardown: drop a held start; outcomes of earlier
  /// starts become stale.
  fun cancel() {
    ticket++
    launch = null
  }
}
