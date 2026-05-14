use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use regex::Regex;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use sha2::{Digest, Sha256};
use tokio::{fs as async_fs, task};
use zip::{result::ZipError, ZipArchive};

use crate::{
    config::AppConfig,
    error::{ApiError, ApiResult},
    models::{
        ImportBackupApplyResponse, ImportBackupDatabasePreview, ImportBackupPreviewResponse,
        ImportBackupSummary, ImportBackupTablePreview, ImportBackupsResponse,
    },
    state::AppState,
};

#[derive(Clone)]
struct ImportedSource {
    key: String,
    name: String,
    version: String,
    file_name: String,
    bytes: Vec<u8>,
}

#[derive(Clone)]
struct ImportedSourceDataFile {
    file_name: String,
    bytes: Vec<u8>,
}

#[derive(Clone)]
struct ImportedLibraryItem {
    source_key: String,
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    episode_id: Option<String>,
    episode_title: Option<String>,
    timestamp_ms: Option<i64>,
}

struct ImportedFavoriteFolder {
    name: String,
    title: String,
    sort_order: i64,
}

struct ImportedFavoriteFolderItem {
    folder_name: String,
    source_key: String,
    comic_id: String,
    timestamp_ms: Option<i64>,
    last_update_time: Option<String>,
    has_new_update: bool,
    last_check_time: Option<i64>,
}

struct ImportPlan {
    file_name: String,
    path: String,
    sources: Vec<ImportedSource>,
    source_data_files: Vec<ImportedSourceDataFile>,
    favorites: Vec<ImportedLibraryItem>,
    favorite_folders: Vec<ImportedFavoriteFolder>,
    favorite_folder_items: Vec<ImportedFavoriteFolderItem>,
    history: Vec<ImportedLibraryItem>,
    favorites_skipped: usize,
    history_skipped: usize,
}

pub async fn list_backups(config: &AppConfig) -> ApiResult<ImportBackupsResponse> {
    let backup_dir = config.imports_dir().join("webdav");
    let mut reader = match async_fs::read_dir(&backup_dir).await {
        Ok(reader) => reader,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ImportBackupsResponse {
                backups: Vec::new(),
            });
        }
        Err(err) => return Err(err.into()),
    };

    let mut backups = Vec::new();
    while let Some(entry) = reader.next_entry().await? {
        let metadata = entry.metadata().await?;
        if !metadata.is_file() {
            continue;
        }

        let file_name = entry.file_name().to_string_lossy().to_string();
        if !file_name.ends_with(".venera") {
            continue;
        }

        backups.push(ImportBackupSummary {
            path: format!("webdav/{file_name}"),
            file_name,
            size: metadata.len(),
            modified: metadata.modified().ok().and_then(system_time_seconds),
        });
    }

    backups.sort_by(|left, right| {
        right
            .modified
            .cmp(&left.modified)
            .then_with(|| left.file_name.cmp(&right.file_name))
    });

    Ok(ImportBackupsResponse { backups })
}

pub async fn preview_backup(
    config: &AppConfig,
    requested_path: &str,
) -> ApiResult<ImportBackupPreviewResponse> {
    let (relative_path, backup_path) = resolve_backup_path(config, requested_path)?;
    let metadata = async_fs::metadata(&backup_path).await?;
    if !metadata.is_file() {
        return Err(ApiError::BadRequest(
            "backup path is not a file".to_string(),
        ));
    }

    let tmp_dir = config.tmp_dir().join("backup-preview");
    let size = metadata.len();
    task::spawn_blocking(move || inspect_backup(&backup_path, &tmp_dir, relative_path, size))
        .await
        .map_err(|err| ApiError::State(format!("import preview task failed: {err}")))?
}

