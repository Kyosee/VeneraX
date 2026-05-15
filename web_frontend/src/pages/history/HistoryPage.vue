<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { listHistory, getComicSources, deleteHistory, clearHistory } from '@/services/server-db'
import { imageProxyUrl } from '@/services/api'
import { showToast, showConfirmDialog } from 'vant'
import type { History, ComicSource } from '@/types'
import { resolveSourceKey } from '@/utils/source'

const router = useRouter()
const items = ref<History[]>([])
const sources = ref<ComicSource[]>([])
const loading = ref(true)
const searchQuery = ref('')
const sortAsc = ref(false)
const viewMode = ref<'detailed' | 'brief'>('detailed')
const isDesktop = ref(window.innerWidth >= 720)
const multiSelectMode = ref(false)
const selectedIds = ref<Set<string>>(new Set())
const showSourceFilter = ref(false)
const selectedSources = ref<Set<string>>(new Set())
const readingStatusFilter = ref<'all' | 'uncompleted' | 'completed'>('all')
const showContextMenu = ref(false)
const contextMenuItem = ref<History | null>(null)
const undoTimer = ref<ReturnType<typeof setTimeout> | null>(null)
const undoItems = ref<History[]>([])
const showUndoToast = ref(false)
const undoMessage = ref('')
let longPressTimer: ReturnType<typeof setTimeout> | null = null
let longPressTriggered = false

function handleResize() { isDesktop.value = window.innerWidth >= 720 }

onMounted(async () => {
  window.addEventListener('resize', handleResize)
  await loadData()
})

onUnmounted(() => {
  window.removeEventListener('resize', handleResize)
  if (undoTimer.value) clearTimeout(undoTimer.value)
})

async function loadData() {
  loading.value = true
  try {
    const [h, s] = await Promise.all([listHistory(), getComicSources()])
    items.value = h.items
    sources.value = s
  } catch (e) {
    console.error('Failed to load history:', e)
  } finally {
    loading.value = false
  }
}

function itemSourceKey(item: History): string {
  return resolveSourceKey(item, sources.value)
}

function getSourceName(item: History): string {
  const key = itemSourceKey(item)
  const source = sources.value.find(x => String(x.key) === key)
  return source?.name ?? `Source ${key}`
}

function itemKey(item: History): string {
  return `${item.id}::${itemSourceKey(item)}`
}

function parseReadEpisode(raw: History['readEpisode']): string[] {
  if (Array.isArray(raw)) return raw.map(String).filter(Boolean)
  if (!raw) return []
  const text = String(raw).trim()
  if (!text) return []
  try {
    const a = JSON.parse(text)
    if (Array.isArray(a)) return a.map(String)
  } catch {}
  return text.split(',').map(s => s.trim()).filter(Boolean)
}

function getReadChapterCount(item: History): number {
  return Math.floor(parseReadEpisode(item.readEpisode).length / 3)
}

function isCompleted(item: History): boolean {
  if (!item.maxPage) return false
  return item.page >= item.maxPage
}

const availableSources = computed(() => {
  const sourceItems = new Map<string, History>()
  for (const item of items.value) {
    const key = itemSourceKey(item)
    if (!sourceItems.has(key)) sourceItems.set(key, item)
  }
  return Array.from(sourceItems.entries()).map(([key, item]) => ({ key, name: getSourceName(item) }))
})

const hasActiveFilters = computed(() => {
  return selectedSources.value.size > 0 || readingStatusFilter.value !== 'all'
})

const filteredItems = computed(() => {
  let list = [...items.value]
  if (searchQuery.value.trim()) {
    const q = searchQuery.value.trim().toLowerCase()
    list = list.filter(item =>
      item.title.toLowerCase().includes(q) ||
      (item.subtitle && item.subtitle.toLowerCase().includes(q))
    )
  }
  if (selectedSources.value.size > 0) {
    list = list.filter(item => selectedSources.value.has(itemSourceKey(item)))
  }
  if (readingStatusFilter.value === 'completed') {
    list = list.filter(item => isCompleted(item))
  } else if (readingStatusFilter.value === 'uncompleted') {
    list = list.filter(item => !isCompleted(item))
  }
  list.sort((a, b) => sortAsc.value ? a.time - b.time : b.time - a.time)
  return list
})

function isThisWeek(ts: number): boolean {
  const now = new Date()
  const date = new Date(ts)
  const startOfWeek = new Date(now)
  startOfWeek.setDate(now.getDate() - now.getDay())
  startOfWeek.setHours(0, 0, 0, 0)
  return date >= startOfWeek
}

const thisWeekItems = computed(() => filteredItems.value.filter(i => isThisWeek(i.time)))
const earlierItems = computed(() => filteredItems.value.filter(i => !isThisWeek(i.time)))

