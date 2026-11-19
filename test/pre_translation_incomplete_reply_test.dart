import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/translations.dart';

class _PageFixture extends PageTranslationPipeline {
  @override
  bool get ocrIsWarm => true;
  @override
  Future<PageOcr> ocrPage(
    Uint8List bytes, {
    required String sourceLang,
    required String targetLang,
  }) async => PageOcr([], [
    if (bytes.first != 0)
      OcrBlock(
        rect: IntRect(0, 0, 1, 1),
        text: 'line ${bytes.first}',
        language: 'en',
        backgroundColor: 0,
        textColor: 0,
      ),
  ], {});
  @override
  Future<Uint8List> renderPage(
    Uint8List bytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
  }) async => Uint8List.fromList([42]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test(
    'incomplete bubbles fail while blank pages and unchanged names remain valid',
    () {
      final pipeline = PageTranslationPipeline();
      OcrBlock block(String text) => OcrBlock(
        rect: IntRect(0, 0, 1, 1),
        text: text,
        language: 'en',
        backgroundColor: 0,
        textColor: 0,
      );
      final bubbles = [block('Hello'), block('Alice')];
      for (final response in <List<String>>[
        ['你好'],
        ['你好', '   '],
        ['你好', 'Alice', 'unexpected extra line'],
      ]) {
        expect(
          () => pipeline.regionsFromTranslation(bubbles, response),
          throwsFormatException,
        );
      }
      expect(pipeline.regionsFromTranslation([], []), isEmpty);
      expect(
        pipeline.regionsFromTranslation(bubbles, ['你好', 'Alice']).single.text,
        '你好',
      );
    },
  );

  test(
    'an incomplete reply fails only its page; retry uses the original without erasing completed pages',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'translation-partial-',
      );
      final oldPath = App.dataPath, oldCache = App.cachePath;
      App.dataPath = temp.path;
      App.cachePath = '${temp.path}/images';
      await TranslationStore().init();
      await CacheManager().ready;
      addTearDown(() async {
        TranslationStore().close();
        DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
        CacheManager.instance = null;
        App.dataPath = oldPath;
        App.cachePath = oldCache;
        await temp.delete(recursive: true);
      });
      appdata.settings['imageTranslationProviders'] = [
        {'id': 'fixture', 'kind': 'script', 'name': 'fixture'},
      ];
      appdata.settings['imageTranslationScripts'] = {
        'fixture':
            'function translate(request) { return request.texts.map(text => text === "line 2" ? " " : "译文"); }',
      };
      final service = ImageTranslationService.withPipeline(_PageFixture());
      final config = TranslationConfig.of('book', 'source');
      final chapter = ImageTranslationService.chapterIdentity(
        cid: 'book',
        sourceKey: 'source',
        eid: '34.2',
        config: config,
      );
      final pages = [
        for (final (i, value) in [1, 2, 0].indexed)
          (
            cacheKey: ImageTranslationService.cacheKeyFor(
              'source',
              'book',
              '34.2',
              i + 1,
            ),
            legacyCacheKey: null as String?,
            imageBytes: Uint8List.fromList([value]),
          ),
      ];
      expect(
        await service.translatePageGroup(
          pages,
          'book@source',
          config,
          chapter: chapter,
        ),
        [true, false, true],
      );
      expect(TranslationStore().get(pages[1].cacheKey), isNull);
      expect(TranslationStore().get(pages[2].cacheKey), isEmpty);
      final shown = Completer<void>();
      appdata.settings['imageTranslationScripts'] = {
        'fixture':
            'function translate(request) { return request.texts.map(text => "补译"); }',
      };
      service.schedule(
        pages[1].cacheKey,
        'book',
        'source',
        pages[1].imageBytes,
        config,
        shown.complete,
        chapter: chapter,
      );
      await shown.future.timeout(const Duration(seconds: 5));
      expect(service.isTranslated(pages[1].cacheKey, config.mode), isTrue);
      expect(TranslationStore().get(pages[0].cacheKey)!.single.text, '译文');
      expect(TranslationStore().get(pages[1].cacheKey)!.single.text, '补译');

      final switchingPage = (
        cacheKey: ImageTranslationService.cacheKeyFor(
          'source',
          'book',
          '34.2',
          4,
        ),
        legacyCacheKey: null as String?,
        imageBytes: Uint8List.fromList([1]),
      );
      await expectLater(
        service.translatePageGroup(
          [switchingPage],
          'book@source',
          config,
          chapter: chapter,
          // Switch chapters after the reply arrives, before rendering starts.
          shouldCancel: () =>
              TranslationStore().get(switchingPage.cacheKey) != null,
        ),
        throwsA(isA<PipelineCanceled>()),
      );
      expect(TranslationStore().get(switchingPage.cacheKey)!.single.text, '补译');
      // A resumed chapter uses its cached reply, even if inference is unavailable.
      appdata.settings['imageTranslationScripts'] = {
        'fixture':
            'function translate(request) { throw new Error("Unexpected repeated request"); }',
      };
      expect(
        await service.translatePageGroup(
          [switchingPage],
          'book@source',
          config,
          chapter: chapter,
        ),
        [true],
      );
    },
  );
}
