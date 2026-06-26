import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/init.dart' show deferredInitCompleter;
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/venera_comics.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_pkg;
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      _runStartupDownload();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    ReadLaterManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  /// Runs the initial WebDAV download, but only after heavy initialization has
  /// finished. [downloadData] may import a backup, and [importAppData] closes
  /// and swaps the favorites/history/local/domain SQLite files. Running that
  /// concurrently with `App.initComponents()` (which is still opening those very
  /// databases) raced into a native use-after-close crash on iOS that repeated
  /// on every launch — the imported backup is only "committed" (dataVersion
  /// advanced) after a successful import, so a crash mid-import re-downloaded and
  /// re-crashed forever. Waiting for init to settle first removes that race; the
  /// swap itself is also atomic against live UI reads (see `_replaceDatabaseFile`
  /// in data.dart), so the import is safe once the app is up.
  void _runStartupDownload() async {
    // The timeout is a safety net for environments that never complete
    // deferredInitCompleter — notably the `--headless` CLI, which runs its own
    // explicit sync and exits without calling initDeferred(); without it this
    // fire-and-forget future would dangle unresolved.
    try {
      await deferredInitCompleter.future.timeout(const Duration(seconds: 60));
    } catch (_) {}
    downloadData();
  }

  static String _platformTag() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'win';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static const _syncLogKey = 'sync_logs';
  static const _maxSyncLogs = 100;

  /// Overall request timeout for WebDAV sync operations. rhttp only enforces a
  /// connect timeout by default, so without this a connected-but-stalled socket
  /// (which iOS routinely produces when the network state changes) would hang
  /// the request forever — leaving [_isDownloading]/[_isUploading] stuck and
  /// every later sync busy-waiting until the user toggles the network. Bounding
  /// the request lets it fail cleanly and the state reset on its own.
  static const _syncRequestTimeout = Duration(seconds: 120);

  /// Image-pack transfers move whole comic archives, so they get a longer bound.
  static const _imageSyncRequestTimeout = Duration(minutes: 5);

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

  void onDataChanged() {
    if (isEnabled) {
      _pendingAutoUpload?.cancel();
      _pendingAutoUpload = Timer(const Duration(seconds: 2), () {
        _pendingAutoUpload = null;
        uploadData();
      });
    }
  }

  bool _handleWindowClose() {
    if (_pendingAutoUpload?.isActive ?? false) {
      _pendingAutoUpload?.cancel();
      _pendingAutoUpload = null;
      uploadData();
    }
    if (_isUploading || _isDownloading || _haveWaitingTask) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Syncing Data".tl,
    );
    while (_isUploading || _isDownloading || _haveWaitingTask) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  bool _isSyncingImages = false;
  bool get isSyncingImages => _isSyncingImages;

  Timer? _pendingAutoUpload;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
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

  /// Parses the numeric backup version out of a `<days>-<version>.<platform>.venera`
  /// file name. Returns 0 when the name does not match. Delegates to
  /// [RemoteBackupInfo.fromFileName] so the whole sync path shares one parser.
  int _versionOfFileName(String name) {
    return RemoteBackupInfo.fromFileName(name).version;
  }

  /// Picks the `.venera` backup with the highest numeric version.
  ///
  /// Selecting by version (instead of lexicographic file-name order) is
  /// essential: once the version crosses into two digits, string ordering
  /// ranks `...-9.venera` above `...-10.venera`, which used to make a stale
  /// backup look newer and reverse the sync direction.
  T? _latestBackup<T>(List<T> files, String? Function(T) nameOf) {
    T? best;
    var bestVersion = -1;
    for (final f in files) {
      var name = nameOf(f);
      if (name == null || !name.endsWith('.venera')) continue;
      var v = _versionOfFileName(name);
      if (v > bestVersion) {
        bestVersion = v;
        best = f;
      }
    }
    return best;
  }

  bool _hasCompletedInitialSync() {
    if (appdata.implicitData['hasCompletedInitialSync'] == true) return true;
    if (_dataVersion() > 0) {
      _markInitialSyncCompleted();
      return true;
    }
    return false;
  }

  void _markInitialSyncCompleted() {
    appdata.implicitData['hasCompletedInitialSync'] = true;
    appdata.writeImplicitData();
  }

  bool _isFavoriteDbValid() {
    var favDbPath = FilePath.join(App.dataPath, 'local_favorite.db');
    var favDbFile = File(favDbPath);
    if (!favDbFile.existsSync() || favDbFile.lengthSync() == 0) {
      return false;
    }
    return true;
  }

  bool _isFollowFolderEmpty() {
    var followFolder = appdata.settings['followUpdatesFolder'];
    if (followFolder is! String || followFolder.isEmpty) {
      return false;
    }
    var favDbPath = FilePath.join(App.dataPath, 'local_favorite.db');
    if (!File(favDbPath).existsSync()) return true;
    try {
      var db = sqlite3_pkg.sqlite3.open(favDbPath);
      try {
        var tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toList();
        if (!tables.contains(followFolder)) return true;
        var escaped = followFolder.replaceAll('"', '""');
        var count = db.select(
          'SELECT COUNT(*) as c FROM "$escaped"',
        ).first['c'] as int;
        return count == 0;
      } finally {
        db.dispose();
      }
    } catch (e) {
      Log.warning("DataSync", "Follow folder check failed: $e");
      return false;
    }
  }

  /// 拉起/刷新 WebDAV 同步的共享保活前台通知（仅 Android 生效，其它平台 no-op）。
  /// 只在确实要走网络传输时调用——快速的配置校验、版本探测、「无新数据」早退等都不触发，
  /// 免得为转瞬即逝的操作反复起停前台服务、在通知栏闪烁。
  void _refreshSyncKeepAlive(String status) {
    BackgroundKeepAlive.instance.update(BackgroundKeepAlive.tagSync, status);
  }

  /// 仅当再无任何同步活动（上传/下载/图片同步/排队等待）时，移除共享的同步保活通知。
  /// 各操作在 finally 里把自身标志清零后调用，最后一个收尾者才真正撤销，避免把仍在跑的
  /// 其它同步赖以不被冻结的前台服务一并撤掉。
  void _maybeStopSyncKeepAlive() {
    if (!syncKeepAliveActive(
      uploading: _isUploading,
      downloading: _isDownloading,
      syncingImages: _isSyncingImages,
      waiting: _haveWaitingTask,
    )) {
      BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagSync);
    }
  }

  Future<Res<bool>> uploadData() async {
    // No usable WebDAV config → nothing to sync. saveData() funnels every
    // settings/search-history change through here (plus comic-source saves,
    // imports, ...), so without bailing out up front an empty or malformed
    // config would still flip the syncing indicator, fire notifyListeners and
    // spawn a (then-cancelled) sync task — surfacing as a phantom upload on an
    // unconfigured app (#67). Validate before any side effects and return.
    final config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }

    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();

    // Create task for UI
    final taskManager = DataSyncTaskManager.instance;
    final task = taskManager.createTask(DataSyncTaskType.upload);

    try {
      taskManager.updateTask(task.id, currentPhase: 'Validating', progress: 0.0);

      if (!_hasCompletedInitialSync()) {
        _lastError = 'Please complete initial sync download first';
        _addSyncLog('upload', null, false, 'Blocked: initial sync not completed');
        taskManager.failTask(task.id, 'Initial sync not completed');
        return const Res.error('Initial sync not completed');
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      if (!_isFavoriteDbValid()) {
        _lastError = 'Favorite database is empty, upload blocked';
        _addSyncLog('upload', null, false, 'Blocked: local_favorite.db empty');
        taskManager.failTask(task.id, 'Favorite database is empty');
        return const Res.error('Favorite database is empty');
      }
      if (_isFollowFolderEmpty()) {
        _lastError = 'Follow folder is empty, auto-upload blocked';
        _addSyncLog('upload', null, false, 'Blocked: follow folder empty');
        taskManager.failTask(task.id, 'Follow folder is empty');
        return const Res.error('Follow folder is empty');
      }

      taskManager.updateTask(task.id, currentPhase: 'Preparing', progress: 0.1);
      // Past the cheap validation bail-outs and committed to an actual export +
      // upload — pin the process to foreground priority so backgrounding the app
      // mid-sync no longer freezes it (issue #78). Android-only; no-op elsewhere.
      _refreshSyncKeepAlive('Uploading data'.tl);

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(timeout: _syncRequestTimeout),
      );

      File? data;
      final previousVersion = _dataVersion();
      final nextVersion = previousVersion + 1;
      try {
        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);

        taskManager.updateTask(task.id, currentPhase: 'Exporting', progress: 0.3);
        data = await exportAppData(
          appdata.settings['disableSyncFields'].toString().isNotEmpty,
        );

        final fileSize = await data.length();
        var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
            .toString();
        var filename = time;
        filename += '-';
        filename += nextVersion.toString();
        filename += '.${_platformTag()}.venera';

        taskManager.updateTask(
          task.id,
          currentPhase: 'Uploading',
          progress: 0.5,
          fileName: filename,
          fileSize: fileSize,
        );
        _refreshSyncKeepAlive(
          formatTaskStatus(title: 'Uploading data'.tl, detail: filename),
        );

        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
        if (old != null) {
          await client.remove(old.name!);
        }
        if (files.length >= 10) {
          files.sort((a, b) => a.name!.compareTo(b.name!));
          await client.remove(files.first.name!);
        }

        taskManager.updateTask(task.id, currentPhase: 'Uploading', progress: 0.7);
        await client.write(filename, await data.readAsBytes());
        data.deleteIgnoreError();

        Log.info("Upload Data", "Data uploaded successfully");
        _addSyncLog('upload', filename, true, null);
        taskManager.completeTask(task.id, fileName: filename);
        _scheduleImageSync();
        return const Res(true);
      } catch (e, s) {
        appdata.settings['dataVersion'] = previousVersion;
        await appdata.saveData(false);
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        _addSyncLog('upload', null, false, e.toString());
        taskManager.failTask(task.id, e.toString());
        return Res.error(e.toString());
      } finally {
        data?.deleteIgnoreError();
      }
    } finally {
      _isUploading = false;
      _maybeStopSyncKeepAlive();
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

    // Create task for UI
    final taskManager = DataSyncTaskManager.instance;
    final task = taskManager.createTask(DataSyncTaskType.download);

    try {
      taskManager.updateTask(task.id, currentPhase: 'Validating', progress: 0.0);

      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        taskManager.failTask(task.id, 'Invalid WebDAV configuration');
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        taskManager.cancelTask(task.id);
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(timeout: _syncRequestTimeout),
      );

      try {
        taskManager.updateTask(task.id, currentPhase: 'Checking', progress: 0.1);

        var files = await client.readDir('/');
        var file = _latestBackup(files, (e) => e.name);
        if (file == null) {
          taskManager.failTask(task.id, 'No data file found');
          throw 'No data file found';
        }
        var remoteVersion = _versionOfFileName(file.name!);
        var currentVersion = _dataVersion();
        if (remoteVersion <= currentVersion) {
          Log.info("Data Sync", 'No new data to download');
          if (!_hasCompletedInitialSync()) {
            _markInitialSyncCompleted();
          }
          taskManager.completeTask(task.id, fileName: file.name);
          return const Res(true);
        }

        taskManager.updateTask(
          task.id,
          currentPhase: 'Downloading',
          progress: 0.2,
          fileName: file.name,
          fileSize: file.size ?? 0,
        );
        // A newer backup exists and we are about to pull + apply it; keep the
        // process alive across backgrounding for the whole download + import.
        _refreshSyncKeepAlive(
          formatTaskStatus(title: 'Downloading data'.tl, detail: file.name),
        );

        Log.info("Data Sync", "Downloading data from WebDAV server");
        var localFile = File(FilePath.join(App.cachePath, file.name!));
        try {
          await client.read2File(file.name!, localFile.path);

          taskManager.updateTask(task.id, currentPhase: 'Applying', progress: 0.6);

          await importAppData(localFile, checkVersion: true);
          if (!_hasCompletedInitialSync()) {
            _markInitialSyncCompleted();
          }
          _addSyncLog('download', file.name, true, null);
          taskManager.completeTask(task.id, fileName: file.name);
          // Align the local version with the backup we just imported. Without
          // this, the downloading device keeps its old (lower) dataVersion and
          // can later be treated as "newer" than the remote, reversing the sync
          // direction and overwriting good data with the stale local copy.
          if (remoteVersion > _dataVersion()) {
            appdata.settings['dataVersion'] = remoteVersion;
            await appdata.saveData(false);
          }

          if (_shouldSyncImages()) {
            _scheduleImageSync();
          }
          return const Res(true);
        } finally {
          localFile.deleteIgnoreError();
        }
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        _addSyncLog('download', null, false, e.toString());
        taskManager.failTask(task.id, e.toString());
        return Res.error(e.toString());
      }
    } finally {
      _isDownloading = false;
      _maybeStopSyncKeepAlive();
      notifyListeners();
    }
  }

  Future<Res<bool>> syncData() async {
    var config = _validateConfig();
    if (config == null || config.isEmpty) {
      return uploadData();
    }
    String url = config[0];
    String user = config[1];
    String pass = config[2];
    try {
      var client = newClient(url, user: user, password: pass, adapter: RHttpAdapter(timeout: _syncRequestTimeout));
      var files = await client.readDir('/');
      var file = _latestBackup(files, (e) => e.name);
      if (file == null) {
        return uploadData();
      }
      if (_versionOfFileName(file.name!) > _dataVersion()) {
        return downloadData();
      }
      return uploadData();
    } catch (e) {
      return uploadData();
    }
  }

  Future<Res<List<RemoteBackupInfo>>> listRemoteBackups() async {
    var config = _validateConfig();
    if (config == null) return const Res.error('Invalid WebDAV configuration');
    if (config.isEmpty) return const Res.error('WebDAV not configured');
    String url = config[0];
    String user = config[1];
    String pass = config[2];
    try {
      var client = newClient(url, user: user, password: pass, adapter: RHttpAdapter(timeout: _syncRequestTimeout));
      var files = await client.readDir('/');
      var backups = <RemoteBackupInfo>[];
      for (var f in files) {
        if (f.name == null || !f.name!.endsWith('.venera')) continue;
        backups.add(RemoteBackupInfo.fromFileName(f.name!, mTime: f.mTime));
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
      var config = _validateConfig();
      if (config == null) return const Res.error('Invalid WebDAV configuration');
      String url = config[0];
      String user = config[1];
      String pass = config[2];
      var client = newClient(url, user: user, password: pass, adapter: RHttpAdapter(timeout: _syncRequestTimeout));
      // User explicitly chose this backup to restore — always a real transfer, so
      // engage keep-alive across the download + apply.
      _refreshSyncKeepAlive(
        formatTaskStatus(title: 'Downloading data'.tl, detail: fileName),
      );
      try {
        var files = await client.readDir('/');
        var latest = _latestBackup(files, (e) => e.name);
        int maxRemoteVersion = 0;
        if (latest != null) {
          maxRemoteVersion = _versionOfFileName(latest.name!);
        }

        var localFile = File(FilePath.join(App.cachePath, fileName));
        try {
          await client.read2File(fileName, localFile.path);
          await importAppData(localFile, checkVersion: false);
        } finally {
          localFile.deleteIgnoreError();
        }

        appdata.settings['dataVersion'] = maxRemoteVersion + 1;
        await appdata.saveData(false);

        if (!_hasCompletedInitialSync()) _markInitialSyncCompleted();
        _addSyncLog('download', fileName, true, null);
        // Mirror downloadData: the backup only restores base app data. If the
        // user has image-pack sync enabled locally, download the comic image
        // packs in the background instead of blocking this call.
        if (_shouldSyncImages()) {
          _scheduleImageSync();
        }
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        _addSyncLog('download', fileName, false, e.toString());
        return Res.error(e.toString());
      }
    } finally {
      _isDownloading = false;
      _maybeStopSyncKeepAlive();
      notifyListeners();
    }
  }

  bool _shouldSyncImages() {
    return appdata.settings['syncLocalComicImages'] == true && isEnabled;
  }

  Timer? _imageSyncTimer;

  void _scheduleImageSync() {
    if (!_shouldSyncImages()) return;
    _imageSyncTimer?.cancel();
    _imageSyncTimer = Timer(const Duration(seconds: 30), () {
      _imageSyncTimer = null;
      syncComicImages();
    });
  }

  Future<void> syncComicImages() async {
    if (_isSyncingImages || !_shouldSyncImages()) return;
    _isSyncingImages = true;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null || config.isEmpty) return;
      String url = config[0];
      String user = config[1];
      String pass = config[2];
      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(timeout: _imageSyncRequestTimeout),
      );

      // Image-pack sync moves whole comic archives and is the longest-running,
      // most background-prone sync op — hold the process across backgrounding.
      _refreshSyncKeepAlive('Syncing images'.tl);
      await _ensureComicsDir(client);
      await _uploadComicImages(client);
      await _downloadComicImages(client);
    } catch (e, s) {
      Log.error("Image Sync", e, s);
    } finally {
      _isSyncingImages = false;
      _maybeStopSyncKeepAlive();
      notifyListeners();
    }
  }

  Future<void> _ensureComicsDir(Client client) async {
    try {
      await client.readDir('/venera-comics/');
    } catch (_) {
      try {
        await client.mkdir('/venera-comics/');
      } catch (_) {}
    }
  }

  Future<void> _uploadComicImages(Client client) async {
    var comics = LocalManager().getComics(LocalSortType.defaultSort)
        .where((c) => c.status == LocalComicStatus.downloaded)
        .toList();
    if (comics.isEmpty) return;

    List<String> remoteFiles;
    try {
      var files = await client.readDir('/venera-comics/');
      remoteFiles = files
          .map((f) => f.name ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      remoteFiles = [];
    }

    for (var comic in comics) {
      var fileName =
          '${comic.id}_${comic.comicType.value}.venera_comics';
      if (remoteFiles.contains(fileName)) continue;

      try {
        var file =
            await exportVeneraComics([comic], includeImages: true);
        await client.write(
          '/venera-comics/$fileName',
          await file.readAsBytes(),
        );
        file.deleteIgnoreError();
        Log.info("Image Sync", "Uploaded: ${comic.title}");
      } catch (e, s) {
        Log.error(
          "Image Sync", "Failed to upload ${comic.title}: $e", s);
      }
    }
  }

  Future<void> _downloadComicImages(Client client) async {
    var comics = LocalManager().getComics(LocalSortType.defaultSort)
        .where((c) => c.status == LocalComicStatus.notDownloaded)
        .toList();
    if (comics.isEmpty) return;

    List<String> remoteFiles;
    try {
      var files = await client.readDir('/venera-comics/');
      remoteFiles = files
          .map((f) => f.name ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return;
    }

    for (var comic in comics) {
      var fileName =
          '${comic.id}_${comic.comicType.value}.venera_comics';
      if (!remoteFiles.contains(fileName)) continue;

      try {
        var localFile = File(FilePath.join(App.cachePath, fileName));
        await client.read2File(
          '/venera-comics/$fileName', localFile.path);
        await importVeneraComics(localFile);
        localFile.deleteIgnoreError();
        Log.info("Image Sync", "Downloaded: ${comic.title}");
      } catch (e, s) {
        Log.error(
          "Image Sync", "Failed to download ${comic.title}: $e", s);
      }
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
    var leadingSegment = int.tryParse(parts.firstOrNull ?? '') ?? 0;
    var versionStr = parts.elementAtOrNull(1)?.split('.').first ?? '0';
    var version = int.tryParse(versionStr) ?? 0;
    var platform = 'unknown';
    var dotParts = parts.elementAtOrNull(1)?.split('.') ?? [];
    if (dotParts.length >= 2) {
      platform = dotParts[1];
    }
    return RemoteBackupInfo(
      fileName: name,
      version: version,
      platform: platform,
      date: _dateFromLeadingSegment(leadingSegment),
      mTime: mTime,
    );
  }

  static const int _msPerDay = 86400000;

  /// Upper bound of [DateTime.fromMillisecondsSinceEpoch]'s valid range.
  static const int _maxValidMs = 8640000000000000;

  /// Resolves the date encoded in a backup file name's leading segment.
  ///
  /// The segment is normally days-since-epoch (~5 digits). Older and foreign
  /// backups instead store a full `millisecondsSinceEpoch` (~13 digits); blindly
  /// multiplying that by [_msPerDay] overflows 64-bit int on Android and throws
  /// a RangeError that aborts the entire directory scan (issue #51). So multiply
  /// only when the value is small enough to be a real day count, otherwise treat
  /// it as milliseconds, and clamp so the constructor can never throw.
  static DateTime _dateFromLeadingSegment(int value) {
    var ms =
        value.abs() <= _maxValidMs ~/ _msPerDay ? value * _msPerDay : value;
    if (ms > _maxValidMs) ms = _maxValidMs;
    if (ms < -_maxValidMs) ms = -_maxValidMs;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}
