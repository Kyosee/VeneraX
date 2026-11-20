import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { ReadingWidgetBinding, ReadingWidgetStore } from './ReadingWidgetStore';

export default class ReadingFormAbility extends FormExtensionAbility {
  private initialImages: Map<string, ReadingWidgetBinding> = new Map();

  onAddForm(want: Want): formBindingData.FormBindingData {
    const store = new ReadingWidgetStore(this.context.filesDir);
    const id = `${want.parameters?.[formInfo.FormParam.IDENTITY_KEY] ?? ''}`;
    const size = want.parameters?.[formInfo.FormParam.DIMENSION_KEY];
    const name = want.parameters?.[formInfo.FormParam.NAME_KEY];
    const kind = typeof name === 'string' ? name.replace(/^reading_/, '') : 'history';
    // Some runtimes pass the location but omit its FormParam constant.
    const locationKey = formInfo.FormParam.FORM_LOCATION_KEY ?? 'ohos.extra.param.key.form_location';
    const location = want.parameters?.[locationKey];
    const preview = this.isPreviewLocation(location) || want.parameters?.[formInfo.FormParam.TEMPORARY_KEY] === true;
    try { store.register(id, typeof size === 'number' ? size : 2, kind, preview); } catch (_) {}
    const binding = store.binding(id, preview);
    this.initialImages.get(id)?.close();
    this.initialImages.set(id, binding);
    // Keep descriptors alive until the framework has consumed the return data.
    return binding.data;
  }

  private isPreviewLocation(location: Object | undefined): boolean {
    // API 12 location values include the home and minus-one screen galleries.
    return location === 1 || location === 2 || location === 4 || location === 5;
  }

  onFormLocationChanged(id: string, location: formInfo.FormLocation): void {
    new ReadingWidgetStore(this.context.filesDir).setPreview(id, this.isPreviewLocation(location));
    this.onUpdateForm(id);
  }

  onCastToNormalForm(id: string): void {
    new ReadingWidgetStore(this.context.filesDir).setPreview(id, false);
    this.onUpdateForm(id);
  }

  onUpdateForm(id: string): void {
    new ReadingWidgetStore(this.context.filesDir).update(id).then(() => {
      this.initialImages.get(id)?.close();
      this.initialImages.delete(id);
    }).catch(() => {});
  }

  onRemoveForm(id: string): void {
    this.initialImages.get(id)?.close();
    this.initialImages.delete(id);
    try { new ReadingWidgetStore(this.context.filesDir).remove(id); } catch (_) {}
  }

  onSizeChanged(id: string, dimension: formInfo.FormDimension, _rect: formInfo.Rect): void {
    try { new ReadingWidgetStore(this.context.filesDir).register(id, dimension); } catch (_) {}
    this.onUpdateForm(id);
  }

  onStop(): void {
    this.initialImages.forEach((binding: ReadingWidgetBinding) => binding.close());
    this.initialImages.clear();
  }
}
