import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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
    if (!_wired) {
      _wired = true;
      trayManager.addListener(this);
      windowManager.addListener(this);
    }
    await setEnabled(appdata.settings['minimizeToTray'] == true);
  }

  /// 切换开关时调用。启用即建立托盘并接管关闭；关闭即移除托盘并放行关闭。
  Future<void> setEnabled(bool enabled) async {
    if (!_supported || enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      await trayManager.setIcon('assets/app_icon.ico');
      await trayManager.setToolTip('Venera');
      await trayManager.setContextMenu(_buildMenu());
      await windowManager.setPreventClose(true);
    } else {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      await windowManager.show();
    }
  }

  /// 把窗口收进托盘。仅在已启用时生效。供窗口关闭按钮路径调用。
  Future<void> hideToTray() async {
    if (!_supported || !_enabled) return;
    await windowManager.hide();
  }

  Menu _buildMenu() => Menu(
        items: [
          MenuItem(key: _menuShow, label: 'Show Venera'.tl),
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
