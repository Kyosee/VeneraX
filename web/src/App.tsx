import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  BookOpen,
  Bookmark,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CheckSquare,
  ClipboardList,
  Compass,
  Download,
  EyeOff,
  Filter,
  FolderOpen,
  Heart,
  History,
  Home,
  Library,
  Loader2,
  MoreHorizontal,
  Play,
  Trash2,
  Upload,
  RefreshCw,
  Save,
  Search,
  Settings,
  Tags,
  WifiOff
} from 'lucide-react'
import {
  type ComicEpisode,
  type ComicInfo,
  type FavoriteWriteRequest,
  type FavoriteFolder,
  type FollowUpdatesResponse,
  type HistoryWriteRequest,
  type HealthResponse,
  type ImportBackupApplyResponse,
  type ImportBackupPreviewResponse,
  type ImportBackupSummary,
  type LibraryItem,
  type LibraryResponse,
  type SearchComic,
  type SettingsResponse,
  type SourceCategoryItem,
  type SourceCategoryPart,
  type SourceComicListResponse,
  type SourcePageManifest,
  type SourcePagesResponse,
  type SourceSettingItem,
  type SourceSettingsResponse,
  type SourceSettingValue,
  type SourceSummary,
  type TaskSummary,
  type WebDavConfigResponse,
  type WebDavEntry,
  type WebDavUploadResponse,
  applyImportBackup,
  getComicInfo,
  getComicPages,
  getFollowUpdates,
  getHealth,
  getLibrary,
  getSettings,
  getSourcePages,
  getSourceSettings,
  getSources,
  getWebDavConfig,
  listImportBackups,
  listWebDav,
  loadSourceCategoryPage,
  loadSourceExplorePage,
  previewImportBackup,
  saveSource,
  saveWebDavConfig,
  deleteSource,
  downloadWebDav,
  imageProxyUrl,
  recordHistory,
  searchComics,
  setFavorite,
  getTasks,
  markFollowUpdatesRead,
  startFollowUpdatesCheck,
  updateSource,
  updateSourceSetting,
  uploadWebDav,
  updateSettings,
  createFavoriteFolder,
  deleteFavoriteFolder
} from './api'
import { ReloadPrompt } from './ReloadPrompt'
import { ThemeProvider } from './theme/ThemeProvider'
import { SnackbarHost } from './ui/Snackbar'

type TabKey =
  | 'home'
  | 'history'
  | 'favorites'
  | 'explore'
  | 'categories'
  | 'updates'
  | 'search'
  | 'tasks'
  | 'settings'

type PrimaryTabKey = 'home' | 'favorites' | 'explore' | 'categories'

type AppData = {
  health: HealthResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
  library: LibraryResponse
  followUpdates: FollowUpdatesResponse
  tasks: TaskSummary[]
}

type ComicOpenRequest = {
  sourceKey: string
  comicId: string
  title: string
  subtitle: string | null
  cover: string | null
  initialComic?: ComicInfo
}

type ReaderOpenRequest = {
  sourceKey: string
  comic: ComicInfo
  episode: ComicEpisode
}

type AppRoute =
  | { kind: 'main' }
  | { kind: 'detail'; request: ComicOpenRequest }
  | { kind: 'reader'; request: ReaderOpenRequest }

type ReaderMode =
  | 'galleryLeftToRight'
  | 'galleryRightToLeft'
  | 'galleryTopToBottom'
  | 'continuousLeftToRight'
  | 'continuousRightToLeft'
  | 'continuousTopToBottom'

const readerModeOptions = [
  { key: 'galleryLeftToRight', label: '单页 左到右' },
  { key: 'galleryRightToLeft', label: '单页 右到左' },
  { key: 'galleryTopToBottom', label: '单页 上到下' },
  { key: 'continuousTopToBottom', label: '连续 上到下' },
  { key: 'continuousLeftToRight', label: '连续 左到右' },
  { key: 'continuousRightToLeft', label: '连续 右到左' }
] satisfies Array<{ key: ReaderMode; label: string }>

const primaryNav = [
  { key: 'home', label: '首页', icon: Home },
  { key: 'favorites', label: '收藏', icon: Heart },
  { key: 'explore', label: '发现', icon: Compass },
  { key: 'categories', label: '分类', icon: Tags }
] satisfies Array<{ key: PrimaryTabKey; label: string; icon: typeof Home }>

const actionNav = [
  { key: 'search', label: '搜索', icon: Search },
  { key: 'tasks', label: '任务', icon: ClipboardList },
  { key: 'settings', label: '设置', icon: Settings }
] satisfies Array<{ key: TabKey; label: string; icon: typeof Home }>

const navigationItems = [...primaryNav, ...actionNav]

const emptyData: AppData = {
  health: null,
  settings: null,
  sources: [],
  library: {
    history_total: 0,
    favorites_total: 0,
    favorites_window_total: 0,
    history: [],
    favorites: [],
    favorite_folders: []
  },
  followUpdates: { folder: null, updated_total: 0, all_total: 0, updated: [], all: [] },
  tasks: []
}

const libraryPageStep = 100

function emptyFollowUpdates(folder: string | null): FollowUpdatesResponse {
  return { folder, updated_total: 0, all_total: 0, updated: [], all: [] }
}

function storedFollowFolder(settings: SettingsResponse, folders: FavoriteFolder[]) {
  const value = settings.values.followUpdatesFolder
  if (typeof value !== 'string' || value.trim() === '') return null
  return folders.some((folder) => folder.name === value) ? value : null
}

function mergeTasks(current: TaskSummary[], incoming: TaskSummary) {
  return [incoming, ...current.filter((task) => task.id !== incoming.id)]
}

function taskPayloadText(task: TaskSummary, key: string) {
  const value = task.payload?.[key]
  return typeof value === 'string' ? value : null
}

function taskPayloadNumber(task: TaskSummary, key: string) {
  const value = task.payload?.[key]
  return typeof value === 'number' ? value : 0
}

function delay(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

type ComicMetaRow = {
  label: string
  value: string
  tone: 'blue' | 'cyan' | 'pink' | 'green' | 'orange' | 'purple'
}

type SettingsSectionKey = 'appearance' | 'reading' | 'explore' | 'network' | 'webdav' | 'about' | 'hidden'

function cleanText(value: unknown) {
  if (typeof value !== 'string' && typeof value !== 'number') return null
  const text = String(value).replace(/\s+/g, ' ').trim()
  return text.length > 0 ? text : null
}

function rawRecord(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function rawText(raw: unknown, keys: string[]) {
  const record = rawRecord(raw)
  if (!record) return null
  for (const key of keys) {
    const value = cleanText(record[key])
    if (value) return value
  }
  return null
}

function parseAppDate(value: string | null) {
  if (!value) return null
  const normalized = /^\d{4}-\d{2}-\d{2} /.test(value) ? value.replace(' ', 'T') : value
  const date = new Date(normalized)
  return Number.isNaN(date.getTime()) ? null : date
}

function formatDateOnly(value: string | null) {
  const date = parseAppDate(value)
  if (!date) return null
  return date.toLocaleDateString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  })
}

function firstPresent(values: Array<string | null | undefined>) {
  return values.find((value) => value != null && value.trim().length > 0) ?? null
}

function libraryItemMetaRows(item: LibraryItem): ComicMetaRow[] {
  return [
    { label: 'Source', value: item.source_key, tone: 'cyan' },
    { label: 'Authors', value: item.subtitle ?? '', tone: 'blue' },
    { label: 'Progress', value: item.episode_title ?? '', tone: 'green' },
    { label: 'Update', value: formatDateOnly(item.updated_at) ?? '', tone: 'orange' }
  ].filter((row) => row.value.trim().length > 0) as ComicMetaRow[]
}

function searchComicMetaRows(comic: SearchComic): ComicMetaRow[] {
  return [
    { label: 'Authors', value: comic.subtitle ?? '', tone: 'blue' },
    { label: 'Tags', value: comic.tags.slice(0, 3).join(', '), tone: 'pink' }
  ].filter((row) => row.value.trim().length > 0) as ComicMetaRow[]
}

function comicInfoRows(comic: ComicInfo, sourceKey: string, progressText?: string | null): ComicMetaRow[] {
  const update = firstPresent([
    rawText(comic.raw, ['updateTime', 'update_time', 'lastUpdate', 'last_update']),
    rawText(comic.raw, ['uploadTime', 'upload_time'])
  ])
  const pages = rawText(comic.raw, ['maxPage', 'pages', 'pageCount'])
  const status = rawText(comic.raw, ['status', 'state'])
  return [
    { label: 'Authors', value: firstPresent([comic.subtitle, rawText(comic.raw, ['author', 'uploader', 'artist'])]) ?? '', tone: 'blue' },
    { label: 'Update', value: update ?? '', tone: 'cyan' },
    { label: 'Source', value: sourceKey, tone: 'cyan' },
    { label: 'Tags', value: comic.tags.slice(0, 4).join(', '), tone: 'pink' },
    { label: 'Status', value: status ?? '', tone: 'purple' },
    { label: 'Progress', value: progressText ?? '', tone: 'green' },
    { label: 'Pages', value: pages ?? '', tone: 'orange' }
  ].filter((row) => row.value.trim().length > 0) as ComicMetaRow[]
}

function libraryItemKey(item: LibraryItem) {
  return `${item.source_key}:${item.comic_id}:${item.episode_id ?? ''}`
}

