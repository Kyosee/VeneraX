import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/launcher_icon.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘控制器（仅 Windows）。
///
/// 开启「最小化到托盘」后：常驻一个托盘图标，并接管窗口关闭——点关闭按钮或
/// Alt+F4 时把窗口藏进托盘而非退出进程；通过托盘菜单或左键点击恢复，或显式退出。
/// 关闭该设置时移除托盘并放行正常关闭。其它平台所有方法均为空操作。
class TrayController with TrayListener, WindowListener {
  TrayController._();

  static final TrayController instance = TrayController._();

  static const _menuShow = 'show';
  static const _menuQuit = 'quit';

  bool get _supported => App.isWindows;

  bool _enabled = false;
  bool _wired = false;

  /// 启动时调用（需在窗口就绪后）。按当前设置决定是否启用托盘。
  Future<void> init() async {
    if (!_supported) return;
    _wire();
    await setEnabled(appdata.settings['minimizeToTray'] == true);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    trayManager.addListener(this);
    windowManager.addListener(this);
    // Keep the tray icon in step when the user switches the app icon preset
    // (issue #134); no-op while the tray is disabled.
    LauncherIconService.onWindowsIconChanged = (icoAsset) async {
      if (_enabled) await trayManager.setIcon(icoAsset);
    };
  }

  /// 切换开关时调用。启用即建立托盘并接管关闭；关闭即移除托盘并放行关闭。
  Future<void> setEnabled(bool enabled) async {
    if (!_supported || enabled == _enabled) return;
    _wire();
    if (enabled) {
      // 先把托盘图标/菜单与关闭拦截都准备好，最后才置 _enabled=true。
      // 否则窗口可能在托盘尚未建好时就被隐藏，出现“窗口消失却没有托盘图标”
      // 的情况，只能重启恢复。
      // Follow the chosen app-icon preset so the tray matches the window.
      await trayManager.setIcon(LauncherIconService.current.windowsIcoAsset);
      await trayManager.setToolTip('VeneraX');
      await trayManager.setContextMenu(_buildMenu());
      await windowManager.setPreventClose(true);
      _enabled = true;
    } else {
      _enabled = false;
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      await windowManager.show();
    }
  }

  /// 把窗口收进托盘。供窗口关闭按钮路径调用。
  Future<void> hideToTray() async {
    if (!_supported) return;
    // 开关可能刚开启、setEnabled 尚未跑完；先确保托盘已就绪再隐藏。
    if (!_enabled) await setEnabled(true);
    await windowManager.hide();
  }

  Menu _buildMenu() => Menu(
        items: [
          MenuItem(key: _menuShow, label: 'Show VeneraX'.tl),
          MenuItem.separator(),
          MenuItem(key: _menuQuit, label: 'Exit'.tl),
        ],
      );

  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => _restoreWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuShow:
        _restoreWindow();
        break;
      case _menuQuit:
        exit(0);
    }
  }

  /// 原生关闭（Alt+F4 / 任务栏关闭）。仅在启用了 preventClose 时触发。
  @override
  void onWindowClose() => hideToTray();
}
