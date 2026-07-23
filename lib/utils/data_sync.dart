import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/init.dart' show deferredInitCompleter;
import 'package:venera/utils/data.dart';
import 'package:venera/utils/sync_protocol.dart';
import 'package:venera/utils/venera_comics.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

// All sync direction / version / file-selection DECISIONS are pure functions
// in sync_protocol.dart — one audited, unit-tested place. This file owns only
// IO, locking, task/UI surface and triggers.
export 'package:venera/utils/sync_protocol.dart';

class DataSync with ChangeNotifier, WidgetsBindingObserver {
  DataSync._() {
    // Downloads run in EVERY sync tier (the probe is a cheap readDir and only
    // pulls when the server genuinely holds newer data); the per-device
    // [syncMode] governs upload automation only.
    if (isConfigured) {
      _runStartupDownload();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    ReadLaterManager().addListener(onDataChanged);
    // History and image-favorites changes must schedule an upload too:
    // without these, a deletion made on this device was silently reverted by
    // the next pull from a device still holding the record.
    HistoryManager().addListener(onDataChanged);
    ImageFavoriteManager().addListener(onDataChanged);
    // Data-saver settle points (#114): going to background / screen-off
    // (Android) and returning to foreground. Safe in headless mode too —
    // both entrypoints call WidgetsFlutterBinding.ensureInitialized().
    WidgetsBinding.instance.addObserver(this);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  /// Data-saver settle points (#114). `paused` fires on Android for both
  /// app-switch and screen-off — the natural "session ended" moments — and
  /// the upload rides the existing sync keep-alive foreground service, so
  /// backgrounding doesn't freeze it mid-PUT. iOS gets NO paused settle: its
  /// ~30s background budget can't reliably carry a request bounded by the
  /// 120s timeout, so a half-finished PUT would only waste the user's data —
  /// there the account settles on resume/startup instead.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && App.isAndroid) {
      settlePendingChanges();
    } else if (state == AppLifecycleState.resumed) {
      settlePendingChanges();
    }
  }

