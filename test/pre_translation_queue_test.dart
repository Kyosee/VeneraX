import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new selections join a running queue once and are processed', () async {
    final temp = await Directory.systemTemp.createTemp('translation-queue-');
    final oldData = App.dataPath, oldCache = App.cachePath;
    final wasBackgroundTask = App.isBackgroundTask;
    App.isBackgroundTask = true;
    App.dataPath = temp.path;
    App.cachePath = '${temp.path}/cache';
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await CacheManager().ready;
    await TranslationStore().init();
    appdata.settings['imageTranslationProviders'] = [
      {'id': 'fixture', 'name': 'Fixture', 'kind': 'public'},
    ];
    for (final model in [
      TranslationModels.activeDetector,
      TranslationModels.ocrEn,
    ]) {
      Directory(model.directory).createSync(recursive: true);
      for (final file in model.files) {
        File(model.filePath(file.name)).writeAsBytesSync([1]);
      }
    }
    TranslationModels.invalidateReadyCache();
    final image = File('${temp.path}/page.png')..writeAsBytesSync([1]);
    final started = Completer<void>(), release = Completer<void>();
    final finished = Completer<PreTranslationTask>();
    final requested = <String>[];
    final retryStarted = Completer<void>(), retryRelease = Completer<void>();
    final recoveryStarted = Completer<void>();
    final recoveryRelease = Completer<void>();
    final ninthStarted = Completer<void>(), ninthRelease = Completer<void>();
    final tenthStarted = Completer<void>(), tenthRelease = Completer<void>();
    var failingLoads = 0;
    var recoveringLoads = 0;
    const sourceKey = 'queue-test';
    ComicSourceManager().add(
      ComicSource(
        'Fixture',
        sourceKey,
        null,
        null,
        null,
        null,
        const [],
        null,
        null,
        null,
        null,
        (cid, eid) async {
          requested.add(eid!);
          if (eid == '9' && !ninthStarted.isCompleted) {
            ninthStarted.complete();
            await ninthRelease.future;
          }
          if (eid == '10' && !tenthStarted.isCompleted) {
            tenthStarted.complete();
            await tenthRelease.future;
          }
          if (eid == 'failed') {
            failingLoads++;
            if (failingLoads == 2) {
              retryStarted.complete();
              await retryRelease.future;
            }
            throw StateError('Fixture page listing failure');
          }
          if (eid == 'recovered') {
            recoveringLoads++;
            if (recoveringLoads == 1) {
              throw StateError('Fixture first page listing failure');
            }
            if (recoveringLoads == 2) {
              recoveryStarted.complete();
              await recoveryRelease.future;
            }
          }
          if (eid == 'a') {
            started.complete();
            await release.future;
          }
          return Res(['file://${image.path}']);
        },
        null,
        null,
        '',
        '',
        '1',
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
      ),
    );
    final config = TranslationConfig.of('book', sourceKey);
    // Another downloaded chapter must not route every chapter to local files.
    await LocalManager().add(
      LocalComic(
        id: 'book',
        title: 'Book',
        subtitle: '',
        tags: const [],
        directory: temp.path,
        chapters: ComicChapters({
          'downloaded-only': 'Downloaded',
          'a': 'A',
          'b': 'B',
        }),
        cover: 'page.png',
        comicType: ComicType.fromKey(sourceKey),
        downloadedChapters: ['downloaded-only'],
        createdAt: DateTime(2026),
      ),
    );
    for (final eid in ['a', 'b', '9', '10', 'rapid', 'recovered']) {
      TranslationStore().put(
        ImageTranslationService.cacheKeyFor(sourceKey, 'book', eid, 1),
        [],
        chapter: ImageTranslationService.chapterIdentity(
          cid: 'book',
          sourceKey: sourceKey,
          eid: eid,
          config: config,
        ),
      );
    }
    final manager = PreTranslationTaskManager.instance;
    manager.onTaskFinished = finished.complete;
    try {
      PreTranslationTask? queue(
        List<String> chapters, [
        TranslationConfig? config,
      ]) => manager.start(
        cid: 'book',
        sourceKey: sourceKey,
        comicType: ComicType.fromKey(sourceKey),
        title: 'Book',
        config: config,
        chapters: chapters
            .map((eid) => PreTranslationChapter(eid: eid, title: eid))
            .toList(),
      );
      final first = queue(['a']);
      await started.future.timeout(const Duration(seconds: 3));
      expect(queue(['a', 'b', 'b']), same(first));
      expect(first!.chapters.map((chapter) => chapter.eid), ['a', 'b']);
      manager.pause(first.id);
      expect(queue(['b']), same(first));
      expect(first.status, PreTranslationTaskStatus.paused);
      expect(manager.currentTasks, [first]);
      appdata.settings[TranslationConfig.scopeKeyName] = 'dialogue';
      final dialogue = TranslationConfig.of('book', sourceKey);
      final dialogueKey = ImageTranslationService.cacheKeyFor(
        sourceKey,
        'book',
        'b',
        1,
        config: dialogue,
      );
      final oldDialogueKey = ImageTranslationService.legacyCacheKeyFor(
        'file://${image.path}',
        sourceKey,
        'book',
        'b',
        config: dialogue,
      );
      TranslationStore().put(
        oldDialogueKey,
        [],
        chapter: ImageTranslationService.chapterIdentity(
          cid: 'book',
          sourceKey: sourceKey,
          eid: 'b',
          config: dialogue,
        ),
      );
      final dialogueFinished = Completer<PreTranslationTask>();
      manager.onTaskFinished = dialogueFinished.complete;
      final dialogueTask = queue(['b'])!;
      expect(dialogueTask, isNot(same(first)));
      expect(first.config.dialogueOnly, isFalse);
      expect(
        manager.chapterProgressFor('book', sourceKey, 'b'),
        same(dialogueTask.chapters.single),
      );
      expect(
        manager.chapterProgressFor('book', sourceKey, 'b', config: config),
        same(first.chapters.last),
      );
      await dialogueFinished.future.timeout(const Duration(seconds: 5));
      expect(dialogueTask.done, 1);
      expect(TranslationStore().get(dialogueKey), isEmpty);
      expect(TranslationStore().get(oldDialogueKey), isNull);
      expect(manager.isChapterActive('book', sourceKey, 'b'), isFalse);
      expect(
        manager.isChapterActive('book', sourceKey, 'b', config: config),
        isTrue,
      );
      manager.resetComicStatus('book', sourceKey, config: dialogue);
      expect(manager.chapterProgressFor('book', sourceKey, 'b'), isNull);
      manager.onTaskFinished = finished.complete;
      manager.activityOf(first.id)!.bufferedDone = 1;
      expect(
        manager.livePagesOf('book', sourceKey, first.chapters.first).done,
        1,
      );
      manager.activityOf(first.id)!.bufferedDone = 0;
      manager.resume(first.id);
      manager.cancelChapter(first.id, 'b');
      expect(queue(['b'], config), same(first));
      final requeued = first.chapters.last;
      expect(
        manager.chapterProgressFor('book', sourceKey, 'b', config: config),
        same(requeued),
      );
      expect(requeued.canceled, isFalse);
      manager.cancelChapter(first.id, 'b');
      expect(requeued.canceled, isTrue);
      expect(queue(['b'], config), same(first));
      release.complete();
      final done = await finished.future.timeout(const Duration(seconds: 5));
      expect(done.status, PreTranslationTaskStatus.completed);
      expect(requested, ['a', 'b', 'b']);
      expect(done.done, 2);
      expect(done.failed, 0);
      appdata.settings[TranslationConfig.scopeKeyName] = 'all';

      requested.clear();
      final retryFinished = Completer<PreTranslationTask>();
      manager.onTaskFinished = retryFinished.complete;
      final retrying = queue(['failed']);
      await retryStarted.future.timeout(const Duration(seconds: 3));
      expect(queue(['b']), same(retrying));
      retryRelease.complete();
      final afterRetry = await retryFinished.future.timeout(
        const Duration(seconds: 5),
      );
      expect(requested, ['failed', 'failed', 'b']);
      expect(afterRetry.done, 1);
      expect(afterRetry.failed, 1);

      requested.clear();
      final recoveryFinished = Completer<PreTranslationTask>();
      manager.onTaskFinished = recoveryFinished.complete;
      final recovering = queue(['recovered'])!;
      await recoveryStarted.future.timeout(const Duration(seconds: 3));
      manager.pauseChapter(recovering.id, 'recovered');
      recoveryRelease.complete();
      final recoveryDeadline = DateTime.now().add(const Duration(seconds: 3));
      while ((recovering.isRunning || recovering.chapters.single.total == 0) &&
          DateTime.now().isBefore(recoveryDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(recovering.status, PreTranslationTaskStatus.paused);
      expect(recovering.chapters.single.total, 1);
      expect(recovering.done, 0);
      expect(recoveryFinished.isCompleted, isFalse);
      manager.resumeChapter(recovering.id, 'recovered');
      final recovered = await recoveryFinished.future.timeout(
        const Duration(seconds: 3),
      );
      expect(recovered.done, 1);
      expect(recovered.failed, 0);
      expect(recovered.status, PreTranslationTaskStatus.completed);
      expect(requested, ['recovered', 'recovered', 'recovered']);

      requested.clear();
      final chapterFinished = Completer<PreTranslationTask>();
      manager.onTaskFinished = chapterFinished.complete;
      final switching = queue(['9', '10'])!;
      await ninthStarted.future.timeout(const Duration(seconds: 3));
      manager.pause(switching.id);
      manager.resumeChapter(switching.id, '10');
      expect(switching.chapters.first.paused, isTrue);
      expect(switching.chapters.last.paused, isFalse);
      ninthRelease.complete();
      await tenthStarted.future.timeout(const Duration(seconds: 3));
      expect(switching.chapters.first.done, 0);
      expect(manager.activityOf(switching.id)!.chapterEid, '10');
      BackgroundKeepAlive.instance.translationBackgroundAllowed.value = false;
      BackgroundKeepAlive.instance.translationBackgroundAllowed.value = true;
      expect(switching.chapters.first.paused, isTrue);
      expect(switching.chapters.last.paused, isFalse);
      manager.pauseChapter(switching.id, '10');
      tenthRelease.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(switching.status, PreTranslationTaskStatus.paused);
      expect(chapterFinished.isCompleted, isFalse);
      final snapshot = PreTranslationTask.fromJson(switching.toJson());
      expect(snapshot.chapters.every((chapter) => chapter.paused), isTrue);

      manager.resumeChapter(switching.id, '10');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (switching.chapters.last.done == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(switching.chapters.last.done, 1);
      expect(switching.chapters.first.done, 0);
      expect(switching.chapters.first.paused, isTrue);
      expect(manager.currentTasks, contains(switching));
      manager.resumeChapter(switching.id, '9');
      final switched = await chapterFinished.future.timeout(
        const Duration(seconds: 3),
      );
      expect(switched.done, 2);
      expect(switched.failed, 0);
      expect(requested, ['9', '10', '10', '9']);
      expect(switched.status, PreTranslationTaskStatus.completed);

      requested.clear();
      final rapidFinished = Completer<PreTranslationTask>();
      manager.onTaskFinished = rapidFinished.complete;
      var interrupted = false;
      void rapidToggle() {
        final task = manager.currentTasks
            .where((t) => t.chapters.singleOrNull?.eid == 'rapid')
            .firstOrNull;
        if (task == null || interrupted || task.chapters.single.total == 0) {
          return;
        }
        interrupted = true;
        manager.pauseChapter(task.id, 'rapid');
        scheduleMicrotask(() => manager.resumeChapter(task.id, 'rapid'));
      }

      manager.addListener(rapidToggle);
      try {
        queue(['rapid']);
        final rapid = await rapidFinished.future.timeout(
          const Duration(seconds: 3),
        );
        expect(rapid.done, 1);
        expect(rapid.failed, 0);
        expect(requested, ['rapid', 'rapid']);
      } finally {
        manager.removeListener(rapidToggle);
      }

      final retryPaused = queue(['failed', 'b'])!;
      manager.pauseChapter(retryPaused.id, 'b');
      Future<void> waitForPause() async {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (retryPaused.isRunning && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(retryPaused.status, PreTranslationTaskStatus.paused);
      }

      await waitForPause();
      final beforeManualRetry = failingLoads;
      manager.retryChapter(retryPaused.id, 'failed');
      await waitForPause();
      expect(failingLoads, beforeManualRetry + 1);
      expect(retryPaused.chapters.last.paused, isTrue);
      final canceledRetry = Completer<PreTranslationTask>();
      manager.onTaskFinished = canceledRetry.complete;
      manager.cancel(retryPaused.id);
      await canceledRetry.future.timeout(const Duration(seconds: 3));
    } finally {
      if (!release.isCompleted) release.complete();
      if (!retryRelease.isCompleted) retryRelease.complete();
      if (!recoveryRelease.isCompleted) recoveryRelease.complete();
      if (!ninthRelease.isCompleted) ninthRelease.complete();
      if (!tenthRelease.isCompleted) tenthRelease.complete();
      manager.onTaskFinished = null;
      manager.currentTasks.clear();
      manager.historyTasks.clear();
      await appdata.writeImplicitData();
      TranslationStore().close();
      LocalManager().close();
      DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
      CacheManager.instance = null;
      ComicSourceManager().remove(sourceKey);
      JsEngine().dispose();
      App.dataPath = oldData;
      App.cachePath = oldCache;
      App.isBackgroundTask = wasBackgroundTask;
      debugDefaultTargetPlatformOverride = null;
      await temp.delete(recursive: true);
    }
  });
}
