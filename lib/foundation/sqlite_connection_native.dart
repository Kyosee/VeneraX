import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

Database openSqliteDatabase(String path) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA foreign_keys = ON;');
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA wal_autocheckpoint = 200;');
  db.execute('PRAGMA synchronous = NORMAL;');
  db.execute('PRAGMA busy_timeout = 5000;');
  return db;
}

void closeSqliteDatabase(String path) {}

Future<void> flushSqliteDatabases() async {}

Future<void> deleteSqliteDatabase(String path) async {
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Future<T> withDatabase<T>(
  String path,
  Future<T> Function(Database db) fn,
) async {
  final db = openSqliteDatabase(path);
  try {
    return await fn(db);
  } finally {
    db.dispose();
  }
}
