package io.github.kyosee.venera

import android.app.Activity
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/** Launcher long-press menu. A tap comes back as a notification route. */
object AppShortcuts {
    private val icons = mapOf(
        "favorites" to R.drawable.shortcut_favorites,
        "follow_updates" to R.drawable.shortcut_follow_updates,
        "history" to R.drawable.shortcut_history,
        "search" to R.drawable.shortcut_search,
    )

    /** [items] are `{route, label}` maps in display order. */
    fun publish(activity: Activity, items: List<*>): Boolean {
        // Bind to the launcher alias enabled right now: the system drops dynamic
        // shortcuts whose alias gets disabled by an icon switch.
        val launcher = activity.packageManager
            .getLaunchIntentForPackage(activity.packageName)?.component
        val shortcuts = items.mapNotNull { it as? Map<*, *> }.mapNotNull { item ->
            val route = item["route"] as? String ?: return@mapNotNull null
            val icon = icons[route] ?: return@mapNotNull null
            val label = (item["label"] as? String)?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            // Same flags as notification taps: reuse the running activity.
            val intent = Intent(activity, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(MainActivity.EXTRA_NOTIFICATION_ROUTE, route)
            ShortcutInfoCompat.Builder(activity, route)
                .setShortLabel(label)
                .setLongLabel(label)
                .setIcon(IconCompat.createWithResource(activity, icon))
                .setIntent(intent)
                .apply { if (launcher != null) setActivity(launcher) }
        }.mapIndexed { rank, builder -> builder.setRank(rank).build() }
        return ShortcutManagerCompat.setDynamicShortcuts(activity, shortcuts)
    }
}
