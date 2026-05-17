<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  listFolders, listFavorites, getComicSources, listHistory,
  createFolder, deleteFolder, renameFolder, reorderFolders,
  batchDeleteFavorites, batchMoveFavorites
} from '@/services/server-db'
import type { FavoriteItem, FavoriteFolder, ComicSource, History } from '@/types'
import { showDialog, showConfirmDialog, showToast } from 'vant'
import { resolveSourceKey } from '@/utils/source'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'

const router = useRouter()
const settingsStore = useSettingsStore()
const folders = ref<FavoriteFolder[]>([])
const sources = ref<ComicSource[]>([])
const favorites = ref<FavoriteItem[]>([])
const histories = ref<History[]>([])
const loading = ref(false)
const selectedFolderId = ref<string | null>(null)
const showDrawer = ref(false)
const isDesktop = ref(window.innerWidth >= 720)
const searchQuery = ref('')
const multiSelectMode = ref(false)
const selectedIds = ref<Set<string>>(new Set())
const showFolderActions = ref(false)
const contextFolder = ref<FavoriteFolder | null>(null)
const showMovePopup = ref(false)
const dragIndex = ref<number | null>(null)
const dragOverIndex = ref<number | null>(null)

function handleResize() {
  isDesktop.value = window.innerWidth >= 720
  if (isDesktop.value) showDrawer.value = false
}
onMounted(() => { window.addEventListener('resize', handleResize); settingsStore.loadSettings(); loadData() })
onUnmounted(() => { window.removeEventListener('resize', handleResize) })

async function loadData() {
  loading.value = true
  try {
    const [f, s] = await Promise.all([listFolders(), getComicSources()])
    folders.value = f.sort((a, b) => a.order - b.order)
    sources.value = s
    await Promise.all([loadFavorites(), loadAllHistory()])
  } finally { loading.value = false }
}

async function loadAllHistory() {
  const items: History[] = []
  let offset = 0
  while (true) {
    const page = await listHistory(500, offset)
    items.push(...page.items)
    if (page.items.length < 500 || items.length >= page.total) break
    offset += page.items.length
  }
  histories.value = items
}

const historyMap = computed(() => {
  const map = new Map<string, History>()
  for (const h of histories.value) map.set(h.id, h)
  return map
})

function readProgressFor(item: FavoriteItem) {
  const h = historyMap.value.get(item.id)
  if (!h) return undefined
  return { page: h.page, maxPage: h.maxPage ?? undefined }
}

async function loadFavorites() {
  loading.value = true
  try { favorites.value = sortFavorites(await listFavorites(selectedFolderId.value ?? undefined)) }
  finally { loading.value = false }
}

function selectFolder(id: string | null) {
  selectedFolderId.value = id
  showDrawer.value = false
  exitMultiSelect()
  loadFavorites()
}

function navigateToComic(item: FavoriteItem) {
  if (multiSelectMode.value) { toggleSelect(item.id); return }
  const sourceKey = resolveSourceKey(item, sources.value)
  router.push(`/comic/${encodeURIComponent(sourceKey)}/${encodeURIComponent(item.id)}`)
}

const allCount = computed(() => favorites.value.length)

const filteredFavorites = computed(() => {
  if (!searchQuery.value.trim()) return favorites.value
  const q = searchQuery.value.toLowerCase()
  return favorites.value.filter(f => f.name.toLowerCase().includes(q))
})

const selectedFavorites = computed(() => favorites.value.filter(item => selectedIds.value.has(item.id)))
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

function sourceNameFor(item: FavoriteItem) {
  const key = resolveSourceKey(item, sources.value)
  const source = sources.value.find(s => s.key === key || s.canonicalKey === key)
  return source?.name || source?.sourceName || source?.displayName || key
}

function sortFavorites(items: FavoriteItem[]): FavoriteItem[] {
  return [...items].sort((a, b) => {
    const orderA = a.displayOrder ?? 0
    const orderB = b.displayOrder ?? 0
    if (orderA !== orderB) return orderA - orderB
    const timeA = a.lastUpdateTime ? Date.parse(a.lastUpdateTime) : NaN
    const timeB = b.lastUpdateTime ? Date.parse(b.lastUpdateTime) : NaN
    const validA = !Number.isNaN(timeA)
    const validB = !Number.isNaN(timeB)
    if (validA && validB) return timeB - timeA
    if (validA) return -1
    if (validB) return 1
    return 0
  })
}

