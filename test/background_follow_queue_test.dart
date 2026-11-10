import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_follow_queue.dart';
import 'package:venera/foundation/ohos_follow_scheduler.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('venerax-follow-test-');
    path = '${directory.path}/queue.json';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'short intervals and failed or killed batches still advance to the tail',
    () {
      final times = {for (var i = 0; i < 12; i++) '$i': 'old'};
      var queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.takeBatch(times.keys.toSet(), times), [
        '0',
        '1',
        '2',
        '3',
        '4',
      ]);
      queue.complete('0', updated: false);
      // No completion for the other requests: simulate a killed worker.
      queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.takeBatch(times.keys.toSet(), times), [
        '5',
        '6',
        '7',
        '8',
        '9',
      ]);
      queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.takeBatch(times.keys.toSet(), times), [
        '10',
        '11',
        '0',
        '1',
        '2',
      ]);
      expect(queue.pending, isEmpty);
    },
  );

  test(
    'new and deleted comics reconcile without checking entries not yet due',
    () {
      var times = {'a': 'old', 'b': 'old', 'c': 'old'};
      var queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.takeBatch({'b'}, times), ['b']);
      times = {'b': 'old', 'c': 'old', 'd': 'new'};
      queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.takeBatch({'c', 'd'}, times), ['c', 'd']);
      expect(queue.takeBatch({}, times), isEmpty);
    },
  );

  test(
    'unacknowledged notifications survive restarts and recover completed DB writes',
    () {
      var times = <String, String?>{'a': 'old', 'b': null, 'c': 'old'};
      var queue = BackgroundFollowQueue(path)..reconcile(times);
      queue.takeBatch(times.keys.toSet(), times);
      queue.complete('a', updated: true);
      // b was committed to the DB, but the worker died before complete().
      times = {'a': 'new', 'b': 'first', 'c': 'old'};
      queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.pending, {'a', 'b'});
      // Failed/blocked notification: no acknowledgement.
      expect(BackgroundFollowQueue(path).pending, {'a', 'b'});
      queue.acknowledge({'a', 'b'});
      expect(BackgroundFollowQueue(path).pending, isEmpty);
      queue = BackgroundFollowQueue(path)..reconcile(times);
      expect(queue.pending, isEmpty);
    },
  );

  test(
    'removed pending comics and malformed continuation data are discarded',
    () {
      var queue = BackgroundFollowQueue(path)..reconcile({'a': null});
      queue.takeBatch({'a'}, {'a': null});
      queue.complete('a', updated: true);
      queue.reconcile({});
      expect(BackgroundFollowQueue(path).pending, isEmpty);
      File(path).writeAsStringSync('{');
      queue = BackgroundFollowQueue(path)..reconcile({'b': null});
      expect(queue.takeBatch({'b'}, {'b': null}), ['b']);
    },
  );

  test(
    'background saves finish synchronously and defer automatic sync',
    () async {
      final oldPath = App.dataPath;
      final oldConfig = appdata.settings['webdav'];
      App.dataPath = directory.path;
      App.isBackgroundTask = true;
      addTearDown(() {
        App.isBackgroundTask = false;
        App.dataPath = oldPath;
        appdata.settings['webdav'] = oldConfig;
        appdata.implicitData.remove('webdavPendingChanges');
      });
      appdata.settings['webdav'] = ['https://example.invalid', 'test', 'test'];
      final first = appdata.saveData();
      appdata.settings['followUpdatesIntervalHours'] = 12;
      final second = appdata.saveData();
      final saved = jsonDecode(
        File('${directory.path}/appdata.json').readAsStringSync(),
      );
      expect(saved['settings']['followUpdatesIntervalHours'], 12);
      final implicit = jsonDecode(
        File('${directory.path}/implicitData.json').readAsStringSync(),
      );
      expect(implicit['webdavPendingChanges'], true);
      expect(DataSync().hasPendingChanges, isTrue);
      await Future.wait([first, second]);
    },
  );

  test(
    'standard platforms never invoke the HarmonyOS scheduling channel',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OhosFollowScheduler.channel, (
            MethodCall call,
          ) async {
            calls++;
            return null;
          });
      await OhosFollowScheduler.acquireUiData();
      await OhosFollowScheduler.sync();
      expect(calls, 0);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OhosFollowScheduler.channel, null);
    },
  );
}
