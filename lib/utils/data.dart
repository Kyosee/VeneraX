import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

/// Coarse phases of a data import, reported to the UI for progress display.
/// `zip_flutter` has no per-entry extraction API, so the extracting phase can
/// only report bytes-written-so-far (indeterminate), not a precise percentage.
enum ImportPhase { preparing, extracting, applying, reloading }

/// Progress callback for [importAppData] / [importPicaData].
/// [message] is an untranslated English key (the UI localizes it); [extractedBytes]
/// is only set during [ImportPhase.extracting].
typedef ImportProgressCallback =
    void Function(ImportPhase phase, String? message, int? extractedBytes);

/// Thrown when an import is canceled before the (uninterruptible) apply phase.
class ImportCanceledException implements Exception {
  const ImportCanceledException();
  @override
  String toString() => 'ImportCanceledException';
}

/// An import failure carrying a translation key for a user-facing message.
class ImportException implements Exception {
  final String messageKey;
  const ImportException(this.messageKey);
  @override
  String toString() => messageKey;
}

/// Maps a low-level extraction/IO error to a user-facing translation key, or
/// null when it doesn't match a known category. Kept pure for unit testing.
String? importErrorMessageKey(Object error) {
  final s = error.toString().toLowerCase();
  if (s.contains('no space') ||
      s.contains('enospc') ||
      s.contains('errno = 28') ||
      s.contains('errno=28') ||
      s.contains('os error 28')) {
    return 'Not enough storage space';
  }
  if (s.contains('zip') ||
      s.contains('unzip') ||
      s.contains('corrupt') ||
      s.contains('not a valid') ||
      s.contains('central directory') ||
      s.contains('bad archive') ||
      s.contains('failed to open') ||
      s.contains('invalid archive')) {
    return 'Backup file is corrupted or unsupported';
  }
  return null;
}

/// Isolate entry point: extracts a zip to a directory and reports the outcome
/// back over [SendPort] (null on success, the error string on failure).
void _extractIsolateEntry(List<dynamic> args) {
  final SendPort sendPort = args[0] as SendPort;
  final String src = args[1] as String;
  final String dest = args[2] as String;
  try {
    ZipFile.openAndExtract(src, dest);
    sendPort.send(null);
  } catch (e) {
    sendPort.send(e.toString());
  }
}

int _directorySizeSync(String path) {
  var total = 0;
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

/// Extracts [src] into [dest] on a background isolate, polling the output
/// directory size to report progress via [onBytes] and supporting cooperative
/// cancellation via [shouldCancel] (kills the isolate). Throws
/// [ImportCanceledException] on cancel and [ImportException] for classified
/// extraction failures.
Future<void> _extractArchiveWithProgress(
  String src,
  String dest, {
  required void Function(int bytes) onBytes,
  required bool Function() shouldCancel,
}) async {
  final resultPort = ReceivePort();
  final isolate = await Isolate.spawn(
    _extractIsolateEntry,
    [resultPort.sendPort, src, dest],
  );
  final completer = Completer<Object?>();
  late final StreamSubscription sub;
  sub = resultPort.listen((message) {
    if (!completer.isCompleted) completer.complete(message);
  });
  var canceled = false;
  final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (shouldCancel()) {
      canceled = true;
      isolate.kill(priority: Isolate.immediate);
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    onBytes(_directorySizeSync(dest));
  });
  Object? result;
  try {
    result = await completer.future;
  } finally {
    timer.cancel();
    sub.cancel();
    resultPort.close();
  }
  if (canceled) {
    throw const ImportCanceledException();
  }
  if (result is String) {
    final key = importErrorMessageKey(result);
    if (key != null) throw ImportException(key);
    throw Exception(result);
  }
  onBytes(_directorySizeSync(dest));
}

int _legacyComicTypeValue(int legacyType) {
  return SourcePlatformResolver.sourceKeyFromLegacyInt(legacyType)?.hashCode ??
      legacyType;
}

