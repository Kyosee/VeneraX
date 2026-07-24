part of 'settings_page.dart';

/// Management page for on-device translation LLMs: pick the active model,
/// download / delete GGUF files (with progress and mirror fallback), and see
/// a per-device performance fit badge so the user knows what their hardware
/// can run before paying a large download. The badge rates ONLY whether the
/// device can run the model — never what it translates.
class LocalLlmModelsPage extends StatefulWidget {
  const LocalLlmModelsPage({super.key});

  @override
  State<LocalLlmModelsPage> createState() => _LocalLlmModelsPageState();
}

class _LocalLlmModelsPageState extends State<LocalLlmModelsPage> {
  int? _totalRam;

  @override
  void initState() {
    super.initState();
    TranslationModelStore.instance.addListener(_update);
    MemoryInfo.getTotalPhysicalMemorySize().then((v) {
      if (mounted) setState(() => _totalRam = v);
    });
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
    if (bytes >= 1 << 30) {
      return "${(bytes / (1 << 30)).toStringAsFixed(2)} GB";
    }
    if (bytes >= 1 << 20) {
      return "${(bytes / (1 << 20)).toStringAsFixed(0)} MB";
    }
    return "${(bytes / (1 << 10)).toStringAsFixed(0)} KB";
  }

  @override
  Widget build(BuildContext context) {
    var recommended = LocalLlmModels.recommendedFor(_totalRam);
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("On-device model".tl)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "Models run entirely on your device. Larger models translate better but need more memory; the badge shows what your device can handle."
                    .tl,
                style: ts.s14,
              ),
            ),
          ),
          for (var model in LocalLlmModels.all)
            _buildModelCard(
              context,
              model,
              isRecommended: recommended?.id == model.id,
            ).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _buildModelCard(
    BuildContext context,
    LocalLlmModel model, {
    required bool isRecommended,
  }) {
    var store = TranslationModelStore.instance;
    var component = model.asComponent;
    var state = store.stateOf(component);
    var installed = model.isInstalled;
    var selectedId =
        appdata.settings['imageTranslationLocalModel'] as String? ?? '';
    var isSelected = selectedId == model.id;
    var fit = LocalLlmModels.fitFor(model, _totalRam);

    // Fit badge: performance only.
    Color badgeColor;
    String badgeText;
    switch (fit) {
      case ModelFit.good:
        badgeColor = context.colorScheme.primary;
        badgeText = "Good fit".tl;
      case ModelFit.tight:
        badgeColor = Colors.orange;
        badgeText = "May be slow".tl;
      case ModelFit.insufficient:
        badgeColor = context.colorScheme.error;
        badgeText = "Insufficient memory".tl;
    }

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
          if (isSelected)
            Icon(Icons.check_circle, color: context.colorScheme.primary)
          else
            Button.outlined(
              onPressed: () {
                setState(() {
                  appdata.settings['imageTranslationLocalModel'] = model.id;
                });
                appdata.saveData();
              },
              child: Text("Use".tl),
            ).fixHeight(32),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              showConfirmDialog(
                context: App.rootContext,
                title: "Delete".tl,
                content: "Delete the downloaded model files?".tl,
                btnColor: context.colorScheme.error,
                onConfirm: () {
                  if (isSelected) {
                    appdata.settings['imageTranslationLocalModel'] = '';
                    appdata.saveData();
                  }
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

    var subtitle = StringBuffer(_formatSize(model.approxSizeBytes));
    subtitle.write(
      " · ${"Needs ~%s RAM".tl.replaceFirst("%s", _formatSize(model.minRecommendedRamBytes))}",
    );
    if (state.error != null) {
      subtitle.write("\n${"Download failed".tl}: ${state.error}");
    }

    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(model.displayName)),
          const SizedBox(width: 8),
          if (isRecommended)
            _pill(context, "Recommended".tl, context.colorScheme.primary),
          const SizedBox(width: 4),
          _pill(context, badgeText, badgeColor),
        ],
      ),
      subtitle: Text(subtitle.toString()),
      isThreeLine: state.error != null,
      trailing: trailing,
    );
  }

  Widget _pill(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: ts.s12.copyWith(color: color)),
    );
  }
}
