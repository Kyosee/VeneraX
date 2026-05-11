import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/source_platform.dart';

class DomainDatabase {
  static const schemaVersion = 1;
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
    seedStaticData(db);
    db.execute('PRAGMA user_version = $schemaVersion');
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
  language TEXT,
  cover_uri TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
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
