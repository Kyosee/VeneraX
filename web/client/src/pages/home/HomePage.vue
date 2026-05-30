<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, onActivated } from 'vue'
import { useRouter } from 'vue-router'
import ProxiedImage from '@/components/ProxiedImage.vue'
import { listHistory, getComicSources, listFavorites, clearComicSourcesCache } from '@/services/server-db'
import { getSyncStatus, type WebDavSyncStatus } from '@/services/sync'
import { useSyncStore } from '@/stores/sync'
import { useSettingsStore } from '@/stores/settings'
import type { History, ComicSource, FavoriteItem } from '@/types'
import { resolveSourceKey } from '@/utils/source'

const router = useRouter()
const syncStore = useSyncStore()
const settingsStore = useSettingsStore()
const histories = ref<History[]>([])
const historyTotal = ref(0)
const favorites = ref<FavoriteItem[]>([])
const localComics = ref<FavoriteItem[]>([])
const sources = ref<ComicSource[]>([])
const syncStatus = ref<WebDavSyncStatus>({
  isDownloading: false, isUploading: false, isEnabled: false, configured: false, autoSyncEnabled: false
})
const syncBusy = ref(false)

const followUpdateItems = computed(() => {
  const folder = settingsStore.settings.followUpdatesFolder
  if (!folder) return []
  const items = favorites.value.filter(item => item.folder === folder)
  return items.sort((a, b) => {
    const ta = a.lastUpdateTime ? new Date(a.lastUpdateTime).getTime() : 0
    const tb = b.lastUpdateTime ? new Date(b.lastUpdateTime).getTime() : 0
    return tb - ta
  })
})
const updateCount = computed(() => followUpdateItems.value.filter(item => item.hasNewUpdate).length)

async function refreshHomeData() {
  const [h, s, f, ss] = await Promise.allSettled([
    listHistory(20),
    getComicSources(),
    listFavorites(),
    getSyncStatus(),
  ])
  if (h.status === 'fulfilled') {
    histories.value = h.value.items
    historyTotal.value = h.value.total
  }
  if (s.status === 'fulfilled') sources.value = s.value
  if (f.status === 'fulfilled') {
    favorites.value = f.value
    localComics.value = f.value.filter(item => resolveSourceKey(item, sources.value) === 'local')
  }
  if (ss.status === 'fulfilled') syncStatus.value = ss.value
  syncStatus.value.isDownloading = syncStore.isDownloading
  syncStatus.value.isUploading = syncStore.isUploading
  syncStatus.value.lastError = syncStore.lastError || syncStatus.value.lastError
}

async function refreshSyncStatus() {
  syncStatus.value = await getSyncStatus()
  syncStatus.value.isDownloading = syncStore.isDownloading
  syncStatus.value.isUploading = syncStore.isUploading
  syncStatus.value.lastError = syncStore.lastError || syncStatus.value.lastError
}

let visibilityHandler: (() => void) | null = null
let activatedOnce = false

onMounted(async () => {
  await syncStore.bootstrapAutoDownload()
  await settingsStore.loadSettings()
  await refreshHomeData()
  activatedOnce = true

  visibilityHandler = () => {
    if (document.visibilityState === 'visible') refreshHomeData()
  }
  document.addEventListener('visibilitychange', visibilityHandler)
})

onActivated(() => {
  // Kept-alive: onActivated also fires right after the first onMounted, so skip
  // that one (onMounted already loaded). On later activations (e.g. returning
  // from a comic detail page after reading), refresh so the history list shows
  // the most recently read comic at the front.
  if (!activatedOnce) return
  void refreshHomeData()
})

onUnmounted(() => {
  if (visibilityHandler) {
    document.removeEventListener('visibilitychange', visibilityHandler)
  }
})

async function doSync() {
  if (syncBusy.value) return
  syncBusy.value = true
  try {
    await syncStore.download()
    clearComicSourcesCache()
    await refreshHomeData()
    await refreshSyncStatus()
  } catch (e: any) {
    try {
      await syncStore.upload()
      await refreshSyncStatus()
    } catch (e2: any) {
      syncStatus.value.lastError = e2.message
    }
  } finally { syncBusy.value = false }
}

