import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

import 'io.dart';

Future<File> exportAppData([bool sync = true]) async {
  final file = File(
    FilePath.join(
      App.cachePath,
      '${DateTime.now().millisecondsSinceEpoch}.venera',
    ),
  );
  final data = appdata.toJson();
  await file.writeAsString(jsonEncode({'appdata.json': data}));
  return file;
}

Future<void> importAppData(File file, [bool checkVersion = false]) async {
  throw UnsupportedError('Web data import is handled by web_helper.');
}

Future<void> importPicaData(File file) async {
  throw UnsupportedError('Pica data import is not supported on web.');
}
