import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_web.dart';

import 'io.dart';

const _serverDbEntries = [
  'data/venera.db',
  'history.db',
  'local_favorite.db',
  'cookie.db',
];

class DataSync with ChangeNotifier {
  DataSync._() {
    unawaited(_bootstrapWebDavConfig().then((_) {
      if (isEnabled) {
        unawaited(downloadData(hydrateLocalCache: true));
      }
    }));
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    ImageFavoriteManager().addListener(onDataChanged);
    ReadLaterManager().addListener(onDataChanged);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  Timer? _pendingAutoUpload;

  String? _lastError;

  static const _syncLogKey = 'sync_logs';
  static const _maxSyncLogs = 100;

  void _addSyncLog(String action, String? fileName, bool success, String? error) {
    var logs = (appdata.implicitData[_syncLogKey] as List?) ?? [];
    logs.insert(0, {
      'time': DateTime.now().millisecondsSinceEpoch,
      'action': action,
      'fileName': fileName,
      'success': success,
      'error': error,
    });
    if (logs.length > _maxSyncLogs) logs = logs.sublist(0, _maxSyncLogs);
    appdata.implicitData[_syncLogKey] = logs;
    appdata.writeImplicitData();
  }

  List<Map<String, dynamic>> get syncLogs {
    final raw = appdata.implicitData[_syncLogKey];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    return [];
  }

  List<String>? _serverWebDavConfig;

  bool? _serverWebDavAutoSync;

  String? _serverWebDavDisableSyncFields;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync =
        appdata.implicitData['webdavAutoSync'] ??
        _serverWebDavAutoSync ??
        false;
    return autoSync &&
        ((config is List && config.isNotEmpty) || _serverWebDavConfig != null);
  }

  void onDataChanged() {
    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
    if (isEnabled) {
      _pendingAutoUpload = Timer(const Duration(seconds: 2), () {
        _pendingAutoUpload = null;
        unawaited(uploadData());
      });
    }
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    var values = config.cast<String>().map((e) => e.trim()).toList();
    if (values.any((e) => e.isEmpty)) {
      return null;
    }
    return values;
  }

  Future<void> _bootstrapWebDavConfig() async {
    try {
      final config = await loadWebDavConfig(force: true);
      if (config != null && (config['autoSync'] == true)) {
        await downloadData(hydrateLocalCache: true);
      }
    } catch (e, s) {
      Log.error('WebDAV Config', e, s);
    }
  }

  Future<List<String>?> _resolveConfig() async {
    final local = _validateConfig();
    if (local != null && local.isNotEmpty) {
      return local;
    }
    await loadWebDavConfig();
    if (_serverWebDavConfig != null) {
      return _serverWebDavConfig;
    }
    return local;
  }

  int _dataVersion() {
    final value = appdata.settings['dataVersion'];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _appdataJsonForSync() {
    final data =
        jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
    final implicitData = appdata.implicitDataForSync();
    if (implicitData.isNotEmpty) {
      data['implicitData'] = jsonDecode(jsonEncode(implicitData));
    }
    final settings = data['settings'];
    if (settings is Map) {
      final disabledFields = appdata.splitField(
        appdata.settings['disableSyncFields'] as String,
      );
      for (final field in disabledFields) {
        settings.remove(field);
      }
    }
    return data;
  }

  Future<List<Map<String, String>>> _comicSourceEntriesForSync() async {
    final dir = Directory(FilePath.join(App.dataPath, 'comic_source'));
    if (!dir.existsSync()) {
      return const [];
    }
    final result = <Map<String, String>>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.name;
      if (!name.endsWith('.js') && !name.endsWith('.data')) {
        continue;
      }
      try {
        result.add({
          'name': name,
          'dataBase64': base64Encode(await entity.readAsBytes()),
        });
      } catch (e, s) {
        Log.warning(
          'Upload Data',
          'Failed to include comic source $name: $e\n$s',
        );
      }
    }
    return result;
  }

