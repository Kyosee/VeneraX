use std::{env, path::PathBuf};

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub bind: String,
    pub data_dir: PathBuf,
    pub static_dir: PathBuf,
}

impl AppConfig {
    pub fn from_env() -> Self {
        let bind = env::var("VENERA_WEB_BIND").unwrap_or_else(|_| "127.0.0.1:3000".to_string());
        let data_dir = env::var_os("VENERA_WEB_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("./data.venera/webpwa"));
        let static_dir = env::var_os("VENERA_WEB_STATIC_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("./web/dist"));

        Self {
            bind,
            data_dir,
            static_dir,
        }
    }

    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join("venera_web.db")
    }

    pub fn sources_dir(&self) -> PathBuf {
        self.data_dir.join("sources")
    }

    pub fn cache_dir(&self) -> PathBuf {
        self.data_dir.join("cache")
    }

    pub fn downloads_dir(&self) -> PathBuf {
        self.data_dir.join("downloads")
    }

    pub fn tmp_dir(&self) -> PathBuf {
        self.data_dir.join("tmp")
    }
}
