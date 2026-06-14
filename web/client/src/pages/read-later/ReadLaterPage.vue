<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { getComicSources } from '@/services/server-db'
import { showToast, showConfirmDialog } from 'vant'
import type { ReadLaterItem, ComicSource } from '@/types'
import { resolveSourceKey } from '@/utils/source'
import ComicCard from '@/components/ComicCard.vue'
import { useSettingsStore } from '@/stores/settings'
import { useReadLaterStore } from '@/stores/readLater'

const router = useRouter()
const settingsStore = useSettingsStore()
const readLaterStore = useReadLaterStore()
const sources = ref<ComicSource[]>([])
const loading = ref(true)
const searchQuery = ref('')
const sortAsc = ref(false)
const viewMode = ref<'detailed' | 'brief'>(settingsStore.settings.thumbnailMode === 'brief' ? 'brief' : 'detailed')
const isDesktop = ref(window.innerWidth >= 720)
const multiSelectMode = ref(false)
const selectedIds = ref<Set<string>>(new Set())
const showContextMenu = ref(false)
const contextMenuItem = ref<ReadLaterItem | null>(null)
const undoTimer = ref<ReturnType<typeof setTimeout> | null>(null)
const undoItems = ref<ReadLaterItem[]>([])
const showUndoToast = ref(false)
const undoMessage = ref('')
let longPressTimer: ReturnType<typeof setTimeout> | null = null
let longPressTriggered = false

const items = computed(() => readLaterStore.items)

function handleResize() { isDesktop.value = window.innerWidth >= 720 }

const gridStyle = computed(() => {
  const scale = Number(settingsStore.settings.thumbnailSize || 1)
  return viewMode.value === 'brief'
    ? {
        '--tile-scale': String(scale),
        gridTemplateColumns: `repeat(auto-fill, minmax(96px, ${Math.round(192 * scale)}px))`,
      }
    : {
        '--tile-scale': String(scale),
        gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 360px), 1fr))',
      }
})

onMounted(async () => {
  window.addEventListener('resize', handleResize)
  document.addEventListener('visibilitychange', onVisibilityChange)
  await settingsStore.loadSettings()
  viewMode.value = settingsStore.settings.thumbnailMode === 'brief' ? 'brief' : 'detailed'
  await loadData()
})

onUnmounted(() => {
  window.removeEventListener('resize', handleResize)
  document.removeEventListener('visibilitychange', onVisibilityChange)
  if (undoTimer.value) clearTimeout(undoTimer.value)
})

function onVisibilityChange() {
  if (document.visibilityState === 'visible') loadData()
}

async function loadData() {
  loading.value = true
  try {
    const [, s] = await Promise.all([readLaterStore.fetch(), getComicSources()])
    sources.value = s
  } catch (e) {
    console.error('Failed to load read later:', e)
  } finally {
    loading.value = false
  }
}

function itemSourceKey(item: ReadLaterItem): string {
  return item.sourceKey || resolveSourceKey(item, sources.value)
}

function getSourceName(item: ReadLaterItem): string {
  const key = itemSourceKey(item)
  const source = sources.value.find(x => String(x.key) === key)
  return source?.name ?? `Source ${key}`
}

function itemKey(item: ReadLaterItem): string {
  return `${item.id}::${item.type}`
}

const filteredItems = computed(() => {
  let list = [...items.value]
  if (searchQuery.value.trim()) {
    const q = searchQuery.value.trim().toLowerCase()
    list = list.filter(item =>
      item.title.toLowerCase().includes(q) ||
      (item.subtitle && item.subtitle.toLowerCase().includes(q))
    )
  }
  list.sort((a, b) => sortAsc.value ? a.time - b.time : b.time - a.time)
  return list
})

function goComic(item: ReadLaterItem) {
  if (multiSelectMode.value) { toggleSelect(item); return }
  router.push(`/comic/${encodeURIComponent(itemSourceKey(item))}/${encodeURIComponent(item.id)}`)
}

function toggleSort() { sortAsc.value = !sortAsc.value }
function toggleViewMode() { viewMode.value = viewMode.value === 'detailed' ? 'brief' : 'detailed' }

function toggleMultiSelect() {
  multiSelectMode.value = !multiSelectMode.value
  if (!multiSelectMode.value) selectedIds.value.clear()
}

function toggleSelect(item: ReadLaterItem) {
  const key = itemKey(item)
  if (selectedIds.value.has(key)) { selectedIds.value.delete(key) }
  else { selectedIds.value.add(key) }
  selectedIds.value = new Set(selectedIds.value)
}

