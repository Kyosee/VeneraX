import { ReactNode, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import styles from './Flyout.module.css'

export function Flyout({ anchor, open, onClose, children, placement = 'bottom-start' }:
  { anchor: HTMLElement | null; open: boolean; onClose: () => void; children: ReactNode;
    placement?: 'bottom-start' | 'bottom-end' | 'top-start' | 'top-end' }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node) && !anchor?.contains(e.target as Node)) onClose()
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open, anchor, onClose])
  if (!open || !anchor) return null
  const r = anchor.getBoundingClientRect()
  const style: React.CSSProperties = placement.startsWith('bottom')
    ? { top: r.bottom + 4, [placement.endsWith('end') ? 'right' : 'left']: placement.endsWith('end') ? window.innerWidth - r.right : r.left }
    : { bottom: window.innerHeight - r.top + 4, [placement.endsWith('end') ? 'right' : 'left']: placement.endsWith('end') ? window.innerWidth - r.right : r.left }
  return createPortal(<div ref={ref} className={styles.flyout} style={style}>{children}</div>, document.body)
}
