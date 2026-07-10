import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';
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

/// Serializes an in-place database restore against every background-isolate
/// reader in this process.
///
/// A restore ([overwriteDatabaseContent]) runs SQLite's online backup on the
/// live connection and rebuilds the target's `-wal`/`-shm` sidecars. Any OTHER
/// connection that still has those files memory-mapped — the image-favorites
/// compute isolate, async folder/history loads, a fresh `withDatabase` open —
/// then reads through a now-dangling pointer, faulting inside `btreeParseCellPtr`
/// / `walIndexReadHdr` and corrupting the process heap. That is the iOS
/// "sync then relaunch" crash: the older fixes only held off startup init and
/// follow-update writers, never these readers.
///
/// Readers dispatch through [guardedRead]; a restore [beginRestore]s (waiting
/// for in-flight reads to drain and blocking new ones), runs, then [endRestore]s.
/// Single-threaded Dart makes the check→count transitions atomic (no await
/// between them), so no reader can slip past once a restore is armed.
class DatabaseRestoreGuard {
  DatabaseRestoreGuard._();

  static final DatabaseRestoreGuard instance = DatabaseRestoreGuard._();

  /// Tail of the serialized-access chain. Every [guardedRead] and every
  /// restore ([beginRestore]→[endRestore]) appends its critical section here,
  /// so at most one of them touches the shared DB files at a time.
  ///
  /// This is not only about restore-vs-read: two background-isolate reads
  /// running *concurrently* (favorites hash, async history/folder load,
  /// image-favorites stats — all fired during startup) each open their own
  /// `sqlite3` handle in a fresh `Isolate.run`. On iOS those handles share one
  /// process C-heap, and overlapping opens/steps/`dispose`s corrupt it — an
  /// `abort()` in libmalloc ("pointer being freed was not allocated") ~1s into
  /// launch. Serializing every guarded op removes that race entirely; the ops
  /// are short, so the added latency is negligible.
  Future<void> _tail = Future.value();

  /// Set while a restore holds the chain open between [beginRestore] and
  /// [endRestore]; completing it releases the chain for the next waiter.
  Completer<void>? _restoreGate;

  /// True while a restore holds the databases exclusively.
  bool get isRestoring => _restoreGate != null;

  /// Arms the guard: waits for the chain to drain (any in-flight guarded read
  /// or prior restore finishes first), then holds it open until [endRestore].
  /// The caller's restore work runs between the two calls. Always pair with
  /// [endRestore] in a `finally`, or the chain stays blocked forever.
  Future<void> beginRestore() async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    await previous;
    _restoreGate = gate;
  }

  /// Releases the guard, letting the next queued op run.
  void endRestore() {
    final gate = _restoreGate;
    _restoreGate = null;
    gate?.complete();
  }

  /// Runs [read] (typically an `Isolate.run` opening one of the shared DB
  /// files) once every earlier guarded op — reads and restores alike — has
  /// finished. Serialized, so no two isolate DB ops overlap.
  Future<T> guardedRead<T>(Future<T> Function() read) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => read()).whenComplete(done.complete);
  }
}

/// Replaces [target]'s entire content — schema included — with the database
/// file at [sourcePath], IN PLACE via SQLite's online backup API.
///
/// The target file is never deleted or renamed, so every other connection in
/// this process keeps a valid handle throughout: background-isolate readers
/// (image-favorites compute, async folder loads), a mid-flight follow-update
/// check, or a leftover hot-restart handle. The old close→delete→rename→reopen
/// swap crashed natively whenever such a second connection was alive (the
/// startup-sync crash loop on iOS) and failed with errno 32 on Windows, where
/// SQLite opens files without FILE_SHARE_DELETE.
///
/// Copies in a single backup step: WAL readers on other connections keep their
/// snapshot; writers briefly queue on their busy_timeout. The copied file may
/// carry an older (or foreign) schema — re-running migrations and rebuilding
/// in-memory caches afterwards is the caller's job.
Future<void> overwriteDatabaseContent(
  CommonDatabase target,
  String sourcePath,
) async {
  final wasWal =
      target.select('PRAGMA journal_mode;').first.values.first.toString() ==
      'wal';
  // Collapse the target's WAL into the main file before the page-level copy.
  // A populated `-wal` left standing while backup rewrites every page — then
  // the WAL re-assertion below — churns the `-shm`/`-wal` sidecars; a reader
  // on another connection that mapped the old sidecars then faults on a
  // dangling page. Truncating first (best-effort: needs a brief write lock)
  // means there is no stale WAL segment to rebuild around. The restore runs
  // under DatabaseRestoreGuard, so no other connection should hold them anyway.
  //
  // Leaving WAL mode entirely (→ rollback journal) is REQUIRED, not just
  // hygiene: SQLite's online backup refuses to change the destination's page
  // size while the destination is in WAL mode, throwing SQLITE_READONLY
  // ("attempt to write a readonly database", code 8). A backup zip produced by
  // an older/foreign build can carry a different page size than the freshly
  // created 4096-byte WAL store here, so a WebDAV restore on a clean install
  // died on the first WAL target (history.db) before this. In DELETE mode the
  // backup is free to resize the destination; we re-assert WAL afterwards.
  if (wasWal) {
    try {
      target.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}
    try {
      target.execute('PRAGMA journal_mode = DELETE;');
    } catch (_) {}
  }
  final source = sqlite3.open(sourcePath);
  try {
    await source.backup(target as Database, nPage: -1).drain();
  } finally {
    source.dispose();
  }
  // A page-level copy brings the source's journal-mode header along; re-assert
  // WAL (only where it was already in use — local.db deliberately isn't) so a
  // backup exported from a rollback-journal database can't silently downgrade
  // this store's journaling. Best-effort: switching modes needs a brief
  // exclusive lock and may be denied while another connection reads.
  if (wasWal) {
    try {
      target.execute('PRAGMA journal_mode = WAL;');
    } catch (_) {}
  }
}

