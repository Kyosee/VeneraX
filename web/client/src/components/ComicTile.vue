<script setup lang="ts">
import { computed } from 'vue'
import ProxiedImage from './ProxiedImage.vue'
import { useSettingsStore } from '@/stores/settings'
import { comicDisplayInfo } from '@/utils/comic-display'
import { canonicalSourceKey } from '@/utils/source'

const props = withDefaults(defineProps<{
  comic: Record<string, any>
  sourceName?: string
  isFavorite?: boolean
  readProgress?: { ep?: number; page?: number; maxPage?: number; readEpisode?: string }
  displayMode?: 'brief' | 'detailed'
  currentChapter?: string
  latestChapter?: string
}>(), {
  sourceName: undefined,
  isFavorite: false,
  readProgress: undefined,
  displayMode: undefined,
  currentChapter: undefined,
  latestChapter: undefined,
})

const settingsStore = useSettingsStore()
const mode = computed(() => props.displayMode ?? (settingsStore.settings.thumbnailMode === 'brief' ? 'brief' : 'detailed'))
const scale = computed(() => Number(settingsStore.settings.thumbnailSize || 1))
const display = computed(() => comicDisplayInfo(props.comic))
const title = computed(() => display.value.title)
const cover = computed(() => display.value.cover)
const author = computed(() => display.value.author)
// Source label. When falling back to a raw sourceKey (no resolved source name),
// strip any "(N)" disambiguation suffix so stale keys like "copy_manga(0)" never
// surface in the UI — mirrors native, which never renders a raw source key.
const sourceText = computed(() => {
  const name = props.sourceName || props.comic.sourceName
  if (name) return name
  return canonicalSourceKey(props.comic.sourceKey || '')
})
const statusText = computed(() => display.value.status)
const updateText = computed(() => display.value.update)
const stars = computed(() => display.value.rating)
const tags = computed(() => display.value.tags)
const description = computed(() => display.value.description)
const briefLines = computed(() => display.value.briefLines)

const showFav = computed(() => settingsStore.settings.showFavBadge && props.isFavorite)

const hasProgress = computed(() => {
  const p = props.readProgress
  if (!p) return false
  const page = Number(p.page)
  return Number.isFinite(page) && page > 0
})

const showProgress = computed(() => settingsStore.settings.showHistoryBadge && hasProgress.value)

const progressPage = computed(() => {
  const p = props.readProgress
  if (!p) return 0
  return Number(p.page) || 0
})

const progressMaxPage = computed(() => {
  const p = props.readProgress
  if (!p) return undefined
  const max = p.maxPage ?? (p as any).max_page
  if (max == null) return undefined
  const n = Number(max)
  return Number.isFinite(n) && n > 0 ? n : undefined
})

const progressDisplay = computed(() => {
  const page = progressPage.value
  const max = progressMaxPage.value
  if (max == null) return { type: 'page-only' as const, text: String(page) }
  if (page >= max) return { type: 'checkmark' as const, text: '' }
  return { type: 'fraction' as const, text: `${page}/${max}` }
})

const showEpisodeBadge = computed(() => !!(props.currentChapter || props.latestChapter))

interface InfoRow { label: string; value: string; color: string }
const infoRows = computed<InfoRow[]>(() => {
  const rows: InfoRow[] = []
  if (author.value) rows.push({ label: '作者', value: author.value, color: '#03a9f4' })
  if (updateText.value) rows.push({ label: '更新', value: updateText.value, color: '#00bcd4' })
  if (sourceText.value) rows.push({ label: '来源', value: sourceText.value, color: '#00bcd4' })
  if (tags.value.length) rows.push({ label: '标签', value: tags.value.join(' / '), color: '#e91e63' })
  if (statusText.value) rows.push({ label: '状态', value: statusText.value, color: '#9c27b0' })
  if (!rows.length && description.value) rows.push({ label: '简介', value: description.value, color: '#ff9800' })
  return rows
})

const styleVars = computed(() => ({
  '--tile-scale': String(scale.value),
}))
</script>

<template>
  <article class="comic-tile" :class="mode" :style="styleVars">
    <div class="cover-wrap">
      <ProxiedImage :src="cover" :alt="title" class="cover" />

      <!-- Top-left status icons: favorite + read progress (matches APP) -->
      <div v-if="showFav || showProgress" class="status-icons">
        <span v-if="showFav" class="icon-fav" title="已收藏">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2z"/></svg>
        </span>
        <span v-if="showProgress" class="icon-progress" :class="progressDisplay.type">
          <template v-if="progressDisplay.type === 'checkmark'">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 13 10 19 20 5"/></svg>
          </template>
          <template v-else>{{ progressDisplay.text }}</template>
        </span>
      </div>

      <!-- Bottom-left episode badge: Current/Latest chapter (matches APP) -->
      <div v-if="showEpisodeBadge" class="episode-badge">
        <span v-if="currentChapter" class="ep-line">Current: {{ currentChapter }}</span>
        <span v-if="latestChapter" class="ep-line">Latest: {{ latestChapter }}</span>
      </div>

      <!-- Brief overlay text (bottom-right) -->
      <div v-if="mode === 'brief' && briefLines.length" class="brief-overlay">
        <span v-for="line in briefLines" :key="line">{{ line }}</span>
      </div>
    </div>

    <div v-if="mode === 'detailed'" class="detail-body">
      <div class="detail-title">{{ title }}</div>
      <div v-if="stars > 0" class="detail-rating">
        <span v-for="n in 5" :key="n" class="star" :class="{ filled: n <= stars }">&#9733;</span>
        <span class="rating-num">{{ stars.toFixed(1) }}</span>
      </div>
      <div class="info-rows">
        <div v-for="row in infoRows" :key="row.label" class="info-row">
          <span class="info-label" :style="{ background: row.color + '2e', color: row.color }">{{ row.label }}</span>
          <span class="info-value">{{ row.value }}</span>
        </div>
      </div>
    </div>

    <div v-else class="brief-title">{{ title }}</div>
  </article>