pub async fn apply_backup(
    state: &AppState,
    requested_path: &str,
) -> ApiResult<ImportBackupApplyResponse> {
    let (relative_path, backup_path) = resolve_backup_path(&state.config, requested_path)?;
    let metadata = async_fs::metadata(&backup_path).await?;
    if !metadata.is_file() {
        return Err(ApiError::BadRequest(
            "backup path is not a file".to_string(),
        ));
    }

    tracing::info!(
        backup_path = %backup_path.display(),
        size_bytes = metadata.len(),
        "apply_backup: start"
    );

    let tmp_dir = state.config.tmp_dir().join("backup-import");
    let plan =
        task::spawn_blocking(move || build_import_plan(&backup_path, &tmp_dir, relative_path))
            .await
            .map_err(|err| ApiError::State(format!("import task failed: {err}")))??;

    tracing::info!(
        sources = plan.sources.len(),
        source_data_files = plan.source_data_files.len(),
        favorites = plan.favorites.len(),
        favorites_skipped = plan.favorites_skipped,
        favorite_folders = plan.favorite_folders.len(),
        favorite_folder_items = plan.favorite_folder_items.len(),
        history = plan.history.len(),
        history_skipped = plan.history_skipped,
        "apply_backup: plan built from zip"
    );

    async_fs::create_dir_all(state.config.sources_dir()).await?;
    for source in &plan.sources {
        async_fs::write(
            state.config.sources_dir().join(&source.file_name),
            &source.bytes,
        )
        .await?;
    }
    for data_file in &plan.source_data_files {
        async_fs::write(
            state.config.sources_dir().join(&data_file.file_name),
            &data_file.bytes,
        )
        .await?;
    }

    {
        let mut database = state
            .database
            .lock()
            .map_err(|_| ApiError::State("database lock poisoned".to_string()))?;
        let transaction = database.transaction()?;

        for source in &plan.sources {
            transaction.execute(
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
                params![&source.key, &source.name, &source.version, &source.file_name],
            )?;
        }

        for favorite in &plan.favorites {
            transaction.execute(
                r#"
                INSERT INTO favorites (source_key, comic_id, title, subtitle, cover, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(datetime(?6 / 1000, 'unixepoch'), CURRENT_TIMESTAMP))
                ON CONFLICT(source_key, comic_id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    cover = excluded.cover
                "#,
                params![
                    &favorite.source_key,
                    &favorite.comic_id,
                    &favorite.title,
                    &favorite.subtitle,
                    &favorite.cover,
                    favorite.timestamp_ms,
                ],
            )?;
        }

        transaction.execute("DELETE FROM favorite_folder_items", [])?;
        transaction.execute("DELETE FROM favorite_folders", [])?;

        for folder in &plan.favorite_folders {
            transaction.execute(
                r#"
                INSERT INTO favorite_folders (folder_name, title, sort_order, updated_at)
                VALUES (?1, ?2, ?3, CURRENT_TIMESTAMP)
                ON CONFLICT(folder_name) DO UPDATE SET
                    title = excluded.title,
                    sort_order = excluded.sort_order,
                    updated_at = CURRENT_TIMESTAMP
                "#,
                params![&folder.name, &folder.title, folder.sort_order],
            )?;
        }

        for item in &plan.favorite_folder_items {
            transaction.execute(
                r#"
                INSERT INTO favorite_folder_items (
                    folder_name, source_key, comic_id, created_at,
                    last_update_time, has_new_update, last_check_time
                )
                VALUES (
                    ?1, ?2, ?3, COALESCE(datetime(?4 / 1000, 'unixepoch'), CURRENT_TIMESTAMP),
                    ?5, ?6, ?7
                )
                ON CONFLICT(folder_name, source_key, comic_id) DO UPDATE SET
                    created_at = excluded.created_at,
                    last_update_time = excluded.last_update_time,
                    has_new_update = excluded.has_new_update,
                    last_check_time = excluded.last_check_time
                "#,
                params![
                    &item.folder_name,
                    &item.source_key,
                    &item.comic_id,
                    item.timestamp_ms,
                    &item.last_update_time,
                    item.has_new_update,
                    item.last_check_time,
                ],
            )?;
        }

        for history in &plan.history {
            transaction.execute(
                r#"
                INSERT INTO reading_history (
                    source_key, comic_id, title, subtitle, cover, episode_id, episode_title, updated_at
                )
                VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7,
                    COALESCE(datetime(?8 / 1000, 'unixepoch'), CURRENT_TIMESTAMP)
                )
                ON CONFLICT(source_key, comic_id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    cover = excluded.cover,
                    episode_id = excluded.episode_id,
                    episode_title = excluded.episode_title,
                    updated_at = excluded.updated_at
                "#,
                params![
                    &history.source_key,
                    &history.comic_id,
                    &history.title,
                    &history.subtitle,
                    &history.cover,
                    &history.episode_id,
                    &history.episode_title,
                    history.timestamp_ms,
                ],
            )?;
        }

        transaction.commit()?;
    }

    Ok(ImportBackupApplyResponse {
        file_name: plan.file_name,
        path: plan.path,
        sources_imported: plan.sources.len(),
        source_data_files_imported: plan.source_data_files.len(),
        favorites_imported: plan.favorites.len(),
        history_imported: plan.history.len(),
        favorites_skipped: plan.favorites_skipped,
        history_skipped: plan.history_skipped,
    })
}

fn inspect_backup(
    backup_path: &Path,
    tmp_dir: &Path,
    relative_path: String,
    size: u64,
) -> ApiResult<ImportBackupPreviewResponse> {
    fs::create_dir_all(tmp_dir)?;

    let file = File::open(backup_path)?;
    let mut archive = ZipArchive::new(file).map_err(zip_error)?;
    let mut appdata_keys = Vec::new();
    let mut comic_source_js_count = 0;
    let mut comic_source_data_count = 0;
    let mut comic_source_samples = Vec::new();

    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(zip_error)?;
        let name = normalize_zip_name(entry.name());
        if name.starts_with("comic_source/") && name.ends_with(".js") {
            comic_source_js_count += 1;
            if comic_source_samples.len() < 8 {
                comic_source_samples.push(name.trim_start_matches("comic_source/").to_string());
            }
        } else if name.starts_with("comic_source/") && name.ends_with(".data") {
            comic_source_data_count += 1;
        }
    }

    if let Ok(mut appdata) = archive.by_name("appdata.json") {
        let mut text = String::new();
        if appdata.read_to_string(&mut text).is_ok() {
            if let Ok(serde_json::Value::Object(object)) =
                serde_json::from_str::<serde_json::Value>(&text)
            {
                appdata_keys = object.keys().cloned().collect();
                appdata_keys.sort();
            }
        }
    }

    let databases = [
        "history.db",
        "local_favorite.db",
        "data/venera.db",
        "cookie.db",
    ]
    .into_iter()
    .map(|name| inspect_database(&mut archive, tmp_dir, name))
    .collect();

    let file_name = backup_path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "backup.venera".to_string());

    Ok(ImportBackupPreviewResponse {
        file_name,
        path: relative_path,
        size,
        entry_count: archive.len(),
        appdata_keys,
        comic_source_js_count,
        comic_source_data_count,
        comic_source_samples,
        databases,
    })
}

