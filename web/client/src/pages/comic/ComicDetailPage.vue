<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, onActivated } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { apiPost } from '@/services/api'
import { addFavorite, deleteFavorite, getComicSources, listFavorites, listFolders, listHistory, createFolder, markAsRead } from '@/services/server-db'
import { resolveSourceKey, sourceTypeFromKey } from '@/utils/source'
import { useSettingsStore } from '@/stores/settings'
import ProxiedImage from '@/components/ProxiedImage.vue'
import ComicCard from '@/components/ComicCard.vue'
import RelatedSourcesDialog from '@/components/RelatedSourcesDialog.vue'
import SourceMigrationDialog from '@/components/SourceMigrationDialog.vue'
import { comicAuthorText, normalizeComicTags, parseComicTags } from '@/utils/comic-display'
import { showToast, showDialog } from 'vant'
import type { Comic, Chapter, ChapterGroup, Comment, ComicSource, History } from '@/types'

const route = useRoute()
const router = useRouter()
const settingsStore = useSettingsStore()
const sourceKey = computed(() => decodeURIComponent(route.params.sourceKey as string))
const comicId = computed(() => decodeURIComponent(route.params.id as string))

const comic = ref<Comic | null>(null)
const chapters = ref<Chapter[] | ChapterGroup[]>([])
const comments = ref<Comment[]>([])
const loading = ref(true)
const error = ref('')
const isFavorite = ref(false)
const favoriteFolder = ref<string | null>(null)
const favoriteLoading = ref(false)
const showFavPopup = ref(false)
const favFolders = ref<Array<{ id: string; name: string }>>([])
const favFolderStatus = ref<Record<string, boolean>>({})
let favLongPressTimer: ReturnType<typeof setTimeout> | null = null
let favLongPressTriggered = false
const descExpanded = ref(false)
const activeTab = ref(0)
const sortAsc = ref(true)
const lastReadChapterId = ref<string | null>(null)
const readChapterIds = ref<Set<string>>(new Set())
const lastReadPage = ref(1)
const lastReadGroup = ref<number | null>(null)
const showMenu = ref(false)
const commentsPage = ref(1)
const commentsLoading = ref(false)
const commentsHasMore = ref(false)
const thumbnails = ref<{ url: string; ep: string; page: number }[]>([])
const thumbnailsLoading = ref(false)
const relatedComics = ref<(Record<string, any> & { id: string })[]>([])
const relatedLoading = ref(false)
const expandedReplies = ref<Set<number>>(new Set())
const detailNotice = ref('')
const sources = ref<ComicSource[]>([])
const detailSourceName = ref('')
const isMobile = ref(false)
const showRelatedDialog = ref(false)
const showMigrationDialog = ref(false)

function onResize() {
  isMobile.value = window.innerWidth < 600
}

const isGrouped = computed(() => {
  if (!chapters.value.length) return false
  return chapters.value.some(c => 'chapters' in c)
})
const groupTitles = computed(() => {
  if (!isGrouped.value) return ['默認']
  return (chapters.value as ChapterGroup[]).map(g => g.title)
})
const activeGroupChapters = computed<Chapter[]>(() => {
  if (!chapters.value.length) return []
  let list: Chapter[]
  if (isGrouped.value) {
    const group = (chapters.value as ChapterGroup[])[activeTab.value]
    list = group ? group.chapters : []
  } else {
    list = chapters.value as Chapter[]
  }
  return sortAsc.value ? list : [...list].reverse()
})
const flatChapters = computed<Chapter[]>(() => {
  if (!chapters.value.length) return []
  if (isGrouped.value) return (chapters.value as ChapterGroup[]).flatMap(g => g.chapters)
  return chapters.value as Chapter[]
})
// Resolve the stored last-read chapter id (which may be an actual chapter id,
// a "groupIdx-chapterIdx" positional pair, or a 1-based flat index) to the
// real Chapter object. Returns the chapter plus the resolved group index.
function resolveHistoryChapter(id: string): { chapter: Chapter | undefined; groupIdx: number | null } {
  let ch = flatChapters.value.find(c => c.id === id)
  if (ch) return { chapter: ch, groupIdx: null }
  // "groupIdx-chapterIdx" positional format (for grouped chapters), both 1-based
  const dashIdx = id.indexOf('-')
  if (dashIdx > 0) {
    const gIdx = parseInt(id.substring(0, dashIdx), 10)
    const cIdx = parseInt(id.substring(dashIdx + 1), 10)
    if (!isNaN(gIdx) && !isNaN(cIdx) && isGrouped.value) {
      const groups = chapters.value as ChapterGroup[]
      if (gIdx >= 1 && gIdx <= groups.length) {
        const group = groups[gIdx - 1]
        if (group?.chapters && cIdx >= 1 && cIdx <= group.chapters.length) {
          return { chapter: group.chapters[cIdx - 1], groupIdx: gIdx }
        }
      }
    }
  }
  // Fallback: simple 1-based flat index
  const idx = parseInt(id, 10)
  if (!isNaN(idx) && idx >= 1 && idx <= flatChapters.value.length) {
    return { chapter: flatChapters.value[idx - 1], groupIdx: null }
  }
  return { chapter: undefined, groupIdx: null }
}

const lastReadChapter = computed<Chapter | undefined>(() => {
  if (!lastReadChapterId.value) return undefined
  return resolveHistoryChapter(lastReadChapterId.value).chapter
})