</template>

<style scoped>
.comic-tile {
  cursor: pointer;
  transition: transform 0.15s ease;
  contain: content;
  transform: translateZ(0);
}
.comic-tile:active { transform: scale(0.97); }
.comic-tile.brief { width: 100%; }
.comic-tile.detailed {
  height: calc(168px * var(--tile-scale));
  min-height: 128px;
  display: flex;
  gap: 14px;
  padding: 8px 14px 8px 8px;
  border-radius: 8px;
}

.cover-wrap { position: relative; overflow: hidden; border-radius: 8px; background: #f0f0f0; }

/* Status icons (top-left, matches APP ComicTile) */
.status-icons {
  position: absolute; top: 0; left: 0;
  display: flex; gap: 0; height: 24px; z-index: 2;
}
.comic-tile.detailed .status-icons { left: 0; }
.icon-fav {
  display: flex; align-items: center; justify-content: center;
  width: 24px; height: 24px; background: #4caf50; flex-shrink: 0;
}
.icon-progress {
  display: flex; align-items: center; justify-content: center;
  min-width: 24px; height: 24px; padding: 0 4px;
  background: rgba(33, 150, 243, 0.9);
  color: #fff; font-size: 12px; font-weight: 600; line-height: 1;
  box-sizing: border-box; flex-shrink: 0;
}
.icon-progress.page-only { font-size: 14px; }
.icon-progress.fraction { font-size: 11px; }
.icon-progress.checkmark { padding: 0; min-width: 24px; width: 24px; }

/* Episode badge (bottom-left, matches APP _buildEpisodeBadge) */
.episode-badge {
  position: absolute; left: 0; bottom: 0; max-width: 72%;
  display: flex; flex-direction: column; gap: 1px;
  padding: 2px 6px; border-radius: 6px;
  background: rgba(33, 150, 243, 0.72); z-index: 2;
}
.ep-line {
  color: #fff; font-size: 10px; font-weight: 600; line-height: 1.2;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}

.brief .cover-wrap { width: 100%; aspect-ratio: 0.64; }
.detailed .cover-wrap {
  width: calc((168px * var(--tile-scale) - 44px) * 0.68);
  min-width: 70px; height: 100%; flex-shrink: 0;
}
.cover { width: 100%; height: 100%; display: block; }
.cover :deep(img) { width: 100%; height: 100%; object-fit: cover; }

/* Detailed mode */
.detail-body { min-width: 0; flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.detail-title {
  font-size: 14px; font-weight: 500; line-height: 1.3; color: #222;
  overflow: hidden; display: -webkit-box; -webkit-line-clamp: 1; -webkit-box-orient: vertical;
  margin-bottom: 4px;
}
.detail-rating { display: flex; align-items: center; gap: 2px; margin-bottom: 2px; }
.star { font-size: 13px; color: #ddd; }
.star.filled { color: #f5a623; }
.rating-num { font-size: 11px; color: #999; margin-left: 4px; }
.info-rows { flex: 1; display: flex; flex-direction: column; gap: 3px; overflow-y: auto; }
.info-row { display: flex; align-items: center; gap: 6px; min-width: 0; }
.info-label {
  flex-shrink: 0; height: 18px; padding: 0 6px; border-radius: 10px;
  font-size: 11px; font-weight: 600; line-height: 18px; white-space: nowrap;
}
.info-value {
  flex: 1; min-width: 0; font-size: 12px; line-height: 18px; color: #555;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}

/* Brief mode */
.brief-overlay {
  position: absolute; right: 2px; bottom: 2px;
  display: flex; flex-direction: column; align-items: flex-end; gap: 2px;
  max-width: calc(100% - 4px);
}
.brief-overlay span {
  max-width: 100%; padding: 2px 5px; border-radius: 6px; color: #fff;
  background: rgba(0, 0, 0, 0.55); font-size: 11px; line-height: 1.2;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.brief-title {
  margin-top: 4px; padding: 0 4px; font-size: 14px; font-weight: 500; line-height: 1.25;
  color: #222; white-space: nowrap; overflow: hidden; text-overflow: clip;
}
</style>
