import { apiPost } from './api'
import type { SyncStatus } from '../types'

export function getWebDavConfig() {
  return apiPost<{ ok: boolean; url?: string; user?: string; pass?: string; autoSync?: boolean }>('/sync/webdav/config/get')
}

export function saveWebDavConfig(url: string, user: string, pass: string, autoSync: boolean) {
  return apiPost('/sync/webdav/config/save', { url, user, pass, autoSync })
}

export function triggerDownload() {
  return apiPost('/sync/webdav/download', {})
}

export async function triggerUpload(): Promise<never> {
  throw new Error('Web 端无法直接构造 Venera 备份体，请通过设置页导出备份后上传')
}

export async function getSyncStatus(): Promise<SyncStatus> {
  const res = await apiPost<any>('/api/server-db/status')
  return {
    isDownloading: false,
    isUploading: false,
    lastError: res?.metadata?.lastError,
    isEnabled: res?.initialized ?? false,
  }
}
