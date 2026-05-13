import { ReactNode, useEffect } from 'react'
import { createPortal } from 'react-dom'
import styles from './Dialog.module.css'

export function Dialog({ open, onClose, title, children, actions, icon }:
  { open: boolean; onClose: () => void; title?: ReactNode; children?: ReactNode;
    actions?: ReactNode; icon?: ReactNode }) {
  useEffect(() => {
    if (!open) return
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', k)
    return () => document.removeEventListener('keydown', k)
  }, [open, onClose])
  if (!open) return null
  return createPortal(
    <div className={styles.scrim} onClick={onClose}>
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        {icon && <div className={styles.icon}>{icon}</div>}
        {title && <h2 className={styles.title}>{title}</h2>}
        {children && <div className={styles.body}>{children}</div>}
        {actions && <div className={styles.actions}>{actions}</div>}
      </div>
    </div>,
    document.body,
  )
}