function formatDate(ts: number): string {
  const d = new Date(ts)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function goComic(item: History) {
  if (multiSelectMode.value) { toggleSelect(item); return }
  router.push(`/comic/${encodeURIComponent(itemSourceKey(item))}/${encodeURIComponent(item.id)}`)
}

function toggleSort() { sortAsc.value = !sortAsc.value }
function toggleViewMode() { viewMode.value = viewMode.value === 'detailed' ? 'brief' : 'detailed' }

// Multi-select
function toggleMultiSelect() {
  multiSelectMode.value = !multiSelectMode.value
  if (!multiSelectMode.value) selectedIds.value.clear()
}

function toggleSelect(item: History) {
  const key = itemKey(item)
  if (selectedIds.value.has(key)) { selectedIds.value.delete(key) }
  else { selectedIds.value.add(key) }
  selectedIds.value = new Set(selectedIds.value)
}

function isSelected(item: History): boolean {
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
    await showConfirmDialog({ title: '批量删除', message: `确定删除选中的 ${count} 条记录？` })
  } catch { return }

  const toDelete = items.value.filter(i => selectedIds.value.has(itemKey(i)))
  undoItems.value = toDelete
  items.value = items.value.filter(i => !selectedIds.value.has(itemKey(i)))
  selectedIds.value.clear()
  multiSelectMode.value = false

  for (const item of toDelete) {
    try { await deleteHistory(item.id, item.type) } catch (e) { console.error(e) }
  }
  showUndoNotification(`已删除 ${count} 条记录`)
}

// Context menu
function onCardContextMenu(e: MouseEvent, item: History) {
  e.preventDefault()
  if (multiSelectMode.value) return
  contextMenuItem.value = item
  showContextMenu.value = true
}

