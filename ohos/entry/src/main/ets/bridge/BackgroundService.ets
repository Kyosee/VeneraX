import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { Any, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

const COMPLETION_NOTIFICATION_ID = 0x56454E41;
const COMPLETION_NOTIFICATION_LABEL = 'venera.download.complete';

interface TransferTask {
  tag: string;
  status: string;
  progress: number;
}

interface PublishedProgress {
  task: TransferTask;
  status: string;
  progress: number;
}

interface PendingCancellation {
  id: number;
  tasks: TransferTask[];
}

export class BackgroundService {
  private context: common.UIAbilityContext;
  private download: MethodChannel;
  private background: MethodChannel;
  private desired = new Map<string, TransferTask>();
  private blocked = new Set<string>();
  private pending = new Set<MethodResult>();
  private queue: Promise<void> = Promise.resolve();
  private permissionRequest?: Promise<boolean>;
  private permissionAsked = false;
  private running?: backgroundTaskManager.ContinuousTaskNotification;
  private published?: PublishedProgress;
  private starting = false;
  private startCancellations: PendingCancellation[] = [];
  private stoppingId?: number;
  private listening = false;
  private disposed = false;
  private cancellation = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    this.onCancelled(info);
  };

  constructor(context: common.UIAbilityContext, engine: FlutterEngine) {
    this.context = context;
    const messenger = engine.getDartExecutor().getBinaryMessenger();
    this.download = new MethodChannel(messenger, 'venera/download_keepalive');
    this.background = new MethodChannel(messenger, 'venera/background_keepalive');
    this.download.setMethodCallHandler(new BackgroundChannelHandler(this, true));
    this.background.setMethodCallHandler(new BackgroundChannelHandler(this, false));
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancellation);
      this.listening = true;
    } catch (_) {
      // Starting without cancellation events would bypass user dismissal.
      this.listening = false;
    }
  }

  handleCall(download: boolean, call: MethodCall, result: MethodResult): void {
    if (this.disposed) {
      result.error('BACKGROUND_CLOSED', 'Background service is closed.', null);
      return;
    }
    this.pending.add(result);
    try {
      if (call.method === 'notificationGranted') {
        this.replyWhen(result, this.enqueue(async (): Promise<boolean> => {
          return !this.disposed && await notificationManager.isNotificationEnabled();
        }));
      } else if (call.method === 'requestNotification') {
        this.replyWhen(result, this.requestNotification());
      } else if ((download && call.method === 'start') || (!download && call.method === 'update')) {
        const tag = download ? 'download' : this.readTag(call);
        const status: Any = call.argument('status');
        const progress: Any = call.argument('progress');
        if (!this.validText(status) || typeof progress !== 'number' ||
          !Number.isFinite(progress) || progress < 0 || progress > 100) {
          throw new Error('Invalid transfer');
        }
        if (!this.desired.has(tag) && this.desired.size >= 32) throw new Error('Too many transfers');
        let task = this.desired.get(tag);
        if (task === undefined) {
          task = { tag: tag, status: status as string, progress: progress };
          this.desired.set(tag, task);
        } else {
          task.status = status as string;
          task.progress = progress;
        }
        this.replyWhen(result, this.enqueue(async (): Promise<boolean> => {
          if (!await this.reconcile()) return false;
          return this.running !== undefined && this.desired.has(tag) && !this.blocked.has(tag);
        }));
      } else if ((download && call.method === 'stop') || (!download && call.method === 'remove')) {
        const tag = download ? 'download' : this.readTag(call);
        this.desired.delete(tag);
        this.blocked.delete(tag);
        this.replyWhen(result, this.enqueue((): Promise<boolean> => this.reconcile()));
      } else if (download && call.method === 'complete') {
        const status: Any = call.argument('status');
        if (!this.validText(status)) throw new Error('Invalid status');
        this.desired.delete('download');
        this.blocked.delete('download');
        this.replyWhen(result, this.enqueue(async (): Promise<boolean> => {
          const reconciled = await this.reconcile();
          if (this.disposed || !await notificationManager.isNotificationEnabled()) return false;
          const agent = await this.notificationAgent(true);
          if (this.disposed) return false;
          await notificationManager.publish({
            id: COMPLETION_NOTIFICATION_ID,
            label: COMPLETION_NOTIFICATION_LABEL,
            wantAgent: agent,
            notificationSlotType: notificationManager.SlotType.OTHER_TYPES,
            content: {
              notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
              normal: { title: 'Venera', text: status as string }
            }
          });
          if (this.disposed) {
            await notificationManager.cancel(COMPLETION_NOTIFICATION_ID, COMPLETION_NOTIFICATION_LABEL);
            return false;
          }
          return reconciled;
        }));
      } else {
        this.pending.delete(result);
        result.notImplemented();
      }
    } catch (_) {
      this.pending.delete(result);
      result.error('BACKGROUND_ARGUMENT', 'Invalid background transfer arguments.', null);
    }
  }

  private validText(value: Any): boolean {
    return typeof value === 'string' && value.length <= 2048 && value.trim().length > 0;
  }

  private readTag(call: MethodCall): string {
    const tag: Any = call.argument('tag');
    if (typeof tag !== 'string' || tag.length > 21 || !/^sync_(0|[1-9][0-9]*)$/.test(tag) ||
      !Number.isSafeInteger(Number(tag.substring(5)))) throw new Error('Invalid tag');
    return tag;
  }

  private enqueue(operation: () => Promise<boolean>): Promise<boolean> {
    const work = this.queue.then(async (): Promise<boolean> => {
      try {
        return await operation();
      } catch (_) {
        return false;
      }
    });
    this.queue = work.then((): void => {});
    return work;
  }

  private replyWhen(result: MethodResult, work: Promise<boolean>): void {
    work.then((value: boolean): void => {
      if (!this.pending.delete(result)) return;
      try {
        result.success(value);
      } catch (_) {}
    });
  }

  private requestNotification(): Promise<boolean> {
    if (this.permissionRequest !== undefined) return this.permissionRequest;
    const work = this.enqueue(async (): Promise<boolean> => {
      if (this.disposed) return false;
      if (await notificationManager.isNotificationEnabled()) return !this.disposed;
      if (this.disposed || this.permissionAsked) return false;
      this.permissionAsked = true;
      await notificationManager.requestEnableNotification(this.context);
      return !this.disposed && await notificationManager.isNotificationEnabled();
    });
    this.permissionRequest = work;
    work.then((): void => {
      if (this.permissionRequest === work) this.permissionRequest = undefined;
    });
    return work;
  }

  private activeTasks(): TransferTask[] {
    const tasks: TransferTask[] = [];
    this.desired.forEach((task: TransferTask, tag: string): void => {
      if (!this.blocked.has(tag)) tasks.push(task);
    });
    return tasks;
  }

  private notificationAgent(download: boolean): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'venera.notification.route': download ? 'downloading' : 'tasks' }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: download ? 0 : 1,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  private async reconcile(): Promise<boolean> {
    if (this.disposed || this.activeTasks().length === 0) return this.stopRunning();
    try {
      if (this.running === undefined) {
        if (!this.listening || !await notificationManager.isNotificationEnabled()) return false;
        let first = this.activeTasks()[0];
        if (this.disposed || first === undefined) return this.stopRunning();
        const agent = await this.notificationAgent(first.tag === 'download');
        first = this.activeTasks()[0];
        if (this.disposed || first === undefined) return this.stopRunning();
        this.starting = true;
        this.startCancellations = [];
        try {
          this.running = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
        } finally {
          this.starting = false;
        }
        const running = this.running;
        if (!Number.isSafeInteger(running.notificationId) || running.continuousTaskId === undefined ||
          !Number.isSafeInteger(running.continuousTaskId)) {
          await this.stopRunning();
          return false;
        }
        for (const event of this.startCancellations) {
          if (event.id === running.continuousTaskId) this.cancelTasks(running, event.tasks);
        }
        this.startCancellations = [];
      }
      const running = this.running;
      const first = this.activeTasks()[0];
      if (this.disposed || first === undefined) {
        await this.stopRunning();
        return false;
      }
      if (running === undefined) return false;
      const published = this.published;
      if (published !== undefined && published.task === first && published.status === first.status &&
        published.progress === first.progress) return true;
      const snapshot: PublishedProgress = { task: first, status: first.status, progress: first.progress };
      await notificationManager.publish({
        id: running.notificationId,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: { typeCode: 8, title: 'Venera', text: snapshot.status }
        },
        template: {
          name: 'downloadTemplate',
          data: { title: 'Venera', fileName: snapshot.status, progressValue: snapshot.progress }
        }
      });
      if (this.running !== running) return false;
      if (this.disposed || this.activeTasks().length === 0) {
        await this.stopRunning();
        return false;
      }
      this.published = snapshot;
      return true;
    } catch (_) {
      this.startCancellations = [];
      await this.stopRunning();
      return false;
    }
  }

  private async stopRunning(): Promise<boolean> {
    const running = this.running;
    if (running === undefined) return true;
    this.stoppingId = running.continuousTaskId;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      if (this.running === running) {
        this.running = undefined;
        this.published = undefined;
      }
      return true;
    } catch (_) {
      // Retain the handle so a later cleanup retries instead of starting another task.
      return false;
    } finally {
      this.stoppingId = undefined;
    }
  }

  private onCancelled(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    if (this.disposed || !Number.isSafeInteger(info.id) || info.id === this.stoppingId) return;
    const running = this.running;
    if (running !== undefined && running.continuousTaskId === info.id) {
      this.cancelTasks(running, this.activeTasks());
    } else if (this.starting) {
      this.startCancellations.push({ id: info.id, tasks: this.activeTasks() });
    }
  }

  private cancelTasks(running: backgroundTaskManager.ContinuousTaskNotification, tasks: TransferTask[]): void {
    if (this.running !== running) return;
    this.running = undefined;
    this.published = undefined;
    const syncTags: string[] = [];
    let download = false;
    for (const task of tasks) {
      if (this.desired.get(task.tag) !== task) continue;
      this.blocked.add(task.tag);
      if (task.tag === 'download') download = true;
      else syncTags.push(task.tag);
    }
    if (download) {
      try {
        this.download.invokeMethod('cancelled', null);
      } catch (_) {}
    }
    if (syncTags.length > 0) {
      try {
        this.background.invokeMethod('cancelled', { tags: syncTags });
      } catch (_) {}
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.desired.clear();
    this.blocked.clear();
    this.download.setMethodCallHandler(null);
    this.background.setMethodCallHandler(null);
    this.pending.forEach((result: MethodResult): void => {
      this.pending.delete(result);
      try {
        result.error('BACKGROUND_CLOSED', 'Background service is closed.', null);
      } catch (_) {}
    });
    if (this.listening) {
      this.listening = false;
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancellation);
      } catch (_) {}
    }
    this.enqueue((): Promise<boolean> => this.stopRunning());
  }
}

class BackgroundChannelHandler implements MethodCallHandler {
  private service: BackgroundService;
  private download: boolean;

  constructor(service: BackgroundService, download: boolean) {
    this.service = service;
    this.download = download;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.service.handleCall(this.download, call, result);
  }
}
