// mob_scene3d plugin — Android bridge: NIF wire + Filament scene applier.
//
// Three layers, one file (the plugin manifest ships a single bridge_kt):
//
//  * MobScene3dBridge — JNI seam. The zig NIF (mob_scene3d_nif.zig) calls the
//    scene3d* statics from BEAM scheduler threads; async traffic flows back
//    through nativeDeliverScene3d (enif_send in the zig thunk).
//  * Scene3dRuntime — the shadow registry. Validates every patch atomically
//    (reject-all, the honest-error taxonomy from the scene-IR decision
//    record) against pure bookkeeping state, synchronously on the calling
//    thread — NO Filament here. Validated ops queue for the renderer; the
//    full shadow can bootstrap a (re)attached renderer at any time.
//  * Scene3dView — the Filament applier + surface/lifecycle shim.
//    SurfaceView + UiHelper + Choreographer; the Engine is created on the
//    main thread and every Filament call stays there (the spike's binding
//    threading contract). Ops apply between frames.
//
// Registration: the manifest's ui_components android.factory makes mob_dev
// generate MobPluginBootstrap's MobNativeViewRegistry.register(
// "Mob_Scene3d_Viewport") call to the two-argument MobScene3dViewport below.
package io.mob.scene3d

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Choreographer
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceView
import android.view.View.VISIBLE
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.android.filament.Camera
import com.google.android.filament.Engine
import com.google.android.filament.EntityManager
import com.google.android.filament.LightManager
import com.google.android.filament.MaterialInstance
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.Skybox
import com.google.android.filament.SwapChain
import com.google.android.filament.Texture
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.android.UiHelper
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.FilamentInstance
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import com.google.android.filament.utils.Utils
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

object MobScene3dBridge {
    @JvmStatic external fun nativeRegister()

    // kind = "scene" (a=requestId, b=sceneJson) | "error" (a=errorJson) | "ready"
    @JvmStatic external fun nativeDeliverScene3d(
        pid: Long,
        kind: String,
        viewportId: String,
        a: String,
        b: String,
    )

    @JvmStatic
    fun register() {
        Utils.init() // loads libfilament-jni / libgltfio-jni / libfilament-utils-jni
        nativeRegister()
    }

    // ── NIF entry points (BEAM scheduler threads — bookkeeping only) ──────

    @JvmStatic
    fun scene3dCaps(): ByteArray = Scene3dRuntime.capsJson().toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dApply(
        pid: Long,
        viewportId: ByteArray,
        patch: ByteArray,
    ): ByteArray =
        Scene3dRuntime
            .apply(pid, String(viewportId, Charsets.UTF_8), String(patch, Charsets.UTF_8))
            .toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dScene(
        pid: Long,
        viewportId: ByteArray,
        requestId: ByteArray,
    ): ByteArray =
        Scene3dRuntime
            .requestScene(pid, String(viewportId, Charsets.UTF_8), String(requestId, Charsets.UTF_8))
            .toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dDestroy(viewportId: ByteArray): ByteArray =
        Scene3dRuntime.destroy(String(viewportId, Charsets.UTF_8)).toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dPick(
        pid: Long,
        viewportId: ByteArray,
        query: ByteArray,
    ): ByteArray =
        Scene3dRuntime
            .enqueueQuery(pid, String(viewportId, Charsets.UTF_8), "pick", String(query, Charsets.UTF_8))
            .toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dSample(
        pid: Long,
        viewportId: ByteArray,
        query: ByteArray,
    ): ByteArray =
        Scene3dRuntime
            .enqueueQuery(pid, String(viewportId, Charsets.UTF_8), "sample", String(query, Charsets.UTF_8))
            .toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dFrameStats(
        pid: Long,
        viewportId: ByteArray,
        requestId: ByteArray,
    ): ByteArray =
        Scene3dRuntime
            .enqueueQuery(
                pid,
                String(viewportId, Charsets.UTF_8),
                "stats",
                JSONObject().put("request_id", String(requestId, Charsets.UTF_8)).toString(),
            ).toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun scene3dViewports(): ByteArray = Scene3dRuntime.viewportsJson().toByteArray(Charsets.UTF_8)
}

// ── Shadow registry + patch validation ─────────────────────────────────────

object Scene3dRuntime {
    private const val SCHEMA = 1

    private val SUPPORTED_OPS =
        listOf(
            "add_entity",
            "replace_entity",
            "remove_entity",
            "set_parent",
            "set_transform",
            "set_visible",
            "set_pickable",
            "set_material",
            "set_animation",
            "set_camera",
            "set_light",
            "set_environment",
        )

    // Additive grammar extensions riding existing ops (the Elixir side
    // refuses to encode them unless declared here — version-skew guard).
    private val SUPPORTED_FEATURES = listOf("material_scope")

    class ViewportState {
        // Insertion-ordered so bootstrap replay is parents-first for free
        // (diff order guarantees parents precede children on first add, and
        // replays re-add in commit order).
        val shadow = LinkedHashMap<String, JSONObject>()
        val pendingOps = ArrayList<JSONArray>()
        val sceneRequests = ArrayList<Pair<Long, String>>()
        val queries = ArrayList<Query>()
        var ownerPid: Long = 0
        var view: Scene3dView? = null
        var resetRequested = false
    }

    /** One introspection query (pick / sample / stats), drained render-side. */
    class Query(
        val kind: String,
        val pid: Long,
        val requestId: String,
        val params: JSONObject,
    )

    private val lock = Any()
    private val viewports = HashMap<String, ViewportState>()

    // Asset path -> clip names, registered by the render thread after a
    // gltfio load. Lets the BEAM-thread shadow validation reject an unknown
    // animation name SYNCHRONOUSLY once the asset is known; before that the
    // render thread re-checks and delivers an async scene error (the same
    // two-tier honesty bad_asset has).
    private val assetAnimations = HashMap<String, List<String>>()

    // Asset path -> glTF material names, same two-tier honesty: synchronous
    // unknown_material rejection once the asset is loaded, async render-side
    // error before that.
    private val assetMaterials = HashMap<String, List<String>>()

    fun registerAssetAnimations(
        assetRef: String,
        names: List<String>,
    ) {
        synchronized(lock) { assetAnimations[assetRef] = names }
    }

    /** Clip names of a loaded asset, or null while not (yet) loaded. */
    fun animationNames(assetRef: String?): List<String>? = synchronized(lock) { assetRef?.let { assetAnimations[it] } }

    fun registerAssetMaterials(
        assetRef: String,
        names: List<String>,
    ) {
        synchronized(lock) { assetMaterials[assetRef] = names }
    }

    /** glTF material names of a loaded asset, or null while not (yet) loaded. */
    fun materialNames(assetRef: String?): List<String>? = synchronized(lock) { assetRef?.let { assetMaterials[it] } }

    fun capsJson(): String {
        val ops = JSONArray()
        SUPPORTED_OPS.forEach { ops.put(it) }
        val features = JSONArray()
        SUPPORTED_FEATURES.forEach { features.put(it) }
        return JSONObject()
            .put("schema", SCHEMA)
            .put("ops", ops)
            .put("features", features)
            .toString()
    }

    fun apply(
        pid: Long,
        viewportId: String,
        patchJson: String,
    ): String {
        val envelope =
            try {
                JSONObject(patchJson)
            } catch (e: Exception) {
                return err("bad_patch", e.message ?: "parse")
            }
        if (envelope.optInt("schema", -1) != SCHEMA) return err("bad_patch", "schema")
        val ops = envelope.optJSONArray("ops") ?: return err("bad_patch", "ops")

        synchronized(lock) {
            val state = viewports.getOrPut(viewportId) { ViewportState() }
            state.ownerPid = pid
            // Dry-run the whole patch against a working copy: atomic
            // reject-all before anything is queued for Filament.
            val work = LinkedHashMap(state.shadow)
            for (i in 0 until ops.length()) {
                val op = ops.optJSONArray(i) ?: return err("bad_patch", "op $i")
                val failure = Scene3dShadow.applyOp(work, op)
                if (failure != null) return JSONObject().put("error", failure).toString()
            }
            val invalid = Scene3dShadow.validateResult(work)
            if (invalid != null) return JSONObject().put("error", invalid).toString()

            state.shadow.clear()
            state.shadow.putAll(work)
            for (i in 0 until ops.length()) state.pendingOps.add(ops.getJSONArray(i))
        }
        return OK
    }

