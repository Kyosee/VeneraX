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

export type LibraryResponse = {
  history: LibraryItem[]
  favorites: LibraryItem[]
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

export function getLibrary() {
  return request<LibraryResponse>('/api/library')
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
