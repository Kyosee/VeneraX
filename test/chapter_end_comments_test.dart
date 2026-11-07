import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

class _CommentsSource implements ComicSource {
  _CommentsSource(this.chapterCommentsLoader, {this.sendChapterCommentFunc});

  @override
  final ChapterCommentsLoader chapterCommentsLoader;

  @override
  final SendChapterCommentFunc? sendChapterCommentFunc;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Comment _comment(String text) =>
    Comment.fromJson({'userName': 'Reader', 'content': text});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedCommentWords'] = <String>[];
  });

  Future<void> pumpComments(
    WidgetTester tester,
    ComicSource source, {
    ScrollController? controller,
    bool inline = true,
  }) async {
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final comments = EmbeddedChapterCommentsPage(
      comicId: 'comic',
      epId: 'episode-12',
      source: source,
      comicTitle: 'Test comic',
      chapterTitle: 'Chapter 12',
      scrollWithReader: inline,
      chapterNavigation: inline ? const Text('Next chapter') : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: inline
              ? SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      const SizedBox(height: 200),
                      comments,
                      const SizedBox(height: 900, child: Text('Chapter 13')),
                    ],
                  ),
                )
              : comments,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'inline comments share reader scrolling and load more on demand',
    (tester) async {
      final calls = <(String, String, int, String?)>[];
      final more = Completer<Res<List<Comment>>>();
      final source = _CommentsSource((comic, ep, page, reply) async {
        calls.add((comic, ep, page, reply));
        if (page == 2) return more.future;
        return Res([_comment('First page')], subData: 2);
      });
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await pumpComments(tester, source, controller: scroll);

      expect(calls, [('comic', 'episode-12', 1, null)]);
      expect(find.text('First page'), findsOneWidget);
      await tester.drag(find.text('First page'), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(calls.length, 1);

      await tester.tap(find.text('Load more comments'));
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last, ('comic', 'episode-12', 2, null));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Loading'))
            .onPressed,
        isNull,
      );
      more.complete(Res([_comment('Second page')], subData: 2));
      await tester.pumpAndSettle();
      expect(find.text('Second page'), findsOneWidget);
      expect(find.text('Load more comments'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline errors retry and empty comments keep chapter navigation',
    (tester) async {
      var requests = 0;
      final source = _CommentsSource((comic, ep, page, reply) async {
        if (++requests == 1) return const Res.error('Offline');
        return const Res([], subData: 1);
      });
      await pumpComments(tester, source);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Next chapter'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.text('No comments yet'), findsOneWidget);
      expect(find.text('Next chapter'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('gallery comments retain their bounded scrolling layout', (
    tester,
  ) async {
    final source = _CommentsSource((comic, ep, page, reply) async {
      return Res(List.generate(25, (i) => _comment('Comment $i')), subData: 1);
    });
    await pumpComments(tester, source, inline: false);
    expect(find.byTooltip('Exit'), findsOneWidget);
    await tester.drag(find.text('Comment 2'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Comment 2').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving comments during a send does not update disposed state', (
    tester,
  ) async {
    final sent = Completer<Res<bool>>();
    final source = _CommentsSource(
      (comic, ep, page, reply) async => const Res([], subData: 1),
      sendChapterCommentFunc: (comic, ep, text, reply) => sent.future,
    );
    await pumpComments(tester, source);
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    sent.complete(const Res(true));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard space is added only to the focused inline chapter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _CommentsSource(
      (comic, ep, page, reply) async => const Res([], subData: 1),
      sendChapterCommentFunc: (comic, ep, text, reply) async => const Res(true),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final chapter in [1, 2])
                  EmbeddedChapterCommentsPage(
                    key: ValueKey(chapter),
                    comicId: 'comic',
                    epId: 'ep$chapter',
                    source: source,
                    comicTitle: 'Test comic',
                    chapterTitle: 'Chapter $chapter',
                    scrollWithReader: true,
                    chapterNavigation: const SizedBox(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey(1));
    final second = find.byKey(const ValueKey(2));
    final firstHeight = tester.getSize(first).height;
    final secondHeight = tester.getSize(second).height;
    await tester.tap(find.byType(TextField).last);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getSize(first).height, firstHeight);
    expect(tester.getSize(second).height, secondHeight + 300);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