function isSelected(item: ReadLaterItem): boolean {
  return selectedIds.value.has(itemKey(item))
}

function selectAll() {
  filteredItems.value.forEach(item => selectedIds.value.add(itemKey(item)))
  selectedIds.value = new Set(selectedIds.value)
}

async function batchDelete() {
  if (selectedIds.value.size === 0) return
  const count = selectedIds.value.size
  try {
    await showConfirmDialog({ title: '批量移除', message: `确定移除选中的 ${count} 项？` })
  } catch { return }
  const toDelete = items.value.filter(i => selectedIds.value.has(itemKey(i)))
  undoItems.value = toDelete
  selectedIds.value.clear()
  multiSelectMode.value = false
  try {
    await readLaterStore.batchDelete(toDelete.map(i => ({ id: i.id, type: i.type })))
  } catch (e) { console.error(e) }
  showUndoNotification(`已移除 ${count} 项`)
}

function onCardContextMenu(e: MouseEvent, item: ReadLaterItem) {
  e.preventDefault()
  if (multiSelectMode.value) return
  contextMenuItem.value = item
  showContextMenu.value = true
}

function onCardTouchStart(item: ReadLaterItem) {
  if (multiSelectMode.value) return
  longPressTriggered = false
  longPressTimer = setTimeout(() => {
    longPressTriggered = true
    contextMenuItem.value = item
    showContextMenu.value = true
  }, 600)
}

function onCardTouchEnd() {
  if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null }
}

function onCardClick(item: ReadLaterItem) {
  if (longPressTriggered) { longPressTriggered = false; return }
  goComic(item)
}

async function deleteSingleItem() {
  if (!contextMenuItem.value) return
  const item = contextMenuItem.value
  showContextMenu.value = false
  undoItems.value = [item]
  try { await readLaterStore.remove(item.id, item.type) } catch (e) { console.error(e) }
  showUndoNotification(`已移除「${item.title}」`)
}

async function onClearAll() {
  try {
    await showConfirmDialog({ title: '清空稍后阅读', message: '确定清空所有稍后阅读？此操作不可撤销。' })
  } catch { return }
  try {
    await readLaterStore.clearAll()
    showToast('已清空稍后阅读')
  } catch (e) {
    console.error(e)
    showToast('清空失败')
  }
}

function showUndoNotification(msg: string) {
  undoMessage.value = msg
  showUndoToast.value = true
  if (undoTimer.value) clearTimeout(undoTimer.value)
  undoTimer.value = setTimeout(() => { showUndoToast.value = false; undoItems.value = [] }, 5000)
}

async function undoDelete() {
  showUndoToast.value = false
  if (undoTimer.value) { clearTimeout(undoTimer.value); undoTimer.value = null }
  for (const item of undoItems.value) {
    try { await readLaterStore.add(item) } catch (e) { console.error(e) }
  }
  undoItems.value = []
  await loadData()
}
</script>

