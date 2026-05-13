use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Path, Query, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE},
        HeaderMap, HeaderValue,
    },
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use regex::Regex;
use rusqlite::params;
use serde_json::Value;
use tokio::fs;

use crate::{
    error::{ApiError, ApiResult},
    image_proxy,
    models::{
        CapabilitiesResponse, Capability, ComicInfoRequest, ComicInfoResponse, ComicPagesRequest,
        ComicPagesResponse, DeleteResponse, FavoriteWriteRequest, HealthResponse,
        HistoryWriteRequest, ImageProxyQuery, LibraryItem, LibraryResponse, SearchRequest,
        SearchResponse, SettingsPatch, SettingsResponse, SourceSummary, SourceWriteRequest,
    },
    source_runtime,
    state::AppState,
};

pub fn api_router() -> Router<AppState> {
    Router::new()
        .route("/health", get(health))
        .route("/capabilities", get(capabilities))
        .route("/settings", get(get_settings).put(update_settings))
        .route("/library", get(get_library))
        .route("/history", post(upsert_history))
        .route("/favorites", post(set_favorite))
        .route("/sources", get(list_sources).post(upsert_source))
        .route("/sources/{key}", delete(delete_source))
        .route("/search", post(search_comics))
        .route("/comic/info", post(comic_info))
        .route("/comic/pages", post(comic_pages))
        .route("/image", get(proxy_image))
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
        database: "sqlite",
        data_dir: state.config.data_dir.display().to_string(),
        source_runtime: state.config.source_runtime_path().is_file(),
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
                status: "available",
                reason: Some("basic server-side source search runtime is available"),
            },
            Capability {
                key: "reader",
                label: "Reader API",
                status: "available",
                reason: Some("basic details and chapter image APIs are available"),
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

async fn get_library(State(state): State<AppState>) -> ApiResult<Json<LibraryResponse>> {
    Ok(Json(read_library(&state)?))
}

async fn upsert_history(
    State(state): State<AppState>,
    Json(payload): Json<HistoryWriteRequest>,
) -> ApiResult<Json<LibraryResponse>> {
    validate_library_key(&payload.source_key, &payload.comic_id)?;
    if payload.title.trim().is_empty() || payload.episode_id.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "history title and episode id cannot be empty".to_string(),
        ));
    }

    {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        database.execute(
            r#"
            INSERT INTO reading_history (
                source_key, comic_id, title, subtitle, cover, episode_id, episode_title, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, CURRENT_TIMESTAMP)
            ON CONFLICT(source_key, comic_id) DO UPDATE SET
                title = excluded.title,
                subtitle = excluded.subtitle,
                cover = excluded.cover,
                episode_id = excluded.episode_id,
                episode_title = excluded.episode_title,
                updated_at = CURRENT_TIMESTAMP
            "#,
            params![
                payload.source_key,
                payload.comic_id,
                payload.title.trim(),
                payload.subtitle,
                payload.cover,
                payload.episode_id.trim(),
                payload.episode_title.trim(),
            ],
        )?;
    }

    Ok(Json(read_library(&state)?))
}

async fn set_favorite(
    State(state): State<AppState>,
    Json(payload): Json<FavoriteWriteRequest>,
) -> ApiResult<Json<LibraryResponse>> {
    validate_library_key(&payload.source_key, &payload.comic_id)?;
    if payload.favorite && payload.title.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "favorite title cannot be empty".to_string(),
        ));
    }

    {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        if payload.favorite {
            database.execute(
                r#"
                INSERT INTO favorites (source_key, comic_id, title, subtitle, cover, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, CURRENT_TIMESTAMP)
                ON CONFLICT(source_key, comic_id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    cover = excluded.cover
                "#,
                params![
                    payload.source_key,
                    payload.comic_id,
                    payload.title.trim(),
                    payload.subtitle,
                    payload.cover,
                ],
            )?;
        } else {
            database.execute(
                "DELETE FROM favorites WHERE source_key = ?1 AND comic_id = ?2",
                params![payload.source_key, payload.comic_id],
            )?;
        }
    }

    Ok(Json(read_library(&state)?))
}

