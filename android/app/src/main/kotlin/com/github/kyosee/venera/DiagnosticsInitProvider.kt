package io.github.kyosee.venera

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri

/**
 * Created before any activity, service or widget receiver, so that a crash in
 * any of them is recorded. Must stay this small: whatever runs here delays
 * every start of the process.
 */
class DiagnosticsInitProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.let { UncaughtExceptionRecord.install(it) }
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
