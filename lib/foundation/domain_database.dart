import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/source_platform.dart';

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

class DomainComicSourceLink {
  const DomainComicSourceLink({
    required this.workId,
    required this.comicId,
    required this.platformId,
    required this.sourceComicId,
    required this.sourceName,
    required this.status,
    required this.linkSource,
    required this.confidence,
  });

  final String workId;
  final String comicId;
  final String platformId;
  final String sourceComicId;
  final String sourceName;
  final String status;
  final String linkSource;
  final double? confidence;
}

class DomainDatabase {
  static const schemaVersion = 2;
  static const dataDirectoryName = 'data';
  static const databaseFileName = 'venera.db';

  Database? _db;

  Database get db {
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
    if (_db != null) {
      return;
    }
    final dbPath = databasePathFor(appDataPath);
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    final database = sqlite3.open(dbPath);
    configure(database);
    createSchema(database);
    _db = database;
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  static void configure(Database db) {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
  }

  static void createSchema(Database db) {
    db.execute(_schemaSql);
    migrateSchema(db);
    seedStaticData(db);
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  static void migrateSchema(Database db) {
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
  }

  static void seedStaticData(Database db) {
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
  }) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final comicId = comicIdFor(platform, sourceComicId);
    final tagsJson = tags == null ? null : jsonEncode(tags);
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
        created_at,
        updated_at,
        base_info_updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(comic_id) DO UPDATE SET
        title = excluded.title,
        subtitle = excluded.subtitle,
        description = excluded.description,
        author = COALESCE(excluded.author, comics.author),
        status = COALESCE(excluded.status, comics.status),
        update_time = COALESCE(excluded.update_time, comics.update_time),
        language = excluded.language,
        cover_uri = excluded.cover_uri,
        tags_json = COALESCE(excluded.tags_json, comics.tags_json),
        page_count = COALESCE(excluded.page_count, comics.page_count),
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
    final workId = 'work:$comicId';
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
      SELECT
        ws.work_id,
        cs.comic_id,
        cs.platform_id,
        cs.source_comic_id,
        sp.display_name,
        ws.link_status,
        ws.link_source,
        ws.confidence
      FROM work_sources current
      JOIN work_sources ws ON ws.work_id = current.work_id
      JOIN comic_sources cs ON cs.comic_id = ws.comic_id
      JOIN source_platforms sp ON sp.platform_id = cs.platform_id
      WHERE current.comic_id = ?
      ORDER BY
        CASE ws.link_status WHEN 'accepted' THEN 0 WHEN 'candidate' THEN 1 ELSE 2 END,
        ws.confidence DESC,
        sp.display_name;
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
    db.execute(
      '''
      UPDATE work_sources
      SET link_status = 'accepted',
          link_source = 'manual',
          updated_at = ?
      WHERE work_id = ? AND comic_id = ?;
      ''',
      [timestamp ?? DateTime.now().millisecondsSinceEpoch, workId, comicId],
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

  void markRead({
    required String comicId,
    String? chapterId,
    String? pageId,
    int? occurredAt,
  }) {
    db.execute(
      '''
      INSERT INTO history_events (
        comic_id,
        chapter_id,
        page_id,
        occurred_at
      ) VALUES (?, ?, ?, ?);
      ''',
      [
        comicId,
        chapterId,
        pageId,
        occurredAt ?? DateTime.now().millisecondsSinceEpoch,
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
    final rows = db.select(
      '''
      SELECT comic_id, title, author
      FROM comics
      WHERE comic_id != ?;
      ''',
      [comicId],
    );
    for (final row in rows) {
      final otherComicId = row['comic_id'] as String;
      final otherTitle = row['title'] as String? ?? '';
      final otherAuthor = row['author'] as String? ?? '';
      if (_normalizeForMatch(otherTitle) != normalizedTitle) {
        continue;
      }
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
      platformId: row['platform_id'] as String,
      sourceComicId: row['source_comic_id'] as String,
      sourceName:
          row['display_name'] as String? ?? row['platform_id'] as String,
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

CREATE TABLE IF NOT EXISTS comic_titles (
  comic_title_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL,
  title TEXT NOT NULL,
  title_kind TEXT NOT NULL DEFAULT 'primary',
  sort_order INTEGER NOT NULL DEFAULT 0,
  UNIQUE (comic_id, title, title_kind),
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

CREATE TABLE IF NOT EXISTS import_batches (
  import_batch_id INTEGER PRIMARY KEY AUTOINCREMENT,
  local_item_id INTEGER NOT NULL,
  source_path TEXT NOT NULL,
  imported_at INTEGER NOT NULL,
  metadata_json TEXT,
  FOREIGN KEY (local_item_id) REFERENCES local_library_items(local_item_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chapters (
  chapter_id TEXT PRIMARY KEY,
  comic_id TEXT NOT NULL,
  title TEXT NOT NULL,
  chapter_index INTEGER NOT NULL,
  source_chapter_id TEXT,
  is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
  created_at INTEGER NOT NULL,
  UNIQUE (comic_id, chapter_index),
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS pages (
  page_id TEXT PRIMARY KEY,
  chapter_id TEXT NOT NULL,
  page_index INTEGER NOT NULL,
  uri TEXT NOT NULL,
  is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
  width INTEGER,
  height INTEGER,
  created_at INTEGER NOT NULL,
  UNIQUE (chapter_id, page_index),
  FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chapter_sources (
  chapter_source_id INTEGER PRIMARY KEY AUTOINCREMENT,
  chapter_id TEXT NOT NULL,
  comic_source_id INTEGER NOT NULL,
  source_chapter_id TEXT,
  source_chapter_index INTEGER,
  source_title TEXT,
  UNIQUE (comic_source_id, source_chapter_id),
  FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id) ON DELETE CASCADE,
  FOREIGN KEY (comic_source_id) REFERENCES comic_sources(comic_source_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS page_sources (
  page_source_id INTEGER PRIMARY KEY AUTOINCREMENT,
  page_id TEXT NOT NULL,
  chapter_source_id INTEGER NOT NULL,
  source_page_id TEXT,
  source_page_index INTEGER NOT NULL,
  source_uri TEXT,
  UNIQUE (chapter_source_id, source_page_index),
  FOREIGN KEY (page_id) REFERENCES pages(page_id) ON DELETE CASCADE,
  FOREIGN KEY (chapter_source_id) REFERENCES chapter_sources(chapter_source_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tags (
  tag_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  translated_name TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS comic_tags (
  comic_id TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  PRIMARY KEY (comic_id, tag_id),
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chapter_collections (
  chapter_collection_id TEXT PRIMARY KEY,
  comic_id TEXT NOT NULL,
  title TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chapter_collection_items (
  chapter_collection_id TEXT NOT NULL,
  chapter_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  PRIMARY KEY (chapter_collection_id, chapter_id),
  FOREIGN KEY (chapter_collection_id)
    REFERENCES chapter_collections(chapter_collection_id) ON DELETE CASCADE,
  FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS page_orders (
  page_order_id TEXT PRIMARY KEY,
  comic_id TEXT NOT NULL,
  title TEXT NOT NULL,
  order_kind TEXT NOT NULL DEFAULT 'user'
    CHECK (order_kind IN ('source', 'import', 'user')),
  created_at INTEGER NOT NULL,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS page_order_items (
  page_order_id TEXT NOT NULL,
  page_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  PRIMARY KEY (page_order_id, page_id),
  FOREIGN KEY (page_order_id) REFERENCES page_orders(page_order_id)
    ON DELETE CASCADE,
  FOREIGN KEY (page_id) REFERENCES pages(page_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS reader_sessions (
  reader_session_id TEXT PRIMARY KEY,
  comic_id TEXT NOT NULL,
  current_chapter_id TEXT,
  current_page_id TEXT,
  page_order_id TEXT,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (current_chapter_id) REFERENCES chapters(chapter_id)
    ON DELETE SET NULL,
  FOREIGN KEY (current_page_id) REFERENCES pages(page_id) ON DELETE SET NULL,
  FOREIGN KEY (page_order_id) REFERENCES page_orders(page_order_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS reader_tabs (
  reader_tab_id TEXT PRIMARY KEY,
  reader_session_id TEXT NOT NULL,
  comic_id TEXT NOT NULL,
  chapter_id TEXT,
  page_id TEXT,
  page_order_id TEXT,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (reader_session_id) REFERENCES reader_sessions(reader_session_id)
    ON DELETE CASCADE,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id) ON DELETE SET NULL,
  FOREIGN KEY (page_id) REFERENCES pages(page_id) ON DELETE SET NULL,
  FOREIGN KEY (page_order_id) REFERENCES page_orders(page_order_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS history_events (
  history_event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL,
  chapter_id TEXT,
  page_id TEXT,
  event_type TEXT NOT NULL DEFAULT 'read',
  occurred_at INTEGER NOT NULL,
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (chapter_id) REFERENCES chapters(chapter_id) ON DELETE SET NULL,
  FOREIGN KEY (page_id) REFERENCES pages(page_id) ON DELETE SET NULL
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

CREATE TABLE IF NOT EXISTS remote_match_candidates (
  remote_match_candidate_id INTEGER PRIMARY KEY AUTOINCREMENT,
  comic_id TEXT NOT NULL,
  platform_id TEXT NOT NULL,
  source_comic_id TEXT NOT NULL,
  source_url TEXT,
  title TEXT,
  cover_uri TEXT,
  score REAL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'rejected')),
  created_at INTEGER NOT NULL,
  resolved_at INTEGER,
  UNIQUE (comic_id, platform_id, source_comic_id),
  FOREIGN KEY (comic_id) REFERENCES comics(comic_id) ON DELETE CASCADE,
  FOREIGN KEY (platform_id) REFERENCES source_platforms(platform_id)
);

CREATE INDEX IF NOT EXISTS idx_comic_sources_comic_id
  ON comic_sources(comic_id);
CREATE INDEX IF NOT EXISTS idx_work_sources_comic_id
  ON work_sources(comic_id, link_status);
CREATE INDEX IF NOT EXISTS idx_local_library_items_comic_id
  ON local_library_items(comic_id);
CREATE INDEX IF NOT EXISTS idx_chapters_comic_id
  ON chapters(comic_id, chapter_index);
CREATE INDEX IF NOT EXISTS idx_pages_chapter_id
  ON pages(chapter_id, page_index);
CREATE INDEX IF NOT EXISTS idx_page_order_items_order
  ON page_order_items(page_order_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_history_events_comic_time
  ON history_events(comic_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_remote_match_candidates_comic_status
  ON remote_match_candidates(comic_id, status);
''';
