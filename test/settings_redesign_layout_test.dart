import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/main.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

const _screenshots = String.fromEnvironment('SETTINGS_SCREENSHOTS');
const _categories = <int, (String, Type)>{
  0: ('appearance', AppSettings),
  1: ('reader', ReaderSettings),
  2: ('favorites', LocalFavoritesSettings),
  3: ('sync', DataSyncSettings),
  4: ('browsing', ExploreSettings),
  5: ('network', NetworkSettings),
  7: ('about', AboutSettings),
  8: ('translation', ReaderSettings),
  9: ('storage', DataSyncSettings),
  10: ('device', AppSettings),
};
const _sections = <int, List<String>>{
  0: ['Layout and navigation'],
  1: [
    'Page layout',
    'Auto turning & preload',
    'Gesture settings',
    'Display settings',
    'Image processing / enhancement',
    'Favorites settings',
    'E-ink screen',
  ],
  2: ['Sorting and placement', 'Library maintenance'],
  3: ['Data import & export', 'Sync preferences'],
  4: [
    'Card details',
    'Reading history',
    'Search preferences',
    'Browsing pages',
    'Content filters',
  ],
  7: ['Diagnostics'],
  8: ['Advanced translation settings', 'Help & cleanup'],
  9: ['Storage locations'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  final sidebarCaptureKey = GlobalKey();
  late Directory temporary;
  late String originalDataPath;
  late String originalCachePath;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('settings-redesign-');
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = temporary.path;
    App.cachePath = '${temporary.path}/cache';
    LocalManager().path = '${temporary.path}/comics';
    await AppTranslation.init();
    await appdata.init();
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    await CacheManager().ready;
    await LocalFavoritesManager().init();
    DataSync();

    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final fontFile = File('C:/Windows/Fonts/msyh.ttc');
    if (Platform.isWindows && await fontFile.exists()) {
      final fontBytes = ByteData.sublistView(await fontFile.readAsBytes());
      for (final family in [
        'Roboto',
        'Ahem',
        'Noto Sans CJK',
        'Microsoft YaHei',
        'Segoe UI',
      ]) {
        final font = FontLoader(family)..addFont(Future.value(fontBytes));
        await font.load();
      }
    } else if (_screenshots.isNotEmpty) {
      throw StateError('Screenshots require the Windows Microsoft YaHei font.');
    }
  });

  setUp(() {
    appdata.settings['language'] = 'zh-CN';
    appdata.settings['theme_mode'] = 'light';
    appdata.settings['color'] = 'purple';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['authorizationRequired'] = false;
    appdata.settings['webdav'] = <String>[];
    appdata.settings['imageTranslationProviders'] = <dynamic>[];
    appdata.settings['imageTranslationActiveProviderId'] = '';
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    appdata.settings['readerNightMode'] = false;
    appdata.settings['readerNightModeFollowSystem'] = false;
    appdata.settings['enableReaderImageEnhance'] = false;
    appdata.settings['enableCustomImageProcessing'] = false;
    appdata.settings['einkFullRefresh'] = false;
  });

  tearDown(() {
    App.mainNavigatorKey = null;
  });

  tearDownAll(() async {
    LocalFavoritesManager().close();
    await CacheManager.instance?.ready;
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    await temporary.delete(recursive: true);
  });

  Future<void> capture(
    WidgetTester tester,
    String name, {
    GlobalKey? key,
  }) async {
    if (_screenshots.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          (key ?? captureKey).currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$_screenshots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> open(
    WidgetTester tester,
    int category,
    Size size, {
    double textScale = 1,
    bool dark = false,
    bool captureHome = false,
    bool sidebar = false,
  }) async {
    final twoViews = size.width > 600;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Read the actual app theme without starting application initialization.
    final dynamic themeFactory = const MyApp().createState();
    final ThemeData theme = themeFactory.getTheme(
      Colors.purple,
      null,
      null,
      dark ? Brightness.dark : Brightness.light,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: App.rootNavigatorKey,
          theme: theme,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: sidebar
              ? Scaffold(
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 400,
                      child: RepaintBoundary(
                        key: sidebarCaptureKey,
                        child: const Material(
                          child: ReaderSettingsPanel(
                            child: ReaderSettings(
                              showSearch: true,
                              comicId: 'layout-preview',
                              comicSource: 'layout-preview',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : SettingsPage(initialPage: category),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Settings home at $size');
    if (!twoViews) {
      if (captureHome) {
        await capture(tester, 'android-home-${size.width.toInt()}');
      }
      final tile = find.byKey(ValueKey('settings-category-$category'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }
    expect(find.byType(_categories[category]!.$2), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'Category $category at $size',
    );
  }

  Future<void> scrollPage(WidgetTester tester, int category) async {
    final page = find.byType(_categories[category]!.$2).last;
    final scrollable = find
        .descendant(of: page, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Scroll category $category');
  }

  for (final size in [
    const Size(1100, 900),
    const Size(626, 900),
    const Size(390, 844),
    const Size(320, 760),
  ]) {
    final label = size.width > 720
        ? 'windows'
        : size.width == 626
        ? 'ios-foldable'
        : 'android';
    final textScale = size.width == 320 ? 1.3 : 1.0;
    for (final category in _categories.entries) {
      testWidgets(
        '$label ${size.width.toInt()} ${category.value.$1} renders at $textScale text scale',
        (tester) async {
          await open(
            tester,
            category.key,
            size,
            textScale: textScale,
            captureHome: category.key == 0,
          );
          await capture(
            tester,
            '$label-${category.value.$1}-${size.width.toInt()}',
          );
          await scrollPage(tester, category.key);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant.only(
          size.width > 720
              ? TargetPlatform.windows
              : size.width == 626
              ? TargetPlatform.iOS
              : TargetPlatform.android,
        ),
      );
    }
  }

  for (final category in _sections.entries) {
    for (final section in category.value) {
      testWidgets(
        'android 320 opens $section with enlarged text',
        (tester) async {
          await open(
            tester,
            category.key,
            const Size(320, 760),
            textScale: 1.3,
          );
          final entry = find.text(section.tl);
          expect(entry, findsOneWidget);
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          await tester.tap(entry);
          await tester.pumpAndSettle();
          expect(find.text(section.tl), findsOneWidget);
          expect(tester.takeException(), isNull, reason: section);
          await scrollPage(tester, category.key);
          final back = find.byTooltip('Back'.tl).last;
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(find.text(section.tl), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'Return from $section',
          );
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }

  testWidgets(
    'windows dark reading settings renders with enlarged text',
    (tester) async {
      await open(tester, 1, const Size(1100, 900), textScale: 1.3, dark: true);
      await capture(tester, 'windows-reader-dark-1100');
      await scrollPage(tester, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final category in [0, 1, 3]) {
    testWidgets(
      'windows 2560 ${_categories[category]!.$1} uses the full settings pane',
      (tester) async {
        await open(tester, category, const Size(2560, 1400));
        await capture(tester, 'windows-${_categories[category]!.$1}-2560');
        await scrollPage(tester, category);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final (category, title) in [(7, 'Diagnostics'), (1, 'E-ink screen')]) {
    testWidgets(
      'wide $title entry fills its entire final row',
      (tester) async {
        await open(tester, category, const Size(1100, 900));
        final label = find.text(title.tl);
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        final link = find
            .ancestor(of: label, matching: find.byType(InkWell))
            .first;
        final group = find
            .ancestor(
              of: label,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Material &&
                    widget.shape is RoundedRectangleBorder,
              ),
            )
            .first;
        final rowRect = tester.getRect(link);
        final groupRect = tester.getRect(group);
        expect(rowRect.width, closeTo(groupRect.width, 0.5));
        expect(rowRect.left, closeTo(groupRect.left, 0.5));
        expect(rowRect.right, closeTo(groupRect.right, 0.5));
        expect(tester.takeException(), isNull);
        await capture(
          tester,
          'windows-${_categories[category]!.$1}-full-row-1100',
        );
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    '400px reader sidebar stays compact inside a 2560px window',
    (tester) async {
      await open(tester, 1, const Size(2560, 1400), sidebar: true);
      expect(tester.getSize(find.byKey(sidebarCaptureKey)).width, 400);
      await capture(
        tester,
        'windows-reader-sidebar-400',
        key: sidebarCaptureKey,
      );
      await scrollPage(tester, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
