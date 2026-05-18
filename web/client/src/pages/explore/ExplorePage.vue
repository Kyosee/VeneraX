<script setup lang="ts">
import { ref, onMounted, computed, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { apiPost } from '@/services/api'
import { getComicSources, getSourceCapabilities } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'

interface ExploreTab {
  sourceKey: string
  sourceName: string
  exploreIndex: number
  title: string
}

interface ExploreSection {
  title: string
  comics: Record<string, any>[]
  viewMore?: string | { page: string; attributes?: Record<string, any> }
}

const route = useRoute()
const router = useRouter()
const settingsStore = useSettingsStore()

const tabs = ref<ExploreTab[]>([])
const activeTab = ref(0)
const comics = ref<Record<string, Record<string, any>[]>>({})
const sections = ref<Record<string, ExploreSection[]>>({})
const exploreType = ref<Record<string, string>>({})
const loading = ref<Record<string, boolean>>({})
const refreshingTab = ref<Record<string, boolean>>({})
const pages = ref<Record<string, number>>({})
const finished = ref<Record<string, boolean>>({})
const showFab = ref(true)
let lastScrollTop = 0
let scrollEl: HTMLElement | null = null

function tabKey(tab: ExploreTab): string {
  return `${tab.sourceKey}:${tab.exploreIndex}`
}

const currentTab = computed(() => tabs.value[activeTab.value])

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

async function loadComics(tab: ExploreTab, page = 1, append = false) {
  if (!tab.sourceKey) return
  const key = tabKey(tab)
  if (loading.value[key]) return
  loading.value[key] = true
  try {
    const res = await apiPost<any>('/api/server-db/explore/list', {
      sourceKey: tab.sourceKey,
      page,
      exploreIndex: tab.exploreIndex,
    })
    if (res?.type === 'multiPart' && Array.isArray(res.sections)) {
      exploreType.value[key] = 'multiPart'
      sections.value[key] = res.sections
      finished.value[key] = true
    } else {
      exploreType.value[key] = 'list'
      const items: Record<string, any>[] = res?.comics ?? res?.items ?? []
      if (append) {
        comics.value[key] = [...(comics.value[key] ?? []), ...items]
      } else {
        comics.value[key] = items
      }
      pages.value[key] = page
      if (items.length === 0) finished.value[key] = true
    }
  } catch (e) {
    console.error('Failed to load explore comics:', e)
  } finally {
    loading.value[key] = false
  }
}

async function onTabChange(index: number) {
  activeTab.value = index
  const tab = tabs.value[index]
  if (!tab) return
  const key = tabKey(tab)
  if (!comics.value[key] && !sections.value[key]) {
    await loadComics(tab)
  }
}

async function onRefresh() {
  const tab = currentTab.value
  if (!tab) return
  const key = tabKey(tab)
  refreshingTab.value[key] = true
  finished.value[key] = false
  await loadComics(tab, 1, false)
  refreshingTab.value[key] = false
}

async function onLoadMore() {
  const tab = currentTab.value
  if (!tab) return
  const key = tabKey(tab)
  if (!key || finished.value[key] || loading.value[key]) return
  const nextPage = (pages.value[key] ?? 1) + 1
  await loadComics(tab, nextPage, true)
}

function handleViewMore(section: ExploreSection, sourceKey: string) {
  if (!section.viewMore) return
  const vm = section.viewMore

  if (typeof vm === 'object' && vm.page) {
    if (vm.page === 'search') {
      const text = vm.attributes?.text || vm.attributes?.keyword || ''
      const opts = vm.attributes?.options
      const query: Record<string, string> = { keyword: text }
      if (opts) query.options = JSON.stringify(opts)
      router.push({ path: `/search/${encodeURIComponent(sourceKey)}`, query })
    } else if (vm.page === 'category') {
      const cat = vm.attributes?.category || ''
      const param = vm.attributes?.param || ''
      const opts = vm.attributes?.options
      const query: Record<string, string> = { cat, source: sourceKey, title: cat }
      if (param) query.param = param
      if (opts) query.options = JSON.stringify(opts)
      router.push({ path: '/categories', query })
    }
    return
  }

  if (typeof vm === 'string') {
    const segments = vm.split(':')
    const page = segments[0]
    if (page === 'search' && segments[1]) {
      router.push({ path: `/search/${encodeURIComponent(sourceKey)}`, query: { keyword: segments[1] } })
    } else if (page === 'category') {
      const c = segments[1] || ''
      if (c.includes('@')) {
        const [cat, param] = c.split('@')
        router.push({ path: '/categories', query: { cat, source: sourceKey, title: cat, param } })
      } else {
        router.push({ path: '/categories', query: { cat: c, source: sourceKey, title: c } })
      }
    }
  }
}

function onScroll(e: Event) {
  const target = e.target as HTMLElement
  const currentScrollTop = target.scrollTop
  showFab.value = currentScrollTop <= lastScrollTop || currentScrollTop < 50
  lastScrollTop = currentScrollTop
}

onMounted(async () => {
  await settingsStore.loadSettings()
  const sources = await getComicSources()

  const allTabs: ExploreTab[] = []
  for (const source of sources) {
    try {
      const caps = await getSourceCapabilities(source.key)
      if (caps?.explore?.length) {
        for (let i = 0; i < caps.explore.length; i++) {
          const ep = caps.explore[i]
          allTabs.push({
            sourceKey: source.key,
            sourceName: source.name,
            exploreIndex: i,
            title: ep.title || source.name,
          })
        }
      } else {
        allTabs.push({
          sourceKey: source.key,
          sourceName: source.name,
          exploreIndex: 0,
          title: source.name,
        })
      }
    } catch {
      allTabs.push({
        sourceKey: source.key,
        sourceName: source.name,
        exploreIndex: 0,
        title: source.name,
      })
    }
  }

  tabs.value = allTabs

  if (allTabs.length > 0) {
    const requestedSource = String(route.query.source || '')
    const targetIndex = requestedSource
      ? allTabs.findIndex(t => t.sourceKey === requestedSource)
      : -1
    activeTab.value = targetIndex >= 0 ? targetIndex : 0
    await loadComics(allTabs[activeTab.value])
  }

  setTimeout(() => {
    scrollEl = document.querySelector('.explore-content')
    scrollEl?.addEventListener('scroll', onScroll)
  }, 100)
})

onUnmounted(() => {
  scrollEl?.removeEventListener('scroll', onScroll)
})
</script>

<template>
  <div class="explore-page">
    <div class="explore-search-bar" @click="$router.push('/search')">
      <van-icon name="search" size="16" />
      <span>搜索漫画</span>
    </div>

    <van-empty v-if="!tabs.length" description="暂无漫画源" />

    <van-tabs
      v-if="tabs.length"
      v-model:active="activeTab"
      class="explore-tabs"
      color="#4f6ef7"
      title-active-color="#4f6ef7"
      swipeable
      sticky
      @change="onTabChange"
    >
      <van-tab v-for="tab in tabs" :key="tabKey(tab)" :title="tab.title">
        <van-pull-refresh v-model="refreshingTab[tabKey(tab)]" @refresh="onRefresh">
          <div class="explore-content" @scroll="onScroll">
            <div
              v-if="loading[tabKey(tab)] && !comics[tabKey(tab)]?.length && !sections[tabKey(tab)]?.length"
              class="comic-grid"
              :style="gridStyle"
            >
              <div v-for="n in 12" :key="n" class="comic-card skeleton-card">
                <div class="skeleton-cover"></div>
                <div class="skeleton-title"></div>
              </div>
            </div>

            <template v-if="exploreType[tabKey(tab)] === 'multiPart' && sections[tabKey(tab)]?.length">
              <div v-for="section in sections[tabKey(tab)]" :key="section.title" class="explore-section">
                <div class="section-header">
                  <h3 class="section-title">{{ section.title }}</h3>
                  <span
                    v-if="section.viewMore"
                    class="section-view-more"
                    @click="handleViewMore(section, tab.sourceKey)"
                  >查看更多 &gt;</span>
                </div>
                <div class="comic-grid" :style="gridStyle">
                  <ComicCard
                    v-for="comic in section.comics"
                    :key="comic.id"
                    :comic="comic"
                    :source-key="tab.sourceKey"
                    :source-name="tab.sourceName"
                    class="comic-card"
                  />
                </div>
              </div>
            </template>

            <template v-else-if="comics[tabKey(tab)]?.length">
              <div class="comic-grid" :style="gridStyle">
                <ComicCard
                  v-for="comic in comics[tabKey(tab)] ?? []"
                  :key="comic.id"
                  :comic="comic"
                  :source-key="tab.sourceKey"
                  :source-name="tab.sourceName"
                  class="comic-card"
                />
              </div>

              <div v-if="!finished[tabKey(tab)]" class="load-more">
                <van-loading v-if="loading[tabKey(tab)]" size="24px" />
                <van-button v-else size="small" plain @click="onLoadMore">加载更多</van-button>
              </div>
            </template>

            <van-empty
              v-if="!loading[tabKey(tab)] && !comics[tabKey(tab)]?.length && !sections[tabKey(tab)]?.length"
              description="暂无内容"
              image="search"
            />
          </div>
        </van-pull-refresh>
      </van-tab>
    </van-tabs>

    <transition name="fab-fade">
      <div v-show="showFab && tabs.length" class="fab" @click="onRefresh">
        <van-icon name="replay" size="22" />
      </div>
    </transition>
  </div>
</template>

<style scoped>
.explore-page {
  height: 100%;
  display: flex;
  flex-direction: column;
  position: relative;
}

.explore-search-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 10px 12px;
  padding: 8px 14px;
  background: #f5f5f5;
  border-radius: 20px;
  color: #999;
  font-size: 14px;
  cursor: pointer;
}

