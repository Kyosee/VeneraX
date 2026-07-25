part of 'settings_page.dart';

/// Management page for offline translation model files: download (with
/// progress and mirror fallback), delete, and choice of download endpoint.
class TranslationModelsPage extends StatefulWidget {
  const TranslationModelsPage({super.key});

  @override
  State<TranslationModelsPage> createState() => _TranslationModelsPageState();
}

class _TranslationModelsPageState extends State<TranslationModelsPage> {
  @override
  void initState() {
    TranslationModelStore.instance.addListener(_update);
    super.initState();
  }

  @override
  void dispose() {
    TranslationModelStore.instance.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  static String _componentName(String id) {
    return switch (id) {
      'text_detector' => "Text detector".tl,
      'ocr_ja' => "Japanese OCR (manga)".tl,
      'ocr_zh' => "Chinese / Latin OCR".tl,
      'ocr_en' => "English OCR".tl,
      'ocr_ko' => "Korean OCR".tl,
      _ => id,
    };
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1 << 30) {
      return "${(bytes / (1 << 30)).toStringAsFixed(2)} GB";
    }
    if (bytes >= 1 << 20) {
      return "${(bytes / (1 << 20)).toStringAsFixed(1)} MB";
    }
    return "${(bytes / (1 << 10)).toStringAsFixed(0)} KB";
  }

  @override
  Widget build(BuildContext context) {
    var requiredIds = TranslationModels.requiredFor(
      appdata.settings['imageTranslationSource'] as String? ?? 'auto',
    ).map((c) => c.id).toSet();
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Translation models".tl)),
          SelectSetting(
            title: "Model download source".tl,
            settingKey: "imageTranslationHfEndpoint",
            optionTranslation: const {
              'https://huggingface.co': "HuggingFace",
              'https://hf-mirror.com': "hf-mirror.com",
            },
          ).toSliver(),
          ListTile(
            title: Text("Storage used by models".tl),
            subtitle: Text(
              _formatSize(TranslationModelStore.instance.installedSizeBytes),
            ),
          ).toSliver(),
          _buildSectionHeader(context, "Text detection".tl).toSliver(),
          for (var component in TranslationModels.all)
            if (component.id == 'text_detector')
              _buildComponent(context, component, requiredIds).toSliver(),
          _buildSectionHeader(context, "Text recognition".tl).toSliver(),
          for (var component in TranslationModels.all)
            if (component.id != 'text_detector')
              _buildComponent(context, component, requiredIds).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: context.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildComponent(
    BuildContext context,
    ModelComponent component,
    Set<String> requiredIds,
  ) {
    var store = TranslationModelStore.instance;
    var state = store.stateOf(component);
    var installed = component.isInstalled;
    Widget trailing;
    if (state.downloading) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              value: state.progress <= 0 ? null : state.progress,
            ),
          ),
          const SizedBox(width: 8),
          Text("${(state.progress * 100).toStringAsFixed(0)}%"),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => store.cancelDownload(component),
          ),
        ],
      );
    } else if (installed) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: context.colorScheme.primary),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              showConfirmDialog(
                context: App.rootContext,
                title: "Delete".tl,
                content: "Delete the downloaded model files?".tl,
                btnColor: context.colorScheme.error,
                onConfirm: () {
                  store.delete(component);
                },
              );
            },
          ),
        ],
      );
    } else {
      trailing = Button.filled(
        onPressed: () => store.download(component),
        child: Text("Download".tl),
      ).fixHeight(32);
    }
    String subtitle = _formatSize(component.approxSizeBytes);
    if (requiredIds.contains(component.id) && !installed) {
      subtitle += " · ${"Required by current settings".tl}";
    }
    if (state.error != null) {
      subtitle += "\n${"Download failed".tl}: ${state.error}";
    }
    return ListTile(
      title: Text(_componentName(component.id)),
      subtitle: Text(subtitle),
      isThreeLine: state.error != null,
      trailing: trailing,
    );
  }
}
