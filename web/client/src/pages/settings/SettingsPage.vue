<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'
import { useSettingsStore } from '../../stores/settings'
import { useSyncStore } from '../../stores/sync'
import { apiPost } from '../../services/api'

const router = useRouter()
const settingsStore = useSettingsStore()
const syncStore = useSyncStore()

const categories = [
  { key: 'explore', label: '发现', icon: 'search' },
  { key: 'reading', label: '阅读', icon: 'records' },
  { key: 'appearance', label: '外观', icon: 'brush-o' },
  { key: 'local', label: '本地收藏', icon: 'star' },
  { key: 'app', label: '应用', icon: 'apps-o' },
  { key: 'network', label: '网络', icon: 'cluster-o' },
  { key: 'about', label: '关于', icon: 'info' },
  { key: 'debug', label: 'Debug', icon: 'warning' },
]
const isMobile = ref(window.innerWidth < 720)
const selectedKey = ref<string | null>(isMobile.value ? null : 'explore')
const selectedCategory = computed(() => categories.find(cat => cat.key === selectedKey.value))

function checkMobile() {
  isMobile.value = window.innerWidth < 720
  if (!isMobile.value && !selectedKey.value) selectedKey.value = 'explore'
}
function selectCategory(key: string) {
  selectedKey.value = key
}
function openGithub() {
  globalThis.open('https://github.com/Kyosee/venera', '_blank')
}
function backFromDetail() {
  if (isMobile.value && selectedKey.value) {
    selectedKey.value = null
    return
  }
  router.back()
}
onMounted(() => {
  window.addEventListener('resize', checkMobile)
  settingsStore.loadSettings()
  syncStore.loadConfig()
})
onUnmounted(() => { window.removeEventListener('resize', checkMobile) })

// Reactive computed getters/setters for each setting
function settingModel<K extends keyof typeof settingsStore.settings>(key: K) {
  return computed({
    get: () => settingsStore.settings[key],
    set: (v) => {
      settingsStore.update(key, v)
      syncStore.queueAutoUpload()
    }
  })
}

// Explore
const thumbnailMode = settingModel('thumbnailMode')
const thumbnailSize = settingModel('thumbnailSize')
const showFavBadge = settingModel('showFavBadge')
const showHistoryBadge = settingModel('showHistoryBadge')
const reverseChapters = settingModel('reverseChapters')
const defaultSearchTarget = settingModel('defaultSearchTarget')
const autoLangFilter = settingModel('autoLangFilter')
const initialPage = settingModel('initialPage')
const comicListMode = settingModel('comicListMode')

// Reading
const deviceSpecific = settingModel('deviceSpecific')
const tapToTurn = settingModel('tapToTurn')
const reverseTap = settingModel('reverseTap')
const pageAnimation = settingModel('pageAnimation')
const readingMode = settingModel('readingMode')
const continuousChapter = settingModel('continuousChapter')
const autoPageInterval = settingModel('autoPageInterval')
const scrollSpeed = settingModel('scrollSpeed')
const doubleTapZoom = settingModel('doubleTapZoom')
const longPressZoom = settingModel('longPressZoom')
const longPressZoomPos = settingModel('longPressZoomPos')
const limitImageWidth = settingModel('limitImageWidth')
const showTimeAndBattery = settingModel('showTimeAndBattery')
const showStatusBar = settingModel('showStatusBar')
const quickFavImage = settingModel('quickFavImage')
const preloadCount = settingModel('preloadCount')
const showPageNum = settingModel('showPageNum')
const showChapterComments = settingModel('showChapterComments')

// Appearance
const themeMode = settingModel('themeMode')
const themeColor = settingModel('themeColor')

// Local
const showLocalFirst = settingModel('showLocalFirst')
const autoClosePanel = settingModel('autoClosePanel')
const addNewTo = settingModel('addNewTo')
const moveAfterRead = settingModel('moveAfterRead')
const quickFav = settingModel('quickFav')
const clickFav = settingModel('clickFav')

// App
const language = settingModel('language')

// Network
const downloadThreads = settingModel('downloadThreads')
const ignoreCertErrors = settingModel('ignoreCertErrors')

// Proxy dialog
const showProxyDialog = ref(false)
const proxyMode = ref<string>('direct')
const proxyHost = ref('')
const proxyPort = ref('')
const proxyUser = ref('')
const proxyPass = ref('')

