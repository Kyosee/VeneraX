<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { apiPost, imageProxyUrl } from '@/services/api'
import { upsertHistory, listHistory, markAsRead } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import { sourceTypeFromKey } from '@/utils/source'
import type { Chapter, ChapterGroup } from '@/types'
import { showToast } from 'vant'

const route = useRoute()
const router = useRouter()
const settingsStore = useSettingsStore()
const sourceKey = computed(() => route.params.sourceKey as string)
const comicId = computed(() => route.params.id as string)

const images = ref<string[]>([])
const imageAspects = ref<Record<number, string>>({})
const loading = ref(true)
const error = ref('')
const currentPage = ref(0)
const chapterBoundaries = ref<Array<{ chapterId: string; startIndex: number; length: number }>>([])
const showToolbar = ref(false)
const showSettings = ref(false)
const showChapterPicker = ref(false)
const chapterIndex = ref(0)
const currentChapterId = ref('')
const chapterTitle = ref('')
const comicTitle = ref('')
const comicCover = ref('')
const continuousEl = ref<HTMLElement | null>(null)
const chapters = ref<Chapter[] | ChapterGroup[]>([])

type ReadingMode = 'galleryLeftToRight' | 'galleryRightToLeft' | 'galleryTopToBottom'
  | 'continuousTopToBottom' | 'continuousLeftToRight' | 'continuousRightToLeft'
const readingMode = ref<ReadingMode>('galleryLeftToRight')
const tapToTurnPages = ref(true)
const reverseTapToTurnPages = ref(false)
const pageAnimation = ref(true)
const continuousChapter = ref(true)
const showSingleImageOnFirstPage = ref(false)
const longPressZoomPos = ref<'press' | 'center'>('press')
const quickFavImage = ref('No')
const preloadCount = ref(4)
const scrollSpeed = ref(1)
const readerScreenPicNumberForLandscape = ref(1)
const readerScreenPicNumberForPortrait = ref(1)
const isLandscape = ref(window.innerWidth > window.innerHeight)
const showTimeAndBattery = ref(true)
const showStatusBar = ref(false)
const showChapterComments = ref(true)
const showChapterCommentsAtEnd = ref(false)
const volumeKeyTurn = ref(true)
const doubleTapZoom = ref(true)
const longPressZoom = ref(true)
const limitImageWidth = ref(true)
const showPageNum = ref(true)

const touchStartX = ref(0)
const touchStartY = ref(0)
const translateX = ref(0)
const isSwiping = ref(false)
let saveTimer: ReturnType<typeof setTimeout> | null = null
let lastSavedPage = -1
const readEpisodes = ref<Set<string>>(new Set())

// Auto page turning
const autoPageEnabled = ref(false)
const autoPageInterval = ref(4)
const autoPageCountdown = ref(0)
let countdownTimer: ReturnType<typeof setInterval> | null = null

// Double-tap zoom
const isZoomed = ref(false)
const zoomScale = ref(1)
const zoomOriginX = ref(50)
const zoomOriginY = ref(50)
let lastTapTime = 0
let lastTapX = 0
let lastTapY = 0

// Long-press
const showImageActions = ref(false)
const longPressImageIndex = ref(-1)
let longPressTimer: ReturnType<typeof setTimeout> | null = null
let longPressTriggered = false

// Continuous mode page indicator
const showPageIndicator = ref(false)
let pageIndicatorTimer: ReturnType<typeof setTimeout> | null = null
let applyingSettings = false

// Fullscreen
const isFullscreen = ref(false)

const totalPages = computed(() => isGallery.value ? groupedPages.value.length : images.value.length)
const isGallery = computed(() => readingMode.value.startsWith('gallery'))
const isContinuous = computed(() => readingMode.value.startsWith('continuous'))
const currentChapterBoundary = computed(() => {
  const bounds = chapterBoundaries.value
  if (!bounds.length) return { startIndex: 0, length: totalPages.value }
  const p = currentPage.value
  // Find the boundary whose range includes currentPage
  for (const b of bounds) {
    if (p >= b.startIndex && p < b.startIndex + b.length) return b
  }
  return bounds[bounds.length - 1] // fallback to last
})
const currentChapterPage = computed(() => isGallery.value ? currentGroupIndex.value : currentPage.value - currentChapterBoundary.value.startIndex)
const currentChapterPageCount = computed(() => isGallery.value ? groupedPages.value.length : currentChapterBoundary.value.length)
const isRTL = computed(() => readingMode.value.includes('RightToLeft'))
const isVerticalMode = computed(() => readingMode.value.includes('TopToBottom'))
const isContinuousHorizontal = computed(() => isContinuous.value && !isVerticalMode.value)

const nPerScreen = computed(() => {
  const n = isLandscape.value
    ? readerScreenPicNumberForLandscape.value
    : readerScreenPicNumberForPortrait.value
  return Math.max(1, n)
})

const groupedPages = computed(() => {
  const n = nPerScreen.value
  const groups: number[][] = []
  let i = 0
  while (i < images.value.length) {
    const isFirst = groups.length === 0
    const count = (isFirst && showSingleImageOnFirstPage.value) ? 1 : n
    const g: number[] = []
    for (let j = 0; j < count && i < images.value.length; j++, i++) {
      g.push(i)
    }
    groups.push(g)
  }
  return groups
})

const currentGroupIndex = computed(() => {
  if (!isGallery.value) return currentPage.value
  if (!groupedPages.value.length) return 0
  let offset = 0
  for (let gi = 0; gi < groupedPages.value.length; gi++) {
    if (currentPage.value < offset + groupedPages.value[gi].length) return gi
    offset += groupedPages.value[gi].length
  }
  return Math.max(0, groupedPages.value.length - 1)
})

const currentGroup = computed(() => groupedPages.value[currentGroupIndex.value] ?? [])
const pageDisplay = computed(() => {
  if (!totalPages.value) return ''
  const p = isGallery.value ? currentGroupIndex.value + 1 : currentPage.value + 1
  return `E${chapterIndex.value + 1} : P${p}`
})
const showPageNumber = computed(() => showPageNum.value)
const canDoubleTapZoom = computed(() => doubleTapZoom.value)
const canLongPressZoom = computed(() => longPressZoom.value)
const limitContinuousImageWidth = computed(() => limitImageWidth.value)
const sliderVal = ref(1)

