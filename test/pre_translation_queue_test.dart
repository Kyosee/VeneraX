import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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
    var failingLoads = 0;
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
          if (eid == 'failed') {
            failingLoads++;
            if (failingLoads == 2) {
              retryStarted.complete();
              await retryRelease.future;
            }
            throw StateError('Fixture page listing failure');
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
    for (final eid in ['a', 'b']) {
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
      PreTranslationTask? queue(List<String> chapters) => manager.start(
        cid: 'book',
        sourceKey: sourceKey,
        comicType: ComicType.fromKey(sourceKey),
        title: 'Book',
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
      manager.activityOf(first.id)!.bufferedDone = 1;
      expect(
        manager.livePagesOf('book', sourceKey, first.chapters.first).done,
        1,
      );
      manager.activityOf(first.id)!.bufferedDone = 0;
      manager.resume(first.id);
      manager.cancelChapter(first.id, 'b');
      expect(queue(['b']), same(first));
      final requeued = first.chapters.last;
      expect(
        manager.chapterProgressFor('book', sourceKey, 'b'),
        same(requeued),
      );
      expect(requeued.canceled, isFalse);
      manager.cancelChapter(first.id, 'b');
      expect(requeued.canceled, isTrue);
      expect(queue(['b']), same(first));
      release.complete();
      final done = await finished.future.timeout(const Duration(seconds: 5));
      expect(done.status, PreTranslationTaskStatus.completed);
      expect(requested, ['a', 'b']);
      expect(done.done, 2);
      expect(done.failed, 0);

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
    } finally {
      if (!release.isCompleted) release.complete();
      if (!retryRelease.isCompleted) retryRelease.complete();
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
