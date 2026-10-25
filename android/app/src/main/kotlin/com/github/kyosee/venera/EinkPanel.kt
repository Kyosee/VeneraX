package io.github.kyosee.venera

import android.app.Activity
import android.os.Build
import android.util.Log
import java.lang.reflect.Method

/**
 * Page-turn ripple on iReader e-readers running SmartOS 4 or later. The system
 * exposes no public API; its display controller takes text commands through a
 * hidden class, and "next-effect-type" makes the next screen update play the
 * ripple instead of a plain redraw.
 */
object EinkPanel {
    private const val TAG = "EinkPanel"

    private val postCommand: Method? by lazy {
        runCatching {
            Class.forName("android.eink.EPDCDevice")
                .getMethod("nativePostCommand", String::class.java)
        }.getOrNull()
    }

    val rippleSupported: Boolean by lazy {
        val vendor = Build.MANUFACTURER.equals("iReader", ignoreCase = true) ||
            Build.BRAND.equals("iReader", ignoreCase = true)
        // Cheap vendor check first: other devices never touch reflection.
        vendor && (smartOsMajor() ?: 0) >= 4 && postCommand != null
    }

    /**
     * [codes] holds the command code for each display rotation (index 0-3);
     * the one matching the current rotation is armed.
     */
    fun queueRipple(codes: List<Int>, activity: Activity): Boolean {
        if (!rippleSupported) return false
        val code = codes.getOrNull(rotationIndex(activity)) ?: return false
        return runCatching { postCommand?.invoke(null, "next-effect-type $code") }
            .onFailure { Log.w(TAG, "ripple command failed: ${it.message}") }
            .isSuccess
    }

    private fun rotationIndex(activity: Activity): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: 0
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }

    private fun smartOsMajor(): Int? =
        systemProperty("ro.build.versionCode")?.substringBefore('.')?.trim()?.toIntOrNull()

    private fun systemProperty(name: String): String? {
        val reflected = runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java)
                .invoke(null, name) as? String
        }.getOrNull()
        if (!reflected.isNullOrBlank()) return reflected
        // Hidden-API restrictions can block the reflective read on newer
        // Android; the shell tool reads the same property.
        return runCatching {
            ProcessBuilder("/system/bin/getprop", name).start()
                .inputStream.bufferedReader().use { it.readLine() }
        }.getOrNull()?.takeIf { it.isNotBlank() }
    }
}