fn build_import_plan(
    backup_path: &Path,
    tmp_dir: &Path,
    relative_path: String,
) -> ApiResult<ImportPlan> {
    fs::create_dir_all(tmp_dir)?;

    let file = File::open(backup_path)?;
    let mut archive = ZipArchive::new(file).map_err(zip_error)?;
    let file_name = backup_path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "backup.venera".to_string());
    let sources = read_source_files(&mut archive)?;
    let source_data_files = read_source_data_files(&mut archive)?;
    let explicit_type_map = read_source_type_map(&mut archive)?;
    let domain_path = extract_database_entry(&mut archive, tmp_dir, "data/venera.db")?;
    let favorite_path = extract_database_entry(&mut archive, tmp_dir, "local_favorite.db")?;
    let history_path = extract_database_entry(&mut archive, tmp_dir, "history.db")?;

    let domain = match domain_path.as_deref() {
        Some(path) => DomainIndex::load(path).unwrap_or_default(),
        None => DomainIndex::default(),
    };
    let source_keys = sources
        .iter()
        .map(|source| source.key.clone())
        .collect::<HashSet<_>>();
    let mut type_map = infer_type_map(
        &domain,
        favorite_path.as_deref(),
        history_path.as_deref(),
        &source_keys,
    );
    for (type_value, source_key) in explicit_type_map {
        if source_keys.contains(&source_key) {
            type_map.insert(type_value, source_key);
        }
    }
    let (favorites, favorite_folders, favorite_folder_items, favorites_skipped) =
        import_favorites(&domain, &type_map, favorite_path.as_deref())?;
    let (history, history_skipped) = import_history(&domain, &type_map, history_path.as_deref())?;

    for path in [domain_path, favorite_path, history_path]
        .into_iter()
        .flatten()
    {
        let _ = fs::remove_file(path);
    }

    Ok(ImportPlan {
        file_name,
        path: relative_path,
        sources,
        source_data_files,
        favorites,
        favorite_folders,
        favorite_folder_items,
        history,
        favorites_skipped,
        history_skipped,
    })
}

