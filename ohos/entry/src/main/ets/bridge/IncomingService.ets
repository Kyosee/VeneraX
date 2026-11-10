import Want from '@ohos.app.ability.Want';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import util from '@ohos.util';
import { systemShare } from '@kit.ShareKit';
import {
  Any, EventChannel, EventSink, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult, StreamHandler
} from '@ohos/flutter_ohos';
import { webUrl } from './ShareService';

const MAX_PENDING = 8;
const MAX_TEXT_BYTES = 16 * 1024;
const MAX_LINK_LENGTH = 4096;

class IncomingEvents implements StreamHandler {
  private pending: string[] = [];
  private events?: EventSink;
  private latestOnly: boolean;
  private draining = false;
  private disposed = false;

  constructor(latestOnly: boolean = false) {
    this.latestOnly = latestOnly;
  }

  publish(value: string): void {
    if (this.disposed) return;
    if (this.latestOnly) this.pending.length = 0;
    if (this.pending.length >= MAX_PENDING) return;
    this.pending.push(value);
    this.drain();
  }

  onListen(_args: Any, events: EventSink): void {
    if (this.disposed) return;
    this.events = events;
    this.drain();
  }

  onCancel(_args: Any): void {
    this.events = undefined;
  }

  dispose(): void {
    this.disposed = true;
    this.events = undefined;
    this.pending.length = 0;
  }

  private drain(): void {
    if (this.draining) return;
    this.draining = true;
    try {
      while (!this.disposed && this.events !== undefined && this.pending.length > 0) {
        const value = this.pending.shift()!;
        this.events.success(value);
      }
    } finally {
      this.draining = false;
    }
  }
}

class IncomingShare {
  readonly want: Want;
  readonly complete: () => void;

  constructor(want: Want, complete: () => void) {
    this.want = want;
    this.complete = complete;
  }
}

export class IncomingService implements MethodCallHandler {
  private text = new IncomingEvents();
  private links = new IncomingEvents();
  private notifications = new IncomingEvents(true);
  private eventChannels: EventChannel[] = [];
  private methods: MethodChannel;
  private initialLink: string | null = null;
  private latestLink: string | null = null;
  private shareQueue: IncomingShare[] = [];
  private activeShare?: IncomingShare;
  private processingShares = false;
  private disposed = false;

  constructor(engine: FlutterEngine) {
    const messenger = engine.getDartExecutor().getBinaryMessenger();
    const text = new EventChannel(messenger, 'venera/text_share');
    text.setStreamHandler(this.text);
    const links = new EventChannel(messenger, 'com.llfbandit.app_links/events');
    links.setStreamHandler(this.links);
    const notifications = new EventChannel(messenger, 'venera/notification_route');
    notifications.setStreamHandler(this.notifications);
    this.eventChannels = [text, links, notifications];
    this.methods = new MethodChannel(messenger, 'com.llfbandit.app_links/messages');
    this.methods.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.disposed) {
      result.error('INCOMING_CLOSED', 'Incoming services have been disposed.', null);
    } else if (call.method === 'getInitialLink') {
      result.success(this.initialLink);
    } else if (call.method === 'getLatestLink') {
      result.success(this.latestLink);
    } else {
      result.notImplemented();
    }
  }

  async handleWant(want: Want, initial: boolean = false): Promise<void> {
    if (this.disposed || want === undefined || want === null) return;
    let widgetUri = want.parameters?.['venera.readingWidget.uri'];
    const formParams = want.parameters?.['params'];
    if (widgetUri === undefined && typeof formParams === 'string' && formParams.length <= MAX_TEXT_BYTES) {
      try {
        // Form Kit serializes postCardAction params into Want.parameters.params.
        const parsed = JSON.parse(formParams) as Record<string, string>;
        widgetUri = parsed['venera.readingWidget.uri'];
      } catch (_) {}
    }
    if (typeof widgetUri === 'string' && widgetUri.length <= MAX_LINK_LENGTH &&
      (/^venerax:\/\/reading-widget\/(history|following|updates|local)$/.test(widgetUri) ||
        /^venerax:\/\/reading-widget\/(?:following\/|updates\/|local\/)?read\?id=[^&#]+&type=-?\d+$/.test(widgetUri))) {
      if (initial && this.initialLink === null) this.initialLink = widgetUri;
      this.latestLink = widgetUri;
      this.links.publish(widgetUri);
      return;
    }
    const route = want.parameters?.['venera.notification.route'];
    if (typeof route === 'string' &&
      (route === 'downloading' || route === 'tasks' || route === 'follow_updates')) {
      this.notifications.publish(route);
      return;
    }
    if (want.action === 'ohos.want.action.sendData') {
      if (this.shareQueue.length + (this.processingShares ? 1 : 0) >= MAX_PENDING) return;
      await new Promise<void>((resolve: () => void) => {
        this.shareQueue.push(new IncomingShare(want, resolve));
        this.processShares();
      });
      return;
    }
    if (want.action !== undefined && want.action !== null && want.action !== 'ohos.want.action.viewData') return;
    const link = this.validLink(want.uri);
    if (link === undefined) return;
    if (initial && this.initialLink === null) this.initialLink = link;
    this.latestLink = link;
    this.links.publish(link);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.text.dispose();
    this.links.dispose();
    this.notifications.dispose();
    this.initialLink = null;
    this.latestLink = null;
    this.shareQueue.forEach((share: IncomingShare) => share.complete());
    this.shareQueue.length = 0;
    this.activeShare?.complete();
    this.activeShare = undefined;
    this.methods.setMethodCallHandler(null);
    this.eventChannels.forEach((channel: EventChannel) => channel.setStreamHandler(null));
    this.eventChannels.length = 0;
  }

  private async processShares(): Promise<void> {
    if (this.processingShares || this.disposed) return;
    this.processingShares = true;
    try {
      while (!this.disposed && this.shareQueue.length > 0) {
        const share = this.shareQueue.shift()!;
        this.activeShare = share;
        try {
          await this.readShare(share.want);
        } catch (_) {
          // Invalid or inaccessible shared data must not reach Dart or logs.
        } finally {
          this.activeShare = undefined;
          share.complete();
        }
      }
    } finally {
      this.processingShares = false;
    }
  }

  private async readShare(want: Want): Promise<void> {
    const data = await systemShare.getSharedData(want);
    if (this.disposed) return;
    const records = data.getRecords();
    if (!Array.isArray(records) || records.length > MAX_PENDING) return;
    const encoder = new util.TextEncoder();
    for (const record of records) {
      if (this.disposed) return;
      if (record === undefined || record === null) continue;
      const content = record.content;
      if (typeof content !== 'string' || content.length === 0) continue;
      if (record.utd === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
        if (content.length > MAX_TEXT_BYTES || encoder.encodeInto(content).byteLength > MAX_TEXT_BYTES) continue;
        this.text.publish(content);
      } else if (record.utd === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
        const link = this.validLink(content);
        if (link !== undefined) this.text.publish(link);
      }
    }
  }

  private validLink(value: Any): string | undefined {
    if (typeof value !== 'string' || value.length === 0 || value.length > MAX_LINK_LENGTH) return undefined;
    const link = webUrl(value);
    return link !== undefined && link.length <= MAX_LINK_LENGTH ? link : undefined;
  }
}
