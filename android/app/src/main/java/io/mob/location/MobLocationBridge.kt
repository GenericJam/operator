// mob_location plugin — Android bridge (FusedLocationProviderClient).
//
// Extracted from mob-core's MobBridge: location_get_once/start/stop. Lives in
// the plugin's own package; mob_dev copies it into the app Kotlin sourceSet and
// MobPluginBootstrap.registerAll() calls register() at startup, hands it the
// Activity (MobActivityAware), and records it as a permission provider
// (MobPermissionProvider, supplying the :location -> ACCESS_FINE_LOCATION
// mapping so core's MobBridge.request_permission can route :location here).
//
// The native thunks (nativeRegister + the two nativeDeliver* delivery hooks)
// are exported directly from the sibling zig NIF mob_location_nif.zig.
package io.mob.location

import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

object MobLocationBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private var activityRef: java.lang.ref.WeakReference<Activity>? = null
    private var locationClient: FusedLocationProviderClient? = null
    private var locationCallback: LocationCallback? = null

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverLocation(
        pid: Long,
        lat: Double,
        lon: Double,
        acc: Double,
        alt: Double,
    )

    // code: 0 = permission_denied, else = unavailable
    @JvmStatic external fun nativeDeliverLocationError(pid: Long, code: Int)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = java.lang.ref.WeakReference(activity)
    }

    // Request BOTH fine and coarse — Android 12+ shows separate toggles for
    // "precise" vs "approximate" location, and a user who grants approximate
    // only should still be able to use the plugin (it still gets a location
    // via the Fused API, just at reduced accuracy). See MOB-75.
    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == "location") {
            arrayOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        } else {
            null
        }

    // Either FINE or COARSE is enough. Android 12+ can grant COARSE only;
    // Fused Location Provider still delivers positions at coarser accuracy.
    private fun hasLocationPermission(activity: Activity): Boolean {
        val fine =
            ContextCompat.checkSelfPermission(
                activity,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            )
        val coarse =
            ContextCompat.checkSelfPermission(
                activity,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        return fine == PackageManager.PERMISSION_GRANTED ||
            coarse == PackageManager.PERMISSION_GRANTED
    }

    @JvmStatic
    fun location_get_once(pid: Long, accuracy: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverLocationError(pid, 1); return
        }
        if (!hasLocationPermission(activity)) {
            nativeDeliverLocationError(pid, 0); return
        }
        val client = LocationServices.getFusedLocationProviderClient(activity)
        client.lastLocation.addOnSuccessListener { loc ->
            if (loc != null) {
                nativeDeliverLocation(pid, loc.latitude, loc.longitude, loc.accuracy.toDouble(), loc.altitude)
            } else {
                val req = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, 1000)
                    .setMaxUpdates(1).build()
                val cb = object : LocationCallback() {
                    override fun onLocationResult(result: LocationResult) {
                        result.lastLocation?.let { l ->
                            nativeDeliverLocation(pid, l.latitude, l.longitude, l.accuracy.toDouble(), l.altitude)
                        }
                        client.removeLocationUpdates(this)
                    }
                }
                client.requestLocationUpdates(req, cb, activity.mainLooper)
            }
        }
    }

    @JvmStatic
    fun location_start(pid: Long, accuracy: String) {
        val activity = activityRef?.get() ?: return
        if (!hasLocationPermission(activity)) {
            nativeDeliverLocationError(pid, 0); return
        }
        val priority = when (accuracy) {
            "high" -> Priority.PRIORITY_HIGH_ACCURACY
            "low" -> Priority.PRIORITY_LOW_POWER
            else -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
        }
        val client = LocationServices.getFusedLocationProviderClient(activity)
        // If location_start was called before without an intervening
        // location_stop (e.g. user switched accuracy, or the plugin was
        // re-activated mid-session), the previous callback keeps firing
        // AND the new one starts — doubled updates, doubled battery drain.
        // Symmetric with location_stop's remove/null. See MOB-76.
        locationCallback?.let { locationClient?.removeLocationUpdates(it) }
        locationClient = client
        val req = LocationRequest.Builder(priority, 5000).build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { l ->
                    nativeDeliverLocation(pid, l.latitude, l.longitude, l.accuracy.toDouble(), l.altitude)
                }
            }
        }
        locationCallback = cb
        client.requestLocationUpdates(req, cb, activity.mainLooper)
    }

    @JvmStatic
    fun location_stop() {
        locationCallback?.let { locationClient?.removeLocationUpdates(it) }
        locationCallback = null
    }
}
