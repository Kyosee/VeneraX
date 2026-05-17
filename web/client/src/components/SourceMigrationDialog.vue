<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { showToast } from 'vant'
import { getComicSources, searchComics as searchSourceComics, startSourceMigration, linkRelatedSource } from '@/services/server-db'
import type { SourceMigrationParams } from '@/services/server-db'
import type { ComicSource } from '@/types'

const props = defineProps<{
  show: boolean
  mode: 'single' | 'batch'
  comic?: { id: string; name: string; type: number; sourceKey?: string; folder?: string }
  comics?: Array<{ id: string; name: string; type: number; sourceKey?: string; folder?: string }>
  folder?: string
}>()

const emit = defineEmits<{
  (e: 'update:show', value: boolean): void
  (e: 'done'): void
}>()

const sources = ref<ComicSource[]>([])
const selectedSourceKeys = ref<Set<string>>(new Set())
const migrateHistory = ref(true)
const replaceFavorite = ref(true)
const confirmEach = ref(false)
const step = ref<'config' | 'searching' | 'results' | 'confirming'>('config')
const singleResults = ref<Record<string, Array<{ id: string; title: string; cover: string; sourceKey: string }>>>({})
const selectedTarget = ref<{ id: string; title: string; sourceKey: string } | null>(null)
const searchLoading = ref(false)

const comicName = computed(() => props.comic?.name || props.comics?.[0]?.name || '')
const comicCount = computed(() => props.mode === 'batch' ? (props.comics?.length || 0) : 1)

watch(() => props.show, async (val) => {
  if (!val) return
  step.value = 'config'
  selectedSourceKeys.value = new Set()
  selectedTarget.value = null
  singleResults.value = {}
  const list = await getComicSources()
  sources.value = list.filter(s => {
    if (props.mode === 'single') return s.key !== props.comic?.sourceKey
    return true
  })
  if (props.mode === 'single') searchKeyword.value = comicName.value
})

const searchKeyword = ref('')

function toggleSource(key: string) {
  const s = new Set(selectedSourceKeys.value)
  if (s.has(key)) { s.delete(key) } else { s.add(key) }
  selectedSourceKeys.value = s
}

async function doSingleSearch() {
  if (!searchKeyword.value.trim()) return
  searchLoading.value = true
  singleResults.value = {}
  const keys = selectedSourceKeys.value.size > 0
    ? [...selectedSourceKeys.value]
    : sources.value.map(s => s.key)
  await Promise.allSettled(keys.map(async (key) => {
    try {
      const res = await searchSourceComics(key, searchKeyword.value.trim(), 1)
      singleResults.value[key] = res.comics.slice(0, 8)
    } catch { singleResults.value[key] = [] }
  }))
  searchLoading.value = false
  step.value = 'results'
}

function selectTarget(target: { id: string; title: string; sourceKey: string }) {
  selectedTarget.value = target
}

async function doSingleMigrate() {
  if (!selectedTarget.value || !props.comic) return
  try {
    await linkRelatedSource(
      props.comic.sourceKey || '',
      props.comic.id,
      selectedTarget.value.sourceKey,
      selectedTarget.value.id,
    )
  } catch { /* best-effort */ }
  const params: SourceMigrationParams = {
    folder: props.comic.folder || '',
    favorites: [{
      id: props.comic.id,
      type: props.comic.type,
      name: props.comic.name,
      sourceKey: props.comic.sourceKey || '',
    }],
    targetSourceKeys: [selectedTarget.value.sourceKey],
    migrateHistory: migrateHistory.value,
    replaceFavorite: replaceFavorite.value,
    confirmEach: false,
  }
  const res = await startSourceMigration(params)
  if (res.taskId) {
    showToast('迁移任务已启动')
    emit('done')
    emit('update:show', false)
  } else {
    showToast('启动迁移失败')
  }
}

async function doBatchMigrate() {
  if (selectedSourceKeys.value.size === 0) {
    showToast('请选择目标源')
    return
  }
  if (!props.comics || !props.folder) return
  const params: SourceMigrationParams = {
    folder: props.folder,
    favorites: props.comics.map(c => ({
      id: c.id,
      type: c.type,
      name: c.name,
      sourceKey: c.sourceKey || '',
    })),
    targetSourceKeys: [...selectedSourceKeys.value],
    migrateHistory: migrateHistory.value,
    replaceFavorite: replaceFavorite.value,
    confirmEach: confirmEach.value,
  }
  const res = await startSourceMigration(params)
  if (res.taskId) {
    showToast('迁移任务已启动')
    emit('done')
    emit('update:show', false)
  } else {
    showToast('启动迁移失败')
  }
}

function close() {
  emit('update:show', false)
}
</script>

