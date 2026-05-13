import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  BookOpen,
  ClipboardList,
  Compass,
  EyeOff,
  Heart,
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
  type HistoryWriteRequest,
  type HealthResponse,
  type LibraryItem,
  type LibraryResponse,
  type SearchComic,
  type SettingsResponse,
  type SourceSummary,
  getComicInfo,
  getComicPages,
  getHealth,
  getLibrary,
  getSettings,
  getSources,
  saveSource,
  deleteSource,
  imageProxyUrl,
  recordHistory,
  searchComics,
  setFavorite,
  updateSettings
} from './api'
import { ReloadPrompt } from './ReloadPrompt'

type TabKey = 'home' | 'favorites' | 'explore' | 'categories' | 'search' | 'tasks' | 'settings'

type AppData = {
  health: HealthResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
  library: LibraryResponse
}

const primaryNav = [
  { key: 'home', label: '首页', icon: Home },
  { key: 'favorites', label: '收藏', icon: Heart },
  { key: 'explore', label: '发现', icon: Compass },
  { key: 'categories', label: '分类', icon: Tags }
] satisfies Array<{ key: TabKey; label: string; icon: typeof Home }>

const actionNav = [
  { key: 'search', label: '搜索', icon: Search },
  { key: 'tasks', label: '任务', icon: ClipboardList },
  { key: 'settings', label: '设置', icon: Settings }
] satisfies Array<{ key: TabKey; label: string; icon: typeof Home }>

const emptyData: AppData = {
  health: null,
  settings: null,
  sources: [],
  library: { history: [], favorites: [] }
}

