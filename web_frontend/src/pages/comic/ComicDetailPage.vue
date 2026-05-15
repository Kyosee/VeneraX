<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { apiPost } from '@/services/api'
import { addFavorite, deleteFavorite, getComicSources, listFavorites, listFolders, listHistory } from '@/services/server-db'
import { resolveSourceKey, sourceTypeFromKey } from '@/utils/source'
import ProxiedImage from '@/components/ProxiedImage.vue'
import { showToast } from 'vant'
import type { Comic, Chapter, ChapterGroup, Comment, ComicSource, History } from '@/types'

const route = useRoute()
const router = useRouter()
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
const descExpanded = ref(false)
const activeTab = ref(0)
const sortAsc = ref(true)
const lastReadChapterId = ref<string | null>(null)
const lastReadPage = ref(1)
const lastReadGroup = ref<number | null>(null)
const showMenu = ref(false)
const commentsPage = ref(1)
const commentsLoading = ref(false)
const commentsHasMore = ref(false)
const thumbnails = ref<{ url: string; ep: string; page: number }[]>([])
const thumbnailsLoading = ref(false)
const relatedComics = ref<{ id: string; title: string; cover: string; subtitle?: string }[]>([])
const relatedLoading = ref(false)
const detailNotice = ref('')
const sources = ref<ComicSource[]>([])

