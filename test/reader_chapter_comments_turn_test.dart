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
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'chapter_comments_turn_test';
const _comicId = 'comments-turn';
const _chapters = ComicChapters({'ep1': 'One', 'ep2': 'Two', 'ep3': 'Three'});
const _pages = 3;

String _imageKey(String ep, int page) => 'file://turn-$ep-$page.png';

ComicSource _source() => ComicSource(
  'Chapter comments turn test',
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
  (id, ep) async => Res([for (var p = 1; p <= _pages; p++) _imageKey(ep!, p)]),
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  (comic, ep, page, reply) async => Res([
    for (var i = 0; i < 3; i++)
      Comment.fromJson({'userName': 'Reader $i', 'content': 'Comment $i'}),
  ], subData: 2),
  (comic, ep, content, reply) async => const Res(true),
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
    Log.isMuted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('comments-turn-');
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
    Log.isMuted = false;
    temp.deleteSync(recursive: true);
  });

  Future<dynamic> open(
    WidgetTester tester,
    String mode, {
    int chapter = 1,
    bool comments = true,
    bool tapToTurn = true,
  }) async {
    for (final entry in <String, dynamic>{
      'language': 'en-US',
      'readerMode': mode,
      'adaptiveReading': false,
      'readerScreenPicNumberForPortrait': 1,
      'readerScreenPicNumberForLandscape': 1,
      'showSingleImageOnFirstPage': false,
      'splitWidePages': 'off',
      'showChapterComments': comments,
      'showChapterCommentsAtEnd': comments,
      'enableContinuousChapterReading': true,
      'enableClockAndBatteryInfoInReader': false,
      'enableTurnPageByVolumeKey': false,
      'autoRemoveFromReadLater': false,
      'enablePageAnimation': false,
      'enableTapToTurnPages': tapToTurn,
      'enableCustomTapZones': false,
      'reverseTapToTurnPages': false,
      'enableDoubleTapToZoom': false,
      'quickCollectImage': 'No',
      'readerCenterPageOnTurn': false,
      'readerPageSpacing': 0.0,
      'blockedCommentWords': <String>[],
    }.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _source();
    ComicSourceManager().add(source);
    for (final ep in _chapters.ids) {
      for (var page = 1; page <= _pages; page++) {
        final provider = ReaderImageProvider(
          _imageKey(ep, page),
          _sourceKey,
          _comicId,
          ep,
          page,
          enableResize: mode.startsWith('continuous'),
        );
        final pixels = await tester.runAsync(
          () => createTestImage(width: 300, height: 450),
        );
        PaintingBinding.instance.imageCache.putIfAbsent(
          provider,
          () => OneFrameImageStreamCompleter(
            SynchronousFuture(ImageInfo(image: pixels!)),
          ),
        );
      }
    }
    final history = History.fromMap({
      'id': _comicId,
      'type': source.intKey,
      'title': 'Comments turn',
      'ep': chapter,
      'page': 1,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Reader(
            type: ComicType(source.intKey),
            cid: _comicId,
            name: 'Comments turn',
            chapters: _chapters,
            history: history,
            initialChapter: chapter,
            initialPage: 1,
            author: '',
            tags: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(Reader));
  }

  Future<void> close(WidgetTester tester) async {
    final history = tester.widget<Reader>(find.byType(Reader)).history;
    await tester.pumpWidget(const SizedBox());
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
    expect(saved, isTrue);
    await tester.pump(const Duration(minutes: 2));
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicSourceManager().remove(_sourceKey);
  }

  testWidgets('turning back into a chapter lands on its comments page', (
    tester,
  ) async {
    var reader = await open(tester, 'galleryLeftToRight', chapter: 2);
    expect((reader.chapter, reader.page), (2, 1));
    await tester.fling(find.byType(Reader), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect(reader.chapter, 1);
    expect(reader.isOnChapterCommentsPage, isTrue);
    expect(reader.page, reader.totalPages);
    expect(find.byType(EmbeddedChapterCommentsPage), findsOneWidget);
    // One more turn back shows the chapter's last image.
    await tester.fling(find.byType(Reader), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect((reader.chapter, reader.page), (1, _pages));
    expect(reader.isOnChapterCommentsPage, isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);

    reader = await open(
      tester,
      'galleryLeftToRight',
      chapter: 2,
      comments: false,
    );
    await tester.fling(find.byType(Reader), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect((reader.chapter, reader.page), (1, _pages));
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
