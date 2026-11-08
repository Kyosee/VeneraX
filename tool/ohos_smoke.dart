import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/sqlite_connection.dart';

// Run this entrypoint only on a disposable development device.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String result;
  try {
    if (Platform.operatingSystem != 'ohos') {
      throw StateError('This check requires an OHOS device.');
    }
    final directory = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    final temporary = await getTemporaryDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final info = await PackageInfo.fromPlatform();
    final path = '${directory.path}/ohos_smoke.db';
    final database = DatabaseGateway.instance.openManaged(path);
    late int launches;
    try {
      database.execute('CREATE TABLE IF NOT EXISTS smoke (value INTEGER)');
      database.execute('INSERT INTO smoke VALUES (1)');
      launches =
          database.select('SELECT count(*) AS n FROM smoke').single['n'] as int;
      if (database.select('PRAGMA journal_mode').single.values.first != 'wal') {
        throw StateError('WAL is not enabled.');
      }
    } finally {
      DatabaseGateway.instance.closeManaged(path);
    }
    final count = await DatabaseGateway.instance.isolateOp(path, (db) async {
      return db.select('SELECT count(*) AS n FROM smoke').single['n'] as int;
    });
    final valid = await Isolate.run(() {
      final backup = File(path).copySync('$path.smoke-backup');
      try {
        restoreDatabaseFiles({path: backup.path});
      } finally {
        backup.deleteSync();
      }
      final db = openRawDatabase(path);
      try {
        return db.select('PRAGMA integrity_check').single.values.first == 'ok';
      } finally {
        db.dispose();
      }
    });
    if (count != launches || !valid) {
      throw StateError('Database reopen or integrity check failed.');
    }
    final probe = File('${cache.path}/ohos_smoke.txt');
    await probe.writeAsString('sandbox');
    if (await probe.readAsString() != 'sandbox') {
      throw StateError('Sandbox file round trip failed.');
    }
    await probe.delete();
    result =
        'PASS: OHOS sandbox, package info, SQLite WAL and isolates\n'
        'Launch count: $launches\n${info.packageName} ${info.version}\n'
        'Data: ${directory.path}\nCache: ${cache.path}\n'
        'Temporary: ${temporary.path}\nDocuments: ${documents.path}';
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  }
  // Device logs retain the result when the UI is unavailable.
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(result),
          ),
        ),
      ),
    ),
  );
}
