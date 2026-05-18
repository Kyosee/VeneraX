import type { SourceSearchOption } from '@/types'

export function parseOptionEntry(entry: string): { key: string; label: string } {
  const idx = entry.indexOf('-')
  if (idx > 0) return { key: entry.substring(0, idx), label: entry.substring(idx + 1) }
  return { key: entry, label: entry }
}

export function initSearchOptions(
  opts: SourceSearchOption[],
  fromQuery?: string | null,
): string[] {
  if (fromQuery && opts.length > 0) {
    try {
      const parsed = JSON.parse(fromQuery)
      if (Array.isArray(parsed) && parsed.length === opts.length) return parsed
    } catch { /* fall through */ }
  }
  return opts.map(opt => {
    if (opt.default != null) {
      return Array.isArray(opt.default) ? JSON.stringify(opt.default) : String(opt.default)
    }
    if (opt.options.length > 0) {
      const first = opt.options[0]
      return first.includes('-') ? first.split('-')[0] : first
    }
    return ''
  })
}

export function toggleMultiSelectOption(current: string[], optionKey: string): string[] {
  const idx = current.indexOf(optionKey)
  if (idx >= 0) current.splice(idx, 1)
  else current.push(optionKey)
  return current
}

export function isMultiSelected(optionsJson: string, optionKey: string): boolean {
  try {
    const current: string[] = JSON.parse(optionsJson || '[]')
    return current.includes(optionKey)
  } catch { return false }
}
