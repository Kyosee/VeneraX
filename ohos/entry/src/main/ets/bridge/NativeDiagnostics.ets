import { AbilityConstant } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';

export class NativeDiagnostics {
  private path: string;
  private watcher?: hiAppEvent.Watcher;

  constructor(filesDir: string, launch: AbilityConstant.LaunchParam) {
    this.path = `${filesDir}/native_diagnostics.json`;
    const reason = launch.lastExitReason;
    if ([1, 3, 4, 5, 6, 7, 10].includes(reason)) {
      this.record(`Previous process exit (${reason}): ${launch.lastExitMessage ?? ''}`);
    }
    this.watcher = {
      name: 'VeneraNativeDiagnostics',
      appEventFilters: [{ domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
      onReceive: (_domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        for (const group of groups) {
          for (const event of group.appEventInfos) this.capture(event);
        }
      }
    };
    try { hiAppEvent.addWatcher(this.watcher); } catch (_) {
      console.warn('Native crash event subscription unavailable');
    }
  }

  private capture(event: hiAppEvent.AppEventInfo): void {
    const params = event.params as Record<string, Object>;
    const details: Record<string, Object> = {
      'time': params['time'], 'crashType': params['crash_type'], 'foreground': params['foreground'],
      'version': params['bundle_version'], 'exception': params['exception'], 'memory': params['memory']
    };
    let text = `${event.name}: ${JSON.stringify(details)}`;
    const paths = params['external_log'] as string[];
    if (Array.isArray(paths)) {
      for (const path of paths) {
        // Only OS-owned reports for this app; never follow arbitrary event paths.
        if (typeof path !== 'string' || !path.startsWith('/data/storage/el2/log/hiappevent/') ||
          path.includes('..')) continue;
        try { text += `\n${fs.readTextSync(path, { length: 65536 })}`; } catch (_) {}
        if (text.length >= 65536) break;
      }
    }
    this.record(text.slice(0, 65536));
  }

  private record(message: string): void {
    try {
      message = message.slice(0, 65536);
      const records = this.read();
      if (records.includes(message)) return;
      records.push(message);
      const file = fs.openSync(`${this.path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(records.slice(-4))); } finally { fs.closeSync(file); }
      fs.renameSync(`${this.path}.tmp`, this.path);
    } catch (_) { console.warn('Unable to persist native diagnostics'); }
  }

  read(): string[] {
    try {
      const records = JSON.parse(fs.readTextSync(this.path)) as string[];
      return Array.isArray(records) ? records.filter((entry: string) => typeof entry === 'string').slice(-4) : [];
    } catch (_) { return []; }
  }

  dispose(): void {
    if (this.watcher === undefined) return;
    try { hiAppEvent.removeWatcher(this.watcher); } catch (_) {}
    this.watcher = undefined;
  }
}