const lastReadInfo = computed(() => {
  if (!lastReadChapterId.value) return null
  const id = lastReadChapterId.value
  const { chapter: ch, groupIdx: resolvedGroupIdx } = resolveHistoryChapter(id)
  const groupIdxForDisplay = resolvedGroupIdx ?? lastReadGroup.value ?? 0
  const groupName = groupTitles.value[groupIdxForDisplay > 0 ? groupIdxForDisplay - 1 : 0] || groupTitles.value[lastReadGroup.value ?? 0] || '默認'
  return { group: groupName, chapter: ch?.title || id, page: lastReadPage.value }
})
const sourceDisplayName = computed(() => {
  const source = sources.value.find(item => {
    const canonical = item.canonicalKey || item.key
    return item.key === sourceKey.value || canonical === sourceKey.value || item.key === detailSourceName.value
  })
  return detailSourceName.value || source?.sourceName || source?.displayName || source?.name || sourceKey.value
})

const hasHistory = computed(() => lastReadChapterId.value != null)
const parsedTags = computed(() => comic.value ? parseComicTags(comic.value as any) : { authors: [] as string[], statuses: [] as string[], updates: [] as string[], contentTags: [] as string[] })
const displayAuthors = computed(() => {
  const fromSubtitle = comic.value?.subtitle || (comic.value as any)?.author || ''
  if (fromSubtitle) return fromSubtitle.split(/[,|]/).map((s: string) => s.trim()).filter(Boolean)
  return parsedTags.value.authors
})
const displayUpdate = computed(() => (comic.value as any)?.updateTime || (comic.value as any)?.lastUpdateTime || parsedTags.value.updates[0] || '')
const displayStatus = computed(() => (comic.value as any)?.status || comic.value?.language || parsedTags.value.statuses[0] || '')
const displayProgress = computed(() => {
  if (!lastReadInfo.value) return ''
  return `${lastReadInfo.value.group} ${lastReadInfo.value.chapter} P${lastReadInfo.value.page}`
})
const menuActions = computed(() => {
  const items: { text: string; icon?: string }[] = [
    { text: '复制标题', icon: 'description' },
    { text: '复制ID', icon: 'label' },
  ]
  if ((comic.value as any)?.url) {
    items.push({ text: '复制链接', icon: 'link' })
    items.push({ text: '浏览器打开', icon: 'browser' })
  }
  return items
})

function parseReadEpisode(raw: History['readEpisode']): string[] {
  if (Array.isArray(raw)) return raw.map(String).filter(Boolean)
  if (!raw) return []
  const text = String(raw).trim()
  if (!text) return []
  try {
    const parsed = JSON.parse(text)
    if (Array.isArray(parsed)) return parsed.map(String).filter(Boolean)
  } catch {}
  return text.split(',').map(s => s.trim()).filter(Boolean)
}

function latestReadChapterId(entry: History): string | null {
  const readEpisodes = parseReadEpisode(entry.readEpisode)
  return readEpisodes[readEpisodes.length - 1] || (entry.ep ? String(entry.ep) : null)
}

async function loadSources() {
  if (sources.value.length) return sources.value
  try {
    sources.value = await getComicSources()
  } catch {
    sources.value = []
  }
  return sources.value
}

async function findHistoryEntry() {
  const sourceList = await loadSources()
  const history = await listHistory(1000)
  return history.items.find((h) => {
    const resolved = resolveSourceKey(h, sourceList)
    return h.id === comicId.value && (
      resolved === sourceKey.value ||
      h.sourceKey === sourceKey.value ||
      String(h.type) === sourceKey.value
    )
  })
}

function favoriteType() {
  return sourceTypeFromKey(sourceKey.value)
}

async function refreshFavoriteState() {
  if (!comic.value) return
  try {
    const type = favoriteType()
    const items = await listFavorites()
    const item = items.find(fav => fav.id === comicId.value && fav.type === type)
    isFavorite.value = !!item
    favoriteFolder.value = item ? ((item as any).folder ?? null) : null
  } catch {
    isFavorite.value = false
    favoriteFolder.value = null
  }
}

function favoriteTime() {
  return new Date().toLocaleString('sv-SE', { hour12: false })
}

async function hydrateFromHistoryFallback(message: string) {
  try {
    const entry = await findHistoryEntry()
    if (!entry) return false
    comic.value = {
      id: entry.id,
      title: entry.title,
      subtitle: entry.subtitle,
      cover: entry.cover,
      description: '当前 Web Helper 未返回完整漫画详情，已显示本地历史记录中的基础信息。',
      sourceKey: sourceKey.value,
      tags: [],
    }
    chapters.value = []
    comments.value = []
    thumbnails.value = []
    relatedComics.value = []
    detailNotice.value = message
    lastReadChapterId.value = latestReadChapterId(entry)
    lastReadPage.value = entry.page || 1
    lastReadGroup.value = entry.group ?? null
    return true
  } catch {
    return false
  }
}

async function fetchDetail() {
  loading.value = true
  error.value = ''
  detailNotice.value = ''
  try {
    const res = await apiPost<{
      comic: Comic
      chapters: Chapter[] | ChapterGroup[]
      comments?: Comment[]
      source?: Partial<ComicSource>
      sourceName?: string
      error?: string
    }>('/api/server-db/comic/detail', {
      sourceKey: sourceKey.value,
      comicId: comicId.value,
    })
    if (res.error) {
      error.value = res.error
      return
    }
    if (!res.comic || typeof res.comic !== 'object') {
      error.value = '返回数据格式错误: 缺少 comic 字段'
      return
    }
    detailSourceName.value = res.sourceName || res.source?.sourceName || res.source?.displayName || ''
    comic.value = { ...res.comic, tags: normalizeComicTags(res.comic.tags), sourceName: detailSourceName.value }
    chapters.value = res.chapters || []
    const detailComments = Array.isArray(res.comments) ? res.comments : []
    comments.value = detailComments
    commentsHasMore.value = detailComments.length >= 20
    void refreshFavoriteState()
  } catch (e: any) {
    const message = e.message || '加载失败'
    const recovered = await hydrateFromHistoryFallback(message)
    if (!recovered) error.value = message
  } finally {
    loading.value = false
  }
}

