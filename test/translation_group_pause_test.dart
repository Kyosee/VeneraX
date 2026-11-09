import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String oldDataPath;
  late String oldCachePath;
  final service = ImageTranslationService.instance;
  final config = TranslationConfig.of('group', 'test');
  final chapter = ImageTranslationService.chapterIdentity(
    cid: 'group',
    sourceKey: 'test',
    eid: 'chapter',
    config: config,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('translation-group-');
    oldDataPath = App.dataPath;
    oldCachePath = App.cachePath;
    App.dataPath = directory.path;
    App.cachePath = '${directory.path}/images';
    await TranslationStore().init();
    await CacheManager().ready;
  });

  tearDown(() async {
    TranslationStore().close();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    App.dataPath = oldDataPath;
    App.cachePath = oldCachePath;
    await directory.delete(recursive: true);
  });

  test(
    'pause between pages preserves the group and resumes without skipped pages',
    () async {
      final pages = [
        for (var i = 1; i <= 3; i++)
          (
            cacheKey: ImageTranslationService.cacheKeyFor(
              'test',
              'group',
              'chapter',
              i,
            ),
            legacyCacheKey: null,
            imageBytes: Uint8List(0),
          ),
      ];
      for (final page in pages) {
        TranslationStore().put(page.cacheKey, [], chapter: chapter);
      }
      var paused = false;
      var firstPage = true;
      final waiting = Completer<void>();
      final resumed = Completer<void>();
      final result = service.translatePageGroup(
        pages,
        'group@test',
        config,
        chapter: chapter,
        waitUntilResumed: () async {
          if (paused) {
            if (!waiting.isCompleted) waiting.complete();
            await resumed.future;
          }
        },
        onStage: (stage, _) {
          if (stage == TranslationStage.rendering && firstPage) {
            firstPage = false;
            paused = true;
          }
        },
      );
      try {
        await waiting.future.timeout(const Duration(seconds: 3));
        expect(
          service.statusOf(pages.first.cacheKey, config.mode),
          PageTranslationStatus.noContent,
        );
        expect(
          service.statusOf(pages[1].cacheKey, config.mode),
          PageTranslationStatus.idle,
        );
        paused = false;
        resumed.complete();
        expect(await result, [true, true, true]);
        for (final page in pages) {
          expect(
            service.statusOf(page.cacheKey, config.mode),
            PageTranslationStatus.noContent,
          );
        }
      } finally {
        if (!resumed.isCompleted) resumed.complete();
        await result;
      }
    },
  );

  test(
    'pause before OCR waits and cancellation does not become a failed page',
    () async {
      var paused = false;
      var canceled = false;
      final waiting = Completer<void>();
      final resumed = Completer<void>();
      final result = service.translatePageGroup(
        [
          (
            cacheKey: 'fresh-page',
            legacyCacheKey: null,
            imageBytes: Uint8List(0),
          ),
        ],
        'group@test',
        config,
        chapter: chapter,
        shouldCancel: () => canceled,
        waitUntilResumed: () async {
          if (paused) {
            if (!waiting.isCompleted) waiting.complete();
            await resumed.future;
          }
        },
        onStage: (stage, _) {
          if (stage == TranslationStage.loadingModel ||
              stage == TranslationStage.recognizing) {
            paused = true;
          }
        },
      );
      final canceledResult = expectLater(
        result,
        throwsA(isA<PipelineCanceled>()),
      );
      try {
        await waiting.future.timeout(const Duration(seconds: 3));
        expect(TranslationStore().get('fresh-page'), isNull);
      } finally {
        canceled = true;
        resumed.complete();
        await canceledResult;
      }
    },
  );
}
