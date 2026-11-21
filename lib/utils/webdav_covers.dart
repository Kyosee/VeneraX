import 'dart:convert';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_cover_store.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/webdav_upload.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:zip_flutter/zip_flutter.dart';

/// A snapshot names its immutable cover manifest after the platform tag.
/// Skipping devices pass this reference on without reading any cover data.
class WebdavCovers {
  WebdavCovers(this.client);
  final Client client;

  static const _directory = '/venera-covers';
  static const _empty = 'c0';
  static const _unset = 'c1';
  static final _tokenPattern = RegExp(r'\.(c[01]|c[0-9a-f]{32}|b[A-Za-z0-9_]+)\.venera$');
  static final _legacyName = RegExp(r'^[0-9]+-[0-9]+(?:\.[a-zA-Z0-9_]+)?\.venera$');
  static const emptyChoices = <String, dynamic>{
    ComicCoverStore.settingsKey: <String, dynamic>{},
    ComicCollectionStore.settingsKey: <String, dynamic>{},
  };

  static String? tokenOf(String? backup) =>
      backup == null ? null : _tokenPattern.firstMatch(backup)?.group(1);

  static String inherit(String? backup) {
    if (backup == null) return _unset;
    final token = tokenOf(backup);
    if (token != null) return token;
    if (!_legacyName.hasMatch(backup)) return _unset;
    return 'b${base64Url.encode(utf8.encode(backup)).replaceAll('=', '')}';
  }

  static String? legacyBackup(String? token) {
    if (token == null || !token.startsWith('b')) return null;
    try {
      final name = utf8.decode(base64Url.decode(base64Url.normalize(token.substring(1))));
      return _legacyName.hasMatch(name) ? name : null;
    } on FormatException {
      return null;
    }
  }

  Future<String> inheritForUpload(String? backup, {required bool directoryExists}) async {
    final token = inherit(backup);
    final legacy = legacyBackup(token);
    if (legacy == null || tokenOf(backup) != null) return token;
    if (!directoryExists) await client.mkdir(_directory);
    // A legacy client may later rotate the only zip containing these images.
    try {
      await client.copy('/$legacy', '$_directory/$legacy', false);
    } on DioException catch (error) {
      // 412 means already copied. Providers without COPY keep the root backup.
      if (![405, 412, 501].contains(error.response?.statusCode)) rethrow;
    }
    return token;
  }

  static bool _same(Map a, Map b) {
    final books = a[ComicCoverStore.settingsKey] as Map? ?? {};
    final previous = b[ComicCoverStore.settingsKey] as Map? ?? {};
    return books.length == previous.length &&
        books.entries.every((e) => mapEquals(e.value as Map?, previous[e.key] as Map?)) &&
        mapEquals(a[ComicCollectionStore.settingsKey] as Map?, b[ComicCollectionStore.settingsKey] as Map?);
  }

  Future<Map<String, dynamic>> _manifest(String token) async {
    final data = await client.read('$_directory/$token.json');
    final json = jsonDecode(utf8.decode(data));
    if (json is! Map<String, dynamic> ||
        json[ComicCoverStore.settingsKey] is! Map ||
        json[ComicCollectionStore.settingsKey] is! Map) {
      throw const FormatException('Invalid custom cover manifest');
    }
    return json;
  }

