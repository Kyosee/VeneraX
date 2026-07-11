import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_provider/local_favorite_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/tags_translation.dart';

import 'app.dart';
import 'comic_source/comic_source.dart';
import 'comic_state_repository.dart';
import 'comic_type.dart';
import 'favorites_meta.dart';

String _getTimeString(DateTime time) {
  return time.toIso8601String().replaceFirst("T", " ").substring(0, 19);
}

class FavoriteItem implements Comic {
  String name;
  String author;
  ComicType type;
  @override
  List<String> tags;
  @override
  String id;
  String coverPath;
  late String time;
  String? lastUpdateTime;
  bool? hasNewUpdate;
  int? lastCheckTime;

  /// Author list parsed from raw tags. Empty if unknown.
  List<String> authors;

  /// Comic serialization status (e.g. "连载中"/"完结"). Null if unknown.
  String? status;

  /// Source-provided update time string (raw, format varies by source).
  String? updateTimeMeta;

  /// Other metadata key→value (language, year, ...). Empty if none.
  Map<String, String> extraMeta;

  FavoriteItem({
    required this.id,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
    DateTime? favoriteTime,
    List<String>? authors,
    this.status,
    this.updateTimeMeta,
    Map<String, String>? extraMeta,
  }) : authors = authors ?? const [],
       extraMeta = extraMeta ?? const {} {
    var t = favoriteTime ?? DateTime.now();
    time = _getTimeString(t);
  }

  FavoriteItem.fromRow(Row row)
    : name = row["name"],
      author = row["author"],
      type = ComicType(row["type"]),
      tags = _parseTagsColumn(row["tags"]),
      id = row["id"],
      coverPath = row["cover_path"],
      time = row["time"],
      authors = _safeDecodeJsonList(row, "authors"),
      status = _safeReadString(row, "comic_status"),
      updateTimeMeta = _safeReadString(row, "update_time_meta"),
      extraMeta = _safeDecodeJsonMap(row, "extra_meta") {
    tags.remove("");
  }

  static List<String> _parseTagsColumn(Object? value) {
    if (value == null) return [];
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return [];
      if (trimmed.startsWith('[')) {
        return decodeJsonList(trimmed);
      }
      return trimmed.split(",").where((s) => s.isNotEmpty).toList();
    }
    return [];
  }

  static String? _safeReadString(Row row, String column) {
    try {
      final v = row[column];
      if (v == null) return null;
      final s = v.toString();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static List<String> _safeDecodeJsonList(Row row, String column) {
    try {
      return decodeJsonList(row[column]);
    } catch (_) {
      return const [];
    }
  }

  static Map<String, String> _safeDecodeJsonMap(Row row, String column) {
    try {
      return decodeJsonMap(row[column]);
    } catch (_) {
      return const {};
    }
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem && other.id == id && other.type == type;
  }

  @override
  int get hashCode => id.hashCode ^ type.hashCode;

  @override
  String toString() {
    var s = "FavoriteItem: $name $author $coverPath $hashCode $tags";
    if (s.length > 100) {
      return s.substring(0, 100);
    }
    return s;
  }

  @override
  String get cover => coverPath;

  @override
  String get description {
    var time = this.time.substring(0, 10);
    return appdata.settings['comicDisplayMode'] == 'detailed'
        ? "$time | ${type == ComicType.local ? 'local' : type.comicSource?.name ?? "Unknown"}"
        : "${type.comicSource?.name ?? "Unknown"} | $time";
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  int? get maxPage => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  String? get subtitle => authors.isNotEmpty ? authors.join(', ') : author;

  @override
  String get title => name;

  @override
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "author": author,
      "type": type.value,
      "tags": tags,
      "id": id,
      "coverPath": coverPath,
      "sourceKey": sourceKey,
      if (authors.isNotEmpty) "authors": authors,
      if (status != null) "status": status,
      if (updateTimeMeta != null) "updateTimeMeta": updateTimeMeta,
      if (extraMeta.isNotEmpty) "extraMeta": extraMeta,
      if (lastUpdateTime != null) "lastUpdateTime": lastUpdateTime,
      if (hasNewUpdate != null) "hasNewUpdate": hasNewUpdate,
      if (lastCheckTime != null) "lastCheckTime": lastCheckTime,
    };
  }

  static FavoriteItem fromJson(Map<String, dynamic> json) {
    var type = json["type"] as int;
    final favorite = FavoriteItem(
      id: json["id"] ?? json['target'],
      name: json["name"],
      author: json["author"],
      coverPath: json["coverPath"],
      type: ComicType(type),
      tags: List<String>.from(json["tags"] ?? []),
      authors: json["authors"] is List
          ? List<String>.from(json["authors"])
          : null,
      status: json["status"]?.toString(),
      updateTimeMeta: json["updateTimeMeta"]?.toString(),
      extraMeta: json["extraMeta"] is Map
          ? (json["extraMeta"] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )
          : null,
    );
    favorite.lastUpdateTime =
        json["lastUpdateTime"]?.toString() ?? json["last_update_time"]?.toString();
    final hasNewUpdate = json["hasNewUpdate"] ?? json["has_new_update"];
    if (hasNewUpdate is bool) {
      favorite.hasNewUpdate = hasNewUpdate;
    } else if (hasNewUpdate is num) {
      favorite.hasNewUpdate = hasNewUpdate != 0;
    }
    final lastCheckTime = json["lastCheckTime"] ?? json["last_check_time"];
    if (lastCheckTime is num) {
      favorite.lastCheckTime = lastCheckTime.toInt();
    }
    return favorite;
  }
}

class FavoriteItemWithFolderInfo extends FavoriteItem {
  String folder;

