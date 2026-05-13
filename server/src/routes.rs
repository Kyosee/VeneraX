use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Path, State},
    routing::{delete, get},
    Json, Router,
};
use regex::Regex;
use serde_json::Value;
use tokio::fs;

use crate::{
    error::{ApiError, ApiResult},
    models::{
        CapabilitiesResponse, Capability, DeleteResponse, HealthResponse, SettingsPatch,
        SettingsResponse, SourceSummary, SourceWriteRequest,
    },
    state::AppState,
};

pub fn api_router() -> Router<AppState> {
    Router::new()
        .route("/health", get(health))
        .route("/capabilities", get(capabilities))
        .route("/settings", get(get_settings).put(update_settings))
        .route("/sources", get(list_sources).post(upsert_source))
        .route("/sources/{key}", delete(delete_source))
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

async fn upsert_source(
    State(state): State<AppState>,
    Json(payload): Json<SourceWriteRequest>,
) -> ApiResult<Json<SourceSummary>> {
    let metadata = parse_source_metadata(&payload.content)?;
    let file_name = normalize_source_file_name(payload.file_name.as_deref(), &metadata.key)?;
    let file_path = state.config.sources_dir().join(&file_name);

    fs::write(&file_path, payload.content).await?;

    let old_file_name = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let old_file_name = database
            .query_row(
                "SELECT file_name FROM comic_sources WHERE source_key = ?1",
                [&metadata.key],
                |row| row.get::<_, String>(0),
            )
            .ok();

        database.execute(
            r#"
            INSERT INTO comic_sources (source_key, name, version, file_name, enabled, updated_at)
            VALUES (?1, ?2, ?3, ?4, 1, CURRENT_TIMESTAMP)
            ON CONFLICT(source_key) DO UPDATE SET
                name = excluded.name,
                version = excluded.version,
                file_name = excluded.file_name,
                enabled = excluded.enabled,
                updated_at = CURRENT_TIMESTAMP
            "#,
            (&metadata.key, &metadata.name, &metadata.version, &file_name),
        )?;

        old_file_name
    };

    if let Some(old_file_name) = old_file_name {
        if old_file_name != file_name {
            let old_path = state.config.sources_dir().join(old_file_name);
            let _ = fs::remove_file(old_path).await;
        }
    }

    Ok(Json(SourceSummary {
        key: metadata.key,
        name: metadata.name,
        version: Some(metadata.version),
        file_name,
        enabled: true,
        runtime_status: "registered",
        updated_at: None,
    }))
}

async fn delete_source(
    State(state): State<AppState>,
    Path(key): Path<String>,
) -> ApiResult<Json<DeleteResponse>> {
    if !is_valid_source_key(&key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }

    let file_name = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let file_name = database
            .query_row(
                "SELECT file_name FROM comic_sources WHERE source_key = ?1",
                [&key],
                |row| row.get::<_, String>(0),
            )
            .ok();
        database.execute("DELETE FROM comic_sources WHERE source_key = ?1", [&key])?;
        file_name
    };

    if let Some(file_name) = file_name {
        let _ = fs::remove_file(state.config.sources_dir().join(file_name)).await;
    }

    Ok(Json(DeleteResponse { deleted: true }))
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

struct SourceMetadata {
    key: String,
    name: String,
    version: String,
}

fn parse_source_metadata(content: &str) -> ApiResult<SourceMetadata> {
    let has_source_class = content.lines().any(|line| {
        line.trim_start().starts_with("class ") && line.contains("extends ComicSource")
    });
    if !has_source_class {
        return Err(ApiError::BadRequest(
            "source must define class extends ComicSource".to_string(),
        ));
    }

    let key = extract_js_string(content, "key")
        .ok_or_else(|| ApiError::BadRequest("source key is required".to_string()))?;
    if !is_valid_source_key(&key) {
        return Err(ApiError::BadRequest("source key is invalid".to_string()));
    }

    let name = extract_js_string(content, "name")
        .ok_or_else(|| ApiError::BadRequest("source name is required".to_string()))?;
    let version = extract_js_string(content, "version")
        .ok_or_else(|| ApiError::BadRequest("source version is required".to_string()))?;

    Ok(SourceMetadata { key, name, version })
}

fn extract_js_string(content: &str, field: &str) -> Option<String> {
    let escaped = regex::escape(field);
    let patterns = [
        format!(r#"(?s)\b{}\s*=\s*"([^"]+)""#, escaped),
        format!(r#"(?s)\b{}\s*=\s*'([^']+)'"#, escaped),
        format!(
            r#"(?s)get\s+{}\s*\(\s*\)\s*\{{.*?return\s*"([^"]+)""#,
            escaped
        ),
        format!(
            r#"(?s)get\s+{}\s*\(\s*\)\s*\{{.*?return\s*'([^']+)'"#,
            escaped
        ),
    ];

    patterns.into_iter().find_map(|pattern| {
        Regex::new(&pattern)
            .ok()?
            .captures(content)?
            .get(1)
            .map(|value| value.as_str().trim().to_string())
    })
}

fn normalize_source_file_name(file_name: Option<&str>, key: &str) -> ApiResult<String> {
    let name = file_name
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(key)
        .trim();
    let name = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let name = if name.ends_with(".js") {
        name.to_string()
    } else {
        format!("{name}.js")
    };

    let valid = name
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'));
    if !valid || name == ".js" {
        return Err(ApiError::BadRequest(
            "source file name is invalid".to_string(),
        ));
    }

    Ok(name)
}

fn is_valid_source_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}
