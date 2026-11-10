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
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import kotlin.math.ceil
import kotlin.math.max

enum class ReadingKind(val key: String, val titleResource: Int, val iconResource: Int) {
    HISTORY("history", R.string.reading_widget_title, R.drawable.reading_widget_history),
    FOLLOWING("following", R.string.reading_widget_following, R.drawable.reading_widget_following),
    UPDATES("updates", R.string.reading_widget_updates, R.drawable.reading_widget_updates),
    LOCAL("local", R.string.reading_widget_local, R.drawable.reading_widget_local);

    val uri: Uri get() = Uri.parse("venerax://reading-widget/$key")
}

class ReadingCoverWidget : ReadingWidgetProvider(ReadingKind.HISTORY, true)
class ReadingListWidget : ReadingWidgetProvider(ReadingKind.HISTORY, false)
class FollowingCoverWidget : ReadingWidgetProvider(ReadingKind.FOLLOWING, true)
class FollowingListWidget : ReadingWidgetProvider(ReadingKind.FOLLOWING, false)
class UpdatesCoverWidget : ReadingWidgetProvider(ReadingKind.UPDATES, true)
class UpdatesListWidget : ReadingWidgetProvider(ReadingKind.UPDATES, false)
class LocalCoverWidget : ReadingWidgetProvider(ReadingKind.LOCAL, true)
class LocalListWidget : ReadingWidgetProvider(ReadingKind.LOCAL, false)

open class ReadingWidgetProvider(private val kind: ReadingKind, private val covers: Boolean) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = ReadingWidgets.load(context, kind)
        ids.forEach { ReadingWidgets.render(context, manager, it, covers, snapshot) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        ReadingWidgets.render(context, manager, id, covers, ReadingWidgets.load(context, kind))
    }
}

data class ReadingWidgetItem(
    val id: String,
    val type: Long,
    val title: String,
    val progress: String,
    val coverPath: String,
    val sourceName: String = "",
    val badge: String = "",
    val pageProgress: Int = -1,
) {
    fun uri(kind: ReadingKind): Uri = Uri.Builder().scheme("venerax").authority("reading-widget")
            .path(if (kind == ReadingKind.HISTORY) "/read" else "/${kind.key}/read")
            .appendQueryParameter("id", id).appendQueryParameter("type", type.toString()).build()
}

data class ReadingWidgetSnapshot(
    val title: String,
    val emptyText: String,
    val items: List<ReadingWidgetItem>,
    val kind: ReadingKind,
    val subtitle: String = "",
    val locked: Boolean = false,
)

