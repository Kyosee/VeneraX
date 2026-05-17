<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { getComicSources, searchComics as searchSourceComics, getRelatedSources, linkRelatedSource, acceptRelatedSource, rejectRelatedSource, unlinkRelatedSource } from '@/services/server-db'
import { apiPost } from '@/services/api'
import { showToast } from 'vant'
import ProxiedImage from '@/components/ProxiedImage.vue'
import type { RelatedSource, Comic } from '@/types'
import type { ComicSource } from '@/types'

const props = defineProps<{
  show: boolean
  sourceKey: string
  comicId: string
  comicTitle: string
}>()

const emit = defineEmits<{
  (e: 'update:show', value: boolean): void
}>()

const activeTab = ref(0)
const loading = ref(false)
const relatedSources = ref<RelatedSource[]>([])
const sources = ref<ComicSource[]>([])

// Linked tab state
const actionLoading = ref<Record<string, boolean>>({})

// Search tab state
const searchKeyword = ref('')
const searchSourceKey = ref('')
const searchResults = ref<any[]>([])
const searchLoading = ref(false)

// Advanced mode
const showAdvanced = ref(false)
const advancedSourceKey = ref('')
const advancedComicId = ref('')

// Preview popup
const previewComic = ref<Comic | null>(null)
const previewVisible = ref(false)
const previewLoading = ref(false)

function close() {
  emit('update:show', false)
}

async function loadSources() {
  if (sources.value.length) return
  try {
    sources.value = await getComicSources()
  } catch {
    sources.value = []
  }
}

const sourceOptions = computed(() => {
  return sources.value.filter(s => s.key && s.key !== props.sourceKey)
})

async function fetchRelatedSources() {
  loading.value = true
  try {
    relatedSources.value = await getRelatedSources(props.sourceKey, props.comicId)
  } catch {
    relatedSources.value = []
  } finally {
    loading.value = false
  }
}

function statusText(status: string) {
  return status === 'accepted' ? '已关联' : status === 'candidate' ? '待确认' : '已拒绝'
}

function statusColor(status: string) {
  return status === 'accepted' ? '#27ae60' : status === 'candidate' ? '#f5a623' : '#999'
}

function isCurrentSource(source: RelatedSource) {
  return source.sourceKey === props.sourceKey && source.id === props.comicId
}

async function handleAccept(source: RelatedSource) {
  const key = `accept-${source.comic_id}`
  actionLoading.value[key] = true
  try {
    await acceptRelatedSource(props.sourceKey, props.comicId, source.work_id)
    showToast('已确认关联')
    await fetchRelatedSources()
  } catch (e: any) {
    showToast(e.message || '操作失败')
  } finally {
    delete actionLoading.value[key]
  }
}

async function handleReject(source: RelatedSource) {
  const key = `reject-${source.comic_id}`
  actionLoading.value[key] = true
  try {
    await rejectRelatedSource(props.sourceKey, props.comicId, source.work_id)
    showToast('已拒绝关联')
    await fetchRelatedSources()
  } catch (e: any) {
    showToast(e.message || '操作失败')
  } finally {
    delete actionLoading.value[key]
  }
}

async function handleUnlink(source: RelatedSource) {
  const key = `unlink-${source.comic_id}`
  actionLoading.value[key] = true
  try {
    await unlinkRelatedSource(props.sourceKey, props.comicId, source.work_id)
    showToast('已取消关联')
    await fetchRelatedSources()
  } catch (e: any) {
    showToast(e.message || '操作失败')
  } finally {
    delete actionLoading.value[key]
  }
}

async function handleSearch() {
  if (!searchSourceKey.value || !searchKeyword.value.trim()) {
    showToast('请选择来源并输入关键词')
    return
  }
  searchLoading.value = true
  try {
    const result = await searchSourceComics(searchSourceKey.value, searchKeyword.value.trim())
    searchResults.value = result.comics || []
  } catch (e: any) {
    showToast(e.message || '搜索失败')
    searchResults.value = []
  } finally {
    searchLoading.value = false
  }
}

async function handleLinkResult(comic: any) {
  if (!comic.id) return
  try {
    await linkRelatedSource(props.sourceKey, props.comicId, searchSourceKey.value, comic.id)
    showToast('关联成功')
    // Switch to linked tab and refresh
    activeTab.value = 0
    await fetchRelatedSources()
    searchResults.value = []
  } catch (e: any) {
    showToast(e.message || '关联失败')
  }
}

