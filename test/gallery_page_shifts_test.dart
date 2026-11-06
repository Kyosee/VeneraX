import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/gallery_page_shifts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const setting = GalleryPageShifts.settingKey;
  const source = 'test-source';
  late Directory directory;
  late String originalPath;
  late Map<String, dynamic> originalSettings;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-page-shifts-');
    originalPath = App.dataPath;
    originalSettings = {
      for (final key in [setting, 'webdav', 'disableSyncFields', 'dataVersion'])
        key: appdata.settings[key],
    };
    App.dataPath = directory.path;
    appdata.settings[setting] = <String, dynamic>{};
    appdata.settings['webdav'] = <String>[];
    appdata.settings['disableSyncFields'] = '';
  });

  tearDown(() async {
    App.dataPath = directory.path;
    await appdata.saveData(false);
    for (final entry in originalSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    App.dataPath = originalPath;
    await directory.delete(recursive: true);
  });

  test('shifts are kept per chapter and per comic', () async {
    expect(GalleryPageShifts.load('comic', source, 'ep1'), isEmpty);
    await GalleryPageShifts.save('comic', source, 'ep1', {9, 3});
    await GalleryPageShifts.save('comic', source, 'ep2', {5});

    expect(GalleryPageShifts.load('comic', source, 'ep1'), {3, 9});
    expect(GalleryPageShifts.load('comic', source, 'ep2'), {5});
    expect(GalleryPageShifts.load('other', source, 'ep1'), isEmpty);
    expect(GalleryPageShifts.load('comic', 'elsewhere', 'ep1'), isEmpty);

    final saved = jsonDecode(
      await File('${directory.path}/appdata.json').readAsString(),
    );
    expect(saved['settings'][setting], {
      'comic@$source': {
        'ep1': [3, 9],
        'ep2': [5],
      },
    });
  });

  test('clearing the last shift removes the entries', () async {
    await GalleryPageShifts.save('comic', source, 'ep1', {3});
    await GalleryPageShifts.save('comic', source, 'ep2', {5});
    await GalleryPageShifts.save('comic', source, 'ep1', {});
    expect(appdata.settings[setting], {
      'comic@$source': {
        'ep2': [5],
      },
    });
    await GalleryPageShifts.save('comic', source, 'ep2', {});
    expect(appdata.settings[setting], isEmpty);
  });

  test('malformed stored values are ignored', () {
    appdata.settings[setting] = {
      'comic@$source': {
        'ep1': [2, 'x', 4.5, 7],
        'ep2': 'not a list',
      },
      'broken@$source': 'not a map',
    };
    expect(GalleryPageShifts.load('comic', source, 'ep1'), {2, 7});
    expect(GalleryPageShifts.load('comic', source, 'ep2'), isEmpty);
    expect(GalleryPageShifts.load('broken', source, 'ep1'), isEmpty);
    appdata.settings[setting] = 'not a map';
    expect(GalleryPageShifts.load('comic', source, 'ep1'), isEmpty);
  });
}
