package io.github.kyosee.venera

import android.content.Context
import java.io.File
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class UncaughtExceptionRecordTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val record: File get() = File(context.filesDir, "uncaught_exception.txt")

    @After
    fun tearDown() {
        record.delete()
    }

    @Test
    fun recordStartsWithTimeReasonAndThreadThenTheStack() {
        val error = IllegalStateException("no view\nsecond line")
        val text = UncaughtExceptionRecord.format(1700000000400, "main", error)
        val lines = text.lines()
        assertEquals("time=1700000000400", lines[0])
        assertEquals("reason=java.lang.IllegalStateException: no view", lines[1])
        assertEquals("thread=main", lines[2])
        assertEquals("java.lang.IllegalStateException: no view", lines[3])
        assertEquals("second line", lines[4])
        assertTrue(lines[5].trimStart().startsWith("at io.github.kyosee.venera.UncaughtExceptionRecordTest"))
    }

    @Test
    fun reasonIsTheClassNameAloneWithoutMessage() {
        val text = UncaughtExceptionRecord.format(1, "worker", NullPointerException())
        assertEquals("reason=java.lang.NullPointerException", text.lines()[1])
        val blank = UncaughtExceptionRecord.format(1, "worker", RuntimeException("\nbelow"))
        assertEquals("reason=java.lang.RuntimeException", blank.lines()[1])
    }

    @Test
    fun stackIncludesTheCause() {
        val cause = java.io.IOException("disk full")
        val text = UncaughtExceptionRecord.format(1, "main", RuntimeException("save failed", cause))
        assertTrue(text.contains("\nCaused by: java.io.IOException: disk full"))
    }

    @Test
    fun longMessagesAndStacksAreCut() {
        val text = UncaughtExceptionRecord.format(1, "main", RuntimeException("界".repeat(12000)))
        val reason = text.lines()[1]
        assertEquals("reason=java.lang.RuntimeException: " + "界".repeat(300), reason)
        val bytes = text.toByteArray(Charsets.UTF_8)
        assertTrue(bytes.size <= 32 * 1024)
        assertTrue(bytes.size > 32 * 1024 - 3)
        // Cut between characters, not inside one.
        assertFalse(text.contains('�'))
        assertTrue(text.endsWith("界"))
    }

    @Test
    fun takeReadsTheRecordOnceAndRemovesIt() {
        record.writeText("time=1\nreason=java.lang.Error\n")
        assertEquals("time=1\nreason=java.lang.Error\n", UncaughtExceptionRecord.take(context))
        assertFalse(record.exists())
        assertNull(UncaughtExceptionRecord.take(context))
    }

    @Test
    fun takeGivesNothingWithoutARecord() {
        assertFalse(record.exists())
        assertNull(UncaughtExceptionRecord.take(context))
    }

    @Test
    fun takeReadsNoMoreThan64Kilobytes() {
        record.writeText("x".repeat(100 * 1024))
        assertEquals(64 * 1024, UncaughtExceptionRecord.take(context)?.length)
        assertFalse(record.exists())
    }

    @Test
    fun installedHandlerRecordsTheExceptionThenHandsItOn() {
        val original = Thread.getDefaultUncaughtExceptionHandler()
        val handed = mutableListOf<Throwable>()
        Thread.setDefaultUncaughtExceptionHandler { _, error -> handed += error }
        try {
            UncaughtExceptionRecord.install(context)
            val installed = Thread.getDefaultUncaughtExceptionHandler()
            UncaughtExceptionRecord.install(context)
            assertSame(installed, Thread.getDefaultUncaughtExceptionHandler())

            val error = IllegalArgumentException("bad page")
            installed!!.uncaughtException(Thread.currentThread(), error)
            assertEquals(listOf<Throwable>(error), handed)
            val text = UncaughtExceptionRecord.take(context)!!
            assertTrue(text.startsWith("time="))
            assertEquals("reason=java.lang.IllegalArgumentException: bad page", text.lines()[1])
            assertEquals("thread=${Thread.currentThread().name}", text.lines()[2])
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(original)
        }
    }
}