#[derive(Clone, Default)]
struct DomainIndex {
    by_source_id: HashMap<String, Vec<ComicRecord>>,
    by_pair: HashMap<(String, String), ComicRecord>,
}

#[derive(Clone)]
struct ComicRecord {
    source_key: String,
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    timestamp_ms: Option<i64>,
}

impl DomainIndex {
    fn load(path: &Path) -> rusqlite::Result<Self> {
        let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let mut statement = connection.prepare(
            r#"
            SELECT
                sp.canonical_key,
                cs.source_comic_id,
                c.title,
                c.subtitle,
                c.cover_uri,
                COALESCE(c.updated_at, c.created_at)
            FROM comic_sources cs
            JOIN source_platforms sp ON sp.platform_id = cs.platform_id
            JOIN comics c ON c.comic_id = cs.comic_id
            WHERE sp.canonical_key IS NOT NULL AND sp.canonical_key != 'local'
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok(ComicRecord {
                source_key: row.get(0)?,
                comic_id: row.get(1)?,
                title: row.get(2)?,
                subtitle: row.get(3)?,
                cover: row.get(4)?,
                timestamp_ms: row.get(5)?,
            })
        })?;

        let mut index = DomainIndex::default();
        for row in rows {
            let record = row?;
            index
                .by_source_id
                .entry(record.comic_id.clone())
                .or_default()
                .push(record.clone());
            index
                .by_pair
                .insert((record.source_key.clone(), record.comic_id.clone()), record);
        }

        Ok(index)
    }

    fn unique_source_key(&self, comic_id: &str) -> Option<String> {
        let records = self.by_source_id.get(comic_id)?;
        (records.len() == 1).then(|| records[0].source_key.clone())
    }

    fn record(&self, source_key: &str, comic_id: &str) -> Option<&ComicRecord> {
        self.by_pair
            .get(&(source_key.to_string(), comic_id.to_string()))
    }
}

fn read_source_files(archive: &mut ZipArchive<File>) -> ApiResult<Vec<ImportedSource>> {
    let mut selected: BTreeMap<String, (u8, ImportedSource)> = BTreeMap::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(zip_error)?;
        let entry_name = normalize_zip_name(entry.name());
        if !entry_name.starts_with("comic_source/") || !entry_name.ends_with(".js") {
            continue;
        }

        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        let Ok(content) = String::from_utf8(bytes.clone()) else {
            continue;
        };
        let Some(metadata) = parse_source_metadata(&content) else {
            continue;
        };
        let file_name = format!("{}.js", metadata.key);
        let original_name = entry_name.trim_start_matches("comic_source/");
        let score = if original_name == file_name { 2 } else { 1 };
        let imported = ImportedSource {
            key: metadata.key.clone(),
            name: metadata.name,
            version: metadata.version,
            file_name,
            bytes,
        };

        let replace = selected
            .get(&metadata.key)
            .map(|(current_score, _)| score >= *current_score)
            .unwrap_or(true);
        if replace {
            selected.insert(metadata.key, (score, imported));
        }
    }

    Ok(selected.into_values().map(|(_, source)| source).collect())
}

fn read_source_data_files(
    archive: &mut ZipArchive<File>,
) -> ApiResult<Vec<ImportedSourceDataFile>> {
    let mut files = Vec::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(zip_error)?;
        let entry_name = normalize_zip_name(entry.name());
        if !entry_name.starts_with("comic_source/") || !entry_name.ends_with(".data") {
            continue;
        }

        let file_name = entry_name.trim_start_matches("comic_source/").to_string();
        if !is_valid_import_file_name(&file_name) {
            continue;
        }

        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        files.push(ImportedSourceDataFile { file_name, bytes });
    }

    Ok(files)
}

