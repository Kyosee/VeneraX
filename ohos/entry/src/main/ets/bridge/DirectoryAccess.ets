import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import fileShare from '@ohos.fileshare';

const DIRECTORY_MODE = fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE;

export class DirectoryAccess {
  readonly roots: string[] = [];
  private context: common.UIAbilityContext;
  private store?: preferences.Preferences;
  private uris: string[] = [];
  private restoration?: Promise<number>;
  private disposed = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  supported(): boolean {
    return canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection') &&
      canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization');
  }

  restore(): Promise<number> {
    if (this.restoration === undefined) this.restoration = this.restoreSaved();
    return this.restoration;
  }

  async authorize(uri: string): Promise<string> {
    await this.restore();
    this.checkOpen();
    if (!this.supported()) throw new Error('Persistent directory selection is unavailable on this device.');
    this.checkUri(uri);
    const policies: fileShare.PolicyInfo[] = [{ uri, operationMode: DIRECTORY_MODE }];
    const existed = (await fileShare.checkPersistentPermission(policies))[0] === true;
    this.checkOpen();
    let persisted = false;
    let saved = false;
    const previousUris = this.uris;
    try {
      await fileShare.persistPermission(policies);
      persisted = true;
      this.checkOpen();
      await fileShare.activatePermission(policies);
      this.checkOpen();
      const path = await this.directoryPath(uri);
      this.checkOpen();
      const uris = this.uris.includes(uri) ? this.uris : this.uris.concat(uri);
      await this.store!.put('uris', uris);
      saved = true;
      this.checkOpen();
      await this.store!.flush();
      this.checkOpen();
      this.uris = uris;
      if (!this.roots.includes(path)) this.roots.push(path);
      return path;
    } catch (error) {
      if (saved) {
        try {
          await this.store!.put('uris', previousUris);
          await this.store!.flush();
        } catch (_) {
          console.warn('Venera: rolling back a directory permission record failed.');
        }
      }
      if (persisted && !existed) {
        try {
          await fileShare.revokePermission(policies);
        } catch (_) {
          console.warn('Venera: revoking an incomplete directory grant failed.');
        }
      }
      throw new Error((error as Error).message);
    }
  }

  dispose(): void {
    this.disposed = true;
    this.roots.length = 0;
  }

  private async restoreSaved(): Promise<number> {
    this.checkOpen();
    this.store = await preferences.getPreferences(this.context, { name: 'venera_directory_access' });
    const uris = await this.store.get('uris', []) as string[];
    this.checkOpen();
    if (!Array.isArray(uris) || uris.some((uri: string) => typeof uri !== 'string')) {
      throw new Error('Saved directory permissions are invalid.');
    }
    this.uris = uris;
    if (!this.supported()) return uris.length;
    let failures = 0;
    for (const uri of uris) {
      this.checkOpen();
      try {
        this.checkUri(uri);
        const policies: fileShare.PolicyInfo[] = [{ uri, operationMode: DIRECTORY_MODE }];
        if ((await fileShare.checkPersistentPermission(policies))[0] !== true) {
          throw new Error('Directory permission is no longer granted.');
        }
        this.checkOpen();
        await fileShare.activatePermission(policies);
        const path = await this.directoryPath(uri);
        this.checkOpen();
        if (!this.roots.includes(path)) this.roots.push(path);
      } catch (_) {
        this.checkOpen();
        failures++;
        console.warn('Venera: a saved directory permission could not be restored.');
      }
    }
    return failures;
  }

  private async directoryPath(uri: string): Promise<string> {
    const path = new fileUri.FileUri(uri).path;
    if (!path.startsWith('/') || path === '/' || path.includes('\\') || path.includes('\u0000') ||
      path.split('/').some((part: string) => part === '.' || part === '..')) {
      throw new Error('The system returned an invalid directory path.');
    }
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('The selected directory is not accessible.');
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  private checkUri(uri: string): void {
    if (!uri.startsWith('file://') || uri.includes('\u0000')) {
      throw new Error('The picker returned an unsupported directory URI.');
    }
  }

  private checkOpen(): void {
    if (this.disposed) throw new Error('Directory services have been disposed.');
  }
}
