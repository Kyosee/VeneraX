import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/utils/translations.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/background_keepalive');
  final platforms = [
    TargetPlatform.android,
    ...TargetPlatform.values.where((p) => p.name == 'ohos'),
  ];
  late Directory temporary;
  final calls = <MethodCall>[];

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('follow-notification-');
    App.dataPath = temporary.path;
    appdata.settings['language'] = 'en-US';
    await AppTranslation.init();
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    await temporary.delete(recursive: true);
  });
  tearDown(() {
    FollowUpdateTaskManager.instance.onTaskFinished = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in platforms) {
    for (final outcome in ['updated', 'unchanged', 'cancelled']) {
      test('$platform follow check handles $outcome notifications', () async {
        debugDefaultTargetPlatformOverride = platform;
        calls.clear();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          return true;
        });
        final manager = FollowUpdateTaskManager.instance;
        manager.currentTasks.clear();
        manager.historyTasks.clear();
        final task = FollowUpdateTask(
          id: outcome,
          folders: [],
          manual: true,
          createdAt: DateTime(2026),
          sources: {},
          updated: outcome == 'unchanged' ? 0 : 2,
        );
        manager.currentTasks.add(task);
        final finished = Completer<void>();
        manager.onTaskFinished = (_) => finished.complete();
        final resumed = manager.resumePendingTasks();
        if (outcome == 'cancelled') manager.cancel(task.id);
        await resumed;
        await finished.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(task.status, switch (outcome) {
          'cancelled' => FollowUpdateTaskStatus.canceled,
          _ => FollowUpdateTaskStatus.completed,
        });
        expect(manager.currentTasks, isEmpty);
        expect(
          calls.any((call) => call.method == 'notificationGranted'),
          isTrue,
        );
        expect(calls.any((call) => call.method == 'remove'), isTrue);
        final completions = calls.where((call) => call.method == 'complete');
        if (platform.name == 'ohos' && outcome == 'updated') {
          expect(completions.single.arguments, {
            'tag': 'follow_update',
            'status': 'Follow Updates · 2 updates',
          });
        } else {
          expect(completions, isEmpty);
        }
      });
    }
  }
}