async function handleAdvancedLink() {
  if (!advancedSourceKey.value.trim() || !advancedComicId.value.trim()) {
    showToast('请输入来源 Key 和漫画 ID')
    return
  }
  try {
    // Mirror the target comic first, then link
    await apiPost('/api/server-db/comic/mirror', {
      sourceKey: advancedSourceKey.value.trim(),
      comicId: advancedComicId.value.trim(),
    })
    await linkRelatedSource(props.sourceKey, props.comicId, advancedSourceKey.value.trim(), advancedComicId.value.trim())
    showToast('高级关联成功')
    showAdvanced.value = false
    advancedSourceKey.value = ''
    advancedComicId.value = ''
    await fetchRelatedSources()
  } catch (e: any) {
    showToast(e.message || '关联失败')
  }
}

async function handlePreviewResult(comic: any) {
  previewVisible.value = true
  previewLoading.value = true
  previewComic.value = null
  try {
    const res = await apiPost<{ comic: Comic }>('/api/server-db/comic/detail', {
      sourceKey: searchSourceKey.value,
      comicId: comic.id,
    })
    previewComic.value = res.comic || null
  } catch (e: any) {
    previewComic.value = {
      id: comic.id,
      title: comic.title || '',
      description: comic.subtitle || '',
      cover: comic.cover || '',
      sourceKey: searchSourceKey.value,
      tags: comic.tags || [],
    } as Comic
  } finally {
    previewLoading.value = false
  }
}

function onNavigateRelated(source: RelatedSource) {
  if (isCurrentSource(source)) return
  const url = `#/comic/${encodeURIComponent(source.sourceKey)}/${encodeURIComponent(source.id)}`
  window.location.hash = url
  window.location.reload()
}

watch(() => props.show, (val) => {
  if (val) {
    loadSources()
    fetchRelatedSources()
    searchKeyword.value = props.comicTitle || ''
    activeTab.value = 0
    searchResults.value = []
    previewComic.value = null
    previewVisible.value = false
    showAdvanced.value = false
  }
})
</script>