// Keep slider in sync with currentPage (chapter-relative)
watch([currentPage, currentChapterBoundary], () => {
  sliderVal.value = currentChapterPage.value + 1
})
function onSliderChange(v: number) {
  if (isGallery.value) {
    const gi = Math.max(0, Math.min(v - 1, groupedPages.value.length - 1))
    currentPage.value = groupedPages.value[gi]?.[0] ?? currentPage.value
  } else {
    const globalPage = currentChapterBoundary.value.startIndex + Math.max(0, Math.min(v - 1, currentChapterPageCount.value - 1))
    currentPage.value = globalPage
    if (continuousEl.value) {
      const els = continuousEl.value.querySelectorAll('.img-placeholder')
      if (els[globalPage]) els[globalPage].scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'start' })
    }
  }
}


const isGrouped = computed(() => {
  if (!chapters.value.length) return false
  return 'chapters' in chapters.value[0]
})
const flatChapters = computed(() => {
  if (!chapters.value.length) return [] as Array<Chapter & { groupIndex: number; chapterIndex: number; groupTitle: string }>
  if (!isGrouped.value) {
    return (chapters.value as Chapter[]).map((chapter, index) => ({
      ...chapter,
      groupIndex: 0,
      chapterIndex: index,
      groupTitle: '默认',
    }))
  }
  return (chapters.value as ChapterGroup[]).flatMap((group, groupIndex) =>
    (group.chapters ?? []).map((chapter, chapterIndex) => ({
      ...chapter,
      groupIndex,
      chapterIndex,
      groupTitle: group.title,
    }))
  )
})
const currentChapter = computed(() =>
  flatChapters.value.find(chapter => chapter.id === currentChapterId.value)
)

const autoPageProgress = computed(() => {
  if (!autoPageEnabled.value || autoPageCountdown.value <= 0) return 0
  return ((autoPageInterval.value - autoPageCountdown.value) / autoPageInterval.value) * 100
})

async function fetchPages() {
  loading.value = true; error.value = ''
  try {
    const ep = route.query.ep?.toString() || flatChapters.value[0]?.id || '0'
    currentChapterId.value = ep
    const listIndex = flatChapters.value.findIndex(chapter => chapter.id === ep)
    chapterIndex.value = listIndex >= 0 ? listIndex : Math.max(0, Number.parseInt(ep, 10) || 0)
    const res = await apiPost<any>('/api/server-db/reader/pages', {
      sourceKey: sourceKey.value, comicId: comicId.value, chapterId: ep
    })
    if (res.ok && res.data) {
      images.value = res.data
      imageAspects.value = {}
      chapterBoundaries.value = [{ chapterId: ep, startIndex: 0, length: res.data.length }]
      chapterTitle.value = res.title || currentChapter.value?.title || `E${chapterIndex.value + 1}`
      comicTitle.value = res.comicTitle || comicTitle.value || route.query.title?.toString() || ''
      const page = Math.max(1, Number.parseInt(route.query.page?.toString() || '1', 10) || 1)
      currentPage.value = Math.min(page - 1, Math.max(0, images.value.length - 1))
    } else { throw new Error('Failed to load pages') }
  } catch (e: any) { error.value = e.message || 'Load failed' }
  finally { loading.value = false }
}

async function fetchChapters() {
  try {
    const res = await apiPost<any>('/api/server-db/comic/detail', {
      sourceKey: sourceKey.value,
      comicId: comicId.value,
    })
    chapters.value = res?.chapters || []
    comicTitle.value = res?.comic?.title || route.query.title?.toString() || comicTitle.value
    comicCover.value = res?.comic?.cover || route.query.cover?.toString() || comicCover.value
  } catch {
    comicTitle.value = route.query.title?.toString() || comicTitle.value
    comicCover.value = route.query.cover?.toString() || comicCover.value
  }
}

function buildReadEpisodeId(): string | null {
  if (!currentChapterId.value) return null
  const ch = currentChapter.value
  if (ch && isGrouped.value) {
    // Flutter-compatible format: "group-chapter" (both 1-based)
    return `${ch.groupIndex + 1}-${ch.chapterIndex + 1}`
  }
  // Non-grouped: 1-based flat index
  const flatIdx = flatChapters.value.findIndex(c => c.id === currentChapterId.value)
  return flatIdx >= 0 ? String(flatIdx + 1) : currentChapterId.value
}

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    if (currentPage.value !== lastSavedPage) {
      lastSavedPage = currentPage.value
      // Accumulate read episode in Flutter-compatible positional format
      const epId = buildReadEpisodeId()
      if (epId) readEpisodes.value.add(epId)
      upsertHistory({
        id: comicId.value,
        type: sourceTypeFromKey(sourceKey.value),
        sourceKey: sourceKey.value,
        title: comicTitle.value,
        cover: comicCover.value,
        time: Date.now(),
        ep: chapterIndex.value + 1,
        page: currentPage.value + 1,
        readEpisode: [...readEpisodes.value],
        maxPage: totalPages.value,
        max_page: totalPages.value,
        group: currentChapter.value ? currentChapter.value.groupIndex + 1 : null,
        chapter_group: currentChapter.value ? currentChapter.value.groupIndex + 1 : null,
      }).catch(() => {})
    }
  }, 1000)
}

