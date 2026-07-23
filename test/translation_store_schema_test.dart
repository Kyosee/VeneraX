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
}
