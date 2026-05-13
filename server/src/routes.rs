use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Path, Query, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE},
        HeaderMap, HeaderValue,
    },
    response::{IntoResponse, Response},
    routing::{get, patch, post},
    Json, Router,
};
use regex::Regex;
use rusqlite::params;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::fs;

use crate::{
    error::{ApiError, ApiResult},
    image_proxy, import_preview,
    models::{
        CapabilitiesResponse, Capability, ComicInfoRequest, ComicInfoResponse, ComicPagesRequest,
        ComicPagesResponse, DeleteResponse, FavoriteFolder, FavoriteWriteRequest,
        FollowUpdatesQuery, FollowUpdatesResponse, HealthResponse, HistoryWriteRequest,
        ImageProxyQuery, ImportBackupApplyRequest, ImportBackupApplyResponse,
        ImportBackupPreviewRequest, ImportBackupPreviewResponse, ImportBackupsResponse,
        LibraryItem, LibraryQuery, LibraryResponse, SearchRequest, SearchResponse, SettingsPatch,
        SettingsResponse, SourcePatchRequest, SourceSummary, SourceWriteRequest,
        WebDavConfigRequest, WebDavConfigResponse, WebDavDownloadRequest, WebDavDownloadResponse,
        WebDavListRequest, WebDavListResponse,
    },
    source_runtime,
    state::AppState,
    webdav_runtime::{self, WebDavConfig},
};