function goPage(p: number) {
  if (p >= 0 && p < totalPages.value) {
    currentPage.value = p
  } else if (p >= totalPages.value && continuousChapter.value) {
    // End of chapter - auto load next chapter
    goChapterByOffset(1)
  } else if (p < 0 && continuousChapter.value) {
    // Before first page - auto load previous chapter
    goChapterByOffset(-1)
  }
}
function nextPage() {
  if (!isGallery.value) { isRTL.value ? goPage(currentPage.value - 1) : goPage(currentPage.value + 1); return }
  const ci = currentGroupIndex.value
  const gp = groupedPages.value
  if (isRTL.value) {
    if (ci > 0) { currentPage.value = gp[ci - 1][0] }
    else if (continuousChapter.value) { goChapterByOffset(1) }
  } else {
    if (ci < gp.length - 1) { currentPage.value = gp[ci + 1][0] }
    else if (continuousChapter.value) { goChapterByOffset(1) }
  }
}
function prevPage() {
  if (!isGallery.value) { isRTL.value ? goPage(currentPage.value + 1) : goPage(currentPage.value - 1); return }
  const ci = currentGroupIndex.value
  const gp = groupedPages.value
  if (isRTL.value) {
    if (ci < gp.length - 1) { currentPage.value = gp[ci + 1][0] }
    else if (continuousChapter.value) { goChapterByOffset(-1) }
  } else {
    if (ci > 0) { currentPage.value = gp[ci - 1][0] }
    else if (continuousChapter.value) { goChapterByOffset(-1) }
  }
}
function goFirst() {
  if (isGallery.value) {
    currentPage.value = groupedPages.value[0]?.[0] ?? 0
  } else {
    currentPage.value = currentChapterBoundary.value.startIndex
    if (continuousEl.value) {
      const els = continuousEl.value.querySelectorAll('.img-placeholder')
      if (els[currentPage.value]) els[currentPage.value].scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'start' })
    }
  }
}
function goLast() {
  if (isGallery.value) {
    const last = groupedPages.value[groupedPages.value.length - 1]
    currentPage.value = last?.[0] ?? 0
  } else {
    currentPage.value = Math.max(0, currentChapterBoundary.value.startIndex + currentChapterPageCount.value - 1)
    if (continuousEl.value) {
      const els = continuousEl.value.querySelectorAll('.img-placeholder')
      if (els[currentPage.value]) els[currentPage.value].scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'start' })
    }
  }
}
function goChapterByOffset(offset: number) {
  const list = flatChapters.value
  const current = list.findIndex(chapter => chapter.id === currentChapterId.value)
  const fallback = current >= 0 ? current : chapterIndex.value
  const next = fallback + offset
  if (next < 0 || next >= list.length) {
    showToast(offset > 0 ? '已经是最后一话' : '已经是第一话')
    return
  }
  selectChapter(list[next].id)
}
function nextChapter() { goChapterByOffset(1) }
function prevChapter() { goChapterByOffset(-1) }
function selectChapter(id: string) {
  showChapterPicker.value = false
  router.replace({ path: route.path, query: { ...route.query, ep: id, page: '1' } })
}
function onBack() { router.back() }

function normalizeReadingMode(value: string): ReadingMode {
  const modes: ReadingMode[] = [
    'galleryLeftToRight',
    'galleryRightToLeft',
    'galleryTopToBottom',
    'continuousTopToBottom',
    'continuousLeftToRight',
    'continuousRightToLeft',
  ]
  return modes.includes(value as ReadingMode) ? value as ReadingMode : 'galleryLeftToRight'
}

function applyReaderSettings() {
  applyingSettings = true
  const s = settingsStore.settings
  readingMode.value = normalizeReadingMode(s.readingMode)
  tapToTurnPages.value = s.tapToTurn
  reverseTapToTurnPages.value = s.reverseTap
  autoPageEnabled.value = s.autoPageEnabled
  autoPageInterval.value = s.autoPageInterval
  pageAnimation.value = s.pageAnimation
  continuousChapter.value = s.continuousChapter
  showSingleImageOnFirstPage.value = s.showSingleImageOnFirstPage
  doubleTapZoom.value = s.doubleTapZoom
  longPressZoom.value = s.longPressZoom
  longPressZoomPos.value = (s.longPressZoomPos as any) || 'press'
  limitImageWidth.value = s.limitImageWidth
  quickFavImage.value = s.quickFavImage
  preloadCount.value = s.preloadCount
  scrollSpeed.value = s.scrollSpeed
  readerScreenPicNumberForLandscape.value = s.readerScreenPicNumberForLandscape
  readerScreenPicNumberForPortrait.value = s.readerScreenPicNumberForPortrait
  showTimeAndBattery.value = s.showTimeAndBattery
  showStatusBar.value = s.showStatusBar
  showPageNum.value = s.showPageNum
  showChapterComments.value = s.showChapterComments
  showChapterCommentsAtEnd.value = s.showChapterCommentsAtEnd
  nextTick(() => { applyingSettings = false })
}

// Auto page turning
function startAutoPage() {
  stopAutoPage()
  if (!isGallery.value) return
  autoPageCountdown.value = autoPageInterval.value
  countdownTimer = setInterval(() => {
    if (showToolbar.value) return // pause when toolbar shown
    autoPageCountdown.value -= 0.1
    if (autoPageCountdown.value <= 0) {
      autoPageCountdown.value = autoPageInterval.value
      if (currentGroupIndex.value < totalPages.value - 1) nextPage()
      else stopAutoPage()
    }
  }, 100)
}
function stopAutoPage() {
  if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null }
  autoPageCountdown.value = 0
}

// Fullscreen
function toggleFullscreen() {
  if (document.fullscreenElement) {
    document.exitFullscreen?.()
  } else {
    document.documentElement.requestFullscreen?.()
  }
}
function onFullscreenChange() {
  isFullscreen.value = !!document.fullscreenElement
}

// Double-tap zoom
function handleDoubleTap(x: number, y: number, rect: DOMRect) {
  if (!isGallery.value || !canDoubleTapZoom.value) return
  if (isZoomed.value) {
    isZoomed.value = false
    zoomScale.value = 1
  } else {
    const px = ((x - rect.left) / rect.width) * 100
    const py = ((y - rect.top) / rect.height) * 100
    zoomOriginX.value = px
    zoomOriginY.value = py
    zoomScale.value = 2
    isZoomed.value = true
  }
}

// Image placeholder aspect ratio tracking
function onImageLoad(e: Event, index: number) {
  const img = e.target as HTMLImageElement
  if (img.naturalWidth && img.naturalHeight) {
    imageAspects.value[index] = `${img.naturalWidth}/${img.naturalHeight}`
  }
}

