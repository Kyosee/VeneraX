<script setup lang="ts">
import { ref, reactive, computed } from 'vue'
import { showToast, showConfirmDialog } from 'vant'
import { listFavorites, listHistory, getComicSources, upsertHistory } from '@/services/server-db'
import { apiPost } from '@/services/api'

// Task types
type TaskType = 'follow_update' | 'history_refresh' | 'source_update'
type TaskStatus = 'pending' | 'running' | 'completed' | 'failed' | 'cancelled'

interface Task {
  id: string
  type: TaskType
  title: string
  status: TaskStatus
  progress: number
  total: number
  currentItem: string
  error?: string
  startTime: number
  endTime?: number
}

const activeTab = ref(0)
const tasks = reactive<Task[]>([])
const showActionSheet = ref(false)

// Abort controllers for cancellation
const abortControllers = new Map<string, AbortController>()

const currentTasks = computed(() =>
  tasks.filter(t => t.status === 'running' || t.status === 'pending')
)
const historyTasks = computed(() =>
  tasks.filter(t => t.status === 'completed' || t.status === 'failed' || t.status === 'cancelled')
)

function getTaskIcon(type: TaskType): string {
  switch (type) {
    case 'follow_update': return 'bell'
    case 'history_refresh': return 'replay'
    case 'source_update': return 'upgrade'
  }
}

function getTaskTypeLabel(type: TaskType): string {
  switch (type) {
    case 'follow_update': return '检查追更'
    case 'history_refresh': return '刷新历史'
    case 'source_update': return '更新漫画源'
  }
}

function getStatusText(task: Task): string {
  switch (task.status) {
    case 'pending': return '等待中...'
    case 'running':
      return task.currentItem
        ? `${task.currentItem} (${task.progress}/${task.total})`
        : `${task.progress}/${task.total}`
    case 'completed': return `完成 (${task.total} 项)`
    case 'failed': return task.error || '失败'
    case 'cancelled': return '已取消'
  }
}

function getStatusColor(status: TaskStatus): string {
  switch (status) {
    case 'running': return '#4f6ef7'
    case 'completed': return '#27ae60'
    case 'failed': return '#e74c3c'
    case 'cancelled': return '#999'
    default: return '#666'
  }
}

function formatDuration(start: number, end?: number): string {
  const ms = (end || Date.now()) - start
  const s = Math.floor(ms / 1000)
  if (s < 60) return `${s}秒`
  return `${Math.floor(s / 60)}分${s % 60}秒`
}

function createTask(type: TaskType): Task {
  return {
    id: `${type}_${Date.now()}`,
    type,
    title: getTaskTypeLabel(type),
    status: 'pending',
    progress: 0,
    total: 0,
    currentItem: '',
    startTime: Date.now()
  }
}

function startTask(type: TaskType) {
  // Prevent duplicate running tasks of same type
  if (currentTasks.value.some(t => t.type === type)) {
    showToast('该任务正在运行中')
    return
  }
  const task = createTask(type)
  tasks.unshift(task)
  showActionSheet.value = false

  switch (type) {
    case 'follow_update': runFollowUpdateTask(task); break
    case 'history_refresh': runHistoryRefreshTask(task); break
    case 'source_update': runSourceUpdateTask(task); break
  }
}

async function runFollowUpdateTask(task: Task) {
  const controller = new AbortController()
  abortControllers.set(task.id, controller)
  task.status = 'running'

  try {
    const favorites = await listFavorites()
    task.total = favorites.length
    if (task.total === 0) {
      task.status = 'completed'
      task.endTime = Date.now()
      return
    }

    let updatedCount = 0
    for (let i = 0; i < favorites.length; i++) {
      if (controller.signal.aborted) {
        task.status = 'cancelled'
        task.endTime = Date.now()
        return
      }
      const fav = favorites[i]
      task.currentItem = fav.name
      task.progress = i + 1

      try {
        const folder = (fav as any).folder
        if (!folder) continue
        await apiPost('/api/server-db/favorites/check-time', {
          folder,
          id: fav.id,
          type: fav.type,
          lastCheckTime: Date.now(),
        })
        updatedCount++
      } catch (e) {
        // Skip individual failures
      }
    }
    task.currentItem = `完成，检查了 ${updatedCount} 项`
    task.status = 'completed'
  } catch (e: any) {
    task.error = e.message || '未知错误'
    task.status = 'failed'
  } finally {
    task.endTime = Date.now()
    abortControllers.delete(task.id)
  }
}

