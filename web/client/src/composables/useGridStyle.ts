import { computed } from 'vue'
import { useSettingsStore } from '@/stores/settings'

export function useGridStyle() {
  const settingsStore = useSettingsStore()
  return computed(() => {
    const scale = Number(settingsStore.settings.thumbnailSize || 1)
    return settingsStore.settings.thumbnailMode === 'brief'
      ? {
          '--tile-scale': String(scale),
          gridTemplateColumns: `repeat(auto-fill, minmax(96px, ${Math.round(192 * scale)}px))`,
        }
      : {
          '--tile-scale': String(scale),
          gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 360px), 1fr))',
        }
  })
}
