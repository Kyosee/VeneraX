import { apiPost } from './api'
import { useSyncStore } from '../stores/sync'
import type { History, FavoriteItem, FavoriteFolder, ComicSource, SourceCapabilities } from '../types'
import { normalizeComicSources, sourceKeyFromType } from '../utils/source'

type FavoritePayloadItem = Pick<FavoriteItem, 'id' | 'type'> & { folder?: string }

function queueAutoUpload() {
  try {
    useSyncStore().queueAutoUpload()
  } catch { /* Pinia may not be active during isolated service tests. */ }
}

function normalizeHistory(item: any): History {
  const type = Number(item?.type ?? 0)
  const readEpisode = Array.isArray(item?.readEpisode)
    ? item.readEpisode.map(String)
    : String(item?.readEpisode ?? '').split(',').filter(Boolean)
  return {
    ...item,
    type,
    sourceKey: item?.sourceKey ?? sourceKeyFromType(type),
    readEpisode,
    maxPage: item?.maxPage ?? item?.max_page ?? null,
    group: item?.group ?? item?.chapter_group ?? null,
  }
}

export async function listHistory(limit = 500, offset = 0): Promise<{ items: History[], total: number }> {
  const res = await apiPost<any>('/api/server-db/history/list', { limit, offset })
  const items = (res?.items ?? res ?? []).map(normalizeHistory)
  const total = res?.total ?? items.length
  return { items, total }
}

export async function upsertHistory(data: Partial<History>): Promise<void> {
  await apiPost('/api/server-db/history/upsert', { history: data })
  queueAutoUpload()
}

export async function deleteHistory(id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/history/delete', { id, type })
  queueAutoUpload()
}

export async function clearHistory(): Promise<void> {
  await apiPost('/api/server-db/history/clear')
  queueAutoUpload()
}

export async function listFolders(): Promise<FavoriteFolder[]> {
  const res = await apiPost<any>('/api/server-db/favorites/folders')
  const folders = res?.folders ?? res ?? []
  return folders.map((folder: any) => ({
    ...folder,
    id: folder.id ?? folder.name,
  }))
}

export async function listFavorites(folder?: string): Promise<FavoriteItem[]> {
  if (!folder) {
    const folders = await listFolders()
    const pages = await Promise.all(folders.map(item => listFavorites(item.name)))
    return pages.flat()
  }

  const items: FavoriteItem[] = []
  let offset = 0
  let total = Number.POSITIVE_INFINITY
  while (offset < total) {
    const res = await apiPost<any>('/api/server-db/favorites/list', { folder, limit: 500, offset })
    const pageItems = res?.items ?? res?.favorites ?? res ?? []
    total = Number(res?.total ?? offset + pageItems.length)
    for (const item of pageItems) {
      item.folder = folder
    }
    items.push(...pageItems)
    if (pageItems.length === 0 || pageItems.length < 500) break
    offset += pageItems.length
  }
  return items
}

export async function addFavorite(data: Partial<FavoriteItem>): Promise<void> {
  await apiPost('/api/server-db/favorites/add', { folder: (data as any).folder, item: data })
  queueAutoUpload()
}

export async function deleteFavorite(folder: string, id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/favorites/delete', { folder, id, type })
  queueAutoUpload()
}

export async function moveFavorite(sourceFolder: string, targetFolder: string, id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/favorites/move', { sourceFolder, targetFolder, id, type })
  queueAutoUpload()
}

export async function createFolder(name: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/create', { name })
  queueAutoUpload()
}

export async function deleteFolder(name: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/delete', { name })
  queueAutoUpload()
}

export async function renameFolder(before: string, after: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/rename', { before, after })
  queueAutoUpload()
}

export async function reorderFolders(folders: string[]): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/order', { folders })
  queueAutoUpload()
}

function favoritePayloadItems(items: FavoritePayloadItem[]) {
  return items.map(item => ({ id: item.id, type: item.type }))
}

export async function batchDeleteFavorites(items: FavoritePayloadItem[], folder?: string): Promise<void> {
  const payloadItems = favoritePayloadItems(items)
  if (folder) {
    await apiPost('/api/server-db/favorites/batch-delete', { folder, items: payloadItems })
    queueAutoUpload()
    return
  }
  await apiPost('/api/server-db/favorites/batch-delete-all', { items: payloadItems })
  queueAutoUpload()
}

