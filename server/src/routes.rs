use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

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
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::fs;

use crate::{
    backup_export,
    error::{ApiError, ApiResult},
    image_proxy, import_preview,
    models::{
        CapabilitiesResponse, Capability, ComicInfoRequest, ComicInfoResponse, ComicPagesRequest,
        ComicPagesResponse, DeleteResponse, FavoriteFolder, FavoriteFolderCreateRequest,
        FavoriteFolderRenameRequest, FavoriteFolderResponse, FavoriteWriteRequest,
        FollowUpdatesCheckRequest, FollowUpdatesMarkReadRequest, FollowUpdatesQuery,
        FollowUpdatesResponse, HealthResponse, HistoryWriteRequest, ImageProxyQuery,
        ImportBackupApplyRequest, ImportBackupApplyResponse, ImportBackupPreviewRequest,
        ImportBackupPreviewResponse, ImportBackupsResponse, LibraryItem, LibraryQuery,
        LibraryResponse, RuntimeComicInfo, SearchRequest, SearchResponse, SettingsPatch,
        SettingsResponse, SourceCategoryRequest, SourceComicListResponse, SourceExploreRequest,
        SourcePageManifest, SourcePagesResponse, SourcePatchRequest, SourceSettingPatchRequest,
        SourceSettingsResponse, SourceSummary, SourceWriteRequest, TaskSummary, TasksResponse,
        WebDavConfigRequest, WebDavConfigResponse, WebDavDownloadRequest, WebDavDownloadResponse,
        WebDavListRequest, WebDavListResponse, WebDavSyncDownloadResponse, WebDavUploadRequest,
        WebDavUploadResponse,
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
        .route("/follow-updates/check", post(start_follow_update_check))
        .route("/follow-updates/mark-read", post(mark_follow_updates_read))
        .route("/tasks", get(list_tasks))
        .route("/history", post(upsert_history))
        .route("/favorites", post(set_favorite))
        .route(
            "/favorite-folders",
            get(list_favorite_folders).post(create_favorite_folder),
        )
        .route(
            "/favorite-folders/{name}",
            patch(rename_favorite_folder).delete(delete_favorite_folder),
        )
        .route(
            "/webdav/config",
            get(get_webdav_config)
                .put(save_webdav_config)
                .delete(clear_webdav_config),
        )
        .route("/webdav/list", post(list_webdav))
        .route("/webdav/download", post(download_webdav))
        .route("/webdav/download-latest", post(download_latest_webdav))
        .route("/webdav/upload", post(upload_webdav))
        .route("/imports/backups", get(list_import_backups))
        .route("/imports/preview", post(preview_import_backup))
        .route("/imports/apply", post(apply_import_backup))
        .route("/sources", get(list_sources).post(upsert_source))
        .route("/source-pages", get(list_source_pages))
        .route("/source-pages/explore", post(load_source_explore_page))
        .route("/source-pages/category", post(load_source_category_page))
        .route(
            "/sources/{key}/settings",
            get(get_source_settings).patch(update_source_setting),
        )
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

async fn start_follow_update_check(
    State(state): State<AppState>,
    Json(payload): Json<FollowUpdatesCheckRequest>,
) -> ApiResult<Json<TaskSummary>> {
    let folder = payload.folder.trim().to_string();
    if folder.is_empty() {
        return Err(ApiError::BadRequest("folder is required".to_string()));
    }

    ensure_favorite_folder(&state, &folder)?;
    if let Some(task) = running_follow_update_task(&state, &folder)? {
        return Ok(Json(task));
    }

    let force = payload.force.unwrap_or(true);
    let limit = payload.limit.map(|value| value.clamp(1, 1000));
    let dry_run = payload.dry_run.unwrap_or(false);
    let total = count_follow_check_items(&state, &folder, force, limit)?;
    let task_id = format!("follow-updates-{}", now_millis());
    let payload = follow_task_payload(&folder, total, 0, 0, 0, None, dry_run);
    insert_task(&state, &task_id, "follow_updates", &payload)?;

    let worker_state = state.clone();
    let worker_task_id = task_id.clone();
    tokio::spawn(async move {
        run_follow_update_task(worker_state, worker_task_id, folder, force, limit, dry_run).await;
    });

    Ok(Json(read_task(&state, &task_id)?))
}

async fn mark_follow_updates_read(
    State(state): State<AppState>,
    Json(payload): Json<FollowUpdatesMarkReadRequest>,
) -> ApiResult<Json<FollowUpdatesResponse>> {
    let folder = payload.folder.trim().to_string();
    if folder.is_empty() {
        return Err(ApiError::BadRequest("folder is required".to_string()));
    }
    ensure_favorite_folder(&state, &folder)?;
    {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        database.execute(
            "UPDATE favorite_folder_items SET has_new_update = 0 WHERE folder_name = ?1",
            [&folder],
        )?;
    }
    Ok(Json(read_follow_updates(
        &state,
        FollowUpdatesQuery {
            folder: Some(folder),
            limit: None,
            offset: None,
        },
    )?))
}

async fn list_tasks(State(state): State<AppState>) -> ApiResult<Json<TasksResponse>> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let mut statement = database.prepare(
        r#"
        SELECT id, kind, status, progress, payload, error, created_at, updated_at
        FROM tasks
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 50
        "#,
    )?;
    let rows = statement.query_map([], task_from_row)?;
    Ok(Json(TasksResponse {
        tasks: rows.collect::<Result<Vec<_>, _>>()?,
    }))
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
                source_key, comic_id, title, subtitle, cover, episode_id, episode_title, page, max_page, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, CURRENT_TIMESTAMP)
            ON CONFLICT(source_key, comic_id) DO UPDATE SET
                title = excluded.title,
                subtitle = excluded.subtitle,
                cover = excluded.cover,
                episode_id = excluded.episode_id,
                episode_title = excluded.episode_title,
                page = excluded.page,
                max_page = excluded.max_page,
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
                payload.page,
                payload.max_page,
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

async fn list_favorite_folders(
    State(state): State<AppState>,
) -> ApiResult<Json<FavoriteFolderResponse>> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let folders = read_favorite_folders(&database)?;
    Ok(Json(FavoriteFolderResponse { folders }))
}

