import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// Persistent store of finished per-page translation text: the recognized
/// regions and their translated strings for one page, under one language pair.
///
/// This is the durable source of truth for translations — NOT a cache. The
/// rendered page image stays in [CacheManager] (re-derivable from these regions
/// at any time, free to LRU-evict); the text here is what lets a page
/// re-render — or render on another device — without paying for OCR or an LLM
/// request again. Nothing here expires; the user clears it explicitly.
///
/// Rows are keyed by the page's translation [cacheKey], the same composed
/// string the reader/pre-translation paths already use — it embeds
/// `sourceLang>targetLang`, the comic, the chapter and the image, and is built
/// to form deletable scope prefixes (see [ImageTranslationService.cacheKeyFor]).
/// Keying on it avoids parsing components back out (image keys are URLs that may
/// contain the field separator) and reuses the existing prefix scopes verbatim
/// for per-comic / per-chapter deletion.
///
/// It lives in its own database file so it rides the WebDAV/backup pipeline like
/// every other store: exporting the file and merging it on another device
/// carries a comic's translations across. Import merges (INSERT OR IGNORE) so
/// two devices that translated different chapters keep both halves.
class TranslationStore {
  static TranslationStore? _cache;

  TranslationStore.create();

  factory TranslationStore() => _cache ??= TranslationStore.create();

  late CommonDatabase _db;

