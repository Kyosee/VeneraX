part of 'settings_page.dart';

class _ModelNoticesTile extends StatelessWidget {
  const _ModelNoticesTile({this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final title = "Model sources and licenses".tl;
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => GuidePage.openDocument(
        context,
        assetPath: App.locale.languageCode == 'zh'
            ? 'doc/model-notices.zh.md'
            : 'doc/model-notices.en.md',
        title: title,
      ),
    );
  }
}

/// Management page for offline translation model files: download (with
/// progress and mirror fallback), delete, and choice of download endpoint.
class TranslationModelsPage extends StatefulWidget {
  const TranslationModelsPage({super.key, this.sourceLang});

  /// Source language whose OCR models are marked "required", or null to use the
  /// global setting. Passed by the reader's per-comic settings so the page marks
  /// the models that comic actually needs, not the ones the global default does.
  final String? sourceLang;

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

  static String _formatSize(int bytes) {
    if (bytes >= 1000000000) {
      return "${(bytes / 1000000000).toStringAsFixed(2)} GB";
    }
    if (bytes >= 1000000) {
      return "${(bytes / 1000000).toStringAsFixed(1)} MB";
    }
    return "${(bytes / 1000).toStringAsFixed(0)} KB";
  }

  @override
  Widget build(BuildContext context) {
    var requiredIds = TranslationModels.requiredFor(
      widget.sourceLang ?? TranslationConfig.global.sourceLang,
    ).map((c) => c.id).toSet();
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text("Translation models".tl)),
          const _ModelNoticesTile().toSliver(),
          SelectSetting(
            title: "Hugging Face download source".tl,
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
          _buildComponent(
            context,
            TranslationModels.detector,
            requiredIds,
          ).toSliver(),
          _buildSectionHeader(context, "Text recognition".tl).toSliver(),
          for (var component in TranslationModels.recognizers)
            _buildComponent(context, component, requiredIds).toSliver(),
          _buildSectionHeader(context, "Optional enhancements".tl).toSliver(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Turn off dialogue detection enhancement to use the default rules and keep the downloaded model."
                  .tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ).toSliver(),
          for (final component in TranslationModels.enhancements) ...[
            _buildComponent(context, component, requiredIds).toSliver(),
            _buildEnhancementDetails(context, component).toSliver(),
            if (component.isInstalled)
              _SwitchSetting(
                title: "Use dialogue detection enhancement".tl,
                settingKey: TranslationConfig.bubbleEnhancementKey,
                subtitle:
                    "Saved translations are kept. Retranslate a page to apply the new dialogue detection setting."
                        .tl,
              ).toSliver(),
          ],
          if (TranslationModels.legacyTextStrokes.isInstalled) ...[
            _buildComponent(
              context,
              TranslationModels.legacyTextStrokes,
              requiredIds,
            ).toSliver(),
            _buildEnhancementDetails(
              context,
              TranslationModels.legacyTextStrokes,
            ).toSliver(),
          ],
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
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: context.colorScheme.primary),
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
          if (component != TranslationModels.legacyTextStrokes)
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
    final source = switch (component) {
      TranslationModels.detector ||
      TranslationModels.ocrZh ||
      TranslationModels.ocrEn ||
      TranslationModels.ocrKo => 'PaddleOCR · SWHL/RapidOCR · Apache-2.0',
      TranslationModels.ocrZhV5 => 'PaddleOCR · RapidAI / webnn · Apache-2.0',
      TranslationModels.ocrJa => 'kha-white / mayocream · Apache-2.0',
      _ => null,
    };
    if (source != null) subtitle += "\n$source";
    if (state.error != null) {
      subtitle += "\n${"Download failed".tl}: ${state.error}";
    }
    return ListTile(
      title: Text(component.displayName),
      subtitle: component == TranslationModels.legacyTextStrokes
          ? null
          : Text(subtitle),
      isThreeLine: state.error != null || source != null,
      trailing: trailing,
    );
  }

  Widget _buildEnhancementDetails(
    BuildContext context,
    ModelComponent component,
  ) {
    const strokeSource = 'https://github.com/dmMaze/comic-text-detector';
    const strokeRevision = '440b978563c71b758e31aaa315d100faba1efa2f';
    const rtDetrSource =
        'https://huggingface.co/${TranslationModels.rtDetrRepository}';
    final (
      description,
      author,
      sourceUrl,
      license,
      licenseUrl,
    ) = switch (component) {
      TranslationModels.rtDetr => (
        "Helps Dialogue only distinguish text inside speech bubbles from captions and sound effects. Uses the Comic Translate author’s INT8 model."
            .tl,
        'ogkalu/Comic Translate',
        '$rtDetrSource/tree/${TranslationModels.rtDetrRevision}',
        'Apache-2.0',
        '$rtDetrSource/blob/${TranslationModels.rtDetrRevision}/README.md',
      ),
      _ => (
        "This older model is no longer used. You can delete its files.".tl,
        'dmMaze/CTD',
        '$strokeSource/tree/$strokeRevision',
        'GPL-3.0',
        '$strokeSource/blob/$strokeRevision/LICENSE',
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          Wrap(
            children: [
              TextButton(
                onPressed: () => launchUrlString(sourceUrl),
                child: Text(author),
              ),
              TextButton(
                onPressed: () => launchUrlString(licenseUrl),
                child: Text(license),
              ),
              if (component == TranslationModels.legacyTextStrokes)
                TextButton(
                  onPressed: () => launchUrlString(
                    'https://github.com/zyddnys/manga-image-translator/releases/tag/beta-0.3',
                  ),
                  child: Text("Model release".tl),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
