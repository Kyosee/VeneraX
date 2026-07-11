import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Opens a connection with the standard pragmas for shared store files.
///
/// App code must NOT call this directly (enforced by
/// `test/native_api_guard_test.dart`): long-lived handles go through
/// [DatabaseGateway.openManaged] so restores can prove no handle is alive
/// before swapping files, and background-isolate work goes through
/// [DatabaseGateway.isolateOp]. Kept public for tests.
Database openSqliteDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA wal_autocheckpoint = 200;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA busy_timeout = 5000;');
  } catch (_) {
    db.dispose();
    rethrow;
  }
  return db;
}

/// Raw, pragma-free connection. For short-lived access to NON-shared database
/// files — entries extracted from a backup, imported archives — or for
/// checkpoint/validity probes that the caller already serializes against
/// restores. Never hold one across an await that can reach a restore window.
Database openRawDatabase(String path) => sqlite3.open(path);

/// Single owner of database access ordering — and of connection lifetime —
/// for this process.
///
/// Two distinct hazards share one root cause — several native `sqlite3` handles
/// bound to the same file share one process C-heap and one `-wal`/`-shm` memory
/// mapping:
///
///  1. Concurrent background reads: startup fires several isolate reads at
///     once, each opening its own handle in a fresh `Isolate.run`.
///  2. A restore that swaps a database file out from under a live reader.
///
/// Both are removed by giving the gateway the only doors:
///
///  - Long-lived main-isolate handles are opened through [openManaged] and
///    closed through [closeManaged], so the gateway KNOWS every live handle.
///    File-swapping helpers call [assertNoLiveHandles] first — a forgotten
///    close is a loud [StateError] at the swap point instead of silent native
///    corruption.
///  - Background-isolate work goes through [isolateOp], which serializes on
///    the gateway chain and opens/disposes its own connection inside the
///    isolate. [guardedRead] remains for the rare op that must run manager
///    code inside the isolate; [runExclusive] drains and blocks everything
///    for the whole close→replace→reopen sequence of a restore.
///
/// Opening a connection any other way is forbidden in `lib/` and enforced by
/// `test/native_api_guard_test.dart`.
class DatabaseGateway {
  DatabaseGateway._();

  static final DatabaseGateway instance = DatabaseGateway._();

  /// Tail of the serialized-access chain. Every [guardedRead] and every
  /// [runExclusive] window appends its critical section here, so at most one of
  /// them touches the shared DB files at a time.
  Future<void> _tail = Future.value();

  /// Live long-lived handles by database file path.
  final Map<String, Database> _managed = {};

  /// Opens (with the standard pragmas) and registers the long-lived handle
  /// for the shared database file at [path]. Throws [StateError] on a double
  /// open — a second live handle to the same store is always a bug.
  Database openManaged(String path) {
    if (_managed.containsKey(path)) {
      throw StateError('Database is already open through the gateway: $path');
    }
    final db = openSqliteDatabase(path);
    _managed[path] = db;
    return db;
  }

  /// Disposes and unregisters the handle for [path]. Safe to call when no
  /// handle is registered.
  void closeManaged(String path) {
    _managed.remove(path)?.dispose();
  }

  /// Throws [StateError] if any of [paths] still has a registered handle.
  /// File-swapping helpers call this so that "forgot to close X before
  /// replacing its file" fails loudly instead of corrupting native state.
  void assertNoLiveHandles(Iterable<String> paths) {
    final offenders = paths.where(_managed.containsKey).toList();
    if (offenders.isNotEmpty) {
      throw StateError(
        'Live database handle(s) held during a file swap: $offenders',
      );
    }
  }

  /// Runs [op] against the shared database file at [path] on a background
  /// isolate: serialized on the gateway chain, fresh connection opened inside
  /// the isolate and disposed before it exits. The only sanctioned way for
  /// app code to touch a shared database from an isolate.
  Future<T> isolateOp<T>(String path, Future<T> Function(Database db) op) {
    return guardedRead(() {
      return Isolate.run(() => withDatabase(path, op));
    });
  }

