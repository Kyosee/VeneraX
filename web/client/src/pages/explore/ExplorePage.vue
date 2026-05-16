<script setup lang="ts">
import { ref, onMounted, computed, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import { apiPost } from '@/services/api'
import { getComicSources } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'
import type { ComicSource } from '@/types'

interface ExploreSection {
  title: string
  comics: Record<string, any>[]
}

const route = useRoute()
const settingsStore = useSettingsStore()
const sources = ref<ComicSource[]>([])
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

const currentSourceKey = computed(() => sources.value[activeTab.value]?.key ?? '')
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

async function loadComics(sourceKey: string, page = 1, append = false) {
  if (!sourceKey) return
  if (loading.value[sourceKey]) return
  loading.value[sourceKey] = true
  try {
    // Server now merges cached comic basic info (author, status, updateTime, etc.)
    // into each comic in the explore response, so no client-side enrichment needed.
    const res = await apiPost<any>('/api/server-db/explore/list', { sourceKey, page })
    if (res?.type === 'multiPart' && Array.isArray(res.sections)) {
      exploreType.value[sourceKey] = 'multiPart'
      sections.value[sourceKey] = res.sections
      finished.value[sourceKey] = true
    } else {
      exploreType.value[sourceKey] = 'list'
      const items: Record<string, any>[] = res?.comics ?? res?.items ?? []
      if (append) {
        comics.value[sourceKey] = [...(comics.value[sourceKey] ?? []), ...items]
      } else {
        comics.value[sourceKey] = items
      }
      pages.value[sourceKey] = page
      if (items.length === 0) finished.value[sourceKey] = true
    }
  } catch (e) {
    console.error('Failed to load explore comics:', e)
  } finally {
    loading.value[sourceKey] = false
  }
}

async function onTabChange(index: number) {
  activeTab.value = index
  const key = sources.value[index]?.key
  if (key && !comics.value[key]) {
    await loadComics(key)
  }
}

async function onRefresh() {
  const key = currentSourceKey.value
  if (!key) return
  refreshingTab.value[key] = true
  finished.value[key] = false
  await loadComics(key, 1, false)
  refreshingTab.value[key] = false
}

async function onLoadMore() {
  const key = currentSourceKey.value
  if (!key || finished.value[key] || loading.value[key]) return
  const nextPage = (pages.value[key] ?? 1) + 1
  await loadComics(key, nextPage, true)
}

function onScroll(e: Event) {
  const target = e.target as HTMLElement
  const currentScrollTop = target.scrollTop
  showFab.value = currentScrollTop <= lastScrollTop || currentScrollTop < 50
  lastScrollTop = currentScrollTop
}

onMounted(async () => {
  await settingsStore.loadSettings()
  const list = await getComicSources()
  sources.value = list
  if (list.length > 0) {
    const requestedSource = String(route.query.source || '')
    const targetIndex = requestedSource ? list.findIndex(s => s.key === requestedSource) : -1
    const startIndex = targetIndex >= 0 ? targetIndex : 0
    activeTab.value = startIndex
    await loadComics(list[startIndex].key)
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
    <!-- Empty state when no sources -->
    <van-empty v-if="!sources.length && !loading['__init']" description="暂无漫画源" />

    <!-- Tabs -->
    <van-tabs
      v-if="sources.length"
      v-model:active="activeTab"
      class="explore-tabs"
      color="#4f6ef7"
      title-active-color="#4f6ef7"
      swipeable
      sticky
      @change="onTabChange"
    >
      <van-tab v-for="source in sources" :key="source.key" :title="source.name">
        <van-pull-refresh v-model="refreshingTab[source.key]" @refresh="onRefresh">
          <div class="explore-content" @scroll="onScroll">
            <!-- Skeleton loading -->
            <div v-if="loading[source.key] && !comics[source.key]?.length && !sections[source.key]?.length" class="comic-grid" :style="gridStyle">
              <div v-for="n in 12" :key="n" class="comic-card skeleton-card">
                <div class="skeleton-cover"></div>
                <div class="skeleton-title"></div>
              </div>
            </div>

            <!-- Multi-part sections -->
            <template v-if="exploreType[source.key] === 'multiPart' && sections[source.key]?.length">
              <div v-for="section in sections[source.key]" :key="section.title" class="explore-section">
                <h3 class="section-title">{{ section.title }}</h3>
                <div class="comic-grid" :style="gridStyle">
                  <ComicCard
                    v-for="comic in section.comics"
                    :key="comic.id"
                    :comic="comic"
                    :source-key="source.key"
                    :source-name="source.name"
                    class="comic-card"
                  />
                </div>
              </div>
            </template>

            <!-- Comic grid (list mode) -->
            <template v-else-if="comics[source.key]?.length">
              <div class="comic-grid" :style="gridStyle">
                <ComicCard
                  v-for="comic in comics[source.key] ?? []"
                  :key="comic.id"
                  :comic="comic"
                  :source-key="source.key"
                  :source-name="source.name"
                  class="comic-card"
                />
              </div>

              <!-- Load more -->
              <div v-if="!finished[source.key]" class="load-more">
                <van-loading v-if="loading[source.key]" size="24px" />
                <van-button v-else size="small" plain @click="onLoadMore">加载更多</van-button>
              </div>
            </template>

            <!-- Empty state -->
            <van-empty
              v-if="!loading[source.key] && !comics[source.key]?.length && !sections[source.key]?.length"
              description="暂无内容"
              image="search"
            />
          </div>
        </van-pull-refresh>
      </van-tab>
    </van-tabs>

    <!-- FAB -->
    <transition name="fab-fade">
      <div v-show="showFab && sources.length" class="fab" @click="onRefresh">
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

.explore-section {
  margin-bottom: 16px;
}

.section-title {
  font-size: 16px;
  font-weight: 600;
  color: #333;
  margin: 12px 0 8px;
  padding: 0 4px;
}

.explore-tabs {
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

.explore-content {
  height: calc(100vh - 94px);
  overflow-y: auto;
  padding: 16px;
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
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

/* Skeleton */
.skeleton-card {
  pointer-events: none;
}

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

/* Load more */
.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}

/* FAB */
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

.fab:active {
  transform: scale(0.92);
}

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
