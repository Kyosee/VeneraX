import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/utils/io.dart';

class DomainComicBaseInfo {
  const DomainComicBaseInfo({
    required this.comicId,
    required this.title,
    required this.subtitle,
    required this.description,
    this.author,
    this.status,
    this.updateTime,
    this.language,
    this.coverUri,
    this.tags = const [],
    this.pageCount,
    this.workId,
  });

  final String comicId;
  final String title;
  final String subtitle;
  final String description;
  final String? author;
  final String? status;
  final String? updateTime;
  final String? language;
  final String? coverUri;
  final List<String> tags;
  final int? pageCount;
  final String? workId;
}

class DomainComicChapterInfo {
  const DomainComicChapterInfo({
    required this.chapterId,
    required this.title,
    required this.chapterIndex,
    this.sourceChapterId,
    this.sourceChapterIndex,
    this.sourceChapterGroup,
    this.sourceGroupTitle,
    this.sourceChapterIndexInGroup,
  });

  final String chapterId;
  final String title;
  final int chapterIndex;
  final String? sourceChapterId;
  final int? sourceChapterIndex;
  final int? sourceChapterGroup;
  final String? sourceGroupTitle;
  final int? sourceChapterIndexInGroup;
}

class DomainComicSourceLink {
  const DomainComicSourceLink({
    required this.workId,
    required this.comicId,
    required this.comicTitle,
    required this.platformId,
    required this.sourceComicId,
    required this.sourceName,
    required this.comicAuthor,
    required this.comicStatus,
    required this.comicCoverUri,
    required this.status,
    required this.linkSource,
    required this.confidence,
  });

  final String workId;
  final String comicId;
  final String comicTitle;
  final String platformId;
  final String sourceComicId;
  final String sourceName;
  final String? comicAuthor;
  final String? comicStatus;
  final String? comicCoverUri;
  final String status;
  final String linkSource;
  final double? confidence;
}

class DomainDatabase {
  static const schemaVersion = 5;
  static const dataDirectoryName = 'data';
  static const databaseFileName = 'venera.db';

  CommonDatabase? _db;
  String? _dbPath;

  CommonDatabase get db {
    final database = _db;
    if (database == null) {
      throw StateError('DomainDatabase is not initialized');
    }
    return database;
  }

  bool get isInitialized => _db != null;

  static String databasePathFor(String appDataPath) =>
      p.join(appDataPath, dataDirectoryName, databaseFileName);

  Future<void> init(String appDataPath) async {
    initSync(appDataPath);
  }

  void initSync(String appDataPath) {
    if (_db != null) {
      return;
    }
    final dbPath = databasePathFor(appDataPath);
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    _dbPath = dbPath;
    _db = _openDatabase(dbPath);
  }

  CommonDatabase _openDatabase(String dbPath) {
    try {
      final database = DatabaseGateway.instance.openManaged(dbPath);
      try {
        configure(database);
        createSchema(database);
        return database;
      } catch (_) {
        // The handle is registered by now — release it before the recovery
        // path moves the files aside and reopens.
        DatabaseGateway.instance.closeManaged(dbPath);
        rethrow;
      }
    } catch (_) {
      _backupDatabaseFiles(dbPath);
    }

    final recoveredDatabase = DatabaseGateway.instance.openManaged(dbPath);
    configure(recoveredDatabase);
    createSchema(recoveredDatabase);
    return recoveredDatabase;
  }

  void close() {
    final dbPath = _db == null ? null : _dbPath;
    _db = null;
    _dbPath = null;
    if (dbPath != null) {
      DatabaseGateway.instance.closeManaged(dbPath);
    }
  }

  /// Replaces this store's content with the database file at [sourcePath] by
  /// closing the connection, swapping the file, and reopening — see
  /// [restoreDatabaseFiles]. Runs inside the caller's exclusive window.
  Future<void> restoreFrom(String sourcePath) async {
    final dbPath = _dbPath;
    if (_db == null || dbPath == null) {
      throw StateError('DomainDatabase is not initialized; cannot restore');
    }
    DatabaseGateway.instance.closeManaged(dbPath);
    _db = null;
    try {
      restoreDatabaseFiles({dbPath: sourcePath});
    } finally {
      // The imported file may carry an older schema; the open-time pipeline is
      // idempotent, so the reopen re-runs it (pragmas, tables/columns, seeds).
      _db = _openDatabase(dbPath);
    }
  }

