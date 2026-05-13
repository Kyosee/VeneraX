export type HealthResponse = {
  status: 'ok'
  version: string
  database: string
  data_dir: string
  static_assets: boolean
}

export type Capability = {
  key: string
  label: string
  status: 'available' | 'planned' | 'hidden'
  reason?: string
}

export type CapabilitiesResponse = {
  mode: string
  multi_user: boolean
  auth: boolean
  features: Capability[]
}

export type SettingsResponse = {
  values: Record<string, unknown>
  hidden_features: string[]
}

export type SourceSummary = {
  key: string
  name: string
  version: string | null
  file_name: string
  enabled: boolean
  runtime_status: 'registered' | 'pending_parse'
  updated_at: string | null
}

export type SourceWriteRequest = {
  file_name?: string
  content: string
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...init?.headers
    },
    ...init
  })

  if (!response.ok) {
    const text = await response.text()
    if (response.status >= 500) {
      throw new Error('API 服务不可用')
    }
    throw new Error(text || `HTTP ${response.status}`)
  }

  return response.json() as Promise<T>
}

export function getHealth() {
  return request<HealthResponse>('/api/health')
}

export function getCapabilities() {
  return request<CapabilitiesResponse>('/api/capabilities')
}

export function getSettings() {
  return request<SettingsResponse>('/api/settings')
}

export function updateSettings(values: Record<string, unknown>) {
  return request<SettingsResponse>('/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ values })
  })
}

export function getSources() {
  return request<SourceSummary[]>('/api/sources')
}

export function saveSource(payload: SourceWriteRequest) {
  return request<SourceSummary>('/api/sources', {
    method: 'POST',
    body: JSON.stringify(payload)
  })
}

export function deleteSource(key: string) {
  return request<{ deleted: boolean }>(`/api/sources/${encodeURIComponent(key)}`, {
    method: 'DELETE'
  })
}