function goComic(item: History) {
  const sourceKey = resolveSourceKey(item, sources.value)
  router.push(`/comic/${encodeURIComponent(sourceKey)}/${encodeURIComponent(item.id)}`)
}

function goFavoriteComic(item: FavoriteItem) {
  const sourceKey = resolveSourceKey(item, sources.value)
  router.push(`/comic/${encodeURIComponent(sourceKey)}/${encodeURIComponent(item.id)}`)
}

function goSources(sourceKey?: string) {
  if (sourceKey) {
    router.push(`/sources?highlight=${encodeURIComponent(sourceKey)}`)
  } else {
    router.push('/sources')
  }
}
</script>

<template>
  <div class="home-page">
    <!-- Search Bar -->
    <div class="search-bar" @click="router.push('/search')">
      <van-icon name="search" class="search-icon" />
      <span class="search-placeholder">搜索</span>
    </div>

    <!-- 同步数据 -->
    <div class="sync-bar" v-if="syncStatus.configured">
      <div class="sync-status">
        <van-icon name="exchange" class="sync-icon" />
        <span v-if="syncStatus.lastError" class="sync-text sync-error">{{ syncStatus.lastError }}</span>
        <span v-else-if="syncBusy" class="sync-text">同步中...</span>
        <span v-else class="sync-text">同步数据</span>
      </div>
      <div class="sync-actions">
        <button class="sync-btn" :disabled="syncBusy" @click="doSync" title="同步">
          <van-icon name="exchange" />
        </button>
      </div>
    </div>

    <!-- History Section -->
    <div class="section-card">
      <div class="section-header" @click="router.push('/history')">
        <div class="section-header-left">
          <span class="section-title">历史</span>
          <span class="count-badge">{{ historyTotal }}</span>
        </div>
        <van-icon name="arrow" class="section-arrow" />
      </div>
      <div class="cover-scroll" v-if="histories.length">
        <div
          v-for="item in histories"
          :key="item.id"
          class="cover-item"
          @click="goComic(item)"
        >
          <ProxiedImage class="cover-img" :src="item.cover" :alt="item.title" />
        </div>
      </div>
      <div v-else class="empty-hint">暂无历史记录</div>
    </div>

    <!-- Local Comics Section -->
    <div class="section-card" v-if="localComics.length">
      <div class="section-header" @click="router.push('/favorites')">
        <div class="section-header-left">
          <span class="section-title">本地漫画</span>
          <span class="count-badge">{{ localComics.length }}</span>
        </div>
        <van-icon name="arrow" class="section-arrow" />
      </div>
      <div class="cover-scroll">
        <div
          v-for="item in localComics"
          :key="item.id"
          class="cover-item"
          @click="goFavoriteComic(item)"
        >
          <ProxiedImage class="cover-img" :src="item.coverPath" :alt="item.name" />
        </div>
      </div>
    </div>

    <!-- Follow Updates Section -->
    <div class="section-card">
      <div class="section-header" @click="router.push('/follow-updates')">
        <div class="section-header-left">
          <span class="section-title">追更</span>
          <span class="count-badge">{{ updateCount }}</span>
          <span class="update-info" v-if="updateCount > 0">{{ updateCount }} 项更新</span>
        </div>
        <van-icon name="arrow" class="section-arrow" />
      </div>
      <div class="cover-scroll" v-if="followUpdateItems.length">
        <div
          v-for="item in followUpdateItems"
          :key="item.id"
          class="cover-item"
          @click="goFavoriteComic(item)"
        >
          <div class="cover-item-wrap">
            <ProxiedImage class="cover-img" :src="item.coverPath" :alt="item.name" />
            <span v-if="item.hasNewUpdate" class="update-dot"></span>
          </div>
        </div>
      </div>
      <div v-else class="empty-hint">暂无追更</div>
    </div>

    <!-- Comic Sources Section -->
    <div class="section-card">
      <div class="section-header" @click="goSources()">
        <div class="section-header-left">
          <span class="section-title">漫画源</span>
          <span class="count-badge">{{ sources.length }}</span>
        </div>
        <van-icon name="arrow" class="section-arrow" />
      </div>
      <div class="sources-wrap" v-if="sources.length">
        <span v-for="s in sources" :key="s.key" class="source-chip" @click.stop="goSources(s.key)">{{ s.name }}</span>
      </div>
      <div v-else class="empty-hint">暂无漫画源</div>
    </div>

    <!-- Image Favorites Section -->
    <div class="section-card">
      <div class="section-header" @click="router.push('/image-favorites')">
        <div class="section-header-left">
          <span class="section-title">图片收藏</span>
        </div>
        <van-icon name="arrow" class="section-arrow" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.home-page {
  padding-bottom: 16px;
  overflow-y: auto;
}

