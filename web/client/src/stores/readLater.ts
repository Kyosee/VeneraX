import { defineStore } from 'pinia'
import { ref } from 'vue'
import {
  listReadLater,
  addReadLater,
  deleteReadLater,
  batchDeleteReadLater,
  clearReadLater,
  toggleReadLater,
} from '../services/server-db'
import { sourceTypeFromKey } from '../utils/source'
import type { ReadLaterItem } from '../types'

export const useReadLaterStore = defineStore('readLater', () => {
  const items = ref<ReadLaterItem[]>([])
  const loading = ref(false)
  const loaded = ref(false)

  async function fetch() {
    loading.value = true
    try {
      const result = await listReadLater()
      items.value = result.items.sort((a, b) => b.time - a.time)
      loaded.value = true
    } finally {
      loading.value = false
    }
  }

  function isInReadLater(id: string, type: number): boolean {
    return items.value.some(item => item.id === id && item.type === type)
  }

  // Toggle by a comic-like object. Returns the new state (true = now in list).
  async function toggle(comic: {
    id: string
    sourceKey?: string
    type?: number
    title?: string
    subtitle?: string
    cover?: string
    tags?: string[]
  }): Promise<boolean> {
    const type = Number.isInteger(comic.type)
      ? (comic.type as number)
      : sourceTypeFromKey(comic.sourceKey)
    const payload = {
      id: comic.id,
      type,
      sourceKey: comic.sourceKey,
      title: comic.title ?? '',
      subtitle: comic.subtitle ?? '',
      cover: comic.cover ?? '',
      tags: Array.isArray(comic.tags) ? comic.tags : [],
      time: Date.now(),
    }
    const nowInList = await toggleReadLater(payload)
    if (nowInList) {
      if (!isInReadLater(comic.id, type)) {
        items.value = [{ ...payload }, ...items.value]
      }
    } else {
      items.value = items.value.filter(i => !(i.id === comic.id && i.type === type))
    }
    return nowInList
  }

  async function add(comic: {
    id: string
    sourceKey?: string
    type?: number
    title?: string
    subtitle?: string
    cover?: string
    tags?: string[]
  }) {
    const type = Number.isInteger(comic.type)
      ? (comic.type as number)
      : sourceTypeFromKey(comic.sourceKey)
    const payload = {
      id: comic.id,
      type,
      sourceKey: comic.sourceKey,
      title: comic.title ?? '',
      subtitle: comic.subtitle ?? '',
      cover: comic.cover ?? '',
      tags: Array.isArray(comic.tags) ? comic.tags : [],
      time: Date.now(),
    }
    await addReadLater(payload)
    if (!isInReadLater(comic.id, type)) {
      items.value = [{ ...payload }, ...items.value]
    }
  }

  async function remove(id: string, type: number) {
    await deleteReadLater(id, type)
    items.value = items.value.filter(i => !(i.id === id && i.type === type))
  }

  async function batchDelete(targets: Array<{ id: string; type: number }>) {
    await batchDeleteReadLater(targets)
    const keys = new Set(targets.map(t => `${t.id}::${t.type}`))
    items.value = items.value.filter(i => !keys.has(`${i.id}::${i.type}`))
  }

  async function clearAll() {
    await clearReadLater()
    items.value = []
  }

  return {
    items, loading, loaded,
    fetch, isInReadLater, toggle, add, remove, batchDelete, clearAll,
  }
})
