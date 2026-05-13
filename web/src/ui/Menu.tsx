import { ReactNode } from 'react'
import { Flyout } from './Flyout'
import { Ripple } from './Ripple'
import styles from './Menu.module.css'

export function Menu({ anchor, open, onClose, items }:
  { anchor: HTMLElement | null; open: boolean; onClose: () => void;
    items: { label: string; icon?: ReactNode; onClick: () => void; destructive?: boolean }[] }) {
  return (
    <Flyout anchor={anchor} open={open} onClose={onClose}>
      <ul className={styles.menu}>
        {items.map((it, i) => (
          <li key={i}>
            <Ripple>
              <button onClick={() => { onClose(); it.onClick() }}
                className={`${styles.item} ${it.destructive ? styles.danger : ''}`}>
                {it.icon && <span className={styles.icon}>{it.icon}</span>}{it.label}
              </button>
            </Ripple>
          </li>
        ))}
      </ul>
    </Flyout>
  )
}