  static void _backupDatabaseFiles(String dbPath) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final path in [dbPath, '$dbPath-wal', '$dbPath-shm']) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      file.renameSync(_nextBackupPath(path, timestamp));
    }
  }

  static String _nextBackupPath(String path, int timestamp) {
    var backupPath = '$path.invalid-$timestamp';
    var index = 1;
    while (File(backupPath).existsSync()) {
      backupPath = '$path.invalid-$timestamp-$index';
      index++;
    }
    return backupPath;
  }

  static void configure(CommonDatabase db) {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
  }

  static void createSchema(CommonDatabase db) {
    db.execute(_schemaSql);
    migrateSchema(db);
    seedStaticData(db);
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  static void migrateSchema(CommonDatabase db) {
    void addColumnIfMissing(String table, String column, String definition) {
      final columns = db.select('PRAGMA table_info("$table");');
      if (!columns.any((element) => element['name'] == column)) {
        db.execute('ALTER TABLE "$table" ADD COLUMN $definition;');
      }
    }

    addColumnIfMissing('comics', 'author', 'author TEXT');
    addColumnIfMissing('comics', 'status', 'status TEXT');
    addColumnIfMissing('comics', 'update_time', 'update_time TEXT');
    addColumnIfMissing('comics', 'tags_json', 'tags_json TEXT');
    addColumnIfMissing('comics', 'page_count', 'page_count INTEGER');
    addColumnIfMissing(
      'comics',
      'base_info_updated_at',
      'base_info_updated_at INTEGER NOT NULL DEFAULT 0',
    );
    addColumnIfMissing('comics', 'normalized_title', 'normalized_title TEXT');
    _backfillNormalizedTitles(db);
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_comics_normalized_title '
      'ON comics(normalized_title);',
    );
    _foldLegacyChapterRows(db);
    _dropRetiredTables(db);
  }

  /// Chapter lists used to take one row per chapter in two tables, repeating
  /// the comic's id on every row — most of the file for a large library. Folds
  /// them into [comic_source_chapters] before the old tables are dropped.
  ///
  /// A legacy list replaces a compact one: with both present, only an older
  /// app version sharing this data can have written the legacy rows since.
  static void _foldLegacyChapterRows(CommonDatabase db) {
    bool hasTable(String name) => db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
      [name],
    ).isNotEmpty;
    if (!hasTable('chapter_sources') || !hasTable('chapters')) {
      return;
    }
    // The lists are a cache the app refills; a file this cannot read must not
    // fail the open, which would set the whole database aside.
    try {
      final columns = db
          .select('PRAGMA table_info("chapter_sources");')
          .map((row) => row['name'])
          .toSet();
      // Group columns arrived after the first release of the table.
      String optional(String column) =>
          columns.contains(column) ? 'cs.$column' : 'NULL';
      final rows = db.prepare('''
        SELECT
          cs.comic_source_id,
          src.comic_id,
          ch.chapter_index,
          cs.source_chapter_id,
          cs.source_chapter_index,
          COALESCE(NULLIF(cs.source_title, ''), ch.title) AS title,
          ${optional('source_chapter_group')} AS source_chapter_group,
          ${optional('source_group_title')} AS source_group_title,
          ${optional('source_chapter_index_in_group')}
            AS source_chapter_index_in_group
        FROM chapter_sources cs
        JOIN chapters ch ON ch.chapter_id = cs.chapter_id
        JOIN comic_sources src ON src.comic_source_id = cs.comic_source_id
        ORDER BY
          cs.comic_source_id,
          COALESCE(cs.source_chapter_index, ch.chapter_index),
          ch.chapter_index;
        ''');
      final insert = db.prepare(
        'INSERT OR REPLACE INTO comic_source_chapters '
        '(comic_source_id, chapters_json) VALUES (?, ?);',
      );
      db.execute('BEGIN TRANSACTION;');
      try {
        int? comicSourceId;
        var comicId = '';
        var chapters = <DomainComicChapterInfo>[];
        void flush() {
          if (comicSourceId != null) {
            insert.execute([comicSourceId, _encodeChapters(chapters, comicId)]);
          }
        }

        // A cursor, not select(): a big library holds 100k+ of these rows.
        final cursor = rows.selectCursor();
        while (cursor.moveNext()) {
          final row = cursor.current;
          final id = row['comic_source_id'] as int;
          if (id != comicSourceId) {
            flush();
            comicSourceId = id;
            comicId = row['comic_id'] as String;
            chapters = [];
          }
          final chapterIndex = row['chapter_index'] as int;
          chapters.add(
            DomainComicChapterInfo(
              chapterId: '$comicId:chapter:$chapterIndex',
              title: row['title'] as String? ?? '',
              chapterIndex: chapterIndex,
              sourceChapterId: row['source_chapter_id'] as String?,
              sourceChapterIndex: row['source_chapter_index'] as int?,
              sourceChapterGroup: row['source_chapter_group'] as int?,
              sourceGroupTitle: row['source_group_title'] as String?,
              sourceChapterIndexInGroup:
                  row['source_chapter_index_in_group'] as int?,
            ),
          );
        }
        flush();
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      } finally {
        rows.dispose();
        insert.dispose();
      }
    } catch (_) {}
  }

  /// Populates [normalized_title] for rows written before the column existed,
  /// so the matching index can serve every comic.
  static void _backfillNormalizedTitles(CommonDatabase db) {
    final rows = db.select(
      "SELECT comic_id, title FROM comics WHERE normalized_title IS NULL;",
    );
    if (rows.isEmpty) {
      return;
    }
    final statement = db.prepare(
      'UPDATE comics SET normalized_title = ? WHERE comic_id = ?;',
    );
    try {
      for (final row in rows) {
        statement.execute([
          _normalizeForMatch(row['title'] as String? ?? ''),
          row['comic_id'] as String,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// Drops tables that were provisioned ahead of features that never shipped,
  /// or that were only ever written to.
  /// Children are removed before their parents so foreign keys stay satisfied.
  static void _dropRetiredTables(CommonDatabase db) {
    const retiredTables = [
      // Append-only read log: one row per page turn, read by nothing.
      'history_events',
      'reader_tabs',
      'reader_sessions',
      'page_order_items',
      'page_orders',
      'page_sources',
      'chapter_collection_items',
      'chapter_collections',
      'import_batches',
      'comic_titles',
      'comic_tags',
      'remote_match_candidates',
      // Row-per-chapter storage, folded into comic_source_chapters. Last:
      // several tables above referenced these.
      'chapter_sources',
      'pages',
      'chapters',
    ];
    for (final table in retiredTables) {
      db.execute('DROP TABLE IF EXISTS $table;');
    }
  }

  static void seedStaticData(CommonDatabase db) {
    db.execute(
      '''
      INSERT OR IGNORE INTO source_platforms (
        platform_id,
        canonical_key,
        display_name,
        kind,
        legacy_int_type,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?);
      ''',
      [
        SourcePlatformResolver.localPlatformId,
        SourcePlatformResolver.localCanonicalKey,
        SourcePlatformResolver.localDisplayName,
        SourcePlatformKind.local.value,
        null,
        0,
      ],
    );
    db.execute(
      '''
      INSERT OR IGNORE INTO source_platform_aliases (
        platform_id,
        alias,
        alias_type,
        legacy_int_type
      ) VALUES (?, ?, ?, ?);
      ''',
      [
        SourcePlatformResolver.localPlatformId,
        SourcePlatformResolver.localCanonicalKey,
        SourceAliasType.canonicalKey.value,
        null,
      ],
    );
  }

  static String comicIdFor(SourcePlatformRef platform, String sourceComicId) {
    return '${platform.platformId}:$sourceComicId';
  }

  /// The work [ensureWorkForComic] creates for a comic that has none yet.
  static String _ownWorkIdFor(String comicId) => 'work:$comicId';

  /// [replaceMetadata] is for the caller that owns the comic's metadata (a
  /// local comic's own files): empty fields then clear stale values, and the
  /// comic's own work snapshot is refreshed. Other callers may pass partial
  /// data, so their empty fields keep what is stored.
  String ensureComicSource({
    required SourcePlatformRef platform,
    required String sourceComicId,
    required String title,
    String subtitle = '',
    String description = '',
    String? author,
    String? status,
    String? updateTime,
    String? language,
    String? coverUri,
    String? sourceUrl,
    String? sourceTitle,
    List<String>? tags,
    int? pageCount,
    int? timestamp,
    bool replaceMetadata = false,
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final comicId = comicIdFor(platform, sourceComicId);
    final tagsJson = tags == null ? null : jsonEncode(tags);
    final normalizedTitle = _normalizeForMatch(title);
    String merged(String column) => replaceMetadata
        ? 'excluded.$column'
        : 'COALESCE(excluded.$column, comics.$column)';
    ensureSourcePlatform(platform, timestamp: now);
    db.execute(
      '''
      INSERT INTO comics (
        comic_id,
        title,
        subtitle,
        description,
        author,
        status,
        update_time,
        language,
        cover_uri,
        tags_json,
        page_count,
        normalized_title,
        created_at,
        updated_at,
        base_info_updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(comic_id) DO UPDATE SET
        title = excluded.title,
        subtitle = excluded.subtitle,
        description = excluded.description,
        author = ${merged('author')},
        status = ${merged('status')},
        update_time = ${merged('update_time')},
        language = excluded.language,
        cover_uri = excluded.cover_uri,
        tags_json = ${merged('tags_json')},
        page_count = ${merged('page_count')},
        normalized_title = excluded.normalized_title,
        updated_at = excluded.updated_at,
        base_info_updated_at = excluded.base_info_updated_at;
      ''',
      [
        comicId,
        title,
        subtitle,
        description,
        _emptyToNull(author),
        _emptyToNull(status),
        _emptyToNull(updateTime),
        language,
        coverUri,
        tagsJson,
        pageCount,
        normalizedTitle,
        now,
        now,
        now,
      ],
    );
    db.execute(
      '''
      INSERT INTO comic_sources (
        comic_id,
        platform_id,
        source_comic_id,
        source_url,
        source_title,
        status,
        created_at,
        accepted_at
      ) VALUES (?, ?, ?, ?, ?, 'accepted', ?, ?)
      ON CONFLICT(platform_id, source_comic_id) DO UPDATE SET
        comic_id = excluded.comic_id,
        source_url = excluded.source_url,
        source_title = excluded.source_title,
        status = 'accepted',
        accepted_at = excluded.accepted_at;
      ''',
      [
        comicId,
        platform.platformId,
        sourceComicId,
        sourceUrl,
        sourceTitle ?? title,
        now,
        now,
      ],
    );
    if (replaceMetadata) {
      // The work row is a snapshot taken once and wins over the comic row in
      // [getComicBaseInfo], so a stale snapshot would outlive the fix above.
      db.execute(
        '''
        UPDATE works SET
          title = ?,
          author = ?,
          status = ?,
          update_time = ?,
          cover_uri = ?,
          description = ?,
          tags_json = ?,
          page_count = ?,
          updated_at = ?
        WHERE work_id = ?;
        ''',
        [
          _emptyToNull(title),
          _emptyToNull(author),
          _emptyToNull(status),
          _emptyToNull(updateTime),
          _emptyToNull(coverUri),
          _emptyToNull(description),
          tags == null || tags.isEmpty ? null : tagsJson,
          pageCount,
          now,
          _ownWorkIdFor(comicId),
        ],
      );
    }
    _createAutoWorkCandidates(
      comicId: comicId,
      title: title,
      author: author,
      timestamp: now,
    );
    return comicId;
  }

  DomainComicBaseInfo? getComicBaseInfo(String comicId) {
    final rows = db.select(
      '''
      SELECT
        c.comic_id,
        COALESCE(NULLIF(w.title, ''), c.title) AS title,
        c.subtitle,
        COALESCE(NULLIF(w.description, ''), c.description) AS description,
        COALESCE(NULLIF(w.author, ''), c.author) AS author,
        COALESCE(NULLIF(w.status, ''), c.status) AS status,
        COALESCE(NULLIF(w.update_time, ''), c.update_time) AS update_time,
        c.language,
        COALESCE(NULLIF(w.cover_uri, ''), c.cover_uri) AS cover_uri,
        COALESCE(NULLIF(w.tags_json, ''), c.tags_json) AS tags_json,
        COALESCE(w.page_count, c.page_count) AS page_count,
        w.work_id
      FROM comics c
      LEFT JOIN work_sources ws
        ON ws.comic_id = c.comic_id AND ws.link_status = 'accepted'
      LEFT JOIN works w ON w.work_id = ws.work_id
      WHERE c.comic_id = ?
      ORDER BY
        CASE ws.link_source WHEN 'manual' THEN 0 ELSE 1 END,
        ws.confidence DESC
      LIMIT 1;
      ''',
      [comicId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _baseInfoFromRow(rows.single);
  }

  DomainComicBaseInfo? getComicBaseInfoBySource({
    required SourcePlatformRef platform,
    required String sourceComicId,
  }) {
    final comicId = comicIdFor(platform, sourceComicId);
    return getComicBaseInfo(comicId);
  }

  void replaceSourceChapters({
    required SourcePlatformRef platform,
    required String sourceComicId,
    required List<DomainComicChapterInfo> chapters,
  }) {
    final sourceRows = db.select(
      '''
      SELECT comic_source_id, comic_id
      FROM comic_sources
      WHERE platform_id = ? AND source_comic_id = ?
      LIMIT 1;
      ''',
      [platform.platformId, sourceComicId],
    );
    if (sourceRows.isEmpty) {
      return;
    }
    final comicSourceId = sourceRows.single['comic_source_id'] as int;
    final encoded = _encodeChapters(
      chapters,
      sourceRows.single['comic_id'] as String,
    );
    // Bulk update checks re-mirror every followed comic's chapter list on each
    // pass. One indexed read to compare keeps an unchanged list from becoming
    // a write on the UI isolate (reader jank during a check).
    final stored = db.select(
      'SELECT chapters_json FROM comic_source_chapters '
      'WHERE comic_source_id = ?;',
      [comicSourceId],
    );
    if (stored.isNotEmpty && stored.single['chapters_json'] == encoded) {
      return;
    }
    db.execute(
      '''
      INSERT INTO comic_source_chapters (comic_source_id, chapters_json)
      VALUES (?, ?)
      ON CONFLICT(comic_source_id) DO UPDATE SET
        chapters_json = excluded.chapters_json;
      ''',
      [comicSourceId, encoded],
    );
  }

  List<DomainComicChapterInfo> getSourceChapters({
    required SourcePlatformRef platform,
    required String sourceComicId,
  }) {
    final rows = db.select(
      '''
      SELECT src.comic_id, c.chapters_json
      FROM comic_sources src
      JOIN comic_source_chapters c ON c.comic_source_id = src.comic_source_id
      WHERE src.platform_id = ? AND src.source_comic_id = ?;
      ''',
      [platform.platformId, sourceComicId],
    );
    if (rows.isEmpty) {
      return const [];
    }
    return _decodeChapters(
      rows.single['chapters_json'] as String,
      rows.single['comic_id'] as String,
    );
  }

  /// One JSON array per chapter, in list order: `[id, title]`, then the group
  /// triple when the list is grouped, then both indexes when they are not
  /// simply the position.
  static String _encodeChapters(
    List<DomainComicChapterInfo> chapters,
    String comicId,
  ) {
    final entries = <List<Object?>>[];
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final sourceIndex = chapter.sourceChapterIndex ?? chapter.chapterIndex;
      final ownIndexes =
          chapter.chapterIndex != i + 1 || sourceIndex != chapter.chapterIndex;
      final grouped =
          chapter.sourceChapterGroup != null ||
          chapter.sourceGroupTitle != null ||
          chapter.sourceChapterIndexInGroup != null;
      entries.add([
        chapter.sourceChapterId ?? '$comicId:chapter:${chapter.chapterIndex}',
        chapter.title,
        if (grouped || ownIndexes) ...[
          chapter.sourceChapterGroup,
          chapter.sourceGroupTitle,
          chapter.sourceChapterIndexInGroup,
        ],
        if (ownIndexes) ...[chapter.chapterIndex, sourceIndex],
      ]);
    }
    return jsonEncode(entries);
  }

  static List<DomainComicChapterInfo> _decodeChapters(
    String encoded,
    String comicId,
  ) {
    final entries = jsonDecode(encoded) as List;
    final chapters = <DomainComicChapterInfo>[];
    var ownIndexes = false;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i] as List;
      final chapterIndex = entry.length > 5 ? entry[5] as int : i + 1;
      ownIndexes = ownIndexes || entry.length > 5;
      chapters.add(
        DomainComicChapterInfo(
          chapterId: '$comicId:chapter:$chapterIndex',
          title: entry[1] as String,
          chapterIndex: chapterIndex,
          sourceChapterId: entry[0] as String,
          sourceChapterIndex: entry.length > 6 ? entry[6] as int : chapterIndex,
          sourceChapterGroup: entry.length > 2 ? entry[2] as int? : null,
          sourceGroupTitle: entry.length > 3 ? entry[3] as String? : null,
          sourceChapterIndexInGroup: entry.length > 4 ? entry[4] as int? : null,
        ),
      );
    }
    if (ownIndexes) {
      chapters.sort((a, b) {
        final bySource = a.sourceChapterIndex!.compareTo(b.sourceChapterIndex!);
        return bySource != 0
            ? bySource
            : a.chapterIndex.compareTo(b.chapterIndex);
      });
    }
    return chapters;
  }

  String ensureWorkForComic({
    required String comicId,
    String? title,
    String? author,
    String? status,
    String? updateTime,
    String? coverUri,
    String? description,
    List<String>? tags,
    int? pageCount,
    int? timestamp,
  }) {
    final existing = db.select(
      '''
      SELECT work_id FROM work_sources
      WHERE comic_id = ? AND link_status = 'accepted'
      ORDER BY CASE link_source WHEN 'manual' THEN 0 ELSE 1 END
      LIMIT 1;
      ''',
      [comicId],
    );
    if (existing.isNotEmpty) {
      return existing.single['work_id'] as String;
    }

    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final baseInfo = getComicBaseInfo(comicId);
    final workId = _ownWorkIdFor(comicId);
    db.execute(
      '''
      INSERT INTO works (
        work_id,
        title,
        author,
        status,
        update_time,
        cover_uri,
        description,
        tags_json,
        page_count,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(work_id) DO UPDATE SET
        title = COALESCE(excluded.title, works.title),
        author = COALESCE(excluded.author, works.author),
        status = COALESCE(excluded.status, works.status),
        update_time = COALESCE(excluded.update_time, works.update_time),
        cover_uri = COALESCE(excluded.cover_uri, works.cover_uri),
        description = COALESCE(excluded.description, works.description),
        tags_json = COALESCE(excluded.tags_json, works.tags_json),
        page_count = COALESCE(excluded.page_count, works.page_count),
        updated_at = excluded.updated_at;
      ''',
      [
        workId,
        _emptyToNull(title) ?? baseInfo?.title,
        _emptyToNull(author) ?? baseInfo?.author,
        _emptyToNull(status) ?? baseInfo?.status,
        _emptyToNull(updateTime) ?? baseInfo?.updateTime,
        _emptyToNull(coverUri) ?? baseInfo?.coverUri,
        _emptyToNull(description) ?? baseInfo?.description,
        tags == null
            ? (baseInfo == null || baseInfo.tags.isEmpty
                  ? null
                  : jsonEncode(baseInfo.tags))
            : jsonEncode(tags),
        pageCount ?? baseInfo?.pageCount,
        now,
        now,
      ],
    );
    _upsertWorkSource(
      workId: workId,
      comicId: comicId,
      status: 'accepted',
      linkSource: 'manual',
      confidence: 1,
      timestamp: now,
    );
    return workId;
  }

  String linkSourceComics({
    required SourcePlatformRef sourcePlatform,
    required String sourceComicId,
    required SourcePlatformRef targetPlatform,
    required String targetSourceComicId,
    String linkSource = 'manual',
    double confidence = 1,
    int? timestamp,
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final sourceComicDomainId = _ensureMinimalComicSource(
      platform: sourcePlatform,
      sourceComicId: sourceComicId,
      timestamp: now,
    );
    final targetComicDomainId = _ensureMinimalComicSource(
      platform: targetPlatform,
      sourceComicId: targetSourceComicId,
      timestamp: now,
    );
    final workId = ensureWorkForComic(
      comicId: sourceComicDomainId,
      timestamp: now,
    );
    _upsertWorkSource(
      workId: workId,
      comicId: targetComicDomainId,
      status: 'accepted',
      linkSource: linkSource,
      confidence: confidence,
      timestamp: now,
    );
    return workId;
  }

  String _ensureMinimalComicSource({
    required SourcePlatformRef platform,
    required String sourceComicId,
    required int timestamp,
  }) {
    final comicId = comicIdFor(platform, sourceComicId);
    if (getComicBaseInfo(comicId) != null) {
      ensureSourcePlatform(platform, timestamp: timestamp);
      return comicId;
    }
    return ensureComicSource(
      platform: platform,
      sourceComicId: sourceComicId,
      title: sourceComicId,
      timestamp: timestamp,
    );
  }

  void unlinkSourceComic({
    required SourcePlatformRef platform,
    required String sourceComicId,
  }) {
    db.execute(
      '''
      DELETE FROM work_sources
      WHERE comic_id = ? AND link_source = 'manual';
      ''',
      [comicIdFor(platform, sourceComicId)],
    );
  }

  void unlinkWorkSource({required String workId, required String comicId}) {
    db.execute(
      '''
      DELETE FROM work_sources
      WHERE work_id = ? AND comic_id = ?;
      ''',
      [workId, comicId],
    );
  }

  List<DomainComicSourceLink> getRelatedSources(String comicId) {
    final rows = db.select(
      '''
      WITH related AS (
        SELECT
          ws.work_id,
          cs.comic_id,
          c.title,
          c.author,
          c.status AS comic_status,
          c.cover_uri,
          cs.platform_id,
          cs.source_comic_id,
          sp.display_name,
          ws.link_status,
          ws.link_source,
          ws.confidence,
          ROW_NUMBER() OVER (
            PARTITION BY cs.comic_id
            ORDER BY
              CASE ws.link_status
                WHEN 'accepted' THEN 0
                WHEN 'candidate' THEN 1
                ELSE 2
              END,
              ws.confidence DESC,
              CASE ws.link_source WHEN 'manual' THEN 0 ELSE 1 END
          ) AS rank
        FROM work_sources current
        JOIN work_sources ws ON ws.work_id = current.work_id
        JOIN comic_sources cs ON cs.comic_id = ws.comic_id
        JOIN comics c ON c.comic_id = cs.comic_id
        JOIN source_platforms sp ON sp.platform_id = cs.platform_id
        WHERE current.comic_id = ?
          AND current.link_status != 'rejected'
          AND ws.link_status != 'rejected'
      )
      SELECT
        work_id,
        comic_id,
        title,
        author,
        comic_status,
        cover_uri,
        platform_id,
        source_comic_id,
        display_name,
        link_status,
        link_source,
        confidence
      FROM related
      WHERE rank = 1
      ORDER BY
        CASE link_status
          WHEN 'accepted' THEN 0
          WHEN 'candidate' THEN 1
          ELSE 2
        END,
        confidence DESC,
        display_name;
      ''',
      [comicId],
    );
    return rows.map(_sourceLinkFromRow).toList();
  }

  void acceptWorkSource({
    required String workId,
    required String comicId,
    int? timestamp,
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    _removeCompetingWorkSources(workId: workId, comicId: comicId);
    db.execute(
      '''
      UPDATE work_sources
      SET link_status = 'accepted',
          link_source = 'manual',
          updated_at = ?
      WHERE work_id = ? AND comic_id = ?;
      ''',
      [now, workId, comicId],
    );
  }

  void rejectWorkSource({
    required String workId,
    required String comicId,
    int? timestamp,
  }) {
    db.execute(
      '''
      UPDATE work_sources
      SET link_status = 'rejected',
          link_source = 'manual',
          updated_at = ?
      WHERE work_id = ? AND comic_id = ?;
      ''',
      [timestamp ?? DateTime.now().millisecondsSinceEpoch, workId, comicId],
    );
  }

  void ensureSourcePlatform(SourcePlatformRef platform, {int? timestamp}) {
    db.execute(
      '''
      INSERT INTO source_platforms (
        platform_id,
        canonical_key,
        display_name,
        kind,
        legacy_int_type,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(platform_id) DO UPDATE SET
        canonical_key = excluded.canonical_key,
        display_name = excluded.display_name,
        kind = excluded.kind,
        legacy_int_type = COALESCE(
          excluded.legacy_int_type,
          source_platforms.legacy_int_type
        );
      ''',
      [
        platform.platformId,
        platform.canonicalKey,
        platform.displayName,
        platform.kind.value,
        platform.legacyIntType,
        timestamp ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
    db.execute(
      '''
      INSERT OR IGNORE INTO source_platform_aliases (
        platform_id,
        alias,
        alias_type,
        legacy_int_type
      ) VALUES (?, ?, ?, ?);
      ''',
      [
        platform.platformId,
        platform.matchedAlias,
        platform.matchedAliasType.value,
        platform.legacyIntType,
      ],
    );
  }

  /// Removes a source comic and all of its dependent rows (work links, local
  /// library item, chapters, favorites — via FK cascade).
  ///
  /// Older versions reused local comic ids, so a stale mirror could attach the
  /// old comic's work link — and therefore its title/cover — to the next comic
  /// that got the same id (issue #135). Works left without any source are
  /// cleaned up as well.
  void removeComicSource({
    required SourcePlatformRef platform,
    required String sourceComicId,
  }) {
    final comicId = comicIdFor(platform, sourceComicId);
    db.execute('DELETE FROM comics WHERE comic_id = ?;', [comicId]);
    db.execute(
      '''
      DELETE FROM works
      WHERE work_id NOT IN (SELECT DISTINCT work_id FROM work_sources);
      ''',
    );
  }

  void markLocalLibraryItem({
    required String comicId,
    required String directory,
    String? importRoot,
    String storageState = 'available',
    int? timestamp,
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      INSERT INTO local_library_items (
        comic_id,
        directory,
        import_root,
        storage_state,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(comic_id) DO UPDATE SET
        directory = excluded.directory,
        import_root = excluded.import_root,
        storage_state = excluded.storage_state,
        updated_at = excluded.updated_at;
      ''',
      [comicId, directory, importRoot, storageState, now, now],
    );
  }

  void markFavorite({
    required String comicId,
    required String folderName,
    int sortOrder = 0,
    int? timestamp,
  }) {
    db.execute(
      '''
      INSERT OR IGNORE INTO favorites (
        comic_id,
        folder_name,
        sort_order,
        created_at
      ) VALUES (?, ?, ?, ?);
      ''',
      [
        comicId,
        folderName,
        sortOrder,
        timestamp ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  void _createAutoWorkCandidates({
    required String comicId,
    required String title,
    String? author,
    int? timestamp,
  }) {
    final normalizedTitle = _normalizeForMatch(title);
    if (normalizedTitle.length < 2) {
      return;
    }
    final normalizedAuthor = _normalizeForMatch(author ?? '');
    // Indexed lookup on normalized_title instead of scanning every comic, so
    // mirroring stays cheap as the library grows.
    final rows = db.select(
      '''
      SELECT comic_id, author
      FROM comics
      WHERE normalized_title = ? AND comic_id != ?;
      ''',
      [normalizedTitle, comicId],
    );
    for (final row in rows) {
      final otherComicId = row['comic_id'] as String;
      final otherAuthor = row['author'] as String? ?? '';
      final otherNormalizedAuthor = _normalizeForMatch(otherAuthor);
      final hasAuthor =
          normalizedAuthor.isNotEmpty && otherNormalizedAuthor.isNotEmpty;
      if (hasAuthor && normalizedAuthor != otherNormalizedAuthor) {
        continue;
      }
      final workId = ensureWorkForComic(
        comicId: otherComicId,
        timestamp: timestamp,
      );
      _upsertWorkSource(
        workId: workId,
        comicId: comicId,
        status: 'candidate',
        linkSource: 'auto',
        confidence: hasAuthor ? 0.95 : 0.72,
        timestamp: timestamp,
      );
    }
  }

  void _upsertWorkSource({
    required String workId,
    required String comicId,
    required String status,
    required String linkSource,
    required double confidence,
    int? timestamp,
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    if (status == 'accepted') {
      _removeCompetingWorkSources(workId: workId, comicId: comicId);
    } else if (status == 'candidate' && _hasAcceptedWorkSource(comicId)) {
      return;
    }
    db.execute(
      '''
      INSERT INTO work_sources (
        work_id,
        comic_id,
        link_status,
        link_source,
        confidence,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(work_id, comic_id) DO UPDATE SET
        link_status = excluded.link_status,
        link_source = excluded.link_source,
        confidence = excluded.confidence,
        updated_at = excluded.updated_at;
      ''',
      [workId, comicId, status, linkSource, confidence, now, now],
    );
  }

  bool _hasAcceptedWorkSource(String comicId) {
    return db
        .select(
          '''
          SELECT 1 FROM work_sources
          WHERE comic_id = ? AND link_status = 'accepted'
          LIMIT 1;
          ''',
          [comicId],
        )
        .isNotEmpty;
  }

  void _removeCompetingWorkSources({
    required String workId,
    required String comicId,
  }) {
    db.execute(
      '''
      DELETE FROM work_sources
      WHERE comic_id = ?
        AND work_id != ?
        AND link_status IN ('candidate', 'accepted');
      ''',
      [comicId, workId],
    );
  }

  DomainComicBaseInfo _baseInfoFromRow(Row row) {
    return DomainComicBaseInfo(
      comicId: row['comic_id'] as String,
      title: row['title'] as String,
      subtitle: row['subtitle'] as String? ?? '',
      description: row['description'] as String? ?? '',
      author: row['author'] as String?,
      status: row['status'] as String?,
      updateTime: row['update_time'] as String?,
      language: row['language'] as String?,
      coverUri: row['cover_uri'] as String?,
      tags: _decodeTags(row['tags_json']),
      pageCount: row['page_count'] as int?,
      workId: row['work_id'] as String?,
    );
  }

  DomainComicSourceLink _sourceLinkFromRow(Row row) {
    return DomainComicSourceLink(
      workId: row['work_id'] as String,
      comicId: row['comic_id'] as String,
      comicTitle: row['title'] as String? ?? row['source_comic_id'] as String,
      platformId: row['platform_id'] as String,
      sourceComicId: row['source_comic_id'] as String,
      sourceName:
          row['display_name'] as String? ?? row['platform_id'] as String,
      comicAuthor: row['author'] as String?,
      comicStatus: row['comic_status'] as String?,
      comicCoverUri: row['cover_uri'] as String?,
      status: row['link_status'] as String,
      linkSource: row['link_source'] as String,
      confidence: (row['confidence'] as num?)?.toDouble(),
    );
  }

  List<String> _decodeTags(dynamic value) {
    if (value is! String || value.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      return const [];
    }
    return const [];
  }

  static String? _emptyToNull(String? value) {
    final result = value?.trim();
    return result == null || result.isEmpty ? null : result;
  }

  static String _normalizeForMatch(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[\[\]【】()（）{}<>《》:：,，.!！?？\-_/\\|]'), '');
  }
}

const _schemaSql = '''
CREATE TABLE IF NOT EXISTS source_platforms (
  platform_id TEXT PRIMARY KEY,
  canonical_key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('local', 'remote', 'virtual')),
  legacy_int_type INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS source_platform_aliases (
  platform_id TEXT NOT NULL,
  alias TEXT NOT NULL,
  alias_type TEXT NOT NULL CHECK (
    alias_type IN (
      'canonical_key',
      'display_name',
      'plugin_key',
      'legacy_key',
      'legacy_int'
    )
  ),
  legacy_int_type INTEGER,
  PRIMARY KEY (alias, alias_type),
  FOREIGN KEY (platform_id) REFERENCES source_platforms(platform_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS comics (
  comic_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  subtitle TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  author TEXT,
  status TEXT,
  update_time TEXT,
  language TEXT,
  cover_uri TEXT,
  tags_json TEXT,
  page_count INTEGER,
  normalized_title TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  base_info_updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS works (
  work_id TEXT PRIMARY KEY,
  title TEXT,
  author TEXT,
  status TEXT,
  update_time TEXT,
  cover_uri TEXT,
  description TEXT,
  tags_json TEXT,
  page_count INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS work_sources (
  work_id TEXT NOT NULL,
  comic_id TEXT NOT NULL,
  link_status TEXT NOT NULL DEFAULT 'accepted'
    CHECK (link_status IN ('candidate', 'accepted', 'rejected')),
  link_source TEXT NOT NULL DEFAULT 'manual'
    CHECK (link_source IN ('manual', 'auto')),
  confidence REAL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (work_id, comic_id),
  FOREIGN KEY (work_id) REFERENCES works(work_id) ON DELETE CASCADE,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS comic_sources (
  comic_source_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL,
  platform_id TEXT NOT NULL,
  source_comic_id TEXT NOT NULL,
  source_url TEXT,
  source_title TEXT,
  status TEXT NOT NULL DEFAULT 'accepted'
    CHECK (status IN ('accepted', 'unavailable')),
  created_at INTEGER NOT NULL,
  accepted_at INTEGER NOT NULL,
  UNIQUE (platform_id, source_comic_id),
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (platform_id) REFERENCES source_platforms(platform_id)
);

CREATE TABLE IF NOT EXISTS source_tags (
  source_tag_id INTEGER PRIMARY KEY AUTOINCREMENT,
  platform_id TEXT NOT NULL,
  name TEXT NOT NULL,
  translated_name TEXT,
  tag_type TEXT NOT NULL DEFAULT 'tag',
  UNIQUE (platform_id, name, tag_type),
  FOREIGN KEY (platform_id) REFERENCES source_platforms(platform_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS comic_source_tags (
  comic_source_id INTEGER NOT NULL,
  source_tag_id INTEGER NOT NULL,
  PRIMARY KEY (comic_source_id, source_tag_id),
  FOREIGN KEY (comic_source_id) REFERENCES comic_sources(comic_source_id)
    ON DELETE CASCADE,
  FOREIGN KEY (source_tag_id) REFERENCES source_tags(source_tag_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS local_library_items (
  local_item_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL UNIQUE,
  directory TEXT NOT NULL,
  import_root TEXT,
  storage_state TEXT NOT NULL DEFAULT 'available'
    CHECK (storage_state IN ('available', 'missing', 'deleted')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS comic_source_chapters (
  comic_source_id INTEGER PRIMARY KEY,
  chapters_json TEXT NOT NULL,
  FOREIGN KEY (comic_source_id) REFERENCES comic_sources(comic_source_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tags (
  tag_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  translated_name TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS favorites (
  favorite_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL,
  folder_name TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (comic_id, folder_name),
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_comic_sources_comic_id
  ON comic_sources(comic_id);
CREATE INDEX IF NOT EXISTS idx_work_sources_comic_id
  ON work_sources(comic_id, link_status);
CREATE INDEX IF NOT EXISTS idx_local_library_items_comic_id
  ON local_library_items(comic_id);
''';
