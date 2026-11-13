import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

/// Entries of the launcher icon's long-press menu.
///
/// Android and iOS publish them at runtime so labels follow the app language.
/// HarmonyOS declares the same routes in `shortcuts_config.json`. A tap comes
/// back through `handleNotificationRoute`.
abstract final class AppShortcuts {
  static const _channel = MethodChannel('venera/method_channel');

  static bool get isSupported => App.isAndroid || App.isIOS;

  static bool _started = false;

  static Object? _publishedLanguage;

  /// Display order: the first entry sits next to the icon.
  static List<Map<String, String>> get items => [
        {'route': 'favorites', 'label': 'Favorites'.tl},
        {'route': 'follow_updates', 'label': 'Follow Updates'.tl},
        {'route': 'history', 'label': 'History'.tl},
        {'route': 'search', 'label': 'Search'.tl},
      ];

  /// Publishes once and again whenever the app language changes.
  static void start() {
    if (!isSupported || _started) return;
    _started = true;
    appdata.settings.addListener(_onSettingsChanged);
    publish();
  }

  static void _onSettingsChanged() {
    if (appdata.settings['language'] != _publishedLanguage) publish();
  }

  static Future<void> publish() async {
    if (!isSupported) return;
    _publishedLanguage = appdata.settings['language'];
    try {
      final ok = await _channel.invokeMethod<bool>('setAppShortcuts', items);
      if (ok != true) Log.warning('App Shortcuts', 'Publish returned $ok');
    } catch (e, s) {
      Log.error('App Shortcuts', e, s);
    }
  }
}