function mergeLibraryItems(current: LibraryItem[], incoming: LibraryItem[]) {
  const seen = new Set(current.map(libraryItemKey))
  return [
    ...current,
    ...incoming.filter((item) => {
      const key = libraryItemKey(item)
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  ]
}

function isPrimaryTabKey(value: TabKey): value is PrimaryTabKey {
  return primaryNav.some((item) => item.key === value)
}

function libraryItemToOpenRequest(item: LibraryItem): ComicOpenRequest {
  return {
    sourceKey: item.source_key,
    comicId: item.comic_id,
    title: item.title,
    subtitle: item.subtitle,
    cover: item.cover,
    initialComic: undefined
  }
}

function searchComicToOpenRequest(sourceKey: string, comic: SearchComic): ComicOpenRequest {
  return {
    sourceKey,
    comicId: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    cover: comic.cover
  }
}

function normalizeReaderMode(value: unknown): ReaderMode {
  return readerModeOptions.some((option) => option.key === value)
    ? (value as ReaderMode)
    : 'galleryLeftToRight'
}

function readerModeClassName(mode: ReaderMode) {
  const direction = mode.endsWith('RightToLeft') ? ' rtl' : ''
  if (mode.startsWith('gallery')) return `reader-mode-gallery${direction}`
  if (mode === 'continuousTopToBottom') return 'reader-mode-continuous-vertical'
  return `reader-mode-continuous-horizontal${direction}`
}

type SearchPreset = { sourceKey: string; keyword: string } | null

export default function App() {
  const [activeTab, setActiveTab] = useState<TabKey>('home')
  const [activePrimaryTab, setActivePrimaryTab] = useState<PrimaryTabKey>('home')
  const [route, setRoute] = useState<AppRoute>({ kind: 'main' })
  const [data, setData] = useState<AppData>(emptyData)
  const [loading, setLoading] = useState(true)
  const [loadingMoreLibrary, setLoadingMoreLibrary] = useState<'history' | 'favorites' | null>(null)
  const [activeFavoriteFolder, setActiveFavoriteFolder] = useState<string | null>(null)
  const [activeFollowFolder, setActiveFollowFolder] = useState<string | null>(null)
  const [loadingFollowUpdates, setLoadingFollowUpdates] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [lastUpdated, setLastUpdated] = useState<string | null>(null)
  const [searchPreset, setSearchPreset] = useState<SearchPreset>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [health, settings, sources, library, tasks] = await Promise.all([
        getHealth(),
        getSettings(),
        getSources(),
        getLibrary(),
        getTasks()
      ])
      const followFolder = storedFollowFolder(settings, library.favorite_folders)
      const followUpdates = followFolder
        ? await getFollowUpdates({ folder: followFolder })
        : emptyFollowUpdates(null)
      setData({ health, settings, sources, library, followUpdates, tasks: tasks.tasks })
      setActiveFavoriteFolder(null)
      setActiveFollowFolder(followFolder)
      setLastUpdated(new Date().toLocaleTimeString('zh-CN', { hour12: false }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '服务端请求失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const themeMode = useMemo(() => {
    const value = data.settings?.values.themeMode
    return typeof value === 'string' ? value : 'system'
  }, [data.settings])
  const readerMode = useMemo(
    () => normalizeReaderMode(data.settings?.values.readerMode),
    [data.settings]
  )

  useEffect(() => {
    document.documentElement.dataset.theme = themeMode === 'dark' ? 'dark' : 'light'
  }, [themeMode])

  const setThemeMode = async (value: string) => {
    const next = await updateSettings({ themeMode: value })
    setData((current) => ({ ...current, settings: next }))
  }

  const setReaderMode = async (value: ReaderMode) => {
    const next = await updateSettings({ readerMode: value })
    setData((current) => ({ ...current, settings: next }))
  }

  const upsertSource = async (file: File) => {
    const content = await file.text()
    const source = await saveSource({ file_name: file.name, content })
    setData((current) => ({
      ...current,
      sources: [source, ...current.sources.filter((item) => item.key !== source.key)]
    }))
  }

  const removeSource = async (key: string) => {
    await deleteSource(key)
    setData((current) => ({
      ...current,
      sources: current.sources.filter((item) => item.key !== key)
    }))
  }

  const toggleSource = async (key: string, enabled: boolean) => {
    const source = await updateSource(key, { enabled })
    setData((current) => ({
      ...current,
      sources: current.sources.map((item) => (item.key === key ? source : item))
    }))
  }

  const saveHistory = useCallback(async (payload: HistoryWriteRequest) => {
    const library = await recordHistory(payload)
    setData((current) => ({
      ...current,
      library: {
        ...library,
        history: mergeLibraryItems(library.history, current.library.history),
        favorites:
          current.library.favorites.length > library.favorites.length
            ? current.library.favorites
            : library.favorites
      }
    }))
  }, [])

  const saveFavorite = async (payload: FavoriteWriteRequest) => {
    const library = await setFavorite(payload)
    setData((current) => ({
      ...current,
      library: {
        ...library,
        history:
          current.library.history.length > library.history.length
            ? current.library.history
            : library.history,
        favorites: payload.favorite
          ? mergeLibraryItems(library.favorites, current.library.favorites)
          : current.library.favorites.filter(
              (item) => item.source_key !== payload.source_key || item.comic_id !== payload.comic_id
            )
      }
    }))
  }

  const loadMoreLibrary = async (kind: 'history' | 'favorites') => {
    setLoadingMoreLibrary(kind)
    setError(null)
    try {
      const library = await getLibrary({
        history_limit: kind === 'history' ? libraryPageStep : 0,
        history_offset: kind === 'history' ? data.library.history.length : 0,
        favorites_limit: kind === 'favorites' ? libraryPageStep : 0,
        favorites_offset: kind === 'favorites' ? data.library.favorites.length : 0,
        favorite_folder: kind === 'favorites' && activeFavoriteFolder ? activeFavoriteFolder : undefined
      })
      setData((current) => ({
        ...current,
        library: {
          ...library,
          history:
            kind === 'history'
              ? mergeLibraryItems(current.library.history, library.history)
              : current.library.history,
          favorites:
            kind === 'favorites'
              ? mergeLibraryItems(current.library.favorites, library.favorites)
              : current.library.favorites
        }
      }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '资料库加载失败')
    } finally {
      setLoadingMoreLibrary(null)
    }
  }

  const selectFavoriteFolder = async (folder: string | null) => {
    setActiveFavoriteFolder(folder)
    setLoadingMoreLibrary('favorites')
    setError(null)
    setData((current) => ({
      ...current,
      library: {
        ...current.library,
        favorites: [],
        favorites_window_total: 0
      }
    }))
    try {
      const library = await getLibrary({
        history_limit: 0,
        favorites_limit: 50,
        favorites_offset: 0,
        favorite_folder: folder ?? undefined
      })
      setData((current) => ({
        ...current,
        library: {
          ...library,
          history: current.library.history
        }
      }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '收藏文件夹加载失败')
    } finally {
      setLoadingMoreLibrary(null)
    }
  }

  const selectFollowFolder = async (folder: string | null) => {
    setActiveFollowFolder(folder)
    setLoadingFollowUpdates(true)
    setError(null)
    try {
      const [settings, followUpdates] = await Promise.all([
        updateSettings({ followUpdatesFolder: folder }),
        folder ? getFollowUpdates({ folder }) : Promise.resolve(emptyFollowUpdates(null))
      ])
      setData((current) => ({ ...current, settings, followUpdates }))
      setLastUpdated(new Date().toLocaleTimeString('zh-CN', { hour12: false }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '追更文件夹加载失败')
    } finally {
      setLoadingFollowUpdates(false)
    }
  }

  const handleCreateFolder = async (title: string) => {
    const name = title.trim().replace(/\s+/g, '_').toLowerCase() || Date.now().toString(36)
    const response = await createFavoriteFolder({ name, title: title.trim() })
    setData((current) => ({
      ...current,
      library: { ...current.library, favorite_folders: response.folders }
    }))
  }

  const handleDeleteFolder = async (name: string) => {
    await deleteFavoriteFolder(name)
    if (activeFavoriteFolder === name) {
      setActiveFavoriteFolder(null)
    }
    if (activeFollowFolder === name) {
      setActiveFollowFolder(null)
    }
    setData((current) => {
      const folders = current.library.favorite_folders.filter((f) => f.name !== name)
      return {
        ...current,
        library: { ...current.library, favorite_folders: folders }
      }
    })
  }

  const refreshTasks = useCallback(async () => {
    const response = await getTasks()
    setData((current) => ({ ...current, tasks: response.tasks }))
    return response.tasks
  }, [])

  const refreshFollowFolder = async (folder: string) => {
    try {
      const followUpdates = await getFollowUpdates({ folder })
      setData((current) => ({ ...current, followUpdates }))
      setLastUpdated(new Date().toLocaleTimeString('zh-CN', { hour12: false }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '追更刷新失败')
      throw err
    }
  }

  const refreshFollowUpdates = async () => {
    if (!activeFollowFolder) return
    setLoadingFollowUpdates(true)
    setError(null)
    try {
      await refreshFollowFolder(activeFollowFolder)
    } finally {
      setLoadingFollowUpdates(false)
    }
  }

  const pollFollowTask = async (taskId: string, folder: string) => {
    try {
      for (let attempt = 0; attempt < 240; attempt += 1) {
        await delay(2000)
        const tasks = await refreshTasks()
        const task = tasks.find((item) => item.id === taskId)
        if (!task || task.status !== 'running') {
          await refreshFollowFolder(folder)
          return
        }
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '追更任务轮询失败')
    }
  }

  const checkFollowUpdates = async () => {
    if (!activeFollowFolder) return
    setLoadingFollowUpdates(true)
    setError(null)
    try {
      const task = await startFollowUpdatesCheck({ folder: activeFollowFolder, force: true })
      setData((current) => ({ ...current, tasks: mergeTasks(current.tasks, task) }))
      if (task.status === 'running') void pollFollowTask(task.id, activeFollowFolder)
    } catch (err) {
      setError(err instanceof Error ? err.message : '追更检查启动失败')
    } finally {
      setLoadingFollowUpdates(false)
    }
  }

  const markFollowUpdatesAsRead = async () => {
    if (!activeFollowFolder) return
    setLoadingFollowUpdates(true)
    setError(null)
    try {
      const followUpdates = await markFollowUpdatesRead({ folder: activeFollowFolder })
      setData((current) => ({ ...current, followUpdates }))
      setLastUpdated(new Date().toLocaleTimeString('zh-CN', { hour12: false }))
    } catch (err) {
      setError(err instanceof Error ? err.message : '追更标记失败')
    } finally {
      setLoadingFollowUpdates(false)
    }
  }

  const openTab = (tab: TabKey) => {
    if (isPrimaryTabKey(tab)) setActivePrimaryTab(tab)
    setActiveTab(tab)
    setRoute({ kind: 'main' })
  }

  const closeStandalonePage = () => {
    setActiveTab(activePrimaryTab)
    setRoute({ kind: 'main' })
  }

  const openDetail = (request: ComicOpenRequest) => {
    setRoute({ kind: 'detail', request })
  }

  const openReader = (request: ReaderOpenRequest) => {
    setRoute({ kind: 'reader', request })
  }

  const backToDetailFromReader = (request: ReaderOpenRequest) => {
    setRoute({
      kind: 'detail',
      request: {
        sourceKey: request.sourceKey,
        comicId: request.comic.id,
        title: request.comic.title,
        subtitle: request.comic.subtitle,
        cover: request.comic.cover,
        initialComic: request.comic
      }
    })
  }

  if (route.kind === 'reader') {
    return (
      <ReaderPage
        request={route.request}
        readerMode={readerMode}
        onBack={() => backToDetailFromReader(route.request)}
        onRecordHistory={saveHistory}
      />
    )
  }

  const showRootChrome = route.kind === 'main' && isPrimaryTabKey(activeTab)
  const activeFollowTask = data.tasks.find(
    (task) =>
      task.kind === 'follow_updates' &&
      task.status === 'running' &&
      taskPayloadText(task, 'folder') === activeFollowFolder
  )

  return (
    <ThemeProvider
      colorSetting={typeof data.settings?.values.color === 'string' ? data.settings.values.color : 'blue'}
      themeMode={(themeMode === 'light' || themeMode === 'dark') ? themeMode : 'system'}
    >
      <SnackbarHost>
        <div className="app-shell">
          <SideNav activeTab={activePrimaryTab} onSelect={openTab} />
          <main className="main-area">
        {showRootChrome ? (
          <TopBar
            activeTab={activePrimaryTab}
            health={data.health}
            loading={loading}
            error={error}
            lastUpdated={lastUpdated}
            onRefresh={load}
            onSelect={openTab}
          />
        ) : null}
        <div className={showRootChrome ? 'content' : 'content content-page'}>
          {route.kind === 'detail' ? (
            <ComicDetailPage
              request={route.request}
              favorites={data.library.favorites}
              onBack={() => setRoute({ kind: 'main' })}
              onOpenReader={openReader}
              onSetFavorite={saveFavorite}
              onSearchTag={(sourceKey, tag) => {
                setSearchPreset({ sourceKey, keyword: tag })
                setActiveTab('search')
                setActivePrimaryTab('search' as PrimaryTabKey)
                setRoute({ kind: 'main' })
              }}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'home' ? (
            <HomeView
              data={data}
              error={error}
              onOpenTab={openTab}
              onOpenComic={openDetail}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'history' ? (
            <LibraryView
              title="历史记录"
              icon={History}
              items={data.library.history}
              total={data.library.history_total}
              emptyText="暂无阅读记录"
              standalone
              loadingMore={loadingMoreLibrary === 'history'}
              onBack={closeStandalonePage}
              onLoadMore={
                data.library.history.length < data.library.history_total
                  ? () => loadMoreLibrary('history')
                  : undefined
              }
              onOpenComic={openDetail}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'favorites' ? (
            <FavoritesView
              items={data.library.favorites}
              total={data.library.favorites_window_total}
              allTotal={data.library.favorites_total}
              folders={data.library.favorite_folders}
              activeFolder={activeFavoriteFolder}
              loadingFolder={loadingMoreLibrary === 'favorites' && data.library.favorites.length === 0}
              loadingMore={loadingMoreLibrary === 'favorites'}
              onFolderSelect={selectFavoriteFolder}
              onLoadMore={
                data.library.favorites.length < data.library.favorites_window_total
                  ? () => loadMoreLibrary('favorites')
                  : undefined
              }
              onOpenComic={openDetail}
              onCreateFolder={handleCreateFolder}
              onDeleteFolder={handleDeleteFolder}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'explore' ? (
            <SourcePagesView
              title="发现"
              icon={Compass}
              kind="explore"
              onOpenComic={openDetail}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'categories' ? (
            <SourcePagesView
              title="分类"
              icon={Tags}
              kind="categories"
              onOpenComic={openDetail}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'updates' ? (
            <UpdatesView
              data={data.followUpdates}
              folders={data.library.favorite_folders}
              activeFolder={activeFollowFolder}
              loading={loadingFollowUpdates}
              task={activeFollowTask ?? null}
              onBack={closeStandalonePage}
              onFolderSelect={selectFollowFolder}
              onRefresh={refreshFollowUpdates}
              onCheck={checkFollowUpdates}
              onMarkRead={markFollowUpdatesAsRead}
              onOpenComic={openDetail}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'search' ? (
            <SearchView
              sources={data.sources}
              onBack={closeStandalonePage}
              onSourceUpload={upsertSource}
              onSourceDelete={removeSource}
              onSourceToggle={toggleSource}
              onOpenComic={openDetail}
              preset={searchPreset}
              onConsumePreset={() => setSearchPreset(null)}
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'tasks' ? (
            <TasksView tasks={data.tasks} onBack={closeStandalonePage} onRefresh={refreshTasks} />
          ) : null}
          {route.kind === 'main' && activeTab === 'settings' ? (
            <SettingsView
              settings={data.settings}
              themeMode={themeMode}
              readerMode={readerMode}
              sources={data.sources}
              onBack={closeStandalonePage}
              onThemeChange={setThemeMode}
              onReaderModeChange={setReaderMode}
              onImportComplete={load}
            />
          ) : null}
        </div>
      </main>
      {showRootChrome ? <BottomNav activeTab={activePrimaryTab} onSelect={openTab} /> : null}
      <ReloadPrompt />
        </div>
      </SnackbarHost>
    </ThemeProvider>
  )
}

function SideNav({
  activeTab,
  onSelect
}: {
  activeTab: PrimaryTabKey
  onSelect: (tab: TabKey) => void
}) {
  return (
    <aside className="side-nav" aria-label="主导航">
      <div className="brand-mark" aria-label="Venera">
        V
      </div>
      <nav className="nav-stack">
        {primaryNav.map((item) => (
          <NavButton key={item.key} item={item} active={activeTab === item.key} onSelect={onSelect} />
        ))}
      </nav>
      <nav className="nav-stack nav-stack-actions">
        {actionNav.map((item) => (
          <NavButton key={item.key} item={item} active={false} onSelect={onSelect} />
        ))}
      </nav>
    </aside>
  )
}

function BottomNav({
  activeTab,
  onSelect
}: {
  activeTab: PrimaryTabKey
  onSelect: (tab: TabKey) => void
}) {
  return (
    <nav className="bottom-nav" aria-label="底部导航">
      {primaryNav.map((item) => (
        <NavButton key={item.key} item={item} active={activeTab === item.key} onSelect={onSelect} />
      ))}
    </nav>
  )
}

function NavButton({
  item,
  active,
  onSelect
}: {
  item: { key: TabKey; label: string; icon: typeof Home }
  active: boolean
  onSelect: (tab: TabKey) => void
}) {
  const Icon = item.icon
  return (
    <button
      className={active ? 'nav-button active' : 'nav-button'}
      type="button"
      aria-current={active ? 'page' : undefined}
      onClick={() => onSelect(item.key)}
      title={item.label}
    >
      <Icon size={22} />
      <span>{item.label}</span>
    </button>
  )
}

function TopBar({
  activeTab,
  health,
  loading,
  error,
  lastUpdated,
  onRefresh,
  onSelect
}: {
  activeTab: PrimaryTabKey
  health: HealthResponse | null
  loading: boolean
  error: string | null
  lastUpdated: string | null
  onRefresh: () => void
  onSelect: (tab: TabKey) => void
}) {
  const isNormal =
    health?.status === 'ok' &&
    health.database === 'sqlite' &&
    health.data_dir.trim().length > 0 &&
    health.source_runtime &&
    !error
  const activeLabel = navigationItems.find((item) => item.key === activeTab)?.label ?? 'Venera'

  return (
    <header className="top-bar">
      <div>
        <h1>{activeLabel}</h1>
        <p>{isNormal ? `服务端 ${health.version}` : '服务或数据异常'}</p>
      </div>
      <div className="top-actions">
        {actionNav.map((item) => {
          const Icon = item.icon
          return (
            <button
              className="top-action-button"
              key={item.key}
              type="button"
              title={item.label}
              aria-label={item.label}
              onClick={() => onSelect(item.key)}
            >
              <Icon size={20} />
            </button>
          )
        })}
        <StatusPill ok={isNormal} text={isNormal ? '正常' : '异常'} />
        {lastUpdated ? <span className="muted-text">{lastUpdated}</span> : null}
        <button className="icon-button" type="button" onClick={onRefresh} aria-label="刷新">
          {loading ? <Loader2 className="spin" size={18} /> : <RefreshCw size={18} />}
        </button>
      </div>
    </header>
  )
}

function HomeView({
  data,
  error,
  onOpenTab,
  onOpenComic
}: {
  data: AppData
  error: string | null
  onOpenTab: (tab: TabKey) => void
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  return (
    <div className="view-stack">
      <button
        className="search-strip app-page-search"
        aria-label="搜索"
        type="button"
        onClick={() => onOpenTab('search')}
      >
        <Search size={20} />
        <span style={{ color: 'var(--muted)', textAlign: 'left', flex: 1 }}>搜索漫画</span>
        <span className="primary-button" style={{ pointerEvents: 'none' }}>
          搜索
        </span>
      </button>

      {error ? (
        <section className="notice error">
          <WifiOff size={18} />
          <span>{error}</span>
        </section>
      ) : null}

      <section className="sync-card">
        <RefreshCw size={20} />
        <div>
          <strong>同步数据</strong>
          <span>WebDAV 支持手动下载和备份上传，默认不自动上传</span>
        </div>
        <StatusPill ok={data.health?.status === 'ok' && !error} text={data.health?.status === 'ok' && !error ? '正常' : '异常'} />
      </section>

      <section className="home-card-list">
        <HomeCard
          title="历史记录"
          count={data.library.history_total}
          icon={History}
          onOpen={() => onOpenTab('history')}
        >
          <ComicStrip
            items={data.library.history.slice(0, 8)}
            emptyText="暂无阅读记录"
            onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
          />
        </HomeCard>
        <HomeCard
          title="追更"
          count={data.followUpdates.updated_total}
          icon={RefreshCw}
          onOpen={() => onOpenTab('updates')}
        >
          <ComicStrip
            items={data.followUpdates.updated.slice(0, 8)}
            emptyText={
              data.followUpdates.all_total > 0
                ? `已跟踪 ${data.followUpdates.all_total} 部，暂无更新`
                : '暂无更新任务'
            }
            icon={RefreshCw}
            onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
          />
        </HomeCard>
        <HomeCard
          title="漫画源"
          count={data.sources.length}
          icon={Library}
          onOpen={() => onOpenTab('search')}
        >
          <SourceChips sources={data.sources.slice(0, 12)} />
        </HomeCard>
      </section>
    </div>
  )
}

function HomeCard({
  title,
  count,
  icon: Icon,
  onOpen,
  children
}: {
  title: string
  count: number
  icon: typeof Home
  onOpen: () => void
  children: React.ReactNode
}) {
  return (
    <section className="home-card">
      <button className="home-card-header" type="button" onClick={onOpen}>
        <Icon size={20} />
        <strong>{title}</strong>
        <span>{count}</span>
        <ChevronRight size={20} />
      </button>
      {children}
    </section>
  )
}

function ComicStrip({
  items,
  emptyText,
  icon: Icon = BookOpen,
  onSelect
}: {
  items: LibraryItem[]
  emptyText: string
  icon?: typeof Home
  onSelect?: (item: LibraryItem) => void
}) {
  if (items.length === 0) {
    return (
      <div className="home-card-empty">
        <EmptyLine icon={Icon} text={emptyText} />
      </div>
    )
  }

  return (
    <div className="comic-strip">
      {items.map((item) => (
        <ComicTile key={libraryItemKey(item)} item={item} compact onSelect={onSelect} />
      ))}
    </div>
  )
}

function SourceChips({ sources }: { sources: SourceSummary[] }) {
  if (sources.length === 0) {
    return (
      <div className="home-card-empty">
        <EmptyLine icon={Library} text="暂无源文件" />
      </div>
    )
  }

  return (
    <div className="source-chip-list">
      {sources.map((source) => (
        <span className="source-chip" key={source.key}>
          {source.name}
        </span>
      ))}
    </div>
  )
}

function PageHeader({
  title,
  onBack,
  actions
}: {
  title: string
  onBack?: () => void
  actions?: React.ReactNode
}) {
  return (
    <header className="page-header">
      <button className="icon-button" type="button" aria-label="返回" onClick={onBack}>
        <ChevronLeft size={20} />
      </button>
      <h1>{title}</h1>
      <div className="page-header-actions">{actions ?? <span />}</div>
    </header>
  )
}

function LoadMoreSentinel({
  loading,
  onLoadMore,
  label
}: {
  loading: boolean
  onLoadMore?: () => void
  label?: string
}) {
  const ref = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!onLoadMore || loading) return
    const node = ref.current
    if (!node) return
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) onLoadMore()
      },
      { rootMargin: '360px 0px' }
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [loading, onLoadMore])

  if (!onLoadMore && !loading) return null

  return (
    <div className="load-more-sentinel" ref={ref}>
      {loading ? <Loader2 size={16} className="spin" /> : <RefreshCw size={16} />}
      <span>{loading ? '加载中' : label ? `继续加载 ${label}` : '继续加载'}</span>
    </div>
  )
}

function ComicDetailPage({
  request,
  favorites,
  onBack,
  onOpenReader,
  onSetFavorite,
  onSearchTag
}: {
  request: ComicOpenRequest
  favorites: LibraryItem[]
  onBack: () => void
  onOpenReader: (request: ReaderOpenRequest) => void
  onSetFavorite: (payload: FavoriteWriteRequest) => Promise<void>
  onSearchTag?: (sourceKey: string, tag: string) => void
}) {
  const [comic, setComic] = useState<ComicInfo | null>(request.initialComic ?? null)
  const [loading, setLoading] = useState(!request.initialComic)
  const [message, setMessage] = useState<string | null>(null)
  const [favoriteBusy, setFavoriteBusy] = useState(false)
  const [descriptionExpanded, setDescriptionExpanded] = useState(false)
  const [chaptersReversed, setChaptersReversed] = useState(false)
  const [readingProgress, setReadingProgress] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setComic(request.initialComic ?? null)
    setLoading(!request.initialComic)
    setMessage(null)
    setDescriptionExpanded(false)
    setChaptersReversed(false)
    setReadingProgress(null)
    if (request.initialComic) return
    void getComicInfo(request.sourceKey, request.comicId)
      .then((response) => {
        if (cancelled) return
        setComic(response.comic)
        setMessage(response.comic.episodes.length === 0 ? '暂无章节' : null)
      })
      .catch((err) => {
        if (!cancelled) setMessage(err instanceof Error ? err.message : '详情加载失败')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [request.comicId, request.initialComic, request.sourceKey])

  useEffect(() => {
    if (!comic) return
    const item = favorites.find(
      (fav) => fav.source_key === request.sourceKey && fav.comic_id === comic.id
    )
    setReadingProgress(item?.episode_title ?? null)
  }, [favorites, comic, request.sourceKey])

  const isFavorite = Boolean(
    comic && favorites.some((item) => item.source_key === request.sourceKey && item.comic_id === comic.id)
  )
  const firstEpisode = comic?.episodes[0]
  const detailRows = comic ? comicInfoRows(comic, request.sourceKey, readingProgress) : []
  const orderedEpisodes = comic
    ? chaptersReversed
      ? [...comic.episodes].reverse()
      : comic.episodes
    : []

  const toggleFavorite = async () => {
    if (!comic || favoriteBusy) return
    setFavoriteBusy(true)
    try {
      await onSetFavorite({
        source_key: request.sourceKey,
        comic_id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        cover: comic.cover,
        favorite: !isFavorite
      })
    } catch (err) {
      setMessage(err instanceof Error ? err.message : '收藏更新失败')
    } finally {
      setFavoriteBusy(false)
    }
  }

  const handleTagClick = (tag: string) => {
    onSearchTag?.(request.sourceKey, tag)
  }

  const openEpisode = (episode: ComicEpisode) => {
    if (!comic) return
    onOpenReader({ sourceKey: request.sourceKey, comic, episode })
  }

  const tags = comic?.tags ?? []
  const tagChips = tags.length > 0 ? (
    <div className="metadata-chips">
      {tags.map((tag) => (
        <span
          key={tag}
          role="button"
          tabIndex={0}
          onClick={() => handleTagClick(tag)}
          onKeyDown={(e) => { if (e.key === 'Enter') handleTagClick(tag) }}
          style={{ cursor: 'pointer' }}
        >
          {tag}
        </span>
      ))}
    </div>
  ) : null

  return (
    <article className="comic-detail-page">
      <PageHeader
        title={comic?.title ?? request.title}
        onBack={onBack}
      />
      {loading ? <EmptyLine icon={Loader2} text="加载详情中" /> : null}
      {!loading && !comic ? <EmptyLine icon={BookOpen} text={message ?? '详情加载失败'} /> : null}
      {comic ? (
        <>
          <section className="detail-hero">
            <CoverImage url={comic.cover ?? request.cover} iconSize={28} />
            <div className="detail-hero-main">
              <h2>{comic.title}</h2>
              {comic.subtitle ? <p>{comic.subtitle}</p> : null}
              {tagChips}
              <ComicMetaRows rows={detailRows} />
            </div>
          </section>
          <section className="detail-action-row" aria-label="漫画操作">
            {firstEpisode ? (
              <button className="detail-action primary" type="button" onClick={() => openEpisode(firstEpisode)}>
                <Play size={18} />
                <span>开始</span>
              </button>
            ) : null}
            <button
              className={isFavorite ? 'detail-action active' : 'detail-action'}
              type="button"
              disabled={favoriteBusy}
              onClick={toggleFavorite}
            >
              <Heart size={18} fill={isFavorite ? 'currentColor' : 'none'} />
              <span>{isFavorite ? '已收藏' : '收藏'}</span>
            </button>
            <button
              className="detail-action"
              type="button"
              onClick={() => {
                const desc = comic.description ? `${comic.title}\n${comic.subtitle ?? ''}\n${comic.description}` : `${comic.title}\n${comic.subtitle ?? ''}`
                navigator.clipboard?.writeText(desc).catch(() => {})
              }}
            >
              <Save size={18} />
              <span>复制</span>
            </button>
          </section>
          {message ? <EmptyLine icon={BookOpen} text={message} /> : null}
          {comic.description ? (
            <section className="detail-section">
              <div className="detail-section-header">
                <h3>简介</h3>
              </div>
              <p className={descriptionExpanded ? 'detail-description expanded' : 'detail-description'}>
                {comic.description}
              </p>
              {(comic.description.length > 80) ? (
                <button
                  className="detail-expand-button"
                  type="button"
                  onClick={() => setDescriptionExpanded((value) => !value)}
                >
                  <ChevronDown className={descriptionExpanded ? 'rotated' : ''} size={18} />
                  <span>{descriptionExpanded ? '收起' : '展开'}</span>
                </button>
              ) : null}
            </section>
          ) : null}
          <section className="detail-section">
            <div className="detail-section-header">
              <h3>章节</h3>
              <button
                className="icon-button"
                type="button"
                aria-label="章节排序"
                title="章节排序"
                onClick={() => setChaptersReversed((value) => !value)}
              >
                <ChevronDown className={chaptersReversed ? 'rotated' : ''} size={18} />
              </button>
            </div>
            {comic.episodes.length === 0 ? (
              <EmptyLine icon={BookOpen} text="暂无章节" />
            ) : (
              <div className="chapter-grid">
                {orderedEpisodes.map((episode) => (
                  <button key={episode.id} className="chapter-cell" type="button" onClick={() => openEpisode(episode)}>
                    {episode.title}
                  </button>
                ))}
              </div>
            )}
          </section>
        </>
      ) : null}
    </article>
  )
}

function ReaderPage({
  request,
  readerMode,
  onBack,
  onRecordHistory
}: {
  request: ReaderOpenRequest
  readerMode: ReaderMode
  onBack: () => void
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [images, setImages] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState<string | null>(null)
  const [pageIndex, setPageIndex] = useState(0)
  const [chromeOpen, setChromeOpen] = useState(true)
  const isGalleryMode = readerMode.startsWith('gallery')
  const isRTL = readerMode.endsWith('RightToLeft')
  const activePageIndex = images.length === 0 ? 0 : Math.min(pageIndex, images.length - 1)
  const visibleImages = isGalleryMode ? images.slice(activePageIndex, activePageIndex + 1) : images

  const currentEpIndex = request.comic.episodes.findIndex((ep) => ep.id === request.episode.id)
  const prevEpisode = currentEpIndex > 0 ? request.comic.episodes[currentEpIndex - 1] : null
  const nextEpisode = currentEpIndex < request.comic.episodes.length - 1 ? request.comic.episodes[currentEpIndex + 1] : null

  const loadEpisode = useCallback((episode: ComicEpisode) => {
    setLoading(true)
    setMessage(null)
    setImages([])
    setPageIndex(0)
    void getComicPages(request.sourceKey, request.comic.id, episode.id)
      .then(async (response) => {
        setImages(response.images)
        setMessage(response.images.length === 0 ? '暂无图片' : null)
        if (response.images.length > 0) {
          await onRecordHistory({
            source_key: request.sourceKey,
            comic_id: request.comic.id,
            title: request.comic.title,
            subtitle: request.comic.subtitle,
            cover: request.comic.cover,
            episode_id: episode.id,
            episode_title: episode.title
          })
        }
      })
      .catch((err) => {
        setMessage(err instanceof Error ? err.message : '章节加载失败')
      })
      .finally(() => {
        setLoading(false)
      })
  }, [onRecordHistory, request.comic, request.sourceKey])

  useEffect(() => {
    loadEpisode(request.episode)
  }, [request.episode.id, loadEpisode])

  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onBack()
        return
      }
      if (!isGalleryMode || images.length === 0) return
      if (event.key === 'ArrowLeft') {
        setPageIndex((current) => isRTL ? Math.min(images.length - 1, current + 1) : Math.max(0, current - 1))
      } else if (event.key === 'ArrowRight') {
        setPageIndex((current) => isRTL ? Math.max(0, current - 1) : Math.min(images.length - 1, current + 1))
      }
    }
    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [isGalleryMode, isRTL, images.length, onBack])

  const readerModeLabel = readerModeOptions.find((option) => option.key === readerMode)?.label
  const goToPrev = () => { if (prevEpisode) loadEpisode(prevEpisode) }
  const goToNext = () => { if (nextEpisode) loadEpisode(nextEpisode) }

  return (
    <main className={`reader-page ${readerModeClassName(readerMode)}`} tabIndex={0}>
      <div className="reader-stage" onClick={() => setChromeOpen((value) => !value)}>
        {loading ? <EmptyLine icon={Loader2} text="加载章节中" /> : null}
        {message && images.length === 0 ? <EmptyLine icon={BookOpen} text={message} /> : null}
        {images.length > 0 ? (
          <div className="reader-image-list">
            {visibleImages.map((image, index) => (
              <img
                key={`${image}-${index}`}
                src={imageProxyUrl(image)}
                alt={`第 ${isGalleryMode ? activePageIndex + 1 : index + 1} 页`}
                loading={index < 2 ? 'eager' : 'lazy'}
              />
            ))}
          </div>
        ) : null}
      </div>
      <header className={chromeOpen ? 'reader-top open' : 'reader-top'}>
        <button className="icon-button" type="button" aria-label="返回" onClick={onBack}>
          <ChevronLeft size={20} />
        </button>
        <div>
          <strong>{request.comic.title}</strong>
          <span>{request.episode.title}</span>
        </div>
        <div style={{ display: 'flex', gap: '4px' }}>
          {prevEpisode ? (
            <button className="icon-button" type="button" aria-label="上一章" title={prevEpisode.title} onClick={goToPrev}>
              <ChevronLeft size={20} />
            </button>
          ) : null}
          {nextEpisode ? (
            <button className="icon-button" type="button" aria-label="下一章" title={nextEpisode.title} onClick={goToNext}>
              <ChevronRight size={20} />
            </button>
          ) : null}
        </div>
      </header>
      <footer className={chromeOpen ? 'reader-bottom open' : 'reader-bottom'}>
        <button
          className="icon-button"
          type="button"
          disabled={!isGalleryMode || activePageIndex === 0}
          onClick={() => setPageIndex((current) => Math.max(0, current - 1))}
        >
          <ChevronLeft size={18} />
        </button>
        <div className="reader-progress">
          <span>{isGalleryMode ? `${activePageIndex + 1}/${images.length || 1}` : `${images.length} 张`}</span>
          <small>{readerModeLabel}</small>
        </div>
        <button
          className="icon-button"
          type="button"
          disabled={!isGalleryMode || activePageIndex >= images.length - 1}
          onClick={() => setPageIndex((current) => Math.min(images.length - 1, current + 1))}
        >
          <ChevronRight size={18} />
        </button>
      </footer>
    </main>
  )
}

const SEARCH_HISTORY_KEY = 'venera_search_history'
const MAX_SEARCH_HISTORY = 50

function loadSearchHistory(): string[] {
  try {
    const raw = localStorage.getItem(SEARCH_HISTORY_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.filter((v) => typeof v === 'string' && v.trim()) : []
  } catch {
    return []
  }
}

function saveSearchHistory(history: string[]) {
  localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(history.slice(0, MAX_SEARCH_HISTORY)))
}

function SearchView({
  sources,
  onBack,
  onSourceUpload,
  onSourceDelete,
  onSourceToggle,
  onOpenComic,
  preset,
  onConsumePreset
}: {
  sources: SourceSummary[]
  onBack: () => void
  onSourceUpload: (file: File) => Promise<void>
  onSourceDelete: (key: string) => Promise<void>
  onSourceToggle: (key: string, enabled: boolean) => Promise<void>
  onOpenComic: (request: ComicOpenRequest) => void
  preset: SearchPreset
  onConsumePreset?: () => void
}) {
  const [keyword, setKeyword] = useState('')
  const [selectedSource, setSelectedSource] = useState('')
  const [aggregatedSearch, setAggregatedSearch] = useState(false)
  const [searching, setSearching] = useState(false)
  const [searchMessage, setSearchMessage] = useState<string | null>(null)
  const [results, setResults] = useState<SearchComic[]>([])
  const [resultSource, setResultSource] = useState('')
  const [resultPage, setResultPage] = useState(1)
  const [resultMaxPage, setResultMaxPage] = useState<number | null>(null)
  const [loadingMore, setLoadingMore] = useState(false)
  const [searchHistory, setSearchHistory] = useState<string[]>(() => loadSearchHistory())
  const [sourceMessage, setSourceMessage] = useState<string | null>(null)
  const enabledSources = useMemo(
    () => sources.filter((source) => source.enabled && source.runtime_status === 'registered'),
    [sources]
  )

  useEffect(() => {
    if (selectedSource && enabledSources.some((source) => source.key === selectedSource)) return
    const nextSource = enabledSources[0]?.key ?? ''
    setSelectedSource(nextSource)
    setResults([])
    setSearchMessage(null)
    if (!nextSource) {
      setKeyword('')
    }
  }, [enabledSources, selectedSource])

  const presetRef = useRef(preset)
  presetRef.current = preset

  useEffect(() => {
    const current = presetRef.current
    if (!current) return
    if (!enabledSources.some((source) => source.key === current.sourceKey)) return

    setSelectedSource(current.sourceKey)
    setAggregatedSearch(false)
    setKeyword(current.keyword)
    setResults([])
    setSearchMessage(null)
    setResultPage(1)
    setResultMaxPage(null)
    onConsumePreset?.()

    void (async () => {
      setSearching(true)
      try {
        const response = await searchComics(current.sourceKey, current.keyword, 1)
        setResults(response.comics)
        setResultSource(current.sourceKey)
        addToHistory(current.keyword)
        setSearchMessage(response.comics.length === 0 ? '没有结果' : null)
      } catch (err) {
        setSearchMessage(err instanceof Error ? err.message : '搜索失败')
      } finally {
        setSearching(false)
      }
    })()
    // Only run when preset changes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preset])

  const handleSourceChange = (key: string) => {
    setSelectedSource(key)
    setAggregatedSearch(false)
    setResults([])
    setSearchMessage(null)
    setResultPage(1)
    setResultMaxPage(null)
  }

  const doSearch = async (text: string, sourceKey: string, page: number) => {
    if (aggregatedSearch) {
      const allResults: SearchComic[] = []
      for (const source of enabledSources) {
        try {
          const response = await searchComics(source.key, text, page)
          allResults.push(...response.comics)
        } catch {
          // skip failed sources in aggregated mode
        }
      }
      return { comics: allResults, max_page: null, next: null }
    }
    return searchComics(sourceKey, text, page)
  }

  const addToHistory = (text: string) => {
    setSearchHistory((prev) => {
      const next = [text, ...prev.filter((item) => item !== text)]
      saveSearchHistory(next)
      return next
    })
  }

  const removeFromHistory = (text: string) => {
    setSearchHistory((prev) => {
      const next = prev.filter((item) => item !== text)
      saveSearchHistory(next)
      return next
    })
  }

  const handleSearch = async (text?: string, page = 1) => {
    const value = (text ?? keyword).trim()
    if (!value || (!aggregatedSearch && !selectedSource)) return
    if (enabledSources.length === 0) return

    const sourceKey = aggregatedSearch ? enabledSources[0].key : selectedSource

    if (page === 1) {
      setSearching(true)
    } else {
      setLoadingMore(true)
    }
    setSearchMessage(null)
    try {
      const response = await doSearch(value, sourceKey, page)
      if (page === 1) {
        setResults(response.comics)
        setResultSource(sourceKey)
        addToHistory(value)
        setKeyword(value)
      } else {
        setResults((prev) => [...prev, ...response.comics])
      }
      setResultPage(page)
      setResultMaxPage(response.max_page)
      setSearchMessage(
        response.comics.length === 0 && page === 1 ? '没有结果' : null
      )
    } catch (err) {
      if (page === 1) {
        setResults([])
        setSearchMessage(err instanceof Error ? err.message : '搜索失败')
      }
    } finally {
      setSearching(false)
      setLoadingMore(false)
    }
  }

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    handleSearch(keyword, 1)
  }

  const handleLoadMore = () => {
    if (loadingMore || resultMaxPage == null || resultPage >= resultMaxPage) return
    handleSearch(keyword, resultPage + 1)
  }

  const handleFileChange = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file) return

    setSourceMessage('导入中')
    try {
      await onSourceUpload(file)
      setSourceMessage('导入完成')
    } catch (err) {
      setSourceMessage(err instanceof Error ? err.message : '导入失败')
    }
  }

  const handleDelete = async (key: string) => {
    setSourceMessage('删除中')
    try {
      await onSourceDelete(key)
      setSourceMessage('已删除')
    } catch (err) {
      setSourceMessage(err instanceof Error ? err.message : '删除失败')
    }
  }

  const handleToggle = async (key: string, enabled: boolean) => {
    setSourceMessage('更新中')
    try {
      await onSourceToggle(key, enabled)
      setSourceMessage(enabled ? '已启用' : '已停用')
    } catch (err) {
      setSourceMessage(err instanceof Error ? err.message : '更新失败')
    }
  }

  const hasResults = results.length > 0
  const hasMore = resultMaxPage != null && resultPage < resultMaxPage

  return (
    <div className="view-stack">
      <PageHeader title="搜索" onBack={onBack} />
      <form className="search-strip" aria-label="搜索" onSubmit={handleSubmit}>
        <Search size={20} />
        <input
          value={keyword}
          placeholder={enabledSources.length > 0 ? '关键词' : '先启用漫画源'}
          disabled={enabledSources.length === 0 || searching}
          onChange={(event) => setKeyword(event.target.value)}
        />
        <button className="primary-button" disabled={!keyword.trim() || searching || enabledSources.length === 0} type="submit">
          {searching ? '搜索中' : '搜索'}
        </button>
      </form>

      {enabledSources.length > 0 ? (
        <div className="source-chip-list" role="radiogroup" aria-label="漫画源">
          {enabledSources.map((source) => (
            <button
              key={source.key}
              className={source.key === selectedSource && !aggregatedSearch ? 'source-chip active' : 'source-chip'}
              type="button"
              role="radio"
              aria-checked={source.key === selectedSource && !aggregatedSearch}
              onClick={() => handleSourceChange(source.key)}
            >
              {source.name}
            </button>
          ))}
          <button
            className={aggregatedSearch ? 'source-chip active' : 'source-chip'}
            type="button"
            role="radio"
            aria-checked={aggregatedSearch}
            onClick={() => {
              setAggregatedSearch(true)
              setResults([])
              setSearchMessage(null)
              setResultPage(1)
              setResultMaxPage(null)
            }}
          >
            聚合搜索
          </button>
        </div>
      ) : null}

      {searchHistory.length > 0 && !hasResults ? (
        <Panel title="搜索历史" action={String(searchHistory.length)}>
          <div className="result-list">
            {searchHistory.map((item) => (
              <div className="result-row" key={item}>
                <button
                  className="library-row"
                  type="button"
                  onClick={() => handleSearch(item, 1)}
                  style={{ gridTemplateColumns: 'minmax(0, 1fr)' }}
                >
                  <div className="result-main">
                    <strong>{item}</strong>
                  </div>
                </button>
                <button
                  className="icon-button"
                  type="button"
                  aria-label={`删除 ${item}`}
                  onClick={() => removeFromHistory(item)}
                >
                  <Trash2 size={14} />
                </button>
              </div>
            ))}
          </div>
        </Panel>
      ) : null}

      {hasResults ? (
        <div className="source-list-content">
          <div className="source-section-title">
            <strong>搜索结果</strong>
            <span>{results.length}{resultMaxPage != null ? ` / 第 ${resultPage} 页` : ''}</span>
          </div>
          <div className="comic-grid">
            {results.map((comic) => (
              <button
                className="comic-tile"
                key={`${resultSource}:${comic.id}`}
                type="button"
                onClick={() => {
                  const sourceKey = aggregatedSearch ? resultSource : selectedSource
                  if (sourceKey) onOpenComic(searchComicToOpenRequest(sourceKey, comic))
                }}
              >
                <CoverImage url={comic.cover} iconSize={18} />
                <div className="comic-tile-main">
                  <strong>{comic.title}</strong>
                  <div className="comic-meta-rows">
                    {comic.subtitle ? (
                      <div className="comic-meta-row">
                        <span className="comic-meta-label blue">作者</span>
                        <span className="comic-meta-value">{comic.subtitle}</span>
                      </div>
                    ) : null}
                    {comic.tags.length > 0 ? (
                      <div className="comic-meta-row">
                        <span className="comic-meta-label pink">标签</span>
                        <span className="comic-meta-value">{comic.tags.slice(0, 4).join(', ')}</span>
                      </div>
                    ) : null}
                  </div>
                </div>
              </button>
            ))}
          </div>
          {hasMore ? (
            <LoadMoreSentinel loading={loadingMore} onLoadMore={handleLoadMore} />
          ) : null}
        </div>
      ) : null}

      {searchMessage && !hasResults ? (
        <EmptyLine icon={Search} text={searchMessage} />
      ) : null}

      {!hasResults && !searchMessage && searchHistory.length === 0 ? (
        <EmptyLine icon={Search} text="输入关键词开始搜索" />
      ) : null}

      <Panel title="源管理" action={String(sources.length)}>
        <div className="source-toolbar">
          <label className="icon-text-button">
            <Upload size={16} />
            导入 JS 源
            <input type="file" accept=".js,text/javascript" onChange={handleFileChange} />
          </label>
          {sourceMessage ? <span className="muted-text">{sourceMessage}</span> : null}
        </div>
        <SourceList sources={sources} onDelete={handleDelete} onToggle={handleToggle} />
      </Panel>
    </div>
  )
}

function SearchResults({
  comics,
  onSelect
}: {
  comics: SearchComic[]
  onSelect: (comic: SearchComic) => void
}) {
  if (comics.length === 0) {
    return <EmptyLine icon={Search} text="输入关键词开始搜索" />
  }

  return (
    <div className="result-list">
      {comics.map((comic) => (
        <button className="result-row" key={comic.id} type="button" onClick={() => onSelect(comic)}>
          <CoverImage url={comic.cover} iconSize={18} />
          <div className="result-main">
            <strong>{comic.title}</strong>
            {comic.subtitle ? <span>{comic.subtitle}</span> : null}
            {comic.tags.length > 0 ? <small>{comic.tags.slice(0, 4).join(' / ')}</small> : null}
          </div>
        </button>
      ))}
    </div>
  )
}

function ComicDetails({
  comic,
  images,
  activeEpisodeTitle,
  readerMode,
  favorite,
  loadingComic,
  loadingImages,
  message,
  onLoadImages,
  onFavoriteChange
}: {
  comic: ComicInfo | null
  images: string[]
  activeEpisodeTitle: string | null
  readerMode: ReaderMode
  favorite: boolean
  loadingComic: boolean
  loadingImages: boolean
  message: string | null
  onLoadImages: (episode: ComicEpisode) => void
  onFavoriteChange?: (comic: ComicInfo, favorite: boolean) => void
}) {
  const [pageIndex, setPageIndex] = useState(0)
  const orderedImages = images
  const isGalleryMode = readerMode.startsWith('gallery')
  const activePageIndex =
    orderedImages.length === 0 ? 0 : Math.min(pageIndex, orderedImages.length - 1)
  const visibleImages = isGalleryMode
    ? orderedImages.slice(activePageIndex, activePageIndex + 1)
    : orderedImages

  useEffect(() => {
    setPageIndex(0)
  }, [activeEpisodeTitle, images.length, readerMode])

  if (loadingComic) {
    return <EmptyLine icon={Loader2} text="加载详情中" />
  }
  if (!comic) {
    return <EmptyLine icon={BookOpen} text={message ?? '选择搜索结果查看详情'} />
  }

  return (
    <div className="comic-detail">
      <div className="comic-summary">
        <CoverImage url={comic.cover} iconSize={20} />
        <div>
          <strong>{comic.title}</strong>
          {comic.subtitle ? <span>{comic.subtitle}</span> : null}
          {comic.description ? <p>{comic.description}</p> : null}
          {onFavoriteChange ? (
            <button
              className={favorite ? 'icon-text-button subtle active' : 'icon-text-button subtle'}
              type="button"
              onClick={() => onFavoriteChange(comic, !favorite)}
            >
              <Heart size={16} fill={favorite ? 'currentColor' : 'none'} />
              {favorite ? '已收藏' : '收藏'}
            </button>
          ) : null}
        </div>
      </div>
      <div className="episode-list">
        {comic.episodes.map((episode) => (
          <button
            key={episode.id}
            className="episode-button"
            type="button"
            disabled={loadingImages}
            onClick={() => onLoadImages(episode)}
          >
            {episode.title}
          </button>
        ))}
      </div>
      {message ? <EmptyLine icon={BookOpen} text={message} /> : null}
      {loadingImages ? <EmptyLine icon={Loader2} text="加载章节中" /> : null}
      {images.length > 0 ? (
        <div className={`reader-shell ${readerModeClassName(readerMode)}`}>
          <div className="reader-heading">
            <strong>{activeEpisodeTitle ?? '当前章节'}</strong>
            <span>
              {isGalleryMode
                ? `${activePageIndex + 1}/${orderedImages.length}`
                : `${orderedImages.length} 张`}
            </span>
          </div>
          {isGalleryMode ? (
            <div className="reader-pager" aria-label="翻页">
              <button
                className="icon-button"
                type="button"
                disabled={activePageIndex === 0}
                aria-label="上一页"
                onClick={() => setPageIndex((current) => Math.max(0, current - 1))}
              >
                <ChevronLeft size={18} />
              </button>
              <span>{readerModeOptions.find((option) => option.key === readerMode)?.label}</span>
              <button
                className="icon-button"
                type="button"
                disabled={activePageIndex >= orderedImages.length - 1}
                aria-label="下一页"
                onClick={() =>
                  setPageIndex((current) => Math.min(orderedImages.length - 1, current + 1))
                }
              >
                <ChevronRight size={18} />
              </button>
            </div>
          ) : null}
          <div className="reader-image-list">
            {visibleImages.map((image, index) => (
              <img
                key={`${image}-${index}`}
                src={imageProxyUrl(image)}
                alt={`第 ${isGalleryMode ? activePageIndex + 1 : index + 1} 页`}
                loading={index < 2 ? 'eager' : 'lazy'}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

function UpdatesView({
  data,
  folders,
  activeFolder,
  loading,
  task,
  onBack,
  onFolderSelect,
  onRefresh,
  onCheck,
  onMarkRead,
  onOpenComic
}: {
  data: FollowUpdatesResponse
  folders: FavoriteFolder[]
  activeFolder: string | null
  loading: boolean
  task: TaskSummary | null
  onBack: () => void
  onFolderSelect: (folder: string | null) => Promise<void>
  onRefresh: () => Promise<void>
  onCheck: () => Promise<void>
  onMarkRead: () => Promise<void>
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  const [activeList, setActiveList] = useState<'updated' | 'all'>('updated')
  const visibleItems = activeList === 'updated' ? data.updated : data.all
  const visibleTotal = activeList === 'updated' ? data.updated_total : data.all_total
  const activeFolderTitle =
    activeFolder == null
      ? '未配置'
      : folders.find((folder) => folder.name === activeFolder)?.title ?? activeFolder

  return (
    <div className="favorite-layout follow-layout">
      <aside className="favorite-folder-panel" aria-label="追更收藏夹">
        <div className="folder-section-title">追更收藏夹</div>
        <FavoriteFolderButton
          title="未配置"
          count={0}
          active={activeFolder == null}
          onClick={() => void onFolderSelect(null)}
        />
        {folders.map((folder) => (
          <FavoriteFolderButton
            key={folder.name}
            title={folder.title}
            count={folder.count}
            active={activeFolder === folder.name}
            onClick={() => void onFolderSelect(folder.name)}
          />
        ))}
      </aside>
      <div className="view-stack">
        <PageHeader
          title="追更"
          onBack={onBack}
          actions={
            <>
              <button
                className="icon-button"
                type="button"
                aria-label="检查更新"
                title="检查更新"
                disabled={!activeFolder || loading || task != null}
                onClick={() => void onCheck()}
              >
                {task ? <Loader2 className="spin" size={18} /> : <Play size={18} />}
              </button>
              <button
                className="icon-button"
                type="button"
                aria-label="全部已读"
                title="全部已读"
                disabled={!activeFolder || loading || data.updated_total === 0}
                onClick={() => void onMarkRead()}
              >
                <CheckSquare size={18} />
              </button>
              <button
                className="icon-button"
                type="button"
                aria-label="刷新追更"
                title="刷新追更"
                disabled={!activeFolder || loading}
                onClick={() => void onRefresh()}
              >
                {loading ? <Loader2 className="spin" size={18} /> : <RefreshCw size={18} />}
              </button>
            </>
          }
        />
        <section className="follow-config-card">
          <div className="follow-config-title">
            <RefreshCw size={20} />
            <strong>追更</strong>
            <span>{activeFolderTitle}</span>
          </div>
          {activeFolder ? (
            <div className="follow-config-stats">
              <span>更新 {data.updated_total}</span>
              <span>追踪 {data.all_total}</span>
            </div>
          ) : (
            <div className="follow-config-stats">
              <span>选择收藏夹后显示追更</span>
            </div>
          )}
          {task ? <TaskProgressLine task={task} /> : null}
        </section>
        {activeFolder ? (
          <>
            <div className="app-tabs" role="tablist" aria-label="追更列表">
              <button
                className={activeList === 'updated' ? 'selected' : ''}
                type="button"
                role="tab"
                aria-selected={activeList === 'updated'}
                onClick={() => setActiveList('updated')}
              >
                更新
              </button>
              <button
                className={activeList === 'all' ? 'selected' : ''}
                type="button"
                role="tab"
                aria-selected={activeList === 'all'}
                onClick={() => setActiveList('all')}
              >
                全部
              </button>
            </div>
            <Panel title={activeList === 'updated' ? '更新' : '全部漫画'} action={String(visibleTotal)}>
              {loading ? (
                <EmptyLine icon={Loader2} text="加载追更中" />
              ) : (
                <LibraryGrid
                  items={visibleItems}
                  emptyText={
                    activeList === 'updated'
                      ? data.all_total > 0
                        ? '暂无更新'
                        : '暂无追更数据'
                      : '暂无追更数据'
                  }
                  icon={RefreshCw}
                  onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
                />
              )}
            </Panel>
          </>
        ) : (
          <Panel title="收藏夹" action={String(folders.length)}>
            <EmptyLine icon={FolderOpen} text={folders.length > 0 ? '请选择收藏夹' : '暂无收藏文件夹'} />
          </Panel>
        )}
      </div>
    </div>
  )
}

function FavoritesView({
  items,
  total,
  allTotal,
  folders,
  activeFolder,
  loadingFolder,
  loadingMore = false,
  onFolderSelect,
  onLoadMore,
  onOpenComic,
  onCreateFolder,
  onDeleteFolder
}: {
  items: LibraryItem[]
  total: number
  allTotal: number
  folders: FavoriteFolder[]
  activeFolder: string | null
  loadingFolder?: boolean
  loadingMore?: boolean
  onFolderSelect: (folder: string | null) => Promise<void>
  onLoadMore?: () => void
  onOpenComic: (request: ComicOpenRequest) => void
  onCreateFolder?: (title: string) => Promise<void>
  onDeleteFolder?: (name: string) => Promise<void>
}) {
  const [addingFolder, setAddingFolder] = useState(false)
  const [newFolderTitle, setNewFolderTitle] = useState('')
  const [folderBusy, setFolderBusy] = useState(false)
  const activeFolderTitle =
    activeFolder == null
      ? '全部'
      : folders.find((folder) => folder.name === activeFolder)?.title ?? activeFolder

  const handleAddFolder = async () => {
    const title = newFolderTitle.trim()
    if (!title || !onCreateFolder) return
    setFolderBusy(true)
    try {
      await onCreateFolder(title)
      setNewFolderTitle('')
      setAddingFolder(false)
    } catch {
      // error handled by parent
    } finally {
      setFolderBusy(false)
    }
  }

  return (
    <div className="favorite-layout">
      <aside className="favorite-folder-panel" aria-label="收藏文件夹">
        <div className="folder-section-title">收藏夹</div>
        <FavoriteFolderButton
          title="全部"
          count={allTotal}
          active={activeFolder == null}
          onClick={() => onFolderSelect(null)}
        />
        {folders.map((folder) => (
          <FavoriteFolderButton
            key={folder.name}
            title={folder.title}
            count={folder.count}
            active={activeFolder === folder.name}
            onClick={() => onFolderSelect(folder.name)}
            onDelete={onDeleteFolder ? () => onDeleteFolder(folder.name) : undefined}
          />
        ))}
        {onCreateFolder ? (
          addingFolder ? (
            <div style={{ display: 'grid', gap: '6px', padding: '8px 12px' }}>
              <input
                className="folder-name-input"
                value={newFolderTitle}
                placeholder="文件夹名称"
                onChange={(e) => setNewFolderTitle(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') handleAddFolder() }}
                autoFocus
              />
              <div style={{ display: 'flex', gap: '6px' }}>
                <button className="primary-button" style={{ minHeight: '32px', fontSize: '13px' }} disabled={!newFolderTitle.trim() || folderBusy} onClick={handleAddFolder}>
                  {folderBusy ? '创建中' : '确定'}
                </button>
                <button className="icon-text-button subtle" style={{ minHeight: '32px', fontSize: '13px' }} onClick={() => setAddingFolder(false)}>
                  取消
                </button>
              </div>
            </div>
          ) : (
            <button className="favorite-folder-button" type="button" onClick={() => setAddingFolder(true)}>
              <span style={{ color: 'var(--muted)' }}>+ 新建文件夹</span>
            </button>
          )
        ) : null}
      </aside>
      <div className="view-stack">
        <Panel title={activeFolderTitle} action={String(total)}>
          {loadingFolder ? (
            <EmptyLine icon={Loader2} text="加载收藏中" />
          ) : (
            <LibraryGrid
              items={items}
              emptyText="暂无收藏"
              icon={Heart}
              onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
            />
          )}
          <LoadMoreSentinel loading={loadingMore} onLoadMore={onLoadMore} label={`${items.length}/${total}`} />
        </Panel>
      </div>
    </div>
  )
}

function FavoriteFolderButton({
  title,
  count,
  active,
  onClick,
  onDelete
}: {
  title: string
  count: number
  active: boolean
  onClick: () => void
  onDelete?: () => void
}) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', alignItems: 'center' }}>
      <button
        className={active ? 'favorite-folder-button active' : 'favorite-folder-button'}
        type="button"
        onClick={onClick}
      >
        <span>{title}</span>
        <small>{count}</small>
      </button>
      {onDelete ? (
        <button
          className="icon-button"
          type="button"
          aria-label={`删除 ${title}`}
          title={`删除 ${title}`}
          onClick={(e) => { e.stopPropagation(); onDelete() }}
          style={{ width: '32px', height: '32px', color: 'var(--muted)' }}
        >
          <Trash2 size={14} />
        </button>
      ) : null}
    </div>
  )
}

function LibraryView({
  title,
  icon: Icon,
  items,
  total,
  emptyText,
  loadingMore = false,
  standalone = false,
  onBack,
  onLoadMore,
  onOpenComic
}: {
  title: string
  icon: typeof Home
  items: LibraryItem[]
  total: number
  emptyText: string
  loadingMore?: boolean
  standalone?: boolean
  onBack?: () => void
  onLoadMore?: () => void
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  return (
    <div className="view-stack">
      {standalone ? (
        <PageHeader
          title={title}
          onBack={onBack}
          actions={
            <>
              <button className="top-action-button" type="button" aria-label="筛选" title="筛选">
                <Filter size={20} />
              </button>
              <button className="top-action-button" type="button" aria-label="刷新" title="刷新">
                <RefreshCw size={20} />
              </button>
              <button className="top-action-button" type="button" aria-label="多选" title="多选">
                <CheckSquare size={20} />
              </button>
              <button className="top-action-button" type="button" aria-label="删除" title="删除">
                <Trash2 size={20} />
              </button>
            </>
          }
        />
      ) : null}
      {standalone ? (
        <section className="search-strip app-page-search" aria-label="搜索">
          <Search size={20} />
          <input placeholder="搜索" disabled />
        </section>
      ) : null}
      <Panel title={title} action={String(total)}>
        {standalone ? (
          <GroupedLibraryList
            items={items}
            emptyText={emptyText}
            icon={Icon}
            onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
          />
        ) : (
          <LibraryGrid
            items={items}
            emptyText={emptyText}
            icon={Icon}
            onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
          />
        )}
        <LoadMoreSentinel loading={loadingMore} onLoadMore={onLoadMore} label={`${items.length}/${total}`} />
      </Panel>
    </div>
  )
}

function GroupedLibraryList({
  items,
  emptyText,
  icon: Icon,
  onSelect
}: {
  items: LibraryItem[]
  emptyText: string
  icon: typeof Home
  onSelect: (item: LibraryItem) => void
}) {
  if (items.length === 0) {
    return <EmptyLine icon={Icon} text={emptyText} />
  }

  const groups = new Map<string, LibraryItem[]>()
  items.forEach((item) => {
    const title = dateGroupTitle(item.updated_at)
    groups.set(title, [...(groups.get(title) ?? []), item])
  })

  return (
    <div className="library-groups">
      {[...groups.entries()].map(([title, groupItems]) => (
        <section className="library-group" key={title}>
          <h3>{title}</h3>
          <LibraryGrid items={groupItems} emptyText={emptyText} icon={Icon} onSelect={onSelect} />
        </section>
      ))}
    </div>
  )
}

function dateGroupTitle(value: string | null) {
  if (!value) return '更早'
  const date = parseAppDate(value)
  if (!date) return '更早'
  const now = new Date()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  const diffDays = Math.floor((today.getTime() - day.getTime()) / 86_400_000)
  if (diffDays <= 0) return '今天'
  if (diffDays === 1) return '昨天'
  if (diffDays < 7) return '本周'
  return '更早'
}

function LibraryGrid({
  items,
  emptyText,
  icon: Icon = BookOpen,
  onSelect
}: {
  items: LibraryItem[]
  emptyText: string
  icon?: typeof Home
  onSelect?: (item: LibraryItem) => void
}) {
  if (items.length === 0) {
    return <EmptyLine icon={Icon} text={emptyText} />
  }

  return (
    <div className="comic-grid">
      {items.map((item) => (
        <ComicTile key={libraryItemKey(item)} item={item} onSelect={onSelect} />
      ))}
    </div>
  )
}

function ComicTile({
  item,
  compact = false,
  onSelect
}: {
  item: LibraryItem
  compact?: boolean
  onSelect?: (item: LibraryItem) => void
}) {
  const rows = libraryItemMetaRows(item)
  if (compact) {
    return (
      <button className="comic-tile compact" type="button" onClick={() => onSelect?.(item)} title={item.title}>
        <div className="comic-tile-cover">
          <CoverImage url={item.cover} iconSize={18} />
        </div>
        <strong>{item.title}</strong>
      </button>
    )
  }

  return (
    <button className="comic-tile" type="button" onClick={() => onSelect?.(item)} title={item.title}>
      <div className="comic-tile-cover">
        <CoverImage url={item.cover} iconSize={18} />
      </div>
      <div className="comic-tile-main">
        <strong>{item.title}</strong>
        <ComicMetaRows rows={rows} />
      </div>
    </button>
  )
}

function ComicMetaRows({ rows }: { rows: ComicMetaRow[] }) {
  if (rows.length === 0) return null
  return (
    <div className="comic-meta-rows">
      {rows.slice(0, 5).map((row) => (
        <div className="comic-meta-row" key={`${row.label}:${row.value}`}>
          <span className={`comic-meta-label ${row.tone}`}>{row.label}</span>
          <span className="comic-meta-value">{row.value}</span>
        </div>
      ))}
    </div>
  )
}

function CoverImage({ url, iconSize }: { url: string | null; iconSize: number }) {
  const [failed, setFailed] = useState(false)

  if (!url || failed) {
    return (
      <div className="result-cover-placeholder">
        <BookOpen size={iconSize} />
      </div>
    )
  }

  return <img src={imageProxyUrl(url)} alt="" loading="lazy" onError={() => setFailed(true)} />
}

function LibraryReader({
  item,
  readerMode,
  onRecordHistory
}: {
  item: LibraryItem
  readerMode: ReaderMode
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [comic, setComic] = useState<ComicInfo | null>(null)
  const [images, setImages] = useState<string[]>([])
  const [activeEpisodeTitle, setActiveEpisodeTitle] = useState<string | null>(null)
  const [loadingComic, setLoadingComic] = useState(false)
  const [loadingImages, setLoadingImages] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setLoadingComic(true)
    setMessage(null)
    setImages([])
    setActiveEpisodeTitle(null)
    void getComicInfo(item.source_key, item.comic_id)
      .then((response) => {
        if (cancelled) return
        setComic(response.comic)
        setMessage(response.comic.episodes.length === 0 ? '暂无章节' : null)
      })
      .catch((err) => {
        if (cancelled) return
        setComic(null)
        setMessage(err instanceof Error ? err.message : '详情加载失败')
      })
      .finally(() => {
        if (!cancelled) setLoadingComic(false)
      })

    return () => {
      cancelled = true
    }
  }, [item.source_key, item.comic_id])

  const handleLoadImages = async (episode: ComicEpisode) => {
    if (!comic) return

    setLoadingImages(true)
    setMessage(null)
    try {
      const response = await getComicPages(item.source_key, comic.id, episode.id)
      setImages(response.images)
      setActiveEpisodeTitle(episode.title)
      setMessage(response.images.length === 0 ? '暂无图片' : null)
      if (response.images.length > 0) {
        await onRecordHistory({
          source_key: item.source_key,
          comic_id: comic.id,
          title: comic.title,
          subtitle: comic.subtitle,
          cover: comic.cover,
          episode_id: episode.id,
          episode_title: episode.title
        })
      }
    } catch (err) {
      setImages([])
      setActiveEpisodeTitle(null)
      setMessage(err instanceof Error ? err.message : '章节加载失败')
    } finally {
      setLoadingImages(false)
    }
  }

  return (
    <ComicDetails
      comic={comic}
      images={images}
      activeEpisodeTitle={activeEpisodeTitle}
      readerMode={readerMode}
      favorite={false}
      loadingComic={loadingComic}
      loadingImages={loadingImages}
      message={message}
      onLoadImages={handleLoadImages}
    />
  )
}

function SourcePagesView({
  title,
  icon: Icon,
  kind,
  onOpenComic
}: {
  title: string
  icon: typeof Home
  kind: 'explore' | 'categories'
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  const [data, setData] = useState<SourcePagesResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [listTarget, setListTarget] = useState<SourceListTarget | null>(null)
  const [list, setList] = useState<SourceComicListResponse | null>(null)
  const [listLoading, setListLoading] = useState(false)
  const [listMessage, setListMessage] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    getSourcePages()
      .then((next) => {
        if (active) setData(next)
      })
      .catch((err) => {
        if (active) setError(err instanceof Error ? err.message : '源页面加载失败')
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [])

  const sources = useMemo(() => {
    const items = data?.sources ?? []
    return items.filter((source) =>
      kind === 'explore'
        ? source.explore_pages.length > 0
        : (source.category?.parts.some((part) => part.items.length > 0) ?? false)
    )
  }, [data, kind])

  const tabs = useMemo<SourcePageTab[]>(() => {
    if (kind === 'explore') {
      return sources.flatMap((source) =>
        source.explore_pages.map((page, index) => ({
          key: `${source.source_key}:explore:${index}:${page.title}`,
          title: page.title,
          subtitle: page.title === source.source_name ? null : source.source_name,
          source,
          page
        }))
      )
    }

    return sources.map((source) => ({
      key: `${source.source_key}:categories`,
      title: source.category?.title ?? source.source_name,
      subtitle: source.category?.title === source.source_name ? null : source.source_name,
      source
    }))
  }, [kind, sources])

  const [selectedKey, setSelectedKey] = useState<string | null>(null)

  useEffect(() => {
    if (tabs.length === 0) {
      if (selectedKey !== null) setSelectedKey(null)
      return
    }
    if (!tabs.some((tab) => tab.key === selectedKey)) {
      setSelectedKey(tabs[0].key)
    }
  }, [selectedKey, tabs])

  const selectedTab = tabs.find((tab) => tab.key === selectedKey) ?? tabs[0]

  const loadSourceList = useCallback(
    async (target: SourceListTarget, page: number, append = false) => {
      setListLoading(true)
      setListMessage(null)
      try {
        const response = await requestSourceList(target, page)
        setList((current) => (append && current ? mergeSourceComicList(current, response) : response))
        setListTarget(target)
        setListMessage(hasSourceComics(response) ? null : '暂无条目')
      } catch (err) {
        if (!append) setList(null)
        setListMessage(err instanceof Error ? err.message : '列表加载失败')
      } finally {
        setListLoading(false)
      }
    },
    []
  )

  useEffect(() => {
    setList(null)
    setListMessage(null)
    if (!selectedTab) {
      setListTarget(null)
      return
    }
    if (kind === 'explore') {
      const target: SourceListTarget = { kind: 'explore', tab: selectedTab }
      setListTarget(target)
      void loadSourceList(target, 1)
    } else {
      setListTarget(null)
    }
  }, [kind, selectedTab?.key, loadSourceList])

  const activeCategoryKey =
    listTarget?.kind === 'category' || listTarget?.kind === 'search'
      ? categoryItemKey(listTarget.tab, listTarget.part, listTarget.item)
      : null

  const handleCategorySelect = (part: SourceCategoryPart, item: SourceCategoryItem) => {
    if (!selectedTab) return
    setList(null)
    const targetPage = item.target_page ?? part.item_type ?? 'category'
    const target: SourceListTarget =
      targetPage === 'search'
        ? {
            kind: 'search',
            tab: selectedTab,
            part,
            item,
            keyword: item.param ?? item.category ?? item.label
          }
        : { kind: 'category', tab: selectedTab, part, item }
    setListTarget(target)
    void loadSourceList(target, 1)
  }

  const handleLoadMore = () => {
    if (!listTarget || !list || listLoading) return
    void loadSourceList(listTarget, list.page + 1, true)
  }

  const handleOpenComic = async (comic: SearchComic) => {
    const sourceKey = list?.source_key ?? selectedTab?.source.source_key
    if (!sourceKey) return
    onOpenComic(searchComicToOpenRequest(sourceKey, comic))
  }

  return (
    <div className="view-stack">
      <Panel title={title} action={loading ? '...' : String(tabs.length)}>
        {error ? <EmptyLine icon={WifiOff} text={error} /> : null}
        {!error && loading ? <EmptyLine icon={Loader2} text="加载中" /> : null}
        {!error && !loading && tabs.length === 0 ? <EmptyLine icon={Icon} text="暂无条目" /> : null}
        {!error && !loading && selectedTab ? (
          <>
            <SourceAppTabs tabs={tabs} selectedKey={selectedTab.key} onSelect={setSelectedKey} />
            <SourcePageContent
              tab={selectedTab}
              kind={kind}
              activeCategoryKey={activeCategoryKey}
              onCategorySelect={handleCategorySelect}
            />
            <SourceComicSections
              response={list}
              loading={listLoading}
              message={listMessage}
              showEmpty={kind === 'explore' || Boolean(listTarget)}
              onSelect={handleOpenComic}
            />
            <LoadMoreSentinel
              loading={listLoading}
              onLoadMore={list && canLoadMoreSourceList(list) ? handleLoadMore : undefined}
              label={list ? `${list.page}/${list.max_page ?? '?'}` : undefined}
            />
          </>
        ) : null}
      </Panel>
    </div>
  )
}

type SourcePageTab = {
  key: string
  title: string
  subtitle: string | null
  source: SourcePageManifest
  page?: SourcePageManifest['explore_pages'][number]
}

type SourceListTarget =
  | { kind: 'explore'; tab: SourcePageTab }
  | { kind: 'category'; tab: SourcePageTab; part: SourceCategoryPart; item: SourceCategoryItem }
  | {
      kind: 'search'
      tab: SourcePageTab
      part: SourceCategoryPart
      item: SourceCategoryItem
      keyword: string
    }

function SourceAppTabs({
  tabs,
  selectedKey,
  onSelect
}: {
  tabs: SourcePageTab[]
  selectedKey: string
  onSelect: (key: string) => void
}) {
  return (
    <div className="source-app-tabs" role="tablist">
      {tabs.map((tab) => (
        <button
          className={tab.key === selectedKey ? 'source-app-tab selected' : 'source-app-tab'}
          key={tab.key}
          type="button"
          role="tab"
          aria-selected={tab.key === selectedKey}
          onClick={() => onSelect(tab.key)}
        >
          <span>{tab.title}</span>
        </button>
      ))}
    </div>
  )
}

function SourcePageContent({
  tab,
  kind,
  activeCategoryKey,
  onCategorySelect
}: {
  tab: SourcePageTab
  kind: 'explore' | 'categories'
  activeCategoryKey: string | null
  onCategorySelect: (part: SourceCategoryPart, item: SourceCategoryItem) => void
}) {
  if (kind === 'explore') {
    return (
      <div className="source-explore-page">
        <div className="source-section-title">
          <strong>{tab.title}</strong>
          {tab.subtitle ? <span>{tab.subtitle}</span> : null}
        </div>
      </div>
    )
  }

  const categoryParts = tab.source.category?.parts ?? []

  return (
    <div className="category-app-page">
      {categoryParts.map((part) => {
        const visible = part.items.slice(0, 60)
        const remaining = part.items.length - visible.length
        return (
          <section className="category-app-section" key={`${tab.source.source_key}:${part.title}`}>
            <div className="source-section-title">
              <strong>{part.title}</strong>
              <span>{part.items.length}</span>
            </div>
                <div className="category-chip-list">
                  {visible.map((item) => (
                    <button
                      className={
                        categoryItemKey(tab, part, item) === activeCategoryKey
                          ? 'category-chip active'
                          : 'category-chip'
                      }
                      key={`${part.title}:${item.label}:${item.param ?? ''}`}
                      type="button"
                      onClick={() => onCategorySelect(part, item)}
                    >
                      {item.label}
                    </button>
                  ))}
                  {remaining > 0 ? <span className="category-chip muted">+{remaining}</span> : null}
                </div>
          </section>
        )
      })}
    </div>
  )
}

async function requestSourceList(target: SourceListTarget, page: number): Promise<SourceComicListResponse> {
  if (target.kind === 'explore') {
    return loadSourceExplorePage(target.tab.source.source_key, target.tab.title, page)
  }

  const category = target.item.category ?? target.item.label
  if (target.kind === 'search') {
    const response = await searchComics(target.tab.source.source_key, target.keyword, page)
    return {
      source_key: response.source_key,
      page: response.page,
      title: null,
      category,
      param: target.item.param,
      max_page: response.max_page,
      next: response.next,
      comics: response.comics,
      parts: []
    }
  }

  return loadSourceCategoryPage({
    sourceKey: target.tab.source.source_key,
    category,
    param: target.item.param,
    page
  })
}

function SourceComicSections({
  response,
  loading,
  message,
  showEmpty,
  onSelect
}: {
  response: SourceComicListResponse | null
  loading: boolean
  message: string | null
  showEmpty: boolean
  onSelect: (comic: SearchComic) => void
}) {
  if (loading && !response) {
    return <EmptyLine icon={Loader2} text="加载中" />
  }
  if (message && (!response || !hasSourceComics(response))) {
    return <EmptyLine icon={WifiOff} text={message} />
  }
  if (!response) return showEmpty ? <EmptyLine icon={Compass} text="暂无条目" /> : null

  return (
    <div className="source-list-content">
      {response.comics.length > 0 ? (
        <SourceComicGrid comics={response.comics} onSelect={onSelect} />
      ) : null}
      {response.parts.map((part, index) => (
        <section className="source-comic-section" key={`${part.title}:${index}`}>
          {part.title ? (
            <div className="source-section-title">
              <strong>{part.title}</strong>
              <span>{part.comics.length}</span>
            </div>
          ) : null}
          <SourceComicGrid comics={part.comics} onSelect={onSelect} />
        </section>
      ))}
      {loading ? <EmptyLine icon={Loader2} text="加载中" /> : null}
    </div>
  )
}

function SourceComicGrid({
  comics,
  onSelect
}: {
  comics: SearchComic[]
  onSelect: (comic: SearchComic) => void
}) {
  return (
    <div className="comic-grid">
      {comics.map((comic) => (
        <button
          className="comic-tile"
          key={comic.id}
          type="button"
          title={comic.title}
          onClick={() => onSelect(comic)}
        >
          <div className="comic-tile-cover">
            <CoverImage url={comic.cover} iconSize={18} />
          </div>
          <div className="comic-tile-main">
            <strong>{comic.title}</strong>
            <ComicMetaRows rows={searchComicMetaRows(comic)} />
          </div>
        </button>
      ))}
    </div>
  )
}

function mergeSourceComicList(
  current: SourceComicListResponse,
  incoming: SourceComicListResponse
): SourceComicListResponse {
  const parts = [...current.parts]
  incoming.parts.forEach((part) => {
    const index = parts.findIndex((item) => item.title === part.title)
    if (index >= 0) {
      parts[index] = {
        ...parts[index],
        comics: mergeSourceComics(parts[index].comics, part.comics)
      }
    } else {
      parts.push(part)
    }
  })

  return {
    ...incoming,
    comics: mergeSourceComics(current.comics, incoming.comics),
    parts
  }
}

function mergeSourceComics(current: SearchComic[], incoming: SearchComic[]) {
  const seen = new Set(current.map((comic) => comic.id))
  return [
    ...current,
    ...incoming.filter((comic) => {
      if (seen.has(comic.id)) return false
      seen.add(comic.id)
      return true
    })
  ]
}

function hasSourceComics(response: SourceComicListResponse) {
  return response.comics.length > 0 || response.parts.some((part) => part.comics.length > 0)
}

function canLoadMoreSourceList(response: SourceComicListResponse) {
  return response.max_page != null && response.page < response.max_page
}

function categoryItemKey(tab: SourcePageTab, part: SourceCategoryPart, item: SourceCategoryItem) {
  return `${tab.source.source_key}:${part.title}:${item.label}:${item.category ?? ''}:${item.param ?? ''}`
}

function TasksView({
  tasks,
  onBack,
  onRefresh
}: {
  tasks: TaskSummary[]
  onBack: () => void
  onRefresh: () => Promise<TaskSummary[]>
}) {
  return (
    <div className="view-stack">
      <PageHeader
        title="任务"
        onBack={onBack}
        actions={
          <button
            className="icon-button"
            type="button"
            aria-label="刷新任务"
            title="刷新任务"
            onClick={() => void onRefresh()}
          >
            <RefreshCw size={18} />
          </button>
        }
      />
      <Panel title="任务" action={String(tasks.length)}>
        {tasks.length === 0 ? (
          <EmptyLine icon={ClipboardList} text="暂无后台任务" />
        ) : (
          <div className="task-list">
            {tasks.map((task) => (
              <TaskRow key={task.id} task={task} />
            ))}
          </div>
        )}
      </Panel>
    </div>
  )
}

function TaskRow({ task }: { task: TaskSummary }) {
  const folder = taskPayloadText(task, 'folder') ?? '未知'
  const total = taskPayloadNumber(task, 'total')
  const checked = taskPayloadNumber(task, 'checked')
  const updated = taskPayloadNumber(task, 'updated')
  const failed = taskPayloadNumber(task, 'failed')
  const currentTitle = taskPayloadText(task, 'currentTitle')
  const title = task.kind === 'follow_updates' ? `追更检查 · ${folder}` : task.kind
  const statusText =
    task.status === 'running' ? '运行中' : task.status === 'completed' ? '完成' : '异常'

  return (
    <div className="task-row">
      <div className="task-row-main">
        <strong>{title}</strong>
        <span>{currentTitle ?? `${checked}/${total}`}</span>
      </div>
      <div className="task-row-meta">
        <span>{statusText}</span>
        <span>{checked}/{total}</span>
        <span>更新 {updated}</span>
        <span>失败 {failed}</span>
      </div>
      <progress value={task.progress} max={100} aria-label={title} />
      {task.error ? <small>{task.error}</small> : null}
    </div>
  )
}

function TaskProgressLine({ task }: { task: TaskSummary }) {
  const total = taskPayloadNumber(task, 'total')
  const checked = taskPayloadNumber(task, 'checked')
  const updated = taskPayloadNumber(task, 'updated')
  const failed = taskPayloadNumber(task, 'failed')
  return (
    <div className="follow-task-summary">
      <span>检查 {checked}/{total}</span>
      <span>更新 {updated}</span>
      <span>失败 {failed}</span>
      <progress value={task.progress} max={100} aria-label="追更检查进度" />
    </div>
  )
}

function SettingsView({
  settings,
  themeMode,
  readerMode,
  sources,
  onBack,
  onThemeChange,
  onReaderModeChange,
  onImportComplete
}: {
  settings: SettingsResponse | null
  themeMode: string
  readerMode: ReaderMode
  sources: SourceSummary[]
  onBack: () => void
  onThemeChange: (value: string) => Promise<void>
  onReaderModeChange: (value: ReaderMode) => Promise<void>
  onImportComplete: () => void | Promise<void>
}) {
  const hidden = settings?.hidden_features ?? []
  const [activeSection, setActiveSection] = useState<SettingsSectionKey>('appearance')
  const cacheLimitMb = useMemo(() => {
    const value = settings?.values.cacheLimitMb
    return typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : 1024
  }, [settings])
  const enabledSources = useMemo(
    () => sources.filter((source) => source.enabled && source.runtime_status === 'registered'),
    [sources]
  )
  const sections = [
    { key: 'appearance' as const, title: '显示', icon: Settings },
    { key: 'reading' as const, title: '阅读', icon: BookOpen },
    { key: 'explore' as const, title: '发现', icon: Compass },
    { key: 'network' as const, title: '网络', icon: WifiOff },
    { key: 'webdav' as const, title: 'WebDAV', icon: Upload },
    { key: 'about' as const, title: '关于', icon: Bookmark },
    { key: 'hidden' as const, title: 'Web 屏蔽项', icon: EyeOff, count: hidden.length }
  ]

  const updateSetting = async (key: string, value: unknown) => {
    await updateSettings({ [key]: value })
  }

  return (
    <div className="view-stack settings-page">
      <PageHeader title="设置" onBack={onBack} />
      <div className="settings-shell">
        <aside className="settings-rail" aria-label="设置分类">
          {sections.map((section) => (
            <SettingsCategoryButton
              key={section.key}
              title={section.title}
              icon={section.icon}
              count={section.count}
              active={activeSection === section.key}
              onClick={() => setActiveSection(section.key)}
            />
          ))}
        </aside>
        <section className="settings-detail-pane">
          {activeSection === 'appearance' ? (
            <SettingsPart title="显示" icon={Settings}>
              <SettingRow title="主题" subtitle="跟随系统或固定明暗色">
                <div className="segmented-control" role="group" aria-label="主题">
                  {['system', 'light', 'dark'].map((value) => (
                    <button
                      key={value}
                      className={themeMode === value ? 'selected' : ''}
                      type="button"
                      onClick={() => void onThemeChange(value)}
                    >
                      {value === 'system' ? '系统' : value === 'light' ? '浅色' : '深色'}
                    </button>
                  ))}
                </div>
              </SettingRow>
            </SettingsPart>
          ) : null}
          {activeSection === 'reading' ? (
            <SettingsPart title="阅读" icon={BookOpen}>
              <SettingRow title="阅读方式" subtitle="Web 端隐藏原生端专用控制">
                <div className="reader-mode-control" role="group" aria-label="阅读方式">
                  {readerModeOptions.map((option) => (
                    <button
                      key={option.key}
                      className={readerMode === option.key ? 'selected' : ''}
                      type="button"
                      onClick={() => void onReaderModeChange(option.key)}
                    >
                      {option.label}
                    </button>
                  ))}
                </div>
              </SettingRow>
            </SettingsPart>
          ) : null}
          {activeSection === 'explore' ? (
            <SettingsPart title="发现" icon={Compass}>
              <div className="settings-list">
                <SettingRow title="探索页面" subtitle="从漫画源获取的探索页面列表">
                  <span className="muted-text">{enabledSources.length} 个可用源</span>
                </SettingRow>
                {enabledSources.slice(0, 8).map((source) => (
                  <div className="settings-list-tile" key={source.key}>
                    <div>
                      <strong>{source.name}</strong>
                      <span>{source.version ? `v${source.version}` : '未知版本'}</span>
                    </div>
                    <StatusPill ok={source.enabled} text={source.enabled ? '启用' : '停用'} />
                  </div>
                ))}
                {enabledSources.length === 0 ? <EmptyLine icon={Compass} text="暂无启用的漫画源" /> : null}
              </div>
            </SettingsPart>
          ) : null}
          {activeSection === 'network' ? (
            <SettingsPart title="网络" icon={WifiOff}>
              <SettingRow title="图片缓存上限" subtitle={`当前: ${cacheLimitMb} MB`}>
                <span className="muted-text">{cacheLimitMb >= 10240 ? '无限制' : `${cacheLimitMb} MB`}</span>
              </SettingRow>
              <div className="settings-list-tile">
                <div>
                  <strong>服务端地址</strong>
                  <span>Web PWA 网络请求由服务端代理</span>
                </div>
              </div>
            </SettingsPart>
          ) : null}
          {activeSection === 'about' ? (
            <SettingsPart title="关于" icon={Bookmark}>
              <div className="settings-list">
                <div className="settings-list-tile">
                  <div>
                    <strong>Venera</strong>
                    <span>漫画阅读器 / Manga & Comic Reader</span>
                  </div>
                </div>
                <div className="settings-list-tile">
                  <div>
                    <strong>版本</strong>
                    <span>{settings?.values.version != null ? String(settings.values.version) : '1.6.3'}</span>
                  </div>
                </div>
                <div className="settings-list-tile">
                  <div>
                    <strong>许可证</strong>
                    <span>MIT License</span>
                  </div>
                </div>
                <div className="settings-list-tile">
                  <div>
                    <strong>GitHub</strong>
                    <span>
                      <a href="https://github.com/kyosee/venera" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--primary)' }}>
                        github.com/kyosee/venera
                      </a>
                    </span>
                  </div>
                </div>
              </div>
            </SettingsPart>
          ) : null}
          {activeSection === 'webdav' ? <WebDavPanel onImportComplete={onImportComplete} /> : null}
          {activeSection === 'hidden' ? (
            <SettingsPart title="Web 屏蔽项" icon={EyeOff}>
              <div className="settings-list">
                {hidden.map((item) => (
                  <div className="settings-list-tile" key={item}>
                    <div>
                      <strong>{item}</strong>
                      <span>Web 端不可用，已隐藏</span>
                    </div>
                  </div>
                ))}
                {hidden.length === 0 ? <EmptyLine icon={EyeOff} text="暂无屏蔽项" /> : null}
              </div>
            </SettingsPart>
          ) : null}
        </section>
      </div>
    </div>
  )
}

function SettingsCategoryButton({
  title,
  icon: Icon,
  count,
  active,
  onClick
}: {
  title: string
  icon: typeof Home
  count?: number
  active: boolean
  onClick: () => void
}) {
  return (
    <button className={active ? 'settings-category active' : 'settings-category'} type="button" onClick={onClick}>
      <Icon size={22} />
      <span>{title}</span>
      {count != null ? <small>{count}</small> : null}
      {active ? <ChevronRight size={18} /> : null}
    </button>
  )
}

function SettingsPart({
  title,
  icon: Icon,
  children
}: {
  title: string
  icon: typeof Home
  children: React.ReactNode
}) {
  return (
    <div className="settings-part">
      <div className="settings-part-title">
        <Icon size={24} />
        <h2>{title}</h2>
      </div>
      {children}
    </div>
  )
}

function SettingRow({
  title,
  subtitle,
  children
}: {
  title: string
  subtitle?: string
  children: React.ReactNode
}) {
  return (
    <div className="settings-list-tile">
      <div>
        <strong>{title}</strong>
        {subtitle ? <span>{subtitle}</span> : null}
      </div>
      <div className="settings-row-control">{children}</div>
    </div>
  )
}

function WebDavPanel({ onImportComplete }: { onImportComplete: () => void | Promise<void> }) {
  const [config, setConfig] = useState<WebDavConfigResponse | null>(null)
  const [endpointUrl, setEndpointUrl] = useState('')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [rootPath, setRootPath] = useState('/')
  const [currentPath, setCurrentPath] = useState('')
  const [entries, setEntries] = useState<WebDavEntry[]>([])
  const [backups, setBackups] = useState<ImportBackupSummary[]>([])
  const [preview, setPreview] = useState<ImportBackupPreviewResponse | null>(null)
  const [importResult, setImportResult] = useState<ImportBackupApplyResponse | null>(null)
  const [uploadResult, setUploadResult] = useState<WebDavUploadResponse | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    void getWebDavConfig()
      .then((next) => {
        setConfig(next)
        setEndpointUrl(next.endpoint_url ?? '')
        setUsername(next.username ?? '')
        setRootPath(next.root_path || '/')
      })
      .catch((err) => setMessage(err instanceof Error ? err.message : 'WebDAV 配置读取失败'))
    void loadBackups()
  }, [])

  const loadBackups = async () => {
    const result = await listImportBackups()
    setBackups(result.backups)
  }

  const handleSave = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setBusy(true)
    setMessage(null)
    try {
      const next = await saveWebDavConfig({
        endpoint_url: endpointUrl,
        username,
        password: password || undefined,
        root_path: rootPath
      })
      setConfig(next)
      setPassword('')
      setMessage('WebDAV 已保存')
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'WebDAV 保存失败')
    } finally {
      setBusy(false)
    }
  }

  const openPath = async (path: string) => {
    setBusy(true)
    setMessage(null)
    try {
      const listing = await listWebDav(path)
      setCurrentPath(listing.path)
      setEntries(listing.entries)
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'WebDAV 读取失败')
    } finally {
      setBusy(false)
    }
  }

  const downloadPath = async (path: string) => {
    setBusy(true)
    setMessage(null)
    try {
      const result = await downloadWebDav(path)
      setMessage(`已下载 ${result.file_name}`)
      await loadBackups()
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'WebDAV 下载失败')
    } finally {
      setBusy(false)
    }
  }

  const previewBackup = async (path: string) => {
    setBusy(true)
    setMessage(null)
    setImportResult(null)
    try {
      setPreview(await previewImportBackup(path))
    } catch (err) {
      setMessage(err instanceof Error ? err.message : '备份预览失败')
    } finally {
      setBusy(false)
    }
  }

  const importBackup = async (path: string) => {
    setBusy(true)
    setMessage(null)
    try {
      const result = await applyImportBackup(path)
      setImportResult(result)
      setMessage(`已导入 ${result.sources_imported} 个源、${result.favorites_imported} 个收藏、${result.history_imported} 条历史`)
      await onImportComplete()
    } catch (err) {
      setMessage(err instanceof Error ? err.message : '备份导入失败')
    } finally {
      setBusy(false)
    }
  }

  const createLocalBackup = async () => {
    setBusy(true)
    setMessage(null)
    setUploadResult(null)
    try {
      const result = await uploadWebDav(true)
      setUploadResult(result)
      setMessage(`已创建本地备份 ${result.file_name}`)
      await loadBackups()
    } catch (err) {
      setMessage(err instanceof Error ? err.message : '本地备份创建失败')
    } finally {
      setBusy(false)
    }
  }

  const uploadBackup = async () => {
    if (!config?.endpoint_url) {
      setMessage('请先保存 WebDAV 配置')
      return
    }
    setBusy(true)
    setMessage(null)
    setUploadResult(null)
    try {
      const result = await uploadWebDav(false)
      setUploadResult(result)
      setMessage(`已上传 ${result.remote_path}`)
      await loadBackups()
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'WebDAV 上传失败')
    } finally {
      setBusy(false)
    }
  }

  const parentPath = currentPath.split('/').filter(Boolean).slice(0, -1).join('/')

  return (
    <Panel title="WebDAV" action={config?.endpoint_url ? '已配置' : undefined}>
      <form className="webdav-form" onSubmit={handleSave}>
        <input
          value={endpointUrl}
          placeholder="WebDAV 地址"
          onChange={(event) => setEndpointUrl(event.target.value)}
        />
        <input value={username} placeholder="用户名" onChange={(event) => setUsername(event.target.value)} />
        <input
          value={password}
          placeholder={config?.password_configured ? '密码已配置' : '密码'}
          type="password"
          onChange={(event) => setPassword(event.target.value)}
        />
        <input value={rootPath} placeholder="根路径" onChange={(event) => setRootPath(event.target.value)} />
        <button className="primary-button" type="submit" disabled={busy || !endpointUrl.trim()}>
          保存
        </button>
        <button className="icon-text-button subtle" type="button" disabled={busy} onClick={() => void openPath('')}>
          <FolderOpen size={16} />
          浏览
        </button>
      </form>
      <div className="webdav-actions">
        <button className="icon-text-button subtle" type="button" disabled={busy} onClick={() => void createLocalBackup()}>
          <Save size={16} />
          创建本地备份
        </button>
        <button
          className="icon-text-button subtle"
          type="button"
          disabled={busy || !config?.endpoint_url}
          onClick={() => void uploadBackup()}
        >
          <Upload size={16} />
          备份并上传
        </button>
      </div>
      {message ? <div className="data-row">{message}</div> : null}
      {entries.length > 0 || currentPath ? (
        <div className="webdav-list">
          <div className="webdav-path">
            <span>{currentPath || '/'}</span>
            {currentPath ? (
              <button className="icon-button" type="button" disabled={busy} onClick={() => void openPath(parentPath)}>
                <FolderOpen size={16} />
              </button>
            ) : null}
          </div>
          {entries.map((entry) => (
            <div className="webdav-row" key={entry.path}>
              <button
                className="webdav-entry-button"
                type="button"
                disabled={busy || !entry.is_dir}
                onClick={() => void openPath(entry.path)}
              >
                {entry.is_dir ? <FolderOpen size={16} /> : <BookOpen size={16} />}
                <span>{entry.name}</span>
              </button>
              {!entry.is_dir ? (
                <button
                  className="icon-button"
                  type="button"
                  disabled={busy}
                  aria-label={`下载 ${entry.name}`}
                  onClick={() => void downloadPath(entry.path)}
                >
                  <Download size={16} />
                </button>
              ) : null}
            </div>
          ))}
        </div>
      ) : null}
      {backups.length > 0 ? (
        <div className="import-backups">
          <div className="section-label">本地备份</div>
          {backups.map((backup) => (
            <div className="webdav-row" key={backup.path}>
              <button
                className="webdav-entry-button"
                type="button"
                disabled={busy}
                onClick={() => void previewBackup(backup.path)}
              >
                <BookOpen size={16} />
                <span>{backup.file_name}</span>
                <small>{formatBytes(backup.size)}</small>
              </button>
              <button
                className="icon-button"
                type="button"
                disabled={busy}
                aria-label={`导入 ${backup.file_name}`}
                onClick={() => void importBackup(backup.path)}
              >
                <Upload size={16} />
              </button>
            </div>
          ))}
        </div>
      ) : null}
      {preview ? <BackupPreview preview={preview} /> : null}
      {importResult ? (
        <div className="import-result">
          源 {importResult.sources_imported}，收藏 {importResult.favorites_imported}，历史 {importResult.history_imported}
          ，跳过 {importResult.favorites_skipped + importResult.history_skipped}
        </div>
      ) : null}
      {uploadResult ? (
        <div className="import-result">
          备份 {uploadResult.file_name}，{formatBytes(uploadResult.size)}，
          {uploadResult.uploaded ? `已上传 ${uploadResult.remote_path}` : '仅创建本地文件'}
        </div>
      ) : null}
    </Panel>
  )
}

function BackupPreview({ preview }: { preview: ImportBackupPreviewResponse }) {
  return (
    <div className="backup-preview">
      <div className="section-label">备份预览</div>
      <div className="backup-stats">
        <span>源 JS {preview.comic_source_js_count}</span>
        <span>源数据 {preview.comic_source_data_count}</span>
        <span>文件 {preview.entry_count}</span>
      </div>
      <div className="data-row">AppData: {preview.appdata_keys.join(', ') || '无'}</div>
      <div className="backup-db-list">
        {preview.databases.map((database) => (
          <div className="backup-db" key={database.name}>
            <strong>{database.name}</strong>
            <span>
              {database.present
                ? database.error
                  ? database.error
                  : `${database.tables.length} 表`
                : '缺失'}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}

function Panel({
  title,
  action,
  children
}: {
  title: string
  action?: string
  children: React.ReactNode
}) {
  return (
    <section className="panel">
      <div className="panel-header">
        <h2>{title}</h2>
        {action ? <span>{action}</span> : null}
      </div>
      {children}
    </section>
  )
}

function SourceList({
  sources,
  compact = false,
  onDelete,
  onToggle
}: {
  sources: SourceSummary[]
  compact?: boolean
  onDelete?: (key: string) => void
  onToggle?: (key: string, enabled: boolean) => void
}) {
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [settingsState, setSettingsState] = useState<Record<string, SourceSettingsCacheItem>>({})
  const [savingSetting, setSavingSetting] = useState<string | null>(null)

  const loadSourceSettings = useCallback(async (key: string) => {
    setSettingsState((current) => ({
      ...current,
      [key]: { loading: true, error: null, data: current[key]?.data ?? null }
    }))
    try {
      const data = await getSourceSettings(key)
      setSettingsState((current) => ({
        ...current,
        [key]: { loading: false, error: null, data }
      }))
    } catch (err) {
      setSettingsState((current) => ({
        ...current,
        [key]: {
          loading: false,
          error: err instanceof Error ? err.message : '读取源设置失败',
          data: current[key]?.data ?? null
        }
      }))
    }
  }, [])

  const handleExpand = (source: SourceSummary) => {
    if (expandedKey === source.key) {
      setExpandedKey(null)
      return
    }
    setExpandedKey(source.key)
    const state = settingsState[source.key]
    if (source.runtime_status === 'registered' && !state?.data && !state?.loading) {
      void loadSourceSettings(source.key)
    }
  }

  const handleSaveSetting = async (
    sourceKey: string,
    setting: SourceSettingItem,
    value: SourceSettingValue
  ) => {
    const saveKey = `${sourceKey}:${setting.key}`
    setSavingSetting(saveKey)
    try {
      const data = await updateSourceSetting(sourceKey, { key: setting.key, value })
      setSettingsState((current) => ({
        ...current,
        [sourceKey]: { loading: false, error: null, data }
      }))
    } catch (err) {
      setSettingsState((current) => ({
        ...current,
        [sourceKey]: {
          loading: false,
          error: err instanceof Error ? err.message : '保存源设置失败',
          data: current[sourceKey]?.data ?? null
        }
      }))
    } finally {
      setSavingSetting(null)
    }
  }

  if (sources.length === 0) {
    return <EmptyLine icon={Library} text="暂无源文件" />
  }

  return (
    <div className={compact ? 'source-list compact' : 'source-list'}>
      {sources.map((source) => {
        const expanded = expandedKey === source.key
        return (
          <div className={expanded ? 'source-item expanded' : 'source-item'} key={source.key}>
            <div className="source-row">
              <button
                className="source-expand-button"
                type="button"
                aria-label={expanded ? `收起 ${source.name}` : `展开 ${source.name}`}
                onClick={() => handleExpand(source)}
              >
                <ChevronDown size={18} />
              </button>
              <button className="source-main source-main-button" type="button" onClick={() => handleExpand(source)}>
                <div className="source-title-row">
                  <strong>{source.name}</strong>
                  {source.version ? <span className="source-version-chip">{source.version}</span> : null}
                </div>
                <span>{source.file_name}</span>
              </button>
              <div className="source-actions">
                <StatusPill
                  ok={source.runtime_status === 'registered' && source.enabled}
                  text={
                    source.runtime_status !== 'registered'
                      ? '待解析'
                      : source.enabled
                        ? '启用'
                        : '停用'
                  }
                />
                {onToggle && source.runtime_status === 'registered' ? (
                  <label className="source-toggle" title={source.enabled ? '停用' : '启用'}>
                    <input
                      type="checkbox"
                      checked={source.enabled}
                      onChange={(event) => onToggle(source.key, event.target.checked)}
                    />
                    <span />
                  </label>
                ) : null}
                {onDelete ? (
                  <button
                    className="icon-button danger"
                    type="button"
                    aria-label={`删除 ${source.name}`}
                    onClick={() => onDelete(source.key)}
                  >
                    <Trash2 size={16} />
                  </button>
                ) : null}
              </div>
            </div>
            {expanded ? (
              <SourceSettingsPanel
                source={source}
                state={settingsState[source.key] ?? emptySourceSettingsState}
                savingSetting={savingSetting}
                onRefresh={() => loadSourceSettings(source.key)}
                onSave={(setting, value) => handleSaveSetting(source.key, setting, value)}
              />
            ) : null}
          </div>
        )
      })}
    </div>
  )
}

type SourceSettingsCacheItem = {
  loading: boolean
  error: string | null
  data: SourceSettingsResponse | null
}

const emptySourceSettingsState: SourceSettingsCacheItem = {
  loading: false,
  error: null,
  data: null
}

function SourceSettingsPanel({
  source,
  state,
  savingSetting,
  onRefresh,
  onSave
}: {
  source: SourceSummary
  state: SourceSettingsCacheItem
  savingSetting: string | null
  onRefresh: () => void
  onSave: (setting: SourceSettingItem, value: SourceSettingValue) => void
}) {
  if (source.runtime_status !== 'registered') {
    return (
      <div className="source-settings-panel">
        <EmptyLine icon={Settings} text="源解析完成后可查看设置" />
      </div>
    )
  }

  const data = state.data
  const showEmpty = data && data.items.length === 0 && !data.account.available

  return (
    <div className="source-settings-panel">
      {state.loading && !data ? (
        <div className="source-settings-message">
          <Loader2 className="spin" size={16} />
          <span>读取设置中</span>
        </div>
      ) : null}
      {state.error ? (
        <div className="source-settings-message error">
          <span>{state.error}</span>
          <button className="icon-button" type="button" aria-label="重试读取源设置" onClick={onRefresh}>
            <RefreshCw size={15} />
          </button>
        </div>
      ) : null}
      {showEmpty ? <EmptyLine icon={Settings} text="该源没有设置项" /> : null}
      {data?.items.map((item) => (
        <SourceSettingControl
          item={item}
          key={item.key}
          saving={savingSetting === `${source.key}:${item.key}`}
          onSave={(value) => onSave(item, value)}
        />
      ))}
      {data?.account.available ? (
        <div className="source-setting-row disabled">
          <div className="source-setting-main">
            <strong>账号</strong>
            <span>{data.account.logged ? 'App 端已有账号数据，Web 登录/退出暂不开放' : 'Web 端登录暂不开放'}</span>
          </div>
          <StatusPill ok={data.account.logged} text={data.account.logged ? '已登录' : '隐藏'} />
        </div>
      ) : null}
    </div>
  )
}

function SourceSettingControl({
  item,
  saving,
  onSave
}: {
  item: SourceSettingItem
  saving: boolean
  onSave: (value: SourceSettingValue) => void
}) {
  const currentValue = sourceSettingValue(item)

  if (!item.supported || item.type === 'callback') {
    return (
      <div className="source-setting-row disabled">
        <div className="source-setting-main">
          <strong>{item.title}</strong>
          <span>{item.type === 'callback' ? 'Web 端暂不执行源回调' : `暂不支持 ${item.type}`}</span>
        </div>
        <span className="muted-text">{item.button_text ?? '隐藏'}</span>
      </div>
    )
  }

  if (item.type === 'switch') {
    return (
      <div className="source-setting-row">
        <div className="source-setting-main">
          <strong>{item.title}</strong>
          <span>{settingValueText(currentValue)}</span>
        </div>
        <label className="source-toggle" title={Boolean(currentValue) ? '关闭' : '开启'}>
          <input
            type="checkbox"
            checked={Boolean(currentValue)}
            disabled={saving}
            onChange={(event) => onSave(event.target.checked)}
          />
          <span />
        </label>
      </div>
    )
  }

  if (item.type === 'select') {
    const selectedIndex = Math.max(
      0,
      item.options.findIndex((option) => settingValuesEqual(option.value, currentValue))
    )
    return (
      <div className="source-setting-row">
        <div className="source-setting-main">
          <strong>{item.title}</strong>
          <span>{item.options[selectedIndex]?.text ?? settingValueText(currentValue)}</span>
        </div>
        <select
          className="source-setting-select"
          disabled={saving || item.options.length === 0}
          value={String(selectedIndex)}
          onChange={(event) => {
            const option = item.options[Number(event.target.value)]
            if (option) onSave(option.value)
          }}
        >
          {item.options.map((option, index) => (
            <option key={`${item.key}:${index}:${settingValueText(option.value)}`} value={String(index)}>
              {option.text}
            </option>
          ))}
        </select>
      </div>
    )
  }

  return <SourceInputSetting item={item} saving={saving} onSave={onSave} />
}

function SourceInputSetting({
  item,
  saving,
  onSave
}: {
  item: SourceSettingItem
  saving: boolean
  onSave: (value: SourceSettingValue) => void
}) {
  const currentValue = sourceSettingValue(item)
  const currentText = settingValueText(currentValue)
  const [draft, setDraft] = useState(currentText)

  useEffect(() => {
    setDraft(currentText)
  }, [currentText, item.key])

  const changed = draft !== currentText
  const save = () => {
    if (!changed || saving) return
    onSave(draft)
  }

  return (
    <div className="source-setting-row input">
      <div className="source-setting-main">
        <strong>{item.title}</strong>
        <input
          value={draft}
          pattern={item.validator ?? undefined}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') save()
          }}
        />
      </div>
      <button
        className="icon-button"
        type="button"
        title="保存"
        aria-label={`保存 ${item.title}`}
        disabled={!changed || saving}
        onClick={save}
      >
        <Save size={15} />
      </button>
    </div>
  )
}

function sourceSettingValue(item: SourceSettingItem): SourceSettingValue {
  return item.value ?? item.default ?? null
}

function settingValueText(value: SourceSettingValue): string {
  if (value == null) return ''
  return String(value)
}

function settingValuesEqual(left: SourceSettingValue, right: SourceSettingValue) {
  return left === right || settingValueText(left) === settingValueText(right)
}

function EmptyLine({ icon: Icon, text }: { icon: typeof Home; text: string }) {
  return (
    <div className="empty-line">
      <Icon size={18} />
      <span>{text}</span>
    </div>
  )
}

function StatusPill({ ok, text }: { ok: boolean; text: string }) {
  return <span className={ok ? 'status-pill ok' : 'status-pill warn'}>{text}</span>
}