fn read_source_type_map(archive: &mut ZipArchive<File>) -> ApiResult<HashMap<i64, String>> {
    let mut entry = match archive.by_name("source_type_map.json") {
        Ok(entry) => entry,
        Err(ZipError::FileNotFound) => return Ok(HashMap::new()),
        Err(err) => return Err(zip_error(err)),
    };
    let mut text = String::new();
    entry.read_to_string(&mut text)?;
    let value: serde_json::Value = serde_json::from_str(&text)
        .map_err(|err| ApiError::ImportPreview(format!("invalid source_type_map.json: {err}")))?;
    let Some(types) = value.get("types").and_then(|item| item.as_object()) else {
        return Ok(HashMap::new());
    };
    Ok(types
        .iter()
        .filter_map(|(key, value)| {
            let type_value = key.parse::<i64>().ok()?;
            let source_key = value.as_str()?.to_string();
            is_valid_source_key(&source_key).then_some((type_value, source_key))
        })
        .collect())
}

struct SourceMetadata {
    key: String,
    name: String,
    version: String,
}

fn parse_source_metadata(content: &str) -> Option<SourceMetadata> {
    let has_source_class = content.lines().any(|line| {
        line.trim_start().starts_with("class ") && line.contains("extends ComicSource")
    });
    if !has_source_class {
        return None;
    }

    let key = extract_js_string(content, "key")?;
    if !is_valid_source_key(&key) {
        return None;
    }
    Some(SourceMetadata {
        key,
        name: extract_js_string(content, "name")?,
        version: extract_js_string(content, "version")?,
    })
}

fn extract_database_entry(
    archive: &mut ZipArchive<File>,
    tmp_dir: &Path,
    entry_name: &str,
) -> ApiResult<Option<PathBuf>> {
    let mut entry = match archive.by_name(entry_name) {
        Ok(entry) => entry,
        Err(ZipError::FileNotFound) => return Ok(None),
        Err(err) => return Err(zip_error(err)),
    };

    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes)?;
    drop(entry);

    let temp_path = temp_database_path(tmp_dir, entry_name, &bytes);
    fs::write(&temp_path, bytes)?;
    Ok(Some(temp_path))
}

fn infer_type_map(
    domain: &DomainIndex,
    favorite_path: Option<&Path>,
    history_path: Option<&Path>,
    source_keys: &HashSet<String>,
) -> HashMap<i64, String> {
    let mut candidates: HashMap<i64, Option<String>> = HashMap::new();
    if let Some(path) = favorite_path {
        let _ = scan_favorite_rows(path, |row| {
            if let Some(source_key) = domain.unique_source_key(&row.comic_id) {
                register_type_candidate(&mut candidates, row.type_value, source_key);
            }
        });
    }
    if let Some(path) = history_path {
        let _ = scan_history_rows(path, |row| {
            if let Some(source_key) = domain.unique_source_key(&row.comic_id) {
                register_type_candidate(&mut candidates, row.type_value, source_key);
            }
        });
    }

    let mut result = candidates
        .into_iter()
        .filter_map(|(type_value, source_key)| source_key.map(|value| (type_value, value)))
        .collect::<HashMap<_, _>>();
    for (type_value, source_key) in common_legacy_type_map() {
        if source_keys.contains(*source_key) {
            result
                .entry(*type_value)
                .or_insert_with(|| (*source_key).to_string());
        }
    }
    result
}

fn register_type_candidate(
    candidates: &mut HashMap<i64, Option<String>>,
    type_value: i64,
    source_key: String,
) {
    match candidates.get_mut(&type_value) {
        Some(Some(existing)) if existing != &source_key => {
            candidates.insert(type_value, None);
        }
        Some(_) => {}
        None => {
            candidates.insert(type_value, Some(source_key));
        }
    }
}

