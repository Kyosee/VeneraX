import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/shortcuts.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _CachedPage implements File {
  _CachedPage(this.bytes);

  final Uint8List bytes;
  var reads = 0;

  @override
  String get path => 'translation-shortcut-test.png';
  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PageCache implements CacheManager {
  final pages = <String, File>{};

  @override
  Future<File?> findCache(String key, [int duration = 604800000]) async =>
      pages[key];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'translation_shortcut_test';
  const comicId = 'shortcut-comic';
  const chapterId = 'chapter-two';
  const chapters = ComicChapters({'chapter-one': 'One', chapterId: 'Two'});
  final images = [
    for (var page = 1; page <= 4; page++)
      'https://translation-shortcut.invalid/$page.png',
  ];
  late Directory temporary;
  late ComicSource source;
  late _CachedPage translated;
  var chapterRequests = 0;

  Future<_CachedPage> page(Color color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(300, 600);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return _CachedPage(bytes!.buffer.asUint8List());
  }

  setUpAll(() async {
    Log.isMuted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temporary = Directory.systemTemp.createTempSync('translation-shortcut-');
    App.dataPath = temporary.path;
    App.cachePath = '${temporary.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    debugDefaultTargetPlatformOverride = null;
    source = ComicSource(
      'Translation shortcut test',
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
      (id, chapter) async {
        chapterRequests++;
        return Res(List<String>.of(images));
      },
      (image, cid, eid) async {
        throw const HttpException('Network is disabled in this test');
      },
      null,
      '',
      '',
      '1.0.0',
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
    );
    ComicSourceManager().add(source);
    final original = await page(Colors.green);
    translated = await page(Colors.purple);
    final cache = _PageCache();
    for (final chapter in chapters.ids) {
      for (var index = 0; index < images.length; index++) {
        cache.pages[ImageDownloader.imageCacheKey(
              images[index],
              sourceKey,
              comicId,
              chapter,
            )] =
            original;
        final key = ImageTranslationService.cacheKeyFor(
          sourceKey,
          comicId,
          chapter,
          index + 1,
        );
        cache.pages[ImageTranslationService.renderedKey(
              key,
              TranslationConfig.of(comicId, sourceKey).mode,
            )] =
            translated;
      }
    }
    CacheManager.instance = cache;
  });

  tearDownAll(() async {
    ImageDownloader.cancelAllLoadingImages();
    ComicSourceManager().remove(sourceKey);
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    CacheManager.instance = null;
    App.isBackgroundTask = false;
    Log.isMuted = false;
    debugDefaultTargetPlatformOverride = null;
    final parent = Directory.systemTemp.absolute.path;
    if (!temporary.absolute.path.startsWith(
      '$parent${Platform.pathSeparator}',
    )) {
      throw StateError('Test directory must remain inside system temp');
    }
    await temporary.delete(recursive: true);
  });

  testWidgets(
    'translation shortcut switches real reader pages and keeps position',
    (tester) async {
      App.isBackgroundTask = true;
      const windowChannel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      for (final entry in <String, dynamic>{
        'language': 'en-US',
        'adaptiveReading': false,
        'readerScreenPicNumberForPortrait': 1,
        'readerScreenPicNumberForLandscape': 1,
        'showSingleImageOnFirstPage': false,
        'showChapterComments': false,
        'enableContinuousChapterReading': false,
        'enableClockAndBatteryInfoInReader': false,
        'enableTurnPageByVolumeKey': false,
        'autoRemoveFromReadLater': false,
        'enablePageAnimation': false,
        'limitImageWidth': false,
        'autoFullscreenOnRead': false,
        'preloadImageCount': 0,
        'imageTranslationProviders': <dynamic>[],
        'keyboardShortcuts': <String, dynamic>{},
      }.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      appdata.implicitData.remove('translationGuidePrompts');
      ImageTranslationService.setEnabledForComic(
        'other-comic',
        sourceKey,
        true,
      );

      Future<void> pumpIo() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }

      Future<void> settleImages(dynamic reader) async {
        for (var i = 0; i < 100; i++) {
          await pumpIo();
          if (!reader.isLoading &&
              PaintingBinding.instance.imageCache.pendingImageCount == 0) {
            break;
          }
        }
        expect(reader.isLoading, isFalse);
        expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
        await tester.pumpAndSettle();
      }

      void checkProviders(bool enabled) {
        final providers = [
          ...tester
              .widgetList<ComicImage>(find.byType(ComicImage))
              .map((image) => image.image),
          ...tester
              .widgetList<PhotoView>(find.byType(PhotoView))
              .map((image) => image.imageProvider),
        ].whereType<ReaderImageProvider>().toList();
        expect(
          providers,
          isNotEmpty,
          reason: '${appdata.settings['readerMode']}: translation=$enabled',
        );
        for (final provider in providers) {
          expect(provider.translationKey != null, enabled);
        }
        expect(
          ImageTranslationService.isEnabledForComic('other-comic', sourceKey),
          isTrue,
        );
        expect(
          ImageTranslationService.isEnabledForComic(comicId, 'other-source'),
          isFalse,
        );
      }

      Future<void> checkPixels(bool translated) async {
        final images = tester.widgetList<RawImage>(
          find.descendant(
            of: find.byType(Reader),
            matching: find.byType(RawImage),
          ),
        );
        expect(images, isNotEmpty);
        for (final image in images) {
          final pixels = await tester.runAsync(
            () => image.image!.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          expect(
            pixels!.buffer.asUint8List(0, 4),
            translated ? [156, 39, 176, 255] : [76, 175, 80, 255],
          );
        }
      }

      for (final mode in ['galleryLeftToRight', 'continuousTopToBottom']) {
        appdata.settings['readerMode'] = mode;
        ImageTranslationService.setEnabledForComic(comicId, sourceKey, false);
        final history = History.fromMap({
          'id': comicId,
          'type': source.intKey,
          'title': 'Shortcut test',
          'ep': 2,
          'page': 2,
        });
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => WindowFrame(child!),
              home: Scaffold(
                body: Reader(
                  type: ComicType(source.intKey),
                  cid: comicId,
                  name: 'Shortcut test',
                  chapters: chapters,
                  history: history,
                  initialChapter: 2,
                  initialPage: 2,
                  author: '',
                  tags: const [],
                ),
              ),
            ),
          );
          final dynamic reader = tester.state(find.byType(Reader));
          await settleImages(reader);
          expect((reader.chapter, reader.page), (2, 2));
          checkProviders(false);
          await checkPixels(false);

          if (mode == 'galleryLeftToRight') {
            expect(TranslationGuidePage.showAutomatically, isTrue);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.f8);
            await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f8);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.f8);
            await tester.pumpAndSettle();
            expect(find.byType(TranslationGuidePage), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.f8);
            await tester.pumpAndSettle();
            expect(
              find.byType(TranslationGuidePage, skipOffstage: false),
              findsOneWidget,
            );
            expect(
              ImageTranslationService.isEnabledForComic(comicId, sourceKey),
              isFalse,
            );
            await tester.binding.handlePopRoute();
            await settleImages(reader);
            expect(find.byType(TranslationGuidePage), findsNothing);
            expect(
              ImageTranslationService.isEnabledForComic(comicId, sourceKey),
              isFalse,
            );
            expect((reader.chapter, reader.page), (2, 2));
            await TranslationGuidePage.setShowAutomatically(false);
          }

          ScrollController? scroll;
          if (mode == 'continuousTopToBottom') {
            scroll = tester
                .widget<CustomScrollView>(find.byType(CustomScrollView).first)
                .controller!;
            scroll.jumpTo(scroll.offset + 73);
            await settleImages(reader);
          }
          final position = (reader.chapter, reader.page);
          final offset = scroll?.offset;
          final requests = chapterRequests;
          final oldReads = translated.reads;

          await tester.sendKeyDownEvent(LogicalKeyboardKey.f8);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isTrue,
          );
          checkProviders(true);
          expect(translated.reads, greaterThan(oldReads));
          await checkPixels(true);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f8);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.f8);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isTrue,
          );
          expect((reader.chapter, reader.page), position);
          if (scroll != null) expect(scroll.offset, closeTo(offset!, 0.01));

          reader.toggleShowOriginalPages();
          await settleImages(reader);
          checkProviders(false);
          expect(reader.showOriginalPages, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.f8);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isFalse,
          );
          expect(reader.showOriginalPages, isFalse);
          checkProviders(false);
          await tester.sendKeyEvent(LogicalKeyboardKey.f8);
          await settleImages(reader);
          checkProviders(true);

          appdata.settings['keyboardShortcuts'] = {
            'toggleImageTranslation': const KeyBinding(
              LogicalKeyboardKey.f9,
            ).encode(),
          };
          await tester.sendKeyEvent(LogicalKeyboardKey.f8);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isTrue,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.f9);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isFalse,
          );
          checkProviders(false);
          appdata.settings['keyboardShortcuts'] = {
            'toggleImageTranslation': '',
          };
          await tester.sendKeyEvent(LogicalKeyboardKey.f8);
          await tester.sendKeyEvent(LogicalKeyboardKey.f9);
          await settleImages(reader);
          expect(
            ImageTranslationService.isEnabledForComic(comicId, sourceKey),
            isFalse,
          );
          expect((reader.chapter, reader.page), position);
          if (scroll != null) expect(scroll.offset, closeTo(offset!, 0.01));
          expect(chapterRequests, requests);
          expect(tester.takeException(), isNull);
        } finally {
          appdata.settings['keyboardShortcuts'] = <String, dynamic>{};
          await tester.pumpWidget(const SizedBox());
          var saved = false;
          unawaited(
            HistoryManager().addHistoryAsync(history).then((_) => saved = true),
          );
          for (var i = 0; i < 500 && !saved; i++) {
            await pumpIo();
          }
          expect(saved, isTrue);
          await tester.pump(const Duration(minutes: 2));
          var drained = false;
          unawaited(
            DatabaseGateway.instance
                .runExclusive(() async {})
                .then((_) => drained = true),
          );
          for (var i = 0; i < 500 && !drained; i++) {
            await pumpIo();
          }
          expect(drained, isTrue);
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        }
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
