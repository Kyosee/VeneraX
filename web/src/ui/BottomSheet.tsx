import { ReactNode, useEffect } from 'react'
import { createPortal } from 'react-dom'
import styles from './BottomSheet.module.css'

export function BottomSheet({ open, onClose, children }:
  { open: boolean; onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, onClose])
  if (!open) return null
  return createPortal(
    <div className={styles.scrim} onClick={onClose}>
      <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div className={styles.handle} />
        {children}
      </div>
    </div>,
    document.body,
  )
}
