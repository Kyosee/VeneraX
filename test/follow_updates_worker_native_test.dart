import 'dart:async';
import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_updates_worker.dart';
import 'package:venera/foundation/js_engine.dart';

// Reuse existing native libraries; add the Windows runner directory to PATH.
// No platform package is built by these tests.
bool get _nativeLibrariesAvailable {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    DynamicLibrary.open('rhttp.dll');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final skip = _nativeLibrariesAvailable
      ? false
      : 'Existing Windows QuickJS and rhttp libraries are required';
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real worker initializes sources concurrently, isolates timeout and checks',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'follow-worker-integration-',
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      App.initBackgroundTask(directory.path, directory.path, '3.0.1');
      App.externalStoragePath = directory.path;
      await appdata.init();
      appdata.settings[FollowUpdateScope.allFoldersKey] = true;
      appdata.settings[FollowUpdateScope.fixedTimeKey] = '';
      appdata.settings['language'] = 'en-US';
      await appdata.saveData(false);
      File('${directory.path}/onboarding.json').writeAsStringSync(
        jsonEncode({
          'setupCompleted': true,
          'acceptedVersion': kDisclaimerVersion,
          'acceptedAt': '2026-11-17T00:00:00Z',
          'acceptedLanguage': 'en-US',
        }),
      );
      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('Following');
      manager.prepareTableForFollowUpdates('Following');
      manager.addComic(
        'Following',
        FavoriteItem(
          id: '1',
          name: 'Before',
          coverPath: '',
          author: '',
          type: ComicType.fromKey('scheduler_test'),
          tags: [],
        ),
        null,
        '2026-11-16',
      );
      manager.close();
      Directory('${directory.path}/comic_source').createSync(recursive: true);
      for (var i = 0; i < 5; i++) {
        File('${directory.path}/comic_source/slow$i.js').writeAsStringSync('''
class SchedulerSlow$i extends ComicSource {
  name = "Scheduler slow $i";
  key = "scheduler_slow_$i";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {};
  comic = {};
  async init() {
    ComicSource.schedulerStarted = (ComicSource.schedulerStarted || 0) + 1;
    while (ComicSource.schedulerStarted < 5) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    ComicSource.schedulerReady = (ComicSource.schedulerReady || 0) + 1;
  }
}
''');
      }
      File('${directory.path}/comic_source/stuck.js').writeAsStringSync('''
class SchedulerStuck extends ComicSource {
  name = "Scheduler stuck";
  key = "scheduler_stuck";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {};
  comic = {};
  init() { return new Promise(() => {}); }
}
''');
      File('${directory.path}/comic_source/test.js').writeAsStringSync('''
class SchedulerTest extends ComicSource {
  name = "Scheduler test";
  key = "scheduler_test";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {};
  ready = false;
  async init() {
    if (!ComicSource.sources.scheduler_slow_4) {
      throw new Error('Sources not registered before initialization');
    }
    await new Promise(resolve => setTimeout(resolve, 50));
    this.ready = true;
  }
  comic = {
    loadInfo: async (id) => {
      if (!this.ready) throw new Error('Source used before initialization');
      if (ComicSource.schedulerReady !== 5) {
        throw new Error('Slow sources were not initialized concurrently');
      }
      return {
      title: await compute("(title) => title + ' updated'", "Synthetic"),
      cover: "", tags: {}, updateTime: "2026-11-17"
      };
    }
  };
}
''');
      final finished = Completer<String>();
      final stages = <String>[];
      final notifications = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/follow_scheduler'),
        (call) async {
          if (call.method == 'ready') return false;
          if (call.method == 'stage') {
            stages.add(call.arguments['stage']);
          }
          if (call.method == 'notify') {
            notifications.add(call.arguments['status']);
            return true;
          }
          if (call.method == 'finished') {
            finished.complete(call.arguments['outcome']);
          }
          return null;
        },
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/method_channel'),
        (_) async => 'No Proxy',
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/reading_widget'),
        (_) async => false,
      );
      runFollowUpdatesWorker([directory.path, directory.path, '3.0.1']);
      expect(
        await finished.future.timeout(const Duration(seconds: 35)),
        'checked',
        reason: stages.join(', '),
      );
      expect(notifications, ['Follow Updates · 1 updates']);
      expect(manager.isInitialized, false);
      expect(App.domain.isInitialized, false);
      await manager.init();
      final comic = manager.getComicsWithUpdatesInfo('Following').single;
      expect(comic.name, 'Synthetic updated');
      expect(comic.hasNewUpdate, true);
      expect(comic.lastCheckDateTime, isNotNull);
      manager.close();
      final queue = jsonDecode(
        File('${directory.path}/android_follow_queue.json').readAsStringSync(),
      );
      expect(queue['pending'], isEmpty);
      expect(queue['inFlight'], isEmpty);
      directory.deleteSync(recursive: true);
    },
    skip: skip,
  );
  test(
    'headless compute preserves promises, nesting and repeat cleanup',
    () async {
      App.isBackgroundTask = true;
      for (var i = 0; i < 3; i++) {
        final engine = JsEngine();
        await engine.init();
        expect(
          await engine.runCode(
            'compute("(a, b) => a + b", 3, 4).then(v => v * 2)',
          ),
          14,
        );
        expect(
          await engine.runCode(
            'compute("(a) => compute(\\"(b) => b + 1\\", a)", 9)',
          ),
          10,
        );
        expect(
          await engine.runCode(
            'compute("() => { throw new Error(\\"expected\\"); }").catch(() => 17)',
          ),
          17,
        );
        engine.dispose();
      }
      App.isBackgroundTask = false;
    },
    skip: skip,
  );
}
