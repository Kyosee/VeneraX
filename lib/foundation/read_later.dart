import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites_meta.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// A single "Read Later" entry. Implements [Comic] so it can be rendered with
/// the same comic tiles/grids as everything else.
class ReadLaterItem implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String? subtitle;

  @override
  final String cover;

  final ComicType type;

  @override
  final List<String> tags;

  /// Time the item was added (used for ordering, most recent first).
  final DateTime time;

  const ReadLaterItem({
    required this.id,
    required this.title,
    this.subtitle,
    required this.cover,
    required this.type,
    this.tags = const [],
    required this.time,
  });

  ReadLaterItem.fromRow(Row row)
      : id = row["id"] as String,
        title = (row["title"] as String?) ?? "",
        subtitle = row["subtitle"] as String?,
        cover = (row["cover"] as String?) ?? "",
        type = ComicType(row["type"] as int),
        tags = _parseTags(row["tags"]),
        time = DateTime.fromMillisecondsSinceEpoch((row["time"] as int?) ?? 0);

  static List<String> _parseTags(Object? value) {
    if (value is! String || value.isEmpty) return const [];
    try {
      return decodeJsonList(value);
    } catch (_) {
      return const [];
    }
  }

  @override
  String get sourceKey => type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  String get description => "";

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  int? get maxPage => null;

  @override
  double? get stars => null;

  @override
  Map<String, dynamic> toJson() => {
        "id": id,
        "title": title,
        "subtitle": subtitle,
        "cover": cover,
        "type": type.value,
        "tags": tags,
        "time": time.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is ReadLaterItem &&
      other.id == id &&
      other.type.value == type.value;

  @override
  int get hashCode => Object.hash(id, type.value);
}

class ReadLaterManager with ChangeNotifier {
  static ReadLaterManager? cache;

  ReadLaterManager.create();

  factory ReadLaterManager() =>
      cache == null ? (cache = ReadLaterManager.create()) : cache!;

  late CommonDatabase _db;

  late String _dbPath;

  bool isInitialized = false;

  /// Cache of "type.value:id" keys, for fast [isExist] checks.
  final Set<String> _ids = {};

