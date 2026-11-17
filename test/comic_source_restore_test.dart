import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'identical restores retain sources and stale delayed init is ignored',
    () async {
      final root = await Directory.systemTemp.createTemp('source-restore-');
      App.dataPath = root.path;
      App.cachePath = (await Directory('${root.path}/cache').create()).path;
      appdata.settings['webdav'] = <String>[];
      const script = '''class RestoreFixture extends ComicSource {
  name = "Restore fixture";
  key = "restore_fixture";
  version = "1.0.0";
  minAppVersion = "0.0.0";
  comic = {};
  search = {};
  init() { globalThis.restoreInitCount++; }
}''';
      final sources = ComicSourceManager();
      final engine = JsEngine();
      await engine.init();
      engine.runCode('globalThis.restoreInitCount = 0;');
      await sources.init();
      Future<File> backup(String data) async {
        final archive = Archive();
        for (final entry in {
          'fixture.js': script,
          'restore_fixture.data': data,
        }.entries) {
          final bytes = utf8.encode(entry.value);
          archive.addFile(
            ArchiveFile('comic_source/${entry.key}', bytes.length, bytes),
          );
        }
        return File(
          '${root.path}/source.venera',
        ).writeAsBytes(ZipEncoder().encode(archive));
      }

      try {
        final first = await ComicSourceParser().createAndParse(
          script,
          'fixture.js',
        );
        sources.add(first);
        // Replace before its 50ms callback gets a chance to run.
        sources.remove(first.key);
        final second = await ComicSourceParser().parse(script, first.filePath);
        sources.add(second);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(engine.runCode('globalThis.restoreInitCount'), 1);
        await File(
          '${root.path}/comic_source/restore_fixture.data',
        ).writeAsString('{}');
        await importAppData(await backup('{}'), mergeTranslations: false);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(ComicSource.find(first.key), same(second));
        expect(engine.runCode('globalThis.restoreInitCount'), 1);
        await importAppData(
          await backup('{"account":["new"]}'),
          mergeTranslations: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(ComicSource.find(first.key), isNot(same(second)));
        expect(ComicSource.find(first.key)!.data['account'], ['new']);
        expect(engine.runCode('globalThis.restoreInitCount'), 2);
      } finally {
        sources.remove('restore_fixture');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await appdata.saveData(false);
        await appdata.writeImplicitData();
        engine.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
