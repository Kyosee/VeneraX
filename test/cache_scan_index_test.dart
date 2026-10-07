import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
