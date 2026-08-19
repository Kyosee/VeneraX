import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/translated_comics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory tempDir;
  late String originalDataPath;
  late dynamic originalHomeSections;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    originalDataPath = App.dataPath;
    originalHomeSections = appdata.settings['homeSections'];
    tempDir = await Directory.systemTemp.createTemp('venera-translated-home-');
    App.dataPath = tempDir.path;
    await TranslationStore().init();
  });

  tearDownAll(() async {
    TranslationStore().close();
    App.dataPath = originalDataPath;
    appdata.settings['homeSections'] = originalHomeSections;
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    TranslationStore().clearAll();
    appdata.settings['homeSections'] = [
      for (var section in kHomeSections)
        {'id': section.id, 'visible': section.id == 'translatedComics'},
    ];
    const chapter = TranslationChapterIdentity(
      scopePrefix: 'pageTranslation@2@auto>zh@src@comic@ch1@',
      sourceKey: 'src',
      comicId: 'comic',
      chapterId: 'ch1',
      sourceLang: 'auto',
      targetLang: 'zh',
      comicTitle: 'Comic',
      chapterTitle: 'Chapter 1',
    );
    TranslationStore().put(
      '${chapter.scopePrefix}page1',
      const [],
      chapter: chapter,
    );
  });

  test(
    'normalization appends the translated-comics section to old layouts',
    () {
      appdata.settings['homeSections'] = [
        {'id': 'history', 'visible': true},
      ];

      var layout = normalizeHomeLayout();

      expect(layout.map((item) => item.id), contains('translatedComics'));
      expect(
        layout.singleWhere((item) => item.id == 'translatedComics').visible,
        isTrue,
      );
    },
  );

  testWidgets('home card opens the comic list and reused chapter list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(find.text('Translated Comics'), findsOneWidget);

    await tester.tap(find.text('Translated Comics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TranslatedComicsPage), findsOneWidget);
    expect(find.text('Comic'), findsOneWidget);

    await tester.tap(find.byType(ComicTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Translated Chapters'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('1 pages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
