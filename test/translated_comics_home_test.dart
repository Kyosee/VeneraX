import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/translated_comics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory tempDir;
  late String originalDataPath;
  late dynamic originalHomeSections;
  late dynamic originalEnabledComics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    originalDataPath = App.dataPath;
    originalHomeSections = appdata.settings['homeSections'];
    originalEnabledComics =
        appdata.implicitData['imageTranslationEnabledComics'];
    tempDir = await Directory.systemTemp.createTemp('venera-translated-home-');
    App.dataPath = tempDir.path;
    await TranslationStore().init();
  });

  tearDownAll(() async {
    TranslationStore().close();
    ComicDetailsCache().close();
    App.dataPath = originalDataPath;
    appdata.settings['homeSections'] = originalHomeSections;
    appdata.implicitData['imageTranslationEnabledComics'] =
        originalEnabledComics;
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    TranslationStore().clearAll();
    appdata.implicitData['imageTranslationEnabledComics'] = {
      'pending@src': true,
    };
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

    expect(find.text('Translation Library'), findsOneWidget);

    await tester.tap(find.text('Translation Library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TranslatedComicsPage), findsOneWidget);
    expect(find.text('Comic'), findsOneWidget);
    expect(find.text('Translated'), findsOneWidget);
    expect(find.text('Not translated'), findsOneWidget);

    await tester.tap(find.text('Not translated'));
    await tester.pumpAndSettle();
    expect(find.text('pending'), findsOneWidget);
    await tester.tap(find.text('Translated'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ComicTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Comic Translation'), findsOneWidget);
    expect(find.text('To translate'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('1 pages'), findsOneWidget);
    expect(find.byTooltip('Open comic details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chapter picker splits cached chapters by translation status', (
    tester,
  ) async {
    ComicDetailsCache().update(
      'src',
      'comic',
      ComicDetails.fromJson({
        'title': 'Comic',
        'subtitle': null,
        'cover': '',
        'description': null,
        'tags': <String, List<String>>{},
        'chapters': {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'},
        'sourceKey': 'src',
        'comicId': 'comic',
        'thumbnails': null,
        'recommend': null,
        'isFavorite': false,
        'subId': null,
        'isLiked': false,
        'likesCount': null,
        'commentCount': null,
        'uploader': null,
        'uploadTime': null,
        'updateTime': null,
        'url': null,
        'stars': null,
        'maxPage': null,
        'comments': null,
      }),
    );

    await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
    await tester.pump();
    await tester.tap(find.byType(ComicTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Comic Translation'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);

    await tester.tap(find.text('To translate'));
    await tester.pumpAndSettle();
    expect(find.text('Chapter 1'), findsNothing);
    expect(find.text('Chapter 2'), findsOneWidget);
  });

  testWidgets('group tabs only show groups for the active status', (
    tester,
  ) async {
    ComicDetailsCache().update(
      'src',
      'comic',
      ComicDetails.fromJson({
        'title': 'Comic',
        'subtitle': null,
        'cover': '',
        'description': null,
        'tags': <String, List<String>>{},
        'chapters': {
          'Translated edition': {'ch1': 'Chapter 1'},
          'Pending edition': {'ch2': 'Chapter 2'},
        },
        'sourceKey': 'src',
        'comicId': 'comic',
        'thumbnails': null,
        'recommend': null,
        'isFavorite': false,
        'subId': null,
        'isLiked': false,
        'likesCount': null,
        'commentCount': null,
        'uploader': null,
        'uploadTime': null,
        'updateTime': null,
        'url': null,
        'stars': null,
        'maxPage': null,
        'comments': null,
      }),
    );

    await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
    await tester.pump();
    await tester.tap(find.byType(ComicTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Translated edition'), findsOneWidget);
    expect(find.text('Pending edition'), findsNothing);
    await tester.tap(find.text('To translate'));
    await tester.pumpAndSettle();
    expect(find.text('Translated edition'), findsNothing);
    expect(find.text('Pending edition'), findsOneWidget);
  });
}
