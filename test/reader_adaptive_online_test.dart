import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _CachedPage implements File {
  _CachedPage(this.bytes);

  final Uint8List bytes;
  @override
  String get path => 'reader-test-cache.png';
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PageCache implements CacheManager {
  _PageCache(this.keys, this.page);

  final Set<String> keys;
  final File page;
  @override
  Future<File?> findCache(String key, [int duration = 604800000]) async =>
      keys.contains(key) ? page : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'reader_adaptive_online_test';
  const comicId = 'four-page-strip';
  const chapterId = 'chapter';
  final images = [
    for (var page = 1; page <= 4; page++)
      'https://reader-test.invalid/$page.png',
  ];
  late Directory temp;
  late ComicSource source;
  var chapterRequests = 0;

  setUpAll(() async {
    Log.isMuted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('reader-adaptive-online-');
    App.dataPath = temp.path;
    App.cachePath = '${temp.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    debugDefaultTargetPlatformOverride = null;
    source = ComicSource(
      'Adaptive online test',
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
        // Cache hits still run this hook; fail before any HTTP fallback.
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
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.green, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final pixels = await picture.toImage(300, 900);
    final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
    pixels.dispose();
    picture.dispose();
    CacheManager.instance = _PageCache({
      for (final image in images)
        ImageDownloader.imageCacheKey(image, sourceKey, comicId, chapterId),
    }, _CachedPage(bytes!.buffer.asUint8List()));
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
    Log.isMuted = false;
    debugDefaultTargetPlatformOverride = null;
    final parent = Directory.systemTemp.absolute.path;
    if (!temp.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
      throw StateError('Test directory must remain inside system temp');
    }
    await temp.delete(recursive: true);
  });

  testWidgets(
    'enabling adaptive reading keeps online pages through remount',
    (tester) async {
      for (final entry in <String, dynamic>{
        'language': 'en-US',
        'readerMode': 'galleryLeftToRight',
        'adaptiveReading': false,
        'showChapterComments': false,
        'enableClockAndBatteryInfoInReader': false,
        'enableTurnPageByVolumeKey': false,
        'autoRemoveFromReadLater': false,
        'enablePageAnimation': false,
        'limitImageWidth': false,
        'preloadImageCount': 0,
      }.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final history = History.fromMap({
        'id': comicId,
        'type': source.intKey,
        'title': 'Adaptive online test',
        'ep': 1,
        'page': 2,
      });

      Future<void> pumpIo() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: Scaffold(
              body: Reader(
                type: ComicType(source.intKey),
                cid: comicId,
                name: 'Adaptive online test',
                chapters: const ComicChapters({chapterId: 'Chapter'}),
                history: history,
                initialChapter: 1,
                initialPage: 2,
                author: '',
                tags: const [],
              ),
            ),
          ),
        );
        final dynamic reader = tester.state(find.byType(Reader));
        for (var i = 0; i < 50; i++) {
          await pumpIo();
          if (!reader.isLoading &&
              PaintingBinding.instance.imageCache.pendingImageCount == 0) {
            break;
          }
        }
        expect(reader.isLoading, isFalse);
        expect(reader.page, 2);
        expect(chapterRequests, 1);
        final dynamic scaffold = tester.state(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_ReaderScaffold',
          ),
        );
        scaffold.openOrClose();
        scaffold.openSetting();
        await tester.pumpAndSettle();
        final settings = tester.widget<ReaderSettings>(
          find.byType(ReaderSettings),
        );

        // Only decoded/displayed pages survive; the new probe must own its
        // three body reads after the previous view's download cleanup.
        ImageDownloader.cancelAllLoadingImages();
        appdata.settings['adaptiveReading'] = true;
        settings.onChanged!('adaptiveReading');
        await tester.pump();
        for (var i = 0; i < 100; i++) {
          await pumpIo();
          if (!reader.isLoading &&
              PaintingBinding.instance.imageCache.pendingImageCount == 0) {
            break;
          }
        }
        await tester.pump();
        expect(reader.isLoading, isFalse);
        expect(reader.mode, ReaderMode.continuousTopToBottom);
        expect(
          PaintingBinding.instance.imageCache
              .statusForKey(
                ReaderImageProvider(
                  images[1],
                  sourceKey,
                  comicId,
                  chapterId,
                  2,
                  enableResize: true,
                ),
              )
              .keepAlive,
          isTrue,
          reason:
              'The displayed strip must finish decoding before checking its position',
        );
        expect(reader.pageImageRange.$1, 1);
        expect(history.page, 2);
        expect(
          chapterRequests,
          1,
          reason: 'Mode changes must reuse the chapter',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var saved = false;
        unawaited(
          HistoryManager().addHistoryAsync(history).then((_) => saved = true),
        );
        for (var i = 0; i < 500 && !saved; i++) {
          await pumpIo();
        }
        expect(
          saved,
          isTrue,
          reason: 'History writes must settle before cleanup',
        );
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
        expect(
          drained,
          isTrue,
          reason: 'Database work must finish in the widget-test clock',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
