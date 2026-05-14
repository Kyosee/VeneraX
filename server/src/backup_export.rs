use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File},
    io::Write,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::{params, Connection};
use serde_json::json;
use tokio::task;
use zip::{write::FileOptions, CompressionMethod, ZipWriter};

use crate::{
    error::{ApiError, ApiResult},
    models::WebDavUploadResponse,
    state::AppState,
};

#[derive(Clone)]
struct ExportSource {
    key: String,
    file_name: String,
    type_value: i64,
}

#[derive(Clone)]
struct ExportFavorite {
    folder_name: String,
    source_key: String,
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    tags: Option<String>,
    timestamp_ms: i64,
    last_update_time: Option<String>,
    has_new_update: bool,
    last_check_time: Option<i64>,
}

#[derive(Clone)]
struct ExportHistory {
    source_key: String,
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    episode_index: Option<i64>,
    page: Option<i64>,
    max_page: Option<i64>,
    timestamp_ms: i64,
}

#[derive(Clone)]
struct ExportFolder {
    name: String,
    sort_order: i64,
}

#[derive(Clone)]
struct ExportSnapshot {
    data_version: i64,
    sources: Vec<ExportSource>,
    folders: Vec<ExportFolder>,
    favorites: Vec<ExportFavorite>,
    all_favorites: Vec<ExportFavorite>,
    history: Vec<ExportHistory>,
}

pub async fn export_backup(state: &AppState) -> ApiResult<WebDavUploadResponse> {
    let snapshot = {
        let database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        ExportSnapshot::load(&database)?
    };
    let config = state.config.clone();

    tokio::fs::create_dir_all(config.imports_dir().join("webdav")).await?;
    task::spawn_blocking(move || {
        write_backup(
            &config.data_dir,
            &config.imports_dir(),
            &config.tmp_dir(),
            snapshot,
        )
    })
    .await
    .map_err(|err| ApiError::State(format!("export task failed: {err}")))?
}

impl ExportSnapshot {
    fn load(database: &Connection) -> rusqlite::Result<Self> {
        let sources = read_sources(database)?;
        let type_map = build_type_map(&sources);
        let data_version = read_data_version(database) + 1;
        let folders = read_folders(database)?;
        let all_favorites = read_all_favorites(database, &type_map)?;
        let favorites = read_folder_favorites(database, &type_map)?;
        let history = read_history(database, &type_map)?;

        Ok(Self {
            data_version,
            sources,
            folders,
            favorites,
            all_favorites,
            history,
        })
    }
}

fn read_sources(database: &Connection) -> rusqlite::Result<Vec<ExportSource>> {
    let mut statement =
        database.prepare("SELECT source_key, file_name FROM comic_sources ORDER BY source_key")?;
    let mut rows = statement
        .query_map([], |row| {
            Ok(ExportSource {
                key: row.get(0)?,
                file_name: row.get(1)?,
                type_value: 0,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    for (index, source) in rows.iter_mut().enumerate() {
        source.type_value = legacy_type_value(&source.key).unwrap_or(900_000 + index as i64);
    }
    Ok(rows)
}

fn read_data_version(database: &Connection) -> i64 {
    database
        .query_row(
            "SELECT value FROM settings WHERE key = 'dataVersion'",
            [],
            |row| row.get::<_, String>(0),
        )
        .ok()
        .and_then(|value| parse_setting_i64(&value))
        .unwrap_or(0)
}

fn parse_setting_i64(value: &str) -> Option<i64> {
    serde_json::from_str::<serde_json::Value>(value)
        .ok()
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))
        })
        .or_else(|| value.parse::<i64>().ok())
}

fn read_folders(database: &Connection) -> rusqlite::Result<Vec<ExportFolder>> {
    let mut statement = database
        .prepare("SELECT folder_name, sort_order FROM favorite_folders ORDER BY sort_order")?;
    let rows = statement.query_map([], |row| {
        Ok(ExportFolder {
            name: row.get(0)?,
            sort_order: row.get(1)?,
        })
    })?;
    rows.collect()
}

