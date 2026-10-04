// mob_touch plugin — Android bridge (Window.Callback touch observer).
//
// Streams the user's raw touches WITHOUT consuming them: on start it wraps the
// Activity window's callback with a reflective proxy that delegates every method
// to the original and only *observes* dispatchTouchEvent (then forwards it, so
// the app's buttons/scrolling keep working). On stop it restores the original
// callback. Coordinates are reported in dp; moves are throttled.
//
// MobPluginBootstrap.registerAll() calls register() at startup and hands off the
// Activity (MobActivityAware). The native thunks (nativeRegister + the
// nativeDeliverTouch hook) are exported from the sibling zig NIF
// mob_touch_nif.zig.
package io.mob.touch

import android.app.Activity
import android.view.MotionEvent
import android.view.Window
import java.lang.ref.WeakReference
import java.lang.reflect.Proxy

object MobTouchBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null
    private var originalCallback: Window.Callback? = null
    private var pid: Long = 0
    private var throttleMs: Long = 16
    private var density: Float = 1f
    private var lastMoveAt: Long = 0

    private const val PHASE_DOWN = 0
    private const val PHASE_MOVE = 1
    private const val PHASE_UP = 2
    private const val PHASE_CANCEL = 3

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverTouch(
        pid: Long,
        phase: Int,
        x: Double,
        y: Double,
        pointer: Int,
        timestamp: Long,
    )

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun touch_start(pid: Long, throttleMs: Long) {
        val activity = activityRef?.get() ?: return
        this.pid = pid
        this.throttleMs = throttleMs
        this.density = activity.resources.displayMetrics.density
        activity.runOnUiThread { install(activity.window) }
    }

    @JvmStatic
    fun touch_stop() {
        val activity = activityRef?.get() ?: return
        activity.runOnUiThread { restore(activity.window) }
    }

    // ── Window.Callback wrapping (observe, never consume) ──────────────────
    private fun install(window: Window) {
        if (originalCallback != null) return // already streaming
        val original = window.callback ?: return
        originalCallback = original
        val proxy = Proxy.newProxyInstance(
            Window.Callback::class.java.classLoader,
            arrayOf(Window.Callback::class.java),
        ) { _, method, args ->
            if (method.name == "dispatchTouchEvent" && args?.size == 1 && args[0] is MotionEvent) {
                observe(args[0] as MotionEvent)
            }
            // Delegate to the real callback and return its result unchanged, so
            // consumption/dispatch behaviour is identical to not wrapping.
            if (args == null) method.invoke(original) else method.invoke(original, *args)
        } as Window.Callback
        window.callback = proxy
    }

    private fun restore(window: Window) {
        originalCallback?.let { window.callback = it }
        originalCallback = null
        pid = 0
    }

    private fun observe(e: MotionEvent) {
        if (pid == 0L) return
        val now = System.currentTimeMillis()
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val i = e.actionIndex
                deliver(PHASE_DOWN, e.getX(i), e.getY(i), e.getPointerId(i), now)
            }
            MotionEvent.ACTION_MOVE -> {
                if (throttleMs <= 0 || now - lastMoveAt >= throttleMs) {
                    lastMoveAt = now
                    for (i in 0 until e.pointerCount) {
                        deliver(PHASE_MOVE, e.getX(i), e.getY(i), e.getPointerId(i), now)
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val i = e.actionIndex
                deliver(PHASE_UP, e.getX(i), e.getY(i), e.getPointerId(i), now)
            }
            MotionEvent.ACTION_CANCEL -> {
                for (i in 0 until e.pointerCount) {
                    deliver(PHASE_CANCEL, e.getX(i), e.getY(i), e.getPointerId(i), now)
                }
            }
        }
    }

    private fun deliver(phase: Int, xPx: Float, yPx: Float, pointer: Int, ts: Long) {
        nativeDeliverTouch(pid, phase, (xPx / density).toDouble(), (yPx / density).toDouble(), pointer, ts)
    }
}