// Long-press image actions
function onImagePointerDown(e: PointerEvent, imgIdx?: number) {
  if (imgIdx !== undefined) longPressImageIndex.value = imgIdx
  if (!canLongPressZoom.value) return
  longPressTriggered = false
  longPressTimer = setTimeout(() => {
    longPressTriggered = true
    showImageActions.value = true
  }, 600)
}
function onImagePointerUp() {
  if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null }
}
function onImagePointerCancel() {
  if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null }
}

async function saveImage() {
  showImageActions.value = false
  const imgIdx = isGallery.value && longPressImageIndex.value >= 0 ? longPressImageIndex.value : currentPage.value
  const url = imageProxyUrl(images.value[imgIdx])
  try {
    const resp = await fetch(url)
    const blob = await resp.blob()
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `page_${imgIdx + 1}.jpg`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(a.href)
  } catch { /* silent fail */ }
}

async function copyImage() {
  showImageActions.value = false
  const imgIdx = isGallery.value && longPressImageIndex.value >= 0 ? longPressImageIndex.value : currentPage.value
  const url = imageProxyUrl(images.value[imgIdx])
  try {
    const resp = await fetch(url)
    const blob = await resp.blob()
    const pngBlob = blob.type === 'image/png' ? blob : await convertToPng(blob)
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': pngBlob })])
  } catch { /* silent fail */ }
}

function convertToPng(blob: Blob): Promise<Blob> {
  return new Promise((resolve) => {
    const img = new Image()
    img.onload = () => {
      const canvas = document.createElement('canvas')
      canvas.width = img.width; canvas.height = img.height
      canvas.getContext('2d')!.drawImage(img, 0, 0)
      canvas.toBlob((b) => resolve(b!), 'image/png')
    }
    img.src = URL.createObjectURL(blob)
  })
}

function handleTap(e: MouseEvent | TouchEvent) {
  if (longPressTriggered) { longPressTriggered = false; return }
  const t = e.target as HTMLElement
  if (t.closest('.toolbar-top') || t.closest('.toolbar-bottom')) return
  const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
  const cx = 'touches' in e ? e.changedTouches[0].clientX : e.clientX
  const cy = 'touches' in e ? e.changedTouches[0].clientY : e.clientY
  const xr = (cx - rect.left) / rect.width
  const yr = (cy - rect.top) / rect.height

  // Double-tap detection
  const now = Date.now()
  if (canDoubleTapZoom.value && isGallery.value && now - lastTapTime < 300 && Math.abs(cx - lastTapX) < 30 && Math.abs(cy - lastTapY) < 30) {
    handleDoubleTap(cx, cy, rect)
    lastTapTime = 0
    return
  }
  lastTapTime = now; lastTapX = cx; lastTapY = cy

  if (isZoomed.value) return // don't navigate when zoomed

  const position = isVerticalMode.value ? yr : xr
  if (position > 0.3 && position < 0.7) { showToolbar.value = !showToolbar.value }
  else if (isGallery.value && tapToTurnPages.value && !showToolbar.value) {
    const forward = reverseTapToTurnPages.value ? position <= 0.3 : position > 0.7
    if (forward) nextPage(); else prevPage()
  }
}

function onTouchStart(e: TouchEvent) {
  if (!isGallery.value || showToolbar.value) return
  touchStartX.value = e.touches[0].clientX; touchStartY.value = e.touches[0].clientY
  isSwiping.value = true; translateX.value = 0
}
function onTouchMove(e: TouchEvent) {
  if (!isSwiping.value || !isGallery.value) return
  const dx = e.touches[0].clientX - touchStartX.value
  if (Math.abs(e.touches[0].clientY - touchStartY.value) > Math.abs(dx)) { isSwiping.value = false; return }
  translateX.value = dx
}
function onTouchEnd() {
  if (!isSwiping.value) return; isSwiping.value = false
  if (translateX.value < -60) { isRTL.value ? prevPage() : nextPage() }
  else if (translateX.value > 60) { isRTL.value ? nextPage() : prevPage() }
  translateX.value = 0
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'ArrowRight') nextPage()
  else if (e.key === 'ArrowLeft') prevPage()
  else if (e.key === 'Escape') onBack()
  else if (e.key === 'F11') { e.preventDefault(); toggleFullscreen() }
}

function onResize() {
  isLandscape.value = window.innerWidth > window.innerHeight
}

function preloadImages() {
  const count = Math.max(0, Number(settingsStore.settings.preloadCount) || 0)
  if (isGallery.value) {
    let loaded = 0
    for (let gi = currentGroupIndex.value + 1; gi < groupedPages.value.length && loaded < count; gi++) {
      for (const idx of groupedPages.value[gi]) {
        if (loaded >= count) break
        const img = new Image(); img.src = imageProxyUrl(images.value[idx])
        loaded++
      }
    }
  } else {
    for (let i = currentPage.value + 1; i < Math.min(currentPage.value + count + 1, totalPages.value); i++) {
      const img = new Image(); img.src = imageProxyUrl(images.value[i])
    }
  }
}

// Loading next/prev chapter in continuous mode
const loadingNextChapter = ref(false)
const loadingPrevChapter = ref(false)

function onScroll() {
  if (!continuousEl.value || !isContinuous.value) return
  const el = continuousEl.value
  const imgs = el.querySelectorAll('.img-placeholder')
  const mid = isContinuousHorizontal.value
    ? el.scrollLeft + el.clientWidth / 2
    : el.scrollTop + el.clientHeight / 2
  let p = 0
  for (let i = 0; i < imgs.length; i++) {
    const img = imgs[i] as HTMLElement
    const center = isContinuousHorizontal.value
      ? img.offsetLeft + img.offsetWidth / 2
      : img.offsetTop + img.offsetHeight / 2
    if (center > mid) break
    p = i
  }
  if (p !== currentPage.value) currentPage.value = p
  // Show page indicator on scroll
  showPageIndicator.value = true
  if (pageIndicatorTimer) clearTimeout(pageIndicatorTimer)
  pageIndicatorTimer = setTimeout(() => { showPageIndicator.value = false }, 2000)

  if (!continuousChapter.value) return
  const pCount = Math.max(1, Number(preloadCount.value) || 4)

  // Preload next chapter when within preloadCount pages of the end
  if (!loadingNextChapter.value && currentPage.value >= totalPages.value - pCount - 1) {
    loadNextChapterContinuous()
  }

  // Load previous chapter when near the top
  if (!loadingPrevChapter.value) {
    const nearStart = isContinuousHorizontal.value
      ? el.scrollLeft < 200
      : el.scrollTop < 200
    if (nearStart && currentPage.value <= pCount) {
      loadPrevChapterContinuous()
    }
  }
}

