import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_updates_scheduler.dart';
import 'package:venera/foundation/onboarding.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = FollowUpdatesScheduler.channel;
  const keepAlive = MethodChannel('venera/background_keepalive');
  late Object? oldFolders;
  late Object? oldAllFolders;
  late Object? oldFixedTime;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    oldFolders = appdata.settings[FollowUpdateScope.foldersKey];
    oldAllFolders = appdata.settings[FollowUpdateScope.allFoldersKey];
    oldFixedTime = appdata.settings[FollowUpdateScope.fixedTimeKey];
    appdata.settings[FollowUpdateScope.foldersKey] = <String>[];
    appdata.settings[FollowUpdateScope.allFoldersKey] = false;
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(keepAlive, null);
    channel.setMethodCallHandler(null);
    appdata.settings[FollowUpdateScope.foldersKey] = oldFolders;
    appdata.settings[FollowUpdateScope.allFoldersKey] = oldAllFolders;
    appdata.settings[FollowUpdateScope.fixedTimeKey] = oldFixedTime;
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android waits for data ownership before proceeding', () async {
    final acquired = Completer<void>();
    var completed = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'acquireUiData');
      return acquired.future;
    });
    final pending = FollowUpdatesScheduler.acquireUiData().then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    acquired.complete();
    await pending;
    expect(completed, isTrue);
  });

  test(
    'data ownership failure cannot silently initialize shared stores',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(code: 'FOLLOW_SCHEDULE_UNAVAILABLE');
      });
      await expectLater(
        FollowUpdatesScheduler.acquireUiData(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'schedule changes serialize and a failed configure can recover',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final enabled = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'configure');
        enabled.add((call.arguments as Map)['enabled'] as bool);
        if (enabled.length == 1) {
          entered.complete();
          await release.future;
          throw PlatformException(code: 'SCHEDULE_FAILED');
        }
        return null;
      });
      appdata.settings[FollowUpdateScope.allFoldersKey] = true;
      final first = FollowUpdatesScheduler.sync();
      await entered.future;
      appdata.settings[FollowUpdateScope.allFoldersKey] = false;
      final second = FollowUpdatesScheduler.sync();
      await Future<void>.delayed(Duration.zero);
      expect(enabled, [true]);
      release.complete();
      await Future.wait([first, second]);
      expect(enabled, [true, false]);
    },
  );

  test('desktop and iOS do not call Android or HarmonyOS scheduling', () async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      await FollowUpdatesScheduler.acquireUiData();
      await FollowUpdatesScheduler.sync();
    }
    expect(calls, isEmpty);
  });

  test('scheduling sends the local fixed minute, including midnight', () async {
    final minutes = <int?>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      minutes.add((call.arguments as Map)['fixedMinute'] as int?);
      return null;
    });
    appdata.settings[FollowUpdateScope.allFoldersKey] = true;
    for (final value in ['21:00', '00:00', '', '25:00']) {
      appdata.settings[FollowUpdateScope.fixedTimeKey] = value;
      await FollowUpdatesScheduler.sync();
    }
    expect(minutes, [1260, 0, null, null]);
  });

  test('the UI poll wakes at the fixed time, including after midnight', () {
    DateTime next(int hour, int minute, String fixedTime) =>
        FollowUpdatesScheduler.nextPoll(
          DateTime(2026, 11, 21, hour, minute),
          fixedTime,
        );
    expect(next(20, 59, '21:00'), DateTime(2026, 11, 21, 21));
    expect(next(21, 0, '21:00'), DateTime(2026, 11, 21, 21, 10));
    expect(next(23, 58, '00:03'), DateTime(2026, 11, 22, 0, 3));
    expect(next(8, 5, '21:00'), DateTime(2026, 11, 21, 8, 15));
    expect(next(8, 5, ''), DateTime(2026, 11, 21, 8, 15));
  });

  test(
    'onboarding blocks scheduling until setup and agreement are complete',
    () async {
      final store = OnboardingStore.instance;
      final previousState = store.state;
      final previousInitialized = store.initialized;
      final previousError = store.loadError;
      addTearDown(() {
        store.state = previousState;
        store.initialized = previousInitialized;
        store.loadError = previousError;
      });
      final enabled = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        enabled.add((call.arguments as Map)['enabled'] as bool);
        return null;
      });
      appdata.settings[FollowUpdateScope.allFoldersKey] = true;
      store.initialized = true;
      store.loadError = null;
      store.state = const OnboardingState();
      await FollowUpdatesScheduler.sync();
      store.state = const OnboardingState(setupCompleted: true);
      await FollowUpdatesScheduler.sync();
      store.state = const OnboardingState(
        setupCompleted: true,
        acceptedVersion: kDisclaimerVersion,
      );
      store.loadError = const FormatException('Unreadable setup');
      await FollowUpdatesScheduler.sync();
      store.loadError = null;
      await FollowUpdatesScheduler.sync();
      expect(enabled, [false, false, false, true]);
    },
  );

  test(
    'result notifications do not request permission or start a foreground service',
    () async {
      final keepAliveCalls = <MethodCall>[];
      final notifications = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(keepAlive, (
        call,
      ) async {
        keepAliveCalls.add(call);
        return false;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        notifications.add(call);
        return false;
      });
      final service = BackgroundKeepAlive.instance;
      await service.completeFollowUpdate('2 updates');
      await Future<void>.delayed(Duration.zero);
      expect(keepAliveCalls, isEmpty);
      expect(notifications.single.method, 'notify');
      expect(notifications.single.arguments, {'status': '2 updates'});
    },
  );

  test(
    'denied or unavailable result notifications do not fail completed checks',
    () async {
      for (final exception in [
        PlatformException(code: 'NOTIFICATION_DENIED'),
        MissingPluginException(),
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          _,
        ) async {
          throw exception;
        });
        await BackgroundKeepAlive.instance.completeFollowUpdate('2 updates');
      }
    },
  );
}
