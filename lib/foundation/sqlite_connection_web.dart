import 'package:sqlite3/wasm.dart';

final _databases = <String, CommonDatabase>{};

WasmSqlite3? _wasmSqlite;
IndexedDbFileSystem? _indexedDbFileSystem;

Future<void> initWebSqlite() async {
  if (_wasmSqlite != null) return;
  _wasmSqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = await IndexedDbFileSystem.open(dbName: 'venera_sqlite');
  _indexedDbFileSystem = fs;
  _wasmSqlite!.registerVirtualFileSystem(fs, makeDefault: true);
}

CommonDatabase openSqliteDatabase(String path) {
  if (_databases.containsKey(path)) {
    return _databases[path]!;
  }
  if (_wasmSqlite == null) {
    throw StateError('Web SQLite not initialized. Call initWebSqlite() first.');
  }
  final db = _wasmSqlite!.open(path);
  db.execute('PRAGMA journal_mode = DELETE;');
  db.execute('PRAGMA synchronous = NORMAL;');
  _databases[path] = db;
  return db;
}

Future<T> withDatabase<T>(
  String path,
  Future<T> Function(CommonDatabase db) fn,
) async {
  final db = openSqliteDatabase(path);
  return fn(db);
}

void closeSqliteDatabase(String path) {
  final db = _databases.remove(path);
  try {
    db?.dispose();
  } catch (_) {}
}

Future<void> flushSqliteDatabases() async {
  await _indexedDbFileSystem?.flush();
}

Future<void> deleteSqliteDatabase(String path) async {
  closeSqliteDatabase(path);
  try {
    _indexedDbFileSystem?.xDelete(path, 0);
  } catch (_) {}
  await flushSqliteDatabases();
}
