import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String custom;

  Future<void> restart() async {
    await CacheManager.instance?.ready;
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    DatabaseGateway.instance.closeManaged(
      p.join(custom, 'venera-cache', 'cache.db'),
    );
    CacheManager.instance = null;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera_cache_directory_');
    App.dataPath = root.path;
    App.cachePath = p.join(root.path, 'default');
    custom = p.join(root.path, 'other-drive', 'nested');
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    await CacheManager().ready;
  });

  tearDown(() async {
    await restart();
    appdata.settings[CacheManager.directorySetting] = '';
    await root.delete(recursive: true);
  });

  test(
    'creates folders, switches only on restart and preserves old cache',
    () async {
      await CacheManager().writeCache('old', [1, 2]);
      final old = (await CacheManager().findCache('old'))!;
      final oldPath = CacheManager.cachePath;
      await CacheManager.setCustomDirectory(custom);
      expect(Directory(CacheManager.configuredPath).existsSync(), isTrue);
      expect(CacheManager.cachePath, oldPath);
      await CacheManager().writeCache('before-restart', [3]);
      expect(
        (await CacheManager().findCache('before-restart'))!.path,
        startsWith(oldPath),
      );

      await restart();
      await CacheManager().ready;
      expect(CacheManager.cachePath, p.join(custom, 'venera-cache', 'cache'));
      expect(await CacheManager().findCache('old'), isNull);
      await CacheManager().writeCache('new', [4, 5, 6]);
      final sibling = File(p.join(custom, 'keep.txt'))
        ..writeAsStringSync('keep');
      await CacheManager().clear();
      expect(await old.exists(), isTrue);
      expect(await sibling.readAsString(), 'keep');
      expect(CacheManager().currentSize, 0);

      await CacheManager.setCustomDirectory('');
      await restart();
      await CacheManager().ready;
      expect((await CacheManager().findCache('old'))!.readAsBytesSync(), [
        1,
        2,
      ]);
    },
  );

  test(
    'rejects invalid paths and populated unrelated folders without saving',
    () async {
      await expectLater(
        CacheManager.setCustomDirectory('relative/path'),
        throwsA(isA<FileSystemException>()),
      );
      final occupied = Directory(p.join(custom, 'venera-cache'))
        ..createSync(recursive: true);
      final keep = File(p.join(occupied.path, 'keep.txt'))
        ..writeAsStringSync('keep');
      await expectLater(
        CacheManager.setCustomDirectory(custom),
        throwsA(isA<FileSystemException>()),
      );
      expect(CacheManager.customDirectory, isEmpty);
      expect(keep.readAsStringSync(), 'keep');
    },
  );

  test('unavailable saved path falls back and remains device-local', () async {
    await restart();
    final blocked = File(p.join(root.path, 'blocked'))
      ..writeAsStringSync('file');
    appdata.settings[CacheManager.directorySetting] = blocked.path;
    await CacheManager().ready;
    expect(CacheManager.cachePath, '${App.cachePath}/cache');
    expect(CacheManager.startupPathError, isNotNull);
    expect(CacheManager.customDirectory, blocked.path);
    expect(
      Appdata.syncDisabledFields([]),
      contains(CacheManager.directorySetting),
    );
    await CacheManager().writeCache('fallback', [7]);
    expect(await CacheManager().findCache('fallback'), isNotNull);
  });
}