async function fetchHistory() {
  try {
    const entry = await findHistoryEntry()
    if (entry) {
      lastReadChapterId.value = latestReadChapterId(entry)
      lastReadPage.value = entry.page || 1
      lastReadGroup.value = entry.group ?? null
      // Populate all read chapter IDs
      const episodes = parseReadEpisode(entry.readEpisode)
      readChapterIds.value = new Set(episodes)
    }
  } catch { /* ignore */ }
}

function isChapterRead(chapterId: string): boolean {
  return enrichedReadChapterIds.value.has(chapterId)
}

// History stores read episodes as 1-based positional indices (or "group-chapter"
// format for grouped chapters), but chapter IDs from the source may differ.
// Augment readChapterIds by mapping positional indices to actual chapter IDs.
const enrichedReadChapterIds = computed(() => {
  const ids = new Set(readChapterIds.value)
  if (!flatChapters.value.length) return ids
  for (const rawId of readChapterIds.value) {
    // 1-based positional index → actual chapter ID
    const idx = parseInt(rawId, 10)
    if (!isNaN(idx) && idx >= 1 && idx <= flatChapters.value.length) {
      ids.add(flatChapters.value[idx - 1].id)
    }
    // Grouped format: "groupIdx-chapterIdx" (both 1-based)
    const dashIdx = rawId.indexOf('-')
    if (dashIdx > 0) {
      const groupIdx = parseInt(rawId.substring(0, dashIdx), 10)
      const chIdx = parseInt(rawId.substring(dashIdx + 1), 10)
      if (!isNaN(groupIdx) && !isNaN(chIdx) && isGrouped.value) {
        const groups = chapters.value as ChapterGroup[]
        if (groupIdx > 0 && groupIdx <= groups.length) {
          const group = groups[groupIdx - 1]
          if (group?.chapters && chIdx > 0 && chIdx <= group.chapters.length) {
            ids.add(group.chapters[chIdx - 1].id)
          }
        }
      }
    }
  }
  return ids
})

async function fetchThumbnails() {
  thumbnailsLoading.value = true
  try {
    const res = await apiPost<{ thumbnails: { url: string; ep: string; page: number }[] }>(
      '/api/server-db/comic/thumbnails',
      { sourceKey: sourceKey.value, comicId: comicId.value }
    )
    thumbnails.value = Array.isArray(res.thumbnails) ? res.thumbnails : []
  } catch { /* ignore */ }
  finally { thumbnailsLoading.value = false }
}

async function fetchRelated() {
  relatedLoading.value = true
  try {
    const res = await apiPost<{ comics: (Record<string, any> & { id: string })[] }>(
      '/api/server-db/comic/related',
      { sourceKey: sourceKey.value, comicId: comicId.value }
    )
    relatedComics.value = Array.isArray(res.comics) ? res.comics : []
  } catch { /* ignore */ }
  finally { relatedLoading.value = false }
}

async function loadMoreComments() {
  commentsLoading.value = true
  try {
    commentsPage.value++
    const res = await apiPost<{ comments: Comment[] }>('/api/server-db/comic/comments', {
      sourceKey: sourceKey.value,
      comicId: comicId.value,
      page: commentsPage.value,
    })
    const newComments = Array.isArray(res.comments) ? res.comments : []
    comments.value = [...comments.value, ...newComments]
    commentsHasMore.value = newComments.length >= 20
  } catch { /* ignore */ }
  finally { commentsLoading.value = false }
}

async function openFavPopup() {
  if (!comic.value) return
  try {
    const folders = await listFolders()
    favFolders.value = folders.map(f => ({ id: f.id || f.name, name: f.name }))
    // Check which folders already contain this comic
    const allFavs = await listFavorites()
    const type = favoriteType()
    const status: Record<string, boolean> = {}
    let foundAny = false
    let foundFolder: string | null = null
    for (const f of folders) {
      const fid = f.id || f.name
      const exists = allFavs.some(fav => fav.id === comicId.value && fav.type === type && (fav as any).folder === fid)
      status[fid] = !!exists
      if (exists) { foundAny = true; foundFolder = fid }
    }
    favFolderStatus.value = status
    isFavorite.value = foundAny
    favoriteFolder.value = foundFolder
    showFavPopup.value = true
  } catch (e: any) {
    showToast('加载收藏夹失败')
  }
}

async function toggleFavInFolder(folderId: string) {
  if (!comic.value) return
  favoriteLoading.value = true
  const type = favoriteType()
  const isFaved = favFolderStatus.value[folderId]
  try {
    if (isFaved) {
      await deleteFavorite(folderId, comicId.value, type)
      favFolderStatus.value[folderId] = false
    } else {
      await addFavorite({
        folder: folderId,
        id: comicId.value,
        type,
        name: comic.value.title,
        author: comicAuthorText(comic.value),
        tags: normalizeComicTags(comic.value.tags),
        coverPath: comic.value.cover,
        time: favoriteTime(),
        title: comic.value.title,
        cover: comic.value.cover,
      } as any)
      favFolderStatus.value[folderId] = true
    }
    // Update global state
    const anyFaved = Object.values(favFolderStatus.value).some(v => v)
    isFavorite.value = anyFaved
    if (!anyFaved) favoriteFolder.value = null
  } catch (e: any) {
    showToast(e.message || '操作失败')
  } finally {
    favoriteLoading.value = false
  }
}