<template>
  <van-popup
    :show="show"
    position="bottom"
    round
    :style="{ height: '80vh' }"
    @update:show="(val: boolean) => emit('update:show', val)"
  >
    <div class="related-dialog">
      <div class="dialog-header">
        <span class="dialog-title">关联源</span>
        <van-icon name="cross" size="20" @click="close" class="close-btn" />
      </div>

      <van-tabs v-model:active="activeTab" sticky>
        <!-- Linked Tab -->
        <van-tab title="已关联">
          <div class="tab-content">
            <div v-if="loading" class="loading-wrap">
              <van-loading size="24" />
            </div>
            <div v-else-if="!relatedSources.length" class="empty-wrap">
              <van-empty description="暂无关联源" />
            </div>
            <div v-else class="source-list">
              <div
                v-for="source in relatedSources"
                :key="source.comic_id"
                class="source-card"
                :class="{ current: isCurrentSource(source) }"
              >
                <ProxiedImage
                  :src="source.cover_uri || ''"
                  :alt="source.title"
                  width="60px"
                  height="80px"
                  class="source-cover"
                />
                <div class="source-info">
                  <div class="source-title-row">
                    <span class="source-title" @click="onNavigateRelated(source)">{{ source.title }}</span>
                    <van-tag
                      :color="statusColor(source.link_status)"
                                            text-color="#fff"
                    >{{ statusText(source.link_status) }}</van-tag>
                  </div>
                  <div class="source-meta">
                    <span class="source-platform">{{ source.platform_name || source.platform_id }}</span>
                    <span v-if="source.author" class="source-author"> / {{ source.author }}</span>
                  </div>
                  <div v-if="source.link_status === 'candidate' && source.link_source === 'auto'" class="source-confidence">
                    自动匹配 置信度: {{ (source.confidence * 100).toFixed(0) }}%
                  </div>
                  <div v-if="source.link_source === 'manual'" class="source-confidence">
                    手动关联
                  </div>
                  <div class="source-actions">
                    <template v-if="source.link_status === 'candidate'">
                      <van-button
                                                type="primary"
                        :loading="actionLoading['accept-' + source.comic_id]"
                        @click.stop="handleAccept(source)"
                      >确认</van-button>
                      <van-button
                                                type="default"
                        :loading="actionLoading['reject-' + source.comic_id]"
                        @click.stop="handleReject(source)"
                      >拒绝</van-button>
                    </template>
                    <template v-if="source.link_status === 'accepted' && !isCurrentSource(source)">
                      <van-button
                                                type="danger"
                        :loading="actionLoading['unlink-' + source.comic_id]"
                        @click.stop="handleUnlink(source)"
                      >取消关联</van-button>
                    </template>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </van-tab>

        <!-- Search Tab -->
        <van-tab title="搜索">
          <div class="tab-content">
            <!-- Source Chips -->
            <div class="source-chips">
              <span class="chip-label">来源:</span>
              <div class="chips-row">
                <span
                  v-for="opt in sourceOptions"
                  :key="opt.key"
                  class="source-chip"
                  :class="{ active: searchSourceKey === opt.key }"
                  @click="searchSourceKey = opt.key"
                >{{ opt.sourceName || opt.displayName || opt.name }}</span>
              </div>
            </div>

            <!-- Search Field -->
            <div class="search-row">
              <input
                v-model="searchKeyword"
                type="text"
                class="search-input"
                placeholder="输入漫画名称..."
                @keyup.enter="handleSearch"
              />
              <van-button
                                type="primary"
                :loading="searchLoading"
                :disabled="!searchSourceKey"
                @click="handleSearch"
              >搜索</van-button>
            </div>

            <!-- Search Results -->
            <div v-if="searchLoading" class="loading-wrap">
              <van-loading size="24" />
            </div>
            <div v-else-if="searchResults.length" class="result-list">
              <div
                v-for="comic in searchResults"
                :key="comic.id"
                class="result-card"
              >
                <ProxiedImage
                  :src="comic.cover || ''"
                  :alt="comic.title"
                  width="50px"
                  height="66px"
                  class="result-cover"
                />
                <div class="result-info">
                  <span class="result-title">{{ comic.title }}</span>
                  <span v-if="comic.subtitle || comic.author" class="result-subtitle">{{ comic.subtitle || comic.author }}</span>
                </div>
                <div class="result-actions">
                  <van-button size="medium" plain @click.stop="handlePreviewResult(comic)">预览</van-button>
                  <van-button size="medium" type="primary" @click.stop="handleLinkResult(comic)">关联</van-button>
                </div>
              </div>
            </div>
            <div v-else-if="searchKeyword && searchSourceKey" class="empty-wrap">
              <van-empty description="无搜索结果" />
            </div>

            <!-- Preview Popup -->
            <van-popup
              v-model:show="previewVisible"
              position="bottom"
              round
              :style="{ maxHeight: '50vh' }"
            >
              <div v-if="previewComic" class="preview-content">
                <div class="preview-header">
                  <ProxiedImage
                    :src="previewComic.cover"
                    :alt="previewComic.title"
                    width="80px"
                    height="106px"
                    class="preview-cover"
                  />
                  <div class="preview-meta">
                    <h3 class="preview-title">{{ previewComic.title }}</h3>
                    <p v-if="(previewComic as any).author || previewComic.subtitle" class="preview-author">{{ (previewComic as any).author || previewComic.subtitle }}</p>
                    <p v-if="(previewComic as any).status" class="preview-status">{{ (previewComic as any).status }}</p>
                  </div>
                </div>
                <p v-if="previewComic.description" class="preview-desc">{{ previewComic.description }}</p>
              </div>
              <div v-else class="loading-wrap" style="padding: 32px;">
                <van-loading size="24" />
              </div>
            </van-popup>

            <!-- Advanced Section -->
            <div class="advanced-section">
              <div class="advanced-toggle" @click="showAdvanced = !showAdvanced">
                <span>高级精确关联</span>
                <van-icon :name="showAdvanced ? 'arrow-up' : 'arrow-down'" size="14" />
              </div>
              <div v-if="showAdvanced" class="advanced-form">
                <input
                  v-model="advancedSourceKey"
                  type="text"
                  class="advanced-input"
                  placeholder="来源 Key (如: copy_manga)"
                />
                <input
                  v-model="advancedComicId"
                  type="text"
                  class="advanced-input"
                  placeholder="漫画 ID"
                />
                <van-button size="medium" type="primary" @click="handleAdvancedLink">关联</van-button>
              </div>
            </div>
          </div>
        </van-tab>
      </van-tabs>
    </div>
  </van-popup>
