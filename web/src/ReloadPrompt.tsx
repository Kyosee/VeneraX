import { RefreshCcw, X } from 'lucide-react'
import { useRegisterSW } from 'virtual:pwa-register/react'

export function ReloadPrompt() {
  const {
    offlineReady: [offlineReady, setOfflineReady],
    needRefresh: [needRefresh, setNeedRefresh],
    updateServiceWorker
  } = useRegisterSW({
    immediate: true,
    onRegisteredSW(_url, registration) {
      if (registration) {
        window.setInterval(() => registration.update(), 60 * 60 * 1000)
      }
    }
  })

  if (!offlineReady && !needRefresh) return null

  return (
    <div className="pwa-toast" role="status">
      <span>{needRefresh ? '新版本可用' : '离线资源已就绪'}</span>
      {needRefresh ? (
        <button className="icon-text-button" onClick={() => updateServiceWorker(true)}>
          <RefreshCcw size={16} />
          更新
        </button>
      ) : null}
      <button
        className="icon-button"
        aria-label="关闭"
        onClick={() => {
          setOfflineReady(false)
          setNeedRefresh(false)
        }}
      >
        <X size={16} />
      </button>
    </div>
  )
}
