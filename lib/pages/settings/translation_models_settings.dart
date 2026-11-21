part of 'settings_page.dart';

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
              "Download either model separately. Standard text removal works without them."
                  .tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ).toSliver(),
          for (final component in TranslationModels.enhancements) ...[
            _buildComponent(context, component, requiredIds).toSliver(),
            _buildEnhancementDetails(context, component).toSliver(),
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
      title: Text(component.displayName),
      subtitle: Text(subtitle),
      isThreeLine: state.error != null,
      trailing: trailing,
    );
  }

  Widget _buildEnhancementDetails(
    BuildContext context,
    ModelComponent component,
  ) {
    final bubble = component == TranslationModels.bubblePop;
    const bubbleSource = 'https://github.com/letmutex/bubble-pop';
    const strokeSource = 'https://github.com/dmMaze/comic-text-detector';
    const strokeRevision = '440b978563c71b758e31aaa315d100faba1efa2f';
    final description = bubble
        ? "Helps Dialogue only find speech bubbles. VeneraX keeps letmutex’s original weights and adjusts the input and decoder to 576 × 768 on this device."
              .tl
        : "Locates original text strokes in both scopes during page retries and chapter pre-translation. Uses more memory. The training images and fonts belong to their respective owners."
              .tl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          Wrap(
            children: [
              TextButton(
                onPressed: () => launchUrlString(
                  bubble
                      ? '$bubbleSource/tree/${TranslationModels.bubblePopRevision}'
                      : '$strokeSource/tree/$strokeRevision',
                ),
                child: Text(bubble ? 'letmutex/BubblePop' : 'dmMaze/CTD'),
              ),
              TextButton(
                onPressed: () => launchUrlString(
                  bubble
                      ? '$bubbleSource/blob/${TranslationModels.bubblePopRevision}/LICENSE'
                      : '$strokeSource/blob/$strokeRevision/LICENSE',
                ),
                child: Text(bubble ? 'Apache-2.0' : 'GPL-3.0'),
              ),
              if (!bubble)
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
