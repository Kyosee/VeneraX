package io.github.kyosee.venera

import android.content.Context
import android.os.Process
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import kotlin.system.exitProcess

/**
 * Keeps the stack of the uncaught Java exception that ends the process, for
 * the next launch's crash report: the system's own exit record says no more
 * than that the app crashed, and before Android 11 there is none at all.
 *
 * The first two lines match what the desktop hosts write, so the app reads
 * both the same way.
 */
object UncaughtExceptionRecord {
    private const val FILE_NAME = "uncaught_exception.txt"
    private const val MAX_REASON_CHARS = 300
    private const val MAX_RECORD_BYTES = 32 * 1024
    private const val MAX_READ_BYTES = 64 * 1024

    private var installed = false

    /** Safe to call from every entry point; only the first call does anything. */
    fun install(context: Context) {
        try {
            synchronized(this) {
                if (installed) return
                installed = true
            }
            // Worked out now: a crashing process should not have to ask the
            // context for anything.
            val file = File(context.applicationContext.filesDir, FILE_NAME)
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                try {
                    file.writeText(format(System.currentTimeMillis(), thread.name, error))
                } catch (_: Throwable) {
                }
                if (previous != null) {
                    previous.uncaughtException(thread, error)
                } else {
                    Process.killProcess(Process.myPid())
                    exitProcess(10)
                }
            }
        } catch (_: Throwable) {
        }
    }

    fun format(time: Long, thread: String, error: Throwable): String {
        val message = error.message?.lineSequence()?.firstOrNull()?.take(MAX_REASON_CHARS)
        val reason = if (message.isNullOrEmpty()) error.javaClass.name else "${error.javaClass.name}: $message"
        val stack = StringWriter()
        PrintWriter(stack).use { error.printStackTrace(it) }
        return truncate("time=$time\nreason=$reason\nthread=$thread\n$stack", MAX_RECORD_BYTES)
    }

    /** Reads the record and removes it, so that it never speaks for a later process. */
    fun take(context: Context): String? {
        val file = try {
            File(context.applicationContext.filesDir, FILE_NAME)
        } catch (_: Throwable) {
            return null
        }
        return try {
            if (!file.isFile) return null
            file.inputStream().use { stream ->
                val buffer = ByteArray(MAX_READ_BYTES)
                var total = 0
                while (total < buffer.size) {
                    val read = stream.read(buffer, total, buffer.size - total)
                    if (read < 0) break
                    total += read
                }
                String(buffer, 0, total, Charsets.UTF_8)
            }
        } catch (_: Throwable) {
            null
        } finally {
            try {
                file.delete()
            } catch (_: Throwable) {
            }
        }
    }

    private fun truncate(text: String, maxBytes: Int): String {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var end = maxBytes
        // Back up to the start of a character rather than split one.
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
        return String(bytes, 0, end, Charsets.UTF_8)
    }
}
