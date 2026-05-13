import { ReactNode, createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import {
  getHealth, getSettings, getSources,
  type HealthResponse, type SettingsResponse, type SourceSummary,
} from '../api'

type Value = {
  health: HealthResponse | null
  settings: SettingsResponse | null
  sources: SourceSummary[]
  refreshAll: () => Promise<void>
  refreshSettings: () => Promise<void>
  refreshSources: () => Promise<void>
}

const Ctx = createContext<Value | null>(null)

export function AppDataProvider({ children }: { children: ReactNode }) {
  const [health, setHealth] = useState<HealthResponse | null>(null)
  const [settings, setSettings] = useState<SettingsResponse | null>(null)
  const [sources, setSources] = useState<SourceSummary[]>([])

  const refreshSettings = useCallback(async () => { setSettings(await getSettings()) }, [])
  const refreshSources = useCallback(async () => { setSources(await getSources()) }, [])
  const refreshAll = useCallback(async () => {
    const [h] = await Promise.all([getHealth(), refreshSettings(), refreshSources()])
    setHealth(h)
  }, [refreshSettings, refreshSources])

  useEffect(() => { void refreshAll() }, [refreshAll])

  const value = useMemo(
    () => ({ health, settings, sources, refreshAll, refreshSettings, refreshSources }),
    [health, settings, sources, refreshAll, refreshSettings, refreshSources],
  )
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useAppData(): Value {
  const v = useContext(Ctx)
  if (!v) throw new Error('useAppData must be used within AppDataProvider')
  return v
}