Map<int, String> _loadLegacySourceTypeMap(
  Directory cacheDir,
  String? sourceTypeMapName,
) {
  if (sourceTypeMapName == null) {
    return const {};
  }
  var mapFile = cacheDir.joinFile(sourceTypeMapName);
  if (!mapFile.existsSync()) {
    return const {};
  }
  try {
    var data = jsonDecode(mapFile.readAsStringSync());
    var types = data is Map ? data['types'] : null;
    if (types is! Map) {
      return const {};
    }
    var result = <int, String>{};
    for (var entry in types.entries) {
      var typeValue = int.tryParse(entry.key.toString());
      var sourceKey = entry.value?.toString();
      if (typeValue != null && sourceKey != null) {
        result[typeValue] = sourceKey;
      }
    }
    SourcePlatformResolver.registerLegacyIntSourceKeys(result);
    return result;
  } catch (e, s) {
    Log.warning('Import Data', 'Failed to read legacy source type map: $e\n$s');
    return const {};
  }
}

void _rewriteLegacyTypeColumn(
  Database db,
  String table,
  String typeColumn,
  Map<int, String> typeMap,
) {
  if (typeMap.isEmpty) {
    return;
  }
  var columns = db.select('PRAGMA table_info("$table");');
  if (!columns.any((element) => element['name'] == typeColumn)) {
    return;
  }
  for (var entry in typeMap.entries) {
    if (entry.key == 0 ||
        entry.value == SourcePlatformResolver.localCanonicalKey) {
      continue;
    }
    db.execute(
      'UPDATE "$table" SET "$typeColumn" = ? WHERE "$typeColumn" = ?;',
      [entry.value.hashCode, entry.key],
    );
  }
}

void _rewriteLegacySourceTypes(Directory cacheDir, Map<int, String> typeMap) {
  if (typeMap.isEmpty) {
    return;
  }

  var historyFile = cacheDir.joinFile("history.db");
  if (historyFile.existsSync()) {
    var db = sqlite3.open(historyFile.path);
    try {
      _rewriteLegacyTypeColumn(db, 'history', 'type', typeMap);
    } finally {
      db.dispose();
    }
  }

  var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
  if (localFavoriteFile.existsSync()) {
    var db = sqlite3.open(localFavoriteFile.path);
    try {
      var tables = db
          .select("SELECT name FROM sqlite_master WHERE type='table';")
          .map((e) => e["name"] as String)
          .where((e) => e != "folder_order" && e != "folder_sync")
          .toList();
      for (var table in tables) {
        _rewriteLegacyTypeColumn(db, table, 'type', typeMap);
      }
    } finally {
      db.dispose();
    }
  }

  var localFile = cacheDir.joinFile("local.db");
  if (localFile.existsSync()) {
    var db = sqlite3.open(localFile.path);
    try {
      _rewriteLegacyTypeColumn(db, 'comics', 'comic_type', typeMap);
    } finally {
      db.dispose();
    }
  }

  var readLaterFile = cacheDir.joinFile("read_later.db");
  if (readLaterFile.existsSync()) {
    var db = sqlite3.open(readLaterFile.path);
    try {
      _rewriteLegacyTypeColumn(db, 'read_later', 'type', typeMap);
    } finally {
      db.dispose();
    }
  }
}

