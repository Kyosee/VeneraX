import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/sqlite_connection.dart';

TranslatedRegion region(String text) => TranslatedRegion(
  rect: IntRect(0, 0, 2, 2),
  text: text,
  backgroundColor: 0,
  textColor: 0,
);

class _Pipeline extends Fake implements PageTranslationPipeline {
  final analysis = Completer<PageAnalysis>();
  var requests = 0;
  @override
  Future<PageAnalysis> analyzePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    Map<String, String> glossary = const {},
  }) {
    requests++;
    return analysis.future;
  }

  @override
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
  }) async => Uint8List.fromList([42]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String oldPath, oldCache;
  late _Pipeline pipeline;
  late ImageTranslationService service;
  final config = TranslationConfig.of('book', 'src');
  final chapter = ImageTranslationService.chapterIdentity(
    cid: 'book',
    sourceKey: 'src',
    eid: 'ch',
    config: config,
  );
  final key = ImageTranslationService.cacheKeyFor('src', 'book', 'ch', 1);
  final neighbor = ImageTranslationService.cacheKeyFor('src', 'book', 'ch', 10);
  Future<bool> run() => service.retranslatePage(
    key,
    'book@src',
    Uint8List.fromList([1]),
    config,
    chapter: chapter,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('page-retranslation-');
    oldPath = App.dataPath;
    oldCache = App.cachePath;
    App.dataPath = temp.path;
    App.cachePath = '${temp.path}/cache';
    await TranslationStore().init();
    await CacheManager().ready;
    pipeline = _Pipeline();
    service = ImageTranslationService.withPipeline(pipeline);
    for (final k in [key, neighbor]) {
      TranslationStore().put(k, [region('old')], chapter: chapter);
      for (final mode in InpaintMode.values) {
        await CacheManager().writeCache(
          ImageTranslationService.renderedKey(k, mode),
          [3],
        );
      }
    }
  });
  tearDown(() async {
    TranslationStore().close();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    App.dataPath = oldPath;
    App.cachePath = oldCache;
    await temp.delete(recursive: true);
  });
  test(
    'a paid retry replaces only the chosen page and its render variants',
    () async {
      final work = run();
      expect(
        service.statusOf(key, config.mode),
        PageTranslationStatus.translating,
      );
      await expectLater(run(), throwsStateError);
      pipeline.analysis.complete(PageAnalysis([region('new')], {}));
      expect(await work, isTrue);
      expect(pipeline.requests, 1);
      expect(service.revisionOf(key), 1);
      expect(service.revisionOf(neighbor), 0);
      expect(TranslationStore().get(key)!.single.text, 'new');
      expect(TranslationStore().get(neighbor)!.single.text, 'old');
      for (final mode in InpaintMode.values) {
        final current = await service.findTranslated(key, mode);
        if (mode == config.mode) {
          expect(await current!.readAsBytes(), [42]);
        } else {
          expect(current, isNull);
        }
        expect(
          await (await service.findTranslated(neighbor, mode))!.readAsBytes(),
          [3],
        );
      }
      final original = ReaderImageProvider(
        'image',
        'src',
        'book',
        'ch',
        1,
        translationKey: key,
        translated: true,
      );
      final updated = ReaderImageProvider(
        'image',
        'src',
        'book',
        'ch',
        1,
        translationKey: key,
        translated: true,
        translationRevision: 1,
      );
      expect(updated, isNot(original));
      expect(updated.diskCacheKey, original.diskCacheKey);
    },
  );
  test(
    'a failed retry keeps the prior translation and rendered page',
    () async {
      final check = expectLater(run(), throwsStateError);
      pipeline.analysis.completeError(StateError('offline'));
      await check;
      expect(TranslationStore().get(key)!.single.text, 'old');
      expect(
        await (await service.findTranslated(key, config.mode))!.readAsBytes(),
        [3],
      );
    },
  );
  test('a retry with no recognized text keeps the prior translation', () async {
    pipeline.analysis.complete(PageAnalysis([], {}));
    expect(await run(), isFalse);
    expect(TranslationStore().get(key)!.single.text, 'old');
    expect(
      await (await service.findTranslated(key, config.mode))!.readAsBytes(),
      [3],
    );
  });
}