  /// Runs the initial WebDAV download, but only after heavy initialization has
  /// finished. [downloadData] may import a backup; running that concurrently
  /// with `App.initComponents()` (which is still opening those very databases)
  /// raced into a native use-after-close crash on iOS that repeated on every
  /// launch — the imported backup is only "committed" (dataVersion advanced)
  /// after a successful import, so a crash mid-import re-downloaded and
  /// re-crashed forever. Waiting for init to settle first removes that race;
  /// the apply itself restores each store by closing its connection, swapping
  /// the file, and reopening, all inside a gateway exclusive window so no other
  /// handle is alive against a file while it is replaced.
  void _runStartupDownload() async {
    // The timeout is a safety net for environments that never complete
    // deferredInitCompleter. When it fires we SKIP this launch's auto
    // download instead of proceeding: applying a backup needs fully
    // initialized stores (the restore closes and reopens their connections). A slow proxy can legitimately hold deferred init (comic
    // script inits do network) past the window; syncing a bit late is better
    // than failing. The headless CLI completes the gate explicitly before its
    // own sync.
    try {
      await deferredInitCompleter.future.timeout(const Duration(seconds: 60));
    } catch (_) {
      Log.warning(
        "Data Sync",
        "Deferred init not settled in time; skipping startup download",
      );
      return;
    }
    var result = await downloadData();
    // Startup settle (#114): pay an account the previous run left open (a
    // killed process, or an iOS session that never got a background settle).
    // Only after a successful check — pushing while possibly behind would
    // just bounce off the stale-upload guard into a second download.
    if (!result.error) {
      await settlePendingChanges();
    }
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

  /// Whether WebDAV sync requests go through the app-wide proxy. Users can turn
  /// this off when an unstable proxy makes sync fail (#99); direct connections
  /// are often more reliable for reaching a WebDAV server on the local network.
  static bool _useProxy() => appdata.settings['webdavUseProxy'] != false;

  /// Builds the sync adapter, honoring the per-user proxy toggle and the given
  /// overall request timeout.
  static RHttpAdapter _syncAdapter(Duration timeout) =>
      RHttpAdapter(enableProxy: _useProxy(), timeout: timeout);

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

  /// True while a downloaded/imported backup is being APPLIED to local state.
  ///
  /// Applying a backup closes and re-inits the favorites/read-later/comic-source
  /// managers, and every one of those `init()`/`reload()` calls fires
  /// `notifyListeners` — the very listeners wired to [onDataChanged]. Without
  /// this flag every successful download was followed ~2s later by an "echo"
  /// upload of the just-downloaded content stamped one version higher: two
  /// aligned devices ping-ponged versions forever, a restored old backup was
  /// instantly re-published fleet-wide, and server retention churned. Data
  /// changes caused by APPLYING remote/imported data must never re-upload it.
  bool _isApplyingBackup = false;

  /// Runs [apply] (an importAppData-based restore) with echo-upload
  /// suppression, also cancelling any auto-upload already pending — that
  /// debounced change is about to be overwritten by the backup anyway.
  Future<T> applyBackup<T>(Future<T> Function() apply) async {
    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
    _isApplyingBackup = true;
    try {
      return await apply();
    } finally {
      _isApplyingBackup = false;
    }
  }

  static const _syncModeKey = 'webdavSyncMode';
  static const _pendingChangesKey = 'webdavPendingChanges';
  static const _pendingPublishKey = 'webdavPendingPublish';

  /// How long the FIRST unsynced change may sit local in data-saver mode
  /// before a mid-session settle uploads it anyway. Bounds cloud staleness
  /// for marathon sessions that never background the app, while capping a
  /// heavy day at a handful of uploads instead of one per comic (#114).
  static const _dataSaverMaxPendingAge = Duration(minutes: 30);

  /// Bumped on every marked change. An upload captures it right before
  /// exporting and only clears the pending flag when nothing landed after the
  /// snapshot — a change arriving mid-upload must never be marked as synced.
  int _pendingChangesEpoch = 0;

  Timer? _pendingSettleTimer;

  /// This device's upload-automation tier. Per-device on purpose (stored in
  /// implicitData, never synced): cadence belongs to the device/connection,
  /// not the account. Reads through [syncModeFromName] so devices configured
  /// before the tiers existed keep their legacy `webdavAutoSync` meaning.
  WebdavSyncMode get syncMode => syncModeFromName(
        appdata.implicitData[_syncModeKey]?.toString(),
        legacyAutoSync: appdata.implicitData['webdavAutoSync'] is bool
            ? appdata.implicitData['webdavAutoSync'] as bool
            : null,
      );

  void setSyncMode(WebdavSyncMode mode) {
    appdata.implicitData[_syncModeKey] = mode.name;
    // Keep the legacy boolean coherent: QR config payloads and downgraded
    // installs still read it.
    appdata.implicitData['webdavAutoSync'] = mode != WebdavSyncMode.manual;
    appdata.writeImplicitData();
    if (mode != WebdavSyncMode.dataSaver) {
      _pendingSettleTimer?.cancel();
      _pendingSettleTimer = null;
    }
    // Entering an automatic tier with an open account settles it now — this
    // also covers dataSaver→realtime, where no timer would ever fire again.
    settlePendingChanges();
    notifyListeners();
  }

  /// True when local changes exist that no successful upload has covered yet.
  /// Maintained by the dataSaver/manual tiers (realtime uploads immediately);
  /// drives the home sync button's badge and every settle decision. Persisted
  /// so a killed process still owes — and pays — its account on next launch.
  bool get hasPendingChanges =>
      appdata.implicitData[_pendingChangesKey] == true;

  void _markPendingChanges() {
    _pendingChangesEpoch++;
    if (syncMode == WebdavSyncMode.dataSaver) {
      _armPendingSettleTimer();
    }
    if (hasPendingChanges) return; // already persisted; skip the IO churn
    appdata.implicitData[_pendingChangesKey] = true;
    appdata.writeImplicitData();
    notifyListeners();
  }

  void _armPendingSettleTimer() {
    // ??= — the clock runs from the FIRST unsynced change. Later changes must
    // not extend it, or continuous reading would defer the settle forever and
    // void the "at most N minutes stale" guarantee.
    _pendingSettleTimer ??= Timer(_dataSaverMaxPendingAge, () {
      _pendingSettleTimer = null;
      settlePendingChanges();
    });
  }

  void _clearPendingChanges(int epochAtExport) {
    // Changes landed after the uploaded snapshot was exported — the account
    // stays open and the next settle point picks them up.
    if (_pendingChangesEpoch != epochAtExport) return;
    _pendingSettleTimer?.cancel();
    _pendingSettleTimer = null;
    if (!hasPendingChanges) return;
    appdata.implicitData[_pendingChangesKey] = false;
    appdata.writeImplicitData();
    notifyListeners();
  }

  /// File name + size of an upload PUT this device sent but never confirmed
  /// (#133). Recorded (persisted, device-local) immediately before the PUT and
  /// cleared once the version is adopted, so a publish that landed without the
  /// client learning it (undecodable response, timeout, process death) can be
  /// reclaimed by [downloadData] instead of pulled back over newer local data.
  ({String fileName, int? size})? get _pendingPublish {
    final v = appdata.implicitData[_pendingPublishKey];
    if (v is! Map) return null;
    final name = v['fileName']?.toString();
    if (name == null || name.isEmpty) return null;
    final size = v['size'];
    return (fileName: name, size: size is int ? size : null);
  }

  void _setPendingPublish(String fileName, int size) {
    appdata.implicitData[_pendingPublishKey] = {
      'fileName': fileName,
      'size': size,
    };
    appdata.writeImplicitData();
  }

  void _clearPendingPublish() {
    if (appdata.implicitData.remove(_pendingPublishKey) != null) {
      appdata.writeImplicitData();
    }
  }

  /// Uploads the pending account if one is open. The data-saver settle
  /// points all funnel here: background/screen-off (Android), resume,
  /// startup, the [_dataSaverMaxPendingAge] cap, desktop window close and
  /// the post-catch-up-download hook. No-op when clean, unconfigured, in
  /// manual mode (its account settles only via the sync button), mid-apply,
  /// before the initial sync completed, or while an upload is already in
  /// flight (it carries the account).
  Future<void> settlePendingChanges() async {
    if (syncMode == WebdavSyncMode.manual) return;
    if (!hasPendingChanges) return;
    if (!isConfigured) return;
    if (_isApplyingBackup) return;
    if (_isUploading) return;
    if (!_hasCompletedInitialSync()) return;
    await uploadData();
    // Failed, or superseded by changes that landed mid-upload: re-arm so a
    // quiet session still retries within the staleness bound instead of
    // waiting for the next change or lifecycle event.
    if (hasPendingChanges && syncMode == WebdavSyncMode.dataSaver) {
      _armPendingSettleTimer();
    }
  }

  /// Single funnel for every AUTOMATIC upload trigger (manager listeners,
  /// settings/search-history saves, comic-source saves). Routes by the
  /// device's [syncMode], ignores echo notifications while a backup is being
  /// applied, and debounces bursts. Explicit publishes (manual button, local
  /// import, headless CLI) do not come through here — they call
  /// [uploadData] with `force: true` directly.
  void requestAutoUpload() {
    if (!isConfigured) return;
    if (_isApplyingBackup) return;
    switch (syncMode) {
      case WebdavSyncMode.realtime:
        _pendingAutoUpload?.cancel();
        _pendingAutoUpload = Timer(const Duration(seconds: 2), () {
          _pendingAutoUpload = null;
          if (_isApplyingBackup) return;
          uploadData();
        });
      case WebdavSyncMode.dataSaver:
      case WebdavSyncMode.manual:
        // Deferred tiers keep an account instead of a network round-trip:
        // dataSaver settles it at the session boundaries, manual only via
        // the sync button (the flag still drives its badge).
        _markPendingChanges();
    }
  }

  void onDataChanged() {
    requestAutoUpload();
  }

  bool _handleWindowClose() {
    var hasPendingDebounce = _pendingAutoUpload?.isActive ?? false;
    if (hasPendingDebounce) {
      _pendingAutoUpload?.cancel();
      _pendingAutoUpload = null;
    }
    // Data-saver keeps its account open for the whole session, and desktop
    // has no `paused` lifecycle moment — the window close IS its settle
    // point. Manual mode is deliberately absent: the user opted out of every
    // automatic upload.
    var hasOpenAccount =
        syncMode == WebdavSyncMode.dataSaver && hasPendingChanges;
    if (hasPendingDebounce || hasOpenAccount) {
      // Flush the pending change before exit. Deliberately NOT forced: if this
      // device is behind the server, uploading would overwrite newer remote
      // data (#86). The guard inside uploadData skips the stale push; we do
      // not let it convert into a download either — pulling a whole backup
      // during window close would silently revert the change the user just
      // made and delay shutdown. Skipping is the safe, predictable choice.
      uploadData(allowCatchUpDownload: false);
    }
    // Include image sync: exiting mid-PUT used to leave a partial pack on the
    // server that the dedup check then treated as complete forever.
    if (_isUploading || _isDownloading || _haveWaitingTask || _isSyncingImages) {
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
    while (_isUploading ||
        _isDownloading ||
        _haveWaitingTask ||
        _isSyncingImages) {
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

  /// True while a downloaded/imported backup is being applied to the local
  /// stores. Concurrent writers (the follow-update checker above all) consult
  /// this to hold off, so their writes don't interleave with the restore.
  bool get isApplyingBackup => _isApplyingBackup;

  Timer? _pendingAutoUpload;

  String? _lastError;

  String? get lastError => _lastError;

  /// A syntactically valid, non-empty WebDAV config exists. This is the only
  /// gate for showing sync UI and for automatic downloads; UPLOAD automation
  /// is governed per-device by [syncMode].
  bool get isConfigured {
    final config = _validateConfig();
    return config != null && config.isNotEmpty;
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

  /// Whether [fileName] actually exists on the server with [expectedSize]
  /// (size check skipped when the server does not report one). Used after a
  /// failed PUT to detect a publish that landed anyway (#133). Any probe
  /// error means "unknown" → false; the persisted pending-publish record then
  /// reconciles on a later sync.
  Future<bool> _publishLanded(
    Client client,
    String fileName,
    int expectedSize,
  ) async {
    try {
      final files = await client.readDir('/');
      for (final f in files) {
        if (f.name == fileName) {
          return f.size == null || f.size == expectedSize;
        }
      }
    } catch (_) {}
    return false;
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
      var db = openRawDatabase(favDbPath);
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

  /// Uploads the current data as a new backup.
  ///
  /// [force] distinguishes an explicit "publish this, it is the source of
  /// truth" (manual upload button, local-file import, headless CLI) from an
  /// automatic or reconciling upload fired by a routine data change
  /// ([saveData], [onDataChanged], comic-source saves) or by [syncData]. Only
  /// the latter run the fall-behind guard below; forced uploads keep the #80
  /// "version = server max + 1, always wins" behavior. [syncData] intentionally
  /// stays unforced so that a device losing a race — the server gaining a newer
  /// backup between syncData's direction check and this re-read — pulls instead
  /// of overwriting it.
  Future<Res<bool>> uploadData({
    bool force = false,
    bool allowCatchUpDownload = true,
  }) async {
    // No usable WebDAV config → nothing to sync. saveData() funnels every
    // settings/search-history change through here (plus comic-source saves,
    // imports, ...), so without bailing out up front an empty or malformed
    // config would still flip the syncing indicator, fire notifyListeners and
    // spawn a (then-cancelled) sync task — surfacing as a phantom upload on an
    // unconfigured app (#67). Validate before any side effects and return.
    final config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      // Surface the error state on the sync button; without this the button
      // stayed visibly idle and taps appeared to do nothing.
      notifyListeners();
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }

    _pendingAutoUpload?.cancel();
    _pendingAutoUpload = null;
    if (_haveWaitingTask) return const Res(true);
    // Waits for image sync too: exportAppData snapshots local.db while image
    // sync may be importing packs into it. Image sync yields between comics
    // when it sees _haveWaitingTask, so this wait is bounded.
    while (isDownloading || isUploading || isSyncingImages) {
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
        adapter: _syncAdapter(_syncRequestTimeout),
      );

      File? data;
      final previousVersion = _dataVersion();
      try {
        // Read the server's existing backups first and stamp this upload with a
        // version above the highest one already there. Basing the new version on
        // the local value alone let a device trailing the server (a fresh device,
        // or one that just imported a foreign archive whose dataVersion is
        // unrelated and lower) upload a backup other devices treated as "older"
        // and never auto-pulled (#80).
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        final remoteMax = maxBackupVersion(files.map((e) => e.name));

        // Fall-behind guard (auto uploads only). If the server already holds a
        // newer backup than this device, we are behind — uploading now would
        // stamp our STALE snapshot with `remoteMax + 1` and, because sync is a
        // whole-library snapshot (last-writer-wins by version number), that
        // higher number makes every other device pull our old data back,
        // reverting the newer data they had (#86). So instead of pushing, we
        // pull the newer backup to catch up. No busy-waiting: the upload turns
        // into a download and returns. Once the download realigns local data,
        // this device is no longer behind, and any genuine later change flows
        // up normally through onDataChanged — recovery needs no explicit retry.
        //
        // Explicit uploads (`force`) skip this: a manual "Upload" tap, a local
        // file import ("make this the source of truth"), and the headless CLI
        // have already decided this device wins — exactly the #80 behavior we
        // must preserve. syncData() stays unforced on purpose: its direction
        // check races the re-read here, and losing that race means the server
        // gained a newer backup we should pull, not overwrite.
        if (shouldSkipStaleUpload(
          force: force,
          localVersion: previousVersion,
          remoteMaxVersion: remoteMax,
        )) {
          Log.info(
            "Data Sync",
            "Local (v$previousVersion) behind server (v$remoteMax); "
                "pulling instead of overwriting with stale data",
          );
          _addSyncLog(
            'upload',
            null,
            false,
            'Skipped: local behind server, downloading first',
          );
          taskManager.cancelTask(task.id);
          if (allowCatchUpDownload) {
            // Release the upload lock so the download we kick off below doesn't
            // wait on our own in-flight flag. downloadData()'s synchronous prefix
            // sets _isDownloading before its first await, so the outer finally
            // sees the download has taken over and keeps the keep-alive up rather
            // than flickering it off.
            _isUploading = false;
            unawaited(
              downloadData().then((res) {
                // Data-saver (#114): the pending account survives the
                // catch-up. Once the pull realigned this device, publish the
                // merged state — onDataChanged no longer does that for the
                // deferred tiers. Only after success: retrying a failed pull
                // here would tight-loop upload→download on a bad network.
                if (!res.error) settlePendingChanges();
              }),
            );
          }
          return const Res(true);
        }

        final nextVersion = nextSyncVersion(previousVersion, remoteMax);

        taskManager.updateTask(task.id, currentPhase: 'Exporting', progress: 0.3);
        // Captured BEFORE the export: only changes already inside this
        // snapshot may be marked as settled. Anything landing between here
        // and completion bumps the epoch and keeps the account open (#114).
        final pendingEpochAtExport = _pendingChangesEpoch;
        data = await exportAppData(
          sync: appdata.settings['disableSyncFields'].toString().isNotEmpty,
          includeLocalComics: _syncLocalComics(),
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

        // Publish FIRST, claim and clean up after. The old order — persist
        // dataVersion, delete today's previous backup, then write — had two
        // failure holes: a process kill mid-upload left a local claim to a
        // version that exists nowhere ("phantom version", which later makes
        // this device skip other devices' legitimate uploads at the same
        // number), and a failed write after the delete permanently destroyed
        // the day's newest snapshot. Writing the new backup before touching
        // anything else means every failure mode leaves the server holding at
        // least everything it held before.
        //
        // Streamed from disk: readAsBytes materialized the whole backup zip
        // in RAM before the PUT — the same OOM class #93 fixed for local
        // export, fatal for large libraries on mobile.
        taskManager.updateTask(task.id, currentPhase: 'Uploading', progress: 0.7);
        // Record the publish attempt BEFORE the PUT (#133). The PUT can land
        // on the server while this client still sees a failure — the response
        // body fails to decode (rhttp "error decoding response body"), the
        // request times out after the server committed, or the process dies
        // before the version is adopted below. The server is then holding our
        // own snapshot one version above our local claim; without this record
        // the next sync reads "local behind server", pulls our own stale
        // snapshot back and reverts everything read since the export — then
        // re-uploads the reverted state, spreading it fleet-wide.
        // downloadData() consults the record and reclaims the orphan instead.
        _setPendingPublish(filename, fileSize);
        try {
          await client.writeFromFile(data.path, filename);
        } catch (e) {
          // The PUT may have succeeded even though its response was lost.
          // Probe once: if the backup is on the server with the expected
          // size, the publish landed — continue as success so the version is
          // adopted and no orphan is left. Probe failure keeps the persisted
          // record for downloadData to reconcile later.
          if (!await _publishLanded(client, filename, fileSize)) rethrow;
          Log.info(
            "Upload Data",
            "PUT reported failure but the backup landed on the server; "
                "treating as success: $e",
          );
        }
        data.deleteIgnoreError();

        // The backup is on the server — only now adopt the version locally.
        appdata.settings['dataVersion'] = nextVersion;
        await appdata.saveData(false);
        _clearPendingPublish();
        // The published snapshot covers every change up to the export —
        // settle the deferred-tier account (no-op unless it was open and
        // nothing landed mid-upload).
        _clearPendingChanges(pendingEpochAtExport);

        // Per-platform retention: every platform keeps its newest
        // [backupRetentionPerPlatform] backups so a bad upload can be rolled
        // back from server history via "restore specific backup". Replaces
        // the old same-day dedup (which could delete the last good snapshot
        // uploaded minutes before a mistake) and the global 10-file cap
        // (which pruned by lowest version fleet-wide and could starve an
        // inactive platform of its only backups). The count is the synced
        // 'webdavBackupRetention' setting, sanitized (#114).
        for (final stale in backupsBeyondPlatformRetention(
          fileNames: files.map((e) => e.name),
          newFileName: filename,
          keepPerPlatform: sanitizedBackupRetention(
            appdata.settings['webdavBackupRetention'],
          ),
        )) {
          try {
            await client.remove(stale);
          } catch (e) {
            // Cleanup is best-effort; the new backup is already safe.
            Log.warning("Upload Data", "Failed to prune backup $stale: $e");
          }
        }

        Log.info("Upload Data", "Data uploaded successfully");
        _addSyncLog('upload', filename, true, null);
        taskManager.completeTask(task.id, fileName: filename);
        _scheduleImageSync();
        return const Res(true);
      } catch (e, s) {
        // dataVersion is only adopted AFTER a successful publish, so a failure
        // here needs no version rollback — the local claim never moved.
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
    // Never apply a backup while heavy init is still bringing up the very
    // stores importAppData restores into — that race was the iOS startup
    // crash loop back when the import swapped files under live handles. The
    // restore now closes, swaps and reopens the files inside an exclusive
    // window, but it still requires initialized stores.
    // _runStartupDownload already waits, but downloads can also be reached
    // early via the #86 catch-up path (auto upload converted to download);
    // gate ALL of them here. Headless completes the completer right after its
    // own init, so CLI runs don't stall on the timeout. If the gate times out
    // we FAIL the download instead of proceeding; a later download retries.
    if (!deferredInitCompleter.isCompleted) {
      try {
        await deferredInitCompleter.future.timeout(const Duration(seconds: 60));
      } catch (_) {
        Log.warning(
          "Data Sync",
          "Deferred init not settled in time; refusing to apply a backup",
        );
        _lastError = 'App initialization not settled';
        return const Res.error('App initialization not settled');
      }
    }
    if (!coreDataStoresReady) {
      // The completer above only proves init finished ATTEMPTING. When a
      // component failed (a corrupt cookie.db once took the whole deferred
      // init down), applying a backup over uninitialized stores half-applies
      // data and storms LateInitializationErrors — refuse; the next launch
      // (with the store recovered) retries.
      Log.warning(
        "Data Sync",
        "Core data stores not ready; refusing to apply a backup",
      );
      _lastError = 'App initialization failed';
      return const Res.error('App initialization failed');
    }
    if (_haveWaitingTask) return const Res(true);
    // Also wait for image sync: applying a backup swaps local.db, which image
    // sync reads/writes (use-after-close otherwise). Image sync yields between
    // comics when it sees us waiting, so this wait is bounded.
    while (isDownloading || isUploading || isSyncingImages) {
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
        adapter: _syncAdapter(_syncRequestTimeout),
      );

      try {
        taskManager.updateTask(task.id, currentPhase: 'Checking', progress: 0.1);

        var files = await client.readDir('/');
        var file = _latestBackup(files, (e) => e.name);
        if (file == null) {
          // Empty server: nothing to pull, and there never will be until
          // someone uploads. Treating this as a failure used to deadlock a
          // brand-new fleet — the initial-sync flag stayed unset, which
          // blocked every upload ("complete initial sync first"), which meant
          // the server stayed empty forever. An empty server IS a completed
          // initial sync: this device holds the fleet's only data.
          _markInitialSyncCompleted();
          Log.info("Data Sync", 'No backups on server; initial sync complete');
          taskManager.completeTask(task.id);
          return const Res(true);
        }
        // Reconcile an unconfirmed upload (#133): when the newest backup on
        // the server is the very file this device PUT but never confirmed,
        // its content is our own PAST snapshot — current local data already
        // supersedes it. Adopt its version instead of downloading, which
        // would revert every read made since that export (and the follow-up
        // settle would re-upload the reverted state fleet-wide). When the
        // newest backup is anything else, the record is obsolete — the PUT
        // truly failed, or another device published since — so drop it and
        // sync normally.
        final claim = _pendingPublish;
        if (claim != null) {
          if (isOwnPendingPublish(
            claimedFileName: claim.fileName,
            claimedSize: claim.size,
            remoteFileName: file.name!,
            remoteSize: file.size,
          )) {
            final reclaimed = _versionOfFileName(file.name!);
            if (reclaimed > _dataVersion()) {
              appdata.settings['dataVersion'] = reclaimed;
              await appdata.saveData(false);
            }
            _clearPendingPublish();
            if (!_hasCompletedInitialSync()) {
              _markInitialSyncCompleted();
            }
            Log.info(
              "Data Sync",
              "Newest server backup is this device's own unconfirmed upload; "
                  "adopted v$reclaimed without downloading",
            );
            _addSyncLog('download', file.name, true, null);
            taskManager.completeTask(task.id, fileName: file.name);
            return const Res(true);
          }
          _clearPendingPublish();
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

          // applyBackup suppresses the echo: applying re-inits the favorites/
          // read-later/comic-source managers, whose notifyListeners used to
          // fire onDataChanged and re-upload the just-downloaded data 2s
          // later, one version higher — aligned devices ping-ponged forever.
          //
          // checkVersion is OFF on purpose. The filename gate above
          // (remoteVersion <= currentVersion => return) is the authoritative
          // "is this newer" test and already passed to get here; :764 below
          // then re-aligns our version to it. importAppData's own gate instead
          // compares the backup's INTERNAL syncdata.json dataVersion, which is
          // structurally one BELOW its filename: an auto-upload only runs when
          // the device is not behind (shouldSkipStaleUpload), so nextSyncVersion
          // == local+1 stamps the filename, while exportAppData wrote the zip
          // with the pre-bump `local` (the bump lands after — publish-first). So
          // content == filename-1 always. When the other device is exactly one
          // version ahead — the ordinary "changed once" case — that deflated
          // label equals ours, the internal gate returns, and the whole import
          // is skipped: the download logs success yet history/favorites/follow
          // marks never apply. Trusting the filename gate fixes it.
          await applyBackup(
            () => importAppData(
              localFile,
              checkVersion: false,
              restoreLocalComics: _syncLocalComics(),
            ),
          );
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

          // The backup replaced settings in place; rebuild the UI so imported
          // appearance changes (e.g. a non-default theme color) take effect now
          // instead of only after a restart (#87). Mirrors the file-import path.
          App.forceRebuild();

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
      var client = newClient(url, user: user, password: pass, adapter: _syncAdapter(_syncRequestTimeout));
      var files = await client.readDir('/');
      var file = _latestBackup(files, (e) => e.name);
      if (file == null) {
        // Empty server: this device's data is the fleet's only copy. Mark
        // initial sync complete so the first publish isn't gated, then upload.
        _markInitialSyncCompleted();
        return uploadData();
      }
      if (_versionOfFileName(file.name!) > _dataVersion()) {
        return downloadData();
      }
      return uploadData();
    } catch (e) {
      // Could not even LIST the server. Blindly falling back to an upload
      // here could push stale data whose staleness we failed to detect; the
      // in-upload guard re-reads the directory anyway, so if that read also
      // fails the upload fails too. Surface the error instead of pretending.
      Log.error("Data Sync", e);
      _lastError = e.toString();
      notifyListeners();
      return Res.error(e.toString());
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
      var client = newClient(url, user: user, password: pass, adapter: _syncAdapter(_syncRequestTimeout));
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

  /// Probes reachability + authentication of a WebDAV config without touching
  /// any local state. Takes the credentials explicitly so the settings form can
  /// verify values the user just typed but has not yet saved. A directory
  /// listing doubles as the probe: it needs a live connection AND valid
  /// credentials (401/403 surface as an error), which is exactly what we want to
  /// confirm before the user commits the config.
  Future<Res<bool>> testConnection({
    required String url,
    required String user,
    required String pass,
  }) async {
    url = url.trim();
    user = user.trim();
    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      return const Res.error('Invalid WebDAV configuration');
    }
    try {
      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: _syncAdapter(_syncRequestTimeout),
      );
      await client.readDir('/');
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> downloadSpecificBackup(String fileName) async {
    if (_haveWaitingTask) return const Res(true);
    // Waits for image sync too — the apply below swaps the very SQLite files
    // image sync reads/writes.
    while (isDownloading || isUploading || isSyncingImages) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null || config.isEmpty) {
        return const Res.error('Invalid WebDAV configuration');
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];
      var client = newClient(url, user: user, password: pass, adapter: _syncAdapter(_syncRequestTimeout));
      // User explicitly chose this backup to restore — always a real transfer, so
      // engage keep-alive across the download + apply.
      _refreshSyncKeepAlive(
        formatTaskStatus(title: 'Downloading data'.tl, detail: fileName),
      );
      try {
        var localFile = File(FilePath.join(App.cachePath, fileName));
        try {
          await client.read2File(fileName, localFile.path);
          // Suppress the echo upload the manager re-inits would fire.
          await applyBackup(
            () => importAppData(
              localFile,
              checkVersion: false,
              restoreLocalComics: _syncLocalComics(),
            ),
          );
        } finally {
          localFile.deleteIgnoreError();
        }

        // Restoring an old backup is an explicit "make this the state again".
        // The old approach claimed dataVersion = remoteMax + 1 locally WITHOUT
        // publishing a backup at that version — a phantom claim. When another
        // device later uploaded (legitimately) at that same number, this
        // device judged it "not newer" and skipped it, then steamrolled it on
        // its own next upload. Instead, publish the restored state as a real
        // new backup: uploadData stamps it above the server max and only
        // adopts the version after the write succeeds, so claim == published.
        // (importAppData -> appdata.syncData already max-merged dataVersion,
        // so a force upload here lands above everything on the server.)
        App.forceRebuild();

        if (!_hasCompletedInitialSync()) _markInitialSyncCompleted();
        _addSyncLog('download', fileName, true, null);

        // Release the download lock before the publish upload; uploadData
        // busy-waits on it otherwise.
        _isDownloading = false;
        unawaited(uploadData(force: true));

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

  /// Whether this device participates in local-comic-library (local.db) sync.
  /// Device-local (#145): a device with this off neither pushes its manifest
  /// nor restores an incoming one, so other devices' local comics don't appear
  /// here as download/import prompts — this device just reads/downloads online.
  /// Defaults on to preserve prior behavior.
  static bool _syncLocalComics() =>
      appdata.settings['syncLocalComics'] != false;

  bool _shouldSyncImages() {
    // Image packs are keyed to the local-comic manifest (local.db): a device
    // opted out of manifest sync (#145) has no entries to match packs against,
    // so uploading/downloading them is pointless. Gate on it too.
    return appdata.settings['syncLocalComicImages'] == true &&
        _syncLocalComics() &&
        isConfigured;
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
    // Mutual exclusion with data sync. Image packs read from and import into
    // local.db — running while downloadData's importAppData swaps that very
    // file was a use-after-close race. Wait without consuming the
    // _haveWaitingTask slot (that queue belongs to real data syncs); data
    // sync waits for us symmetrically via isSyncingImages in its wait loops.
    while (isDownloading || isUploading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_isSyncingImages) return;
    _isSyncingImages = true;
    notifyListeners();
    var failures = 0;
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
        adapter: _syncAdapter(_imageSyncRequestTimeout),
      );

      // Image-pack sync moves whole comic archives and is the longest-running,
      // most background-prone sync op — hold the process across backgrounding.
      _refreshSyncKeepAlive('Syncing images'.tl);
      await _ensureComicsDir(client);
      failures += await _uploadComicImages(client);
      failures += await _downloadComicImages(client);
      // Image sync used to be entirely invisible; record the pass so the
      // sync-log page reflects reality.
      _addSyncLog(
        'images',
        null,
        failures == 0,
        failures == 0 ? null : '$failures comic(s) failed',
      );
    } catch (e, s) {
      Log.error("Image Sync", e, s);
      _addSyncLog('images', null, false, e.toString());
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

  /// Uploads image packs for downloaded comics missing on the server.
  /// Returns the number of comics that failed.
  Future<int> _uploadComicImages(Client client) async {
    var comics = LocalManager().getComics(LocalSortType.defaultSort)
        .where((c) => c.status == LocalComicStatus.downloaded)
        .toList();
    if (comics.isEmpty) return 0;

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

    var failures = 0;
    for (var comic in comics) {
      var fileName = _imagePackFileName(comic);
      // Ids containing path separators can't map to a server file name; a raw
      // '/' both broke the dedup check (readDir returns basenames) and made
      // every pass re-export and re-upload the pack forever.
      if (fileName == null) continue;
      if (remoteFiles.contains(fileName)) continue;
      // A data sync wants the lock — finish this comic's turn and yield; the
      // rescheduled pass will pick up where we left off.
      if (_haveWaitingTask) break;

      File? file;
      try {
        file = await exportVeneraComics([comic], includeImages: true);
        // Streamed: image packs are whole comic archives (often hundreds of
        // MB) — buffering one in RAM via readAsBytes was an OOM in waiting.
        await client.writeFromFile(file.path, '/venera-comics/$fileName');
        Log.info("Image Sync", "Uploaded: ${comic.title}");
      } catch (e, s) {
        failures++;
        Log.error(
          "Image Sync", "Failed to upload ${comic.title}: $e", s);
      } finally {
        file?.deleteIgnoreError();
      }
    }
    return failures;
  }

  /// Server file name for a comic's image pack, or null when the id cannot be
  /// safely embedded in a single path segment.
  String? _imagePackFileName(LocalComic comic) {
    var id = comic.id;
    if (id.contains('/') || id.contains('\\')) return null;
    return '${id}_${comic.comicType.value}.venera_comics';
  }

  /// Downloads image packs for comics known but not downloaded locally.
  /// Returns the number of comics that failed.
  Future<int> _downloadComicImages(Client client) async {
    var comics = LocalManager().getComics(LocalSortType.defaultSort)
        .where((c) => c.status == LocalComicStatus.notDownloaded)
        .toList();
    if (comics.isEmpty) return 0;

    List<String> remoteFiles;
    try {
      var files = await client.readDir('/venera-comics/');
      remoteFiles = files
          .map((f) => f.name ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return 0;
    }

    var failures = 0;
    for (var comic in comics) {
      var fileName = _imagePackFileName(comic);
      if (fileName == null) continue;
      if (!remoteFiles.contains(fileName)) continue;
      if (_haveWaitingTask) break;

      var localFile = File(FilePath.join(App.cachePath, fileName));
      try {
        await client.read2File(
          '/venera-comics/$fileName', localFile.path);
        await importVeneraComics(localFile);
        Log.info("Image Sync", "Downloaded: ${comic.title}");
      } catch (e, s) {
        failures++;
        Log.error(
          "Image Sync", "Failed to download ${comic.title}: $e", s);
      } finally {
        // Delete on failure too — a mid-transfer abort used to leak the
        // partial archive in cache.
        localFile.deleteIgnoreError();
      }
    }
    return failures;
  }
}