  Future<String> publish(Map<String, dynamic> covers, String? previousBackup, {required bool directoryExists}) async {
    if (_same(covers, emptyChoices)) return _empty;
    if (!directoryExists) await client.mkdir(_directory);
    final names = ComicCoverStore.fileNames(covers);
    if (names.isNotEmpty) {
      final remote = {for (final entry in await client.readDir('$_directory/')) entry.name: entry.size};
      for (final name in names) {
        final file = ComicCoverStore.fileFor(ComicCollectionStore.localCoverRef(name))!;
        final size = await file.length();
        if (size == 0) throw const FormatException('Empty cover image');
        if (remote.containsKey(name) && (remote[name] == null || remote[name] == size)) continue;
        final path = '$_directory/$name';
        await uploadWithWebdav404Fallback(
          streamUpload: () => writeFileStreamed(client, file, path),
          bufferedUpload: () async => client.write(path, await file.readAsBytes()),
        );
      }
    }
    final previous = tokenOf(previousBackup);
    if (previous != null && previous.length == 33 && previous.startsWith('c')) {
      try {
        if (_same(covers, await _manifest(previous))) return previous;
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
      }
    }
    final token = 'c${const Uuid().v4().replaceAll('-', '')}';
    await client.write('$_directory/$token.json', utf8.encode(jsonEncode(covers)));
    return token;
  }

  Future<Map<String, dynamic>> restore(String backup, Map<String, dynamic> embedded, {
    Set<String> visited = const {},
  }) async {
    final token = tokenOf(backup) ?? embedded[ComicCoverStore.inheritedWebdavKey];
    if (token == _unset) return ComicCoverStore.current;
    if (token == _empty) return emptyChoices;
    if (token != null && (token is! String || tokenOf('backup.$token.venera') != token)) {
      throw const FormatException('Invalid cover snapshot');
    }
    final legacy = legacyBackup(token);
    if (legacy != null) return _readLegacy(legacy, archived: true, visited: visited);
    if (token != null && !token.startsWith('c')) throw const FormatException('Invalid cover snapshot');
    // Older clients may forward the choices without having cached their images.
    final covers = token == null ? embedded : await _manifest(token);
    for (final name in ComicCoverStore.fileNames(covers)) {
      final file = ComicCoverStore.fileFor(ComicCollectionStore.localCoverRef(name))!;
      if (await file.exists() && await file.length() > 0) continue;
      await ComicCoverStore.installFile(file, (path) => client.read2File('$_directory/$name', path));
    }
    return covers;
  }

  Future<Map<String, dynamic>> restoreLatest(String backup) =>
      tokenOf(backup) == null ? _readLegacy(backup) : restore(backup, {});

  Future<Map<String, dynamic>> _readLegacy(String backup, {
    bool archived = false, Set<String> visited = const {},
  }) async {
    if (visited.contains(backup)) throw const FormatException('Circular cover backup');
    final staging = await Directory(App.cachePath).createTemp('legacy-covers-');
    try {
      final archive = File(FilePath.join(staging.path, 'backup.zip'));
      if (archived) {
        try {
          await client.read2File('$_directory/$backup', archive.path);
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
          await client.read2File('/$backup', archive.path);
        }
      } else {
        await client.read2File('/$backup', archive.path);
      }
      final root = staging.path;
      final covers = await Isolate.run(() => _extractLegacy(root));
      await ComicCoverStore.installFiles(covers, staging, requireAll: false);
      return await restore(backup, covers, visited: {...visited, backup});
    } finally {
      await staging.deleteIgnoreError(recursive: true);
    }
  }

  static Map<String, dynamic> _extractLegacy(String root) {
    final zip = ZipFile.openRead(FilePath.join(root, 'backup.zip'));
    try {
      final json = File(FilePath.join(root, 'appdata.json'));
      const dir = ComicCollectionStore.coverDirName;
      for (var i = 0; i < zip.entriesCount; i++) {
        final entry = zip.getEntryByIndex(i);
        if (entry.isDir) continue;
        if (entry.name == 'appdata.json') entry.writeToFile(json.path);
        if (!entry.name.startsWith('$dir/')) continue;
        final name = entry.name.substring(dir.length + 1);
        if (ComicCoverStore.nameOf(ComicCollectionStore.localCoverRef(name)) == null) continue;
        Directory(FilePath.join(root, dir)).createSync(recursive: true);
        entry.writeToFile(FilePath.join(root, dir, name));
      }
      final data = jsonDecode(json.readAsStringSync());
      return ComicCoverStore.snapshot(data['settings'] as Map);
    } finally {
      zip.close();
    }
  }
}
