import { argbFromHex, hexFromArgb, themeFromSourceColor } from '@material/material-color-utilities'

export type Brightness = 'light' | 'dark'
export type ColorScheme = Record<string, string>

const ROLES = [
  'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
  'secondary', 'onSecondary', 'secondaryContainer', 'onSecondaryContainer',
  'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer',
  'error', 'onError', 'errorContainer', 'onErrorContainer',
  'background', 'onBackground',
  'surface', 'onSurface', 'surfaceVariant', 'onSurfaceVariant',
  'outline', 'outlineVariant',
  'inverseSurface', 'inverseOnSurface', 'inversePrimary',
  'shadow', 'scrim',
] as const

export function fromSeeds(opts: { primary: string; brightness: Brightness }): ColorScheme {
  const theme = themeFromSourceColor(argbFromHex(opts.primary))
  const scheme = opts.brightness === 'light' ? theme.schemes.light : theme.schemes.dark
  const out: ColorScheme = {}
  for (const role of ROLES) {
    const argb = (scheme as unknown as Record<string, number>)[role]
    if (typeof argb === 'number') out[role] = hexFromArgb(argb).toUpperCase()
  }
  return out
}
