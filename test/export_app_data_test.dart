import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_cover_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/translations.dart';

History _record(String id, String title) => History.fromMap({
  'type': ComicType.local.value,
  'time': DateTime(2026, 11, 15).millisecondsSinceEpoch,
  'title': title,
  'subtitle': '',
  'cover': '',
  'ep': 1,
  'page': 3,
  'id': id,
  'readEpisode': const <String>[],
  'max_page': null,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('venera-export-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    Directory(App.cachePath).createSync();
    final comics = Directory('${root.path}/comics')..createSync();
    File('${root.path}/local_path').writeAsStringSync(comics.path);
    await AppTranslation.init();
    await appdata.init();
    SingleInstanceCookieJar('${root.path}/cookie.db');
    await JsEngine().init();
    await ComicSourceManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await App.readLater.init();
    await LocalManager().init();
    await App.domain.init(App.dataPath);
    await TranslationStore().init();
  });

  tearDownAll(() {
    HistoryManager().close();
    LocalFavoritesManager().close();
    App.readLater.close();
    LocalManager().close();
    App.domain.close();
    TranslationStore().close();
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    JsEngine().dispose();
    root.deleteSync(recursive: true);
  });

  test('manual backups restore comic and collection covers even on a skipping device', () async {
    const ref = 'collection://picked.png';
    const remote = 'collection://other.jpg';
    final file = ComicCoverStore.fileFor(ref)!;
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    appdata.settings['disableSyncFields'] = '@customCovers';
    appdata.settings[ComicCoverStore.settingsKey] = {'a': {'same': ref}};
    appdata.settings[ComicCollectionStore.settingsKey] = [
      {'id': 'album', 'name': 'Series', 'customCover': ref},
    ];
    addTearDown(() async {
      appdata.settings['disableSyncFields'] = '';
      appdata.settings[ComicCoverStore.settingsKey] = {};
      appdata.settings[ComicCollectionStore.settingsKey] = [];
      await appdata.saveData(false);
    });

    final backup = await exportAppData(sync: false);
    final zip = ZipDecoder().decodeBytes(await backup.readAsBytes());
    expect(zip.findFile('collection_covers/picked.png')!.content, [1, 2, 3]);
    final compact = await exportAppData(includeCoverFiles: false, customCovers: ComicCoverStore.current);
    expect(ZipDecoder().decodeBytes(await compact.readAsBytes()).findFile('collection_covers/picked.png'), isNull);

    appdata.settings[ComicCoverStore.settingsKey] = {'b': {'same': remote}};
    appdata.settings[ComicCollectionStore.settingsKey] = [
      {'id': 'album', 'name': 'Local', 'customCover': remote},
    ];
    await file.delete();
    await importAppData(backup, restoreCustomCovers: false,
        loadCustomCovers: (_) => throw StateError('skipped device fetched images'));
    expect(ComicCoverStore.reference('b', 'same'), remote);
    expect(ComicCollectionStore.find('album')!.customCover, remote);
    expect(ComicCollectionStore.find('album')!.name, 'Series');
    expect(await file.exists(), isFalse);

    await expectLater(importAppData(compact,
        loadCustomCovers: (_) => throw StateError('download interrupted')), throwsStateError);
    expect(ComicCoverStore.reference('b', 'same'), remote);
    await importAppData(backup);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(ComicCoverStore.reference('a', 'same'), ref);
    expect(ComicCoverStore.reference('b', 'same'), isNull);
    expect(ComicCollectionStore.find('album')!.customCover, ref);
  });

  test('backups exclude atomic write files and keep saved data', () async {
    final sourceDir = Directory('${root.path}/comic_source')
      ..createSync(recursive: true);
    const saved = '{"setting":"saved"}';
    File('${sourceDir.path}/example.data').writeAsStringSync(saved);
    File('${sourceDir.path}/example.js').writeAsStringSync('// Script');
    File('${sourceDir.path}/example.data.tmp').writeAsStringSync('{"setting":');
    File('${sourceDir.path}/example.js.tmp').writeAsStringSync('// Incomplete');

    for (final sync in [true, false]) {
      final backup = await exportAppData(sync: sync);
      final archive = ZipDecoder().decodeBytes(backup.readAsBytesSync());
      expect(archive.findFile('comic_source/example.data.tmp'), isNull);
      expect(archive.findFile('comic_source/example.js.tmp'), isNull);
      expect(
        utf8.decode(archive.findFile('comic_source/example.data')!.content),
        saved,
      );
      expect(archive.findFile('comic_source/example.js'), isNotNull);
    }
  });

  test(
    'sync carries totals only for translated comics and respects skipping',
    () async {
      final store = TranslationStore();
      const identity = TranslationChapterIdentity(
        scopePrefix: 'pageTranslation@2@auto>zh@src@translated@chapter@',
        sourceKey: 'src',
        comicId: 'translated',
        chapterId: 'chapter',
        sourceLang: 'auto',
        targetLang: 'zh',
      );
      store.put('${identity.scopePrefix}p1@', [], chapter: identity);
      store.recordChapterPageCount('src', 'translated', 'chapter', 294);
      store.recordChapterPageCount('src', 'untranslated', 'chapter', 500);
      final included = await exportAppData();
      final archive = ZipDecoder().decodeBytes(included.readAsBytesSync());
      final dbFile = File('${root.path}/exported-translation.db')
        ..writeAsBytesSync(archive.findFile('image_translation.db')!.content);
      final db = sqlite3.open(dbFile.path);
      try {
        expect(
          db.select('select comic_id, total_pages from chapter_page_count;'),
          [
            {'comic_id': 'translated', 'total_pages': 294},
          ],
        );
        expect(db.select('select count(*) from translated_page;').first[0], 1);
      } finally {
        db.dispose();
      }
      final skipped = await exportAppData(includeTranslations: false);
      final skippedArchive = ZipDecoder().decodeBytes(
        skipped.readAsBytesSync(),
      );
      expect(skippedArchive.findFile('image_translation.db'), isNull);
      expect(skippedArchive.findFile('image_translation_prefs.json'), isNull);
      expect(store.chapterPageCounts('src', 'untranslated'), {'chapter': 500});
    },
  );

  test('backups carry unsaved writes and only the comics kept here', () async {
    final repository = ComicStateRepository(domain: App.domain);
    final library = LocalComic(
      id: 'library',
      title: 'Library comic',
      subtitle: '',
      tags: const [],
      directory: '${root.path}/comics/library',
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2026, 11),
    );
    await LocalManager().add(library, library.id);
    LocalFavoritesManager().createFolder('Keep');
    LocalFavoritesManager().addComic(
      'Keep',
      FavoriteItem(
        id: 'favorite',
        name: 'Favorite comic',
        coverPath: '',
        author: '',
        type: ComicType.local,
        tags: const [],
      ),
    );
    HistoryManager().addHistory(_record('kept', 'Kept comic'));
    for (final id in ['library', 'favorite', 'kept', 'browsed']) {
      repository.mirrorComic(_record(id, '$id comic'));
    }
    expect(File('${root.path}/history.db-wal').lengthSync(), greaterThan(0));

    final backup = await exportAppData();
    final archive = ZipDecoder().decodeBytes(backup.readAsBytesSync());
    Database open(String name) {
      final file = File('${root.path}/unzipped/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(archive.findFile(name)!.content);
      final db = sqlite3.open(file.path);
      addTearDown(db.dispose);
      return db;
    }

    // Still only in the WAL file unless checkpointed before zipping.
    final history = open('history.db');
    expect(history.select('select page from history where id = ?', ['kept']), [
      {'page': 3},
    ]);
    final domain = open('data/venera.db');
    final comics = {
      for (final row in domain.select('select comic_id from comics'))
        row['comic_id'] as String,
    };
    String domainId(String id) => repository.identityFor('local', id).comicId;
    expect(comics, containsAll(['library', 'favorite', 'kept'].map(domainId)));
    expect(comics, isNot(contains(domainId('browsed'))));
  });
}
