use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub version: &'static str,
    pub database: &'static str,
    pub data_dir: String,
    pub source_runtime: bool,
    pub static_assets: bool,
}

#[derive(Serialize)]
pub struct Capability {
    pub key: &'static str,
    pub label: &'static str,
    pub status: &'static str,
    pub reason: Option<&'static str>,
}

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub mode: &'static str,
    pub multi_user: bool,
    pub auth: bool,
    pub features: Vec<Capability>,
}

#[derive(Serialize)]
pub struct SettingsResponse {
    pub values: BTreeMap<String, Value>,
    pub hidden_features: Vec<&'static str>,
}

#[derive(Deserialize)]
pub struct SettingsPatch {
    pub values: BTreeMap<String, Value>,
}

#[derive(Serialize)]
pub struct SourceSummary {
    pub key: String,
    pub name: String,
    pub version: Option<String>,
    pub file_name: String,
    pub enabled: bool,
    pub runtime_status: &'static str,
    pub updated_at: Option<String>,
}

#[derive(Deserialize)]
pub struct SourceWriteRequest {
    pub file_name: Option<String>,
    pub content: String,
}

#[derive(Deserialize)]
pub struct SourcePatchRequest {
    pub enabled: Option<bool>,
}

#[derive(Serialize)]
pub struct DeleteResponse {
    pub deleted: bool,
}

#[derive(Deserialize)]
pub struct SearchRequest {
    pub source_key: String,
    pub keyword: String,
    pub page: Option<u32>,
}

#[derive(Deserialize)]
pub struct ComicInfoRequest {
    pub source_key: String,
    pub comic_id: String,
}

#[derive(Deserialize)]
pub struct ComicPagesRequest {
    pub source_key: String,
    pub comic_id: String,
    pub episode_id: String,
}

#[derive(Deserialize)]
pub struct ImageProxyQuery {
    pub url: String,
}

#[derive(Serialize, Deserialize)]
pub struct SearchComic {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub cover: Option<String>,
    pub url: Option<String>,
    pub tags: Vec<String>,
    pub raw: Value,
}

#[derive(Serialize)]
pub struct SearchResponse {
    pub source_key: String,
    pub keyword: String,
    pub page: u32,
    pub max_page: Option<u32>,
    pub next: Option<String>,
    pub comics: Vec<SearchComic>,
}

#[derive(Deserialize)]
pub struct RuntimeSearchResult {
    pub max_page: Option<u32>,
    pub next: Option<String>,
    pub comics: Vec<SearchComic>,
}

#[derive(Serialize, Deserialize)]
pub struct ComicEpisode {
    pub id: String,
    pub title: String,
}

#[derive(Serialize, Deserialize)]
pub struct RuntimeComicInfo {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub cover: Option<String>,
    pub description: Option<String>,
    pub tags: Vec<String>,
    pub episodes: Vec<ComicEpisode>,
    pub raw: Value,
}

#[derive(Serialize)]
pub struct ComicInfoResponse {
    pub source_key: String,
    pub comic: RuntimeComicInfo,
}

#[derive(Deserialize)]
pub struct RuntimeComicPages {
    pub images: Vec<String>,
}

#[derive(Serialize)]
pub struct ComicPagesResponse {
    pub source_key: String,
    pub comic_id: String,
    pub episode_id: String,
    pub images: Vec<String>,
}

#[derive(Serialize)]
pub struct LibraryItem {
    pub source_key: String,
    pub comic_id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub cover: Option<String>,
    pub episode_id: Option<String>,
    pub episode_title: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Serialize)]
pub struct FavoriteFolder {
    pub name: String,
    pub title: String,
    pub count: u64,
}

#[derive(Serialize)]
pub struct LibraryResponse {
    pub history_total: u64,
    pub favorites_total: u64,
    pub favorites_window_total: u64,
    pub history: Vec<LibraryItem>,
    pub favorites: Vec<LibraryItem>,
    pub favorite_folders: Vec<FavoriteFolder>,
}

#[derive(Default, Deserialize)]
pub struct LibraryQuery {
    pub history_limit: Option<u32>,
    pub history_offset: Option<u32>,
    pub favorites_limit: Option<u32>,
    pub favorites_offset: Option<u32>,
    pub favorite_folder: Option<String>,
}

#[derive(Default, Deserialize)]
pub struct FollowUpdatesQuery {
    pub folder: Option<String>,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
}

#[derive(Serialize)]
pub struct FollowUpdatesResponse {
    pub folder: Option<String>,
    pub updated_total: u64,
    pub all_total: u64,
    pub updated: Vec<LibraryItem>,
    pub all: Vec<LibraryItem>,
}

#[derive(Deserialize)]
pub struct HistoryWriteRequest {
    pub source_key: String,
    pub comic_id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub cover: Option<String>,
    pub episode_id: String,
    pub episode_title: String,
}

#[derive(Deserialize)]
pub struct FavoriteWriteRequest {
    pub source_key: String,
    pub comic_id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub cover: Option<String>,
    pub favorite: bool,
}

#[derive(Serialize)]
pub struct WebDavConfigResponse {
    pub endpoint_url: Option<String>,
    pub username: Option<String>,
    pub root_path: String,
    pub password_configured: bool,
    pub read_only: bool,
    pub updated_at: Option<String>,
}

#[derive(Deserialize)]
pub struct WebDavConfigRequest {
    pub endpoint_url: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub root_path: Option<String>,
}

#[derive(Deserialize)]
pub struct WebDavListRequest {
    pub path: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct WebDavEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub modified: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct WebDavListResponse {
    pub path: String,
    pub entries: Vec<WebDavEntry>,
}

#[derive(Deserialize)]
pub struct WebDavDownloadRequest {
    pub path: String,
}

#[derive(Serialize, Deserialize)]
pub struct WebDavDownloadResponse {
    pub path: String,
    pub file_name: String,
    pub local_path: String,
    pub size: u64,
    pub content_type: Option<String>,
}

#[derive(Serialize)]
pub struct ImportBackupSummary {
    pub file_name: String,
    pub path: String,
    pub size: u64,
    pub modified: Option<u64>,
}

#[derive(Serialize)]
pub struct ImportBackupsResponse {
    pub backups: Vec<ImportBackupSummary>,
}

#[derive(Deserialize)]
pub struct ImportBackupPreviewRequest {
    pub path: String,
}

#[derive(Deserialize)]
pub struct ImportBackupApplyRequest {
    pub path: String,
}

#[derive(Serialize)]
pub struct ImportBackupTablePreview {
    pub name: String,
    pub row_count: Option<u64>,
    pub columns: Vec<String>,
}

#[derive(Serialize)]
pub struct ImportBackupDatabasePreview {
    pub name: String,
    pub present: bool,
    pub tables: Vec<ImportBackupTablePreview>,
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct ImportBackupPreviewResponse {
    pub file_name: String,
    pub path: String,
    pub size: u64,
    pub entry_count: usize,
    pub appdata_keys: Vec<String>,
    pub comic_source_js_count: usize,
    pub comic_source_data_count: usize,
    pub comic_source_samples: Vec<String>,
    pub databases: Vec<ImportBackupDatabasePreview>,
}

#[derive(Serialize)]
pub struct ImportBackupApplyResponse {
    pub file_name: String,
    pub path: String,
    pub sources_imported: usize,
    pub source_data_files_imported: usize,
    pub favorites_imported: usize,
    pub history_imported: usize,
    pub favorites_skipped: usize,
    pub history_skipped: usize,
}
