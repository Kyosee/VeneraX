import { ReactNode, createContext, useCallback, useContext, useState } from 'react'
import styles from './Snackbar.module.css'

type Item = { id: number; message: string; action?: { label: string; onClick: () => void } }
const Ctx = createContext<{ show: (m: string, action?: Item['action']) => void }>({ show: () => {} })

export function SnackbarHost({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<Item[]>([])
  const show = useCallback((message: string, action?: Item['action']) => {
    const id = Date.now() + Math.random()
    setItems((xs) => [...xs, { id, message, action }])
    setTimeout(() => setItems((xs) => xs.filter((x) => x.id !== id)), 4000)
  }, [])
  return (
    <Ctx.Provider value={{ show }}>
      {children}
      <div className={styles.host}>
        {items.map((it) => (
          <div key={it.id} className={styles.bar}>
            <span>{it.message}</span>
            {it.action && <button className={styles.action} onClick={it.action.onClick}>{it.action.label}</button>}
          </div>
        ))}
      </div>
    </Ctx.Provider>
  )
}

export function useSnackbar() { return useContext(Ctx).show }
