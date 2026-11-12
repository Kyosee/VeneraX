import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'missing_pages_test';

final _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...List.filled(120, 0),
];

// Pages are served from the image cache; a page missing from the cache fails
// in getImageLoadingConfig, so no test touches the network.
ComicSource _source() => ComicSource(
      'Missing pages test',
      _sourceKey,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      null,
      null,
      null,
      (image, cid, eid) =>
          Future<Map<String, dynamic>>.error('Page gone: $image'),
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

Future<void> _cachePage(String comicId, String page) {
  return CacheManager().writeCache(
    ImageDownloader.imageCacheKey(page, _sourceKey, comicId, ''),
    _png,
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = Directory.systemTemp.createTempSync('venera-missing-pages-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    // LocalManager.init waits for ComicSourceManager.
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    await CacheManager().ready;
    debugDefaultTargetPlatformOverride = null;
    ComicSourceManager().add(_source());
  });

  tearDownAll(() async {
    ComicSourceManager().remove(_sourceKey);
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    await appdata.saveData(false);
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// Starts a single-chapter download. Pages named `good*` are cached.
  Future<ImagesDownloadTask> start(
    String comicId,
    List<String> pages, {
    int threads = 3,
  }) async {
    appdata.settings['downloadThreads'] = threads;
    final dir = Directory('${root.path}/$comicId')..createSync();
    for (final page in pages.where((p) => p.startsWith('good'))) {
      await _cachePage(comicId, page);
    }
    final details = ComicDetails.fromJson({
      'title': comicId,
      'cover': '',
      'comicId': comicId,
      'sourceKey': _sourceKey,
      'tags': <String, List<String>>{},
    });
    final task = ImagesDownloadTask.fromJson(
      ImagesDownloadTask(
        source: ComicSource.find(_sourceKey)!,
        comicId: comicId,
        comic: details,
      ).toJson()
        ..addAll({
          'path': dir.path,
          'cover': 'file://${dir.path}/cover.png',
          'images': {'': pages},
          'totalCount': pages.length,
        }),
    )!;
    addTearDown(task.pause);
    task.resume();
    return task;
  }

  bool pageSaved(ImagesDownloadTask task, int index) =>
      File('${task.path}/$index.png').existsSync();

  test('a failing page is skipped, then filled in on retry', () async {
    final task = await start('retry', ['good0', 'bad1', 'good2']);
    await _until(() => task.isError);

    expect(pageSaved(task, 0), isTrue);
    expect(pageSaved(task, 1), isFalse);
    expect(pageSaved(task, 2), isTrue);
    expect(task.toJson()['missingPages'], {
      '': [1],
    });
    expect(task.message, 'Failed pages: 1');
    expect(task.canKeepDownloadedPages, isTrue);

    // The page becomes available; retry fetches only that page.
    await _cachePage('retry', 'bad1');
    task.resume();
    await _until(() => LocalManager().find('retry', task.comicType) != null);

    expect(pageSaved(task, 1), isTrue);
    expect(task.toJson()['missingPages'], isEmpty);
    expect(task.isError, isFalse);
  });

  test('keeping downloaded pages finishes the comic without them', () async {
    final task = await start('keep', ['good0', 'bad1']);
    await _until(() => task.isError);

    task.keepDownloadedPages();
    await _until(() => LocalManager().find('keep', task.comicType) != null);

    expect(pageSaved(task, 0), isTrue);
    expect(pageSaved(task, 1), isFalse);
    expect(task.canKeepDownloadedPages, isFalse);
  });

  test('a run of failing pages stops the task instead of skipping', () async {
    final task = await start(
      'broken',
      ['bad0', 'bad1', 'bad2', 'bad3', 'bad4', 'good5'],
      threads: 5,
    );
    await _until(() => task.isError);

    expect(task.message, contains('Page gone'));
    expect(task.canKeepDownloadedPages, isFalse);
    expect(task.toJson()['missingPages'], {
      '': [0, 1, 2, 3],
    });
    expect(LocalManager().find('broken', task.comicType), isNull);
  });
}
