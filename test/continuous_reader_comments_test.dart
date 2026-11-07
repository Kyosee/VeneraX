import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

const _sourceKey = 'continuous_comments_test';
const _comicId = 'sample-comic';
const _screenshots = String.fromEnvironment('READER_COMMENTS_SCREENSHOTS');
const _chapters = ComicChapters({'ep1': '第 12 话 · 雨后', 'ep2': '第 13 话 · 重逢'});

String _imageKey(String ep, int page) => 'file://reader-$ep-$page.png';

Future<ui.Image> _pageImage(String ep, int page) async {
  if (_screenshots.isEmpty) return createTestImage(width: 430, height: 200);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xffe4e9e6), BlendMode.src);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(16, 16, 398, 168),
      const Radius.circular(8),
    ),
    Paint()..color = const Color(0xfff6f8f6),
  );
  final label = TextPainter(
    text: TextSpan(
      text:
          '${ep == 'ep1' ? '第 12 话' : '第 13 话'} · ${page == 2 ? '末页' : '第 1 页'}（示例画面）',
      style: const TextStyle(
        fontFamily: 'Preview',
        fontSize: 17,
        color: Color(0xff57655d),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  label.paint(canvas, Offset((430 - label.width) / 2, page == 2 ? 145 : 90));
  label.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(430, 200);
  picture.dispose();
  return image;
}

ComicSource _source(ChapterCommentsLoader? comments) => ComicSource(
  'Reader comments test',
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
  (id, ep) async => Res([_imageKey(ep!, 1), _imageKey(ep, 2)]),
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  comments,
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
  final captureKey = GlobalKey();

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('reader-comments-');
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
    if (_screenshots.isNotEmpty) {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      if (Platform.isWindows) {
        final font = FontLoader('Preview');
        font.addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
        await font.load();
      }
    }
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

  void resetSettings() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['readerMode'] = 'continuousTopToBottom';
    appdata.settings['showChapterComments'] = true;
    appdata.settings['showChapterCommentsAtEnd'] = false;
    appdata.settings['enableContinuousChapterReading'] = true;
    appdata.settings['enableClockAndBatteryInfoInReader'] = false;
    appdata.settings['enableTurnPageByVolumeKey'] = false;
    appdata.settings['autoRemoveFromReadLater'] = false;
    appdata.settings['enablePageAnimation'] = false;
    appdata.settings['limitImageWidth'] = false;
    appdata.settings['readerCenterPageOnTurn'] = false;
    appdata.settings['blockedCommentWords'] = <String>[];
    appdata.settings['readerPageSpacing'] = 0.0;
  }

  setUp(resetSettings);

  tearDown(() => ComicSourceManager().remove(_sourceKey));

  Future<History> openReader(
    WidgetTester tester, {
    bool supported = true,
    bool longComments = false,
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _source(
      supported
          ? (comic, ep, page, reply) async {
              expect(comic, _comicId);
              return Res(
                List.generate(
                  longComments ? 40 : 3,
                  (i) => Comment.fromJson({
                    'userName': ['翻页的猫', '山间有风', '晚灯'][i % 3],
                    'content': [
                      '这一话的留白很喜欢，最后一格看了好久。',
                      '读完直接接着看大家的讨论，再往下就是下一话，顺手多了。',
                      '这条评论是预览示例。期待下一话！',
                    ][i % 3],
                    'time': '${i + 1} 分钟前',
                  }),
                ),
                subData: 1,
              );
            }
          : null,
    );
    ComicSourceManager().add(source);
    for (final ep in _chapters.ids) {
      for (var page = 1; page <= 2; page++) {
        final provider = ReaderImageProvider(
          _imageKey(ep, page),
          _sourceKey,
          _comicId,
          ep,
          page,
          enableResize: true,
        );
        final pixels = await tester.runAsync(() => _pageImage(ep, page));
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
      'title': '雨后书简',
      'ep': 1,
      'page': 1,
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: _screenshots.isEmpty ? null : 'Preview',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff486b61),
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
          ),
          home: Scaffold(
            body: Reader(
              type: ComicType(source.intKey),
              cid: _comicId,
              name: '雨后书简',
              chapters: _chapters,
              history: history,
              author: '',
              tags: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return history;
  }

  ScrollController readerScroll(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView).first)
      .controller!;

  Future<void> closeReader(WidgetTester tester) async {
    final history = tester.widget<Reader>(find.byType(Reader)).history;
    await tester.pumpWidget(const SizedBox());
    // Native history writes and their fake-clock polling must both finish.
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
    resetSettings();
  }

  Future<void> checkLongComments(WidgetTester tester) async {
    final history = await openReader(tester, longComments: true);
    final comments = find.byKey(const ValueKey('chapter-comments-1'));
    expect(comments, findsOneWidget);
    expect(tester.widget<EmbeddedChapterCommentsPage>(comments).epId, 'ep1');
    final scroll = readerScroll(tester);
    scroll.jumpTo(1800);
    await tester.pumpAndSettle();
    expect(history.ep, 1);
    expect(history.page, 2);
    final next = find.descendant(
      of: comments,
      matching: find.widgetWithText(TextButton, 'Next Chapter'),
    );
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(history.ep, 2);
    expect(history.page, 1);
    expect(tester.takeException(), isNull);
    await closeReader(tester);
  }

  Future<void> checkSettings(WidgetTester tester) async {
    appdata.settings['enableContinuousChapterReading'] = false;
    appdata.settings['showChapterComments'] = false;
    await openReader(tester);
    expect(find.byType(EmbeddedChapterCommentsPage), findsNothing);
    appdata.settings['showChapterComments'] = true;
    final dynamic reader = tester.state(find.byType(Reader));
    reader.update();
    await tester.pumpAndSettle();
    expect(find.byType(EmbeddedChapterCommentsPage), findsOneWidget);
    expect(
      tester
          .widget<EmbeddedChapterCommentsPage>(
            find.byType(EmbeddedChapterCommentsPage),
          )
          .epId,
      'ep1',
    );
    appdata.settings['showChapterComments'] = false;
    reader.update();
    await tester.pumpAndSettle();
    expect(find.byType(EmbeddedChapterCommentsPage), findsNothing);
    expect(tester.takeException(), isNull);
    await closeReader(tester);
  }

  Future<void> checkUnsupportedSource(WidgetTester tester) async {
    await openReader(tester, supported: false);
    expect(find.byType(EmbeddedChapterCommentsPage), findsNothing);
    expect(find.text('Next Chapter'), findsWidgets);
    expect(tester.takeException(), isNull);
    await closeReader(tester);
  }

  Future<void> checkHorizontalScroll(WidgetTester tester) async {
    appdata.settings['readerMode'] = 'continuousLeftToRight';
    await openReader(tester, longComments: true);
    final outer = readerScroll(tester);
    outer.jumpTo(3870);
    await tester.pumpAndSettle();
    final comments = find.byKey(const ValueKey('chapter-comments-1'));
    expect(comments, findsOneWidget);
    final grid = find
        .descendant(
          of: comments,
          matching: find.byWidgetPredicate(
            (w) => w is ScrollView && w.controller != null,
          ),
        )
        .first;
    final inner = tester.widget<ScrollView>(grid).controller!;
    final beforeOuter = outer.offset;
    final beforeInner = inner.offset;
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(grid),
        scrollDelta: const Offset(0, 240),
      ),
    );
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(beforeInner));
    expect(outer.offset, beforeOuter);
    expect(tester.takeException(), isNull);
    await closeReader(tester);
  }

  testWidgets('continuous chapter comments, settings and navigation', (
    tester,
  ) async {
    await checkLongComments(tester);
    await checkSettings(tester);
    await checkUnsupportedSource(tester);
    await checkHorizontalScroll(tester);
    if (_screenshots.isNotEmpty) {
      for (final dark in [false, true]) {
        appdata.settings['language'] = 'zh-CN';
        await openReader(tester, dark: dark);
        final scroll = readerScroll(tester);
        scroll.jumpTo(300);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '$_screenshots/issue-123-preview-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
        await closeReader(tester);
      }
    }
  });
}
