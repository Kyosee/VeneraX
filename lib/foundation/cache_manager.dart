import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';

class CacheManager {
  static const directorySetting = 'comicCacheDirectory';

  static String get customDirectory =>
      (appdata.settings[directorySetting] as String? ?? '').trim();

  static String get configuredPath => customDirectory.isEmpty
      ? '${App.cachePath}/cache'
      : p.join(customDirectory, 'venera-cache', 'cache');

  static String get cachePath => instance?._cachePath ?? configuredPath;

  // Keep both paths fixed until restart, including during background writes.
  final String _cachePath;
  final String _dbPath;

  static String? startupPathError;

  /// Uses a dedicated child directory; the selected parent is never cleared.
  static String _prepareDirectory(String path) {
    if (!p.isAbsolute(path)) {
      throw const FileSystemException('An absolute directory path is required');
    }
    final parent = p.normalize(path);
    final root = p.join(parent, 'venera-cache');
    final images = p.join(root, 'cache');
    for (final dir in [root, images]) {
      if (FileSystemEntity.typeSync(dir, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException('The cache directory cannot be a link');
      }
    }
    // Do not adopt an unrelated, populated folder with the same name.
    if (Directory(root).existsSync() &&
        !File(p.join(root, 'cache.db')).existsSync() &&
        Directory(root).listSync().isNotEmpty) {
      final entries = Directory(root).listSync();
      if (entries.length != 1 ||
          entries.single.path != images ||
          !Directory(images).existsSync() ||
          Directory(images).listSync().isNotEmpty) {
        throw const FileSystemException(
          'The cache directory is already in use',
        );
      }
    }
    Directory(images).createSync(recursive: true);
    final probe = Directory(root).createTempSync('.write-test-');
    try {
      File(p.join(probe.path, 'test')).writeAsStringSync('test', flush: true);
    } finally {
      probe.deleteSync(recursive: true);
    }
    return parent;
  }

  /// Saves a device-local preference without moving live cache files.
  static Future<void> setCustomDirectory(String path) async {
    CacheManager();
    final value = path.trim().isEmpty ? '' : _prepareDirectory(path.trim());
    final previous = customDirectory;
    appdata.settings[directorySetting] = value;
    try {
      await appdata.saveData(false);
    } catch (_) {
      appdata.settings[directorySetting] = previous;
      rethrow;
    }
  }

  static CacheManager? instance;

  late Database _db;

  late final Future<void> ready;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  static Future<int> _scanDir(String dbPath, String dir) async {
    // Runs on a fresh connection inside an isolate rather than sharing the
    // main isolate's handle: the sqlite3 package attaches a NativeFinalizer to
    // every Database, so a wrapper built from a shared pointer could close the
    // connection the main isolate is still using (double-free / use-after-free,
    // a native heap abort). isolateOp serializes on the gateway chain so this
    // scan never runs concurrently with another background DB isolate.
    var res = await DatabaseGateway.instance.isolateOp(dbPath, (db) async {
      int totalSize = 0;
      List<String> unmanagedFiles = [];
      await for (var file in Directory(
        dir,
      ).list(recursive: true, followLinks: false)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          var res = db.select(
            '''
                SELECT 1 FROM cache
                WHERE dir = ? AND name = ?
                LIMIT 1
              ''',
            [dir, name],
          );
          if (res.isEmpty) {
            unmanagedFiles.add(file.path);
          } else {
            totalSize += size;
          }
        }
      }
      return {'totalSize': totalSize, 'unmanagedFiles': unmanagedFiles};
    });
    // delete unmanaged files
    // Only modify the database in the main isolate to avoid deadlock
    for (var filePath in res['unmanagedFiles'] as List<String>) {
      var file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      var segments = file.uri.pathSegments;
      var name = segments.last;
      var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
      CacheManager()._db.execute(
        '''
        DELETE FROM cache
        WHERE dir = ? AND name = ?
      ''',
        [dir, name],
      );
    }
    return res['totalSize'] as int;
  }