  FavoriteItemWithFolderInfo(FavoriteItem item, this.folder)
    : super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
        authors: item.authors,
        status: item.status,
        updateTimeMeta: item.updateTimeMeta,
        extraMeta: item.extraMeta,
      );
}

class FavoriteItemWithUpdateInfo extends FavoriteItem {
  String? updateTime;

  DateTime? get lastCheckDateTime => lastCheckTime == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastCheckTime!);

  FavoriteItemWithUpdateInfo(
    FavoriteItem item,
    this.updateTime,
    bool hasNewUpdate,
    int? lastCheckTime,
  ) : super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
        authors: item.authors,
        status: item.status,
        updateTimeMeta: item.updateTimeMeta,
        extraMeta: item.extraMeta,
      ) {
    lastUpdateTime = updateTime;
    this.hasNewUpdate = hasNewUpdate;
    this.lastCheckTime = lastCheckTime;
  }

  @override
  String get description {
    var updateTime = this.updateTime ?? "Unknown";
    var sourceName = type.comicSource?.name ?? "Unknown";
    return "$updateTime | $sourceName";
  }

  @override
  operator ==(Object other) {
    return other is FavoriteItemWithUpdateInfo &&
        other.updateTime == updateTime &&
        other.hasNewUpdate == hasNewUpdate &&
        super == other;
  }

  @override
  int get hashCode =>
      super.hashCode ^ updateTime.hashCode ^ hasNewUpdate.hashCode;
}

/// Follow-update bookkeeping of one favorited comic, captured with
/// [LocalFavoritesManager.snapshotUpdateInfo] before a backup import replaces
/// the favorites database and re-applied with
/// [LocalFavoritesManager.mergeUpdateInfo] afterwards.
typedef FollowUpdateInfoRow = ({
  String id,
  int type,
  String? lastUpdateTime,
  bool hasNewUpdate,
  int? lastCheckTime,
});

/// Folder name -> rows carrying follow-update bookkeeping.
typedef FollowUpdateInfoSnapshot = Map<String, List<FollowUpdateInfoRow>>;

class LocalFavoritesManager with ChangeNotifier {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  static const _nonFavoriteTables = {
    'folder_sync',
    'folder_order',
    'comic_links',
    'sqlite_sequence',
  };

  late CommonDatabase _db;
  late String _dbPath;

  bool isInitialized = false;

  late Map<String, int> counts;

  var _hashedIds = <int, int>{};

  int get totalComics {
    return _hashedIds.length;
  }

  int folderComics(String folder) {
    return counts[folder] ?? 0;
  }

  Future<void> init() async {
    counts = {};
    _dbPath = "${App.dataPath}/local_favorite.db";
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute("""
      create table if not exists folder_order (
        folder_name text primary key,
        order_value int
      );
    """);
    _db.execute("""
      create table if not exists folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    """);
    await appdata.ensureInit();
    var folderNames = _getFolderNamesWithDB();
    for (var folder in folderNames) {
      _ensureFavoriteFolderSchema(folder);
    }
    // Make sure the follow updates folder is ready
    var followUpdateFolder = appdata.settings['followUpdatesFolder'];
    if (followUpdateFolder is String &&
        folderNames.contains(followUpdateFolder)) {
      prepareTableForFollowUpdates(followUpdateFolder, false);
    } else {
      appdata.settings['followUpdatesFolder'] = null;
    }
    isInitialized = true;
    initCounts();
  }

  void initCounts() {
    for (var folder in folderNames) {
      counts[folder] = count(folder);
    }
    _initHashedIds(folderNames, _dbPath).then((value) {
      _hashedIds = value;
      notifyListeners();
    });
  }