function escapeHtmlAttribute(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

// --- Create folder ---
async function handleCreateFolder() {
  let folderName = ''
  try {
    await new Promise<void>((resolve, reject) => {
      showDialog({
        title: '新建文件夹',
        showCancelButton: true,
        confirmButtonText: '创建',
        cancelButtonText: '取消',
        message: `<div style="padding:16px 0"><input id="folder-name-input" type="text" placeholder="文件夹名称" style="width:100%;padding:8px 12px;border:1px solid #ddd;border-radius:4px;font-size:14px;box-sizing:border-box;" /></div>`,
        allowHtml: true,
      }).then(() => {
        const input = document.getElementById('folder-name-input') as HTMLInputElement
        folderName = input?.value?.trim() || ''
        if (folderName) resolve()
        else reject()
      }).catch(reject)
    })
  } catch { return }
  if (!folderName) return
  try {
    await createFolder(folderName)
    showToast('创建成功')
    await loadData()
  } catch { showToast('创建失败') }
}

// --- Rename folder ---
async function handleRenameFolder() {
  if (!contextFolder.value) return
  showFolderActions.value = false
  const oldName = contextFolder.value.name
  const escapedOldName = escapeHtmlAttribute(oldName)
  let newName = ''
  try {
    await new Promise<void>((resolve, reject) => {
      showDialog({
        title: '重命名文件夹',
        showCancelButton: true,
        confirmButtonText: '确定',
        cancelButtonText: '取消',
        message: `<div style="padding:16px 0"><input id="rename-folder-input" type="text" value="${escapedOldName}" style="width:100%;padding:8px 12px;border:1px solid #ddd;border-radius:4px;font-size:14px;box-sizing:border-box;" /></div>`,
        allowHtml: true,
      }).then(() => {
        const input = document.getElementById('rename-folder-input') as HTMLInputElement
        newName = input?.value?.trim() || ''
        if (newName && newName !== oldName) resolve()
        else reject()
      }).catch(reject)
    })
  } catch { return }
  if (!newName) return
  try {
    await renameFolder(oldName, newName)
    showToast('重命名成功')
    await loadData()
  } catch { showToast('重命名失败') }
}

// --- Delete folder ---
async function handleDeleteFolder() {
  if (!contextFolder.value) return
  showFolderActions.value = false
  const folder = contextFolder.value
  try {
    await showConfirmDialog({
      title: '删除文件夹',
      message: `确定要删除文件夹「${folder.name}」吗？文件夹内的收藏不会被删除。`,
    })
  } catch { return }
  try {
    await deleteFolder(folder.id)
    showToast('删除成功')
    if (selectedFolderId.value === folder.id) selectedFolderId.value = null
    await loadData()
  } catch { showToast('删除失败') }
}

// --- Folder context menu ---
function onFolderContextMenu(e: MouseEvent, folder: FavoriteFolder) {
  e.preventDefault()
  contextFolder.value = folder
  showFolderActions.value = true
}
let longPressTimer: ReturnType<typeof setTimeout> | null = null
function onFolderTouchStart(folder: FavoriteFolder) {
  longPressTimer = setTimeout(() => {
    contextFolder.value = folder
    showFolderActions.value = true
  }, 600)
}
function onFolderTouchEnd() {
  if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null }
}
// --- Drag reorder ---
function onDragStart(index: number) { dragIndex.value = index }
function onDragOver(e: DragEvent, index: number) { e.preventDefault(); dragOverIndex.value = index }
function onDragLeave() { dragOverIndex.value = null }
async function onDrop(index: number) {
  if (dragIndex.value === null || dragIndex.value === index) {
    dragIndex.value = null; dragOverIndex.value = null; return
  }
  const arr = [...folders.value]
  const [moved] = arr.splice(dragIndex.value, 1)
  arr.splice(index, 0, moved)
  folders.value = arr
  dragIndex.value = null; dragOverIndex.value = null
  try { await reorderFolders(arr.map(f => f.name)) }
  catch { showToast('排序失败'); await loadData() }
}
function onDragEnd() { dragIndex.value = null; dragOverIndex.value = null }