  CacheManager._create(this._cachePath, this._dbPath) {
    Directory(_cachePath).createSync(recursive: true);
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS cache_file_location ON cache (dir, name)
    ''');
    ready = _scanDir(_dbPath, _cachePath)
        .then((value) async {
          _currentSize = value;
          await checkCache();
        })
        .catchError((Object error, StackTrace stack) {
          Log.error('Cache', 'Failed to scan cache: $error', stack);
        });
  }

  /// Get the singleton instance of CacheManager.
  factory CacheManager() {
    if (instance != null) return instance!;
    startupPathError = null;
    if (customDirectory.isNotEmpty) {
      try {
        final parent = _prepareDirectory(customDirectory);
        final root = p.join(parent, 'venera-cache');
        return instance = CacheManager._create(
          p.join(root, 'cache'),
          p.join(root, 'cache.db'),
        );
      } catch (e) {
        startupPathError = e.toString();
        Log.error('Cache', 'Custom cache directory unavailable: $e');
      }
    }
    return instance = CacheManager._create(
      '${App.cachePath}/cache',
      '${App.dataPath}/cache.db',
    );
  }

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk.
  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = 7 * 24 * 60 * 60 * 1000,
  ]) async {
    await delete(key);
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute(
      '''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''',
      [key, dir.toString(), name, expires],
    );
    if (_currentSize != null) {
      _currentSize = _currentSize! + data.length;
    }
    checkCacheIfRequired();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var expires = row[3] as int;
    var file = File('$cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      // expired
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    }
    if (await file.exists()) {
      // update time
      var expires = now + 7 * 24 * 60 * 60 * 1000;
      _db.execute(
        '''
        UPDATE cache
        SET expires = ?
        WHERE key = ?
      ''',
        [expires, key],
      );
      return file;
    } else {
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
    }
    return null;
  }

  bool _isChecking = false;

  /// Check cache size and delete expired cache.
  /// Only check cache if current size is greater than limit size.
  void checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      checkCache();
    }
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE expires < ?
    ''',
      [DateTime.now().millisecondsSinceEpoch],
    );
    for (var row in res) {
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        var size = await file.length();
        _currentSize = _currentSize! - size;
        await file.delete();
      }
    }
    if (res.isNotEmpty) {
      _db.execute(
        '''
      DELETE FROM cache
      WHERE expires < ?
    ''',
        [DateTime.now().millisecondsSinceEpoch],
      );
    }

    while (_currentSize != null && _currentSize! > _limitSize) {
      var res = _db.select('''
        SELECT * FROM cache
        ORDER BY expires ASC
        limit 10
      ''');
      if (res.isEmpty) {
        // There are many files unmanaged by the cache manager.
        // Clear all cache.
        await Directory(cachePath).delete(recursive: true);
        Directory(cachePath).createSync(recursive: true);
        break;
      }
      for (var row in res) {
        var key = row[0] as String;
        var dir = row[1] as String;
        var name = row[2] as String;
        var file = File('$cachePath/$dir/$name');
        if (await file.exists()) {
          var size = await file.length();
          await file.delete();
          _db.execute(
            '''
            DELETE FROM cache
            WHERE key = ?
          ''',
            [key],
          );
          _currentSize = _currentSize! - size;
          if (_currentSize! <= _limitSize) {
            break;
          }
        } else {
          _db.execute(
            '''
            DELETE FROM cache
            WHERE key = ?
          ''',
            [key],
          );
        }
      }
    }
    _isChecking = false;
  }

  /// Delete cache by key.
  Future<void> delete(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute(
      '''
      DELETE FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (_currentSize != null) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  /// Deletes every cache entry whose key starts with [prefix], returning the
  /// number removed. Used to invalidate a scope of derived cache (e.g. all
  /// translated pages of one comic) without touching unrelated entries.
  Future<int> deleteByPrefix(String prefix) async {
    var rows = _db.select(
      '''
      SELECT key, dir, name FROM cache
      WHERE key LIKE ? ESCAPE '\\'
    ''',
      ['${_escapeLike(prefix)}%'],
    );
    var removed = 0;
    for (var row in rows) {
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        if (_currentSize != null) {
          _currentSize = _currentSize! - await file.length();
        }
        await file.delete();
      }
      removed++;
    }
    _db.execute(
      '''
      DELETE FROM cache
      WHERE key LIKE ? ESCAPE '\\'
    ''',
      ['${_escapeLike(prefix)}%'],
    );
    return removed;
  }

  /// Escapes LIKE wildcards so a prefix containing '%' or '_' matches literally.
  static String _escapeLike(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  /// Delete all cache.
  Future<void> clear() async {
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
