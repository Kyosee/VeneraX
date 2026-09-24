import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const setting = ChapterOrderPrefs.settingKey;
  const chapters = ComicChapters({'a': 'One', 'c': 'Three', 'b': 'Two'});
  const source = 'test-source';
  late Directory directory;
  late String originalPath;
  late Map<String, dynamic> originalSettings;
  late List<String> originalHistory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-chapter-order-');
    originalPath = App.dataPath;
    originalSettings = {
      for (final key in [setting, 'webdav', 'disableSyncFields', 'dataVersion'])
        key: appdata.settings[key],
    };
    originalHistory = List.of(appdata.searchHistory);
    App.dataPath = directory.path;
    appdata.settings[setting] = <String, dynamic>{};
    appdata.settings['webdav'] = <String>[];
    appdata.settings['disableSyncFields'] = '';
  });

  tearDown(() async {
    // Drain syncData's asynchronous snapshot write before removing its folder.
    App.dataPath = directory.path;
    await appdata.saveData(false);
    for (final entry in originalSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    appdata.searchHistory = originalHistory;
    App.dataPath = originalPath;
    await directory.delete(recursive: true);
  });

  Future<Map<String, dynamic>> snapshot(String name) async =>
      Map<String, dynamic>.from(
        jsonDecode(await File('${directory.path}/$name.json').readAsString()),
      );

  test('custom order keeps original chapter IDs and indices', () async {
    expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
      0,
      1,
      2,
    ]);
    await ChapterOrderPrefs.save(chapters, 'comic', source, [0, 2, 1]);

    final order = ChapterOrderPrefs.orderedIndices(chapters, 'comic', source);
    expect(order, [0, 2, 1]);
    expect(order.map((i) => chapters.titles.elementAt(i)), [
      'One',
      'Two',
      'Three',
    ]);
    expect(chapters.ids, ['a', 'c', 'b']);
    expect(chapters.toJson(), {'a': 'One', 'c': 'Three', 'b': 'Two'});
    expect(ChapterOrderPrefs.hasCustomOrder(chapters, 'comic', source), isTrue);
    expect(ChapterOrderPrefs.orderedIndices(chapters, 'other', source), [
      0,
      1,
      2,
    ]);
    expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', 'other'), [
      0,
      1,
      2,
    ]);
  });

  test(
    'source refresh follows IDs, ignores removals and appends new chapters',
    () async {
      await ChapterOrderPrefs.save(chapters, 'comic', source, [0, 2, 1]);
      const updated = ComicChapters({
        'new': 'Four',
        'b': 'Two renamed',
        'a': 'One renamed',
      });
      expect(ChapterOrderPrefs.orderedIndices(updated, 'comic', source), [
        2,
        1,
        0,
      ]);
    },
  );

  test('groups keep separate orders even when chapter IDs overlap', () async {
    const grouped = ComicChapters.grouped({
      'English': {'a': 'One', 'c': 'Three', 'b': 'Two'},
      'Chinese': {'a': '一', 'b': '二'},
    });
    await ChapterOrderPrefs.save(grouped, 'comic', source, [0, 2, 1, 4, 3]);
    expect(ChapterOrderPrefs.orderedIndices(grouped, 'comic', source), [
      0,
      2,
      1,
      4,
      3,
    ]);
    expect(
      ChapterOrderPrefs.orderedIndicesForGroup(grouped, 'comic', source, 0),
      [0, 2, 1],
    );
    expect(
      ChapterOrderPrefs.orderedIndicesForGroup(grouped, 'comic', source, 1),
      [1, 0],
    );
    const refreshed = ComicChapters.grouped({
      'Chinese': {'a': '一', 'b': '二'},
      'English': {'b': 'Two', 'a': 'One', 'c': 'Three'},
    });
    expect(ChapterOrderPrefs.orderedIndices(refreshed, 'comic', source), [
      1,
      0,
      3,
      2,
      4,
    ]);
    expect(
      ChapterOrderPrefs.orderedIndicesForGroup(grouped, 'comic', source, -1),
      isEmpty,
    );
    expect(
      ChapterOrderPrefs.orderedIndicesForGroup(grouped, 'comic', source, 2),
      isEmpty,
    );
  });

  test(
    'malformed preferences fall back safely and duplicate IDs are ignored',
    () {
      for (final value in [
        null,
        'invalid',
        42,
        [],
        {'comic@$source': false},
      ]) {
        appdata.settings[setting] = value;
        expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
          0,
          1,
          2,
        ]);
      }
      appdata.settings[setting] = {
        'comic@$source': ['b', 'b', null, {}, 1, 'missing', 'a'],
      };
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        2,
        0,
        1,
      ]);
    },
  );

  test(
    'saving sanitizes invalid indices and reset affects only this comic',
    () async {
      await ChapterOrderPrefs.save(chapters, 'comic', source, [2, 2, -1, 99]);
      await ChapterOrderPrefs.save(chapters, 'other', source, [1, 0, 2]);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        2,
        0,
        1,
      ]);
      await ChapterOrderPrefs.reset('comic', source);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        0,
        1,
        2,
      ]);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'other', source), [
        1,
        0,
        2,
      ]);
      await ChapterOrderPrefs.save(chapters, 'other', source, [0, 1, 2]);
      expect(appdata.settings[setting], isEmpty);
    },
  );

  test('grouped save cannot move chapters across group boundaries', () async {
    const grouped = ComicChapters.grouped({
      'A': {'a': 'One', 'b': 'Two'},
      'B': {'c': 'Three', 'd': 'Four'},
    });
    await ChapterOrderPrefs.save(grouped, 'comic', source, [3, 1, 0, 2, 1, 99]);
    expect(ChapterOrderPrefs.orderedIndices(grouped, 'comic', source), [
      1,
      0,
      3,
      2,
    ]);
    await ChapterOrderPrefs.save(grouped, 'comic', source, [0, 1, 2, 3]);
    expect(appdata.settings[setting], isEmpty);
  });

  test(
    'WebDAV comics persist and restore order through the sync snapshot',
    () async {
      const webdav = ComicChapters({
        '/book/1/': 'One',
        '/book/3/': 'Three',
        '/book/2/': 'Two',
      });
      const library = 'webdav_library_test';
      await ChapterOrderPrefs.save(webdav, '/book/', library, [0, 2, 1]);
      for (final name in ['appdata', 'syncdata']) {
        final data = await snapshot(name);
        expect(data['settings'][setting], {
          '/book/@$library': ['/book/1/', '/book/2/', '/book/3/'],
        });
      }
      final remote = await snapshot('syncdata');
      appdata.settings[setting] = {};
      appdata.syncData(remote);
      await appdata.saveData(false);
      expect(ChapterOrderPrefs.orderedIndices(webdav, '/book/', library), [
        0,
        2,
        1,
      ]);
      expect(
        ChapterOrderPrefs.orderedIndices(
          webdav,
          '/book/',
          'webdav_library_other',
        ),
        [0, 1, 2],
      );
    },
  );

  test(
    'old snapshots preserve order while an explicit synced reset clears it',
    () async {
      await ChapterOrderPrefs.save(chapters, 'comic', source, [2, 0, 1]);
      appdata.syncData({
        'settings': {'dataVersion': 1},
      });
      await appdata.saveData(false);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        2,
        0,
        1,
      ]);
      await ChapterOrderPrefs.reset('comic', source);
      final reset = await snapshot('syncdata');
      await ChapterOrderPrefs.save(chapters, 'comic', source, [2, 0, 1]);
      appdata.syncData(reset);
      await appdata.saveData(false);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        0,
        1,
        2,
      ]);
    },
  );

  test(
    'the explicit sync exclusion applies on both upload and restore',
    () async {
      appdata.settings['disableSyncFields'] = setting;
      await ChapterOrderPrefs.save(chapters, 'comic', source, [2, 0, 1]);
      final local = await snapshot('appdata');
      final remote = await snapshot('syncdata');
      expect(local['settings'].containsKey(setting), isTrue);
      expect(remote['settings'].containsKey(setting), isFalse);
      appdata.syncData({
        'settings': {setting: {}},
      });
      await appdata.saveData(false);
      expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
        2,
        0,
        1,
      ]);
    },
  );

  test('failed persistence keeps the previously saved order', () async {
    await ChapterOrderPrefs.save(chapters, 'comic', source, [2, 0, 1]);
    final blocked = File('${directory.path}/blocked');
    await blocked.writeAsString('not a directory');
    App.dataPath = blocked.path;
    await expectLater(
      ChapterOrderPrefs.save(chapters, 'comic', source, [0, 2, 1]),
      throwsA(isA<FileSystemException>()),
    );
    expect(ChapterOrderPrefs.orderedIndices(chapters, 'comic', source), [
      2,
      0,
      1,
    ]);
  });

  group('navigation in custom order', () {
    int? next(int from, int step, {Set<int> hidden = const {}}) =>
        nextVisibleChapter(
          from: from,
          step: step,
          maxChapter: 5,
          order: const [3, 1, 5, 2, 4],
          isHidden: hidden.contains,
          groupOf: (_) => 0,
        );

    test(
      'follows the whole sequence in both directions and stops at its ends',
      () {
        final forward = <int>[];
        for (int? c = 3; c != null; c = next(c, 1)) {
          forward.add(c);
        }
        final backward = <int>[];
        for (int? c = 4; c != null; c = next(c, -1)) {
          backward.add(c);
        }
        expect(forward, [3, 1, 5, 2, 4]);
        expect(backward, [4, 2, 5, 1, 3]);
        expect(next(1, 0), isNull);
        expect(next(99, 1), isNull);
      },
    );

    test(
      'skips hidden chapters without changing the identity of the target',
      () {
        expect(next(1, 1, hidden: {5, 2}), 4);
        expect(next(4, -1, hidden: {5, 2}), 1);
        expect(next(5, 1, hidden: {5}), 2);
        expect(next(1, -1, hidden: {3}), isNull);
      },
    );

    test(
      'group boundaries follow reordered positions and retain the skip guard',
      () {
        int? grouped(int from, int step, Set<int> hidden) => nextVisibleChapter(
          from: from,
          step: step,
          maxChapter: 6,
          order: const [3, 1, 2, 5, 4, 6],
          isHidden: hidden.contains,
          groupOf: (c) => c <= 3 ? 0 : 1,
        );
        expect(grouped(2, 1, {}), 5);
        expect(grouped(5, -1, {}), 2);
        expect(grouped(3, 1, {1}), 2);
        expect(grouped(2, 1, {5}), isNull);
        expect(grouped(1, 1, {2}), isNull);
        expect(grouped(6, -1, {4}), 5);
      },
    );
  });
}
