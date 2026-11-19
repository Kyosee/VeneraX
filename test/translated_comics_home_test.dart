import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/sqlite_connection.dart';
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

  testWidgets('a chapter with a failed page shows its failure count', (
    tester,
  ) async {
    final task = PreTranslationTask(
      id: 'partial',
      cid: 'comic',
      sourceKey: 'src',
      comicType: ComicType.fromKey('src'),
      title: 'Comic',
      createdAt: DateTime(2026),
      status: PreTranslationTaskStatus.completed,
      chapters: [
        PreTranslationChapter(
          eid: 'ch1',
          title: 'Chapter 1',
          total: 2,
          done: 1,
          failed: 1,
          failedPages: {1},
        ),
      ],
    );
    final history = PreTranslationTaskManager.instance.historyTasks;
    history.add(task);
    addTearDown(() => history.remove(task));
    await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
    await tester.pump();
    await tester.tap(find.byType(ComicTile).first);
    await tester.pumpAndSettle();
    final row = find.widgetWithText(CheckboxListTile, 'Chapter 1');
    expect(
      find.descendant(of: row, matching: find.text('Failed: 1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Translated')),
      findsNothing,
    );

    final oldCachePath = App.cachePath;
    App.cachePath = '${App.dataPath}/rendered';
    addTearDown(() async {
      await appdata.writeImplicitData();
      DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
      CacheManager.instance = null;
      App.cachePath = oldCachePath;
    });
    await tester.runAsync(() async {
      await CacheManager().ready;
      final key = ImageTranslationService.cacheKeyFor('src', 'comic', 'ch1', 2);
      final service = ImageTranslationService.instance;
      await CacheManager().writeCache(
        ImageTranslationService.renderedKey(key, task.config.mode),
        [42],
      );
      final finished = Completer<void>();
      service.schedule(
        key,
        'comic',
        'src',
        Uint8List(0),
        task.config,
        finished.complete,
        chapter: ImageTranslationService.chapterIdentity(
          cid: 'comic',
          sourceKey: 'src',
          eid: 'ch1',
          config: task.config,
        ),
      );
      await finished.future.timeout(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    expect(task.chapters.single.failed, 0);
    expect(task.chapters.single.done, 2);
    expect(task.chapters.single.failedPages, isEmpty);
    final persisted =
        appdata.implicitData['pre_translation_task_history'] as List;
    expect(PreTranslationTask.fromJson(persisted.single).hasFailures, isFalse);
    expect(
      find.descendant(of: row, matching: find.text('Failed: 1')),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.text('Translated')),
      findsOneWidget,
    );
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

  testWidgets('library page keeps comics matched by block rules', (
    tester,
  ) async {
    final previous = appdata.settings['blockedWords'];
    appdata.settings['blockedWords'] = ['Comic'];
    addTearDown(() => appdata.settings['blockedWords'] = previous);

    await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
    await tester.pump();

    expect(find.text('Comic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