async fn search_comics(
    State(state): State<AppState>,
    Json(payload): Json<SearchRequest>,
) -> ApiResult<Json<SearchResponse>> {
    if !is_valid_source_key(&payload.source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let keyword = payload.keyword.trim();
    if keyword.is_empty() {
        return Err(ApiError::BadRequest("keyword cannot be empty".to_string()));
    }

    let page = payload.page.unwrap_or(1).max(1);
    let file_name = source_file_name(&state, &payload.source_key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let result = source_runtime::search(&state.config, &source_path, keyword, page).await?;

    Ok(Json(SearchResponse {
        source_key: payload.source_key,
        keyword: keyword.to_string(),
        page,
        max_page: result.max_page,
        next: result.next,
        comics: result.comics,
    }))
}

async fn comic_info(
    State(state): State<AppState>,
    Json(payload): Json<ComicInfoRequest>,
) -> ApiResult<Json<ComicInfoResponse>> {
    if !is_valid_source_key(&payload.source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let comic_id = payload.comic_id.trim();
    if comic_id.is_empty() {
        return Err(ApiError::BadRequest("comic id cannot be empty".to_string()));
    }

    let file_name = source_file_name(&state, &payload.source_key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let comic = source_runtime::comic_info(&state.config, &source_path, comic_id).await?;

    Ok(Json(ComicInfoResponse {
        source_key: payload.source_key,
        comic,
    }))
}

async fn comic_pages(
    State(state): State<AppState>,
    Json(payload): Json<ComicPagesRequest>,
) -> ApiResult<Json<ComicPagesResponse>> {
    if !is_valid_source_key(&payload.source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let comic_id = payload.comic_id.trim();
    let episode_id = payload.episode_id.trim();
    if comic_id.is_empty() || episode_id.is_empty() {
        return Err(ApiError::BadRequest(
            "comic id and episode id are required".to_string(),
        ));
    }

    let file_name = source_file_name(&state, &payload.source_key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let pages =
        source_runtime::comic_pages(&state.config, &source_path, comic_id, episode_id).await?;

    Ok(Json(ComicPagesResponse {
        source_key: payload.source_key,
        comic_id: comic_id.to_string(),
        episode_id: episode_id.to_string(),
        images: pages.images,
    }))
}

async fn proxy_image(
    State(state): State<AppState>,
    Query(query): Query<ImageProxyQuery>,
) -> ApiResult<Response> {
    let image = image_proxy::load_image(&state.config, &query.url).await?;
    let content_type = HeaderValue::from_str(&image.content_type)
        .map_err(|_| ApiError::ImageProxy("invalid image content type".to_string()))?;
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, content_type);
    headers.insert(
        CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=604800, immutable"),
    );
    headers.insert(
        "x-venera-cache",
        HeaderValue::from_static(image.cache_status),
    );

    Ok((headers, image.bytes).into_response())
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

fn read_library(state: &AppState) -> ApiResult<LibraryResponse> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;

    let history = {
        let mut statement = database.prepare(
            r#"
            SELECT source_key, comic_id, title, subtitle, cover, episode_id, episode_title, updated_at
            FROM reading_history
            ORDER BY updated_at DESC
            LIMIT 20
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok(LibraryItem {
                source_key: row.get(0)?,
                comic_id: row.get(1)?,
                title: row.get(2)?,
                subtitle: row.get(3)?,
                cover: row.get(4)?,
                episode_id: row.get(5)?,
                episode_title: row.get(6)?,
                updated_at: row.get(7)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    let favorites = {
        let mut statement = database.prepare(
            r#"
            SELECT source_key, comic_id, title, subtitle, cover, created_at
            FROM favorites
            ORDER BY created_at DESC
            LIMIT 50
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok(LibraryItem {
                source_key: row.get(0)?,
                comic_id: row.get(1)?,
                title: row.get(2)?,
                subtitle: row.get(3)?,
                cover: row.get(4)?,
                episode_id: None,
                episode_title: None,
                updated_at: row.get(5)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    Ok(LibraryResponse { history, favorites })
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

fn validate_library_key(source_key: &str, comic_id: &str) -> ApiResult<()> {
    if !is_valid_source_key(source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    if comic_id.trim().is_empty() {
        return Err(ApiError::BadRequest("comic id cannot be empty".to_string()));
    }
    Ok(())
}

fn source_file_name(state: &AppState, key: &str) -> ApiResult<String> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;

    database
        .query_row(
            "SELECT file_name FROM comic_sources WHERE source_key = ?1 AND enabled = 1",
            [key],
            |row| row.get::<_, String>(0),
        )
        .map_err(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => {
                ApiError::BadRequest("source not found".to_string())
            }
            other => ApiError::Database(other),
        })
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
