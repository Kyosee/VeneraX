part of 'settings_page.dart';

typedef _ModelChoice = ({
  String id,
  String title,
  VoidCallback? select,
  bool installed,
  Widget Function({Widget? selector}) build,
});

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
  static const _catalogPadding = EdgeInsets.symmetric(horizontal: 16);

  bool? _library;
  String _category = 'Text detection';
  String? _expandedId;
  late Map<String, int> _diskSizes;
  late int _diskRevision;

  @override
  void initState() {
    _refreshDiskSizes();
    TranslationModelStore.instance.addListener(_update);
    super.initState();
  }

  @override
  void dispose() {
    TranslationModelStore.instance.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (_diskRevision != TranslationModelStore.instance.diskRevision) {
      _refreshDiskSizes();
    }
    if (mounted) setState(() {});
  }

  void _refreshDiskSizes() {
    final store = TranslationModelStore.instance;
    _diskRevision = store.diskRevision;
    _diskSizes = store.localModelSizes;
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1000000000) {
      return "${(bytes / 1000000000).toStringAsFixed(2)} GB";
    }
    if (bytes >= 1000000) {
      return "${(bytes / 1000000).toStringAsFixed(1)} MB";
    }
    return bytes < 1000
        ? "$bytes B"
        : "${(bytes / 1000).toStringAsFixed(0)} KB";
  }

  void _confirmDownload(
    String title,
    ModelComponent component,
    Future<void> Function() verify,
  ) {
    final size = component.approxSizeBytes;
    var content = size > 0
        ? "Download @size?".tlParams({'size': _formatSize(size)})
        : "The host did not report the size. Download anyway?".tl;
    if (size > 100 << 20) {
      content +=
          "\n\n${"Large models load slower and use more memory; on phones they may be slow or run out of memory.".tl}";
    }
    showConfirmDialog(
      context: context,
      title: title,
      content: content,
      confirmText: "Download".tl,
      onConfirm: () =>
          TranslationModelStore.instance.download(component, verify: verify),
    );
  }

  void _downloadRecognizer(String name, RecognitionModel model) {
    final component = model.component;
    _confirmDownload(
      name,
      component,
      () => checkRecognitionModel(
        component.filePath('rec.onnx'),
        component.filePath('dict.txt'),
        model.inputHeight,
      ),
    );
  }

  Future<void> _editSource({
    CustomSourceLanguage? language,
    RecognitionModel? preset,
  }) async {
    final saved = await showDialog<CustomSourceLanguage>(
      context: context,
      builder: (_) =>
          _SourceLanguageEditor(existing: language, initialModel: preset),
    );
    if (saved == null || !mounted) return;
    _update();
    if (!saved.component.isInstalled) _downloadRecognizer(saved.name, saved);
  }

  void _removeLanguage(CustomSourceLanguage language, bool shared) {
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content:
          (shared
                  ? "Remove @name? Other languages keep using the shared model."
                  : "Remove @name and its downloaded model? Pages already translated from it are kept.")
              .tlParams({'name': language.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        TranslationSources.remove(language.code);
        _update();
      },
    );
  }

  Future<void> _addDetector() async {
    final model = await showDialog<CustomDetectorModel>(
      context: context,
      builder: (_) => const _DetectorEditor(),
    );
    if (model == null || !mounted) return;
    TranslationSources.setDetector(model, select: false);
    _update();
    if (!model.component.isInstalled) _downloadDetector(model);
  }

  void _downloadDetector(CustomDetectorModel model) {
    final component = model.component;
    _confirmDownload(
      "Text detection".tl,
      component,
      () => checkDetectionModel(component.filePath('det.onnx')),
    );
  }

  String _fileName(String url) {
    final uri = Uri.parse(url);
    return uri.pathSegments.where((segment) => segment.isNotEmpty).lastOrNull ??
        uri.host;
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.sourceLang ?? TranslationConfig.global.sourceLang;
    final requiredIds = TranslationModels.requiredFor(
      language,
    ).map((c) => c.id).toSet();
    final autoIds = language == 'auto'
        ? TranslationModels.automaticRecognizerIds
        : const <String>{};
    final selectedDetector = TranslationSources.detector;
    final activeDetector = TranslationModels.activeDetector.id;
    final groups = <String, List<CustomSourceLanguage>>{};
    for (final source in TranslationSources.custom) {
      (groups[source.engine] ??= []).add(source);
    }

    final detectors = [
      _detectorRow('PP-OCRv5 mobile', null, selectedDetector, activeDetector),
      for (final entry in TranslationSources.detectorPresets.entries)
        _detectorRow(entry.key, entry.value, selectedDetector, activeDetector),
      for (final model in TranslationSources.savedDetectors.values)
        _detectorRow(
          _fileName(model.url),
          model,
          selectedDetector,
          activeDetector,
          custom: true,
        ),
    ];
    final recognizers = [
      for (final component in TranslationModels.recognizers)
        _recognizerRow(component, requiredIds, autoIds),
      for (final preset in TranslationSources.recognitionPresets.entries)
        _languageRow(
          preset.key.tl,
          preset.value,
          groups.remove(preset.value.engine) ?? [],
          requiredIds,
          preset: true,
        ),
      for (final sources in groups.values)
        _languageRow(
          sources.map((language) => language.name).join(' / '),
          sources.first,
          sources,
          requiredIds,
        ),
    ];
    final enhancements = [
      for (final component in TranslationModels.enhancements)
        _component(
          component,
          title: component.displayName,
          status:
              component.isInstalled &&
                  TranslationConfig.bubbleEnhancementEnabled
              ? "Enabled".tl
              : null,
          details: [_buildEnhancementDetails(context, component)],
        ),
    ];
    final catalog = {
      'Text detection': detectors,
      'Text recognition': recognizers,
      'Optional enhancements': enhancements,
    };
    final installed = {
      for (final entry in catalog.entries)
        entry.key: entry.value.where((model) => model.installed).toList(),
    };
    final listed = {
      for (final choices in catalog.values)
        for (final choice in choices) choice.id: choice,
    };
    final unfinished = [
      for (final entry in _diskSizes.entries)
        if (listed[entry.key] case final model?)
          if (!model.installed &&
              !TranslationModelStore.instance.isDownloading(model.id))
            _localFiles(
              model.id,
              entry.value,
              title: model.title,
              incomplete: true,
            ),
    ];
    final archived =
        _diskSizes.entries
            .where((entry) => !listed.containsKey(entry.key))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final empty =
        archived.isEmpty &&
        unfinished.isEmpty &&
        installed.values.every((models) => models.isEmpty);
    final library = _library ??= empty;
    final colors = context.colorScheme;
    final endpoint = TranslationModelStore.hfEndpoint;
    final downloadSources = {
      'https://huggingface.co': 'Hugging Face',
      'https://hf-mirror.com': 'hf-mirror.com',
    };
    downloadSources.putIfAbsent(endpoint, () => endpoint);
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text("Model management".tl),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.add),
                tooltip: "Add".tl,
                onSelected: (value) {
                  if (value == 'source') {
                    _editSource();
                  } else {
                    _addDetector();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'source',
                    child: Text("Add source language".tl),
                  ),
                  PopupMenuItem(
                    value: 'detector',
                    child: Text("Add custom detector".tl),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: "Model sources and licenses".tl,
                onPressed: () => GuidePage.openDocument(
                  context,
                  assetPath: App.locale.languageCode == 'zh'
                      ? 'doc/model-notices.zh.md'
                      : 'doc/model-notices.en.md',
                  title: "Model sources and licenses".tl,
                ),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            sliver: SliverList.list(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: false,
                            label: Text("My models".tl),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text("Model library".tl),
                          ),
                        ],
                        selected: {library},
                        onSelectionChanged: (values) => setState(() {
                          _library = values.first;
                          _expandedId = null;
                        }),
                      ),
                      Text(
                        "@size on device".tlParams({
                          'size': _formatSize(
                            _diskSizes.values.fold<int>(
                              0,
                              (sum, size) => sum + size,
                            ),
                          ),
                        }),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (library) ...[
                  _SettingsGroup(
                    children: [
                      Padding(
                        padding: _catalogPadding,
                        child: DropdownButtonFormField<String>(
                          initialValue: endpoint,
                          decoration: InputDecoration(
                            labelText: "Hugging Face download source".tl,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                            filled: false,
                            border: InputBorder.none,
                          ),
                          icon: const SizedBox(
                            width: kMinInteractiveDimension,
                            child: Center(child: Icon(Icons.arrow_drop_down)),
                          ),
                          isExpanded: true,
                          items: [
                            for (final source in downloadSources.entries)
                              DropdownMenuItem(
                                value: source.key,
                                child: Text(
                                  source.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (url) {
                            if (url == null) return;
                            appdata.settings['imageTranslationHfEndpoint'] =
                                url;
                            appdata.saveData();
                          },
                        ),
                      ),
                      DefaultTabController(
                        initialIndex: catalog.keys.toList().indexOf(_category),
                        length: catalog.length,
                        child: TabBar(
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          tabs: [
                            for (final category in catalog.keys)
                              Tab(text: category.tl),
                          ],
                          onTap: (index) =>
                              _openLibrary(catalog.keys.elementAt(index)),
                        ),
                      ),
                      for (final model in catalog[_category]!) model.build(),
                    ],
                  ),
                ] else if (empty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Column(
                        children: [
                          Text("No models downloaded".tl),
                          TextButton(
                            onPressed: () => _openLibrary('Text detection'),
                            child: Text("Browse model library".tl),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  _detectorPicker(installed['Text detection']!, activeDetector),
                  _SettingsGroup(
                    title: 'Text recognition',
                    children: [
                      for (final model in installed['Text recognition']!)
                        model.build(),
                      if (installed['Text recognition']!.isEmpty)
                        _browseLink('Text recognition'),
                    ],
                  ),
                  if (installed['Optional enhancements']!.isNotEmpty)
                    _SettingsGroup(
                      title: 'Optional enhancements',
                      children: [
                        for (final model in installed['Optional enhancements']!)
                          model.build(),
                      ],
                    ),
                  if (archived.isNotEmpty)
                    _SettingsGroup(
                      title: 'Older model files',
                      children: [
                        for (final entry in archived)
                          _localFiles(entry.key, entry.value),
                      ],
                    ),
                  if (unfinished.isNotEmpty)
                    _SettingsGroup(
                      title: 'Incomplete model download',
                      children: unfinished,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openLibrary(String category) {
    setState(() {
      _category = category;
      _library = true;
      _expandedId = null;
    });
  }

  Widget _localFiles(
    String id,
    int bytes, {
    String? title,
    bool incomplete = false,
  }) {
    final component = ModelComponent(
      id: id,
      files: const [],
      approxSizeBytes: bytes,
    );
    title ??= switch (id) {
      'translator' => 'M2M100-418M',
      'inpaint' => 'LaMa',
      'text_detector' => 'PP-OCRv4 mobile · ${"Text detection".tl}',
      'ocr_zh' => 'PP-OCRv4 mobile · ${"Chinese / Latin OCR".tl}',
      'comic_text_detector' => TranslationModels.legacyTextStrokes.displayName,
      _ => id,
    };
    return _component(
      component,
      title: title,
      description: incomplete
          ? null
          : "Kept from an earlier download. You can remove these files to free up space."
                .tl,
      details: [
        if (id == TranslationModels.legacyTextStrokes.id)
          _buildEnhancementDetails(
            context,
            TranslationModels.legacyTextStrokes,
          ),
      ],
    ).build();
  }

  Widget _browseLink(String category) => ListTile(
    title: Text("Browse model library".tl),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _openLibrary(category),
  );

  Widget _detectorPicker(List<_ModelChoice> installed, String activeId) {
    if (installed.isEmpty) {
      return _SettingsGroup(
        title: 'Text detection',
        children: [_browseLink('Text detection')],
      );
    }
    final active = installed.where((item) => item.id == activeId).firstOrNull;
    final selector = DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('active-detector'),
        value: active?.id,
        hint: Text("Choose a detector".tl),
        isExpanded: true,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final item in installed)
            DropdownMenuItem(
              value: item.id,
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) {
          if (id != null && id != activeId) {
            installed.firstWhere((item) => item.id == id).select?.call();
          }
        },
      ),
    );
    return _SettingsGroup(
      title: 'Text detection',
      children: [
        if (active != null)
          active.build(selector: selector)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: selector,
          ),
      ],
    );
  }

  _ModelChoice _detectorRow(
    String name,
    CustomDetectorModel? model,
    CustomDetectorModel? selected,
    String activeId, {
    bool custom = false,
  }) {
    final component = model?.component ?? TranslationModels.detector;
    final selectedHere = model?.url == selected?.url;
    final status = activeId == component.id
        ? (component.isInstalled
              ? "In use".tl
              : "Required by current settings".tl)
        : selectedHere
        ? "Selected, awaiting download".tl
        : null;
    final source = model == null
        ? 'PaddlePaddle · Apache-2.0'
        : custom
        ? Uri.parse(model.url).host
        : 'RapidAI/RapidOCR · Apache-2.0';
    return _component(
      component,
      title: name,
      detail: model == null ? "Default detector".tl : null,
      source: source,
      status: status,
      onDownload: model == null ? null : () => _downloadDetector(model),
      onSelect: component.isInstalled
          ? () {
              TranslationSources.setDetector(model);
              _update();
            }
          : null,
      description:
          "One detector finds text regions for all source languages.".tl,
      details: [
        if (custom && !component.isInstalled)
          TextButton(
            onPressed: () => showConfirmDialog(
              context: context,
              title: "Remove custom detector".tl,
              content:
                  "Remove the custom detection model and its downloaded file?"
                      .tl,
              btnColor: context.colorScheme.error,
              onConfirm: () {
                TranslationSources.removeDetector(model!);
                _update();
              },
            ),
            child: Text("Remove custom detector".tl),
          ),
      ],
    );
  }

  _ModelChoice _recognizerRow(
    ModelComponent component,
    Set<String> required,
    Set<String> auto,
  ) {
    final (version, files) = switch (component) {
      TranslationModels.ocrJa => (
        'Manga OCR · manga-ocr-base',
        'kha-white / mayocream · Apache-2.0',
      ),
      TranslationModels.ocrZhV5 => (
        'PP-OCRv5 mobile',
        'RapidAI / webnn / PaddlePaddle · Apache-2.0',
      ),
      TranslationModels.ocrEn => ('PP-OCRv3', 'SWHL/RapidOCR · Apache-2.0'),
      _ => ('PP-OCR mobile v2.0', 'SWHL/RapidOCR · Apache-2.0'),
    };
    return _component(
      component,
      title: component.displayName,
      detail: version,
      source: files,
      status: auto.contains(component.id)
          ? "Used for automatic recognition".tl
          : _languageStatus(component, required),
    );
  }

  String? _languageStatus(ModelComponent component, Set<String> required) {
    if (!required.contains(component.id)) return null;
    return component.isInstalled
        ? "In use".tl
        : "Required by current settings".tl;
  }

  _ModelChoice _languageRow(
    String title,
    RecognitionModel model,
    List<CustomSourceLanguage> languages,
    Set<String> required, {
    bool preset = false,
  }) {
    final component = model.component;
    String fileSource(String url) {
      final uri = Uri.parse(url);
      return '${uri.host}${uri.path}';
    }

    final shared = languages.length > 1;
    return _component(
      component,
      title: title,
      detail: preset ? 'PP-OCRv5 mobile' : "Custom recognition model".tl,
      source: preset
          ? 'RapidAI/RapidOCR · Apache-2.0'
          : '${fileSource(model.modelUrl)}\n${fileSource(model.dictUrl)}',
      status: _languageStatus(component, required),
      onDownload: () => _downloadRecognizer(title, model),
      allowDelete: !shared,
      description:
          "Recognizers read the text in each region. Each language uses its own model and dictionary, or shares a pair with related languages."
              .tl,
      details: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final language in languages)
              InputChip(
                label: Text(
                  '${language.name} (${language.code})',
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => _editSource(language: language),
                deleteButtonTooltipMessage: "Remove @name".tlParams({
                  'name': language.name,
                }),
                onDeleted: () => _removeLanguage(language, shared),
              ),
            TextButton(
              onPressed: () => _editSource(preset: model),
              child: Text("Add source language".tl),
            ),
          ],
        ),
      ],
    );
  }

  _ModelChoice _component(
    ModelComponent component, {
    required String title,
    String? detail,
    String? source,
    String? status,
    String? description,
    VoidCallback? onDownload,
    VoidCallback? onSelect,
    bool allowDelete = true,
    List<Widget> details = const [],
  }) {
    final store = TranslationModelStore.instance;
    final installed = component.isInstalled;
    final state = store.stateOf(component);
    final expanded = _expandedId == component.id;
    final legacy = component.files.isEmpty;
    final size = installed && _library != true
        ? _diskSizes[component.id] ?? 0
        : component.approxSizeBytes;
    final summary = [
      ?detail,
      if (!legacy || size > 0) size > 0 ? _formatSize(size) : "Size unknown".tl,
      if (state.downloading)
        '${(state.progress * 100).round()}%'
      else if (status != null)
        status
      else if (installed && !legacy)
        "Downloaded".tl,
    ].join(' · ');
    Widget trailing;
    if (state.downloading) {
      trailing = IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Cancel".tl,
        onPressed: () => store.cancelDownload(component),
      );
    } else if (!installed) {
      trailing = IconButton(
        icon: const Icon(Icons.download_outlined),
        tooltip: "Download".tl,
        onPressed: onDownload ?? () => store.download(component),
      );
    } else if (component == TranslationModels.rtDetr && _library != true) {
      trailing = Tooltip(
        message: "Use dialogue detection enhancement".tl,
        child: Switch(
          value: TranslationConfig.bubbleEnhancementEnabled,
          onChanged: (enabled) {
            appdata.settings[TranslationConfig.bubbleEnhancementKey] = enabled;
            appdata.saveData();
            _update();
          },
        ),
      );
    } else {
      trailing = _library == true
          ? Icon(Icons.download_done, color: context.colorScheme.primary)
          : const SizedBox.shrink();
    }
    return (
      id: component.id,
      title: title,
      select: onSelect,
      installed: installed,
      build: ({selector}) => Column(
        key: ValueKey(component.id),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: expanded,
            child: ListTile(
              contentPadding: _library == true ? _catalogPadding : null,
              title:
                  selector ??
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Tooltip(
                message: "Model details".tl,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (summary.isNotEmpty)
                      Flexible(
                        child: Text(
                          summary,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(width: 6),
                    Icon(
                      expanded ? Icons.expand_less : Icons.info_outline,
                      size: 15,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
              trailing: _library == true
                  ? SizedBox(
                      width: kMinInteractiveDimension,
                      child: Center(child: trailing),
                    )
                  : trailing,
              onTap: () =>
                  setState(() => _expandedId = expanded ? null : component.id),
            ),
          ),
          if (state.downloading)
            LinearProgressIndicator(
              value: state.progress > 0 ? state.progress : null,
            ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                "${"Download failed".tl}: ${state.error}",
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (description != null)
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (source != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        "Model files: @source".tlParams({'source': source}),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ...details,
                  if (installed && allowDelete)
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: Text("Delete downloaded files".tl),
                      onPressed: () => showConfirmDialog(
                        context: context,
                        title: title,
                        content: "Delete the downloaded model files?".tl,
                        btnColor: context.colorScheme.error,
                        onConfirm: () => store.delete(component),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
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
      padding: const EdgeInsets.only(bottom: 4),
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
