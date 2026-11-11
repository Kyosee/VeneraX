import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('settings-navigation-');
    App.dataPath = temporary.path;
    App.cachePath = '${temporary.path}/cache';
    LocalManager().path = '${temporary.path}/comics';
    await AppTranslation.init();
    await CacheManager().ready;
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    await temporary.delete(recursive: true);
  });
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['readerNightMode'] = false;
    appdata.settings['readerNightModeFollowSystem'] = false;
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    appdata.settings['autoPageTurningMode'] = 'page';
  });

  Future<void> open(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
  }

  Future<void> openSection(WidgetTester tester, String title) async {
    final link = find.text(title.tl);
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextField).first, title.tl);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-result-$title')));
    await tester.pumpAndSettle();
  }

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('single-history progress setting is usable in $locale', (
      tester,
    ) async {
      const key = 'clearReadingProgressOnSingleHistoryDelete';
      const title =
          'Clear reading progress when deleting a single history entry';
      final original = appdata.settings[key];
      addTearDown(() => appdata.settings[key] = original);
      appdata.settings['language'] = locale;
      await open(tester, 390);
      await search(tester, title);

      final row = find.widgetWithText(ListTile, title.tl);
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      expect(toggle.hitTestable(), findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.runAsync(() async {
        await tester.tap(toggle);
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(appdata.settings[key], isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'wide settings starts populated and switches categories',
    (tester) async {
      await open(tester, 1100);
      expect(find.text('Page animation'), findsOneWidget);
      expect(find.text('Theme Mode'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('settings-category-5')));
      await tester.pumpAndSettle();
      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('Download Threads'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('settings-category-9')));
      await tester.pumpAndSettle();
      expect(find.text('Download Threads'), findsOneWidget);
      expect(find.text('Theme Mode'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('tablet settings consume the top inset before nested log pages', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 24);
    await open(tester, 900);
    final searchField = find.byType(TextField).first;
    expect(tester.getTopLeft(searchField).dy, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('settings-category-7')));
    await tester.pumpAndSettle();
    await openSection(tester, 'Diagnostics');
    await openSection(tester, 'Open Log');

    final logs = find.byType(LogsPage);
    final header = find.descendant(of: logs, matching: find.byType(Appbar));
    expect(MediaQuery.paddingOf(tester.element(logs)).top, 0);
    expect(MediaQuery.paddingOf(tester.element(logs)).bottom, 24);
    expect(tester.getSize(header).height, 52);
    expect(
      tester.getTopLeft(header).dy,
      tester.getBottomLeft(searchField).dy + 12,
    );
    final searchSurface = find
        .ancestor(of: searchField, matching: find.byType(Material))
        .first;
    final scaffold = find.descendant(of: logs, matching: find.byType(Scaffold));
    expect(
      tester.widget<Material>(searchSurface).color,
      tester.widget<Scaffold>(scaffold).backgroundColor ??
          Theme.of(tester.element(scaffold)).scaffoldBackgroundColor,
    );
    final headerBackground = tester
        .widgetList<Container>(
          find.descendant(of: header, matching: find.byType(Container)),
        )
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .first;
    expect(
      headerBackground.color,
      tester.widget<Material>(searchSurface).color,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested model pages share the settings pane and header surface', (
    tester,
  ) async {
    await open(tester, 900);
    await tester.tap(find.byKey(const ValueKey('settings-category-8')));
    await tester.pumpAndSettle();
    await openSection(tester, 'Translation models');
    final models = find.byType(TranslationModelsPage);
    expect(models, findsOneWidget);
    final searchSurface = find
        .ancestor(
          of: find.byType(TextField).first,
          matching: find.byType(Material),
        )
        .first;
    final header = find.descendant(
      of: models,
      matching: find.byType(SliverAppbar),
    );
    final headerSurface = find.descendant(
      of: header,
      matching: find.byType(Material),
    );
    expect(
      tester.widget<Material>(headerSurface.first).color,
      tester.widget<Material>(searchSurface).color,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [800.0, 950.0, 1100.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'settings search matches the detail surface at $width $brightness',
        (tester) async {
          if (width == 950) {
            tester.view.padding = const FakeViewPadding(left: 24, right: 24);
            tester.view.viewPadding = const FakeViewPadding(
              left: 24,
              right: 24,
            );
          }
          await open(tester, width);
          final theme = ThemeData(brightness: brightness);
          await tester.pumpWidget(
            MaterialApp(theme: theme, home: const SettingsPage()),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('settings-category-4')));
          await tester.pumpAndSettle();
          final searchField = find.byType(TextField).first;
          final searchSurface = find
              .ancestor(of: searchField, matching: find.byType(Material))
              .first;
          final title = find.descendant(
            of: find.byType(ExploreSettings),
            matching: find.text('Browsing & filters'),
          );
          expect(title, findsOneWidget);
          final detailSurface = find
              .ancestor(of: title, matching: find.byType(Material))
              .first;
          expect(
            tester.widget<Material>(searchSurface).color,
            tester.widget<Material>(detailSurface).color,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'desktop child pages stay beside the category sidebar',
    (tester) async {
      await open(tester, 1100);
      await openSection(tester, 'Page layout');
      expect(
        tester.widget<ReaderSettings>(find.byType(ReaderSettings)).section,
        'Page layout',
      );
      expect(
        find.byKey(const ValueKey('settings-category-1')).hitTestable(),
        findsOneWidget,
      );
      final root = tester.state<NavigatorState>(find.byType(Navigator).first);
      final detail = tester.state<NavigatorState>(find.byType(Navigator).last);
      expect(root.canPop(), isFalse);
      expect(detail.canPop(), isTrue);
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expect(find.text('Page animation'), findsOneWidget);
      expect(detail.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'foldable settings keep categories beside child pages at 626 pixels',
    (tester) async {
      await open(tester, 626);
      expect(find.text('Page animation'), findsOneWidget);
      await openSection(tester, 'Page layout');
      expect(
        tester.widget<ReaderSettings>(find.byType(ReaderSettings)).section,
        'Page layout',
      );
      expect(
        find.byKey(const ValueKey('settings-category-1')).hitTestable(),
        findsOneWidget,
      );
      final root = tester.state<NavigatorState>(find.byType(Navigator).first);
      expect(root.canPop(), isFalse);
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expect(find.text('Page animation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-category-5')));
      await tester.pumpAndSettle();
      expect(find.text('Proxy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('settings use the available pane width inside a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(child: SizedBox(width: 390, child: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderSettings), findsNothing);
    expect(find.byKey(const ValueKey('settings-category-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'settings retain the selected category when folding and unfolding',
    (tester) async {
      await open(tester, 626);
      await tester.tap(find.byKey(const ValueKey('settings-category-5')));
      await tester.pumpAndSettle();
      expect(find.text('Proxy'), findsOneWidget);

      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettings), findsNothing);
      expect(find.byKey(const ValueKey('settings-category-5')), findsOneWidget);

      tester.view.physicalSize = const Size(626, 900);
      await tester.pumpAndSettle();
      expect(find.text('Proxy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final width in [320.0, 390.0, 600.0]) {
    testWidgets('mobile child pages return to their category at $width', (
      tester,
    ) async {
      await open(tester, width);
      await tester.tap(find.byKey(const ValueKey('settings-category-1')));
      await tester.pumpAndSettle();
      await openSection(tester, 'Display settings');
      expect(find.text('Show Chapter Comments'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Page animation'), findsOneWidget);
      expect(find.text('Show Chapter Comments'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-category-1')), findsOneWidget);
      expect(find.byType(ReaderSettings), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short mobile choices open a bottom sheet at 320 pixels', (
    tester,
  ) async {
    appdata.settings['readerMode'] = 'continuousTopToBottom';
    await open(tester, 320);
    await tester.tap(find.byKey(const ValueKey('settings-category-1')));
    await tester.pumpAndSettle();
    await openSection(tester, 'Auto turning & preload');
    final mode = find.widgetWithText(ListTile, 'Auto page turning mode');
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(mode));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.left, greaterThanOrEqualTo(0));
    expect(sheet.right, lessThanOrEqualTo(320));
    await tester.runAsync(() async {
      await tester.tap(find.text('Scroll'));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(appdata.settings['autoPageTurningMode'], 'scroll');
    expect(find.text('Auto scroll speed'), findsOneWidget);
    expect(find.text('Auto page turning interval'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search reveals a control and can change target in the same category',
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

  testWidgets('search highlights the control instead of its matching heading', (
    tester,
  ) async {
    await open(tester, 1100);
    await search(tester, 'Reading mode');
    final row = find.widgetWithText(ListTile, 'Reading mode');
    final highlight = find.byKey(const ValueKey('settings-search-highlight'));
    expect(row.hitTestable(), findsOneWidget);
    expect(highlight, findsOneWidget);
    expect(tester.getRect(highlight).overlaps(tester.getRect(row)), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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
    await tester.ensureVisible(find.text('AI Translation'));
    await tester.pumpAndSettle();
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
