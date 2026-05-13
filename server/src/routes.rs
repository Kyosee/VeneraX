use std::collections::{BTreeMap, BTreeSet};

use axum::{extract::State, routing::get, Json, Router};
use serde_json::Value;
use tokio::fs;

use crate::{
    error::{ApiError, ApiResult},
    models::{
        CapabilitiesResponse, Capability, HealthResponse, SettingsPatch, SettingsResponse,
        SourceSummary,
    },
    state::AppState,
};

pub fn api_router() -> Router<AppState> {
    Router::new()
        .route("/health", get(health))
        .route("/capabilities", get(capabilities))
        .route("/settings", get(get_settings).put(update_settings))
        .route("/sources", get(list_sources))
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
        database: "sqlite",
        data_dir: state.config.data_dir.display().to_string(),
        static_assets: state.config.static_dir.join("index.html").is_file(),
    })
}

async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        mode: "single-user-lan",
        multi_user: false,
        auth: false,
        features: vec![
            Capability {
                key: "pwa_shell",
                label: "PWA shell",
                status: "available",
                reason: None,
            },
            Capability {
                key: "comic_sources",
                label: "Comic source runtime",
                status: "planned",
                reason: Some("server-side source parser/runtime will be connected in stage 2"),
            },
            Capability {
                key: "reader",
                label: "Reader API",
                status: "planned",
                reason: Some("image proxy, cache, and history are stage 3"),
            },
            Capability {
                key: "native_login",
                label: "Native WebView login",
                status: "hidden",
                reason: Some("browser PWA cannot embed the same native WebView flow"),
            },
            Capability {
                key: "native_file_access",
                label: "Native file access",
                status: "hidden",
                reason: Some("Docker data directory replaces local platform pickers"),
            },
        ],
    })
}

async fn get_settings(State(state): State<AppState>) -> ApiResult<Json<SettingsResponse>> {
    let values = read_settings(&state)?;

    Ok(Json(SettingsResponse {
        values,
        hidden_features: vec![
            "native_webview_login",
            "biometric_lock",
            "native_directory_picker",
            "native_share_sheet",
            "desktop_window_controls",
            "volume_key_turning",
        ],
    }))
}

async fn update_settings(
    State(state): State<AppState>,
    Json(payload): Json<SettingsPatch>,
) -> ApiResult<Json<SettingsResponse>> {
    for (key, value) in payload.values {
        if key.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "setting key cannot be empty".to_string(),
            ));
        }

        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        database.execute(
            r#"
                INSERT INTO settings (key, value, updated_at)
                VALUES (?1, ?2, CURRENT_TIMESTAMP)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = CURRENT_TIMESTAMP
                "#,
            (&key, &value.to_string()),
        )?;
    }

    get_settings(State(state)).await
}

async fn list_sources(State(state): State<AppState>) -> ApiResult<Json<Vec<SourceSummary>>> {
    let rows = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let mut statement = database.prepare(
            r#"
            SELECT source_key, name, version, file_name, enabled, updated_at
            FROM comic_sources
            ORDER BY name COLLATE NOCASE
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })?;

        rows.collect::<Result<Vec<_>, _>>()?
    };

    let mut seen = BTreeSet::new();
    let mut sources = Vec::new();

    for (key, name, version, file_name, enabled, updated_at) in rows {
        seen.insert(file_name.clone());
        sources.push(SourceSummary {
            key,
            name,
            version,
            file_name,
            enabled: enabled != 0,
            runtime_status: "registered",
            updated_at,
        });
    }

    let mut dir = fs::read_dir(state.config.sources_dir()).await?;
    while let Some(entry) = dir.next_entry().await? {
        let path = entry.path();
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !file_name.ends_with(".js") || seen.contains(file_name) {
            continue;
        }

        let key = path
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or(file_name)
            .to_string();

        sources.push(SourceSummary {
            name: key.clone(),
            key,
            version: None,
            file_name: file_name.to_string(),
            enabled: true,
            runtime_status: "pending_parse",
            updated_at: None,
        });
    }

    Ok(Json(sources))
}

fn read_settings(state: &AppState) -> ApiResult<BTreeMap<String, Value>> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let mut statement = database.prepare("SELECT key, value FROM settings ORDER BY key")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;

    let mut values = BTreeMap::new();
    for row in rows {
        let (key, value) = row?;
        let parsed = serde_json::from_str::<Value>(&value).unwrap_or(Value::String(value));
        values.insert(key, parsed);
    }

    Ok(values)
}
