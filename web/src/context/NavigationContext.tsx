import { ReactNode, createContext, useCallback, useContext, useMemo, useState } from 'react'

export type TabKey = 'home' | 'favorites' | 'explore' | 'categories'
  | 'search' | 'history' | 'updates' | 'tasks' | 'settings'

export type ComicOpenRequest = {
  sourceKey: string
  comicId: string
  title: string
}

type Value = {
  tab: TabKey
  setTab: (k: TabKey) => void
  comicOpen: ComicOpenRequest | null
  openComic: (r: ComicOpenRequest | null) => void
  searchQuery: string
  setSearchQuery: (q: string) => void
}

const Ctx = createContext<Value | null>(null)

export function NavigationProvider({ children }: { children: ReactNode }) {
  const [tab, setTab] = useState<TabKey>('home')
  const [comicOpen, _setComicOpen] = useState<ComicOpenRequest | null>(null)
  const [searchQuery, setSearchQuery] = useState('')

  const openComic = useCallback((r: ComicOpenRequest | null) => _setComicOpen(r), [])

  const value = useMemo(
    () => ({ tab, setTab, comicOpen, openComic, searchQuery, setSearchQuery }),
    [tab, comicOpen, openComic, searchQuery],
  )
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useNavigation(): Value {
  const v = useContext(Ctx)
  if (!v) throw new Error('useNavigation must be used within NavigationProvider')
  return v
}