async function createFavAndAdd() {
  showFavPopup.value = false
  let folderName = ''
  try {
    await new Promise<void>((resolve, reject) => {
      showDialog({
        title: '新建收藏夹',
        showCancelButton: true,
        confirmButtonText: '创建并收藏',
        cancelButtonText: '取消',
        message: `<div style="padding:16px 0"><input id="new-fav-folder-input" type="text" placeholder="文件夹名称" style="width:100%;padding:8px 12px;border:1px solid #ddd;border-radius:4px;font-size:14px;box-sizing:border-box;" /></div>`,
        allowHtml: true,
      }).then(() => {
        const input = document.getElementById('new-fav-folder-input') as HTMLInputElement
        folderName = input?.value?.trim() || ''
        if (folderName) resolve()
        else reject()
      }).catch(reject)
    })
  } catch { return }
  if (!folderName || !comic.value) return
  try {
    await createFolder(folderName)
    showToast('创建成功')
    // Refresh folder list and add to new folder
    await openFavPopup()
    const newFolder = favFolders.value.find(f => f.name === folderName)
    if (newFolder) await toggleFavInFolder(newFolder.id)
  } catch { showToast('创建失败') }
}

async function quickFavorite() {
  if (!comic.value) return
  const presetFolder = settingsStore.settings.quickFav
  if (!presetFolder) {
    // No preset: fall back to opening the popup
    openFavPopup()
    return
  }
  favoriteLoading.value = true
  const type = favoriteType()
  try {
    // Check if already in preset folder
    const allFavs = await listFavorites()
    const alreadyFaved = allFavs.some(fav =>
      fav.id === comicId.value && fav.type === type && (fav as any).folder === presetFolder
    )
    if (alreadyFaved) {
      showToast('已在该收藏夹中')
      return
    }
    await addFavorite({
      folder: presetFolder,
      id: comicId.value,
      type,
      name: comic.value.title,
      author: comicAuthorText(comic.value),
      tags: normalizeComicTags(comic.value.tags),
      coverPath: comic.value.cover,
      time: favoriteTime(),
      title: comic.value.title,
      cover: comic.value.cover,
    } as any)
    isFavorite.value = true
    favoriteFolder.value = presetFolder
    showToast('已收藏')
  } catch (e: any) {
    showToast(e.message || '收藏失败')
  } finally {
    favoriteLoading.value = false
  }
}

function onFavPointerDown() {
  favLongPressTriggered = false
  favLongPressTimer = setTimeout(() => {
    favLongPressTriggered = true
    quickFavorite()
  }, 600)
}
function onFavPointerUp() {
  if (favLongPressTimer) { clearTimeout(favLongPressTimer); favLongPressTimer = null }
}
function onFavClick() {
  if (favLongPressTriggered) { favLongPressTriggered = false; return }
  openFavPopup()
}

function readComic(chapter?: Chapter) {
  const ch = chapter || flatChapters.value[0]
  if (!ch) {
    if (lastReadChapterId.value) {
      router.push({
        path: `/reader/${sourceKey.value}/${comicId.value}`,
        query: { ep: lastReadChapterId.value, page: String(lastReadPage.value || 1) },
      })
      return
    }
    showToast('暂无可阅读章节')
    return
  }
  // Resume the saved page only when opening the chapter that was last read.
  // lastReadChapterId may be stored as a positional id, so compare against the
  // resolved chapter object rather than the raw id.
  const isLastRead = lastReadChapter.value
    ? ch.id === lastReadChapter.value.id
    : ch.id === lastReadChapterId.value
  const page = isLastRead ? lastReadPage.value : 1
  router.push({
    path: `/reader/${sourceKey.value}/${comicId.value}`,
    query: { ep: ch.id, page: String(page) },
  })
}

function continueReading() {
  const ch = lastReadChapter.value
  if (ch) { readComic(ch); return }
  readComic()
}

function startReading() {
  const first = flatChapters.value[0]
  if (first) readComic(first)
}

async function shareComic() {
  if (!comic.value) return
  if (navigator.share) {
    try {
      await navigator.share({ title: comic.value.title, url: window.location.href })
    } catch { /* user cancelled */ }
  }
}

async function markAsReadHandler() {
  if (!comic.value) return
  const folder = (comic.value as any).folder || favoriteFolder.value
  if (!folder) {
    showToast('请先收藏此漫画')
    return
  }
  try {
    await markAsRead(folder, comicId.value, favoriteType())
    showToast('已标记为已读')
    // Refresh reading progress
    lastReadChapterId.value = null
    lastReadPage.value = 1
    await fetchHistory()
  } catch (e: any) {
    showToast(e.message || '标记失败')
  }
}

function onTagClick(tag: string) {
  router.push({ path: '/search', query: { keyword: tag, source: sourceKey.value } })
}

function onAuthorClick(author: string) {
  router.push({ path: '/search', query: { keyword: author, source: sourceKey.value } })
}

function handleMenuSelect(action: { text: string }) {
  if (!comic.value) return
  const c = comic.value as any
  switch (action.text) {
    case '复制标题':
      navigator.clipboard.writeText(comic.value.title).then(() => showToast('已复制'))
      break
    case '复制ID':
      navigator.clipboard.writeText(comicId.value).then(() => showToast('已复制'))
      break
    case '复制链接':
      if (c.url) navigator.clipboard.writeText(c.url).then(() => showToast('已复制'))
      break
    case '浏览器打开':
      if (c.url) window.open(c.url, '_blank')
      break
  }
}

function toggleReplies(idx: number) {
  const set = expandedReplies.value
  if (set.has(idx)) { set.delete(idx) } else { set.add(idx) }
}

function scrollToComments() {
  const el = document.querySelector('.comments-section')
  if (el) el.scrollIntoView({ behavior: 'smooth' })
}

function toggleSort() { sortAsc.value = !sortAsc.value }
function onBack() { router.back() }

onMounted(async () => {
  window.addEventListener('resize', onResize)
  onResize()
  await settingsStore.loadSettings()
  sortAsc.value = !settingsStore.settings.reverseChapters
  void loadSources()
  await fetchDetail()
  void fetchHistory()
  const loadOptional = () => {
    void fetchThumbnails()
    void fetchRelated()
  }
  const requestIdle = (window as any).requestIdleCallback
  if (typeof requestIdle === 'function') {
    requestIdle(loadOptional, { timeout: 1500 })
  } else {
    setTimeout(loadOptional, 300)
  }
})

