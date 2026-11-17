package io.github.kyosee.venera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.Context
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.common.FlutterException
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class FollowUpdatesSchedulerTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val jobs: JobScheduler get() = context.getSystemService(JobScheduler::class.java)
    private val notifications: NotificationManager
        get() = context.getSystemService(NotificationManager::class.java)

    @Before
    fun setUp() {
        resetScheduler()
        jobs.cancelAll()
        notifications.cancelAll()
        shadowOf(notifications).setNotificationsEnabled(true)
    }

    @After
    fun tearDown() {
        FollowUpdatesScheduler.execution?.finish(false)
        resetScheduler()
        FlutterInjector.reset()
        jobs.cancelAll()
        notifications.cancelAll()
    }

    @Test
    fun scheduleIsPersistentAndConstrained() {
        FollowUpdatesScheduler.configure(context, true)
        val job = jobs.allPendingJobs.single()
        assertEquals(FollowUpdatesScheduler.JOB_ID, job.id)
        assertEquals(FollowUpdatesJobService::class.java.name, job.service.className)
        assertTrue(job.isPersisted)
        assertTrue(job.isPeriodic)
        assertEquals(15 * 60 * 1000L, job.intervalMillis)
        assertEquals(JobInfo.NETWORK_TYPE_ANY, job.networkType)
        assertTrue(job.isRequireBatteryNotLow)
        assertEquals(JobInfo.BACKOFF_POLICY_LINEAR, job.backoffPolicy)
    }

    @Test
    fun repeatedSyncKeepsExistingJobWithoutResettingItsPeriod() {
        FollowUpdatesScheduler.configure(context, true)
        val original = jobs.allPendingJobs.single()
        repeat(3) { FollowUpdatesScheduler.configure(context, true) }
        assertSame(original, jobs.allPendingJobs.single())
    }

    @Test
    fun disablingCancelsScheduleAndRequestsOneStop() {
        FollowUpdatesScheduler.configure(context, true)
        val messenger = TestMessenger()
        val results = mutableListOf<Boolean>()
        val run = uiExecution(messenger, results)
        FollowUpdatesScheduler.configure(context, false)
        FollowUpdatesScheduler.configure(context, false)
        assertTrue(jobs.allPendingJobs.isEmpty())
        assertEquals(listOf("stop"), messenger.calls.map { it.method })
        assertSame(run, FollowUpdatesScheduler.execution)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))
        assertNull(FollowUpdatesScheduler.execution)
        assertEquals(listOf(true), results)
    }

    @Test
    fun overlappingJobCannotReplaceAnActiveExecution() {
        val run = uiExecution(TestMessenger(), mutableListOf())
        assertNull(FollowUpdatesScheduler.start(context) { fail("Overlapping job ran") })
        assertSame(run, FollowUpdatesScheduler.execution)
    }

    @Test
    fun uiCheckCompletesOnlyAfterDartReplies() {
        val messenger = TestMessenger()
        val results = mutableListOf<Boolean>()
        val run = uiExecution(messenger, results)
        run.start()
        assertEquals(listOf("check"), messenger.calls.map { it.method })
        assertTrue(results.isEmpty())
        assertSame(run, FollowUpdatesScheduler.execution)
        messenger.replySuccess()
        assertEquals(listOf(false), results)
        assertNull(FollowUpdatesScheduler.execution)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(3))
        assertEquals(listOf(false), results)
    }

    @Test
    fun missingDartHandlerRequestsRetry() {
        val messenger = TestMessenger()
        val results = mutableListOf<Boolean>()
        uiExecution(messenger, results).start()
        messenger.replyNotImplemented()
        assertEquals(listOf(true), results)
        assertNull(FollowUpdatesScheduler.execution)
    }

    @Test
    fun deadlineStopsUnresponsiveUiCheckAndCompletesOnce() {
        val messenger = TestMessenger()
        val results = mutableListOf<Boolean>()
        uiExecution(messenger, results).start()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(110))
        assertEquals(listOf("check", "stop"), messenger.calls.map { it.method })
        assertTrue(results.isEmpty())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))
        assertEquals(listOf(true), results)
        messenger.replySuccess()
        assertEquals(listOf(true), results)
    }

    @Test
    fun oldCompletionCannotReleaseTheNextExecution() {
        val messenger = TestMessenger()
        val originalResults = mutableListOf<Boolean>()
        val first = uiExecution(messenger, originalResults)
        first.start()
        first.stop()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))
        val second = uiExecution(TestMessenger(), mutableListOf())
        messenger.replySuccess()
        FollowUpdatesScheduler.released(first, true)
        assertSame(second, FollowUpdatesScheduler.execution)
        assertEquals(listOf(true), originalResults)
    }

    @Test
    fun uiDataWaitsForPrivateWorkerDestruction() {
        val events = mutableListOf<String>()
        val worker = mock(FlutterEngine::class.java)
        doAnswer { events.add("destroy"); null }.`when`(worker).destroy()
        val messenger = TestMessenger()
        val run = headlessExecution(worker, messenger)
        val ui = registerUi()

        ui.messenger.invokeNative("acquireUiData") { events.add("released") }
        assertTrue(events.isEmpty())
        assertEquals(listOf("stop"), messenger.calls.map { it.method })
        assertSame(run, FollowUpdatesScheduler.execution)
        run.finish(false)

        assertEquals(listOf("destroy", "released"), events)
        assertNull(FollowUpdatesScheduler.execution)
        verify(worker, times(1)).destroy()
    }

    @Test
    fun failedWorkerDestructionBlocksWaitingAndFutureUiReaders() {
        val worker = mock(FlutterEngine::class.java)
        doThrow(IllegalStateException("teardown failed")).`when`(worker).destroy()
        val run = headlessExecution(worker, TestMessenger())
        val ui = registerUi()
        val results = mutableListOf<Any?>()
        ui.messenger.invokeNative("acquireUiData", onResult = results::add)
        assertTrue(results.isEmpty())

        run.finish(false)
        assertEquals("FOLLOW_SCHEDULE_UNAVAILABLE", (results.single() as FlutterException).code)
        ui.messenger.invokeNative("acquireUiData", onResult = results::add)
        assertEquals(2, results.size)
        assertTrue(results.all { it is FlutterException })
        assertNull(FollowUpdatesScheduler.start(context) { fail("Unsafe data was reused") })
        verify(worker, times(1)).destroy()
    }

    @Test
    fun finishedAcknowledgesDartBeforeDestroyingPrivateEngine() {
        val events = mutableListOf<String>()
        val messenger = TestMessenger()
        val executor = mock(DartExecutor::class.java)
        `when`(executor.binaryMessenger).thenReturn(messenger)
        val loader = mock(FlutterLoader::class.java)
        `when`(loader.findAppBundlePath()).thenReturn("flutter_assets")
        doAnswer { call -> call.getArgument<Runnable>(3).run(); null }.`when`(loader)
            .ensureInitializationCompleteAsync(any(), isNull(), any(), any())
        FlutterInjector.reset()
        FlutterInjector.setInstance(FlutterInjector.Builder().setFlutterLoader(loader).build())

        mockConstruction(FlutterEngine::class.java) { engine, _ ->
            `when`(engine.dartExecutor).thenReturn(executor)
            doAnswer { events.add("destroy"); null }.`when`(engine).destroy()
        }.use { engines ->
            val run = requireNotNull(FollowUpdatesScheduler.start(context) { events.add("jobFinished") })
            shadowOf(Looper.getMainLooper()).idle()
            assertTrue(run.headless)
            assertEquals(1, engines.constructed().size)
            messenger.invokeNative("finished", mapOf("outcome" to "checked")) { events.add("ack") }
            assertEquals(listOf("ack"), events)
            assertSame(run, FollowUpdatesScheduler.execution)

            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf("ack", "destroy", "jobFinished"), events)
            assertNull(FollowUpdatesScheduler.execution)
            verify(executor).executeDartEntrypoint(any(), eq(listOf(
                context.filesDir.path, context.cacheDir.path,
                context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0.0.0",
            )))
        }
    }

    @Test
    fun uiEngineOwnsDataUntilItsDestructionCallback() {
        val ui = registerUi()
        val results = mutableListOf<Boolean>()
        val run = requireNotNull(FollowUpdatesScheduler.start(context, results::add))
        assertFalse(run.headless)
        shadowOf(Looper.getMainLooper()).idle()
        ui.lifecycle.onPreEngineRestart()
        assertSame(run, FollowUpdatesScheduler.execution)
        assertTrue(results.isEmpty())

        ui.lifecycle.onEngineWillDestroy()
        assertNull(FollowUpdatesScheduler.execution)
        assertEquals(listOf(true), results)
        val next = requireNotNull(FollowUpdatesScheduler.start(context) {})
        assertTrue(next.headless)
        next.finish(false)
        verify(ui.engine, never()).destroy()
    }

    @Test
    fun oldUiEngineDestructionCannotUnregisterItsReplacement() {
        val old = registerUi()
        val current = registerUi()
        old.lifecycle.onEngineWillDestroy()
        val run = requireNotNull(FollowUpdatesScheduler.start(context) {})
        assertFalse(run.headless)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(old.messenger.calls.isEmpty())
        assertEquals(listOf("check"), current.messenger.calls.map { it.method })
    }

    @Test
    fun notificationDenialDoesNotPublishOrAskForPermission() {
        shadowOf(notifications).setNotificationsEnabled(false)
        assertFalse(FollowUpdatesScheduler.notify(context, "1 update"))
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity)
    }

    @Test
    fun mutedNotificationChannelDoesNotAcknowledgeDelivery() {
        notifications.createNotificationChannel(NotificationChannel(
            "follow.updates", "Updates", NotificationManager.IMPORTANCE_NONE,
        ))
        assertFalse(FollowUpdatesScheduler.notify(context, "1 update"))
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
    }

    @Test
    fun updateNotificationRoutesToFollowUpdatesAndReusesSlot() {
        assertTrue(FollowUpdatesScheduler.notify(context, "1 update"))
        assertTrue(FollowUpdatesScheduler.notify(context, "2 updates"))
        val notification = shadowOf(notifications).allNotifications.single()
        assertEquals("2 updates", notification.extras.getString(Notification.EXTRA_TEXT))
        val intent = shadowOf(notification.contentIntent).savedIntent
        assertEquals(MainActivity::class.java.name, intent.component?.className)
        assertEquals("follow_updates", intent.getStringExtra(MainActivity.EXTRA_NOTIFICATION_ROUTE))
        assertTrue(notification.flags and Notification.FLAG_AUTO_CANCEL != 0)
    }

    private fun uiExecution(
        messenger: TestMessenger,
        results: MutableList<Boolean>,
    ): FollowJobExecution = FollowJobExecution(
        context, MethodChannel(messenger, "venera/follow_scheduler"), results::add,
    ).also { FollowUpdatesScheduler.execution = it }

    private fun headlessExecution(engine: FlutterEngine, messenger: TestMessenger): FollowJobExecution =
        FollowJobExecution(context, null) {}.also { run ->
            FollowUpdatesScheduler.execution = run
            setField(run, "engine", engine)
            setField(run, "channel", MethodChannel(messenger, "venera/follow_scheduler"))
        }

    private data class UiEngine(
        val engine: FlutterEngine,
        val messenger: TestMessenger,
        val lifecycle: FlutterEngine.EngineLifecycleListener,
    )

    private fun registerUi(): UiEngine {
        val engine = mock(FlutterEngine::class.java)
        val executor = mock(DartExecutor::class.java)
        val messenger = TestMessenger()
        lateinit var lifecycle: FlutterEngine.EngineLifecycleListener
        `when`(engine.dartExecutor).thenReturn(executor)
        `when`(executor.binaryMessenger).thenReturn(messenger)
        doAnswer { call -> lifecycle = call.getArgument(0); null }.`when`(engine)
            .addEngineLifecycleListener(any())
        FollowUpdatesScheduler.registerUi(context, engine)
        return UiEngine(engine, messenger, lifecycle)
    }

    private fun resetScheduler() {
        FollowUpdatesScheduler.execution = null
        setField(FollowUpdatesScheduler, "uiEngine", null)
        setField(FollowUpdatesScheduler, "uiChannel", null)
        setField(FollowUpdatesScheduler, "dataUnavailable", false)
        FollowUpdatesScheduler::class.java.getDeclaredField("dataWaiters").apply {
            isAccessible = true
            (get(null) as MutableList<*>).clear()
        }
    }

    private fun setField(target: Any, name: String, value: Any?) {
        target.javaClass.getDeclaredField(name).apply {
            isAccessible = true
            set(target, value)
        }
    }

    private class TestMessenger : BinaryMessenger {
        val calls = mutableListOf<MethodCall>()
        private var checkReply: BinaryMessenger.BinaryReply? = null
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            require(channel == "venera/follow_scheduler")
            val data = requireNotNull(message).duplicate().apply { flip() }
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(data)
            calls.add(call)
            if (call.method == "check") checkReply = callback
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        fun invokeNative(method: String, arguments: Any? = null, onResult: (Any?) -> Unit) {
            val data = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments)).apply { flip() }
            requireNotNull(handlers["venera/follow_scheduler"]).onMessage(data) { reply ->
                val result: Any? = try {
                    StandardMethodCodec.INSTANCE.decodeEnvelope(requireNotNull(reply).apply { flip() })
                } catch (error: FlutterException) {
                    error
                }
                onResult(result)
            }
        }

        fun replySuccess() {
            val envelope = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null).apply { flip() }
            requireNotNull(checkReply).reply(envelope)
        }

        fun replyNotImplemented() = requireNotNull(checkReply).reply(null)
    }
}