<template>
  <div class="read-later-page">
    <!-- Top bar -->
    <div class="top-bar">
      <div class="top-bar-left">
        <van-icon name="arrow-left" size="20" class="back-btn" @click="router.back()" />
        <span class="page-title">{{ multiSelectMode ? `已选 ${selectedIds.size}` : '稍后阅读' }}</span>
      </div>
      <div class="top-bar-right" v-if="!multiSelectMode">
        <van-icon name="replay" size="20" class="action-icon" @click="loadData" />
        <van-icon :name="sortAsc ? 'ascending' : 'descending'" size="20" class="action-icon" @click="toggleSort" />
        <van-icon :name="viewMode === 'detailed' ? 'bars' : 'apps-o'" size="20" class="action-icon" @click="toggleViewMode" />
        <van-icon name="certificate" size="20" class="action-icon" @click="toggleMultiSelect" />
        <van-icon name="delete-o" size="20" class="action-icon" @click="onClearAll" />
      </div>
      <div class="top-bar-right" v-else>
        <span class="text-btn" @click="selectAll">全选</span>
        <span class="text-btn danger" @click="batchDelete">移除</span>
        <span class="text-btn" @click="toggleMultiSelect">取消</span>
      </div>
    </div>

    <!-- Search bar -->
    <div class="search-wrap">
      <van-search v-model="searchQuery" placeholder="搜索" shape="round" :show-action="false" />
    </div>

    <!-- Content -->
    <div class="content-area">
      <div v-if="loading" class="loading-state">
        <van-loading size="32" />
      </div>
      <div v-else-if="!filteredItems.length" class="empty-state">
        <van-empty description="暂无稍后阅读" />
      </div>
      <div v-else class="read-later-grid" :style="gridStyle">
        <div
          v-for="item in filteredItems"
          :key="itemKey(item)"
          class="read-later-card-wrap"
          :class="{ selected: isSelected(item) }"
          @click.stop="onCardClick(item)"
          @contextmenu="onCardContextMenu($event, item)"
          @touchstart.passive="onCardTouchStart(item)"
          @touchend="onCardTouchEnd()"
          @touchcancel="onCardTouchEnd()"
        >
          <van-checkbox
            v-if="multiSelectMode"
            :model-value="isSelected(item)"
            class="card-checkbox"
            @click.stop="toggleSelect(item)"
          />
          <ComicCard
            :comic="item"
            :source-key="itemSourceKey(item)"
            :source-name="getSourceName(item)"
          />
        </div>
      </div>
    </div>

    <!-- Context menu (action sheet) -->
    <van-action-sheet
      v-model:show="showContextMenu"
      :actions="[{ name: '移除', color: '#ee0a24' }]"
      cancel-text="取消"
      @select="deleteSingleItem"
      @cancel="showContextMenu = false"
    />

    <!-- Undo toast -->
    <transition name="slide-up">
      <div v-if="showUndoToast" class="undo-toast">
        <span class="undo-msg">{{ undoMessage }}</span>
        <span class="undo-btn" @click="undoDelete">撤销</span>
      </div>
    </transition>
  </div>
</template>

<style scoped>
.read-later-page {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #f5f5f5;
}

.top-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 48px;
  padding: 0 16px;
  background: #fff;
  border-bottom: 0.5px solid #e8e8e8;
}

.top-bar-left {
  display: flex;
  align-items: center;
  gap: 12px;
}

.back-btn { cursor: pointer; }

.page-title {
  font-size: 17px;
  font-weight: 600;
  color: #333;
}

.top-bar-right {
  display: flex;
  align-items: center;
  gap: 16px;
}

.action-icon {
  cursor: pointer;
  color: #666;
  transition: color 0.2s;
}

.action-icon:hover,
.action-icon.active {
  color: #4f6ef7;
}

.text-btn {
  font-size: 14px;
  color: #4f6ef7;
  cursor: pointer;
  user-select: none;
}

.text-btn.danger {
  color: #ee0a24;
}

.search-wrap {
  background: #fff;
  padding: 0 4px 8px;
}

.content-area {
  flex: 1;
  overflow-y: auto;
  padding: 8px 16px 16px;
  padding-bottom: calc(16px + 50px + env(safe-area-inset-bottom, 0px));
  will-change: scroll-position;
  transform: translateZ(0);
}

.loading-state,
.empty-state {
  display: flex;
  justify-content: center;
  padding: 60px 0;
}

.read-later-grid {
  display: grid;
  gap: 12px;
}

.read-later-card-wrap {
  position: relative;
  cursor: pointer;
  border-radius: 8px;
  transition: transform 0.15s;
  content-visibility: auto;
  contain-intrinsic-size: auto 300px;
}

.read-later-card-wrap:hover {
  transform: translateY(-1px);
}

.read-later-card-wrap.selected {
  outline: 2px solid #4f6ef7;
  outline-offset: -2px;
  border-radius: 8px;
}

.card-checkbox {
  position: absolute;
  top: 6px;
  right: 6px;
  z-index: 2;
}

.undo-toast {
  position: fixed;
  bottom: 80px;
  left: 50%;
  transform: translateX(-50%);
  background: #333;
  color: #fff;
  padding: 12px 20px;
  border-radius: 24px;
  display: flex;
  align-items: center;
  gap: 16px;
  z-index: 9999;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
}

.undo-msg { font-size: 14px; }

.undo-btn {
  font-size: 14px;
  color: #4f6ef7;
  font-weight: 600;
  cursor: pointer;
}

.slide-up-enter-active,
.slide-up-leave-active {
  transition: all 0.3s ease;
}

.slide-up-enter-from,
.slide-up-leave-to {
  opacity: 0;
  transform: translateX(-50%) translateY(20px);
}

:deep(.van-search) {
  padding: 4px 12px;
}

:deep(.van-search__content) {
  background: #f5f5f5;
}
</style>