    fun requestScene(
        pid: Long,
        viewportId: String,
        requestId: String,
    ): String {
        synchronized(lock) {
            val state = viewports[viewportId]
            if (state?.view == null) return err("no_viewport", viewportId)
            state.sceneRequests.add(pid to requestId)
        }
        return OK
    }

    /** Queue a pick/sample/stats query for the render thread. */
    fun enqueueQuery(
        pid: Long,
        viewportId: String,
        kind: String,
        queryJson: String,
    ): String {
        val params =
            try {
                JSONObject(queryJson)
            } catch (e: Exception) {
                return err("bad_query", e.message ?: "parse")
            }
        val requestId = params.optString("request_id")
        if (requestId.isEmpty()) return err("bad_query", "request_id")
        synchronized(lock) {
            val state = viewports[viewportId]
            if (state?.view == null) return err("no_viewport", viewportId)
            state.queries.add(Query(kind, pid, requestId, params))
        }
        return OK
    }

    fun viewportsJson(): String {
        val ids = JSONArray()
        synchronized(lock) {
            for ((id, state) in viewports) if (state.view != null) ids.put(id)
        }
        return JSONObject().put("viewports", ids).toString()
    }

    fun destroy(viewportId: String): String {
        synchronized(lock) {
            val state = viewports[viewportId] ?: return OK
            state.shadow.clear()
            state.pendingOps.clear()
            state.sceneRequests.clear()
            state.queries.clear()
            state.resetRequested = true
        }
        return OK
    }

    // ── renderer side (main thread) ────────────────────────────────────────

    /** Attach a renderer; returns bootstrap ops replaying the shadow. */
    fun attach(
        viewportId: String,
        view: Scene3dView,
    ): List<JSONArray> {
        synchronized(lock) {
            val state = viewports.getOrPut(viewportId) { ViewportState() }
            state.view = view
            state.resetRequested = false
            // The renderer starts empty: pending deltas are subsumed by the
            // shadow replay.
            state.pendingOps.clear()
            return state.shadow.values.map { entity ->
                JSONArray().put("add_entity").put(entity)
            }
        }
    }

    fun detach(
        viewportId: String,
        view: Scene3dView,
    ) {
        synchronized(lock) {
            val state = viewports[viewportId] ?: return
            if (state.view === view) state.view = null
        }
    }

    class Drained(
        val ops: List<JSONArray>,
        val sceneRequests: List<Pair<Long, String>>,
        val queries: List<Query>,
        val reset: Boolean,
        val ownerPid: Long,
    )

    fun drain(viewportId: String): Drained {
        synchronized(lock) {
            val state =
                viewports[viewportId]
                    ?: return Drained(emptyList(), emptyList(), emptyList(), false, 0)
            val ops = ArrayList(state.pendingOps)
            state.pendingOps.clear()
            val requests = ArrayList(state.sceneRequests)
            state.sceneRequests.clear()
            val queries = ArrayList(state.queries)
            state.queries.clear()
            val reset = state.resetRequested
            state.resetRequested = false
            return Drained(ops, requests, queries, reset, state.ownerPid)
        }
    }

    fun ownerPid(viewportId: String): Long = synchronized(lock) { viewports[viewportId]?.ownerPid ?: 0 }

    private const val OK = "{\"ok\":true}"

    private fun err(vararg args: String): String {
        val arr = JSONArray()
        args.forEach { arr.put(it) }
        return JSONObject().put("error", arr).toString()
    }
}

// Pure patch semantics against the shadow map — mirrors Mob.Scene3d.IR.Patch
// (the executable Elixir reference); the parity harness bead (zn8) checks
// cross-platform agreement.
object Scene3dShadow {
    /** Applies one op to `work`, returning an error JSONArray or null. */
    fun applyOp(
        work: LinkedHashMap<String, JSONObject>,
        op: JSONArray,
    ): JSONArray? {
        return when (val name = op.optString(0)) {
            "add_entity" -> {
                val entity = op.optJSONObject(1) ?: return err("bad_patch", "add_entity")
                val id = entity.optString("id")
                val parent = Scene3dShadow.parentOf(entity)
                when {
                    work.containsKey(id) -> {
                        err("duplicate_entity", id)
                    }

                    parent != null && !work.containsKey(parent) -> {
                        err("unknown_parent", id, parent)
                    }

                    else -> {
                        animationError(entity) ?: materialError(entity) ?: run {
                            work[id] = entity
                            null
                        }
                    }
                }
            }

            "replace_entity" -> {
                val entity = op.optJSONObject(1) ?: return err("bad_patch", "replace_entity")
                val id = entity.optString("id")
                val parent = Scene3dShadow.parentOf(entity)
                when {
                    !work.containsKey(id) -> {
                        err("unknown_entity", id)
                    }

                    parent != null && !work.containsKey(parent) -> {
                        err("unknown_parent", id, parent)
                    }

                    else -> {
                        animationError(entity) ?: materialError(entity) ?: run {
                            work[id] = entity
                            null
                        }
                    }
                }
            }

            "remove_entity" -> {
                val id = op.optString(1)
                when {
                    !work.containsKey(id) -> {
                        err("unknown_entity", id)
                    }

                    work.values.any { parentOf(it) == id } -> {
                        err("has_children", id)
                    }

                    else -> {
                        work.remove(id)
                        null
                    }
                }
            }

            "set_parent" -> {
                val id = op.optString(1)
                val parent = if (op.isNull(2)) null else op.optString(2)
                val entity = work[id] ?: return err("unknown_entity", id)
                if (parent != null && !work.containsKey(parent)) return err("unknown_parent", id, parent)
                val updated = clone(entity)
                if (parent == null) updated.put("parent", JSONObject.NULL) else updated.put("parent", parent)
                work[id] = updated
                if (cyclic(work, id)) err("invalid_result", "parent_cycle") else null
            }

            "set_transform" -> {
                setField(work, op, "transform")
            }

            "set_visible" -> {
                setField(work, op, "visible")
            }

            "set_pickable" -> {
                setField(work, op, "pickable")
            }

            "set_material" -> {
                setDataField(work, op, "model", "material")
                    ?: work[op.optString(1)]?.let { materialError(it) }
            }

            "set_animation" -> {
                setDataField(work, op, "model", "animation")
                    ?: work[op.optString(1)]?.let { animationError(it) }
            }

            "set_camera" -> {
                setData(work, op, "camera") { _, _ -> null }
            }

            "set_light" -> {
                setData(work, op, "light") { current, next ->
                    if (current.optString("type") != next.optString("type")) {
                        err("structural_field", op.optString(1), "light_type")
                    } else {
                        null
                    }
                }
            }

            "set_environment" -> {
                setData(work, op, "environment") { current, next ->
                    if (current.optString("ibl", "") != next.optString("ibl", "") ||
                        current.optString("skybox", "") != next.optString("skybox", "")
                    ) {
                        err("structural_field", op.optString(1), "environment_assets")
                    } else {
                        null
                    }
                }
            }

            else -> {
                err("unknown_op", name)
            }
        }
    }

    /** Whole-scene invariants after a grammar-legal op sequence. */
    fun validateResult(work: Map<String, JSONObject>): JSONArray? {
        var cameras = 0
        var environments = 0
        for (entity in work.values) {
            when (kindOf(entity)) {
                "camera" -> cameras++
                "environment" -> environments++
            }
        }
        return when {
            cameras > 1 -> err("invalid_result", "multiple_cameras")
            environments > 1 -> err("invalid_result", "multiple_environments")
            else -> null
        }
    }

    fun kindOf(entity: JSONObject): String = entity.optJSONObject("data")?.optString("kind", "group") ?: "group"

