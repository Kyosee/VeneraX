export type HealthResponse = {
  status: 'ok'
  version: string
  database: string
  data_dir: string
  source_runtime: boolean
  static_assets: boolean
}

export type Capability = {
  key: string
  label: string
  status: 'available' | 'planned' | 'hidden'
  reason?: string
}

export type CapabilitiesResponse = {
  mode: string
  multi_user: boolean
  auth: boolean
  features: Capability[]
}

export type SettingsResponse = {
  values: Record<string, unknown>
  hidden_features: string[]
}

export type SourceSummary = {
  key: string
  name: string
  version: string | null
  file_name: string
  enabled: boolean
  runtime_status: 'registered' | 'pending_parse'
  updated_at: string | null
}

export type SourceWriteRequest = {
  file_name?: string
  content: string
}

export type SearchComic = {
  id: string
  title: string
  subtitle: string | null
  cover: string | null
  url: string | null
  tags: string[]
  raw: unknown
}

export type SearchResponse = {
  source_key: string
  keyword: string
  page: number
  max_page: number | null
  next: string | null
  comics: SearchComic[]
}

export type ComicEpisode = {
  id: string
  title: string
}

export type ComicInfo = {
  id: string
  title: string
  subtitle: string | null
  cover: string | null
  description: string | null
  tags: string[]
  episodes: ComicEpisode[]
  raw: unknown
}

export type ComicInfoResponse = {
  source_key: string
  comic: ComicInfo
}

export type ComicPagesResponse = {
  source_key: string
  comic_id: string
  episode_id: string
  images: string[]
}

export type LibraryItem = {
  source_key: string
  comic_id: string
  title: string
  subtitle: string | null
  cover: string | null
  episode_id: string | null
  episode_title: string | null
  updated_at: string | null
}

export type FavoriteFolder = {
  name: string
  title: string
  count: number
}

export type LibraryResponse = {
  history_total: number
  favorites_total: number
  favorites_window_total: number
  history: LibraryItem[]
  favorites: LibraryItem[]
  favorite_folders: FavoriteFolder[]
}

export type LibraryQuery = {
  history_limit?: number
  history_offset?: number
  favorites_limit?: number
  favorites_offset?: number
  favorite_folder?: string
}

export type FollowUpdatesResponse = {
  folder: string | null
  updated_total: number
  all_total: number
  updated: LibraryItem[]
  all: LibraryItem[]
}

export type FollowUpdatesQuery = {
  folder?: string
  limit?: number
  offset?: number
}

export type HistoryWriteRequest = {
  source_key: string
  comic_id: string
  title: string
  subtitle: string | null
  cover: string | null
  episode_id: string
  episode_title: string
}

export type FavoriteWriteRequest = {
  source_key: string
  comic_id: string
  title: string
  subtitle: string | null
  cover: string | null
  favorite: boolean
}

export type WebDavConfigResponse = {
  endpoint_url: string | null
  username: string | null
  root_path: string
  password_configured: boolean
  read_only: boolean
  updated_at: string | null
}

export type WebDavConfigRequest = {
  endpoint_url: string
  username?: string
  password?: string
  root_path?: string
}

export type WebDavEntry = {
  name: string
  path: string
  is_dir: boolean
  size: number | null
  modified: string | null
}

export type WebDavListResponse = {
  path: string
  entries: WebDavEntry[]
}

export type WebDavDownloadResponse = {
  path: string
  file_name: string
  local_path: string
  size: number
  content_type: string | null
}

export type ImportBackupSummary = {
  file_name: string
  path: string
  size: number
  modified: number | null
}

export type ImportBackupsResponse = {
  backups: ImportBackupSummary[]
}

export type ImportBackupTablePreview = {
  name: string
  row_count: number | null
  columns: string[]
}

export type ImportBackupDatabasePreview = {
  name: string
  present: boolean
  tables: ImportBackupTablePreview[]
  error: string | null
}

export type ImportBackupPreviewResponse = {
  file_name: string
  path: string
  size: number
  entry_count: number
  appdata_keys: string[]
  comic_source_js_count: number
  comic_source_data_count: number
  comic_source_samples: string[]
  databases: ImportBackupDatabasePreview[]
}