  static String _key(String id, ComicType type) => "${type.value}:$id";

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _dbPath = "${App.dataPath}/read_later.db";
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute(_createTableSql);
    _migrateSchema();
    _loadIds();
    isInitialized = true;
    notifyListeners();
  }

  /// Replaces this store's content with the database file at [sourcePath] by
  /// closing the connection, swapping the file, and reopening — see
  /// [restoreDatabaseFiles]. Runs inside the caller's exclusive window.
  Future<void> restoreFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError("ReadLaterManager is not initialized; cannot restore");
    }
    DatabaseGateway.instance.closeManaged(_dbPath);
    try {
      restoreDatabaseFiles({_dbPath: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(_dbPath);
    }
    _db.execute(_createTableSql);
    _migrateSchema();
    _loadIds();
    notifyListeners();
  }

  /// Canonical table schema. Kept as a constant so [init] and the rebuild path
  /// in [_migrateSchema] cannot drift apart.
  static const String _createTableSql = """
      create table if not exists read_later (
        id text,
        title text,
        subtitle text,
        cover text,
        type int,
        tags text,
        time int,
        primary key (id, type)
      );
    """;

  /// Expected columns, derived from the create-table schema above. Older
  /// databases were created before some columns existed; `create table if not
  /// exists` is a no-op for them, so we add any missing columns here. Adding a
  /// new field later only needs an entry in this map (mirrors the
  /// addColumnIfMissing pattern in domain_database/history/favorites), so a
  /// schema gap can never throw "no column named ..." again.
  static const Map<String, String> _expectedColumns = {
    "id": "text",
    "title": "text",
    "subtitle": "text",
    "cover": "text",
    "type": "int",
    "tags": "text",
    "time": "int",
  };

  void _migrateSchema() => migrateSchema(_db);

  /// Normalize the on-disk `read_later` table to our canonical schema.
  ///
  /// A WebDAV/import sync can replace read_later.db wholesale with a file
  /// created by a foreign app that happens to use a table also named
  /// `read_later` but with a different layout (extra columns, NOT NULL
  /// constraints, different types, CHECK constraints, etc.). We can't predict
  /// what those columns look like, and our fixed-column INSERT would break on
  /// any unexpected NOT NULL column. So instead of enumerating every possible
  /// mismatch, we normalize: if the on-disk columns aren't exactly our
  /// canonical set, rebuild the table to the canonical schema and migrate the
  /// data we recognize (intersection of columns). Foreign columns are dropped
  /// (we don't use them); columns we expect but the foreign table lacks are
  /// left empty.
  ///
  /// Exposed as a static method (taking the db) so it can be unit-tested
  /// without an [App] data path, and so [init] has a single source of truth.
  @visibleForTesting
  static void migrateSchema(CommonDatabase db) {
    final columns = db.select("PRAGMA table_info(read_later);");
    final existing = columns.map((c) => c["name"] as String).toSet();

    final hasExtraColumn = existing.any((c) => !_expectedColumns.containsKey(c));
    final missingColumn =
        _expectedColumns.keys.any((c) => !existing.contains(c));

    if (hasExtraColumn) {
      // Structure diverges from ours — rebuild to the canonical schema.
      _rebuildTable(db, existing);
      return;
    }

    // No foreign columns: only our own columns are present (possibly a subset
    // from an older version of *our* schema). Additively backfill the missing
    // ones so older databases keep working without losing data.
    if (missingColumn) {
      for (final entry in _expectedColumns.entries) {
        if (!existing.contains(entry.key)) {
          db.execute(
            "alter table read_later add column ${entry.key} ${entry.value};",
          );
        }
      }
    }
  }

  /// Rebuild `read_later` to the canonical schema, copying over the columns we
  /// still recognize. Runs in a transaction so a failure can't leave a
  /// half-migrated table.
  static void _rebuildTable(CommonDatabase db, Set<String> existing) {
    final carried =
        _expectedColumns.keys.where(existing.contains).toList();
    final columnList = carried.join(", ");
    db.execute("BEGIN TRANSACTION;");
    try {
      db.execute("alter table read_later rename to read_later_legacy;");
      db.execute(_createTableSql);
      if (carried.isNotEmpty) {
        db.execute(
          "insert or ignore into read_later ($columnList) "
          "select $columnList from read_later_legacy;",
        );
      }
      db.execute("drop table read_later_legacy;");
      db.execute("COMMIT;");
    } catch (e, s) {
      db.execute("ROLLBACK;");
      Log.error("ReadLater", "rebuild failed: $e", s);
    }
  }

  void _loadIds() {
    _ids.clear();
    try {
      final rows = _db.select("select id, type from read_later;");
      for (final row in rows) {
        _ids.add(_key(row["id"] as String, ComicType(row["type"] as int)));
      }
    } catch (e, s) {
      Log.error("ReadLater", e, s);
    }
  }

  bool isExist(String id, ComicType type) {
    if (!isInitialized) return false;
    return _ids.contains(_key(id, type));
  }

  int get count {
    if (!isInitialized) return 0;
    try {
      return _db.select("select count(*) from read_later;").first[0] as int;
    } catch (e, s) {
      Log.error("ReadLater", e, s);
      return 0;
    }
  }

  /// All items, most recent first.
  List<ReadLaterItem> getAll() {
    if (!isInitialized) return const [];
    try {
      final rows = _db.select("select * from read_later order by time desc;");
      return rows.map((r) => ReadLaterItem.fromRow(r)).toList();
    } catch (e, s) {
      Log.error("ReadLater", e, s);
      return const [];
    }
  }

  /// The [limit] most recently added items.
  List<ReadLaterItem> getRecent([int limit = 20]) {
    if (!isInitialized) return const [];
    try {
      final rows = _db.select(
        "select * from read_later order by time desc limit ?;",
        [limit],
      );
      return rows.map((r) => ReadLaterItem.fromRow(r)).toList();
    } catch (e, s) {
      Log.error("ReadLater", e, s);
      return const [];
    }
  }

  static const _insertSql = """
    insert or replace into read_later (id, title, subtitle, cover, type, tags, time)
    values (?, ?, ?, ?, ?, ?, ?);
  """;

  List<Object?> _sqlArgs(ReadLaterItem item) => [
        item.id,
        item.title,
        item.subtitle,
        item.cover,
        item.type.value,
        encodeJsonList(item.tags),
        item.time.millisecondsSinceEpoch,
      ];

  /// Add a comic to "Read Later". Builds the entry from any [Comic].
  Future<void> add(Comic comic) async {
    if (!isInitialized) return;
    final type = ComicType.fromKey(comic.sourceKey);
    await addItem(ReadLaterItem(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      cover: comic.cover,
      type: type,
      tags: comic.tags ?? const [],
      time: DateTime.now(),
    ));
  }

  /// Add a pre-built entry to "Read Later".
  Future<void> addItem(ReadLaterItem item) async {
    if (!isInitialized) return;
    _db.execute(_insertSql, _sqlArgs(item));
    _ids.add(_key(item.id, item.type));
    notifyListeners();
  }

  /// Add multiple pre-built entries in a single transaction.
  Future<void> addMultiple(List<ReadLaterItem> items) async {
    if (!isInitialized || items.isEmpty) return;
    _db.execute("BEGIN TRANSACTION;");
    try {
      for (final item in items) {
        _db.execute(_insertSql, _sqlArgs(item));
        _ids.add(_key(item.id, item.type));
      }
      _db.execute("COMMIT;");
    } catch (e) {
      _db.execute("ROLLBACK;");
      rethrow;
    }
    notifyListeners();
  }

  /// Add multiple comics, building entries from any [Comic].
  Future<void> addComics(List<Comic> comics) async {
    if (!isInitialized || comics.isEmpty) return;
    final now = DateTime.now();
    final items = comics.map((comic) {
      final type = ComicType.fromKey(comic.sourceKey);
      return ReadLaterItem(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        cover: comic.cover,
        type: type,
        tags: comic.tags ?? const [],
        time: now,
      );
    }).toList();
    await addMultiple(items);
  }

  Future<void> remove(String id, ComicType type) async {
    if (!isInitialized) return;
    _db.execute(
      "delete from read_later where id = ? and type = ?;",
      [id, type.value],
    );
    _ids.remove(_key(id, type));
    notifyListeners();
  }

  /// Toggle membership; returns the new state (true = now in read later).
  Future<bool> toggle(Comic comic) async {
    final type = ComicType.fromKey(comic.sourceKey);
    if (isExist(comic.id, type)) {
      await remove(comic.id, type);
      return false;
    }
    await add(comic);
    return true;
  }

  Future<void> removeMultiple(List<ReadLaterItem> items) async {
    if (!isInitialized || items.isEmpty) return;
    _db.execute("BEGIN TRANSACTION;");
    try {
      for (final item in items) {
        _db.execute(
          "delete from read_later where id = ? and type = ?;",
          [item.id, item.type.value],
        );
        _ids.remove(_key(item.id, item.type));
      }
      _db.execute("COMMIT;");
    } catch (e) {
      _db.execute("ROLLBACK;");
      rethrow;
    }
    notifyListeners();
  }

  Future<void> clearAll() async {
    if (!isInitialized) return;
    _db.execute("delete from read_later;");
    _ids.clear();
    notifyListeners();
  }

  /// Reload from disk after an import — re-open DB and refresh cache.
  Future<void> reload() async {
    if (isInitialized) {
      DatabaseGateway.instance.closeManaged(_dbPath);
      isInitialized = false;
    }
    await init();
  }

  void close() {
    if (!isInitialized) return;
    DatabaseGateway.instance.closeManaged(_dbPath);
    isInitialized = false;
  }
}