/// Renames a database and its WAL sidecars aside (`.invalid-<timestamp>`) so a
/// fresh one can be created at [path]. For open failures that survive restarts
/// (e.g. a crash left sidecars the next open cannot recover) — trades that
/// store's content for a working app instead of failing every launch.
void backupAsideCorruptDatabase(String path) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (!file.existsSync()) continue;
    var backupPath = '$path$suffix.invalid-$timestamp';
    var index = 1;
    while (File(backupPath).existsSync()) {
      backupPath = '$path$suffix.invalid-$timestamp-$index';
      index++;
    }
    try {
      file.renameSync(backupPath);
    } catch (_) {
      // Rename can fail if another handle still pins the file (Windows); the
      // caller's reopen will then surface the original error.
    }
  }
}

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

Uint8List exportDatabaseBytes(String path) {
  final db = openSqliteDatabase(path);
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
  } finally {
    db.dispose();
  }
  return File(path).readAsBytesSync();
}

void rebuildDatabaseFromBytes(String path, Uint8List bytes) {
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
}

String _quoteSqlIdentifier(String value) {
  return '"${value.replaceAll('"', '""')}"';
}

Object? _decodeDumpValue(Object? value) {
  if (value is Map) {
    final map = value.cast<String, dynamic>();
    if (map.containsKey(r'$blob')) {
      return base64Decode(map[r'$blob']?.toString() ?? '');
    }
    if (map.containsKey(r'$bigint')) {
      return int.tryParse(map[r'$bigint']?.toString() ?? '');
    }
  }
  return value;
}

void rebuildDatabaseFromDump(
  String path,
  List<dynamic> tables, {
  List<dynamic> indexes = const [],
}) {
  final db = openSqliteDatabase(path);
  db.execute('PRAGMA foreign_keys = OFF;');
  db.execute('BEGIN IMMEDIATE;');
  try {
    final existingTables = db
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .where((name) => !name.toLowerCase().startsWith('sqlite_'))
        .toList();
    for (final table in existingTables) {
      db.execute('DROP TABLE IF EXISTS ${_quoteSqlIdentifier(table)}');
    }

    for (final table in tables) {
      if (table is! Map) {
        throw FormatException('Invalid sqlite dump table entry: $table');
      }
      final sql = table['sql']?.toString();
      if (sql == null || sql.trim().isEmpty) {
        throw const FormatException('Missing sqlite dump table schema');
      }
      db.execute(sql);
    }

    for (final table in tables) {
      if (table is! Map) continue;
      final name = table['name']?.toString();
      if (name == null || name.isEmpty) {
        throw const FormatException('Missing sqlite dump table name');
      }
      final rows = table['rows'];
      if (rows is! List || rows.isEmpty) continue;
      final columns = table['columns'] is List
          ? (table['columns'] as List).map((e) => e.toString()).toList()
          : const <String>[];
      for (final row in rows) {
        if (row is! List) {
          throw FormatException('Invalid sqlite dump row for $name');
        }
        final placeholders = List.filled(row.length, '?').join(',');
        final columnSql = columns.length == row.length
            ? ' (${columns.map(_quoteSqlIdentifier).join(',')})'
            : '';
        final stmt = db.prepare(
          'INSERT INTO ${_quoteSqlIdentifier(name)}$columnSql '
          'VALUES ($placeholders)',
        );
        try {
          stmt.execute(row.map(_decodeDumpValue).toList());
        } finally {
          stmt.dispose();
        }
      }
    }

    for (final index in indexes) {
      final sql = index?.toString() ?? '';
      if (sql.trim().isNotEmpty) {
        db.execute(sql);
      }
    }

    db.execute('COMMIT;');
  } catch (_) {
    try {
      db.execute('ROLLBACK;');
    } catch (_) {}
    rethrow;
  } finally {
    db.execute('PRAGMA foreign_keys = ON;');
    db.dispose();
  }
}