Future<File> exportAppData([bool sync = true]) async {
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  try {
    if (App.domain.isInitialized) {
      App.domain.db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    }
  } catch (e, s) {
    Log.warning('Export Data', 'Failed to checkpoint domain database: $e\n$s');
  }
  for (final dbName in [
    'history.db',
    'local_favorite.db',
    'local.db',
    'read_later.db',
    // Without a checkpoint, logins living in cookie.db's WAL sidecar were
    // silently missing from every backup.
    'cookie.db',
  ]) {
    try {
      final db = sqlite3.open(FilePath.join(App.dataPath, dbName));
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      db.dispose();
    } catch (e, s) {
      Log.warning('Export Data', 'Failed to checkpoint $dbName: $e\n$s');
    }
  }
  // Serialize the learned legacy-int -> source-key registry so orphan data
  // (sources that may not be installed on the importing device) can still be
  // resolved after migration. Built in the main isolate; the zip write below
  // runs in a separate isolate without access to appdata.
  Uint8List? sourceTypeMapBytes;
  final sourceTypeRegistry =
      appdata.implicitData[Appdata.sourceTypeRegistryKey];
  if (sourceTypeRegistry is Map && sourceTypeRegistry.isNotEmpty) {
    sourceTypeMapBytes = utf8.encode(
      jsonEncode({'types': sourceTypeRegistry}),
    );
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var domainFile = DomainDatabase.databasePathFor(dataPath);
    var appdata = FilePath.join(
      dataPath,
      sync ? "syncdata.json" : "appdata.json",
    );
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("local_favorite.db", localFavoriteFile);
    if (sourceTypeMapBytes != null) {
      zipFile.addFileFromBytes("source_type_map.json", sourceTypeMapBytes);
    }
    if (File(domainFile).existsSync()) {
      zipFile.addFile("data/venera.db", domainFile);
    }
    var readLaterFile = FilePath.join(dataPath, "read_later.db");
    if (File(readLaterFile).existsSync()) {
      zipFile.addFile("read_later.db", readLaterFile);
    }
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
    var localDbFile = FilePath.join(dataPath, "local.db");
    if (File(localDbFile).existsSync()) {
      zipFile.addFile("local.db", localDbFile);
    }
    for (var file in Directory(
      FilePath.join(dataPath, "comic_source"),
    ).listSync()) {
      if (file is File) {
        zipFile.addFile("comic_source/${file.name}", file.path);
      }
    }
    zipFile.close();
  });
  return cacheFile;
}

/// Whether every SQLite-backed store the import path restores into is alive.
/// The deferred-init completer only says init *finished attempting* — after a
/// mid-init failure it still completes (so gates don't hang), which used to
/// let a startup download apply a backup over uninitialized stores (LateError
/// storms, half-applied data). Ground truth about the stores lives here.
bool get coreDataStoresReady =>
    HistoryManager().isInitialized &&
    LocalFavoritesManager().isInitialized &&
    App.readLater.isInitialized &&
    LocalManager().isInitialized &&
    App.domain.isInitialized &&
    SingleInstanceCookieJar.instance != null;

/// Returns true if [config] is a complete native WebDAV configuration:
/// a 3-element list of non-empty strings ([url, user, password]).
bool _isWebdavConfigComplete(dynamic config) {
  if (config is! List || config.length != 3) {
    return false;
  }
  if (config.whereType<String>().length != 3) {
    return false;
  }
  return config.cast<String>().every((e) => e.trim().isNotEmpty);
}

/// Restores the WebDAV configuration from an imported backup, but only when the
/// current device has no usable configuration.
///
/// WebDAV credentials are device-specific and therefore excluded from
/// [Appdata.syncData], so a normal import never touches them. We make a
/// deliberate exception here: if this device is unconfigured — or only
/// partially configured (any of url/user/password blank) — and the backup
/// carries a complete configuration, adopt it. A device that already has a
/// complete configuration keeps its own.
Future<void> _restoreWebdavConfigIfAbsent(Map<String, dynamic> data) async {
  if (_isWebdavConfigComplete(appdata.settings['webdav'])) {
    return;
  }
  var settings = data['settings'];
  if (settings is! Map) {
    return;
  }
  var incoming = settings['webdav'];
  if (!_isWebdavConfigComplete(incoming)) {
    return;
  }
  // Preserve values verbatim (e.g. don't trim the password).
  appdata.settings['webdav'] = (incoming as List).cast<String>().toList();
  await appdata.saveData(false);
}

/// Serializes concurrent [importAppData] runs. A WebDAV download-apply and a
/// manual file import could previously run at once: both used the SAME fixed
/// `temp_data` staging dir and each deleted it wholesale on entry, yanking
/// extracted files out from under the other mid-apply.
Future<void>? _importInProgress;

