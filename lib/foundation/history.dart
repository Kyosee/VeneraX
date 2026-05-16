import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

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
import 'package:venera/utils/server_db.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
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

  int get length => isInitialized
      ? _db.select("select count(*) from history;").first[0] as int
      : 0;

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
    _db = openSqliteDatabase(_dbPath);

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

    isInitialized = true;
    notifyListeners();
    ImageFavoriteManager().init();
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
    return Isolate.run(() {
      return withDatabase(dbPath, (db) async {
        db.execute(_insertHistorySql, _historySqlArgs(newItem));
      });
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

  Future<bool> _upsertServerHistory(History newItem) async {
    if (!kIsWeb) return false;
    try {
      return await const ServerDbClient().upsertHistory(newItem);
    } catch (e, s) {
      Log.error('Server DB History', e, s);
      return false;
    }
  }

  Future<bool> _deleteServerHistory(String id, ComicType type) async {
    if (!kIsWeb) return false;
    try {
      return await const ServerDbClient().deleteHistory(id, type);
    } catch (e, s) {
      Log.error('Server DB History', e, s);
      return false;
    }
  }

  Future<bool> _clearServerHistory() async {
    if (!kIsWeb) return false;
    try {
      return await const ServerDbClient().clearHistory();
    } catch (e, s) {
      Log.error('Server DB History', e, s);
      return false;
    }
  }

  Future<bool> _clearServerUnfavoritedHistory() async {
    if (!kIsWeb) return false;
    try {
      return await const ServerDbClient().clearUnfavoritedHistory();
    } catch (e, s) {
      Log.error('Server DB History', e, s);
      return false;
    }
  }

  final _pendingServerHistoryWrites = <Future<void>>{};

  void _trackServerHistoryWrite(Future<void> pending) {
    _pendingServerHistoryWrites.add(pending);
    unawaited(
      pending.whenComplete(() {
        _pendingServerHistoryWrites.remove(pending);
      }),
    );
  }

  Future<void> waitServerHistorySync() async {
    if (!kIsWeb || _pendingServerHistoryWrites.isEmpty) return;
    await Future.wait(_pendingServerHistoryWrites.toList());
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
    if (kIsWeb) {
      _writeLocalHistory(newItem);
      _mirrorToDomain(newItem);
      final pendingServerWrite = _upsertServerHistory(
        newItem,
      ).then<void>((_) {});
      _trackServerHistoryWrite(pendingServerWrite);
    } else {
      await _addHistoryAsync(_dbPath, newItem);
      _mirrorToDomain(newItem);
    }
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
    if (kIsWeb) {
      final pending = _upsertServerHistory(newItem).then<void>((_) {});
      _trackServerHistoryWrite(pending);
    }
  }

  void clearHistory() {
    if (!isInitialized) return;
    if (kIsWeb) {
      final pending = () async {
        await _clearServerHistory();
        _db.execute("delete from history;");
        updateCache();
        notifyListeners();
      }();
      _trackServerHistoryWrite(pending);
      return;
    }
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
    if (kIsWeb) {
      final pending = () async {
        await _clearServerUnfavoritedHistory();
        _clearLocalUnfavoritedHistory();
        updateCache();
        notifyListeners();
      }();
      _trackServerHistoryWrite(pending);
      return;
    }
    _clearLocalUnfavoritedHistory();
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    if (!isInitialized) return;
    if (kIsWeb) {
      await _deleteServerHistory(id, type);
    }
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
    if (!isInitialized) return;
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
  }

  History? find(String id, ComicType type) {
    if (!isInitialized) return null;
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
  }

  List<History> getAll() {
    if (!isInitialized) return [];
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
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
    _db.dispose();
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
