import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late TargetPlatform? previousTarget;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('venerax-export-options-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousTarget = debugDefaultTargetPlatformOverride;
    App.dataPath = root.path;
    App.cachePath = root.path;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    try {
      await LocalManager().init();
    } finally {
      debugDefaultTargetPlatformOverride = previousTarget;
    }
    await TranslationStore().init();
    await AppTranslation.init();
    appdata.settings['language'] = 'en-US';
    appdata.implicitData['local_sort'] = 'default';
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    TranslationStore().close();
    LocalManager().close();
    JsEngine().dispose();
    await root.delete(recursive: true);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    debugDefaultTargetPlatformOverride = previousTarget;
  });

  LocalComic comic(String id, {String sourceKey = 'local'}) => LocalComic(
    id: id,
    title: 'Comic $id',
    subtitle: 'Author',
    tags: const [],
    directory: '${root.path}/$id',
    chapters: null,
    cover: 'cover.png',
    comicType: ComicType.fromKey(sourceKey),
    downloadedChapters: const [],
    createdAt: DateTime.utc(2026),
  );

  void translated(LocalComic comic, String sourceKey) {
    final chapter = TranslationChapterIdentity(
      scopePrefix: 'pageTranslation@2@auto>zh@$sourceKey@${comic.id}@0@',
      sourceKey: sourceKey,
      comicId: comic.id,
      chapterId: '0',
      sourceLang: 'auto',
      targetLang: 'zh',
    );
    TranslationStore().put(
      '${chapter.scopePrefix}p1@',
      const [],
      chapter: chapter,
    );
  }

  Future<void> openOptions(WidgetTester tester, List<LocalComic> comics) async {
    tester.view.physicalSize = const Size(390, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const LocalComicsPage(),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(LocalComicsPage));
    for (final comic in comics) {
      state.selectedItems[comic] = true;
    }
    final menu = state.buildMultiSelectMenu() as MenuButton;
    menu.entries
        .firstWhere((entry) => entry.text == 'Export .venera_comics')
        .onClick();
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
  }

  Future<void> closeOptions(WidgetTester tester) async {
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('untranslated selection hides the translation switch', (
    tester,
  ) async {
    translated(comic('not-selected'), 'local');
    await openOptions(tester, [comic('untranslated')]);
    expect(find.text('Include translation data'), findsNothing);
    expect(find.byType(SwitchListTile), findsOneWidget);
    await closeOptions(tester);
  });

  testWidgets(
    'translation switch defaults on and can be disabled independently',
    (tester) async {
      final selected = comic('translated');
      translated(selected, 'local');
      await openOptions(tester, [selected, comic('plain')]);
      final switchFinder = find.widgetWithText(
        SwitchListTile,
        'Include translation data',
      );
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      await tester.tap(find.text('Merge into a single .venera_comics'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(
                SwitchListTile,
                'Merge into a single .venera_comics',
              ),
            )
            .value,
        isTrue,
      );
      await closeOptions(tester);
    },
  );

  testWidgets(
    'uninstalled sources still expose the enabled translation switch',
    (tester) async {
      const sourceKey = 'missing-export-options-source';
      final selected = comic('uninstalled', sourceKey: sourceKey);
      expect(selected.sourceKey, startsWith('Unknown:'));
      translated(selected, sourceKey);
      await openOptions(tester, [selected]);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Include translation data'),
            )
            .value,
        isTrue,
      );
      await closeOptions(tester);
    },
  );
}
