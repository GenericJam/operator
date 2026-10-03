// mob_photos plugin — Android bridge (system Photo Picker).
//
// Extracted from mob-core's MobBridge photos_pick / handlePhotosResult plus
// MainActivity's photosPickerLauncher. Lives in the plugin's own package;
// MobPluginBootstrap.registerAll() calls register() at startup and hands it
// the Activity (MobActivityAware). It is NOT a MobPermissionProvider — the
// Photo Picker runs out of process, so no runtime permission dialog exists.
//
// The native thunks (nativeRegister + the two deliver hooks) are exported
// directly from the sibling zig NIF mob_photos_nif.zig.
//
// DESIGN NOTE vs core: core pre-registered the launcher in MainActivity's
// onCreate via registerForActivityResult (MainActivity.kt.eex:42-53), but
// that convenience API must run before the host reaches STARTED — a
// late-bound plugin can't meet that. mob's MainActivity is a
// ComponentActivity (Compose host), not a FragmentActivity, so a headless
// Fragment can't attach either. Instead this bridge registers directly on
// the ComponentActivity's ActivityResultRegistry (register(key, contract,
// callback) is callable any time) and unregisters in the callback —
// self-contained, no host MainActivity changes. (Same pattern as
// mob_camera's MobCameraBridge.)
//
// CONTRACT GOTCHA: PickMultipleVisualMedia(maxItems) throws when
// maxItems < 2, so max == 1 uses the single-item PickVisualMedia() contract
// instead — both feed the same handlePhotosResult. Core sidestepped this by
// ignoring max entirely (its pre-registered launcher always used the
// default multi-pick); honoring max here is a deliberate fidelity
// improvement over core, message shapes unchanged.
package io.mob.photos

import android.app.Activity
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong

object MobPhotosBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:photos, :cancelled}
    @JvmStatic external fun nativeDeliverPhotosCancelled(pid: Long)

    // {:mob_file_result, "photos", "picked", json} — decoded by core
    // Mob.Screen into {:photos, :picked, items} (lib/mob/screen.ex:343-391)
    @JvmStatic external fun nativeDeliverPhotosPicked(
        pid: Long,
        json: String,
    )

    // {:media, :listed, items} — json is a JSON array of metadata maps
    // (string keys), decoded by the zig NIF into a list of Elixir maps.
    @JvmStatic external fun nativeDeliverMediaListed(
        pid: Long,
        json: String,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // The :media capability maps to READ_MEDIA_IMAGES + READ_MEDIA_VIDEO on
    // API 33+ (READ_EXTERNAL_STORAGE on older). core's MobBridge.request_permission
    // falls through to MobPluginBootstrap.permissionsFor(cap) for caps it doesn't
    // know, which walks the registered providers — this is how :media is granted.
    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == "media") {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                arrayOf(
                    android.Manifest.permission.READ_MEDIA_IMAGES,
                    android.Manifest.permission.READ_MEDIA_VIDEO,
                )
            } else {
                arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        } else {
            null
        }

    private val pickSeq = AtomicLong(0L)

    // ── Pick (photos / videos) ────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V —
    // core passed max as a decimal string (mob_nif.zig:2553-2566).
    @JvmStatic
    fun photos_pick(
        pid: Long,
        maxStr: String,
    ) {
        val max = maxStr.toIntOrNull() ?: 1
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        val owner =
            activity as? ActivityResultRegistryOwner ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
        val key = "mob_photos_${pickSeq.incrementAndGet()}"
        if (max >= 2) {
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher =
                owner.activityResultRegistry.register(
                    key,
                    ActivityResultContracts.PickMultipleVisualMedia(max),
                ) { uris: List<Uri> ->
                    handlePhotosResult(pid, uris)
                    launcher?.unregister()
                }
            launcher.launch(request)
        } else {
            // PickMultipleVisualMedia(maxItems) requires maxItems >= 2 — for a
            // single item use the dedicated single-pick contract.
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher =
                owner.activityResultRegistry.register(
                    key,
                    ActivityResultContracts.PickVisualMedia(),
                ) { uri: Uri? ->
                    handlePhotosResult(pid, listOfNotNull(uri))
                    launcher?.unregister()
                }
            launcher.launch(request)
        }
    }

    // Result processing copied from core MobBridge.handlePhotosResult
    // (MobBridge.kt.eex:722-741): copy each content URI into a cacheDir tmp
    // file on a background thread, then deliver the JSON item array. The
    // JSON shape ({"path","type","width":0,"height":0}, type as a string,
    // dimensions not probed) is core parity — Mob.Screen atomizes only the
    // keys, so Android items reach user code with string type values.
    internal fun handlePhotosResult(
        pid: Long,
        uris: List<Uri>,
    ) {
        if (uris.isEmpty()) {
            nativeDeliverPhotosCancelled(pid)
            return
        }
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        Thread {
            try {
                val items =
                    uris.mapIndexed { i, uri ->
                        val ext = if (uri.toString().contains("video")) "mp4" else "jpg"
                        val tmp = File(activity.cacheDir, "mob_pick_${System.currentTimeMillis()}_$i.$ext")
                        activity.contentResolver.openInputStream(uri)?.use { it.copyTo(tmp.outputStream()) }
                        val type = if (ext == "mp4") "video" else "image"
                        """{"path":"${tmp.absolutePath}","type":"$type","width":0,"height":0}"""
                    }
                val json = "[${items.joinToString(",")}]"
                nativeDeliverPhotosPicked(pid, json)
            } catch (e: Exception) {
                nativeDeliverPhotosCancelled(pid)
            }
        }.start()
    }

    // ── Library enumeration (MediaStore) ───────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V — the
    // opts JSON carries {"type":"image"|"video"|"all","limit":N}. Queries the
    // MediaStore via ContentResolver on a background thread (the NIF callback
    // arrives on a BEAM scheduler thread), builds a JSON array of metadata, and
    // delivers it as {:media, :listed, items}. Requires READ_MEDIA_* — without
    // it the cursor is empty and an empty list is delivered (not an error). This
    // lists metadata only; it does NOT copy bytes (unlike the picker).
    @JvmStatic
    fun media_list(
        pid: Long,
        optsJson: String,
    ) {
        val type =
            try {
                JSONObject(optsJson).optString("type", "all")
            } catch (_: Exception) {
                "all"
            }
        val limit =
            try {
                JSONObject(optsJson).optInt("limit", 200)
            } catch (_: Exception) {
                200
            }
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverMediaListed(pid, "[]")
                return
            }
        Thread {
            val out = JSONArray()
            try {
                if (type == "image" || type == "all") {
                    queryInto(activity, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image", limit, out)
                }
                if (type == "video" || type == "all") {
                    queryInto(activity, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video", limit, out)
                }
            } catch (e: Exception) {
                // A SecurityException (permission not granted) or any query
                // failure yields whatever was gathered so far (often empty).
            }
            nativeDeliverMediaListed(pid, out.toString())
        }.start()
    }

    // DISPLAY_NAME / SIZE / DATE_ADDED / MIME_TYPE are shared column names
    // across MediaStore.Images and MediaStore.Video (MediaColumns), so one
    // projection serves both. date_added is already unix seconds.
    private fun queryInto(
        activity: Activity,
        collection: Uri,
        kind: String,
        limit: Int,
        out: JSONArray,
    ) {
        val projection =
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.MIME_TYPE,
            )
        val order = "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        activity.contentResolver.query(collection, projection, null, null, order)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val dateCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val mimeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            while (c.moveToNext()) {
                if (limit > 0 && out.length() >= limit) break
                val id = c.getLong(idCol)
                val uri = Uri.withAppendedPath(collection, id.toString())
                val o = JSONObject()
                o.put("uri", uri.toString())
                o.put("display_name", c.getString(nameCol) ?: "")
                o.put("size", c.getLong(sizeCol))
                o.put("date_added", c.getLong(dateCol))
                o.put("mime_type", c.getString(mimeCol) ?: "")
                o.put("type", kind)
                out.put(o)
            }
        }
    }
}
