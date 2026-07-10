import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  Directory tempDir() {
    final dir = Directory.systemTemp.createTempSync('venera_restore_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    return dir;
  }

  test('overwriteDatabaseContent replaces schema and rows in place', () async {
    final dir = tempDir();
    final targetPath = '${dir.path}${Platform.pathSeparator}target.db';
    final sourcePath = '${dir.path}${Platform.pathSeparator}source.db';

    final target = openSqliteDatabase(targetPath);
    addTearDown(target.dispose);
    target.execute('CREATE TABLE old_table (id INTEGER PRIMARY KEY, v TEXT);');
    target.execute("INSERT INTO old_table VALUES (1, 'old');");

    final source = sqlite3.open(sourcePath);
    source.execute('CREATE TABLE new_table (id TEXT PRIMARY KEY, n INT);');
    source.execute("INSERT INTO new_table VALUES ('a', 42);");
    source.dispose();

    await overwriteDatabaseContent(target, sourcePath);

    final tables = target
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'])
        .toList();
    expect(tables, contains('new_table'));
    expect(tables, isNot(contains('old_table')));
    expect(target.select('SELECT n FROM new_table').first['n'], 42);

    // The connection stays writable after the copy.
    target.execute("INSERT INTO new_table VALUES ('b', 7);");
    expect(target.select('SELECT count(*) c FROM new_table').first['c'], 2);
  });

  test('a second connection opened before the restore survives it', () async {
    final dir = tempDir();
    final targetPath = '${dir.path}${Platform.pathSeparator}target.db';
    final sourcePath = '${dir.path}${Platform.pathSeparator}source.db';

    final target = openSqliteDatabase(targetPath);
    addTearDown(target.dispose);
    target.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
    target.execute("INSERT INTO t VALUES (1, 'old');");

    // Simulates an isolate-side reader (image-favorites compute, async folder
    // load) or a leftover hot-restart handle: a second live connection that
    // the old delete+rename swap crashed or errno-32'd against.
    final ghost = sqlite3.open(targetPath);
    addTearDown(ghost.dispose);
    expect(ghost.select('SELECT v FROM t').first['v'], 'old');

    final source = sqlite3.open(sourcePath);
    source.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
    source.execute("INSERT INTO t VALUES (1, 'new');");
    source.dispose();

    await overwriteDatabaseContent(target, sourcePath);

    // The ghost handle stays valid and observes the restored content on its
    // next read; the restoring connection sees it too.
    expect(ghost.select('SELECT v FROM t').first['v'], 'new');
    expect(target.select('SELECT v FROM t').first['v'], 'new');
  });

  test('guard blocks new reads while restoring and drains in-flight ones',
      () async {
    final guard = DatabaseRestoreGuard.instance;

    // A reader already dispatched before the restore arms.
    var inFlightDone = false;
    final inFlight = guard.guardedRead(() async {
      await Future.delayed(const Duration(milliseconds: 60));
      inFlightDone = true;
    });

    // beginRestore must not return until that reader finished.
    await guard.beginRestore();
    expect(inFlightDone, isTrue,
        reason: 'beginRestore returned before draining in-flight reads');
    await inFlight;

    // A read requested during the restore is held off, not run.
    var duringRan = false;
    final during = guard.guardedRead(() async => duringRan = true);
    await Future.delayed(const Duration(milliseconds: 40));
    expect(duringRan, isFalse, reason: 'read ran while a restore held the DB');

    // Releasing lets it proceed.
    guard.endRestore();
    await during;
    expect(duringRan, isTrue);
  });

  test('two guarded reads never overlap (serialized)', () async {
    final guard = DatabaseRestoreGuard.instance;
    // Drain any state left by earlier tests.
    await guard.guardedRead(() async {});

    var active = 0;
    var maxConcurrent = 0;
    Future<void> read() => guard.guardedRead(() async {
          active++;
          maxConcurrent = maxConcurrent > active ? maxConcurrent : active;
          await Future.delayed(const Duration(milliseconds: 20));
          active--;
        });

    // Fire several at once, as startup does (favorites hash, history load,
    // image-favorites stats). Each opens its own sqlite handle in an isolate;
    // on iOS concurrent opens corrupt the shared C-heap, so they must run one
    // at a time.
    await Future.wait([read(), read(), read(), read()]);
    expect(maxConcurrent, 1,
        reason: 'guarded reads ran concurrently — the crash race is back');
  });

  test('a failing guarded read does not wedge the chain', () async {
    final guard = DatabaseRestoreGuard.instance;
    await expectLater(
      guard.guardedRead(() async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
    // The next op must still run.
    var ran = false;
    await guard.guardedRead(() async => ran = true);
    expect(ran, isTrue);
  });

  test('restore fails cleanly when the source is not a database', () async {
    final dir = tempDir();
    final targetPath = '${dir.path}${Platform.pathSeparator}target.db';
    final sourcePath = '${dir.path}${Platform.pathSeparator}bad.db';

    final target = openSqliteDatabase(targetPath);
    addTearDown(target.dispose);
    target.execute('CREATE TABLE t (v TEXT);');
    target.execute("INSERT INTO t VALUES ('keep');");

    File(sourcePath).writeAsStringSync('this is not a sqlite database');

    await expectLater(
      overwriteDatabaseContent(target, sourcePath),
      throwsA(isA<SqliteException>()),
    );
    // The target connection is still usable and its data intact.
    expect(target.select('SELECT v FROM t').first['v'], 'keep');
  });
}