async function loadNextChapterContinuous() {
  const list = flatChapters.value
  const current = list.findIndex(ch => ch.id === currentChapterId.value)
  const fallback = current >= 0 ? current : chapterIndex.value
  const next = fallback + 1
  if (next >= list.length) {
    showToast('已经是最后一话')
    return
  }
  loadingNextChapter.value = true
  try {
    const nextCh = list[next]
    const res = await apiPost<any>('/api/server-db/reader/pages', {
      sourceKey: sourceKey.value, comicId: comicId.value, chapterId: nextCh.id
    })
    if (res.ok && res.data && res.data.length > 0) {
      const prevLen = images.value.length
      images.value = [...images.value, ...res.data]
      chapterBoundaries.value = [...chapterBoundaries.value, { chapterId: nextCh.id, startIndex: prevLen, length: res.data.length }]
      currentChapterId.value = nextCh.id
      chapterIndex.value = next
      chapterTitle.value = res.title || nextCh.title || `E${next + 1}`
    }
  } catch { /* silent */ }
  finally { loadingNextChapter.value = false }
}

async function loadPrevChapterContinuous() {
  const list = flatChapters.value
  const current = list.findIndex(ch => ch.id === currentChapterId.value)
  const fallback = current >= 0 ? current : chapterIndex.value
  const prev = fallback - 1
  if (prev < 0) return
  loadingPrevChapter.value = true
  try {
    const prevCh = list[prev]
    const res = await apiPost<any>('/api/server-db/reader/pages', {
      sourceKey: sourceKey.value, comicId: comicId.value, chapterId: prevCh.id
    })
    if (res.ok && res.data && res.data.length > 0) {
      const prevCount = res.data.length
      images.value = [...res.data, ...images.value]
      // Shift existing aspect ratios by prevCount
      const shifted: Record<number, string> = {}
      for (const [k, v] of Object.entries(imageAspects.value)) {
        shifted[Number(k) + prevCount] = v
      }
      imageAspects.value = shifted
      currentPage.value += prevCount
      chapterBoundaries.value = [
        { chapterId: prevCh.id, startIndex: 0, length: prevCount },
        ...chapterBoundaries.value.map(b => ({ ...b, startIndex: b.startIndex + prevCount })),
      ]
      await nextTick()
      // Maintain scroll position after prepending
      if (continuousEl.value) {
        const els = continuousEl.value.querySelectorAll('.img-placeholder')
        if (els[currentPage.value]) {
          els[currentPage.value].scrollIntoView({ block: 'start', inline: 'start' })
        }
      }
    }
  } catch { /* silent */ }
  finally { loadingPrevChapter.value = false }
}

watch(currentPage, () => {
  scheduleSave(); preloadImages()
  // Reset zoom on page change
  if (isZoomed.value) { isZoomed.value = false; zoomScale.value = 1 }
})
watch(() => route.query.ep, () => { fetchPages() })
watch(readingMode, () => {
  if (isContinuous.value) nextTick(() => {
    const els = continuousEl.value?.querySelectorAll('.img-placeholder')
    if (els?.[currentPage.value]) els[currentPage.value].scrollIntoView()
  })
  // Stop auto page if switching to continuous
  if (isContinuous.value && autoPageEnabled.value) {
    autoPageEnabled.value = false; stopAutoPage()
  }
})
watch(autoPageEnabled, (v) => { v && isGallery.value ? startAutoPage() : stopAutoPage() })
watch(autoPageInterval, () => { if (autoPageEnabled.value) startAutoPage() })
watch([readingMode, tapToTurnPages, reverseTapToTurnPages, autoPageInterval, pageAnimation, continuousChapter], () => {
  if (applyingSettings) return
  settingsStore.update('readingMode', readingMode.value)
  settingsStore.update('tapToTurn', tapToTurnPages.value)
  settingsStore.update('reverseTap', reverseTapToTurnPages.value)
  settingsStore.update('autoPageInterval', autoPageInterval.value)
  settingsStore.update('pageAnimation', pageAnimation.value)
  settingsStore.update('continuousChapter', continuousChapter.value)
})

onMounted(async () => {
  await settingsStore.loadSettings()
  applyReaderSettings()
  await fetchChapters()
  await fetchPages()
  // Mark comic as read in follow-updates folder so it disappears from update list
  const followFolder = settingsStore.settings.followUpdatesFolder
  if (followFolder) {
    markAsRead(followFolder, comicId.value, sourceTypeFromKey(sourceKey.value)).catch(() => {})
  }
  // Load existing read episodes from history to accumulate
  try {
    const history = await listHistory(1000)
    const type = sourceTypeFromKey(sourceKey.value)
    const entry = history.items.find(h => h.id === comicId.value && h.type === type)
    if (entry?.readEpisode) {
      const episodes = Array.isArray(entry.readEpisode)
        ? entry.readEpisode : String(entry.readEpisode).split(',').filter(Boolean)
      for (const ep of episodes) readEpisodes.value.add(ep)
    }
  } catch { /* ignore */ }
  document.addEventListener('keydown', onKeydown)
  document.addEventListener('fullscreenchange', onFullscreenChange)
  window.addEventListener('resize', onResize)
})
onUnmounted(() => {
  document.removeEventListener('keydown', onKeydown)
  document.removeEventListener('fullscreenchange', onFullscreenChange)
  window.removeEventListener('resize', onResize)
  if (saveTimer) clearTimeout(saveTimer)
  stopAutoPage()
  if (longPressTimer) clearTimeout(longPressTimer)
  if (pageIndicatorTimer) clearTimeout(pageIndicatorTimer)
})
</script>