const isGrouped = computed(() => {
  if (!chapters.value.length) return false
  return 'chapters' in chapters.value[0]
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
const lastReadInfo = computed(() => {
  if (!lastReadChapterId.value) return null
  const ch = flatChapters.value.find(c => c.id === lastReadChapterId.value)
  const groupName = groupTitles.value[lastReadGroup.value ?? 0] || '默認'
  return { group: groupName, chapter: ch?.title || lastReadChapterId.value, page: lastReadPage.value }
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

async function firstFavoriteFolder() {
  const folders = await listFolders()
  const folder = folders[0]?.name || folders[0]?.id
  if (!folder) throw new Error('请先创建收藏文件夹')
  return folder
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
    comic.value = res.comic
    chapters.value = res.chapters || []
    const detailComments = Array.isArray(res.comments) ? res.comments : []
    comments.value = detailComments
    commentsHasMore.value = detailComments.length >= 20
    await refreshFavoriteState()
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
    }
  } catch { /* ignore */ }
}

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
    const res = await apiPost<{ comics: { id: string; title: string; cover: string; subtitle?: string }[] }>(
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

async function toggleFavorite() {
  if (!comic.value) return
  favoriteLoading.value = true
  try {
    const type = favoriteType()
    if (isFavorite.value) {
      if (!favoriteFolder.value) await refreshFavoriteState()
      if (!favoriteFolder.value) throw new Error('未找到收藏所在文件夹')
      await deleteFavorite(favoriteFolder.value, comicId.value, type)
      isFavorite.value = false
      favoriteFolder.value = null
    } else {
      const folder = await firstFavoriteFolder()
      await addFavorite({
        folder,
        id: comicId.value,
        type,
        name: comic.value.title,
        author: comic.value.subtitle || '',
        tags: comic.value.tags || [],
        coverPath: comic.value.cover,
        time: favoriteTime(),
        title: comic.value.title,
        cover: comic.value.cover,
      } as any)
      isFavorite.value = true
      favoriteFolder.value = folder
    }
  } catch (e: any) {
    showToast(e.message || '收藏操作失败')
  }
  finally { favoriteLoading.value = false }
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
  const page = (ch.id === lastReadChapterId.value) ? lastReadPage.value : 1
  router.push({
    path: `/reader/${sourceKey.value}/${comicId.value}`,
    query: { ep: ch.id, page: String(page) },
  })
}

function continueReading() {
  if (lastReadChapterId.value) {
    const ch = flatChapters.value.find(c => c.id === lastReadChapterId.value)
    if (ch) { readComic(ch); return }
  }
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

function onDownload() {
  showToast('Web 端暂不支持下载，请在桌面或移动端使用下载功能')
}

function onTagClick(tag: string) {
  router.push({ path: '/search', query: { keyword: tag, source: sourceKey.value } })
}

function goToRelatedComic(c: { id: string; title: string; cover: string }) {
  router.push(`/comic/${sourceKey.value}/${encodeURIComponent(c.id)}`)
}

function scrollToComments() {
  const el = document.querySelector('.comments-section')
  if (el) el.scrollIntoView({ behavior: 'smooth' })
}

function toggleSort() { sortAsc.value = !sortAsc.value }
function onBack() { router.back() }

onMounted(() => {
  fetchDetail()
  fetchHistory()
  fetchThumbnails()
  fetchRelated()
})
</script>
<template>
  <div class="comic-detail-page">
    <!-- Top Bar -->
    <div class="top-bar">
      <div class="top-bar-btn" @click="onBack">
        <van-icon name="arrow-left" size="20" />
      </div>
      <div class="top-bar-btn" @click="showMenu = !showMenu">
        <van-icon name="ellipsis" size="20" />
      </div>
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
          <div class="meta-row" v-if="comic.subtitle">
            <span class="meta-label">作者:</span>
            <span class="meta-value">{{ comic.subtitle }}</span>
          </div>
          <div class="meta-row">
            <span class="meta-label">来源:</span>
            <span class="meta-value">{{ sourceKey }}</span>
          </div>
          <div class="meta-row" v-if="comic.tags?.length">
            <span class="meta-label">标签:</span>
            <span class="tags-inline">
              <span v-for="tag in comic.tags" :key="tag" class="tag-link" @click="onTagClick(tag)">{{ tag }}</span>
            </span>
          </div>
          <div class="meta-row" v-if="comic.language">
            <span class="meta-label">状态:</span>
            <span class="meta-value">{{ comic.language }}</span>
          </div>
          <!-- Star Rating -->
          <div class="meta-row" v-if="comic.stars">
            <span class="meta-label">评分:</span>
            <van-rate :model-value="comic.stars" readonly allow-half size="14" color="#f5a623" void-color="#ddd" />
          </div>
        </div>
      </div>

      <!-- Action Buttons Row -->
      <div class="action-buttons">
        <button class="action-btn" @click="continueReading">
          <van-icon name="play-circle-o" class="action-icon icon-orange" />
          <span>继续</span>
        </button>
        <button class="action-btn" @click="startReading">
          <van-icon name="play" class="action-icon icon-red" />
          <span>开始</span>
        </button>
        <button class="action-btn" :class="{ active: isFavorite }" @click="toggleFavorite">
          <van-icon :name="isFavorite ? 'star' : 'star-o'" class="action-icon icon-purple" />
          <span>收藏</span>
        </button>
        <button class="action-btn" @click="onDownload">
          <van-icon name="down" class="action-icon icon-teal" />
          <span>下载</span>
        </button>
        <button class="action-btn" v-if="comments.length" @click="scrollToComments">
          <van-icon name="chat-o" class="action-icon icon-green" />
          <span>评论</span>
        </button>
        <button class="action-btn" @click="shareComic">
          <van-icon name="share-o" class="action-icon icon-blue" />
          <span>分享</span>
        </button>
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
            :class="{ 'is-read': ch.id === lastReadChapterId }"
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
              <div v-if="comment.replyCount" class="comment-replies">
                <van-icon name="chat-o" size="12" />
                <span>{{ comment.replyCount }} 回复</span>
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
          <div
            v-for="rc in relatedComics"
            :key="rc.id"
            class="related-card"
            @click="goToRelatedComic(rc)"
          >
            <ProxiedImage
              :src="rc.cover"
              :alt="rc.title"
              width="100px"
              height="133px"
              class="related-cover"
            />
            <div class="related-title">{{ rc.title }}</div>
            <div v-if="rc.subtitle" class="related-subtitle">{{ rc.subtitle }}</div>
          </div>
        </div>
      </div>
      <div v-else-if="relatedLoading" class="related-section">
        <van-loading size="20" />
      </div>
    </div>
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
.meta-row {
  display: flex;
  align-items: flex-start;
  font-size: 14px;
  line-height: 1.4;
}
.meta-label {
  color: #999;
  font-size: 13px;
  flex-shrink: 0;
  margin-right: 4px;
}
.meta-value {
  color: #333;
  font-size: 14px;
}
.tags-inline {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 8px;
}
.tag-link {
  color: #4f6ef7;
  font-size: 14px;
  cursor: pointer;
}
.tag-link:hover {
  text-decoration: underline;
}

/* Action Buttons */
.action-buttons {
  display: flex;
  gap: 8px;
  margin-bottom: 14px;
  overflow-x: auto;
  padding: 4px 0;
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
.icon-orange { color: #f5a623; }
.icon-red { color: #e74c3c; }
.icon-purple { color: #9b59b6; }
.icon-green { color: #27ae60; }
.icon-blue { color: #4f6ef7; }
.icon-teal { color: #17a2b8; }

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
.chapter-btn.is-read {
  background: #e8f0fe;
  color: #4f6ef7;
}
.no-chapters {
  text-align: center;
  color: #999;
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
</style>
