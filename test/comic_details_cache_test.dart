import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

ComicDetails _details({
  required String id,
  Map<String, dynamic>? chapters,
  String title = 'Title',
}) {
  return ComicDetails.fromJson({
    'title': title,
    'subtitle': null,
    'cover': 'cover.jpg',
    'description': 'desc',
    'tags': {
      'Author': ['Someone'],
    },
    'chapters': chapters,
    'sourceKey': 'test_source',
    'comicId': id,
    'thumbnails': null,
    'recommend': null,
    'isFavorite': false,
    'subId': null,
    'likesCount': null,
    'isLiked': null,
    'commentCount': null,
    'uploader': null,
    'uploadTime': null,
    'updateTime': null,
    'url': null,
    'stars': null,
    'maxPage': null,
    'comments': null,
  });
}

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  late Directory tempDir;
  late ComicDetailsCache cache;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_details_cache_');
    cache = ComicDetailsCache.openForTesting('${tempDir.path}/details_cache.db');
  });

  tearDown(() {
    cache.close();
    ComicDetailsCache.maxEntries = 2000;
    tempDir.deleteSync(recursive: true);
  });

  test('returns null before anything is cached', () {
    expect(cache.find('test_source', 'a'), isNull);
  });

  test('round-trips flat chapters through cache', () {
    final details = _details(
      id: 'a',
      chapters: {'c1': 'Chapter 1', 'c2': 'Chapter 2'},
    );
    cache.update('test_source', 'a', details);

    final restored = cache.find('test_source', 'a');
    expect(restored, isNotNull);
    expect(restored!.chapters!.isGrouped, isFalse);
    expect(restored.chapters!.length, 2);
    expect(restored.chapters!.titles.toList(), ['Chapter 1', 'Chapter 2']);
    expect(restored.title, 'Title');
    expect(restored.tags['Author'], contains('Someone'));
  });

  test('round-trips grouped chapters and tabs', () {
    final details = _details(
      id: 'g',
      chapters: {
        'Main': {'m1': 'M1', 'm2': 'M2'},
        'Extra': {'e1': 'E1'},
      },
    );
    cache.update('test_source', 'g', details);

    final restored = cache.find('test_source', 'g')!;
    expect(restored.chapters!.isGrouped, isTrue);
    expect(restored.chapters!.groups.toList(), ['Main', 'Extra']);
    expect(restored.chapters!.length, 3);
  });

  test('overwrites an existing entry with new chapters', () {
    cache.update(
      'test_source',
      'a',
      _details(id: 'a', chapters: {'c1': 'Chapter 1'}),
    );
    cache.update(
      'test_source',
      'a',
      _details(id: 'a', chapters: {'c1': 'Chapter 1', 'c2': 'Chapter 2'}),
    );
    expect(cache.find('test_source', 'a')!.chapters!.length, 2);
  });

  test('does not cache local comics', () {
    cache.update('local', 'x', _details(id: 'x', chapters: {'c1': 'C1'}));
    expect(cache.find('local', 'x'), isNull);
  });

  test('does not cache collection sources', () {
    const key = 'comic_collection_1';
    cache.update(key, 'x', _details(id: 'x', chapters: {'c1': 'C1'}));
    expect(cache.find(key, 'x'), isNull);
  });

  test('prunes oldest entries beyond the cap', () {
    ComicDetailsCache.maxEntries = 3;
    // Re-open so the cap takes effect from a clean table.
    cache.close();
    cache = ComicDetailsCache.openForTesting('${tempDir.path}/details_cache.db');

    for (var i = 0; i < 5; i++) {
      cache.update(
        'test_source',
        'id$i',
        _details(id: 'id$i', chapters: {'c': 'C'}),
      );
    }
    // Pruning runs on open; force it by re-opening after the writes.
    cache.close();
    cache = ComicDetailsCache.openForTesting('${tempDir.path}/details_cache.db');

    var remaining = 0;
    for (var i = 0; i < 5; i++) {
      if (cache.find('test_source', 'id$i') != null) remaining++;
    }
    expect(remaining, 3);
  });

  test('drops a malformed row instead of throwing', () {
    final db = sqlite3.open('${tempDir.path}/details_cache.db');
    db.execute(
      "INSERT OR REPLACE INTO details_cache "
      "(source_key, comic_id, data, time) VALUES (?, ?, ?, ?);",
      ['test_source', 'bad', 'not json', 1],
    );
    db.dispose();

    expect(cache.find('test_source', 'bad'), isNull);
    // The bad row is gone, so a later good write is retrievable.
    cache.update(
      'test_source',
      'bad',
      _details(id: 'bad', chapters: {'c1': 'C1'}),
    );
    expect(cache.find('test_source', 'bad'), isNotNull);
  });
}