// --- Multi-select ---
function toggleMultiSelect() {
  multiSelectMode.value = !multiSelectMode.value
  if (!multiSelectMode.value) selectedIds.value = new Set()
}
function exitMultiSelect() { multiSelectMode.value = false; selectedIds.value = new Set() }
function toggleSelect(id: string) {
  const s = new Set(selectedIds.value)
  if (s.has(id)) s.delete(id); else s.add(id)
  selectedIds.value = s
}
function selectAll() { selectedIds.value = new Set(filteredFavorites.value.map(f => f.id)) }
function deselectAll() { selectedIds.value = new Set() }

// --- Batch delete ---
async function handleBatchDelete() {
  if (selectedIds.value.size === 0) return
  try {
    await showConfirmDialog({
      title: '批量删除',
      message: `确定要删除选中的 ${selectedIds.value.size} 个收藏吗？`,
    })
  } catch { return }
  try {
    await batchDeleteFavorites(selectedFavorites.value, selectedFolderId.value ?? undefined)
    showToast('删除成功')
    exitMultiSelect()
    await loadFavorites()
  } catch { showToast('删除失败') }
}

// --- Batch move ---
async function handleBatchMove(targetFolderId: string) {
  if (selectedIds.value.size === 0) return
  showMovePopup.value = false
  try {
    await batchMoveFavorites(selectedFavorites.value, targetFolderId, selectedFolderId.value ?? undefined)
    showToast('移动成功')
    exitMultiSelect()
    await loadFavorites()
  } catch { showToast('移动失败') }
}
</script>
<template>
  <div class="favorites-page">
    <!-- Mobile header -->
    <div v-if="!isDesktop" class="mobile-header">
      <van-icon name="bars" size="22" @click="showDrawer = true" class="menu-btn" />
      <span class="mobile-title">收藏</span>
      <div class="header-actions">
        <van-icon
          :name="multiSelectMode ? 'success' : 'list-switch'"
          size="20"
          @click="toggleMultiSelect"
          :class="{ 'active-icon': multiSelectMode }"
        />
      </div>
    </div>

    <!-- Multi-select toolbar -->
    <div v-if="multiSelectMode" class="multi-select-toolbar">
      <span class="select-count">已选 {{ selectedIds.size }} 项</span>
      <div class="toolbar-actions">
        <van-button size="small" @click="selectAll">全选</van-button>
        <van-button size="small" @click="deselectAll">取消全选</van-button>
        <van-button size="small" type="primary" @click="showMovePopup = true" :disabled="selectedIds.size === 0">移动</van-button>
        <van-button size="small" type="danger" @click="handleBatchDelete" :disabled="selectedIds.size === 0">删除</van-button>
        <van-button size="small" @click="exitMultiSelect">取消</van-button>
      </div>
    </div>

    <!-- Mobile drawer -->
    <van-popup
      v-if="!isDesktop"
      v-model:show="showDrawer"
      position="left"
      :style="{ width: '256px', height: '100%' }"
    >
      <div class="sidebar-content">
        <div class="sidebar-header">
          本地收藏
          <van-icon name="plus" size="18" class="add-folder-btn" @click="handleCreateFolder" />
        </div>
        <div
          class="folder-item"
          :class="{ active: selectedFolderId === null }"
          @click="selectFolder(null)"
        >
          <van-icon name="apps-o" size="20" />
          <span class="folder-name">全部</span>
          <span class="folder-count">{{ allCount }}</span>
        </div>
        <div
          v-for="(folder, idx) in folders"
          :key="folder.id"
          class="folder-item"
          :class="{ active: selectedFolderId === folder.id, 'drag-over': dragOverIndex === idx }"
          draggable="true"
          @click="selectFolder(folder.id)"
          @contextmenu="onFolderContextMenu($event, folder)"
          @touchstart="onFolderTouchStart(folder)"
          @touchend="onFolderTouchEnd"
          @touchmove="onFolderTouchEnd"
          @dragstart="onDragStart(idx)"
          @dragover="onDragOver($event, idx)"
          @dragleave="onDragLeave"
          @drop="onDrop(idx)"
          @dragend="onDragEnd"
        >
          <van-icon name="folder-o" size="20" />
          <span class="folder-name">{{ folder.name }}</span>
        </div>

        <div class="sidebar-header">网络收藏</div>
        <div
          v-for="source in sources"
          :key="source.key"
          class="folder-item"
          :class="{ active: selectedFolderId === `source:${source.key}` }"
          @click="selectFolder(`source:${source.key}`)"
        >
          <van-icon name="apps-o" size="20" />
          <span class="folder-name">{{ source.name }}</span>
        </div>
      </div>
    </van-popup>

    <div class="main-layout">
      <!-- Desktop sidebar -->
      <div v-if="isDesktop" class="sidebar">
        <div class="sidebar-content">
          <div class="sidebar-header">
            本地收藏
            <van-icon name="plus" size="18" class="add-folder-btn" @click="handleCreateFolder" />
          </div>
          <div
            class="folder-item"
            :class="{ active: selectedFolderId === null }"
            @click="selectFolder(null)"
          >
            <van-icon name="apps-o" size="20" />
            <span class="folder-name">全部</span>
            <span class="folder-count">{{ allCount }}</span>
          </div>
          <div
            v-for="(folder, idx) in folders"
            :key="folder.id"
            class="folder-item"
            :class="{ active: selectedFolderId === folder.id, 'drag-over': dragOverIndex === idx }"
            draggable="true"
            @click="selectFolder(folder.id)"
            @contextmenu="onFolderContextMenu($event, folder)"
            @touchstart="onFolderTouchStart(folder)"
            @touchend="onFolderTouchEnd"
            @touchmove="onFolderTouchEnd"
            @dragstart="onDragStart(idx)"
            @dragover="onDragOver($event, idx)"
            @dragleave="onDragLeave"
            @drop="onDrop(idx)"
            @dragend="onDragEnd"
          >
            <van-icon name="folder-o" size="20" />
            <span class="folder-name">{{ folder.name }}</span>
          </div>

          <div class="sidebar-header">网络收藏</div>
          <div
            v-for="source in sources"
            :key="source.key"
            class="folder-item"
            :class="{ active: selectedFolderId === `source:${source.key}` }"
            @click="selectFolder(`source:${source.key}`)"
          >
            <van-icon name="apps-o" size="20" />
            <span class="folder-name">{{ source.name }}</span>
          </div>
        </div>
      </div>

      <!-- Content area -->
      <div class="content-area">
        <!-- Search + multi-select toggle (desktop) -->
        <div class="content-toolbar">
          <van-search
            v-model="searchQuery"
            placeholder="搜索收藏"
            shape="round"
            class="search-input"
          />
          <van-icon
            v-if="isDesktop"
            :name="multiSelectMode ? 'success' : 'list-switch'"
            size="22"
            class="toolbar-icon"
            :class="{ 'active-icon': multiSelectMode }"
            @click="toggleMultiSelect"
          />
        </div>

        <van-loading v-if="loading && !favorites.length" class="loading-state" />
        <div v-else-if="filteredFavorites.length" class="comic-grid" :style="gridStyle">
          <div
            v-for="item in filteredFavorites"
            :key="item.id"
            class="comic-card"
            :class="{ selected: selectedIds.has(item.id) }"
            @click.stop="navigateToComic(item)"
          >
            <ComicCard
              :comic="item"
              :source-key="resolveSourceKey(item, sources)"
              :source-name="sourceNameFor(item)"
              :is-favorite="true"
              :read-progress="readProgressFor(item)"
            />
            <div v-if="multiSelectMode" class="checkbox-overlay">
              <van-checkbox
                :model-value="selectedIds.has(item.id)"
                @click.stop="toggleSelect(item.id)"
                shape="square"
              />
            </div>
          </div>
        </div>
        <van-empty v-else description="暂无收藏" />
      </div>
    </div>

    <!-- Folder action sheet -->
    <van-action-sheet
      v-model:show="showFolderActions"
      :actions="[
        { name: '重命名', color: '#333' },
        { name: '删除', color: '#ee0a24' }
      ]"
      cancel-text="取消"
      @select="(action: any) => {
        if (action.name === '重命名') handleRenameFolder()
        else if (action.name === '删除') handleDeleteFolder()
      }"
    />

    <!-- Batch move popup -->
    <van-popup
      v-model:show="showMovePopup"
      position="bottom"
      round
      :style="{ maxHeight: '60%' }"
    >
      <div class="move-popup">
        <div class="move-popup-title">移动到文件夹</div>
        <div class="move-popup-list">
          <div
            v-for="folder in folders"
            :key="folder.id"
            class="move-popup-item"
            @click="handleBatchMove(folder.id)"
          >
            <van-icon name="folder-o" size="20" />
            <span>{{ folder.name }}</span>
          </div>
          <van-empty v-if="!folders.length" description="暂无文件夹" image="search" />
        </div>
      </div>
    </van-popup>
  </div>
