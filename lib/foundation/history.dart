import 'dart:async';
import 'dart:convert';
// Used by part file image_favorites.dart: computeImageFavorites runs manager
// code inside a raw guardedRead + Isolate.run (see the comment there).
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'appdata.dart';
import 'comic_state_repository.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

int _historyInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int? _historyNullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

Set<String> _readEpisodeSet(Object? value) {
  if (value is String) {
    return value.split(',').where((element) => element.isNotEmpty).toSet();
  }
  if (value is Iterable) {
    return value
        .map((element) => element?.toString() ?? '')
        .where((element) => element.isNotEmpty)
        .toSet();
  }
  return <String>{};
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(_historyInt(map["type"])),
      time = DateTime.fromMillisecondsSinceEpoch(_historyInt(map["time"])),
      title = map["title"]?.toString() ?? '',
      subtitle = map["subtitle"]?.toString() ?? '',
      cover = map["cover"]?.toString() ?? '',
      ep = _historyInt(map["ep"]),
      page = _historyInt(map["page"]),
      id = map["id"]?.toString() ?? '',
      readEpisode = _readEpisodeSet(map["readEpisode"]),
      maxPage = _historyNullableInt(map["max_page"]) {
    group = _historyNullableInt(map["chapter_group"]);
  }

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"],
      subtitle = row["subtitle"],
      cover = row["cover"],
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String)
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late CommonDatabase _db;

  late String _dbPath;

  bool _isCorrupted = false;

  void _handleCorruption(SqliteException e) {
    if (!_isCorrupted) {
      _isCorrupted = true;
      Log.addLog(LogLevel.error, 'History DB Corrupted', '$e');
    }
  }

  int get length {
    if (!isInitialized || _isCorrupted) return 0;
    try {
      return _db.select("select count(*) from history;").first[0] as int;
    } on SqliteException catch (e) {
      _handleCorruption(e);
      return 0;
    }
  }

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _clearCache();
    _dbPath = "${App.dataPath}/history.db";
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _ensureSchema();

    isInitialized = true;
    notifyListeners();
    ImageFavoriteManager().init();
  }

  /// Creates the history table when missing and upgrades older layouts.
  /// Idempotent; also run after [restoreFrom], whose page-level copy may bring
  /// in a backup created by an older app version.
  void _ensureSchema() {
    _db.execute("""
        create table if not exists history  (
          id text,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      """);

    var columns = _db.select("PRAGMA table_info(history);");
    if (!_hasCompositePrimaryKey(columns)) {
      _migrateToCompositePrimaryKey();
      columns = _db.select("PRAGMA table_info(history);");
    }
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      _db.execute("alter table history add column chapter_group int;");
    }
  }

  /// Replaces this store's content with the database file at [sourcePath] by
  /// closing the connection, swapping the file, and reopening — see
  /// [restoreDatabaseFiles]. The dispose→replace→reopen sequence runs with no
  /// `await` in between, so no main-isolate read can observe a closed handle;
  /// background-isolate reads are held off by the surrounding exclusive window.
  Future<void> restoreFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError("HistoryManager is not initialized; cannot restore");
    }
    _clearCache();
    DatabaseGateway.instance.closeManaged(_dbPath);
    try {
      restoreDatabaseFiles({_dbPath: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(_dbPath);
    }
    _ensureSchema();
    _isCorrupted = false;
    // image_favorites lives in this same database file: re-ensure its table
    // exists and rerun its cache-key fix against the imported rows.
    ImageFavoriteManager().init();
    updateCache();
    notifyListeners();
  }

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static String _cacheKey(String id, ComicType type) => "${type.value}:$id";

  bool _hasCompositePrimaryKey(ResultSet columns) {
    var idColumn = columns.firstWhereOrNull((e) => e["name"] == "id");
    var typeColumn = columns.firstWhereOrNull((e) => e["name"] == "type");
    return idColumn?["pk"] == 1 && typeColumn?["pk"] == 2;
  }

  void _migrateToCompositePrimaryKey() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final hasChapterGroup = _db
          .select("PRAGMA table_info(history);")
          .any((element) => element["name"] == "chapter_group");
      _db.execute("""
        create table if not exists history_new (
          id text,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      """);
      if (hasChapterGroup) {
        _db.execute("""
          insert or replace into history_new (
            id, title, subtitle, cover, time, type, ep, page,
            readEpisode, max_page, chapter_group
          )
          select
            id, title, subtitle, cover, time, type, ep, page,
            readEpisode, max_page, chapter_group
          from history;
        """);
      } else {
        _db.execute("""
          insert or replace into history_new (
            id, title, subtitle, cover, time, type, ep, page,
            readEpisode, max_page
          )
          select
            id, title, subtitle, cover, time, type, ep, page,
            readEpisode, max_page
          from history;
        """);
      }
      _db.execute("drop table history;");
      _db.execute("alter table history_new rename to history;");
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return DatabaseGateway.instance.isolateOp(dbPath, (db) async {
      db.execute(_insertHistorySql, _historySqlArgs(newItem));
    });
  }

  static List<Object?> _historySqlArgs(History newItem) {
    return [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ];
  }

  void _writeLocalHistory(History newItem) {
    _db.execute(_insertHistorySql, _historySqlArgs(newItem));
  }

  void _mirrorToDomain(History newItem) {
    try {
      const ComicStateRepository().mirrorComic(newItem);
    } catch (_) {
      // Domain DB may not be ready; mirror is best-effort
    }
  }

  void _cacheAddedHistory(History newItem) {
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKey(newItem.id, newItem.type)] = true;
    }
    cachedHistories[_cacheKey(newItem.id, newItem.type)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
  }

  void _clearCache() {
    _cachedHistoryIds = null;
    cachedHistories.clear();
  }

  bool _haveAsyncTask = false;

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) async {
    if (!isInitialized) return;
    while (_haveAsyncTask) {
      await Future.delayed(Duration(milliseconds: 20));
    }

    _haveAsyncTask = true;
    await _addHistoryAsync(_dbPath, newItem);
    _mirrorToDomain(newItem);
    _haveAsyncTask = false;
    _cacheAddedHistory(newItem);
    notifyListeners();
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    if (!isInitialized) return;
    _writeLocalHistory(newItem);
    _mirrorToDomain(newItem);
    _cacheAddedHistory(newItem);
    notifyListeners();
  }

  /// Update the set of read episodes for a comic and persist it.
  ///
  /// Used by the manual "mark as read/unread" feature on the chapters list.
  /// If no history exists yet (the user has never opened the comic), a new
  /// history record is created from [model] so the marks can still be stored.
  ///
  /// Returns the updated [History] so callers can refresh their local state.
  History updateReadEpisodes(
    HistoryMixin model,
    Set<String> readEpisode,
  ) {
    var type = model.historyType;
    var existing = find(model.id, type);
    History newItem;
    if (existing != null) {
      existing.readEpisode = readEpisode;
      // Keep the existing reading position/time untouched; only the read
      // marks change. Refresh time so the comic surfaces in recent history.
      existing.time = DateTime.now();
      newItem = existing;
    } else {
      newItem = History.fromModel(
        model: model,
        ep: 0,
        page: 0,
        readChapters: readEpisode,
      );
    }
    if (!isInitialized) return newItem;
    _writeLocalHistory(newItem);
    _mirrorToDomain(newItem);
    _cacheAddedHistory(newItem);
    notifyListeners();
    return newItem;
  }

  void clearHistory() {
    if (!isInitialized) return;
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void _clearLocalUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void clearUnfavoritedHistory() {
    if (!isInitialized) return;
    _clearLocalUnfavoritedHistory();
    updateCache();
    notifyListeners();
  }

  /// Delete history records older than [maxAge], counted from each record's
  /// last-read time. Returns the number of rows removed. A no-op (returns 0)
  /// when not initialized or corrupted.
  int cleanHistoryOlderThan(Duration maxAge) {
    if (!isInitialized || _isCorrupted) return 0;
    var cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    try {
      _db.execute("delete from history where time < ?;", [cutoff]);
      var removed = _db.updatedRows;
      if (removed > 0) {
        updateCache();
        notifyListeners();
      }
      return removed;
    } on SqliteException catch (e) {
      _handleCorruption(e);
      return 0;
    }
  }

  void remove(String id, ComicType type) async {
    if (!isInitialized) return;
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    if (!isInitialized || _isCorrupted) return;
    try {
      _cachedHistoryIds = {};
      var res = _db.select("""
        select id, type from history;
      """);
      for (var element in res) {
        _cachedHistoryIds![_cacheKey(
              element["id"] as String,
              ComicType(element["type"] as int),
            )] =
            true;
      }
      for (var key in cachedHistories.keys.toList()) {
        if (!_cachedHistoryIds!.containsKey(key)) {
          cachedHistories.remove(key);
        }
      }
    } on SqliteException catch (e) {
      _cachedHistoryIds = {};
      _handleCorruption(e);
    }
  }

  History? find(String id, ComicType type) {
    if (!isInitialized || _isCorrupted) return null;
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    var key = _cacheKey(id, type);
    if (!_cachedHistoryIds!.containsKey(key)) {
      return null;
    }
    if (cachedHistories.containsKey(key)) {
      return cachedHistories[key];
    }

    try {
      var res = _db.select(
        """
      select * from history
      where id == ? and type == ?;
    """,
        [id, type.value],
      );
      if (res.isEmpty) {
        return null;
      }
      return History.fromRow(res.first);
    } on SqliteException catch (e) {
      _handleCorruption(e);
      return null;
    }
  }

  static List<History> _queryAllHistory(CommonDatabase db) {
    var res = db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  List<History> getAll() {
    if (!isInitialized || _isCorrupted) return [];
    try {
      return _queryAllHistory(_db);
    } on SqliteException catch (e) {
      _handleCorruption(e);
      return [];
    }
  }

  static Future<List<History>> _getAllHistoryAsync(String dbPath) {
    // Runs in a separate isolate. Only [dbPath] (a String) is captured, never
    // `this` — the manager holds a live DB handle that can't cross isolates.
    return DatabaseGateway.instance.isolateOp(
      dbPath,
      (db) async => _queryAllHistory(db),
    );
  }

  /// Load all history in a background isolate, keeping the UI thread free when
  /// the table is large. Falls back to an empty list if not ready.
  Future<List<History>> getAllAsync() {
    if (!isInitialized || _isCorrupted) return Future.value(const []);
    return _getAllHistoryAsync(_dbPath);
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    if (!isInitialized) return [];
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    if (!isInitialized) return 0;
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  void close() {
    _clearCache();
    if (!isInitialized) return;
    isInitialized = false;
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return (await _refreshSingleHistory(history)).success;
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<_HistoryRefreshResult> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return const _HistoryRefreshResult(false, 'Source unavailable');
    }

    int retries = 3;
    String? lastError;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          lastError = res.errorMessage ?? 'Load failed';
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return _HistoryRefreshResult(false, lastError);
          }
          continue;
        }

        var comicDetails = res.data;
        // Mirror full details to domain DB
        try {
          const ComicStateRepository().mirrorComicDetails(comicDetails);
        } catch (_) {}
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return const _HistoryRefreshResult(true);
      } catch (e, s) {
        lastError = e.toString();
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return _HistoryRefreshResult(false, lastError);
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream({
    bool Function()? shouldCancel,
  }) {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller, shouldCancel);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
    bool Function()? shouldCancel,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        if (shouldCancel?.call() ?? false) {
          break;
        }
        await channel.push(history);
        c++;
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          if (shouldCancel?.call() ?? false) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result.success) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(
              total,
              current,
              success,
              failed,
              skipped,
              history,
              result.errorMessage,
            ),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;
  final History? history;
  final String? errorMessage;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped, [
    this.history,
    this.errorMessage,
  ]);
}

class _HistoryRefreshResult {
  const _HistoryRefreshResult(this.success, [this.errorMessage]);

  final bool success;
  final String? errorMessage;
}