Future<void> importAppData(
  File file, {
  bool checkVersion = false,
  ImportProgressCallback? onProgress,
  bool Function()? shouldCancel,
}) async {
  while (_importInProgress != null) {
    // Wait for the other import to fully finish (ignore its outcome).
    await _importInProgress!.catchError((_) {});
  }
  final completer = Completer<void>();
  _importInProgress = completer.future;
  try {
    await _importAppDataLocked(
      file,
      checkVersion: checkVersion,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  } finally {
    _importInProgress = null;
    completer.complete();
  }
}

Future<void> _importAppDataLocked(
  File file, {
  bool checkVersion = false,
  ImportProgressCallback? onProgress,
  bool Function()? shouldCancel,
}) async {
  void report(ImportPhase phase, [String? message, int? bytes]) {
    onProgress?.call(phase, message, bytes);
  }

  report(ImportPhase.preparing);
  // Unique staging dir per run — a leftover from a crashed run can't collide,
  // and (defense in depth) neither can a concurrent caller.
  var cacheDirPath = FilePath.join(
    App.cachePath,
    'temp_data_${DateTime.now().microsecondsSinceEpoch}',
  );
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    report(ImportPhase.extracting, null, 0);
    await _extractArchiveWithProgress(
      file.path,
      cacheDirPath,
      onBytes: (b) => report(ImportPhase.extracting, null, b),
      shouldCancel: () => shouldCancel?.call() ?? false,
    );
    var legacySourceTypeMap = _loadLegacySourceTypeMap(
      cacheDir,
      "source_type_map.json",
    );
    _rewriteLegacySourceTypes(cacheDir, legacySourceTypeMap);
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var domainFile = File(FilePath.join(cacheDirPath, "data", "venera.db"));
    var appdataFile = cacheDir.joinFile("appdata.json");
    var implicitDataFile = cacheDir.joinFile("implicitData.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    if (checkVersion && appdataFile.existsSync()) {
      var data = jsonDecode(await appdataFile.readAsString());
      var version = data["settings"]["dataVersion"];
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return;
      }
    }
    // Hold every background-isolate DB reader off while the store restores run:
    // each restoreFrom rebuilds its file's -wal/-shm, and a reader mapping the
    // old sidecars faults natively (the iOS sync-relaunch crash). beginRestore
    // also drains reads already dispatched to an isolate before returning.
    await DatabaseRestoreGuard.instance.beginRestore();
    try {
    if (await historyFile.exists()) {
      report(ImportPhase.applying, 'Importing history');
      await HistoryManager().restoreFrom(historyFile.path);
    }
    if (await localFavoriteFile.exists()) {
      report(ImportPhase.applying, 'Importing favorites');
      // The restore replaces the favorites DB wholesale, but follow-update
      // bookkeeping (has_new_update / last_update_time / last_check_time) is
      // written by THIS device's update checks and may be missing or stale in
      // the incoming backup — a startup or catch-up sync download used to
      // silently erase every unread update mark while the follow-update task
      // history kept counting them (#106). Snapshot it and merge it back in.
      var updateInfo = LocalFavoritesManager().snapshotUpdateInfo();
      await LocalFavoritesManager().restoreFrom(localFavoriteFile.path);
      LocalFavoritesManager().mergeUpdateInfo(updateInfo);
    }
    if (await domainFile.exists()) {
      report(ImportPhase.applying, 'Importing library');
      await App.domain.restoreFrom(domainFile.path);
    }
    if (await appdataFile.exists()) {
      report(ImportPhase.applying, 'Importing settings');
      var content = await appdataFile.readAsString();
      var data = jsonDecode(content);
      appdata.syncData(data);
      if (data is Map<String, dynamic>) {
        await _restoreWebdavConfigIfAbsent(data);
      }
    }
    if (await implicitDataFile.exists()) {
      try {
        var implicitData = jsonDecode(await implicitDataFile.readAsString());
        if (implicitData is Map) {
          // Device-local state must survive a restore: the backup's copy of
          // these keys describes ANOTHER device. Wholesale replacement used to
          // silently flip this device's auto-sync toggle, forget its completed
          // initial sync (blocking all uploads), and clobber its sync/task
          // history. The follow-update task records are this device's own run
          // history/breakpoints too — importing a foreign copy showed another
          // device's task counts and could resume its interrupted check here.
          const deviceLocalKeys = [
            'webdavAutoSync',
            'hasCompletedInitialSync',
            'sync_logs',
            'data_sync_tasks',
            'follow_update_active_tasks',
            'follow_update_task_history',
          ];
          final merged = Map<String, dynamic>.from(implicitData);
          for (final key in deviceLocalKeys) {
            if (appdata.implicitData.containsKey(key)) {
              merged[key] = appdata.implicitData[key];
            } else {
              merged.remove(key);
            }
          }
          appdata.implicitData
            ..clear()
            ..addAll(merged);
          appdata.writeImplicitData();
        }
      } catch (e, s) {
        Log.warning('Import Data', 'Failed to import implicit data: $e\n$s');
      }
    }
    if (await cookieFile.exists()) {
      report(ImportPhase.applying, 'Importing settings');
      var jar =
          SingleInstanceCookieJar.instance ??
          await SingleInstanceCookieJar.createInstance();
      await jar.restoreFrom(cookieFile.path);
    }
    var readLaterFile = cacheDir.joinFile("read_later.db");
    if (await readLaterFile.exists()) {
      report(ImportPhase.applying, 'Importing read later');
      await App.readLater.restoreFrom(readLaterFile.path);
    }
    var localDbFile = cacheDir.joinFile("local.db");
    if (await localDbFile.exists()) {
      report(ImportPhase.applying, 'Importing local library');
      await LocalManager().restoreFrom(localDbFile.path);
    }
    } finally {
      DatabaseRestoreGuard.instance.endRestore();
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    if (Directory(comicSourceDir).existsSync()) {
      report(ImportPhase.reloading);
      // Stage-then-swap. The old delete-then-copy order meant a copy failure
      // midway (disk full, locked file) permanently wiped EVERY installed
      // source together with its login/config .data. Copy into a sibling
      // staging dir first; only after all copies succeed, swap it in.
      final liveDir = Directory(FilePath.join(App.dataPath, "comic_source"));
      final stagingDir = Directory(
        FilePath.join(App.dataPath, "comic_source.staging"),
      );
      stagingDir.deleteIfExistsSync(recursive: true);
      stagingDir.createSync();
      for (var file in Directory(comicSourceDir).listSync()) {
        if (file is File) {
          if (file.name.endsWith(".js") || file.name.endsWith(".data")) {
            await file.copy(FilePath.join(stagingDir.path, file.name));
          }
        }
      }
      liveDir.deleteIfExistsSync(recursive: true);
      stagingDir.renameSync(liveDir.path);
      await ComicSourceManager().reload();
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> importPicaData(
  File file, {
  ImportProgressCallback? onProgress,
  bool Function()? shouldCancel,
}) async {
  void report(ImportPhase phase, [String? message, int? bytes]) {
    onProgress?.call(phase, message, bytes);
  }

  report(ImportPhase.preparing);
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    report(ImportPhase.extracting, null, 0);
    await _extractArchiveWithProgress(
      file.path,
      cacheDirPath,
      onBytes: (b) => report(ImportPhase.extracting, null, b),
      shouldCancel: () => shouldCancel?.call() ?? false,
    );
    report(ImportPhase.applying, 'Importing favorites');
    _loadLegacySourceTypeMap(cacheDir, "source_type_map.json");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"] as String)
            .toList();
        folderNames.removeWhere(
          (e) => e == "folder_order" || e == "folder_sync",
        );
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          var folderName = folderSyncValue["folder_name"];
          String sourceKey = folderSyncValue["key"];
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(
              folderName,
              sourceKey,
              jsonDecode(folderSyncValue["sync_data"])["folderId"],
            );
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (var folderName in folderNames) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var comic in db.select("SELECT * FROM \"$folderName\";")) {
            LocalFavoritesManager().addComic(
              folderName,
              FavoriteItem(
                id: comic['target'],
                name: comic['name'],
                coverPath: comic['cover_path'],
                author: comic['author'],
                type: ComicType(_legacyComicTypeValue(comic['type'])),
                tags: comic['tags'].split(','),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.dispose();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": _legacyComicTypeValue(comic['type']),
              "id": comic['target'],
              "max_page": comic["max_page"],
              "ep": comic["ep"],
              "page": comic["page"],
              "time": comic["time"],
              "title": comic["title"],
              "subtitle": comic["subtitle"],
              "cover": comic["cover"],
              "readEpisode": [comic["ep"]],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = comic["id"].split("-")[0];
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = comic["id"].split("-")[1];
          int page = comic["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = comic["ep"] == 0 ? 1 : comic["ep"];
          String title = comic["title"];
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.dispose();
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
