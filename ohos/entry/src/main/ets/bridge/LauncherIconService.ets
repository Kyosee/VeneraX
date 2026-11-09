import { bundleManager } from '@kit.AbilityKit';
import { Any, MethodCall, MethodResult } from '@ohos/flutter_ohos';

const ALTERNATE_ICON_NAMES: string[] = ['IconOrig', 'IconFlat', 'IconMono', 'IconIllust'];

export class LauncherIconService {
  private pending = new Set<MethodResult>();
  private changing = false;
  private disposed = false;

  static async getStartupIcon(): Promise<Resource | undefined> {
    try {
      if (typeof bundleManager.getAlternateIcons !== 'function') {
        return $r('app.media.icon_default');
      }
      const icons = await bundleManager.getAlternateIcons();
      const current = icons.find((icon: bundleManager.AlternateIconInfo): boolean => icon.enabled);
      if (current === undefined) return $r('app.media.icon_default');
      switch (current.iconName) {
        case 'IconOrig': return $r('app.media.icon_orig');
        case 'IconFlat': return $r('app.media.icon_flat');
        case 'IconMono': return $r('app.media.icon_mono');
        case 'IconIllust': return $r('app.media.icon_illust');
        default: return undefined;
      }
    } catch (_) {
      // Keep a neutral background when the active icon cannot be determined.
      return undefined;
    }
  }

  handleMethodCall(call: MethodCall, result: MethodResult): boolean {
    if (call.method !== 'supportsAlternateIcons' && call.method !== 'setLauncherIcon') return false;
    if (this.disposed) {
      result.error('LAUNCHER_ICON_CLOSED', 'Launcher icon service has been disposed.', null);
      return true;
    }

    let alias: string | undefined;
    if (call.method === 'setLauncherIcon') {
      try {
        const value: Any = call.argument('alias');
        if (value !== null && (typeof value !== 'string' ||
          (value !== '' && !ALTERNATE_ICON_NAMES.includes(value as string)))) {
          result.error('INVALID_ARGUMENT', 'Unknown launcher icon alias.', null);
          return true;
        }
        alias = value === null ? '' : value as string;
      } catch (_) {
        result.error('INVALID_ARGUMENT', 'A launcher icon alias is required.', null);
        return true;
      }
      if (this.changing) {
        result.error('LAUNCHER_ICON_BUSY', 'A launcher icon change is already running.', null);
        return true;
      }
      this.changing = true;
    }

    this.pending.add(result);
    this.handle(alias, result);
    return true;
  }

  private async handle(alias: string | undefined, result: MethodResult): Promise<void> {
    try {
      // The shared Core capability exists on older systems without these APIs.
      if (typeof bundleManager.getAlternateIcons !== 'function' ||
        typeof bundleManager.setAlternateIcon !== 'function') {
        this.reply(result, false);
        return;
      }
      const icons = await bundleManager.getAlternateIcons();
      if (this.disposed || !this.pending.has(result)) return;
      const supported = ALTERNATE_ICON_NAMES.every((name: string): boolean =>
        icons.some((icon: bundleManager.AlternateIconInfo): boolean => icon.iconName === name));
      if (alias === undefined || !supported) {
        this.reply(result, supported);
        return;
      }

      // Avoid the official "no alternate icon enabled" error on a default reset.
      const current = icons.find((icon: bundleManager.AlternateIconInfo): boolean => icon.enabled)?.iconName ?? '';
      if (current !== alias) await bundleManager.setAlternateIcon(alias);
      this.reply(result, true);
    } catch (_) {
      this.reply(result, false);
    } finally {
      if (alias !== undefined) this.changing = false;
    }
  }

  private reply(result: MethodResult, value: boolean): void {
    if (this.pending.delete(result)) result.success(value);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.pending.forEach((result: MethodResult): void => {
      this.pending.delete(result);
      result.error('LAUNCHER_ICON_CLOSED', 'Launcher icon service has been disposed.', null);
    });
    // The official icon API has no cancellation; ignore its late completion.
  }
}