function onCardTouchStart(item: History) {
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

function onCardClick(item: History) {
  if (longPressTriggered) { longPressTriggered = false; return }
  goComic(item)
}

async function deleteSingleItem() {
  if (!contextMenuItem.value) return
  const item = contextMenuItem.value
  showContextMenu.value = false
  undoItems.value = [item]
  items.value = items.value.filter(i => itemKey(i) !== itemKey(item))
  try { await deleteHistory(item.id, item.type) } catch (e) { console.error(e) }
  showUndoNotification(`已删除「${item.title}」`)
}

// Clear all
async function onClearHistory() {
  try {
    await showConfirmDialog({ title: '清空历史', message: '确定清空所有历史记录？此操作不可撤销。' })
  } catch { return }
  const backup = [...items.value]
  items.value = []
  try {
    await clearHistory()
    showToast('已清空历史记录')
  } catch (e) {
    console.error(e)
    items.value = backup
    showToast('清空失败')
  }
}

// Undo
function showUndoNotification(msg: string) {
  undoMessage.value = msg
  showUndoToast.value = true
  if (undoTimer.value) clearTimeout(undoTimer.value)
  undoTimer.value = setTimeout(() => { showUndoToast.value = false; undoItems.value = [] }, 5000)
}

async function undoDelete() {
  showUndoToast.value = false
  if (undoTimer.value) { clearTimeout(undoTimer.value); undoTimer.value = null }
  items.value = [...undoItems.value, ...items.value]
  undoItems.value = []
  await loadData()
}

// Source filter
function toggleSourceSelection(key: string) {
  if (selectedSources.value.has(key)) { selectedSources.value.delete(key) }
  else { selectedSources.value.add(key) }
  selectedSources.value = new Set(selectedSources.value)
}

function clearSourceFilter() {
  selectedSources.value.clear()
  selectedSources.value = new Set(selectedSources.value)
}

function setStatusFilter(status: 'all' | 'uncompleted' | 'completed') {
  readingStatusFilter.value = status
}
</script>

<template>
  <div class="history-page">
    <!-- Top bar -->
    <div class="top-bar">
      <div class="top-bar-left">
        <van-icon name="arrow-left" size="20" class="back-btn" @click="router.back()" />
        <span class="page-title">{{ multiSelectMode ? `已选 ${selectedIds.size}` : '历史' }}</span>
      </div>
      <div class="top-bar-right" v-if="!multiSelectMode">
        <van-icon name="replay" size="20" class="action-icon" @click="loadData" />
        <van-icon :name="sortAsc ? 'ascending' : 'descending'" size="20" class="action-icon" @click="toggleSort" />
        <van-icon :name="viewMode === 'detailed' ? 'bars' : 'apps-o'" size="20" class="action-icon" @click="toggleViewMode" />
        <van-icon name="filter-o" size="20" class="action-icon" :class="{ active: hasActiveFilters }" @click="showSourceFilter = true" />
        <van-icon name="certificate" size="20" class="action-icon" @click="toggleMultiSelect" />
        <van-icon name="delete-o" size="20" class="action-icon" @click="onClearHistory" />
      </div>
      <div class="top-bar-right" v-else>
        <span class="text-btn" @click="selectAll">全选</span>
        <span class="text-btn danger" @click="batchDelete">删除</span>
        <span class="text-btn" @click="toggleMultiSelect">取消</span>
      </div>
    </div>

    <!-- Search bar -->
    <div class="search-wrap">
      <van-search v-model="searchQuery" placeholder="搜索" shape="round" :show-action="false" />
    </div>

    <!-- Status filter tabs -->
    <div class="status-tabs">
      <span class="status-tab" :class="{ active: readingStatusFilter === 'all' }" @click="setStatusFilter('all')">全部</span>
      <span class="status-tab" :class="{ active: readingStatusFilter === 'uncompleted' }" @click="setStatusFilter('uncompleted')">未读完</span>
      <span class="status-tab" :class="{ active: readingStatusFilter === 'completed' }" @click="setStatusFilter('completed')">已读完</span>
    </div>

    <!-- Content -->
    <div class="content-area">
      <div v-if="loading" class="loading-state">
        <van-loading size="32" />
      </div>
      <div v-else-if="!filteredItems.length" class="empty-state">
        <van-empty description="暂无历史记录" />
      </div>
      <div v-else class="history-content">
        <!-- This week section -->
        <template v-if="thisWeekItems.length">
          <div class="section-header">本周</div>
          <div class="history-grid" :class="{ brief: viewMode === 'brief' }">
            <div
              v-for="item in thisWeekItems"
              :key="`${itemKey(item)}-w`"
              class="history-card"
              :class="{ 'card-brief': viewMode === 'brief', selected: isSelected(item) }"
              @click="onCardClick(item)"
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
              <div class="card-cover">
                <img v-if="item.cover" :src="imageProxyUrl(item.cover)" loading="lazy" />
                <div v-else class="cover-placeholder">
                  <van-icon name="photo-o" size="28" color="#ccc" />
                </div>
                <div v-if="getReadChapterCount(item) > 0" class="badge-chapter">
                  {{ getReadChapterCount(item) }}
                </div>
              </div>
              <div class="card-info" v-if="viewMode === 'detailed'">
                <div class="info-title">{{ item.title || item.id }}</div>
                <div v-if="item.subtitle" class="info-row">
                  <span class="info-label">作者:</span>
                  <span class="info-value">{{ item.subtitle }}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">更新:</span>
                  <span class="info-value">{{ formatDate(item.time) }}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">来源:</span>
                  <span class="info-value source-tag">{{ getSourceName(item) }}</span>
                </div>
                <div v-if="item.maxPage" class="info-row">
                  <span class="info-label">页数:</span>
                  <span class="info-value">{{ item.page }}/{{ item.maxPage }}</span>
                </div>
              </div>
              <div class="card-info-brief" v-else>
                <div class="info-title">{{ item.title || item.id }}</div>
              </div>
            </div>
          </div>
        </template>

        <!-- Earlier section -->
        <template v-if="earlierItems.length">
          <div class="section-header">更早</div>
          <div class="history-grid" :class="{ brief: viewMode === 'brief' }">
            <div
              v-for="item in earlierItems"
              :key="`${itemKey(item)}-e`"
              class="history-card"
              :class="{ 'card-brief': viewMode === 'brief', selected: isSelected(item) }"
              @click="onCardClick(item)"
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
              <div class="card-cover">
                <img v-if="item.cover" :src="imageProxyUrl(item.cover)" loading="lazy" />
                <div v-else class="cover-placeholder">
                  <van-icon name="photo-o" size="28" color="#ccc" />
                </div>
                <div v-if="getReadChapterCount(item) > 0" class="badge-chapter">
                  {{ getReadChapterCount(item) }}
                </div>
              </div>
              <div class="card-info" v-if="viewMode === 'detailed'">
                <div class="info-title">{{ item.title || item.id }}</div>
                <div v-if="item.subtitle" class="info-row">
                  <span class="info-label">作者:</span>
                  <span class="info-value">{{ item.subtitle }}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">更新:</span>
                  <span class="info-value">{{ formatDate(item.time) }}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">来源:</span>
                  <span class="info-value source-tag">{{ getSourceName(item) }}</span>
                </div>
                <div v-if="item.maxPage" class="info-row">
                  <span class="info-label">页数:</span>
                  <span class="info-value">{{ item.page }}/{{ item.maxPage }}</span>
                </div>
              </div>
              <div class="card-info-brief" v-else>
                <div class="info-title">{{ item.title || item.id }}</div>
              </div>
            </div>
          </div>
        </template>
      </div>
    </div>

    <!-- Context menu (action sheet) -->
    <van-action-sheet
      v-model:show="showContextMenu"
      :actions="[{ name: '删除', color: '#ee0a24' }]"
      cancel-text="取消"
      @select="deleteSingleItem"
      @cancel="showContextMenu = false"
    />

    <!-- Source filter popup -->
    <van-popup v-model:show="showSourceFilter" position="bottom" round :style="{ maxHeight: '60%' }">
      <div class="filter-popup">
        <div class="filter-header">
          <span class="filter-title">按来源筛选</span>
          <span class="filter-clear" @click="clearSourceFilter">清除</span>
        </div>
        <div class="filter-list">
          <div
            v-for="src in availableSources"
            :key="src.key"
            class="filter-item"
            @click="toggleSourceSelection(src.key)"
          >
            <van-checkbox :model-value="selectedSources.has(src.key)" />
            <span class="filter-item-name">{{ src.name }}</span>
          </div>
          <div v-if="!availableSources.length" class="filter-empty">暂无来源</div>
        </div>
        <div class="filter-footer">
          <van-button type="primary" block round size="small" @click="showSourceFilter = false">确定</van-button>
        </div>
      </div>
    </van-popup>

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
.history-page {
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

.status-tabs {
  display: flex;
  gap: 0;
  background: #fff;
  padding: 0 16px 10px;
  border-bottom: 0.5px solid #e8e8e8;
}

.status-tab {
  flex: 1;
  text-align: center;
  padding: 6px 0;
  font-size: 13px;
  color: #666;
  cursor: pointer;
  border-radius: 16px;
  transition: all 0.2s;
}

.status-tab.active {
  background: #4f6ef7;
  color: #fff;
  font-weight: 500;
}

.content-area {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px 16px;
}

.loading-state,
.empty-state {
  display: flex;
  justify-content: center;
  padding: 60px 0;
}

.history-content {
  padding-top: 8px;
}

.section-header {
  font-size: 16px;
  font-weight: 500;
  color: #333;
  margin: 16px 0 12px;
}

.section-header:first-child {
  margin-top: 8px;
}

.history-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
}

.history-grid.brief {
  grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
}

@media (min-width: 720px) {
  .history-grid {
    grid-template-columns: repeat(3, 1fr);
  }
}

@media (max-width: 480px) {
  .history-grid {
    grid-template-columns: 1fr;
  }
}

.history-card {
  position: relative;
  display: flex;
  flex-direction: row;
  background: #fff;
  border-radius: 8px;
  overflow: hidden;
  cursor: pointer;
  transition: transform 0.15s, box-shadow 0.15s;
}

.history-card:hover {
  transform: translateY(-1px);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
}

.history-card.selected {
  outline: 2px solid #4f6ef7;
  outline-offset: -2px;
}

.history-card.card-brief {
  flex-direction: column;
}

.card-checkbox {
  position: absolute;
  top: 6px;
  right: 6px;
  z-index: 2;
}

.card-cover {
  position: relative;
  width: 100px;
  min-width: 100px;
  aspect-ratio: 0.7;
  flex-shrink: 0;
  background: #f0f0f0;
  border-radius: 4px;
  overflow: hidden;
}

.card-brief .card-cover {
  width: 100%;
  min-width: unset;
  aspect-ratio: 0.64;
}

.card-cover img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.cover-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f5f5f5;
}

