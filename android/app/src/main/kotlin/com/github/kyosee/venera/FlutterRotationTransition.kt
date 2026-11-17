package io.github.kyosee.venera

import android.app.Activity
import android.os.Build
import android.os.SystemClock
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.renderer.FlutterRenderer

/** Commits a resized SurfaceView only after Flutter has rendered its new size. */
internal class FlutterRotationTransition(
    private val activity: Activity,
    private val renderer: () -> FlutterRenderer?,
) : SurfaceHolder.Callback2 {
    private var surface: FlutterSurfaceView? = null
    private val pending = mutableListOf<Runnable>()
    private var previousWidth = 0
    private var previousHeight = 0

    fun attach() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || surface != null || activity.isDestroyed) return
        val view = activity.findViewById<FlutterView>(FlutterFragment.FLUTTER_VIEW_ID) ?: return
        surface = (0 until view.childCount).map { view.getChildAt(it) }
            .filterIsInstance<FlutterSurfaceView>().firstOrNull()
        surface?.let {
            // The first draw may already be complete when this callback attaches.
            previousWidth = it.width
            previousHeight = it.height
            it.holder.addCallback(this)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {}
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceRedrawNeeded(holder: SurfaceHolder) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { finishPending() }

    override fun surfaceRedrawNeededAsync(holder: SurfaceHolder, drawingFinished: Runnable) {
        val view = surface ?: return drawingFinished.run()
        val width = holder.surfaceFrame.width()
        val height = holder.surfaceFrame.height()
        val rotated = previousWidth > 0 && previousHeight > 0 &&
            (previousWidth > previousHeight) != (width > height)
        val rotationPending = pending.isNotEmpty()
        previousWidth = width
        previousHeight = height
        finishPending()
        if ((!rotated && !rotationPending) || width <= 0 || height <= 0) return drawingFinished.run()
        // An already visible Flutter UI can finish the embedding's redraw callback
        // before the new raster arrives, stretching the previous surface buffer.
        val started = SystemClock.uptimeMillis()
        pending.add(drawingFinished)
        val check = object : Runnable {
            override fun run() {
                if (!pending.contains(drawingFinished)) return
                val frame = try { renderer()?.bitmap } catch (_: RuntimeException) { null }
                val ready = frame == null || (frame.width == width && frame.height == height)
                frame?.recycle()
                if (ready || SystemClock.uptimeMillis() - started > 1000) {
                    pending.remove(drawingFinished)
                    drawingFinished.run()
                } else {
                    view.postDelayed(this, 32)
                }
            }
        }
        view.postOnAnimation(check)
    }

    private fun finishPending() {
        val callbacks = pending.toList()
        pending.clear()
        callbacks.forEach(Runnable::run)
    }

    fun dispose() {
        surface?.holder?.removeCallback(this)
        finishPending()
        surface = null
    }
}
