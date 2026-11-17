package io.github.kyosee.venera

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** All engine ownership transitions run on Android's main thread. */
object FollowUpdatesScheduler {
    const val JOB_ID = 359
    private const val CHANNEL = "venera/follow_scheduler"
    private const val PERIOD_MS = 15 * 60 * 1000L
    private const val NOTIFICATION_CHANNEL = "follow.updates"
    private var uiEngine: FlutterEngine? = null
    private var uiChannel: MethodChannel? = null
    internal var execution: FollowJobExecution? = null
    private val dataWaiters = mutableListOf<MethodChannel.Result>()
    private var dataUnavailable = false

    fun registerUi(context: Context, engine: FlutterEngine) {
        uiEngine = engine
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit
            override fun onEngineWillDestroy() = unregisterUi(engine)
        })
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        uiChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireUiData" -> {
                    if (dataUnavailable) {
                        result.error("FOLLOW_SCHEDULE_UNAVAILABLE", "Background cleanup failed", null)
                    } else if (execution?.headless == true) {
                        dataWaiters.add(result)
                        execution?.stop()
                    } else {
                        result.success(null)
                    }
                }
                "configure" -> try {
                    configure(context, call.argument<Boolean>("enabled") == true)
                    result.success(null)
                } catch (_: Exception) {
                    result.error("FOLLOW_SCHEDULE_UNAVAILABLE", "Unable to schedule checks", null)
                }
                "notify" -> result.success(notify(context, call.argument<String>("status") ?: ""))
                else -> result.notImplemented()
            }
        }
    }

    fun unregisterUi(engine: FlutterEngine) {
        if (uiEngine !== engine) return
        uiEngine = null
        uiChannel = null
        if (execution?.headless == false) execution?.finish(true)
    }

    internal fun configure(context: Context, enabled: Boolean) {
        val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        if (!enabled) {
            scheduler.cancel(JOB_ID)
            execution?.stop()
            return
        }
        // Reopening the app must not postpone the existing periodic job.
        if (scheduler.allPendingJobs.any { it.id == JOB_ID }) return
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, FollowUpdatesJobService::class.java))
            .setPersisted(true)
            .setPeriodic(PERIOD_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setBackoffCriteria(PERIOD_MS, JobInfo.BACKOFF_POLICY_LINEAR)
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) setRequiresBatteryNotLow(true) }
            .build()
        check(scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS)
    }

    internal fun start(context: Context, finished: (Boolean) -> Unit): FollowJobExecution? {
        if (execution != null || dataUnavailable) return null
        val run = FollowJobExecution(context.applicationContext, uiChannel, finished)
        execution = run
        // Do not finish synchronously inside JobService.onStartJob.
        Handler(Looper.getMainLooper()).post { run.start() }
        return run
    }

    internal fun released(run: FollowJobExecution, safe: Boolean) {
        if (execution !== run) return
        execution = null
        dataUnavailable = !safe
        val waiting = dataWaiters.toList()
        dataWaiters.clear()
        waiting.forEach {
            if (safe) it.success(null)
            else it.error("FOLLOW_SCHEDULE_UNAVAILABLE", "Background cleanup failed", null)
        }
    }

    internal fun notify(context: Context, status: String): Boolean {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val system = context.getSystemService(NotificationManager::class.java)
                system.createNotificationChannel(NotificationChannel(
                    NOTIFICATION_CHANNEL, context.getString(R.string.background_title_follow_update),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ))
                if (system.getNotificationChannel(NOTIFICATION_CHANNEL).importance == NotificationManager.IMPORTANCE_NONE) {
                    return false
                }
            }
            val open = PendingIntent.getActivity(context, JOB_ID,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(MainActivity.EXTRA_NOTIFICATION_ROUTE, "follow_updates"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            manager.notify(JOB_ID, NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle(context.getString(R.string.background_title_follow_update))
                .setContentText(status).setContentIntent(open).setAutoCancel(true)
                .setOnlyAlertOnce(true).build())
            true
        } catch (_: Exception) {
            false
        }
    }
}