async fn create_favorite_folder(
    State(state): State<AppState>,
    Json(payload): Json<FavoriteFolderCreateRequest>,
) -> ApiResult<Json<FavoriteFolderResponse>> {
    let name = payload.name.trim().to_string();
    let title = payload.title.trim().to_string();
    if name.is_empty() || title.is_empty() {
        return Err(ApiError::BadRequest(
            "folder name and title are required".to_string(),
        ));
    }
    if !name
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
    {
        return Err(ApiError::BadRequest(
            "folder name contains invalid characters".to_string(),
        ));
    }

    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let exists: bool = database
        .query_row(
            "SELECT 1 FROM favorite_folders WHERE folder_name = ?1",
            [&name],
            |_| Ok(true),
        )
        .optional()?
        .unwrap_or(false);
    if exists {
        return Err(ApiError::BadRequest(
            "folder already exists".to_string(),
        ));
    }

    let max_order: i64 = database
        .query_row(
            "SELECT COALESCE(MAX(sort_order), -1) FROM favorite_folders",
            [],
            |row| row.get(0),
        )
        .unwrap_or(-1);
    database.execute(
        "INSERT INTO favorite_folders (folder_name, title, sort_order) VALUES (?1, ?2, ?3)",
        params![&name, &title, max_order + 1],
    )?;

    let folders = read_favorite_folders(&database)?;
    Ok(Json(FavoriteFolderResponse { folders }))
}

async fn rename_favorite_folder(
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(payload): Json<FavoriteFolderRenameRequest>,
) -> ApiResult<Json<FavoriteFolderResponse>> {
    let title = payload.title.trim().to_string();
    if title.is_empty() {
        return Err(ApiError::BadRequest("folder title is required".to_string()));
    }

    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let changed = database.execute(
        "UPDATE favorite_folders SET title = ?1 WHERE folder_name = ?2",
        params![&title, &name],
    )?;
    if changed == 0 {
        return Err(ApiError::BadRequest("folder not found".to_string()));
    }

    let folders = read_favorite_folders(&database)?;
    Ok(Json(FavoriteFolderResponse { folders }))
}

