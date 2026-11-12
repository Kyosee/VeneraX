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
import 'package:venera/foundation/sqlite_connection.dart';
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
    var drained = false;
    unawaited(
      DatabaseGateway.instance
          .runExclusive(() async {})
          .then((_) => drained = true),
    );
    for (var i = 0; i < 500 && !drained; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(drained, isTrue);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicSourceManager().remove(_sourceKey);
  }

  Future<void> checkTurnBackOntoComments(WidgetTester tester) async {
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
  }

  dynamic scaffoldOf(WidgetTester tester) => tester.state(
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ReaderScaffold'),
  );

  Future<void> openToolbar(WidgetTester tester) async {
    final dynamic scaffold = scaffoldOf(tester);
    if (!scaffold.isOpen) scaffold.openOrClose();
    await tester.pumpAndSettle();
    expect(scaffold.isOpen, isTrue);
  }

  // Blank comment area: the tap zones are the outer 30% of the 400px width.
  const leftBlank = Offset(50, 450);
  const centerBlank = Offset(200, 450);
  const rightBlank = Offset(350, 450);

  Future<void> checkGalleryCommentsTaps(WidgetTester tester) async {
    final reader = await open(tester, 'galleryLeftToRight');
    final dynamic scaffold = scaffoldOf(tester);
    for (var i = 0; i < _pages; i++) {
      await tester.tapAt(rightBlank);
      await tester.pumpAndSettle();
    }
    expect(reader.isOnChapterCommentsPage, isTrue);

    final commentText = find.text('Comment 0').first;
    await openToolbar(tester);
    await tester.tap(commentText);
    await tester.pumpAndSettle();
    expect(scaffold.isOpen, isFalse);
    expect(reader.isOnChapterCommentsPage, isTrue);

    // The middle of the comments never opens the bars.
    await tester.tapAt(centerBlank);
    await tester.pumpAndSettle();
    expect(scaffold.isOpen, isFalse);
    expect(reader.isOnChapterCommentsPage, isTrue);

    // Controls in a tap zone keep working and don't turn the page.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(reader.isOnChapterCommentsPage, isTrue);
    final input = tester.getCenter(find.byType(TextField));
    await tester.tapAt(Offset(300, input.dy));
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.widget.focusNode.hasFocus, isTrue);
    expect(reader.isOnChapterCommentsPage, isTrue);
    // With the input focused, a tap only puts the keyboard away.
    await tester.tapAt(rightBlank);
    await tester.pumpAndSettle();
    expect(editable.widget.focusNode.hasFocus, isFalse);
    expect(reader.isOnChapterCommentsPage, isTrue);

    // Comment text on the left turns back to the last image.
    await tester.tap(commentText);
    await tester.pumpAndSettle();
    expect((reader.chapter, reader.page), (1, _pages));

    await tester.tapAt(rightBlank);
    await tester.pumpAndSettle();
    expect(reader.isOnChapterCommentsPage, isTrue);
    // On from the comments opens the next chapter.
    await tester.tapAt(rightBlank);
    await tester.pumpAndSettle();
    expect((reader.chapter, reader.page), (2, 1));
    expect(tester.takeException(), isNull);
    await close(tester);
  }

  Future<void> checkContinuousCommentsTaps(WidgetTester tester) async {
    final reader = await open(tester, 'continuousLeftToRight');
    final dynamic scaffold = scaffoldOf(tester);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView).first)
        .controller!;
    final comments = find.byKey(const ValueKey('chapter-comments-1'));

    Future<void> showComments() async {
      // Built only once scrolled near.
      for (var i = 0; i < 20 && comments.evaluate().isEmpty; i++) {
        scroll.jumpTo(scroll.offset + 300);
        await tester.pumpAndSettle();
      }
      final left = tester.getTopLeft(comments).dx;
      scroll.jumpTo(scroll.offset + left);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getTopLeft(comments).dx, moreOrLessEquals(0));
      expect((reader.chapter, reader.page), (1, _pages));
    }

    await showComments();
    await openToolbar(tester);
    await tester.tap(
      find.descendant(of: comments, matching: find.text('Comment 0')).first,
    );
    await tester.pumpAndSettle();
    expect(scaffold.isOpen, isFalse);

    // Back from the comments shows the chapter's last image whole.
    await tester.tapAt(leftBlank);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect((reader.chapter, reader.page), (1, _pages));
    final last = tester.getTopLeft(find.byWidgetPredicate(
      (w) =>
          w is ComicImage &&
          (w.image as ReaderImageProvider).imageKey == _imageKey('ep1', _pages),
    ));
    expect(last.dx, moreOrLessEquals(0));

    await showComments();
    await tester.tapAt(rightBlank);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect((reader.chapter, reader.page), (2, 1));
    expect(tester.takeException(), isNull);
    await close(tester);
  }

  // One test body: history writes don't settle across separate tests here.
  testWidgets('chapter comments page turns and taps', (tester) async {
    await checkTurnBackOntoComments(tester);
    await checkGalleryCommentsTaps(tester);
    await checkContinuousCommentsTaps(tester);
  });
}
