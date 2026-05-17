<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { apiPost } from '@/services/api'
import { getComicSources, getSourceCapabilities } from '@/services/server-db'
import type { ComicSource, SourceCapabilities } from '@/types'

const router = useRouter()
const route = useRoute()
const sources = ref<ComicSource[]>([])
const loading = ref(false)
const addUrl = ref('')
const adding = ref(false)
const activeNames = ref<string[]>([])
const capabilities = ref<Record<string, SourceCapabilities | null>>({})
const capLoading = ref<Record<string, boolean>>({})
const checkingUpdates = ref(false)

const highlightKey = computed(() => (route.query.highlight as string) || '')

async function loadSources() {
  loading.value = true
  try {
    sources.value = await getComicSources()
    if (highlightKey.value && !activeNames.value.includes(highlightKey.value)) {
      activeNames.value.push(highlightKey.value)
      loadCapabilities(highlightKey.value)
    }
  } catch (e: any) {
    showToast({ message: '加载失败: ' + e.message, type: 'fail' })
  } finally {
    loading.value = false
  }
}

async function loadCapabilities(sourceKey: string) {
  if (capabilities.value[sourceKey] || capLoading.value[sourceKey]) return
  capLoading.value[sourceKey] = true
  try {
    capabilities.value[sourceKey] = await getSourceCapabilities(sourceKey)
  } catch {
    capabilities.value[sourceKey] = null
  } finally {
    capLoading.value[sourceKey] = false
  }
}

function onCollapseChange(names: string | string[]) {
  const arr = Array.isArray(names) ? names : [names]
  activeNames.value = arr
  for (const key of arr) {
    loadCapabilities(key)
  }
}

async function addSource() {
  const url = addUrl.value.trim()
  if (!url) return
  adding.value = true
  try {
    await apiPost('/api/server-db/sources/add', { url })
    showToast({ message: '添加成功', type: 'success' })
    addUrl.value = ''
    await loadSources()
  } catch (e: any) {
    showToast({ message: '添加失败: ' + e.message, type: 'fail' })
  } finally {
    adding.value = false
  }
}

async function deleteSource(sourceKey: string, sourceName: string) {
  try {
    await showConfirmDialog({ title: '删除漫画源', message: `确定删除 "${sourceName}" 吗？` })
    await apiPost('/api/server-db/sources/delete', { sourceKey })
    showToast({ message: '已删除', type: 'success' })
    await loadSources()
  } catch { /* cancelled */ }
}

async function updateSource(sourceKey: string) {
  try {
    const res = await apiPost<any>('/api/server-db/sources/update', { sourceKey })
    if (res?.updated) {
      showToast({ message: '已更新到 v' + res.version, type: 'success' })
      await loadSources()
    } else {
      showToast({ message: res?.message || '已是最新版本' })
    }
  } catch (e: any) {
    showToast({ message: '更新失败: ' + e.message, type: 'fail' })
  }
}

async function checkAllUpdates() {
  checkingUpdates.value = true
  try {
    const res = await apiPost<any>('/api/server-db/sources/check-updates')
    const count = res?.updatedCount ?? 0
    if (count > 0) {
      showToast({ message: `已更新 ${count} 个漫画源`, type: 'success' })
      await loadSources()
    } else {
      showToast({ message: '所有漫画源已是最新' })
    }
  } catch (e: any) {
    showToast({ message: '检查更新失败: ' + e.message, type: 'fail' })
  } finally {
    checkingUpdates.value = false
  }
}

function browseSourceList() {
  router.push('/explore')
}

onMounted(() => { loadSources() })
</script>