</template>

<style scoped>
.related-dialog {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.dialog-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 16px 8px;
}

.dialog-title {
  font-size: 18px;
  font-weight: 600;
}

.close-btn {
  cursor: pointer;
  color: #999;
}
.close-btn:hover { color: #333; }

.tab-content {
  padding: 12px 16px;
  overflow-y: auto;
  max-height: calc(80vh - 100px);
}

.loading-wrap {
  display: flex;
  justify-content: center;
  padding: 32px 0;
}

.empty-wrap {
  padding: 24px 0;
}

/* Source List */
.source-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.source-card {
  display: flex;
  gap: 12px;
  padding: 12px;
  background: #fafafa;
  border-radius: 8px;
  border: 1px solid #f0f0f0;
}

.source-card.current {
  border-color: #4f6ef7;
  background: #f5f7ff;
}

.source-cover {
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
}

.source-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.source-title-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.source-title {
  font-size: 14px;
  font-weight: 500;
  color: #4f6ef7;
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.source-title:hover {
  text-decoration: underline;
}

.source-meta {
  font-size: 12px;
  color: #888;
}

.source-platform {
  color: #4f6ef7;
}

.source-confidence {
  font-size: 11px;
  color: #f5a623;
  margin-top: 2px;
}

.source-actions {
  display: flex;
  gap: 6px;
  margin-top: 6px;
}

/* Source Chips */
.source-chips {
  margin-bottom: 12px;
}

.chip-label {
  font-size: 13px;
  color: #666;
  margin-right: 4px;
}

.chips-row {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 4px;
}

.source-chip {
  display: inline-block;
  padding: 4px 10px;
  border-radius: 14px;
  font-size: 12px;
  background: #f5f5f5;
  color: #666;
  cursor: pointer;
  transition: all 0.15s;
  border: 1px solid transparent;
}
.source-chip:hover { background: #ebebeb; }
.source-chip.active {
  background: #e8f0fe;
  color: #4f6ef7;
  border-color: #4f6ef7;
}

/* Search Row */
.search-row {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
}

.search-input {
  flex: 1;
  padding: 8px 12px;
  border: 1px solid #e0e0e0;
  border-radius: 6px;
  font-size: 14px;
  outline: none;
  box-sizing: border-box;
}

.search-input:focus {
  border-color: #4f6ef7;
}

/* Result List */
.result-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 12px;
}

.result-card {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px;
  background: #fafafa;
  border-radius: 8px;
}

.result-cover {
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
}

.result-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.result-title {
  font-size: 13px;
  font-weight: 500;
  color: #333;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.result-subtitle {
  font-size: 11px;
  color: #999;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.result-actions {
  display: flex;
  gap: 6px;
  flex-shrink: 0;
}

/* Preview */
.preview-content {
  padding: 16px;
}

.preview-header {
  display: flex;
  gap: 12px;
  margin-bottom: 12px;
}

.preview-cover {
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
}

.preview-meta {
  flex: 1;
  min-width: 0;
}

.preview-title {
  font-size: 16px;
  font-weight: 600;
  margin: 0 0 4px;
  color: #1a1a1a;
}

.preview-author {
  font-size: 13px;
  color: #666;
  margin: 0 0 2px;
}

.preview-status {
  font-size: 12px;
  color: #999;
  margin: 0;
}

.preview-desc {
  font-size: 13px;
  line-height: 1.5;
  color: #555;
  white-space: pre-wrap;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 5;
  -webkit-box-orient: vertical;
}

/* Advanced Section */
.advanced-section {
  margin-top: 16px;
  padding-top: 12px;
  border-top: 1px solid #f0f0f0;
}

.advanced-toggle {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 13px;
  color: #999;
  cursor: pointer;
  padding: 4px 0;
}

.advanced-toggle:hover { color: #4f6ef7; }

.advanced-form {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 8px;
}

.advanced-input {
  width: 100%;
  padding: 8px 12px;
  border: 1px solid #e0e0e0;
  border-radius: 6px;
  font-size: 13px;
  outline: none;
  box-sizing: border-box;
}

.advanced-input:focus {
  border-color: #4f6ef7;
}
</style>
