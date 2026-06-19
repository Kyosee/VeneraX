import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// 拼装前台通知正文。纯函数，方便单测。
/// 有速度时附在末尾，让用户一眼看出后台确实在跑。
String formatDownloadStatus({
  required String title,
  required String message,
  required int speed,
}) {
  final head = message.isEmpty ? title : '$title · $message';
  return speed > 0 ? '$head · ${bytesToReadableString(speed)}/s' : head;
}

/// 队列里首个真正在下载（既非暂停也非出错）的任务。
DownloadTask? activeDownload(Iterable<DownloadTask> tasks) =>
    tasks.where((t) => !t.isPaused && !t.isError).firstOrNull;

/// 下载保活：Android 上在有任务运行时拉起原生前台服务并定时刷新进度通知，
/// 队列空闲时停掉。其它平台不做任何事。
///
/// 下载本体仍在主 isolate 跑（见 [DownloadTask]），本类只负责「别让系统冻结
/// 进程」这一件事，因此与下载逻辑解耦、可独立演进。
class DownloadKeepAlive {
  DownloadKeepAlive._();

  static final DownloadKeepAlive instance = DownloadKeepAlive._();

  static const _channel = MethodChannel('venera/download_keepalive');

  bool get _supported => App.isAndroid;

  bool _serviceUp = false;
  bool _permissionAsked = false;
  String? _lastStatus;
  Timer? _ticker;
  bool _ticking = false;

  /// 队列结构变化、或应用回到前台时调用，把服务状态校正到与队列一致。
  void refresh() {
    if (!_supported) return;
    if (activeDownload(LocalManager().downloadingTasks) == null) {
      _teardown();
    } else {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _tick();
    }
  }

  /// 回到前台时调用：系统可能在后台把服务杀了，这里重新校正。
  /// 注意不主动恢复用户手动暂停的任务——保活只针对正在跑的下载。
  void onResume() => refresh();

  void _teardown() {
    _ticker?.cancel();
    _ticker = null;
    _lastStatus = null;
    if (_serviceUp) {
      _serviceUp = false;
      _invoke('stop');
    }
  }

  Future<void> _tick() async {
    if (_ticking) return; // 避免上一次 _tick（如正在等通知权限弹窗）尚未结束时重入
    _ticking = true;
    try {
      if (activeDownload(LocalManager().downloadingTasks) == null) {
        _teardown();
        return;
      }
      if (!await _ensurePermission()) {
        _teardown(); // 没有通知权限就别空转着每秒发通道调用
        return;
      }
      // 异步间隙后重新确认仍有任务在跑（期间可能已完成/暂停并触发 teardown）
      final tasks = LocalManager().downloadingTasks;
      final task = activeDownload(tasks);
      if (task == null) {
        _teardown();
        return;
      }
      var status = formatDownloadStatus(
        title: task.title,
        message: task.message,
        speed: task.speed,
      );
      if (tasks.length > 1) {
        status = '@a and @b more'.tlParams({'a': status, 'b': tasks.length - 1});
      }
      // 文案没变就不再打扰系统，省下重复的通道往返与通知刷新。
      if (_serviceUp && status == _lastStatus) return;
      final ok = await _invoke('start', {'status': status});
      // start 是异步的，期间下载可能已结束并 teardown；此时撤销本次启动，
      // 避免留下一个没有对应下载的常驻通知。
      if (activeDownload(LocalManager().downloadingTasks) == null) {
        if (ok == true) _invoke('stop');
        _serviceUp = false;
        _lastStatus = null;
        return;
      }
      _serviceUp = ok == true;
      _lastStatus = _serviceUp ? status : null;
      if (!_serviceUp) {
        _ticker?.cancel();
        _ticker = null;
      }
    } finally {
      _ticking = false;
    }
  }

  /// 确保有通知权限。本次会话内最多弹一次系统请求；被拒后静默降级，
  /// 下载本身不受影响，只是失去后台保活。
  Future<bool> _ensurePermission() async {
    if (await _invoke('notificationGranted') == true) return true;
    if (_permissionAsked) return false;
    _permissionAsked = true;
    return await _invoke('requestNotification') == true;
  }

  Future<Object?> _invoke(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
