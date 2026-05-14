use anyhow::Context;
use rusqlite::Connection;
use std::sync::{Arc, Mutex};
use tokio::fs;

use crate::config::AppConfig;

pub type Database = Arc<Mutex<Connection>>;

pub async fn connect(config: &AppConfig) -> anyhow::Result<Database> {
    ensure_directories(config).await?;

    let connection = Connection::open(config.database_path()).context("connect sqlite database")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.execute_batch(include_str!("../migrations/0001_init.sql"))?;
    ensure_schema_upgrades(&connection)?;

    Ok(Arc::new(Mutex::new(connection)))
}

fn ensure_schema_upgrades(connection: &Connection) -> rusqlite::Result<()> {
    add_column_if_missing(
        connection,
        "favorite_folder_items",
        "last_update_time",
        "last_update_time TEXT",
    )?;
    add_column_if_missing(
        connection,
        "favorite_folder_items",
        "has_new_update",
        "has_new_update INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        connection,
        "favorite_folder_items",
        "last_check_time",
        "last_check_time INTEGER",
    )?;
    add_column_if_missing(connection, "reading_history", "page", "page INTEGER")?;
    add_column_if_missing(connection, "reading_history", "max_page", "max_page INTEGER")?;
    add_column_if_missing(connection, "favorites", "tags", "tags TEXT")?;
    connection.execute(
        r#"
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
        )
        "#,
        [],
    )?;
    connection.execute(
        r#"
        CREATE INDEX IF NOT EXISTS idx_favorite_folder_items_updates
        ON favorite_folder_items (has_new_update, last_update_time DESC)
        "#,
        [],
    )?;
    connection.execute(
        r#"
        UPDATE tasks
        SET status = 'failed',
            error = 'server restarted before task finished',
            updated_at = CURRENT_TIMESTAMP
        WHERE status = 'running'
        "#,
        [],
    )?;
    Ok(())
}

fn add_column_if_missing(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> rusqlite::Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !columns.iter().any(|item| item == column) {
        connection.execute(&format!("ALTER TABLE {table} ADD COLUMN {definition}"), [])?;
    }
    Ok(())
}

async fn ensure_directories(config: &AppConfig) -> anyhow::Result<()> {
    let dirs = [
        config.data_dir.clone(),
        config.sources_dir(),
        config.cache_dir(),
        config.downloads_dir(),
        config.imports_dir(),
        config.tmp_dir(),
    ];

    for dir in dirs {
        fs::create_dir_all(&dir)
            .await
            .with_context(|| format!("create directory {}", dir.display()))?;
    }

    Ok(())
}
