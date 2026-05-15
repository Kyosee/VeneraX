import { defineStore } from 'pinia'
import { ref } from 'vue'
import {
  listFolders,
  listFavorites,
  addFavorite as apiAddFavorite,
  deleteFavorite as apiRemoveFavorite,
  moveFavorite as apiMoveFavorite
} from '../services/server-db'
import type { FavoriteFolder, FavoriteItem } from '../types'

export const useFavoritesStore = defineStore('favorites', () => {
  const folders = ref<FavoriteFolder[]>([])
  const items = ref<FavoriteItem[]>([])
  const currentFolder = ref<string | null>(null)
  const loading = ref(false)

  async function fetchFolders() {
    folders.value = await listFolders()
  }

  async function fetchItems(folderId?: string) {
    loading.value = true
    try {
      currentFolder.value = folderId ?? null
      items.value = await listFavorites(folderId)
    } finally {
      loading.value = false
    }
  }

  async function addFavorite(data: Partial<FavoriteItem> & { folderId?: string }) {
    await apiAddFavorite({ ...data, folder: data.folderId ?? currentFolder.value ?? undefined } as Partial<FavoriteItem>)
    await fetchItems(currentFolder.value ?? undefined)
  }

  async function removeFavorite(id: string) {
    const item = items.value.find(i => i.id === id)
    if (currentFolder.value && item) {
      await apiRemoveFavorite(currentFolder.value, item.id, item.type)
    }
    items.value = items.value.filter(i => i.id !== id)
  }

  async function moveFavorite(id: string, folderId: string) {
    const item = items.value.find(i => i.id === id)
    if (currentFolder.value && item) {
      await apiMoveFavorite(currentFolder.value, folderId, item.id, item.type)
    }
    if (currentFolder.value && currentFolder.value !== folderId) {
      items.value = items.value.filter(i => i.id !== id)
    }
  }

  return { folders, items, currentFolder, loading, fetchFolders, fetchItems, addFavorite, removeFavorite, moveFavorite }
})
