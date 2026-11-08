import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/image.dart' as pixels;
import 'package:zip_flutter/zip_flutter.dart';

Future<void> checkQuickJs() async {
  final engine = FlutterQjs(hostPromiseRejectionHandler: (_) {});
  engine.dispatch();
  try {
    final echo = engine.evaluate('(value) => value') as JSInvokable;
    try {
      final value =
          echo([
                {
                  'integer': 7,
                  'double': 2.5,
                  'items': [true, null, '鸿蒙'],
                },
              ])
              as Map;
      if (value['integer'] != 7 ||
          value['double'] != 2.5 ||
          (value['items'] as List).last != '鸿蒙') {
        throw StateError('QuickJS values changed across the FFI boundary.');
      }
    } finally {
      echo.free();
    }
    final resolved = engine.evaluate('Promise.resolve(42)') as Future;
    if (await resolved.timeout(const Duration(seconds: 5)) != 42) {
      throw StateError('QuickJS Promise did not resolve.');
    }
    var rejected = false;
    try {
      await (engine.evaluate('(async () => { throw null; })()') as Future)
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      if (error != 'null') rethrow;
      rejected = true;
    }
    if (!rejected) throw StateError('QuickJS null rejection was lost.');
  } finally {
    engine.close();
    engine.port.close();
  }
}

Future<void> checkArchivesAndPng(String cachePath) async {
  final image = pixels.Image(
    Uint32List.fromList([0xff123456, 0xffabcdef]),
    2,
    1,
  );
  final encoded = image.encodePng();
  final decoded = await pixels.Image.decodeImage(encoded);
  if (decoded.width != 2 ||
      decoded.height != 1 ||
      decoded.getPixelAtIndex(0).value != 0xff123456 ||
      decoded.getPixelAtIndex(1).value != 0xffabcdef) {
    throw StateError('PNG pixel round trip failed.');
  }
  final zipPath = '$cachePath/ohos_smoke.zip';
  final writer = ZipFile.open(zipPath);
  try {
    writer.addFileFromBytes('章节/第一页.png', encoded);
  } finally {
    writer.close();
  }
  await Isolate.run(() {
    final reader = ZipFile.openRead(zipPath);
    try {
      final entry = reader.getEntryByName('章节/第一页.png');
      if (reader.entriesCount != 1 || !listEquals(entry.read(), encoded)) {
        throw StateError('ZIP Unicode entry round trip failed.');
      }
    } finally {
      reader.close();
    }
  });
  File(zipPath).deleteSync();
  // Fixture from the locked flutter_7zip example/test.7z (MIT).
  final sevenZip = File('$cachePath/ohos_smoke.7z');
  sevenZip.writeAsBytesSync(
    base64Decode(
      'N3q8ryccAARKPtfvlQAAAAAAAAAhAAAAAAAAAP3zJ2sBABJIZWxsbyBXb3JsZCFIZWxsbyAyAAAAgTMHrg/Pbu6MB8hDf0Gx+v3nLX3pbT1BZLwWjK7zxq9ZmyShC7zx0LLLXlD7c8S9mp99Sp+hdIvrgyQQn0aE4StNOXZRG/Wq8FaD3u3+bYmj2y6mFLxPXVvWMIc2dk/d1gnR4ylhussJxoTH6usm0JFuAD8fADzNhZPgABcGFwEJfgAHCwEAASMDAQEFXQAQAAAMgJ4KAUYr0MAAAA==',
    ),
  );
  final archive = SZArchive.open(sevenZip.path);
  try {
    final contents = <String, String>{};
    for (var i = 0; i < archive.numFiles; i++) {
      final entry = archive.getFile(i);
      if (!entry.isDirectory) {
        contents[entry.name] = utf8.decode(archive.extractFile(i));
      }
    }
    if (contents['1.txt'] != 'Hello World!' ||
        contents['dir/2.txt'] != 'Hello 2') {
      throw StateError('7z contents did not match.');
    }
  } finally {
    archive.dispose();
    sevenZip.deleteSync();
  }
}

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
    await checkQuickJs();
    await Isolate.run(checkQuickJs);
    await checkArchivesAndPng(cache.path);
    result =
        'PASS: OHOS sandbox, package info, SQLite WAL, QuickJS, ZIP, 7z, PNG and isolates\n'
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