export default function App() {
  const [activeTab, setActiveTab] = useState<TabKey>('home')
  const [data, setData] = useState<AppData>(emptyData)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [lastUpdated, setLastUpdated] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [health, settings, sources, library] = await Promise.all([
        getHealth(),
        getSettings(),
        getSources(),
        getLibrary()
      ])
      setData({ health, settings, sources, library })
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

  useEffect(() => {
    document.documentElement.dataset.theme = themeMode === 'dark' ? 'dark' : 'light'
  }, [themeMode])

  const setThemeMode = async (value: string) => {
    const next = await updateSettings({ themeMode: value })
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

  const saveHistory = async (payload: HistoryWriteRequest) => {
    const library = await recordHistory(payload)
    setData((current) => ({ ...current, library }))
  }

  const saveFavorite = async (payload: FavoriteWriteRequest) => {
    const library = await setFavorite(payload)
    setData((current) => ({ ...current, library }))
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
          {activeTab === 'home' ? <HomeView data={data} error={error} /> : null}
          {activeTab === 'favorites' ? (
            <LibraryView title="收藏" icon={Heart} items={data.library.favorites} emptyText="暂无收藏" />
          ) : null}
          {activeTab === 'explore' ? <CollectionView title="发现" icon={Compass} /> : null}
          {activeTab === 'categories' ? <CollectionView title="分类" icon={Tags} /> : null}
          {activeTab === 'search' ? (
            <SearchView
              sources={data.sources}
              favorites={data.library.favorites}
              onSourceUpload={upsertSource}
              onSourceDelete={removeSource}
              onRecordHistory={saveHistory}
              onSetFavorite={saveFavorite}
            />
          ) : null}
          {activeTab === 'tasks' ? <TasksView /> : null}
          {activeTab === 'settings' ? (
            <SettingsView settings={data.settings} themeMode={themeMode} onThemeChange={setThemeMode} />
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
      {[primaryNav[0], primaryNav[1], primaryNav[2], actionNav[0], actionNav[2]].map((item) => (
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

function HomeView({ data, error }: { data: AppData; error: string | null }) {
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

      <section className="panel-grid">
        <Panel title="历史记录" action={String(data.library.history.length)}>
          <LibraryList items={data.library.history.slice(0, 4)} emptyText="暂无阅读记录" />
        </Panel>
        <Panel title="收藏" action={String(data.library.favorites.length)}>
          <LibraryList items={data.library.favorites.slice(0, 4)} emptyText="暂无收藏" />
        </Panel>
        <Panel title="追更" action="0">
          <EmptyLine icon={RefreshCw} text="暂无更新任务" />
        </Panel>
        <Panel title="漫画源" action={String(data.sources.length)}>
          <SourceList sources={data.sources.slice(0, 5)} compact />
        </Panel>
      </section>
    </div>
  )
}

function SearchView({
  sources,
  favorites,
  onSourceUpload,
  onSourceDelete,
  onRecordHistory,
  onSetFavorite
}: {
  sources: SourceSummary[]
  favorites: LibraryItem[]
  onSourceUpload: (file: File) => Promise<void>
  onSourceDelete: (key: string) => Promise<void>
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

  useEffect(() => {
    if (selectedSource && sources.some((source) => source.key === selectedSource)) return
    const nextSource = sources[0]?.key ?? ''
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
  }, [selectedSource, sources])

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

  return (
    <div className="view-stack">
      <form className="search-strip" aria-label="搜索" onSubmit={handleSearch}>
        <Search size={20} />
        <input
          value={keyword}
          placeholder={selectedSource ? '关键词' : '先导入漫画源'}
          disabled={!selectedSource || searching}
          onChange={(event) => setKeyword(event.target.value)}
        />
        <select
          value={selectedSource}
          disabled={sources.length === 0 || searching}
          aria-label="漫画源"
          onChange={(event) => handleSourceChange(event.target.value)}
        >
          {sources.map((source) => (
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
        <SourceList sources={sources} onDelete={handleDelete} />
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
          {comic.cover ? (
            <img src={imageProxyUrl(comic.cover)} alt="" loading="lazy" />
          ) : (
            <div className="result-cover-placeholder">
              <BookOpen size={18} />
            </div>
          )}
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
  favorite: boolean
  loadingComic: boolean
  loadingImages: boolean
  message: string | null
  onLoadImages: (episode: ComicEpisode) => void
  onFavoriteChange: (comic: ComicInfo, favorite: boolean) => void
}) {
  if (loadingComic) {
    return <EmptyLine icon={Loader2} text="加载详情中" />
  }
  if (!comic) {
    return <EmptyLine icon={BookOpen} text={message ?? '选择搜索结果查看详情'} />
  }

  return (
    <div className="comic-detail">
      <div className="comic-summary">
        {comic.cover ? (
          <img src={imageProxyUrl(comic.cover)} alt="" loading="lazy" />
        ) : (
          <div className="result-cover-placeholder">
            <BookOpen size={20} />
          </div>
        )}
        <div>
          <strong>{comic.title}</strong>
          {comic.subtitle ? <span>{comic.subtitle}</span> : null}
          {comic.description ? <p>{comic.description}</p> : null}
          <button
            className={favorite ? 'icon-text-button subtle active' : 'icon-text-button subtle'}
            type="button"
            onClick={() => onFavoriteChange(comic, !favorite)}
          >
            <Heart size={16} fill={favorite ? 'currentColor' : 'none'} />
            {favorite ? '已收藏' : '收藏'}
          </button>
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
        <div className="reader-shell">
          <div className="reader-heading">
            <strong>{activeEpisodeTitle ?? '当前章节'}</strong>
            <span>{images.length} 张</span>
          </div>
          <div className="reader-image-list">
            {images.map((image, index) => (
              <img
                key={`${image}-${index}`}
                src={imageProxyUrl(image)}
                alt={`第 ${index + 1} 页`}
                loading={index < 2 ? 'eager' : 'lazy'}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

function LibraryView({
  title,
  icon: Icon,
  items,
  emptyText
}: {
  title: string
  icon: typeof Home
  items: LibraryItem[]
  emptyText: string
}) {
  return (
    <div className="view-stack">
      <Panel title={title} action={String(items.length)}>
        <LibraryList items={items} emptyText={emptyText} icon={Icon} />
      </Panel>
    </div>
  )
}

function LibraryList({
  items,
  emptyText,
  icon: Icon = BookOpen
}: {
  items: LibraryItem[]
  emptyText: string
  icon?: typeof Home
}) {
  if (items.length === 0) {
    return <EmptyLine icon={Icon} text={emptyText} />
  }

  return (
    <div className="library-list">
      {items.map((item) => (
        <div className="library-row" key={`${item.source_key}:${item.comic_id}`}>
          {item.cover ? (
            <img src={imageProxyUrl(item.cover)} alt="" loading="lazy" />
          ) : (
            <div className="result-cover-placeholder">
              <BookOpen size={18} />
            </div>
          )}
          <div className="library-main">
            <strong>{item.title}</strong>
            {item.episode_title ? <span>{item.episode_title}</span> : null}
            {item.subtitle ? <small>{item.subtitle}</small> : null}
          </div>
        </div>
      ))}
    </div>
  )
}

function CollectionView({ title, icon: Icon }: { title: string; icon: typeof Home }) {
  return (
    <div className="view-stack">
      <Panel title={title} action="0">
        <EmptyLine icon={Icon} text="暂无条目" />
      </Panel>
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
  onThemeChange
}: {
  settings: SettingsResponse | null
  themeMode: string
  onThemeChange: (value: string) => Promise<void>
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
  onDelete
}: {
  sources: SourceSummary[]
  compact?: boolean
  onDelete?: (key: string) => void
}) {
  if (sources.length === 0) {
    return <EmptyLine icon={Library} text="暂无源文件" />
  }

  return (
    <div className={compact ? 'source-list compact' : 'source-list'}>
      {sources.map((source) => (
        <div className="source-row" key={source.key}>
          <div className="source-main">
            <strong>{source.name}</strong>
            <span>{source.file_name}</span>
          </div>
          <StatusPill
            ok={source.runtime_status === 'registered'}
            text={source.runtime_status === 'registered' ? '已登记' : '待解析'}
          />
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
