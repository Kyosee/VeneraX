<script setup lang="ts">
import { ref, onMounted, computed, nextTick, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { getComicSources, searchComics, getSourceCapabilities, batchGetComicBasicInfo } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'
import type { ComicSource, SourceCapabilities, SourceSearchOption } from '@/types'

interface SearchResult {
  id: string
  title: string
  cover: string
  subtitle?: string
  sourceKey?: string
}

interface SourceResults {
  comics: SearchResult[]
  hasMore: boolean
  page: number
  loading: boolean
  error: string | null
}

const router = useRouter()
const route = useRoute()
const settingsStore = useSettingsStore()
const searchText = ref('')
const sources = ref<ComicSource[]>([])
const selectedSourceKey = ref('')
const aggregatedMode = ref(false)
const searchHistory = ref<string[]>([])
const sourcesLoading = ref(true)
const results = ref<Record<string, SourceResults>>({})
const capabilities = ref<Record<string, SourceCapabilities | null>>({})
const searchOptions = ref<string[]>([])

const HISTORY_KEY = 'venera_search_history'
const MAX_HISTORY = 20

const currentSearchOptions = computed<SourceSearchOption[]>(() => {
  const caps = capabilities.value[selectedSourceKey.value]
  return caps?.search?.optionList ?? []
})

watch(selectedSourceKey, async (key) => {
  if (!key || capabilities.value[key] !== undefined) {
    initSearchOptions()
    return
  }
  capabilities.value[key] = null
  try {
    const caps = await getSourceCapabilities(key)
    capabilities.value[key] = caps
  } catch { /* ignore */ }
  initSearchOptions()
})

function initSearchOptions() {
  const opts = currentSearchOptions.value
  searchOptions.value = opts.map(opt => {
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

function parseOptionEntry(entry: string): { key: string, label: string } {
  const idx = entry.indexOf('-')
  if (idx > 0) return { key: entry.substring(0, idx), label: entry.substring(idx + 1) }
  return { key: entry, label: entry }
}

function toggleMultiSelectOption(groupIndex: number, optionKey: string) {
  let current: string[] = []
  try { current = JSON.parse(searchOptions.value[groupIndex] || '[]') } catch { current = [] }
  const idx = current.indexOf(optionKey)
  if (idx >= 0) current.splice(idx, 1)
  else current.push(optionKey)
  searchOptions.value[groupIndex] = JSON.stringify(current)
}

function isMultiSelected(groupIndex: number, optionKey: string): boolean {
  try {
    const current: string[] = JSON.parse(searchOptions.value[groupIndex] || '[]')
    return current.includes(optionKey)
  } catch { return false }
}

const currentResults = computed(() => {
  if (aggregatedMode.value) {
    const allComics: SearchResult[] = []
    for (const key of Object.keys(results.value)) {
      allComics.push(...results.value[key].comics)
    }
    return allComics
  }
  return results.value[selectedSourceKey.value]?.comics ?? []
})

const isLoading = computed(() => {
  if (aggregatedMode.value) {
    return Object.values(results.value).some(r => r.loading)
  }
  return results.value[selectedSourceKey.value]?.loading ?? false
})

const currentError = computed(() => {
  if (aggregatedMode.value) {
    const errors = Object.values(results.value).filter(r => r.error).map(r => formatError(r.error))
    return errors.length ? errors.join('; ') : null
  }
  return formatError(results.value[selectedSourceKey.value]?.error)
})

const hasMore = computed(() => {
  if (aggregatedMode.value) return false
  return results.value[selectedSourceKey.value]?.hasMore ?? false
})

const hasSearched = ref(false)
const gridStyle = computed(() => {
  const scale = Number(settingsStore.settings.thumbnailSize || 1)
  return settingsStore.settings.thumbnailMode === 'brief'
    ? {
        '--tile-scale': String(scale),
        gridTemplateColumns: `repeat(auto-fill, minmax(96px, ${Math.round(192 * scale)}px))`,
      }
    : {
        '--tile-scale': String(scale),
        gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 360px), 1fr))',
      }
})

function loadHistory() {
  try {
    const raw = localStorage.getItem(HISTORY_KEY)
    searchHistory.value = raw ? JSON.parse(raw) : []
  } catch { searchHistory.value = [] }
}

function saveHistory(keyword: string) {
  const trimmed = keyword.trim()
  if (!trimmed) return
  const list = searchHistory.value.filter(h => h !== trimmed)
  list.unshift(trimmed)
  searchHistory.value = list.slice(0, MAX_HISTORY)
  localStorage.setItem(HISTORY_KEY, JSON.stringify(searchHistory.value))
}

function queryString(value: unknown): string {
  if (Array.isArray(value)) return value[0]?.toString() ?? ''
  return value?.toString() ?? ''
}

function withSourceKey(comics: SearchResult[], sourceKey: string): SearchResult[] {
  return comics.map(comic => ({
    ...comic,
    sourceKey: comic.sourceKey || sourceKey,
  }))
}

async function enrichWithLocalInfo(sourceKey: string, comics: SearchResult[]) {
  if (!comics.length) return
  try {
    const ids = comics.map(c => ({ sourceKey, comicId: c.id }))
    const infoMap = await batchGetComicBasicInfo(ids)
    for (const c of comics) {
      const key = `${sourceKey}:${c.id}`
      const info = infoMap[key]
      if (info) {
        if (!c.subtitle && info.subtitle) c.subtitle = info.subtitle
      }
    }
  } catch { /* best-effort */ }
}

function formatError(message?: string | null) {
  if (!message) return null
  if (/not found/i.test(message)) return '当前漫画源暂不支持搜索或接口未就绪'
  if (/search failed/i.test(message)) return '搜索失败'
  if (/load more failed/i.test(message)) return '加载更多失败'
  return message
}

function removeHistoryItem(keyword: string) {
  searchHistory.value = searchHistory.value.filter(h => h !== keyword)
  localStorage.setItem(HISTORY_KEY, JSON.stringify(searchHistory.value))
}

function clearSearchHistory() {
  searchHistory.value = []
  localStorage.removeItem(HISTORY_KEY)
}

async function doSearch(keyword?: string) {
  const term = (keyword ?? searchText.value).trim()
  if (!term) return
  searchText.value = term
  saveHistory(term)
  hasSearched.value = true
  results.value = {}

  if (aggregatedMode.value) {
    for (const source of sources.value) {
      results.value[source.key] = { comics: [], hasMore: false, page: 1, loading: true, error: null }
    }
    await Promise.allSettled(
      sources.value.map(async (source) => {
        try {
          const res = await searchComics(source.key, term, 1)
          const comics = withSourceKey(res.comics, source.key)
          results.value[source.key] = { comics, hasMore: res.hasMore, page: 1, loading: false, error: null }
          enrichWithLocalInfo(source.key, comics)
        } catch (e: any) {
          results.value[source.key] = { comics: [], hasMore: false, page: 1, loading: false, error: e.message ?? '搜索失败' }
        }
      })
    )
  } else {
    const key = selectedSourceKey.value
    if (!key) return
    results.value[key] = { comics: [], hasMore: false, page: 1, loading: true, error: null }
    try {
      const opts = currentSearchOptions.value.length > 0 ? searchOptions.value : undefined
      const res = await searchComics(key, term, 1, opts)
      const comics = withSourceKey(res.comics, key)
      results.value[key] = { comics, hasMore: res.hasMore, page: 1, loading: false, error: null }
      enrichWithLocalInfo(key, comics)
    } catch (e: any) {
      results.value[key] = { comics: [], hasMore: false, page: 1, loading: false, error: e.message ?? '搜索失败' }
    }
  }
}

async function loadMore() {
  const key = selectedSourceKey.value
  if (!key || aggregatedMode.value) return
  const current = results.value[key]
  if (!current || current.loading || !current.hasMore) return
  current.loading = true
  const nextPage = current.page + 1
  try {
    const opts = currentSearchOptions.value.length > 0 ? searchOptions.value : undefined
    const res = await searchComics(key, searchText.value.trim(), nextPage, opts)
    const newComics = withSourceKey(res.comics, key)
    current.comics.push(...newComics)
    current.hasMore = res.hasMore
    current.page = nextPage
    current.loading = false
    enrichWithLocalInfo(key, newComics)
  } catch (e: any) {
    current.loading = false
    current.error = e.message ?? '加载更多失败'
  }
}

function selectSource(key: string) {
  selectedSourceKey.value = key
  if (hasSearched.value && searchText.value.trim()) {
    doSearch()
  }
}

function onHistoryClick(keyword: string) {
  searchText.value = keyword
  doSearch(keyword)
}



function sourceNameFor(key: string | undefined) {
  if (!key) return ''
  const source = sources.value.find(item => item.key === key || item.canonicalKey === key)
  return source?.name || source?.sourceName || source?.displayName || key
}

function onBack() { router.back() }

onMounted(async () => {
  await settingsStore.loadSettings()
  loadHistory()
  const initialKeyword = queryString(route.query.keyword).trim()
  const initialSource = queryString(route.query.source).trim()
  const initialAggregated = initialSource === 'all' || initialSource === '*'
  if (initialAggregated) aggregatedMode.value = true
  else if (initialSource) selectedSourceKey.value = initialSource

  sourcesLoading.value = true
  try {
    const list = await getComicSources()
    sources.value = list
    if (!selectedSourceKey.value && list.length > 0) {
      selectedSourceKey.value = list[0].key
    }
  } catch (e) {
    console.error('Failed to load sources:', e)
  } finally {
    sourcesLoading.value = false
  }
  if (initialKeyword) {
    await doSearch(initialKeyword)
  }
  await nextTick()
  const input = document.querySelector('.search-page .van-field__control') as HTMLInputElement
  input?.focus()
})
</script>

<template>
  <div class="search-page">
    <van-nav-bar title="搜索" left-arrow @click-left="onBack" />

    <!-- Search bar -->
    <van-search
      v-model="searchText"
      placeholder="搜索漫画..."
      show-action
      action-text="搜索"
      @search="doSearch()"
      @click-action="doSearch()"
    />

    <!-- Source selector -->
    <div v-if="sources.length" class="source-section">
      <div class="source-chips">
        <van-tag
          v-for="source in sources"
          :key="source.key"
          :type="selectedSourceKey === source.key && !aggregatedMode ? 'primary' : 'default'"
          size="medium"
          class="source-chip"
          @click="aggregatedMode = false; selectSource(source.key)"
        >
          {{ source.name }}
        </van-tag>
      </div>
      <div class="aggregated-toggle">
        <van-checkbox v-model="aggregatedMode" shape="square" icon-size="16px">
          搜索全部漫画源
        </van-checkbox>
      </div>
    </div>

    <!-- Search options -->
    <div v-if="!aggregatedMode && currentSearchOptions.length" class="search-options-section">
      <div v-for="(opt, groupIdx) in currentSearchOptions" :key="groupIdx" class="option-group">
        <span v-if="opt.label" class="option-label">{{ opt.label }}</span>
        <div v-if="opt.type === 'dropdown' || opt.options.length > 8" class="option-dropdown">
          <select
            :value="searchOptions[groupIdx]"
            @change="searchOptions[groupIdx] = ($event.target as HTMLSelectElement).value"
          >
            <option v-for="entry in opt.options" :key="entry" :value="parseOptionEntry(entry).key">
              {{ parseOptionEntry(entry).label }}
            </option>
          </select>
        </div>
        <div v-else-if="opt.type === 'multi-select'" class="option-chips">
          <van-tag
            v-for="entry in opt.options"
            :key="entry"
            :type="isMultiSelected(groupIdx, parseOptionEntry(entry).key) ? 'primary' : 'default'"
            size="medium"
            class="option-chip"
            @click="toggleMultiSelectOption(groupIdx, parseOptionEntry(entry).key)"
          >
            {{ parseOptionEntry(entry).label }}
          </van-tag>
        </div>
        <div v-else class="option-chips">
          <van-tag
            v-for="entry in opt.options"
            :key="entry"
            :type="searchOptions[groupIdx] === parseOptionEntry(entry).key ? 'primary' : 'default'"
            size="medium"
            class="option-chip"
            @click="searchOptions[groupIdx] = parseOptionEntry(entry).key"
          >
            {{ parseOptionEntry(entry).label }}
          </van-tag>
        </div>
      </div>
    </div>

    <div class="search-content">
      <!-- Search history (shown before first search) -->
      <div v-if="!hasSearched && searchHistory.length" class="history-section">
        <div class="history-header">
          <span class="history-title">最近搜索</span>
          <van-button size="mini" plain @click="clearSearchHistory">清空</van-button>
        </div>
        <div class="history-list">
          <div
            v-for="item in searchHistory"
            :key="item"
            class="history-item"
            @click="onHistoryClick(item)"
          >
            <span class="history-text">{{ item }}</span>
            <van-icon name="cross" size="14" class="history-remove" @click.stop="removeHistoryItem(item)" />
          </div>
        </div>
      </div>

      <!-- Empty state before search -->
      <van-empty
        v-if="!hasSearched && !searchHistory.length"
        description="输入关键词开始搜索"
        image="search"
      />

      <!-- Loading state -->
      <div v-if="isLoading && !currentResults.length" class="loading-state">
        <van-loading size="36px" color="#4f6ef7" vertical>搜索中...</van-loading>
      </div>

      <!-- Error state -->
      <div v-if="currentError && !currentResults.length && !isLoading" class="error-state">
        <van-empty image="error" :description="currentError" />
        <van-button type="primary" size="small" @click="doSearch()">重试</van-button>
      </div>

      <!-- Results grid -->
      <div v-if="currentResults.length" class="results-section">
        <div class="comic-grid" :style="gridStyle">
          <ComicCard
            v-for="comic in currentResults"
            :key="`${comic.sourceKey || selectedSourceKey}:${comic.id}`"
            :comic="comic"
            :source-key="comic.sourceKey || selectedSourceKey"
            :source-name="sourceNameFor(comic.sourceKey || selectedSourceKey)"
            class="comic-card"
          />
        </div>

        <!-- Load more -->
        <div v-if="hasMore" class="load-more">
          <van-loading v-if="isLoading" size="24px" />
          <van-button v-else size="small" plain @click="loadMore">加载更多</van-button>
        </div>
      </div>

      <!-- No results -->
      <van-empty
        v-if="hasSearched && !isLoading && !currentResults.length && !currentError"
        description="没有找到结果"
        image="search"
      />
    </div>
  </div>
</template>

<style scoped>
.search-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.source-section {
  padding: 8px 16px 4px;
  border-bottom: 1px solid #f0f0f0;
}

.source-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.source-chip {
  cursor: pointer;
  transition: all 0.2s;
}

.aggregated-toggle {
  margin-top: 8px;
  padding-bottom: 4px;
}

.search-options-section {
  padding: 8px 16px;
  border-bottom: 1px solid #f0f0f0;
}

.option-group {
  margin-bottom: 6px;
}

.option-group:last-child {
  margin-bottom: 0;
}

.option-label {
  display: block;
  font-size: 12px;
  color: #666;
  margin-bottom: 4px;
}

.option-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.option-chip {
  cursor: pointer;
  transition: all 0.2s;
}

.option-dropdown select {
  width: 100%;
  padding: 6px 8px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 13px;
  background: #fff;
  color: #333;
}

.search-content {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
  -webkit-overflow-scrolling: touch;
}

.history-section {
  margin-bottom: 16px;
}

.history-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 10px;
}