export async function batchMoveFavorites(items: FavoritePayloadItem[], targetFolder: string, sourceFolder?: string): Promise<void> {
  if (sourceFolder) {
    await apiPost('/api/server-db/favorites/batch-move', {
      sourceFolder,
      targetFolder,
      items: favoritePayloadItems(items),
    })
    queueAutoUpload()
    return
  }

  const itemsByFolder = new Map<string, FavoritePayloadItem[]>()
  for (const item of items) {
    if (!item.folder) continue
    itemsByFolder.set(item.folder, [...(itemsByFolder.get(item.folder) ?? []), item])
  }
  await Promise.all([...itemsByFolder.entries()].map(([folder, folderItems]) =>
    apiPost('/api/server-db/favorites/batch-move', {
      sourceFolder: folder,
      targetFolder,
      items: favoritePayloadItems(folderItems),
    }),
  ))
  queueAutoUpload()
}

export async function getAppdata(): Promise<Record<string, any>> {
  const res = await apiPost<any>('/api/server-db/appdata')
  return res?.data ?? res ?? {}
}

export async function getComicSources(): Promise<ComicSource[]> {
  const res = await apiPost<any>('/api/server-db/comic-sources')
  const items = res?.items ?? res ?? []
  return normalizeComicSources(items)
}

export async function searchComics(sourceKey: string, keyword: string, page = 1, options?: string[]): Promise<{ comics: any[], hasMore: boolean }> {
  const res = await apiPost<any>('/api/server-db/search', { sourceKey, keyword, page, options })
  return { comics: res?.comics ?? [], hasMore: res?.hasMore ?? false }
}

export async function getRanking(sourceKey: string, option: string, page = 1): Promise<{ comics: any[], hasMore: boolean }> {
  const res = await apiPost<any>('/api/server-db/ranking', { sourceKey, option, page })
  return { comics: res?.comics ?? [], hasMore: res?.hasMore ?? false }
}

export async function searchAllComics(keyword: string, page = 1, options?: string[]): Promise<{ comics: any[] }> {
  const res = await apiPost<any>('/api/server-db/search/aggregated', { keyword, page, options })
  return { comics: res?.comics ?? [] }
}

export async function batchGetComicBasicInfo(ids: Array<{ sourceKey: string; comicId: string }>): Promise<Record<string, any>> {
  const res = await apiPost<any>('/api/server-db/comic/basic-info/batch', { ids })
  return res?.items ?? {}
}

export async function getSourceCapabilities(sourceKey: string): Promise<SourceCapabilities | null> {
  try {
    const res = await apiPost<any>('/api/server-db/source/capabilities', { sourceKey })
    if (!res || res.ok === false) return null
    return res as SourceCapabilities
  } catch { return null }
}

export async function listImageFavorites(): Promise<any[]> {
  const res = await apiPost<any>('/api/server-db/image-favorites/list')
  return res?.items ?? res?.favorites ?? res ?? []
}

export async function markAsRead(folder: string, id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/favorites/mark-read', { folder, id, type })
  queueAutoUpload()
}

export async function checkFollowUpdates(
  folder: string,
  ignoreCheckTime = false,
): Promise<{ checked: number; updated: Array<{ id: string; type: number; title: string; updateTime: string }> }> {
  const res = await apiPost<any>('/api/server-db/follow-updates/check', { folder, ignoreCheckTime })
  return { checked: res?.checked ?? 0, updated: res?.updated ?? [] }
}

export interface FollowUpdateTaskState {
  taskId: string
  status: 'pending' | 'running' | 'completed' | 'failed' | 'cancelled'
  total: number
  checked: number
  updated: Array<{ id: string; type: number; title: string; updateTime: string }>
  currentItem: string
  error: string | null
  startTime: number
  endTime: number | null
  notFound?: boolean
}

export async function startAsyncFollowUpdateCheck(folder: string): Promise<string> {
  const res = await apiPost<any>('/api/server-db/follow-updates/check-async', { folder })
  return res?.taskId ?? ''
}

export async function getFollowUpdateCheckStatus(taskId: string): Promise<FollowUpdateTaskState | null> {
  const res = await apiPost<any>('/api/server-db/follow-updates/check-status', { taskId })
  if (res?.notFound) return null
  return {
    taskId: res?.taskId ?? taskId,
    status: res?.status ?? 'pending',
    total: res?.total ?? 0,
    checked: res?.checked ?? 0,
    updated: res?.updated ?? [],
    currentItem: res?.currentItem ?? '',
    error: res?.error ?? null,
    startTime: res?.startTime ?? 0,
    endTime: res?.endTime ?? null,
    notFound: false,
  }
}

export async function cancelFollowUpdateCheck(taskId: string): Promise<boolean> {
  const res = await apiPost<any>('/api/server-db/follow-updates/check-cancel', { taskId })
  return res?.ok === true && !res?.notFound
}