    fun parentOf(entity: JSONObject): String? = if (entity.isNull("parent")) null else entity.optString("parent")

    /**
     * Normalize a wire material override — a single object (scope nil = all
     * instances, the pre-scope wire shape) or an array of scoped overrides —
     * to a list. Anything else (including null) is "no override".
     */
    fun overrides(material: Any?): List<JSONObject> =
        when (material) {
            is JSONObject -> listOf(material)
            is JSONArray -> (0 until material.length()).mapNotNull { material.optJSONObject(it) }
            else -> emptyList()
        }

    /** The scope of one override entry: a glTF material name, or null = all. */
    fun scopeOf(override: JSONObject): String? = if (override.isNull("scope")) null else override.optString("scope")

    // Unknown scope names reject synchronously when the asset's material
    // list is already registered (loaded by the render thread); an asset
    // still loading validates render-side instead and errors asynchronously
    // — the same two-tier honesty animation names have.
    private fun materialError(entity: JSONObject): JSONArray? {
        val data = entity.optJSONObject("data") ?: return null
        if (data.optString("kind") != "model" || data.isNull("material")) return null
        val known = Scene3dRuntime.materialNames(data.optString("asset")) ?: return null
        for (override in overrides(data.opt("material"))) {
            val scope = scopeOf(override) ?: continue
            if (scope !in known) return err("unknown_material", entity.optString("id"), scope)
        }
        return null
    }

    // Unknown clip names reject synchronously when the asset's clip list is
    // already registered (loaded by the render thread); an asset still
    // loading validates render-side instead and errors asynchronously —
    // either way the failure is loud, never a silently idle model.
    private fun animationError(entity: JSONObject): JSONArray? {
        val data = entity.optJSONObject("data") ?: return null
        if (data.optString("kind") != "model" || data.isNull("animation")) return null
        val name = data.getJSONObject("animation").optString("name")
        val known = Scene3dRuntime.animationNames(data.optString("asset")) ?: return null
        return if (name in known) null else err("unknown_animation", entity.optString("id"), name)
    }

    private fun cyclic(
        work: Map<String, JSONObject>,
        start: String,
    ): Boolean {
        var current: String? = start
        val seen = HashSet<String>()
        while (current != null) {
            if (!seen.add(current)) return true
            current = work[current]?.let { parentOf(it) }
        }
        return false
    }

    private fun setField(
        work: LinkedHashMap<String, JSONObject>,
        op: JSONArray,
        field: String,
    ): JSONArray? {
        val id = op.optString(1)
        val entity = work[id] ?: return err("unknown_entity", id)
        val updated = clone(entity)
        updated.put(field, if (op.isNull(2)) JSONObject.NULL else op.get(2))
        work[id] = updated
        return null
    }

    private fun setDataField(
        work: LinkedHashMap<String, JSONObject>,
        op: JSONArray,
        expectedKind: String,
        field: String,
    ): JSONArray? {
        val id = op.optString(1)
        val entity = work[id] ?: return err("unknown_entity", id)
        if (kindOf(entity) != expectedKind) return err("kind_mismatch", id, expectedKind)
        val updated = clone(entity)
        updated.getJSONObject("data").put(field, if (op.isNull(2)) JSONObject.NULL else op.get(2))
        work[id] = updated
        return null
    }

    private fun setData(
        work: LinkedHashMap<String, JSONObject>,
        op: JSONArray,
        expectedKind: String,
        structuralCheck: (JSONObject, JSONObject) -> JSONArray?,
    ): JSONArray? {
        val id = op.optString(1)
        val entity = work[id] ?: return err("unknown_entity", id)
        if (kindOf(entity) != expectedKind) return err("kind_mismatch", id, expectedKind)
        val next = op.optJSONObject(2) ?: return err("bad_patch", "set_$expectedKind")
        val current = entity.getJSONObject("data")
        structuralCheck(current, next)?.let { return it }
        val updated = clone(entity)
        next.put("kind", expectedKind)
        updated.put("data", next)
        work[id] = updated
        return null
    }

    private fun clone(entity: JSONObject): JSONObject = JSONObject(entity.toString())

    private fun err(vararg args: String): JSONArray {
        val arr = JSONArray()
        args.forEach { arr.put(it) }
        return arr
    }
}

// ── The composable factory ─────────────────────────────────────────────────

/**
 * The generated registration's factory: mob_dev calls it with the props and
 * the host's native event sender (typed in the host package, hence `Any?`).
 * Picks and animation events go over the plugin's own NIF wire, not `send`.
 */
@Composable
fun MobScene3dViewport(props: Map<String, Any?>, @Suppress("UNUSED_PARAMETER") send: Any?) {
    MobScene3dViewport(props)
}

@Composable
fun MobScene3dViewport(props: Map<String, Any?>) {
    val viewportId = props["viewport_id"] as? String ?: return
    val w = (props["width"] as? Number)?.toFloat() ?: 340f
    val h = (props["height"] as? Number)?.toFloat() ?: 420f
    // background: 0xAARRGGBB (sRGB) clear colour; absent = the default dark
    // skybox. Applied on create and on every recomposition so a screen can
    // change it without recreating the surface.
    val background = (props["background"] as? Number)?.toLong()
    // clipToBounds: a surface otherwise draws past its declared bounds and
    // stomps siblings (MobGpuView's identical treatment).
    Box(modifier = Modifier.size(w.dp, h.dp).clipToBounds()) {
        AndroidView(
            factory = { ctx -> Scene3dView(ctx, viewportId, background) },
            update = { view -> view.setBackgroundArgb(background) },
        )
    }
}

// ── The Filament applier + surface/lifecycle shim ──────────────────────────

