part of '../tasks_page.dart';

mixin _ModelDownloadTaskCard on _TaskCardCommon {
  TranslationModelStore get modelStore;

  /// Progress card for an ongoing translation-model download. Transient (no
  /// history entry): once finished the model simply shows as installed in the
  /// model management page.
  Widget buildModelDownloadCard(ModelComponent component) {
    var state = modelStore.stateOf(component);
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const _RotatingIcon(icon: Icons.download),
        title: Text(
          "${"Translation model".tl}: ${translationModelName(component.id)}",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "${bytesToReadableString(state.receivedBytes)} / "
              "${bytesToReadableString(state.totalBytes ?? component.approxSizeBytes)}",
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: state.progress <= 0 ? null : state.progress,
            ),
          ],
        ),
        trailing: TextButton(
          onPressed: () => modelStore.cancelDownload(component),
          child: Text("Cancel".tl),
        ),
      ),
    );
  }

  String translationModelName(String id) {
    return switch (id) {
      'text_detector' => "Text detector".tl,
      'ocr_ja' => "Japanese OCR (manga)".tl,
      'ocr_zh' => "Chinese / Latin OCR".tl,
      'ocr_en' => "English OCR".tl,
      'ocr_ko' => "Korean OCR".tl,
      _ => id,
    };
  }
}