object ReadingWidgets {
    private const val PREFERENCES = "reading_widgets"
    private const val SNAPSHOT = "snapshot"
    private const val MAX_ITEMS = 6
    private const val MAX_IMAGE_SIZE = 256

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "venera/reading_widget").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasWidgets" -> result.success(
                    providers(appContext).any { (kind, _, ids) -> kind.key == call.arguments && ids.isNotEmpty() },
                )
                "update" -> {
                    val json = call.arguments as? String
                    if (json == null) {
                        result.error("INVALID_SNAPSHOT", "Reading widget data must be a JSON string.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val snapshot = parse(appContext, json)
                        val wasLocked = preferences(appContext).getBoolean("locked", true)
                        val editor = preferences(appContext).edit()
                        if (snapshot.locked || wasLocked) {
                            ReadingKind.entries.forEach { editor.remove("${SNAPSHOT}_${it.key}") }
                        }
                        if (!snapshot.locked) editor.putString("${SNAPSHOT}_${snapshot.kind.key}", json)
                        val stored = editor.putBoolean("locked", snapshot.locked).commit()
                        val manager = AppWidgetManager.getInstance(appContext)
                        providers(appContext).forEach { (kind, covers, ids) ->
                            if (kind == snapshot.kind || snapshot.locked || wasLocked) {
                                val data = if (kind == snapshot.kind) snapshot else load(appContext, kind)
                                ids.forEach { render(appContext, manager, it, covers, data) }
                            }
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

    private fun providers(context: Context): List<Triple<ReadingKind, Boolean, IntArray>> {
        val manager = AppWidgetManager.getInstance(context)
        return listOf(
            Triple(ReadingKind.HISTORY, true, ReadingCoverWidget::class.java),
            Triple(ReadingKind.HISTORY, false, ReadingListWidget::class.java),
            Triple(ReadingKind.FOLLOWING, true, FollowingCoverWidget::class.java),
            Triple(ReadingKind.FOLLOWING, false, FollowingListWidget::class.java),
            Triple(ReadingKind.UPDATES, true, UpdatesCoverWidget::class.java),
            Triple(ReadingKind.UPDATES, false, UpdatesListWidget::class.java),
            Triple(ReadingKind.LOCAL, true, LocalCoverWidget::class.java),
            Triple(ReadingKind.LOCAL, false, LocalListWidget::class.java),
        ).map { (kind, covers, type) -> Triple(kind, covers, manager.getAppWidgetIds(ComponentName(context, type))) }
    }

    private fun parse(context: Context, json: String): ReadingWidgetSnapshot {
        val objectValue = JSONObject(json)
        val kind = ReadingKind.entries.first { it.key == objectValue.getString("kind") }
        val array = objectValue.getJSONArray("items")
        val items = (0 until minOf(array.length(), MAX_ITEMS)).map { index ->
            val item = array.getJSONObject(index)
            ReadingWidgetItem(
                id = item.getString("id"),
                type = item.getLong("type"),
                title = item.getString("title"),
                progress = item.optString("progress"),
                coverPath = item.optString("coverPath"),
                sourceName = item.optString("sourceName"),
                badge = item.optString("badge"),
                pageProgress = item.optInt("pageProgress", -1).takeIf { it in 0..100 } ?: -1,
            )
        }.filter { it.id.isNotEmpty() }
        return ReadingWidgetSnapshot(
            title = objectValue.optString("title").ifEmpty { context.getString(kind.titleResource) },
            emptyText = objectValue.optString("emptyText").ifEmpty { context.getString(R.string.reading_widget_open) },
            items = items,
            kind = kind,
            subtitle = objectValue.optString("subtitle"),
            locked = objectValue.optBoolean("locked"),
        )
    }

    fun load(context: Context, kind: ReadingKind): ReadingWidgetSnapshot {
        val json = preferences(context).getString("${SNAPSHOT}_${kind.key}", null)
        if (json != null) {
            runCatching { parse(context, json) }.getOrNull()?.let { return it }
        }
        return ReadingWidgetSnapshot(
            context.getString(kind.titleResource),
            context.getString(R.string.reading_widget_open),
            emptyList(),
            kind,
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
        val visible = if (contentAllowed && !preferences(context).getBoolean("locked", true)) snapshot else ReadingWidgetSnapshot(
            context.getString(snapshot.kind.titleResource),
            context.getString(R.string.reading_widget_open),
            emptyList(),
            snapshot.kind,
        )
        val layout = if (covers) R.layout.reading_widget_cover else R.layout.reading_widget_list
        val views = RemoteViews(context.packageName, layout)
        val openList = pendingIntent(context, visible.kind.uri)
        views.setOnClickPendingIntent(android.R.id.background, openList)
        views.setOnClickPendingIntent(R.id.reading_widget_header, openList)
        views.setImageViewResource(R.id.reading_widget_kind_icon, visible.kind.iconResource)
        views.setTextViewText(R.id.reading_widget_title, visible.title)
        views.setTextViewText(R.id.reading_widget_empty, visible.emptyText)
        views.setTextViewText(R.id.reading_widget_subtitle, visible.subtitle)
        views.removeAllViews(R.id.reading_widget_items)

        val options = manager.getAppWidgetOptions(id)
        val landscape = context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val width = options.getInt(
            if (landscape) AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH else AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH,
            if (covers) 180 else 250,
        ).takeIf { it > 0 } ?: 180
        val height = options.getInt(
            if (landscape) AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180),
        ).takeIf { it > 0 } ?: 180
        val fontScale = context.resources.configuration.fontScale
        val showSubtitle = visible.subtitle.isNotEmpty() && height >= 200
        val showSource = width >= 240 && height >= 260
        val titleLines = if (height < 240 || width < 220) 1 else 2
        val headerHeight = max(32, ceil(18 * fontScale + 4).toInt()) +
                if (showSubtitle) ceil(14 * fontScale + 2).toInt() else 0
        val hasMetadata = showSource || visible.items.any { it.badge.isNotEmpty() }
        val rowHeight = max(66, ceil((17 * titleLines + 14 + if (hasMetadata) 14 else 0) * fontScale + 21).toInt())
        val count = if (covers) 2 else ((height - 32 - headerHeight) / rowHeight).coerceIn(1, MAX_ITEMS)
        val coverTextHeight = ceil((16 * titleLines + 13 + if (showSource) 12 else 0) * fontScale + 20).toInt()
        val coverHeight = minOf(160, ((width - 40) / 2f / 0.72f).toInt(), height - 32 - headerHeight - coverTextHeight)
            .coerceAtLeast(28)
        views.setViewVisibility(R.id.reading_widget_subtitle, if (showSubtitle) View.VISIBLE else View.GONE)
        visible.items.take(count).forEach { item ->
            val child = RemoteViews(
                context.packageName,
                if (covers) R.layout.reading_widget_book else R.layout.reading_widget_row,
            )
            child.setTextViewText(R.id.reading_widget_item_title, item.title)
            child.setInt(R.id.reading_widget_item_title, "setMaxLines", titleLines)
            child.setTextViewText(R.id.reading_widget_item_progress, item.progress.ifEmpty {
                context.getString(R.string.reading_widget_continue)
            })
            child.setTextViewText(R.id.reading_widget_item_source, item.sourceName)
            child.setViewVisibility(R.id.reading_widget_item_source, if (showSource && item.sourceName.isNotEmpty()) View.VISIBLE else View.GONE)
            child.setTextViewText(R.id.reading_widget_item_badge, item.badge)
            child.setViewVisibility(R.id.reading_widget_item_badge, if (item.badge.isEmpty()) View.GONE else View.VISIBLE)
            child.setViewVisibility(R.id.reading_widget_item_bar, if (item.pageProgress >= 0) View.VISIBLE else View.GONE)
            child.setProgressBar(R.id.reading_widget_item_bar, 100, item.pageProgress.coerceAtLeast(0), false)
            if (covers) {
                // Bound the artwork independently from the launcher's tall widget canvas.
                child.setInt(R.id.reading_widget_image, "setMaxHeight", (coverHeight * context.resources.displayMetrics.density).toInt())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    child.setViewLayoutWidth(R.id.reading_widget_cover_frame, coverHeight * 0.72f, TypedValue.COMPLEX_UNIT_DIP)
                    child.setViewLayoutHeight(R.id.reading_widget_image, coverHeight.toFloat(), TypedValue.COMPLEX_UNIT_DIP)
                }
            }
            child.setContentDescription(
                R.id.reading_widget_item,
                listOf(item.title, item.progress, item.sourceName, item.badge,
                    if (item.pageProgress >= 0) context.getString(R.string.reading_widget_chapter_progress, item.pageProgress) else "",
                ).filter { it.isNotEmpty() }.joinToString(", "),
            )
            child.setOnClickPendingIntent(R.id.reading_widget_item, pendingIntent(context, item.uri(visible.kind)))
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
