<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'
import { useRouter } from 'vue-router'
import { searchComics, getComicSources } from '@/services/server-db'
import ComicCard from '@/components/ComicCard.vue'
import type { ComicSource } from '@/types'

interface SearchResult {
  id: string
  title: string
  cover: string
  subtitle?: string
  sourceKey?: string
}

interface SourceRow {
  source: ComicSource
  comics: SearchResult[]
  hasMore: boolean
  loading: boolean
  error: string | null
}

const props = defineProps<{
  keyword: string
}>()

const router = useRouter()
const rows = ref<SourceRow[]>([])
const hasResults = ref(false)

async function loadAll() {
  if (!props.keyword.trim()) return
  const sources = await getComicSources()
  rows.value = sources.map(source => ({
    source,
    comics: [],
    hasMore: false,
    loading: true,
    error: null,
  }))

  await Promise.allSettled(
    rows.value.map(async (row) => {
      try {
        const res = await searchComics(row.source.key, props.keyword.trim(), 1)
        row.comics = (res.comics ?? []).map((c: any) => ({
          ...c,
          sourceKey: c.sourceKey || row.source.key,
        }))
        row.hasMore = res.hasMore
        row.loading = false
      } catch (e: any) {
        row.error = e.message ?? '搜索失败'
        row.loading = false
      }
    })
  )

  hasResults.value = rows.value.some(r => r.comics.length > 0)
}

function navigateToSource(sourceKey: string) {
  router.push({
    path: `/search/${encodeURIComponent(sourceKey)}`,
    query: { keyword: props.keyword.trim() },
  })
}

watch(() => props.keyword, () => {
  if (props.keyword.trim()) loadAll()
})

onMounted(() => {
  if (props.keyword.trim()) loadAll()
})
</script>

<template>
  <div class="aggregated-results">
    <van-empty
      v-if="!hasResults && rows.every(r => !r.loading)"
      description="没有找到结果"
      image="search"
    />
    <div
      v-for="row in rows"
      :key="row.source.key"
      class="source-row"
    >
      <div class="row-header" @click="navigateToSource(row.source.key)">
        <h3 class="row-title">{{ row.source.name }}</h3>
        <span class="row-view-all">查看全部 &gt;</span>
      </div>
      <div v-if="row.loading" class="row-loading">
        <div class="shimmer-cards">
          <div v-for="n in 4" :key="n" class="shimmer-card" />
        </div>
      </div>
      <div v-else-if="row.error" class="row-error">
        <span>{{ row.error }}</span>
      </div>
      <div v-else-if="row.comics.length" class="row-scroll">
        <ComicCard
          v-for="comic in row.comics"
          :key="`${row.source.key}:${comic.id}`"
          :comic="comic"
          :source-key="row.source.key"
          :source-name="row.source.name"
          class="row-comic-card"
        />
      </div>
      <div v-else class="row-empty">
        <span>暂无结果</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.aggregated-results {
  padding-bottom: 24px;
}

.source-row {
  margin-bottom: 20px;
}

.row-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 4px 8px;
  cursor: pointer;
}

.row-header:active {
  opacity: 0.7;
}

.row-title {
  font-size: 15px;
  font-weight: 600;
  color: #333;
  margin: 0;
}

.row-view-all {
  font-size: 12px;
  color: #4f6ef7;
}

.row-scroll {
  display: flex;
  gap: 10px;
  overflow-x: auto;
  padding: 4px 0 8px;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
}

.row-scroll::-webkit-scrollbar {
  display: none;
}

.row-comic-card {
  flex-shrink: 0;
  width: 120px;
}

.row-loading {
  padding: 4px 0;
}

.shimmer-cards {
  display: flex;
  gap: 10px;
}

.shimmer-card {
  flex-shrink: 0;
  width: 120px;
  height: 180px;
  border-radius: 4px;
  background: linear-gradient(90deg, #f0f0f0 25%, #e0e0e0 50%, #f0f0f0 75%);
  background-size: 200% 100%;
  animation: shimmer 1.5s infinite;
}

@keyframes shimmer {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}

.row-error,
.row-empty {
  padding: 12px;
  font-size: 13px;
  color: #999;
  text-align: center;
  background: #fafafa;
  border-radius: 6px;
}
</style>