async function runHistoryRefreshTask(task: Task) {
  const controller = new AbortController()
  abortControllers.set(task.id, controller)
  task.status = 'running'

  try {
    const historyResult = await listHistory()
    const historyItems = historyResult.items
    task.total = historyItems.length
    if (task.total === 0) {
      task.status = 'completed'
      task.endTime = Date.now()
      return
    }

    let refreshed = 0
    for (let i = 0; i < historyItems.length; i++) {
      if (controller.signal.aborted) {
        task.status = 'cancelled'
        task.endTime = Date.now()
        return
      }
      const item = historyItems[i]
      task.currentItem = item.title
      task.progress = i + 1

      try {
        await upsertHistory({ ...item })
        refreshed++
      } catch (e) {
        // Skip individual failures
      }
    }
    task.currentItem = `完成，刷新了 ${refreshed} 项`
    task.status = 'completed'
  } catch (e: any) {
    task.error = e.message || '未知错误'
    task.status = 'failed'
  } finally {
    task.endTime = Date.now()
    abortControllers.delete(task.id)
  }
}

async function runSourceUpdateTask(task: Task) {
  const controller = new AbortController()
  abortControllers.set(task.id, controller)
  task.status = 'running'

  try {
    const sources = await getComicSources()
    task.total = sources.length
    if (task.total === 0) {
      task.status = 'completed'
      task.endTime = Date.now()
      return
    }

    let checked = 0
    for (let i = 0; i < sources.length; i++) {
      if (controller.signal.aborted) {
        task.status = 'cancelled'
        task.endTime = Date.now()
        return
      }
      const src = sources[i]
      task.currentItem = src.name
      task.progress = i + 1

      try {
        await apiPost('/api/source/check-update', { sourceKey: src.key })
        checked++
      } catch (e) {
        // Skip individual failures
      }
    }
    task.currentItem = `完成，检查了 ${checked} 个源`
    task.status = 'completed'
  } catch (e: any) {
    task.error = e.message || '未知错误'
    task.status = 'failed'
  } finally {
    task.endTime = Date.now()
    abortControllers.delete(task.id)
  }
}

function cancelTask(task: Task) {
  showConfirmDialog({ title: '取消任务', message: `确定取消「${task.title}」？` })
    .then(() => {
      const controller = abortControllers.get(task.id)
      if (controller) controller.abort()
      else {
        task.status = 'cancelled'
        task.endTime = Date.now()
      }
    })
    .catch(() => {})
}

function clearHistoryTasks() {
  const toRemove = historyTasks.value.map(t => t.id)
  toRemove.forEach(id => {
    const idx = tasks.findIndex(t => t.id === id)
    if (idx >= 0) tasks.splice(idx, 1)
  })
}

function progressPercent(task: Task): number {
  if (task.total === 0) return 0
  return Math.round((task.progress / task.total) * 100)
}

const taskActions = [
  { name: '检查追更', value: 'follow_update' as TaskType, icon: 'bell' },
  { name: '刷新历史', value: 'history_refresh' as TaskType, icon: 'replay' },
  { name: '更新漫画源', value: 'source_update' as TaskType, icon: 'upgrade' },
]
</script>

