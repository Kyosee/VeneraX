import 'package:flutter/services.dart';
import 'package:flutter_dynamic_icon_plus/flutter_dynamic_icon_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'appdata.dart';
import 'log.dart';

/// Launcher / app icon presets the user can switch between. This is the
/// OS-level app icon, not the in-app logo.
///
/// Runtime behaviour differs by platform:
/// - **iOS / Android** swap the real home-screen launcher icon.
/// - **Windows** swaps only the *live* window/taskbar-button icon (and the tray
///   icon) via `WM_SETICON`; the .exe's embedded icon — shown in Explorer, on a
///   pinned taskbar shortcut and in the Start menu — is fixed at build time and
///   cannot change at runtime (issue #134). WM_SETICON does not persist across
///   restarts, so [LauncherIconService.applyForStartup] re-applies the stored
///   choice once the window is ready.
/// - Other desktops (Linux/macOS) have no runtime path, so the settings entry
///   stays hidden there (see [LauncherIconService.isSupported]).
enum LauncherIconPreset {
  /// Current illustrated logo — the app's primary icon (baked into the bundle).
  defaultIcon('default'),

  /// The original Venera icon (pre-rebrand).
  orig('orig'),

  /// Flat icon variant (issue #120).
  flat('flat'),

  /// Monogram "Vx" gradient lettermark on a white field.
  mono('mono'),

  /// Illustrated "VeneraX" artwork on a night-sky field.
  illust('illust');

  const LauncherIconPreset(this.id);

  /// Stable id stored in settings (`appLauncherIcon`).
  final String id;

  static LauncherIconPreset fromId(String? id) {
    return LauncherIconPreset.values.firstWhere(
      (e) => e.id == id,
      orElse: () => LauncherIconPreset.defaultIcon,
    );
  }

  /// Android activity-alias short name this preset maps to. The native side
  /// resolves it against the application package, so the bare alias suffices.
  String get _androidAlias => switch (this) {
    LauncherIconPreset.defaultIcon => 'IconDefault',
    LauncherIconPreset.orig => 'IconOrig',
    LauncherIconPreset.flat => 'IconFlat',
    LauncherIconPreset.mono => 'IconMono',
    LauncherIconPreset.illust => 'IconIllust',
  };

  /// iOS alternate-icon key (from `CFBundleAlternateIcons` in Info.plist).
  ///
  /// Null means the primary icon: iOS restores it via a null iconName, so the
  /// default preset carries no alternate key.
  String? get _iosIconName {
    return switch (this) {
      LauncherIconPreset.defaultIcon => null,
      LauncherIconPreset.orig => 'IconOrig',
      LauncherIconPreset.flat => 'IconFlat',
      LauncherIconPreset.mono => 'IconMono',
      LauncherIconPreset.illust => 'IconIllust',
    };
  }

  /// In-app logo asset matching this preset. Shown in the sidebar header and
  /// the About page so the in-app branding follows the chosen launcher icon
  /// (issue #127). These mirror the launcher art, not the settings previews.
  String get inAppLogoAsset => switch (this) {
    LauncherIconPreset.defaultIcon => 'assets/app_icon.png',
    LauncherIconPreset.orig => 'assets/venera_original.png',
    LauncherIconPreset.flat => 'assets/user_logo.png',
    LauncherIconPreset.mono => 'assets/new_logo2.png',
    LauncherIconPreset.illust => 'assets/new_logo3.png',
  };

  /// Bundled multi-resolution `.ico` this preset maps to for the Windows
  /// window/taskbar/tray icon. Paths are relative to `assets/` because both
  /// `window_manager.setIcon` and `tray_manager.setIcon` resolve against the
  /// bundle's `data/flutter_assets/` directory. Generated from the matching
  /// PNGs by `tool/gen_launcher_icos.dart`.
  String get windowsIcoAsset => switch (this) {
    LauncherIconPreset.defaultIcon => 'assets/app_icon.ico',
    LauncherIconPreset.orig => 'assets/venera_original.ico',
    LauncherIconPreset.flat => 'assets/user_logo.ico',
    LauncherIconPreset.mono => 'assets/new_logo2.ico',
    LauncherIconPreset.illust => 'assets/new_logo3.ico',
  };
}

