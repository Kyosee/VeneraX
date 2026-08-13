import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// Device-local cache of the last details a source returned for a comic, so a
/// revisited comic shows its chapter list (and group tabs) instantly while the
/// real request refreshes in the background.
///
/// Deliberately NOT part of the backup/sync payload: entries are derived data
/// and self-heal on the next successful details fetch.
class ComicDetailsCache {
  static ComicDetailsCache? _instance;

  factory ComicDetailsCache() =>
      _instance ??= ComicDetailsCache._open('${App.dataPath}/details_cache.db');

  @visibleForTesting
  static ComicDetailsCache openForTesting(String path) =>
      ComicDetailsCache._open(path);

  @visibleForTesting
  static int maxEntries = 2000;

  late final Database _db;

  final String _path;

  ComicDetailsCache._open(String path) : _path = path {
    _db = DatabaseGateway.instance.openManaged(path);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS details_cache (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        data TEXT NOT NULL,
        time INTEGER NOT NULL,
        PRIMARY KEY (source_key, comic_id)
      );
    ''');
    _prune();
  }

  @visibleForTesting
  void close() {
    DatabaseGateway.instance.closeManaged(_path);
    if (identical(_instance, this)) {
      _instance = null;
    }
  }

  /// Local comics have no source request to cache, and a collection's details
  /// are rebuilt from its own store on every load.
  static bool isCacheable(String sourceKey) {
    if (ComicType.fromKey(sourceKey) == ComicType.local) return false;
    return !ComicCollectionStore.isCollectionSourceKey(sourceKey);
  }

  ComicDetails? find(String sourceKey, String comicId) {
    if (!isCacheable(sourceKey)) return null;
    try {
      final rows = _db.select(
        'SELECT data FROM details_cache WHERE source_key = ? AND comic_id = ?;',
        [sourceKey, comicId],
      );
      if (rows.isEmpty) return null;
      final details = ComicDetails.fromJson(
        jsonDecode(rows.first[0] as String) as Map<String, dynamic>,
      );
      // Keep visited entries alive: pruning evicts by oldest [time].
      _db.execute(
        'UPDATE details_cache SET time = ? '
        'WHERE source_key = ? AND comic_id = ?;',
        [DateTime.now().millisecondsSinceEpoch, sourceKey, comicId],
      );
      return details;
    } catch (e) {
      // A malformed row must never break the details page; drop it instead.
      try {
        _db.execute(
          'DELETE FROM details_cache WHERE source_key = ? AND comic_id = ?;',
          [sourceKey, comicId],
        );
      } catch (_) {}
      Log.warning('ComicDetailsCache', 'Dropped bad cache entry: $e');
      return null;
    }
  }

  /// Stores [details] under ([sourceKey], [comicId]) — the page's navigation
  /// key, which may differ from the id the source normalized to. Skips the
  /// write when the cached copy is identical.
  void update(String sourceKey, String comicId, ComicDetails details) {
    if (!isCacheable(sourceKey)) return;
    try {
      final encoded = jsonEncode(encode(details));
      final rows = _db.select(
        'SELECT data FROM details_cache WHERE source_key = ? AND comic_id = ?;',
        [sourceKey, comicId],
      );
      if (rows.isNotEmpty && rows.first[0] == encoded) return;
      _db.execute(
        'INSERT OR REPLACE INTO details_cache '
        '(source_key, comic_id, data, time) VALUES (?, ?, ?, ?);',
        [sourceKey, comicId, encoded, DateTime.now().millisecondsSinceEpoch],
      );
    } catch (e) {
      Log.warning('ComicDetailsCache', 'Cache write failed: $e');
    }
  }

  void _prune() {
    try {
      final count =
          _db.select('SELECT COUNT(*) FROM details_cache;').first[0] as int;
      if (count <= maxEntries) return;
      _db.execute(
        'DELETE FROM details_cache WHERE rowid IN ('
        'SELECT rowid FROM details_cache ORDER BY time ASC, rowid ASC LIMIT ?'
        ');',
        [count - maxEntries],
      );
    } catch (_) {}
  }

  /// A [ComicDetails.fromJson]-compatible map. [ComicDetails.toJson] is not
  /// round-trip safe (its "subTitle"/"commentsCount" keys don't match what
  /// fromJson reads), so the cache keeps its own encoder. Comments and
  /// recommendations are dropped on purpose: they are enrichment the
  /// background refresh re-fetches anyway.
  static Map<String, dynamic> encode(ComicDetails details) {
    return {
      'title': details.title,
      'subtitle': details.subTitle,
      'cover': details.cover,
      'description': details.description,
      'tags': details.tags,
      'chapters': details.chapters?.toJson(),
      'sourceKey': details.sourceKey,
      'comicId': details.comicId,
      'thumbnails': details.thumbnails,
      'recommend': null,
      'isFavorite': details.isFavorite,
      'subId': details.subId,
      'likesCount': details.likesCount,
      'isLiked': details.isLiked,
      'commentCount': details.commentCount,
      'uploader': details.uploader,
      'uploadTime': details.uploadTime,
      'updateTime': details.updateTime,
      'url': details.url,
      'stars': details.stars,
      'maxPage': details.maxPage,
      'comments': null,
    };
  }
}
