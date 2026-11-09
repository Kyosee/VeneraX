import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/sqlite_connection.dart';

const _folder = 'Tags';
const _tags = [
  '测试',
  '含,逗号',
  'unicode-漫画',
  "artist's tag",
  '[brackets]',
  'quote" and \\slash',
  'line\nbreak',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = LocalFavoritesManager();
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('venera-favorite-tags-');
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await appdata.init();
    await manager.init();
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    await DatabaseGateway.instance.runExclusive(() async {});
    manager.close();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    await directory.delete(recursive: true);
  });

  setUp(() {
    if (manager.existsFolder(_folder)) manager.deleteFolder(_folder);
    manager.createFolder(_folder);
  });

  FavoriteItem favorite({
    String id = 'comic',
    ComicType type = ComicType.local,
    List<String> tags = const ['original'],
  }) => FavoriteItem(
    id: id,
    name: 'Comic',
    author: 'Author',
    coverPath: '',
    type: type,
    tags: tags,
  );

  void setStoredTags(
    String id,
    Object? tags, [
    ComicType type = ComicType.local,
  ]) {
    final db = openRawDatabase('${directory.path}/local_favorite.db');
    try {
      db.execute('UPDATE "$_folder" SET tags = ? WHERE id = ? AND type = ?;', [
        tags,
        id,
        type.value,
      ]);
    } finally {
      db.dispose();
    }
  }

  Object? storedTags(String id) {
    final db = openRawDatabase('${directory.path}/local_favorite.db');
    try {
      return db.select('SELECT tags FROM "$_folder" WHERE id = ?;', [
        id,
      ]).single['tags'];
    } finally {
      db.dispose();
    }
  }

  test('addComic preserves tags exactly across database reopen', () async {
    expect(manager.addComic(_folder, favorite(tags: _tags)), isTrue);
    expect(manager.getComic(_folder, 'comic', ComicType.local).tags, _tags);
    manager.close();
    await manager.init();
    expect(manager.getComic(_folder, 'comic', ComicType.local).tags, _tags);
  });

  test('editTags preserves commas and can clear the tag list', () {
    manager.addComic(_folder, favorite());
    manager.editTags('comic', _folder, _tags);
    expect(manager.getComic(_folder, 'comic', ComicType.local).tags, _tags);
    manager.editTags('comic', _folder, []);
    expect(manager.getComic(_folder, 'comic', ComicType.local).tags, isEmpty);
  });

  test('updateInfo preserves the exact replacement tags', () {
    manager.addComic(_folder, favorite());
    final changed = favorite(tags: _tags)..name = 'Updated comic';
    manager.updateInfo(_folder, changed, true, false);
    final restored = manager.getComic(_folder, 'comic', ComicType.local);
    expect(restored.name, 'Updated comic');
    expect(restored.tags, _tags);
  });

  test('addTagTo preserves existing JSON tags and literal quotes', () {
    manager.addComic(_folder, favorite());
    setStoredTags('comic', jsonEncode(_tags));
    const added = "creator's, new tag";
    manager.addTagTo(_folder, 'comic', added);
    expect(manager.getComic(_folder, 'comic', ComicType.local).tags, [
      added,
      ..._tags,
    ]);
  });

  test(
    'addTagTo retains distinct rows with the same id and reads legacy tags',
    () {
      const otherType = ComicType(123);
      manager.addComic(_folder, favorite());
      manager.addComic(_folder, favorite(type: otherType));
      manager.addComic(_folder, favorite(id: 'other'));
      setStoredTags('comic', 'old-one,old-two');
      setStoredTags('comic', 'different', otherType);
      manager.addTagTo(_folder, 'comic', '含,逗号');
      expect(manager.getComic(_folder, 'comic', ComicType.local).tags, [
        '含,逗号',
        'old-one',
        'old-two',
      ]);
      expect(manager.getComic(_folder, 'comic', otherType).tags, [
        '含,逗号',
        'different',
      ]);
      expect(manager.getComic(_folder, 'other', ComicType.local).tags, [
        'original',
      ]);
    },
  );

  test(
    'legacy comma rows, null and empty tags remain readable without migration',
    () async {
      const legacy = {
        'comma': 'old-one,,old-two,unicode-漫画',
        'empty': '',
        'null': null,
      };
      for (final entry in legacy.entries) {
        manager.addComic(_folder, favorite(id: entry.key));
        setStoredTags(entry.key, entry.value);
      }
      manager.close();
      await manager.init();
      expect(manager.getComic(_folder, 'comma', ComicType.local).tags, [
        'old-one',
        'old-two',
        'unicode-漫画',
      ]);
      for (final id in ['empty', 'null']) {
        expect(manager.getComic(_folder, id, ComicType.local).tags, isEmpty);
      }
      for (final entry in legacy.entries) {
        expect(storedTags(entry.key), entry.value);
      }
    },
  );
}
