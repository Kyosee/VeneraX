import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'cover_refresh_test';
const _comicId = 'cached-comic';
const _coverUrl = 'https://example.invalid/unchanged-cover.jpg';
const _provider = CachedImageProvider(
  _coverUrl,
  sourceKey: _sourceKey,
  cid: _comicId,
);

ComicDetails _details({String title = 'Cached comic'}) => ComicDetails.fromJson({
  'title': title,
  'cover': _coverUrl,
  'comicId': _comicId,
  'sourceKey': _sourceKey,
  'tags': <String, List<String>>{},
  'chapters': <String, String>{'1': 'Chapter 1'},
});

ComicSource _source(LoadComicFunc loadDetails) => ComicSource(
  'Cover refresh test',
  _sourceKey,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  loadDetails,
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CacheManager cache;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = Directory.systemTemp.createTempSync('comic-cover-refresh-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    appdata.settings['language'] = 'en-US';
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    cache = CacheManager();
    await cache.ready;
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicSourceManager().remove(_sourceKey);
    ComicDetailsCache().close();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  testWidgets('blocked details list all matching rules including saved favorites', (tester) async {
    const id = 'blocking-rules-test';
    final local = LocalComic(
      id: id, title: 'Current title', subtitle: '', tags: ['genre:Fantasy'],
      directory: root.path, cover: '', comicType: ComicType.local,
      chapters: null, downloadedChapters: const [], createdAt: DateTime.utc(2026),
    );
    await LocalManager().add(local);
    final favorites = LocalFavoritesManager();
    final folder = favorites.createFolder('Blocking rules test');
    final secondFolder = favorites.createFolder('Blocking rules test B');
    favorites.addComic(folder, FavoriteItem(
      id: id, name: 'Saved title', author: '', coverPath: '',
      type: ComicType.local, tags: ['genre:Magic'],
    ), null, 'Old follow time');
    favorites.addComic(secondFolder, FavoriteItem(
      id: id, name: 'Saved title', author: '', coverPath: '',
      type: ComicType.local, tags: ['genre:Magic'],
    )..hasNewUpdate = true, null, 'Follow-only');
    final oldWords = appdata.settings['blockedWords'];
    final oldTags = appdata.settings['blockedTags'];
    final oldFollowScope = appdata.settings[FollowUpdateScope.allFoldersKey];
    appdata.settings[FollowUpdateScope.allFoldersKey] = true;
    final wasInitialized = App.isInitialized;
    App.isInitialized = true;
    appdata.settings['blockedWords'] = ['Current', 'Saved', 'Old follow time', 'Follow-only', 'unrelated'];
    appdata.settings['blockedTags'] = ['Fantasy', 'genre:Magic'];
    addTearDown(() {
      App.domain.close();
      App.isInitialized = wasInitialized;
      appdata.settings['blockedWords'] = oldWords;
      appdata.settings['blockedTags'] = oldTags;
      appdata.settings[FollowUpdateScope.allFoldersKey] = oldFollowScope;
      favorites.deleteFolder(folder);
      favorites.deleteFolder(secondFolder);
      LocalManager().remove(id, ComicType.local);
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const ComicPage(id: id, sourceKey: 'local'),
    ));
    await tester.pump();
    expect(find.text('Blocked comic'), findsOneWidget);
    await tester.tap(find.text('Matched blocking rules'));
    await tester.pumpAndSettle();
    expect(find.text('Current\nSaved\nFollow-only'), findsOneWidget);
    expect(find.text('Fantasy\ngenre:Magic'), findsOneWidget);
    expect(find.text('unrelated'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('View anyway'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'pull-to-refresh during background loading refreshes an unchanged cover URL',
    (tester) async {
      final background = Completer<Res<ComicDetails>>();
      var detailRequests = 0;
      var sourceTitle = '日本語タイトル';
      var sourceFails = false;
      ComicSourceManager().add(
        _source((id) async {
          expect(id, _comicId);
          detailRequests++;
          if (sourceFails) return const Res.error('offline');
          return detailRequests == 1
              ? background.future
              : Res(_details(title: sourceTitle));
        }),
      );
      final history = History.fromModel(model: _details(), ep: 1, page: 7);
      HistoryManager().addHistory(history);
      addTearDown(() => HistoryManager().remove(_comicId, history.type));
      final favorites = LocalFavoritesManager();
      final folders = [
        favorites.createFolder('A'),
        favorites.createFolder('B'),
      ];
      for (final folder in folders) {
        for (final type in [history.type, ComicType.local]) {
          favorites.addComic(
            folder,
            FavoriteItem(
              id: _comicId,
              name: 'Saved title',
              type: type,
              coverPath: 'saved-cover',
              author: 'Saved author',
              tags: const [],
              favoriteTime: DateTime(2024),
            ),
          );
        }
      }
      void checkFavorites(String expectedTitle) {
        for (final folder in folders) {
          final item = favorites.getComic(folder, _comicId, history.type);
          expect(item.name, expectedTitle);
          expect(item.coverPath, 'saved-cover');
          expect(item.time, '2024-01-01 00:00:00');
          expect(
            favorites.getComic(folder, _comicId, ComicType.local).name,
            'Saved title',
          );
        }
      }

      ComicDetailsCache().update(_sourceKey, _comicId, _details());
      final diskKey = ImageDownloader.thumbnailCacheKey(
        _coverUrl,
        _sourceKey,
        _comicId,
      );
      await tester.runAsync(() => cache.writeCache(diskKey, [1, 2, 3]));
      final oldPixels = await tester.runAsync(
        () => createTestImage(width: 20, height: 30),
      );
      final images = PaintingBinding.instance.imageCache;
      images.putIfAbsent(
        _provider,
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: oldPixels!)),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: ComicPage(id: _comicId, sourceKey: _sourceKey),
        ),
      );
      await tester.pump();
      expect(detailRequests, 1);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      final cover = find.byWidgetPredicate(
        (widget) => widget is AnimatedImage && widget.image == _provider,
      );
      expect(cover, findsOneWidget);
      final oldCoverState = tester.state(cover);
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: cover, matching: find.byType(RawImage)),
            )
            .image!
            .width,
        20,
      );

      late Future<void> refresh;
      await tester.runAsync(() async {
        refresh = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
      });
      await tester.pump();
      expect(detailRequests, 1);

      background.complete(Res(_details()));
      await tester.pump();
      await tester.runAsync(() => refresh.timeout(const Duration(seconds: 5)));
      expect(detailRequests, 2);
      checkFavorites(sourceTitle);
      expect(HistoryManager().find(_comicId, history.type)!.title, sourceTitle);
      expect(HistoryManager().find(_comicId, history.type)!.page, 7);
      expect(await tester.runAsync(() => cache.findCache(diskKey)), isNull);
      expect(images.containsKey(_provider), isFalse);

      // Supply the new decoded frame before the next build, avoiding HTTP.
      final newPixels = await tester.runAsync(
        () => createTestImage(width: 40, height: 60),
      );
      images.putIfAbsent(
        _provider,
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: newPixels!)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.state(cover), isNot(same(oldCoverState)));
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: cover, matching: find.byType(RawImage)),
            )
            .image!
            .width,
        40,
      );
      expect(tester.takeException(), isNull);

      sourceTitle = '別のタイトル';
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.refresh),
      );
      await tester.runAsync(() async {
        final updated = Completer<void>();
        void onHistoryChanged() {
          final stored = HistoryManager().find(_comicId, history.type);
          if (!updated.isCompleted && stored?.title == sourceTitle) {
            updated.complete();
          }
        }

        HistoryManager().addListener(onHistoryChanged);
        try {
          button.onPressed!();
          await updated.future.timeout(const Duration(seconds: 5));
        } finally {
          HistoryManager().removeListener(onHistoryChanged);
        }
      });
      expect(detailRequests, 3);
      expect(HistoryManager().find(_comicId, history.type)!.title, sourceTitle);
      checkFavorites(sourceTitle);

      sourceFails = true;
      await tester.runAsync(
        tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh,
      );
      checkFavorites(sourceTitle);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'source title updates preserve downloads and hidden reading progress',
    () async {
      final type = ComicType.fromKey(_sourceKey);
      const id = 'downloaded-title';
      final created = DateTime(2024);
      final local = LocalManager();
      final history = HistoryManager();
      LocalComic download(ComicType type) => LocalComic(
        id: id,
        title: 'Old title',
        subtitle: 'Author',
        tags: const ['tag'],
        directory: 'original-directory',
        chapters: const ComicChapters({'one': 'Chapter one'}),
        cover: 'cover.jpg',
        comicType: type,
        downloadedChapters: const ['one'],
        createdAt: created,
      );
      await local.add(download(type));
      await local.add(download(ComicType.local));
      final record = History.fromModel(
        model: download(type),
        ep: 1,
        page: 23,
        readChapters: {'one'},
        time: created,
      );
      final save = history.addHistoryAsync(record);
      const repository = ComicStateRepository();
      final rename = repository.updateStoredSourceMetadata(
        id,
        type,
        _details(title: '新題'),
      );
      await Future.wait([save, rename]);
      expect(history.find(id, type)!.title, '新題');
      history.hide(id, type);
      await repository.updateStoredSourceMetadata(
        id,
        type,
        _details(title: '更新後'),
      );
      await repository.updateStoredSourceMetadata(id, type, _details(title: ' '));
      await repository.updateStoredSourceMetadata('absent', type, _details());

      final saved = local.find(id, type)!;
      expect(saved.title, '更新後');
      expect(saved.directory, 'original-directory');
      expect(saved.cover, 'cover.jpg');
      expect(saved.chapters!.allChapters, {'one': 'Chapter one'});
      expect(saved.downloadedChapters, ['one']);
      expect(saved.createdAt, created);
      expect(local.search('更新後').map((comic) => comic.id), contains(id));
      expect(local.find(id, ComicType.local)!.title, 'Old title');
      expect(local.find('absent', type), isNull);
      final stored = history.find(id, type)!;
      expect(stored.title, '更新後');
      expect(stored.page, 23);
      expect(stored.readEpisode, {'one'});
      expect(stored.time, created);
      expect(history.getAll(), isNot(contains(stored)));
      expect(history.find('absent', type), isNull);
    },
  );

  for (final grouped in [false, true]) {
    testWidgets(
      'chapter selection respects cleared history, grouped=$grouped',
      (tester) async {
        final wasInitialized = App.isInitialized;
        App.isInitialized = true;
        addTearDown(() {
          App.domain.close();
          App.isInitialized = wasInitialized;
        });
        tester.view.physicalSize = const Size(1200, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final details = ComicDetails.fromJson({
          'title': 'Cached comic',
          'cover': _coverUrl,
          'comicId': _comicId,
          'sourceKey': _sourceKey,
          'tags': <String, List<String>>{},
          'chapters': grouped
              ? const ComicChapters.grouped({
                  'Group A': {'a': 'Old chapter', 'b': 'New chapter'},
                  'Group B': {'c': 'Other chapter'},
                })
              : const ComicChapters({'a': 'Old chapter', 'b': 'New chapter'}),
        });
        expect(details.chapters!.isGrouped, grouped);
        ComicSourceManager().remove(_sourceKey);
        ComicSourceManager().add(_source((_) async => Res(details)));
        ComicDetailsCache().update(_sourceKey, _comicId, details);
        final history = History.fromModel(
          model: details,
          ep: 1,
          page: 7,
          group: grouped ? 1 : null,
          readChapters: {grouped ? '1-1' : '1'},
        );
        HistoryManager().addHistory(history);
        final pixels = await tester.runAsync(
          () => createTestImage(width: 20, height: 30),
        );
        PaintingBinding.instance.imageCache.putIfAbsent(
          _provider,
          () => OneFrameImageStreamCompleter(
            SynchronousFuture(ImageInfo(image: pixels!)),
          ),
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: ComicPage(id: _comicId, sourceKey: _sourceKey),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('Batch manage'));
        await tester.tap(find.byTooltip('Batch manage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New chapter'));
        await tester.pumpAndSettle();

        await tester.runAsync(
          () => HistoryManager().clearReadingProgress(history.id, history.type),
        );
        await tester.pumpAndSettle();
        expect(HistoryManager().find(history.id, history.type), isNull);
        await tester.tap(find.byTooltip('Mark as read'));
        await tester.pumpAndSettle();

        expect(HistoryManager().find(history.id, history.type)!.readEpisode, {
          grouped ? '1-2' : '2',
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