internal class FollowJobExecution(
    private val context: Context,
    private val uiChannel: MethodChannel?,
    private val finished: (Boolean) -> Unit,
) {
    val headless = uiChannel == null
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = uiChannel
    private var stopping = false
    private var done = false
    private val deadline = Runnable { stop() }
    private val teardown = Runnable { finish(true) }

    fun start() {
        if (done || stopping) return
        handler.postDelayed(deadline, 110_000)
        if (uiChannel != null) {
            uiChannel.invokeMethod("check", null, object : MethodChannel.Result {
                override fun success(result: Any?) = finish(false)
                override fun error(code: String, message: String?, details: Any?) = finish(true)
                override fun notImplemented() = finish(true)
            })
            return
        }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationCompleteAsync(context, null, handler) {
                if (done || stopping) return@ensureInitializationCompleteAsync
                try {
                    val worker = FlutterEngine(context)
                    engine = worker
                    val messenger = worker.dartExecutor.binaryMessenger
                    ReadingWidgets.register(context, messenger)
                    MethodChannel(messenger, "venera/method_channel").setMethodCallHandler { call, result ->
                        if (call.method == "getProxy") {
                            val host = System.getProperty("http.proxyHost")
                            val port = System.getProperty("http.proxyPort")
                            result.success(if (host != null && port != null) "$host:$port" else "No Proxy")
                        } else result.notImplemented()
                    }
                    val bridge = MethodChannel(messenger, "venera/follow_scheduler")
                    channel = bridge
                    bridge.setMethodCallHandler { call, result ->
                        if (done) return@setMethodCallHandler
                        when (call.method) {
                            "ready" -> result.success(stopping)
                            "stage" -> result.success(null)
                            "notify" -> result.success(!stopping && FollowUpdatesScheduler.notify(
                                context, call.argument<String>("status") ?: "",
                            ))
                            "finished" -> {
                                val retry = call.argument<String>("outcome") in listOf("failed", "cancelled")
                                result.success(null)
                                handler.post { finish(retry) }
                            }
                            else -> result.notImplemented()
                        }
                    }
                    val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0.0.0"
                    worker.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "followUpdatesBackgroundMain"),
                        listOf(context.filesDir.path, context.cacheDir.path, version),
                    )
                } catch (_: Exception) {
                    finish(true)
                }
            }
        } catch (_: Exception) {
            finish(true)
        }
    }

    fun stop() {
        if (done || stopping) return
        stopping = true
        channel?.invokeMethod("stop", null)
        // A UI engine stays alive; only a private worker can be destroyed here.
        handler.postDelayed(teardown, 5_000)
    }

    fun finish(retry: Boolean) {
        if (done) return
        done = true
        handler.removeCallbacks(deadline)
        handler.removeCallbacks(teardown)
        var safe = true
        try {
            engine?.destroy()
        } catch (_: Exception) {
            safe = false
        }
        engine = null
        FollowUpdatesScheduler.released(this, safe)
        finished(retry)
    }
}

class FollowUpdatesJobService : JobService() {
    private var execution: FollowJobExecution? = null
    private var parameters: JobParameters? = null

    override fun onStartJob(params: JobParameters): Boolean {
        parameters = params
        execution = FollowUpdatesScheduler.start(this) { retry ->
            if (parameters === params) {
                parameters = null
                execution = null
                jobFinished(params, retry)
            }
        }
        if (execution == null) parameters = null
        return execution != null
    }

    override fun onStopJob(params: JobParameters): Boolean {
        if (parameters === params) {
            parameters = null
            execution?.stop()
            execution = null
        }
        return true
    }

    override fun onDestroy() {
        parameters = null
        execution?.stop()
        execution = null
        super.onDestroy()
    }
}