fn read_all_favorites(
    database: &Connection,
    type_map: &HashMap<String, i64>,
) -> rusqlite::Result<Vec<ExportFavorite>> {
    let fallback_time = current_unix_millis();
    let mut statement = database.prepare(
        r#"
        SELECT source_key, comic_id, title, subtitle, cover, tags,
               COALESCE(CAST(strftime('%s', created_at) AS INTEGER) * 1000, ?1)
        FROM favorites
        ORDER BY created_at DESC
        "#,
    )?;
    let rows = statement.query_map([fallback_time], |row| {
        let source_key: String = row.get(0)?;
        Ok(ExportFavorite {
            folder_name: "default".to_string(),
            source_key: source_key.clone(),
            comic_id: row.get(1)?,
            title: row.get(2)?,
            subtitle: row.get(3)?,
            cover: row.get(4)?,
            tags: row.get(5)?,
            timestamp_ms: row.get(6)?,
            last_update_time: None,
            has_new_update: false,
            last_check_time: None,
        })
    })?;
    rows.filter_map(|row| match row {
        Ok(item) if type_map.contains_key(&item.source_key) => Some(Ok(item)),
        Ok(_) => None,
        Err(err) => Some(Err(err)),
    })
    .collect()
}

fn read_folder_favorites(
    database: &Connection,
    type_map: &HashMap<String, i64>,
) -> rusqlite::Result<Vec<ExportFavorite>> {
    let fallback_time = current_unix_millis();
    let mut statement = database.prepare(
        r#"
        SELECT ffi.folder_name, ffi.source_key, ffi.comic_id, f.title, f.subtitle, f.cover, f.tags,
               COALESCE(CAST(strftime('%s', ffi.created_at) AS INTEGER) * 1000, ?1),
               ffi.last_update_time, ffi.has_new_update, ffi.last_check_time
        FROM favorite_folder_items ffi
        JOIN favorites f ON f.source_key = ffi.source_key AND f.comic_id = ffi.comic_id
        ORDER BY ffi.folder_name, ffi.created_at DESC
        "#,
    )?;
    let rows = statement.query_map([fallback_time], |row| {
        let source_key: String = row.get(1)?;
        Ok(ExportFavorite {
            folder_name: row.get(0)?,
            source_key: source_key.clone(),
            comic_id: row.get(2)?,
            title: row.get(3)?,
            subtitle: row.get(4)?,
            cover: row.get(5)?,
            tags: row.get(6)?,
            timestamp_ms: row.get(7)?,
            last_update_time: row.get(8)?,
            has_new_update: row.get::<_, i64>(9)? != 0,
            last_check_time: row.get(10)?,
        })
    })?;
    rows.filter_map(|row| match row {
        Ok(item) if type_map.contains_key(&item.source_key) => Some(Ok(item)),
        Ok(_) => None,
        Err(err) => Some(Err(err)),
    })
    .collect()
}