<template>
  <div class="source-page">
    <!-- Header -->
    <div class="page-header">
      <h2 class="page-title">漫画源管理</h2>
      <div class="header-actions">
        <van-button size="small" :loading="checkingUpdates" @click="checkAllUpdates" icon="replay">
          检查更新
        </van-button>
        <van-button size="small" type="primary" @click="browseSourceList" icon="apps-o">
          漫画源列表
        </van-button>
      </div>
    </div>

    <!-- Add Source -->
    <div class="add-source-card">
      <van-field
        v-model="addUrl"
        placeholder="输入漫画源 URL 添加"
        clearable
        @keyup.enter="addSource"
      >
        <template #button>
          <van-button size="small" type="primary" :loading="adding" @click="addSource">
            添加
          </van-button>
        </template>
      </van-field>
    </div>

    <!-- Sources List -->
    <div class="sources-list" v-if="sources.length">
      <van-collapse v-model="activeNames" @change="onCollapseChange">
        <van-collapse-item
          v-for="source in sources"
          :key="source.key"
          :name="source.key"
          :class="{ 'highlight-source': highlightKey === source.key }"
        >
          <template #title>
            <div class="source-title-row">
              <span class="source-name">{{ source.name }}</span>
              <span class="source-version">v{{ source.version }}</span>
            </div>
          </template>
          <template #label>
            <span class="source-key">{{ source.key }}</span>
          </template>

          <div class="source-detail">
            <!-- Actions -->
            <div class="source-actions">
              <van-button size="small" icon="replay" @click.stop="updateSource(source.key)">
                更新
              </van-button>
              <van-button size="small" icon="delete-o" type="danger" plain
                @click.stop="deleteSource(source.key, source.name)">
                删除
              </van-button>
            </div>

            <!-- Capabilities Loading -->
            <div v-if="capLoading[source.key]" class="cap-loading">
              <van-loading size="20px">加载中...</van-loading>
            </div>

            <!-- Account Section -->
            <div v-if="capabilities[source.key]?.account?.hasLogin" class="source-section">
              <div class="section-label">账号</div>
              <div class="account-actions">
                <van-button size="small" icon="user-o" type="primary" plain disabled>
                  登录（Web 端暂不支持）
                </van-button>
              </div>
            </div>

            <!-- Settings Section -->
            <div v-if="capabilities[source.key]?.settings" class="source-section">
              <div class="section-label">设置</div>
              <div class="settings-info">
                <span class="settings-hint">此漫画源有可配置的设置项（Web 端暂不支持）</span>
              </div>
            </div>

            <!-- Capabilities Info -->
            <div v-if="capabilities[source.key]" class="source-section">
              <div class="section-label">功能</div>
              <div class="cap-tags">
                <span class="cap-tag" v-if="capabilities[source.key]?.search">搜索</span>
                <span class="cap-tag" v-if="capabilities[source.key]?.explore?.length">发现</span>
                <span class="cap-tag" v-if="capabilities[source.key]?.category">分类</span>
                <span class="cap-tag" v-if="capabilities[source.key]?.favorites">收藏</span>
                <span class="cap-tag" v-if="capabilities[source.key]?.account">账号</span>
              </div>
            </div>

            <!-- Source URL -->
            <div class="source-url" v-if="source.url">
              <van-icon name="link-o" size="14" />
              <span>{{ source.url }}</span>
            </div>
          </div>
        </van-collapse-item>
      </van-collapse>
    </div>

    <!-- Empty State -->
    <div class="empty-state" v-else-if="!loading">
      <van-icon name="info-o" size="48" color="#ccc" />
      <p>暂无已安装的漫画源</p>
      <van-button type="primary" size="small" @click="browseSourceList">
        浏览漫画源列表
      </van-button>
    </div>
  </div>
</template>

<style scoped>
.source-page {
  padding: 16px;
  max-width: 800px;
  margin: 0 auto;
}

.page-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 16px;
  flex-wrap: wrap;
  gap: 8px;
}

.page-title {
  font-size: 20px;
  font-weight: 600;
  margin: 0;
  color: #333;
}

.header-actions {
  display: flex;
  gap: 8px;
}

.add-source-card {
  background: #fff;
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 16px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
}

.sources-list {
  background: #fff;
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
}

.source-title-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.source-name {
  font-weight: 500;
  font-size: 15px;
  color: #333;
}

.source-version {
  font-size: 12px;
  color: #4f6ef7;
  background: rgba(79, 110, 247, 0.08);
  padding: 2px 6px;
  border-radius: 4px;
}

.source-key {
  font-size: 12px;
  color: #999;
  font-family: monospace;
}

.highlight-source {
  background: rgba(79, 110, 247, 0.04);
}

.source-detail {
  padding: 4px 0;
}

.source-actions {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
}

.cap-loading {
  padding: 12px 0;
  text-align: center;
}

.source-section {
  margin-top: 12px;
  padding-top: 12px;
  border-top: 1px solid #f0f0f0;
}

.section-label {
  font-size: 13px;
  font-weight: 500;
  color: #666;
  margin-bottom: 8px;
}

.account-actions {
  display: flex;
  gap: 8px;
}

.settings-hint {
  font-size: 13px;
  color: #999;
}

.cap-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.cap-tag {
  font-size: 12px;
  padding: 2px 8px;
  border-radius: 4px;
  background: rgba(79, 110, 247, 0.08);
  color: #4f6ef7;
}

.source-url {
  margin-top: 12px;
  padding-top: 12px;
  border-top: 1px solid #f0f0f0;
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: #999;
  word-break: break-all;
}

.empty-state {
  text-align: center;
  padding: 48px 16px;
  color: #999;
}

.empty-state p {
  margin: 12px 0 16px;
  font-size: 14px;
}
</style>
