import styles from './Switch.module.css'
export function Switch({ checked, onChange, disabled }:
  { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <button role="switch" aria-checked={checked} disabled={disabled}
      className={`${styles.sw} ${checked ? styles.on : ''}`}
      onClick={() => onChange(!checked)}>
      <span className={styles.thumb} />
    </button>
  )
}
