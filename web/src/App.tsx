import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  BookOpen,
  ChevronLeft,
  ChevronRight,
  ClipboardList,
  Compass,
  Download,
  EyeOff,
  FolderOpen,
  Heart,
  History,
  Home,
  Library,
  Loader2,
  Trash2,
  Upload,
  RefreshCw,
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
  type SourcePageManifest,
  type SourcePagesResponse,
  type SourceSummary,
  type WebDavConfigResponse,
  type WebDavEntry,
  applyImportBackup,
  getComicInfo,
  getComicPages,
  getFollowUpdates,
  getHealth,
  getLibrary,
  getSettings,
  getSourcePages,
  getSources,
  getWebDavConfig,
  listImportBackups,
  listWebDav,
  previewImportBackup,
  saveSource,
  saveWebDavConfig,
  deleteSource,
  downloadWebDav,
  imageProxyUrl,
  recordHistory,
  searchComics,
  setFavorite,
  updateSource,
  updateSettings
} from './api'
import { ReloadPrompt } from './ReloadPrompt'

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

type AppData = {
  health: HealthResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
  library: LibraryResponse
  followUpdates: FollowUpdatesResponse
}

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
  { key: 'history', label: '历史', icon: History },
  { key: 'favorites', label: '收藏', icon: Heart },
  { key: 'explore', label: '发现', icon: Compass },
  { key: 'categories', label: '分类', icon: Tags }
] satisfies Array<{ key: TabKey; label: string; icon: typeof Home }>

const actionNav = [
  { key: 'updates', label: '追更', icon: RefreshCw },
  { key: 'search', label: '搜索', icon: Search },
  { key: 'tasks', label: '任务', icon: ClipboardList },
  { key: 'settings', label: '设置', icon: Settings }
] satisfies Array<{ key: TabKey; label: string; icon: typeof Home }>

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
  followUpdates: { folder: null, updated_total: 0, all_total: 0, updated: [], all: [] }
}

const libraryPageStep = 100

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

export default function App() {
  const [activeTab, setActiveTab] = useState<TabKey>('home')
  const [data, setData] = useState<AppData>(emptyData)
  const [loading, setLoading] = useState(true)
  const [loadingMoreLibrary, setLoadingMoreLibrary] = useState<'history' | 'favorites' | null>(null)
  const [activeFavoriteFolder, setActiveFavoriteFolder] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [lastUpdated, setLastUpdated] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [health, settings, sources, library, followUpdates] = await Promise.all([
        getHealth(),
        getSettings(),
        getSources(),
        getLibrary(),
        getFollowUpdates()
      ])
      setData({ health, settings, sources, library, followUpdates })
      setActiveFavoriteFolder(null)
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

  const saveHistory = async (payload: HistoryWriteRequest) => {
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
  }

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

  return (
    <div className="app-shell">
      <SideNav activeTab={activeTab} onSelect={setActiveTab} />
      <main className="main-area">
        <TopBar
          health={data.health}
          loading={loading}
          error={error}
          lastUpdated={lastUpdated}
          onRefresh={load}
        />
        <div className="content">
          {activeTab === 'home' ? (
            <HomeView
              data={data}
              error={error}
              readerMode={readerMode}
              onOpenTab={setActiveTab}
              onRecordHistory={saveHistory}
            />
          ) : null}
          {activeTab === 'history' ? (
            <LibraryView
              title="历史记录"
              icon={History}
              items={data.library.history}
              total={data.library.history_total}
              emptyText="暂无阅读记录"
              loadingMore={loadingMoreLibrary === 'history'}
              onLoadMore={
                data.library.history.length < data.library.history_total
                  ? () => loadMoreLibrary('history')
                  : undefined
              }
              readerMode={readerMode}
              onRecordHistory={saveHistory}
            />
          ) : null}
          {activeTab === 'favorites' ? (
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
              readerMode={readerMode}
              onRecordHistory={saveHistory}
            />
          ) : null}
          {activeTab === 'explore' ? (
            <SourcePagesView title="发现" icon={Compass} kind="explore" />
          ) : null}
          {activeTab === 'categories' ? (
            <SourcePagesView title="分类" icon={Tags} kind="categories" />
          ) : null}
          {activeTab === 'updates' ? (
            <UpdatesView
              data={data.followUpdates}
              readerMode={readerMode}
              onRecordHistory={saveHistory}
            />
          ) : null}
          {activeTab === 'search' ? (
            <SearchView
              sources={data.sources}
              favorites={data.library.favorites}
              readerMode={readerMode}
              onSourceUpload={upsertSource}
              onSourceDelete={removeSource}
              onSourceToggle={toggleSource}
              onRecordHistory={saveHistory}
              onSetFavorite={saveFavorite}
            />
          ) : null}
          {activeTab === 'tasks' ? <TasksView /> : null}
          {activeTab === 'settings' ? (
            <SettingsView
              settings={data.settings}
              themeMode={themeMode}
              readerMode={readerMode}
              onThemeChange={setThemeMode}
              onReaderModeChange={setReaderMode}
              onImportComplete={load}
            />
          ) : null}
        </div>
      </main>
      <BottomNav activeTab={activeTab} onSelect={setActiveTab} />
      <ReloadPrompt />
    </div>
  )
}

