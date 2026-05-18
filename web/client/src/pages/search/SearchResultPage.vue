<script setup lang="ts">
import { ref, onMounted, computed, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { searchComics, getSourceCapabilities, batchGetComicBasicInfo } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'
import type { SourceCapabilities, SourceSearchOption, TagSuggestion } from '@/types'
import { loadTagData, matchSuggestions, isURL, getTagSuggestionLabel } from '@/utils/tags-translation'
import { parseOptionEntry, initSearchOptions, toggleMultiSelectOption as toggleMultiOpt, isMultiSelected as isMultiOpt } from '@/utils/options'
import { applyAutoLangFilter } from '@/utils/search'
import { useGridStyle } from '@/composables/useGridStyle'

interface SearchResult {
  id: string
  title: string
  cover: string
  subtitle?: string
  sourceKey?: string
}

const router = useRouter()
const route = useRoute()
const settingsStore = useSettingsStore()

const sourceKey = computed(() => route.params.sourceKey as string)
const initialKeyword = computed(() => (route.query.keyword as string) || '')

const searchText = ref(initialKeyword.value)
const comics = ref<SearchResult[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const hasMore = ref(false)
const page = ref(1)
const hasSearched = ref(false)

const capabilities = ref<SourceCapabilities | null>(null)
const searchOptions = ref<string[]>([])
const showSettings = ref(false)
const showSuggestions = ref(false)
const suggestions = ref<TagSuggestion[]>([])
const showUrlSuggestion = ref(false)

const sourceName = ref('')

const currentSearchOptions = computed<SourceSearchOption[]>(() => {
  return capabilities.value?.search?.optionList ?? []
})

const enableTagsSuggestions = computed(() => {
  return capabilities.value?.search?.enableTagsSuggestions ?? false
})

const gridStyle = useGridStyle()

function localToggleMultiSelectOption(groupIndex: number, optionKey: string) {
  const current: string[] = (() => { try { return JSON.parse(searchOptions.value[groupIndex] || '[]') } catch { return [] } })()
  toggleMultiOpt(current, optionKey)
  searchOptions.value[groupIndex] = JSON.stringify(current)
}

function localIsMultiSelected(groupIndex: number, optionKey: string): boolean {
  return isMultiOpt(searchOptions.value[groupIndex], optionKey)
}

function findSuggestions() {
  const text = searchText.value
  showUrlSuggestion.value = isURL(text)
  if (showUrlSuggestion.value) {
    suggestions.value = []
    showSuggestions.value = true
    return
  }
  if (!enableTagsSuggestions.value) {
    suggestions.value = []
    showSuggestions.value = false
    return
  }
  suggestions.value = matchSuggestions(text, 200)
  showSuggestions.value = suggestions.value.length > 0
}

function onSuggestionClick(s: TagSuggestion) {
  const words = searchText.value.split(' ')
  words[words.length - 1] = s.label
  searchText.value = words.join(' ') + ' '
  showSuggestions.value = false
  showUrlSuggestion.value = false
}

function onUrlSuggestionClick() {
  const url = searchText.value.trim()
  if (url) window.open(url, '_blank')
}

async function doSearch() {
  let term = searchText.value.trim()
  if (!term) return
  term = applyAutoLangFilter(sourceKey.value, term, settingsStore.settings.autoLangFilter)
  hasSearched.value = true
  page.value = 1
  comics.value = []
  loading.value = true
  error.value = null
  showSuggestions.value = false

  try {
    const opts = currentSearchOptions.value.length > 0 ? searchOptions.value : undefined
    const res = await searchComics(sourceKey.value, term, 1, opts)
    comics.value = (res.comics ?? []).map((c: any) => ({
      ...c,
      sourceKey: c.sourceKey || sourceKey.value,
    }))
    hasMore.value = res.hasMore
    page.value = 1
    enrichWithLocalInfo(comics.value)
  } catch (e: any) {
    error.value = e.message ?? '搜索失败'
  } finally {
    loading.value = false
  }
}

async function loadMore() {
  if (loading.value || !hasMore.value) return
  loading.value = true
  const nextPage = page.value + 1
  try {
    const opts = currentSearchOptions.value.length > 0 ? searchOptions.value : undefined
    const res = await searchComics(sourceKey.value, searchText.value.trim(), nextPage, opts)
    const newComics = (res.comics ?? []).map((c: any) => ({
      ...c,
      sourceKey: c.sourceKey || sourceKey.value,
    }))
    comics.value.push(...newComics)
    hasMore.value = res.hasMore
    page.value = nextPage
    enrichWithLocalInfo(newComics)
  } catch (e: any) {
    error.value = e.message ?? '加载更多失败'
  } finally {
    loading.value = false
  }
}

async function enrichWithLocalInfo(comicsList: SearchResult[]) {
  if (!comicsList.length) return
  try {
    const ids = comicsList.map(c => ({ sourceKey: sourceKey.value, comicId: c.id }))
    const infoMap = await batchGetComicBasicInfo(ids)
    for (const c of comicsList) {
      const key = `${sourceKey.value}:${c.id}`
      const info = infoMap[key]
      if (info) {
        if (!c.subtitle && info.subtitle) c.subtitle = info.subtitle
      }
    }
  } catch { /* best-effort */ }
}

function onSettingsChange() {
  showSettings.value = false
  if (hasSearched.value) doSearch()
}

watch(route, () => {
  if (hasSearched.value && searchText.value) doSearch()
})

watch(searchText, () => {
  findSuggestions()
})

onMounted(async () => {
  await settingsStore.loadSettings()
  await loadTagData()

  const caps = await getSourceCapabilities(sourceKey.value)
  capabilities.value = caps
  sourceName.value = caps?.name || sourceKey.value
  searchOptions.value = initSearchOptions(currentSearchOptions.value, route.query.options as string | undefined)

  if (initialKeyword.value) {
    searchText.value = initialKeyword.value
    await doSearch()
  }
})
</script>

<template>
  <div class="search-result-page">
    <van-nav-bar
      :title="sourceName || '搜索结果'"
      left-arrow
      @click-left="router.back()"
    >
      <template #right>
        <van-icon
          v-if="currentSearchOptions.length"
          name="filter-o"
          size="20"
          @click="showSettings = true"
        />
      </template>
    </van-nav-bar>

    <van-search
      v-model="searchText"
      placeholder="搜索漫画..."
      show-action
      action-text="搜索"
      @search="doSearch()"
      @click-action="doSearch()"
    />

    <div v-if="showSuggestions" class="suggestions-overlay" @click.self="showSuggestions = false">
      <div class="suggestions-panel">
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
    </div>

    <div class="search-content">
      <div v-if="loading && !comics.length" class="loading-state">
        <van-loading size="36px" color="#4f6ef7" vertical>搜索中...</van-loading>
      </div>

      <div v-if="error && !comics.length && !loading" class="error-state">
        <van-empty image="error" :description="error" />
        <van-button type="primary" size="small" @click="doSearch()">重试</van-button>
      </div>

      <div v-if="comics.length" class="results-section">
        <div class="comic-grid" :style="gridStyle">
          <ComicCard
            v-for="comic in comics"
            :key="`${sourceKey}:${comic.id}`"
            :comic="comic"
            :source-key="sourceKey"
            :source-name="sourceName"
            class="comic-card"
          />
        </div>

        <div v-if="hasMore" class="load-more">
          <van-loading v-if="loading" size="24px" />
          <van-button v-else size="small" plain @click="loadMore">加载更多</van-button>
        </div>
      </div>

      <van-empty
        v-if="hasSearched && !loading && !comics.length && !error"
        description="没有找到结果"
        image="search"
      />
    </div>

    <van-overlay :show="showSettings" @click="showSettings = false" />
    <van-popup
      v-model:show="showSettings"
      position="bottom"
      :style="{ height: '50%', borderRadius: '12px 12px 0 0' }"
    >
      <div class="settings-dialog">
        <h3 class="settings-title">搜索设置</h3>
        <div v-if="currentSearchOptions.length" class="settings-options">
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
        <van-button type="primary" block @click="onSettingsChange">应用</van-button>
      </div>
    </van-popup>
  </div>
</template>

<style scoped>
.search-result-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.suggestions-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 100;
  background: rgba(0, 0, 0, 0.15);
}

.suggestions-panel {
  position: absolute;
  top: 56px;
  left: 16px;
  right: 16px;
  max-height: 260px;
  overflow-y: auto;
  background: #fff;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
}

.suggestion-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  cursor: pointer;
  border-bottom: 1px solid #f5f5f5;
  font-size: 13px;
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

.search-content {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
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

.results-section { margin-top: 4px; }

.comic-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 192px));
  gap: 12px;
  justify-content: center;
}

.comic-card {
  cursor: pointer;
  transition: transform 0.15s ease;
  content-visibility: auto;
  contain-intrinsic-size: auto 300px;
}

.comic-card:active { transform: scale(0.97); }

.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}

.settings-dialog {
  padding: 20px 16px;
}

.settings-title {
  font-size: 16px;
  font-weight: 600;
  margin: 0 0 16px;
  text-align: center;
}

.settings-options {
  margin-bottom: 20px;
}

.option-group { margin-bottom: 12px; }

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

.option-chip { cursor: pointer; transition: all 0.2s; }

.option-dropdown select {
  width: 100%;
  padding: 6px 8px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 13px;
  background: #fff;
  color: #333;
}
</style>
