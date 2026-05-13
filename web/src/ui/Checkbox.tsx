import styles from './Checkbox.module.css'
export function Checkbox({ checked, onChange, label, disabled }:
  { checked: boolean; onChange: (v: boolean) => void; label?: string; disabled?: boolean }) {
  return (
    <label className={styles.row}>
      <input type="checkbox" checked={checked} disabled={disabled}
        onChange={(e) => onChange(e.target.checked)} className={styles.box} />
      {label && <span>{label}</span>}
    </label>
  )
}
