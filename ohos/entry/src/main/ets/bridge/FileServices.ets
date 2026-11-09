import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import bundleManager from '@ohos.bundle.bundleManager';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import picker from '@ohos.file.picker';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import { Any, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { sanitizeFileName, ShareService, validateSandboxFile, webUrl } from './ShareService';
import { DirectoryAccess } from './DirectoryAccess';

const COPY_BUFFER_SIZE = 256 * 1024;

class FileReply {
  private result: MethodResult;
  private completed = false;
  private onComplete: () => void;

  constructor(result: MethodResult, onComplete: () => void) {
    this.result = result;
    this.onComplete = onComplete;
  }

  success(value: Any): void {
    if (this.completed) return;
    this.completed = true;
    this.onComplete();
    this.result.success(value);
  }

  error(code: string, message: string, details: Any = null): void {
    if (this.completed) return;
    this.completed = true;
    this.onComplete();
    this.result.error(code, message, details);
  }

  notImplemented(): void {
    if (this.completed) return;
    this.completed = true;
    this.onComplete();
    this.result.notImplemented();
  }
}

export class FileServices implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channels: MethodChannel[] = [];
  private share: ShareService;
  private directories: DirectoryAccess;
  private pending = new Set<FileReply>();
  private pickerActive = false;
  private disposed = false;

  constructor(context: common.UIAbilityContext, engine: FlutterEngine) {
    this.context = context;
    this.directories = new DirectoryAccess(context);
    const messenger = engine.getDartExecutor().getBinaryMessenger();
    const names: string[] = ['plugins.flutter.io/file_selector', 'flutter_file_dialog', 'plugins.flutter.io/url_launcher'];
    for (let index = 0; index < names.length; index++) {
      const channel = new MethodChannel(messenger, names[index]);
      channel.setMethodCallHandler(this);
      this.channels.push(channel);
    }
    this.share = new ShareService(context, engine, this.directories.roots);
  }

  // Route only this shared-channel method here; keep the central channel owner.
  handleMethodCall(call: MethodCall, result: MethodResult): boolean {
    if (call.method !== 'getDirectoryPath' && call.method !== 'restoreDirectories') return false;
    this.onMethodCall(call, result);
    return true;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const reply: FileReply = new FileReply(result, () => this.pending.delete(reply));
    this.pending.add(reply);
    if (this.disposed) {
      reply.error('FILE_SERVICES_CLOSED', 'File services have been disposed.');
      return;
    }
    switch (call.method) {
      case 'openFile':
        this.selectFiles(call, reply, true);
        break;
      case 'pickFile':
        this.selectFiles(call, reply, false);
        break;
      case 'saveFile':
        this.saveFile(call, reply);
        break;
      case 'isPickDirectorySupported':
        reply.success(false);
        break;
      case 'getDirectoryPath':
      case 'getDirectoryPaths':
        this.selectDirectory(reply, call.method === 'getDirectoryPaths');
        break;
      case 'restoreDirectories':
        this.directories.restore().then((failures: number) => reply.success(failures))
          .catch((error: BusinessError) => this.fileFailure(reply, 'DIRECTORY_RESTORE_FAILED', error));
        break;
      case 'pickDirectory':
      case 'saveFileToDirectory':
        reply.error('DIRECTORY_ACCESS_UNSUPPORTED', 'Use the directory picker path API on HarmonyOS.');
        break;
      case 'getSavePath':
        reply.error('SAVE_PATH_UNSUPPORTED', 'Use the user-authorized saveFile operation to export a file on HarmonyOS.');
        break;
      case 'canLaunch':
        this.canLaunch(call, reply);
        break;
      case 'launch':
        this.launch(call, reply);
        break;
      case 'closeWebView':
        reply.success(null);
        break;
      default:
        reply.notImplemented();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (let index = 0; index < this.channels.length; index++) this.channels[index].setMethodCallHandler(null);
    this.share.dispose();
    this.directories.dispose();
    this.pending.forEach((reply: FileReply) => reply.error('FILE_SERVICES_CLOSED', 'File services have been disposed.'));
    this.pending.clear();
  }

  private async selectDirectory(reply: FileReply, returnList: boolean): Promise<void> {
    if (this.pickerActive) {
      reply.error('PICKER_IN_PROGRESS', 'A file picker operation is already active.');
      return;
    }
    if (!this.directories.supported()) {
      reply.error('DIRECTORY_ACCESS_UNSUPPORTED', 'This device does not support persistent directory selection.');
      return;
    }
    this.pickerActive = true;
    try {
      const uris = await new picker.DocumentViewPicker(this.context).select({
        selectMode: picker.DocumentSelectMode.FOLDER, maxSelectNumber: returnList ? 32 : 1
      });
      this.checkOpen();
      if (!uris || uris.length === 0) {
        reply.success(returnList ? [] : null);
        return;
      }
      if (uris.length > (returnList ? 32 : 1)) throw new Error('The picker returned too many directories.');
      const paths: string[] = [];
      for (const uri of uris) {
        this.checkOpen();
        paths.push(await this.directories.authorize(uri));
      }
      this.checkOpen();
      reply.success(returnList ? paths : paths[0]);
    } catch (error) {
      this.fileFailure(reply, 'DIRECTORY_PICK_FAILED', error as BusinessError);
    } finally {
      this.pickerActive = false;
    }
  }

  private async selectFiles(call: MethodCall, reply: FileReply, returnList: boolean): Promise<void> {
    if (this.pickerActive) {
      reply.error('PICKER_IN_PROGRESS', 'A file picker operation is already active.');
      return;
    }
    this.pickerActive = true;
    let stage = '';
    let keepStage = false;
    try {
      if (!returnList && call.argument('localOnly') === true) {
        throw new Error('The system document picker does not expose a local-only provider restriction.');
      }
      const extensions = this.extensions(call, returnList);
      const multiple = returnList && call.argument('multiple') === true;
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: multiple ? 32 : 1, fileSuffixFilters: this.pickerFilters(extensions)
      };
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      this.checkOpen();
      if (!uris || uris.length === 0) {
        reply.success(null);
        return;
      }
      if (uris.length > (multiple ? 32 : 1)) throw new Error('The document picker returned too many files.');
      stage = await fs.mkdtemp(this.context.cacheDir + '/venera_pick_XXXXXX');
      const paths: string[] = [];
      for (let index = 0; index < uris.length; index++) {
        this.checkPickerUri(uris[index]);
        const name = sanitizeFileName(new fileUri.FileUri(uris[index]).name);
        if (extensions.length > 0 && !extensions.some((extension: string) => name.toLowerCase().endsWith('.' + extension))) {
          throw new Error('The selected file does not match the requested file extensions.');
        }
        const itemDir = stage + '/' + index;
        await fs.mkdir(itemDir);
        const target = itemDir + '/' + name;
        await this.copyFile(uris[index], target);
        paths.push(target);
      }
      this.checkOpen();
      keepStage = true;
      reply.success(returnList ? paths : paths[0]);
    } catch (error) {
      this.fileFailure(reply, 'FILE_PICK_FAILED', error as BusinessError);
    } finally {
      if (!keepStage) await this.removeStage(stage);
      this.pickerActive = false;
    }
  }

  private async saveFile(call: MethodCall, reply: FileReply): Promise<void> {
    if (this.pickerActive) {
      reply.error('PICKER_IN_PROGRESS', 'A file picker operation is already active.');
      return;
    }
    this.pickerActive = true;
    let stage = '';
    let savedUri: string | null = null;
    let failure: BusinessError | undefined;
    try {
      const source: Any = call.argument('sourceFilePath');
      const bytes: Any = call.argument('data');
      const suppliedName: Any = call.argument('fileName');
      const hasSource = source !== null && source !== undefined;
      const hasData = bytes !== null && bytes !== undefined;
      if (hasSource === hasData || (hasSource && (typeof source !== 'string' || (source as string).length === 0)) ||
        (hasData && (!(bytes instanceof Uint8Array) || typeof suppliedName !== 'string' || suppliedName.length === 0)) ||
        (suppliedName !== null && suppliedName !== undefined && typeof suppliedName !== 'string')) {
        throw new Error('saveFile requires exactly one sourceFilePath or byte data with a fileName.');
      }
      const sourcePath = hasSource ? source as string : '';
      if (hasSource) await validateSandboxFile(this.context, sourcePath, this.directories.roots);
      const name = sanitizeFileName(typeof suppliedName === 'string' && suppliedName.length > 0 ? suppliedName :
        sourcePath.substring(sourcePath.lastIndexOf('/') + 1));
      stage = await fs.mkdtemp(this.context.cacheDir + '/venera_save_XXXXXX');
      const stagedSource = stage + '/' + name;
      if (hasSource) {
        await this.copyFile(sourcePath, stagedSource);
      } else {
        await this.writeBytes(stagedSource, bytes as Uint8Array);
      }
      this.checkOpen();
      const options: picker.DocumentSaveOptions = { newFileNames: [name] };
      const uris = await new picker.DocumentViewPicker(this.context).save(options);
      this.checkOpen();
      if (uris && uris.length > 0) {
        if (uris.length !== 1) throw new Error('The document picker returned an unexpected save target count.');
        this.checkPickerUri(uris[0]);
        if (hasSource && uris[0] === fileUri.getUriFromPath(sourcePath)) throw new Error('The save target cannot replace the source file.');
        await this.copyFile(stagedSource, uris[0]);
        this.checkOpen();
        // This is a picker URI, not a Dart/FFI filesystem path.
        savedUri = uris[0];
      }
    } catch (error) {
      failure = error as BusinessError;
    } finally {
      await this.removeStage(stage);
      this.pickerActive = false;
    }
    // A reply may immediately start another save; cleanup must finish first.
    if (failure !== undefined) {
      this.fileFailure(reply, 'FILE_SAVE_FAILED', failure);
    } else {
      reply.success(savedUri);
    }
  }

  private extensions(call: MethodCall, selector: boolean): string[] {
    const extensions = new Set<string>();
    if (selector) {
      const groups: Any = call.argument('acceptedTypeGroups');
      if (groups !== null && groups !== undefined && !Array.isArray(groups)) throw new Error('File type groups must be a list.');
      const values: Map<string, Any>[] = (groups ?? []) as Map<string, Any>[];
      for (let index = 0; index < values.length; index++) {
        const group: Map<string, Any> = values[index];
        if (!(group instanceof Map)) throw new Error('File type groups must contain maps.');
        const suffixes = this.stringList(group.get('extensions'));
        const mimes = this.stringList(group.get('mimeTypes'));
        if (suffixes.length === 0 && mimes.length === 0) return [];
        this.addExtensions(extensions, suffixes);
        this.addMimeExtensions(extensions, mimes);
      }
    } else {
      this.addExtensions(extensions, this.stringList(call.argument('fileExtensionsFilter')));
      this.addMimeExtensions(extensions, this.stringList(call.argument('mimeTypesFilter')));
    }
    const result: string[] = [];
    extensions.forEach((value: string) => result.push(value));
    return result;
  }

  private stringList(value: Any): string[] {
    if (value === null || value === undefined) return [];
    if (!Array.isArray(value) || (value as string[]).some((entry: string) => typeof entry !== 'string')) {
      throw new Error('File filters must be lists of strings.');
    }
    return value as string[];
  }

  private addExtensions(target: Set<string>, extensions: string[]): void {
    for (let index = 0; index < extensions.length; index++) {
      const extension = extensions[index].replace(/^\./, '').toLowerCase();
      if (!/^[a-z0-9][a-z0-9._+-]{0,30}$/.test(extension)) throw new Error('The file extension filter is invalid.');
      target.add(extension);
    }
  }

  private addMimeExtensions(target: Set<string>, mimes: string[]): void {
    try {
      for (let index = 0; index < mimes.length; index++) {
        const utd = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mimes[index]);
        const descriptor = uniformTypeDescriptor.getTypeDescriptor(utd);
        if (!descriptor || descriptor.filenameExtensions.length === 0) {
          throw new Error('The system document picker cannot represent this MIME filter.');
        }
        this.addExtensions(target, descriptor.filenameExtensions);
      }
    } catch (error) {
      throw new Error((error as BusinessError).message);
    }
  }

  private pickerFilters(extensions: string[]): string[] | undefined {
    if (extensions.length === 0) return undefined;
    const filters: string[] = [];
    let group = '';
    for (let index = 0; index < extensions.length; index++) {
      const suffix = '.' + extensions[index];
      if (group.length + suffix.length + 1 > 95) {
        filters.push(group);
        group = '';
      }
      group += (group.length === 0 ? '' : ',') + suffix;
    }
    if (group.length > 0) filters.push(group);
    return filters;
  }

  private async copyFile(source: string, target: string): Promise<void> {
    let input: fs.File | undefined;
    let output: fs.File | undefined;
    try {
      this.checkOpen();
      input = await fs.open(source, fs.OpenMode.READ_ONLY);
      if (!(await fs.stat(input.fd)).isFile()) throw new Error('The selected source must be a regular file.');
      this.checkOpen();
      output = await fs.open(target, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const buffer = new ArrayBuffer(COPY_BUFFER_SIZE);
      while (true) {
        this.checkOpen();
        const length = await fs.read(input.fd, buffer);
        if (length === 0) break;
        if (length < 0 || length > buffer.byteLength) throw new Error('The system returned an invalid file read size.');
        await this.writeAll(output.fd, buffer, length);
      }
      await fs.fsync(output.fd);
    } catch (error) {
      throw new Error((error as BusinessError).message);
    } finally {
      await this.closeFile(output);
      await this.closeFile(input);
    }
  }

  private async writeBytes(path: string, bytes: Uint8Array): Promise<void> {
    let output: fs.File | undefined;
    try {
      this.checkOpen();
      output = await fs.open(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      for (let offset = 0; offset < bytes.byteLength; offset += COPY_BUFFER_SIZE) {
        this.checkOpen();
        const end = Math.min(offset + COPY_BUFFER_SIZE, bytes.byteLength);
        const chunk = bytes.buffer.slice(bytes.byteOffset + offset, bytes.byteOffset + end);
        await this.writeAll(output.fd, chunk, chunk.byteLength);
      }
      await fs.fsync(output.fd);
    } catch (error) {
      throw new Error((error as BusinessError).message);
    } finally {
      await this.closeFile(output);
    }
  }

  private async writeAll(fd: number, buffer: ArrayBuffer, length: number): Promise<void> {
    try {
      let written = 0;
      while (written < length) {
        this.checkOpen();
        const chunk = written === 0 && length === buffer.byteLength ? buffer : buffer.slice(written, length);
        const count = await fs.write(fd, chunk);
        if (count <= 0 || count > length - written) throw new Error('The system returned an invalid file write size.');
        written += count;
      }
    } catch (error) {
      throw new Error((error as BusinessError).message);
    }
  }

  private async closeFile(file?: fs.File): Promise<void> {
    if (file === undefined) return;
    try {
      await fs.close(file);
    } catch (_) {
      console.warn('Venera: closing a document file descriptor failed.');
    }
  }

  private async removeStage(stage: string): Promise<void> {
    if (stage.length === 0 || !stage.startsWith(this.context.cacheDir + '/venera_')) return;
    try {
      await fs.rmdir(stage);
    } catch (_) {
      console.warn('Venera: cleaning this document operation cache failed.');
    }
  }

  private checkOpen(): void {
    if (this.disposed) throw new Error('File services have been disposed.');
  }

  private checkPickerUri(uri: string): void {
    if (typeof uri !== 'string' || !uri.startsWith('file://') || uri.includes('\u0000')) {
      throw new Error('The system document picker returned an unsupported URI.');
    }
  }

  private fileFailure(reply: FileReply, code: string, error: BusinessError): void {
    reply.error(code, error.message, error.code ?? null);
  }

  private canLaunch(call: MethodCall, reply: FileReply): void {
    try {
      const link = webUrl(call.argument('url'));
      reply.success(link === undefined ? false : bundleManager.canOpenLink(link));
    } catch (_) {
      reply.success(false);
    }
  }

  private async launch(call: MethodCall, reply: FileReply): Promise<void> {
    try {
      const link = webUrl(call.argument('url'));
      if (link === undefined) {
        reply.success(false);
        return;
      }
      const headers: Any = call.argument('headers');
      if (headers !== null && headers !== undefined && !(headers instanceof Map)) {
        reply.error('INVALID_ARGUMENT', 'URL headers must be a map.');
        return;
      }
      if (headers instanceof Map && headers.size > 0) {
        reply.error('CUSTOM_HEADERS_UNSUPPORTED', 'The system browser cannot accept custom WebView request headers.');
        return;
      }
      // url_launcher permits falling back from an unsupported in-app mode.
      await this.context.openLink(link, { appLinkingOnly: call.argument('universalLinksOnly') === true });
      reply.success(true);
    } catch (_) {
      reply.success(false);
    }
  }
}
