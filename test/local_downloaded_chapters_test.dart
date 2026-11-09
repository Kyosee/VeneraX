import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database database;
  late String previousDataPath;
  late String previousCachePath;
  late TargetPlatform? previousTarget;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('local-chapters-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    App.dataPath = root.path;
    App.cachePath = (await Directory('${root.path}/cache').create()).path;
    await Directory('${root.path}/fixture').create();
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    database = openRawDatabase('${root.path}/local.db');
  });

  tearDownAll(() async {
    database.dispose();
    await appdata.saveData(false);
    LocalManager().close();
    JsEngine().dispose();
    await root.delete(recursive: true);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    debugDefaultTargetPlatformOverride = previousTarget;
  });

  LocalComic comic(String id, List<String> downloaded) => LocalComic(
    id: id,
    title: 'Downloaded chapters $id',
    subtitle: 'Generated fixture',
    tags: const ['test'],
    directory: '${root.path}/fixture',
    chapters: const ComicChapters({
      'a': 'First chapter',
      'b': 'Second chapter',
      'c': 'Third chapter',
    }),
    cover: '',
    comicType: ComicType.local,
    downloadedChapters: downloaded,
    createdAt: DateTime.utc(2026),
  );

  List<String> storedChapters(String id) {
    final row = database.select(
      'SELECT downloadedChapters FROM comics WHERE id = ? AND comic_type = ?',
      [id, ComicType.local.value],
    ).single;
    return List<String>.from(jsonDecode(row['downloadedChapters'] as String));
  }

  test('first insert stores each downloaded chapter only once', () async {
    await LocalManager().add(comic('new', ['b', 'a', 'b']));
    expect(storedChapters('new'), ['b', 'a']);
    expect(LocalManager().find('new', ComicType.local)!.downloadedChapters, [
      'b',
      'a',
    ]);
  });

  test('repeated adds do not accumulate stored chapters', () async {
    final fixture = comic('repeated', ['b', 'a']);
    await LocalManager().add(fixture);
    await LocalManager().add(fixture);
    await LocalManager().add(fixture);
    expect(storedChapters(fixture.id), ['b', 'a']);
    expect(
      LocalManager().find(fixture.id, ComicType.local)!.downloadedChapters,
      ['b', 'a'],
    );
  });

  test('legacy duplicate rows read in first-occurrence order', () async {
    final fixture = comic('legacy', ['a']);
    await LocalManager().add(fixture);
    database.execute(
      'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?',
      [
        jsonEncode(['c', 'a', 'c', 'b', 'a']),
        fixture.id,
        ComicType.local.value,
      ],
    );
    expect(
      LocalManager().find(fixture.id, ComicType.local)!.downloadedChapters,
      ['c', 'a', 'b'],
    );
  });

  test(
    'new chapters merge with older downloads without losing order',
    () async {
      await LocalManager().add(comic('merged', ['b', 'a']));
      await LocalManager().add(comic('merged', ['c', 'b', 'c']));
      // Keep the existing new-first merge order, followed by older chapters.
      expect(storedChapters('merged'), ['c', 'b', 'a']);
      expect(
        LocalManager().find('merged', ComicType.local)!.downloadedChapters,
        ['c', 'b', 'a'],
      );
    },
  );
}
