import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPush = route;
  }
}

class _PausedDirectory extends Fake implements Directory {
  _PausedDirectory(this.directory, this.started, this.release);

  final Directory directory;
  final Completer<void> started;
  final Completer<void> release;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    if (!started.isCompleted) started.complete();
    await release.future;
    yield* directory.list(recursive: recursive, followLinks: followLinks);
  }
}

final class _PausedScan extends IOOverrides {
  _PausedScan(this.path);

  final String path;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return p.equals(path, this.path)
        ? _PausedDirectory(directory, started, release)
        : directory;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final local = LocalManager();
  final favorites = LocalFavoritesManager();
  final history = HistoryManager();
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late String initialClickBehavior;
  late List<int> cover;

  Future<LocalComic> addComic(String id, {int? size}) async {
    final directory = '${root.path}/comics/$id';
    if (size != null) {
      await Directory(directory).create(recursive: true);
      await File('$directory/cover.png').writeAsBytes(cover);
      await File('$directory/page.bin').writeAsBytes(List.filled(size, 0));
    }
    final comic = LocalComic(
      id: id,
      title: 'Comic $id',
      subtitle: 'Author',
      tags: const [],
      directory: directory,
      chapters: null,
      cover: 'cover.png',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime.utc(2026),
    );
    await local.add(comic);
    return comic;
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('venera-local-ui-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await appdata.init();
    initialClickBehavior = appdata.settings['onClickLocalComic'];
    await JsEngine().init();
    await ComicSourceManager().init();
    final previousTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await local.init();
    } finally {
      debugDefaultTargetPlatformOverride = previousTarget;
    }
    await favorites.init();
    await history.init();
    await AppTranslation.init();
    await CacheManager().ready;
    favorites.createFolder('Keep');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.white, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    try {
      cover = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
    await addComic('small', size: 1);
    await addComic('large', size: 100);
    await addComic('missing');
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    await DatabaseGateway.instance.runExclusive(() async {});
    local.close();
    favorites.close();
    history.close();
    JsEngine().dispose();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    await root.delete(recursive: true);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['onClickLocalComic'] = 'viewDetail';
    appdata.implicitData['local_sort'] = 'default';
  });