<template>
  <div class="reader" @click="handleTap" @touchstart="onTouchStart" @touchmove.passive="onTouchMove" @touchend="onTouchEnd">
    <div v-if="loading" class="center"><van-loading size="48" color="#fff" /></div>
    <div v-else-if="error" class="center">
      <p style="color:#ff6b6b;font-size:14px">{{ error }}</p>
      <van-button type="primary" size="small" @click.stop="fetchPages">重试</van-button>
    </div>
    <template v-else>
      <div v-if="isGallery" class="gallery" :style="{ transform: `translateX(${translateX}px)` }">
        <div
          class="gallery-page"
          :class="{ 'gallery-page-h': isLandscape, 'gallery-page-v': !isLandscape, 'zoom-transition': pageAnimation }"
          :style="{ transform: `scale(${zoomScale})`, transformOrigin: `${zoomOriginX}% ${zoomOriginY}%` }"
        >
          <img
            v-for="idx in currentGroup"
            :key="idx"
            :src="imageProxyUrl(images[idx])"
            class="gallery-img"
            draggable="false"
            @pointerdown="(e: PointerEvent) => onImagePointerDown(e, idx)"
            @pointerup="onImagePointerUp"
            @pointercancel="onImagePointerCancel"
            @contextmenu.prevent
          />
        </div>
      </div>
      <div
        v-else
        ref="continuousEl"
        class="continuous"
        :class="{ horizontal: isContinuousHorizontal, limited: limitContinuousImageWidth }"
        @scroll="onScroll"
      >
        <div
          v-for="(url, i) in images" :key="i"
          class="img-placeholder"
          :style="{ aspectRatio: imageAspects[i] || '3/4' }"
        >
          <img
            :src="imageProxyUrl(url)"
            class="continuous-img" loading="lazy"
            @load="onImageLoad($event, i)"
            @pointerdown="onImagePointerDown"
            @pointerup="onImagePointerUp"
            @pointercancel="onImagePointerCancel"
            @contextmenu.prevent
          />
        </div>
      </div>
    </template>

    <!-- Auto page indicator -->
    <div v-if="autoPageEnabled && isGallery && !showToolbar" class="auto-page-indicator">
      <svg width="36" height="36" viewBox="0 0 36 36">
        <circle cx="18" cy="18" r="15" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="3" />
        <circle cx="18" cy="18" r="15" fill="none" stroke="#1989fa" stroke-width="3"
          stroke-linecap="round" :stroke-dasharray="94.2" :stroke-dashoffset="94.2 - (autoPageProgress / 100) * 94.2"
          transform="rotate(-90 18 18)" />
      </svg>
    </div>

    <!-- Continuous mode page indicator -->
    <transition name="fade">
      <div v-if="isContinuous && showPageNumber && showPageIndicator && totalPages > 0" class="page-indicator-pill">
        {{ currentPage + 1 }} / {{ totalPages }}
      </div>
    </transition>

    <!-- Top toolbar -->
    <transition name="slide-top">
      <div v-if="showToolbar" class="toolbar-top" @click.stop>
        <van-icon name="arrow-left" size="22" color="#fff" @click="onBack" />
        <div class="title-section">
          <div class="comic-name">{{ comicTitle }}</div>
          <div class="chapter-name">{{ chapterTitle }}</div>
        </div>
        <span v-if="showPageNumber" class="page-badge">{{ pageDisplay }}</span>
        <van-icon :name="isFullscreen ? 'shrink' : 'expand-o'" size="20" color="#fff" @click="toggleFullscreen" />
        <van-icon name="setting-o" size="20" color="#fff" @click="showSettings = true" />
      </div>
    </transition>

    <!-- Bottom toolbar -->
    <transition name="slide-bottom">
      <div v-if="showToolbar" class="toolbar-bottom" @click.stop>
        <span class="tb-btn tb-btn-text" @click="goFirst">首页</span>
        <div class="slider-wrap">
          <van-slider v-model="sliderVal" :min="1" :max="Math.max(currentChapterPageCount, 1)" :step="1" active-color="#1989fa" @change="onSliderChange" />
        </div>
        <span class="tb-btn tb-btn-text" @click="goLast">末页</span>
        <div class="chapter-btns">
          <van-button size="mini" type="default" class="chapter-nav-btn" @click="prevChapter">上一话</van-button>
          <van-button size="mini" type="default" class="chapter-nav-btn" @click="showChapterPicker = true">章节</van-button>
          <van-button size="mini" type="default" class="chapter-nav-btn" @click="nextChapter">下一话</van-button>
        </div>
      </div>
    </transition>

    <!-- Settings panel -->
    <van-popup v-model:show="showSettings" position="right" :style="{ width: '300px', height: '100%', background: '#fff', color: '#1a1a1a' }">
      <div class="settings">
        <h3 style="margin:16px">阅读设置</h3>
        <div style="overflow-y:auto;height:calc(100% - 56px);padding-bottom:env(safe-area-inset-bottom,0px)">
        <van-cell-group inset>
          <van-cell title="阅读模式">
            <template #value>
              <select v-model="readingMode" class="mode-select" @change="settingsStore.update('readingMode', readingMode)">
                <option value="galleryLeftToRight">画廊（从左到右）</option>
                <option value="galleryRightToLeft">画廊（从右到左）</option>
                <option value="galleryTopToBottom">画廊（从上到下）</option>
                <option value="continuousTopToBottom">连续（从上到下）</option>
                <option value="continuousLeftToRight">连续（从左到右）</option>
                <option value="continuousRightToLeft">连续（从右到左）</option>
              </select>
            </template>
          </van-cell>
          <van-cell title="点击翻页">
            <template #right-icon><van-switch v-model="tapToTurnPages" size="20" @change="settingsStore.update('tapToTurn', tapToTurnPages)" /></template>
          </van-cell>
          <van-cell title="反转点击翻页">
            <template #right-icon><van-switch v-model="reverseTapToTurnPages" size="20" @change="settingsStore.update('reverseTap', reverseTapToTurnPages)" /></template>
          </van-cell>
          <van-cell title="页面动画">
            <template #right-icon><van-switch v-model="pageAnimation" size="20" @change="settingsStore.update('pageAnimation', pageAnimation)" /></template>
          </van-cell>
          <van-cell title="连续章节阅读">
            <template #right-icon><van-switch v-model="continuousChapter" size="20" @change="settingsStore.update('continuousChapter', continuousChapter)" /></template>
          </van-cell>
          <van-cell title="在首页显示单张图片" v-if="isGallery">
            <template #right-icon><van-switch v-model="showSingleImageOnFirstPage" size="20" @change="settingsStore.update('showSingleImageOnFirstPage', showSingleImageOnFirstPage)" /></template>
          </van-cell>
          <van-cell title="自动翻页" v-if="isGallery">
            <template #right-icon><van-switch v-model="autoPageEnabled" size="20" @change="settingsStore.update('autoPageEnabled', autoPageEnabled)" /></template>
          </van-cell>
          <van-cell title="自动翻页间隔" v-if="isGallery && autoPageEnabled">
            <template #value>
              <van-stepper v-model="autoPageInterval" :min="1" :max="20" :step="1" theme="round" @change="settingsStore.update('autoPageInterval', autoPageInterval)" />
            </template>
          </van-cell>
        </van-cell-group>

        <van-cell-group inset style="margin-top:12px">
          <van-cell title="双击缩放">
            <template #right-icon><van-switch v-model="doubleTapZoom" size="20" @change="settingsStore.update('doubleTapZoom', doubleTapZoom)" /></template>
          </van-cell>
          <van-cell title="长按缩放">
            <template #right-icon><van-switch v-model="longPressZoom" size="20" @change="settingsStore.update('longPressZoom', longPressZoom)" /></template>
          </van-cell>
          <van-cell title="长按缩放位置" v-if="longPressZoom">
            <template #value>
              <select v-model="longPressZoomPos" class="mode-select" @change="settingsStore.update('longPressZoomPos', longPressZoomPos)">
                <option value="press">按压位置</option>
                <option value="center">屏幕中心</option>
              </select>
            </template>
          </van-cell>
          <van-cell title="限制图片宽度" v-if="isContinuous && isVerticalMode">
            <template #right-icon><van-switch v-model="limitImageWidth" size="20" @change="settingsStore.update('limitImageWidth', limitImageWidth)" /></template>
          </van-cell>
          <van-cell title="鼠标滚动速度" v-if="isContinuous">
            <template #value>
              <van-stepper v-model="scrollSpeed" :min="0.5" :max="3" :step="0.1" :decimal-length="1" theme="round" @change="settingsStore.update('scrollSpeed', scrollSpeed)" />
            </template>
          </van-cell>
        </van-cell-group>

        <van-cell-group inset style="margin-top:12px">
          <van-cell title="快速收藏图片">
            <template #value>
              <select v-model="quickFavImage" class="mode-select" @change="settingsStore.update('quickFavImage', quickFavImage)">
                <option value="No">不启用</option>
                <option value="DoubleTap">双击</option>
                <option value="Swipe">滑动</option>
              </select>
            </template>
          </van-cell>
          <van-cell title="预加载图片数量">
            <template #value>
              <van-stepper v-model="preloadCount" :min="1" :max="16" :step="1" theme="round" @change="settingsStore.update('preloadCount', preloadCount)" />
            </template>
          </van-cell>
          <van-cell title="横屏同屏幕图片数量" v-if="isGallery">
            <template #value>
              <van-stepper v-model="readerScreenPicNumberForLandscape" :min="1" :max="5" :step="1" theme="round" @change="settingsStore.update('readerScreenPicNumberForLandscape', readerScreenPicNumberForLandscape)" />
            </template>
          </van-cell>
          <van-cell title="竖屏同屏幕图片数量" v-if="isGallery">
            <template #value>
              <van-stepper v-model="readerScreenPicNumberForPortrait" :min="1" :max="5" :step="1" theme="round" @change="settingsStore.update('readerScreenPicNumberForPortrait', readerScreenPicNumberForPortrait)" />
            </template>
          </van-cell>
        </van-cell-group>

        <van-cell-group inset style="margin-top:12px">
          <van-cell title="显示页码">
            <template #right-icon><van-switch v-model="showPageNum" size="20" @change="settingsStore.update('showPageNum', showPageNum)" /></template>
          </van-cell>
          <van-cell title="在阅读器中显示时间和电量信息" v-if="false">
            <template #right-icon><van-switch v-model="showTimeAndBattery" size="20" @change="settingsStore.update('showTimeAndBattery', showTimeAndBattery)" /></template>
          </van-cell>
          <van-cell title="显示系统状态栏" v-if="false">
            <template #right-icon><van-switch v-model="showStatusBar" size="20" @change="settingsStore.update('showStatusBar', showStatusBar)" /></template>
          </van-cell>
          <van-cell title="显示章节评论">
            <template #right-icon><van-switch v-model="showChapterComments" size="20" @change="settingsStore.update('showChapterComments', showChapterComments)" /></template>
          </van-cell>
          <van-cell title="章节末尾显示评论">
            <template #right-icon><van-switch v-model="showChapterCommentsAtEnd" size="20" @change="settingsStore.update('showChapterCommentsAtEnd', showChapterCommentsAtEnd)" /></template>
          </van-cell>
          <van-cell title="使用音量键翻页" v-if="false">
            <template #right-icon><van-switch v-model="volumeKeyTurn" size="20" /></template>
          </van-cell>
        </van-cell-group>
        </div>
      </div>
    </van-popup>

    <!-- Chapter picker -->
    <van-popup v-model:show="showChapterPicker" position="right" :style="{ width: '320px', maxWidth: '88vw', height: '100%' }">
      <div class="chapter-panel">
        <div class="chapter-panel-title">章节</div>
        <div class="chapter-list">
          <button
            v-for="chapter in flatChapters"
            :key="chapter.id"
            type="button"
            class="chapter-item"
            :class="{ active: chapter.id === currentChapterId }"
            @click="selectChapter(chapter.id)"
          >
            <span class="chapter-main">{{ chapter.title || `第 ${chapter.chapterIndex + 1} 话` }}</span>
            <span class="chapter-sub">{{ chapter.groupTitle }}</span>
          </button>
        </div>
      </div>
    </van-popup>

    <!-- Image action sheet (long-press) -->
    <van-action-sheet
      v-model:show="showImageActions"
      :actions="[{ name: '保存图片' }, { name: '复制图片' }]"
      cancel-text="取消"
      @select="(action: any) => action.name === '保存图片' ? saveImage() : copyImage()"
      @cancel="showImageActions = false"
    />
  </div>
