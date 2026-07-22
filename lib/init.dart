import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/sync_protocol.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

/// Critical initialization that must complete before UI renders.
/// Only includes what's needed for theme, locale, and basic app state.
Future<void> init() async {
  await App.init().wait();
  await appdata.init().wait();
  await AppTranslation.init().wait();
  if (App.isWindows) {
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

/// Heavy initialization that runs after UI is visible.
final Completer<void> deferredInitCompleter = Completer<void>();

Future<void> initDeferred() async {
  try {
    // Every step is individually guarded: one component failing must not skip
    // the rest. A corrupt cookie.db once threw here before App.initComponents
    // ever ran — yet the finally still completed the gate, so the app carried
    // on believing init had succeeded: the startup sync applied a backup over
    // uninitialized stores and the follow-update checker hit
    // LateInitializationError inside widget builds. The completer only means
    // "init finished attempting"; callers that need working stores must check
    // [coreDataStoresReady].
    await SingleInstanceCookieJar.createInstance().wait();
    await initPlatformServices().wait();
    var futures = [
      App.initComponents().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init().wait(),
      ImageEnhanceShader.instance.preload().wait(),
    ];
    await Future.wait(futures);
    CacheManager().setLimitSize(appdata.settings['cacheSize']);
    RelatedSourceTaskManager.instance;
    _checkOldConfigs();
    _autoCleanHistory();
    if (App.isAndroid) {
      initAndroidExtras();
      await trySetHighRefreshRate();
    }
    FlutterError.onError = (details) {
      Log.error(
          "Unhandled Exception", "${details.exception}\n${details.stack}");
    };
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  } finally {
    deferredInitCompleter.complete();
  }
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  // One-time stamp of the sync tier (#114). The legacy-boolean fallback in
  // DataSync.syncMode cannot tell a user's explicit "auto-sync off" apart
  // from the shim above writing `false` on an unconfigured fresh install —
  // only here, with the config at hand, can that be decided: an explicit
  // opt-out (false + configured) keeps its "nothing automatic" intent as
  // manual; everything else gets the historical default, realtime.
  if (appdata.implicitData['webdavSyncMode'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    var configured = webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3;
    appdata.implicitData['webdavSyncMode'] =
        (appdata.implicitData['webdavAutoSync'] == false && configured)
            ? WebdavSyncMode.manual.name
            : WebdavSyncMode.realtime.name;
    appdata.writeImplicitData();
  }
}

/// Removes reading history older than the user-selected retention window.
/// Driven by the `autoCleanHistoryDays` setting (0 = keep forever). Runs once
/// per startup after the history DB is ready; failures are swallowed so they
/// never block app launch.
void _autoCleanHistory() {
  var raw = appdata.settings['autoCleanHistoryDays'];
  var days = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
  if (days <= 0) return;
  try {
    var removed =
        HistoryManager().cleanHistoryOlderThan(Duration(days: days));
    if (removed > 0) {
      Log.info("History", "Auto-cleaned $removed history record(s) older "
          "than $days day(s).");
    }
  } catch (e, s) {
    Log.error("History", "Auto-clean failed: $e", s);
  }
}

Future<void> _checkAppUpdates() async {
  final now = DateTime.now().millisecondsSinceEpoch;

  // Comic source update check remains daily.
  final lastSourceCheck =
      (appdata.implicitData['lastCheckUpdate'] as num?)?.toInt() ?? 0;
  if (now - lastSourceCheck >= 24 * 60 * 60 * 1000) {
    appdata.implicitData['lastCheckUpdate'] = now;
    appdata.writeImplicitData();
    unawaited(ComicSourcePage.checkComicSourceUpdate());
  }

  // App update check runs on each startup when enabled.
  if (appdata.settings['checkUpdateOnStart'] == true) {
    await checkUpdateUi(false, false);
  }
}

void checkUpdates() {
  // Delay to make sure navigator context is ready for update dialogs.
  Future.delayed(const Duration(seconds: 2), _checkAppUpdates).wait();
  FollowUpdatesService.initChecker();
  PreTranslationTaskManager.instance.resumePendingTasks();
}

Future<void> initPlatformServices() async {
  await Future.wait([_initRhttp(), SAFTaskWorker().init()]);
}

Future<void> _initRhttp() async {
  try {
    await nativeInitRhttp();
  } catch (e, s) {
    Log.error("Rhttp", "Failed to initialize rhttp/RustLib: $e\n$s");
  }
}

void initAndroidExtras() {
  handleLinks();
  handleTextShare();
}

Future<void> trySetHighRefreshRate() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    Log.error("Display Mode", "Failed to set high refresh rate: $e");
  }
}