<template>
  <div class="tasks-page">
    <van-nav-bar title="任务">
      <template #right>
        <van-icon
          v-if="historyTasks.length > 0 && activeTab === 1"
          name="delete-o"
          size="20"
          @click="clearHistoryTasks"
        />
      </template>
    </van-nav-bar>

    <van-tabs v-model:active="activeTab" sticky>
      <van-tab title="当前">
        <div class="task-list">
          <div v-if="currentTasks.length === 0" class="empty-state">
            <van-empty description="没有正在运行的任务" image="search" />
          </div>
          <div
            v-for="task in currentTasks"
            :key="task.id"
            class="task-card"
          >
            <div class="task-header">
              <van-icon
                :name="getTaskIcon(task.type)"
                class="task-icon"
                size="22"
              />
              <div class="task-info">
                <div class="task-title">{{ task.title }}</div>
                <div
                  class="task-status"
                  :style="{ color: getStatusColor(task.status) }"
                >
                  {{ getStatusText(task) }}
                </div>
              </div>
              <van-button
                v-if="task.status === 'running'"
                size="small"
                type="danger"
                plain
                round
                @click="cancelTask(task)"
              >
                取消
              </van-button>
            </div>
            <van-progress
              v-if="task.status === 'running' && task.total > 0"
              :percentage="progressPercent(task)"
              :show-pivot="true"
              color="#4f6ef7"
              class="task-progress"
            />
          </div>
        </div>
      </van-tab>

      <van-tab title="历史">
        <div class="task-list">
          <div v-if="historyTasks.length === 0" class="empty-state">
            <van-empty description="没有历史任务" image="search" />
          </div>
          <div
            v-for="task in historyTasks"
            :key="task.id"
            class="task-card"
            :class="{ 'task-card--failed': task.status === 'failed' }"
          >
            <div class="task-header">
              <van-icon
                :name="getTaskIcon(task.type)"
                class="task-icon"
                size="22"
              />
              <div class="task-info">
                <div class="task-title">{{ task.title }}</div>
                <div
                  class="task-status"
                  :style="{ color: getStatusColor(task.status) }"
                >
                  {{ getStatusText(task) }}
                </div>
                <div class="task-time">
                  {{ formatDuration(task.startTime, task.endTime) }}
                </div>
              </div>
              <van-icon
                v-if="task.status === 'completed'"
                name="checked"
                color="#27ae60"
                size="20"
              />
              <van-icon
                v-else-if="task.status === 'failed'"
                name="warning-o"
                color="#e74c3c"
                size="20"
              />
              <van-icon
                v-else-if="task.status === 'cancelled'"
                name="close"
                color="#999"
                size="20"
              />
            </div>
          </div>
        </div>
      </van-tab>
    </van-tabs>

    <!-- FAB to start new task -->
    <div class="fab-container">
      <van-button
        type="primary"
        round
        icon="plus"
        class="fab-button"
        @click="showActionSheet = true"
      />
    </div>

    <!-- Action sheet for task selection -->
    <van-action-sheet
      v-model:show="showActionSheet"
      title="选择任务"
      cancel-text="取消"
    >
      <div class="action-list">
        <div
          v-for="action in taskActions"
          :key="action.value"
          class="action-item"
          @click="startTask(action.value)"
        >
          <van-icon :name="action.icon" size="24" color="#4f6ef7" />
          <span class="action-name">{{ action.name }}</span>
          <van-icon name="arrow" color="#ccc" />
        </div>
      </div>
    </van-action-sheet>
  </div>
</template>

<style scoped>
.tasks-page {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #f5f5f5;
}

.task-list {
  padding: 12px;
  padding-bottom: 80px;
}

.empty-state {
  padding-top: 40px;
}

.task-card {
  background: #fff;
  border-radius: 12px;
  padding: 14px 16px;
  margin-bottom: 10px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
}

.task-card--failed {
  border-left: 3px solid #e74c3c;
}

.task-header {
  display: flex;
  align-items: center;
  gap: 12px;
}

.task-icon {
  color: #4f6ef7;
  flex-shrink: 0;
}

.task-info {
  flex: 1;
  min-width: 0;
}

.task-title {
  font-size: 15px;
  font-weight: 500;
  color: #333;
  margin-bottom: 2px;
}

.task-status {
  font-size: 12px;
  color: #666;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.task-time {
  font-size: 11px;
  color: #999;
  margin-top: 2px;
}

.task-progress {
  margin-top: 10px;
}

.fab-container {
  position: fixed;
  bottom: calc(env(safe-area-inset-bottom, 0px) + 70px);
  right: 20px;
  z-index: 100;
}

.fab-button {
  width: 52px;
  height: 52px;
  background: #4f6ef7;
  box-shadow: 0 4px 12px rgba(79, 110, 247, 0.4);
}

.action-list {
  padding: 8px 0 16px;
}

.action-item {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px 20px;
  cursor: pointer;
  transition: background 0.15s;
}

.action-item:active {
  background: #f5f5f5;
}

.action-name {
  flex: 1;
  font-size: 15px;
  color: #333;
}
</style>