async fn delete_favorite_folder(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> ApiResult<Json<DeleteResponse>> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database.execute(
        "DELETE FROM favorite_folder_items WHERE folder_name = ?1",
        [&name],
    )?;
    let deleted = database.execute("DELETE FROM favorite_folders WHERE folder_name = ?1", [&name])?;
    Ok(Json(DeleteResponse {
        deleted: deleted > 0,
    }))
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
    if let Some(auto_sync) = payload.auto_sync {
        write_setting_value(&state, "webdavAutoSync", json!(auto_sync))?;
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
    write_setting_value(&state, "webdavAutoSync", json!(false))?;

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

async fn download_latest_webdav(
    State(state): State<AppState>,
) -> ApiResult<Json<WebDavSyncDownloadResponse>> {
    let webdav_config = read_webdav_config(&state)?;
    let local_version = read_data_version(&state)?;
    let listing = webdav_runtime::list(&state.config, &webdav_config, "").await?;
    let latest = listing
        .entries
        .into_iter()
        .filter(|entry| !entry.is_dir && entry.name.ends_with(".venera"))
        .max_by(|left, right| left.name.cmp(&right.name))
        .ok_or_else(|| ApiError::WebDav("No data file found".to_string()))?;
    let remote_version = data_version_from_file_name(&latest.name);
    if remote_version.is_some_and(|version| version <= local_version) {
        return Ok(Json(WebDavSyncDownloadResponse {
            skipped: true,
            message: "No new data to download".to_string(),
            local_version,
            remote_version,
            download: None,
            import_result: None,
        }));
    }

    let import_dir = state.config.imports_dir().join("webdav");
    fs::create_dir_all(&import_dir).await?;
    let file_name = local_import_file_name(&latest.path);
    let local_path = import_dir.join(&file_name);
    let download =
        webdav_runtime::download(&state.config, &webdav_config, &latest.path, &local_path).await?;
    let import_path = format!("webdav/{file_name}");
    let import_result = import_preview::apply_backup(&state, &import_path).await?;
    if let Some(version) = remote_version {
        write_data_version(&state, version)?;
    }
    let local_version = match remote_version {
        Some(version) => version,
        None => read_data_version(&state)?,
    };

    Ok(Json(WebDavSyncDownloadResponse {
        skipped: false,
        message: "Data downloaded successfully".to_string(),
        local_version,
        remote_version,
        download: Some(download),
        import_result: Some(import_result),
    }))
}

async fn upload_webdav(
    State(state): State<AppState>,
    Json(payload): Json<WebDavUploadRequest>,
) -> ApiResult<Json<WebDavUploadResponse>> {
    let backup = backup_export::export_backup(&state).await?;
    let next_version = data_version_from_file_name(&backup.file_name);
    if payload.dry_run.unwrap_or(false) {
        return Ok(Json(backup));
    }

    let webdav_config = read_webdav_config(&state)?;
    let local_path = PathBuf::from(&backup.local_path);
    let response = webdav_runtime::upload(
        &state.config,
        &webdav_config,
        &backup.remote_path,
        &local_path,
    )
    .await?;
    if let Some(next_version) = next_version {
        write_data_version(&state, next_version)?;
    }
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

async fn list_source_pages(State(state): State<AppState>) -> ApiResult<Json<SourcePagesResponse>> {
    let rows = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let mut statement = database.prepare(
            r#"
            SELECT source_key, name, file_name
            FROM comic_sources
            WHERE enabled = 1
            ORDER BY name COLLATE NOCASE
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    let mut sources = Vec::with_capacity(rows.len());
    for (source_key, source_name, file_name) in rows {
        let source_path = state.config.sources_dir().join(file_name);
        let manifest = source_runtime::manifest(&state.config, &source_path).await;
        match manifest {
            Ok(manifest) => sources.push(SourcePageManifest {
                source_key,
                source_name,
                explore_pages: manifest.explore_pages,
                category: manifest.category,
                error: None,
            }),
            Err(err) => sources.push(SourcePageManifest {
                source_key,
                source_name,
                explore_pages: Vec::new(),
                category: None,
                error: Some(err.to_string()),
            }),
        }
    }

    Ok(Json(SourcePagesResponse { sources }))
}

async fn load_source_explore_page(
    State(state): State<AppState>,
    Json(payload): Json<SourceExploreRequest>,
) -> ApiResult<Json<SourceComicListResponse>> {
    if !is_valid_source_key(&payload.source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let title = payload.title.trim();
    if title.is_empty() {
        return Err(ApiError::BadRequest(
            "explore page title cannot be empty".to_string(),
        ));
    }

    let page = payload.page.unwrap_or(1).max(1);
    let file_name = source_file_name(&state, &payload.source_key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let result = source_runtime::explore_page(&state.config, &source_path, title, page).await?;

    Ok(Json(SourceComicListResponse {
        source_key: payload.source_key,
        page,
        title: Some(title.to_string()),
        category: None,
        param: None,
        max_page: result.max_page,
        next: result.next,
        comics: result.comics,
        parts: result.parts,
    }))
}

async fn load_source_category_page(
    State(state): State<AppState>,
    Json(payload): Json<SourceCategoryRequest>,
) -> ApiResult<Json<SourceComicListResponse>> {
    if !is_valid_source_key(&payload.source_key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let category = payload.category.trim();
    if category.is_empty() {
        return Err(ApiError::BadRequest("category cannot be empty".to_string()));
    }

    let page = payload.page.unwrap_or(1).max(1);
    let param = payload.param.and_then(|value| {
        let value = value.trim().to_string();
        (!value.is_empty()).then_some(value)
    });
    let options = payload.options.unwrap_or_default();
    let file_name = source_file_name(&state, &payload.source_key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let result = source_runtime::category_page(
        &state.config,
        &source_path,
        category,
        param.as_deref(),
        &options,
        page,
    )
    .await?;

    Ok(Json(SourceComicListResponse {
        source_key: payload.source_key,
        page,
        title: None,
        category: Some(category.to_string()),
        param,
        max_page: result.max_page,
        next: result.next,
        comics: result.comics,
        parts: result.parts,
    }))
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

async fn get_source_settings(
    State(state): State<AppState>,
    Path(key): Path<String>,
) -> ApiResult<Json<SourceSettingsResponse>> {
    if !is_valid_source_key(&key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    let file_name = source_file_name_any(&state, &key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let settings = source_runtime::source_settings(&state.config, &source_path).await?;
    Ok(Json(settings))
}

async fn update_source_setting(
    State(state): State<AppState>,
    Path(key): Path<String>,
    Json(payload): Json<SourceSettingPatchRequest>,
) -> ApiResult<Json<SourceSettingsResponse>> {
    if !is_valid_source_key(&key) {
        return Err(ApiError::BadRequest("invalid source key".to_string()));
    }
    if payload.key.trim().is_empty() {
        return Err(ApiError::BadRequest("setting key is required".to_string()));
    }
    let file_name = source_file_name_any(&state, &key)?;
    let source_path = state.config.sources_dir().join(file_name);
    let settings = source_runtime::set_source_setting(
        &state.config,
        &source_path,
        payload.key.trim(),
        &payload.value,
    )
    .await?;
    Ok(Json(settings))
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
            SELECT h.source_key, h.comic_id, h.title, h.subtitle, h.cover,
                   h.episode_id, h.episode_title, h.page, h.max_page, h.updated_at,
                   s.name, COALESCE(m.author, h.subtitle), m.update_time,
                   NULL, m.tags_json, m.status, NULL,
                   CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                   m.description, m.latest_title, 0
            FROM reading_history h
            LEFT JOIN comic_sources s ON s.source_key = h.source_key
            LEFT JOIN comic_metadata m ON m.source_key = h.source_key AND m.comic_id = h.comic_id
            ORDER BY h.updated_at DESC
            LIMIT ?1 OFFSET ?2
            "#,
        )?;
        let rows = statement.query_map(
            params![
                i64::from(window.history_limit),
                i64::from(window.history_offset)
            ],
            library_item_from_query_row,
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
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, i.created_at,
                       s.name, COALESCE(m.author, f.subtitle), COALESCE(i.last_update_time, m.update_time),
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, i.has_new_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = f.source_key AND h.comic_id = f.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.folder_name = ?1
                ORDER BY datetime(i.created_at) DESC, f.title COLLATE NOCASE ASC, f.comic_id ASC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let rows = statement.query_map(
                params![
                    folder_name,
                    i64::from(window.favorites_limit),
                    i64::from(window.favorites_offset)
                ],
                library_item_from_query_row,
            )?;
            rows.collect::<Result<Vec<_>, _>>()?
        }
        None => {
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, f.created_at,
                       s.name, COALESCE(m.author, f.subtitle), m.update_time,
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, 0
                FROM favorites f
                LEFT JOIN reading_history h ON h.source_key = f.source_key AND h.comic_id = f.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                ORDER BY datetime(f.created_at) DESC, f.title COLLATE NOCASE ASC, f.comic_id ASC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let rows = statement.query_map(
                params![
                    i64::from(window.favorites_limit),
                    i64::from(window.favorites_offset)
                ],
                library_item_from_query_row,
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

fn library_item_from_query_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<LibraryItem> {
    let source_key: String = row.get(0)?;
    let episode_title: Option<String> = row.get(6)?;
    let page: Option<u32> = row.get(7)?;
    let max_page: Option<u32> = row.get(8)?;
    let progress_text: Option<String> = row.get(16)?;
    let pages_text: Option<String> = row.get(17)?;
    let has_new_update = row.get::<_, Option<i64>>(20)?.unwrap_or(0) != 0;
    Ok(LibraryItem {
        source_key,
        comic_id: row.get(1)?,
        title: row.get(2)?,
        subtitle: row.get(3)?,
        cover: row.get(4)?,
        episode_id: row.get(5)?,
        episode_title: episode_title.clone(),
        page,
        max_page,
        updated_at: row.get(9)?,
        source_name: row.get(10)?,
        author: row.get(11)?,
        update_time: row.get(12)?,
        tags: parse_library_tags(row.get(13)?, row.get(14)?),
        status: row.get(15)?,
        progress_text: progress_text.or_else(|| format_progress_text(episode_title, page)),
        pages_text: pages_text.or_else(|| max_page.map(|value| value.to_string())),
        description: row.get(18)?,
        latest_title: row.get(19)?,
        has_new_update,
    })
}

fn parse_library_tags(favorite_tags: Option<String>, metadata_tags: Option<String>) -> Vec<String> {
    let mut tags = metadata_tags
        .and_then(|value| serde_json::from_str::<Vec<String>>(&value).ok())
        .unwrap_or_default();
    if tags.is_empty() {
        tags = favorite_tags
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .collect();
    }
    tags
}

fn format_progress_text(episode_title: Option<String>, page: Option<u32>) -> Option<String> {
    match (episode_title, page) {
        (Some(episode), Some(page)) => Some(format!("{episode} - 第 {page} 页")),
        (Some(episode), None) => Some(episode),
        (None, Some(page)) => Some(format!("第 {page} 页")),
        (None, None) => None,
    }
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

    let (all_total, updated_total, unread_total, ended_total, updated, unread, ended, all) = match folder.as_deref() {
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
            let unread_total = database.query_row(
                r#"
                SELECT COUNT(*)
                FROM favorite_folder_items i
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                WHERE i.folder_name = ?1
                  AND h.source_key IS NULL
                "#,
                params![folder_name],
                |row| row.get::<_, u64>(0),
            )?;
            let ended_total = database.query_row(
                r#"
                SELECT COUNT(*)
                FROM favorite_folder_items i
                JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                WHERE i.folder_name = ?1
                  AND h.max_page IS NOT NULL
                  AND h.page IS NOT NULL
                  AND h.page >= h.max_page
                "#,
                params![folder_name],
                |row| row.get::<_, u64>(0),
            )?;
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, COALESCE(i.last_update_time, i.created_at),
                       s.name, COALESCE(m.author, f.subtitle), COALESCE(i.last_update_time, m.update_time),
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, i.has_new_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.folder_name = ?1 AND i.has_new_update != 0
                ORDER BY COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let rows = statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let updated = rows.collect::<Result<Vec<_>, _>>()?;
            let mut unread_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, COALESCE(i.last_update_time, i.created_at),
                       s.name, COALESCE(m.author, f.subtitle), COALESCE(i.last_update_time, m.update_time),
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, i.has_new_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.folder_name = ?1
                  AND h.source_key IS NULL
                ORDER BY i.has_new_update DESC, COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let unread_rows = unread_statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let unread = unread_rows.collect::<Result<Vec<_>, _>>()?;
            let mut ended_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, COALESCE(i.last_update_time, i.created_at),
                       s.name, COALESCE(m.author, f.subtitle), COALESCE(i.last_update_time, m.update_time),
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, i.has_new_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.folder_name = ?1
                  AND h.max_page IS NOT NULL
                  AND h.page IS NOT NULL
                  AND h.page >= h.max_page
                ORDER BY COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let ended_rows = ended_statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let ended = ended_rows.collect::<Result<Vec<_>, _>>()?;
            let mut all_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, h.page, h.max_page, COALESCE(i.last_update_time, i.created_at),
                       s.name, COALESCE(m.author, f.subtitle), COALESCE(i.last_update_time, m.update_time),
                       f.tags, m.tags_json, m.status, NULL,
                       CASE WHEN m.page_count IS NOT NULL THEN CAST(m.page_count AS TEXT) ELSE NULL END,
                       m.description, m.latest_title, i.has_new_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.folder_name = ?1
                ORDER BY i.has_new_update DESC, COALESCE(i.last_update_time, i.created_at) DESC
                LIMIT ?2 OFFSET ?3
                "#,
            )?;
            let all_rows = all_statement.query_map(
                params![folder_name, i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            (
                all_total,
                updated_total,
                unread_total,
                ended_total,
                updated,
                unread,
                ended,
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
            let unread_total = database.query_row(
                r#"
                SELECT COUNT(DISTINCT i.source_key || char(31) || i.comic_id)
                FROM favorite_folder_items i
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                WHERE h.source_key IS NULL
                "#,
                [],
                |row| row.get::<_, u64>(0),
            )?;
            let ended_total = database.query_row(
                r#"
                SELECT COUNT(DISTINCT i.source_key || char(31) || i.comic_id)
                FROM favorite_folder_items i
                JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                WHERE h.max_page IS NOT NULL
                  AND h.page IS NOT NULL
                  AND h.page >= h.max_page
                "#,
                [],
                |row| row.get::<_, u64>(0),
            )?;
            let mut statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, MAX(h.page) AS page, MAX(h.max_page) AS max_page,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at,
                       MAX(s.name), COALESCE(MAX(m.author), f.subtitle),
                       COALESCE(MAX(i.last_update_time), MAX(m.update_time)),
                       f.tags, MAX(m.tags_json), MAX(m.status), NULL,
                       CASE WHEN MAX(m.page_count) IS NOT NULL THEN CAST(MAX(m.page_count) AS TEXT) ELSE NULL END,
                       MAX(m.description), MAX(m.latest_title), MAX(i.has_new_update)
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE i.has_new_update != 0
                GROUP BY f.source_key, f.comic_id
                ORDER BY updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let rows = statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let updated = rows.collect::<Result<Vec<_>, _>>()?;
            let mut unread_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, MAX(h.page) AS page, MAX(h.max_page) AS max_page,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at,
                       MAX(s.name), COALESCE(MAX(m.author), f.subtitle),
                       COALESCE(MAX(i.last_update_time), MAX(m.update_time)),
                       f.tags, MAX(m.tags_json), MAX(m.status), NULL,
                       CASE WHEN MAX(m.page_count) IS NOT NULL THEN CAST(MAX(m.page_count) AS TEXT) ELSE NULL END,
                       MAX(m.description), MAX(m.latest_title), MAX(i.has_new_update) AS has_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE h.source_key IS NULL
                GROUP BY f.source_key, f.comic_id
                ORDER BY has_update DESC, updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let unread_rows = unread_statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let unread = unread_rows.collect::<Result<Vec<_>, _>>()?;
            let mut ended_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, MAX(h.page) AS page, MAX(h.max_page) AS max_page,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at,
                       MAX(s.name), COALESCE(MAX(m.author), f.subtitle),
                       COALESCE(MAX(i.last_update_time), MAX(m.update_time)),
                       f.tags, MAX(m.tags_json), MAX(m.status), NULL,
                       CASE WHEN MAX(m.page_count) IS NOT NULL THEN CAST(MAX(m.page_count) AS TEXT) ELSE NULL END,
                       MAX(m.description), MAX(m.latest_title), MAX(i.has_new_update)
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                WHERE h.max_page IS NOT NULL
                  AND h.page IS NOT NULL
                  AND h.page >= h.max_page
                GROUP BY f.source_key, f.comic_id
                ORDER BY updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let ended_rows = ended_statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            let ended = ended_rows.collect::<Result<Vec<_>, _>>()?;
            let mut all_statement = database.prepare(
                r#"
                SELECT f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
                       NULL, NULL, MAX(h.page) AS page, MAX(h.max_page) AS max_page,
                       MAX(COALESCE(i.last_update_time, i.created_at)) AS updated_at,
                       MAX(s.name), COALESCE(MAX(m.author), f.subtitle),
                       COALESCE(MAX(i.last_update_time), MAX(m.update_time)),
                       f.tags, MAX(m.tags_json), MAX(m.status), NULL,
                       CASE WHEN MAX(m.page_count) IS NOT NULL THEN CAST(MAX(m.page_count) AS TEXT) ELSE NULL END,
                       MAX(m.description), MAX(m.latest_title), MAX(i.has_new_update) AS has_update
                FROM favorite_folder_items i
                JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
                LEFT JOIN reading_history h ON h.source_key = i.source_key AND h.comic_id = i.comic_id
                LEFT JOIN comic_sources s ON s.source_key = f.source_key
                LEFT JOIN comic_metadata m ON m.source_key = f.source_key AND m.comic_id = f.comic_id
                GROUP BY f.source_key, f.comic_id
                ORDER BY has_update DESC, updated_at DESC
                LIMIT ?1 OFFSET ?2
                "#,
            )?;
            let all_rows = all_statement.query_map(
                params![i64::from(limit), i64::from(offset)],
                library_item_from_query_row,
            )?;
            (
                all_total,
                updated_total,
                unread_total,
                ended_total,
                updated,
                unread,
                ended,
                all_rows.collect::<Result<Vec<_>, _>>()?,
            )
        }
    };

    Ok(FollowUpdatesResponse {
        folder,
        updated_total,
        unread_total,
        ended_total,
        all_total,
        updated,
        unread,
        ended,
        all,
    })
}

struct FollowCheckItem {
    folder_name: String,
    source_key: String,
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    last_update_time: Option<String>,
    file_name: String,
}

async fn run_follow_update_task(
    state: AppState,
    task_id: String,
    folder: String,
    force: bool,
    limit: Option<u32>,
    dry_run: bool,
) {
    let result =
        run_follow_update_task_inner(&state, &task_id, &folder, force, limit, dry_run).await;
    if let Err(err) = result {
        let payload = json!({ "folder": folder });
        let _ = update_task(
            &state,
            &task_id,
            "failed",
            100,
            &payload,
            Some(err.to_string()),
        );
    }
}

async fn run_follow_update_task_inner(
    state: &AppState,
    task_id: &str,
    folder: &str,
    force: bool,
    limit: Option<u32>,
    dry_run: bool,
) -> ApiResult<()> {
    let items = read_follow_check_items(state, folder, force, limit)?;
    let total = items.len() as u64;
    if total == 0 {
        let payload = follow_task_payload(folder, 0, 0, 0, 0, None, dry_run);
        update_task(state, task_id, "completed", 100, &payload, None)?;
        return Ok(());
    }

    let mut checked = 0;
    let mut updated = 0;
    let mut failed = 0;
    for item in items {
        let current_title = Some(item.title.clone());
        match check_follow_item(state, &item, dry_run).await {
            Ok(has_update) => {
                if has_update {
                    updated += 1;
                }
            }
            Err(_) => {
                failed += 1;
            }
        }
        checked += 1;
        let progress = ((checked * 100) / total).min(100) as u32;
        let payload = follow_task_payload(
            folder,
            total,
            checked,
            updated,
            failed,
            current_title,
            dry_run,
        );
        update_task(state, task_id, "running", progress, &payload, None)?;
    }

    let payload = follow_task_payload(folder, total, checked, updated, failed, None, dry_run);
    update_task(state, task_id, "completed", 100, &payload, None)
}

async fn check_follow_item(
    state: &AppState,
    item: &FollowCheckItem,
    dry_run: bool,
) -> ApiResult<bool> {
    let source_path = state.config.sources_dir().join(&item.file_name);
    let info = source_runtime::comic_info(&state.config, &source_path, &item.comic_id).await?;
    let marker = follow_update_marker(&info);
    let has_update = marker
        .as_deref()
        .map(|next| !follow_markers_equivalent(item.last_update_time.as_deref(), next))
        .unwrap_or(false);
    let now = now_millis() as i64;
    if dry_run {
        return Ok(has_update);
    }

    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database.execute(
        r#"
        UPDATE favorites
        SET title = ?1, subtitle = ?2, cover = ?3
        WHERE source_key = ?4 AND comic_id = ?5
        "#,
        params![
            info.title.trim(),
            info.subtitle.as_deref().or(item.subtitle.as_deref()),
            info.cover.as_deref().or(item.cover.as_deref()),
            &item.source_key,
            &item.comic_id,
        ],
    )?;

    if let Some(marker) = marker {
        database.execute(
            r#"
            UPDATE favorite_folder_items
            SET last_update_time = ?1,
                has_new_update = CASE WHEN ?2 THEN 1 ELSE has_new_update END,
                last_check_time = ?3
            WHERE folder_name = ?4 AND source_key = ?5 AND comic_id = ?6
            "#,
            params![
                marker,
                has_update,
                now,
                &item.folder_name,
                &item.source_key,
                &item.comic_id,
            ],
        )?;
    } else {
        database.execute(
            r#"
            UPDATE favorite_folder_items
            SET last_check_time = ?1
            WHERE folder_name = ?2 AND source_key = ?3 AND comic_id = ?4
            "#,
            params![now, &item.folder_name, &item.source_key, &item.comic_id],
        )?;
    }

    Ok(has_update)
}

fn read_follow_check_items(
    state: &AppState,
    folder: &str,
    force: bool,
    limit: Option<u32>,
) -> ApiResult<Vec<FollowCheckItem>> {
    let cutoff = now_millis().saturating_sub(24 * 60 * 60 * 1000) as i64;
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let mut statement = database.prepare(
        r#"
        SELECT i.folder_name, f.source_key, f.comic_id, f.title, f.subtitle, f.cover,
               i.last_update_time, s.file_name
        FROM favorite_folder_items i
        JOIN favorites f ON f.source_key = i.source_key AND f.comic_id = i.comic_id
        JOIN comic_sources s ON s.source_key = i.source_key AND s.enabled = 1
        WHERE i.folder_name = ?1
          AND (?2 OR i.last_check_time IS NULL OR i.last_check_time < ?3)
        ORDER BY i.created_at DESC
        LIMIT ?4
        "#,
    )?;
    let rows = statement.query_map(
        params![folder, force, cutoff, i64::from(limit.unwrap_or(u32::MAX))],
        |row| {
            Ok(FollowCheckItem {
                folder_name: row.get(0)?,
                source_key: row.get(1)?,
                comic_id: row.get(2)?,
                title: row.get(3)?,
                subtitle: row.get(4)?,
                cover: row.get(5)?,
                last_update_time: row.get(6)?,
                file_name: row.get(7)?,
            })
        },
    )?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

fn count_follow_check_items(
    state: &AppState,
    folder: &str,
    force: bool,
    limit: Option<u32>,
) -> ApiResult<u64> {
    let cutoff = now_millis().saturating_sub(24 * 60 * 60 * 1000) as i64;
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let count = database.query_row(
        r#"
        SELECT COUNT(*)
        FROM favorite_folder_items i
        JOIN comic_sources s ON s.source_key = i.source_key AND s.enabled = 1
        WHERE i.folder_name = ?1
          AND (?2 OR i.last_check_time IS NULL OR i.last_check_time < ?3)
        "#,
        params![folder, force, cutoff],
        |row| row.get(0),
    )?;
    Ok(limit.map(u64::from).map_or(count, |value| count.min(value)))
}

fn ensure_favorite_folder(state: &AppState, folder: &str) -> ApiResult<()> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let exists = database
        .query_row(
            "SELECT 1 FROM favorite_folders WHERE folder_name = ?1",
            [folder],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if exists {
        Ok(())
    } else {
        Err(ApiError::BadRequest(
            "favorite folder not found".to_string(),
        ))
    }
}

fn follow_update_marker(info: &RuntimeComicInfo) -> Option<String> {
    raw_update_time(&info.raw).or_else(|| chapter_update_marker(info))
}

fn raw_update_time(raw: &Value) -> Option<String> {
    let keys = [
        "updateTime",
        "update_time",
        "lastUpdate",
        "last_update",
        "uploadTime",
        "upload_time",
    ];
    for key in keys {
        if let Some(value) = raw.get(key).and_then(Value::as_str) {
            if let Some(date) = normalize_update_date(value) {
                return Some(date);
            }
        }
    }
    let accepted = ["更新", "最後更新", "最后更新", "update", "last update"];
    if let Some(tags) = raw.get("tags").and_then(Value::as_object) {
        for (key, value) in tags {
            if !accepted.iter().any(|name| key.eq_ignore_ascii_case(name)) {
                continue;
            }
            if let Some(date) = value
                .as_array()
                .and_then(|items| items.first())
                .and_then(Value::as_str)
                .and_then(normalize_update_date)
            {
                return Some(date);
            }
            if let Some(date) = value.as_str().and_then(normalize_update_date) {
                return Some(date);
            }
        }
    }
    None
}

fn normalize_update_date(value: &str) -> Option<String> {
    let date = value.split([' ', 'T']).next()?.trim();
    let mut parts = date.split('-');
    let year = parts.next()?.parse::<u32>().ok()?;
    let month = parts.next()?.parse::<u32>().ok()?;
    let day = parts.next()?.parse::<u32>().ok()?;
    if parts.next().is_some()
        || !(2000..=3000).contains(&year)
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
    {
        return None;
    }
    Some(format!("{year}-{month}-{day}"))
}

fn chapter_update_marker(info: &RuntimeComicInfo) -> Option<String> {
    if info.episodes.is_empty() {
        return None;
    }
    let mut hasher = Sha256::new();
    for episode in &info.episodes {
        hasher.update(episode.id.as_bytes());
        hasher.update([0]);
        hasher.update(episode.title.as_bytes());
        hasher.update([0]);
    }
    let digest = format!("{:x}", hasher.finalize());
    Some(format!(
        "__chapters__{}_{}",
        info.episodes.len(),
        &digest[..8]
    ))
}

fn follow_markers_equivalent(current: Option<&str>, next: &str) -> bool {
    if current == Some(next) {
        return true;
    }
    match current.and_then(chapter_marker_count) {
        Some(current_count) => chapter_marker_count(next) == Some(current_count),
        None => false,
    }
}

fn chapter_marker_count(marker: &str) -> Option<usize> {
    marker
        .strip_prefix("__chapters__")?
        .split('_')
        .next()?
        .parse()
        .ok()
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

fn follow_task_payload(
    folder: &str,
    total: u64,
    checked: u64,
    updated: u64,
    failed: u64,
    current_title: Option<String>,
    dry_run: bool,
) -> Value {
    json!({
        "folder": folder,
        "total": total,
        "checked": checked,
        "updated": updated,
        "failed": failed,
        "currentTitle": current_title,
        "dryRun": dry_run
    })
}

fn insert_task(state: &AppState, id: &str, kind: &str, payload: &Value) -> ApiResult<()> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database.execute(
        r#"
        INSERT INTO tasks (id, kind, status, progress, payload, created_at, updated_at)
        VALUES (?1, ?2, 'running', 0, ?3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        "#,
        params![id, kind, payload.to_string()],
    )?;
    Ok(())
}

fn update_task(
    state: &AppState,
    id: &str,
    status: &str,
    progress: u32,
    payload: &Value,
    error: Option<String>,
) -> ApiResult<()> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database.execute(
        r#"
        UPDATE tasks
        SET status = ?1, progress = ?2, payload = ?3, error = ?4, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?5
        "#,
        params![status, progress, payload.to_string(), error, id],
    )?;
    Ok(())
}

fn running_follow_update_task(state: &AppState, folder: &str) -> ApiResult<Option<TaskSummary>> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let mut statement = database.prepare(
        r#"
        SELECT id, kind, status, progress, payload, error, created_at, updated_at
        FROM tasks
        WHERE kind = 'follow_updates' AND status = 'running'
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = statement.query_map([], task_from_row)?;
    for row in rows {
        let task = row?;
        if task.payload.get("folder").and_then(Value::as_str) == Some(folder) {
            return Ok(Some(task));
        }
    }
    Ok(None)
}

fn read_task(state: &AppState, id: &str) -> ApiResult<TaskSummary> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    database
        .query_row(
            r#"
            SELECT id, kind, status, progress, payload, error, created_at, updated_at
            FROM tasks
            WHERE id = ?1
            "#,
            [id],
            task_from_row,
        )
        .map_err(ApiError::Database)
}

fn task_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskSummary> {
    let payload_text: String = row.get(4)?;
    let payload = serde_json::from_str::<Value>(&payload_text).unwrap_or(Value::Null);
    Ok(TaskSummary {
        id: row.get(0)?,
        kind: row.get(1)?,
        status: row.get(2)?,
        progress: row.get::<_, i64>(3)?.clamp(0, 100) as u32,
        payload,
        error: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
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
    let auto_sync = read_bool_setting(state, "webdavAutoSync", false)?;
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
            auto_sync,
            password_configured: password.is_some_and(|value| !value.is_empty()),
            read_only: false,
            updated_at,
        });
    }

    Ok(WebDavConfigResponse {
        endpoint_url: None,
        username: None,
        root_path: "/".to_string(),
        auto_sync,
        password_configured: false,
        read_only: false,
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

fn read_bool_setting(state: &AppState, key: &str, default: bool) -> ApiResult<bool> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let value = database
        .query_row("SELECT value FROM settings WHERE key = ?1", [key], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(value
        .as_deref()
        .and_then(parse_setting_bool)
        .unwrap_or(default))
}

fn read_data_version(state: &AppState) -> ApiResult<i64> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
    let value = database
        .query_row(
            "SELECT value FROM settings WHERE key = 'dataVersion'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(value
        .as_deref()
        .and_then(parse_setting_i64)
        .unwrap_or(0))
}

fn write_data_version(state: &AppState, value: i64) -> ApiResult<()> {
    write_setting_value(state, "dataVersion", json!(value))
}

fn write_setting_value(state: &AppState, key: &str, value: Value) -> ApiResult<()> {
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
        params![key, value.to_string()],
    )?;
    Ok(())
}

fn parse_setting_bool(value: &str) -> Option<bool> {
    serde_json::from_str::<Value>(value)
        .ok()
        .and_then(|value| {
            value
                .as_bool()
                .or_else(|| value.as_str().and_then(|text| text.parse::<bool>().ok()))
        })
        .or_else(|| value.parse::<bool>().ok())
}

fn parse_setting_i64(value: &str) -> Option<i64> {
    serde_json::from_str::<Value>(value)
        .ok()
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))
        })
        .or_else(|| value.parse::<i64>().ok())
}

fn data_version_from_file_name(file_name: &str) -> Option<i64> {
    file_name
        .split('-')
        .nth(1)?
        .split('.')
        .next()?
        .parse::<i64>()
        .ok()
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

fn source_file_name_any(state: &AppState, key: &str) -> ApiResult<String> {
    let database = state
        .database
        .lock()
        .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;

    database
        .query_row(
            "SELECT file_name FROM comic_sources WHERE source_key = ?1",
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
