import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { bundleManager, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { connection } from '@kit.NetworkKit';
import { Any, FlutterEngine, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { DartEntrypoint } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/dart/DartExecutor';
import { FOLLOW_WORK_ID } from '../bridge/FollowSchedulerService';
import { ReadingWidgetService } from '../widget/ReadingWidgetService';

const FOLLOW_STAGES: string[] = ['data', 'translation', 'network', 'stores', 'sources', 'checks', 'cleanup'];

export default class FollowUpdatesAbility extends WorkSchedulerExtensionAbility {
  private engine?: FlutterEngine;
  private channel?: MethodChannel;
  private paths?: MethodChannel;
  private system?: MethodChannel;
  private widgets?: MethodChannel;
  private lease?: fs.File;
  private deadline?: number;
  private stopping = false;

  onWorkStart(work: workScheduler.WorkInfo): void {
    if (work.workId !== FOLLOW_WORK_ID || this.engine !== undefined) return;
    this.stopping = false;
    console.info('VeneraX follow scheduler: started');
    try {
      this.lease = fs.openSync(`${this.context.filesDir}/.follow-scheduler.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        this.lease.tryLock(true);
      } catch (_) {
        console.info('VeneraX follow scheduler: UI owns data');
        this.finish(work);
        return;
      }
      const engine = new FlutterEngine(this.context, null, null, null);
      this.engine = engine;
      engine.init(this.context, null, false);
      const messenger = engine.getDartExecutor().getBinaryMessenger();
      this.widgets = new MethodChannel(messenger, 'venera/reading_widget');
      this.widgets.setMethodCallHandler(new ReadingWidgetService(this.context.filesDir));
      this.paths = new MethodChannel(messenger, 'plugins.flutter.io/path_provider');
      this.paths.setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult): void => {
          if (call.method === 'getApplicationSupportDirectory' || call.method === 'getApplicationDocumentsDirectory') {
            result.success(this.context.filesDir);
          } else if (call.method === 'getTemporaryDirectory' || call.method === 'getApplicationCacheDirectory') {
            result.success(this.context.cacheDir);
          } else result.notImplemented();
        }
      });
      this.system = new MethodChannel(messenger, 'venera/method_channel');
      this.system.setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult): void => {
          if (call.method === 'getProxy') {
            connection.getDefaultHttpProxy().then((proxy: connection.HttpProxy): void => {
              if (this.engine !== engine) return;
              const host = proxy.host.trim();
              const address = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
              result.success(host.length > 0 && proxy.port > 0 && proxy.port <= 65535 &&
                !(proxy.exclusionList.length === 1 && proxy.exclusionList[0] === '*') ? `${address}:${proxy.port}` : 'No Proxy');
            }).catch((): void => {
              if (this.engine === engine) result.success('No Proxy');
            });
          } else result.notImplemented();
        }
      });
      const channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), 'venera/follow_scheduler');
      this.channel = channel;
      channel.setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult): void => {
          if (this.engine !== engine) return;
          if (call.method === 'ready') {
            console.info('VeneraX follow scheduler: Dart ready');
            result.success(this.stopping);
          } else if (call.method === 'stage') {
            const stage: Any = call.argument('stage');
            if (typeof stage === 'string' && FOLLOW_STAGES.includes(stage as string)) {
              console.info(`VeneraX follow scheduler: ${stage as string}`);
            }
            result.success(null);
          } else if (call.method === 'finished') {
            const outcome: Any = call.argument('outcome');
            const stage: Any = call.argument('stage');
            if (typeof outcome === 'string' && typeof stage === 'string' &&
              ['checked', 'cancelled', 'disabled', 'failed'].includes(outcome as string) &&
              FOLLOW_STAGES.includes(stage as string)) {
              console.info(`VeneraX follow scheduler: finished ${outcome as string} (${stage as string})`);
            }
            result.success(null);
            setTimeout((): void => {
              if (this.engine === engine) this.finish(work);
            }, 0);
          } else if (call.method === 'notify') {
            const status: Any = call.argument('status');
            if (typeof status !== 'string' || status.length > 256) {
              result.error('INVALID_STATUS', 'Invalid completion message.', null);
              return;
            }
            this.notify(status as string, engine).then((sent: boolean): void => {
              if (this.engine === engine) result.success(sent);
            }).catch((): void => {
              if (this.engine === engine) result.success(false);
            });
          } else {
            result.notImplemented();
          }
        }
      });
      this.deadline = setTimeout((): void => {
        if (this.engine === engine) this.requestStop(work);
      }, 100000);
      engine.getDartExecutor().executeDartEntrypoint(new DartEntrypoint(
        engine.getFlutterLoader().findAppBundlePath(), '', 'followUpdatesBackgroundMain'
      ), [this.context.filesDir, this.context.cacheDir, bundleManager.getBundleInfoForSelfSync(0).versionName]);
    } catch (_) {
      console.warn('VeneraX follow scheduler: engine unavailable');
      this.finish(work);
    }
  }

  private async notify(status: string, engine: FlutterEngine): Promise<boolean> {
    if (this.stopping || !await notificationManager.isNotificationEnabled()) return false;
    if (this.stopping || this.engine !== engine) return false;
    const agent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: bundleManager.getBundleInfoForSelfSync(0).name,
        abilityName: 'EntryAbility',
        parameters: { 'venera.notification.route': 'follow_updates' }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (this.stopping || this.engine !== engine) return false;
    await notificationManager.publish({
      id: 0x56454E44,
      label: 'venera.follow_update.complete',
      wantAgent: agent,
      notificationSlotType: notificationManager.SlotType.OTHER_TYPES,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: 'VeneraX', text: status }
      }
    });
    return true;
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    if (work.workId === FOLLOW_WORK_ID) this.requestStop(work);
  }

  private requestStop(work: workScheduler.WorkInfo): void {
    if (this.stopping || this.engine === undefined) return;
    const engine = this.engine;
    this.stopping = true;
    if (this.deadline !== undefined) clearTimeout(this.deadline);
    this.channel?.invokeMethod('stop', null);
    this.deadline = setTimeout((): void => {
      if (this.engine === engine) this.finish(work);
    }, 5000);
  }

  private finish(work: workScheduler.WorkInfo): void {
    this.stopping = true;
    if (this.deadline !== undefined) clearTimeout(this.deadline);
    this.deadline = undefined;
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.paths?.setMethodCallHandler(null);
    this.system?.setMethodCallHandler(null);
    this.widgets?.setMethodCallHandler(null);
    this.paths = undefined;
    this.system = undefined;
    this.widgets = undefined;
    const engine = this.engine;
    this.engine = undefined;
    try {
      engine?.destroy();
    } finally {
      // Release only after Dart can no longer write to any shared store.
      if (this.lease !== undefined) fs.closeSync(this.lease);
      this.lease = undefined;
    }
    try {
      workScheduler.stopWork(work, false);
    } catch (_) {}
  }
}
