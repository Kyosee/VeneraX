const LANG_FILTER_SOURCES = ['nhentai', 'ehentai', 'eh', 'exhentai']

export function applyAutoLangFilter(
  sourceKey: string,
  keyword: string,
  mode: string,
): string {
  if (!mode || mode === 'none') return keyword
  if (!LANG_FILTER_SOURCES.some(k => sourceKey.toLowerCase().includes(k))) return keyword
  if (/language:/i.test(keyword)) return keyword
  return `language:${mode} ${keyword}`
}