<template>
  <van-popup
    :show="show"
    round
    position="center"
    :style="{ width: '440px', maxWidth: '92vw', maxHeight: '80vh', padding: '20px', background: '#fff', color: '#1a1a1a' }"
    @update:show="$emit('update:show', $event)"
  >
    <div class="migration-dialog">
      <h3 style="margin:0 0 4px; font-size:16px;">
        {{ mode === 'single' ? '迁移漫画源' : `批量迁移 ${comicCount} 个漫画` }}
      </h3>
      <p style="color:#999;font-size:12px;margin:0 0 12px;">{{ comicName }}</p>

      <!-- Config step -->
      <template v-if="step === 'config'">
        <!-- Target source selector -->
        <div style="margin-bottom:10px;">
          <div style="font-size:13px; font-weight:500; margin-bottom:6px;">目标源</div>
          <div class="source-chips">
            <van-tag
              v-for="s in sources" :key="s.key"
              :type="selectedSourceKeys.has(s.key) ? 'primary' : 'default'"
              size="medium"
              class="source-chip"
              @click="toggleSource(s.key)"
            >{{ s.name }}</van-tag>
          </div>
        </div>

        <!-- Single mode: search field -->
        <template v-if="mode === 'single'">
          <van-field v-model="searchKeyword" label="关键词" placeholder="输入漫画名称搜索" @keyup.enter="doSingleSearch" />
          <div style="display:flex;justify-content:flex-end;margin-top:8px;">
            <van-button size="small" type="primary" :loading="searchLoading" @click="doSingleSearch">搜索</van-button>
          </div>
        </template>

        <!-- Options -->
        <div style="margin-top:12px;">
          <van-cell title="迁移阅读进度" center>
            <template #right-icon><van-switch v-model="migrateHistory" size="20" /></template>
          </van-cell>
          <van-cell title="替换收藏（删除源漫画）" center>
            <template #right-icon><van-switch v-model="replaceFavorite" size="20" /></template>
          </van-cell>
          <van-cell v-if="mode === 'batch'" title="逐项确认" center>
            <template #right-icon><van-switch v-model="confirmEach" size="20" /></template>
          </van-cell>
        </div>

        <!-- Actions -->
        <div style="display:flex;justify-content:flex-end;gap:10px;margin-top:12px;">
          <van-button size="small" plain @click="close">取消</van-button>
          <van-button size="small" type="primary" @click="mode === 'single' ? doSingleSearch() : doBatchMigrate()">
            {{ mode === 'single' ? '搜索' : '开始迁移' }}
          </van-button>
        </div>
      </template>

      <!-- Search results -->
      <template v-if="step === 'results'">
        <div
          v-if="!Object.values(singleResults).some(r => r.length)"
          style="text-align:center;padding:20px;color:#999;"
        >暂无匹配结果</div>
        <div v-else class="results-list">
          <div v-for="(results, sourceKey) in singleResults" :key="sourceKey" style="margin-bottom:10px;">
            <div style="font-size:12px;color:#999;margin-bottom:4px;">{{ sources.find(s => s.key === sourceKey)?.name || sourceKey }}</div>
            <div
              v-for="r in results.filter(x => x.id)"
              :key="`${sourceKey}:${r.id}`"
              class="result-item"
              :class="{ selected: selectedTarget?.id === r.id && selectedTarget?.sourceKey === sourceKey }"
              @click="selectTarget({ id: r.id, title: r.title, sourceKey })"
            >
              <van-image :src="r.cover" width="42" height="56" fit="cover" radius="4" />
              <div class="result-info">
                <div class="result-title">{{ r.title }}</div>
                <div class="result-source">{{ sources.find(s => s.key === sourceKey)?.name || sourceKey }}</div>
              </div>
              <van-icon v-if="selectedTarget?.id === r.id && selectedTarget?.sourceKey === sourceKey" name="checked" color="#4f6ef7" size="18" />
            </div>
          </div>
        </div>
        <div style="display:flex;justify-content:flex-end;gap:10px;margin-top:12px;">
          <van-button size="small" plain @click="step = 'config'">返回</van-button>
          <van-button size="small" type="primary" :disabled="!selectedTarget" @click="doSingleMigrate">迁移</van-button>
        </div>
      </template>
    </div>
  </van-popup>
</template>

<style scoped>
.migration-dialog { max-height: 70vh; overflow-y: auto; }
.source-chips { display: flex; flex-wrap: wrap; gap: 6px; }
.source-chip { cursor: pointer; }
.results-list { max-height: 40vh; overflow-y: auto; }
.result-item {
  display: flex; align-items: center; gap: 10px;
  padding: 8px 10px; border-radius: 8px; cursor: pointer;
  transition: background 0.15s;
}
.result-item:hover, .result-item.selected { background: #f0f4ff; }
.result-info { flex: 1; min-width: 0; }
.result-title { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.result-source { font-size: 11px; color: #999; }
</style>
