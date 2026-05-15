import { apiPost } from './api'
import type { History, FavoriteItem, FavoriteFolder, ComicSource } from '../types'
import { normalizeComicSources, sourceKeyFromType } from '../utils/source'

type FavoritePayloadItem = Pick<FavoriteItem, 'id' | 'type'> & { folder?: string }

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
}

export async function deleteHistory(id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/history/delete', { id, type })
}

export async function clearHistory(): Promise<void> {
  await apiPost('/api/server-db/history/clear')
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
  const res = await apiPost<any>('/api/server-db/favorites/list', { folder })
  return res?.items ?? res?.favorites ?? res ?? []
}

export async function addFavorite(data: Partial<FavoriteItem>): Promise<void> {
  await apiPost('/api/server-db/favorites/add', { folder: (data as any).folder, item: data })
}

export async function deleteFavorite(folder: string, id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/favorites/delete', { folder, id, type })
}

export async function moveFavorite(sourceFolder: string, targetFolder: string, id: string, type: number): Promise<void> {
  await apiPost('/api/server-db/favorites/move', { sourceFolder, targetFolder, id, type })
}

export async function createFolder(name: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/create', { name })
}

export async function deleteFolder(name: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/delete', { name })
}

export async function renameFolder(before: string, after: string): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/rename', { before, after })
}

export async function reorderFolders(folders: string[]): Promise<void> {
  await apiPost('/api/server-db/favorites/folder/order', { folders })
}

function favoritePayloadItems(items: FavoritePayloadItem[]) {
  return items.map(item => ({ id: item.id, type: item.type }))
}

export async function batchDeleteFavorites(items: FavoritePayloadItem[], folder?: string): Promise<void> {
  const payloadItems = favoritePayloadItems(items)
  if (folder) {
    await apiPost('/api/server-db/favorites/batch-delete', { folder, items: payloadItems })
    return
  }
  await apiPost('/api/server-db/favorites/batch-delete-all', { items: payloadItems })
}

export async function batchMoveFavorites(items: FavoritePayloadItem[], targetFolder: string, sourceFolder?: string): Promise<void> {
  if (sourceFolder) {
    await apiPost('/api/server-db/favorites/batch-move', {
      sourceFolder,
      targetFolder,
      items: favoritePayloadItems(items),
    })
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

export async function searchComics(sourceKey: string, keyword: string, page = 1, options?: Record<string, unknown>): Promise<{ comics: any[], hasMore: boolean }> {
  const res = await apiPost<any>('/api/server-db/search', { sourceKey, keyword, page, options })
  return { comics: res?.comics ?? [], hasMore: res?.hasMore ?? false }
}

export async function listImageFavorites(): Promise<any[]> {
  const res = await apiPost<any>('/api/server-db/image-favorites/list')
  return res?.items ?? res?.favorites ?? res ?? []
}