  /// Replaces this store's content with the database file at [sourcePath] by
  /// closing the connection, swapping the file, and reopening — see
  /// [restoreDatabaseFiles]. Runs inside the caller's exclusive window, so no
  /// background-isolate reader can hold the old file during the swap.
  /// Callers wanting the #106 semantics must snapshot/merge follow-update
  /// bookkeeping around this call ([snapshotUpdateInfo] / [mergeUpdateInfo]).
  Future<void> restoreFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError(
        "LocalFavoritesManager is not initialized; cannot restore",
      );
    }
    DatabaseGateway.instance.closeManaged(_dbPath);
    try {
      restoreDatabaseFiles({_dbPath: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(_dbPath);
    }
    // Re-run the schema upkeep init() performs: the imported file may come
    // from an older version or lack the bookkeeping tables entirely.
    _db.execute("""
      create table if not exists folder_order (
        folder_name text primary key,
        order_value int
      );
    """);
    _db.execute("""
      create table if not exists folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    """);
    var names = _getFolderNamesWithDB();
    for (var folder in names) {
      _ensureFavoriteFolderSchema(folder);
    }
    // Unlike init(), a follow folder missing from the backup does NOT
    // unconfigure the setting: it is device-local, and a foreign backup must
    // not wipe this device's choice.
    var followUpdateFolder = appdata.settings['followUpdatesFolder'];
    if (followUpdateFolder is String && names.contains(followUpdateFolder)) {
      prepareTableForFollowUpdates(followUpdateFolder, false);
    }
    counts = {};
    initCounts();
    notifyListeners();
  }

  void refreshHashedIds() {
    _initHashedIds(folderNames, _dbPath).then((value) {
      _hashedIds = value;
      notifyListeners();
    });
  }

  void reduceHashedId(String id, int type) {
    var hash = id.hashCode ^ type;
    if (_hashedIds.containsKey(hash)) {
      if (_hashedIds[hash]! > 1) {
        _hashedIds[hash] = _hashedIds[hash]! - 1;
      } else {
        _hashedIds.remove(hash);
      }
    }
  }

  static Future<Map<int, int>> _initHashedIds(
    List<String> folders,
    String dbPath,
  ) {
    return DatabaseGateway.instance.isolateOp(
      dbPath,
      (db) async => _queryHashedIds(folders, db),
    );
  }

  static Map<int, int> _queryHashedIds(
    List<String> folders,
    CommonDatabase db,
  ) {
    var hashedIds = <int, int>{};
    for (var folder in folders) {
      var rows = db.select("""
        select id, type from "$folder";
      """);
      for (var row in rows) {
        var id = row["id"] as String;
        var type = row["type"] as int;
        var hash = id.hashCode ^ type;
        hashedIds[hash] = (hashedIds[hash] ?? 0) + 1;
      }
    }
    return hashedIds;
  }

  List<String> find(String id, ComicType type) {
    if (!isInitialized) return [];
    var res = <String>[];
    for (var folder in folderNames) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<List<String>> findWithModel(FavoriteItem item) async {
    var res = <String>[];
    for (var folder in folderNames) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [item.id, item.type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  List<String> _getTablesWithDB() {
    final tables = _db
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((element) => element["name"] as String)
        .toList();
    return tables;
  }

  Set<String> _tableColumns(String table) => _columnsOf(_db, table);

  bool _isFavoriteFolderTable(String table) =>
      _isFavoriteFolderTableOf(_db, table);

  void _createLocalFolderTable(String name) {
    _db.execute("""
      create table "$name"(
        id text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        translated_tags TEXT,
        authors TEXT,
        comic_status TEXT,
        update_time_meta TEXT,
        extra_meta TEXT,
        primary key (id, type)
      );
    """);
  }

  void _insertLocalFavoriteItem(
    String folder,
    FavoriteItem comic,
    int displayOrder, [
    String? updateTime,
  ]) {
    final translatedTags = _translateTags(comic.tags);
    _db.execute(
      """
      insert or replace into "$folder" (id, name, author, type, tags, cover_path, time, translated_tags, display_order, authors, comic_status, update_time_meta, extra_meta)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """,
      [
        comic.id,
        comic.name,
        comic.author,
        comic.type.value,
        comic.tags.join(","),
        comic.coverPath,
        comic.time,
        translatedTags,
        displayOrder,
        encodeJsonList(comic.authors),
        comic.status,
        comic.updateTimeMeta,
        encodeJsonMap(comic.extraMeta),
      ],
    );
    final lastUpdateTime = comic.lastUpdateTime ?? updateTime;
    final hasNewUpdate = comic.hasNewUpdate;
    final lastCheckTime = comic.lastCheckTime;
    if (lastUpdateTime != null || hasNewUpdate != null || lastCheckTime != null) {
      prepareTableForFollowUpdates(folder, false);
      final updates = <String>[];
      final args = <Object?>[];
      if (lastUpdateTime != null) {
        updates.add('last_update_time = ?');
        args.add(lastUpdateTime);
      }
      if (hasNewUpdate != null) {
        updates.add('has_new_update = ?');
        args.add(hasNewUpdate ? 1 : 0);
      }
      if (lastCheckTime != null) {
        updates.add('last_check_time = ?');
        args.add(lastCheckTime);
      }
      _db.execute(
        """
        update "$folder"
        set ${updates.join(', ')}
        where id == ? and type == ?;
      """,
        [...args, comic.id, comic.type.value],
      );
    }
    try {
      const ComicStateRepository().mirrorComic(comic);
    } catch (_) {}
  }

  void _ensureFavoriteFolderSchema(String folder) {
    var columns = _tableColumns(folder);
    if (!columns.contains('type')) {
      _db.execute("""
        alter table "$folder"
        add column type int;
      """);
      _db.execute(
        """
        update "$folder"
        set type = ?
        where type is null;
      """,
        [ComicType.local.value],
      );
      columns = _tableColumns(folder);
    }
    if (!columns.contains('display_order')) {
      _db.execute("""
        alter table "$folder"
        add column display_order int;
      """);
      _db.execute("""
        update "$folder"
        set display_order = rowid
        where display_order is null;
      """);
      columns = _tableColumns(folder);
    }
    if (!columns.contains('translated_tags')) {
      _db.execute("""
        alter table "$folder"
        add column translated_tags TEXT;
      """);
      var comics = getFolderComics(folder);
      for (var comic in comics) {
        var translatedTags = _translateTags(comic.tags);
        _db.execute(
          """
            update "$folder"
            set translated_tags = ?
            where id == ? and type == ?;
          """,
          [translatedTags, comic.id, comic.type.value],
        );
      }
    }
    final hasAuthors = columns.contains('authors');
    final hasStatus = columns.contains('comic_status');
    final hasUpdateTime = columns.contains('update_time_meta');
    final hasExtra = columns.contains('extra_meta');
    if (!hasAuthors) {
      _db.execute("""
        alter table "$folder" add column authors TEXT;
      """);
    }
    if (!hasStatus) {
      _db.execute("""
        alter table "$folder" add column comic_status TEXT;
      """);
    }
    if (!hasUpdateTime) {
      _db.execute("""
        alter table "$folder" add column update_time_meta TEXT;
      """);
    }
    if (!hasExtra) {
      _db.execute("""
        alter table "$folder" add column extra_meta TEXT;
      """);
    }
    if (!hasAuthors || !hasStatus || !hasUpdateTime || !hasExtra) {
      _backfillFavoriteMetaColumns(folder);
    }
  }

  /// One-shot migration: read each row's legacy `tags` column, classify by
  /// prefix and write the buckets into the new dedicated columns. Idempotent
  /// — only run when at least one new column is missing.
  void _backfillFavoriteMetaColumns(String folder) {
    final rows = _db.select(
      """select id, type, tags from "$folder";""",
    );
    for (final row in rows) {
      final raw = (row['tags'] as String?)?.split(',') ?? const <String>[];
      final buckets = splitFavoriteTags(raw);
      _db.execute(
        """
        update "$folder"
        set authors = ?, comic_status = ?, update_time_meta = ?, extra_meta = ?
        where id == ? and type == ?;
        """,
        [
          encodeJsonList(buckets.authors),
          buckets.status,
          buckets.updateTime,
          encodeJsonMap(buckets.extraMeta),
          row['id'],
          row['type'],
        ],
      );
    }
  }

  List<String> _getFolderNamesWithDB() {
    final folders = _getTablesWithDB();
    folders.removeWhere((folder) => !_isFavoriteFolderTable(folder));
    for (var folder in folders) {
      _ensureFavoriteFolderSchema(folder);
    }
    var folderToOrder = <String, int>{};
    for (var folder in folders) {
      var res = _db.select(
        """
        select * from folder_order
        where folder_name == ?;
      """,
        [folder],
      );
      if (res.isNotEmpty) {
        folderToOrder[folder] = res.first["order_value"];
      } else {
        folderToOrder[folder] = 0;
      }
    }
    folders.sort((a, b) {
      return folderToOrder[a]! - folderToOrder[b]!;
    });
    return folders;
  }

  void updateOrder(List<String> folders) {
    for (int i = 0; i < folders.length; i++) {
      _db.execute(
        """
        insert or replace into folder_order (folder_name, order_value)
        values (?, ?);
      """,
        [folders[i], i],
      );
    }
    notifyListeners();
  }

  int count(String folderName) {
    if (!isInitialized) return 0;
    return _db.select("""
      select count(*) as c
      from "$folderName"
    """).first["c"];
  }

  /// Empty while the store is down (init not run yet, or failed): reading
  /// through the `late` handle here used to throw LateInitializationError
  /// inside widget builds during degraded sessions, corrupting the element
  /// tree. Callers treat "no folders" as the safe degraded answer.
  List<String> get folderNames =>
      isInitialized ? _getFolderNamesWithDB() : const <String>[];

  int maxValue(String folder) {
    return _db.select("""
        SELECT MAX(display_order) AS max_value
        FROM "$folder";
      """).firstOrNull?["max_value"] ??
        0;
  }

  int minValue(String folder) {
    return _db.select("""
        SELECT MIN(display_order) AS min_value
        FROM "$folder";
      """).firstOrNull?["min_value"] ??
        0;
  }

  List<FavoriteItem> getFolderComics(String folder) {
    var rows = _db.select("""
        select * from "$folder"
        ORDER BY display_order;
      """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  static Future<List<FavoriteItem>> _getFolderComicsAsync(
    String folder,
    String dbPath,
  ) {
    return DatabaseGateway.instance.isolateOp(
      dbPath,
      (db) async => _queryFolderComics(folder, db),
    );
  }

  static List<FavoriteItem> _queryFolderComics(
    String folder,
    CommonDatabase db,
  ) {
    var rows = db.select("""
      select * from "$folder"
      ORDER BY display_order;
    """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  /// Start a new isolate to get the comics in the folder
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    return _getFolderComicsAsync(folder, _dbPath);
  }

  List<FavoriteItem> getAllComics() {
    var res = <FavoriteItem>{};
    for (final folder in folderNames) {
      var comics = _db.select("""
        select * from "$folder";
      """);
      res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
    }
    return res.toList();
  }

  static Future<List<FavoriteItem>> _getAllComicsAsync(
    List<String> folders,
    String dbPath,
  ) {
    return DatabaseGateway.instance.isolateOp(
      dbPath,
      (db) async => _queryAllComics(folders, db),
    );
  }

  static List<FavoriteItem> _queryAllComics(
    List<String> folders,
    CommonDatabase db,
  ) {
    var res = <FavoriteItem>{};
    for (final folder in folders) {
      var comics = db.select("""
        select * from "$folder";
      """);
      res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
    }
    return res.toList();
  }

  /// Start a new isolate to get all the comics
  Future<List<FavoriteItem>> getAllComicsAsync() {
    return _getAllComicsAsync(folderNames, _dbPath);
  }

  void addTagTo(String folder, String id, String tag) {
    _db.execute(
      """
      update "$folder"
      set tags = '$tag,' || tags
      where id == ?
    """,
      [id],
    );
    notifyListeners();
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    var res = <FavoriteItemWithFolderInfo>[];
    for (final folder in folderNames) {
      var comics = _db.select("""
        select * from "$folder";
      """);
      res.addAll(
        comics.map(
          (element) =>
              FavoriteItemWithFolderInfo(FavoriteItem.fromRow(element), folder),
        ),
      );
    }
    return res;
  }

  bool existsFolder(String name) {
    return folderNames.contains(name);
  }

  /// create a folder
  String createFolder(String name, [bool renameWhenInvalidName = false]) {
    if (name.isEmpty) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw "name is empty!";
      }
    }
    if (existsFolder(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    _createLocalFolderTable(name);
    counts[name] = 0;
    notifyListeners();
    return name;
  }

  void linkFolderToNetwork(String folder, String source, String networkFolder) {
    _db.execute(
      """
      insert or replace into folder_sync (folder_name, source_key, source_folder)
      values (?, ?, ?);
    """,
      [folder, source, networkFolder],
    );
  }

  bool isLinkedToNetworkFolder(
    String folder,
    String source,
    String networkFolder,
  ) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ? and source_key == ? and source_folder == ?;
    """,
      [folder, source, networkFolder],
    );
    return res.isNotEmpty;
  }

  (String?, String?) findLinked(String folder) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ?;
    """,
      [folder],
    );
    if (res.isEmpty) {
      return (null, null);
    }
    return (res.first["source_key"], res.first["source_folder"]);
  }

  bool comicExists(String folder, String id, ComicType type) {
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    return res.isNotEmpty;
  }

  FavoriteItem getComic(String folder, String id, ComicType type) {
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      throw Exception("Comic not found");
    }
    return FavoriteItem.fromRow(res.first);
  }

  String _translateTags(List<String> tags) {
    var res = <String>[];
    for (var tag in tags) {
      var translated = tag.translateTagsToCN;
      if (translated != tag) {
        res.add(translated);
      }
    }
    return res.join(",");
  }

  /// add comic to a folder.
  /// return true if success, false if already exists
  bool addComic(
    String folder,
    FavoriteItem comic, [
    int? order,
    String? updateTime,
  ]) {
    if (!existsFolder(folder)) {
      throw Exception("Folder does not exists");
    }
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [comic.id, comic.type.value],
    );
    if (res.isNotEmpty) {
      return false;
    }
    final displayOrder =
        order ??
        (appdata.settings['newFavoriteAddTo'] == "end"
            ? maxValue(folder) + 1
            : minValue(folder) - 1);
    _insertLocalFavoriteItem(folder, comic, displayOrder, updateTime);
    if (counts[folder] == null) {
      counts[folder] = count(folder);
    } else {
      counts[folder] = counts[folder]! + 1;
    }
    var hash = comic.id.hashCode ^ comic.type.value;
    _hashedIds[hash] = (_hashedIds[hash] ?? 0) + 1;
    notifyListeners();
    return true;
  }

  void moveFavorite(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    var res = _db.select(
      """
    select * from "$targetFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    if (res.isNotEmpty) {
      return;
    }

    _db.execute(
      """
      insert into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
      select id, name, author, type, tags, cover_path, time, ?
      from "$sourceFolder"
      where id == ? and type == ?;
    """,
      [minValue(targetFolder) - 1, id, type.value],
    );

    _db.execute(
      """
    delete from "$sourceFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    notifyListeners();
  }

  void batchMoveFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        _db.execute(
          """
          delete from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Move Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    refreshHashedIds();

    notifyListeners();
  }

  void batchCopyFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Copy Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }

    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    refreshHashedIds();

    notifyListeners();
  }

  /// Copy the given items into [targetFolder] without relying on a single
  /// source folder. Used by the "All folders" aggregated view where each item
  /// may originate from a different folder. Returns the number of items that
  /// were actually added (items already present in the target are skipped).
  int batchCopyFavoritesToFolder(
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }
    var added = 0;
    var addedItems = <FavoriteItem>[];
    _db.execute("BEGIN TRANSACTION");
    try {
      var displayOrder = maxValue(targetFolder) + 1;
      for (var item in items) {
        var exists = _db.select(
          """
          select 1 from "$targetFolder"
          where id == ? and type == ?;
        """,
          [item.id, item.type.value],
        );
        if (exists.isNotEmpty) {
          continue;
        }
        _insertLocalFavoriteItem(targetFolder, item, displayOrder);
        displayOrder++;
        added++;
        addedItems.add(item);
      }
    } catch (e) {
      Log.error("Batch Copy Favorites To Folder", e.toString());
      _db.execute("ROLLBACK");
      return 0;
    }
    _db.execute("COMMIT");
    counts[targetFolder] = count(targetFolder);
    refreshHashedIds();
    if (addedItems.isNotEmpty) {
    }
    notifyListeners();
    return added;
  }

  /// Move the given items into [targetFolder] from wherever they currently
  /// live. Used by the "All folders" aggregated view: each item is inserted
  /// into [targetFolder] and then removed from every other folder. This
  /// removes the item from all of its source folders, consolidating it into
  /// the target.
  void batchMoveFavoritesToFolder(
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }
    _db.execute("BEGIN TRANSACTION");
    try {
      var allFolders = _getFolderNamesWithDB();
      var displayOrder = maxValue(targetFolder) + 1;
      for (var item in items) {
        var exists = _db.select(
          """
          select 1 from "$targetFolder"
          where id == ? and type == ?;
        """,
          [item.id, item.type.value],
        );
        if (exists.isEmpty) {
          _insertLocalFavoriteItem(targetFolder, item, displayOrder);
          displayOrder++;
        }
        for (var folder in allFolders) {
          if (folder == targetFolder) continue;
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [item.id, item.type.value],
          );
        }
      }
    } catch (e) {
      Log.error("Batch Move Favorites To Folder", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    for (var folder in _getFolderNamesWithDB()) {
      counts[folder] = count(folder);
    }
    refreshHashedIds();
    notifyListeners();
  }

  /// delete a folder
  void deleteFolder(String name) {
    _db.execute("""
      drop table "$name";
    """);
    _db.execute(
      """
      delete from folder_order
      where folder_name == ?;
    """,
      [name],
    );
    counts.remove(name);
    refreshHashedIds();
    notifyListeners();
  }

  void deleteComicWithId(String folder, String id, ComicType type) {
    LocalFavoriteImageProvider.delete(id, type.value);
    _db.execute(
      """
      delete from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (counts[folder] != null) {
      counts[folder] = counts[folder]! - 1;
    } else {
      counts[folder] = count(folder);
    }
    reduceHashedId(id, type.value);
    notifyListeners();
  }

  void batchDeleteComics(String folder, List<FavoriteItem> comics) {
    _db.execute("BEGIN TRANSACTION");
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        _db.execute(
          """
          delete from "$folder"
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
      }
      if (counts[folder] != null) {
        counts[folder] = counts[folder]! - comics.length;
      } else {
        counts[folder] = count(folder);
      }
    } catch (e) {
      Log.error("Batch Delete Comics", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    for (var comic in comics) {
      reduceHashedId(comic.id, comic.type.value);
    }
    notifyListeners();
  }

  void batchDeleteComicsInAllFolders(List<ComicID> comics) {
    _db.execute("BEGIN TRANSACTION");
    var folderNames = _getFolderNamesWithDB();
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        for (var folder in folderNames) {
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [comic.id, comic.type.value],
          );
        }
      }
    } catch (e) {
      Log.error("Batch Delete Comics in All Folders", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    initCounts();
    _db.execute("COMMIT");
    for (var comic in comics) {
      var hash = comic.id.hashCode ^ comic.type.value;
      _hashedIds.remove(hash);
    }
    notifyListeners();
  }

  Future<int> removeInvalid() async {
    int count = 0;
    await Future.microtask(() {
      var all = allComics();
      for (var c in all) {
        var comicSource = c.type.comicSource;
        if ((c.type == ComicType.local &&
                LocalManager().find(c.id, c.type) == null) ||
            (c.type != ComicType.local && comicSource == null)) {
          deleteComicWithId(c.folder, c.id, c.type);
          count++;
        }
      }
    });
    return count;
  }

  Future<void> clearAll() async {
    DatabaseGateway.instance.closeManaged(_dbPath);
    await deleteSqliteDatabase(_dbPath);
    await init();
  }

  void reorder(List<FavoriteItem> newFolder, String folder) async {
    if (!existsFolder(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    _db.execute("BEGIN TRANSACTION");
    try {
      for (int i = 0; i < newFolder.length; i++) {
        _db.execute(
          """
          update "$folder"
          set display_order = ?
          where id == ? and type == ?;
        """,
          [i, newFolder[i].id, newFolder[i].type.value],
        );
      }
    } catch (e) {
      Log.error("Reorder", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    notifyListeners();
  }

  void rename(String before, String after) {
    if (existsFolder(after)) {
      throw "Name already exists!";
    }
    if (after.contains('"')) {
      throw "Invalid name";
    }
    _db.execute("""
      ALTER TABLE "$before"
      RENAME TO "$after";
    """);
    _db.execute(
      """
      update folder_order
      set folder_name = ?
      where folder_name == ?;
    """,
      [after, before],
    );
    _db.execute(
      """
      update folder_sync
      set folder_name = ?
      where folder_name == ?;
    """,
      [after, before],
    );
    counts[after] = counts[before] ?? 0;
    counts.remove(before);
    notifyListeners();
  }

  void onRead(String id, ComicType type) async {
    final moveMode = appdata.settings['moveFavoriteAfterRead']?.toString() ?? 'none';
    if (moveMode == "none") {
      markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = appdata.settings['followUpdatesFolder'];
    var changed = false;
    for (final folder in folderNames) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        var newTime = DateTime.now()
            .toIso8601String()
            .replaceFirst("T", " ")
            .substring(0, 19);
        String updateLocationSql = "";
        if (moveMode == "end") {
          int maxValue =
              _db.select("""
            SELECT MAX(display_order) AS max_value
            FROM "$folder";
          """).firstOrNull?["max_value"] ??
              0;
          updateLocationSql = "display_order = ${maxValue + 1},";
        } else if (moveMode == "start") {
          int minValue =
              _db.select("""
            SELECT MIN(display_order) AS min_value
            FROM "$folder";
          """).firstOrNull?["min_value"] ??
              0;
          updateLocationSql = "display_order = ${minValue - 1},";
        }
        _db.execute(
          """
            UPDATE "$folder"
            SET 
              $updateLocationSql
              ${followUpdatesFolder == folder ? "has_new_update = 0," : ""}
              time = ?
            WHERE id == ? and type == ?;
          """,
          [newTime, id, type.value],
        );
        if (followUpdatesFolder == folder) {
          updateFollowUpdatesUI();
        }
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) {
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    keyword = "%$keyword%";
    var res = _db.select(
      """
      SELECT * FROM "$folder" 
      WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
    """,
      [keyword, keyword, keyword, keyword],
    );
    var comics = res.map((e) => FavoriteItem.fromRow(e)).toList();
    bool test(FavoriteItem comic, String keyword) {
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics = comics
          .where((element) => test(element, keywordList[i]))
          .toList();
    }
    return comics;
  }

  List<FavoriteItem> search(String keyword) {
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    var comics = <FavoriteItem>{};
    for (var table in folderNames) {
      keyword = "%$keyword%";
      var res = _db.select(
        """
        SELECT * FROM "$table" 
        WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
      """,
        [keyword, keyword, keyword, keyword],
      );
      for (var comic in res) {
        comics.add(FavoriteItem.fromRow(comic));
      }
      if (comics.length > 200) {
        break;
      }
    }

    bool test(FavoriteItem comic, String keyword) {
      keyword = keyword.trim();
      if (keyword.isEmpty) {
        return true;
      }
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    return comics.where((element) {
      for (var i = 1; i < keywordList.length; i++) {
        if (!test(element, keywordList[i])) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  void editTags(String id, String folder, List<String> tags) {
    _db.execute(
      """
        update "$folder"
        set tags = ?
        where id == ?;
      """,
      [tags.join(","), id],
    );
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    var hash = id.hashCode ^ type.value;
    return _hashedIds.containsKey(hash);
  }

  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
    _db.execute(
      """
      update "$folder"
      set name = ?, author = ?, cover_path = ?, tags = ?
      where id == ? and type == ?;
    """,
      [
        comic.name,
        comic.author,
        comic.coverPath,
        comic.tags.join(","),
        comic.id,
        comic.type.value,
      ],
    );
    try {
      const ComicStateRepository().mirrorComic(comic);
    } catch (_) {}
    if (notify) {
      notifyListeners();
    }
  }

  String folderToJson(String folder) {
    var res = _db.select("""
      select * from "$folder";
    """);
    return jsonEncode({
      "info": "Generated by Venera",
      "name": folder,
      "comics": res.map((e) => FavoriteItem.fromRow(e).toJson()).toList(),
    });
  }

  void fromJson(String json) {
    var data = jsonDecode(json);
    var folder = data["name"];
    if (folder == null || folder is! String) {
      throw "Invalid data";
    }
    if (existsFolder(folder)) {
      int i = 0;
      while (existsFolder("$folder($i)")) {
        i++;
      }
      folder = "$folder($i)";
    }
    createFolder(folder);
    for (var comic in data["comics"]) {
      try {
        addComic(folder, FavoriteItem.fromJson(comic));
      } catch (e) {
        Log.error("Import Data", e.toString());
      }
    }
  }

  void prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    _ensureUpdateColumns(_db, table);
    if (clearData) {
      _db.execute("""
        update "$table"
        set has_new_update = 0;
      """);
    }
  }

  static Set<String> _columnsOf(CommonDatabase db, String table) {
    return db
        .select('pragma table_info("$table");')
        .map((e) => e["name"] as String)
        .toSet();
  }

  /// Adds the follow-update columns ("last_update_time", "has_new_update",
  /// "last_check_time") to [table] if missing.
  static void _ensureUpdateColumns(CommonDatabase db, String table) {
    var columns = _columnsOf(db, table);
    if (!columns.contains("last_update_time")) {
      db.execute("""
        alter table "$table"
        add column last_update_time TEXT;
      """);
    }
    if (!columns.contains("has_new_update")) {
      db.execute("""
        alter table "$table"
        add column has_new_update int;
      """);
    }
    if (!columns.contains("last_check_time")) {
      db.execute("""
        alter table "$table"
        add column last_check_time int;
      """);
    }
  }

  static bool _isFavoriteFolderTableOf(CommonDatabase db, String table) {
    if (_nonFavoriteTables.contains(table) || table.startsWith('sqlite_')) {
      return false;
    }
    const requiredColumns = {
      'id',
      'name',
      'author',
      'tags',
      'cover_path',
      'time',
    };
    return _columnsOf(db, table).containsAll(requiredColumns);
  }

  static List<String> _favoriteFolderTablesOf(CommonDatabase db) {
    return db
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((e) => e["name"] as String)
        .where((table) => _isFavoriteFolderTableOf(db, table))
        .toList();
  }

  /// Captures every row carrying follow-update bookkeeping, so it can be
  /// merged back after a backup import replaces the database wholesale.
  static FollowUpdateInfoSnapshot snapshotUpdateInfoOf(CommonDatabase db) {
    var result = <String, List<FollowUpdateInfoRow>>{};
    for (var table in _favoriteFolderTablesOf(db)) {
      var columns = _columnsOf(db, table);
      var hasTime = columns.contains('last_update_time');
      var hasFlag = columns.contains('has_new_update');
      var hasCheck = columns.contains('last_check_time');
      if (!hasTime && !hasFlag && !hasCheck) {
        continue;
      }
      var conditions = [
        if (hasFlag) 'has_new_update == 1',
        if (hasTime) 'last_update_time is not null',
        if (hasCheck) 'last_check_time is not null',
      ];
      var rows = db.select(
        'select * from "$table" where ${conditions.join(' or ')};',
      );
      var snapshot = <FollowUpdateInfoRow>[];
      for (var row in rows) {
        var id = row['id'];
        var type = row['type'];
        if (id is! String || type is! int) {
          continue;
        }
        snapshot.add((
          id: id,
          type: type,
          lastUpdateTime: hasTime ? row['last_update_time'] as String? : null,
          hasNewUpdate: hasFlag && row['has_new_update'] == 1,
          lastCheckTime: hasCheck
              ? (row['last_check_time'] as num?)?.toInt()
              : null,
        ));
      }
      if (snapshot.isNotEmpty) {
        result[table] = snapshot;
      }
    }
    return result;
  }

  /// Re-applies a pre-import [snapshot] onto the just-imported database.
  ///
  /// Backups replace the favorites database wholesale, but follow-update
  /// bookkeeping is written by each device's own update checks and may be
  /// missing or stale in the incoming backup — without this merge, a startup
  /// or catch-up sync download silently erased every unread update mark while
  /// the follow-update task history kept counting them (#106).
  ///
  /// Per (id, type) row that exists on both sides:
  /// - `has_new_update` is sticky-OR'd: an unread mark from either side
  ///   survives; only the read path (markAsRead) may clear it.
  /// - `last_update_time` / `last_check_time` follow the freshest check: they
  ///   are restored from the snapshot only when its check is at least as
  ///   recent as the imported row's. Restoring a stale baseline would make
  ///   the next check re-flag comics the user already read; keeping a newer
  ///   imported one preserves the other device's later observation.
  ///
  /// Rows or folders absent from the imported database are skipped: the
  /// backup deleted them, and the merge must not resurrect anything.
  static void mergeUpdateInfoInto(
    CommonDatabase db,
    FollowUpdateInfoSnapshot snapshot,
  ) {
    if (snapshot.isEmpty) {
      return;
    }
    var tables = _favoriteFolderTablesOf(db).toSet();
    db.execute('begin;');
    try {
      for (var entry in snapshot.entries) {
        var table = entry.key;
        if (!tables.contains(table)) {
          continue;
        }
        _ensureUpdateColumns(db, table);
        var statement = db.prepare("""
          update "$table" set
            has_new_update = (coalesce(has_new_update, 0) | ?),
            last_update_time = case
              when ? >= coalesce(last_check_time, 0) and ? is not null then ?
              else last_update_time end,
            last_check_time = case
              when ? >= coalesce(last_check_time, 0) and ? is not null then ?
              else last_check_time end
          where id == ? and type == ?;
        """);
        try {
          for (var row in entry.value) {
            var checkTime = row.lastCheckTime ?? 0;
            statement.execute([
              row.hasNewUpdate ? 1 : 0,
              checkTime,
              row.lastUpdateTime,
              row.lastUpdateTime,
              checkTime,
              row.lastCheckTime,
              row.lastCheckTime,
              row.id,
              row.type,
            ]);
          }
        } finally {
          statement.dispose();
        }
      }
      db.execute('commit;');
    } catch (_) {
      db.execute('rollback;');
      rethrow;
    }
  }

  /// See [snapshotUpdateInfoOf]. Returns an empty snapshot (never throws) so
  /// a bookkeeping failure can't abort the import that calls it.
  FollowUpdateInfoSnapshot snapshotUpdateInfo() {
    if (!isInitialized) {
      return const {};
    }
    try {
      return snapshotUpdateInfoOf(_db);
    } catch (e, s) {
      Log.error("Follow Updates", "Failed to snapshot update info: $e", s);
      return const {};
    }
  }

  /// See [mergeUpdateInfoInto]. Failures are logged, not thrown — a merge
  /// problem must not fail the whole import.
  void mergeUpdateInfo(FollowUpdateInfoSnapshot snapshot) {
    if (!isInitialized || snapshot.isEmpty) {
      return;
    }
    try {
      mergeUpdateInfoInto(_db, snapshot);
    } catch (e, s) {
      Log.error("Follow Updates", "Failed to merge update info: $e", s);
    }
  }

  void updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
  ) {
    var row = _db
        .select(
          """
      select last_update_time from "$folder"
      where id == ? and type == ?;
    """,
          [id, type.value],
        )
        .firstOrNull;
    if (row == null) {
      // The comic left the folder while its check was in flight.
      return;
    }
    var oldTime = row['last_update_time'];
    var hasNewUpdate = oldTime != updateTime;
    // The flag is sticky: a check may only RAISE has_new_update to 1, never
    // clear it (`has_new_update | ?`). Clearing is the read path's job
    // (markAsRead). This prevents a re-check / interrupted-and-restarted check
    // from silently wiping an already-flagged-but-unread comic's badge when the
    // in-memory snapshot (c.updateTime) has drifted from the DB — see the
    // follow-update cancel race that turned "3 updates" into "2".
    _db.execute(
      """
      update "$folder"
      set last_update_time = ?,
          has_new_update = (coalesce(has_new_update, 0) | ?),
          last_check_time = ?
      where id == ? and type == ?;
    """,
      [
        updateTime,
        hasNewUpdate ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
        id,
        type.value,
      ],
    );
  }

  void updateCheckTime(String folder, String id, ComicType type) {
    _db.execute(
      """
      update "$folder"
      set last_check_time = ?
      where id == ? and type == ?;
    """,
      [DateTime.now().millisecondsSinceEpoch, id, type.value],
    );
  }

  int countUpdates(String folder) {
    if (!isInitialized || !existsFolder(folder)) return 0;
    return _db.select("""
      select count(*) as c from "$folder"
      where has_new_update == 1;
    """).first['c'];
  }

  List<FavoriteItemWithUpdateInfo> getUpdates(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from "$folder"
      where has_new_update == 1;
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  static List<FavoriteItemWithUpdateInfo> _queryComicsWithUpdatesInfo(
    String folder,
    CommonDatabase db,
  ) {
    var res = db.select("""
      select * from "$folder";
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    return _queryComicsWithUpdatesInfo(folder, _db);
  }

  static Future<List<FavoriteItemWithUpdateInfo>> _getComicsWithUpdatesInfoAsync(
    String folder,
    String dbPath,
  ) {
    return DatabaseGateway.instance.isolateOp(
      dbPath,
      (db) async => _queryComicsWithUpdatesInfo(folder, db),
    );
  }

  /// Same as [getComicsWithUpdatesInfo] but runs the query + row mapping in a
  /// background isolate so a large folder doesn't jank the UI thread.
  Future<List<FavoriteItemWithUpdateInfo>> getComicsWithUpdatesInfoAsync(
    String folder,
  ) {
    if (!existsFolder(folder)) {
      return Future.value(const []);
    }
    return _getComicsWithUpdatesInfoAsync(folder, _dbPath);
  }

  FavoriteItemWithUpdateInfo? getComicWithUpdatesInfo(
    String folder,
    String id,
    ComicType type,
  ) {
    if (!existsFolder(folder)) {
      return null;
    }
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    return FavoriteItemWithUpdateInfo(
      FavoriteItem.fromRow(row),
      row['last_update_time'],
      row['has_new_update'] == 1,
      row['last_check_time'],
    );
  }

  void markAsRead(String id, ComicType type) {
    var folder = appdata.settings['followUpdatesFolder'];
    // Reading any comic funnels through here (onRead); the setting is null
    // whenever follow-updates isn't configured, and passing null into
    // existsFolder(String) would throw on every reader open.
    if (folder is! String || !existsFolder(folder)) {
      return;
    }
    _db.execute(
      """
      update "$folder"
      set has_new_update = 0
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    // Refresh the follow-updates count badge on the home screen and the
    // follow-updates page list. Without this, reading a comic (which calls
    // onRead -> markAsRead when moveFavoriteAfterRead is "none") clears
    // has_new_update in the database but leaves the UI showing the stale
    // entry/count until the page is rebuilt. notifyListeners keeps any other
    // LocalFavoritesManager listeners in sync as well.
    updateFollowUpdatesUI();
    notifyListeners();
  }

  void close() {
    if (!isInitialized) return;
    isInitialized = false;
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  void notifyChanges() {
    notifyListeners();
  }
}
