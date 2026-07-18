import 'package:flutter/services.dart';
import 'package:flutter_dynamic_icon_plus/flutter_dynamic_icon_plus.dart';

import 'app.dart';
import 'appdata.dart';
import 'log.dart';

/// Launcher (home-screen / app-drawer) icon presets the user can switch
/// between. This is the OS-level app icon, not the in-app logo.
///
/// Only iOS and Android support alternate launcher icons at runtime; on desktop
/// the taskbar/Dock icon is fixed at build time, so the settings entry is
/// hidden there (see [LauncherIconService.isSupported]).
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
}

abstract final class LauncherIconService {
  static const _channel = MethodChannel('venera/method_channel');

  /// Whether this platform can switch launcher icons at runtime.
  static bool get isSupported => App.isAndroid || App.isIOS;

  /// The preset currently stored in settings.
  static LauncherIconPreset get current =>
      LauncherIconPreset.fromId(appdata.settings['appLauncherIcon'] as String?);

  /// Apply [preset] as the launcher icon and persist the choice.
  ///
  /// Returns true on success. Android and iOS take different paths:
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
}
