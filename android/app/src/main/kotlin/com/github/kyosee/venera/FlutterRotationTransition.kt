package io.github.kyosee.venera

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.view.PixelCopy
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.embedding.engine.renderer.FlutterUiResizeListener

/** Commits a resized SurfaceView only after Flutter has rendered its new size. */
internal class FlutterRotationTransition(
    private val activity: Activity,
    private val renderer: () -> FlutterRenderer?,
    private val probe: (FlutterSurfaceView, Int, Int, (Boolean) -> Unit) -> Unit = ::probeFrameCorner,
) : SurfaceHolder.Callback2, FlutterUiResizeListener {
    private var surface: FlutterSurfaceView? = null
    private val pending = mutableListOf<Runnable>()
    private var previousWidth = 0
    private var previousHeight = 0
    private var attachedRenderer: FlutterRenderer? = null
    private var rasterWidth = 0
    private var rasterHeight = 0
    private var check: Runnable? = null
    private var timeout: Runnable? = null

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
            attachedRenderer = renderer()
            attachedRenderer?.addResizingFlutterUiListener(this)
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
        pending.add(drawingFinished)
        var copying = false
        val readyCheck = object : Runnable {
            override fun run() {
                if (!pending.contains(drawingFinished) || copying ||
                    rasterWidth != width || rasterHeight != height) return
                copying = true
                probe(view, width, height) { ready ->
                    copying = false
                    if (!pending.contains(drawingFinished)) return@probe
                    if (ready) finishPending() else view.postDelayed(this, 32)
                }
            }
        }
        check = readyCheck
        timeout = Runnable { finishPending() }.also { view.postDelayed(it, 1000) }
        view.postOnAnimation(readyCheck)
    }

    override fun resizeEngineView(width: Int, height: Int) {
        rasterWidth = width
        rasterHeight = height
        check?.let { surface?.postOnAnimation(it) }
    }

    private fun finishPending() {
        check?.let { surface?.removeCallbacks(it) }
        timeout?.let { surface?.removeCallbacks(it) }
        check = null
        timeout = null
        val callbacks = pending.toList()
        pending.clear()
        callbacks.forEach(Runnable::run)
    }

    fun dispose() {
        attachedRenderer?.removeResizingFlutterUiListener(this)
        attachedRenderer = null
        surface?.holder?.removeCallback(this)
        finishPending()
        surface = null
        rasterWidth = 0
        rasterHeight = 0
    }
}

private fun probeFrameCorner(view: FlutterSurfaceView, width: Int, height: Int, complete: (Boolean) -> Unit) {
    // A new-size frame may still be rasterizing when the resize callback arrives.
    // The old orientation cannot contain the new bottom-right pixel. Copy one
    // pixel asynchronously instead of reading the entire GPU frame on the UI thread.
    val pixel = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
    try {
        PixelCopy.request(view, Rect(width - 1, height - 1, width, height), pixel, { result ->
            pixel.recycle()
            complete(result == PixelCopy.SUCCESS)
        }, Handler(view.handler.looper))
    } catch (_: IllegalArgumentException) {
        pixel.recycle()
        complete(false)
    }
}
