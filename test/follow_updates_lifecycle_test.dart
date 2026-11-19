import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_follow_queue.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/follow_update_result.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_updates_scheduler.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'follow_lifecycle_test';
const _folder = 'Following';

ComicDetails _details(String id) => ComicDetails.fromJson({
  'title': 'Updated $id',
  'cover': '',
  'comicId': id,
  'sourceKey': _sourceKey,
  'tags': <String, List<String>>{},
  'updateTime': '2026-11-17',
});

ComicSource _source(LoadComicFunc loadDetails) => ComicSource(
  'Follow lifecycle test',
  _sourceKey,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  loadDetails,
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

class _FailingQueue extends BackgroundFollowQueue {
  _FailingQueue(super.path, {required this.failOnComplete});

  final bool failOnComplete;

  @override
  List<String> takeBatch(Set<String> due, Map<String, String?> updateTimes) {
    if (!failOnComplete) throw const FileSystemException('Queue write failed');
    return super.takeBatch(due, updateTimes);
  }

  @override
  void complete(String key, {required bool updated}) {
    if (failOnComplete) {
      throw const FileSystemException('Queue completion failed');
    }
    super.complete(key, updated: updated);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final originalDataPath = App.dataPath;
  final favorites = LocalFavoritesManager();

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('follow-lifecycle-');
    App.dataPath = directory.path;
    App.isBackgroundTask = true;
    await appdata.init();
    appdata.settings['language'] = 'en-US';
    await AppTranslation.init();
    await favorites.init();
    favorites.createFolder(_folder);
    favorites.prepareTableForFollowUpdates(_folder);
  });

  tearDown(() {
    ComicSourceManager().remove(_sourceKey);
    App.isBackgroundTask = true;
    FollowUpdateTaskManager.instance.onTaskFinished = null;
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FollowUpdatesScheduler.channel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('venera/background_keepalive'),
      null,
    );
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    favorites.close();
    directory.deleteSync(recursive: true);
    App.dataPath = originalDataPath;
    App.isBackgroundTask = false;
  });

  FavoriteItemWithUpdateInfo add(String id, {String folder = _folder}) {
    favorites.addComic(
      folder,
      FavoriteItem(
        id: id,
        name: 'Original $id',
        coverPath: '',
        author: '',
        type: ComicType.fromKey(_sourceKey),
        tags: const [],
      ),
      null,
      '2026-11-16',
    );
    return favorites
        .getComicsWithUpdatesInfo(folder)
        .firstWhere((c) => c.id == id);
  }

  FavoriteItemWithUpdateInfo read(String id, {String folder = _folder}) =>
      favorites.getComicsWithUpdatesInfo(folder).firstWhere((c) => c.id == id);

  Future<void> nativeCall(String method) async {
    const codec = StandardMethodCodec();
    final done = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      FollowUpdatesScheduler.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (response) {
        try {
          codec.decodeEnvelope(response!);
          done.complete();
        } catch (error, stack) {
          done.completeError(error, stack);
        }
      },
    );
    await done.future;
  }

  test('background checks commit without a UI frame', () async {
    ComicSourceManager().add(_source((id) async => Res(_details(id))));
    final comic = add('headless');
    SchedulerBinding.instance.scheduleFrame();
    final result = await updateComic(comic, [
      _folder,
    ]).timeout(const Duration(seconds: 2));
    expect(result.errorMessage, isNull);
    expect(result.updated, isTrue);
    expect(read(comic.id).name, 'Updated ${comic.id}');
    expect(read(comic.id).lastCheckDateTime, isNotNull);
  });

  test(
    'cancellation while a write waits for a frame leaves stored data unchanged',
    () async {
      ComicSourceManager().add(_source((id) async => Res(_details(id))));
      final comic = add('cancelled-write');
      App.isBackgroundTask = false;
      SchedulerBinding.instance.scheduleFrame();
      var cancelled = false;
      var cancellationChecks = 0;
      final checking = updateComic(
        comic,
        [_folder],
        shouldCancel: () {
          cancellationChecks++;
          return cancelled;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancellationChecks, 2);
      cancelled = true;
      final result = await checking.timeout(const Duration(seconds: 2));
      expect(result.errorMessage, isNull);
      expect(result.updated, isFalse);
      expect(read(comic.id).name, 'Original ${comic.id}');
      expect(read(comic.id).lastCheckDateTime, isNull);
      expect(cancellationChecks, 3);
    },
  );

  test(
    'cancelled requests block new checks until their real execution ends',
    () async {
      final requested = Completer<void>();
      final response = Completer<Res<ComicDetails>>();
      ComicSourceManager().add(
        _source((id) async {
          if (id == 'draining') {
            if (!requested.isCompleted) requested.complete();
            return response.future;
          }
          return Res(_details(id));
        }),
      );
      final comic = add('draining');
      final manager = FollowUpdateTaskManager.instance;
      final task = manager.startCheck([_folder], manual: true)!;
      await requested.future.timeout(const Duration(seconds: 2));
      final finished = Completer<void>();
      manager.onTaskFinished = (done) {
        if (done.id == task.id) finished.complete();
      };
      manager.cancel(task.id);
      expect(task.isRunning, isFalse);
      expect(manager.isExecuting(task.id), isTrue);
      expect(manager.hasPendingWork, isTrue);
      expect(manager.startCheck([_folder], manual: true), isNull);
      var idle = false;
      final drained = manager.waitForIdle().then((_) => idle = true);
      await Future<void>.delayed(Duration.zero);
      expect(idle, isFalse);
      response.complete(Res(_details(comic.id)));
      await finished.future.timeout(const Duration(seconds: 3));
      await drained.timeout(const Duration(seconds: 2));
      expect(idle, isTrue);
      expect(manager.isExecuting(task.id), isFalse);
      expect(manager.hasPendingWork, isFalse);
      expect(read(comic.id).name, 'Original ${comic.id}');
      expect(read(comic.id).lastCheckDateTime, isNull);
      final restarted = manager.startCheck([_folder], manual: true);
      expect(restarted, isNotNull);
      await manager.waitForIdle().timeout(const Duration(seconds: 3));
      expect(restarted!.status, FollowUpdateTaskStatus.completed);
      expect(read(comic.id).lastCheckDateTime, isNotNull);
    },
  );

  test(
    'an interval with no due comic creates no empty automatic task',
    () async {
      ComicSourceManager().add(_source((id) async => Res(_details(id))));
      final manager = FollowUpdateTaskManager.instance;
      for (final comic in favorites.getComicsWithUpdatesInfo(_folder)) {
        favorites.updateCheckTime(_folder, comic.id, comic.type);
      }
      appdata.settings[FollowUpdateScope.intervalKey] = 24;
      final historyCount = manager.historyTasks.length;
      expect(manager.startCheck([_folder], manual: false), isNull);
      expect(manager.hasPendingWork, isFalse);
      expect(manager.historyTasks.length, historyCount);
    },
  );

  test(
    'native stop preserves manual work and waits for its own cancelled requests',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const scheduler = FollowUpdatesScheduler.channel;
      const keepAlive = MethodChannel('venera/background_keepalive');
      final keepAliveCalls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        scheduler,
        (_) async => true,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(keepAlive, (
        call,
      ) async {
        keepAliveCalls.add(call);
        return true;
      });

      var requested = Completer<void>();
      var response = Completer<Res<ComicDetails>>();
      var target = 'manual';
      ComicSourceManager().add(
        _source((id) async {
          if (id == target) {
            if (!requested.isCompleted) requested.complete();
            return response.future;
          }
          return Res(_details(id));
        }),
      );
      add(target);
      final manager = FollowUpdateTaskManager.instance;
      final manual = manager.startCheck([_folder], manual: true)!;
      await requested.future.timeout(const Duration(seconds: 2));
      appdata.settings[FollowUpdateScope.allFoldersKey] = true;
      appdata.settings[FollowUpdateScope.checkOnStartKey] = false;
      appdata.settings[FollowUpdateScope.fixedTimeKey] = '';
      FollowUpdatesService.initChecker();
      await nativeCall('check').timeout(const Duration(seconds: 2));
      await nativeCall('stop');
      expect(manual.isRunning, isTrue);
      expect(manager.isExecuting(manual.id), isTrue);
      final manualFinished = Completer<void>();
      manager.onTaskFinished = (task) {
        if (task.id == manual.id) manualFinished.complete();
      };
      response.complete(Res(_details(target)));
      await manualFinished.future.timeout(const Duration(seconds: 3));
      expect(manual.status, FollowUpdateTaskStatus.completed);
      final lastResult = FollowUpdateResult.latest!;
      expect(lastResult.updatedKeys, contains(read(target).identityKey));
      await Future<void>.delayed(Duration.zero);

      target = 'scheduled';
      requested = Completer<void>();
      response = Completer<Res<ComicDetails>>();
      final comic = add(target);
      keepAliveCalls.clear();
      var checkReturned = false;
      final checking = nativeCall('check').then((_) => checkReturned = true);
      await requested.future.timeout(const Duration(seconds: 2));
      final scheduled = manager.currentTasks.single;
      await nativeCall('stop');
      expect(scheduled.status, FollowUpdateTaskStatus.canceled);
      expect(checkReturned, isFalse);
      expect(manager.isExecuting(scheduled.id), isTrue);
      response.complete(Res(_details(target)));
      await checking.timeout(const Duration(seconds: 3));
      expect(checkReturned, isTrue);
      expect(manager.hasPendingWork, isFalse);
      expect(read(comic.id).lastCheckDateTime, isNull);
      expect(keepAliveCalls, isEmpty);
      expect(FollowUpdateResult.latest!.checkedAt, lastResult.checkedAt);
      expect(FollowUpdateResult.latest!.updatedKeys, lastResult.updatedKeys);
    },
  );

  test(
    'cancelled system checks retain updates and retry denied notifications without fetching again',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const folder = 'Pending notifications';
      favorites.createFolder(folder);
      favorites.prepareTableForFollowUpdates(folder);
      appdata.settings[FollowUpdateScope.allFoldersKey] = false;
      appdata.settings[FollowUpdateScope.foldersKey] = [folder];
      appdata.settings[FollowUpdateScope.checkOnStartKey] = false;
      appdata.settings[FollowUpdateScope.fixedTimeKey] = '';
      appdata.settings[FollowUpdateScope.intervalKey] = 24;
      final response = Completer<Res<ComicDetails>>();
      final requested = Completer<void>();
      var requests = 0;
      ComicSourceManager().add(
        _source((id) async {
          requests++;
          if (id == 'pending-slow') {
            requested.complete();
            return response.future;
          }
          return Res(_details(id));
        }),
      );
      final updated = add('pending-updated', folder: folder);
      final slow = add('pending-slow', folder: folder);
      final notifications = <MethodCall>[];
      var granted = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FollowUpdatesScheduler.channel,
        (call) async {
          if (call.method == 'notify') notifications.add(call);
          return granted;
        },
      );
      FollowUpdatesService.initChecker();
      final committed = Completer<void>();
      final manager = FollowUpdateTaskManager.instance;
      void changed() {
        if (!committed.isCompleted &&
            read(updated.id, folder: folder).hasNewUpdate == true) {
          committed.complete();
        }
      }

      manager.addListener(changed);
      addTearDown(() => manager.removeListener(changed));
      final checking = nativeCall('check');
      await requested.future.timeout(const Duration(seconds: 2));
      await committed.future.timeout(const Duration(seconds: 2));
      await nativeCall('stop');
      response.complete(Res(_details(slow.id)));
      await checking.timeout(const Duration(seconds: 3));
      expect(notifications.single.arguments, {
        'status': 'Follow Updates · 1 updates',
      });
      final queuePath = '${App.dataPath}/android_follow_queue.json';
      expect(BackgroundFollowQueue(queuePath).pending, {updated.identityKey});
      expect(read(slow.id, folder: folder).lastCheckDateTime, isNull);

      // Nothing is due, but the previous denied result must still be delivered.
      favorites.updateCheckTime(folder, slow.id, slow.type);
      final fetched = requests;
      final historyCount = manager.historyTasks.length;
      granted = true;
      await nativeCall('check').timeout(const Duration(seconds: 2));
      expect(requests, fetched);
      expect(manager.historyTasks.length, historyCount);
      expect(notifications, hasLength(2));
      expect(BackgroundFollowQueue(queuePath).pending, isEmpty);
      await nativeCall('check').timeout(const Duration(seconds: 2));
      expect(notifications, hasLength(2));
    },
  );

  test(
    'a manual check starting during scheduled cleanup keeps its foreground service',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const folder = 'Manual handoff';
      favorites.createFolder(folder);
      favorites.prepareTableForFollowUpdates(folder);
      appdata.settings[FollowUpdateScope.allFoldersKey] = false;
      appdata.settings[FollowUpdateScope.foldersKey] = [folder];
      appdata.settings[FollowUpdateScope.checkOnStartKey] = false;
      appdata.settings[FollowUpdateScope.fixedTimeKey] = '';
      final manualRequested = Completer<void>();
      final manualResponse = Completer<Res<ComicDetails>>();
      var requests = 0;
      ComicSourceManager().add(
        _source((id) {
          requests++;
          if (requests == 1) return Future.value(Res(_details(id)));
          manualRequested.complete();
          return manualResponse.future;
        }),
      );
      final comic = add('handoff', folder: folder);
      final foregroundUpdated = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FollowUpdatesScheduler.channel,
        (_) async => true,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('venera/background_keepalive'),
        (call) async {
          if (call.method == 'update' && !foregroundUpdated.isCompleted) {
            foregroundUpdated.complete();
          }
          return true;
        },
      );
      FollowUpdatesService.initChecker();
      final manager = FollowUpdateTaskManager.instance;
      FollowUpdateTask? manual;
      manager.onTaskFinished = (_) {
        manager.onTaskFinished = null;
        manual = manager.startCheck([folder], manual: true);
      };
      final scheduledCheck = nativeCall('check');
      await manualRequested.future.timeout(const Duration(seconds: 2));
      await foregroundUpdated.future.timeout(const Duration(seconds: 2));
      expect(manual?.manual, isTrue);
      expect(manual?.isRunning, isTrue);
      manualResponse.complete(Res(_details(comic.id)));
      await manager.waitForIdle().timeout(const Duration(seconds: 3));
      await scheduledCheck.timeout(const Duration(seconds: 2));
      expect(manual?.status, FollowUpdateTaskStatus.completed);
    },
  );

  test(
    'bounded requests release stalled checks and ignore late results',
    () async {
      final responses = <Completer<Res<ComicDetails>>>[];
      ComicSourceManager().add(
        _source((id) {
          final response = Completer<Res<ComicDetails>>();
          responses.add(response);
          return response.future;
        }),
      );
      final comic = add('timeout');
      ComicUpdateResult? result;
      final checking = updateComic(
        comic,
        [_folder],
        requestTimeout: const Duration(milliseconds: 10),
      ).then((value) => result = value);
      await checking.timeout(const Duration(seconds: 2));
      expect(responses, hasLength(1));
      expect(result, isNotNull);
      expect(result!.errorMessage, contains('TimeoutException'));
      expect(result!.updated, isFalse);
      for (final response in responses) {
        response.complete(Res(_details(comic.id)));
      }
      await Future<void>.delayed(Duration.zero);
      expect(read(comic.id).name, 'Original ${comic.id}');
      expect(read(comic.id).lastCheckDateTime, isNull);
    },
  );

  test('requests without a deadline wait for the source response', () async {
    final response = Completer<Res<ComicDetails>>();
    ComicSourceManager().add(_source((id) => response.future));
    final comic = add('manual-without-timeout');
    ComicUpdateResult? result;
    final checking = updateComic(comic, [
      _folder,
    ]).then((value) => result = value);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(result, isNull);
    response.complete(Res(_details(comic.id)));
    await checking.timeout(const Duration(seconds: 2));
    expect(result?.updated, isTrue);
  });

  for (final failOnComplete in [false, true]) {
    test(
      'queue ${failOnComplete ? 'completion' : 'rotation'} failure closes the stream and releases the task',
      () async {
        final folder = 'Queue failure $failOnComplete';
        favorites.createFolder(folder);
        favorites.prepareTableForFollowUpdates(folder);
        ComicSourceManager().add(_source((id) async => Res(_details(id))));
        final comic = add('queue-failure-$failOnComplete', folder: folder);
        final queue = _FailingQueue(
          '${directory.path}/failing-$failOnComplete.json',
          failOnComplete: failOnComplete,
        )..reconcile({comic.identityKey: comic.updateTime});
        final errors = <Object>[];
        final closed = Completer<void>();
        final subscription =
            updateFolders([folder], true, backgroundQueue: queue).listen(
              (_) {},
              onError: (Object error) => errors.add(error),
              onDone: closed.complete,
            );
        addTearDown(subscription.cancel);
        await closed.future.timeout(const Duration(seconds: 3));
        expect(errors, [isA<FileSystemException>()]);

        final manager = FollowUpdateTaskManager.instance;
        final task = manager.startCheck(
          [folder],
          manual: true,
          backgroundQueue: queue,
        )!;
        await manager.waitForIdle().timeout(const Duration(seconds: 3));
        expect(task.status, FollowUpdateTaskStatus.failed);
        expect(manager.hasPendingWork, isFalse);
        expect(manager.isExecuting(task.id), isFalse);
      },
    );
  }
}
