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
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

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
    if (File(domainFile).existsSync()) {
      zipFile.addFile("data/venera.db", domainFile);
    }
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
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

Future<void> importAppData(File file, [bool checkVersion = false]) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
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
    if (await historyFile.exists()) {
      HistoryManager().close();
      File(FilePath.join(App.dataPath, "history.db")).deleteIfExistsSync();
      historyFile.renameSync(FilePath.join(App.dataPath, "history.db"));
      HistoryManager().init();
    }
    if (await localFavoriteFile.exists()) {
      LocalFavoritesManager().close();
      File(
        FilePath.join(App.dataPath, "local_favorite.db"),
      ).deleteIfExistsSync();
      localFavoriteFile.renameSync(
        FilePath.join(App.dataPath, "local_favorite.db"),
      );
      LocalFavoritesManager().init();
    }
    if (await domainFile.exists()) {
      App.domain.close();
      final domainDir = Directory(
        FilePath.join(App.dataPath, DomainDatabase.dataDirectoryName),
      );
      domainDir.createSync(recursive: true);
      final target = DomainDatabase.databasePathFor(App.dataPath);
      File(target).deleteIfExistsSync();
      File('$target-wal').deleteIfExistsSync();
      File('$target-shm').deleteIfExistsSync();
      domainFile.renameSync(target);
      await App.domain.init(App.dataPath);
    }
    if (await appdataFile.exists()) {
      var content = await appdataFile.readAsString();
      var data = jsonDecode(content);
      appdata.syncData(data);
    }
    if (await implicitDataFile.exists()) {
      try {
        var implicitData = jsonDecode(await implicitDataFile.readAsString());
        if (implicitData is Map) {
          await implicitDataFile.copy(
            FilePath.join(App.dataPath, "implicitData.json"),
          );
          appdata.implicitData
            ..clear()
            ..addAll(Map<String, dynamic>.from(implicitData));
        }
      } catch (e, s) {
        Log.warning('Import Data', 'Failed to import implicit data: $e\n$s');
      }
    }
    if (await cookieFile.exists()) {
      SingleInstanceCookieJar.instance?.dispose();
      File(FilePath.join(App.dataPath, "cookie.db")).deleteIfExistsSync();
      cookieFile.renameSync(FilePath.join(App.dataPath, "cookie.db"));
      SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
        FilePath.join(App.dataPath, "cookie.db"),
      )..init();
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    if (Directory(comicSourceDir).existsSync()) {
      Directory(
        FilePath.join(App.dataPath, "comic_source"),
      ).deleteIfExistsSync(recursive: true);
      Directory(FilePath.join(App.dataPath, "comic_source")).createSync();
      for (var file in Directory(comicSourceDir).listSync()) {
        if (file is File) {
          if (file.name.endsWith(".js") || file.name.endsWith(".data")) {
            var targetFile = FilePath.join(
              App.dataPath,
              "comic_source",
              file.name,
            );
            await file.copy(targetFile);
          }
        }
      }
      await ComicSourceManager().reload();
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
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
          sourceKey = sourceKey.toLowerCase() == "htmanga"
              ? "wnacg"
              : sourceKey;
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
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
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