  Future<_RouteObserver> open(
    WidgetTester tester,
    Widget page, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        navigatorObservers: [observer],
        home: page,
      ),
    );
    await tester.pumpAndSettle();
    observer.lastPush = null;
    return observer;
  }

  SliverGridComics grid(WidgetTester tester) =>
      tester.widget<SliverGridComics>(find.byType(SliverGridComics));

  List<String> ids(WidgetTester tester) =>
      grid(tester).comics.map((comic) => comic.id).toList();

  Future<void> waitFor(WidgetTester tester, bool Function() complete) async {
    final timer = Stopwatch()..start();
    while (timer.elapsed < const Duration(seconds: 5)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (complete() &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Local library did not finish updating');
  }

  Future<void> selectSort(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  test('local comics open details by default', () {
    expect(initialClickBehavior, 'viewDetail');
  });

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    for (final width in [320.0, 1100.0]) {
      testWidgets('local click setting is searchable in $locale at $width', (
        tester,
      ) async {
        appdata.settings['language'] = locale;
        await open(tester, const SettingsPage(), width: width);
        await tester.enterText(
          find.byType(TextField).first,
          'Click local comic'.tl,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-result-Click local comic')),
        );
        await tester.pumpAndSettle();
        final row = find.widgetWithText(ListTile, 'Click local comic'.tl);
        expect(row.hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-search-highlight')),
          findsOneWidget,
        );
        await tester.runAsync(() => tester.tap(row));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Read'.tl).last);
          await appdata.saveData(false);
        });
        await tester.pumpAndSettle();
        expect(appdata.settings['onClickLocalComic'], 'read');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final action in ['viewDetail', 'read']) {
    testWidgets('local click uses $action and keeps reading progress', (
      tester,
    ) async {
      appdata.settings['onClickLocalComic'] = action;
      final observer = await open(tester, const LocalComicsPage());
      final comics = grid(tester);
      final comic =
          comics.comics.firstWhere((c) => c.id == 'small') as LocalComic;
      history.addHistory(History.fromModel(model: comic, ep: 2, page: 8));
      comics.onTap!(comic, 0);
      final route = observer.lastPush! as AppPageRoute;
      // Inspect the actual destination without mounting native reader plugins.
      final destination = route.builder(
        tester.element(find.byType(LocalComicsPage)),
      );
      if (action == 'read') {
        final reader = destination as Reader;
        expect(reader.cid, 'small');
        expect(reader.initialChapter, 2);
        expect(reader.initialPage, 8);
        expect(reader.type, ComicType.local);
      } else {
        final details = destination as ComicPage;
        expect(details.id, 'small');
        expect(details.sourceKey, 'local');
      }
      App.rootNavigatorKey.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      expect(history.find('small', ComicType.local)!.page, 8);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('direct reading still warns for missing local files', (
    tester,
  ) async {
    appdata.settings['onClickLocalComic'] = 'read';
    await open(tester, const LocalComicsPage());
    final comics = grid(tester);
    comics.onTap!(comics.comics.firstWhere((c) => c.id == 'missing'), 0);
    await tester.pumpAndSettle();
    expect(find.text('Comic Not Available'), findsOneWidget);
    expect(find.byType(Reader), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'size sorting is confirmed, persisted and filters current comics',
    (tester) async {
      await open(tester, const LocalComicsPage());
      final original = ids(tester);
      await selectSort(tester, 'Size Desc');
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(appdata.implicitData['local_sort'], 'default');
      expect(ids(tester), original);

      final dynamic state = tester.state(find.byType(LocalComicsPage));
      for (final sort in ['size_asc', 'size_desc']) {
        await selectSort(tester, sort == 'size_asc' ? 'Size Asc' : 'Size Desc');
        await tester.runAsync(() => tester.tap(find.text('Confirm')));
        final expected = sort == 'size_asc'
            ? ['missing', 'small', 'large']
            : ['large', 'small', 'missing'];
        await waitFor(
          tester,
          () =>
              (state.comics as List<LocalComic>).map((c) => c.id).join(',') ==
              expected.join(','),
        );
        expect(ids(tester), expected);
        expect(appdata.implicitData['local_sort'], sort);
      }

      await tester.ensureVisible(find.text('Not Downloaded'));
      await tester.pump();
      await tester.tap(find.text('Not Downloaded'));
      await waitFor(tester, () => (state.comics as List).length == 1);
      expect(ids(tester), ['missing']);
      await tester.ensureVisible(find.text('All'));
      await tester.pump();
      await tester.tap(find.text('All'));
      await waitFor(tester, () => (state.comics as List).length == 3);
      final pause = _PausedScan(local.find('small', ComicType.local)!.baseDir);
      await tester.runAsync(() async {
        IOOverrides.runWithIOOverrides<void>(() => state.update(), pause);
      });
      await tester.pump();
      await tester.runAsync(
        () => pause.started.future.timeout(const Duration(seconds: 5)),
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'small');
      expect((state.comics as List<LocalComic>).single.id, 'small');
      pause.release.complete();
      await waitFor(
        tester,
        () =>
            (state.comics as List<LocalComic>).map((c) => c.id).join(',') ==
            'small',
      );
      expect(ids(tester), ['small']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('delete switches remove favorites but retain history and files', (
    tester,
  ) async {
    late LocalComic comic;
    await tester.runAsync(() async {
      comic = await addComic('delete-ui', size: 5);
    });
    favorites.addComic(
      'Keep',
      FavoriteItem(
        id: comic.id,
        name: comic.title,
        author: comic.subtitle,
        coverPath: comic.cover,
        type: comic.comicType,
        tags: comic.tags,
      ),
    );
    history.addHistory(History.fromModel(model: comic, ep: 2, page: 8));
    await open(tester, const LocalComicsPage());
    final dynamic state = tester.state(find.byType(LocalComicsPage));
    final deleted = state.deleteComics([comic]) as Future<bool>;
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNWidgets(3));
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.text('Remove history'));
    await tester.tap(find.text('Also remove files on disk'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Remove local favorite'),
          )
          .value,
      isTrue,
    );
    await tester.runAsync(() => tester.tap(find.text('Confirm')));
    await tester.pumpAndSettle();
    expect(await deleted, isTrue);
    expect(local.find(comic.id, comic.comicType), isNull);
    expect(favorites.find(comic.id, comic.comicType), isEmpty);
    expect(history.find(comic.id, comic.comicType)!.page, 8);
    expect(File('${comic.baseDir}/page.bin').existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
