import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['readerNightMode'] = false;
    appdata.settings['readerNightModeFollowSystem'] = false;
  });

  Future<void> open(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextField).first, title.tl);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-result-$title')));
    await tester.pumpAndSettle();
  }

  testWidgets('wide settings starts populated and switches categories', (
    tester,
  ) async {
    await open(tester, 1100);
    expect(find.text('Theme Mode'), findsOneWidget);
    await tester.ensureVisible(find.text('Network'));
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();
    expect(find.text('Download Threads'), findsOneWidget);
    expect(find.text('Theme Mode'), findsNothing);
  });

  testWidgets(
    'search expands a collapsed group and can change target in the same category',
    (tester) async {
      await open(tester, 1100);
      await search(tester, 'Language');
      expect(
        find.byKey(const ValueKey('settings-search-highlight')),
        findsOneWidget,
      );
      expect(find.text('Language').hitTestable(), findsWidgets);
      await search(tester, 'Theme Color');
      expect(
        find.byKey(const ValueKey('settings-search-highlight')),
        findsOneWidget,
      );
      expect(find.text('Theme Color').hitTestable(), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unavailable settings explain the prerequisite without enabling it',
    (tester) async {
      await open(tester, 1100);
      await search(tester, 'Night mode intensity');
      expect(
        find.text(
          'This option is unavailable in the current mode. Check the related controls below.',
        ),
        findsOneWidget,
      );
      expect(appdata.settings['readerNightMode'], isFalse);
      expect(
        find.byKey(const ValueKey('settings-search-highlight')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('AI translation opens separately and keeps the comic context', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderSettings(comicId: 'comic', comicSource: 'source'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('AI Translation'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('AI Translation'));
    await tester.pumpAndSettle();
    final page = tester
        .widgetList<ReaderSettings>(find.byType(ReaderSettings))
        .last;
    expect(page.translationOnly, isTrue);
    expect(page.comicId, 'comic');
    expect(page.comicSource, 'source');
    expect(find.text('LLM providers'), findsOneWidget);
  });

  for (final locale in ['zh-CN', 'zh-TW']) {
    testWidgets(
      'mobile localized search navigates to the actual control in $locale',
      (tester) async {
        appdata.settings['language'] = locale;
        await open(tester, 390);
        await search(tester, 'Download Threads');
        expect(
          find.byKey(const ValueKey('settings-search-highlight')),
          findsOneWidget,
        );
        expect(find.text('Download Threads'.tl).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
