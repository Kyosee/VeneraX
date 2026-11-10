import { fileIo as fs } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { ReadingWidgetData, parseReadingWidgetData } from './ReadingWidgetData';

interface WidgetPrivacySettings {
  authorizationRequired: boolean;
}

interface WidgetAppdata {
  settings: WidgetPrivacySettings;
}

class ReadingForm {
  id: string;
  dimension: number;
  constructor(id: string, dimension: number) {
    this.id = id;
    this.dimension = dimension;
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

  save(json: string): void {
    this.write('reading_widget.json', JSON.stringify(parseReadingWidgetData(json)));
  }

  private forms(): ReadingForm[] {
    try {
      const forms = JSON.parse(fs.readTextSync(`${this.filesDir}/reading_widget_forms.json`)) as ReadingForm[];
      if (!Array.isArray(forms)) return [];
      return forms.filter((form: ReadingForm) => typeof form.id === 'string' && /^-?\d+$/.test(form.id));
    } catch (_) { return []; }
  }

  hasWidgets(): boolean { return this.forms().length > 0; }

  register(id: string, dimension: number): void {
    if (!/^-?\d+$/.test(id)) return;
    const forms = this.forms().filter((form: ReadingForm) => form.id !== id);
    forms.push(new ReadingForm(id, dimension));
    this.write('reading_widget_forms.json', JSON.stringify(forms));
  }

  remove(id: string): void {
    this.write('reading_widget_forms.json', JSON.stringify(this.forms().filter((form: ReadingForm) => form.id !== id)));
  }

  private contentAllowed(): boolean {
    try {
      const appdata = JSON.parse(fs.readTextSync(`${this.filesDir}/appdata.json`)) as WidgetAppdata;
      return appdata.settings.authorizationRequired === false;
    } catch (_) { return false; }
  }

  binding(id: string): ReadingWidgetBinding {
    let snapshot = new ReadingWidgetData();
    try {
      // Settings may persist before Dart clears the last public snapshot.
      if (this.contentAllowed()) {
        snapshot = parseReadingWidgetData(fs.readTextSync(`${this.filesDir}/reading_widget.json`));
      }
    } catch (_) {}
    snapshot.dimension = this.forms().find((form: ReadingForm) => form.id === id)?.dimension ?? 2;
    snapshot.items = snapshot.items.slice(0, snapshot.dimension === 4 ? 4 : 2);
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
    if (binding.hasContent && !this.contentAllowed()) await this.update(id);
  }

  async updateAll(): Promise<void> {
    for (const form of this.forms()) {
      try { await this.update(form.id); } catch (_) {
        // One removed or temporarily unavailable form must not block others.
      }
    }
  }
}
