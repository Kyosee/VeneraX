import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

const _type = ComicType(1);

History _history(String id, {int time = 1000, String cover = 'c.jpg'}) =>
    History.fromMap({
      'id': id,
      'type': 1,
      'title': 't-$id',
      'subtitle': '',
      'cover': cover,
      'time': time,
      'ep': 3,
      'page': 42,
      'readEpisode': '1,2',
      'max_page': 100,
    });

void main() {
  final manager = HistoryManager();
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;

  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  setUp(() async {
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    directory = Directory.systemTemp.createTempSync(
      'venera-history-visibility-',
    );
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    appdata.implicitData['image_favorites_cache_key_fix_v1'] = true;
    await manager.init();
  });

  tearDown(() {
    manager.close();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    directory.deleteSync(recursive: true);
  });

  test('maintenance write on a hidden row leaves it hidden', () {
    manager.addHistory(_history('a'));
    manager.hide('a', _type);

    manager.updateHistoryKeepingVisibility(
      _history('a', cover: 'https://example.test/new.jpg'),
    );

    expect(manager.getAll(), isEmpty);
    expect(manager.find('a', _type)!.cover, 'https://example.test/new.jpg');
    expect(manager.find('a', _type)!.page, 42);
    expect(manager.find('a', _type)!.readEpisode, {'1', '2'});
  });

  test('repeated maintenance writes keep it hidden', () {
    manager.addHistory(_history('a'));
    manager.hide('a', _type);

    for (var i = 0; i < 4; i++) {
      manager.updateHistoryKeepingVisibility(
        _history('a', cover: 'https://example.test/$i.jpg'),
      );
    }

    expect(manager.getAll(), isEmpty);
  });

  test('maintenance write on a visible row leaves it visible', () {
    manager.addHistory(_history('a'));

    manager.updateHistoryKeepingVisibility(
      _history('a', cover: 'https://example.test/new.jpg'),
    );

    expect(manager.getAll(), hasLength(1));
    expect(manager.find('a', _type)!.cover, 'https://example.test/new.jpg');
  });

  test('maintenance cannot create a missing history record', () {
    manager.updateHistoryKeepingVisibility(_history('fresh'));

    expect(manager.getAll(), isEmpty);
    expect(manager.find('fresh', _type), isNull);
  });

  test(
    'maintenance persists remapped local reading state without unhiding',
    () async {
      manager.addHistory(_history('a'));
      manager.hide('a', _type);
      final remapped = _history('a')
        ..ep = 1
        ..page = 7
        ..group = 2
        ..readEpisode = {'2-1'};

      manager.updateHistoryKeepingVisibility(remapped);
      manager.close();
      await manager.init();

      expect(manager.getAll(), isEmpty);
      final saved = manager.find('a', _type)!;
      expect(saved.ep, 1);
      expect(saved.page, 7);
      expect(saved.group, 2);
      expect(saved.readEpisode, {'2-1'});
    },
  );

  test('reading still unhides after maintenance', () {
    manager.addHistory(_history('a'));
    manager.hide('a', _type);
    manager.updateHistoryKeepingVisibility(_history('a'));

    manager.addHistory(_history('a', time: 2000));

    expect(manager.getAll(), hasLength(1));
  });

  test('maintenance touches only the addressed comic and source', () {
    manager.addHistory(_history('a'));
    manager.addHistory(_history('b'));
    manager.addHistory(_history('a')..type = const ComicType(2));
    manager.hide('a', _type);

    manager.updateHistoryKeepingVisibility(
      _history('a', cover: 'https://example.test/new.jpg'),
    );

    expect(manager.getAll(), hasLength(2));
    expect(manager.find('b', _type)!.cover, 'c.jpg');
    expect(manager.find('a', const ComicType(2))!.cover, 'c.jpg');
  });
}
