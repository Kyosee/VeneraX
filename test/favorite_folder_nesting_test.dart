import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;
  var backups = 0;
  final manager = LocalFavoritesManager();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    directory = Directory.systemTemp.createTempSync('venera-folder-nesting-');
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await appdata.init();
    await manager.init();
  });

  tearDownAll(() async {
    await DatabaseGateway.instance.runExclusive(() async {});
    manager.close();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    directory.deleteSync(recursive: true);
  });

  setUp(() {
    for (final folder in manager.folderNames) {
      if (manager.existsFolder(folder)) manager.deleteFolder(folder);
    }
  });

  /// A favorites database as an older version writes it: folder tables in
  /// their oldest shape, folder_order, and a layout table only if [links] is
  /// given.
  String backup(
    Map<String, int> folders, {
    Map<String, String>? links,
    List<String> order = const [],
  }) {
    final path = '${directory.path}/backup_${backups++}.db';
    final db = sqlite3.open(path);
    try {
      db.execute('create table folder_order '
          '(folder_name text primary key, order_value int);');
      db.execute('create table folder_sync '
          '(folder_name text primary key, source_key text, source_folder text);');
      for (final MapEntry(key: name, value: comics) in folders.entries) {
        db.execute('create table "$name" (id text, name TEXT, author TEXT, '
            'type int, tags TEXT, cover_path TEXT, time TEXT, '
            'primary key (id, type));');
        for (var i = 0; i < comics; i++) {
          db.execute(
            'insert into "$name" values (?, ?, ?, ?, ?, ?, ?);',
            ['$name-$i', 'Comic $i', '', 0, '', '', '2026-01-01 00:00:00'],
          );
        }
      }
      for (var i = 0; i < order.length; i++) {
        db.execute('insert into folder_order values (?, ?);', [order[i], i]);
      }
      if (links != null) {
        db.execute('create table folder_tree '
            '(folder_name text primary key, parent text);');
        for (final e in links.entries) {
          db.execute('insert into folder_tree values (?, ?);', [e.key, e.value]);
        }
      }
    } finally {
      db.dispose();
    }
    return path;
  }

  Future<void> restore(String path) => DatabaseGateway.instance.runExclusive(
    () => manager.restoreFrom(path),
  );

  /// The folder list a version without nesting shows: folder_order alone.
  Future<List<String>> flatOrder() {
    return DatabaseGateway.instance.runExclusive(() async {
      final db = sqlite3.open(
        '${App.dataPath}/local_favorite.db',
        mode: OpenMode.readOnly,
      );
      try {
        return db
            .select('select folder_name from folder_order order by order_value;')
            .map((r) => r['folder_name'] as String)
            .where(manager.existsFolder)
            .toList();
      } finally {
        db.dispose();
      }
    });
  }

  test('a new folder goes after the existing ones', () async {
    manager.createFolder('A');
    manager.createFolder('B');
    manager.reorderFolders(null, ['B', 'A']);
    manager.createFolder('C');
    expect(manager.folderNames, ['B', 'A', 'C']);
    expect(await flatOrder(), ['B', 'A', 'C']);
  });

  test('moving nests a folder and keeps the flat order parent-first', () async {
    for (final f in ['A', 'B', 'C']) {
      manager.createFolder(f);
    }
    manager.moveFolder('C', 'A');
    expect(manager.folderNames, ['A', 'C', 'B']);
    expect(manager.folderTree.parentOf('C'), 'A');
    expect(await flatOrder(), ['A', 'C', 'B']);
    manager.moveFolder('C', null);
    expect(manager.folderNames, ['A', 'B', 'C']);
  });

  test('a folder cannot move into itself or its subfolders', () {
    manager.createFolder('A');
    manager.createFolder('A1');
    manager.moveFolder('A1', 'A');
    expect(() => manager.moveFolder('A', 'A'), throwsArgumentError);
    expect(() => manager.moveFolder('A', 'A1'), throwsArgumentError);
  });

  test('renaming keeps the place and the subfolders', () {
    for (final f in ['A', 'A1', 'A1x']) {
      manager.createFolder(f);
    }
    manager.moveFolder('A1', 'A');
    manager.moveFolder('A1x', 'A1');
    manager.rename('A1', 'Renamed');
    expect(manager.folderTree.parentOf('Renamed'), 'A');
    expect(manager.folderTree.parentOf('A1x'), 'Renamed');
    expect(manager.folderNames, ['A', 'Renamed', 'A1x']);
  });

  test('deleting moves subfolders up, or takes them along', () {
    for (final f in ['P', 'A', 'A1', 'A1x', 'B']) {
      manager.createFolder(f);
    }
    manager.moveFolder('A', 'P');
    manager.moveFolder('A1', 'A');
    manager.moveFolder('A1x', 'A1');
    expect(manager.deleteFolder('A1'), ['A1']);
    expect(manager.folderTree.parentOf('A1x'), 'A');
    expect(manager.folderNames, ['P', 'A', 'A1x', 'B']);
    expect(manager.deleteFolder('A', withSubfolders: true), ['A', 'A1x']);
    expect(manager.folderNames, ['P', 'B']);
  });

  test('a rename may change only the letter case', () {
    manager.createFolder('abc');
    manager.createFolder('abc1');
    manager.moveFolder('abc1', 'abc');
    manager.rename('abc', 'ABC');
    expect(manager.folderNames, ['ABC', 'abc1']);
    expect(manager.folderTree.parentOf('abc1'), 'ABC');
    expect(manager.folderComics('ABC'), 0);
  });

  test('deleting a folder drops its network link', () {
    manager.createFolder('A');
    manager.linkFolderToNetwork('A', 'source', 'remote');
    manager.deleteFolder('A');
    manager.createFolder('A');
    expect(manager.findLinked('A').$1, isNull);
  });

  test('a stale sort list still applies', () {
    for (final f in ['A', 'B', 'C']) {
      manager.createFolder(f);
    }
    manager.reorderFolders(null, ['C', 'gone', 'A']);
    expect(manager.folderNames, ['C', 'A', 'B']);
  });

  group('importing data from versions without nesting', () {
    test('keeps this device\'s nesting for folders that survive', () async {
      for (final f in ['A', 'A1', 'B']) {
        manager.createFolder(f);
      }
      manager.moveFolder('A1', 'A');
      await restore(backup({'B': 1, 'A': 0, 'A1': 2}, order: ['B', 'A', 'A1']));
      expect(manager.folderNames, ['B', 'A', 'A1']);
      expect(manager.folderTree.parentOf('A1'), 'A');
      expect(manager.folderComics('A1'), 2);
      expect(manager.getFolderComics('A1').map((c) => c.id), ['A1-0', 'A1-1']);
    });

    test('drops a kept link whose parent the backup lacks', () async {
      manager.createFolder('A');
      manager.createFolder('A1');
      manager.moveFolder('A1', 'A');
      await restore(backup({'A1': 0}));
      expect(manager.folderTree.parentOf('A1'), isNull);
      manager.createFolder('A');
      expect(manager.folderTree.parentOf('A1'), isNull);
    });

    test('a backup with a layout replaces the nesting here', () async {
      manager.createFolder('A');
      manager.createFolder('A1');
      manager.moveFolder('A1', 'A');
      await restore(backup({'A': 0, 'A1': 0}, links: {}));
      expect(manager.folderTree.parentOf('A1'), isNull);
    });

    test('a stale link from an old rename is not picked up again', () async {
      await restore(
        backup({'Renamed': 0, 'Child': 0}, links: {'Child': 'Old'}),
      );
      expect(manager.folderTree.parentOf('Child'), isNull);
      manager.createFolder('Old');
      expect(manager.folderTree.parentOf('Child'), isNull);
    });

    test('an old folder named like the layout table stays usable', () async {
      await restore(backup({'folder_tree': 1, 'A': 0, 'B': 0}));
      expect(manager.folderNames, contains('folder_tree'));
      expect(manager.folderComics('folder_tree'), 1);
      expect(manager.supportsFolderNesting, isFalse);
      expect(() => manager.moveFolder('B', 'A'), throwsStateError);
      manager.createFolder('C');
      manager.rename('folder_tree', 'Old');
      expect(manager.supportsFolderNesting, isTrue);
      manager.moveFolder('B', 'A');
      expect(manager.folderTree.parentOf('B'), 'A');
      expect(manager.folderComics('Old'), 1);
    });

    test('a single-folder export imports at the chosen place', () {
      manager.createFolder('A');
      final name = manager.fromJson(
        '{"name": "folder_tree", "comics": []}',
        parent: 'A',
      );
      expect(name, 'folder_tree(0)');
      expect(manager.folderTree.parentOf(name), 'A');
    });
  });
}
