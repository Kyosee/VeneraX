import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';
import { ReadingWidgetStore } from './ReadingWidgetStore';

export class ReadingWidgetService implements MethodCallHandler {
  private store: ReadingWidgetStore;
  private updates: Promise<void> = Promise.resolve();

  constructor(filesDir: string) { this.store = new ReadingWidgetStore(filesDir); }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'hasWidgets') {
      result.success(this.store.hasWidgets(call.args as string));
      return;
    }
    if (call.method !== 'update') {
      result.notImplemented();
      return;
    }
    try {
      const json: string = call.args as string;
      if (typeof json !== 'string') throw new Error('Invalid snapshot');
      const kind = this.store.save(json);
      // A later privacy update must be the last update delivered to every form.
      this.updates = this.updates.catch(() => {}).then(() => this.store.updateAll(kind));
      this.updates.then(() => result.success(null)).catch(() => {
        result.error('WIDGET_UPDATE_FAILED', 'Unable to update reading widgets.', null);
      });
    } catch (_) {
      result.error('WIDGET_UPDATE_FAILED', 'Unable to save reading widget data.', null);
    }
  }
}
