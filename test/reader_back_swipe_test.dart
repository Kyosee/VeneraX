import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'reader_back_swipe_test';
  const comicId = 'sample-comic';
  const chapterId = 'chapter';
  final images = [
    for (var i = 0; i < 8; i++) 'https://reader.invalid/back-swipe-$i.png',
  ];
  late Directory temp;
  late ComicSource source;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('reader-back-swipe-');
    App.dataPath = temp.path;
    App.cachePath = '${temp.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await HistoryManager().init();
    ImageFavoriteManager().init();
    await LocalFavoritesManager().init();
    debugDefaultTargetPlatformOverride = null;
    source = ComicSource(
      'Reader back swipe test',
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
      (id, chapter) async => Res(List<String>.of(images)),
      null,
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
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    ComicSourceManager().remove(sourceKey);
    debugDefaultTargetPlatformOverride = null;
    final parent = Directory.systemTemp.absolute.path;
    if (!temp.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
      throw StateError('Test directory must remain inside system temp');
    }
    await temp.delete(recursive: true);
  });

  Future<History> openReader(
    WidgetTester tester,
    ReaderMode mode, {
    String quickCollectImage = 'No',
  }) async {
    final favorites = ImageFavoriteManager().find(comicId, sourceKey);
    if (favorites != null) {
      ImageFavoriteManager().deleteImageFavorite(favorites.images.toList());
    }
    for (final entry in <String, dynamic>{
      'language': 'en-US',
      'readerMode': mode.key,
      'adaptiveReading': false,
      'readerScreenPicNumberForPortrait': 1,
      'showChapterComments': false,
      'enableContinuousChapterReading': false,
      'enableClockAndBatteryInfoInReader': false,
      'enableTurnPageByVolumeKey': false,
      'autoRemoveFromReadLater': false,
      'enablePageAnimation': true,
      'enableDoubleTapToZoom': false,
      'limitImageWidth': false,
      'readerCenterPageOnTurn': false,
      'readerPageSpacing': 0.0,
      'preloadImageCount': 0,
      'quickCollectImage': quickCollectImage,
      'autoFavoriteCover': false,
    }.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    for (var i = 0; i < images.length; i++) {
      final pixels = await tester.runAsync(
        () => createTestImage(width: 430, height: 900),
      );
      for (final resize in [false, true]) {
        PaintingBinding.instance.imageCache.putIfAbsent(
          ReaderImageProvider(
            images[i],
            sourceKey,
            comicId,
            chapterId,
            i + 1,
            enableResize: resize,
          ),
          () => OneFrameImageStreamCompleter(
            SynchronousFuture(ImageInfo(image: pixels!.clone())),
          ),
        );
      }
      pixels!.dispose();
    }
    final history = History.fromMap({
      'id': comicId,
      'type': source.intKey,
      'title': 'Reader back swipe test',
      'ep': 1,
      'page': 3,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        navigatorObservers: [App.rootRouteObserver],
        home: const Scaffold(body: Text('Comic details')),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      App.rootNavigatorKey.currentState!.push(
        AppPageRoute<void>(
          builder: (_) => Scaffold(
            body: Reader(
              type: ComicType(source.intKey),
              cid: comicId,
              name: 'Reader back swipe test',
              chapters: const ComicChapters({chapterId: 'Chapter'}),
              history: history,
              initialPage: 3,
              author: '',
              tags: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Reader), findsOneWidget);
    expect(history.page, 3);
    return history;
  }

  Future<void> closeReader(WidgetTester tester, History history) async {
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    var saved = false;
    unawaited(
      HistoryManager().addHistoryAsync(history).then((_) => saved = true),
    );
    for (var i = 0; i < 500 && !saved; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(saved, isTrue, reason: 'Reader history writes did not settle');
    await tester.pump(const Duration(minutes: 2));
  }

  Future<void> swipe(
    WidgetTester tester,
    Offset start,
    Offset distance, {
    int steps = 4,
  }) async {
    final gesture = await tester.startGesture(start);
    // A fast touch event can cross the scrollable's drag threshold at once.
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(
        distance / steps.toDouble(),
        timeStamp: Duration(milliseconds: i * 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 80));
  }

  Future<void> swipeRight(WidgetTester tester, {double startX = 130}) async {
    await swipe(tester, Offset(startX, 450), const Offset(220, 0));
  }

  bool isCollected(int page) =>
      ImageFavoriteManager().has(comicId, sourceKey, chapterId, page, 1);

  Future<void> checkSwipeCollection(WidgetTester tester) async {
    for (final mode in ReaderMode.values) {
      final vertical =
          mode == ReaderMode.continuousTopToBottom ||
          mode == ReaderMode.galleryTopToBottom;
      final crossAxisSwipe = vertical
          ? const Offset(220, 0)
          : const Offset(0, 220);
      final history = await openReader(
        tester,
        mode,
        quickCollectImage: 'Swipe',
      );
      try {
        await swipe(tester, const Offset(130, 450), crossAxisSwipe);
        await tester.pumpAndSettle();
        expect(find.byType(Reader), findsOneWidget);
        expect(history.page, 3);
        expect(isCollected(3), isTrue);

        await swipe(tester, const Offset(300, 450), -crossAxisSwipe);
        await tester.pumpAndSettle();
        expect(find.byType(Reader), findsOneWidget);
        expect(isCollected(3), isFalse);

        await swipe(
          tester,
          const Offset(130, 450),
          vertical ? const Offset(170, -400) : const Offset(-300, 100),
        );
        await tester.pumpAndSettle();
        expect(ImageFavoriteManager().find(comicId, sourceKey), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await closeReader(tester, history);
      }
    }
  }

  Future<void> checkFastSwipeCollection(WidgetTester tester) async {
    final history = await openReader(
      tester,
      ReaderMode.continuousTopToBottom,
      quickCollectImage: 'Swipe',
    );
    try {
      await swipe(
        tester,
        const Offset(130, 450),
        const Offset(270, 0),
        steps: 1,
      );
      await tester.pumpAndSettle();
      expect(isCollected(3), isTrue);
      await swipe(
        tester,
        const Offset(300, 450),
        const Offset(-270, 0),
        steps: 1,
      );
      await tester.pumpAndSettle();
      expect(isCollected(3), isFalse);

      final photoView = tester.widget<PhotoView>(find.byType(PhotoView));
      photoView.controller!.scale = 1.5;
      await tester.pumpAndSettle();
      await swipeRight(tester);
      await tester.pumpAndSettle();
      expect(find.byType(Reader), findsOneWidget);
      expect(isCollected(3), isFalse);
      photoView.controller!.scale = 1.0;
      await tester.pumpAndSettle();

      await swipeRight(tester, startX: 5);
      await tester.pumpAndSettle();
      expect(isCollected(3), isFalse);
      expect(find.byType(Reader), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await closeReader(tester, history);
    }
  }

  testWidgets(
    'reader swipes respect navigation and image collection (#344, #349)',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await checkSwipeCollection(tester);
      await checkFastSwipeCollection(tester);

      for (final mode in [
        ReaderMode.galleryRightToLeft,
        ReaderMode.continuousRightToLeft,
        ReaderMode.galleryLeftToRight,
        ReaderMode.continuousLeftToRight,
      ]) {
        for (final reopened in [false, true]) {
          final reason = '${mode.key}, reopened: $reopened';
          final history = await openReader(tester, mode);
          try {
            if (!reopened) {
              await swipeRight(tester);
              await tester.pump(const Duration(milliseconds: 16));
            }
            await swipeRight(tester);
            await tester.pumpAndSettle();
            expect(find.byType(Reader), findsOneWidget, reason: reason);
            if (mode.isContinuous) {
              expect(
                history.page,
                mode == ReaderMode.continuousRightToLeft
                    ? greaterThan(3)
                    : lessThan(3),
                reason: reason,
              );
            }

            if (reopened) {
              expect(
                await App.rootNavigatorKey.currentState!.maybePop(),
                isTrue,
              );
            } else {
              final dynamic reader = tester.state(find.byType(Reader));
              final target = history.page == 3 ? 4 : 3;
              reader.toPage(target);
              await tester.pump(const Duration(milliseconds: 16));
              expect(reader.isPageAnimating, isTrue, reason: reason);
              await swipeRight(tester);
              await tester.pumpAndSettle();
              expect(find.byType(Reader), findsOneWidget, reason: reason);
              expect(history.page, target, reason: reason);

              await swipeRight(tester, startX: 5);
            }
            await tester.pumpAndSettle();
            expect(find.byType(Reader), findsNothing, reason: reason);
            expect(find.text('Comic details'), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            await closeReader(tester, history);
          }
        }
      }

      for (final mode in [
        ReaderMode.galleryTopToBottom,
        ReaderMode.continuousTopToBottom,
      ]) {
        final history = await openReader(tester, mode);
        try {
          await swipeRight(tester);
          await tester.pumpAndSettle();
          expect(find.byType(Reader), findsNothing, reason: mode.key);
        } finally {
          await closeReader(tester, history);
        }
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
