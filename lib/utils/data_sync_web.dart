import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
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

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  void onDataChanged() {
    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
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

  Map<String, dynamic> _webDavPayload(List<String> config) {
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

  Future<Map<String, dynamic>> _callHelper(
    String route,
    Map<String, dynamic> payload,
  ) async {
    final response = await _helperDio().post(
      '/sync/webdav/$route',
      data: payload,
      options: Options(extra: const {'maskDataInLog': true}),
    );
    final data = response.data;
    if (data is Map) {
      return data.cast<String, dynamic>();
    }
    throw StateError('Unexpected helper response');
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
      final config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }

      File? data;
      final previousVersion = _dataVersion();
      final nextVersion = previousVersion + 1;
      try {
        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);
        data = await exportAppData(
          appdata.settings['disableSyncFields'].toString().isNotEmpty,
        );
        final bytes = await data.readAsBytes();
        final daysSinceEpoch =
            DateTime.now().millisecondsSinceEpoch ~/ 86400000;
        final fileName = '$daysSinceEpoch-$nextVersion.venera';
        final uploadResult = await _callHelper('upload', {
          ..._webDavPayload(config),
          'fileName': fileName,
          'dataBase64': base64Encode(bytes),
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
        return const Res(true);
      } catch (e, s) {
        appdata.settings['dataVersion'] = previousVersion;
        await appdata.saveData(false);
        Log.error("Upload Data", e, s);
        _lastError = _formatError(e);
        return Res.error(_lastError!);
      } finally {
        data?.deleteIgnoreError();
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
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
      final config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
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
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = _formatError(e);
        return Res.error(_lastError!);
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}