.history-title {
  font-size: 14px;
  font-weight: 500;
  color: #333;
}

.history-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.history-item {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 6px 12px;
  background: #f5f5f5;
  border-radius: 16px;
  cursor: pointer;
  transition: background 0.2s;
}

.history-item:active {
  background: #e8e8e8;
}

.history-text {
  font-size: 13px;
  color: #333;
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.history-remove {
  color: #999;
  flex-shrink: 0;
}

.loading-state {
  display: flex;
  justify-content: center;
  padding: 48px 0;
}

.error-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px 0;
}

.results-section {
  margin-top: 4px;
}

.comic-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 192px));
  gap: 12px;
  justify-content: center;
}

.comic-card {
  cursor: pointer;
  transition: transform 0.15s ease;
}

.comic-card:active {
  transform: scale(0.97);
}

.comic-cover {
  width: 100%;
  aspect-ratio: 0.64;
  object-fit: cover;
  border-radius: 4px;
  background: #f0f0f0;
  display: block;
}

.comic-title {
  margin-top: 6px;
  font-size: 14px;
  line-height: 1.3;
  color: #333;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-overflow: ellipsis;
  word-break: break-all;
}

.comic-subtitle {
  margin-top: 2px;
  font-size: 12px;
  color: #999;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}
</style>
