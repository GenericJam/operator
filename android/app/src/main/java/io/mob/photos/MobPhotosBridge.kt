// mob_photos plugin — Android bridge (system Photo Picker, MediaStore
// enumeration, thumbnails).
//
// Extracted from mob-core's MobBridge photos_pick / handlePhotosResult plus
// MainActivity's photosPickerLauncher. Lives in the plugin's own package;
// MobPluginBootstrap.registerAll() calls register() at startup and hands it
// the Activity (MobActivityAware). It is also a MobPermissionProvider for the
// plugin-owned :media capability (enumeration + thumbnails of library items;
// the Photo Picker itself runs out of process and needs no permission).
//
// The native thunks (nativeRegister + the deliver hooks) are exported
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
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

object MobPhotosBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    @Volatile private var activityRef: WeakReference<Activity>? = null

    // Process-lifetime, so thumbnails of plain files keep working after the
    // Activity is destroyed while the BEAM lives on.
    @Volatile private var appContext: Context? = null

    // Thumbnail decodes run here, never on a BEAM scheduler thread. Two
    // workers bound the memory of concurrent full-size decodes.
    private val thumbnailPool = java.util.concurrent.Executors.newFixedThreadPool(2)

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

    // {:mob_photos_thumbnail, reply_json} to the receiver pid given to the
    // photo_thumbnail NIF; MobPhotos.thumbnail/2 waits for it.
    @JvmStatic external fun nativeDeliverThumbnail(
        pid: Long,
        reply: ByteArray,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
        appContext = activity.applicationContext
    }

    // The :media capability maps to READ_MEDIA_IMAGES + READ_MEDIA_VIDEO on
    // API 33+ (READ_EXTERNAL_STORAGE on older), plus ACCESS_MEDIA_LOCATION on
    // API 29+ so thumbnail() can read un-redacted EXIF GPS. That one shows no
    // dialog of its own: it rides the photos grant. core's
    // MobBridge.request_permission falls through to
    // MobPluginBootstrap.permissionsFor(cap) for caps it doesn't know, which
    // walks the registered providers — this is how :media is granted.
    override fun permissionsFor(cap: String): Array<String>? {
        if (cap != "media") return null
        val sdk = android.os.Build.VERSION.SDK_INT
        val read =
            if (sdk >= 33) {
                listOf(
                    android.Manifest.permission.READ_MEDIA_IMAGES,
                    android.Manifest.permission.READ_MEDIA_VIDEO,
                )
            } else {
                listOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        // Only when the host's merged manifest declares it: core grants a
        // capability only if every listed permission is granted, so an
        // undeclared (stripped) one would deny :media forever.
        val location =
            if (sdk >= 29 && declares(android.Manifest.permission.ACCESS_MEDIA_LOCATION)) {
                listOf(android.Manifest.permission.ACCESS_MEDIA_LOCATION)
            } else {
                emptyList()
            }
        return (read + location).toTypedArray()
    }

    private fun declares(permission: String): Boolean {
        val ctx = appContext ?: activityRef?.get() ?: return true
        return try {
            ctx.packageManager
                .getPackageInfo(ctx.packageName, android.content.pm.PackageManager.GET_PERMISSIONS)
                .requestedPermissions
                ?.contains(permission) == true
        } catch (e: Exception) {
            true
        }
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

    // Result processing from core MobBridge.handlePhotosResult
    // (MobBridge.kt.eex:722-741): copy each content URI into a cacheDir tmp
    // file on a background thread, then deliver the JSON item array. Item keys
    // {"path","type","width","height"} are core parity (type as a string —
    // Mob.Screen atomizes only the keys); "name"/"size" are additive. The
    // dimensions are read from the copy's header (upright, EXIF orientation
    // applied) and stay 0 for videos.
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
                val items = JSONArray()
                uris.forEachIndexed { i, uri -> items.put(pickedItem(activity, uri, i)) }
                nativeDeliverPhotosPicked(pid, items.toString())
            } catch (e: Exception) {
                nativeDeliverPhotosCancelled(pid)
            }
        }.start()
    }

    private fun pickedItem(
        activity: Activity,
        uri: Uri,
        index: Int,
    ): JSONObject {
        val resolver = activity.contentResolver
        // Picker URIs (content://media/picker/...) don't name the media kind,
        // so ask the provider; the old substring check is only a fallback.
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
        val isVideo = mime?.startsWith("video/") ?: uri.toString().contains("video")
        val ext = if (isVideo) "mp4" else "jpg"
        val tmp = File(activity.cacheDir, "mob_pick_${System.currentTimeMillis()}_$index.$ext")
        resolver.openInputStream(uri)?.use { input -> tmp.outputStream().use { input.copyTo(it) } }
        val name =
            runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0) else null
                }
            }.getOrNull()
        var width = 0
        var height = 0
        if (!isVideo) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(tmp.path, bounds)
            val orientation =
                runCatching {
                    ExifInterface(tmp.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
            val swap = orientation in 5..8
            width = maxOf(0, if (swap) bounds.outHeight else bounds.outWidth)
            height = maxOf(0, if (swap) bounds.outWidth else bounds.outHeight)
        }
        return JSONObject()
            .put("path", tmp.absolutePath)
            .put("type", if (isVideo) "video" else "image")
            .put("width", width)
            .put("height", height)
            .put("name", name ?: tmp.name)
            .put("size", tmp.length())
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
        val opts = runCatching { JSONObject(optsJson) }.getOrDefault(JSONObject())
        val type = opts.optString("type", "all")
        val limit = opts.optInt("limit", 200)
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverMediaListed(pid, "[]")
                return
            }
        Thread {
            val rows = ArrayList<Pair<Long, JSONObject>>()
            try {
                if (type == "image" || type == "all") {
                    queryInto(activity, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image", limit, rows)
                }
                if (type == "video" || type == "all") {
                    queryInto(activity, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video", limit, rows)
                }
            } catch (e: Exception) {
                // A SecurityException (permission not granted) or any query
                // failure yields whatever was gathered so far (often empty).
            }
            // Each collection is already newest-first; for "all" merge the two
            // so the limit keeps the newest of either kind.
            rows.sortByDescending { it.first }
            val out = JSONArray()
            for ((_, o) in if (limit > 0) rows.take(limit) else rows) out.put(o)
            nativeDeliverMediaListed(pid, out.toString())
        }.start()
    }

    // The columns are shared across MediaStore.Images and MediaStore.Video
    // (MediaColumns; "datetaken" is the same name in both ImageColumns and
    // VideoColumns), so one projection serves both. date_added is unix
    // seconds, date_taken unix ms. Unknown values (NULL / 0) are left out of
    // the item: core's JSON decoder would turn a JSON null into :null.
    // WIDTH/HEIGHT are the stored (pre-rotation) pixels; "orientation"
    // (images always, videos from API 29) makes them upright.
    private fun queryInto(
        activity: Activity,
        collection: Uri,
        kind: String,
        limit: Int,
        out: MutableList<Pair<Long, JSONObject>>,
    ) {
        val hasOrientation = kind == "image" || android.os.Build.VERSION.SDK_INT >= 29
        val projection =
            listOfNotNull(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.Images.ImageColumns.DATE_TAKEN,
                MediaStore.MediaColumns.WIDTH,
                MediaStore.MediaColumns.HEIGHT,
                if (hasOrientation) MediaStore.Images.ImageColumns.ORIENTATION else null,
            ).toTypedArray()
        val order = "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        activity.contentResolver.query(collection, projection, null, null, order)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val dateCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val mimeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val takenCol = c.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.DATE_TAKEN)
            val widthCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val heightCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val orientCol = if (hasOrientation) c.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.ORIENTATION) else -1
            var n = 0
            while (c.moveToNext()) {
                if (limit > 0 && n >= limit) break
                n++
                val id = c.getLong(idCol)
                val dateAdded = c.getLong(dateCol)
                val o = JSONObject()
                o.put("uri", Uri.withAppendedPath(collection, id.toString()).toString())
                o.put("display_name", c.getString(nameCol) ?: "")
                if (!c.isNull(sizeCol)) o.put("size", c.getLong(sizeCol))
                o.put("date_added", dateAdded)
                o.put("mime_type", c.getString(mimeCol) ?: "")
                if (!c.isNull(takenCol) && c.getLong(takenCol) > 0) o.put("date_taken", c.getLong(takenCol))
                val w = if (c.isNull(widthCol)) 0 else c.getInt(widthCol)
                val h = if (c.isNull(heightCol)) 0 else c.getInt(heightCol)
                if (w > 0 && h > 0) {
                    val deg = if (orientCol >= 0 && !c.isNull(orientCol)) c.getInt(orientCol) else 0
                    val swap = deg == 90 || deg == 270
                    o.put("width", if (swap) h else w)
                    o.put("height", if (swap) w else h)
                }
                o.put("type", kind)
                out.add(dateAdded to o)
            }
        }
    }

    // ── Thumbnail ──────────────────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (J[B)V — the receiver pid and
    // a UTF-8 JSON request
    // {"kind":"file"|"content"|"asset","source":…,"max_size":N,"quality":Q,
    // "timeout_ms":T}. A job still queued when its timeout has passed is
    // skipped (its caller has already given up), so abandoned requests don't
    // hold the two workers. A decode that has started runs to completion.
    // Returns at once: the decode runs on thumbnailPool (never a BEAM
    // scheduler thread) and the UTF-8 JSON reply goes back through
    // nativeDeliverThumbnail. Never throws — every failure becomes
    // {"error": …}, decoded by MobPhotos.decode_thumbnail_result/1.
    @JvmStatic
    fun photo_thumbnail(
        pid: Long,
        request: ByteArray,
    ) {
        try {
            val queuedAt = System.nanoTime()
            thumbnailPool.execute { nativeDeliverThumbnail(pid, thumbnailReply(request, queuedAt)) }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            nativeDeliverThumbnail(pid, errorReply("thumbnail worker unavailable"))
        }
    }

    private fun thumbnailReply(
        request: ByteArray,
        queuedAt: Long,
    ): ByteArray {
        val reply =
            try {
                val req = JSONObject(String(request, Charsets.UTF_8))
                val waitedMs = (System.nanoTime() - queuedAt) / 1_000_000
                if (waitedMs >= req.optLong("timeout_ms", 30_000L)) throw ThumbError("timeout")
                thumbnail(req)
            } catch (e: ThumbError) {
                JSONObject().put("error", e.code)
            } catch (e: FileNotFoundException) {
                JSONObject().put("error", if (isPermissionDenied(e)) "permission" else "not_found")
            } catch (e: SecurityException) {
                JSONObject().put("error", "permission")
            } catch (e: OutOfMemoryError) {
                JSONObject().put("error", "out of memory decoding the image")
            } catch (e: Throwable) {
                JSONObject().put("error", e.message ?: e.javaClass.simpleName)
            }
        return reply.toString().toByteArray(Charsets.UTF_8)
    }

    private fun errorReply(message: String): ByteArray =
        JSONObject().put("error", message).toString().toByteArray(Charsets.UTF_8)

    private class ThumbError(
        val code: String,
    ) : Exception(code)

    // Scoped storage reports an unreadable path as EACCES (or EPERM); a file
    // that isn't there is ENOENT. File.exists() can't tell them apart: it is
    // false for both.
    private fun isPermissionDenied(e: FileNotFoundException): Boolean {
        val msg = e.message ?: return false
        return msg.contains("EACCES") || msg.contains("EPERM") || msg.contains("Permission denied")
    }

    // Where the bytes come from: a plain file, or a content:// URI (for
    // MediaStore URIs, the un-redacted original when ACCESS_MEDIA_LOCATION is
    // held, so EXIF GPS survives).
    private interface ThumbSource {
        fun open(): InputStream

        fun size(): Long?

        fun mime(): String?

        fun dateTakenMs(): Long?
    }

    private class FileThumbSource(
        val file: File,
    ) : ThumbSource {
        override fun open(): InputStream = file.inputStream()

        override fun size(): Long? = file.length().takeIf { it > 0 }

        override fun mime(): String? = null

        override fun dateTakenMs(): Long? = null
    }

    private class ContentThumbSource(
        val ctx: Context,
        val uri: Uri,
    ) : ThumbSource {
        private val resolver = ctx.contentResolver
        private val isMediaStore = uri.authority == MediaStore.AUTHORITY

        override fun open(): InputStream {
            if (isMediaStore && android.os.Build.VERSION.SDK_INT >= 29 &&
                ctx.checkSelfPermission(android.Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED
            ) {
                // Picker URIs and some providers reject requireOriginal; fall
                // back to the (location-redacted) default stream.
                runCatching { resolver.openInputStream(MediaStore.setRequireOriginal(uri)) }
                    .getOrNull()
                    ?.let { return it }
            }
            return resolver.openInputStream(uri) ?: throw ThumbError("not_found")
        }

        override fun size(): Long? = queryLong(OpenableColumns.SIZE)?.takeIf { it > 0 }

        override fun mime(): String? = runCatching { resolver.getType(uri) }.getOrNull()

        override fun dateTakenMs(): Long? =
            if (isMediaStore) queryLong(MediaStore.Images.ImageColumns.DATE_TAKEN)?.takeIf { it > 0 } else null

        private fun queryLong(column: String): Long? =
            runCatching {
                resolver.query(uri, arrayOf(column), null, null, null)?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
                }
            }.getOrNull()
    }

    private fun thumbnail(req: JSONObject): JSONObject {
        val ctx = appContext ?: throw ThumbError("mob_photos bridge has no context yet")
        val kind = req.getString("kind")
        val sourceStr = req.getString("source")
        val maxSize = req.optInt("max_size", 1280).coerceAtLeast(1)
        val quality = req.optInt("quality", 80).coerceIn(1, 100)
        val source: ThumbSource =
            when (kind) {
                "file" -> FileThumbSource(File(sourceStr))
                "content" -> ContentThumbSource(ctx, Uri.parse(sourceStr))
                "asset" -> throw ThumbError("ph:// asset ids are iOS-only; on Android pass a content:// URI or a file path")
                else -> throw ThumbError("unknown source kind: $kind")
            }

        // 1. Header only: dimensions + decoded MIME. No size => not an image
        //    BitmapFactory can decode (videos included).
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        source.open().use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw ThumbError("unsupported")

        // 2. EXIF (orientation + metadata). Not every format carries EXIF.
        val exif = runCatching { source.open().use { ExifInterface(it) } }.getOrNull()
        val orientation =
            exif?.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                ?: ExifInterface.ORIENTATION_NORMAL

        // 3. Decode subsampled (power of two, never below max_size), then scale
        //    + orient in one matrix pass.
        var sample = 1
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        while (longest / (sample * 2) >= maxSize) sample *= 2
        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded =
            source.open().use { BitmapFactory.decodeStream(it, null, decodeOpts) }
                ?: throw ThumbError("unsupported")
        var thumb = decoded
        try {
            // Never upscale; never shrink the short side below 1 px (a
            // 10000x5 strip at max_size 100 would otherwise round to 0).
            val scale =
                minOf(1f, maxSize.toFloat() / maxOf(decoded.width, decoded.height))
                    .coerceAtLeast(1f / minOf(decoded.width, decoded.height))
            val matrix = Matrix().apply { postScale(scale, scale) }
            applyOrientation(matrix, orientation)
            thumb = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            if (thumb !== decoded) decoded.recycle()
            if (thumb.hasAlpha()) {
                // JPEG has no alpha: transparent pixels would turn black.
                val opaque = Bitmap.createBitmap(thumb.width, thumb.height, Bitmap.Config.ARGB_8888)
                Canvas(opaque).apply {
                    drawColor(Color.WHITE)
                    drawBitmap(thumb, 0f, 0f, null)
                }
                thumb.recycle()
                thumb = opaque
            }

            // 4. Write to the cache dir under a name derived from the request,
            //    so a repeat request overwrites instead of accumulating files.
            //    The temp file is unique per call, so concurrent requests for
            //    the same thumbnail can't truncate each other's output.
            val out = File(ctx.cacheDir, "mob_thumb_${digest("$kind\n$sourceStr\n$maxSize\n$quality")}.jpg")
            val tmp = File.createTempFile("mob_thumb_", ".tmp", ctx.cacheDir)
            try {
                val written = tmp.outputStream().use { thumb.compress(Bitmap.CompressFormat.JPEG, quality, it) }
                if (!written || !tmp.renameTo(out)) throw ThumbError("could not write ${out.path}")
            } finally {
                tmp.delete() // no-op after a successful rename
            }
            val reply =
                JSONObject()
                    .put("path", out.absolutePath)
                    .put("width", thumb.width)
                    .put("height", thumb.height)

            val swap = orientation in 5..8
            reply.put("orig_width", if (swap) bounds.outHeight else bounds.outWidth)
            reply.put("orig_height", if (swap) bounds.outWidth else bounds.outHeight)
            reply.putOpt("mime", bounds.outMimeType ?: source.mime())
            reply.putOpt("size", source.size())
            reply.putOpt("date_taken_ms", source.dateTakenMs())
            if (exif != null) putExif(reply, exif)
            return reply
        } finally {
            if (!decoded.isRecycled) decoded.recycle()
            if (!thumb.isRecycled) thumb.recycle()
        }
    }

    // EXIF orientation 1..8 -> the transform that makes the pixels upright.
    private fun applyOrientation(
        m: Matrix,
        orientation: Int,
    ) {
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.postRotate(90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.postRotate(-90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
        }
    }

    // Raw EXIF fields; MobPhotos.decode_thumbnail_result/1 builds taken_at
    // from exif_datetime + exif_offset (+ date_taken_ms) and treats a (0, 0)
    // fix as absent.
    private fun putExif(
        reply: JSONObject,
        exif: ExifInterface,
    ) {
        // Each time tag has its own offset tag; keep them paired. (Offset tags
        // are EXIF 2.31 — older platform ExifInterface versions don't read
        // them, and taken_at then falls back per the precedence above.)
        val original = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
        if (original != null) {
            reply.put("exif_datetime", original)
            reply.putOpt("exif_offset", exif.getAttribute("OffsetTimeOriginal"))
        } else {
            reply.putOpt("exif_datetime", exif.getAttribute(ExifInterface.TAG_DATETIME_DIGITIZED))
            reply.putOpt("exif_offset", exif.getAttribute("OffsetTimeDigitized"))
        }
        val lat = gpsDegrees(exif, ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, "S")
        val lon = gpsDegrees(exif, ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF, "W")
        if (lat != null && lon != null) {
            reply.put("latitude", lat)
            reply.put("longitude", lon)
            val alt = exif.getAltitude(Double.NaN)
            if (!alt.isNaN()) reply.put("altitude", alt)
        }
        reply.putOpt("make", exif.getAttribute(ExifInterface.TAG_MAKE))
        reply.putOpt("model", exif.getAttribute(ExifInterface.TAG_MODEL))
    }

    // The platform ExifInterface only exposes lat/long as floats (~1 m of
    // error); parse the "d/1,m/1,s/100" rationals at double precision.
    private fun gpsDegrees(
        exif: ExifInterface,
        tag: String,
        refTag: String,
        negativeRef: String,
    ): Double? {
        val parts = exif.getAttribute(tag)?.split(",") ?: return null
        if (parts.size != 3) return null
        val values =
            parts.map { part ->
                val (num, den) = part.trim().split("/").let { if (it.size == 2) it else return null }
                val d = den.toDoubleOrNull()?.takeIf { it != 0.0 } ?: return null
                (num.toDoubleOrNull() ?: return null) / d
            }
        val deg = values[0] + values[1] / 60.0 + values[2] / 3600.0
        return if (exif.getAttribute(refTag)?.trim() == negativeRef) -deg else deg
    }

    private fun digest(s: String): String =
        MessageDigest
            .getInstance("SHA-1")
            .digest(s.toByteArray(Charsets.UTF_8))
            .take(8)
            .joinToString("") { "%02x".format(it) }
}
