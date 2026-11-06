import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  group('TranslationStore.migrateSchema', () {
    late CommonDatabase db;

    setUp(() {
      db = sqlite3.open(':memory:');
    });

    tearDown(() {
      db.dispose();
    });

    test('adds a column missing from an older own schema', () {
      // An earlier version without the `time` column.
      db.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text
        );
      ''');
      db.execute(
        "insert into translated_page (cache_key, regions) values ('k', '[]');",
      );

      TranslationStore.migrateSchema(db);

      var columns = db
          .select("PRAGMA table_info(translated_page);")
          .map((c) => c['name'] as String)
          .toSet();
      expect(columns, {'cache_key', 'regions', 'time'});
      // Existing rows survive the additive migration.
      expect(db.select("select cache_key from translated_page;").length, 1);
    });

    test(
      'rebuilds to the canonical schema when a foreign column is present',
      () {
        // A foreign app's table that happens to share the name.
        db.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text,
          time int,
          alien text not null
        );
      ''');
        db.execute(
          "insert into translated_page (cache_key, regions, time, alien) "
          "values ('k', '[]', 1, 'x');",
        );

        TranslationStore.migrateSchema(db);

        var columns = db
            .select("PRAGMA table_info(translated_page);")
            .map((c) => c['name'] as String)
            .toSet();
        // Foreign column dropped; the recognized columns are carried over.
        expect(columns, {'cache_key', 'regions', 'time'});
        var rows = db.select(
          "select cache_key, regions, time from translated_page;",
        );
        expect(rows.length, 1);
        expect(rows.first['cache_key'], 'k');
      },
    );

    test('is a no-op when the schema already matches', () {
      db.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text,
          time int
        );
      ''');
      db.execute(
        "insert into translated_page (cache_key, regions, time) "
        "values ('k', '[{\"l\":0}]', 5);",
      );

      TranslationStore.migrateSchema(db);

      var rows = db.select("select * from translated_page;");
      expect(rows.length, 1);
      expect(rows.first['time'], 5);
    });
  });

  // Generation 1 keys must be carried into the generation-2 namespace, not
  // dropped: the stored text costs OCR + a paid translation request to rebuild,
  // and #201 was every already-translated page reverting to untranslated after
  // updating.
  group('TranslationStore.migrateLegacyKeys', () {
    late CommonDatabase db;

    void put(String key, [String regions = '[]', int time = 0]) => db.execute(
      "insert into translated_page (cache_key, regions, time) values (?, ?, ?);",
      [key, regions, time],
    );

    List<Object?> keys() => db
        .select('select cache_key from translated_page order by cache_key;')
        .map((row) => row['cache_key'])
        .toList();

    setUp(() {
      db = sqlite3.open(':memory:');
      db.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text,
          time int
        );
      ''');
    });

    tearDown(() => db.dispose());

    test('rewrites generation 1 keys into the current generation', () {
      put('pageTranslation@ja>zh@src@cid@ch@1', '[{"text":"x"}]', 7);

      TranslationStore.migrateLegacyKeys(db);

      expect(keys(), ['pageTranslation@2@ja>zh@src@cid@ch@1']);
      // The expensive part — the stored text — and its timestamp survive.
      var row = db.select('select regions, time from translated_page;').first;
      expect(row['regions'], '[{"text":"x"}]');
      expect(row['time'], 7);
    });

    test('leaves current and future generations alone', () {
      put('pageTranslation@2@ja>zh@src@cid@ch@1');
      put('pageTranslation@3@ja>zh@src@cid@ch@1');
      // A two-digit generation must not read as legacy.
      put('pageTranslation@10@ja>zh@src@cid@ch@1');
      put('other@row');

      TranslationStore.migrateLegacyKeys(db);

      expect(keys(), [
        'other@row',
        'pageTranslation@10@ja>zh@src@cid@ch@1',
        'pageTranslation@2@ja>zh@src@cid@ch@1',
        'pageTranslation@3@ja>zh@src@cid@ch@1',
      ]);
    });

    test(
      'keeps the newer row when the page was re-translated after upgrading',
      () {
        put('pageTranslation@ja>zh@src@cid@ch@1', '[{"text":"old"}]', 1);
        put('pageTranslation@2@ja>zh@src@cid@ch@1', '[{"text":"new"}]', 2);

        TranslationStore.migrateLegacyKeys(db);

        expect(keys(), ['pageTranslation@2@ja>zh@src@cid@ch@1']);
        expect(
          db.select('select regions from translated_page;').first['regions'],
          '[{"text":"new"}]',
        );
      },
    );

    test('is idempotent across restarts', () {
      put('pageTranslation@ja>zh@src@cid@ch@1', '[{"text":"x"}]', 7);

      TranslationStore.migrateLegacyKeys(db);
      TranslationStore.migrateLegacyKeys(db);

      expect(keys(), ['pageTranslation@2@ja>zh@src@cid@ch@1']);
      expect(
        db.select('select regions from translated_page;').first['regions'],
        '[{"text":"x"}]',
      );
    });

    test('an image key containing @ still migrates whole', () {
      // Image keys are URLs and may contain the field separator; the rewrite
      // only replaces the leading prefix and must not split on later '@'.
      put('pageTranslation@ja>zh@src@cid@ch@https://h/a@b.jpg');

      TranslationStore.migrateLegacyKeys(db);

      expect(keys(), ['pageTranslation@2@ja>zh@src@cid@ch@https://h/a@b.jpg']);
    });
  });

  // Mirrors TranslationStore.countByPrefix against a raw in-memory db (the
  // store itself needs DatabaseGateway + IO). Guards the two properties the
  // chapter-picker "already translated" fallback relies on: a chapter prefix
  // counts only that chapter's pages, and LIKE wildcards inside a stored key
  // cannot widen the match.
  group('countByPrefix scoping', () {
    late Directory tempDir;
    late String originalDataPath;
    late TranslationStore store;

    void put(String key) => store.put(key, const []);

    setUp(() async {
      originalDataPath = App.dataPath;
      tempDir = await Directory.systemTemp.createTemp('venera-count-');
      App.dataPath = tempDir.path;
      store = TranslationStore.create();
      await store.init();
    });

    tearDown(() async {
      store.close();
      App.dataPath = originalDataPath;
      await tempDir.delete(recursive: true);
    });

    test('counts only pages under the chapter prefix', () {
      // Two chapters of one comic; the prefix ends at the chapter boundary.
      put('pageTranslation@2@ja>zh@src@cid@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@cid@ch1@p2@');
      put('pageTranslation@2@ja>zh@src@cid@ch2@p1@');

      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@ch1@'), 2);
      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@ch2@'), 1);
      // Whole-comic prefix spans both chapters.
      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@'), 3);
    });

    test('a sibling chapter whose id is a prefix of another does not leak', () {
      // 'ch1' must not match rows of 'ch10' — the trailing '@' in the scope
      // prefix is what prevents it.
      put('pageTranslation@2@ja>zh@src@cid@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@cid@ch10@p1@');
      put('pageTranslation@2@ja>zh@src@cid@ch10@p2@');

      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@ch1@'), 1);
      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@ch10@'), 2);
    });

    test('wildcard characters and letter case match literally', () {
      put('pageTranslation@2@ja>zh@src@100%@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@100X@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@a_b@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@aXb@ch1@p1@');
      put('pageTranslation@2@ja>zh@src@CID@ch1@p1@');

      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@100%@ch1@'), 1);
      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@a_b@'), 1);
      // Comic ids are case sensitive.
      expect(store.countByPrefix('pageTranslation@2@ja>zh@src@cid@'), 0);
    });
  });

  group('TranslationStore chapter index', () {
    late Directory tempDir;
    late String originalDataPath;
    late TranslationStore store;

    TranslationChapterIdentity chapter({
      String chapterId = 'ch1',
      String sourceLang = 'ja',
      String targetLang = 'zh',
      String title = 'Chapter 1',
    }) {
      return TranslationChapterIdentity(
        scopePrefix:
            'pageTranslation@2@$sourceLang>$targetLang@src@comic@$chapterId@',
        sourceKey: 'src',
        comicId: 'comic',
        chapterId: chapterId,
        sourceLang: sourceLang,
        targetLang: targetLang,
        comicTitle: 'Comic',
        comicCover: 'https://example.com/cover.jpg',
        chapterTitle: title,
      );
    }

    setUp(() async {
      originalDataPath = App.dataPath;
      tempDir = await Directory.systemTemp.createTemp(
        'venera-translation-store-',
      );
      App.dataPath = tempDir.path;
      store = TranslationStore.create();
      await store.init();
    });

    tearDown(() async {
      store.close();
      App.dataPath = originalDataPath;
      await tempDir.delete(recursive: true);
    });

    test('put indexes pages and aggregates chapters into a comic', () {
      var first = chapter();
      var second = chapter(chapterId: 'ch2', title: 'Chapter 2');

      store.put('${first.scopePrefix}page1', const [], chapter: first);
      store.put('${first.scopePrefix}page2', const [], chapter: first);
      store.put('${second.scopePrefix}page1', const [], chapter: second);

      expect(store.chaptersFor('src', 'comic'), hasLength(2));
      expect(
        store
            .chaptersFor('src', 'comic')
            .firstWhere((item) => item.identity.chapterId == 'ch1')
            .pageCount,
        2,
      );
      expect(store.comics, hasLength(1));
      expect(store.comics.single.chapterCount, 2);
      expect(store.comics.single.pageCount, 3);
      expect(store.comics.single.title, 'Comic');
    });

    // #287: the key used to end with the image key — a source url online, an
    // absolute file:// path once downloaded — so downloading a pre-translated
    // chapter made every page read as untranslated. Reading now adopts the old
    // row onto the transport-independent key instead of re-translating.
    test('adoptLegacyKey moves a transport-keyed row to the stable key', () {
      var identity = chapter();
      var legacyKey = '${identity.scopePrefix}https://cdn/page-1.jpg';
      var stableKey = '${identity.scopePrefix}p1@';
      store.put(legacyKey, [
        TranslatedRegion(
          rect: IntRect(1, 2, 30, 40),
          text: 'translated',
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
          lineHeight: 10,
        ),
      ]);

      var adopted = store.adoptLegacyKey(legacyKey, stableKey);

      expect(adopted, isNotNull);
      expect(adopted!.single.text, 'translated');
      // Readable under the stable key from now on, and the old row is gone so
      // the adoption never repeats.
      expect(store.get(stableKey)?.single.text, 'translated');
      expect(store.get(legacyKey), isNull);
    });

    test('adoptLegacyKey keeps an existing stable row and drops the old one', () {
      var identity = chapter();
      var legacyKey = '${identity.scopePrefix}https://cdn/page-1.jpg';
      var stableKey = '${identity.scopePrefix}p1@';
      store.put(legacyKey, const []);
      store.put(stableKey, [
        TranslatedRegion(
          rect: IntRect(0, 0, 10, 10),
          text: 'newer',
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
          lineHeight: 10,
        ),
      ]);

      expect(store.adoptLegacyKey(legacyKey, stableKey)?.single.text, 'newer');
      expect(store.get(legacyKey), isNull);
    });

    test('adoptLegacyKey reports nothing to adopt', () {
      var identity = chapter();
      expect(
        store.adoptLegacyKey(
          '${identity.scopePrefix}https://cdn/page-1.jpg',
          '${identity.scopePrefix}p1@',
        ),
        isNull,
      );
    });

    test('recordExistingChapter lazily indexes durable page rows', () {
      var identity = chapter();
      store.put('${identity.scopePrefix}page1', const []);

      expect(store.chapters, isEmpty);
      expect(store.recordExistingChapter(identity), 1);
      expect(store.chapters.single.identity.chapterTitle, 'Chapter 1');
      expect(store.chapters.single.pageCount, 1);
    });

    test('init backfills the chapter index from legacy page rows', () async {
      store.close();
      var path = '${tempDir.path}/image_translation.db';
      var legacy = sqlite3.open(path);
      legacy.execute('drop table translated_chapter_index;');
      legacy.execute('insert into translated_page values (?, ?, ?);', [
        'pageTranslation@ja>zh@null@localComic@ch1@page1',
        '[]',
        10,
      ]);
      legacy.execute('insert into translated_page values (?, ?, ?);', [
        'pageTranslation@ja>zh@null@localComic@ch1@https://h/a@b.jpg',
        '[]',
        20,
      ]);
      legacy.dispose();

      store = TranslationStore.create();
      await store.init();

      expect(store.chapters, hasLength(1));
      var indexed = store.chapters.single;
      expect(
        indexed.identity.scopePrefix,
        'pageTranslation@2@ja>zh@null@localComic@ch1@',
      );
      expect(indexed.identity.sourceKey, 'local');
      expect(indexed.identity.comicId, 'localComic');
      expect(indexed.identity.chapterId, 'ch1');
      expect(indexed.pageCount, 2);
      expect(indexed.updatedAt.millisecondsSinceEpoch, 20);
      expect(store.comics, hasLength(1));
    });

    test('metadata hydration updates comic cover and chapter titles', () {
      var identity = chapter();
      store.put('${identity.scopePrefix}page1', const [], chapter: identity);

      store.updateComicMetadata(
        'src',
        'comic',
        comicTitle: 'Loaded comic',
        comicCover: 'https://example.com/loaded.jpg',
        chapterTitles: {'ch1': 'Loaded chapter'},
      );

      var indexed = store.chapters.single;
      expect(indexed.identity.comicTitle, 'Loaded comic');
      expect(indexed.identity.comicCover, 'https://example.com/loaded.jpg');
      expect(indexed.identity.chapterTitle, 'Loaded chapter');
      expect(store.comics.single.title, 'Loaded comic');
      expect(store.comics.single.cover, 'https://example.com/loaded.jpg');
    });

    test(
      'language pairs stay separate and filters select the requested one',
      () {
        var ja = chapter();
        var en = chapter(sourceLang: 'en', targetLang: 'ko');
        store.put('${ja.scopePrefix}page1', const [], chapter: ja);
        store.put('${en.scopePrefix}page1', const [], chapter: en);

        expect(
          store.chaptersFor('src', 'comic', sourceLang: 'ja', targetLang: 'zh'),
          hasLength(1),
        );
        expect(store.comics, hasLength(2));
      },
    );

    test('prefix deletion and clear remove index rows with their pages', () {
      var first = chapter();
      var second = chapter(chapterId: 'ch2', title: 'Chapter 2');
      store.put('${first.scopePrefix}page1', const [], chapter: first);
      store.put('${second.scopePrefix}page1', const [], chapter: second);

      expect(store.deleteByPrefix(first.scopePrefix), 1);
      expect(store.chapters.map((item) => item.identity.chapterId), ['ch2']);
      expect(store.clearAll(), 1);
      expect(store.chapters, isEmpty);
      expect(store.comics, isEmpty);
    });

    test(
      'merge carries indexed chapters and tolerates a legacy source',
      () async {
        var identity = chapter();
        var sourcePath = '${tempDir.path}/source.db';
        var source = sqlite3.open(sourcePath);
        source.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text,
          time int
        );
        create table translated_chapter_index (
          scope_prefix text primary key,
          source_key text not null,
          comic_id text not null,
          chapter_id text not null,
          source_lang text not null,
          target_lang text not null,
          comic_title text not null default '',
          comic_cover text not null default '',
          chapter_title text not null default '',
          page_count int not null default 0,
          updated_at int not null default 0
        );
      ''');
        source.execute('insert into translated_page values (?, ?, ?);', [
          '${identity.scopePrefix}page1',
          '[]',
          12,
        ]);
        source.execute(
          'insert into translated_chapter_index values '
          '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            identity.scopePrefix,
            identity.sourceKey,
            identity.comicId,
            identity.chapterId,
            identity.sourceLang,
            identity.targetLang,
            identity.comicTitle,
            identity.comicCover,
            identity.chapterTitle,
            1,
            12,
          ],
        );
        source.dispose();

        expect((await store.mergeFrom(sourcePath)).applied, 1);
        expect(store.chapters.single.pageCount, 1);
        expect(store.chapters.single.identity.comicTitle, 'Comic');

        var legacyPath = '${tempDir.path}/legacy.db';
        var legacy = sqlite3.open(legacyPath);
        legacy.execute('''
        create table translated_page (
          cache_key text primary key,
          regions text,
          time int
        );
      ''');
        legacy.execute('insert into translated_page values (?, ?, ?);', [
          'pageTranslation@2@ja>zh@src@other@ch1@page1',
          '[]',
          20,
        ]);
        legacy.dispose();

        expect((await store.mergeFrom(legacyPath)).applied, 1);
        expect(store.count, 2);
        expect(store.chapters, hasLength(2));
        expect(
          store.chapters
              .firstWhere((item) => item.identity.comicId == 'other')
              .pageCount,
          1,
        );
      },
    );
  });

  group('TranslationStore merge', () {
    const ch1 = 'pageTranslation@2@ja>zh@src@comic@ch1@';
    const ch2 = 'pageTranslation@2@ja>zh@src@comic@ch2@';
    const p1 = '${ch1}p1@';
    const p2 = '${ch2}p1@';

    late Directory tempDir;
    late String originalDataPath;
    late TranslationStore store;
    var opened = <TranslationStore>[];

    int now() => DateTime.now().millisecondsSinceEpoch;

    String regions(String text) => jsonEncode([
      {'l': 0, 't': 0, 'r': 10, 'b': 10, 'text': text, 'bg': 0, 'fg': 0},
    ]);

    List<TranslatedRegion> region(String text) => [
      TranslatedRegion(
        rect: IntRect(0, 0, 10, 10),
        text: text,
        backgroundColor: 0,
        textColor: 0,
      ),
    ];

    String? textOf(TranslationStore s, String key) => s.get(key)?.single.text;

    // A store file as another device would upload it.
    String source(
      String name, {
      List<(String, String, int)> pages = const [],
      List<(String, int)> deletions = const [],
      List<(String, String)> index = const [],
    }) {
      var path = '${tempDir.path}/$name.db';
      var db = sqlite3.open(path);
      db.execute('''
        create table translated_page (
          cache_key text primary key, regions text, time int);
        create table translated_tombstone (
          scope_prefix text primary key, deleted_at int not null);
        create table translated_chapter_index (
          scope_prefix text primary key, source_key text not null,
          comic_id text not null, chapter_id text not null,
          source_lang text not null, target_lang text not null,
          comic_title text not null default '',
          comic_cover text not null default '',
          chapter_title text not null default '',
          page_count int not null default 0,
          updated_at int not null default 0);
      ''');
      for (var (key, value, time) in pages) {
        db.execute('insert into translated_page values (?, ?, ?);', [
          key,
          value,
          time,
        ]);
      }
      for (var (prefix, at) in deletions) {
        db.execute('insert into translated_tombstone values (?, ?);', [
          prefix,
          at,
        ]);
      }
      for (var (scope, title) in index) {
        db.execute(
          'insert into translated_chapter_index values '
          "(?, 'src', 'comic', 'ch1', 'ja', 'zh', ?, '', 'Chapter 1', 1, 1);",
          [scope, title],
        );
      }
      db.dispose();
      return path;
    }

    Future<TranslationStore> openStore(String name) async {
      var dir = Directory('${tempDir.path}/$name')..createSync();
      App.dataPath = dir.path;
      var s = TranslationStore.create();
      await s.init();
      opened.add(s);
      return s;
    }

    setUp(() async {
      originalDataPath = App.dataPath;
      tempDir = await Directory.systemTemp.createTemp('venera-merge-');
      opened = [];
      store = await openStore('local');
    });

    tearDown(() async {
      for (var s in opened) {
        s.close();
      }
      App.dataPath = originalDataPath;
      await tempDir.delete(recursive: true);
    });

    test('the newer copy of a page wins on both sides', () async {
      store.put(p1, region('old'));
      var newer = source('newer', pages: [(p1, regions('new'), now() + 60000)]);
      var result = await store.mergeFrom(newer);
      expect(textOf(store, p1), 'new');
      expect(result.applied, 1);
      expect(result.changedKeys, {p1});

      var older = source('older', pages: [(p1, regions('stale'), 5)]);
      result = await store.mergeFrom(older);
      expect(textOf(store, p1), 'new');
      expect(result.applied, 0);
      expect(result.changedKeys, isEmpty);
    });

    test('a deletion from another device removes what it covers', () async {
      store.put(p1, region('a'));
      store.put(p2, region('b'));
      var result = await store.mergeFrom(
        source('deleted', deletions: [(ch1, now() + 60000)]),
      );
      expect(store.get(p1), isNull);
      expect(textOf(store, p2), 'b');
      expect(result.changedKeys, {p1});
      expect(store.chapters.map((c) => c.identity.chapterId), ['ch2']);
    });

    test('deleted pages do not come back from a device that kept them', () async {
      store.put(p1, region('a'));
      store.deleteByPrefix(ch1);
      var result = await store.mergeFrom(
        source('stale', pages: [(p1, regions('a'), 5)]),
      );
      expect(store.get(p1), isNull);
      expect(result.applied, 0);

      store.put(p2, region('b'));
      store.clearAll();
      await store.mergeFrom(source('stale2', pages: [(p2, regions('b'), 5)]));
      expect(store.count, 0);
    });

    test('a page translated after a deletion survives it', () async {
      store.deleteByPrefix(ch1);
      await store.mergeFrom(
        source('fresh', pages: [(p1, regions('fresh'), now() + 60000)]),
      );
      expect(textOf(store, p1), 'fresh');

      // A deletion stamped ahead by a fast clock must not swallow a page
      // written here afterwards.
      var ahead = source('ahead', deletions: [(ch2, now() + 3600000)]);
      await store.mergeFrom(ahead);
      store.put(p2, region('mine'));
      await store.mergeFrom(ahead);
      expect(textOf(store, p2), 'mine');
    });

    test('a user import outranks local deletions and deletes nothing', () async {
      store.put(p1, region('a'));
      store.deleteByPrefix(ch1);
      store.put(p2, region('kept'));
      var file = source(
        'backup',
        pages: [(p1, regions('restored'), 5)],
        deletions: [(ch2, now() + 60000)],
      );
      var result = await store.mergeFrom(file, restore: true);
      expect(textOf(store, p1), 'restored');
      expect(textOf(store, p2), 'kept');
      expect(result.applied, 1);

      // Still there after the next background merge re-applies deletions.
      await store.mergeFrom(source('empty'));
      expect(textOf(store, p1), 'restored');
    });

    test('pages can be filed under this device\'s comic language', () async {
      var file = source(
        'export',
        pages: [(p1, regions('x'), 5)],
        index: [(ch1, 'Comic')],
      );
      await store.mergeFrom(file, languageFor: (_, _) => 'auto');
      expect(store.get(p1), isNull);
      expect(
        textOf(store, 'pageTranslation@2@auto>zh@src@comic@ch1@p1@'),
        'x',
      );
      var chapter = store.chapters.single.identity;
      expect(chapter.scopePrefix, 'pageTranslation@2@auto>zh@src@comic@ch1@');
      expect(chapter.sourceLang, 'auto');
      expect(chapter.comicTitle, 'Comic');
    });

    test('a malformed deletion in a foreign file is ignored', () async {
      store.put(p1, region('a'));
      await store.mergeFrom(
        source('bad', deletions: [('p', now() + 60000), ('', now() + 60000)]),
      );
      expect(textOf(store, p1), 'a');
    });

    test('a deletion travels between two devices via snapshots', () async {
      store.put(p1, region('a'));
      store.put(p2, region('b'));
      var upload = '${tempDir.path}/upload_a.db';
      await store.exportSnapshot(upload);

      var other = await openStore('other');
      await other.mergeFrom(upload);
      expect(other.count, 2);
      other.deleteByPrefix(ch1);
      var reply = '${tempDir.path}/upload_b.db';
      await other.exportSnapshot(reply);

      var result = await store.mergeFrom(reply);
      expect(store.get(p1), isNull);
      expect(textOf(store, p2), 'b');
      expect(result.changedKeys, {p1});

      // The first upload, still holding the page, does not undo it.
      await store.mergeFrom(upload);
      expect(store.get(p1), isNull);
    });
  });
}
