import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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
  final started = Completer<void>();
  final groupOcr = Completer<void>();
  final analysis = Completer<PageAnalysis>();
  var requests = 0;
  List<TranslatedRegion> previousRegions = [];
  bool maskAvailable = false;
  @override
  bool get ocrIsWarm => true;

  @override
  Future<PageOcr> ocrPage(
    Uint8List bytes, {
    required String sourceLang,
    required String targetLang,
    bool dialogueOnly = false,
    List<TranslatedRegion> previous = const [],
  }) async {
    if (!groupOcr.isCompleted) groupOcr.complete();
    return PageOcr([], [
      OcrBlock(
        rect: IntRect(0, 0, 2, 2),
        text: 'source',
        language: 'en',
        backgroundColor: 0,
        textColor: 0,
      ),
    ], {});
  }

  @override
  Future<PageAnalysis> analyzePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    Map<String, String> glossary = const {},
    bool dialogueOnly = false,
    List<TranslatedRegion> previous = const [],
  }) {
    requests++;
    if (!started.isCompleted) started.complete();
    previousRegions = previous;
    return analysis.future;
  }

  @override
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
    bool enhanceStrokes = false,
    void Function()? onStrokeMask,
  }) async {
    if (enhanceStrokes && maskAvailable) onStrokeMask?.call();
    return Uint8List.fromList([42]);
  }
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

  test(
    'changing modes during a reader request pays once and renders both modes',
    () async {
      final page = ImageTranslationService.cacheKeyFor('src', 'book', 'ch', 9);
      final oldMode = appdata.settings[TranslationConfig.inpaintKeyName];
      addTearDown(
        () => appdata.settings[TranslationConfig.inpaintKeyName] = oldMode,
      );
      final first = Completer<void>(), second = Completer<void>();
      void request(TranslationConfig selection, Completer<void> done) {
        service.schedule(
          page,
          'book',
          'src',
          Uint8List.fromList([9]),
          selection,
          done.complete,
          chapter: chapter,
        );
      }

      request(config, first);
      await pipeline.started.future.timeout(const Duration(seconds: 5));
      appdata.settings[TranslationConfig.inpaintKeyName] = 'patch';
      final other = TranslationConfig.of('book', 'src');
      expect(other.mode, isNot(config.mode));
      request(other, second);
      pipeline.analysis.complete(PageAnalysis([region('dialogue')], {}));
      await Future.wait([
        first.future,
        second.future,
      ]).timeout(const Duration(seconds: 5));
      expect(pipeline.requests, 1);
      for (final mode in InpaintMode.values) {
        expect(await service.hasRenderedPage(page, mode), isTrue);
      }
    },
  );

  test(
    'empty dialogue results do not cover full text, and switching erase modes reuses paid text',
    () async {
      final all = ImageTranslationService.cacheKeyFor('src', 'book', 'ch', 8);
      final dialogue = config.alternateScopeKey(all)!;
      TranslationStore().put(dialogue, []);
      pipeline.analysis.complete(PageAnalysis([region('caption')], {}));
      Future<bool> translate(TranslationConfig selection) =>
          service.translateOne(
            all,
            'book@src',
            Uint8List.fromList([8]),
            selection,
            chapter: chapter,
          );
      expect(await translate(config), isTrue);
      expect(pipeline.requests, 1);
      final patch = TranslationConfig(
        sourceLang: config.sourceLang,
        targetLang: config.targetLang,
        mode: InpaintMode.patch,
      );
      expect(await translate(patch), isTrue);
      expect(pipeline.requests, 1);
      expect(
        ImageTranslationService.pageTranslation(all, null).single.text,
        'caption',
      );
      expect(ImageTranslationService.pageTranslation(dialogue, null), isEmpty);
    },
  );

  test(
    'a chapter shares an in-flight reader translation across render modes',
    () async {
      final page = ImageTranslationService.cacheKeyFor('src', 'book', 'ch', 11);
      final image = Uint8List.fromList([11]);
      final rendered = Completer<void>();
      service.schedule(
        page,
        'book',
        'src',
        image,
        config,
        rendered.complete,
        chapter: chapter,
      );
      await pipeline.started.future.timeout(const Duration(seconds: 5));
      final patch = TranslationConfig(
        sourceLang: config.sourceLang,
        targetLang: config.targetLang,
        mode: InpaintMode.patch,
      );
      final batch = service.translatePageGroup(
        [(cacheKey: page, legacyCacheKey: null, imageBytes: image)],
        'book@src',
        patch,
        chapter: chapter,
      );
      await pipeline.groupOcr.future.timeout(const Duration(seconds: 5));
      pipeline.analysis.complete(PageAnalysis([region('shared')], {}));
      await rendered.future.timeout(const Duration(seconds: 5));
      expect(await batch, [true]);
      expect(pipeline.requests, 1);
      expect(TranslationStore().get(page)!.single.text, 'shared');
      for (final mode in InpaintMode.values) {
        expect(await service.hasRenderedPage(page, mode), isTrue);
      }
    },
  );

  test(
    'dialogue analysis receives the existing full-page text for identical OCR lines',
    () async {
      final dialogue = TranslationConfig(
        sourceLang: config.sourceLang,
        targetLang: config.targetLang,
        mode: config.mode,
        dialogueOnly: true,
      );
      final scoped =
          dialogue.alternateScopeKey(key) ?? config.alternateScopeKey(key)!;
      pipeline.analysis.complete(PageAnalysis([region('old')], {}));
      await service.translateOne(
        scoped,
        'book@src',
        Uint8List.fromList([1]),
        dialogue,
        chapter: ImageTranslationService.chapterIdentity(
          cid: 'book',
          sourceKey: 'src',
          eid: 'ch',
          config: dialogue,
        ),
      );
      final block = OcrBlock(
        rect: IntRect(0, 0, 2, 2),
        text: 'source',
        language: 'en',
        backgroundColor: 0,
        textColor: 0,
      );
      expect(
        PageTranslationPipeline.matchingTranslation(
          block,
          pipeline.previousRegions,
        )?.text,
        'old',
      );
      final moved = OcrBlock(
        rect: IntRect(1, 1, 3, 3),
        text: 'source',
        language: 'en',
        backgroundColor: 0,
        textColor: 0,
      );
      expect(
        PageTranslationPipeline.matchingTranslation(
          moved,
          pipeline.previousRegions,
        ),
        isNull,
      );
    },
  );

  test(
    'the reader prefers an enhanced retry while a fallback stays eligible for enhancement',
    () async {
      pipeline.maskAvailable = true;
      pipeline.analysis.complete(PageAnalysis([region('new')], {}));
      expect(await run(), isTrue);
      expect(
        await service.hasRenderedPage(key, config.mode, enhanceStrokes: true),
        isTrue,
      );
      expect(
        await (await service.findTranslated(key, config.mode))!.readAsBytes(),
        [42],
      );
      expect(
        await service.hasRenderedPage(
          neighbor,
          config.mode,
          enhanceStrokes: true,
        ),
        isFalse,
      );
      ReaderImageProvider provider(TranslationConfig selection) =>
          ReaderImageProvider(
            'image',
            'src',
            'book',
            'ch',
            1,
            translationKey: key,
            translationConfig: selection,
            translated: true,
          );
      expect(
        provider(config),
        isNot(
          provider(
            TranslationConfig(
              sourceLang: config.sourceLang,
              targetLang: config.targetLang,
              mode: InpaintMode.patch,
            ),
          ),
        ),
      );
    },
  );
}