.badge-chapter {
  position: absolute;
  top: 6px;
  left: 6px;
  background: #4f6ef7;
  color: #fff;
  font-size: 11px;
  min-width: 18px;
  height: 18px;
  line-height: 18px;
  text-align: center;
  border-radius: 9px;
  padding: 0 4px;
}

.card-info {
  flex: 1;
  padding: 10px 12px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  overflow: hidden;
}

.card-info-brief {
  padding: 6px 0;
}

.info-title {
  font-size: 15px;
  font-weight: 600;
  color: #333;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.info-row {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 13px;
  line-height: 1.6;
}

.info-label {
  color: #999;
  flex-shrink: 0;
}

.info-value {
  color: #333;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.source-tag {
  color: #4f6ef7;
}

/* Filter popup */
.filter-popup {
  padding: 16px;
}

.filter-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 16px;
}

.filter-title {
  font-size: 16px;
  font-weight: 600;
  color: #333;
}

.filter-clear {
  font-size: 14px;
  color: #4f6ef7;
  cursor: pointer;
}

.filter-list {
  max-height: 300px;
  overflow-y: auto;
}

.filter-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 0.5px solid #f0f0f0;
  cursor: pointer;
}

.filter-item-name {
  font-size: 14px;
  color: #333;
}

.filter-empty {
  text-align: center;
  padding: 24px;
  color: #999;
  font-size: 14px;
}

.filter-footer {
  margin-top: 16px;
}

/* Undo toast */
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

.undo-msg {
  font-size: 14px;
}

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
