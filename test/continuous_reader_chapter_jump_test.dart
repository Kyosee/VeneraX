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
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'continuous_chapter_jump_test';
const _comicId = 'sample-comic';
const _chapters = ComicChapters({
  'ep1': 'Chapter 1',
  'ep2': 'Chapter 2',
  'ep3': 'Chapter 3',
});
const _pageCounts = {'ep1': 2, 'ep2': 3, 'ep3': 4};
const _colors = [Color(0xFFF44336), Color(0xFF4CAF50), Color(0xFF2196F3)];

List<String> _images(String ep) => [
  for (var page = 1; page <= _pageCounts[ep]!; page++)
    'file://chapter-jump-$ep-$page.png',
];

ComicSource _source(Completer<void> pending, List<String?> requests) =>
    ComicSource(
      'Chapter jump test',
      _sourceKey,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      null,
      null,
      (id, ep) async {
        requests.add(ep);
        if (ep == 'ep3') await pending.future;
        return Res(_images(ep!));
      },
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('reader-chapter-jump-');
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
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    debugDefaultTargetPlatformOverride = null;
    final parent = Directory.systemTemp.absolute.path;
    if (!temp.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
      throw StateError('Test directory must remain inside system temp');
    }
    temp.deleteSync(recursive: true);
  });

  Future<History> openReader(
    WidgetTester tester,
    String mode,
    Completer<void> pending,
    List<String?> requests,
  ) async {
    appdata.settings['language'] = 'en-US';
    appdata.settings['readerMode'] = mode;
    appdata.settings['showChapterComments'] = false;
    appdata.settings['enableContinuousChapterReading'] = true;
    appdata.settings['enableClockAndBatteryInfoInReader'] = false;
    appdata.settings['enableTurnPageByVolumeKey'] = false;
    appdata.settings['autoRemoveFromReadLater'] = false;
    appdata.settings['enablePageAnimation'] = false;
    appdata.settings['limitImageWidth'] = false;
    appdata.settings['readerCenterPageOnTurn'] = false;
    appdata.settings['readerPageSpacing'] = 0.0;
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _source(pending, requests);
    ComicSourceManager().add(source);
    for (var chapter = 1; chapter <= 3; chapter++) {
      final images = _images('ep$chapter');
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(_colors[chapter - 1], ui.BlendMode.src);
      final picture = recorder.endRecording();
      final pixels = await tester.runAsync(() => picture.toImage(430, 900));
      picture.dispose();
      for (var page = 1; page <= images.length; page++) {
        // A URL keeps its own artwork even if the caller uses a wrong chapter.
        for (var callerChapter = 1; callerChapter <= 3; callerChapter++) {
          final provider = ReaderImageProvider(
            images[page - 1],
            _sourceKey,
            _comicId,
            'ep$callerChapter',
            page,
            enableResize: true,
          );
          PaintingBinding.instance.imageCache.putIfAbsent(
            provider,
            () => OneFrameImageStreamCompleter(
              SynchronousFuture(ImageInfo(image: pixels!.clone())),
            ),
          );
        }
      }
      pixels!.dispose();
    }
    final history = History.fromMap({
      'id': _comicId,
      'type': source.intKey,
      'title': 'Chapter jump test',
      'ep': 2,
      'page': 1,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('chapter-jump-paint'),
            child: Reader(
              type: ComicType(source.intKey),
              cid: _comicId,
              name: 'Chapter jump test',
              chapters: _chapters,
              history: history,
              initialChapter: 2,
              author: '',
              tags: const [],
            ),
          ),
        ),
      ),
    );
    // The pending next-chapter loader keeps its progress indicator animating.
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return history;
  }

  Future<void> closeReader(WidgetTester tester, History history) async {
    await tester.pumpWidget(const SizedBox());
    // Drain native history writes and their fake-clock polling.
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
    ComicSourceManager().remove(_sourceKey);
  }

  Future<Color> centerPixel(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('chapter-jump-paint')),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      final color = Color.fromARGB(
        pixels!.getUint8(offset + 3),
        pixels.getUint8(offset),
        pixels.getUint8(offset + 1),
        pixels.getUint8(offset + 2),
      );
      image.dispose();
      return color;
    }))!;
  }

  testWidgets('chapter jumps keep their artwork after a background preload', (
    tester,
  ) async {
    // Keep the native history worker in one widget-test clock.
    for (final mode in [
      'continuousLeftToRight',
      'continuousRightToLeft',
      'continuousTopToBottom',
    ]) {
      final pending = Completer<void>();
      final requests = <String?>[];
      final history = await openReader(tester, mode, pending, requests);
      try {
        final dynamic reader = tester.state(find.byType(Reader));
        final dynamic scaffold = tester.state(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_ReaderScaffold',
          ),
        );
        expect(reader.chapter, 2, reason: mode);
        expect(requests, containsAll(['ep1', 'ep2', 'ep3']), reason: mode);
        expect(await centerPixel(tester), _colors[1], reason: mode);
        scaffold.openOrClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(
          find.byIcon(scaffold.isReversed ? Icons.last_page : Icons.first_page),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(reader.chapter, 1, reason: mode);
        expect(await centerPixel(tester), _colors[0], reason: mode);

        pending.complete();
        await tester.pumpAndSettle();
        expect(find.text('Chapter 1'), findsOneWidget, reason: mode);
        expect(await centerPixel(tester), _colors[0], reason: mode);
        expect(reader.images, _images('ep1'), reason: mode);
        expect(reader.maxPage, 2, reason: mode);
        expect(history.ep, 1, reason: mode);
        expect(history.maxPage, 2, reason: mode);

        await tester.tap(
          find.byIcon(scaffold.isReversed ? Icons.first_page : Icons.last_page),
        );
        await tester.pumpAndSettle();
        expect(find.text('Chapter 2'), findsOneWidget, reason: mode);
        expect(await centerPixel(tester), _colors[1], reason: mode);
        expect(reader.images, _images('ep2'), reason: mode);
        expect(reader.maxPage, 3, reason: mode);
        expect(history.ep, 2, reason: mode);
        expect(history.maxPage, 3, reason: mode);

        expect(reader.toPrevChapter(toLastPage: true), isTrue, reason: mode);
        await tester.pumpAndSettle();
        expect(await centerPixel(tester), _colors[0], reason: mode);
        expect(reader.images, _images('ep1'), reason: mode);
        expect(reader.page, 2, reason: mode);
        expect(history.ep, 1, reason: mode);
        expect(history.page, 2, reason: mode);
        expect(history.maxPage, 2, reason: mode);
        expect(requests, hasLength(3), reason: 'Loaded chapters stay cached');
        expect(tester.takeException(), isNull, reason: mode);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await closeReader(tester, history);
      }
    }
  });
}
