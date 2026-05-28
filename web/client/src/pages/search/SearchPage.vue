<script setup lang="ts">
import { ref, onMounted, computed, nextTick, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { getComicSources, getSourceCapabilities } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import AggregatedSearchResults from './AggregatedSearchResults.vue'
import type { ComicSource, SourceCapabilities, SourceSearchOption, TagSuggestion } from '@/types'
import { loadTagData, matchSuggestions, isURL, getTagSuggestionLabel } from '@/utils/tags-translation'
import { parseOptionEntry, initSearchOptions as initOpts, toggleMultiSelectOption as toggleMultiOpt, isMultiSelected as isMultiOpt } from '@/utils/options'
import { applyAutoLangFilter as applyLangFilter } from '@/utils/search'

const router = useRouter()
const route = useRoute()
const settingsStore = useSettingsStore()
const searchText = ref('')
const sources = ref<ComicSource[]>([])
const selectedSourceKey = ref('')
const aggregatedMode = ref(true)
const searchHistory = ref<string[]>([])
const sourcesLoading = ref(true)
const capabilities = ref<Record<string, SourceCapabilities | null>>({})
const searchOptions = ref<string[]>([])

const HISTORY_KEY = 'venera_search_history'
const MAX_HISTORY = 50

const suggestions = ref<TagSuggestion[]>([])
const showUrlSuggestion = ref(false)
const contextMenuVisible = ref(false)
const contextMenuItem = ref('')
const contextMenuStyle = ref({ top: '0px', left: '0px' })
const hasSearched = ref(false)

const currentSearchOptions = computed<SourceSearchOption[]>(() => {
  const caps = capabilities.value[selectedSourceKey.value]
  return caps?.search?.optionList ?? []
})

const enableTagsSuggestions = computed(() => {
  if (aggregatedMode.value) return false
  const caps = capabilities.value[selectedSourceKey.value]
  return caps?.search?.enableTagsSuggestions ?? false
})

watch(selectedSourceKey, async (key) => {
  if (!key || capabilities.value[key] !== undefined) {
    localInitSearchOptions()
    return
  }
  capabilities.value[key] = null
  try {
    const caps = await getSourceCapabilities(key)
    capabilities.value[key] = caps
  } catch { /* ignore */ }
  localInitSearchOptions()
})

function localInitSearchOptions() {
  searchOptions.value = initOpts(currentSearchOptions.value)
}

function localToggleMultiSelectOption(groupIndex: number, optionKey: string) {
  const current: string[] = (() => { try { return JSON.parse(searchOptions.value[groupIndex] || '[]') } catch { return [] } })()
  toggleMultiOpt(current, optionKey)
  searchOptions.value[groupIndex] = JSON.stringify(current)
}

function localIsMultiSelected(groupIndex: number, optionKey: string): boolean {
  return isMultiOpt(searchOptions.value[groupIndex], optionKey)
}

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

function removeHistoryItem(keyword: string) {
  searchHistory.value = searchHistory.value.filter(h => h !== keyword)
  localStorage.setItem(HISTORY_KEY, JSON.stringify(searchHistory.value))
}

function clearSearchHistory() {
  searchHistory.value = []
  localStorage.removeItem(HISTORY_KEY)
}

function queryString(value: unknown): string {
  if (Array.isArray(value)) return value[0]?.toString() ?? ''
  return value?.toString() ?? ''
}

function findSuggestions() {
  const text = searchText.value
  showUrlSuggestion.value = isURL(text)
  if (showUrlSuggestion.value) {
    suggestions.value = []
    return
  }
  if (!enableTagsSuggestions.value) {
    suggestions.value = []
    return
  }
  suggestions.value = matchSuggestions(text, 100)
}

function onSuggestionClick(suggestion: TagSuggestion) {
  const words = searchText.value.split(' ')
  words[words.length - 1] = suggestion.label
  searchText.value = words.join(' ') + ' '
  suggestions.value = []
  showUrlSuggestion.value = false
}

function onUrlSuggestionClick() {
  const url = searchText.value.trim()
  if (url) window.open(url, '_blank')
}

function doSearch(keyword?: string) {
  let term = (keyword ?? searchText.value).trim()
  if (!term) return
  saveHistory(term)
  searchText.value = term
  hasSearched.value = true

  if (aggregatedMode.value) return

  term = applyLangFilter(selectedSourceKey.value, term, settingsStore.settings.autoLangFilter)
  const query: Record<string, string> = { keyword: term }
  if (searchOptions.value.length > 0 && currentSearchOptions.value.length > 0) {
    query.options = JSON.stringify(searchOptions.value)
  }
  router.push({
    path: `/search/${encodeURIComponent(selectedSourceKey.value)}`,
    query,
  })
}

function selectSource(key: string) {
  selectedSourceKey.value = key
  aggregatedMode.value = false
}

function onHistoryClick(keyword: string) {
  searchText.value = keyword
  doSearch(keyword)
}

function showContextMenu(event: MouseEvent, keyword: string) {
  event.preventDefault()
  contextMenuItem.value = keyword
  contextMenuVisible.value = true
  const menuWidth = 130
  const menuHeight = 80
  let top = event.clientY
  let left = event.clientX
  if (left + menuWidth > window.innerWidth) left = window.innerWidth - menuWidth - 8
  if (top + menuHeight > window.innerHeight) top = event.clientY - menuHeight
  if (left < 8) left = 8
  if (top < 8) top = 8
  contextMenuStyle.value = { top: top + 'px', left: left + 'px' }
  document.addEventListener('click', hideContextMenu, { once: true })
}

function hideContextMenu() {
  contextMenuVisible.value = false
  contextMenuItem.value = ''
  document.removeEventListener('click', hideContextMenu)
}

async function copyHistoryItem(keyword: string) {
  try {
    await navigator.clipboard.writeText(keyword)
  } catch {
    const input = document.createElement('input')
    input.value = keyword
    document.body.appendChild(input)
    input.select()
    document.execCommand('copy')
    document.body.removeChild(input)
  }
  hideContextMenu()
}

function onBack() { router.back() }

watch(searchText, () => {
  findSuggestions()
})

onMounted(async () => {
  await settingsStore.loadSettings()
  loadHistory()
  loadTagData()
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
    searchText.value = initialKeyword
    if (initialAggregated) hasSearched.value = true
    else doSearch(initialKeyword)
  }
  await nextTick()
  const input = document.querySelector('.search-page .van-field__control') as HTMLInputElement
  input?.focus()
})
</script>

