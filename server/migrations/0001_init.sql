CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS comic_sources (
    source_key TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    version TEXT,
    file_name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS reading_history (
    source_key TEXT NOT NULL,
    comic_id TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    cover TEXT,
    episode_id TEXT,
    episode_title TEXT,
    page INTEGER,
    max_page INTEGER,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_key, comic_id)
);

CREATE TABLE IF NOT EXISTS favorites (
    source_key TEXT NOT NULL,
    comic_id TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    cover TEXT,
    tags TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_key, comic_id)
);

CREATE TABLE IF NOT EXISTS comic_metadata (
    source_key TEXT NOT NULL,
    comic_id TEXT NOT NULL,
    author TEXT,
    status TEXT,
    update_time TEXT,
    description TEXT,
    tags_json TEXT,
    page_count INTEGER,
    latest_title TEXT,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_key, comic_id)
);

CREATE TABLE IF NOT EXISTS favorite_folders (
    folder_name TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS favorite_folder_items (
    folder_name TEXT NOT NULL,
    source_key TEXT NOT NULL,
    comic_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_update_time TEXT,
    has_new_update INTEGER NOT NULL DEFAULT 0,
    last_check_time INTEGER,
    PRIMARY KEY (folder_name, source_key, comic_id)
);

CREATE INDEX IF NOT EXISTS idx_favorite_folder_items_folder
    ON favorite_folder_items (folder_name, created_at DESC);

CREATE TABLE IF NOT EXISTS webdav_config (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    endpoint_url TEXT NOT NULL,
    username TEXT,
    password TEXT,
    root_path TEXT NOT NULL DEFAULT '/',
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    progress INTEGER NOT NULL DEFAULT 0,
    payload TEXT NOT NULL DEFAULT '{}',
    error TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO settings (key, value) VALUES
    ('themeMode', '"system"'),
    ('readerMode', '"galleryLeftToRight"'),
    ('cacheLimitMb', '1024');