  late String _dbPath;

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) return;
    _dbPath = "${App.dataPath}/image_translation.db";
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute(_createTableSql);
    _migrateSchema();
    isInitialized = true;
  }

  /// Merges the rows of another translation database at [sourcePath] into this
  /// one without dropping local rows — the WebDAV/backup import path. A device
  /// that translated chapters 1-5 and one that did 6-10 end up with all ten, and
  /// where both hold the same page the local row wins (INSERT OR IGNORE). The
  /// source is opened read-only and disposed before returning. Tolerates a
  /// foreign/absent file: an incompatible table simply merges nothing.
  Future<int> mergeFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError("TranslationStore is not initialized; cannot merge");
    }
    var src = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
    var merged = 0;
    try {
      var cols = src
          .select("PRAGMA table_info(translated_page);")
          .map((c) => c["name"] as String)
          .toSet();
      if (!_requiredColumns.every(cols.contains)) {
        return 0;
      }
      var rows = src.select(
        "select cache_key, regions, time from translated_page;",
      );
      _db.execute("BEGIN TRANSACTION;");
      try {
        for (var r in rows) {
          _db.execute(_insertIgnoreSql, [
            r["cache_key"],
            r["regions"],
            r["time"],
          ]);
          merged++;
        }
        _db.execute("COMMIT;");
      } catch (e) {
        _db.execute("ROLLBACK;");
        rethrow;
      }
    } catch (e, s) {
      Log.error("TranslationStore", "merge failed: $e", s);
    } finally {
      src.dispose();
    }
    return merged;
  }

  static const String _createTableSql = """
      create table if not exists translated_page (
        cache_key text primary key,
        regions text,
        time int
      );
    """;

  /// Columns a foreign database must have for [mergeFrom] to read it.
  static const _requiredColumns = ["cache_key", "regions", "time"];

  static const Map<String, String> _expectedColumns = {
    "cache_key": "text",
    "regions": "text",
    "time": "int",
  };

  void _migrateSchema() => migrateSchema(_db);

  /// Normalize the on-disk `translated_page` table to our canonical schema — a
  /// restore/merge can meet a file a foreign app happens to name the same.
  /// Mirrors [ReadLaterManager.migrateSchema]: rebuild on structural
  /// divergence, additively backfill a column missing from an older own schema.
  @visibleForTesting
  static void migrateSchema(CommonDatabase db) {
    final columns = db.select("PRAGMA table_info(translated_page);");
    final existing = columns.map((c) => c["name"] as String).toSet();
    final hasExtraColumn = existing.any((c) => !_expectedColumns.containsKey(c));
    final missingColumn =
        _expectedColumns.keys.any((c) => !existing.contains(c));
    if (hasExtraColumn) {
      _rebuildTable(db, existing);
      return;
    }
    if (missingColumn) {
      for (final entry in _expectedColumns.entries) {
        if (!existing.contains(entry.key)) {
          db.execute(
            "alter table translated_page add column ${entry.key} ${entry.value};",
          );
        }
      }
    }
  }

  static void _rebuildTable(CommonDatabase db, Set<String> existing) {
    final carried = _expectedColumns.keys.where(existing.contains).toList();
    final columnList = carried.join(", ");
    db.execute("BEGIN TRANSACTION;");
    try {
      db.execute(
        "alter table translated_page rename to translated_page_legacy;",
      );
      db.execute(_createTableSql);
      if (carried.isNotEmpty) {
        db.execute(
          "insert or ignore into translated_page ($columnList) "
          "select $columnList from translated_page_legacy;",
        );
      }
      db.execute("drop table translated_page_legacy;");
      db.execute("COMMIT;");
    } catch (e, s) {
      db.execute("ROLLBACK;");
      Log.error("TranslationStore", "rebuild failed: $e", s);
    }
  }

  static const _insertReplaceSql = """
    insert or replace into translated_page (cache_key, regions, time)
    values (?, ?, ?);
  """;

  static const _insertIgnoreSql = """
    insert or ignore into translated_page (cache_key, regions, time)
    values (?, ?, ?);
  """;

  /// Stores the finished [regions] of one page. An empty list is valid and
  /// meaningful: it records "this page has no translatable text", so the page is
  /// never re-analyzed. A local write overwrites (INSERT OR REPLACE) — a
  /// re-translate must win over whatever was there.
  void put(String cacheKey, List<TranslatedRegion> regions) {
    if (!isInitialized) return;
    _db.execute(_insertReplaceSql, [
      cacheKey,
      jsonEncode([for (var r in regions) r.toJson()]),
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }

  /// The stored regions for a page, or null when the page was never translated.
  /// An empty list means "translated, nothing to render" (the page has no text).
  List<TranslatedRegion>? get(String cacheKey) {
    if (!isInitialized) return null;
    try {
      var rows = _db.select(
        "select regions from translated_page where cache_key = ?;",
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      var data = jsonDecode(rows.first["regions"] as String);
      if (data is! List) return const [];
      return [
        for (var item in data)
          TranslatedRegion.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (e, s) {
      Log.error("TranslationStore", "get failed: $e", s);
      return null;
    }
  }

  /// Deletes every stored page whose key starts with [scopePrefix] — the same
  /// comic/chapter scope prefixes the rendered-image cache is cleared by, so a
  /// re-translate or "clear" drops both levels in lockstep. Returns rows removed.
  int deleteByPrefix(String scopePrefix) {
    if (!isInitialized) return 0;
    // Escape LIKE wildcards in the prefix so a '%' or '_' inside a key can't
    // widen the match; '\' is the explicit escape char below.
    var escaped = scopePrefix
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    _db.execute(
      "delete from translated_page where cache_key like ? escape '\\';",
      ['$escaped%'],
    );
    return _db.select("select changes();").first[0] as int;
  }

  /// Wipes every stored translation across all comics.
  int clearAll() {
    if (!isInitialized) return 0;
    _db.execute("delete from translated_page;");
    return _db.select("select changes();").first[0] as int;
  }

  int get count {
    if (!isInitialized) return 0;
    try {
      return _db.select("select count(*) from translated_page;").first[0]
          as int;
    } catch (e, s) {
      Log.error("TranslationStore", "count failed: $e", s);
      return 0;
    }
  }

  void close() {
    if (!isInitialized) return;
    DatabaseGateway.instance.closeManaged(_dbPath);
    isInitialized = false;
  }
}