abstract final class LauncherIconService {
  static const _channel = MethodChannel('venera/method_channel');

  /// Whether this platform can switch app icons at runtime. Windows swaps only
  /// the live window/taskbar/tray icon (not the .exe's embedded icon); iOS and
  /// Android swap the real home-screen launcher icon.
  static bool get isSupported => App.isAndroid || App.isIOS || App.isWindows;

  /// Whether this platform can only swap the *live* window icon, leaving the
  /// installed/pinned icon unchanged. Drives the extra caveat in the settings
  /// copy so Windows users know the Explorer/Start-menu icon won't follow.
  static bool get isWindowIconOnly => App.isWindows;

  /// The preset currently stored in settings.
  static LauncherIconPreset get current =>
      LauncherIconPreset.fromId(appdata.settings['appLauncherIcon'] as String?);

  /// Hook the tray controller registers so its icon follows the chosen preset.
  /// Left null on non-Windows / before the tray is wired.
  static Future<void> Function(String icoAsset)? onWindowsIconChanged;

  /// Apply [preset] as the app icon and persist the choice.
  ///
  /// Returns true on success. Each platform takes a different path:
  ///
  /// - **Android** switches the enabled `activity-alias` immediately via our own
  ///   native channel (`DONT_KILL_APP`). We deliberately bypass
  ///   `flutter_dynamic_icon_plus` here: its Android path only writes the target
  ///   to prefs and defers the real switch to a Service's `onTaskRemoved` /
  ///   `onDestroy`, which never runs when the user force-stops the app — so the
  ///   icon would never change (issue #127). All aliases target the same
  ///   MainActivity, so an in-place switch is safe and effective at once.
  /// - **iOS** goes through the plugin, matching an Info.plist alternate-icon key
  ///   (null = primary); the system shows its own "icon changed" alert.
  /// - **Windows** pushes the preset's bundled `.ico` to the live window via
  ///   `window_manager.setIcon` (WM_SETICON) and to the tray, if wired. This
  ///   does not touch the .exe's embedded icon and does not persist across
  ///   restarts — [applyForStartup] re-applies the stored choice on launch.
  static Future<bool> apply(LauncherIconPreset preset) async {
    if (!isSupported) return false;

    try {
      if (App.isAndroid) {
        final ok = await _channel.invokeMethod<bool>(
          'setLauncherIcon',
          {'alias': preset._androidAlias},
        );
        if (ok != true) {
          Log.warning('LauncherIcon', 'Native icon switch returned $ok');
          return false;
        }
      } else if (App.isWindows) {
        await windowManager.setIcon(preset.windowsIcoAsset);
        // Keep the tray icon (if the tray is active) in step with the window.
        await onWindowsIconChanged?.call(preset.windowsIcoAsset);
      } else {
        if (!await FlutterDynamicIconPlus.supportsAlternateIcons) {
          Log.warning('LauncherIcon', 'Alternate icons not supported on device');
          return false;
        }
        await FlutterDynamicIconPlus.setAlternateIconName(
          iconName: preset._iosIconName,
        );
      }

      appdata.settings['appLauncherIcon'] = preset.id;
      appdata.saveData();
      return true;
    } catch (e, s) {
      Log.error('LauncherIcon', 'Failed to set launcher icon: $e', s);
      return false;
    }
  }

  /// Re-apply the stored preset's icon to the live Windows window on startup.
  ///
  /// WM_SETICON is per-process and lost on exit, so without this the window
  /// would revert to the built-in icon each launch. No-op unless the stored
  /// preset actually differs from the built-in default, and only on Windows.
  static Future<void> applyForStartup() async {
    if (!App.isWindows) return;
    final preset = current;
    if (preset == LauncherIconPreset.defaultIcon) return;
    try {
      await windowManager.setIcon(preset.windowsIcoAsset);
    } catch (e, s) {
      Log.error('LauncherIcon', 'Failed to apply startup icon: $e', s);
    }
  }
}
