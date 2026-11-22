import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_follow_queue.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_updates_worker.dart';
import 'package:venera/foundation/onboarding.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'worker delivers pending results while deferring a cancelled round',
    () async {
      final directory = Directory.systemTemp.createTempSync('follow-cancel-');
      addTearDown(() => directory.deleteSync(recursive: true));
      App.initBackgroundTask(directory.path, directory.path, '3.0.2');
      App.externalStoragePath = directory.path;
      await OnboardingStore.instance.load(directory.path);
      await OnboardingStore.instance.accept('en-US');
      await OnboardingStore.instance.completeSetup();
      await appdata.init();
      appdata.settings[FollowUpdateScope.allFoldersKey] = true;
      appdata.settings[FollowUpdateScope.fixedTimeKey] = '';
      appdata.settings['language'] = 'en-US';
      appdata.implicitData[FollowUpdateScope.lastUserCancellationKey] =
          DateTime.now().toUtc().toIso8601String();
      addTearDown(() {
        appdata.implicitData.remove(FollowUpdateScope.lastUserCancellationKey);
      });
      await appdata.saveData(false);
      await appdata.writeImplicitData();
      final store = LocalFavoritesManager();
      await store.init();
      store.createFolder('Following');
      store.prepareTableForFollowUpdates('Following');
      final comic = FavoriteItem(
        id: 'pending',
        name: 'Updated',
        coverPath: '',
        author: '',
        type: ComicType.fromKey('scheduler_test'),
        tags: const [],
      );
      store.addComic('Following', comic, null, '2026-11-21');
      final prefix = App.isOhos ? 'ohos' : 'android';
      final queuePath = '${directory.path}/${prefix}_follow_queue.json';
      BackgroundFollowQueue(queuePath).complete(
        comic.identityKey,
        updated: true,
      );
      store.close();

      final stages = <String>[];
      final notifications = <String>[];
      final finished = Completer<String>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/follow_scheduler'),
        (call) async {
          switch (call.method) {
            case 'ready':
              return false;
            case 'stage':
              stages.add(call.arguments['stage']);
            case 'notify':
              notifications.add(call.arguments['status']);
              return true;
            case 'finished':
              finished.complete(call.arguments['outcome']);
          }
          return null;
        },
      );
      runFollowUpdatesWorker([directory.path, directory.path, '3.0.2']);
      expect(
        await finished.future.timeout(const Duration(seconds: 5)),
        'disabled',
      );
      expect(stages, isNot(contains('network')));
      expect(notifications, ['Follow Updates · 1 updates']);
      expect(BackgroundFollowQueue(queuePath).pending, isEmpty);
      expect(store.isInitialized, isFalse);
    },
  );
}
