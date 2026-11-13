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

  test('drops retired tables when upgrading an existing database', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final dbPath = DomainDatabase.databasePathFor(tempDir.path);
    File(dbPath).parent.createSync(recursive: true);
    final legacyDb = sqlite3.open(dbPath);
    legacyDb.execute('''
      CREATE TABLE comics (
        comic_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE page_orders (page_order_id TEXT PRIMARY KEY);
      CREATE TABLE reader_sessions (reader_session_id TEXT PRIMARY KEY);
      CREATE TABLE remote_match_candidates (
        remote_match_candidate_id INTEGER PRIMARY KEY
      );
      CREATE TABLE comic_titles (comic_title_id INTEGER PRIMARY KEY);
      CREATE TABLE chapters (chapter_id TEXT PRIMARY KEY);
      CREATE TABLE chapter_collection_items (
        chapter_collection_item_id INTEGER PRIMARY KEY,
        chapter_id TEXT NOT NULL,
        FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id)
      );
      CREATE TABLE history_events (
        history_event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        comic_id TEXT NOT NULL,
        occurred_at INTEGER NOT NULL,
        FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
      );
      ''');
    legacyDb.execute(
      "INSERT INTO comics (comic_id, title) VALUES ('local:a', 'Kept Title');",
    );
    legacyDb.execute(
      "INSERT INTO history_events (comic_id, occurred_at) "
      "VALUES ('local:a', 1), ('local:a', 1), ('local:a', 2);",
    );
    // A retired child still pointing at a chapter must not fail the drop.
    legacyDb.execute('''
      INSERT INTO chapters (chapter_id) VALUES ('local:a:chapter:1');
      INSERT INTO chapter_collection_items (chapter_id)
        VALUES ('local:a:chapter:1');
      ''');
    legacyDb.dispose();
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final db = domain.db;
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((row) => row['name'] as String)
          .toSet();

      expect(
        tables.intersection({
          'page_orders',
          'reader_sessions',
          'remote_match_candidates',
          'comic_titles',
          'history_events',
          'chapters',
          'chapter_collection_items',
        }),
        isEmpty,
      );
      // Pre-existing rows survive the upgrade and gain a normalized title.
      expect(
        db
            .select(
              "SELECT normalized_title FROM comics WHERE comic_id = 'local:a';",
            )
            .single['normalized_title'],
        'kepttitle',
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
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
          'works',
          'work_sources',
          'comic_sources',
          'source_tags',
          'comic_source_tags',
          'local_library_items',
          'comic_source_chapters',
          'tags',
          'favorites',
        }),
      );
      expect(
        tables.intersection({
          'history_events',
          'chapter_sources',
          'pages',
          'chapters',
          'comic_titles',
          'import_batches',
          'page_sources',
          'comic_tags',
          'chapter_collections',
          'chapter_collection_items',
          'page_orders',
          'page_order_items',
          'reader_sessions',
          'reader_tabs',
          'remote_match_candidates',
        }),
        isEmpty,
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
        SourcePlatformResolver.fromSourceKey('source_a'),
        timestamp: 2,
      );
      expect(
        db.select('''
          SELECT alias, alias_type
          FROM source_platform_aliases
          WHERE platform_id = 'remote:source_a';
          ''').single,
        containsPair('alias', 'source_a'),
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('recovers from incompatible canonical database schema', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final dbPath = DomainDatabase.databasePathFor(tempDir.path);
    File(dbPath).parent.createSync(recursive: true);
    final legacyDb = sqlite3.open(dbPath);
    legacyDb.execute('''
      CREATE TABLE source_platforms (
        platform_id TEXT PRIMARY KEY
      );
      ''');
    legacyDb.dispose();
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final db = domain.db;
      final backups = File(dbPath).parent
          .listSync()
          .where((entity) => entity.path.contains('venera.db.invalid-'))
          .toList();

      expect(domain.isInitialized, isTrue);
      expect(backups, isNotEmpty);
      expect(
        db.select('PRAGMA user_version;').first['user_version'],
        DomainDatabase.schemaVersion,
      );
      expect(
        db.select('''
          SELECT canonical_key
          FROM source_platforms
          WHERE platform_id = 'local';
          ''').single,
        containsPair('canonical_key', 'local'),
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
        platform: SourcePlatformResolver.fromSourceKey('source_a'),
        sourceComicId: 'abc',
        title: 'Title',
        subtitle: 'Sub',
        description: 'Desc',
        author: 'Author',
        status: '连载中',
        updateTime: '2026-05-11',
        coverUri: 'cover.jpg',
        tags: const ['genre:Action', 'status:连载中'],
        pageCount: 12,
        timestamp: 10,
      );
      domain.markFavorite(
        comicId: comicId,
        folderName: 'default',
        timestamp: 11,
      );

      expect(comicId, 'remote:source_a:abc');
      expect(
        domain.db.select('SELECT subtitle FROM comics WHERE comic_id = ?;', [
          comicId,
        ]).single,
        containsPair('subtitle', 'Sub'),
      );
      final baseInfo = domain.getComicBaseInfo(comicId)!;
      expect(baseInfo.author, 'Author');
      expect(baseInfo.status, '连载中');
      expect(baseInfo.updateTime, '2026-05-11');
      expect(baseInfo.tags, contains('genre:Action'));
      expect(baseInfo.pageCount, 12);
      expect(
        domain.db
            .select('SELECT COUNT(*) AS count FROM favorites;')
            .single['count'],
        1,
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'creates manual links and automatic candidates between source comics',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        final sourceA = SourcePlatformResolver.fromSourceKey('source_a');
        final sourceB = SourcePlatformResolver.fromSourceKey('source_b');

        final firstId = domain.ensureComicSource(
          platform: sourceA,
          sourceComicId: 'same-a',
          title: 'Same Title',
          author: 'Same Author',
          timestamp: 20,
        );
        final secondId = domain.ensureComicSource(
          platform: sourceB,
          sourceComicId: 'same-b',
          title: 'Same Title',
          author: 'Same Author',
          timestamp: 21,
        );

        final candidates = domain.getRelatedSources(secondId);
        expect(candidates.any((link) => link.status == 'candidate'), isTrue);
        final candidate = candidates.firstWhere(
          (link) => link.comicId == secondId && link.status == 'candidate',
        );
        domain.acceptWorkSource(
          workId: candidate.workId,
          comicId: candidate.comicId,
          timestamp: 22,
        );
        domain.ensureWorkForComic(comicId: secondId, timestamp: 23);
        final acceptedLinks = domain.getRelatedSources(secondId);
        expect(acceptedLinks, hasLength(2));
        expect(
          acceptedLinks.map((link) => link.comicId).toSet().length,
          acceptedLinks.length,
        );

        final workId = domain.linkSourceComics(
          sourcePlatform: sourceA,
          sourceComicId: 'same-a',
          targetPlatform: sourceB,
          targetSourceComicId: 'same-b',
          timestamp: 24,
        );
        final links = domain.getRelatedSources(firstId);
        expect(workId, startsWith('work:'));
        expect(links.where((link) => link.status == 'accepted'), hasLength(2));
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    },
  );

  test('removeComicSource purges mirror so a reused local id starts clean', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final local = SourcePlatformResolver.fromSourceKey('local');
      final comicId = domain.ensureComicSource(
        platform: local,
        sourceComicId: '1',
        title: 'Old Comic',
        coverUri: 'cover.jpg',
        timestamp: 30,
      );
      domain.markLocalLibraryItem(
        comicId: comicId,
        directory: 'old-comic',
        timestamp: 31,
      );
      // Simulate an accepted work link carrying the old comic's metadata.
      domain.ensureWorkForComic(comicId: comicId, timestamp: 32);
      expect(domain.getComicBaseInfo(comicId)!.title, 'Old Comic');

      domain.removeComicSource(platform: local, sourceComicId: '1');

      expect(domain.getComicBaseInfo(comicId), isNull);
      for (final table in [
        'comic_sources',
        'work_sources',
        'works',
        'local_library_items',
      ]) {
        expect(
          domain.db
              .select('SELECT COUNT(*) AS count FROM $table;')
              .single['count'],
          0,
          reason: '$table should be empty after purge',
        );
      }

      // The next comic reusing id '1' must not inherit the old title.
      final reusedId = domain.ensureComicSource(
        platform: local,
        sourceComicId: '1',
        title: 'New Comic',
        timestamp: 40,
      );
      expect(domain.getComicBaseInfo(reusedId)!.title, 'New Comic');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('replaceSourceChapters skips the rewrite when nothing changed', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final platform = SourcePlatformResolver.fromSourceKey('source_a');
      final comicId = domain.ensureComicSource(
        platform: platform,
        sourceComicId: 'abc',
        title: 'Title',
        timestamp: 10,
      );
      List<DomainComicChapterInfo> chapters(String secondTitle) => [
        DomainComicChapterInfo(
          chapterId: '$comicId:chapter:1',
          title: 'Ch 1',
          chapterIndex: 1,
          sourceChapterId: 'c1',
          sourceChapterIndex: 1,
        ),
        DomainComicChapterInfo(
          chapterId: '$comicId:chapter:2',
          title: secondTitle,
          chapterIndex: 2,
          sourceChapterId: 'c2',
          sourceChapterIndex: 2,
        ),
      ];
      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: chapters('Ch 2'),
      );
      int changes() =>
          domain.db.select('SELECT total_changes() AS c;').single['c'] as int;
      final before = changes();
      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: chapters('Ch 2'),
      );
      expect(
        changes(),
        before,
        reason: 'an unchanged chapter list must not be rewritten',
      );

      // A real change must still rewrite.
      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: chapters('Ch 2 (fixed)'),
      );
      expect(changes(), greaterThan(before));
      expect(
        domain
            .getSourceChapters(platform: platform, sourceComicId: 'abc')
            .map((chapter) => chapter.title),
        ['Ch 1', 'Ch 2 (fixed)'],
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('chapter lists keep grouping, explicit indexes and order', () async {
    final tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final platform = SourcePlatformResolver.fromSourceKey('source_a');
      final comicId = domain.ensureComicSource(
        platform: platform,
        sourceComicId: 'abc',
        title: 'Title',
        timestamp: 10,
      );
      List<DomainComicChapterInfo> stored() =>
          domain.getSourceChapters(platform: platform, sourceComicId: 'abc');

      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: [
          DomainComicChapterInfo(
            chapterId: '$comicId:chapter:1',
            title: 'A1',
            chapterIndex: 1,
            sourceChapterId: 'a1',
            sourceChapterIndex: 1,
            sourceChapterGroup: 1,
            sourceGroupTitle: 'Main',
            sourceChapterIndexInGroup: 1,
          ),
          DomainComicChapterInfo(
            chapterId: '$comicId:chapter:2',
            title: 'B1',
            chapterIndex: 2,
            sourceChapterId: 'b1',
            sourceChapterIndex: 2,
            sourceChapterGroup: 2,
            sourceGroupTitle: 'Extra',
            sourceChapterIndexInGroup: 1,
          ),
        ],
      );
      final grouped = stored();
      expect(grouped.map((c) => c.title), ['A1', 'B1']);
      expect(grouped.map((c) => c.sourceChapterId), ['a1', 'b1']);
      expect(grouped.map((c) => c.chapterId), [
        '$comicId:chapter:1',
        '$comicId:chapter:2',
      ]);
      expect(grouped.map((c) => c.chapterIndex), [1, 2]);
      expect(grouped.map((c) => c.sourceChapterIndex), [1, 2]);
      expect(grouped.map((c) => c.sourceChapterGroup), [1, 2]);
      expect(grouped.map((c) => c.sourceGroupTitle), ['Main', 'Extra']);
      expect(grouped.map((c) => c.sourceChapterIndexInGroup), [1, 1]);

      // Indexes that differ from the position, given out of order, and a
      // chapter without an id of its own.
      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: [
          DomainComicChapterInfo(
            chapterId: '$comicId:chapter:5',
            title: 'Five',
            chapterIndex: 5,
            sourceChapterIndex: 9,
          ),
          DomainComicChapterInfo(
            chapterId: '$comicId:chapter:2',
            title: 'Two',
            chapterIndex: 2,
            sourceChapterId: 'two',
            sourceChapterIndex: 3,
          ),
        ],
      );
      final sparse = stored();
      expect(sparse.map((c) => c.title), ['Two', 'Five']);
      expect(sparse.map((c) => c.chapterIndex), [2, 5]);
      expect(sparse.map((c) => c.sourceChapterIndex), [3, 9]);
      expect(sparse.map((c) => c.sourceChapterId), [
        'two',
        '$comicId:chapter:5',
      ]);
      expect(sparse.map((c) => c.sourceChapterGroup), [null, null]);

      domain.replaceSourceChapters(
        platform: platform,
        sourceComicId: 'abc',
        chapters: const [],
      );
      expect(stored(), isEmpty);
      expect(
        domain.db
            .select('SELECT COUNT(*) AS count FROM comic_source_chapters;')
            .single['count'],
        1,
        reason: 'a list is one row however many chapters it has',
      );
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  group('chapter rows written by older versions', () {
    late Directory tempDir;
    late SourcePlatformRef platform;
    late int comicSourceId;

    /// Opens a current database holding one comic, then hands back a raw
    /// handle so a test can add the tables an older version would have left.
    Future<Database> seededLegacyFile({bool staleCompactRow = false}) async {
      final domain = DomainDatabase();
      await domain.init(tempDir.path);
      final comicId = domain.ensureComicSource(
        platform: platform,
        sourceComicId: 'abc',
        title: 'Title',
        timestamp: 10,
      );
      if (staleCompactRow) {
        domain.replaceSourceChapters(
          platform: platform,
          sourceComicId: 'abc',
          chapters: [
            DomainComicChapterInfo(
              chapterId: '$comicId:chapter:1',
              title: 'Stale',
              chapterIndex: 1,
              sourceChapterId: 'stale',
              sourceChapterIndex: 1,
            ),
          ],
        );
      }
      comicSourceId =
          domain.db
                  .select('SELECT comic_source_id FROM comic_sources;')
                  .single['comic_source_id']
              as int;
      domain.close();
      final legacy = sqlite3.open(DomainDatabase.databasePathFor(tempDir.path));
      legacy.execute('''
        CREATE TABLE chapters (
          chapter_id TEXT PRIMARY KEY,
          comic_id TEXT NOT NULL,
          title TEXT NOT NULL,
          chapter_index INTEGER NOT NULL,
          source_chapter_id TEXT,
          is_hidden INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          UNIQUE (comic_id, chapter_index),
          FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
        );
        CREATE TABLE pages (
          page_id TEXT PRIMARY KEY,
          chapter_id TEXT NOT NULL,
          FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id)
            ON DELETE CASCADE
        );
        INSERT INTO chapters (
          chapter_id, comic_id, title, chapter_index, source_chapter_id,
          created_at
        ) VALUES
          ('remote:source_a:abc:chapter:1', 'remote:source_a:abc', 'Ch 1', 1, 'c1', 1),
          ('remote:source_a:abc:chapter:2', 'remote:source_a:abc', 'Ch 2', 2, 'c2', 1),
          -- Left behind when the list shrank: no chapter_sources row.
          ('remote:source_a:abc:chapter:3', 'remote:source_a:abc', 'Gone', 3, 'c3', 1);
        ''');
      return legacy;
    }

    Future<DomainDatabase> reopen() async {
      final domain = DomainDatabase();
      await domain.init(tempDir.path);
      return domain;
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_domain_db_');
      platform = SourcePlatformResolver.fromSourceKey('source_a');
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('fold into one row and replace a stale compact list', () async {
      final legacy = await seededLegacyFile(staleCompactRow: true);
      legacy.execute('''
        CREATE TABLE chapter_sources (
          chapter_source_id INTEGER PRIMARY KEY AUTOINCREMENT,
          chapter_id TEXT NOT NULL,
          comic_source_id INTEGER NOT NULL,
          source_chapter_id TEXT,
          source_chapter_index INTEGER,
          source_title TEXT,
          source_chapter_group INTEGER,
          source_group_title TEXT,
          source_chapter_index_in_group INTEGER,
          UNIQUE (comic_source_id, source_chapter_id),
          FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id)
            ON DELETE CASCADE,
          FOREIGN KEY (comic_source_id)
            REFERENCES comic_sources(comic_source_id) ON DELETE CASCADE
        );
        ''');
      legacy.execute(
        '''
        INSERT INTO chapter_sources (
          chapter_id, comic_source_id, source_chapter_id, source_chapter_index,
          source_title, source_chapter_group, source_group_title,
          source_chapter_index_in_group
        ) VALUES
          ('remote:source_a:abc:chapter:2', ?, 'c2', 2, 'Ch 2', 2, 'Extra', 1),
          ('remote:source_a:abc:chapter:1', ?, 'c1', 1, '', 1, 'Main', 1);
        ''',
        [comicSourceId, comicSourceId],
      );
      legacy.dispose();

      final domain = await reopen();
      try {
        final chapters = domain.getSourceChapters(
          platform: platform,
          sourceComicId: 'abc',
        );
        // An empty source_title falls back to the chapter's own title.
        expect(chapters.map((c) => c.title), ['Ch 1', 'Ch 2']);
        expect(chapters.map((c) => c.sourceChapterId), ['c1', 'c2']);
        expect(chapters.map((c) => c.sourceGroupTitle), ['Main', 'Extra']);
        expect(chapters.map((c) => c.sourceChapterGroup), [1, 2]);
        expect(
          domain.db
              .select("SELECT name FROM sqlite_master WHERE type = 'table';")
              .map((row) => row['name'])
              .toSet()
              .intersection({'chapters', 'chapter_sources', 'pages'}),
          isEmpty,
        );
      } finally {
        domain.close();
      }
    });

    test('convert even without the later group columns', () async {
      final legacy = await seededLegacyFile();
      legacy.execute('''
        CREATE TABLE chapter_sources (
          chapter_source_id INTEGER PRIMARY KEY AUTOINCREMENT,
          chapter_id TEXT NOT NULL,
          comic_source_id INTEGER NOT NULL,
          source_chapter_id TEXT,
          source_chapter_index INTEGER,
          source_title TEXT
        );
        ''');
      legacy.execute(
        '''
        INSERT INTO chapter_sources (
          chapter_id, comic_source_id, source_chapter_id, source_chapter_index,
          source_title
        ) VALUES
          ('remote:source_a:abc:chapter:1', ?, 'c1', 1, 'Ch 1'),
          ('remote:source_a:abc:chapter:2', ?, 'c2', 2, 'Ch 2');
        ''',
        [comicSourceId, comicSourceId],
      );
      legacy.dispose();

      final domain = await reopen();
      try {
        final chapters = domain.getSourceChapters(
          platform: platform,
          sourceComicId: 'abc',
        );
        expect(chapters.map((c) => c.title), ['Ch 1', 'Ch 2']);
        expect(chapters.map((c) => c.sourceChapterGroup), [null, null]);
      } finally {
        domain.close();
      }
    });
  });
}
