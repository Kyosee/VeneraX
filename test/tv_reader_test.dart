import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/foundation/tv_platform.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart' show overrideIO;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'tv_reader_test';
  const chapters = ComicChapters({'one': 'Chapter one', 'two': 'Chapter two'});
  late Directory temp;
  late ComicSource source;
  late String imageUrl;

  setUpAll(() async {
    enableTvApp();
    Log.isMuted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('venera-tv-reader-');
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
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(180, 720);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${temp.path}/strip.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    imageUrl = 'file://${file.path}';
    source = ComicSource(
      'TV test',
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
      (id, chapter) async => Res([imageUrl, imageUrl]),
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
    ComicSourceManager().remove(sourceKey);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    Log.isMuted = false;
    await temp.delete(recursive: true);
  });

  test('TV decode bounds include strips, panoramas and small pages', () {
    for (final (w, h) in [
      (200, 80000),
      (80000, 200),
      (4096, 4096),
      (180, 720),
    ]) {
      final size = tvDecodeSize(w, h);
      expect(size.width! * size.height!, lessThanOrEqualTo(4 << 20));
      expect(size.width, inInclusiveRange(1, 8192));
      expect(size.height, inInclusiveRange(1, 8192));
      expect(
        (size.width! - size.height! * w / h).abs(),
        lessThanOrEqualTo(w / h + 1),
      );
    }
    expect(tvDecodeSize(180, 720).height, 720);
  });

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String why,
  ) async {
    for (var i = 0; i < 250 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      ready(),
      isTrue,
      reason:
          '$why; text=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data)}, focus=${FocusManager.instance.primaryFocus}, images=${find.byType(ComicImage).evaluate().length}',
    );
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> shelf(WidgetTester tester, ReaderMode mode, String id) async {
    for (final entry in {
      'language': 'en-US',
      'readerMode': mode.key,
      'adaptiveReading': false,
      'tvFitWidth': true,
      'enablePageAnimation': false,
      'enableTurnPageByVolumeKey': false,
      'enableClockAndBatteryInfoInReader': false,
      'enableContinuousChapterReading': true,
      'autoRemoveFromReadLater': false,
      'autoPageTurningInterval': 5,
    }.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        navigatorObservers: [App.rootRouteObserver],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              child: const Text('Open'),
              onPressed: () {
                final history =
                    HistoryManager()
                        .getAll()
                        .where((h) => h.id == id)
                        .firstOrNull ??
                    History.fromMap({
                      'id': id,
                      'type': source.intKey,
                      'title': id,
                      'ep': 1,
                      'page': 1,
                    });
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: Reader(
                        cid: id,
                        name: id,
                        type: ComicType(source.intKey),
                        chapters: chapters,
                        history: history,
                        initialChapter: history.ep,
                        initialPage: history.page,
                        author: '',
                        tags: const [],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await press(tester, LogicalKeyboardKey.enter);
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await until(
      tester,
      () => find.byType(Reader).evaluate().isEmpty,
      'back saves and exits',
    );
    await tester.pump(const Duration(minutes: 2));
    var drained = false;
    DatabaseGateway.instance
        .runExclusive(() async {})
        .then((_) => drained = true);
    await until(tester, () => drained, 'reader database queue drained');
  }

  testWidgets(
    'D-pad reads a gallery and a strip, changes fit, confirms chapters and resumes history',
    (tester) => overrideIO(() async {
      final oldBytes = PaintingBinding.instance.imageCache.maximumSizeBytes;
      await shelf(tester, ReaderMode.galleryLeftToRight, 'remote');
      final images = find.byType(ComicImage);
      await until(
        tester,
        () => find
            .byType(RawImage)
            .evaluate()
            .any((e) => (e.widget as RawImage).image != null),
        'tall image decoded',
      );
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        lessThanOrEqualTo(64 << 20),
      );
      ScrollPosition position() => Scrollable.of(
        tester.element(images.first),
        axis: Axis.vertical,
      ).position;
      expect(position().maxScrollExtent, greaterThan(0));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(position().pixels, greaterThan(0));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(position().pixels, 0);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Fit page'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      expect(appdata.settings['tvFitWidth'], false);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(appdata.settings['tvPreloadCount'], 0);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(appdata.settings['autoPageTurningInterval'], isNot(5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        Scrollable.maybeOf(tester.element(images.first), axis: Axis.vertical),
        isNull,
      );
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.textContaining('2/2'), findsWidgets);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('Next Chapter'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Next Chapter'), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      final dynamic second = tester.state(find.byType(Reader));
      expect((second.chapter, second.page), (2, 1));
      await press(tester, LogicalKeyboardKey.arrowRight);
      await leave(tester);
      final saved = HistoryManager().getAll().singleWhere(
        (h) => h.id == 'remote',
      );
      expect((saved.ep, saved.page), (2, 2));
      expect(PaintingBinding.instance.imageCache.maximumSizeBytes, oldBytes);
      await press(tester, LogicalKeyboardKey.enter);
      final dynamic reader = tester.state(find.byType(Reader));
      expect((reader.chapter, reader.page), (2, 2));
      await leave(tester);
      await tester.pumpWidget(const SizedBox());
      await shelf(tester, ReaderMode.continuousTopToBottom, 'strip');
      final image = find.byType(ComicImage).first;
      await until(
        tester,
        () => find
            .byType(RawImage)
            .evaluate()
            .any((e) => (e.widget as RawImage).image != null),
        'strip decoded',
      );
      final stripPosition = Scrollable.of(
        tester.element(image),
        axis: Axis.vertical,
      ).position;
      expect(
        tester.getSize(image).width,
        tester.getSize(find.byType(Reader)).width,
      );
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(stripPosition.pixels, greaterThan(0));
      for (
        var i = 0;
        i < 40 && find.text('Next Chapter').evaluate().isEmpty;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(find.text('Next Chapter'), findsOneWidget);
      final dynamic strip = tester.state(find.byType(Reader));
      expect((strip.chapter, strip.page), (1, 2));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await press(tester, LogicalKeyboardKey.select);
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.select);
      expect(appdata.settings['autoPageTurningMode'], 'scroll');
      final oldSpeed = appdata.settings['autoScrollSpeed'];
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(appdata.settings['autoScrollSpeed'], isNot(oldSpeed));
      await press(tester, LogicalKeyboardKey.arrowDown);
      final start = tester.element(find.text('Auto Page Turning'));
      if (!Focus.of(start).hasFocus) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(Focus.of(start).hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.select);
      for (var i = 0; i < 16 && find.byType(AlertDialog).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Next Chapter'), findsOneWidget);
      expect(strip.chapter, 1);
      expect(strip.autoPageTurning, false);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await leave(tester);
    }),
  );
}
