import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/sqlite_connection.dart';

class _PendingCacheFile implements File {
  _PendingCacheFile(this.onWrite);
  final void Function() onWrite;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async => this;
  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    onWrite();
    return this;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new cache writes wait until startup orphan cleanup completes', () async {
    final root = Directory.systemTemp.createTempSync('cache-startup-write-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    final release = Completer<void>();
    final gate = DatabaseGateway.instance.runExclusive(() => release.future);
    final manager = CacheManager();
    var writes = 0;
    var writesDuringScan = -1;
    try {
      await IOOverrides.runZoned(() async {
        final pending = manager.writeCache('new', [1, 2, 3]);
        await Future<void>(() {});
        writesDuringScan = writes;
        release.complete();
        await pending;
      }, createFile: (_) => _PendingCacheFile(() => writes++));
      await manager.ready;
      expect(writesDuringScan, 0);
      expect(writes, 1);
      expect(manager.currentSize, 3);
    } finally {
      if (!release.isCompleted) release.complete();
      await gate;
      await manager.ready;
      DatabaseGateway.instance.closeManaged('${root.path}/cache.db');
      CacheManager.instance = null;
      root.deleteSync(recursive: true);
    }
  });

  test('old cache databases gain indexed file lookup without losing cached data', () async {
    final root = Directory.systemTemp.createTempSync('cache-scan-index-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    final dbPath = '${root.path}/cache.db';
    final db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE cache (key TEXT PRIMARY KEY NOT NULL, '
        'dir TEXT NOT NULL, name TEXT NOT NULL, expires INTEGER NOT NULL, type TEXT)');
    db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, ?)',
        ['kept', '1', 'cover', DateTime.now().millisecondsSinceEpoch + 60000, null]);
    db.dispose();
    final file = File('${root.path}/cache/1/cover')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final orphan = File('${root.path}/cache/1/orphan')..writeAsBytesSync([9]);
    try {
      final manager = CacheManager();
      await manager.ready;
      expect(manager.currentSize, 3);
      expect((await manager.findCache('kept'))!.path, file.path);
      expect(orphan.existsSync(), isFalse);
      final connection = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final plan = connection.select(
        'EXPLAIN QUERY PLAN SELECT 1 FROM cache WHERE dir = ? AND name = ? LIMIT 1',
        ['1', 'cover'],
      );
      final details = plan.map((row) => row['detail']).join(' ');
      connection.dispose();
      expect(details, contains('SEARCH cache'));
    } finally {
      await CacheManager.instance?.ready;
      DatabaseGateway.instance.closeManaged(dbPath);
      CacheManager.instance = null;
      root.deleteSync(recursive: true);
    }
  });
}
