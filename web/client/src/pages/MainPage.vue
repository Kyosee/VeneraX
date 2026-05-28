<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'

const router = useRouter()
const route = useRoute()

const tabs = [
  { key: 'home', label: '主页', icon: 'wap-home-o', iconActive: 'wap-home', path: '/home' },
  { key: 'favorites', label: '收藏', icon: 'star-o', iconActive: 'star', path: '/favorites' },
  { key: 'explore', label: '发现', icon: 'search', iconActive: 'search', path: '/explore' },
  { key: 'categories', label: '分类', icon: 'apps-o', iconActive: 'apps-o', path: '/categories' },
]

const bottomActions = [
  { key: 'tasks', label: '任务', icon: 'orders-o', iconActive: 'orders-o', path: '/tasks' },
  { key: 'settings', label: '设置', icon: 'setting-o', iconActive: 'setting-o', path: '/settings' },
]

const mobileTabs = [...tabs, ...bottomActions]

const activeTab = computed({
  get() {
    const path = route.path
    const found = mobileTabs.findIndex(t => path.startsWith(t.path))
    return found >= 0 ? found : 0
  },
  set(index: number) {
    goMobileTab(index)
  },
})

function pushPath(path: string) {
  if (route.path !== path) router.push(path)
}

function goTab(index: number) {
  const tab = tabs[index]
  if (tab) pushPath(tab.path)
}

function goMobileTab(index: number) {
  const tab = mobileTabs[index]
  if (tab) pushPath(tab.path)
}

function goAction(path: string) { pushPath(path) }

const isMobile = ref(false)
function onResize() { isMobile.value = window.innerWidth < 720 }
onMounted(() => { onResize(); window.addEventListener('resize', onResize) })
onUnmounted(() => { window.removeEventListener('resize', onResize) })
</script>

<template>
  <div class="app-layout" :class="{ mobile: isMobile }">
    <!-- Desktop Sidebar -->
    <aside v-if="!isMobile" class="sidebar">
      <div class="sidebar-logo">
        <img src="/favicon.png" alt="Venera" class="logo-img" />
        <span class="logo-text">Venera</span>
      </div>
      <nav class="sidebar-nav">
        <div
          v-for="(tab, i) in tabs" :key="tab.key"
          class="nav-item" :class="{ active: activeTab === i }"
          @click="goTab(i)"
        >
          <van-icon :name="activeTab === i ? tab.iconActive : tab.icon" size="20" />
          <span>{{ tab.label }}</span>
        </div>
      </nav>
      <div class="sidebar-bottom">
        <div v-for="act in bottomActions" :key="act.key"
          class="nav-item" :class="{ active: route.path.startsWith(act.path) }"
          @click="goAction(act.path)">
          <van-icon :name="act.icon" size="20" />
          <span>{{ act.label }}</span>
        </div>
      </div>
    </aside>

    <!-- Main Content -->
    <main class="main-content">
      <router-view v-slot="{ Component, route: childRoute }">
        <keep-alive :max="6">
          <component :is="Component" :key="childRoute.path" />
        </keep-alive>
      </router-view>
    </main>

    <!-- Mobile Bottom Tab -->
    <van-tabbar v-if="isMobile" v-model="activeTab">
      <van-tabbar-item
        v-for="(tab, i) in mobileTabs"
        :key="tab.key"
        :icon="activeTab === i ? tab.iconActive : tab.icon"
      >
        {{ tab.label }}
      </van-tabbar-item>
    </van-tabbar>
  </div>
</template>

<style scoped>
.app-layout {
  height: 100%;
  display: flex;
}

/* Desktop: horizontal flex with sidebar */
.sidebar {
  width: 140px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 0.6px solid var(--van-border-color);
  padding: 16px 12px;
  background: var(--van-background-2);
}
.sidebar-logo {
  display: flex; align-items: center; gap: 8px;
  padding: 8px 12px; margin-bottom: 16px;
}
.logo-img { width: 32px; height: 32px; border-radius: 8px; }
.logo-text { font-size: 16px; font-weight: 800; }
.sidebar-nav { flex: 1; display: flex; flex-direction: column; gap: 4px; }
.sidebar-bottom { display: flex; flex-direction: column; gap: 4px; border-top: 0.6px solid var(--van-border-color); padding-top: 12px; }
.nav-item {
  display: flex; align-items: center; gap: 12px;
  padding: 10px 12px; border-radius: 12px;
  cursor: pointer; font-size: 14px; color: var(--van-text-color);
  transition: background 0.15s;
}
.nav-item:hover { background: var(--van-active-color); }
.nav-item.active {
  background: rgba(79, 110, 247, 0.12);
  color: #4f6ef7; font-weight: 500;
  border-left: 2px solid #4f6ef7;
}

/* Main content area */
.main-content {
  flex: 1;
  min-width: 0;
  min-height: 0;
  overflow-y: auto;
}

/* Mobile: vertical layout */
.app-layout.mobile {
  display: flex;
  flex-direction: column;
}

.app-layout.mobile .main-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  /* van-tabbar is position:fixed and ~50px tall */
  padding-bottom: 50px;
  padding-bottom: calc(50px + env(safe-area-inset-bottom, 0px));
}
</style>
