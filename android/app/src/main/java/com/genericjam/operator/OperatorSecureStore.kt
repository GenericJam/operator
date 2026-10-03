package com.genericjam.operator

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Kotlin bridge for Operator.Nifs.OperatorSecureStore (Android side
 * of the same NIF that talks Keychain on iOS via
 * c_src/operator_secure_store.c). Ported from muster_app's
 * MusterSecureStore.kt; holds the OpenRouter key (Operator.KeyStore).
 *
 * Wraps AndroidX Jetpack Security's EncryptedSharedPreferences —
 * itself backed by a MasterKey stored in the Android Keystore
 * (hardware-backed on devices that expose a Strongbox/TEE). Both
 * keys and values are encrypted at rest; only the current app
 * can read them.
 *
 * The C NIF (Android branch of operator_secure_store.c) resolves
 * this class + method IDs at startup (from MainActivity.onCreate),
 * then calls `getBridge` / `putBridge` / `deleteBridge` per Elixir
 * request. init(Context) MUST be called before any bridge method —
 * see MainActivity.onCreate.
 *
 * Operator.KeyStore signs out with `deleteBridge`: it has no fallback
 * key, so "never written" and "signed out" mean the same thing.
 */
object OperatorSecureStore {
    private const val PREFS_NAME = "operator_secure_store"

    @Volatile
    private var prefs: SharedPreferences? = null

    /**
     * One-time bootstrap. Call from MainActivity.onCreate BEFORE
     * the BEAM starts (mob_start_beam), so the first Elixir call
     * into the NIF always finds prefs initialised AND the C NIF
     * has the bridge class + method IDs cached.
     *
     * Uses AES256_GCM for value encryption and AES256_SIV for
     * deterministic key hashing (so lookups by account name work
     * without leaking the account through key ordering).
     *
     * `nativeRegister` hands the C NIF a reference to this class
     * from the app class loader — FindClass called later from a
     * BEAM scheduler thread walks the SYSTEM class loader, which
     * doesn't see app classes, so lazy lookup from Elixir fails
     * with `bridge_init_failed`. Pre-registering here fixes it.
     */
    @JvmStatic
    fun init(context: Context) {
        if (prefs != null) return

        synchronized(this) {
            if (prefs != null) return

            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            prefs = EncryptedSharedPreferences.create(
                context.applicationContext,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

            // Register with the native side while the app class
            // loader is still on the stack.
            nativeRegister()
        }
    }

    @JvmStatic
    private external fun nativeRegister()

    /**
     * Get the value for `account`. Returns null when the key
     * doesn't exist (fresh install) — mirrors iOS's
     * errSecItemNotFound → {:ok, nil} coalescing in the NIF.
     */
    @JvmStatic
    fun getBridge(account: String): String? {
        return prefs?.getString(account, null)
    }

    /**
     * Set the value for `account`. Upsert semantics (matches
     * iOS's SecItemAdd + SecItemUpdate flow). `commit` (not
     * `apply`) so the C NIF's return means "durably written"
     * rather than "queued to disk."
     */
    @JvmStatic
    fun putBridge(account: String, value: String): Boolean {
        val p = prefs ?: return false
        return p.edit().putString(account, value).commit()
    }

    /**
     * Remove the entry for `account`. Idempotent — removing a
     * missing key is a no-op on SharedPreferences and returns
     * true, matching iOS's errSecItemNotFound → :ok on delete.
     */
    @JvmStatic
    fun deleteBridge(account: String): Boolean {
        val p = prefs ?: return false
        return p.edit().remove(account).commit()
    }
}
