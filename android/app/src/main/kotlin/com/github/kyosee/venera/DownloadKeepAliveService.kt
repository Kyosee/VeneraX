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
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * 下载进行时把进程钉在前台优先级，避免熄屏或切到后台后被系统回收，
 * 导致 Flutter 端的下载循环被挂起。
 *
 * 这里不碰任何下载逻辑——下载全部在 Dart 侧完成；本服务只负责两件事：
 * 展示一条不可滑除的进度通知，以及持有一个 CPU 唤醒锁。Dart 侧在队列
 * 有活时拉起服务、空闲时停掉。
 */
class DownloadKeepAliveService : Service() {

    private var cpuLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 每次拉起都顺便刷新通知文案；重复调用是安全的。
        promoteToForeground(intent?.getStringExtra(KEY_STATUS).orEmpty())
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
        super.onDestroy()
    }

    private fun promoteToForeground(status: String) {
        ensureChannelRegistered()
        val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        // 经 ServiceCompat 调用，兼容 API 29 以下没有「带类型」startForeground 重载的系统。
        ServiceCompat.startForeground(this, NOTE_ID, composeNotification(status), serviceType)
    }

    private fun composeNotification(status: String): Notification {
        val resume = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val openApp = PendingIntent.getActivity(
            this, 0, resume,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val body = status.ifBlank { getString(R.string.download_notification_default) }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(body)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun ensureChannelRegistered() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // 重复创建对已存在渠道是 no-op，但能在升级后刷新本地化的渠道名称。
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.download_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.download_channel_desc)
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
        private const val NOTE_ID = 1101
        private const val CHANNEL_ID = "download.progress"
        private const val KEY_STATUS = "status"
        private const val WAKE_TAG = "venera:dl-keepalive"

        /** 拉起服务，或在已运行时刷新通知文案。幂等。 */
        fun launch(context: Context, status: String) {
            val intent = Intent(context, DownloadKeepAliveService::class.java)
                .putExtra(KEY_STATUS, status)
            ContextCompat.startForegroundService(context, intent)
        }

        /** 停止服务，未运行时调用也安全。 */
        fun halt(context: Context) {
            context.stopService(Intent(context, DownloadKeepAliveService::class.java))
        }
    }
}