function SideNav({
  activeTab,
  onSelect
}: {
  activeTab: TabKey
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
          <NavButton key={item.key} item={item} active={activeTab === item.key} onSelect={onSelect} />
        ))}
      </nav>
    </aside>
  )
}

function BottomNav({
  activeTab,
  onSelect
}: {
  activeTab: TabKey
  onSelect: (tab: TabKey) => void
}) {
  return (
    <nav className="bottom-nav" aria-label="底部导航">
      {[...primaryNav, ...actionNav].map((item) => (
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
  health,
  loading,
  error,
  lastUpdated,
  onRefresh
}: {
  health: HealthResponse | null
  loading: boolean
  error: string | null
  lastUpdated: string | null
  onRefresh: () => void
}) {
  const isNormal =
    health?.status === 'ok' &&
    health.database === 'sqlite' &&
    health.data_dir.trim().length > 0 &&
    health.source_runtime &&
    !error

  return (
    <header className="top-bar">
      <div>
        <h1>Venera</h1>
        <p>{isNormal ? `服务端 ${health.version}` : '服务或数据异常'}</p>
      </div>
      <div className="top-actions">
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
  readerMode,
  onOpenTab,
  onRecordHistory
}: {
  data: AppData
  error: string | null
  readerMode: ReaderMode
  onOpenTab: (tab: TabKey) => void
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [selectedItem, setSelectedItem] = useState<LibraryItem | null>(null)

  return (
    <div className="view-stack">
      <section className="search-strip" aria-label="搜索">
        <Search size={20} />
        <input placeholder="搜索漫画" disabled />
        <button className="primary-button" disabled>
          搜索
        </button>
      </section>

      {error ? (
        <section className="notice error">
          <WifiOff size={18} />
          <span>{error}</span>
        </section>
      ) : null}

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
            onSelect={setSelectedItem}
          />
        </HomeCard>
        <HomeCard
          title="收藏"
          count={data.library.favorites_total}
          icon={Heart}
          onOpen={() => onOpenTab('favorites')}
        >
          <ComicStrip
            items={data.library.favorites.slice(0, 8)}
            emptyText="暂无收藏"
            onSelect={setSelectedItem}
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
            onSelect={setSelectedItem}
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
      {selectedItem ? (
        <Panel title="漫画详情">
          <LibraryReader
            item={selectedItem}
            readerMode={readerMode}
            onRecordHistory={onRecordHistory}
          />
        </Panel>
      ) : null}
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

function SearchView({
  sources,
  favorites,
  readerMode,
  onSourceUpload,
  onSourceDelete,
  onSourceToggle,
  onRecordHistory,
  onSetFavorite
}: {
  sources: SourceSummary[]
  favorites: LibraryItem[]
  readerMode: ReaderMode
  onSourceUpload: (file: File) => Promise<void>
  onSourceDelete: (key: string) => Promise<void>
  onSourceToggle: (key: string, enabled: boolean) => Promise<void>
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
  onSetFavorite: (payload: FavoriteWriteRequest) => Promise<void>
}) {
  const [keyword, setKeyword] = useState('')
  const [selectedSource, setSelectedSource] = useState('')
  const [searching, setSearching] = useState(false)
  const [searchMessage, setSearchMessage] = useState<string | null>(null)
  const [results, setResults] = useState<SearchComic[]>([])
  const [selectedComic, setSelectedComic] = useState<ComicInfo | null>(null)
  const [comicMessage, setComicMessage] = useState<string | null>(null)
  const [images, setImages] = useState<string[]>([])
  const [activeEpisodeTitle, setActiveEpisodeTitle] = useState<string | null>(null)
  const [loadingComic, setLoadingComic] = useState(false)
  const [loadingImages, setLoadingImages] = useState(false)
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
    setSelectedComic(null)
    setComicMessage(null)
    setImages([])
    setActiveEpisodeTitle(null)
    if (!nextSource) {
      setKeyword('')
    }
  }, [enabledSources, selectedSource])

  const handleSourceChange = (value: string) => {
    setSelectedSource(value)
    setResults([])
    setSearchMessage(null)
    setSelectedComic(null)
    setComicMessage(null)
    setImages([])
    setActiveEpisodeTitle(null)
  }

  const handleSearch = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const value = keyword.trim()
    if (!value || !selectedSource) return

    setSearching(true)
    setSearchMessage(null)
    try {
      const response = await searchComics(selectedSource, value, 1)
      setResults(response.comics)
      setSelectedComic(null)
      setImages([])
      setActiveEpisodeTitle(null)
      setSearchMessage(response.comics.length === 0 ? '没有结果' : null)
    } catch (err) {
      setResults([])
      setSearchMessage(err instanceof Error ? err.message : '搜索失败')
    } finally {
      setSearching(false)
    }
  }

  const handleOpenComic = async (comic: SearchComic) => {
    if (!selectedSource) return

    setLoadingComic(true)
    setComicMessage(null)
    setImages([])
    setActiveEpisodeTitle(null)
    try {
      const response = await getComicInfo(selectedSource, comic.id)
      setSelectedComic(response.comic)
      setComicMessage(response.comic.episodes.length === 0 ? '暂无章节' : null)
    } catch (err) {
      setSelectedComic(null)
      setComicMessage(err instanceof Error ? err.message : '详情加载失败')
    } finally {
      setLoadingComic(false)
    }
  }

  const handleLoadImages = async (episode: ComicEpisode) => {
    if (!selectedSource || !selectedComic) return

    setLoadingImages(true)
    setComicMessage(null)
    try {
      const response = await getComicPages(selectedSource, selectedComic.id, episode.id)
      setImages(response.images)
      setActiveEpisodeTitle(episode.title)
      setComicMessage(response.images.length === 0 ? '暂无图片' : null)
      if (response.images.length > 0) {
        await onRecordHistory({
          source_key: selectedSource,
          comic_id: selectedComic.id,
          title: selectedComic.title,
          subtitle: selectedComic.subtitle,
          cover: selectedComic.cover,
          episode_id: episode.id,
          episode_title: episode.title
        })
      }
    } catch (err) {
      setImages([])
      setActiveEpisodeTitle(null)
      setComicMessage(err instanceof Error ? err.message : '章节加载失败')
    } finally {
      setLoadingImages(false)
    }
  }

  const handleFavoriteChange = async (comic: ComicInfo, favorite: boolean) => {
    if (!selectedSource) return
    await onSetFavorite({
      source_key: selectedSource,
      comic_id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      cover: comic.cover,
      favorite
    })
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

  return (
    <div className="view-stack">
      <form className="search-strip" aria-label="搜索" onSubmit={handleSearch}>
        <Search size={20} />
        <input
          value={keyword}
          placeholder={selectedSource ? '关键词' : '先启用漫画源'}
          disabled={!selectedSource || searching}
          onChange={(event) => setKeyword(event.target.value)}
        />
        <select
          value={selectedSource}
          disabled={enabledSources.length === 0 || searching}
          aria-label="漫画源"
          onChange={(event) => handleSourceChange(event.target.value)}
        >
          {enabledSources.map((source) => (
            <option key={source.key} value={source.key}>
              {source.name}
            </option>
          ))}
        </select>
        <button className="primary-button" disabled={!keyword.trim() || !selectedSource || searching} type="submit">
          {searching ? '搜索中' : '搜索'}
        </button>
      </form>
      <Panel title="搜索结果" action={String(results.length)}>
        {searchMessage ? (
          <EmptyLine icon={Search} text={searchMessage} />
        ) : (
          <SearchResults comics={results} onSelect={handleOpenComic} />
        )}
      </Panel>
      <Panel title="漫画详情" action={selectedComic ? String(selectedComic.episodes.length) : undefined}>
        <ComicDetails
          comic={selectedComic}
          images={images}
          activeEpisodeTitle={activeEpisodeTitle}
          readerMode={readerMode}
          favorite={Boolean(
            selectedComic &&
              favorites.some(
                (item) => item.source_key === selectedSource && item.comic_id === selectedComic.id
              )
          )}
          loadingComic={loadingComic}
          loadingImages={loadingImages}
          message={comicMessage}
          onLoadImages={handleLoadImages}
          onFavoriteChange={handleFavoriteChange}
        />
      </Panel>
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
  readerMode,
  onRecordHistory
}: {
  data: FollowUpdatesResponse
  readerMode: ReaderMode
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [selectedItem, setSelectedItem] = useState<LibraryItem | null>(null)
  const [activeList, setActiveList] = useState<'updated' | 'all'>('updated')
  const visibleItems = activeList === 'updated' ? data.updated : data.all
  const visibleTotal = activeList === 'updated' ? data.updated_total : data.all_total

  return (
    <div className="view-stack">
      <section className="follow-config-card">
        <div className="follow-config-title">
          <RefreshCw size={20} />
          <strong>追更</strong>
          <span>{data.folder ?? '全部收藏夹'}</span>
        </div>
        <div className="follow-config-stats">
          <span>更新 {data.updated_total}</span>
          <span>追踪 {data.all_total}</span>
        </div>
      </section>
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
          onSelect={setSelectedItem}
        />
      </Panel>
      {selectedItem ? (
        <Panel title="漫画详情">
          <LibraryReader
            item={selectedItem}
            readerMode={readerMode}
            onRecordHistory={onRecordHistory}
          />
        </Panel>
      ) : null}
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
  readerMode,
  onFolderSelect,
  onLoadMore,
  onRecordHistory
}: {
  items: LibraryItem[]
  total: number
  allTotal: number
  folders: FavoriteFolder[]
  activeFolder: string | null
  loadingFolder?: boolean
  loadingMore?: boolean
  readerMode: ReaderMode
  onFolderSelect: (folder: string | null) => Promise<void>
  onLoadMore?: () => void
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [selectedItem, setSelectedItem] = useState<LibraryItem | null>(null)
  const activeFolderTitle =
    activeFolder == null
      ? '全部'
      : folders.find((folder) => folder.name === activeFolder)?.title ?? activeFolder

  return (
    <div className="favorite-layout">
      <aside className="favorite-folder-panel" aria-label="收藏文件夹">
        <div className="folder-section-title">本地收藏</div>
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
          />
        ))}
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
              onSelect={setSelectedItem}
            />
          )}
          {onLoadMore ? (
            <button
              className="icon-text-button subtle library-more-button"
              type="button"
              disabled={loadingMore}
              onClick={onLoadMore}
            >
              {loadingMore ? <Loader2 size={16} className="spin" /> : <RefreshCw size={16} />}
              {loadingMore ? '加载中' : `加载更多 (${items.length}/${total})`}
            </button>
          ) : null}
        </Panel>
        {selectedItem ? (
          <Panel title="漫画详情">
            <LibraryReader
              item={selectedItem}
              readerMode={readerMode}
              onRecordHistory={onRecordHistory}
            />
          </Panel>
        ) : null}
      </div>
    </div>
  )
}

function FavoriteFolderButton({
  title,
  count,
  active,
  onClick
}: {
  title: string
  count: number
  active: boolean
  onClick: () => void
}) {
  return (
    <button
      className={active ? 'favorite-folder-button active' : 'favorite-folder-button'}
      type="button"
      onClick={onClick}
    >
      <span>{title}</span>
      <small>{count}</small>
    </button>
  )
}

function LibraryView({
  title,
  icon: Icon,
  items,
  total,
  emptyText,
  loadingMore = false,
  readerMode,
  onLoadMore,
  onRecordHistory
}: {
  title: string
  icon: typeof Home
  items: LibraryItem[]
  total: number
  emptyText: string
  loadingMore?: boolean
  readerMode: ReaderMode
  onLoadMore?: () => void
  onRecordHistory: (payload: HistoryWriteRequest) => Promise<void>
}) {
  const [selectedItem, setSelectedItem] = useState<LibraryItem | null>(null)

  return (
    <div className="view-stack">
      <Panel title={title} action={String(total)}>
        <LibraryGrid items={items} emptyText={emptyText} icon={Icon} onSelect={setSelectedItem} />
        {onLoadMore ? (
          <button
            className="icon-text-button subtle library-more-button"
            type="button"
            disabled={loadingMore}
            onClick={onLoadMore}
          >
            {loadingMore ? <Loader2 size={16} className="spin" /> : <RefreshCw size={16} />}
            {loadingMore ? '加载中' : `加载更多 (${items.length}/${total})`}
          </button>
        ) : null}
      </Panel>
      {selectedItem ? (
        <Panel title="漫画详情">
          <LibraryReader
            item={selectedItem}
            readerMode={readerMode}
            onRecordHistory={onRecordHistory}
          />
        </Panel>
      ) : null}
    </div>
  )
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
  return (
    <button
      className={compact ? 'comic-tile compact' : 'comic-tile'}
      type="button"
      onClick={() => onSelect?.(item)}
      title={item.title}
    >
      <CoverImage url={item.cover} iconSize={18} />
      <strong>{item.title}</strong>
      {item.episode_title ? <span>{item.episode_title}</span> : null}
      {item.subtitle ? <small>{item.subtitle}</small> : null}
    </button>
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
  kind
}: {
  title: string
  icon: typeof Home
  kind: 'explore' | 'categories'
}) {
  const [data, setData] = useState<SourcePagesResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

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

  return (
    <div className="view-stack">
      <Panel title={title} action={loading ? '...' : String(tabs.length)}>
        {error ? <EmptyLine icon={WifiOff} text={error} /> : null}
        {!error && loading ? <EmptyLine icon={Loader2} text="加载中" /> : null}
        {!error && !loading && tabs.length === 0 ? <EmptyLine icon={Icon} text="暂无条目" /> : null}
        {!error && !loading && selectedTab ? (
          <>
            <SourceAppTabs tabs={tabs} selectedKey={selectedTab.key} onSelect={setSelectedKey} />
            <SourcePageContent tab={selectedTab} kind={kind} />
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
  kind
}: {
  tab: SourcePageTab
  kind: 'explore' | 'categories'
}) {
  if (kind === 'explore') {
    return (
      <div className="source-explore-page">
        <div className="source-section-title">
          <strong>{tab.title}</strong>
          {tab.subtitle ? <span>{tab.subtitle}</span> : null}
        </div>
        <EmptyLine icon={Compass} text="暂无条目" />
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
                <span className="category-chip" key={`${part.title}:${item.label}:${item.param ?? ''}`}>
                  {item.label}
                </span>
              ))}
              {remaining > 0 ? <span className="category-chip muted">+{remaining}</span> : null}
            </div>
          </section>
        )
      })}
    </div>
  )
}