</template>
<style scoped>
.favorites-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.mobile-header {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 16px;
  border-bottom: 0.6px solid #e0e0e0;
  gap: 12px;
}

.menu-btn { cursor: pointer; }

.mobile-title {
  font-size: 16px;
  font-weight: 500;
  flex: 1;
}

.header-actions {
  display: flex;
  align-items: center;
  gap: 12px;
}

.active-icon { color: #4f6ef7; }

.multi-select-toolbar {
  display: flex;
  align-items: center;
  padding: 8px 16px;
  background: #f7f8fa;
  border-bottom: 0.6px solid #e0e0e0;
  gap: 12px;
  flex-wrap: wrap;
}

.select-count {
  font-size: 14px;
  color: #333;
  white-space: nowrap;
}

.toolbar-actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.main-layout {
  display: flex;
  flex: 1;
  overflow: hidden;
}

.sidebar {
  width: 256px;
  flex-shrink: 0;
  border-right: 0.6px solid #e0e0e0;
  overflow-y: auto;
}

.sidebar-content {
  overflow-y: auto;
  height: 100%;
}

.sidebar-header {
  font-size: 14px;
  color: #999;
  padding: 16px;
  padding-bottom: 4px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.add-folder-btn {
  cursor: pointer;
  color: #4f6ef7;
  padding: 4px;
  border-radius: 4px;
  transition: background 0.15s;
}

.add-folder-btn:hover { background: rgba(79, 110, 247, 0.1); }

.folder-item {
  height: 48px;
  padding: 0 16px;
  display: flex;
  align-items: center;
  gap: 12px;
  cursor: pointer;
  transition: background 0.15s;
  position: relative;
  user-select: none;
}

.folder-item:hover { background: #f5f5f5; }

.folder-item.active {
  background: rgba(79, 110, 247, 0.12);
  border-left: 2px solid #4f6ef7;
  padding-left: 14px;
}

.folder-item.drag-over {
  border-top: 2px solid #4f6ef7;
}

.folder-name {
  flex: 1;
  font-size: 14px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.folder-count {
  font-size: 12px;
  color: #999;
  background: #f0f0f0;
  padding: 2px 8px;
  border-radius: 10px;
}

.content-area {
  flex: 1;
  overflow-y: auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  will-change: scroll-position;
  transform: translateZ(0);
}

.content-toolbar {
  display: flex;
  align-items: center;
  padding: 8px 12px;
  gap: 8px;
  border-bottom: 0.6px solid #e0e0e0;
}

.search-input { flex: 1; }

.toolbar-icon {
  cursor: pointer;
  padding: 6px;
  border-radius: 4px;
  transition: background 0.15s;
}

.toolbar-icon:hover { background: #f0f0f0; }

.loading-state {
  display: flex;
  justify-content: center;
  padding: 48px;
}

.comic-grid {
  display: grid;
  gap: 12px;
  padding: 16px;
  justify-content: center;
}

.comic-card {
  cursor: pointer;
  transition: transform 0.15s;
  position: relative;
  content-visibility: auto;
  contain-intrinsic-size: auto 300px;
}

.comic-card:hover { transform: translateY(-2px); }

.comic-card.selected {
  outline: 2px solid #4f6ef7;
  outline-offset: 2px;
  border-radius: 8px;
}

.checkbox-overlay {
  position: absolute;
  top: 6px;
  left: 6px;
  z-index: 2;
}

.move-popup {
  padding: 16px;
}

.move-popup-title {
  font-size: 16px;
  font-weight: 500;
  margin-bottom: 12px;
  text-align: center;
}

.move-popup-list {
  max-height: 300px;
  overflow-y: auto;
}

.move-popup-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
  border-radius: 8px;
  cursor: pointer;
  transition: background 0.15s;
}

.move-popup-item:hover { background: #f5f5f5; }
</style>
