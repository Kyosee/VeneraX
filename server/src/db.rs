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

    Ok(Arc::new(Mutex::new(connection)))
}

async fn ensure_directories(config: &AppConfig) -> anyhow::Result<()> {
    let dirs = [
        config.data_dir.clone(),
        config.sources_dir(),
        config.cache_dir(),
        config.downloads_dir(),
        config.tmp_dir(),
    ];

    for dir in dirs {
        fs::create_dir_all(&dir)
            .await
            .with_context(|| format!("create directory {}", dir.display()))?;
    }

    Ok(())
}