onActivated(() => {
  // Page is kept-alive; when navigating back from the reader, onMounted does
  // not run again. Re-fetch reading progress so the chapter list "read" styles
  // and the 上次阅读 / 继续 button reflect the latest history.
  void fetchHistory()
})

onUnmounted(() => {
  window.removeEventListener('resize', onResize)
})
</script>
<template>
  <div class="comic-detail-page">
    <!-- Top Bar -->
    <div class="top-bar">
      <div class="top-bar-btn" @click="onBack">
        <van-icon name="arrow-left" size="20" />
      </div>
      <van-popover v-model:show="showMenu" :actions="menuActions" placement="bottom-end" @select="handleMenuSelect">
        <template #reference>
          <div class="top-bar-btn">
            <van-icon name="ellipsis" size="20" />
          </div>
        </template>
      </van-popover>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="content">
      <van-skeleton title :row="6" />
    </div>

    <!-- Error -->
    <div v-else-if="error" class="content error-content">
      <van-empty :description="error" image="error">
        <van-button type="primary" size="small" @click="fetchDetail">重试</van-button>
      </van-empty>
    </div>

    <!-- Main Content -->
    <div v-else-if="comic" class="content">
      <div v-if="detailNotice" class="detail-notice">
        {{ detailNotice }}，已使用本地记录兜底显示。
      </div>

      <!-- Header: Cover + Metadata -->
      <div class="header-section">
        <ProxiedImage
          :src="comic.cover"
          :alt="comic.title"
          width="120px"
          height="160px"
          class="cover-image"
        />
        <div class="meta-info">
          <h2 class="comic-title">{{ comic.title }}</h2>
          <div class="capsule-rows">
            <div v-if="displayAuthors.length" class="capsule-row">
              <span class="capsule-label" style="background: #03a9f42e; color: #03a9f4">作者</span>
              <span class="capsule-values">
                <template v-for="(author, idx) in displayAuthors" :key="author">
                  <span class="capsule-link" @click="onAuthorClick(author)">{{ author }}</span>
                  <span v-if="idx < displayAuthors.length - 1" class="capsule-sep">/</span>
                </template>
              </span>
            </div>
            <div v-if="displayUpdate" class="capsule-row">
              <span class="capsule-label" style="background: #00bcd42e; color: #00bcd4">更新</span>
              <span class="capsule-value">{{ displayUpdate }}</span>
            </div>
            <div class="capsule-row">
              <span class="capsule-label" style="background: #00bcd42e; color: #00bcd4">来源</span>
              <span class="capsule-value">{{ sourceDisplayName }}</span>
            </div>
            <div v-if="parsedTags.contentTags.length" class="capsule-row">
              <span class="capsule-label" style="background: #e91e632e; color: #e91e63">标签</span>
              <span class="capsule-values">
                <template v-for="(tag, idx) in parsedTags.contentTags" :key="tag">
                  <span class="capsule-link" @click="onTagClick(tag)">{{ tag }}</span>
                  <span v-if="idx < parsedTags.contentTags.length - 1" class="capsule-sep">/</span>
                </template>
              </span>
            </div>
            <div v-if="displayStatus" class="capsule-row">
              <span class="capsule-label" style="background: #9c27b02e; color: #9c27b0">状态</span>
              <span class="capsule-value">{{ displayStatus }}</span>
            </div>
            <div v-if="comic.pagesText" class="capsule-row">
              <span class="capsule-label" style="background: #ff98002e; color: #ff9800">页数</span>
              <span class="capsule-value">{{ comic.pagesText }}</span>
            </div>
            <div v-if="displayProgress" class="capsule-row">
              <span class="capsule-label" style="background: #4caf502e; color: #4caf50">进度</span>
              <span class="capsule-value">{{ displayProgress }}</span>
            </div>
          </div>
          <div v-if="comic.stars" class="meta-stars">
            <van-rate :model-value="comic.stars" readonly allow-half size="14" color="#f5a623" void-color="#ddd" />
          </div>
        </div>
      </div>

      <!-- Action Buttons - Desktop (matches APP: single horizontal scroll row) -->
      <div v-if="!isMobile" class="action-buttons desktop-actions">
        <button v-if="hasHistory" class="action-btn" style="background:#4f6ef7;color:#fff;border-color:#4f6ef7" @click="continueReading">
          <van-icon name="play-circle-o" class="action-icon" />
          <span>继续</span>
        </button>
        <button class="action-btn" style="background:#27ae60;color:#fff;border-color:#27ae60" @click="startReading">
          <van-icon name="play" class="action-icon" />
          <span>开始</span>
        </button>
        <button
          class="action-btn" style="background:#f5a623;color:#fff;border-color:#f5a623"
          :class="{ active: isFavorite }"
          @click="onFavClick"
          @pointerdown="onFavPointerDown"
          @pointerup="onFavPointerUp"
          @pointercancel="onFavPointerUp"
        >
          <van-icon :name="isFavorite ? 'star' : 'star-o'" class="action-icon" />
          <span>收藏</span>
        </button>
        <button v-if="comments.length" class="action-btn" @click="scrollToComments">
          <van-icon name="chat-o" class="action-icon" style="color:#27ae60" />
          <span>评论</span>
        </button>
        <button class="action-btn" style="background:#5b9bd5;color:#fff;border-color:#5b9bd5" @click="shareComic">
          <van-icon name="share-o" class="action-icon" />
          <span>分享</span>
        </button>
        <button class="action-btn" style="background:#e74c3c;color:#fff;border-color:#e74c3c" @click="markAsReadHandler">
          <van-icon name="checked" class="action-icon" />
          <span>标记已读</span>
        </button>
        <button class="action-btn" style="background:#ff9800;color:#fff;border-color:#ff9800" @click="showMigrationDialog = true">
          <van-icon name="exchange" class="action-icon" />
          <span>迁移源</span>
        </button>
        <button class="action-btn" style="background:#9b59b6;color:#fff;border-color:#9b59b6" @click="showRelatedDialog = true">
          <van-icon name="cluster-o" class="action-icon" />
          <span>关联源</span>
        </button>
      </div>

      <!-- Action Buttons - Mobile (compact row + full-width row) -->
      <div v-else class="mobile-actions">
        <div class="mobile-action-row">
          <button v-if="hasHistory" class="action-btn compact" style="background:#27ae60;color:#fff;border-color:#27ae60" @click="startReading">
            <van-icon name="play" class="action-icon" />
            <span>开始</span>
          </button>
          <button
            class="action-btn compact" style="background:#f5a623;color:#fff;border-color:#f5a623"
            :class="{ active: isFavorite }"
            @click="onFavClick"
            @pointerdown="onFavPointerDown"
            @pointerup="onFavPointerUp"
            @pointercancel="onFavPointerUp"
          >
            <van-icon :name="isFavorite ? 'star' : 'star-o'" class="action-icon" />
            <span>收藏</span>
          </button>
          <button v-if="comments.length" class="action-btn compact" @click="scrollToComments">
            <van-icon name="chat-o" class="action-icon" style="color:#27ae60" />
            <span>评论</span>
          </button>
          <button class="action-btn compact" style="background:#5b9bd5;color:#fff;border-color:#5b9bd5" @click="shareComic">
            <van-icon name="share-o" class="action-icon" />
            <span>分享</span>
          </button>
          <button class="action-btn compact" style="background:#e74c3c;color:#fff;border-color:#e74c3c" @click="markAsReadHandler">
            <van-icon name="checked" class="action-icon" />
            <span>标记已读</span>
          </button>
          <button class="action-btn compact" style="background:#ff9800;color:#fff;border-color:#ff9800" @click="showMigrationDialog = true">
            <van-icon name="exchange" class="action-icon" />
            <span>迁移源</span>
          </button>
          <button class="action-btn compact" style="background:#9b59b6;color:#fff;border-color:#9b59b6" @click="showRelatedDialog = true">
            <van-icon name="cluster-o" class="action-icon" />
            <span>关联源</span>
          </button>
        </div>
        <div class="mobile-full-row">
          <button v-if="hasHistory" class="continue-btn" style="background:#4f6ef7;color:#fff" @click="continueReading">
            <van-icon name="play-circle-o" />
            <span>继续</span>
          </button>
          <button v-else class="continue-btn" style="background:#27ae60;color:#fff" @click="startReading">
            <van-icon name="play" />
            <span>开始</span>
          </button>
        </div>
      </div>

      <!-- Last Read Progress -->
      <div v-if="lastReadInfo" class="last-read-pill">
        <van-icon name="clock-o" size="14" />
        <span>上次阅读: {{ lastReadInfo.group }} {{ lastReadInfo.chapter }} P{{ lastReadInfo.page }}</span>
      </div>

      <!-- Description Section -->
      <div v-if="comic.description" class="desc-section">
        <div class="section-header">描述</div>
        <div
          class="desc-text"
          :class="{ expanded: descExpanded }"
          @click="descExpanded = !descExpanded"
        >
          {{ comic.description }}
        </div>
        <span v-if="!descExpanded" class="expand-btn" @click="descExpanded = true">展开</span>
        <div class="divider"></div>
      </div>

      <!-- Chapters Section -->
      <div class="chapters-section">
        <div class="section-header">
          <span>章节</span>
          <van-icon
            :name="sortAsc ? 'ascending' : 'descending'"
            size="18"
            class="sort-icon"
            @click="toggleSort"
          />
        </div>

        <!-- Group Tabs -->
        <div v-if="groupTitles.length > 1" class="group-tabs">
          <div
            v-for="(title, idx) in groupTitles"
            :key="idx"
            class="group-tab"
            :class="{ active: activeTab === idx }"
            @click="activeTab = idx"
          >
            {{ title }}
          </div>
        </div>

        <!-- Chapter Grid -->
        <div class="chapter-grid">
          <div
            v-for="ch in activeGroupChapters"
            :key="ch.id"
            class="chapter-btn"
            :class="{
              'is-current': ch.id === (lastReadChapter?.id ?? lastReadChapterId),
              'is-read': isChapterRead(ch.id) && ch.id !== (lastReadChapter?.id ?? lastReadChapterId)
            }"
            @click="readComic(ch)"
          >
            {{ ch.title }}
          </div>
        </div>

        <div v-if="!activeGroupChapters.length" class="no-chapters">
          暂无章节
        </div>
      </div>

      <!-- Thumbnails Section -->
      <div v-if="thumbnails.length" class="thumbnails-section">
        <div class="section-header">预览</div>
        <div class="thumbnails-grid">
          <div v-for="(thumb, idx) in thumbnails" :key="idx" class="thumbnail-item">
            <ProxiedImage
              :src="thumb.url"
              :alt="`P${thumb.page}`"
              width="80px"
              height="110px"
              class="thumbnail-img"
            />
            <span class="thumbnail-label">{{ thumb.ep }} P{{ thumb.page }}</span>
          </div>
        </div>
        <div class="divider"></div>
      </div>
      <div v-else-if="thumbnailsLoading" class="thumbnails-section">
        <van-loading size="20" />
      </div>

      <!-- Comments Section -->
      <div v-if="comments.length" class="comments-section">
        <div class="section-header">评论 ({{ comments.length }})</div>
        <div class="comments-list">
          <div v-for="(comment, idx) in comments" :key="idx" class="comment-card">
            <div class="comment-avatar">
              <img v-if="comment.avatar" :src="comment.avatar" alt="" class="avatar-img" />
              <van-icon v-else name="user-circle-o" size="32" color="#ccc" />
            </div>
            <div class="comment-body">
              <div class="comment-header">
                <span class="comment-username">{{ comment.userName || '匿名' }}</span>
                <span class="comment-time">{{ comment.time || '' }}</span>
              </div>
              <div class="comment-content">{{ comment.content }}</div>
              <div v-if="comment.replyCount" class="comment-replies" @click.stop="toggleReplies(idx)">
                <van-icon name="chat-o" size="12" />
                <span>{{ comment.replyCount }} 回复</span>
                <van-icon :name="expandedReplies.has(idx) ? 'arrow-up' : 'arrow-down'" size="12" />
              </div>
              <div v-if="comment.replyCount && expandedReplies.has(idx)" class="comment-replies-placeholder">
                回复功能暂未实现
              </div>
            </div>
          </div>
        </div>
        <div v-if="commentsHasMore" class="load-more">
          <van-button
            size="small"
            :loading="commentsLoading"
            @click="loadMoreComments"
          >加载更多评论</van-button>
        </div>
        <div class="divider"></div>
      </div>

      <!-- Related/Recommended Comics -->
      <div v-if="relatedComics.length" class="related-section">
        <div class="section-header">相关推荐</div>
        <div class="related-scroll">
          <ComicCard
            v-for="rc in relatedComics"
            :key="rc.id"
            :comic="rc"
            :source-key="sourceKey"
            :source-name="sourceDisplayName"
            display-mode="brief"
            class="related-card"
          />
        </div>
      </div>
      <div v-else-if="relatedLoading" class="related-section">
        <van-loading size="20" />
      </div>
    </div>

    <!-- Favorite folder selection popup -->
    <van-popup v-model:show="showFavPopup" position="bottom" round :style="{ maxHeight: '60vh' }">
      <div class="fav-popup">
        <div class="fav-popup-title">选择收藏夹</div>
        <div class="fav-folder-list">
          <div
            v-for="folder in favFolders"
            :key="folder.id"
            class="fav-folder-item"
            @click="toggleFavInFolder(folder.id)"
          >
            <span class="fav-folder-name">{{ folder.name }}</span>
            <van-icon
              :name="favFolderStatus[folder.id] ? 'success' : ''"
              :color="favFolderStatus[folder.id] ? '#4f6ef7' : 'transparent'"
              size="18"
            />
          </div>
          <div v-if="!favFolders.length" class="fav-folder-empty">暂无收藏夹，请先创建</div>
        </div>
        <div class="fav-popup-actions">
          <van-button size="small" plain block @click="createFavAndAdd">新建收藏夹并收藏</van-button>
        </div>
      </div>
    </van-popup>

    <!-- Related Sources Dialog -->
    <RelatedSourcesDialog
      v-model:show="showRelatedDialog"
      :source-key="sourceKey"
      :comic-id="comicId"
      :comic-title="comic?.title || ''"
    />

    <!-- Source Migration Dialog -->
    <SourceMigrationDialog
      v-model:show="showMigrationDialog"
      mode="single"
      :comic="comic ? { id: comicId, name: comic.title || '', type: sourceTypeFromKey(sourceKey), sourceKey } : undefined"
    />
  </div>
