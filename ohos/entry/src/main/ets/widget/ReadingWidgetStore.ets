import { fileIo as fs } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { ReadingWidgetData, parseReadingWidgetData, isReadingWidgetKind } from './ReadingWidgetData';

interface WidgetPrivacySettings {
  authorizationRequired: boolean;
}

interface WidgetAppdata {
  settings: WidgetPrivacySettings;
}

class ReadingForm {
  id: string;
  dimension: number;
  kind: string;
  preview: boolean;
  constructor(id: string, dimension: number, kind: string, preview: boolean = false) {
    this.id = id;
    this.dimension = dimension;
    this.kind = kind;
    this.preview = preview;
  }
}

export class ReadingWidgetBinding {
  data: formBindingData.FormBindingData;
  hasContent: boolean;
  private files: fs.File[];

  constructor(data: ReadingWidgetData, files: fs.File[]) {
    this.files = files;
    this.hasContent = data.items.length > 0;
    this.data = formBindingData.createFormBindingData(data);
  }

  close(): void {
    this.files.forEach((file: fs.File) => {
      try { fs.closeSync(file); } catch (_) {}
    });
    this.files = [];
  }
}

export class ReadingWidgetStore {
  private filesDir: string;

  constructor(filesDir: string) { this.filesDir = filesDir; }

  private write(name: string, value: string): void {
    const target = `${this.filesDir}/${name}`;
    const file = fs.openSync(`${target}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, value); } finally { fs.closeSync(file); }
    fs.renameSync(`${target}.tmp`, target);
  }

  save(json: string): string | undefined {
    const data = parseReadingWidgetData(json);
    let wasLocked = true;
    try { wasLocked = fs.readTextSync(`${this.filesDir}/reading_widget_privacy.json`) !== 'false'; } catch (_) {}
    if (data.locked || wasLocked) {
      this.write('reading_widget_privacy.json', 'true');
      for (const kind of ['history', 'following', 'updates', 'local']) {
        const empty = new ReadingWidgetData();
        empty.kind = kind;
        this.write(`reading_widget_${kind}.json`, JSON.stringify(empty));
      }
      if (data.locked) return undefined;
    }
    this.write(`reading_widget_${data.kind}.json`, JSON.stringify(data));
    this.write('reading_widget_privacy.json', 'false');
    return wasLocked ? undefined : data.kind;
  }

  private forms(): ReadingForm[] {
    try {
      const forms = JSON.parse(fs.readTextSync(`${this.filesDir}/reading_widget_forms.json`)) as ReadingForm[];
      if (!Array.isArray(forms)) return [];
      return forms.filter((form: ReadingForm) => typeof form.id === 'string' && /^-?\d+$/.test(form.id) && isReadingWidgetKind(form.kind));
    } catch (_) { return []; }
  }

  hasWidgets(kind?: string): boolean {
    return this.forms().some((form: ReadingForm) => !form.preview && (kind === undefined || form.kind === kind));
  }

  register(id: string, dimension: number, kind?: string, preview?: boolean): void {
    if (!/^-?\d+$/.test(id)) return;
    const forms = this.forms();
    const existing = forms.find((form: ReadingForm) => form.id === id);
    const selected = kind ?? existing?.kind ?? 'history';
    if (!isReadingWidgetKind(selected)) return;
    const retained = forms.filter((form: ReadingForm) => form.id !== id);
    retained.push(new ReadingForm(id, dimension, selected, preview ?? existing?.preview ?? false));
    this.write('reading_widget_forms.json', JSON.stringify(retained));
  }

  setPreview(id: string, preview: boolean): void {
    const form = this.forms().find((item: ReadingForm) => item.id === id);
    if (form !== undefined) this.register(id, form.dimension, form.kind, preview);
  }

  remove(id: string): void {
    this.write('reading_widget_forms.json', JSON.stringify(this.forms().filter((form: ReadingForm) => form.id !== id)));
  }

  private contentAllowed(): boolean {
    try {
      const appdata = JSON.parse(fs.readTextSync(`${this.filesDir}/appdata.json`)) as WidgetAppdata;
      const privateSnapshot = fs.readTextSync(`${this.filesDir}/reading_widget_privacy.json`) !== 'false';
      return appdata.settings.authorizationRequired === false && !privateSnapshot;
    } catch (_) { return false; }
  }

  binding(id: string, preview: boolean = false): ReadingWidgetBinding {
    let snapshot = new ReadingWidgetData();
    const form = this.forms().find((item: ReadingForm) => item.id === id);
    const kind = form?.kind ?? 'history';
    if (preview || form?.preview) {
      snapshot.preview = true;
      snapshot.kind = kind;
      snapshot.dimension = form?.dimension ?? 2;
      return new ReadingWidgetBinding(snapshot, []);
    }
    if (form === undefined) return new ReadingWidgetBinding(snapshot, []);
    try {
      // Settings may persist before Dart clears the last public snapshot.
      if (this.contentAllowed()) {
        snapshot = parseReadingWidgetData(fs.readTextSync(`${this.filesDir}/reading_widget_${kind}.json`));
      }
    } catch (_) {}
    snapshot.kind = kind;
    snapshot.uri = `venerax://reading-widget/${kind}`;
    snapshot.dimension = form?.dimension ?? 2;
    snapshot.items = snapshot.items.slice(0, snapshot.dimension === 4 ? 5 : snapshot.dimension === 3 ? 3 : 1);
    const files: fs.File[] = [];
    snapshot.items.forEach((item) => {
      const prefix = `${this.filesDir}/reading_widget_covers/`;
      if (!item.coverPath.startsWith(prefix) || !/^[a-zA-Z0-9-]+\.png$/.test(item.coverPath.slice(prefix.length))) return;
      try {
        const file = fs.openSync(item.coverPath, fs.OpenMode.READ_ONLY);
        files.push(file);
        if (fs.statSync(file.fd).size > 2 * 1024 * 1024) return;
        // ArkUI refreshes a transferred image when its memory name changes.
        const key = item.coverPath.slice(prefix.length);
        snapshot.formImages[key] = file.fd;
        item.image = `memory://${key}`;
      } catch (_) {
        // Missing thumbnails use the bundled placeholder.
      }
    });
    try {
      return new ReadingWidgetBinding(snapshot, files);
    } catch (_) {
      files.forEach((file: fs.File) => { try { fs.closeSync(file); } catch (_) {} });
      throw new Error('Unable to bind reading widget images');
    }
  }

  async update(id: string): Promise<void> {
    const binding = this.binding(id);
    try {
      await formProvider.updateForm(id, binding.data);
    } finally {
      binding.close();
    }
    // The UI and extension processes may finish updates in a different order.
    if (binding.hasContent && (this.forms().find((form: ReadingForm) => form.id === id)?.preview ||
      !this.contentAllowed())) await this.update(id);
  }

  async updateAll(kind?: string): Promise<void> {
    for (const form of this.forms()) {
      if (kind !== undefined && form.kind !== kind) continue;
      try { await this.update(form.id); } catch (_) {
        // One removed or temporarily unavailable form must not block others.
      }
    }
  }
}
