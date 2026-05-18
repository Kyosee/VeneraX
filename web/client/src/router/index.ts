import { createRouter, createWebHistory } from 'vue-router'

function resolveInitialPage(): string {
  try {
    const raw = localStorage.getItem('venera_settings')
    if (!raw) return '/home'
    const settings = JSON.parse(raw)
    const page = settings?.initialPage
    switch (page) {
      case '1': return '/favorites'
      case '2': return '/explore'
      case '3': return '/categories'
      default: return '/home'
    }
  } catch { return '/home' }
}

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      component: () => import('../pages/MainPage.vue'),
      redirect: resolveInitialPage,
      children: [
        { path: 'home', component: () => import('../pages/home/HomePage.vue') },
        { path: 'favorites', component: () => import('../pages/favorites/FavoritesPage.vue') },
        { path: 'explore', component: () => import('../pages/explore/ExplorePage.vue') },
        { path: 'categories', component: () => import('../pages/categories/CategoriesPage.vue') },
        { path: 'settings', component: () => import('../pages/settings/SettingsPage.vue') },
        { path: 'tasks', component: () => import('../pages/tasks/TasksPage.vue') },
        { path: 'history', component: () => import('../pages/history/HistoryPage.vue') },
        { path: 'follow-updates', component: () => import('../pages/follow-updates/FollowUpdatesPage.vue') },
        { path: 'image-favorites', component: () => import('../pages/image-favorites/ImageFavoritesPage.vue') },
        { path: 'sources', component: () => import('../pages/sources/SourceManagementPage.vue') },
      ]
    },
    { path: '/comic/:sourceKey/:id', component: () => import('../pages/comic/ComicDetailPage.vue') },
    { path: '/reader/:sourceKey/:id', component: () => import('../pages/reader/ReaderPage.vue') },
    { path: '/search', component: () => import('../pages/search/SearchPage.vue') },
    { path: '/search/:sourceKey', component: () => import('../pages/search/SearchResultPage.vue') },
    { path: '/ranking', component: () => import('../pages/ranking/RankingPage.vue') },
  ]
})

export default router
