<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { apiPost } from '@/services/api'
import ProxiedImage from '@/components/ProxiedImage.vue'
import { getComicSources, getSourceCapabilities } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'
import type { ComicSource, SourceCapabilities, SourceSearchOption } from '@/types'

interface CategoryItem {
  title: string
  cover?: string
  link?: string
  param?: string
}

interface CategoryComic {
  id: string
  title: string
  cover: string
  subtitle?: string
}

const router = useRouter()
const route = useRoute()
const settingsStore = useSettingsStore()
const sources = ref<ComicSource[]>([])
const activeTab = ref(0)
const categories = ref<Record<string, CategoryItem[]>>({})
const catLoading = ref<Record<string, boolean>>({})
const catError = ref<Record<string, string | null>>({})
const capabilities = ref<Record<string, SourceCapabilities | null>>({})
const randomParts = ref<Record<string, Array<{ name: string; fullList: CategoryItem[] }>>>({})

const selectedCategory = ref<string | null>(null)
const selectedCategoryTitle = ref('')
const selectedCategoryParam = ref<string | null>(null)
const comics = ref<CategoryComic[]>([])
const comicsPage = ref(1)
const comicsLoading = ref(false)
const comicsError = ref<string | null>(null)
const comicsHasMore = ref(false)
const filterOptions = ref<string[]>([])

const currentSourceKey = computed(() => sources.value[activeTab.value]?.key ?? '')
const currentSourceName = computed(() => sources.value[activeTab.value]?.name ?? currentSourceKey.value)
const showComicsList = computed(() => selectedCategory.value !== null)

const currentCategoryOptions = computed<SourceSearchOption[]>(() => {
  const caps = capabilities.value[currentSourceKey.value]
  return caps?.categoryComics?.optionList ?? []
})

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

watch(() => route.query.cat, (val) => {
  if (val && typeof val === 'string') {
    selectedCategory.value = val
    const t = route.query.title
    selectedCategoryTitle.value = typeof t === 'string' ? t : val
    const p = route.query.param
    selectedCategoryParam.value = typeof p === 'string' ? p : null
    initFilterOptions()
    loadCategoryComics(currentSourceKey.value, val, true)
  } else {
    selectedCategory.value = null
    selectedCategoryTitle.value = ''
    selectedCategoryParam.value = null
    comics.value = []
    comicsPage.value = 1
    comicsHasMore.value = false
  }
}, { immediate: true })

