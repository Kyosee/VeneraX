import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  late Directory tempDir;
  late String originalDataPath;
  late Map<String, dynamic> originalSettings;
  late List<String> originalSearchHistory;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-backup-settings-');
    originalDataPath = App.dataPath;
    originalSettings = {
      'webdavUseProxy': appdata.settings['webdavUseProxy'],
      'webdavBackupRetention': appdata.settings['webdavBackupRetention'],
      'disableSyncFields': appdata.settings['disableSyncFields'],
      'dataVersion': appdata.settings['dataVersion'],
    };
    originalSearchHistory = List<String>.from(appdata.searchHistory);
    App.dataPath = tempDir.path;
    appdata.settings['disableSyncFields'] = '';
  });

  tearDown(() async {
    for (final entry in originalSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    appdata.searchHistory = originalSearchHistory;
    App.dataPath = originalDataPath;
    await tempDir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> readSnapshot(String name) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    return Map<String, dynamic>.from(jsonDecode(await file.readAsString()));
  }

  test('writes WebDAV backup settings to local and sync snapshots', () async {
    appdata.settings['webdavUseProxy'] = false;
    appdata.settings['webdavBackupRetention'] = 20;

    await appdata.saveData(false);

    for (final name in ['appdata.json', 'syncdata.json']) {
      final snapshot = await readSnapshot(name);
      final settings = Map<String, dynamic>.from(snapshot['settings'] as Map);
      expect(settings['webdavUseProxy'], isFalse);
      expect(settings['webdavBackupRetention'], 20);
    }
  });

  test('restores WebDAV backup settings from synced data', () async {
    appdata.settings['webdavUseProxy'] = true;
    appdata.settings['webdavBackupRetention'] = 10;

    appdata.syncData({
      'settings': {
        'webdavUseProxy': false,
        'webdavBackupRetention': 20,
        'dataVersion': 1,
      },
      'searchHistory': <String>[],
    });
    await appdata.saveData(false);

    expect(appdata.settings['webdavUseProxy'], isFalse);
    expect(appdata.settings['webdavBackupRetention'], 20);
  });

  test('keeps current values when an old backup omits the fields', () async {
    appdata.settings['webdavUseProxy'] = false;
    appdata.settings['webdavBackupRetention'] = 20;

    appdata.syncData({
      'settings': {'dataVersion': 1},
      'searchHistory': <String>[],
    });
    await appdata.saveData(false);

    expect(appdata.settings['webdavUseProxy'], isFalse);
    expect(appdata.settings['webdavBackupRetention'], 20);
  });
}