function openProxyDialog() {
  const raw = settingsStore.settings as any
  proxyMode.value = raw.proxyMode || 'direct'
  proxyHost.value = raw.proxyHost || ''
  proxyPort.value = raw.proxyPort || ''
  proxyUser.value = raw.proxyUser || ''
  proxyPass.value = raw.proxyPass || ''
  showProxyDialog.value = true
}

function saveProxy() {
  const s = settingsStore as any
  s.update('proxyMode', proxyMode.value)
  s.update('proxyHost', proxyHost.value)
  s.update('proxyPort', proxyPort.value)
  s.update('proxyUser', proxyUser.value)
  s.update('proxyPass', proxyPass.value)
  syncStore.queueAutoUpload()
  showProxyDialog.value = false
  showToast({ message: '代理设置已保存', type: 'success' })
}

// DNS dialog
const showDnsDialog = ref(false)
const dnsOverrides = ref<{ domain: string; ip: string }[]>([])

function openDnsDialog() {
  const raw = settingsStore.settings as any
  const existing = raw.dnsOverrides
  if (Array.isArray(existing) && existing.length) {
    dnsOverrides.value = existing.map((item: any) => ({ domain: item.domain || '', ip: item.ip || '' }))
  } else {
    dnsOverrides.value = [{ domain: '', ip: '' }]
  }
  showDnsDialog.value = true
}

function addDnsEntry() {
  dnsOverrides.value.push({ domain: '', ip: '' })
}

function removeDnsEntry(idx: number) {
  dnsOverrides.value.splice(idx, 1)
}

function saveDns() {
  const valid = dnsOverrides.value.filter(e => e.domain.trim() && e.ip.trim())
  const s = settingsStore as any
  s.update('dnsOverrides', valid)
  syncStore.queueAutoUpload()
  showDnsDialog.value = false
  showToast({ message: 'DNS 设置已保存', type: 'success' })
}

// Keyword blocking dialog
const showBlockDialog = ref(false)
const blockKeywords = ref('')
const blockType = ref<'comic' | 'comment'>('comic')

function openBlockDialog(type: 'comic' | 'comment') {
  blockType.value = type
  const raw = settingsStore.settings as any
  const key = type === 'comic' ? 'blockKeywords' : 'blockCommentKeywords'
  blockKeywords.value = Array.isArray(raw[key]) ? raw[key].join('\n') : (raw[key] || '')
  showBlockDialog.value = true
}

function saveBlockKeywords() {
  const keywords = blockKeywords.value.split('\n').map(s => s.trim()).filter(Boolean)
  const key = blockType.value === 'comic' ? 'blockKeywords' : 'blockCommentKeywords'
  const s = settingsStore as any
  s.update(key, keywords)
  syncStore.queueAutoUpload()
  showBlockDialog.value = false
  showToast({ message: '屏蔽词已保存', type: 'success' })
}

// Debug
const jsCode = ref('')
const jsResult = ref('')

// WebDAV dialog
const showWebDavDialog = ref(false)
const webdavUrl = ref('')
const webdavUser = ref('')
const webdavPass = ref('')
const webdavAutoSync = ref(false)
const webdavDisableSyncFields = ref('')
const webdavTesting = ref(false)

// Sync logs
const showSyncLogsPopup = ref(false)
const syncLogsData = ref<Array<{ time: number; action: string; fileName: string | null; success: boolean; error: string | null }>>([])
const syncLogsLoading = ref(false)

async function openSyncLogs() {
  showSyncLogsPopup.value = true
  syncLogsLoading.value = true
  try {
    const resp = await apiPost('/sync/webdav/logs', {})
    syncLogsData.value = resp.logs || []
  } catch { syncLogsData.value = [] }
  finally { syncLogsLoading.value = false }
}

function formatSyncTime(ts: number) {
  return new Date(ts).toLocaleString()
}

function syncActionLabel(action: string) {
  switch (action) {
    case 'upload': return '上传'
    case 'download': return '下载'
    case 'auto-upload': return '自动上传'
    default: return action
  }
}
const webdavSaving = ref(false)