fn common_legacy_type_map() -> &'static [(i64, &'static str)] {
    &[
        (637999886, "Komiic"),
        (981441865, "ManHuaGui"),
        (233488852, "baozi"),
        (807338462, "ccc"),
        (893043064, "comic_walker"),
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
        (875043938, "kavita"),
        (635587041, "komga"),
        (1059410886, "komiic"),
        (11995058, "lanraragi"),
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

fn import_favorites(
    domain: &DomainIndex,
    type_map: &HashMap<i64, String>,
    favorite_path: Option<&Path>,
) -> ApiResult<(
    Vec<ImportedLibraryItem>,
    Vec<ImportedFavoriteFolder>,
    Vec<ImportedFavoriteFolderItem>,
    usize,
)> {
    let Some(path) = favorite_path else {
        return Ok((Vec::new(), Vec::new(), Vec::new(), 0));
    };

    let folder_order = read_favorite_folder_order(path)?;
    let mut folders = BTreeMap::<String, ImportedFavoriteFolder>::new();
    let mut folder_items_seen = HashSet::new();
    let mut folder_items = Vec::new();
    let mut seen = HashSet::new();
    let mut imported = Vec::new();
    let mut skipped = 0;
    scan_favorite_rows(path, |row| {
        let next_sort_order = folders.len() as i64;
        let sort_order = folder_order
            .get(&row.folder_name)
            .copied()
            .unwrap_or(next_sort_order);
        folders
            .entry(row.folder_name.clone())
            .or_insert_with(|| ImportedFavoriteFolder {
                name: row.folder_name.clone(),
                title: row.folder_name.clone(),
                sort_order,
            });

        let Some(source_key) = resolve_source_key(domain, type_map, &row.comic_id, row.type_value)
        else {
            skipped += 1;
            return;
        };
        let timestamp_ms = parse_favorite_time(row.time.clone()).or_else(|| {
            domain
                .record(&source_key, &row.comic_id)
                .and_then(|value| value.timestamp_ms)
        });
        if folder_items_seen.insert((
            row.folder_name.clone(),
            source_key.clone(),
            row.comic_id.clone(),
        )) {
            folder_items.push(ImportedFavoriteFolderItem {
                folder_name: row.folder_name.clone(),
                source_key: source_key.clone(),
                comic_id: row.comic_id.clone(),
                timestamp_ms,
                last_update_time: row.last_update_time.clone(),
                has_new_update: row.has_new_update.unwrap_or(0) != 0,
                last_check_time: row.last_check_time,
            });
        }
        if !seen.insert((source_key.clone(), row.comic_id.clone())) {
            return;
        }

        let record = domain.record(&source_key, &row.comic_id);
        imported.push(ImportedLibraryItem {
            source_key,
            comic_id: row.comic_id,
            title: first_non_empty(row.title, record.map(|value| value.title.clone()))
                .unwrap_or_else(|| "Untitled".to_string()),
            subtitle: first_non_empty(row.author, record.and_then(|value| value.subtitle.clone())),
            cover: first_non_empty(row.cover, record.and_then(|value| value.cover.clone())),
            episode_id: None,
            episode_title: None,
            timestamp_ms,
        });
    })?;

    Ok((
        imported,
        folders.into_values().collect(),
        folder_items,
        skipped,
    ))
}

fn import_history(
    domain: &DomainIndex,
    type_map: &HashMap<i64, String>,
    history_path: Option<&Path>,
) -> ApiResult<(Vec<ImportedLibraryItem>, usize)> {
    let Some(path) = history_path else {
        return Ok((Vec::new(), 0));
    };

    let mut seen = HashSet::new();
    let mut imported = Vec::new();
    let mut skipped = 0;
    scan_history_rows(path, |row| {
        let Some(source_key) = resolve_source_key(domain, type_map, &row.comic_id, row.type_value)
        else {
            skipped += 1;
            return;
        };
        if !seen.insert((source_key.clone(), row.comic_id.clone())) {
            return;
        }

        let record = domain.record(&source_key, &row.comic_id);
        let episode_id = row.episode.map(|value| value.to_string());
        let episode_title = row.episode.map(|value| format!("第 {value} 话"));
        imported.push(ImportedLibraryItem {
            source_key,
            comic_id: row.comic_id,
            title: first_non_empty(Some(row.title), record.map(|value| value.title.clone()))
                .unwrap_or_else(|| "Untitled".to_string()),
            subtitle: first_non_empty(
                row.subtitle,
                record.and_then(|value| value.subtitle.clone()),
            ),
            cover: first_non_empty(row.cover, record.and_then(|value| value.cover.clone())),
            episode_id,
            episode_title,
            timestamp_ms: row
                .time_ms
                .or_else(|| record.and_then(|value| value.timestamp_ms)),
        });
    })?;

    Ok((imported, skipped))
}

struct FavoriteRow {
    folder_name: String,
    comic_id: String,
    title: Option<String>,
    author: Option<String>,
    cover: Option<String>,
    time: Option<String>,
    type_value: i64,
    last_update_time: Option<String>,
    has_new_update: Option<i64>,
    last_check_time: Option<i64>,
}

struct HistoryRow {
    comic_id: String,
    title: String,
    subtitle: Option<String>,
    cover: Option<String>,
    time_ms: Option<i64>,
    type_value: i64,
    episode: Option<i64>,
}

fn read_favorite_folder_order(path: &Path) -> rusqlite::Result<HashMap<String, i64>> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let has_folder_order = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'folder_order'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !has_folder_order {
        return Ok(HashMap::new());
    }

    let mut statement = connection.prepare("SELECT folder_name, order_value FROM folder_order")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;

    let mut order = HashMap::new();
    for row in rows {
        let (folder_name, order_value) = row?;
        order.insert(folder_name, order_value);
    }
    Ok(order)
}

fn sqlite_columns(connection: &Connection, table_name: &str) -> rusqlite::Result<HashSet<String>> {
    let identifier = quote_identifier(table_name);
    let mut statement = connection.prepare(&format!("PRAGMA table_info({identifier})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<HashSet<_>>>()?;
    Ok(columns)
}

fn optional_column_expr(columns: &HashSet<String>, column: &str) -> String {
    if columns.contains(column) {
        quote_identifier(column)
    } else {
        "NULL".to_string()
    }
}

fn scan_favorite_rows(path: &Path, mut visit: impl FnMut(FavoriteRow)) -> rusqlite::Result<()> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let table_names = user_table_names(&connection)?
        .into_iter()
        .filter(|name| {
            !matches!(
                name.as_str(),
                "folder_order" | "folder_sync" | "comic_links"
            )
        })
        .collect::<Vec<_>>();

    for table_name in table_names {
        let columns = sqlite_columns(&connection, &table_name)?;
        let identifier = quote_identifier(&table_name);
        let last_update_expr = optional_column_expr(&columns, "last_update_time");
        let has_new_update_expr = optional_column_expr(&columns, "has_new_update");
        let last_check_expr = optional_column_expr(&columns, "last_check_time");
        let mut statement = connection.prepare(&format!(
            "SELECT id, name, author, cover_path, time, type, {last_update_expr}, {has_new_update_expr}, {last_check_expr} FROM {identifier}"
        ))?;
        let rows = statement.query_map([], |row| {
            Ok(FavoriteRow {
                folder_name: table_name.clone(),
                comic_id: row.get(0)?,
                title: row.get(1)?,
                author: row.get(2)?,
                cover: row.get(3)?,
                time: row.get(4)?,
                type_value: row.get(5)?,
                last_update_time: row.get(6)?,
                has_new_update: row.get(7)?,
                last_check_time: row.get(8)?,
            })
        })?;
        for row in rows {
            visit(row?);
        }
    }

    Ok(())
}

fn scan_history_rows(path: &Path, mut visit: impl FnMut(HistoryRow)) -> rusqlite::Result<()> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let has_history = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'history'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !has_history {
        return Ok(());
    }

    let mut statement = connection.prepare(
        "SELECT id, title, subtitle, cover, time, type, ep FROM history ORDER BY time DESC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(HistoryRow {
            comic_id: row.get(0)?,
            title: row.get(1)?,
            subtitle: row.get(2)?,
            cover: row.get(3)?,
            time_ms: row.get(4)?,
            type_value: row.get(5)?,
            episode: row.get(6)?,
        })
    })?;
    for row in rows {
        visit(row?);
    }

    Ok(())
}

