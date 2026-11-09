import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

const _sourceKey = 'continuous_rtl_test';
const _comicId = 'sample-comic';
const _chapters = ComicChapters({'ep1': 'Chapter 1'});

String _imageKey(int page) => 'file://rtl-reader-$page.png';

ComicSource _source() => ComicSource(
  'Continuous direction test',
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
  (id, ep) async => Res([_imageKey(1), _imageKey(2), _imageKey(3)]),
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
    temp = Directory.systemTemp.createTempSync('reader-rtl-');
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
    temp.deleteSync(recursive: true);
  });

  Future<History> openReader(WidgetTester tester, String mode) async {
    appdata.settings['language'] = 'en-US';
    appdata.settings['readerMode'] = mode;
    appdata.settings['showChapterComments'] = false;
    appdata.settings['enableContinuousChapterReading'] = false;
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
    final source = _source();
    ComicSourceManager().add(source);
    for (var page = 1; page <= 3; page++) {
      final provider = ReaderImageProvider(
        _imageKey(page),
        _sourceKey,
        _comicId,
        'ep1',
        page,
        enableResize: true,
      );
      final pixels = await tester.runAsync(
        () => createTestImage(width: 430, height: 900),
      );
      PaintingBinding.instance.imageCache.putIfAbsent(
        provider,
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: pixels!)),
        ),
      );
    }
    final history = History.fromMap({
      'id': _comicId,
      'type': source.intKey,
      'title': 'Continuous direction test',
      'ep': 1,
      'page': 1,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Reader(
            type: ComicType(source.intKey),
            cid: _comicId,
            name: 'Continuous direction test',
            chapters: _chapters,
            history: history,
            author: '',
            tags: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(history.page, 1);
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

  testWidgets('continuous directions track gestures and page actions', (
    tester,
  ) async {
    // Keep the shared native history worker in the same widget-test clock.
    for (final mode in [
      'continuousLeftToRight',
      'continuousRightToLeft',
      'continuousTopToBottom',
    ]) {
      final reverse = mode == 'continuousRightToLeft';
      final vertical = mode == 'continuousTopToBottom';
      for (final pageAction in [false, true]) {
        final reason = '$mode ${pageAction ? 'page action' : 'drag'}';
        final history = await openReader(tester, mode);
        try {
          final scroll = find.byType(CustomScrollView).first;
          final view = tester.widget<CustomScrollView>(scroll);
          final dynamic reader = tester.state(find.byType(Reader));
          expect(view.reverse, reverse);
          if (pageAction) {
            reader.onDown();
          } else {
            await tester.drag(
              scroll,
              vertical
                  ? const Offset(0, -1000)
                  : Offset(reverse ? 530 : -530, 0),
            );
          }
          await tester.pumpAndSettle();
          expect(view.controller!.offset, greaterThan(0), reason: reason);
          expect(history.page, 2, reason: reason);
          if (pageAction) {
            reader.onUp();
            await tester.pumpAndSettle();
            expect(view.controller!.offset, closeTo(0, 1), reason: reason);
            expect(history.page, 1, reason: reason);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await closeReader(tester, history);
        }
      }
    }
  });
}