function openWebDavDialog() {
  webdavUrl.value = syncStore.config.url
  webdavUser.value = syncStore.config.user
  webdavPass.value = ''
  webdavAutoSync.value = syncStore.config.autoSync
  webdavDisableSyncFields.value = syncStore.config.disableSyncFields
  showWebDavDialog.value = true
}

async function testWebDavConnection() {
  if (!webdavUrl.value || !webdavUser.value) {
    showToast('请填写URL和用户名')
    return
  }
  webdavTesting.value = true
  try {
    await apiPost('/sync/webdav/test', {
      url: webdavUrl.value,
      user: webdavUser.value,
      pass: webdavPass.value || syncStore.config.pass,
    })
    showToast({ message: '连接成功', type: 'success' })
  } catch (e: any) {
    showToast({ message: '连接失败: ' + (e.message || '未知错误'), type: 'fail' })
  } finally {
    webdavTesting.value = false
  }
}

async function saveWebDavConfig() {
  if (!webdavUrl.value || !webdavUser.value) {
    showToast('请填写URL和用户名')
    return
  }
  webdavSaving.value = true
  try {
    await syncStore.saveConfig(
      webdavUrl.value,
      webdavUser.value,
      webdavPass.value,
      webdavAutoSync.value,
      webdavDisableSyncFields.value,
    )
    showToast({ message: '保存成功', type: 'success' })
    showWebDavDialog.value = false
  } catch (e: any) {
    showToast({ message: '保存失败: ' + (e.message || '未知错误'), type: 'fail' })
  } finally {
    webdavSaving.value = false
  }
}