.search-bar {
  display: flex;
  align-items: center;
  height: 52px;
  margin: 8px;
  padding: 0 16px;
  background: #f5f5f5;
  border-radius: 32px;
  cursor: pointer;
}

.search-icon {
  font-size: 18px;
  color: #999;
  margin-right: 8px;
}

.search-placeholder {
  font-size: 15px;
  color: #999;
  flex: 1;
}

/* Sync Bar */
.sync-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 0 8px 4px;
  padding: 8px 12px;
  background: #f0f3ff;
  border-radius: 8px;
}

.sync-status {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  flex: 1;
}

.sync-icon {
  font-size: 16px;
  color: #4f6ef7;
  flex-shrink: 0;
}

.sync-text {
  font-size: 13px;
  color: #666;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sync-error {
  color: #e74c3c;
}

.sync-actions {
  display: flex;
  gap: 8px;
  flex-shrink: 0;
}

.sync-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  border: none;
  border-radius: 50%;
  background: #4f6ef7;
  color: #fff;
  font-size: 16px;
  cursor: pointer;
  transition: opacity 0.2s;
}

.sync-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.sync-btn:active:not(:disabled) {
  opacity: 0.7;
}

/* Section Cards */
.section-card {
  margin: 8px;
  border: 0.6px solid #e0e0e0;
  border-radius: 8px;
  overflow: hidden;
}

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 56px;
  padding: 0 12px;
  cursor: pointer;
}

.section-header-left {
  display: flex;
  align-items: center;
  gap: 8px;
}

.section-title {
  font-size: 18px;
  font-weight: 500;
}

.count-badge {
  background: #e8eaf6;
  color: #4f6ef7;
  border-radius: 8px;
  padding: 2px 8px;
  font-size: 13px;
  font-weight: 500;
}

.update-info {
  font-size: 12px;
  color: #e74c3c;
  font-weight: 500;
}

.section-arrow {
  font-size: 16px;
  color: #999;
}

.cover-scroll {
  display: flex;
  overflow-x: auto;
  padding: 0 8px 16px;
  gap: 16px;
  height: 154px;
  -webkit-overflow-scrolling: touch;
  will-change: scroll-position;
  transform: translateZ(0);
  scroll-behavior: smooth;
}

.cover-scroll::-webkit-scrollbar {
  display: none;
}

.cover-item {
  flex-shrink: 0;
  width: 98px;
  cursor: pointer;
  transform: translateZ(0);
}

.cover-item-wrap {
  position: relative;
  display: inline-block;
  transform: translateZ(0);
}

.cover-img {
  width: 98px;
  height: 136px;
  object-fit: cover;
  border-radius: 8px;
  background: #f0f0f0;
  content-visibility: auto;
  contain-intrinsic-size: 98px 136px;
  transform: translateZ(0);
}

.update-dot {
  position: absolute;
  top: 4px;
  right: 4px;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #e74c3c;
  border: 1.5px solid #fff;
}

.sources-wrap {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 0 12px 12px;
}

.source-chip {
  background: #e8eaf6;
  color: #4f6ef7;
  border-radius: 8px;
  padding: 2px 8px;
  font-size: 13px;
  font-weight: 500;
}

.empty-hint {
  padding: 12px;
  font-size: 13px;
  color: #999;
}

@media (min-width: 768px) {
  .search-bar {
    height: 46px;
  }
}
</style>
