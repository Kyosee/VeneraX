package io.github.kyosee.venera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * 通用后台任务保活：在追更检查/导入/导出运行时把进程钉在前台优先级，避免熄屏或切到
 * 后台后被系统冻结，导致 Flutter 端的任务循环被挂起。
 *
 * 与 [DownloadKeepAliveService] 同样不碰任何业务逻辑——任务全部在 Dart 侧完成；本服务
 * 只负责两件事：为每一类正在运行的任务展示一条不可滑除的独立进度通知，以及持有一个
 * CPU 唤醒锁。Dart 侧（[venera/background_keepalive] 通道）在某类任务有活时上报状态、
 * 全部空闲时移除。
 *
 * 之所以独立于下载那套：下载保活已上线、单标签即可，这里需要「多类任务各一条独立通知」，
 * 拆开实现可让下载保活零改动、零回归。两个前台服务在 Android 上可以并存。
 */
class BackgroundKeepAliveService : Service() {

    private var cpuLock: PowerManager.WakeLock? = null

    // tag -> 通知正文。LinkedHashMap 保留插入序，便于稳定地挑选「前台」那条通知。
    private val statuses = LinkedHashMap<String, String>()

    // 当前作为 startForeground 载体的 tag。被移除时需换一条仍存活的通知顶上。
    private var foregroundTag: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tag = intent?.getStringExtra(KEY_TAG)
        if (tag != null) {
            val stopTag = intent.getBooleanExtra(KEY_STOP, false)
            if (stopTag) {
                statuses.remove(tag)
                // 非前台载体的通知不属于 startForeground，也不在 refreshNotifications
                // 的存活集合里——不在这里撤销的话，任务结束后它那条 ongoing 的
                // 「进行中」卡片会永远留在通知栏且无法滑除（#84）。前台载体那条
                // 由 refreshNotifications 换载体时撤销，或最后一个任务结束时由
                // stopForeground 连带移除。
                if (tag != foregroundTag) {
                    NotificationManagerCompat.from(this).cancel(notificationId(tag))
                }
            } else {
                statuses[tag] = intent.getStringExtra(KEY_STATUS).orEmpty()
            }
        }
        if (statuses.isEmpty()) {
            // 没有任何任务在跑，收摊。stopForeground 连带移除前台通知。
            // 若本次是冷启动就收摊（任务已结束后才送达的 remove）：
            // startForegroundService 的契约要求本次启动必须调用过 startForeground，
            // 否则系统会抛 ForegroundServiceDidNotStartInTimeException。
            // 先短暂促前台，随后 stopForeground 会立即把这条通知一并移除。
            if (foregroundTag == null) {
                ensureChannelRegistered()
                startForegroundCompat(BASE_NOTE_ID, composeNotification("", ""))
            }
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        refreshNotifications()
        keepCpuAwake()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 应用被划掉时主 isolate 也随之消失，没有继续保活的意义。
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        cpuLock?.takeIf { it.isHeld }?.release()
        cpuLock = null
        // 退场时清掉本服务发出的全部附属通知（前台通知由 stopForeground 处理）。
        val manager = NotificationManagerCompat.from(this)
        for (tag in statuses.keys) {
            if (tag != foregroundTag) manager.cancel(notificationId(tag))
        }
        super.onDestroy()
    }

    private fun refreshNotifications() {
        ensureChannelRegistered()
        // 选一条通知作为前台载体：优先沿用当前的，避免不必要的 startForeground 抖动。
        val nextForeground = foregroundTag?.takeIf { statuses.containsKey(it) }
            ?: statuses.keys.first()

        startForegroundCompat(
            notificationId(nextForeground),
            composeNotification(nextForeground, statuses[nextForeground].orEmpty()),
        )

        val manager = NotificationManagerCompat.from(this)
        // 上一条前台通知若已不再是前台载体（被换下或被移除），按附属通知处理：
        // 仍存活则降级为普通通知，已移除则撤销。
        foregroundTag?.let { prev ->
            if (prev != nextForeground) {
                if (statuses.containsKey(prev)) {
                    manager.notify(
                        notificationId(prev),
                        composeNotification(prev, statuses[prev].orEmpty()),
                    )
                } else {
                    manager.cancel(notificationId(prev))
                }
            }
        }
        foregroundTag = nextForeground

        // 其余存活 tag 各自刷新独立通知。
        for ((tag, status) in statuses) {
            if (tag == nextForeground) continue
            manager.notify(notificationId(tag), composeNotification(tag, status))
        }
    }

