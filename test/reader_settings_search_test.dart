import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('reader-settings-search-');
    App.dataPath = temporary.path;
    await AppTranslation.init();
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    temporary.deleteSync(recursive: true);
  });
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceId'] = 'search-test';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    appdata.settings['adaptiveReading'] = false;
    appdata.settings['readerNightMode'] = false;
    appdata.settings['readerNightModeFollowSystem'] = false;
    appdata.settings['showPageNumberInReader'] = true;
  });

  Future<void> open(
    WidgetTester tester, {
    void Function(String)? onChanged,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettings(
            showSearch: true,
            comicId: 'comic',
            comicSource: 'source',
            onChanged: onChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(ValueKey('settings-result-$title')));
    await tester.pumpAndSettle();
  }

  testWidgets('search stays at the top, scopes results and clears', (
    tester,
  ) async {
    await open(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    await search(tester, '  NIGHT MODE  ');
    expect(
      find.byKey(const ValueKey('settings-result-Night mode')),
      findsOneWidget,
    );
    await search(tester, 'Proxy');
    expect(find.text('No matching settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Enable comic specific settings'), findsOneWidget);
    expect(find.text('No matching settings'), findsNothing);
    expect(find.text('Enable device specific settings'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('localized search reveals a hidden prerequisite in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      await open(tester);
      await search(tester, 'Night mode intensity'.tl);
      await select(tester, 'Night mode intensity');
      expect(find.text('Night mode'.tl).hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-search-highlight')),
        findsOneWidget,
      );
      expect(
        find.text(
          'This option is unavailable in the current mode. Check the related controls below.'
              .tl,
        ),
        findsOneWidget,
      );
      expect(appdata.settings['readerNightMode'], isFalse);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      await search(tester, 'Split wide pages'.tl);
      await select(tester, 'Split wide pages');
      expect(find.text('Split wide pages'.tl).hitTestable(), findsOneWidget);
      await search(tester, 'Paged comic reading mode'.tl);
      await select(tester, 'Paged comic reading mode');
      expect(
        find.text('Adaptive reading mode'.tl).hitTestable(),
        findsOneWidget,
      );
      expect(appdata.settings['adaptiveReading'], isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('result edits the current comic and calls the reader callback', (
    tester,
  ) async {
    appdata.settings.setEnabledComicSpecificSettings('comic', 'source', true);
    final changed = <String>[];
    await open(tester, onChanged: changed.add);
    await search(tester, 'Show Page Number');
    await select(tester, 'Show Page Number');
    final row = find.ancestor(
      of: find.text('Show Page Number'),
      matching: find.byType(ListTile),
    );
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(
      appdata.settings.getReaderSetting(
        'comic',
        'source',
        'showPageNumberInReader',
      ),
      isFalse,
    );
    expect(appdata.settings['showPageNumberInReader'], isTrue);
    expect(changed, ['showPageNumberInReader']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'search finds grouped settings and preserves translation context',
    (tester) async {
      await open(tester);
      await search(tester, 'Gesture settings');
      expect(
        find.byKey(const ValueKey('settings-result-Top edge tap')),
        findsOneWidget,
      );
      await search(tester, 'AI Translation');
      await select(tester, 'AI Translation');
      await tester.tap(find.text('AI Translation'));
      await tester.pumpAndSettle();
      final translation = tester
          .widgetList<ReaderSettings>(find.byType(ReaderSettings))
          .last;
      expect(translation.translationOnly, isTrue);
      expect(translation.comicId, 'comic');
      expect(translation.comicSource, 'source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'sidebar search fits above the keyboard and back closes only the sidebar',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSideBar(
                  context,
                  const ReaderSettings(
                    showSearch: true,
                    comicId: 'comic',
                    comicSource: 'source',
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await search(tester, 'Split wide pages');
      final result = find.byKey(
        const ValueKey('settings-result-Split wide pages'),
      );
      expect(result.hitTestable(), findsOneWidget);
      expect(tester.getRect(result).bottom, lessThan(844 - 300));
      expect(
        tester.getRect(find.byType(TextField)).top,
        greaterThanOrEqualTo(24),
      );
      await select(tester, 'Split wide pages');
      expect(find.text('Split wide pages').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettings), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a 400 pixel sidebar keeps child pages local on a 2560 pixel desktop',
    (tester) async {
      tester.view.physicalSize = const Size(2560, 1440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Reader canvas'),
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showSideBar(
                        context,
                        const ReaderSettingsPanel(
                          child: ReaderSettings(
                            showSearch: true,
                            comicId: 'comic',
                            comicSource: 'source',
                          ),
                        ),
                        width: 400,
                      ),
                      child: const Text('Open settings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      void expectLocalPage() {
        final bounds = tester.getRect(find.byType(ReaderSettings).last);
        expect(bounds.left, closeTo(2160, 0.01));
        expect(bounds.width, closeTo(400, 0.01));
        expect(find.text('Reader canvas'), findsOneWidget);
        expect(
          tester.getRect(find.text('Reader canvas')).right,
          lessThan(2160),
        );
        expect(tester.takeException(), isNull);
      }

      Future<void> openPage(String title) async {
        final link = find.text(title);
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        await tester.tap(link);
        await tester.pumpAndSettle();
        expectLocalPage();
      }

      expectLocalPage();
      await search(tester, 'Proxy');
      expect(find.text('No matching settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Enable comic specific settings'), findsOneWidget);
      expect(find.text('Enable device specific settings'), findsNothing);

      await openPage('Page layout');
      expect(
        tester.widget<ReaderSettings>(find.byType(ReaderSettings).last).section,
        'Page layout',
      );
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expectLocalPage();
      expect(find.byType(TextField), findsOneWidget);

      await openPage('AI Translation');
      final translation = tester.widget<ReaderSettings>(
        find.byType(ReaderSettings).last,
      );
      expect(translation.translationOnly, isTrue);
      expect(translation.comicId, 'comic');
      expect(translation.comicSource, 'source');
      expect(find.text('LLM providers'), findsOneWidget);
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expectLocalPage();
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsPanel), findsNothing);
      expect(find.byType(ReaderSettings), findsNothing);
      expect(find.text('Reader canvas').hitTestable(), findsOneWidget);
      expect(find.text('Open settings').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
