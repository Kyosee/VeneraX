import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test(
    'background expiry persists jobs and foreground only resumes those jobs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'translation-background-',
      );
      final oldPath = App.dataPath;
      App.dataPath = directory.path;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final manager = PreTranslationTaskManager.instance;
      final allowance =
          BackgroundKeepAlive.instance.translationBackgroundAllowed;
      final finished = Completer<void>();
      manager.onTaskFinished = (_) => finished.complete();
      PreTranslationTask task(String id) => PreTranslationTask(
        id: id,
        cid: id,
        sourceKey: 'test',
        comicType: ComicType(0),
        title: 'Test',
        chapters: [],
        createdAt: DateTime(2026),
      );
      final automatic = task('automatic');
      final manual = task('manual');
      final canceled = task('canceled');
      manager.currentTasks.addAll([automatic, manual, canceled]);
      try {
        allowance.value = false;
        expect(
          manager.currentTasks.every(
            (task) => task.status == PreTranslationTaskStatus.paused,
          ),
          isTrue,
        );
        final persisted =
            appdata.implicitData['pre_translation_active_tasks'] as List;
        expect(persisted.map((value) => value['id']), [
          'automatic',
          'manual',
          'canceled',
        ]);
        manager.pause(manual.id);
        manager.cancel(canceled.id);
        allowance.value = true;
        expect(automatic.status, PreTranslationTaskStatus.running);
        expect(manual.status, PreTranslationTaskStatus.paused);
        expect(canceled.status, PreTranslationTaskStatus.canceled);
        await finished.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () =>
              throw TimeoutException('automatic task did not finish'),
        );
        expect(automatic.status, PreTranslationTaskStatus.completed);
        expect(manager.currentTasks, [manual]);

        allowance.value = false;
        final lateTask = task('late')..status = PreTranslationTaskStatus.paused;
        final lateFinished = Completer<void>();
        manager.onTaskFinished = (_) => lateFinished.complete();
        manager.currentTasks.add(lateTask);
        manager.resume(lateTask.id);
        await Future<void>.delayed(Duration.zero);
        expect(lateTask.status, PreTranslationTaskStatus.paused);
        expect(lateFinished.isCompleted, isFalse);
        allowance.value = true;
        await lateFinished.future.timeout(const Duration(seconds: 3));
        expect(lateTask.status, PreTranslationTaskStatus.completed);
        expect(manual.status, PreTranslationTaskStatus.paused);
      } finally {
        manager.onTaskFinished = null;
        manager.currentTasks.clear();
        manager.historyTasks.clear();
        allowance.value = true;
        // Drain the existing async implicit-data writer before removing its path.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await appdata
            .saveData(false)
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () =>
                  throw TimeoutException('cleanup persistence did not finish'),
            );
        App.dataPath = oldPath;
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
