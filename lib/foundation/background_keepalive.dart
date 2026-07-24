import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';

/// 拼装后台任务前台通知正文。纯函数，方便单测。
/// 有 detail（如「3/10」「正在导出 xxx」）时附在标题后，让用户一眼看出后台确实在跑。
String formatTaskStatus({required String title, String? detail}) {
  final d = detail?.trim() ?? '';
  return d.isEmpty ? title : '$title · $d';
}

/// 判断 WebDAV 同步那条共享保活通知是否仍需保留。
///
/// 同步子系统里数条操作可能交叠运行——数据上/下载，以及上传/下载完成后延时触发的图片包
/// 同步，外加排队等待当前操作结束的下一次同步——但它们共用同一条 [`sync`]
/// [BackgroundKeepAlive.tagSync] 通知。任何一个一结束就移除通知，会把仍在跑的其它操作赖以
/// 不被系统冻结的前台服务一并撤掉。故此处以「活跃标志的引用计数」语义判断：只有当全部标志
/// 都清零时才允许释放保活。纯函数，方便单测。
bool syncKeepAliveActive({
  required bool uploading,
  required bool downloading,
  required bool syncingImages,
  required bool waiting,
}) =>
    uploading || downloading || syncingImages || waiting;

/// 通用后台任务保活：Android 上在追更检查/导入/导出等任务运行时，按类别（tag）拉起原生
/// 前台服务并各自展示一条独立的进度通知；该类任务结束时移除其通知，最后一类移除后服务自停。
/// 其它平台（iOS/桌面）不做任何事。
///
/// 任务本体仍在主 isolate 跑，本类只负责「别让系统冻结进程」这一件事，因此与各任务逻辑
/// 解耦、可独立演进。与下载专用的 DownloadKeepAlive 并行存在、互不影响。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static final BackgroundKeepAlive instance = BackgroundKeepAlive._();

  static const _channel = MethodChannel('venera/background_keepalive');

  /// 与原生 [BackgroundKeepAliveService] 的 tag 常量保持一致。
  static const tagFollowUpdate = 'follow_update';
  static const tagImport = 'import';
  static const tagExport = 'export';
  static const tagComicImport = 'comic_import';
  static const tagSync = 'sync';
  static const tagPreTranslate = 'pre_translate';
  static const tagWebdavMigration = 'webdav_migration';

  bool get _supported => App.isAndroid;

  /// tag -> 最近一次上报给原生的文案。用于去重，避免重复的通道往返与通知刷新。
  final _statuses = <String, String>{};
  bool _permissionAsked = false;

  /// 上报某类任务的最新状态。文案没变则不打扰系统。被移除/未授权时静默降级，
  /// 任务本身不受影响，只是失去后台保活。
  void update(String tag, String status) {
    if (!_supported) return;
    if (_statuses[tag] == status) return;
    _statuses[tag] = status;
    unawaited(_pushUpdate(tag, status));
  }

  /// 移除某类任务的保活通知。任务结束/取消/暂停时调用。
  void remove(String tag) {
    if (!_supported) return;
    if (!_statuses.containsKey(tag)) return;
    _statuses.remove(tag);
    unawaited(_invoke('remove', {'tag': tag}));
  }

  Future<void> _pushUpdate(String tag, String status) async {
    if (!await _ensurePermission()) {
      // 没有通知权限就别空转——前台服务必须有通知，拿不到权限直接放弃这次保活。
      _statuses.remove(tag);
      return;
    }
    // 异步等权限期间该 tag 可能已被 remove（任务在弹窗时结束）。复查后再决定是否上报，
    // 避免留下一个没有对应任务的常驻通知。
    if (_statuses[tag] != status) return;
    final ok = await _invoke('update', {'tag': tag, 'status': status});
    if (ok != true) {
      // 系统拒绝（如后台启动限制），清掉缓存的文案以便下次重试。
      _statuses.remove(tag);
    }
  }

  /// 确保有通知权限。本次会话内最多弹一次系统请求；被拒后静默降级。
  /// 与下载保活共用同一套原生通知权限实现（同一权限，互不冲突）。
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
