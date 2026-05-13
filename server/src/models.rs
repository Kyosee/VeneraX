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
pub struct LibraryResponse {
    pub history: Vec<LibraryItem>,
    pub favorites: Vec<LibraryItem>,
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