.explore-section { margin-bottom: 16px; }

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 12px 0 8px;
  padding: 0 4px;
}

.section-title {
  font-size: 16px;
  font-weight: 600;
  color: #333;
  margin: 0;
}

.section-view-more {
  font-size: 12px;
  color: #4f6ef7;
  cursor: pointer;
  flex-shrink: 0;
}

.section-view-more:active { opacity: 0.7; }

.explore-tabs {
  flex: 1;
  display: flex;
  flex-direction: column;
}

:deep(.van-tabs__content) { flex: 1; overflow: hidden; }
:deep(.van-tab__panel) { height: 100%; }

.explore-content {
  height: calc(100vh - 94px);
  overflow-y: auto;
  padding: 16px;
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
  transform: translateZ(0);
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

.comic-card:active { transform: scale(0.97); }

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

.skeleton-card { pointer-events: none; }

.skeleton-cover {
  width: 100%;
  aspect-ratio: 0.64;
  border-radius: 4px;
  background: linear-gradient(90deg, #f0f0f0 25%, #e8e8e8 50%, #f0f0f0 75%);
  background-size: 200% 100%;
  animation: shimmer 1.5s infinite;
}

.skeleton-title {
  margin-top: 6px;
  height: 14px;
  width: 80%;
  border-radius: 3px;
  background: linear-gradient(90deg, #f0f0f0 25%, #e8e8e8 50%, #f0f0f0 75%);
  background-size: 200% 100%;
  animation: shimmer 1.5s infinite;
}

@keyframes shimmer {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}

.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}

.fab {
  position: fixed;
  bottom: 72px;
  right: 16px;
  width: 48px;
  height: 48px;
  border-radius: 50%;
  background: #4f6ef7;
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: 0 4px 12px rgba(79, 110, 247, 0.4);
  cursor: pointer;
  z-index: 100;
  transition: transform 0.2s ease, opacity 0.2s ease;
}

.fab:active { transform: scale(0.92); }

.fab-fade-enter-active,
.fab-fade-leave-active {
  transition: opacity 0.25s ease, transform 0.25s ease;
}

.fab-fade-enter-from,
.fab-fade-leave-to {
  opacity: 0;
  transform: translateY(16px);
}
</style>
