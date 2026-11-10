import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';

export class StartupTheme {
  static restore(context: common.UIAbilityContext): void {
    let mode = 'system';
    try {
      const store = preferences.getPreferencesSync(context, { name: 'venera_appearance' });
      const saved = store.getSync('theme_mode', 'system');
      if (saved === 'light' || saved === 'dark') mode = saved;
    } catch (_) {
      console.warn('VeneraX: startup theme preference is unavailable.');
    }
    AppStorage.setOrCreate('veneraThemeMode', mode);
  }

  static async setMode(context: common.UIAbilityContext, mode: string): Promise<void> {
    // Keep the in-app splash current even if saving the preference fails.
    AppStorage.setOrCreate('veneraThemeMode', mode);
    const store = preferences.getPreferencesSync(context, { name: 'venera_appearance' });
    store.putSync('theme_mode', mode);
    await store.flush();
  }

  static background(mode: string): ResourceColor {
    if (mode === 'dark') return '#121212';
    if (mode === 'light') return '#FFFFFF';
    // The system-owned starting window also uses these day/night resources.
    return $r('app.color.start_window_background');
  }
}