    /** 经 ServiceCompat 调用，兼容 API 29 以下没有「带类型」startForeground 重载的系统。 */
    private fun startForegroundCompat(noteId: Int, notification: Notification) {
        val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, noteId, notification, serviceType)
    }

    private fun stopForegroundCompat() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foregroundTag = null
    }

    private fun composeNotification(tag: String, status: String): Notification {
        val resume = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val openApp = PendingIntent.getActivity(
            this, 0, resume,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val body = status.ifBlank { getString(R.string.background_notification_default) }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(titleFor(tag))
            .setContentText(body)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun titleFor(tag: String): String {
        val resId = when (tag) {
            TAG_FOLLOW_UPDATE -> R.string.background_title_follow_update
            TAG_IMPORT -> R.string.background_title_import
            TAG_EXPORT -> R.string.background_title_export
            TAG_COMIC_IMPORT -> R.string.background_title_comic_import
            TAG_SYNC -> R.string.background_title_sync
            else -> R.string.app_name
        }
        return getString(resId)
    }

    private fun ensureChannelRegistered() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // 重复创建对已存在渠道是 no-op，但能在升级后刷新本地化的渠道名称。
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.background_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.background_channel_desc)
                setShowBadge(false)
            }
        )
    }

    private fun keepCpuAwake() {
        if (cpuLock?.isHeld == true) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    companion object {
        private const val CHANNEL_ID = "background.tasks"
        private const val KEY_TAG = "tag"
        private const val KEY_STATUS = "status"
        private const val KEY_STOP = "stop"
        private const val WAKE_TAG = "venera:bg-keepalive"

        // 每个 tag 落到固定通知槽位，保证同一类任务始终复用同一条通知。
        private const val BASE_NOTE_ID = 1200

        const val TAG_FOLLOW_UPDATE = "follow_update"
        const val TAG_IMPORT = "import"
        const val TAG_EXPORT = "export"
        const val TAG_COMIC_IMPORT = "comic_import"
        const val TAG_SYNC = "sync"

        private fun notificationId(tag: String): Int = when (tag) {
            TAG_FOLLOW_UPDATE -> BASE_NOTE_ID + 1
            TAG_IMPORT -> BASE_NOTE_ID + 2
            TAG_EXPORT -> BASE_NOTE_ID + 3
            TAG_COMIC_IMPORT -> BASE_NOTE_ID + 4
            TAG_SYNC -> BASE_NOTE_ID + 5
            else -> BASE_NOTE_ID + (tag.hashCode() and 0x3F) + 8
        }

        /** 上报某类任务的最新状态，或在已运行时刷新其通知文案。幂等。 */
        fun update(context: Context, tag: String, status: String) {
            val intent = Intent(context, BackgroundKeepAliveService::class.java)
                .putExtra(KEY_TAG, tag)
                .putExtra(KEY_STATUS, status)
            ContextCompat.startForegroundService(context, intent)
        }

        /** 移除某类任务；移除最后一类时服务自行停止。未运行时调用也安全。 */
        fun remove(context: Context, tag: String) {
            val intent = Intent(context, BackgroundKeepAliveService::class.java)
                .putExtra(KEY_TAG, tag)
                .putExtra(KEY_STOP, true)
            ContextCompat.startForegroundService(context, intent)
        }
    }
}
