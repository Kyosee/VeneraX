package io.github.kyosee.venera

import android.appwidget.AppWidgetManager
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import android.widget.RemoteViews
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.Mockito.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ReadingWidgetsTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val snapshot = ReadingWidgetSnapshot(
        "Latest check", "No updates", (1..6).map {
            ReadingWidgetItem("book$it", 1, "Sample book $it", "Chapter 2", "", badge = "New")
        }, ReadingKind.UPDATES, "Last checked today",
    )

    @Before
    fun setUp() {
        context.getSharedPreferences("reading_widgets", Context.MODE_PRIVATE)
            .edit().clear().putBoolean("locked", false).commit()
        File(context.filesDir, "appdata.json").writeText("{\"settings\":{\"authorizationRequired\":false}}")
    }

    private fun render(height: Int, covers: Boolean = false, data: ReadingWidgetSnapshot = snapshot): View {
        val manager = mock(AppWidgetManager::class.java)
        val options = Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 320)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, height)
        }
        `when`(manager.getAppWidgetOptions(anyInt())).thenReturn(options)
        ReadingWidgets.render(context, manager, 1, covers, data)
        val captor = ArgumentCaptor.forClass(RemoteViews::class.java)
        verify(manager).updateAppWidget(eq(1), captor.capture())
        return captor.value.apply(context, null)
    }

    @Test
    fun listUsesAvailableHeightAndResizesWithoutClippingRows() {
        for ((height, count) in listOf(180 to 1, 300 to 3, 440 to 5)) {
            val view = render(height)
            val items = view.findViewById<LinearLayout>(R.id.reading_widget_items)
            assertEquals(count, items.childCount)
            val density = context.resources.displayMetrics.density
            view.measure(View.MeasureSpec.makeMeasureSpec((320 * density).toInt(), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec((height * density).toInt(), View.MeasureSpec.EXACTLY))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            assertTrue("Rows fit within the card", items.bottom <= view.height - view.paddingBottom)
        }
    }

    @Test
    fun wideCoverCardShowsThreeBooks() {
        assertEquals(3, render(300, covers = true).findViewById<LinearLayout>(R.id.reading_widget_items).childCount)
    }

    @Test
    fun missingSettingsAndLockedSnapshotsNeverShowBooks() {
        assertEquals(0, render(300, data = snapshot.copy(locked = true))
            .findViewById<LinearLayout>(R.id.reading_widget_items).childCount)
        File(context.filesDir, "appdata.json").delete()
        assertEquals(0, render(300).findViewById<LinearLayout>(R.id.reading_widget_items).childCount)
    }

    @Test
    fun privacyChangeDuringDeliveryClearsTheInFlightContent() {
        val manager = mock(AppWidgetManager::class.java)
        `when`(manager.getAppWidgetOptions(anyInt())).thenReturn(Bundle())
        val delivered = mutableListOf<RemoteViews>()
        doAnswer { invocation ->
            delivered.add(invocation.getArgument(1))
            context.getSharedPreferences("reading_widgets", Context.MODE_PRIVATE)
                .edit().putBoolean("locked", true).commit()
            null
        }.`when`(manager).updateAppWidget(eq(1), any(RemoteViews::class.java))
        ReadingWidgets.render(context, manager, 1, false, snapshot)
        assertEquals(2, delivered.size)
        assertEquals(0, delivered.last().apply(context, null)
            .findViewById<LinearLayout>(R.id.reading_widget_items).childCount)
    }

    @Test
    fun publicationUsesFlutterBackgroundTaskQueue() {
        val messenger = mock(BinaryMessenger::class.java)
        val queue = mock(BinaryMessenger.TaskQueue::class.java)
        `when`(messenger.makeBackgroundTaskQueue()).thenReturn(queue)
        ReadingWidgets.register(context, messenger)
        verify(messenger).setMessageHandler(eq("venera/reading_widget"), any(), eq(queue))
    }
}
