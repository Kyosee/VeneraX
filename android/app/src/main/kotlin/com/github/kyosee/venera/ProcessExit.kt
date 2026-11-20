package io.github.kyosee.venera

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/**
 * What the system recorded about the last time this app's main process ended.
 * It is the only account of a native crash: the process is gone before the app
 * can write anything itself.
 */
object ProcessExit {
    // A tombstone leads with the signal and the thread stacks, an ANR trace with
    // the main thread; what follows is memory maps, logs and the other threads.
    private const val MAX_TRACE_BYTES = 512 * 1024

    /** Null before Android 11, or when nothing is on record. */
    fun last(context: Context, withTrace: Boolean): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null
        val info = manager.getHistoricalProcessExitReasons(context.packageName, 0, 8)
            .firstOrNull { it.processName == context.packageName } ?: return null
        return mapOf(
            "kind" to kind(info.reason),
            "name" to name(info.reason),
            "reason" to info.reason,
            "description" to (info.description ?: ""),
            "at" to info.timestamp,
            "format" to if (info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) "tombstone" else "text",
            "trace" to if (withTrace) trace(info) else null,
        )
    }

    /**
     * "crash" settles that the process failed and "ended" that it was closed on
     * purpose. "other" is the system reclaiming it, which says nothing either
     * way.
     */
    private fun kind(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH,
        ApplicationExitInfo.REASON_CRASH_NATIVE,
        ApplicationExitInfo.REASON_ANR,
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "crash"

        ApplicationExitInfo.REASON_EXIT_SELF,
        ApplicationExitInfo.REASON_USER_REQUESTED,
        ApplicationExitInfo.REASON_USER_STOPPED,
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "ended"

        else -> "other"
    }

    private fun name(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        else -> "UNKNOWN"
    }

    private fun trace(info: ApplicationExitInfo): ByteArray? = runCatching {
        info.traceInputStream?.use { stream ->
            val buffer = ByteArray(MAX_TRACE_BYTES)
            var total = 0
            while (total < buffer.size) {
                val read = stream.read(buffer, total, buffer.size - total)
                if (read < 0) break
                total += read
            }
            buffer.copyOf(total)
        }
    }.getOrNull()
}
