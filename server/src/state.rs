use std::sync::Arc;

use crate::config::AppConfig;
use crate::db::Database;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub database: Database,
}

impl AppState {
    pub fn new(config: AppConfig, database: Database) -> Self {
        Self {
            config: Arc::new(config),
            database,
        }
    }
}