</template>
<style scoped>
.comic-detail-page {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #fff;
}

/* Top Bar */
.top-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 16px;
  position: sticky;
  top: 0;
  background: #fff;
  z-index: 10;
}
.top-bar-btn {
  width: 36px;
  height: 36px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  border-radius: 50%;
}
.top-bar-btn:active {
  background: #f0f0f0;
}

/* Content */
.content {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px 16px;
}
.error-content {
  display: flex;
  align-items: center;
  justify-content: center;
}
.detail-notice {
  margin: 0 0 12px;
  padding: 10px 12px;
  border-radius: 6px;
  background: #fff7e6;
  color: #8a5a00;
  font-size: 13px;
  line-height: 1.45;
}

/* Header Section */
.header-section {
  display: flex;
  gap: 14px;
  margin-bottom: 16px;
}
.cover-image {
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
}
.meta-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.comic-title {
  font-size: 18px;
  font-weight: 700;
  margin: 0;
  line-height: 1.3;
  color: #1a1a1a;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
/* Capsule tag rows (matches APP ComicDescription) */
.capsule-rows {
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.capsule-row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.capsule-label {
  flex-shrink: 0;
  height: 18px;
  padding: 0 6px;
  border-radius: 10px;
  font-size: 11px;
  font-weight: 600;
  line-height: 18px;
  white-space: nowrap;
}
.capsule-value {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  line-height: 18px;
  color: #555;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.capsule-values {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  line-height: 18px;
  color: #555;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.capsule-link {
  color: #4f6ef7;
  cursor: pointer;
}
.capsule-link:hover {
  text-decoration: underline;
}
.capsule-sep {
  color: #999;
  margin: 0 2px;
}
.meta-stars {
  margin-top: 2px;
}

/* Action Buttons */
.action-buttons {
  display: flex;
  gap: 8px;
  margin-bottom: 14px;
  overflow-x: auto;
  padding: 4px 0;
}
.desktop-actions {
  flex-wrap: nowrap;
}
.action-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  min-width: 64px;
  padding: 10px 12px;
  border: 1px solid #e0e0e0;
  border-radius: 8px;
  background: #fff;
  cursor: pointer;
  font-size: 12px;
  color: #333;
  transition: background 0.15s;
  flex-shrink: 0;
}
.action-btn:active {
  background: #f5f5f5;
}
.action-btn.active {
  border-color: #4f6ef7;
}
.action-icon {
  font-size: 20px;
}
.icon-red { color: #e74c3c; }

/* Mobile Actions */
.mobile-actions {
  margin-bottom: 14px;
}
.mobile-action-row {
  display: flex;
  gap: 8px;
  overflow-x: auto;
  padding: 4px 0;
  margin-bottom: 10px;
}
.mobile-action-row .action-btn.compact {
  min-width: 52px;
  padding: 8px 10px;
  gap: 3px;
}
.mobile-action-row .action-icon {
  font-size: 18px;
}
.mobile-full-row {
  display: flex;
  justify-content: center;
  gap: 8px;
}
.continue-btn {
  width: 100%;
  display: inline-flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 12px 24px;
  font-size: 14px;
  font-weight: 500;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  transition: opacity 0.15s;
}
.continue-btn:active { opacity: 0.85; }

/* Last Read Pill */
.last-read-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  background: #f5f5f5;
  border-radius: 20px;
  padding: 6px 14px;
  font-size: 13px;
  color: #666;
  margin-bottom: 16px;
}

/* Description */
.desc-section {
  margin-bottom: 8px;
}
.section-header {
  font-size: 16px;
  font-weight: 500;
  color: #1a1a1a;
  margin-bottom: 8px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.desc-text {
  font-size: 14px;
  line-height: 1.6;
  color: #333;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  white-space: pre-wrap;
}
.desc-text.expanded {
  -webkit-line-clamp: unset;
  display: block;
}
.expand-btn {
  font-size: 13px;
  color: #4f6ef7;
  cursor: pointer;
  margin-top: 4px;
  display: inline-block;
}
.divider {
  height: 1px;
  background: #f0f0f0;
  margin-top: 12px;
}

/* Chapters */
.chapters-section {
  margin-top: 8px;
}
.sort-icon {
  cursor: pointer;
  color: #666;
}
.sort-icon:hover {
  color: #4f6ef7;
}
.group-tabs {
  display: flex;
  gap: 0;
  border-bottom: 1px solid #f0f0f0;
  margin-bottom: 12px;
  overflow-x: auto;
}
.group-tab {
  padding: 8px 16px;
  font-size: 14px;
  color: #666;
  cursor: pointer;
  white-space: nowrap;
  border-bottom: 2px solid transparent;
  transition: color 0.2s, border-color 0.2s;
}
.group-tab.active {
  color: #4f6ef7;
  border-bottom-color: #4f6ef7;
}
.chapter-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
  gap: 8px;
}
.chapter-btn {
  background: #f5f5f5;
  border-radius: 8px;
  padding: 10px 12px;
  font-size: 13px;
  color: #333;
  text-align: center;
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  transition: background 0.15s;
}
.chapter-btn:hover {
  background: #ebebeb;
}
.chapter-btn.is-current {
  background: #e8f0fe;
  color: #4f6ef7;
  font-weight: 600;
  border-left: 3px solid #4f6ef7;
}
.chapter-btn.is-read {
  color: #999;
  background: #fafafa;
}
.no-chapters {
  text-align: center;
  color: #666;
  padding: 32px 0;
  font-size: 14px;
}

/* Thumbnails */
.thumbnails-section {
  margin-top: 16px;
}
.thumbnails-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(80px, 1fr));
  gap: 8px;
}
.thumbnail-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}
.thumbnail-img {
  border-radius: 4px;
  overflow: hidden;
}
.thumbnail-label {
  font-size: 11px;
  color: #999;
  text-align: center;
}