function initFilterOptions() {
  const opts = currentCategoryOptions.value
  filterOptions.value = opts.map(opt => {
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

async function loadCategories(sourceKey: string) {
  if (!sourceKey || categories.value[sourceKey]) return
  catLoading.value[sourceKey] = true
  catError.value[sourceKey] = null
  try {
    if (capabilities.value[sourceKey] === undefined) {
      capabilities.value[sourceKey] = null
      try {
        const caps = await getSourceCapabilities(sourceKey)
        capabilities.value[sourceKey] = caps
      } catch { /* ignore */ }
    }
    const caps = capabilities.value[sourceKey]
    if (caps?.category?.parts?.length) {
      const items: CategoryItem[] = []
      const randParts: Array<{ name: string; fullList: CategoryItem[] }> = []
      for (const part of caps.category.parts) {
        const fullList: CategoryItem[] = []
        for (let i = 0; i < part.categories.length; i++) {
          fullList.push({
            title: part.categories[i],
            param: part.categoryParams?.[i] ?? undefined,
          })
        }
        if (part.type === 'random') {
          const count = Math.min(12, fullList.length)
          const shuffled = [...fullList].sort(() => Math.random() - 0.5)
          items.push(...shuffled.slice(0, count))
          randParts.push({ name: part.name, fullList })
        } else {
          items.push(...fullList)
        }
      }
      categories.value[sourceKey] = items
      if (randParts.length) randomParts.value[sourceKey] = randParts
    } else {
      const res = await apiPost<any>('/api/server-db/categories', { sourceKey })
      if (res?.ok === false) throw new Error(res?.error ?? 'Failed to load categories')
      const rawCats = res?.categories ?? []
      if (rawCats && typeof rawCats === 'object' && !Array.isArray(rawCats) && rawCats.parts) {
        const items: CategoryItem[] = []
        for (const part of (rawCats.parts || [])) {
          for (let i = 0; i < (part.categories || []).length; i++) {
            items.push({
              title: part.categories[i],
              param: part.categoryParams?.[i] ?? undefined,
            })
          }
        }
        categories.value[sourceKey] = items
      } else {
        categories.value[sourceKey] = Array.isArray(rawCats) ? rawCats : []
      }
    }
  } catch (e: any) {
    catError.value[sourceKey] = e.message ?? 'Failed to load categories'
    categories.value[sourceKey] = []
  } finally {
    catLoading.value[sourceKey] = false
  }
}

async function loadCategoryComics(sourceKey: string, categoryId: string, reset = false) {
  if (!sourceKey || !categoryId) return
  if (comicsLoading.value) return
  comicsLoading.value = true
  comicsError.value = null
  const page = reset ? 1 : comicsPage.value + 1
  try {
    const opts = currentCategoryOptions.value.length > 0 ? filterOptions.value : undefined
    const res = await apiPost<any>('/api/server-db/category/comics', {
      sourceKey,
      categoryId,
      page,
      param: selectedCategoryParam.value,
      options: opts,
    })
    if (res?.ok === false) throw new Error(res?.error ?? 'Failed to load comics')
    const items: CategoryComic[] = res?.comics ?? []
    if (reset) {
      comics.value = items
    } else {
      comics.value = [...comics.value, ...items]
    }
    comicsPage.value = page
    comicsHasMore.value = res?.hasMore ?? false
  } catch (e: any) {
    comicsError.value = e.message ?? 'Failed to load comics'
  } finally {
    comicsLoading.value = false
  }
}

async function retryCategories() {
  const key = currentSourceKey.value
  if (!key) return
  delete categories.value[key]
  await loadCategories(key)
}

function onTabChange(index: number) {
  activeTab.value = index
  const key = sources.value[index]?.key
  if (key) loadCategories(key)
}

function onCategoryClick(cat: CategoryItem) {
  const id = cat.link || cat.title
  const query: Record<string, string> = { cat: id, title: cat.title }
  if (cat.param) query.param = cat.param
  router.push({ path: route.path, query })
}

function shuffleRandomCategories(sourceKey: string) {
  const parts = randomParts.value[sourceKey]
  if (!parts?.length || !categories.value[sourceKey]) return
  const items = [...categories.value[sourceKey]]
  for (const rp of parts) {
    const idx = items.findIndex(item => rp.fullList.some(fl => fl.title === item.title && fl.param === item.param))
    if (idx < 0) continue
    const count = Math.min(12, rp.fullList.length)
    const shuffled = [...rp.fullList].sort(() => Math.random() - 0.5).slice(0, count)
    const endIdx = idx + count
    items.splice(idx, endIdx - idx, ...shuffled)
  }
  categories.value[sourceKey] = items
}

function onBackFromComics() {
  router.push({ path: route.path })
}

function goToRanking(sourceKey: string) {
  router.push({ path: '/ranking', query: { sourceKey } })
}

async function loadMoreComics() {
  if (!selectedCategory.value) return
  await loadCategoryComics(currentSourceKey.value, selectedCategory.value, false)
}

async function retryComics() {
  if (!selectedCategory.value) return
  await loadCategoryComics(currentSourceKey.value, selectedCategory.value, true)
}

onMounted(async () => {
  await settingsStore.loadSettings()
  try {
    const list = await getComicSources()
    sources.value = list
    if (list.length > 0) {
      await loadCategories(list[0].key)
    }
  } catch (e) {
    console.error('Failed to load sources:', e)
  }
})
</script>

<template>
  <div class="categories-page">
    <template v-if="showComicsList">
      <van-nav-bar
        :title="selectedCategoryTitle"
        left-arrow
        @click-left="onBackFromComics"
      />

      <div v-if="currentCategoryOptions.length" class="filter-section">
        <div v-for="(opt, groupIdx) in currentCategoryOptions" :key="groupIdx" class="filter-group">
          <span v-if="opt.label" class="filter-label">{{ opt.label }}</span>
          <div v-if="opt.options.length > 8" class="filter-dropdown">
            <select
              :value="filterOptions[groupIdx]"
              @change="filterOptions[groupIdx] = ($event.target as HTMLSelectElement).value; loadCategoryComics(currentSourceKey, selectedCategory!, true)"
            >
              <option v-for="entry in opt.options" :key="entry" :value="parseOptionEntry(entry).key">
                {{ parseOptionEntry(entry).label }}
              </option>
            </select>
          </div>
          <div v-else class="filter-chips">
            <van-tag
              v-for="entry in opt.options"
              :key="entry"
              :type="filterOptions[groupIdx] === parseOptionEntry(entry).key ? 'primary' : 'default'"
              size="medium"
              class="filter-chip"
              @click="filterOptions[groupIdx] = parseOptionEntry(entry).key; loadCategoryComics(currentSourceKey, selectedCategory!, true)"
            >
              {{ parseOptionEntry(entry).label }}
            </van-tag>
          </div>
        </div>
      </div>

      <div class="comics-content">
        <div v-if="comicsLoading && !comics.length" class="loading-state">
          <van-loading size="36px" color="#4f6ef7" vertical>Loading...</van-loading>
        </div>

        <div v-if="comicsError && !comics.length && !comicsLoading" class="error-state">
          <van-empty image="error" :description="comicsError" />
          <van-button type="primary" size="small" @click="retryComics">Retry</van-button>
        </div>

        <div v-if="comics.length" class="comic-grid" :style="gridStyle">
          <ComicCard
            v-for="comic in comics"
            :key="comic.id"
            :comic="comic"
            :source-key="currentSourceKey"
            :source-name="currentSourceName"
            class="comic-card"
          />
        </div>

        <div v-if="comics.length && comicsHasMore" class="load-more">
          <van-loading v-if="comicsLoading" size="24px" />
          <van-button v-else size="small" plain @click="loadMoreComics">Load more</van-button>
        </div>

        <van-empty
          v-if="!comicsLoading && !comics.length && !comicsError"
          description="No comics in this category"
          image="search"
        />
      </div>
    </template>

    <template v-else>
      <van-empty v-if="!sources.length" description="No comic sources available" />

      <van-tabs
        v-if="sources.length"
        v-model:active="activeTab"
        class="categories-tabs"
        color="#4f6ef7"
        title-active-color="#4f6ef7"
        swipeable
        sticky
        @change="onTabChange"
      >
        <van-tab v-for="source in sources" :key="source.key" :title="source.name">
          <div class="categories-content">
            <div
              v-if="capabilities[source.key] && (capabilities[source.key]!.category?.enableRankingPage || capabilities[source.key]!.categoryComics?.hasRanking)"
              class="ranking-quick-access"
            >
              <van-button
                type="primary"
                size="small"
                icon="chart-trending-o"
                @click="goToRanking(source.key)"
              >
                排行榜
              </van-button>
            </div>

            <div v-if="randomParts[source.key]?.length" class="random-refresh-bar">
              <van-button size="small" plain icon="replay" @click="shuffleRandomCategories(source.key)">
                换一批
              </van-button>
            </div>

            <div v-if="catLoading[source.key]" class="loading-state">
              <van-loading size="36px" color="#4f6ef7" vertical>Loading categories...</van-loading>
            </div>

            <div v-if="catError[source.key] && !catLoading[source.key]" class="error-state">
              <van-empty image="error" :description="catError[source.key]!" />
              <van-button type="primary" size="small" @click="retryCategories">Retry</van-button>
            </div>

            <div
              v-if="!catLoading[source.key] && !catError[source.key] && categories[source.key]?.length"
              class="category-grid"
            >
              <div
                v-for="cat in categories[source.key]"
                :key="cat.title"
                class="category-item"
                @click="onCategoryClick(cat)"
              >
                <div class="category-cover-wrap">
                  <ProxiedImage
                    class="category-cover"
                    :src="cat.cover ?? ''"
                    :alt="cat.title"
                  />
                </div>
                <div class="category-name">{{ cat.title }}</div>
              </div>
            </div>

            <van-empty
              v-if="!catLoading[source.key] && !catError[source.key] && !categories[source.key]?.length"
              description="No categories available"
              image="search"
            />
          </div>
        </van-tab>
      </van-tabs>
    </template>
  </div>
</template>

<style scoped>
.categories-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.filter-section {
  padding: 8px 16px;
  border-bottom: 1px solid #f0f0f0;
}

.filter-group {
  margin-bottom: 6px;
}

.filter-group:last-child {
  margin-bottom: 0;
}

.filter-label {
  display: block;
  font-size: 12px;
  color: #666;
  margin-bottom: 4px;
}

.filter-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.filter-chip {
  cursor: pointer;
  transition: all 0.2s;
}

.filter-dropdown select {
  width: 100%;
  padding: 6px 8px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 13px;
  background: #fff;
  color: #333;
}

.categories-tabs {
  flex: 1;
  display: flex;
  flex-direction: column;
}

:deep(.van-tabs__content) {
  flex: 1;
  overflow: hidden;
}

:deep(.van-tab__panel) {
  height: 100%;
}

.categories-content {
  height: calc(100vh - 94px);
  overflow-y: auto;
  padding: 16px;
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
}

.comics-content {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
}

.category-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
}

@media (min-width: 720px) {
  .category-grid {
    grid-template-columns: repeat(5, 1fr);
  }
}

@media (min-width: 480px) and (max-width: 719px) {
  .category-grid {
    grid-template-columns: repeat(4, 1fr);
  }
}

.category-item {
  cursor: pointer;
  text-align: center;
  transition: transform 0.15s ease;
}

.category-item:active {
  transform: scale(0.95);
}

.category-cover-wrap {
  width: 100%;
  aspect-ratio: 1;
  border-radius: 8px;
  overflow: hidden;
  background: #f5f5f5;
}

.category-cover {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.category-cover-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(135deg, #f0f0f0, #e8e8e8);
}

.category-name {
  margin-top: 8px;
  font-size: 13px;
  line-height: 1.3;
  color: #333;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-overflow: ellipsis;
  word-break: break-all;
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
  content-visibility: auto;
  contain-intrinsic-size: auto 300px;
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

.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}

.ranking-quick-access {
  padding: 8px 0 4px;
}

.random-refresh-bar {
  padding: 0 0 12px;
}
</style>