function TasksView() {
  return (
    <div className="view-stack">
      <Panel title="任务" action="0">
        <EmptyLine icon={ClipboardList} text="暂无后台任务" />
      </Panel>
    </div>
  )
}

function SettingsView({
  settings,
  themeMode,
  readerMode,
  onThemeChange,
  onReaderModeChange,
  onImportComplete
}: {
  settings: SettingsResponse | null
  themeMode: string
  readerMode: ReaderMode
  onThemeChange: (value: string) => Promise<void>
  onReaderModeChange: (value: ReaderMode) => Promise<void>
  onImportComplete: () => void | Promise<void>
}) {
  const hidden = settings?.hidden_features ?? []

  return (
    <div className="view-stack">
      <Panel title="显示">
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
      </Panel>
      <Panel title="阅读方式">
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
      </Panel>
      <WebDavPanel onImportComplete={onImportComplete} />
      <Panel title="Web 屏蔽项" action={String(hidden.length)}>
        <div className="hidden-list">
          {hidden.map((item) => (
            <div className="data-row" key={item}>
              <EyeOff size={17} />
              <span>{item}</span>
            </div>
          ))}
        </div>
      </Panel>
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

  const parentPath = currentPath.split('/').filter(Boolean).slice(0, -1).join('/')

  return (
    <Panel title="WebDAV" action={config?.read_only ? '只读' : undefined}>
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
  if (sources.length === 0) {
    return <EmptyLine icon={Library} text="暂无源文件" />
  }

  return (
    <div className={compact ? 'source-list compact' : 'source-list'}>
      {sources.map((source) => (
        <div className="source-row" key={source.key}>
          <div className="source-main">
            <div className="source-title-row">
              <strong>{source.name}</strong>
              {source.version ? <span className="source-version-chip">{source.version}</span> : null}
            </div>
            <span>{source.file_name}</span>
          </div>
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
      ))}
    </div>
  )
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