  Map<String, dynamic> _webDavPayload(List<String> config) {
    if (_serverWebDavConfig != null) {
      return {};
    }
    return {'url': config[0], 'user': config[1], 'pass': config[2]};
  }

  Dio _helperDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
        sendTimeout: const Duration(seconds: 120),
      ),
    );
  }

  Future<Map<String, dynamic>> _postHelper(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await _helperDio().post(
      path,
      data: payload,
      options: Options(extra: const {'maskDataInLog': true}),
    );
    final data = response.data;
    if (data is Map) {
      return data.cast<String, dynamic>();
    }
    throw StateError('Unexpected helper response');
  }

  Future<Map<String, dynamic>> _callHelper(
    String route,
    Map<String, dynamic> payload,
  ) {
    return _postHelper('/sync/webdav/$route', payload);
  }

  Future<Map<String, dynamic>?> loadWebDavConfig({bool force = false}) async {
    if (!force && _serverWebDavConfig != null) {
      return {
        'configured': true,
        'url': _serverWebDavConfig![0],
        'user': _serverWebDavConfig![1],
        'pass': _serverWebDavConfig![2],
        'autoSync': _serverWebDavAutoSync ?? false,
        'disableSyncFields': _serverWebDavDisableSyncFields ?? '',
      };
    }
    final data = await _callHelper('config/get', const <String, dynamic>{});
    if (data['configured'] != true) {
      _serverWebDavConfig = null;
      _serverWebDavAutoSync = false;
      _serverWebDavDisableSyncFields = null;
      notifyListeners();
      return null;
    }
    final url = data['url']?.toString().trim() ?? '';
    final user = data['user']?.toString().trim() ?? '';
    final pass = data['pass']?.toString() ?? '';
    if (url.isEmpty || user.isEmpty) {
      _serverWebDavConfig = null;
      _serverWebDavAutoSync = false;
      _serverWebDavDisableSyncFields = null;
      notifyListeners();
      return null;
    }
    _serverWebDavConfig = [url, user, pass];
    _serverWebDavAutoSync = data['autoSync'] == true;
    _serverWebDavDisableSyncFields =
        data['disableSyncFields']?.toString() ?? '';
    notifyListeners();
    return data;
  }

  Future<void> saveWebDavConfig(
    List<String> config, {
    required bool autoSync,
    required String disableSyncFields,
  }) async {
    final data = await _callHelper('config/save', {
      'url': config[0],
      'user': config[1],
      'pass': config[2],
      'autoSync': autoSync,
      'disableSyncFields': disableSyncFields,
    });
    _serverWebDavConfig = [
      data['url']?.toString() ?? config[0],
      data['user']?.toString() ?? config[1],
      data['pass']?.toString() ?? config[2],
    ];
    _serverWebDavAutoSync = data['autoSync'] == true;
    _serverWebDavDisableSyncFields =
        data['disableSyncFields']?.toString() ?? disableSyncFields;
    notifyListeners();
  }

  Future<void> clearWebDavConfig() async {
    await _callHelper('config/clear', const <String, dynamic>{});
    _serverWebDavConfig = null;
    _serverWebDavAutoSync = false;
    _serverWebDavDisableSyncFields = null;
    notifyListeners();
  }

  String get _serverDbProfile {
    final value = appdata.settings['webServerDbProfile']?.toString().trim();
    return value == null || value.isEmpty ? 'default' : value;
  }

  bool _isMissingServerDbRoute(Object error) {
    return error is DioException &&
        error.response?.statusCode == 404 &&
        error.requestOptions.path.startsWith('/api/server-db/');
  }

  Future<Map<String, dynamic>> _syncServerDatabase(List<String> config) {
    return _postHelper('/api/server-db/sync/webdav', {
      ..._webDavPayload(config),
      'profile': _serverDbProfile,
    });
  }

  Future<void> _importServerDatabaseFromHelper(
    List<String> config, {
    required bool hydrateLocalCache,
  }) async {
    final syncData = await _syncServerDatabase(config);
    final status = syncData['status'];
    final metadata = status is Map ? status['metadata'] : null;
    var sha256 = '';
    final responseSha256 = syncData['sha256']?.toString() ?? '';
    if (responseSha256.isNotEmpty) {
      sha256 = responseSha256;
    } else if (metadata is Map) {
      sha256 = metadata['sha256']?.toString() ?? '';
    }
    final importedSha = appdata.implicitData['webServerDbImportSha256']
        ?.toString();
    if (hydrateLocalCache &&
        syncData['skipped'] == true &&
        sha256.isNotEmpty &&
        importedSha == sha256) {
      Log.info('Data Sync', 'Server DB already imported');
      return;
    }

    try {
      final appdataResponse = await _postHelper('/api/server-db/appdata', {
        'profile': _serverDbProfile,
      });
      final remoteAppdata = appdataResponse['data'];
      if (remoteAppdata is Map) {
        appdata.syncData(remoteAppdata.cast<String, dynamic>());
      }
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
    }

    await _importServerComicSourcesFromHelper();
    if (HistoryManager().isInitialized) {
      await ImageFavoriteManager().hydrateServerImageFavorites(
        force: true,
        clearWhenRemoteEmpty: true,
      );
    }

    if (!hydrateLocalCache) {
      if (sha256.isNotEmpty) {
        appdata.implicitData['webServerDbSyncedSha256'] = sha256;
        appdata.writeImplicitData();
      }
      return;
    }

    final dumps = <String, dynamic>{};
    for (final entry in _serverDbEntries) {
      try {
        final dump = await _postHelper('/api/server-db/dump', {
          'profile': _serverDbProfile,
          'database': entry,
        });
        dumps[entry] = dump;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    final importStatus = await importWebServerDbDumps(dumps);
    if (importStatus != null) {
      appdata.implicitData[webPendingDbImportKey] = importStatus;
    }
    if (sha256.isNotEmpty) {
      appdata.implicitData['webServerDbImportSha256'] = sha256;
    }
    appdata.writeImplicitData();
  }

  Future<void> _importServerComicSourcesFromHelper() async {
    try {
      final comicSourcesResponse = await _postHelper(
        '/api/server-db/comic-sources',
        {'profile': _serverDbProfile},
      );
      final items = comicSourcesResponse['items'];
      if (items is List) {
        final imported = await importWebServerComicSources(items);
        if (imported > 0) {
          Log.info(
            'Data Sync',
            'Imported $imported comic sources from server DB',
          );
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
    }
  }

  int _backupDay(String fileName) {
    final value =
        int.tryParse(fileName.replaceAll('.venera', '').split('-').first) ?? 0;
    if (value > 1000000000) {
      return value ~/ 86400000;
    }
    return value;
  }

  int _backupVersion(String fileName) {
    final parts = fileName.replaceAll('.venera', '').split('-');
    if (parts.length < 2) {
      return -1;
    }
    return int.tryParse(parts[1]) ?? -1;
  }

  int _compareBackups(String a, String b) {
    final dayCompare = _backupDay(a).compareTo(_backupDay(b));
    if (dayCompare != 0) {
      return dayCompare;
    }
    final versionCompare = _backupVersion(a).compareTo(_backupVersion(b));
    if (versionCompare != 0) {
      return versionCompare;
    }
    return a.compareTo(b);
  }

  List<String> _cleanupFiles(List<String> files) {
    final backups = files
        .where((e) => e.endsWith('.venera') && e != 'latest.venera')
        .toList();
    backups.sort(_compareBackups);
    final remove = <String>[];
    while (backups.length - remove.length > 10) {
      remove.add(backups[remove.length]);
    }
    return remove;
  }

  Future<List<String>> _listRemoteFiles(List<String> config) async {
    final data = await _callHelper('list', _webDavPayload(config));
    return (data['files'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
  }

  String _formatError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) {
        return data['error'].toString();
      }
      if (error.response?.statusCode != null) {
        return 'HTTP ${error.response!.statusCode}';
      }
      return error.message ?? error.toString();
    }
    return error.toString();
  }

  Future<Res<bool>> uploadData() async {
    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      final config = await _resolveConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }

      final previousVersion = _dataVersion();
      final nextVersion = previousVersion + 1;
      try {
        await HistoryManager().waitServerHistorySync();
        await LocalFavoritesManager().waitServerFavoriteSync();
        await ImageFavoriteManager().syncServerImageFavorites();
        await ReadLaterManager().waitServerReadLaterSync();
        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);
        final daysSinceEpoch =
            DateTime.now().millisecondsSinceEpoch ~/ 86400000;
        final fileName = '$daysSinceEpoch-$nextVersion.venera';
        final uploadResult = await _postHelper('/api/server-db/upload/webdav', {
          ..._webDavPayload(config),
          'profile': _serverDbProfile,
          'fileName': fileName,
          'appdata': _appdataJsonForSync(),
          'comicSources': await _comicSourceEntriesForSync(),
        });
        var files =
            (uploadResult['files'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            await _listRemoteFiles(config);
        final removeFileNames = _cleanupFiles(files);
        if (removeFileNames.isNotEmpty) {
          final cleanupResult = await _callHelper('cleanup', {
            ..._webDavPayload(config),
            'removeFileNames': removeFileNames,
          });
          files =
              (cleanupResult['files'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              files;
        }
        Log.info("Upload Data", "Data uploaded successfully");
        _addSyncLog('upload', fileName, true, null);
        return const Res(true);
      } catch (e, s) {
        appdata.settings['dataVersion'] = previousVersion;
        await appdata.saveData(false);
        Log.error("Upload Data", e, s);
        _lastError = _formatError(e);
        _addSyncLog('upload', null, false, _lastError);
        return Res.error(_lastError!);
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData({bool hydrateLocalCache = true}) async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      final config = await _resolveConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }

      try {
        await _importServerDatabaseFromHelper(
          config,
          hydrateLocalCache: hydrateLocalCache,
        );
        Log.info("Data Sync", "Server DB synchronized successfully");
        HistoryManager().notifyListeners();
        LocalFavoritesManager().notifyListeners();
        ReadLaterManager().notifyListeners();
        return const Res(true);
      } catch (e, s) {
        if (!_isMissingServerDbRoute(e)) {
          Log.error("Data Sync", e, s);
          _lastError = _formatError(e);
          return Res.error(_lastError!);
        }
        Log.warning(
          "Data Sync",
          "Server DB helper route missing; falling back to legacy download: $e",
        );
      }

      try {
        final helperData = await _callHelper('download', {
          ..._webDavPayload(config),
          'lastSyncTime': 0,
        });
        if (helperData['skipped'] == true) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }
        final dataBase64 = helperData['dataBase64']?.toString() ?? '';
        if (dataBase64.isEmpty) {
          throw StateError('Remote backup file is empty');
        }
        final remoteFileName =
            helperData['remoteFileName']?.toString() ??
            '${DateTime.now().millisecondsSinceEpoch}.venera';
        final localFile = File(FilePath.join(App.cachePath, remoteFileName));
        try {
          await localFile.writeAsBytes(base64Decode(dataBase64));
          await importAppData(localFile, true);
        } finally {
          localFile.deleteIgnoreError();
        }
        Log.info("Data Sync", "Data downloaded successfully");
        _addSyncLog('download', null, true, null);
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = _formatError(e);
        _addSyncLog('download', null, false, _lastError);
        return Res.error(_lastError!);
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> syncData() async {
    final config = await _resolveConfig();
    if (config == null || config.isEmpty) {
      return uploadData();
    }
    try {
      final data = await _callHelper('list', _webDavPayload(config));
      final files = (data['files'] as List?)?.cast<String>() ?? [];
      if (files.isEmpty) return uploadData();
      var latest = files.first;
      var parts = latest.replaceAll('.venera', '').split('-');
      var versionStr = parts.elementAtOrNull(1)?.split('.').first ?? '0';
      var remoteVersion = int.tryParse(versionStr) ?? 0;
      var localVersion = appdata.settings['dataVersion'] is int
          ? appdata.settings['dataVersion'] as int
          : 0;
      if (remoteVersion > localVersion) {
        return downloadData();
      }
      return uploadData();
    } catch (e) {
      return uploadData();
    }
  }

  Future<Res<List<RemoteBackupInfo>>> listRemoteBackups() async {
    final config = await _resolveConfig();
    if (config == null) return const Res.error('Invalid WebDAV configuration');
    if (config.isEmpty) return const Res.error('WebDAV not configured');
    try {
      final data = await _callHelper('list', _webDavPayload(config));
      final files = (data['files'] as List?)?.cast<String>() ?? [];
      var backups = <RemoteBackupInfo>[];
      for (var name in files) {
        if (!name.endsWith('.venera')) continue;
        backups.add(RemoteBackupInfo.fromFileName(name));
      }
      backups.sort((a, b) => b.version.compareTo(a.version));
      return Res(backups);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> downloadSpecificBackup(String fileName) async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      final config = await _resolveConfig();
      if (config == null) return const Res.error('Invalid WebDAV configuration');

      final listData = await _callHelper('list', _webDavPayload(config));
      final files = (listData['files'] as List?)?.cast<String>() ?? [];
      int maxRemoteVersion = 0;
      for (var f in files) {
        var v = f.replaceAll('.venera', '').split('-').elementAtOrNull(1)?.split('.').first;
        if (v != null) {
          var ver = int.tryParse(v) ?? 0;
          if (ver > maxRemoteVersion) maxRemoteVersion = ver;
        }
      }

      try {
        final helperData = await _callHelper('download', {
          ..._webDavPayload(config),
          'remoteFileName': fileName,
          'force': true,
        });
        final dataBase64 = helperData['dataBase64']?.toString() ?? '';
        if (dataBase64.isEmpty) throw StateError('Remote backup file is empty');
        final localFile = File(FilePath.join(App.cachePath, fileName));
        try {
          await localFile.writeAsBytes(base64Decode(dataBase64));
          await importAppData(localFile, false);
        } finally {
          localFile.deleteIgnoreError();
        }

        appdata.settings['dataVersion'] = maxRemoteVersion + 1;
        await appdata.saveData(false);

        _addSyncLog('download', fileName, true, null);
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = _formatError(e);
        _addSyncLog('download', fileName, false, _lastError);
        return Res.error(_lastError!);
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}

class RemoteBackupInfo {
  final String fileName;
  final int version;
  final String platform;
  final DateTime date;
  final DateTime? mTime;

  RemoteBackupInfo({
    required this.fileName,
    required this.version,
    required this.platform,
    required this.date,
    this.mTime,
  });

  /// The most precise timestamp available for display: prefer the WebDAV
  /// last-modified time (has hour/minute/second) and fall back to the
  /// day-precision date parsed from the file name.
  DateTime get effectiveDate => mTime ?? date;

  factory RemoteBackupInfo.fromFileName(String name, {DateTime? mTime}) {
    var parts = name.replaceAll('.venera', '').split('-');
    var daysSinceEpoch = int.tryParse(parts.firstOrNull ?? '') ?? 0;
    var versionStr = parts.elementAtOrNull(1)?.split('.').first ?? '0';
    var version = int.tryParse(versionStr) ?? 0;
    var platform = 'unknown';
    var dotParts = parts.elementAtOrNull(1)?.split('.') ?? [];
    if (dotParts.length >= 2) {
      platform = dotParts[1];
    }
    var date = DateTime.fromMillisecondsSinceEpoch(daysSinceEpoch * 86400000);
    return RemoteBackupInfo(
      fileName: name,
      version: version,
      platform: platform,
      date: date,
      mTime: mTime,
    );
  }
}
