import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late TargetPlatform? previousTarget;
  final local = LocalManager();
  final favorites = LocalFavoritesManager();
  final history = HistoryManager();

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('venera-local-actions-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    App.dataPath = root.path;
    App.cachePath = root.path;
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await local.init();
    await favorites.init();
    await history.init();
    favorites.createFolder('Keep');
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    await DatabaseGateway.instance.runExclusive(() async {});
    local.close();
    favorites.close();
    history.close();
    JsEngine().dispose();
    await root.delete(recursive: true);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    debugDefaultTargetPlatformOverride = previousTarget;
  });

  LocalComic comic(String id, {ComicType type = ComicType.local}) => LocalComic(
    id: id,
    title: 'Comic $id',
    subtitle: 'Author',
    tags: const [],
    directory: '${root.path}/$id',
    chapters: null,
    cover: '',
    comicType: type,
    downloadedChapters: const [],
    createdAt: DateTime.utc(2026),
  );

  Future<void> file(String relativePath, int size) async {
    final target = File('${root.path}/$relativePath');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(List.filled(size, 0));
  }

  test(
    'file size sorting includes nested files and missing directories',
    () async {
      await file('small/cover.jpg', 3);
      await file('small/chapter/page.jpg', 7);
      await file('large/page.jpg', 24);
      final input = [comic('small'), comic('large'), comic('missing')];

      expect((await sortLocalComicsBySize(input)).map((c) => c.id), [
        'missing',
        'small',
        'large',
      ]);
      expect(
        (await sortLocalComicsBySize(input, descending: true)).map((c) => c.id),
        ['large', 'small', 'missing'],
      );
      expect(input.map((c) => c.id), ['small', 'large', 'missing']);
    },
  );

  test('file size sorting refreshes files changed by a download', () async {
    await file('growing/page.jpg', 1);
    await file('fixed/page.jpg', 10);
    final input = [comic('growing'), comic('fixed')];
    expect((await sortLocalComicsBySize(input)).first.id, 'growing');
    await file('growing/next.jpg', 20);
    expect((await sortLocalComicsBySize(input)).first.id, 'fixed');
    expect(LocalSortType.fromString('size_asc').value, 'size_asc');
    expect(LocalSortType.fromString('size_desc').value, 'size_desc');
  });

  test(
    'equal file sizes have a stable name order in both directions',
    () async {
      await file('equal-b/page.jpg', 10);
      await file('equal-a/page.jpg', 10);
      final input = [comic('equal-b'), comic('equal-a')];
      for (final descending in [false, true]) {
        expect(
          (await sortLocalComicsBySize(
            input,
            descending: descending,
          )).map((c) => c.id),
          ['equal-a', 'equal-b'],
        );
      }
    },
  );

  test('default deletion still removes files, favorites and history', () async {
    final target = comic('delete-default');
    await file('${target.id}/page.jpg', 4);
    await local.add(target);
    favorites.addComic(
      'Keep',
      FavoriteItem(
        id: target.id,
        name: target.title,
        author: target.subtitle,
        coverPath: target.cover,
        type: target.comicType,
        tags: target.tags,
      ),
    );
    history.addHistory(History.fromModel(model: target, ep: 2, page: 8));

    local.batchDeleteComics([target]);

    expect(local.find(target.id, target.comicType), isNull);
    expect(favorites.find(target.id, target.comicType), isEmpty);
    expect(history.find(target.id, target.comicType), isNull);
    final timer = Stopwatch()..start();
    while (await Directory(target.baseDir).exists()) {
      if (timer.elapsed > const Duration(seconds: 5)) {
        fail('Deleted comic files are still on disk');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });

  for (final removeFavorites in [false, true]) {
    for (final removeHistory in [false, true]) {
      test(
        'delete favorites=$removeFavorites and history=$removeHistory independently',
        () async {
          final id = 'delete-$removeFavorites-$removeHistory';
          await file('$id/page.jpg', 4);
          final targets = [comic(id), comic(id, type: const ComicType(12345))];
          for (final target in targets) {
            await local.add(target);
            favorites.addComic(
              'Keep',
              FavoriteItem(
                id: target.id,
                name: target.title,
                author: target.subtitle,
                coverPath: target.cover,
                type: target.comicType,
                tags: target.tags,
              ),
            );
            history.addHistory(
              History.fromModel(model: target, ep: 2, page: 8),
            );
          }

          local.batchDeleteComics(
            targets,
            removeFileOnDisk: false,
            removeFavorites: removeFavorites,
            removeHistory: removeHistory,
          );

          for (final target in targets) {
            expect(local.find(target.id, target.comicType), isNull);
            expect(
              favorites.find(target.id, target.comicType),
              removeFavorites ? isEmpty : ['Keep'],
            );
            final retained = history.find(target.id, target.comicType);
            if (removeHistory) {
              expect(retained, isNull);
            } else {
              expect(retained, isNotNull);
              expect(retained!.ep, 2);
              expect(retained.page, 8);
              expect(retained.title, target.title);
              expect(history.getAll().any((h) => h.id == target.id), isTrue);
            }
          }
          expect(File('${root.path}/$id/page.jpg').existsSync(), isTrue);
        },
      );
    }
  }
}
