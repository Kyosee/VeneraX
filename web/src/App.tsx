import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  BookOpen,
  CheckCircle2,
  ClipboardList,
  Compass,
  Database,
  EyeOff,
  Heart,
  Home,
  Library,
  Loader2,
  RefreshCw,
  Search,
  Server,
  Settings,
  Tags,
  WifiOff
} from 'lucide-react'
import {
  type CapabilitiesResponse,
  type HealthResponse,
  type SettingsResponse,
  type SourceSummary,
  getCapabilities,
  getHealth,
  getSettings,
  getSources,
  updateSettings
} from './api'
import { ReloadPrompt } from './ReloadPrompt'

type TabKey = 'home' | 'favorites' | 'explore' | 'categories' | 'search' | 'tasks' | 'settings'

type AppData = {
  health: HealthResponse | null
  capabilities: CapabilitiesResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
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
  capabilities: null,
  settings: null,
  sources: []
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
      const [health, capabilities, settings, sources] = await Promise.all([
        getHealth(),
        getCapabilities(),
        getSettings(),
        getSources()
      ])
      setData({ health, capabilities, settings, sources })
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
          {activeTab === 'home' ? <HomeView data={data} error={error} loading={loading} /> : null}
          {activeTab === 'favorites' ? <CollectionView title="收藏" icon={Heart} /> : null}
          {activeTab === 'explore' ? <CollectionView title="发现" icon={Compass} /> : null}
          {activeTab === 'categories' ? <CollectionView title="分类" icon={Tags} /> : null}
          {activeTab === 'search' ? <SearchView sources={data.sources} /> : null}
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
      {[...primaryNav, actionNav[2]].map((item) => (
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
  const connected = health?.status === 'ok' && !error

  return (
    <header className="top-bar">
      <div>
        <h1>Venera</h1>
        <p>{connected ? `服务端 ${health.version}` : '服务端未连接'}</p>
      </div>
      <div className="top-actions">
        <StatusPill ok={connected} text={connected ? '在线' : '离线'} />
        {lastUpdated ? <span className="muted-text">{lastUpdated}</span> : null}
        <button className="icon-button" type="button" onClick={onRefresh} aria-label="刷新">
          {loading ? <Loader2 className="spin" size={18} /> : <RefreshCw size={18} />}
        </button>
      </div>
    </header>
  )
}

function HomeView({ data, error, loading }: { data: AppData; error: string | null; loading: boolean }) {
  const availableCount =
    data.capabilities?.features.filter((feature) => feature.status === 'available').length ?? 0
  const plannedCount =
    data.capabilities?.features.filter((feature) => feature.status === 'planned').length ?? 0

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

      <section className="metric-grid" aria-label="状态概览">
        <Metric icon={Server} label="服务" value={loading ? '检查中' : data.health ? '正常' : '离线'} />
        <Metric icon={Database} label="数据" value={data.health?.database ?? 'SQLite'} />
        <Metric icon={Library} label="源" value={String(data.sources.length)} />
        <Metric icon={CheckCircle2} label="能力" value={`${availableCount}/${availableCount + plannedCount}`} />
      </section>

      <section className="panel-grid">
        <Panel title="历史记录" action="0">
          <EmptyLine icon={BookOpen} text="暂无阅读记录" />
        </Panel>
        <Panel title="本地漫画" action="0">
          <EmptyLine icon={Library} text="暂无本地条目" />
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

function SearchView({ sources }: { sources: SourceSummary[] }) {
  return (
    <div className="view-stack">
      <section className="search-strip" aria-label="搜索">
        <Search size={20} />
        <input placeholder="关键词" disabled />
        <button className="primary-button" disabled>
          搜索
        </button>
      </section>
      <Panel title="可用源" action={String(sources.length)}>
        <SourceList sources={sources} />
      </Panel>
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

function Metric({ icon: Icon, label, value }: { icon: typeof Home; label: string; value: string }) {
  return (
    <div className="metric">
      <Icon size={20} />
      <span>{label}</span>
      <strong>{value}</strong>
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

function SourceList({ sources, compact = false }: { sources: SourceSummary[]; compact?: boolean }) {
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