export type ImportBackupApplyResponse = {
  file_name: string
  path: string
  sources_imported: number
  source_data_files_imported: number
  favorites_imported: number
  history_imported: number
  favorites_skipped: number
  history_skipped: number
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...init?.headers
    },
    ...init
  })

  if (!response.ok) {
    const text = await response.text()
    if (response.status >= 500) {
      throw new Error('API 服务不可用')
    }
    throw new Error(text || `HTTP ${response.status}`)
  }

  return response.json() as Promise<T>
}

export function getHealth() {
  return request<HealthResponse>('/api/health')
}

export function getCapabilities() {
  return request<CapabilitiesResponse>('/api/capabilities')
}

export function getSettings() {
  return request<SettingsResponse>('/api/settings')
}

export function updateSettings(values: Record<string, unknown>) {
  return request<SettingsResponse>('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ values })
  })
}

export function getLibrary(query?: LibraryQuery) {
  const params = new URLSearchParams()
  Object.entries(query ?? {}).forEach(([key, value]) => {
    if (value != null) params.set(key, String(value))
  })
  const suffix = params.toString()
  return request<LibraryResponse>(`/api/library${suffix ? `?${suffix}` : ''}`)
}

export function getFollowUpdates(query?: FollowUpdatesQuery) {
  const params = new URLSearchParams()
  Object.entries(query ?? {}).forEach(([key, value]) => {
    if (value != null) params.set(key, String(value))
  })
  const suffix = params.toString()
  return request<FollowUpdatesResponse>(`/api/follow-updates${suffix ? `?${suffix}` : ''}`)
}

export function recordHistory(payload: HistoryWriteRequest) {
  return request<LibraryResponse>('/api/history', {
    method: 'POST',
    body: JSON.stringify(payload)
  })
}

export function setFavorite(payload: FavoriteWriteRequest) {
  return request<LibraryResponse>('/api/favorites', {
    method: 'POST',
    body: JSON.stringify(payload)
  })
}

export function getWebDavConfig() {
  return request<WebDavConfigResponse>('/api/webdav/config')
}

export function saveWebDavConfig(payload: WebDavConfigRequest) {
  return request<WebDavConfigResponse>('/api/webdav/config', {
    method: 'PUT',
    body: JSON.stringify(payload)
  })
}

export function clearWebDavConfig() {
  return request<WebDavConfigResponse>('/api/webdav/config', {
    method: 'DELETE'
  })
}

export function listWebDav(path = '') {
  return request<WebDavListResponse>('/api/webdav/list', {
    method: 'POST',
    body: JSON.stringify({ path })
  })
}

export function downloadWebDav(path: string) {
  return request<WebDavDownloadResponse>('/api/webdav/download', {
    method: 'POST',
    body: JSON.stringify({ path })
  })
}

export function listImportBackups() {
  return request<ImportBackupsResponse>('/api/imports/backups')
}

export function previewImportBackup(path: string) {
  return request<ImportBackupPreviewResponse>('/api/imports/preview', {
    method: 'POST',
    body: JSON.stringify({ path })
  })
}

export function applyImportBackup(path: string) {
  return request<ImportBackupApplyResponse>('/api/imports/apply', {
    method: 'POST',
    body: JSON.stringify({ path })
  })
}

export function getSources() {
  return request<SourceSummary[]>('/api/sources')
}

export function saveSource(payload: SourceWriteRequest) {
  return request<SourceSummary>('/api/sources', {
    method: 'POST',
    body: JSON.stringify(payload)
  })
}

export function deleteSource(key: string) {
  return request<{ deleted: boolean }>(`/api/sources/${encodeURIComponent(key)}`, {
    method: 'DELETE'
  })
}

export function searchComics(sourceKey: string, keyword: string, page = 1) {
  return request<SearchResponse>('/api/search', {
    method: 'POST',
    body: JSON.stringify({ source_key: sourceKey, keyword, page })
  })
}

export function getComicInfo(sourceKey: string, comicId: string) {
  return request<ComicInfoResponse>('/api/comic/info', {
    method: 'POST',
    body: JSON.stringify({ source_key: sourceKey, comic_id: comicId })
  })
}

export function getComicPages(sourceKey: string, comicId: string, episodeId: string) {
  return request<ComicPagesResponse>('/api/comic/pages', {
    method: 'POST',
    body: JSON.stringify({ source_key: sourceKey, comic_id: comicId, episode_id: episodeId })
  })
}

export function imageProxyUrl(url: string) {
  return `/api/image?url=${encodeURIComponent(url)}`
}