  /// Runs [read] (typically an `Isolate.run` opening one of the shared DB
  /// files) once every earlier queued op — reads and restores alike — has
  /// finished. Serialized, so no two isolate DB ops overlap. Prefer
  /// [isolateOp]; use this directly only when the isolate must run more than
  /// a plain connection-bound function.
  Future<T> guardedRead<T>(Future<T> Function() read) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => read()).whenComplete(done.complete);
  }

  /// Runs [body] with exclusive access to every database: waits for all
  /// in-flight [guardedRead]s to drain, then blocks new ones until [body]
  /// completes. Restores use this to close all connections, replace the files
  /// on disk, and reopen — with no other handle alive at the swap point.
  Future<T> runExclusive<T>(Future<T> Function() body) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      return await body();
    } finally {
      gate.complete();
    }
  }
}

/// Replaces each target database file (key) with its source file (value) by
/// plain file copy, discarding stale `-wal`/`-shm` sidecars. All-or-nothing.
///
/// The caller MUST have closed every connection to the targets first (restores
/// run inside [DatabaseGateway.runExclusive], which additionally blocks the
/// background-isolate readers). Because no SQLite handle is open during the
/// swap, there is no live memory mapping to dangle and no online-backup step to
/// churn sidecars — the native heap corruption and the Windows FILE_SHARE_DELETE
/// error that plagued the old in-place approach cannot occur. The copied files
/// may carry an older (or foreign) schema, so re-running migrations and
/// rebuilding in-memory caches after reopening is the caller's job.
///
/// Every source is validated as a readable SQLite database before anything is
/// touched, and the originals are set aside and restored if any step fails, so
/// a truncated backup entry or a mid-way error can never leave a half-restored
/// data directory.
void restoreDatabaseFiles(Map<String, String> swaps) {
  // A live handle at the swap point means some store was not closed first —
  // fail loudly here rather than corrupting the native side.
  DatabaseGateway.instance.assertNoLiveHandles(swaps.keys);
  for (final sourcePath in swaps.values) {
    final db = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
    try {
      db.select('PRAGMA schema_version;');
    } finally {
      db.dispose();
    }
  }
  const suffixes = ['', '-wal', '-shm'];
  // Stage phase: copy every source next to its target BEFORE any original is
  // touched. The vulnerable window per target during the swap phase below is
  // then two directory-entry renames, not a multi-megabyte copy — a process
  // death mid-restore can leave the old or the new file in place, never
  // neither.
  final staged = <String, String>{};
  final setAside = <String, String>{};
  // Targets whose staged copy was renamed into place; rollback may only delete
  // these — a target the swap never reached still holds its ORIGINAL file.
  final swappedIn = <String>[];
  try {
    for (final entry in swaps.entries) {
      final stagedPath = '${entry.key}.restore-incoming';
      final stagedFile = File(stagedPath);
      if (stagedFile.existsSync()) {
        stagedFile.deleteSync();
      }
      File(entry.value).copySync(stagedPath);
      staged[entry.key] = stagedPath;
    }
    // Swap phase: set the originals aside, move the staged copies into place.
    for (final entry in swaps.entries) {
      final targetPath = entry.key;
      for (final suffix in suffixes) {
        final file = File('$targetPath$suffix');
        if (!file.existsSync()) continue;
        final asidePath = '$targetPath$suffix.restore-aside';
        final aside = File(asidePath);
        if (aside.existsSync()) {
          aside.deleteSync();
        }
        file.renameSync(asidePath);
        setAside['$targetPath$suffix'] = asidePath;
      }
      File(staged.remove(targetPath)!).renameSync(targetPath);
      swappedIn.add(targetPath);
    }
  } catch (e) {
    // Roll back: remove only the files this run put in place, then restore the
    // set-aside originals. Never delete a path that was not swapped — for an
    // entry the failure preceded, the file at the target path IS the original.
    for (final targetPath in swappedIn) {
      try {
        final current = File(targetPath);
        if (current.existsSync()) {
          current.deleteSync();
        }
      } catch (_) {}
    }
    for (final entry in setAside.entries) {
      try {
        if (!File(entry.key).existsSync()) {
          File(entry.value).renameSync(entry.key);
        }
      } catch (_) {}
    }
    rethrow;
  } finally {
    for (final stagedPath in staged.values) {
      try {
        final file = File(stagedPath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
    }
  }
  for (final asidePath in setAside.values) {
    try {
      File(asidePath).deleteSync();
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

Future<void> deleteSqliteDatabase(String path) async {
  DatabaseGateway.instance.assertNoLiveHandles([path]);
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
