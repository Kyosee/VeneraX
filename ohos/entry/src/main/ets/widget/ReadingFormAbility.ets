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
    try { store.register(id, typeof size === 'number' ? size : 2, kind); } catch (_) {}
    const binding = store.binding(id);
    this.initialImages.get(id)?.close();
    this.initialImages.set(id, binding);
    // Keep descriptors alive until the framework has consumed the return data.
    return binding.data;
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