pub fn api_router() -> Router<AppState> {
    Router::new()
        .route("/health", get(health))
        .route("/capabilities", get(capabilities))
        .route("/settings", get(get_settings).put(update_settings))
        .route("/library", get(get_library))
        .route("/follow-updates", get(get_follow_updates))
        .route("/history", post(upsert_history))
        .route("/favorites", post(set_favorite))
        .route(
            "/webdav/config",
            get(get_webdav_config)
                .put(save_webdav_config)
                .delete(clear_webdav_config),
        )
        .route("/webdav/list", post(list_webdav))
        .route("/webdav/download", post(download_webdav))
        .route("/imports/backups", get(list_import_backups))
        .route("/imports/preview", post(preview_import_backup))
        .route("/imports/apply", post(apply_import_backup))
        .route("/sources", get(list_sources).post(upsert_source))
        .route("/sources/{key}", patch(update_source).delete(delete_source))
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

async fn get_library(
    State(state): State<AppState>,
    Query(query): Query<LibraryQuery>,
) -> ApiResult<Json<LibraryResponse>> {
    Ok(Json(read_library(&state, query)?))
}

async fn get_follow_updates(
    State(state): State<AppState>,
    Query(query): Query<FollowUpdatesQuery>,
) -> ApiResult<Json<FollowUpdatesResponse>> {
    Ok(Json(read_follow_updates(&state, query)?))
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

    Ok(Json(read_library(&state, LibraryQuery::default())?))
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

    Ok(Json(read_library(&state, LibraryQuery::default())?))
}

async fn get_webdav_config(State(state): State<AppState>) -> ApiResult<Json<WebDavConfigResponse>> {
    Ok(Json(read_webdav_config_response(&state)?))
}

async fn save_webdav_config(
    State(state): State<AppState>,
    Json(payload): Json<WebDavConfigRequest>,
) -> ApiResult<Json<WebDavConfigResponse>> {
    let endpoint_url = payload.endpoint_url.trim();
    if !endpoint_url.starts_with("http://") && !endpoint_url.starts_with("https://") {
        return Err(ApiError::BadRequest(
            "webdav url must use http or https".to_string(),
        ));
    }
    let root_path = normalize_remote_path(payload.root_path.as_deref().unwrap_or("/"))?;
    let root_path = if root_path.is_empty() {
        "/".to_string()
    } else {
        root_path
    };
    let username = payload.username.and_then(|value| {
        let value = value.trim().to_string();
        (!value.is_empty()).then_some(value)
    });
    let next_password = payload.password.map(|value| value.trim().to_string());

    {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let previous_password = database
            .query_row(
                "SELECT password FROM webdav_config WHERE id = 1",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .ok()
            .flatten();
        let password = next_password
            .filter(|value| !value.is_empty())
            .or(previous_password);

        database.execute(
            r#"
            INSERT INTO webdav_config (id, endpoint_url, username, password, root_path, updated_at)
            VALUES (1, ?1, ?2, ?3, ?4, CURRENT_TIMESTAMP)
            ON CONFLICT(id) DO UPDATE SET
                endpoint_url = excluded.endpoint_url,
                username = excluded.username,
                password = excluded.password,
                root_path = excluded.root_path,
                updated_at = CURRENT_TIMESTAMP
            "#,
            params![endpoint_url, username, password, root_path],
        )?;
    }

    Ok(Json(read_webdav_config_response(&state)?))
}

async fn clear_webdav_config(
    State(state): State<AppState>,
) -> ApiResult<Json<WebDavConfigResponse>> {
    {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        database.execute("DELETE FROM webdav_config WHERE id = 1", [])?;
    }

    Ok(Json(read_webdav_config_response(&state)?))
}

async fn list_webdav(
    State(state): State<AppState>,
    Json(payload): Json<WebDavListRequest>,
) -> ApiResult<Json<WebDavListResponse>> {
    let webdav_config = read_webdav_config(&state)?;
    let path = normalize_remote_path(payload.path.as_deref().unwrap_or(""))?;
    let response = webdav_runtime::list(&state.config, &webdav_config, &path).await?;
    Ok(Json(response))
}

async fn download_webdav(
    State(state): State<AppState>,
    Json(payload): Json<WebDavDownloadRequest>,
) -> ApiResult<Json<WebDavDownloadResponse>> {
    let webdav_config = read_webdav_config(&state)?;
    let path = normalize_remote_path(&payload.path)?;
    if path.is_empty() || path.ends_with('/') {
        return Err(ApiError::BadRequest(
            "webdav download path must be a file".to_string(),
        ));
    }

    let import_dir = state.config.imports_dir().join("webdav");
    fs::create_dir_all(&import_dir).await?;
    let file_name = local_import_file_name(&path);
    let local_path = import_dir.join(&file_name);
    let response =
        webdav_runtime::download(&state.config, &webdav_config, &path, &local_path).await?;
    Ok(Json(response))
}

async fn list_import_backups(
    State(state): State<AppState>,
) -> ApiResult<Json<ImportBackupsResponse>> {
    Ok(Json(import_preview::list_backups(&state.config).await?))
}

async fn preview_import_backup(
    State(state): State<AppState>,
    Json(payload): Json<ImportBackupPreviewRequest>,
) -> ApiResult<Json<ImportBackupPreviewResponse>> {
    Ok(Json(
        import_preview::preview_backup(&state.config, &payload.path).await?,
    ))
}

async fn apply_import_backup(
    State(state): State<AppState>,
    Json(payload): Json<ImportBackupApplyRequest>,
) -> ApiResult<Json<ImportBackupApplyResponse>> {
    Ok(Json(
        import_preview::apply_backup(&state, &payload.path).await?,
    ))
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

async fn update_source(
    State(state): State<AppState>,
    Path(key): Path<String>,
    Json(payload): Json<SourcePatchRequest>,
) -> ApiResult<Json<SourceSummary>> {
    if !is_valid_source_key(&key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let Some(enabled) = payload.enabled else {
        return Err(ApiError::BadRequest(
            "enabled field is required".to_string(),
        ));
    };

    let source = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let changed = database.execute(
            r#"
            UPDATE comic_sources
            SET enabled = ?2, updated_at = CURRENT_TIMESTAMP
            WHERE source_key = ?1
            "#,
            params![&key, enabled],
        )?;
        if changed == 0 {
            return Err(ApiError::BadRequest("source not found".to_string()));
        }

        database.query_row(
            r#"
            SELECT source_key, name, version, file_name, enabled, updated_at
            FROM comic_sources
            WHERE source_key = ?1
            "#,
            [&key],
            |row| {
                Ok(SourceSummary {
                    key: row.get(0)?,
                    name: row.get(1)?,
                    version: row.get(2)?,
                    file_name: row.get(3)?,
                    enabled: row.get::<_, i64>(4)? != 0,
                    runtime_status: "registered",
                    updated_at: row.get(5)?,
                })
            },
        )?
    };

    Ok(Json(source))
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

const DEFAULT_HISTORY_LIMIT: u32 = 20;
const DEFAULT_FAVORITES_LIMIT: u32 = 50;
const MAX_LIBRARY_LIMIT: u32 = 200;

struct LibraryWindow {
    history_limit: u32,
    history_offset: u32,
    favorites_limit: u32,
    favorites_offset: u32,
    favorite_folder: Option<String>,
}

impl From<LibraryQuery> for LibraryWindow {
    fn from(query: LibraryQuery) -> Self {
        let favorite_folder = query
            .favorite_folder
            .and_then(|value| (!value.trim().is_empty()).then(|| value.trim().to_string()));
        Self {
            history_limit: normalize_limit(query.history_limit, DEFAULT_HISTORY_LIMIT),
            history_offset: query.history_offset.unwrap_or(0),
            favorites_limit: normalize_limit(query.favorites_limit, DEFAULT_FAVORITES_LIMIT),
            favorites_offset: query.favorites_offset.unwrap_or(0),
            favorite_folder,
        }
    }
}

fn normalize_limit(value: Option<u32>, default: u32) -> u32 {
    match value {
        Some(0) => 0,
        Some(limit) => limit.clamp(1, MAX_LIBRARY_LIMIT),
        None => default,
    }
}

fn read_library(state: &AppState, query: LibraryQuery) -> ApiResult<LibraryResponse> {
    let window = LibraryWindow::from(query);
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
            LIMIT ?1 OFFSET ?2
            "#,
        )?;
        let rows = statement.query_map(
            params![
                i64::from(window.history_limit),
                i64::from(window.history_offset)
            ],
            |row| {
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
            },
        )?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let history_total = database.query_row("SELECT COUNT(*) FROM reading_history", [], |row| {
        row.get::<_, u64>(0)
    })?;

    let favorite_folders = read_favorite_folders(&database)?;
    let favorites = match window.favorite_folder.as_deref() {
        Some(folder_name) => {
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover, i.created_at
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                WHERE i.folder_name = ?1
                ORDER BY i.created_at DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let rows = statement.query_map(
                params![
                    folder_name,
                    i64::from(window.favorites_limit),
                    i64::from(window.favorites_offset)
                ],
                library_item_from_favorite_row,
            )?;
            rows.collect::<Result<Vec<_>, _>>()?
        }
        None => {
            let mut statement = database.prepare(
                r#"
                SELECT source_key, comic_id, title, subtitle, cover, created_at
                FROM favorites
                ORDER BY created_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let rows = statement.query_map(
                params![
                    i64::from(window.favorites_limit),
                    i64::from(window.favorites_offset)
                ],
                library_item_from_favorite_row,
            )?;
            rows.collect::<Result<Vec<_>, _>>()?
        }
    };
    let favorites_total = database.query_row("SELECT COUNT(*) FROM favorites", [], |row| {
        row.get::<_, u64>(0)
    })?;
    let favorites_window_total = match window.favorite_folder.as_deref() {
        Some(folder_name) => database.query_row(
            "SELECT COUNT(*) FROM favorite_folder_items WHERE folder_name = ?1",
            params![folder_name],
            |row| row.get::<_, u64>(0),
        )?,
        None => favorites_total,
    };

    Ok(LibraryResponse {
        history_total,
        favorites_total,
        favorites_window_total,
        history,
        favorites,
        favorite_folders,
    })
}

fn read_favorite_folders(database: &rusqlite::Connection) -> rusqlite::Result<Vec<FavoriteFolder>> {
    let mut statement = database.prepare(
        r#"
        SELECT folder_name, title, sort_order
        FROM favorite_folders
        ORDER BY sort_order ASC, title ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;

    let mut folders = Vec::new();
    for row in rows {
        let (name, title, _) = row?;
        let count = database.query_row(
            "SELECT COUNT(*) FROM favorite_folder_items WHERE folder_name = ?1",
            params![&name],
            |row| row.get::<_, u64>(0),
        )?;
        folders.push(FavoriteFolder { name, title, count });
    }

    Ok(folders)
}

fn library_item_from_favorite_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<LibraryItem> {
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
}

fn read_follow_updates(
    state: &AppState,
    query: FollowUpdatesQuery,
) -> ApiResult<FollowUpdatesResponse> {
    let folder = query
        .folder
        .and_then(|value| (!value.trim().is_empty()).then(|| value.trim().to_string()));
    let limit = normalize_limit(query.limit, DEFAULT_FAVORITES_LIMIT);
    let offset = query.offset.unwrap_or(0);
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;

    let (all_total, updated_total, updated, all) = match folder.as_deref() {
        Some(folder_name) => {
            let all_total = database.query_row(
                "SELECT COUNT(*) FROM favorite_folder_items WHERE folder_name = ?1",
                params![folder_name],
                |row| row.get::<_, u64>(0),
            )?;
            let updated_total = database.query_row(
                r#"
                SELECT COUNT(*)
                FROM favorite_folder_items
                WHERE folder_name = ?1 AND has_new_update != 0
                "#,
                params![folder_name],
                |row| row.get::<_, u64>(0),
            )?;
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       COALESCE(i.last_update_time, i.created_at)
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                WHERE i.folder_name = ?1 AND i.has_new_update != 0
                ORDER BY COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let rows = statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_favorite_row,
            )?;
            let updated = rows.collect::<Result<Vec<_>, _>>()?;
            let mut all_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       COALESCE(i.last_update_time, i.created_at)
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                WHERE i.folder_name = ?1
                ORDER BY i.has_new_update DESC, COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let all_rows = all_statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_favorite_row,
            )?;
            (
                all_total,
                updated_total,
                updated,
                all_rows.collect::<Result<Vec<_>, _>>()?,
            )
        }
        None => {
            let all_total = database.query_row(
                r#"
                SELECT COUNT(DISTINCT source_key || char(31) || comic_id)
                FROM favorite_folder_items
                "#,
                [],
                |row| row.get::<_, u64>(0),
            )?;
            let updated_total = database.query_row(
                r#"
                SELECT COUNT(DISTINCT source_key || char(31) || comic_id)
                FROM favorite_folder_items
                WHERE has_new_update != 0
                "#,
                [],
                |row| row.get::<_, u64>(0),
            )?;
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                WHERE i.has_new_update != 0
                GROUP BY f.source_key, f.comic_id
                ORDER BY updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let rows = statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_favorite_row,
            )?;
            let updated = rows.collect::<Result<Vec<_>, _>>()?;
            let mut all_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at,
                       MAX(i.has_new_update) AS has_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                GROUP BY f.source_key, f.comic_id
                ORDER BY has_update DESC, updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let all_rows = all_statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_favorite_row,
            )?;
            (
                all_total,
                updated_total,
                updated,
                all_rows.collect::<Result<Vec<_>, _>>()?,
            )
        }
    };

    Ok(FollowUpdatesResponse {
        folder,
        updated_total,
        all_total,
        updated,
        all,
    })
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

fn read_webdav_config_response(state: &AppState) -> ApiResult<WebDavConfigResponse> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let row = database
        .query_row(
            "SELECT endpoint_url, username, password, root_path, updated_at FROM webdav_config WHERE id = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .ok();

    if let Some((endpoint_url, username, password, root_path, updated_at)) = row {
        return Ok(WebDavConfigResponse {
            endpoint_url: Some(endpoint_url),
            username,
            root_path,
            password_configured: password.is_some_and(|value| !value.is_empty()),
            read_only: true,
            updated_at,
        });
    }

    Ok(WebDavConfigResponse {
        endpoint_url: None,
        username: None,
        root_path: "/".to_string(),
        password_configured: false,
        read_only: true,
        updated_at: None,
    })
}

fn read_webdav_config(state: &AppState) -> ApiResult<WebDavConfig> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database
        .query_row(
            "SELECT endpoint_url, username, password, root_path FROM webdav_config WHERE id = 1",
            [],
            |row| {
                Ok(WebDavConfig {
                    endpoint_url: row.get(0)?,
                    username: row.get(1)?,
                    password: row.get(2)?,
                    root_path: row.get(3)?,
                })
            },
        )
        .map_err(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => {
                ApiError::BadRequest("webdav config is missing".to_string())
            }
            other => ApiError::Database(other),
        })
}

fn normalize_remote_path(value: &str) -> ApiResult<String> {
    let normalized = value.trim().replace('\\', "/");
    let parts = normalized
        .split('/')
        .filter(|part| !part.is_empty())
        .map(str::trim)
        .collect::<Vec<_>>();
    if parts.iter().any(|part| *part == "." || *part == "..") {
        return Err(ApiError::BadRequest("invalid webdav path".to_string()));
    }
    Ok(parts.join("/"))
}

fn local_import_file_name(remote_path: &str) -> String {
    let original = remote_path
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or("webdav-file");
    let sanitized = original
        .chars()
        .map(|ch| match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '-' | '_' => ch,
            _ => '_',
        })
        .collect::<String>();
    let sanitized = sanitized.trim_matches('_');
    let digest = Sha256::digest(remote_path.as_bytes());
    let prefix = format!("{digest:x}").chars().take(12).collect::<String>();
    if sanitized.is_empty() {
        format!("{prefix}-webdav-file")
    } else {
        format!("{prefix}-{sanitized}")
    }
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