// Data export
async function exportData() {
  try {
    const res = await apiPost<any>('/api/server-db/dump')
    const blob = new Blob([JSON.stringify(res, null, 2)], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `venera-backup-${new Date().toISOString().slice(0, 10)}.json`
    a.click()
    URL.revokeObjectURL(url)
    showToast({ message: '导出成功', type: 'success' })
  } catch (e: any) {
    showToast({ message: '导出失败: ' + (e.message || '未知错误'), type: 'fail' })
  }
}

// Data import
const fileInput = ref<HTMLInputElement | null>(null)
function triggerImport() {
  fileInput.value?.click()
}
async function handleImportFile(event: Event) {
  const target = event.target as HTMLInputElement
  const file = target.files?.[0]
  if (!file) return
  try {
    const text = await file.text()
    const data = JSON.parse(text)
    await apiPost('/api/server-db/import', { data })
    syncStore.queueAutoUpload()
    showToast({ message: '导入成功', type: 'success' })
  } catch (e: any) {
    showToast({ message: '导入失败: ' + (e.message || '未知错误'), type: 'fail' })
  }
  target.value = ''
}
</script>

<template>
  <div class="settings-page">
    <div v-if="!isMobile || !selectedKey" class="left-panel">
      <div class="panel-header"><van-icon name="arrow-left" size="20" @click="router.back()" /><span>设置</span></div>
      <div v-for="cat in categories" :key="cat.key" class="cat-item" :class="{ active: selectedKey === cat.key }" @click="selectCategory(cat.key)">
        <van-icon :name="cat.icon" size="18" /><span>{{ cat.label }}</span>
      </div>
    </div>
    <div v-if="selectedKey" class="right-panel">
      <div v-if="isMobile" class="mobile-detail-header">
        <van-icon name="arrow-left" size="20" @click="backFromDetail" />
        <span>{{ selectedCategory?.label || '设置' }}</span>
      </div>
      <div v-if="selectedKey === 'explore'" class="content">
        <h3>发现</h3>
        <div class="setting-row"><span>漫画缩略图的显示模式</span><select v-model="thumbnailMode" class="s-select"><option value="detailed">详细</option><option value="brief">简略</option></select></div>
        <div class="setting-row"><span>漫画缩略图的大小</span><span class="s-value">{{ thumbnailSize }}</span></div>
        <div class="slider-row"><van-slider v-model="thumbnailSize" :min="0.5" :max="2" :step="0.1" active-color="#1a2a5e" /></div>
        <div class="setting-row clickable" @click="router.push('/explore')"><span>探索页面</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row clickable" @click="router.push('/categories')"><span>分类页面</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row clickable" @click="router.push('/favorites')"><span>网络收藏页面</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row clickable" @click="router.push('/sources')"><span>搜索源</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row"><span>在漫画缩略图上显示收藏状态</span><van-switch v-model="showFavBadge" size="20" /></div>
        <div class="setting-row"><span>在漫画缩略图上显示历史记录</span><van-switch v-model="showHistoryBadge" size="20" /></div>
        <div class="setting-row"><span>反转默认章节顺序</span><van-switch v-model="reverseChapters" size="20" /></div>
        <div class="setting-row clickable" @click="openBlockDialog('comic')"><span>关键词屏蔽</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row clickable" @click="openBlockDialog('comment')"><span>评论关键词屏蔽</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row"><span>默认搜索目标</span><select v-model="defaultSearchTarget" class="s-select"><option value="">聚合</option><option value="single">单源</option></select></div>
        <div class="setting-row"><span>自动语言筛选</span><select v-model="autoLangFilter" class="s-select"><option value="none">无</option><option value="zh">中文</option><option value="ja">日语</option><option value="en">英语</option></select></div>
        <div class="setting-row"><span>初始页面</span><select v-model="initialPage" class="s-select"><option value="0">主页</option><option value="1">收藏</option><option value="2">发现</option><option value="3">分类</option></select></div>
        <div class="setting-row"><span>漫画列表的显示模式</span><select v-model="comicListMode" class="s-select"><option value="continuous">连续</option><option value="paging">分页</option></select></div>
      </div>
      <!-- READING_SECTION_PLACEHOLDER -->
      <div v-else-if="selectedKey === 'reading'" class="content">
        <h3>阅读中</h3>
        <div class="setting-row"><span>启用此设备特定设置</span><van-switch v-model="deviceSpecific" size="20" /></div>
        <div class="setting-row"><span>点击翻页</span><van-switch v-model="tapToTurn" size="20" /></div>
        <div class="setting-row"><span>反转点击翻页</span><van-switch v-model="reverseTap" size="20" /></div>
        <div class="setting-row"><span>页面动画</span><van-switch v-model="pageAnimation" size="20" /></div>
        <div class="setting-row"><span>阅读模式</span><select v-model="readingMode" class="s-select"><option value="galleryLeftToRight">分页：从左到右</option><option value="galleryRightToLeft">分页：从右到左</option><option value="galleryTopToBottom">分页：从上到下</option><option value="continuousTopToBottom">连续：从上到下</option><option value="continuousLeftToRight">连续：从左到右</option><option value="continuousRightToLeft">连续：从右到左</option></select></div>
        <div class="setting-row"><span>连续章节阅读</span><van-switch v-model="continuousChapter" size="20" /></div>
        <div class="setting-sub-text">在连续阅读模式中拼接多个章节</div>
        <div class="setting-row"><span>自动翻页间隔</span><span class="s-value">{{ autoPageInterval }}</span></div>
        <div class="slider-row"><van-slider v-model="autoPageInterval" :min="1" :max="10" :step="1" active-color="#1a2a5e" /></div>
        <div class="setting-row"><span>鼠标滚动速度</span><span class="s-value">{{ scrollSpeed }}</span></div>
        <div class="slider-row"><van-slider v-model="scrollSpeed" :min="1" :max="10" :step="1" active-color="#1a2a5e" /></div>
        <div class="setting-row"><span>双击缩放</span><van-switch v-model="doubleTapZoom" size="20" /></div>
        <div class="setting-row"><span>长按缩放</span><van-switch v-model="longPressZoom" size="20" /></div>
        <div class="setting-row"><span>长按缩放位置</span><select v-model="longPressZoomPos" class="s-select"><option value="press">按压位置</option><option value="center">中心</option></select></div>
        <div class="setting-row"><span>限制图片宽度</span><van-switch v-model="limitImageWidth" size="20" /></div>
        <div class="setting-sub-text">当使用连续（从上到下）模式</div>
        <div class="setting-row"><span>在阅读器中显示时间和电量信息</span><van-switch v-model="showTimeAndBattery" size="20" /></div>
        <div class="setting-row"><span>显示系统状态栏</span><van-switch v-model="showStatusBar" size="20" /></div>
        <div class="setting-row"><span>快速收藏图片</span><select v-model="quickFavImage" class="s-select"><option value="No">不启用</option><option value="Yes">启用</option></select></div>
        <div v-if="false" class="setting-row"><span>自定义图片处理</span><van-button size="small" plain>编辑</van-button></div>
        <div class="setting-row"><span>预加载图片数量</span><span class="s-value">{{ preloadCount }}</span></div>
        <div class="slider-row"><van-slider v-model="preloadCount" :min="1" :max="10" :step="1" active-color="#1a2a5e" /></div>
        <div class="setting-row"><span>显示页码</span><van-switch v-model="showPageNum" size="20" /></div>
        <div class="setting-row"><span>显示章节评论</span><van-switch v-model="showChapterComments" size="20" /></div>
      </div>
      <!-- APPEARANCE_PLACEHOLDER -->
      <div v-else-if="selectedKey === 'appearance'" class="content">
        <h3>外观</h3>
        <div class="setting-row"><span>主题模式</span><select v-model="themeMode" class="s-select"><option value="system">系统</option><option value="light">浅色</option><option value="dark">深色</option></select></div>
        <div class="setting-row"><span>主题颜色</span><select v-model="themeColor" class="s-select"><option value="system">系统</option><option value="blue">蓝色</option><option value="purple">紫色</option><option value="green">绿色</option></select></div>
      </div>
      <div v-else-if="selectedKey === 'local'" class="content">
        <h3>本地收藏</h3>
        <div class="setting-row"><span>在网络收藏之前显示本地收藏</span><van-switch v-model="showLocalFirst" size="20" /></div>
        <div class="setting-row"><span>自动关闭收藏面板</span><van-switch v-model="autoClosePanel" size="20" /></div>
        <div class="setting-row"><span>添加新收藏到</span><select v-model="addNewTo" class="s-select"><option value="start">开始</option><option value="end">末尾</option></select></div>
        <div class="setting-row"><span>阅读后移动收藏</span><select v-model="moveAfterRead" class="s-select"><option value="none">无</option><option value="start">开始</option><option value="end">末尾</option></select></div>
        <div v-if="false" class="setting-row"><span>快速收藏</span><select v-model="quickFav" class="s-select"><option value="">—</option></select></div>
        <div class="setting-row"><span>删除所有无效的本地收藏</span><van-button size="small" plain disabled>Web 端不支持本地收藏</van-button></div>
        <div class="setting-row"><span>点击收藏</span><select v-model="clickFav" class="s-select"><option value="viewDetail">查看详情</option><option value="read">直接阅读</option></select></div>
      </div>
      <!-- APP_PLACEHOLDER -->
      <div v-else-if="selectedKey === 'app'" class="content">
        <h3>应用</h3>
        <div class="section-header"><van-icon name="bars" size="16" /><span>数据</span></div>
        <div class="setting-row"><span>导出应用数据</span><van-button size="small" plain @click="exportData">导出</van-button></div>
        <div class="setting-row"><span>导入应用数据</span><van-button size="small" plain @click="triggerImport">导入</van-button></div>
        <input ref="fileInput" type="file" accept=".json" style="display:none" @change="handleImportFile" />
        <div class="setting-row"><span>数据同步</span><van-button size="small" plain @click="openWebDavDialog">设置</van-button></div>
        <div class="setting-row"><span>同步日志</span><van-button size="small" plain @click="openSyncLogs">查看</van-button></div>
        <div class="section-header"><van-icon name="contact" size="16" /><span>用户</span></div>
        <div class="setting-row"><span>语言</span><select v-model="language" class="s-select"><option value="system">系统</option><option value="zh-CN">简体中文</option><option value="zh-TW">繁體中文</option><option value="en">English</option><option value="ja">日本語</option></select></div>
      </div>
      <div v-else-if="selectedKey === 'network'" class="content">
        <h3>网络</h3>
        <div class="setting-row clickable" @click="openProxyDialog"><span>代理</span><span class="s-value">{{ proxyMode === 'direct' ? '直连' : proxyMode === 'system' ? '系统' : '手动' }}</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row clickable" @click="openDnsDialog"><span>DNS覆写</span><van-icon name="arrow" size="14" /></div>
        <div class="setting-row"><span>下载线程数</span><span class="s-value">{{ downloadThreads }}</span></div>
        <div class="slider-row"><van-slider v-model="downloadThreads" :min="1" :max="10" :step="1" active-color="#1a2a5e" /></div>
      </div>
      <!-- ABOUT_PLACEHOLDER -->
      <div v-else-if="selectedKey === 'about'" class="content about-content">
        <div class="about-logo"><img src="/favicon.png" alt="Venera" class="about-logo-img" /><div class="about-version">V2.0.0</div><div class="about-desc">Venera是一个免费的开源漫画阅读应用。</div></div>
        <div v-if="false" class="setting-row"><span>检查更新</span><van-button size="small" type="primary">检查</van-button></div>
        <div v-if="false" class="setting-row"><span>启动时检查更新</span><van-switch model-value size="20" /></div>
        <div class="setting-row clickable" @click="openGithub"><span>Github</span><van-icon name="share-o" size="16" /></div>
      </div>
      <div v-else-if="selectedKey === 'debug'" class="content">
        <h3>Debug</h3>
        <div v-if="false" class="setting-row"><span>重新加载配置文件</span><van-button size="small" plain>重载</van-button></div>
        <div v-if="false" class="setting-row"><span>打开日志</span><van-button size="small" plain>打开</van-button></div>
        <div class="setting-row"><span>忽略证书错误</span><van-switch v-model="ignoreCertErrors" size="20" /></div>
        <div v-if="false" class="debug-section"><div class="debug-label">JS Evaluator</div><textarea v-model="jsCode" class="debug-textarea" rows="5" placeholder="输入 JavaScript 代码..."></textarea><div class="debug-run"><a href="#" @click.prevent>Run</a></div><div class="debug-label">Result</div><textarea v-model="jsResult" class="debug-textarea" rows="4" readonly></textarea></div>
      </div>
    </div>

    <!-- WebDAV Config Dialog -->
    <van-popup v-model:show="showWebDavDialog" round position="center" :style="{ width: '400px', maxWidth: '90vw', padding: '24px', background: '#fff', color: '#1a1a1a' }">
      <div class="webdav-dialog">
        <h3 class="webdav-title">WebDAV 同步设置</h3>
        <van-field v-model="webdavUrl" label="URL" placeholder="https://dav.example.com/path" class="webdav-field" />
        <van-field v-model="webdavUser" label="用户名" placeholder="用户名" class="webdav-field" />
        <van-field v-model="webdavPass" type="password" label="密码" placeholder="留空则保留原密码" class="webdav-field" />
        <div class="webdav-row">
          <span>自动同步</span>
          <van-switch v-model="webdavAutoSync" size="20" />
        </div>
        <van-field v-model="webdavDisableSyncFields" label="不同步字段" placeholder="用英文逗号分隔，如 token" class="webdav-field" />
        <div class="webdav-actions">
          <van-button size="small" plain :loading="webdavTesting" @click="testWebDavConnection">测试连接</van-button>
          <van-button size="small" type="primary" :loading="webdavSaving" @click="saveWebDavConfig">保存</van-button>
        </div>
      </div>
    </van-popup>

    <!-- Sync Logs Popup -->
    <van-popup v-model:show="showSyncLogsPopup" round position="center" :style="{ width: '420px', maxWidth: '90vw', maxHeight: '70vh', padding: '20px', background: '#fff', color: '#1a1a1a' }">
      <div class="sync-logs-dialog">
        <h3 style="margin: 0 0 12px; font-size: 16px;">同步日志</h3>
        <van-loading v-if="syncLogsLoading" style="text-align: center; padding: 20px;" />
        <div v-else-if="syncLogsData.length === 0" style="text-align: center; color: #999; padding: 20px;">暂无日志</div>
        <div v-else class="sync-logs-list">
          <div v-for="(log, i) in syncLogsData" :key="i" class="sync-log-item">
            <div class="sync-log-header">
              <span class="sync-log-action" :class="{ success: log.success, fail: !log.success }">{{ syncActionLabel(log.action) }}</span>
              <span class="sync-log-time">{{ formatSyncTime(log.time) }}</span>
            </div>
            <div v-if="log.fileName" class="sync-log-file">{{ log.fileName }}</div>
            <div v-if="log.error" class="sync-log-error">{{ log.error }}</div>
          </div>
        </div>
      </div>
    </van-popup>

    <!-- Proxy Dialog -->
    <van-popup v-model:show="showProxyDialog" round position="center" :style="{ width: '400px', maxWidth: '90vw', padding: '24px', background: '#fff', color: '#1a1a1a' }">
      <div class="webdav-dialog">
        <h3 class="webdav-title">代理设置</h3>
        <div class="webdav-row">
          <span>代理模式</span>
          <select v-model="proxyMode" class="s-select">
            <option value="direct">直连</option>
            <option value="system">系统代理</option>
            <option value="manual">手动</option>
          </select>
        </div>
        <template v-if="proxyMode === 'manual'">
          <van-field v-model="proxyHost" label="主机" placeholder="127.0.0.1" class="webdav-field" />
          <van-field v-model="proxyPort" label="端口" placeholder="7890" class="webdav-field" />
          <van-field v-model="proxyUser" label="用户名" placeholder="可选" class="webdav-field" />
          <van-field v-model="proxyPass" type="password" label="密码" placeholder="可选" class="webdav-field" />
        </template>
        <div class="webdav-actions">
          <van-button size="small" plain @click="showProxyDialog = false">取消</van-button>
          <van-button size="small" type="primary" @click="saveProxy">保存</van-button>
        </div>
      </div>
    </van-popup>

    <!-- DNS Dialog -->
    <van-popup v-model:show="showDnsDialog" round position="center" :style="{ width: '440px', maxWidth: '90vw', padding: '24px', background: '#fff', color: '#1a1a1a' }">
      <div class="webdav-dialog">
        <h3 class="webdav-title">DNS 覆写</h3>
        <div v-for="(entry, idx) in dnsOverrides" :key="idx" class="dns-entry">
          <van-field v-model="entry.domain" placeholder="域名" class="dns-field" />
          <span class="dns-arrow">→</span>
          <van-field v-model="entry.ip" placeholder="IP" class="dns-field" />
          <van-icon name="cross" size="16" class="dns-remove" @click="removeDnsEntry(idx)" />
        </div>
        <van-button size="small" plain icon="plus" @click="addDnsEntry">添加</van-button>
        <div class="webdav-actions">
          <van-button size="small" plain @click="showDnsDialog = false">取消</van-button>
          <van-button size="small" type="primary" @click="saveDns">保存</van-button>
        </div>
      </div>
    </van-popup>

    <!-- Keyword Blocking Dialog -->
    <van-popup v-model:show="showBlockDialog" round position="center" :style="{ width: '400px', maxWidth: '90vw', padding: '24px', background: '#fff', color: '#1a1a1a' }">
      <div class="webdav-dialog">
        <h3 class="webdav-title">{{ blockType === 'comic' ? '关键词屏蔽' : '评论关键词屏蔽' }}</h3>
        <p class="block-hint">每行一个关键词，包含该关键词的内容将被隐藏</p>
        <textarea v-model="blockKeywords" class="debug-textarea" rows="8" placeholder="输入屏蔽关键词，每行一个..."></textarea>
        <div class="webdav-actions">
          <van-button size="small" plain @click="showBlockDialog = false">取消</van-button>
          <van-button size="small" type="primary" @click="saveBlockKeywords">保存</van-button>
        </div>
      </div>
    </van-popup>
  </div>
</template>

<style scoped>
.settings-page { display: flex; height: 100%; }
.left-panel { width: 160px; flex-shrink: 0; border-right: 0.6px solid #e0e0e0; padding: 12px 8px; display: flex; flex-direction: column; gap: 2px; }
.panel-header { display: flex; align-items: center; gap: 12px; padding: 8px 12px; margin-bottom: 12px; font-size: 16px; font-weight: 600; }
.cat-item { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px; cursor: pointer; font-size: 14px; transition: background 0.15s; }
.cat-item:hover { background: #f5f5f5; }
.cat-item.active { background: rgba(79,110,247,0.1); color: #4f6ef7; border-left: 2.5px solid #4f6ef7; }
.right-panel { flex: 1; padding: 20px 24px; overflow-y: auto; }
.right-panel h3 { font-size: 16px; font-weight: 500; margin-bottom: 16px; }
.content { max-width: 700px; }
.mobile-detail-header { display: none; }
.setting-row { display: flex; align-items: center; justify-content: space-between; padding: 14px 0; border-bottom: 0.5px solid #f0f0f0; font-size: 14px; }
.setting-row.clickable { cursor: pointer; }
.setting-row.clickable:hover { background: #fafafa; margin: 0 -8px; padding: 14px 8px; border-radius: 4px; }
.setting-sub-text { font-size: 12px; color: #999; padding-bottom: 14px; border-bottom: 0.5px solid #f0f0f0; }
.slider-row { padding: 8px 0 16px; border-bottom: 0.5px solid #f0f0f0; }
.s-select { background: #f5f5f5; border: 1px solid #e0e0e0; border-radius: 6px; padding: 4px 10px; font-size: 13px; min-width: 80px; }
.s-value { font-size: 13px; color: #666; }
.section-header { display: flex; align-items: center; gap: 8px; padding: 16px 0 8px; font-size: 14px; font-weight: 500; color: #333; border-bottom: 0.5px solid #e0e0e0; }
.about-content { text-align: left; }
.about-logo { text-align: center; padding: 32px 0 24px; }
.about-logo-img { width: 72px; height: 72px; border-radius: 16px; margin: 0 auto 12px; }
.about-version { font-size: 16px; font-weight: 600; margin-bottom: 4px; }
.about-desc { font-size: 13px; color: #666; }
.debug-section { margin-top: 16px; }
.debug-label { font-size: 13px; color: #333; margin-bottom: 6px; }
.debug-textarea { width: 100%; border: 1px solid #e0e0e0; border-radius: 6px; padding: 10px; font-family: monospace; font-size: 13px; resize: vertical; }
.debug-run { text-align: right; margin: 6px 0 16px; }
.debug-run a { color: #4f6ef7; font-size: 13px; }
.webdav-dialog { display: flex; flex-direction: column; gap: 12px; color: #1a1a1a; }
.webdav-dialog :deep(.van-field__label) { color: #333; }
.webdav-dialog :deep(.van-field__control) { color: #1a1a1a; }
.webdav-dialog :deep(.van-field__control::placeholder) { color: #999; }
.webdav-title { font-size: 16px; font-weight: 600; margin: 0 0 8px; }
.webdav-field { padding: 0; }
.webdav-row { display: flex; align-items: center; justify-content: space-between; min-height: 32px; font-size: 14px; }
.webdav-actions { display: flex; justify-content: flex-end; gap: 12px; margin-top: 8px; }
.sync-logs-dialog { display: flex; flex-direction: column; }
.sync-logs-list { max-height: 50vh; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; }
.sync-log-item { padding: 8px 10px; border-radius: 6px; background: #f7f8fa; font-size: 13px; }
.sync-log-header { display: flex; justify-content: space-between; align-items: center; }
.sync-log-action { font-weight: 600; padding: 2px 6px; border-radius: 4px; font-size: 12px; }
.sync-log-action.success { background: #e8f5e9; color: #2e7d32; }
.sync-log-action.fail { background: #fbe9e7; color: #c62828; }
.sync-log-time { color: #999; font-size: 12px; }
.sync-log-file { color: #555; margin-top: 4px; word-break: break-all; }
.sync-log-error { color: #c62828; margin-top: 4px; font-size: 12px; }
.dns-entry { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
.dns-field { flex: 1; padding: 0; }
.dns-arrow { color: #999; font-size: 14px; flex-shrink: 0; }
.dns-remove { cursor: pointer; color: #999; flex-shrink: 0; }
.dns-remove:hover { color: #ee0a24; }
.block-hint { font-size: 12px; color: #999; margin: 0 0 8px; }
@media (max-width: 720px) {
  .settings-page { display: block; height: 100%; }
  .left-panel { width: 100%; min-height: 100%; border-right: 0; padding: 12px 10px; box-sizing: border-box; }
  .cat-item { min-height: 44px; border-radius: 8px; }
  .cat-item.active { border-left: 0; }
  .right-panel { height: 100%; padding: 0 16px 16px; box-sizing: border-box; }
  .mobile-detail-header { display: flex; align-items: center; gap: 12px; height: 52px; font-size: 16px; font-weight: 600; position: sticky; top: 0; z-index: 3; background: #fff; }
  .content { max-width: none; }
  .setting-row { gap: 16px; min-height: 46px; }
  .setting-row > span:first-child { min-width: 0; }
  .s-select { max-width: 52vw; }
}
</style>