/* Comments */
.comments-section {
  margin-top: 16px;
}
.comments-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.comment-card {
  display: flex;
  gap: 10px;
  padding: 12px;
  background: #fafafa;
  border-radius: 8px;
}
.comment-avatar {
  flex-shrink: 0;
  width: 32px;
  height: 32px;
  border-radius: 50%;
  overflow: hidden;
}
.avatar-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.comment-body {
  flex: 1;
  min-width: 0;
}
.comment-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 4px;
}
.comment-username {
  font-size: 13px;
  font-weight: 500;
  color: #333;
}
.comment-time {
  font-size: 12px;
  color: #999;
}
.comment-content {
  font-size: 14px;
  line-height: 1.5;
  color: #333;
  word-break: break-word;
}
.comment-replies {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 6px;
  font-size: 12px;
  color: #4f6ef7;
  cursor: pointer;
  user-select: none;
}
.comment-replies:hover {
  opacity: 0.8;
}
.comment-replies-placeholder {
  margin-top: 8px;
  margin-left: 0;
  padding: 10px 12px;
  background: #f5f5f5;
  border-radius: 6px;
  font-size: 13px;
  color: #999;
  text-align: center;
}
.load-more {
  text-align: center;
  margin-top: 12px;
}

/* Related Comics */
.related-section {
  margin-top: 16px;
  padding-bottom: 16px;
}
.related-scroll {
  display: flex;
  gap: 12px;
  overflow-x: auto;
  padding: 4px 0;
}
.related-card {
  flex-shrink: 0;
  width: 100px;
  cursor: pointer;
}
.related-cover {
  border-radius: 4px;
  overflow: hidden;
}
.related-title {
  font-size: 12px;
  color: #333;
  margin-top: 6px;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  line-height: 1.3;
}
.related-subtitle {
  font-size: 11px;
  color: #999;
  margin-top: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Favorite folder popup */
.fav-popup {
  padding: 16px;
}
.fav-popup-title {
  font-size: 16px;
  font-weight: 600;
  color: #1a1a1a;
  margin-bottom: 12px;
}
.fav-folder-list {
  max-height: 40vh;
  overflow-y: auto;
  margin-bottom: 12px;
}
.fav-folder-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 8px;
  border-bottom: 0.5px solid #f0f0f0;
  cursor: pointer;
  transition: background 0.15s;
}
.fav-folder-item:active { background: #f5f5f5; }
.fav-folder-name {
  font-size: 14px;
  color: #333;
}
.fav-folder-empty {
  text-align: center;
  color: #999;
  padding: 24px 0;
  font-size: 14px;
}
.fav-popup-actions {
  padding: 8px 0;
  padding-bottom: calc(8px + env(safe-area-inset-bottom, 0px));
}
</style>
