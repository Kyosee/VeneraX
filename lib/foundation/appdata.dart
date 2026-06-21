import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  bool _isSavingData = false;

  Future<void> saveData([bool sync = true]) async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var futures = <Future>[];
      var json = toJson();
      var data = jsonEncode(json);
      var file = File(FilePath.join(App.dataPath, 'appdata.json'));
      futures.add(file.writeAsString(data));

      var disableSyncFields = json["settings"]["disableSyncFields"] as String;
      if (disableSyncFields.isNotEmpty) {
        var json4sync = jsonDecode(data);
        List<String> customDisableSync = splitField(disableSyncFields);
        for (var field in customDisableSync) {
          json4sync["settings"].remove(field);
        }
        var data4sync = jsonEncode(json4sync);
        var file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
        futures.add(file4sync.writeAsString(data4sync));
      }

      await Future.wait(futures);
    } finally {
      _isSavingData = false;
    }
    if (sync) {
      DataSync().uploadData();
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  static const sourceTypeRegistryKey = 'sourceTypeRegistry';

  static const syncImplicitDataKeys = [
    'follow_update_task_history',
    sourceTypeRegistryKey,
  ];

  Map<String, dynamic> implicitDataForSync() {
    return {
      for (final key in syncImplicitDataKeys)
        if (implicitData.containsKey(key)) key: implicitData[key],
    };
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
    "followUpdatesFolder",
    "syncLocalComicImages",
    // Per-source origin/offering provenance is device-local: originId reflects
    // where THIS device installed each source, and libraryIds/updateLibraryId
    // are rebuilt from the library list on every update check. Syncing it
    // whole-blob would let one device's map overwrite another's non-derivable
    // originId. The library list itself (comicSourceLibraries) still syncs.
    "comicSourceProvenance",
  ];

  /// Sync data from another device.
  ///
  /// This is the "apply remote data locally" path (download / import), so it
  /// must NOT trigger an upload afterwards — doing so would push the
  /// just-downloaded (and possibly stale) data straight back to the server.
  /// Hence the final [saveData] is called with `sync: false`.
  void syncData(Map<String, dynamic> data) {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"] as String,
      );

      int localDataVersion = _asVersion(this.settings['dataVersion']);

      for (var key in settings.keys) {
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }

      // Never let an imported/older backup pull the local version backwards.
      // If a restore wrote a lower dataVersion, this device would look "behind"
      // the server and get overwritten by stale remote data on the next sync.
      int incomingDataVersion = _asVersion(settings['dataVersion']);
      this.settings['dataVersion'] =
          localDataVersion > incomingDataVersion
              ? localDataVersion
              : incomingDataVersion;
    }
    searchHistory = List.from(data['searchHistory'] ?? []);
    var implicitDataChanged = false;
    final syncedImplicitData = data['implicitData'];
    if (syncedImplicitData is Map) {
      for (final key in syncImplicitDataKeys) {
        if (syncedImplicitData.containsKey(key)) {
          implicitData[key] = syncedImplicitData[key];
          implicitDataChanged = true;
        }
      }
    }
    if (implicitDataChanged) {
      writeImplicitData();
    }
    saveData(false);
  }

  static int _asVersion(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  var implicitData = <String, dynamic>{};

  /// Loads the learned `legacyIntType -> sourceKey` registry into the resolver
  /// and wires the persistence hook so future learned mappings are saved. The
  /// registry lives in [implicitData] (per-device, synced with backups), which
  /// replaces the old hardcoded source-key table.
  void _initSourceTypeRegistry() {
    final stored = implicitData[sourceTypeRegistryKey];
    if (stored is Map) {
      final restored = <int, String>{};
      for (final entry in stored.entries) {
        final intKey = int.tryParse(entry.key.toString());
        final sourceKey = entry.value?.toString();
        if (intKey != null && sourceKey != null && sourceKey.isNotEmpty) {
          restored[intKey] = sourceKey;
        }
      }
      // Restore without triggering the persistence hook (not yet attached).
      SourcePlatformResolver.registerLegacyIntSourceKeys(restored);
    }
    SourcePlatformResolver.onLegacyKeyLearned = (legacyIntType, sourceKey) {
      final registry = (implicitData[sourceTypeRegistryKey] as Map?) ?? {};
      final stringKey = legacyIntType.toString();
      if (registry[stringKey] == sourceKey) {
        return;
      }
      registry[stringKey] = sourceKey;
      implicitData[sourceTypeRegistryKey] = registry;
      writeImplicitData();
    };
  }

  void writeImplicitData() async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
      await file.writeAsString(jsonEncode(implicitData));
    } finally {
      _isSavingData = false;
    }
  }

  @override
  Future<void> doInit() async {
    var dataPath = App.dataPath;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    try {
      var json = jsonDecode(await file.readAsString());
      for (var key in (json['settings'] as Map<String, dynamic>).keys) {
        if (json['settings'][key] != null) {
          settings[key] = json['settings'][key];
        }
      }
      searchHistory = List.from(json['searchHistory']);
    } catch (e) {
      Log.error("Appdata", "Failed to load appdata", e);
      Log.info("Appdata", "Resetting appdata");
      file.deleteIgnoreError();
    }
    if ((settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = jsonDecode(await implicitDataFile.readAsString());
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
    _initSourceTypeRegistry();
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'showReadLaterStatusOnTile': true,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'enableContinuousChapterReading': true,
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'minimizeToTray': false, // Windows 关闭窗口时最小化到系统托盘
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': true,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'autoFavoriteCover': false, // 收藏图片时是否自动连带收藏该章节封面
    'authorizationRequired': false,
    'requireDisclaimerConsent': false,
    'disclaimerConsented': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': _defaultSourceListUrl,
    'comicSourceLibraries': [],
    'comicSourceProvenance': <String, dynamic>{},
    'comicSourceLibrariesMigrated': false,
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'galleryFillScreen':
        false, // when true, gallery mode uses BoxFit.cover instead of contain
    'readerBackgroundColor':
        'system', // system, white, gray, black, sepia, green
    'readerNightMode': false, // warm dimming overlay for night reading
    'readerNightModeFollowSystem':
        false, // auto-toggle night mode with system dark mode
    'readerNightModeColor': 'warm', // overlay tint: warm, black, red
    'readerNightModeIntensity': 0.45, // overlay opacity, 0.1 - 0.85
    'enableReaderImageEnhance': false, // GPU render-time image sharpening in reader
    'readerImageEnhanceStrength': 0.5, // unsharp mask strength
    'readerImageEnhanceClarity': 0.0, // 0.0 - 1.0 mid-radius local contrast
    'readerImageEnhanceContrast': 0.0, // 0.0 - 1.0 level-stretch amount
    'readerImageEnhanceVibrance': 0.0, // 0.0 - 1.0 colour-page saturation lift
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

const _defaultSourceListUrl = "";
