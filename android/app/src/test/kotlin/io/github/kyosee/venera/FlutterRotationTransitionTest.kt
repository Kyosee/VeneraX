package io.github.kyosee.venera

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Looper
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.renderer.FlutterRenderer
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.*
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class FlutterRotationTransitionTest {
    private lateinit var activity: Activity
    private lateinit var renderer: FlutterRenderer
    private lateinit var transition: FlutterRotationTransition
    private val holder = mock(SurfaceHolder::class.java)

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val view = FlutterView(activity, FlutterSurfaceView(activity))
        view.id = FlutterFragment.FLUTTER_VIEW_ID
        activity.setContentView(view)
        renderer = mock(FlutterRenderer::class.java)
        transition = FlutterRotationTransition(activity) { renderer }
        transition.attach()
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 300, 600))
        transition.surfaceRedrawNeededAsync(holder, Runnable {})
    }

    @After
    fun tearDown() { transition.dispose() }

    @Test
    fun rotationWaitsForMatchingRasterSizeAndReleasesBitmaps() {
        val old = Bitmap.createBitmap(300, 600, Bitmap.Config.ARGB_8888)
        val resized = Bitmap.createBitmap(600, 300, Bitmap.Config.ARGB_8888)
        `when`(renderer.bitmap).thenReturn(old, resized)
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var finishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        assertEquals(0, finishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
        assertTrue(old.isRecycled)
        assertEquals(0, finishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(40))
        assertEquals(1, finishes)
        assertTrue(resized.isRecycled)
    }

    @Test
    fun ordinaryResizeDoesNotCaptureAndDisposalCompletesPendingDraw() {
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 300, 500))
        var finishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        assertEquals(1, finishes)
        verifyNoInteractions(renderer)
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        transition.dispose()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertEquals(2, finishes)
        verifyNoInteractions(renderer)
    }

    @Test
    fun missingCaptureNeverBlocksTheWindow() {
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var finishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        assertEquals(1, finishes)
    }

    @Test
    fun insetResizeDuringRotationStillWaitsForMatchingFrame() {
        val old = Bitmap.createBitmap(300, 600, Bitmap.Config.ARGB_8888)
        val resized = Bitmap.createBitmap(600, 280, Bitmap.Config.ARGB_8888)
        `when`(renderer.bitmap).thenReturn(old, resized)
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var finishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 280))
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        assertEquals(1, finishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
        assertEquals(1, finishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(40))
        assertEquals(2, finishes)
        assertTrue(old.isRecycled)
        assertTrue(resized.isRecycled)
    }

    @Test
    fun firstRotationAfterLateAttachmentStillWaitsForNewSize() {
        transition.dispose()
        val view = activity.findViewById<FlutterView>(FlutterFragment.FLUTTER_VIEW_ID)
        view.getChildAt(0).layout(0, 0, 300, 600)
        transition.attach()
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var finishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { finishes++ })
        assertEquals(0, finishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        assertEquals(1, finishes)
    }

    @Test
    fun stalledRendererTimesOutAndSupersededDrawCompletesOnlyOnce() {
        `when`(renderer.bitmap).thenAnswer {
            Bitmap.createBitmap(300, 600, Bitmap.Config.ARGB_8888)
        }
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var firstFinishes = 0
        var secondFinishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { firstFinishes++ })
        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 300, 600))
        transition.surfaceRedrawNeededAsync(holder, Runnable { secondFinishes++ })
        assertEquals(1, firstFinishes)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        assertEquals(1, secondFinishes)

        `when`(holder.surfaceFrame).thenReturn(Rect(0, 0, 600, 300))
        var stalledFinishes = 0
        transition.surfaceRedrawNeededAsync(holder, Runnable { stalledFinishes++ })
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertEquals(1, stalledFinishes)
        transition.surfaceDestroyed(holder)
        transition.dispose()
        assertEquals(1, firstFinishes)
        assertEquals(1, secondFinishes)
        assertEquals(1, stalledFinishes)
    }
}
