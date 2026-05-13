import { ReactNode, createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import { getLibrary, type LibraryResponse, type FavoriteFolder } from '../api'

type Value = {
  library: LibraryResponse | null
  folders: FavoriteFolder[]
  refreshLibrary: () => Promise<void>
}

const Ctx = createContext<Value | null>(null)

export function LibraryProvider({ children }: { children: ReactNode }) {
  const [library, setLibrary] = useState<LibraryResponse | null>(null)

  const refreshLibrary = useCallback(async () => { setLibrary(await getLibrary()) }, [])
  useEffect(() => { void refreshLibrary() }, [refreshLibrary])

  const folders: FavoriteFolder[] = library?.favorite_folders ?? []
  const value = useMemo(() => ({ library, folders, refreshLibrary }), [library, folders, refreshLibrary])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useLibrary(): Value {
  const v = useContext(Ctx)
  if (!v) throw new Error('useLibrary must be used within LibraryProvider')
  return v
}
