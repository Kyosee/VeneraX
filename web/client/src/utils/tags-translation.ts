/**
 * Tag suggestion system — ported from lib/utils/tags_translation.dart.
 * Data source: https://github.com/EhTagTranslation/Database
 */

export interface TagSuggestion {
  namespace: string
  key: string
  label: string
}

interface TagsData {
  [namespace: string]: Record<string, string>
}

let _data: TagsData | null = null
let _loadPromise: Promise<TagsData> | null = null

const NAMESPACE_ORDER = [
  'female', 'male', 'parody', 'character',
  'other', 'mixed', 'language', 'artist',
  'group', 'cosplayer',
] as const

export async function loadTagData(): Promise<TagsData> {
  if (_data) return _data
  if (!_loadPromise) {
    _loadPromise = fetch('/data/tags.json')
      .then(res => res.json())
      .then(json => {
        _data = json as TagsData
        return _data
      })
      .catch(() => {
        _loadPromise = null
        return {}
      })
  }
  return _loadPromise
}

export function getTagData(): TagsData | null {
  return _data
}

function checkMatch(text: string, key: string, value: string): boolean {
  if (!text) return false
  const lowerText = text.toLowerCase()
  const lowerKey = key.toLowerCase()
  const lowerValue = value.toLowerCase()

  if (lowerKey.length >= lowerText.length && lowerKey.startsWith(lowerText)) return true
  if (key.includes(' ')) {
    const lastWord = key.split(' ').pop()!.toLowerCase()
    if (lastWord.length >= lowerText.length && lastWord.startsWith(lowerText)) return true
  }
  if (lowerValue.length >= lowerText.length && lowerValue.includes(lowerText)) return true
  return false
}

export function matchSuggestions(text: string, maxResults = 100): TagSuggestion[] {
  if (!_data) return []

  const lastWord = text.split(' ').pop() ?? ''
  if (!lastWord) return []

  const suggestions: TagSuggestion[] = []

  for (const namespace of NAMESPACE_ORDER) {
    const map = _data[namespace]
    if (!map) continue
    for (const [key, value] of Object.entries(map)) {
      if (suggestions.length >= maxResults) break
      if (checkMatch(lastWord, key, value)) {
        suggestions.push({ namespace, key, label: `${namespace}:${key}` })
      }
    }
    if (suggestions.length >= maxResults) break
  }

  return suggestions
}

export function getTagSuggestionLabel(suggestion: TagSuggestion): string {
  const map = _data?.[suggestion.namespace]
  const translation = map?.[suggestion.key]
  if (translation && translation !== suggestion.key) {
    return `${translation} (${suggestion.key})`
  }
  return suggestion.key
}

export function isURL(text: string): boolean {
  return /^https?:\/\//i.test(text.trim())
}
