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
import 'package:venera/foundation/favorites.dart';
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

ComicDetails _details() => ComicDetails.fromJson({
  'title': 'Cached comic',
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

  testWidgets(
    'pull-to-refresh during background loading refreshes an unchanged cover URL',
    (tester) async {
      final background = Completer<Res<ComicDetails>>();
      var detailRequests = 0;
      ComicSourceManager().add(
        _source((id) async {
          expect(id, _comicId);
          detailRequests++;
          return detailRequests == 1 ? background.future : Res(_details());
        }),
      );
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
      await tester.pumpWidget(const SizedBox.shrink());
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
