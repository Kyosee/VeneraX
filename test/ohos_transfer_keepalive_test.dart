import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/background_keepalive');
  final ohos = TargetPlatform.values.where((p) => p.name == 'ohos').firstOrNull;
  final calls = <MethodCall>[];
  var granted = true;
  void Function(MethodCall)? observe;

  setUp(() {
    debugDefaultTargetPlatformOverride = ohos;
    BackgroundKeepAlive.instance.allowTransferBackground();
    calls.clear();
    granted = true;
    observe = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          observe?.call(call);
          return switch (call.method) {
            'notificationGranted' || 'requestNotification' => granted,
            _ => true,
          };
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'real transfer progress is sent and its grant ends before return',
    () async {
      final progressSeen = Completer<void>();
      observe = (call) {
        if (call.method == 'update' && call.arguments['progress'] == 50) {
          progressSeen.complete();
        }
      };
      final result = await BackgroundKeepAlive.instance.runTransfer(
        'Transfer',
        (progress) async {
          progress(1, 2);
          await progressSeen.future;
          return 42;
        },
      );
      expect(result, 42);
      final updates = calls.where((call) => call.method == 'update').toList();
      expect(updates.map((call) => call.arguments['progress']), [0, 50]);
      expect(calls.last.method, 'remove');
      expect(calls.last.arguments['tag'], updates.first.arguments['tag']);
    },
    skip: ohos == null,
  );

  test(
    'concurrent transfers retain separate grants until each finishes',
    () async {
      final first = Completer<void>();
      final second = Completer<void>();
      final started = Completer<void>();
      var count = 0;
      Future<void> waitFor(Completer<void> gate) {
        if (++count == 2) started.complete();
        return gate.future;
      }

      final a = BackgroundKeepAlive.instance.runTransfer(
        'First',
        (_) => waitFor(first),
      );
      final b = BackgroundKeepAlive.instance.runTransfer(
        'Second',
        (_) => waitFor(second),
      );
      await started.future;
      final tags = calls
          .where((call) => call.method == 'update')
          .map((call) => call.arguments['tag'])
          .toSet();
      expect(tags.length, 2);
      first.complete();
      await a;
      expect(calls.where((call) => call.method == 'remove').length, 1);
      second.complete();
      await b;
      expect(
        calls
            .where((call) => call.method == 'remove')
            .map((call) => call.arguments['tag'])
            .toSet(),
        tags,
      );
    },
    skip: ohos == null,
  );

  test(
    'failed transfer releases its grant and ignores late progress',
    () async {
      late void Function(int, int) lateProgress;
      await expectLater(
        BackgroundKeepAlive.instance.runTransfer<void>('Failure', (
          progress,
        ) async {
          lateProgress = progress;
          throw StateError('Transfer failed');
        }),
        throwsStateError,
      );
      expect(calls.last.method, 'remove');
      final completedCount = calls.length;
      lateProgress(80, 100);
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, completedCount);
    },
    skip: ohos == null,
  );

  test(
    'permission refusal preserves foreground IO and local tasks do not request data transfer',
    () async {
      granted = false;
      BackgroundKeepAlive.instance.update(
        BackgroundKeepAlive.tagImport,
        'Local import',
      );
      expect(calls, isEmpty);
      final value = await BackgroundKeepAlive.instance.runTransfer(
        'Foreground',
        (progress) async {
          progress(1, 2);
          return 'data';
        },
      );
      expect(value, 'data');
      expect(calls.where((call) => call.method == 'update'), isEmpty);
      expect(calls.last.method, 'remove');
    },
    skip: ohos == null,
  );

  test(
    'system cancellation suppresses subsequent automatic transfers until explicit sync',
    () async {
      var callsAfterCancellation = -1;
      await BackgroundKeepAlive.instance.runTransfer('Current transfer', (
        _,
      ) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('cancelled'),
              ),
              (_) {},
            );
      });
      callsAfterCancellation = calls.length;
      final value = await BackgroundKeepAlive.instance.runTransfer(
        'Next automatic transfer',
        (progress) async {
          progress(1, 2);
          return 'foreground data';
        },
      );
      expect(value, 'foreground data');
      expect(calls.length, callsAfterCancellation);
      BackgroundKeepAlive.instance.allowTransferBackground();
      await BackgroundKeepAlive.instance.runTransfer(
        'Explicit sync',
        (_) async {},
      );
      expect(
        calls
            .skip(callsAfterCancellation)
            .where((call) => call.method == 'update')
            .length,
        1,
      );
      expect(calls.last.method, 'remove');
    },
    skip: ohos == null,
  );

  test(
    'a deferred native permission request can be retried from the foreground',
    () async {
      var requests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'notificationGranted') return false;
            if (call.method == 'requestNotification') return ++requests > 1;
            return true;
          });
      final service = BackgroundKeepAlive.instance;
      service.update(
        BackgroundKeepAlive.tagFollowUpdate,
        'Checking: background',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'update'), isEmpty);
      service.update(
        BackgroundKeepAlive.tagFollowUpdate,
        'Checking: foreground',
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, 2);
      expect(calls.where((call) => call.method == 'update').length, 1);
      service.remove(BackgroundKeepAlive.tagFollowUpdate);
      await Future<void>.delayed(Duration.zero);
    },
    skip: ohos == null,
  );

  test(
    'follow updates reach OHOS and completion does not request permission',
    () async {
      final updated = Completer<void>();
      observe = (call) {
        if (call.method == 'update') updated.complete();
      };
      final service = BackgroundKeepAlive.instance;
      service.update(BackgroundKeepAlive.tagFollowUpdate, 'Checking: 0/2');
      await updated.future.timeout(const Duration(seconds: 3));
      final update = calls.last;
      expect(update.arguments, {
        'tag': 'follow_update',
        'status': 'Checking: 0/2',
        'progress': 0,
      });
      calls.clear();
      await service.completeFollowUpdate('Found 1 update');
      expect(calls.map((call) => call.method), ['complete']);
      expect(calls.single.arguments, {
        'tag': 'follow_update',
        'status': 'Found 1 update',
      });
    },
    skip: ohos == null,
  );

  test(
    'ending a follow check during permission lookup suppresses late progress',
    () async {
      final service = BackgroundKeepAlive.instance;
      observe = (call) {
        if (call.method == 'notificationGranted') {
          service.remove(BackgroundKeepAlive.tagFollowUpdate);
        }
      };
      service.update(BackgroundKeepAlive.tagFollowUpdate, 'Checking: 0/3');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'update'), isEmpty);
      expect(calls.where((call) => call.method == 'remove').length, 1);
    },
    skip: ohos == null,
  );

  test(
    'denied follow checks still remove native state and can retry when allowed',
    () async {
      granted = false;
      final service = BackgroundKeepAlive.instance;
      service.update(BackgroundKeepAlive.tagFollowUpdate, 'Checking: 0/4');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'update'), isEmpty);
      service.remove(BackgroundKeepAlive.tagFollowUpdate);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'remove');
      granted = true;
      service.update(BackgroundKeepAlive.tagFollowUpdate, 'Checking: 0/4');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'update').length, 1);
      service.remove(BackgroundKeepAlive.tagFollowUpdate);
      await Future<void>.delayed(Duration.zero);
    },
    skip: ohos == null,
  );
}