fn read_history(
    database: &Connection,
    type_map: &HashMap<String, i64>,
) -> rusqlite::Result<Vec<ExportHistory>> {
    let fallback_time = current_unix_millis();
    let mut statement = database.prepare(
        r#"
        SELECT source_key, comic_id, title, subtitle, cover, episode_id, page, max_page,
               COALESCE(CAST(strftime('%s', updated_at) AS INTEGER) * 1000, ?1)
        FROM reading_history
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = statement.query_map([fallback_time], |row| {
        let source_key: String = row.get(0)?;
        let episode_id: Option<String> = row.get(5)?;
        Ok(ExportHistory {
            source_key: source_key.clone(),
            comic_id: row.get(1)?,
            title: row.get(2)?,
            subtitle: row.get(3)?,
            cover: row.get(4)?,
            episode_index: episode_id.and_then(|value| value.parse::<i64>().ok()),
            page: row.get(6)?,
            max_page: row.get(7)?,
            timestamp_ms: row.get(8)?,
        })
    })?;
    rows.filter_map(|row| match row {
        Ok(item) if type_map.contains_key(&item.source_key) => Some(Ok(item)),
        Ok(_) => None,
        Err(err) => Some(Err(err)),
    })
    .collect()
}

fn write_backup(
    data_dir: &Path,
    imports_dir: &Path,
    tmp_dir: &Path,
    snapshot: ExportSnapshot,
) -> ApiResult<WebDavUploadResponse> {
    let backup_dir = imports_dir.join("webdav");
    fs::create_dir_all(&backup_dir)?;
    fs::create_dir_all(tmp_dir)?;

    let day = current_unix_millis() / 86_400_000;
    let mut file_name = format!("{day}-{}.venera", snapshot.data_version);
    let mut local_path = backup_dir.join(&file_name);
    if local_path.exists() {
        file_name = format!(
            "{day}-{}-{}.venera",
            snapshot.data_version,
            current_unix_millis()
        );
        local_path = backup_dir.join(&file_name);
    }

    let working_dir = tmp_dir.join(format!("webdav-export-{}", current_unix_millis()));
    fs::create_dir_all(&working_dir)?;

    let history_path = working_dir.join("history.db");
    let favorites_path = working_dir.join("local_favorite.db");
    create_history_db(&history_path, &snapshot)?;
    create_favorites_db(&favorites_path, &snapshot)?;

    let type_map = snapshot
        .sources
        .iter()
        .map(|source| (source.type_value.to_string(), source.key.clone()))
        .collect::<BTreeMap<_, _>>();
    let appdata = json!({
        "settings": { "dataVersion": snapshot.data_version },
        "searchHistory": []
    });
    let source_type_map = json!({ "types": type_map });

    let file = File::create(&local_path)?;
    let mut zip = ZipWriter::new(file);
    let options = FileOptions::default().compression_method(CompressionMethod::Deflated);
    add_bytes(
        &mut zip,
        "appdata.json",
        serde_json::to_vec(&appdata).map_err(|err| ApiError::State(err.to_string()))?,
        options,
    )?;
    add_bytes(
        &mut zip,
        "source_type_map.json",
        serde_json::to_vec(&source_type_map).map_err(|err| ApiError::State(err.to_string()))?,
        options,
    )?;
    add_file(&mut zip, "history.db", &history_path, options)?;
    add_file(&mut zip, "local_favorite.db", &favorites_path, options)?;
    add_source_files(&mut zip, &data_dir.join("sources"), &snapshot, options)?;
    zip.finish().map_err(zip_error)?;

    let size = fs::metadata(&local_path)?.len();
    let _ = fs::remove_dir_all(&working_dir);
    let local_path_text = local_path.display().to_string();
    Ok(WebDavUploadResponse {
        file_name: file_name.clone(),
        local_path: local_path_text.clone(),
        path: format!("webdav/{file_name}"),
        remote_path: file_name,
        size,
        uploaded: false,
        content_type: None,
    })
}

fn create_history_db(path: &Path, snapshot: &ExportSnapshot) -> ApiResult<()> {
    let connection = Connection::open(path)?;
    connection.execute_batch(
        r#"
        CREATE TABLE history (
            id TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT,
            cover TEXT,
            time INTEGER,
            type INTEGER NOT NULL,
            ep INTEGER,
            page INTEGER NOT NULL DEFAULT 0,
            readEpisode TEXT NOT NULL DEFAULT '',
            max_page INTEGER,
            chapter_group INTEGER
        );
        "#,
    )?;
    let type_map = build_type_map(&snapshot.sources);
    for item in &snapshot.history {
        let Some(type_value) = type_map.get(&item.source_key) else {
            continue;
        };
        connection.execute(
            "INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, '', ?9, NULL)",
            params![
                &item.comic_id,
                &item.title,
                &item.subtitle,
                &item.cover,
                item.timestamp_ms,
                type_value,
                item.episode_index.unwrap_or(0),
                item.page.unwrap_or(0),
                item.max_page
            ],
        )?;
    }
    Ok(())
}

fn create_favorites_db(path: &Path, snapshot: &ExportSnapshot) -> ApiResult<()> {
    let connection = Connection::open(path)?;
    connection.execute(
        "CREATE TABLE folder_order (folder_name TEXT PRIMARY KEY, order_value INTEGER NOT NULL)",
        [],
    )?;

    let mut folders = snapshot.folders.clone();
    if folders.is_empty() && !snapshot.all_favorites.is_empty() {
        folders.push(ExportFolder {
            name: "default".to_string(),
            sort_order: 0,
        });
    }
    for folder in &folders {
        connection.execute(
            "INSERT OR REPLACE INTO folder_order (folder_name, order_value) VALUES (?1, ?2)",
            params![&folder.name, folder.sort_order],
        )?;
    }

    let mut rows_by_folder: BTreeMap<String, Vec<&ExportFavorite>> = BTreeMap::new();
    for item in &snapshot.favorites {
        rows_by_folder
            .entry(non_empty_folder(&item.folder_name))
            .or_default()
            .push(item);
    }
    if rows_by_folder.is_empty() {
        for item in &snapshot.all_favorites {
            rows_by_folder
                .entry("default".to_string())
                .or_default()
                .push(item);
        }
    }

    let type_map = build_type_map(&snapshot.sources);
    for (folder_name, items) in rows_by_folder {
        let table = quote_identifier(&folder_name);
        connection.execute_batch(&format!(
            r#"
            CREATE TABLE {table} (
                id TEXT NOT NULL,
                name TEXT,
                author TEXT,
                tags TEXT,
                cover_path TEXT,
                time TEXT,
                type INTEGER NOT NULL,
                last_update_time TEXT,
                has_new_update INTEGER NOT NULL DEFAULT 0,
                last_check_time INTEGER
            );
            "#
        ))?;
        for item in items {
            let Some(type_value) = type_map.get(&item.source_key) else {
                continue;
            };
            connection.execute(
                &format!(
                    "INSERT INTO {table} (id, name, author, tags, cover_path, time, type, last_update_time, has_new_update, last_check_time) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"
                ),
                params![
                    &item.comic_id,
                    &item.title,
                    &item.subtitle,
                    &item.tags,
                    &item.cover,
                    item.timestamp_ms.to_string(),
                    type_value,
                    &item.last_update_time,
                    if item.has_new_update { 1 } else { 0 },
                    item.last_check_time
                ],
            )?;
        }
    }
    Ok(())
}

fn add_source_files(
    zip: &mut ZipWriter<File>,
    sources_dir: &Path,
    snapshot: &ExportSnapshot,
    options: FileOptions,
) -> ApiResult<()> {
    if !sources_dir.exists() {
        return Ok(());
    }
    let allowed = snapshot
        .sources
        .iter()
        .map(|source| source.file_name.clone())
        .collect::<HashSet<_>>();
    let mut files = fs::read_dir(sources_dir)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();
    files.sort();
    for path in files {
        let Some(name) = path
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
        else {
            continue;
        };
        let is_source = allowed.contains(&name);
        let is_data = name.ends_with(".data");
        if is_source || is_data {
            add_file(zip, &format!("comic_source/{name}"), &path, options)?;
        }
    }
    Ok(())
}

fn add_file(
    zip: &mut ZipWriter<File>,
    name: &str,
    path: &Path,
    options: FileOptions,
) -> ApiResult<()> {
    let bytes = fs::read(path)?;
    add_bytes(zip, name, bytes, options)
}

fn add_bytes(
    zip: &mut ZipWriter<File>,
    name: &str,
    bytes: Vec<u8>,
    options: FileOptions,
) -> ApiResult<()> {
    zip.start_file(name, options).map_err(zip_error)?;
    zip.write_all(&bytes)?;
    Ok(())
}

fn build_type_map(sources: &[ExportSource]) -> HashMap<String, i64> {
    sources
        .iter()
        .map(|source| (source.key.clone(), source.type_value))
        .collect()
}

fn non_empty_folder(value: &str) -> String {
    let value = value.trim();
    if value.is_empty() {
        "default".to_string()
    } else {
        value.to_string()
    }
}

fn quote_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn current_unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn legacy_type_value(source_key: &str) -> Option<i64> {
    common_legacy_type_map()
        .iter()
        .find_map(|(value, key)| (*key == source_key).then_some(*value))
}

fn common_legacy_type_map() -> &'static [(i64, &'static str)] {
    &[
        (637999886, "Komiic"),
        (981441865, "ManHuaGui"),
        (233488852, "baozi"),
        (807338462, "ccc"),
        (964788560, "comick"),
        (557997769, "copy_manga"),
        (385625716, "ehentai"),
        (550146035, "goda"),
        (977805693, "happy"),
        (236897507, "hcomic"),
        (258019538, "hitomi"),
        (29663848, "hot_manga"),
        (716010982, "ikmmh"),
        (740690276, "jcomic"),
        (769844263, "jm"),
        (577718694, "manga_dex"),
        (607393360, "manhuagui"),
        (631413104, "manhuaren"),
        (42816288, "manwaba"),
        (577341847, "mh1234"),
        (778108598, "mh18"),
        (771282371, "mxs"),
        (264196719, "nhentai"),
        (553570794, "picacg"),
        (331263271, "shonen_jump_plus"),
        (823512256, "wnacg"),
        (798816513, "ykmh"),
        (150465061, "zaimanhua"),
    ]
}

fn zip_error(err: zip::result::ZipError) -> ApiError {
    ApiError::State(format!("backup zip failed: {err}"))
}
