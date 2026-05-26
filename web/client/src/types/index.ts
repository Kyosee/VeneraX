export interface History {
  id: string
  type: number
  sourceKey?: string
  title: string
  subtitle: string
  cover: string
  time: number
  ep: number
  page: number
  group: number | null
  readEpisode: string[] | string
  maxPage: number | null
  max_page?: number | null
  chapter_group?: number | null
}

export interface FavoriteItem {
  folder?: string
  id: string
  name: string
  author: string
  type: number
  tags: string[]
  coverPath: string
  time: string
  lastUpdateTime?: string
  hasNewUpdate?: boolean
  status?: string | null
  displayOrder?: number
  sourceKey?: string
  authors?: string[]
  updateTimeMeta?: string | null
  extraMeta?: Record<string, string>
}

export interface FavoriteFolder {
  id: string
  name: string
  order: number
}

export interface Comic {
  title: string
  cover: string
  id: string
  subtitle?: string
  tags?: string[] | Record<string, unknown>
  description: string
  sourceKey: string
  maxPage?: number
  stars?: number
  language?: string
  favoriteId?: string
  status?: string
  updateTime?: string
  pagesText?: string
  sourceName?: string
}

export interface Chapter {
  title: string
  id: string
  group?: string
}

export interface ChapterGroup {
  title: string
  chapters: Chapter[]
}

export interface Comment {
  userName: string
  avatar?: string
  content: string
  time?: string
  replyCount?: number
  id?: string
  score?: number
  isLiked?: boolean
}

export interface ComicSource {
  name: string
  key: string
  version: string
  url: string
  canonicalKey?: string | null
  displayName?: string
  sourceName?: string
}

export interface SourceSearchOption {
  label: string
  type: 'select' | 'multi-select' | 'dropdown'
  options: string[]
  default?: string | string[] | null
}

export interface SourceCategoryPart {
  name: string
  type: 'fixed' | 'random' | 'dynamic'
  categories: string[]
  categoryParams: string[] | null
  itemType: string
}

export interface SourceCapabilities {
  key: string
  name: string
  version: string
  search: {
    hasLoad: boolean
    hasLoadNext: boolean
    optionList: SourceSearchOption[]
    enableTagsSuggestions: boolean
  } | null
  explore: Array<{
    title: string
    type: string
    hasLoad: boolean
    hasLoadNext: boolean
  }>
  category: {
    title: string
    parts: SourceCategoryPart[]
    enableRankingPage: boolean
  } | null
  categoryComics: {
    hasLoad: boolean
    optionList: SourceSearchOption[]
    hasRanking: boolean
    rankingOptions: string[] | null
  } | null
  comic: {
    hasLoadInfo: boolean
    hasLoadEp: boolean
    hasLoadComments: boolean
    hasLoadThumbnails: boolean
  } | null
  account: { hasLogin: boolean } | null
  favorites: { multiFolder: boolean } | null
  settings: Record<string, any> | null
  translation: Record<string, Record<string, string>> | null
}

export interface RelatedSource {
  comic_id: string
  id: string
  sourceKey: string
  title: string
  author: string | null
  status: string | null
  cover_uri: string | null
  description: string | null
  tags: string[] | null
  tags_json: string | null
  page_count: number | null
  link_status: 'candidate' | 'accepted' | 'rejected'
  link_source: 'auto' | 'manual'
  confidence: number
  work_id: string
  platform_name: string
  platform_id: string
}

export interface SyncStatus {
  isDownloading: boolean
  isUploading: boolean
  lastError?: string
  isEnabled: boolean
}

export interface TagSuggestion {
  namespace: string
  key: string
  label: string
}

export interface ApiResponse {
  ok: boolean
  [key: string]: any
}
