export interface SourceKeyItem {
  sourceKey?: string | null
  source_key?: string | null
  type?: number | string | null
}

export interface SourceKeySource {
  key?: string | null
  canonicalKey?: string | null
  canonical_key?: string | null
  type?: number | string | null
  intKey?: number | string | null
  int_key?: number | string | null
  legacyInt?: number | string | null
  legacyIntType?: number | string | null
  legacy_int_type?: number | string | null
}

export interface NormalizedComicSource extends SourceKeySource {
  name: string
  key: string
  version: string
  url: string
  [key: string]: unknown
}

const SOURCE_DISPLAY_NAMES: Record<string, string> = {}

function stringValue(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function numberValue(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value !== 'string' || !value.trim()) return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

function sourceLegacyType(source: SourceKeySource): number | null {
  const candidates = [
    source.type,
    source.intKey,
    source.int_key,
    source.legacyInt,
    source.legacyIntType,
    source.legacy_int_type,
  ]
  for (const candidate of candidates) {
    const value = numberValue(candidate)
    if (value !== null) return value
  }
  return null
}

function sourceDisplayName(source: Record<string, unknown>): string {
  const name = stringValue(source.sourceName) || stringValue(source.displayName) || stringValue(source.name)
  return name.replace(/^comic_source[\\/]/, '').replace(/\.js$/i, '').replace(/\s*\(\d+\)$/i, '')
}

function normalizeSourceKeyText(value: string): string {
  return value.replace(/^comic_source[\\/]/, '').replace(/\.js$/i, '').replace(/\s*\(\d+\)$/i, '')
}

function displayNameFromKey(value: string): string {
  const normalized = normalizeSourceKeyText(value)
  return SOURCE_DISPLAY_NAMES[normalized] || SOURCE_DISPLAY_NAMES[value] || ''
}

function decodeBase64Text(value: unknown): string {
  const dataBase64 = stringValue(value)
  if (!dataBase64) return ''
  try {
    const binary = atob(dataBase64)
    const bytes = Uint8Array.from(binary, char => char.charCodeAt(0))
    return new TextDecoder().decode(bytes)
  } catch {
    return ''
  }
}

function extractScriptMeta(script: string): Partial<NormalizedComicSource> {
  const pick = (keys: string[]) => {
    for (const key of keys) {
      const match = script.match(new RegExp(`${key}\\s*[:=]\\s*['"\`]([^'"\`]+)['"\`]`))
      if (match?.[1]) return match[1].trim()
    }
    return ''
  }
  return {
    key: pick(['key', 'sourceKey']),
    name: pick(['name', 'title', 'displayName']),
    version: pick(['version']),
    url: pick(['url', 'website']),
  } as Partial<NormalizedComicSource>
}

// Mirror Dart's String.hashCode (Jenkins one-at-a-time + 0x3fffffff mask),
// which the native app uses as a source's numeric `type`. MUST stay byte-for-byte
// identical to the backend's comicSourceTypeFromKey (web/server/server.js) and to
// Dart's hashCode, otherwise the same source resolves to two different types and
// produces duplicate history rows / "Unknown:<hash>" source labels.
function stableSourceTypeHash(sourceKey: string): number {
  let h = 0
  for (let i = 0; i < sourceKey.length; i++) {
    h = (h + sourceKey.charCodeAt(i)) >>> 0
    h = (h + ((h << 10) >>> 0)) >>> 0
    h = (h ^ (h >>> 6)) >>> 0
  }
  h = (h + ((h << 3) >>> 0)) >>> 0
  h = (h ^ (h >>> 11)) >>> 0
  h = (h + ((h << 15) >>> 0)) >>> 0
  h = h & 0x3fffffff
  return h === 0 ? 1 : h
}

// Canonicalize a source key the same way the backend does (canonicalComicSourceKey):
// strip a trailing ".js" and a "(N)" / "（N）" disambiguation suffix (both ASCII
// and full-width parentheses, with optional surrounding spaces) so variants like
// "copy_manga(0)" / "copy_manga（0）" all reduce to "copy_manga".
export function canonicalSourceKey(sourceKey: string): string {
  return String(sourceKey || '')
    .trim()
    .replace(/\.js$/i, '')
    .replace(/[\s　]*[(（]\d+[)）]$/u, '')
    .trim()
}

export function normalizeComicSource(item: unknown): NormalizedComicSource | null {
  if (!item || typeof item !== 'object') return null

  const source = item as Record<string, unknown>
  const rawName = stringValue(source.name)
  const rawKey = stringValue(source.key)
  const filename = (rawName || rawKey).replace(/^comic_source[\\/]/, '')
  if (filename.toLowerCase().endsWith('.data')) return null

  const scriptMeta = extractScriptMeta(decodeBase64Text(source.dataBase64))
  const derivedName = sourceDisplayName(source) || rawKey
  const executableKey = rawKey || filename.replace(/\.js$/i, '')
  const canonicalKey = stringValue(scriptMeta.key) || executableKey.replace(/\s*\(\d+\)$/i, '') || derivedName
  const key = executableKey || canonicalKey
  if (!key) return null

  const metadataName =
    stringValue(source.sourceName) || stringValue(source.displayName) || stringValue(scriptMeta.name)
  const normalizedMetadataName = normalizeSourceKeyText(metadataName)
  const fallbackName = displayNameFromKey(canonicalKey) || displayNameFromKey(key) || displayNameFromKey(derivedName) || derivedName || key
  const rawNameIsTechnical =
    !rawName ||
    rawName.toLowerCase().endsWith('.js') ||
    normalizeSourceKeyText(rawName) === canonicalKey ||
    /^[a-z][a-z0-9_]*(\(\d+\))?$/i.test(rawName)
  const name = rawNameIsTechnical
    ? displayNameFromKey(normalizedMetadataName) || metadataName || fallbackName
    : rawName
  return {
    ...source,
    name,
    key,
    canonicalKey,
    version: stringValue(source.version) || stringValue(scriptMeta.version),
    url: stringValue(source.url) || stringValue(scriptMeta.url),
  } as NormalizedComicSource
}

export function normalizeComicSources(items: unknown[]): NormalizedComicSource[] {
  const result: NormalizedComicSource[] = []
  const seen = new Set<string>()

  for (const item of items) {
    const source = normalizeComicSource(item)
    if (!source) continue

    const dedupeKey = stringValue(source.canonicalKey) || source.key
    if (seen.has(dedupeKey)) continue

    seen.add(dedupeKey)
    result.push(source)
  }

  return result.sort((a, b) => a.name.localeCompare(b.name))
}

export function sourceKeyFromType(type: number | string | null | undefined): string {
  const value = numberValue(type)
  if (value === null) return stringValue(type)
  if (value === 0) return 'local'
  return `Unknown:${value}`
}

export function sourceTypeFromKey(sourceKey: string | number | null | undefined): number {
  if (typeof sourceKey === 'number' && Number.isFinite(sourceKey)) return sourceKey
  const key = stringValue(sourceKey)
  if (!key || key === 'local') return 0
  if (/^-?\d+$/.test(key)) return Number(key)
  if (key.startsWith('Unknown:')) return Number(key.slice('Unknown:'.length)) || 0
  // Canonicalize before hashing so "copy_manga(0)" and "copy_manga" share a type,
  // matching the native ComicType.fromKey(canonicalKey.hashCode) behavior.
  return stableSourceTypeHash(canonicalSourceKey(key))
}

// Find the installed source whose key/canonicalKey resolves to [type], trying
// the legacy numeric field first, then the Dart-compatible hash of key and
// canonicalKey (both raw and (N)-stripped forms).
function findSourceByType(type: number, sources: SourceKeySource[]): SourceKeySource | undefined {
  return sources.find(source => {
    const k = stringValue(source.key)
    if (!k) return false
    const ck = stringValue(source.canonicalKey) || stringValue(source.canonical_key) || k
    if (sourceLegacyType(source) === type) return true
    return stableSourceTypeHash(k) === type
      || stableSourceTypeHash(canonicalSourceKey(k)) === type
      || stableSourceTypeHash(ck) === type
      || stableSourceTypeHash(canonicalSourceKey(ck)) === type
  })
}

export function resolveSourceKey(
  item: SourceKeyItem,
  sources: SourceKeySource[] = [],
  fallback = 'local',
): string {
  const explicit = stringValue(item.sourceKey) || stringValue(item.source_key)
  if (explicit) {
    const explicitCanonical = canonicalSourceKey(explicit)
    const matched = sources.find(source => {
      const key = stringValue(source.key)
      const canonicalKey = stringValue(source.canonicalKey) || stringValue(source.canonical_key) || key
      // Compare both raw and canonicalized forms so a stored "copy_manga(0)"
      // still matches an installed "copy_manga" source.
      return key === explicit || canonicalKey === explicit
        || key === explicitCanonical || canonicalKey === explicitCanonical
        || canonicalSourceKey(key) === explicitCanonical
    })
    if (matched) return stringValue(matched.key)
    // An "Unknown:<hash>" explicit key carries a numeric type we can still
    // resolve against installed sources (e.g. native-synced rows whose real
    // sourceKey was lost). Fall through to type resolution instead of showing
    // the raw "Unknown:..." string.
    if (explicit.startsWith('Unknown:')) {
      const t = Number(explicit.slice('Unknown:'.length))
      if (Number.isFinite(t)) {
        const byType = findSourceByType(t, sources)
        if (byType) return stringValue(byType.key)
      }
    } else {
      // No installed source matched; return the canonicalized key so a stale
      // "(N)" suffix never leaks into the UI / downstream type hashing.
      return explicitCanonical || explicit
    }
  }

  const type = numberValue(item.type)
  if (type === null) return explicit || fallback
  if (type === 0) return 'local'

  const matched = findSourceByType(type, sources)
  return stringValue(matched?.key) || sourceKeyFromType(type)
}
