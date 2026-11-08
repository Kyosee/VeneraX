import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import deviceInfo from '@ohos.deviceInfo';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import url from '@ohos.url';
import systemShare from '@hms.collaboration.systemShare';
import { Any, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

const SHARE_UNAVAILABLE = 'dev.fluttercommunity.plus/share/unavailable';

export function sanitizeFileName(name: string): string {
  let safe = name.replace(/[\u0000-\u001f\u007f/\\:*?"<>|]/g, '_').trim().replace(/\.+$/g, '');
  if (safe.length === 0 || safe === '.' || safe === '..') return 'file';
  if (safe.length > 80) {
    const dot = safe.lastIndexOf('.');
    const extension = dot > 0 && safe.length - dot <= 20 ? safe.substring(dot) : '';
    safe = safe.substring(0, 80 - extension.length).replace(/[\ud800-\udbff]$/g, '_') + extension;
  }
  // Avoid leaving a split UTF-16 surrogate at the end of a truncated name.
  return safe.replace(/[\ud800-\udbff]$/g, '_');
}

export function webUrl(value: Any): string | undefined {
  if (typeof value !== 'string' || /[\u0000-\u0020\u007f]/.test(value)) return undefined;
  try {
    const parsed = new url.URL(value);
    if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.hostname.length === 0) return undefined;
    return parsed.href;
  } catch (_) {
    return undefined;
  }
}

export async function validateSandboxFile(context: common.UIAbilityContext, path: string,
  authorizedDirectories: string[] = []): Promise<void> {
  if (!path.startsWith('/') || path.includes('\\') || path.includes('\u0000') ||
    path.split('/').some((part: string) => part === '.' || part === '..')) {
    throw new Error('Only an absolute file path is supported.');
  }
  const roots: string[] = [context.cacheDir, context.filesDir, ...authorizedDirectories];
  let root = '';
  for (let index = 0; index < roots.length; index++) {
    if (path.startsWith(roots[index] + '/')) root = roots[index];
  }
  if (root.length === 0) throw new Error('The source file must be inside the app sandbox or an authorized directory.');
  try {
    const rootStat = await fs.lstat(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('The source directory is not accessible.');
    const components = path.substring(root.length + 1).split('/');
    let current = root;
    for (let index = 0; index < components.length; index++) {
      if (components[index].length === 0) throw new Error('An empty path component is not supported.');
      current += '/' + components[index];
      const entry = await fs.lstat(current);
      if (entry.isSymbolicLink() || (index < components.length - 1 && !entry.isDirectory()) ||
        (index === components.length - 1 && !entry.isFile())) {
        throw new Error('Only regular files without symbolic links are supported.');
      }
    }
  } catch (error) {
    throw new Error((error as BusinessError).message);
  }
}

export class ShareService implements MethodCallHandler {
  private channel: MethodChannel;
  private context: common.UIAbilityContext;
  private authorizedDirectories: string[];
  private pending?: MethodResult;
  private controller?: systemShare.ShareController;
  private completion?: (operation: systemShare.ShareOperationResult) => void;
  private dismissal?: () => void;
  private disposed = false;

  constructor(context: common.UIAbilityContext, engine: FlutterEngine, authorizedDirectories: string[] = []) {
    this.context = context;
    this.authorizedDirectories = authorizedDirectories;
    this.channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), 'dev.fluttercommunity.plus/share');
    this.channel.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'share') {
      result.notImplemented();
    } else if (this.disposed) {
      result.error('SHARE_SERVICE_CLOSED', 'Share services have been disposed.', null);
    } else if (this.pending !== undefined) {
      result.error('SHARE_IN_PROGRESS', 'A share operation is already active.', null);
    } else {
      this.pending = result;
      this.share(call, result);
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.channel.setMethodCallHandler(null);
    this.finish(SHARE_UNAVAILABLE);
  }

  private async share(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const records = await this.records(call);
      if (this.disposed || this.pending !== result) return;
      const data = new systemShare.SharedData(records[0]);
      for (let index = 1; index < records.length; index++) data.addRecord(records[index]);
      const controller = new systemShare.ShareController(data);
      this.controller = controller;
      this.dismissal = () => {
        // Dismissal alone does not distinguish a completed share from cancellation.
        if (this.controller === controller) this.finish(SHARE_UNAVAILABLE);
      };
      controller.on('dismiss', this.dismissal);
      if (deviceInfo.sdkApiVersion >= 18) {
        this.completion = (operation: systemShare.ShareOperationResult) => {
          if (this.controller === controller) this.finish(operation.targetAbilityInfo.name || SHARE_UNAVAILABLE);
        };
        controller.on('shareCompleted', this.completion);
      }
      const options: systemShare.ShareControllerOptions = {
        selectionMode: records.length > 1 ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE
      };
      await controller.show(this.context, options);
    } catch (error) {
      if (this.pending !== result) return;
      const failure = error as BusinessError;
      this.clearListeners();
      this.pending = undefined;
      result.error('SHARE_FAILED', failure.message, failure.code ?? null);
    }
  }

  private async records(call: MethodCall): Promise<systemShare.SharedRecord[]> {
    const textValue: Any = call.argument('text');
    const titleValue: Any = call.argument('subject') ?? call.argument('title');
    const text = typeof textValue === 'string' ? textValue : '';
    const title = typeof titleValue === 'string' ? titleValue : '';
    const pathsValue: Any = call.argument('paths');
    const mimeValue: Any = call.argument('mimeTypes');
    if (pathsValue !== null && pathsValue !== undefined && !Array.isArray(pathsValue)) {
      throw new Error('Share paths must be a list of app sandbox paths.');
    }
    const paths = (pathsValue ?? []) as string[];
    if (paths.length > 32 || paths.some((path: string) => typeof path !== 'string')) {
      throw new Error('Share supports at most 32 app sandbox files.');
    }
    if (mimeValue !== null && mimeValue !== undefined && (!Array.isArray(mimeValue) ||
      (mimeValue as string[]).length !== paths.length || (mimeValue as string[]).some((mime: string) => typeof mime !== 'string'))) {
      throw new Error('Share MIME types must match the file list.');
    }
    const mimeTypes = (mimeValue ?? []) as string[];
    const records: systemShare.SharedRecord[] = [];
    let estimatedBytes = (text.length + title.length) * 3;
    for (let index = 0; index < paths.length; index++) {
      await validateSandboxFile(this.context, paths[index], this.authorizedDirectories);
      const uri = fileUri.getUriFromPath(paths[index]);
      const record: systemShare.SharedRecord = {
        utd: this.fileType(paths[index], mimeTypes[index]), uri: uri, title: title || undefined, description: text || undefined
      };
      estimatedBytes += (uri.length + text.length + title.length) * 3 + 512;
      records.push(record);
    }
    if (paths.length === 0) {
      const uriValue: Any = call.argument('uri');
      const link = uriValue === null || uriValue === undefined ? undefined : webUrl(uriValue);
      if (uriValue !== null && uriValue !== undefined && link === undefined) {
        throw new Error('Only HTTP(S) links can be shared as a URI.');
      }
      if (link === undefined && text.length === 0) throw new Error('Share requires text, a link or a file.');
      records.push({
        utd: link === undefined ? uniformTypeDescriptor.UniformDataType.PLAIN_TEXT : uniformTypeDescriptor.UniformDataType.HYPERLINK,
        content: link ?? text, title: title || undefined, description: link === undefined ? undefined : text || undefined
      });
      estimatedBytes += (link?.length ?? 0) * 3 + 512;
    }
    if (estimatedBytes > 160 * 1024) throw new Error('The shared text and metadata exceed the system share IPC limit.');
    return records;
  }

  private fileType(path: string, mime?: string): string {
    try {
      if (mime && mime.length <= 255 && mime !== 'application/octet-stream' &&
        /^[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+$/.test(mime)) {
        const type = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mime, uniformTypeDescriptor.UniformDataType.FILE);
        if (type.length > 0) return type;
      }
    } catch (_) {
      // Fall back to the filename when the MIME mapping is unavailable.
    }
    try {
      const name = path.substring(path.lastIndexOf('/') + 1);
      const dot = name.lastIndexOf('.');
      if (dot > 0) {
        const type = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(name.substring(dot).toLowerCase(), uniformTypeDescriptor.UniformDataType.FILE);
        if (type.length > 0) return type;
      }
    } catch (_) {
      // A generic file remains shareable if the system cannot resolve its type.
    }
    return uniformTypeDescriptor.UniformDataType.FILE;
  }

  private finish(value: string): void {
    const result = this.pending;
    this.pending = undefined;
    this.clearListeners();
    result?.success(value);
  }

  private clearListeners(): void {
    const controller = this.controller;
    this.controller = undefined;
    if (controller !== undefined) {
      try {
        if (this.dismissal !== undefined) controller.off('dismiss', this.dismissal);
      } catch (_) {
        console.warn('Venera: removing the share dismissal listener failed.');
      }
      try {
        if (this.completion !== undefined) controller.off('shareCompleted', this.completion);
      } catch (_) {
        console.warn('Venera: removing the share completion listener failed.');
      }
    }
    this.dismissal = undefined;
    this.completion = undefined;
  }
}
