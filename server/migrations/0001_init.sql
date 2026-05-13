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
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_key, comic_id)
);

CREATE TABLE IF NOT EXISTS favorites (
    source_key TEXT NOT NULL,
    comic_id TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    cover TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_key, comic_id)
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
    ('readerMode', '"continuousTopToBottom"'),
    ('cacheLimitMb', '1024');