fn user_table_names(connection: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names)
}

fn resolve_source_key(
    domain: &DomainIndex,
    type_map: &HashMap<i64, String>,
    comic_id: &str,
    type_value: i64,
) -> Option<String> {
    type_map
        .get(&type_value)
        .cloned()
        .or_else(|| domain.unique_source_key(comic_id))
}

fn inspect_database(
    archive: &mut ZipArchive<File>,
    tmp_dir: &Path,
    entry_name: &str,
) -> ImportBackupDatabasePreview {
    let mut entry = match archive.by_name(entry_name) {
        Ok(entry) => entry,
        Err(ZipError::FileNotFound) => {
            return ImportBackupDatabasePreview {
                name: entry_name.to_string(),
                present: false,
                tables: Vec::new(),
                error: None,
            };
        }
        Err(err) => return database_error(entry_name, err.to_string()),
    };

    let mut bytes = Vec::new();
    if let Err(err) = entry.read_to_end(&mut bytes) {
        return database_error(entry_name, err.to_string());
    }
    drop(entry);

    let temp_path = temp_database_path(tmp_dir, entry_name, &bytes);
    if let Err(err) = fs::write(&temp_path, bytes) {
        return database_error(entry_name, err.to_string());
    }

    let tables = inspect_sqlite_tables(&temp_path);
    let _ = fs::remove_file(&temp_path);

    match tables {
        Ok(tables) => ImportBackupDatabasePreview {
            name: entry_name.to_string(),
            present: true,
            tables,
            error: None,
        },
        Err(err) => database_error(entry_name, err.to_string()),
    }
}

