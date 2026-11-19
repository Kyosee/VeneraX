import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/translation_progress_surface.dart';
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
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/translated_comics_page.dart';
import 'package:venera/pages/tasks_page.dart';
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
    expect(find.widgetWithText(Appbar, 'Comic Translation'), findsOneWidget);
    expect(find.text('Pending translation'), findsOneWidget);
    expect(find.text('Translating'), findsOneWidget);
    expect(find.text('Translated'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('1 pages saved · Total unknown'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.byKey(const ValueKey('translation-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chapter with a failed page shows its failure count', (
    tester,
  ) async {
    TranslationStore().recordChapterPageCount('src', 'comic', 'ch1', 2);
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
    final row = find.byKey(const ValueKey('translation-chapter-ch1'));
    expect(
      find.descendant(of: row, matching: find.textContaining('1 failed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('Complete')),
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
      find.descendant(of: row, matching: find.textContaining('1 failed')),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('Complete')),
      findsOneWidget,
    );
    PreTranslationTaskManager.instance.currentTasks.add(task);
    addTearDown(
      () => PreTranslationTaskManager.instance.currentTasks.remove(task),
    );
    await tester.tap(find.byKey(const ValueKey('translation-manage')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('translation-select-visible')),
      findsNothing,
    );
    final checkbox = find.descendant(of: row, matching: find.byType(Checkbox));
    expect(tester.widget<Checkbox>(checkbox).onChanged, isNull);
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

    expect(find.widgetWithText(Appbar, 'Comic Translation'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('translation-filter-pending')));
    await tester.pumpAndSettle();
    expect(find.text('Chapter 1'), findsNothing);
    expect(find.text('Chapter 2'), findsOneWidget);
  });

  testWidgets(
    'edition selection stays explicit when the status filter changes',
    (tester) async {
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
      await tester.tap(
        find.byKey(const ValueKey('translation-filter-pending')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Translated edition'), findsOneWidget);
      expect(find.text('No matching chapters'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('translation-edition')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pending edition').last);
      await tester.pumpAndSettle();
      expect(find.text('Chapter 2'), findsOneWidget);
      expect(find.text('Chapter 1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'translating filter keeps chapter progress and pauses only its row',
    (tester) async {
      final wasBackgroundTask = App.isBackgroundTask;
      App.isBackgroundTask = true;
      addTearDown(() => App.isBackgroundTask = wasBackgroundTask);
      tester.view.physicalSize = const Size(840, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final manager = PreTranslationTaskManager.instance;
      final ninth = PreTranslationChapter(
        eid: '9',
        title: 'Chapter 9',
        total: 10,
        done: 4,
      );
      TranslationStore().recordChapterPageCount('src', 'comic', '9', 10);
      final tenth = PreTranslationChapter(eid: '10', title: 'Chapter 10');
      final task = PreTranslationTask(
        id: 'chapter-controls',
        cid: 'comic',
        sourceKey: 'src',
        comicType: ComicType.fromKey('src'),
        title: 'Comic',
        createdAt: DateTime(2026),
        chapters: [ninth, tenth],
      );
      manager.currentTasks.add(task);
      addTearDown(() => manager.currentTasks.remove(task));
      ComicDetailsCache().update(
        'src',
        'comic',
        ComicDetails.fromJson({
          'title': 'Comic',
          'cover': '',
          'comicId': 'comic',
          'sourceKey': 'src',
          'tags': <String, List<String>>{},
          'chapters': {
            'ch1': 'Chapter 1',
            '9': 'Chapter 9',
            '10': 'Chapter 10',
            '11': 'Chapter 11',
          },
        }),
      );
      await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
      await tester.pump();
      await tester.tap(find.byType(ComicTile).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-filter-translating')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 9'), findsOneWidget);
      expect(find.text('Chapter 10'), findsOneWidget);
      expect(find.text('Chapter 1'), findsNothing);
      expect(find.text('Chapter 11'), findsNothing);
      final progress = find.byKey(const ValueKey('translation-progress-9'));
      expect(tester.widget<TranslationProgressSurface>(progress).progress, .4);
      expect(
        tester.widget<TranslationProgressSurface>(progress).active,
        isTrue,
      );
      final unknown = tester.widget<TranslationProgressSurface>(
        find.byKey(const ValueKey('translation-progress-10')),
      );
      expect(unknown.progress, isNull);
      expect(unknown.active, isTrue);
      await tester.tap(find.byKey(const ValueKey('translation-toggle-9')));
      await tester.pumpAndSettle();
      expect(ninth.paused, isTrue);
      expect(tenth.paused, isFalse);
      expect(task.status, PreTranslationTaskStatus.running);
      expect(
        tester.widget<TranslationProgressSurface>(progress).paused,
        isTrue,
      );
      expect(tester.widget<TranslationProgressSurface>(progress).progress, .4);
      expect(find.textContaining('40%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('translation-manage')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-select-visible')),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 chapters selected'), findsOneWidget);
      expect(find.text('Pause 1 chapters'), findsOneWidget);
      expect(find.text('Resume 1 chapters'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('translation-pause-selected')),
      );
      await tester.pumpAndSettle();
      expect(tenth.paused, isTrue);
      expect(task.status, PreTranslationTaskStatus.running);
      expect(find.text('Resume 2 chapters'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('translation-cancel-selected')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Stop translation of 2 chapters? Saved pages are kept.'),
        findsOneWidget,
      );
      expect(ninth.canceled, isFalse);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(ninth.canceled, isTrue);
      expect(tenth.canceled, isTrue);
      expect(task.status, PreTranslationTaskStatus.canceled);
      expect(ninth.done, 4);
      expect(find.text('No matching chapters'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('translation-filter-pending')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 11'), findsOneWidget);
      expect(find.text('Chapter 9'), findsOneWidget);
      manager.historyTasks.remove(task);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bulk deletion removes only selected saved chapters after confirmation',
    (tester) async {
      final oldBackground = App.isBackgroundTask;
      final oldCache = App.cachePath;
      App.isBackgroundTask = true;
      App.cachePath = '${App.dataPath}/bulk-delete-cache';
      await tester.runAsync(() async => CacheManager().ready);
      addTearDown(() {
        DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
        CacheManager.instance = null;
        App.cachePath = oldCache;
        App.isBackgroundTask = oldBackground;
      });
      for (final eid in ['ch2', 'ch3']) {
        final chapter = TranslationChapterIdentity(
          scopePrefix: 'pageTranslation@2@auto>zh@src@comic@$eid@',
          sourceKey: 'src',
          comicId: 'comic',
          chapterId: eid,
          sourceLang: 'auto',
          targetLang: 'zh',
          comicTitle: 'Comic',
          chapterTitle: eid,
        );
        TranslationStore().put(
          '${chapter.scopePrefix}page1',
          const [],
          chapter: chapter,
        );
      }
      ComicDetailsCache().update(
        'src',
        'comic',
        ComicDetails.fromJson({
          'title': 'Comic',
          'cover': '',
          'comicId': 'comic',
          'sourceKey': 'src',
          'tags': <String, List<String>>{},
          'chapters': {
            'ch1': 'Chapter 1',
            'ch2': 'Chapter 2',
            'ch3': 'Chapter 3',
          },
        }),
      );
      await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
      await tester.pump();
      await tester.tap(find.byType(ComicTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translation-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translation-chapter-ch1')));
      await tester.tap(find.byKey(const ValueKey('translation-chapter-ch2')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-delete-selected')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Delete selected chapter translations?'),
        findsOneWidget,
      );
      expect(TranslationStore().chaptersFor('src', 'comic').length, 3);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (TranslationStore().chaptersFor('src', 'comic').length > 1 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(
        TranslationStore()
            .chaptersFor('src', 'comic')
            .map((chapter) => chapter.identity.chapterId),
        ['ch3'],
      );
      expect(find.text('Chapter 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'source totals and partial download lists fill saved chapter counts',
    (tester) async {
      const sourceKey = 'page_count_test';
      const comicId = 'page-count-book';
      final requests = <String?>[];
      final source = ComicSource(
        'Page counts',
        sourceKey,
        null,
        null,
        null,
        null,
        const [],
        null,
        null,
        null,
        null,
        (cid, eid) async {
          requests.add(eid);
          if (eid == 'bad') {
            return const Res<List<String>>.error('Fixture failure');
          }
          return Res(List.generate(7, (index) => 'fixture-page-$index'));
        },
        null,
        null,
        '',
        '',
        '1',
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
        null,
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(sourceKey));
      for (final eid in ['loaded', 'cached', 'unknown', 'bad']) {
        final identity = TranslationChapterIdentity(
          scopePrefix: 'pageTranslation@2@auto>zh@$sourceKey@$comicId@$eid@',
          sourceKey: sourceKey,
          comicId: comicId,
          chapterId: eid,
          sourceLang: 'auto',
          targetLang: 'zh',
          comicTitle: 'Page counts',
          chapterTitle: eid,
        );
        TranslationStore().put(
          '${identity.scopePrefix}p1@',
          [],
          chapter: identity,
        );
      }
      final download = ImagesDownloadTask.fromJson({
        'type': 'ImagesDownloadTask',
        'source': sourceKey,
        'comicId': comicId,
        'images': {
          'cached': ['first', 'missing', 'third'],
        },
        'downloadedCount': 2,
        'totalCount': 3,
        'missingPages': {
          'cached': [1],
        },
      })!;
      LocalManager().downloadingTasks.add(download);
      addTearDown(() => LocalManager().downloadingTasks.remove(download));
      // A reader or download source request records the full list before images.
      await source.loadComicPages!(comicId, 'loaded');
      expect(
        TranslationStore().chapterPageCounts(sourceKey, comicId)['loaded'],
        7,
      );
      final partialTask = PreTranslationTask(
        id: 'partial-local-page-count',
        cid: comicId,
        sourceKey: sourceKey,
        comicType: ComicType.fromKey(sourceKey),
        title: 'Page counts',
        createdAt: DateTime(2026),
        status: PreTranslationTaskStatus.paused,
        chapters: [
          PreTranslationChapter(
            eid: 'loaded',
            title: 'loaded',
            total: 1,
            done: 1,
          ),
          PreTranslationChapter(eid: 'bad', title: 'bad', total: 2, done: 1),
        ],
      );
      final history = PreTranslationTaskManager.instance.currentTasks;
      history.add(partialTask);
      addTearDown(() => history.remove(partialTask));
      requests.clear();
      await tester.pumpWidget(const MaterialApp(home: TranslatedComicsPage()));
      await tester.pump();
      await tester.tap(find.widgetWithText(ComicTile, 'Page counts').first);
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('1/7 pages saved'), findsOneWidget);
      expect(find.text('1/3 pages saved'), findsOneWidget);
      expect(
        find.textContaining('1 pages saved · Total unknown'),
        findsNWidgets(2),
      );
      expect(
        TranslationStore().chapterPageCounts(sourceKey, comicId)['bad'],
        isNull,
      );
      expect(
        TranslationStore()
            .chaptersFor(sourceKey, comicId)
            .every((chapter) => chapter.pageCount == 1),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('translation-menu-unknown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fetch page count'));
      await tester.pumpAndSettle();
      expect(requests, ['unknown']);
      expect(find.text('1/7 pages saved'), findsNWidgets(2));
      expect(
        PreTranslationTaskManager.instance.currentTasks.where(
          (task) => task.cid == comicId,
        ),
        [partialTask],
      );

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(Appbar, 'Comic Translation'),
          matching: find.byIcon(Icons.more_horiz),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fill missing page counts'));
      await tester.pumpAndSettle();
      expect(requests, ['unknown', 'bad']);
      expect(
        TranslationStore().chapterPageCounts(sourceKey, comicId)['bad'],
        isNull,
      );
      expect(
        find.textContaining('1 pages saved · Total unknown'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workspace shares comic metadata and scopes management selection',
    (tester) async {
      tester.view.physicalSize = const Size(840, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ComicDetailsCache().update(
        'src',
        'comic',
        ComicDetails.fromJson({
          'title': 'Comic',
          'cover': '',
          'comicId': 'comic',
          'sourceKey': 'src',
          'tags': <String, List<String>>{
            'author': ['Test Artist'],
          },
          'chapters': {
            'English': {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'},
            'Japanese': {'jp1': 'Chapter 1 (JP)'},
          },
        }),
      );
      final colors = ColorScheme.fromSeed(seedColor: Colors.purple);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: colors),
          home: const TranslatedComicsPage(),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(ComicTile).first);
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('translation-comic-header'));
      final title = find.byKey(const ValueKey('translation-comic-title'));
      final author = find.byKey(const ValueKey('translation-comic-author'));
      void expectHeader() {
        expect(
          find.descendant(of: header, matching: find.text('Comic')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: header, matching: find.text('Test Artist')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(author).dy,
          greaterThan(tester.getBottomLeft(title).dy),
        );
        expect(find.text('Translation Library / Chapters'), findsNothing);
        expect(find.text('Comic details / Pre-translate'), findsNothing);
        expect(find.text('Tasks / Translation'), findsNothing);
        expect(Theme.of(tester.element(header)).colorScheme, colors);
      }

      expectHeader();
      await tester.tap(find.byKey(const ValueKey('translation-manage')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-select-visible')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 chapters selected'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Re-translate 1 chapters'),
        findsOneWidget,
      );
      expect(find.text('Delete 1 chapter translations'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'absent');
      await tester.pumpAndSettle();
      expect(find.text('0 chapters selected'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('translation-retranslate')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(
        find.byKey(const ValueKey('translation-filter-pending')),
      );
      await tester.pumpAndSettle();
      expectHeader();
      await tester.enterText(find.byType(TextField), 'Chapter 2');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-select-visible')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 chapters selected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('translation-chapter-ch1')),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translation-edition')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Japanese').last);
      await tester.pumpAndSettle();
      expect(find.text('0 chapters selected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('translation-chapter-jp1')),
        findsOneWidget,
      );

      expectHeader();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Task queue'), findsNothing);
      expect(
        find.byKey(const ValueKey('translation-view-tasks')),
        findsNothing,
      );
      final pickerTabs = find.byKey(const ValueKey('translation-filters'));
      expect(tester.widget<AppTabBar>(pickerTabs).controller!.index, 1);
      await tester.tap(
        find.byKey(const ValueKey('translation-select-visible')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 chapters selected'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('translation-filter-attention')),
      );
      await tester.tap(
        find.byKey(const ValueKey('translation-filter-attention')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<AppTabBar>(pickerTabs).controller!.index, 4);
      expect(find.text('No matching chapters'), findsOneWidget);
      expect(find.text('0 chapters selected'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('translation-filter-stored')),
      );
      await tester.tap(find.byKey(const ValueKey('translation-filter-stored')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppTabBar>(
              find.byKey(const ValueKey('translation-filters')),
            )
            .controller!
            .index,
        3,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('translation-filter-pending')),
      );
      await tester.tap(
        find.byKey(const ValueKey('translation-filter-pending')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<AppTabBar>(pickerTabs).controller!.index, 1);
      expect(
        find.byKey(const ValueKey('translation-chapter-jp1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('translation-edition')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translation-filter-all')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-select-visible')),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 chapters selected'), findsOneWidget);
      expect(find.text('Pre-translate 1 chapters'), findsOneWidget);
      expect(find.text('Re-translate 1 chapters'), findsOneWidget);
      expect(find.widgetWithText(Appbar, 'Comic Translation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('translation-menu-ch1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View tasks'));
      await tester.pumpAndSettle();
      expect(find.byType(TasksPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
