<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { getSourceCapabilities, getRanking } from '@/services/server-db'
import { useSettingsStore } from '@/stores/settings'
import ComicCard from '@/components/ComicCard.vue'
import type { SourceCapabilities } from '@/types'

interface RankingComic {
  id: string
  title: string
  cover: string
  subtitle?: string
}

const router = useRouter()
const route = useRoute()
const settingsStore = useSettingsStore()

const sourceKey = computed(() => (route.query.sourceKey as string) || '')

const capabilities = ref<SourceCapabilities | null>(null)
const sourceName = ref('')

const rankingOptions = ref<Array<{ key: string; label: string }>>([])
const rankingSelected = ref('')
const comics = ref<RankingComic[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const hasMore = ref(false)
const page = ref(1)

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

function parseRankingOption(entry: string): { key: string; label: string } {
  const idx = entry.indexOf('-')
  if (idx > 0) return { key: entry.substring(0, idx), label: entry.substring(idx + 1) }
  return { key: entry, label: entry }
}

async function loadRanking(reset = false) {
  if (!sourceKey.value || !rankingSelected.value) return
  if (loading.value) return
  loading.value = true
  error.value = null

  const targetPage = reset ? 1 : page.value + 1
  try {
    const res = await getRanking(sourceKey.value, rankingSelected.value, targetPage)
    if (reset) {
      comics.value = res.comics
    } else {
      comics.value = [...comics.value, ...res.comics]
    }
    page.value = targetPage
    hasMore.value = res.hasMore
  } catch (e: any) {
    error.value = e.message ?? '加载排行榜失败'
  } finally {
    loading.value = false
  }
}

function onOptionChange(key: string) {
  rankingSelected.value = key
  loadRanking(true)
}

async function loadMore() {
  await loadRanking(false)
}

onMounted(async () => {
  await settingsStore.loadSettings()
  if (!sourceKey.value) {
    error.value = '缺少來源參數'
    return
  }

  const caps = await getSourceCapabilities(sourceKey.value)
  capabilities.value = caps
  sourceName.value = caps?.name || sourceKey.value

  const rawOpts = caps?.categoryComics?.rankingOptions
  if (rawOpts && rawOpts.length > 0) {
    rankingOptions.value = rawOpts.map(parseRankingOption)
    rankingSelected.value = rankingOptions.value[0].key
    await loadRanking(true)
  } else {
    error.value = '该源没有排行榜数据'
  }
})
</script>

<template>
  <div class="ranking-page">
    <van-nav-bar
      title="排行榜"
      left-arrow
      @click-left="router.back()"
    />

    <div v-if="rankingOptions.length > 0" class="ranking-options">
      <van-tag
        v-for="opt in rankingOptions"
        :key="opt.key"
        :type="rankingSelected === opt.key ? 'primary' : 'default'"
        size="medium"
        class="ranking-option-chip"
        @click="onOptionChange(opt.key)"
      >
        {{ opt.label }}
      </van-tag>
    </div>

    <div class="ranking-content">
      <div v-if="loading && !comics.length" class="loading-state">
        <van-loading size="36px" color="#4f6ef7" vertical>加载中...</van-loading>
      </div>

      <div v-if="error && !comics.length && !loading" class="error-state">
        <van-empty image="error" :description="error" />
        <van-button type="primary" size="small" @click="loadRanking(true)">重试</van-button>
      </div>

      <div v-if="comics.length" class="comic-grid" :style="gridStyle">
        <ComicCard
          v-for="comic in comics"
          :key="comic.id"
          :comic="comic"
          :source-key="sourceKey"
          :source-name="sourceName"
          class="comic-card"
        />
      </div>

      <div v-if="comics.length && hasMore" class="load-more">
        <van-loading v-if="loading" size="24px" />
        <van-button v-else size="small" plain @click="loadMore">加载更多</van-button>
      </div>

      <van-empty
        v-if="!loading && !comics.length && !error"
        description="暂无排行榜数据"
        image="search"
      />
    </div>
  </div>
</template>

<style scoped>
.ranking-page {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.ranking-options {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 10px 16px;
  border-bottom: 1px solid #f0f0f0;
}

.ranking-option-chip {
  cursor: pointer;
  transition: all 0.2s;
}

.ranking-content {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
}

.loading-state {
  display: flex;
  justify-content: center;
  padding: 48px 0;
}

.error-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px 0;
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

.load-more {
  display: flex;
  justify-content: center;
  padding: 16px 0 24px;
}
</style>