</template>

<style scoped>
.reader { position: fixed; inset: 0; background: #000; color: #fff; user-select: none; overflow: hidden; z-index: 100; }
.center { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px; }
.gallery { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; overflow: hidden; }
.gallery-page { display: flex; width: 100%; height: 100%; max-width: 100%; max-height: 100%; }
.gallery-page-h { flex-direction: row; }
.gallery-page-v { flex-direction: column; }
.gallery-img { min-width: 0; min-height: 0; object-fit: contain; flex: 1 1 0; }
.zoom-transition { transition: transform 0.25s cubic-bezier(0.25, 0.1, 0.25, 1); }
.continuous { width: 100%; height: 100%; overflow-y: auto; -webkit-overflow-scrolling: touch; }
.continuous.horizontal { display: flex; overflow-x: auto; overflow-y: hidden; scroll-snap-type: x mandatory; }
.continuous-img { display: block; width: 100%; height: 100%; object-fit: contain; }
.img-placeholder { width: 100%; background: #1a1a1a; }
.continuous.limited:not(.horizontal) .img-placeholder { max-width: min(100%, 980px); margin: 0 auto; }
.continuous.limited:not(.horizontal) .continuous-img { max-width: 100%; }
.continuous.horizontal .img-placeholder { width: auto; height: 100%; flex: 0 0 auto; aspect-ratio: 3/4; scroll-snap-align: center; }
.continuous.horizontal .continuous-img { width: auto; height: 100%; max-width: none; object-fit: contain; }
.toolbar-top {
  position: absolute; top: 0; left: 0; right: 0; z-index: 50;
  display: flex; align-items: center; gap: 12px;
  padding: 12px 16px; padding-top: calc(env(safe-area-inset-top, 0px) + 12px);
  background: rgba(30,30,30,0.92); backdrop-filter: blur(10px);
  border-bottom: 0.5px solid rgba(128,128,128,0.5);
}
.title-section { flex: 1; min-width: 0; }
.comic-name { font-size: 16px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.chapter-name { font-size: 12px; opacity: 0.7; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.page-badge { font-size: 13px; background: rgba(100,100,100,0.5); padding: 2px 8px; border-radius: 8px; white-space: nowrap; }
.toolbar-bottom {
  position: absolute; bottom: 0; left: 0; right: 0; z-index: 50;
  display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
  padding: 12px 16px; padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 12px);
  background: rgba(30,30,30,0.92); backdrop-filter: blur(10px);
  border-top: 0.5px solid rgba(128,128,128,0.5);
}
.tb-btn { cursor: pointer; padding: 4px; }
.tb-btn-text { color: #fff; font-size: 13px; font-weight: 500; white-space: nowrap; user-select: none; }
.slider-wrap { flex: 1; min-width: 100px; padding: 0 4px; }
.chapter-btns { display: flex; gap: 6px; width: 100%; justify-content: center; margin-top: 4px; }
.chapter-nav-btn { color: #fff !important; border-color: rgba(255,255,255,0.5) !important; background: rgba(255,255,255,0.1) !important; }
.settings { padding-bottom: env(safe-area-inset-bottom, 0px); }
.mode-select { background: transparent; color: inherit; border: 1px solid #ddd; border-radius: 4px; padding: 4px 8px; font-size: 13px; }
.chapter-panel { height: 100%; background: #111; color: #fff; display: flex; flex-direction: column; }
.chapter-panel-title { padding: calc(env(safe-area-inset-top, 0px) + 16px) 16px 12px; font-size: 16px; font-weight: 600; border-bottom: 0.5px solid rgba(255,255,255,0.12); }
.chapter-list { flex: 1; overflow-y: auto; padding: 8px; }
.chapter-item { width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 12px; border: 0; border-radius: 6px; padding: 12px 10px; background: transparent; color: inherit; text-align: left; cursor: pointer; }
.chapter-item.active { background: rgba(25,137,250,0.22); color: #6bb6ff; }
.chapter-main { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
.chapter-sub { flex: 0 0 auto; font-size: 12px; opacity: 0.62; }

/* Auto page indicator */
.auto-page-indicator {
  position: absolute; bottom: 24px; right: 24px; z-index: 40;
  width: 36px; height: 36px; opacity: 0.8;
}
/* Page indicator pill for continuous mode */
.page-indicator-pill {
  position: absolute; bottom: 24px; left: 50%; transform: translateX(-50%); z-index: 40;
  background: rgba(0,0,0,0.65); color: #fff; font-size: 13px;
  padding: 4px 14px; border-radius: 14px; white-space: nowrap;
  backdrop-filter: blur(4px);
}
/* Transitions */
.slide-top-enter-active, .slide-top-leave-active { transition: transform 140ms cubic-bezier(0.33,1,0.68,1); }
.slide-top-enter-from, .slide-top-leave-to { transform: translateY(-100%); }
.slide-bottom-enter-active, .slide-bottom-leave-active { transition: transform 140ms cubic-bezier(0.33,1,0.68,1); }
.slide-bottom-enter-from, .slide-bottom-leave-to { transform: translateY(100%); }
.fade-enter-active, .fade-leave-active { transition: opacity 0.3s ease; }
.fade-enter-from, .fade-leave-to { opacity: 0; }
</style>
