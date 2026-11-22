import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    await OpenCC.init();
  });

  testWidgets(
    'source links open externally and a bundled notice opens offline',
    (tester) async {
      const fixture = 'doc/guide_links_fixture.md';
      const notice = 'doc/model-notices.en.md';
      const document =
          '# Links\n[Publisher](https://first.example/source)\n'
          '[Publisher](https://second.example/license)\n'
          '[Offline notice](model-notices.en.md)\n[Unknown](file:///private)';
      final messenger = tester.binding.defaultBinaryMessenger;
      final requested = <MethodCall>[];
      const platform = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(platform, (call) async {
        requested.add(call);
        return true;
      });
      messenger.setMockMessageHandler('flutter/assets', (message) async {
        final path = const StringCodec().decodeMessage(message);
        final data = switch (path) {
          fixture => document,
          notice => '# Local copy of model notices',
          _ => null,
        };
        return data == null ? null : const StringCodec().encodeMessage(data);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(platform, null);
        messenger.setMockMessageHandler('flutter/assets', null);
        rootBundle.evict(fixture);
        rootBundle.evict(notice);
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: GuidePage(assetPath: fixture)),
        );
        await rootBundle.loadString(fixture);
      });
      await tester.pumpAndSettle();
      Finder labeled(String text) => find.byWidgetPredicate(
        (w) => w is Text && w.textSpan?.toPlainText() == text,
      );
      Future<void> tapText(Finder finder) async {
        await tester.tapAt(tester.getTopLeft(finder) + const Offset(3, 10));
        await tester.pumpAndSettle();
      }

      await tapText(labeled('Publisher').first);
      await tapText(labeled('Publisher').last);
      await tapText(labeled('Unknown'));
      expect(requested.map((call) => call.arguments['url']), [
        'https://first.example/source',
        'https://second.example/license',
      ]);
      expect(requested.every((call) => call.method == 'launch'), isTrue);
      expect(
        requested.every(
          (call) =>
              call.arguments['useWebView'] == false &&
              call.arguments['useSafariVC'] == false,
        ),
        isTrue,
      );

      await tester.tapAt(
        tester.getTopLeft(labeled('Offline notice')) + const Offset(3, 10),
      );
      await tester.runAsync(() async {
        await tester.pump();
        await rootBundle.loadString(notice);
      });
      await tester.pumpAndSettle();
      expect(labeled('Local copy of model notices'), findsOneWidget);
      expect(requested.length, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in {
    'en-US': 'Finding settings',
    'zh-CN': '设置导航',
    'zh-TW': '設置導航',
  }.entries) {
    testWidgets('contents scrolls to an unanchored heading in ${entry.key}', (
      tester,
    ) async {
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = entry.key;
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: GuidePage()));
        await rootBundle.loadString(
          entry.key == 'en-US' ? 'doc/guide.en.md' : 'doc/guide.zh.md',
        );
      });
      await tester.pumpAndSettle();

      final titles = find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.textSpan?.toPlainText() == entry.value,
      );
      expect(titles, findsNWidgets(2));
      final heading = titles.last;
      expect(tester.getTopLeft(heading).dy, greaterThan(700));

      await tester.tapAt(
        tester.getTopLeft(titles.first) + const Offset(10, 10),
      );
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(heading).dy, inInclusiveRange(0, 200));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opening at an existing help anchor scrolls to its section', (
    tester,
  ) async {
    final previousLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = previousLanguage);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: GuidePage(anchor: GuideAnchor.autoPageTurning)),
      );
      await rootBundle.loadString('doc/guide.en.md');
    });
    await tester.pumpAndSettle();

    final heading = find
        .byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.textSpan?.toPlainText() == 'Auto page turning',
        )
        .last;
    expect(tester.getTopLeft(heading).dy, inInclusiveRange(0, 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated headings keep independent help targets', (
    tester,
  ) async {
    const assetPath = 'test/repeated-headings.md';
    final document =
        '''
# Repeated headings
${List.filled(30, 'Paragraph before the sections.').join('\n\n')}
## Section
First section.
<!--anchor:auto-page-turning-->
## Section
Second section.
<!--anchor:eink-->
## Section
${List.filled(30, 'Paragraph after the sections.').join('\n\n')}
''';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      return const StringCodec().decodeMessage(message) == assetPath
          ? const StringCodec().encodeMessage(document)
          : null;
    });
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      rootBundle.evict(assetPath);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: GuidePage(
            assetPath: assetPath,
            anchor: GuideAnchor.autoPageTurning,
          ),
        ),
      );
      await rootBundle.loadString(assetPath);
    });
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final headings = find.byWidgetPredicate(
      (widget) => widget is Text && widget.textSpan?.toPlainText() == 'Section',
    );
    expect(headings, findsNWidgets(3));
    expect(tester.getTopLeft(headings.at(1)).dy, inInclusiveRange(0, 200));
  });
}