class Scene3dView(
    context: Context,
    private val viewportId: String,
    backgroundArgb: Long? = null,
) : SurfaceView(context),
    Choreographer.FrameCallback {
    private class Rec(
        val entity: Int,
        var json: JSONObject,
        var instance: FilamentInstance? = null,
        var assetRef: String? = null,
        var overridden: Boolean = false,
        var inScene: Boolean = false,
        var camera: Camera? = null,
        var hasLight: Boolean = false,
        var status: String = "ready",
        var statusDetail: String? = null,
        var anim: AnimState? = null,
        // Applied material-override truth for scene/1 readback: one entry
        // per override (scope, applied params, matched instance names, or
        // an unknown_material error marker). Null = no override applied.
        var materialState: JSONArray? = null,
    )

    // The render-thread clip clock for one model's declarative animation
    // state. The Animator itself is NOT held here — it belongs to the
    // gltfio instance and is looked up per frame, so a material-clear
    // instance rebuild keeps the clock without holding a stale pointer.
    private class AnimState(
        val name: String,
        val playId: String,
        val index: Int,
        val duration: Double,
    ) {
        var clock = 0.0
        var loop = false
        var speed = 1.0
        var paused = false
        var lastSeek: Double? = null
        var done = false
        var doneDelivered = false
        var appliedTime = 0.0
    }

    // gltfio has no per-instance destroy in the Java API, and createInstance
    // needs the asset's source data retained — so assets keep their source
    // data and detached instances go to a free list. Instances that carried
    // material overrides are NOT reused (their asset-authored factors are
    // unrecoverable); they are abandoned until asset teardown.
    private class AssetEntry(
        val asset: FilamentAsset,
        val freeInstances: ArrayDeque<FilamentInstance> = ArrayDeque(),
    )

    private val choreographer = Choreographer.getInstance()
    private val engine = Engine.create()
    private val renderer: Renderer = engine.createRenderer()
    private val scene: Scene = engine.createScene()
    private val view: View = engine.createView()
    private val uiHelper = UiHelper(UiHelper.ContextErrorPolicy.DONT_CHECK)
    private var swapChain: SwapChain? = null

    private val materialProvider = UbershaderProvider(engine)
    private val assetLoader = AssetLoader(engine, materialProvider, EntityManager.get())
    private val resourceLoader = ResourceLoader(engine)
    private val assets = HashMap<String, AssetEntry>()

    private val registry = LinkedHashMap<String, Rec>()
    private var irCameraId: String? = null

    private val fallbackCameraEntity = EntityManager.get().create()
    private val fallbackCamera: Camera = engine.createCamera(fallbackCameraEntity)

    // The clear colour: the viewport's `background` prop (sRGB ARGB → linear)
    // or the default dark skybox when the screen sets none.
    private val skybox: Skybox =
        Skybox.Builder().color(0.035f, 0.04f, 0.07f, 1.0f).build(engine).also {
            skyboxArgb = backgroundArgb
            applySkyboxColor(it, backgroundArgb)
        }
    private var skyboxArgb: Long? = null

    /** Re-tint the skybox; `null` restores the default dark clear colour. */
    fun setBackgroundArgb(argb: Long?) {
        if (argb == skyboxArgb) return
        skyboxArgb = argb
        applySkyboxColor(skybox, argb)
    }

    private fun applySkyboxColor(
        sky: Skybox,
        argb: Long?,
    ) {
        if (argb == null) {
            sky.setColor(0.035f, 0.04f, 0.07f, 1.0f)
            return
        }
        val r = srgbToLinear(((argb shr 16) and 0xFF).toFloat() / 255f)
        val g = srgbToLinear(((argb shr 8) and 0xFF).toFloat() / 255f)
        val b = srgbToLinear((argb and 0xFF).toFloat() / 255f)
        sky.setColor(r, g, b, 1.0f)
    }

    private fun srgbToLinear(c: Float): Float =
        if (c <= 0.04045f) c / 12.92f else Math.pow(((c + 0.055f) / 1.055f).toDouble(), 2.4).toFloat()

    private var viewportWidth = 0
    private var viewportHeight = 0
    private var readySent = false
    private var frameCallbackPosted = false

    // ── introspection state (render thread only) ──────────────────────────
    private val mainHandler = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density

    // Sample queries wait for a frame we actually render: readPixels must
    // sit between render() and endFrame() to read the swap chain.
    private val pendingSamples = ArrayDeque<Scene3dRuntime.Query>()

    // Frame timing ring buffer — one delta per Choreographer tick, cheap by
    // construction. 120 entries ≈ the last two seconds at 60 Hz.
    private val frameDeltas = DoubleArray(120)
    private var frameDeltaCount = 0
    private var frameDeltaIndex = 0
    private var lastFrameNanos = 0L
    private var framesSinceQuery = 0
    private var droppedSinceQuery = 0

    // Animation clock: one dt per Choreographer tick, shared by every
    // playing clip (render thread only).
    private var lastAnimNanos = 0L

    // Tap capture: a single tap inside the viewport rides the same native
    // pick path pick/3 uses. Hits on pickable models become pick events;
    // misses are silence (the decision record's honest-miss ruling).
    private val gestureDetector =
        GestureDetector(
            context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDown(e: MotionEvent): Boolean = true

                override fun onSingleTapUp(e: MotionEvent): Boolean {
                    pickAt(e.x.toDouble(), e.y.toDouble(), null)
                    return true
                }
            },
        )

    init {
        view.scene = scene
        view.camera = fallbackCamera
        scene.skybox = skybox
        // Physical-light exposure (sunny 16) — matches the spike and the
        // 100k-lux directional lights meters-and-lux scenes use.
        fallbackCamera.setExposure(16.0f, 1.0f / 125.0f, 100.0f)
        fallbackCamera.lookAt(0.0, 1.8, 4.8, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)

        uiHelper.renderCallback =
            object : UiHelper.RendererCallback {
                override fun onNativeWindowChanged(surface: Surface) {
                    swapChain?.let { engine.destroySwapChain(it) }
                    swapChain = engine.createSwapChain(surface, uiHelper.swapChainFlags)
                }

                override fun onDetachedFromSurface() {
                    swapChain?.let {
                        engine.destroySwapChain(it)
                        engine.flushAndWait()
                        swapChain = null
                    }
                }

                override fun onResized(
                    width: Int,
                    height: Int,
                ) {
                    viewportWidth = width
                    viewportHeight = height
                    view.viewport = Viewport(0, 0, width, height)
                    updateProjection()
                }
            }
        uiHelper.attachTo(this)
    }

    // ── lifecycle ──────────────────────────────────────────────────────────

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        applyOps(Scene3dRuntime.attach(viewportId, this))
        postFrames()
    }

    override fun onDetachedFromWindow() {
        pauseFrames()
        Scene3dRuntime.detach(viewportId, this)
        destroyRenderer()
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        // Background pause / foreground resume: no frames while invisible.
        if (visibility == VISIBLE && isAttachedToWindow) postFrames() else pauseFrames()
    }

    private fun postFrames() {
        if (!frameCallbackPosted) {
            frameCallbackPosted = true
            choreographer.postFrameCallback(this)
        }
    }

    private fun pauseFrames() {
        if (frameCallbackPosted) {
            frameCallbackPosted = false
            choreographer.removeFrameCallback(this)
        }
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!frameCallbackPosted) return
        choreographer.postFrameCallback(this)
        recordFrameDelta(frameTimeNanos)

        val drained = Scene3dRuntime.drain(viewportId)
        if (drained.reset) clearScene()
        applyOps(drained.ops)
        advanceAnimations(frameTimeNanos)
        for ((pid, requestId) in drained.sceneRequests) {
            MobScene3dBridge.nativeDeliverScene3d(pid, "scene", viewportId, requestId, sceneJson())
        }
        for (query in drained.queries) {
            when (query.kind) {
                "pick" -> {
                    pickAt(
                        query.params.optDouble("x", 0.0) * density,
                        query.params.optDouble("y", 0.0) * density,
                        query,
                    )
                }

                "sample" -> {
                    pendingSamples.addLast(query)
                }

                "stats" -> {
                    deliverFrameStats(query)
                }
            }
        }

        if (uiHelper.isReadyToRender && swapChain != null &&
            renderer.beginFrame(swapChain!!, frameTimeNanos)
        ) {
            renderer.render(view)
            // GPU readback rides between render() and endFrame(): that is
            // the window where the swap chain is readable. Window capture
            // cannot see this surface at all (the SurfaceView blindspot) —
            // this IS the pixel-truth path.
            while (pendingSamples.isNotEmpty()) readbackSample(pendingSamples.removeFirst())
            renderer.endFrame()
            framesSinceQuery++
            if (!readySent) {
                readySent = true
                val owner = Scene3dRuntime.ownerPid(viewportId)
                if (owner != 0L) {
                    MobScene3dBridge.nativeDeliverScene3d(owner, "ready", viewportId, "", "")
                }
            }
        }
    }

    // ── input: tap → ray pick → {tag, entity} event (bead na8) ────────────

    override fun onTouchEvent(event: MotionEvent): Boolean = gestureDetector.onTouchEvent(event)

    /**
     * Ray-pick at view-local pixel coords. `query == null` is the touch
     * path (hit → "pick_event" to the owner; miss → silence). A query gets
     * an explicit reply either way. Filament picks async on the GPU; the
     * callback lands on the main thread a frame or two later.
     */
    private fun pickAt(
        xPx: Double,
        yPx: Double,
        query: Scene3dRuntime.Query?,
    ) {
        // Filament pick coords: viewport pixels, origin bottom-left.
        val px = Math.round(xPx).toInt()
        val py = viewportHeight - Math.round(yPx).toInt()
        view.pick(px, py, mainHandler) { result ->
            val entityId = resolvePick(result.renderable)
            if (query != null) {
                val reply =
                    if (entityId != null) {
                        JSONObject().put("entity", entityId)
                    } else {
                        JSONObject().put("miss", true)
                    }
                MobScene3dBridge.nativeDeliverScene3d(
                    query.pid,
                    "pick",
                    viewportId,
                    query.requestId,
                    reply.toString(),
                )
            } else if (entityId != null) {
                val owner = Scene3dRuntime.ownerPid(viewportId)
                if (owner != 0L) {
                    MobScene3dBridge.nativeDeliverScene3d(owner, "pick_event", viewportId, entityId, "")
                }
            }
        }
    }

    /** Picked renderable → owning IR entity id, pickable models only. */
    private fun resolvePick(renderable: Int): String? {
        if (renderable == 0) return null
        for ((id, rec) in registry) {
            val instance = rec.instance ?: continue
            if (!rec.json.optBoolean("pickable", false)) continue
            if (instance.entities.contains(renderable)) return id
        }
        return null
    }

    // ── pixel truth: Filament readPixels over a viewport-local dp rect ────

    private fun readbackSample(query: Scene3dRuntime.Query) {
        // dp rect → device pixels, clamped to the viewport.
        val left = Math.round(query.params.optDouble("x", 0.0) * density).toInt()
        val top = Math.round(query.params.optDouble("y", 0.0) * density).toInt()
        val right =
            Math
                .round((query.params.optDouble("x", 0.0) + query.params.optDouble("w", 0.0)) * density)
                .toInt()
        val bottom =
            Math
                .round((query.params.optDouble("y", 0.0) + query.params.optDouble("h", 0.0)) * density)
                .toInt()
        val x0 = left.coerceIn(0, viewportWidth)
        val y0 = top.coerceIn(0, viewportHeight)
        val x1 = right.coerceIn(0, viewportWidth)
        val y1 = bottom.coerceIn(0, viewportHeight)
        val w = x1 - x0
        val h = y1 - y0
        if (w <= 0 || h <= 0) {
            deliverQueryError(query, "offscreen")
            return
        }

        // readPixels origin is bottom-left (GL convention); rows arrive
        // bottom-to-top, which the order-invariant stats reduction ignores.
        val glY = viewportHeight - (y0 + h)
        val buffer = ByteBuffer.allocateDirect(w * h * 4)
        val descriptor =
            Texture.PixelBufferDescriptor(buffer, Texture.Format.RGBA, Texture.Type.UBYTE)
        descriptor.setCallback(mainHandler) {
            buffer.rewind()
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            // The swap chain's alpha channel is not part of the composited
            // output (the surface is opaque; GLES leaves it 0) — report the
            // pixels as displayed: opaque. Keeps 0xAARRGGBB comparisons
            // against Mob.Test's sampler sane.
            var alphaIndex = 3
            while (alphaIndex < bytes.size) {
                bytes[alphaIndex] = -1
                alphaIndex += 4
            }
            val reply =
                JSONObject()
                    .put("width", w)
                    .put("height", h)
                    .put("rgba", Base64.encodeToString(bytes, Base64.NO_WRAP))
            MobScene3dBridge.nativeDeliverScene3d(
                query.pid,
                "sample",
                viewportId,
                query.requestId,
                reply.toString(),
            )
        }
        renderer.readPixels(x0, glY, w, h, descriptor)
    }

    private fun deliverQueryError(
        query: Scene3dRuntime.Query,
        vararg reason: String,
    ) {
        val error = JSONArray()
        reason.forEach { error.put(it) }
        MobScene3dBridge.nativeDeliverScene3d(
            query.pid,
            query.kind,
            viewportId,
            query.requestId,
            JSONObject().put("error", error).toString(),
        )
    }

    // ── perf readback: ring buffer of vsync deltas (bead 0n7 scope note) ──

    private fun recordFrameDelta(frameTimeNanos: Long) {
        if (lastFrameNanos != 0L) {
            val deltaMs = (frameTimeNanos - lastFrameNanos) / 1_000_000.0
            frameDeltas[frameDeltaIndex] = deltaMs
            frameDeltaIndex = (frameDeltaIndex + 1) % frameDeltas.size
            if (frameDeltaCount < frameDeltas.size) frameDeltaCount++
            if (deltaMs > 1.5 * refreshPeriodMs()) droppedSinceQuery++
        }
        lastFrameNanos = frameTimeNanos
    }

    private fun refreshPeriodMs(): Double {
        val rate = display?.refreshRate?.toDouble() ?: 60.0
        return if (rate > 1.0) 1_000.0 / rate else 1_000.0 / 60.0
    }

    private fun deliverFrameStats(query: Scene3dRuntime.Query) {
        val window = DoubleArray(frameDeltaCount) { frameDeltas[it] }
        window.sort()
        val avg = if (window.isEmpty()) 0.0 else window.average()
        val p95 =
            if (window.isEmpty()) {
                0.0
            } else {
                window[((window.size - 1) * 95 + 99) / 100]
            }
        val reply =
            JSONObject()
                .put("frames", framesSinceQuery)
                .put("avg_ms", Math.round(avg * 1000.0) / 1000.0)
                .put("p95_ms", Math.round(p95 * 1000.0) / 1000.0)
                .put("dropped", droppedSinceQuery)
                .put("entities", registry.size)
                .put("renderables", scene.renderableCount)
        framesSinceQuery = 0
        droppedSinceQuery = 0
        MobScene3dBridge.nativeDeliverScene3d(
            query.pid,
            "stats",
            viewportId,
            query.requestId,
            reply.toString(),
        )
    }

    // ── the applier: patch ops → Filament mutations (the mapping table) ────

    private fun applyOps(ops: List<JSONArray>) {
        for (op in ops) {
            try {
                applyOp(op)
            } catch (e: Exception) {
                // Shadow-validated ops shouldn't throw; if one does, that is
                // an applier bug — surface it, never swallow it.
                val owner = Scene3dRuntime.ownerPid(viewportId)
                val error = JSONArray().put("bad_patch").put("applier: ${e.message}")
                if (owner != 0L) {
                    MobScene3dBridge.nativeDeliverScene3d(owner, "error", viewportId, error.toString(), "")
                }
                android.util.Log.e("scene3d", "applier failure on ${op.optString(0)}", e)
            }
        }
    }

    private fun applyOp(op: JSONArray) {
        when (op.getString(0)) {
            "add_entity" -> addEntity(op.getJSONObject(1))
            "replace_entity" -> replaceEntity(op.getJSONObject(1))
            "remove_entity" -> removeEntity(op.getString(1))
            "set_parent" -> setParent(op.getString(1), if (op.isNull(2)) null else op.getString(2))
            "set_transform" -> setTransform(op.getString(1), op.getJSONObject(2))
            "set_visible" -> setVisible(op.getString(1), op.getBoolean(2))
            "set_pickable" -> setPickable(op.getString(1), op.getBoolean(2))
            "set_material" -> setMaterial(op.getString(1), if (op.isNull(2)) null else op.get(2))
            "set_animation" -> setAnimation(op.getString(1), if (op.isNull(2)) null else op.getJSONObject(2))
            "set_camera" -> setCamera(op.getString(1), op.getJSONObject(2))
            "set_light" -> setLight(op.getString(1), op.getJSONObject(2))
            "set_environment" -> setEnvironment(op.getString(1), op.getJSONObject(2))
        }
    }

    private fun addEntity(json: JSONObject) {
        val id = json.getString("id")
        val entity = EntityManager.get().create()
        engine.transformManager.create(entity)
        val rec = Rec(entity, json)
        registry[id] = rec
        applyLocalTransform(rec)
        applyParent(rec)
        buildData(rec)
        applyVisibility(rec)
    }

    // Same id, structural change: kind-specific native resources are
    // destroyed and recreated; the transform entity persists, so children
    // stay parented untouched.
    private fun replaceEntity(json: JSONObject) {
        val id = json.getString("id")
        val rec = registry[id] ?: return
        tearDownData(rec)
        rec.json = json
        rec.status = "ready"
        rec.statusDetail = null
        applyLocalTransform(rec)
        applyParent(rec)
        buildData(rec)
        applyVisibility(rec)
    }

    private fun removeEntity(id: String) {
        val rec = registry.remove(id) ?: return
        tearDownData(rec)
        engine.transformManager.destroy(rec.entity)
        engine.destroyEntity(rec.entity)
        EntityManager.get().destroy(rec.entity)
    }

    private fun setParent(
        id: String,
        parent: String?,
    ) {
        val rec = registry[id] ?: return
        rec.json =
            rec.json.also {
                if (parent == null) it.put("parent", JSONObject.NULL) else it.put("parent", parent)
            }
        applyParent(rec)
    }

    private fun setTransform(
        id: String,
        transform: JSONObject,
    ) {
        val rec = registry[id] ?: return
        rec.json.put("transform", transform)
        applyLocalTransform(rec)
    }

    private fun setVisible(
        id: String,
        visible: Boolean,
    ) {
        val rec = registry[id] ?: return
        rec.json.put("visible", visible)
        applyVisibility(rec)
    }

    private fun setPickable(
        id: String,
        pickable: Boolean,
    ) {
        // The registry json is what pick resolution consults (resolvePick),
        // so flipping the flag takes effect on the next tap/pick.
        registry[id]?.json?.put("pickable", pickable)
    }

    private fun setMaterial(
        id: String,
        material: Any?,
    ) {
        val rec = registry[id] ?: return
        val previous = rec.json.optJSONObject("data")?.opt("material")
        rec.json.getJSONObject("data").put("material", material ?: JSONObject.NULL)
        val next = Scene3dShadow.overrides(material)
        if (next.isEmpty()) {
            // Clearing an override restores the asset-authored factors.
            // gltfio material instances have no readback for the originals,
            // so recreate the instance from the shared asset — cheap next to
            // an asset load, and exactly what "keep what the asset authored"
            // means.
            rebuildModelInstance(rec)
        } else if (rec.overridden && !covers(Scene3dShadow.overrides(previous), next)) {
            // Whole-value replace semantics: a (scope, parameter) pair the
            // new override no longer touches must return to its
            // asset-authored value, and only a fresh instance has those —
            // rebuild, then buildModel re-applies the stored new override.
            rebuildModelInstance(rec)
        } else {
            applyMaterial(rec, material)
        }
    }

    // The new override keeps in-place application safe iff every previously
    // overridden (scope, parameter) pair is still set: same-scope entry
    // present with a superset of the non-null parameters. Conservative on
    // purpose — overlap analysis across different scopes would need
    // instance-name knowledge the hot path shouldn't pay for.
    private fun covers(
        old: List<JSONObject>,
        new: List<JSONObject>,
    ): Boolean =
        old.all { previous ->
            val scope = Scene3dShadow.scopeOf(previous)
            val replacement = new.firstOrNull { Scene3dShadow.scopeOf(it) == scope }
            replacement != null &&
                paramNames(previous).all { it in paramNames(replacement) }
        }

    private fun paramNames(override: JSONObject): List<String> =
        listOf("base_color", "metallic", "roughness", "emissive").filter { !override.isNull(it) }

    private fun setAnimation(
        id: String,
        animation: JSONObject?,
    ) {
        val rec = registry[id] ?: return
        rec.json.getJSONObject("data").put("animation", animation ?: JSONObject.NULL)
        applyAnimationState(rec, id, animation)
    }

    // Reconcile the declarative animation intent with the render-thread
    // clip clock. Replay = a play_id change (restart from seek ?: 0);
    // same play_id = in-place field updates, a changed non-null seek
    // repositions the clock without restarting (the decision record's
    // seek semantics).
    private fun applyAnimationState(
        rec: Rec,
        id: String,
        animation: JSONObject?,
    ) {
        if (animation == null) {
            // Declaratively "no animation": stop driving the clip; the pose
            // stays where the clock left it (resources untouched).
            rec.anim = null
            return
        }
        val animator = rec.instance?.animator
        if (animator == null) {
            // No instance = bad_asset already reported; nothing to drive.
            rec.anim = null
            return
        }
        val name = animation.optString("name")
        val playId = animation.optString("play_id")
        var index = -1
        for (i in 0 until animator.animationCount) {
            if (animator.getAnimationName(i) == name) {
                index = i
                break
            }
        }
        if (index < 0) {
            // Unknown clip that raced the shadow's name registry: honest and
            // loud — an error event to the owner AND an error-shaped
            // animation_state in the readback. Never a silently idle model.
            rec.anim = AnimState(name, playId, -1, 0.0)
            val owner = Scene3dRuntime.ownerPid(viewportId)
            if (owner != 0L) {
                val error = JSONArray().put("unknown_animation").put(id).put(name)
                MobScene3dBridge.nativeDeliverScene3d(owner, "error", viewportId, error.toString(), "")
            }
            return
        }
        val seek = if (animation.isNull("seek")) null else animation.getDouble("seek")
        val current = rec.anim
        val restart = current == null || current.playId != playId || current.name != name || current.index < 0
        val state =
            if (restart) {
                AnimState(name, playId, index, animator.getAnimationDuration(index).toDouble())
                    .also {
                        it.clock = seek ?: 0.0
                        rec.anim = it
                    }
            } else {
                current!!.also {
                    if (seek != null && seek != it.lastSeek) it.clock = seek
                }
            }
        state.loop = animation.optBoolean("loop", false)
        state.speed = animation.optDouble("speed", 1.0)
        state.paused = animation.optBoolean("paused", false)
        state.lastSeek = seek
    }

    /** Advance every model's clip clock and pose; deliver completions. */
    private fun advanceAnimations(frameTimeNanos: Long) {
        // Clamped dt: a background pause must not fast-forward clips to
        // their end on resume (the clock freezes with the vsync loop).
        val dt =
            if (lastAnimNanos == 0L) {
                0.0
            } else {
                ((frameTimeNanos - lastAnimNanos) / 1e9).coerceIn(0.0, 0.1)
            }
        lastAnimNanos = frameTimeNanos
        for (rec in registry.values) {
            val st = rec.anim ?: continue
            if (st.index < 0) continue
            val animator = rec.instance?.animator ?: continue
            if (!st.paused && !st.done) st.clock += dt * st.speed
            st.appliedTime =
                when {
                    st.duration <= 0.0 -> 0.0
                    st.loop -> st.clock.mod(st.duration)
                    else -> st.clock.coerceAtMost(st.duration)
                }
            animator.applyAnimation(st.index, st.appliedTime.toFloat())
            animator.updateBoneMatrices()
            if (!st.loop && !st.paused && !st.done && st.clock >= st.duration) {
                // Clip end: clamp the pose at the final frame and deliver
                // {:animation_done, play_id} once per play_id. Completion
                // needs a RUNNING clock — a paused clip seeked to the end
                // holds the final pose without completing until unpaused.
                // Seeking a completed clip repositions the pose; only a new
                // play_id runs it again.
                st.done = true
                if (!st.doneDelivered) {
                    st.doneDelivered = true
                    val owner = Scene3dRuntime.ownerPid(viewportId)
                    if (owner != 0L) {
                        MobScene3dBridge.nativeDeliverScene3d(owner, "anim_done", viewportId, st.playId, "")
                    }
                }
            }
        }
    }

    private fun setCamera(
        id: String,
        camera: JSONObject,
    ) {
        val rec = registry[id] ?: return
        rec.json.getJSONObject("data").apply {
            put("fov_y", camera.optDouble("fov_y", 45.0))
            put("near", camera.optDouble("near", 0.1))
            put("far", camera.optDouble("far", 100.0))
        }
        updateProjection()
    }

    private fun setLight(
        id: String,
        light: JSONObject,
    ) {
        val rec = registry[id] ?: return
        light.put("kind", "light")
        rec.json.put("data", light)
        val lm = engine.lightManager
        val li = lm.getInstance(rec.entity)
        if (li == 0) return
        lm.setIntensity(li, light.optDouble("intensity", 0.0).toFloat())
        val color = light.optJSONArray("color")
        if (color != null) {
            lm.setColor(
                li,
                color.optDouble(0, 1.0).toFloat(),
                color.optDouble(1, 1.0).toFloat(),
                color.optDouble(2, 1.0).toFloat(),
            )
        }
        lm.setShadowCaster(li, light.optBoolean("cast_shadows", false))
        if (!light.isNull("falloff")) lm.setFalloff(li, light.optDouble("falloff", 1.0).toFloat())
        if (!light.isNull("spot_inner") && !light.isNull("spot_outer")) {
            lm.setSpotLightCone(
                li,
                Math.toRadians(light.getDouble("spot_inner")).toFloat(),
                Math.toRadians(light.getDouble("spot_outer")).toFloat(),
            )
        }
    }

    private fun setEnvironment(
        id: String,
        environment: JSONObject,
    ) {
        val rec = registry[id] ?: return
        environment.put("kind", "environment")
        rec.json.put("data", environment)
        // IBL/skybox KTX loading is the asset-pipeline bead (mob_scene3d-392).
        // Accepted and recorded for readback; loudly logged, never silent.
        android.util.Log.w(
            "scene3d",
            "environment accepted but IBL/skybox loading is not wired yet " +
                "(bead mob_scene3d-392): ${environment.optString("ibl", "-")}",
        )
    }

    // ── data builders / teardown ───────────────────────────────────────────

    private fun buildData(rec: Rec) {
        val data = rec.json.optJSONObject("data") ?: return
        when (data.optString("kind")) {
            "model" -> buildModel(rec, data)
            "light" -> buildLight(rec, data)
            "camera" -> buildCamera(rec)
            "environment" -> setEnvironment(rec.json.getString("id"), data)
        }
    }

    private fun buildModel(
        rec: Rec,
        data: JSONObject,
    ) {
        val ref = data.getString("asset")
        val entry = loadAsset(ref)
        val instance =
            entry?.let { it.freeInstances.removeFirstOrNull() ?: assetLoader.createInstance(it.asset) }
        if (entry == null || instance == null) {
            rec.status = "error"
            rec.statusDetail = "bad_asset"
            val owner = Scene3dRuntime.ownerPid(viewportId)
            if (owner != 0L) {
                val error = JSONArray().put("bad_asset").put(ref).put("load_failed")
                MobScene3dBridge.nativeDeliverScene3d(owner, "error", viewportId, error.toString(), "")
            }
            return
        }
        rec.instance = instance
        rec.assetRef = ref
        rec.overridden = false
        rec.materialState = null
        val tm = engine.transformManager
        tm.setParent(tm.getInstance(instance.root), tm.getInstance(rec.entity))
        if (!data.isNull("material")) applyMaterial(rec, data.opt("material"))
        // Reconcile the declared animation with the (possibly fresh)
        // instance: same play_id keeps its clock across a material-clear
        // rebuild; a new entity starts from seek ?: 0.
        applyAnimationState(rec, rec.json.getString("id"), data.optJSONObject("animation"))
    }

    private fun buildLight(
        rec: Rec,
        data: JSONObject,
    ) {
        val type =
            when (data.optString("type")) {
                "point" -> LightManager.Type.POINT
                "spot" -> LightManager.Type.SPOT
                else -> LightManager.Type.DIRECTIONAL
            }
        val builder =
            LightManager
                .Builder(type)
                .intensity(data.optDouble("intensity", 0.0).toFloat())
                .castShadows(data.optBoolean("cast_shadows", false))
                // Lights shine down local -Z (the IR convention); the entity's
                // transform orients them.
                .direction(0.0f, 0.0f, -1.0f)
        data.optJSONArray("color")?.let {
            builder.color(
                it.optDouble(0, 1.0).toFloat(),
                it.optDouble(1, 1.0).toFloat(),
                it.optDouble(2, 1.0).toFloat(),
            )
        }
        if (!data.isNull("falloff")) builder.falloff(data.getDouble("falloff").toFloat())
        if (!data.isNull("spot_inner") && !data.isNull("spot_outer")) {
            builder.spotLightCone(
                Math.toRadians(data.getDouble("spot_inner")).toFloat(),
                Math.toRadians(data.getDouble("spot_outer")).toFloat(),
            )
        }
        builder.build(engine, rec.entity)
        rec.hasLight = true
    }

    private fun buildCamera(rec: Rec) {
        val camera = engine.createCamera(rec.entity)
        camera.setExposure(16.0f, 1.0f / 125.0f, 100.0f)
        rec.camera = camera
        irCameraId = rec.json.getString("id")
        view.camera = camera
        updateProjection()
    }

    private fun tearDownData(rec: Rec) {
        // Structural teardown (replace/remove): the clip identity dies with
        // the data payload; a replacement entity re-resolves from its json.
        rec.anim = null
        rec.materialState = null
        rec.instance?.let { instance ->
            if (rec.inScene) scene.removeEntities(instance.entities)
            rec.inScene = false
            val tm = engine.transformManager
            tm.setParent(tm.getInstance(instance.root), 0)
            if (!rec.overridden) {
                rec.assetRef?.let { assets[it]?.freeInstances?.addLast(instance) }
            }
            rec.instance = null
            rec.assetRef = null
        }
        if (rec.hasLight) {
            scene.remove(rec.entity)
            engine.lightManager.destroy(rec.entity)
            rec.hasLight = false
        }
        if (rec.camera != null) {
            engine.destroyCameraComponent(rec.entity)
            rec.camera = null
            if (irCameraId == rec.json.optString("id")) {
                irCameraId = null
                view.camera = fallbackCamera
                updateProjection()
            }
        }
    }

    private fun rebuildModelInstance(rec: Rec) {
        val data = rec.json.optJSONObject("data") ?: return
        rec.instance?.let { instance ->
            if (rec.inScene) scene.removeEntities(instance.entities)
            rec.inScene = false
            engine.transformManager.setParent(engine.transformManager.getInstance(instance.root), 0)
            // Overridden by definition (that is why it is being rebuilt) —
            // abandoned, not reused.
            rec.instance = null
            rec.assetRef = null
        }
        buildModel(rec, data)
        applyVisibility(rec)
    }

    // Apply an override (single object or array of scoped overrides) to the
    // instance's material instances. scope == null hits every instance
    // (pre-scope behaviour); a named scope hits only instances whose glTF
    // material name matches (gltfio carries the authored name onto each
    // MaterialInstance). A named scope matching nothing is the async half
    // of the unknown_material honesty: an error event to the owner AND an
    // error marker in the readback — never a silently unstyled model.
    private fun applyMaterial(
        rec: Rec,
        material: Any?,
    ) {
        val instance = rec.instance ?: return
        val id = rec.json.getString("id")
        val state = JSONArray()
        for (override in Scene3dShadow.overrides(material)) {
            val scope = Scene3dShadow.scopeOf(override)
            val targets = instance.materialInstances.filter { scope == null || it.name == scope }
            val entry = JSONObject().put("scope", scope ?: JSONObject.NULL)
            if (scope != null && targets.isEmpty()) {
                entry.put("error", "unknown_material")
                state.put(entry)
                val owner = Scene3dRuntime.ownerPid(viewportId)
                if (owner != 0L) {
                    val error = JSONArray().put("unknown_material").put(id).put(scope)
                    MobScene3dBridge.nativeDeliverScene3d(owner, "error", viewportId, error.toString(), "")
                }
                continue
            }
            rec.overridden = true
            for (mi in targets) applyOverrideParams(mi, override)
            entry.put("applied", JSONArray(paramNames(override)))
            val names = JSONArray()
            targets.forEach { names.put(it.name) }
            entry.put("instances", names)
            state.put(entry)
        }
        rec.materialState = state
    }

    private fun applyOverrideParams(
        mi: MaterialInstance,
        material: JSONObject,
    ) {
        material.optJSONArray("base_color")?.let {
            if (mi.material.hasParameter("baseColorFactor")) {
                mi.setParameter(
                    "baseColorFactor",
                    it.getDouble(0).toFloat(),
                    it.getDouble(1).toFloat(),
                    it.getDouble(2).toFloat(),
                    it.getDouble(3).toFloat(),
                )
            }
        }
        if (!material.isNull("metallic") && mi.material.hasParameter("metallicFactor")) {
            mi.setParameter("metallicFactor", material.getDouble("metallic").toFloat())
        }
        if (!material.isNull("roughness") && mi.material.hasParameter("roughnessFactor")) {
            mi.setParameter("roughnessFactor", material.getDouble("roughness").toFloat())
        }
        material.optJSONArray("emissive")?.let {
            if (mi.material.hasParameter("emissiveFactor")) {
                mi.setParameter(
                    "emissiveFactor",
                    it.getDouble(0).toFloat(),
                    it.getDouble(1).toFloat(),
                    it.getDouble(2).toFloat(),
                )
            }
        }
    }

    private fun loadAsset(path: String): AssetEntry? {
        assets[path]?.let { return it }
        val bytes =
            try {
                File(path).readBytes()
            } catch (e: Exception) {
                return null
            }
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        buffer.put(bytes).rewind()
        // Instanced creation, and source data deliberately retained: both are
        // what makes createInstance work for later entities sharing this ref.
        val instances = arrayOfNulls<FilamentInstance>(1)
        val asset = assetLoader.createInstancedAsset(buffer, instances) ?: return null
        resourceLoader.loadResources(asset)
        val entry = AssetEntry(asset)
        instances[0]?.let { entry.freeInstances.addLast(it) }
        assets[path] = entry
        // Publish the asset's clip names so the BEAM-thread shadow can
        // reject unknown animation names synchronously from now on.
        val animator = instances[0]?.animator
        val names =
            if (animator == null) {
                emptyList()
            } else {
                List(animator.animationCount) { animator.getAnimationName(it) }
            }
        Scene3dRuntime.registerAssetAnimations(path, names)
        // Publish the glTF material names too, so unknown material scopes
        // reject synchronously once the asset is loaded.
        val materialNames =
            instances[0]?.materialInstances?.map { it.name }?.distinct() ?: emptyList()
        Scene3dRuntime.registerAssetMaterials(path, materialNames)
        return entry
    }

    // ── per-frame state pokes ──────────────────────────────────────────────

    private fun applyParent(rec: Rec) {
        val tm = engine.transformManager
        val parentId = Scene3dShadow.parentOf(rec.json)
        val parentInstance = parentId?.let { registry[it] }?.let { tm.getInstance(it.entity) } ?: 0
        tm.setParent(tm.getInstance(rec.entity), parentInstance)
    }

    private fun applyLocalTransform(rec: Rec) {
        val t = rec.json.optJSONObject("transform") ?: return
        engine.transformManager.setTransform(
            engine.transformManager.getInstance(rec.entity),
            trsMatrix(t),
        )
    }

    private fun applyVisibility(rec: Rec) {
        val visible = rec.json.optBoolean("visible", true)
        if (visible == rec.inScene) return
        rec.instance?.let { instance ->
            if (visible) scene.addEntities(instance.entities) else scene.removeEntities(instance.entities)
        }
        if (rec.hasLight) {
            if (visible) scene.addEntity(rec.entity) else scene.remove(rec.entity)
        }
        rec.inScene = visible && (rec.instance != null || rec.hasLight)
    }

    private fun updateProjection() {
        if (viewportWidth <= 0 || viewportHeight <= 0) return
        val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
        val data = irCameraId?.let { registry[it] }?.json?.optJSONObject("data")
        val fov = data?.optDouble("fov_y", 45.0) ?: 35.0
        val near = data?.optDouble("near", 0.1) ?: 0.05
        val far = data?.optDouble("far", 100.0) ?: 100.0
        (view.camera ?: fallbackCamera).setProjection(fov, aspect, near, far, Camera.Fov.VERTICAL)
    }

    /** Column-major T·R·S from the wire transform. */
    private fun trsMatrix(t: JSONObject): FloatArray {
        val p = t.getJSONArray("position")
        val q = t.getJSONArray("rotation")
        val s = t.getJSONArray("scale")
        var x = q.getDouble(0)
        var y = q.getDouble(1)
        var z = q.getDouble(2)
        var w = q.getDouble(3)
        val norm = Math.sqrt(x * x + y * y + z * z + w * w)
        if (norm > 1e-9) {
            x /= norm
            y /= norm
            z /= norm
            w /= norm
        }
        val sx = s.getDouble(0).toFloat()
        val sy = s.getDouble(1).toFloat()
        val sz = s.getDouble(2).toFloat()
        val m = FloatArray(16)
        m[0] = ((1 - 2 * (y * y + z * z)).toFloat()) * sx
        m[1] = ((2 * (x * y + z * w)).toFloat()) * sx
        m[2] = ((2 * (x * z - y * w)).toFloat()) * sx
        m[4] = ((2 * (x * y - z * w)).toFloat()) * sy
        m[5] = ((1 - 2 * (x * x + z * z)).toFloat()) * sy
        m[6] = ((2 * (y * z + x * w)).toFloat()) * sy
        m[8] = ((2 * (x * z + y * w)).toFloat()) * sz
        m[9] = ((2 * (y * z - x * w)).toFloat()) * sz
        m[10] = ((1 - 2 * (x * x + y * y)).toFloat()) * sz
        m[12] = p.getDouble(0).toFloat()
        m[13] = p.getDouble(1).toFloat()
        m[14] = p.getDouble(2).toFloat()
        m[15] = 1.0f
        return m
    }

    // ── readback: the applied scene, from the applier's own registry ───────

    private fun sceneJson(): String {
        val entities = JSONObject()
        val tm = engine.transformManager
        for ((id, rec) in registry) {
            val world = FloatArray(16)
            tm.getWorldTransform(tm.getInstance(rec.entity), world)
            val worldArr = JSONArray()
            world.forEach { worldArr.put(it.toDouble()) }
            val entity = JSONObject(rec.json.toString())
            entity.put("kind", Scene3dShadow.kindOf(rec.json))
            entity.put("world_transform", worldArr)
            entity.put("status", rec.status)
            rec.statusDetail?.let { entity.put("status_detail", it) }
            rec.anim?.let { st ->
                // Native truth, not intent echoed back: the applier's own
                // clip clock (data.animation above is the mirrored intent).
                val animState =
                    JSONObject()
                        .put("name", st.name)
                        .put("play_id", st.playId)
                if (st.index < 0) {
                    animState.put("error", "unknown_animation")
                } else {
                    animState
                        .put("time", Math.round(st.appliedTime * 1000.0) / 1000.0)
                        .put("done", st.done)
                        .put("paused", st.paused)
                        .put("loop", st.loop)
                }
                entity.put("animation_state", animState)
            }
            rec.materialState?.let { state ->
                // Applied override truth (which scopes matched which glTF
                // material instances) — data.material above is the mirrored
                // intent; this is what the applier actually did.
                if (state.length() > 0) entity.put("material_state", state)
            }
            // World transforms of the instance's NAMED glTF nodes: animation
            // retargets nodes inside the asset, so post-settle orientations
            // (the Chopaat shell-slot contract) are readable per node.
            val asset = rec.assetRef?.let { assets[it]?.asset }
            val instance = rec.instance
            if (asset != null && instance != null) {
                val nodes = JSONObject()
                for (nodeEntity in instance.entities) {
                    val name = asset.getName(nodeEntity) ?: continue
                    val nodeWorld = FloatArray(16)
                    tm.getWorldTransform(tm.getInstance(nodeEntity), nodeWorld)
                    val nodeArr = JSONArray()
                    nodeWorld.forEach { nodeArr.put(it.toDouble()) }
                    nodes.put(name, nodeArr)
                }
                if (nodes.length() > 0) entity.put("nodes", nodes)
            }
            entities.put(id, entity)
        }
        return JSONObject().put("entities", entities).toString()
    }

    private fun clearScene() {
        for (id in registry.keys.toList().asReversed()) removeEntity(id)
        irCameraId = null
        view.camera = fallbackCamera
    }

    private fun destroyRenderer() {
        clearScene()
        uiHelper.detach()
        for (entry in assets.values) assetLoader.destroyAsset(entry.asset)
        assets.clear()
        assetLoader.destroy()
        materialProvider.destroyMaterials()
        materialProvider.destroy()
        resourceLoader.destroy()
        engine.destroySkybox(skybox)
        engine.destroyCameraComponent(fallbackCameraEntity)
        EntityManager.get().destroy(fallbackCameraEntity)
        engine.destroyView(view)
        engine.destroyScene(scene)
        engine.destroyRenderer(renderer)
        swapChain?.let { engine.destroySwapChain(it) }
        engine.destroy()
    }
}