fn inspect_sqlite_tables(path: &Path) -> rusqlite::Result<Vec<ImportBackupTablePreview>> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut table_statement = connection.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )?;
    let table_names = table_statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(table_statement);

    let mut tables = Vec::new();
    for table_name in table_names {
        let identifier = quote_identifier(&table_name);
        let row_count = connection
            .query_row(&format!("SELECT COUNT(*) FROM {identifier}"), [], |row| {
                row.get::<_, i64>(0)
            })
            .ok()
            .and_then(|value| u64::try_from(value).ok());

        let mut column_statement =
            connection.prepare(&format!("PRAGMA table_info({identifier})"))?;
        let columns = column_statement
            .query_map([], |row| {
                let name = row.get::<_, String>(1)?;
                let column_type = row.get::<_, String>(2)?;
                if column_type.is_empty() {
                    Ok(name)
                } else {
                    Ok(format!("{name}:{column_type}"))
                }
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        tables.push(ImportBackupTablePreview {
            name: table_name,
            row_count,
            columns,
        });
    }

    Ok(tables)
}

fn resolve_backup_path(config: &AppConfig, value: &str) -> ApiResult<(String, PathBuf)> {
    let relative_path = normalize_import_path(value)?;
    if relative_path.is_empty() {
        return Err(ApiError::BadRequest("backup path is required".to_string()));
    }
    if !relative_path.ends_with(".venera") {
        return Err(ApiError::BadRequest(
            "backup path must point to a .venera file".to_string(),
        ));
    }

    Ok((
        relative_path.clone(),
        config.imports_dir().join(relative_path),
    ))
}

fn normalize_import_path(value: &str) -> ApiResult<String> {
    let normalized = value.trim().replace('\\', "/");
    let parts = normalized
        .split('/')
        .filter(|part| !part.is_empty())
        .map(str::trim)
        .collect::<Vec<_>>();
    if parts.iter().any(|part| *part == "." || *part == "..") {
        return Err(ApiError::BadRequest("invalid backup path".to_string()));
    }
    Ok(parts.join("/"))
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

fn is_valid_source_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}

fn is_valid_import_file_name(file_name: &str) -> bool {
    !file_name.is_empty()
        && file_name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
}

fn first_non_empty(primary: Option<String>, fallback: Option<String>) -> Option<String> {
    primary
        .and_then(|value| {
            let value = value.trim().to_string();
            (!value.is_empty()).then_some(value)
        })
        .or_else(|| {
            fallback.and_then(|value| {
                let value = value.trim().to_string();
                (!value.is_empty()).then_some(value)
            })
        })
}

fn parse_favorite_time(value: Option<String>) -> Option<i64> {
    let value = value?;
    if let Ok(parsed) = value.parse::<i64>() {
        return Some(parsed);
    }
    None
}

fn temp_database_path(tmp_dir: &Path, entry_name: &str, bytes: &[u8]) -> PathBuf {
    let mut hasher = Sha256::new();
    hasher.update(entry_name.as_bytes());
    hasher.update(bytes.len().to_le_bytes());
    hasher.update(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .to_le_bytes(),
    );
    let digest = format!("{:x}", hasher.finalize());
    tmp_dir.join(format!("{}.db", &digest[..16]))
}

fn quote_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn normalize_zip_name(value: &str) -> String {
    value.replace('\\', "/")
}

fn database_error(name: &str, error: String) -> ImportBackupDatabasePreview {
    ImportBackupDatabasePreview {
        name: name.to_string(),
        present: true,
        tables: Vec::new(),
        error: Some(error),
    }
}

fn zip_error(err: ZipError) -> ApiError {
    ApiError::ImportPreview(err.to_string())
}

fn system_time_seconds(value: SystemTime) -> Option<u64> {
    value
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}
