package io.github.kyosee.venera

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import kotlin.math.ceil
import kotlin.math.max

class ReadingCoverWidget : ReadingWidgetProvider(true)

class ReadingListWidget : ReadingWidgetProvider(false)

open class ReadingWidgetProvider(private val covers: Boolean) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = ReadingWidgets.load(context)
        ids.forEach { ReadingWidgets.render(context, manager, it, covers, snapshot) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        ReadingWidgets.render(context, manager, id, covers, ReadingWidgets.load(context))
    }
}

data class ReadingWidgetItem(
    val id: String,
    val type: Long,
    val title: String,
    val progress: String,
    val coverPath: String,
) {
    val uri: Uri
        get() = Uri.Builder().scheme("venerax").authority("reading-widget").path("/read")
            .appendQueryParameter("id", id).appendQueryParameter("type", type.toString()).build()
}

data class ReadingWidgetSnapshot(
    val title: String,
    val emptyText: String,
    val items: List<ReadingWidgetItem>,
)

object ReadingWidgets {
    private const val PREFERENCES = "reading_widgets"
    private const val SNAPSHOT = "snapshot"
    private const val MAX_ITEMS = 6
    private const val MAX_IMAGE_SIZE = 256
    private val historyUri = Uri.parse("venerax://reading-widget/history")

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "venera/reading_widget").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasWidgets" -> result.success(
                    providers(appContext).any { (_, ids) -> ids.isNotEmpty() },
                )
                "update" -> {
                    val json = call.arguments as? String
                    if (json == null) {
                        result.error("INVALID_SNAPSHOT", "Reading widget data must be a JSON string.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val snapshot = parse(appContext, json)
                        val stored = preferences(appContext).edit().putString(SNAPSHOT, json).commit()
                        val manager = AppWidgetManager.getInstance(appContext)
                        providers(appContext).forEach { (covers, ids) ->
                            ids.forEach { render(appContext, manager, it, covers, snapshot) }
                        }
                        if (stored) {
                            result.success(null)
                        } else {
                            result.error("WIDGET_STORAGE_FAILED", "Unable to save reading widget data.", null)
                        }
                    } catch (_: Exception) {
                        result.error("WIDGET_UPDATE_FAILED", "Unable to update reading widgets.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private fun providers(context: Context): List<Pair<Boolean, IntArray>> {
        val manager = AppWidgetManager.getInstance(context)
        return listOf(
            true to manager.getAppWidgetIds(ComponentName(context, ReadingCoverWidget::class.java)),
            false to manager.getAppWidgetIds(ComponentName(context, ReadingListWidget::class.java)),
        )
    }

    private fun parse(context: Context, json: String): ReadingWidgetSnapshot {
        val objectValue = JSONObject(json)
        val array = objectValue.getJSONArray("items")
        val items = (0 until minOf(array.length(), MAX_ITEMS)).map { index ->
            val item = array.getJSONObject(index)
            ReadingWidgetItem(
                id = item.getString("id"),
                type = item.getLong("type"),
                title = item.getString("title"),
                progress = item.optString("progress"),
                coverPath = item.optString("coverPath"),
            )
        }.filter { it.id.isNotEmpty() }
        return ReadingWidgetSnapshot(
            title = objectValue.optString("title").ifEmpty { context.getString(R.string.reading_widget_title) },
            emptyText = objectValue.optString("emptyText").ifEmpty { context.getString(R.string.reading_widget_open) },
            items = items,
        )
    }

    fun load(context: Context): ReadingWidgetSnapshot {
        val json = preferences(context).getString(SNAPSHOT, null)
        if (json != null) {
            runCatching { parse(context, json) }.getOrNull()?.let { return it }
        }
        return ReadingWidgetSnapshot(
            context.getString(R.string.reading_widget_title),
            context.getString(R.string.reading_widget_open),
            emptyList(),
        )
    }

    fun render(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        covers: Boolean,
        snapshot: ReadingWidgetSnapshot,
    ) {
        // A provider may restart after settings persisted but before Dart cleared the snapshot.
        val contentAllowed = runCatching {
            !JSONObject(File(context.filesDir, "appdata.json").readText())
                .getJSONObject("settings").optBoolean("authorizationRequired", true)
        }.getOrDefault(false)
        val visible = if (contentAllowed) snapshot else ReadingWidgetSnapshot(
            context.getString(R.string.reading_widget_title),
            context.getString(R.string.reading_widget_open),
            emptyList(),
        )
        val layout = if (covers) R.layout.reading_widget_cover else R.layout.reading_widget_list
        val views = RemoteViews(context.packageName, layout)
        val openHistory = pendingIntent(context, historyUri)
        views.setOnClickPendingIntent(android.R.id.background, openHistory)
        views.setTextViewText(R.id.reading_widget_title, visible.title)
        views.setTextViewText(R.id.reading_widget_empty, visible.emptyText)
        views.removeAllViews(R.id.reading_widget_items)

        val options = manager.getAppWidgetOptions(id)
        val height = options.getInt(
            if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)
                AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
            else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180),
        )
        val fontScale = context.resources.configuration.fontScale
        val rowHeight = max(56, ceil(37 * fontScale + 8).toInt())
        val headerHeight = max(28, ceil(18 * fontScale).toInt())
        val count = if (covers) 2 else ((height - 32 - headerHeight) / rowHeight).coerceIn(1, MAX_ITEMS)
        visible.items.take(count).forEach { item ->
            val child = RemoteViews(
                context.packageName,
                if (covers) R.layout.reading_widget_book else R.layout.reading_widget_row,
            )
            child.setTextViewText(R.id.reading_widget_item_title, item.title)
            child.setTextViewText(R.id.reading_widget_item_progress, item.progress)
            child.setContentDescription(
                R.id.reading_widget_item,
                listOf(item.title, item.progress).filter { it.isNotEmpty() }.joinToString(", "),
            )
            child.setOnClickPendingIntent(R.id.reading_widget_item, pendingIntent(context, item.uri))
            val image = loadCover(context, item.coverPath)
            if (image == null) {
                child.setImageViewResource(R.id.reading_widget_image, R.drawable.reading_widget_placeholder)
            } else {
                child.setImageViewBitmap(R.id.reading_widget_image, image)
            }
            views.addView(R.id.reading_widget_items, child)
        }
        views.setViewVisibility(R.id.reading_widget_items, if (visible.items.isEmpty()) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.reading_widget_empty, if (visible.items.isEmpty()) View.VISIBLE else View.GONE)
        // Full replacement releases old cover bitmaps and removed/private content.
        manager.updateAppWidget(id, views)
    }

    private fun pendingIntent(context: Context, uri: Uri): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, uri, context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // Intent.data is part of PendingIntent identity, even for equal request codes.
        return PendingIntent.getActivity(
            context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun loadCover(context: Context, path: String): Bitmap? = runCatching {
        if (path.isEmpty()) return null
        val file = File(path).canonicalFile
        val roots = listOf(context.filesDir, context.cacheDir, File(context.applicationInfo.dataDir, "app_flutter"))
        if (roots.none { file.path.startsWith(it.canonicalPath + File.separator) } ||
            !file.isFile || file.length() > 4 * 1024 * 1024) return null
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inSampleSize = 1
        while (max(options.outWidth, options.outHeight) / options.inSampleSize > MAX_IMAGE_SIZE) {
            options.inSampleSize *= 2
        }
        options.inJustDecodeBounds = false
        BitmapFactory.decodeFile(file.path, options)
    }.getOrNull()
}