<template>
  <div class="search-page">
    <van-nav-bar title="搜索" left-arrow @click-left="onBack" />

    <van-search
      v-model="searchText"
      placeholder="搜索漫画..."
      show-action
      action-text="搜索"
      @search="doSearch()"
      @click-action="doSearch()"
    />

    <div v-if="showUrlSuggestion || suggestions.length" class="suggestions-panel">
      <div
        v-if="showUrlSuggestion"
        class="suggestion-item url-suggestion"
        @click="onUrlSuggestionClick"
      >
        <van-icon name="link-o" size="16" />
        <span>打开链接</span>
      </div>
      <div
        v-for="s in suggestions"
        :key="`${s.namespace}:${s.key}`"
        class="suggestion-item"
        @click="onSuggestionClick(s)"
      >
        <span class="suggestion-namespace">{{ s.namespace }}</span>
        <span class="suggestion-key">{{ getTagSuggestionLabel(s) }}</span>
      </div>
    </div>

    <div v-if="sources.length" class="source-section">
      <div class="source-chips">
        <van-tag
          v-for="source in sources"
          :key="source.key"
          :type="selectedSourceKey === source.key && !aggregatedMode ? 'primary' : 'default'"
          size="medium"
          class="source-chip"
          @click="selectSource(source.key)"
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
            :type="localIsMultiSelected(groupIdx, parseOptionEntry(entry).key) ? 'primary' : 'default'"
            size="medium"
            class="option-chip"
            @click="localToggleMultiSelectOption(groupIdx, parseOptionEntry(entry).key)"
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
            @contextmenu="showContextMenu($event, item)"
          >
            <span class="history-text">{{ item }}</span>
            <van-icon name="cross" size="14" class="history-remove" @click.stop="removeHistoryItem(item)" />
          </div>
        </div>
        <Teleport to="body">
          <div
            v-if="contextMenuVisible"
            class="context-menu"
            :style="contextMenuStyle"
            @click.stop
          >
            <div class="context-menu-item" @click="copyHistoryItem(contextMenuItem)">
              <van-icon name="records-o" size="14" />
              <span>复制</span>
            </div>
            <div class="context-menu-item" @click="removeHistoryItem(contextMenuItem); hideContextMenu()">
              <van-icon name="delete-o" size="14" />
              <span>删除</span>
            </div>
          </div>
        </Teleport>
      </div>

      <van-empty
        v-if="!hasSearched && !searchHistory.length"
        description="输入关键词开始搜索"
        image="search"
      />

      <div v-if="aggregatedMode && hasSearched" class="results-section">
        <AggregatedSearchResults :keyword="searchText" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.search-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.suggestions-panel {
  max-height: 260px;
  overflow-y: auto;
  margin: 0 16px;
  background: #fff;
  border: 1px solid #ebedf0;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
  z-index: 100;
}

.suggestion-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  cursor: pointer;
  border-bottom: 1px solid #f5f5f5;
  font-size: 13px;
  transition: background 0.15s;
}

.suggestion-item:last-child { border-bottom: none; }
.suggestion-item:active { background: #f0f4ff; }
.suggestion-item.url-suggestion { color: #4f6ef7; font-weight: 500; }

.suggestion-namespace {
  display: inline-block;
  padding: 1px 6px;
  background: #eef1ff;
  color: #4f6ef7;
  border-radius: 3px;
  font-size: 11px;
  font-weight: 500;
  flex-shrink: 0;
}

.suggestion-key {
  color: #333;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
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

.option-group { margin-bottom: 6px; }
.option-group:last-child { margin-bottom: 0; }

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
  overflow-x: hidden;
  padding: 16px;
  padding-bottom: calc(16px + 50px + env(safe-area-inset-bottom, 0px));
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
  overscroll-behavior: contain;
}

.history-section { margin-bottom: 16px; }

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

.history-item:active { background: #e8e8e8; }

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

.results-section { margin-top: 4px; }

.context-menu {
  position: fixed;
  z-index: 9999;
  background: #fff;
  border-radius: 8px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.15);
  min-width: 120px;
  overflow: hidden;
}

.context-menu-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  font-size: 13px;
  color: #333;
  cursor: pointer;
  transition: background 0.15s;
}

.context-menu-item:active { background: #f0f4ff; }
</style>
