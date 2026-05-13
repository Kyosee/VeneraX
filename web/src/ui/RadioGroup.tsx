import styles from './RadioGroup.module.css'
export function RadioGroup<T extends string>({ value, onChange, options }:
  { value: T; onChange: (v: T) => void; options: { value: T; label: string }[] }) {
  return (
    <div className={styles.group}>
      {options.map((o) => (
        <label key={o.value} className={styles.row}>
          <input type="radio" checked={o.value === value}
            onChange={() => onChange(o.value)} className={styles.dot} />
          <span>{o.label}</span>
        </label>
      ))}
    </div>
  )
}
