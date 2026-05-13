import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  BookOpen,
  Bookmark,
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
  MessageCircle,
  MoreHorizontal,
  Play,
  Share2,
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
  type SourceCategoryItem,
  type SourceCategoryPart,
  type SourceComicListResponse,
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

type PrimaryTabKey = 'home' | 'favorites' | 'explore' | 'categories'

type AppData = {
  health: HealthResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
  library: LibraryResponse
  followUpdates: FollowUpdatesResponse
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

export default function App() {
  const [activeTab, setActiveTab] = useState<TabKey>('home')
  const [activePrimaryTab, setActivePrimaryTab] = useState<PrimaryTabKey>('home')
  const [route, setRoute] = useState<AppRoute>({ kind: 'main' })
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

  return (
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
              onBack={closeStandalonePage}
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
            />
          ) : null}
          {route.kind === 'main' && activeTab === 'tasks' ? <TasksView onBack={closeStandalonePage} /> : null}
          {route.kind === 'main' && activeTab === 'settings' ? (
            <SettingsView
              settings={data.settings}
              themeMode={themeMode}
              readerMode={readerMode}
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

      <section className="sync-card">
        <RefreshCw size={20} />
        <div>
          <strong>同步数据</strong>
          <span>WebDAV 当前为只读下载，上传待功能稳定后启用</span>
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
        <HomeCard title="本地" count={0} icon={FolderOpen} onOpen={() => undefined}>
          <div className="home-card-empty">
            <EmptyLine icon={FolderOpen} text="Web 端暂未接入本地导入" />
          </div>
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
        <HomeCard title="图片收藏" count={0} icon={Bookmark} onOpen={() => undefined}>
          <div className="home-card-empty">
            <EmptyLine icon={Bookmark} text="暂无图片收藏数据" />
          </div>
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
  onSetFavorite
}: {
  request: ComicOpenRequest
  favorites: LibraryItem[]
  onBack: () => void
  onOpenReader: (request: ReaderOpenRequest) => void
  onSetFavorite: (payload: FavoriteWriteRequest) => Promise<void>
}) {
  const [comic, setComic] = useState<ComicInfo | null>(request.initialComic ?? null)
  const [loading, setLoading] = useState(!request.initialComic)
  const [message, setMessage] = useState<string | null>(null)
  const [favoriteBusy, setFavoriteBusy] = useState(false)

  useEffect(() => {
    let cancelled = false
    setComic(request.initialComic ?? null)
    setLoading(!request.initialComic)
    setMessage(null)
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

  const isFavorite = Boolean(
    comic && favorites.some((item) => item.source_key === request.sourceKey && item.comic_id === comic.id)
  )
  const firstEpisode = comic?.episodes[0]

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

  const openEpisode = (episode: ComicEpisode) => {
    if (!comic) return
    onOpenReader({ sourceKey: request.sourceKey, comic, episode })
  }

  return (
    <article className="comic-detail-page">
      <PageHeader
        title={comic?.title ?? request.title}
        onBack={onBack}
        actions={
          <button className="top-action-button" type="button" aria-label="更多" title="更多">
            <MoreHorizontal size={20} />
          </button>
        }
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
              <div className="metadata-chips">
                <span>{request.sourceKey}</span>
                <span>{comic.episodes.length} 章</span>
                {comic.tags.slice(0, 3).map((tag) => (
                  <span key={tag}>{tag}</span>
                ))}
              </div>
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
            <button className="detail-action" type="button" disabled>
              <Download size={18} />
              <span>下载</span>
            </button>
            <button className="detail-action" type="button" disabled>
              <MessageCircle size={18} />
              <span>评论</span>
            </button>
            <button className="detail-action" type="button" disabled>
              <Share2 size={18} />
              <span>分享</span>
            </button>
          </section>
          {message ? <EmptyLine icon={BookOpen} text={message} /> : null}
          {comic.description ? (
            <section className="detail-section">
              <h3>简介</h3>
              <p>{comic.description}</p>
            </section>
          ) : null}
          <section className="detail-section">
            <h3>章节</h3>
            {comic.episodes.length === 0 ? (
              <EmptyLine icon={BookOpen} text="暂无章节" />
            ) : (
              <div className="chapter-grid">
                {comic.episodes.map((episode) => (
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
  const activePageIndex = images.length === 0 ? 0 : Math.min(pageIndex, images.length - 1)
  const visibleImages = isGalleryMode ? images.slice(activePageIndex, activePageIndex + 1) : images

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setMessage(null)
    setImages([])
    setPageIndex(0)
    void getComicPages(request.sourceKey, request.comic.id, request.episode.id)
      .then(async (response) => {
        if (cancelled) return
        setImages(response.images)
        setMessage(response.images.length === 0 ? '暂无图片' : null)
        if (response.images.length > 0) {
          await onRecordHistory({
            source_key: request.sourceKey,
            comic_id: request.comic.id,
            title: request.comic.title,
            subtitle: request.comic.subtitle,
            cover: request.comic.cover,
            episode_id: request.episode.id,
            episode_title: request.episode.title
          })
        }
      })
      .catch((err) => {
        if (!cancelled) setMessage(err instanceof Error ? err.message : '章节加载失败')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [onRecordHistory, request.comic, request.episode, request.sourceKey])

  const readerModeLabel = readerModeOptions.find((option) => option.key === readerMode)?.label

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
        <button className="icon-button" type="button" aria-label="更多">
          <MoreHorizontal size={20} />
        </button>
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

function SearchView({
  sources,
  onBack,
  onSourceUpload,
  onSourceDelete,
  onSourceToggle,
  onOpenComic
}: {
  sources: SourceSummary[]
  onBack: () => void
  onSourceUpload: (file: File) => Promise<void>
  onSourceDelete: (key: string) => Promise<void>
  onSourceToggle: (key: string, enabled: boolean) => Promise<void>
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  const [keyword, setKeyword] = useState('')
  const [selectedSource, setSelectedSource] = useState('')
  const [searching, setSearching] = useState(false)
  const [searchMessage, setSearchMessage] = useState<string | null>(null)
  const [results, setResults] = useState<SearchComic[]>([])
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

  const handleSourceChange = (value: string) => {
    setSelectedSource(value)
    setResults([])
    setSearchMessage(null)
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
      setSearchMessage(response.comics.length === 0 ? '没有结果' : null)
    } catch (err) {
      setResults([])
      setSearchMessage(err instanceof Error ? err.message : '搜索失败')
    } finally {
      setSearching(false)
    }
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
      <PageHeader title="搜索" onBack={onBack} />
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
          <SearchResults
            comics={results}
            onSelect={(comic) => {
              if (selectedSource) onOpenComic(searchComicToOpenRequest(selectedSource, comic))
            }}
          />
        )}
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
  onBack,
  onOpenComic
}: {
  data: FollowUpdatesResponse
  onBack: () => void
  onOpenComic: (request: ComicOpenRequest) => void
}) {
  const [activeList, setActiveList] = useState<'updated' | 'all'>('updated')
  const visibleItems = activeList === 'updated' ? data.updated : data.all
  const visibleTotal = activeList === 'updated' ? data.updated_total : data.all_total

  return (
    <div className="view-stack">
      <PageHeader title="追更" onBack={onBack} />
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
          onSelect={(item) => onOpenComic(libraryItemToOpenRequest(item))}
        />
      </Panel>
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
  onOpenComic
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
}) {
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
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '更早'
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
          <CoverImage url={comic.cover} iconSize={18} />
          <strong>{comic.title}</strong>
          {comic.subtitle ? <small>{comic.subtitle}</small> : null}
          {comic.tags.length > 0 ? <small>{comic.tags.slice(0, 2).join(' / ')}</small> : null}
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

function TasksView({ onBack }: { onBack: () => void }) {
  return (
    <div className="view-stack">
      <PageHeader title="任务" onBack={onBack} />
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
  onBack,
  onThemeChange,
  onReaderModeChange,
  onImportComplete
}: {
  settings: SettingsResponse | null
  themeMode: string
  readerMode: ReaderMode
  onBack: () => void
  onThemeChange: (value: string) => Promise<void>
  onReaderModeChange: (value: ReaderMode) => Promise<void>
  onImportComplete: () => void | Promise<void>
}) {
  const hidden = settings?.hidden_features ?? []

  return (
    <div className="view-stack">
      <PageHeader title="设置" onBack={onBack} />
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
