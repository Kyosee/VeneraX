package io.github.kyosee.venera

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import dev.flutter.packages.file_selector_android.FileUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    private val storageRequestCode = 0x10
    private var storagePermissionRequest: ((Boolean) -> Unit)? = null

    private val notificationRequestCode = 0x11
    private var notificationPermissionRequest: ((Boolean) -> Unit)? = null

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayList<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            sharedTexts.add(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>
    ) {
        val key = "activity_rq_for_result#${nextLocalRequestCode.getAndIncrement()}"
        val registry = activityResultRegistry
        var launcher: ActivityResultLauncher<I>? = null
        val observer = object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (Lifecycle.Event.ON_DESTROY == event) {
                    launcher?.unregister()
                    lifecycle.removeObserver(this)
                }
            }
        }
        lifecycle.addObserver(observer)
        val newCallback = ActivityResultCallback<O> {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            callback.onActivityResult(it)
        }
        launcher = registry.register(key, contract, newCallback)
        launcher.launch(input)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/method_channel"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "getProxy" -> res.success(getProxy())
                "setScreenOn" -> {
                    val set = call.argument<Boolean>("set") ?: false
                    if (set) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    res.success(null)
                }

                "getDirectoryPath" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
                        if (activityResult.resultCode != Activity.RESULT_OK) {
                            res.success(null)
                            return@startContractForResult
                        }
                        val pickedDirectoryUri = activityResult.data?.data
                        if (pickedDirectoryUri == null)
                            res.success(null)
                        else
                            onPickedDirectory(pickedDirectoryUri, res)
                    }
                }

                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        res.error("INVALID_ARGUMENT", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = java.io.File(path)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this, "${applicationContext.packageName}.fileprovider", file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        res.success(true)
                    } catch (e: Exception) {
                        res.error("INSTALL_FAILED", e.message, null)
                    }
                }

                // 桌面图标切换：立即启用目标 activity-alias、停用其余，用
                // DONT_KILL_APP 保证不重启进程。所有 alias 都指向同一个
                // MainActivity，运行中的组件不受影响，故可安全即时生效——
                // 无需依赖第三方插件把切换推迟到进程销毁时，那条路径在被系统
                // 强行停止时根本不会执行，图标便永远换不掉。
                "setLauncherIcon" -> {
                    val target = call.argument<String>("alias")
                    if (target.isNullOrEmpty()) {
                        res.error("INVALID_ARGUMENT", "alias is required", null)
                        return@setMethodCallHandler
                    }
                    val ok = runCatching { applyLauncherIcon(target) }
                        .onFailure { Log.w("Venera", "set launcher icon failed: ${it.message}") }
                        .getOrDefault(false)
                    res.success(ok)
                }

                else -> res.notImplemented()
            }
        }

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.onUp = {
                        events.success(1)
                    }
                    volumeListen.onDown = {
                        events.success(2)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    listening = false
                }
            })

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/storage")
        storageChannel.setMethodCallHandler { _, res ->
            requestStoragePermission { result ->
                res.success(result)
            }
        }

        val selectFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/select_file")
        selectFileChannel.setMethodCallHandler { req, res ->
            val mimeType = req.arguments<String>()
            openFile(res, mimeType!!)
        }

        // 下载保活：Flutter 端经此通道按需拉起/停止前台服务，并协商通知权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/download_keepalive")
            .setMethodCallHandler { call, res ->
                when (call.method) {
                    "start" -> {
                        val status = call.argument<String>("status").orEmpty()
                        try {
                            DownloadKeepAliveService.launch(this, status)
                            res.success(true)
                        } catch (e: Exception) {
                            // 通知权限缺失或系统限制后台启动时落到这里，交由 Dart 端降级。
                            Log.w("Venera", "keepalive launch rejected: ${e.message}")
                            res.success(false)
                        }
                    }
                    "stop" -> {
                        runCatching { DownloadKeepAliveService.halt(this) }
                            .onFailure { Log.w("Venera", "keepalive halt failed: ${it.message}") }
                        res.success(null)
                    }
                    "complete" -> {
                        // 一次性「下载完成」通知，可滑除，与常驻进度通知分属不同 id/渠道。
                        val text = call.argument<String>("status").orEmpty()
                        runCatching { DownloadKeepAliveService.notifyComplete(this, text) }
                            .onFailure { Log.w("Venera", "keepalive complete failed: ${it.message}") }
                        res.success(null)
                    }
                    "notificationGranted" -> res.success(isNotificationGranted())
                    "requestNotification" -> when {
                        isNotificationGranted() -> res.success(true)
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                            notificationPermissionRequest?.invoke(false)
                            notificationPermissionRequest = { granted -> res.success(granted) }
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                notificationRequestCode,
                            )
                        }
                        else -> res.success(true)
                    }
                    else -> res.notImplemented()
                }
            }

        // 通用后台任务保活：追更检查/导入/导出经此通道按类别上报状态/移除，复用下载那套的通知权限协商。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/background_keepalive")
            .setMethodCallHandler { call, res ->
                when (call.method) {
                    "update" -> {
                        val tag = call.argument<String>("tag")
                        if (tag.isNullOrEmpty()) {
                            res.success(false)
                            return@setMethodCallHandler
                        }
                        val status = call.argument<String>("status").orEmpty()
                        try {
                            BackgroundKeepAliveService.update(this, tag, status)
                            res.success(true)
                        } catch (e: Exception) {
                            // 通知权限缺失或系统限制后台启动时落到这里，交由 Dart 端降级。
                            Log.w("Venera", "background keepalive update rejected: ${e.message}")
                            res.success(false)
                        }
                    }
                    "remove" -> {
                        val tag = call.argument<String>("tag")
                        if (!tag.isNullOrEmpty()) {
                            runCatching { BackgroundKeepAliveService.remove(this, tag) }
                                .onFailure { Log.w("Venera", "background keepalive remove failed: ${it.message}") }
                        }
                        res.success(null)
                    }
                    "notificationGranted" -> res.success(isNotificationGranted())
                    "requestNotification" -> when {
                        isNotificationGranted() -> res.success(true)
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                            notificationPermissionRequest?.invoke(false)
                            notificationPermissionRequest = { granted -> res.success(granted) }
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                notificationRequestCode,
                            )
                        }
                        else -> res.success(true)
                    }
                    else -> res.notImplemented()
                }
            }

        // 电池优化豁免：查询当前是否已豁免、拉起系统请求对话框，或跳转到电池优化设置列表。
        // 前台服务只挡得住系统冻结的一部分，OEM ROM 的省电策略仍会在应用切后台后冻结进程，
        // 需要用户把本应用加入电池优化白名单，后台任务（追更/同步/导入导出/下载）才能持续运行。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/battery_optimization")
            .setMethodCallHandler { call, res ->
                when (call.method) {
                    "isIgnoring" -> res.success(isIgnoringBatteryOptimizations())
                    "request" -> {
                        // Android 6.0 起才有此机制；更早版本无需豁免，直接返回已豁免。
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                            res.success(true)
                            return@setMethodCallHandler
                        }
                        if (isIgnoringBatteryOptimizations()) {
                            res.success(true)
                            return@setMethodCallHandler
                        }
                        try {
                            @android.annotation.SuppressLint("BatteryLife")
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                            startContractForResult(
                                ActivityResultContracts.StartActivityForResult(),
                                intent,
                            ) { _ ->
                                res.success(isIgnoringBatteryOptimizations())
                            }
                        } catch (e: Exception) {
                            // 个别 ROM 屏蔽了该 action，退回到设置列表让用户手动处理。
                            Log.w("Venera", "request battery exemption failed: ${e.message}")
                            runCatching { openBatteryOptimizationSettings() }
                            res.success(false)
                        }
                    }
                    "openSettings" -> {
                        val ok = runCatching { openBatteryOptimizationSettings() }
                            .getOrDefault(false)
                        res.success(ok)
                    }
                    else -> res.notImplemented()
                }
            }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = {text ->
                        events.success(text)
                    }
                    if (sharedTexts.isNotEmpty()) {
                        for (text in sharedTexts) {
                            events.success(text)
                        }
                        sharedTexts.clear()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    textShareHandler = null
                }
            })
    }

    private fun getProxy(): String {
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (host != null && port != null) {
            "$host:$port"
        } else {
            "No Proxy"
        }
    }

    // 与 AndroidManifest 中声明的三个 activity-alias 一一对应。切换时启用目标、
    // 停用其余，任何时刻只有一个入口处于启用态（launcher 里就不会出现重复图标）。
    private val launcherAliases = listOf("IconDefault", "IconOrig", "IconFlat")

    private fun applyLauncherIcon(alias: String): Boolean {
        if (alias !in launcherAliases) return false
        val pm = packageManager
        fun setState(name: String, enabled: Boolean) {
            pm.setComponentEnabledSetting(
                ComponentName(this, "$packageName.$name"),
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        // Enable the target first, then disable the rest, so there is never a
        // moment with zero enabled launcher entries (which could drop the app
        // from the home screen on some launchers).
        setState(alias, true)
        for (name in launcherAliases) {
            if (name != alias) setState(name, false)
        }
        return true
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (listening) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }

                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// Ensure that the directory is accessible by dart:io
    private fun onPickedDirectory(uri: Uri, result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            var plain = uri.toString()
            if(plain.contains("%3A")) {
                plain = Uri.decode(plain)
            }
            val externalStoragePrefix = "content://com.android.externalstorage.documents/tree/primary:";
            if(plain.startsWith(externalStoragePrefix)) {
                val path = plain.substring(externalStoragePrefix.length)
                result.success(Environment.getExternalStorageDirectory().absolutePath + "/" + path)
            }
            // The uri cannot be parsed to plain path, use copy method
        }
        // dart:io cannot access the directory without permission.
        // so we need to copy the directory to cache directory
        val contentResolver = contentResolver
        var tmp = cacheDir
        var dirName = DocumentFile.fromTreeUri(this, uri)?.name
        tmp = File(tmp, dirName!!)
        if(tmp.exists()) {
            tmp.deleteRecursively()
        }
        tmp.mkdir()
        Thread {
            try {
                copyDirectory(contentResolver, uri, tmp)
                result.success(tmp.absolutePath)
            }
            catch (e: Exception) {
                result.error("copy error", e.message, null)
            }
        }.start()

    }

    private fun copyDirectory(resolver: ContentResolver, srcUri: Uri, destDir: File) {
        val src = DocumentFile.fromTreeUri(this, srcUri) ?: return
        for (file in src.listFiles()) {
            if (file.isDirectory) {
                val newDir = File(destDir, file.name!!)
                newDir.mkdir()
                copyDirectory(resolver, file.uri, newDir)
            } else {
                val newFile = File(destDir, file.name!!)
                resolver.openInputStream(file.uri)?.use { input ->
                    FileOutputStream(newFile).use { output ->
                        input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            val writePermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            if (!readPermission || !writePermission) {
                storagePermissionRequest = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } else {
                result(true)
            }
        } else {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.addCategory("android.intent.category.DEFAULT")
                    intent.data = Uri.parse("package:$packageName")
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ _ ->
                        result(Environment.isExternalStorageManager())
                    }
                } catch (e: Exception) {
                    result(false)
                }
            } else {
                result(true)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            storagePermissionRequest?.invoke(grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            })
            storagePermissionRequest = null
        } else if (requestCode == notificationRequestCode) {
            notificationPermissionRequest?.invoke(
                grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            )
            notificationPermissionRequest = null
        }
    }

    // 通知权限：Android 13 起需运行时申请，更早版本默认拥有。
    private fun isNotificationGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    // 是否已被系统豁免电池优化。Android 6.0 以下没有此机制，视为已豁免。
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = getSystemService(POWER_SERVICE) as? PowerManager
            ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    // 跳转到系统「电池优化」设置列表，让用户手动把本应用移出优化名单。
    // 作为 ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 被 ROM 屏蔽时的兜底。
    private fun openBatteryOptimizationSettings(): Boolean {
        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            // 连列表页都没有的 ROM，退回到本应用的详情设置页。
            Log.w("Venera", "open battery settings failed: ${e.message}")
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    )
                )
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@startContractForResult
            }
            val contentResolver = contentResolver
            val file = DocumentFile.fromSingleUri(this, uri)
            if (file == null) {
                result.success(null)
                return@startContractForResult
            }
            val fileName = file.name
            if (fileName == null) {
                result.success(null)
                return@startContractForResult
            }
            if(hasStoragePermission()) {
                try {
                    val filePath = FileUtils.getPathFromUri(this, uri)
                    result.success(filePath)
                    return@startContractForResult
                }
                catch (e: Exception) {
                    // ignore
                }
            }
            // use copy method
            val tmp = File(cacheDir, fileName)
            if(tmp.exists()) {
                tmp.delete()
            }
            Log.i("Venera", "copy file (${fileName}) to ${tmp.absolutePath}")
            Thread {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tmp).use { output ->
                            input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                            output.flush()
                        }
                    }
                    result.success(tmp.absolutePath)
                }
                catch (e: Exception) {
                    result.error("copy error", e.message, null)
                }
            }.start()
        }
    }
}

class VolumeListen {
    var onUp = fun() {}
    var onDown = fun() {}
    fun up() {
        onUp()
    }

    fun down() {
        onDown()
    }
}

