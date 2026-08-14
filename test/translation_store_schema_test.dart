import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';

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
      expect(
        db.select("select cache_key from translated_page;").length,
        1,
      );
    });

    test('rebuilds to the canonical schema when a foreign column is present',
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
      var rows = db.select("select cache_key, regions, time from translated_page;");
      expect(rows.length, 1);
      expect(rows.first['cache_key'], 'k');
    });

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

    test('keeps the newer row when the page was re-translated after upgrading',
        () {
      put('pageTranslation@ja>zh@src@cid@ch@1', '[{"text":"old"}]', 1);
      put('pageTranslation@2@ja>zh@src@cid@ch@1', '[{"text":"new"}]', 2);

      TranslationStore.migrateLegacyKeys(db);

      expect(keys(), ['pageTranslation@2@ja>zh@src@cid@ch@1']);
      expect(
        db.select('select regions from translated_page;').first['regions'],
        '[{"text":"new"}]',
      );
    });

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
    late CommonDatabase db;

    // The exact query TranslationStore.countByPrefix issues.
    int countByPrefix(String scopePrefix) {
      var escaped = scopePrefix
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      var rows = db.select(
        "select count(*) from translated_page "
        "where cache_key like ? escape '\\';",
        ['$escaped%'],
      );
      return rows.first[0] as int;
    }

    void put(String key) => db.execute(
          "insert into translated_page (cache_key, regions, time) "
          "values (?, '[]', 0);",
          [key],
        );

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

    test('counts only pages under the chapter prefix', () {
      // Two chapters of one comic; the prefix ends at the chapter boundary.
      put('pageTr@ja>zh@src@cid@ch1@img1');
      put('pageTr@ja>zh@src@cid@ch1@img2');
      put('pageTr@ja>zh@src@cid@ch2@img1');

      expect(countByPrefix('pageTr@ja>zh@src@cid@ch1@'), 2);
      expect(countByPrefix('pageTr@ja>zh@src@cid@ch2@'), 1);
      // Whole-comic prefix spans both chapters.
      expect(countByPrefix('pageTr@ja>zh@src@cid@'), 3);
    });

    test('a sibling chapter whose id is a prefix of another does not leak', () {
      // 'ch1' must not match rows of 'ch10' — the trailing '@' in the scope
      // prefix is what prevents it.
      put('pageTr@ja>zh@src@cid@ch1@img1');
      put('pageTr@ja>zh@src@cid@ch10@img1');
      put('pageTr@ja>zh@src@cid@ch10@img2');

      expect(countByPrefix('pageTr@ja>zh@src@cid@ch1@'), 1);
      expect(countByPrefix('pageTr@ja>zh@src@cid@ch10@'), 2);
    });

    test('LIKE wildcards inside a key are escaped, not matched', () {
      // A comic id containing '%' must be matched literally.
      put('pageTr@ja>zh@src@100%@ch1@img1');
      put('pageTr@ja>zh@src@100X@ch1@img1');

      // Without escaping the '%' the first prefix would also swallow the
      // second row; escaping keeps them distinct.
      expect(countByPrefix('pageTr@ja>zh@src@100%@ch1@'), 1);
    });
  });
}
