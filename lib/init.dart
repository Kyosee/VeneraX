import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';
import 'init_native.dart'
    if (dart.library.html) 'init_web.dart'
    if (dart.library.js_interop) 'init_web.dart';

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
    if (!kIsWeb) {
      await SingleInstanceCookieJar.createInstance();
    }
    await initPlatformServices().wait();
    var futures = [
      App.initComponents(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
    CacheManager().setLimitSize(appdata.settings['cacheSize']);
    RelatedSourceTaskManager.instance;
    _checkOldConfigs();
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

  if (appdata.settings['comicSourceListUrl'].toString().contains(
    "git.nyne.dev",
  )) {
    // migrate to jsdelivr cdn
    appdata.settings['comicSourceListUrl'] =
        "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
    appdata.saveData();
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
}
