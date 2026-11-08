import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:zip_flutter/zip_flutter.dart';

const channel = MethodChannel('venera/method_channel');
const markerName = 'ohos_directory_probe_path';
const contents = 'HarmonyOS directory persistence 中文';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<String> verifyDirectory(String path) async {
  final folder = Directory(path);
  check(await folder.exists(), 'The authorized folder is inaccessible.');
  final file = File('$path/持久文件.txt');
  check(await file.readAsString() == contents, 'Persistent file changed.');
  final temporary = File('$path/rename.txt');
  await temporary.writeAsString(contents, flush: true);
  final renamed = await temporary.rename('$path/renamed.txt');
  check(await renamed.readAsString() == contents, 'Rename/read failed.');
  await renamed.delete();
  check(
    (await folder.list().toList()).any((entry) => entry.path == file.path),
    'Directory enumeration failed.',
  );
  final count = await Isolate.run(() {
    final db = openRawDatabase('$path/probe.db');
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('CREATE TABLE IF NOT EXISTS starts (n INTEGER NOT NULL)');
      if (db.select('SELECT n FROM starts').isEmpty) {
        db.execute('INSERT INTO starts VALUES (0)');
      }
      db.execute('UPDATE starts SET n = n + 1');
      check(
        db.select('PRAGMA integrity_check').single.values.single == 'ok',
        'External SQLite integrity check failed.',
      );
      return db.select('SELECT n FROM starts').single['n'] as int;
    } finally {
      db.dispose();
    }
  });
  await Isolate.run(() {
    final zip = ZipFile.openRead('$path/archive.cbz');
    try {
      check(
        utf8.decode(zip.getEntryByName('章节/测试.txt').read()) == contents,
        'Native ZIP could not read the authorized directory.',
      );
    } finally {
      zip.close();
    }
  });
  return 'directory Dart IO, rename/delete/list, SQLite WAL in worker isolate, '
      'native ZIP, persistent launch count $count';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: DirectoryProbe()));
}

class DirectoryProbe extends StatefulWidget {
  const DirectoryProbe({super.key});

  @override
  State<DirectoryProbe> createState() => _DirectoryProbeState();
}

class _DirectoryProbeState extends State<DirectoryProbe> {
  String status = 'Initializing';
  String? testPath;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(
      run(() async {
        await App.init();
        final marker = File('${App.dataPath}/$markerName');
        if (!await marker.exists()) return 'Ready: choose a test directory.';
        testPath = await marker.readAsString();
        return 'PASS: ${await verifyDirectory(testPath!)}';
      }),
    );
  }

  Future<void> run(Future<String> Function() operation) async {
    setState(() => busy = true);
    try {
      status = await operation();
    } catch (error, stack) {
      status = 'FAIL: $error\n$stack';
    }
    debugPrint(status);
    if (mounted) setState(() => busy = false);
  }

  Future<String> select() async {
    final selected = await channel.invokeMethod<String>('getDirectoryPath');
    if (selected == null) return 'Cancelled';
    final folder = await Directory(
      selected,
    ).createTemp('venera_directory_probe_');
    testPath = folder.path;
    await File('${folder.path}/持久文件.txt').writeAsString(contents, flush: true);
    final archive = ZipFile.open('${folder.path}/archive.cbz');
    try {
      archive.addFileFromBytes('章节/测试.txt', utf8.encode(contents));
    } finally {
      archive.close();
    }
    final result = await verifyDirectory(folder.path);
    await File(
      '${App.dataPath}/$markerName',
    ).writeAsString(folder.path, flush: true);
    return 'PASS: $result; restart to verify restoration.';
  }

  Future<String> share() async {
    check(testPath != null, 'Choose a directory first.');
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile('$testPath/持久文件.txt', mimeType: 'text/plain')]),
    );
    check(
      result.status != ShareResultStatus.success,
      'Dismiss without selecting a recipient.',
    );
    return 'PASS: authorized directory file reached the share sheet, then dismissed.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HarmonyOS directory probe')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ElevatedButton(
          onPressed: busy ? null : () => run(select),
          child: const Text('Choose test directory'),
        ),
        ElevatedButton(
          onPressed: busy ? null : () => run(share),
          child: const Text('Open and dismiss external file share'),
        ),
        SelectableText(status),
      ],
    ),
  );
}
