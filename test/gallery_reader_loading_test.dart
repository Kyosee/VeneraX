import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/gallery_layout.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/data_sync.dart';

class _ReaderSync extends ChangeNotifier implements DataSync {
  @override
  WebdavSyncMode syncMode = WebdavSyncMode.realtime;
  final flushedPages = <int>[];

  @override
  Future<void> settlePendingChanges() async {
    flushedPages.add(HistoryManager().getAll().single.page);
  }

  @override
  void requestAutoUpload() {}

  @override
  void onDataChanged() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledImage extends ImageStreamCompleter {
  bool completed = false;

  bool get observed => hasListeners;

  void show(ui.Image image) {
    if (completed) return;
    completed = true;
    setImage(ImageInfo(image: image.clone()));
  }

  void fail(ImageProvider provider) {
    completed = true;
    reportError(exception: StateError('controlled decode failure'));
    // Match BaseImageProvider's eviction after a failed decode.
    scheduleMicrotask(
      () => PaintingBinding.instance.imageCache.evict(provider),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'gallery_loading_test';
  const comicId = 'mixed-pages';
  const chapterId = 'chapter';
  final red = Colors.red.toARGB32();
  final blue = Colors.blue.toARGB32();
  final images = [for (var i = 0; i < 6; i++) 'file://gallery-loading-$i.png'];
  late Directory temp;
  late ComicSource source;
  late ui.Image wide;
  late ui.Image single;

  setUpAll(() async {
    Log.isMuted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('gallery-loading-');
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
      'Gallery loading test',
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
    Future<ui.Image> paint(int width, int height, bool spread) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(spread ? Colors.red : Colors.green, ui.BlendMode.src);
      if (spread) {
        canvas.drawRect(
          Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
          Paint()..color = Colors.blue,
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      return image;
    }

    wide = await paint(600, 300, true);
    single = await paint(300, 450, false);
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    ComicSourceManager().remove(sourceKey);
    wide.dispose();
    single.dispose();
    Log.isMuted = false;
    final parent = Directory.systemTemp.absolute.path;
    if (!temp.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
      throw StateError('Test directory must remain inside system temp');
    }
    await temp.delete(recursive: true);
  });

  Future<({dynamic reader, History history, List<_ControlledImage> decodes})>
  openGallery(
    WidgetTester tester,
    ReaderMode mode,
    int perScreen,
    String split,
  ) async {
    for (final entry in <String, dynamic>{
      'language': 'en-US',
      'readerMode': mode.key,
      'adaptiveReading': false,
      'readerScreenPicNumberForLandscape': perScreen,
      'readerScreenPicNumberForPortrait': 1,
      'showSingleImageOnFirstPage': false,
      'splitWidePages': split,
      'showChapterComments': false,
      'enableClockAndBatteryInfoInReader': false,
      'enableTurnPageByVolumeKey': false,
      'autoRemoveFromReadLater': false,
      'enablePageAnimation': false,
      'preloadImageCount': 0,
    }.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    final decodes = [
      for (var i = 0; i < images.length; i++) _ControlledImage(),
    ];
    for (var i = 0; i < images.length; i++) {
      PaintingBinding.instance.imageCache.putIfAbsent(
        ReaderImageProvider(images[i], sourceKey, comicId, chapterId, i + 1),
        () => decodes[i],
      );
    }
    final history = History.fromMap({
      'id': comicId,
      'type': source.intKey,
      'title': 'Gallery loading test',
      'ep': 1,
      'page': 1,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('gallery-paint'),
            child: Reader(
              type: ComicType(source.intKey),
              cid: comicId,
              name: 'Gallery loading test',
              chapters: const ComicChapters({chapterId: 'Chapter'}),
              history: history,
              initialChapter: 1,
              initialPage: 1,
              author: '',
              tags: const [],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final dynamic reader = tester.state(find.byType(Reader));
    expect(reader.isLoading, isFalse);
    return (reader: reader, history: history, decodes: decodes);
  }

  Future<void> closeGallery(WidgetTester tester, History history) async {
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    Future<void> drain(Future<void> work) async {
      var done = false;
      unawaited(work.then((_) => done = true));
      for (var i = 0; i < 500 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(
        done,
        isTrue,
        reason: 'Database work must finish in the widget-test clock',
      );
    }

    await drain(HistoryManager().addHistoryAsync(history));
    await tester.pump(const Duration(minutes: 2));
    await drain(DatabaseGateway.instance.runExclusive(() async {}));
  }

  Future<List<int>> sampleFrame(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('gallery-paint')),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int at(double x) {
          final offset =
              ((image.height ~/ 2) * image.width + (image.width * x).floor()) *
              4;
          return Color.fromARGB(
            pixels.getUint8(offset + 3),
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          ).toARGB32();
        }

        return [at(0.35), at(0.65)];
      } finally {
        image.dispose();
      }
    }))!;
  }

  Iterable<int> visibleImages(
    WidgetTester tester, {
    bool keepDuplicates = false,
  }) {
    final viewport = tester.getRect(
      find.byKey(const ValueKey('gallery-paint')),
    );
    final shown = <int>[];
    for (final element in find.byType(ComicImage).evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) {
        continue;
      }
      final visible = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      ).intersect(viewport);
      if (visible.width <= 1 || visible.height <= 1) {
        continue;
      }
      final provider =
          (element.widget as ComicImage).image as ReaderImageProvider;
      shown.add(images.indexOf(provider.imageKey));
    }
    return keepDuplicates ? shown : shown.toSet();
  }

  Future<void> checkRotation(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final mode in [
      ReaderMode.galleryLeftToRight,
      ReaderMode.galleryRightToLeft,
      ReaderMode.galleryTopToBottom,
    ]) {
      for (final perScreen in [1, 2]) {
        tester.view.physicalSize = const Size(900, 600);
        final opened = await openGallery(tester, mode, perScreen, 'off');
        try {
          for (final decode in opened.decodes) {
            decode.show(single);
          }
          await tester.pump();
          await tester.pump();
          opened.reader.toNextPage();
          await tester.pump();
          final (int first, int last) = opened.reader.pageImageRange;
          for (final size in [const Size(600, 900), const Size(900, 600)]) {
            tester.view.physicalSize = size;
            await tester.pump();
            final (int start, int end) = opened.reader.pageImageRange;
            expect(start, lessThanOrEqualTo(first));
            expect(end, greaterThan(first));
            expect(visibleImages(tester), contains(first));
            for (final element in find.byType(ComicImage).evaluate()) {
              final box = element.renderObject as RenderBox;
              if (!box.attached || !box.hasSize) continue;
              final transform = box.getTransformTo(null);
              final origin = MatrixUtils.transformPoint(transform, Offset.zero);
              final x = MatrixUtils.transformPoint(
                transform,
                const Offset(1, 0),
              );
              final y = MatrixUtils.transformPoint(
                transform,
                const Offset(0, 1),
              );
              expect(
                (x - origin).distance,
                closeTo((y - origin).distance, 0.001),
                reason: 'Rotation must never apply a non-uniform image scale',
              );
            }
            expect(tester.takeException(), isNull);
          }
          expect(last, greaterThan(first));
        } finally {
          await closeGallery(tester, opened.history);
        }
      }
    }
  }

  testWidgets(
    'gallery loading keeps complete spreads and split halves in order',
    (tester) async {
      await checkRotation(tester);
      final previousSync = DataSync.instance;
      final readerSync = _ReaderSync();
      DataSync.instance = readerSync;
      for (final mode in [WebdavSyncMode.realtime, WebdavSyncMode.dataSaver]) {
        readerSync.syncMode = mode;
        readerSync.flushedPages.clear();
        final progress = await openGallery(
          tester,
          ReaderMode.galleryLeftToRight,
          1,
          'off',
        );
        progress.decodes[0].show(single);
        progress.decodes[1].show(single);
        await tester.pump();
        await tester.pump();
        progress.reader.toNextPage();
        await tester.pump();
        expect(progress.history.page, 2);
        await tester.pumpWidget(const SizedBox());
        // Observe the reader's own save before the test helper writes history.
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 25));
          if (HistoryManager().getAll().single.page == 2 &&
              (mode != WebdavSyncMode.realtime ||
                  readerSync.flushedPages.isNotEmpty)) {
            break;
          }
        }
        expect(HistoryManager().getAll().single.page, 2);
        expect(
          readerSync.flushedPages,
          mode == WebdavSyncMode.realtime ? [2] : isEmpty,
        );
        await closeGallery(tester, progress.history);
      }
      DataSync.instance = previousSync;
      readerSync.dispose();
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final (mode, order, firstColor, secondColor) in [
        (ReaderMode.galleryLeftToRight, 'leftFirst', red, blue),
        (ReaderMode.galleryRightToLeft, 'rightFirst', blue, red),
      ]) {
        final opened = await openGallery(tester, mode, 1, order);
        final reader = opened.reader;
        try {
          opened.decodes[0].show(wide);
          for (var frame = 0; frame < 4; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              await sampleFrame(tester),
              isNot(equals([red, blue])),
              reason:
                  'A pending split must never paint the whole red/blue spread',
            );
          }
          expect(reader.galleryLayout.halfOf(reader.page), GalleryHalf.first);
          expect(reader.pageImageRange, (0, 1));
          expect(await sampleFrame(tester), [firstColor, firstColor]);
          expect(reader.toNextPage(), isTrue);
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(reader.galleryLayout.halfOf(reader.page), GalleryHalf.second);
          expect(reader.pageImageRange, (0, 1));
          expect(await sampleFrame(tester), [secondColor, secondColor]);
          expect(tester.takeException(), isNull);
        } finally {
          await closeGallery(tester, opened.history);
        }
      }

      for (final mode in [
        ReaderMode.galleryLeftToRight,
        ReaderMode.galleryRightToLeft,
      ]) {
        final opened = await openGallery(tester, mode, 2, 'leftFirst');
        final reader = opened.reader;
        try {
          opened.decodes[0].show(wide);
          opened.decodes[1].show(single);
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            reader.imageSizeOf(0),
            const Size(600, 300),
            reason:
                'Visible dimensions must be known before the 200ms prefetch timer',
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            reader.pageImageRange,
            (0, 1),
            reason: 'A decoded spread must occupy a two-image screen alone',
          );

          final seen = <int>[];
          for (
            var turn = 0;
            turn < images.length && seen.length < images.length;
            turn++
          ) {
            final (int start, int end) = reader.pageImageRange;
            for (var i = start; i < end; i++) {
              opened.decodes[i].show(i == 0 || i == 3 ? wide : single);
            }
            // Every turn settles in 48ms, so none reaches the prefetch timer.
            for (var frame = 0; frame < 3; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final (int first, int last) = reader.pageImageRange;
            expect(
              first,
              seen.length,
              reason: 'Fast turns must not repeat or skip source images',
            );
            expect(last, greaterThan(first));
            final current = [for (var i = first; i < last; i++) i];
            if (current.contains(0) || current.contains(3)) {
              expect(current, hasLength(1));
            }
            expect(
              visibleImages(tester),
              unorderedEquals(current),
              reason: 'The rendered images must match the recorded range',
            );
            seen.addAll(current);
            if (seen.length < images.length) {
              expect(reader.toNextPage(), isTrue);
            }
          }
          expect(seen, [0, 1, 2, 3, 4, 5]);
          expect(tester.takeException(), isNull);
        } finally {
          await closeGallery(tester, opened.history);
        }
      }
      final retryCase = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        1,
        'leftFirst',
      );
      try {
        final provider = ReaderImageProvider(
          images[0],
          sourceKey,
          comicId,
          chapterId,
          1,
        );
        retryCase.decodes[0].fail(provider);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.textContaining('controlled decode failure'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        final replacement = _ControlledImage();
        expect(
          PaintingBinding.instance.imageCache.putIfAbsent(
            provider,
            () => replacement,
          ),
          same(replacement),
          reason: 'A failed decode must release its cache entry for retry',
        );
        await tester.tap(find.text('Retry'));
        await tester.pump(const Duration(milliseconds: 16));
        replacement.show(wide);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.textContaining('controlled decode failure'), findsNothing);
        expect(retryCase.reader.pageImageRange, (0, 1));
        expect(
          retryCase.reader.galleryLayout.halfOf(retryCase.reader.page),
          GalleryHalf.first,
        );
        expect(await sampleFrame(tester), [red, red]);
        expect(tester.takeException(), isNull);
      } finally {
        await closeGallery(tester, retryCase.history);
      }
      final uncached = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        1,
        'leftFirst',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      final cache = PaintingBinding.instance.imageCache;
      final previousLimit = cache.maximumSizeBytes;
      try {
        cache.maximumSizeBytes = 1;
        uncached.decodes[0].show(wide);
        final provider = ReaderImageProvider(
          images[0],
          sourceKey,
          comicId,
          chapterId,
          1,
        );
        expect(
          cache.statusForKey(provider).live,
          isTrue,
          reason:
              'The decoded frame must stay available until the gallery paints it without an LRU entry',
        );
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(cache.maximumSizeBytes, 1);
        expect(uncached.reader.pageImageRange, (0, 1));
        expect(await sampleFrame(tester), [red, red]);
        expect(tester.takeException(), isNull);
      } finally {
        cache.maximumSizeBytes = previousLimit;
        await closeGallery(tester, uncached.history);
      }
      final paired = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        2,
        'off',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      final pairedLimit = cache.maximumSizeBytes;
      final oneImageBudget = single.width * single.height * 4 + 1;
      try {
        cache.maximumSizeBytes = oneImageBudget;
        paired.decodes[0].show(single);
        paired.decodes[1].show(single);
        for (var i = 0; i < 2; i++) {
          expect(
            cache
                .statusForKey(
                  ReaderImageProvider(
                    images[i],
                    sourceKey,
                    comicId,
                    chapterId,
                    i + 1,
                  ),
                )
                .live,
            isTrue,
            reason:
                'Both current frames must survive when only one fits in the LRU cache',
          );
        }
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(cache.maximumSizeBytes, oneImageBudget);
        expect(paired.reader.pageImageRange, (0, 2));
        expect(visibleImages(tester), {0, 1});
        expect(await sampleFrame(tester), [
          Colors.green.toARGB32(),
          Colors.green.toARGB32(),
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        cache.maximumSizeBytes = pairedLimit;
        await closeGallery(tester, paired.history);
      }
      final variant = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        1,
        'leftFirst',
      );
      try {
        const replacementKey = 'file://gallery-loading-replacement.png';
        final replacement = _ControlledImage();
        PaintingBinding.instance.imageCache.putIfAbsent(
          const ReaderImageProvider(
            replacementKey,
            sourceKey,
            comicId,
            chapterId,
            1,
          ),
          () => replacement,
        );
        variant.reader.images[0] = replacementKey;
        variant.reader.update();
        await tester.pump(const Duration(milliseconds: 16));
        replacement.show(single);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(variant.reader.imageSizeOf(0), const Size(300, 450));
        variant.decodes[0].show(wide);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          variant.reader.imageSizeOf(0),
          const Size(300, 450),
          reason:
              'An old provider completing late must not overwrite the replacement dimensions',
        );
        expect(
          variant.decodes[0].observed,
          isFalse,
          reason: 'A replaced provider must not retain a gallery listener',
        );
        expect(await sampleFrame(tester), [
          Colors.green.toARGB32(),
          Colors.green.toARGB32(),
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await closeGallery(tester, variant.history);
      }

      final secondImage = images[1];
      images[1] = images[0];
      final duplicate = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        2,
        'off',
      );
      try {
        duplicate.decodes[0].show(single);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(duplicate.reader.imageSizeOf(0), const Size(300, 450));
        expect(
          duplicate.reader.imageSizeOf(1),
          const Size(300, 450),
          reason:
              'Both source indexes must learn dimensions from their shared provider',
        );
        expect(duplicate.reader.pageImageRange, (0, 2));
        expect(visibleImages(tester, keepDuplicates: true), [0, 0]);
        expect(await sampleFrame(tester), [
          Colors.green.toARGB32(),
          Colors.green.toARGB32(),
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await closeGallery(tester, duplicate.history);
        images[1] = secondImage;
      }

      // Local spreads further ahead are grouped from their file headers,
      // before any of them decodes.
      final original = List.of(images);
      final png = (await tester.runAsync(() async {
        final data = await wide.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      }))!;
      for (var i = 0; i < images.length; i++) {
        final file = File('${temp.path}/header-$i.png')..writeAsBytesSync(png);
        images[i] = 'file://${file.path}';
      }
      final headers = await openGallery(
        tester,
        ReaderMode.galleryLeftToRight,
        2,
        'off',
      );
      try {
        appdata.settings['preloadImageCount'] = 4;
        for (
          var i = 0;
          i < 100 && headers.reader.maxPage < images.length;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          headers.reader.maxPage,
          images.length,
          reason: 'Each spread must stand alone before any of them decodes',
        );
        expect(headers.decodes.any((decode) => decode.completed), isFalse);
        expect(headers.reader.pageImageRange, (0, 1));
        expect(tester.takeException(), isNull);
      } finally {
        await closeGallery(tester, headers.history);
        images.setAll(0, original);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
