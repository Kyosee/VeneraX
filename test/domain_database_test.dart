import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/source_platform.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  test('opens canonical database with baseline pragmas and schema', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final db = domain.db;
      final dbFile = File(DomainDatabase.databasePathFor(tempDir.path));
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((row) => row['name'] as String)
          .toSet();

      expect(dbFile.existsSync(), isTrue);
      expect(db.select('PRAGMA foreign_keys;').first['foreign_keys'], 1);
      expect(db.select('PRAGMA journal_mode;').first['journal_mode'], 'wal');
      expect(
        db.select('PRAGMA user_version;').first['user_version'],
        DomainDatabase.schemaVersion,
      );
      expect(
        tables,
        containsAll({
          'source_platforms',
          'source_platform_aliases',
          'comics',
          'comic_titles',
          'comic_sources',
          'source_tags',
          'comic_source_tags',
          'local_library_items',
          'import_batches',
          'chapters',
          'pages',
          'chapter_sources',
          'page_sources',
          'tags',
          'comic_tags',
          'chapter_collections',
          'chapter_collection_items',
          'page_orders',
          'page_order_items',
          'reader_sessions',
          'reader_tabs',
          'history_events',
          'favorites',
          'remote_match_candidates',
        }),
      );
      expect(
        db.select('''
          SELECT platform_id, canonical_key, kind
          FROM source_platforms
          WHERE platform_id = 'local';
          ''').single,
        containsPair('canonical_key', 'local'),
      );
      domain.ensureSourcePlatform(
        SourcePlatformResolver.fromSourceKey('picacg'),
        timestamp: 2,
      );
      expect(
        db.select('''
          SELECT alias, alias_type
          FROM source_platform_aliases
          WHERE platform_id = 'remote:picacg';
          ''').single,
        containsPair('alias', 'picacg'),
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('enforces foreign keys in canonical database', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      expect(
        () => domain.db.execute('''
          INSERT INTO local_library_items (
            comic_id,
            directory,
            created_at,
            updated_at
          ) VALUES ('missing-comic', 'local/path', 1, 1);
          '''),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('upserts comic source and related domain state', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final comicId = domain.ensureComicSource(
        platform: SourcePlatformResolver.fromSourceKey('picacg'),
        sourceComicId: 'abc',
        title: 'Title',
        subtitle: 'Sub',
        description: 'Desc',
        coverUri: 'cover.jpg',
        timestamp: 10,
      );
      domain.markFavorite(
        comicId: comicId,
        folderName: 'default',
        timestamp: 11,
      );
      domain.markRead(comicId: comicId, occurredAt: 12);

      expect(comicId, 'remote:picacg:abc');
      expect(
        domain.db.select('SELECT subtitle FROM comics WHERE comic_id = ?;', [
          comicId,
        ]).single,
        containsPair('subtitle', 'Sub'),
      );
      expect(
        domain.db
            .select('SELECT COUNT(*) AS count FROM favorites;')
            .single['count'],
        1,
      );
      expect(
        domain.db
            .select('SELECT COUNT(*) AS count FROM history_events;')
            .single['count'],
        1,
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });
}
