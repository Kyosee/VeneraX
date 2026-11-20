package io.github.kyosee.venera

import org.junit.Assert.*
import org.junit.Test

class ProcessExitTest {
    private data class Record(val pid: Int, val reason: String)

    private fun cause(vararg records: Record) = ProcessExit.cause(records.toList()) { it.pid }

    @Test
    fun theLatestProcessIsTheOneReported() {
        assertEquals(
            Record(7, "crash"),
            cause(Record(7, "crash"), Record(5, "user requested"), Record(3, "low memory")),
        )
        assertNull(cause())
    }

    @Test
    fun aProcessClearedAwayAfterItCrashedIsReportedAsTheCrash() {
        // Kept alive behind the "keeps stopping" dialog, then killed as cached.
        assertEquals(
            Record(7, "crash"),
            cause(Record(7, "excessive resource usage"), Record(7, "crash"), Record(5, "crash")),
        )
    }

    @Test
    fun anOlderProcessWithTheSamePidIsNotTakenForTheLatest() {
        assertEquals(
            Record(7, "user requested"),
            cause(Record(7, "user requested"), Record(5, "crash"), Record(7, "crash")),
        )
    }
}
