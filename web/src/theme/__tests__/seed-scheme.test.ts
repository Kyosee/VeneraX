import { describe, expect, it } from 'vitest'
import { COLOR_PRESETS } from '../color-presets'
import { fromSeeds } from '../seed-scheme'

describe('fromSeeds', () => {
  for (const [presetName, hex] of Object.entries(COLOR_PRESETS)) {
    for (const brightness of ['light', 'dark'] as const) {
      it(`${presetName}/${brightness} produces a valid scheme`, () => {
        const scheme = fromSeeds({ primary: hex, brightness })
        expect(scheme.primary).toMatch(/^#[0-9A-F]{6}$/)
        expect(scheme.onPrimary).toMatch(/^#[0-9A-F]{6}$/)
        expect(scheme.surface).toMatch(/^#[0-9A-F]{6}$/)
        expect(scheme.onSurface).toMatch(/^#[0-9A-F]{6}$/)
        expect(scheme.error).toMatch(/^#[0-9A-F]{6}$/)
        // primary ≠ onPrimary (contrast guarantee)
        expect(scheme.primary).not.toBe(scheme.onPrimary)
      })
    }
  }

  it('light and dark produce different surface colors for same seed', () => {
    const light = fromSeeds({ primary: COLOR_PRESETS.blue, brightness: 'light' })
    const dark = fromSeeds({ primary: COLOR_PRESETS.blue, brightness: 'dark' })
    expect(light.surface).not.toBe(dark.surface)
  })

  it('different seeds produce different primary colors', () => {
    const blue = fromSeeds({ primary: COLOR_PRESETS.blue, brightness: 'light' })
    const red = fromSeeds({ primary: COLOR_PRESETS.red, brightness: 'light' })
    expect(blue.primary).not.toBe(red.primary)
  })
})
