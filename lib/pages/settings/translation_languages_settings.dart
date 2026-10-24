part of 'settings_page.dart';

/// The user's own translation languages in one place: target languages, and
/// source languages with the recognition model each one downloads, plus an
/// optional replacement text detector. Codes are fixed once added: they are
/// part of the keys translations are stored under.
class TranslationLanguagesPage extends StatefulWidget {
  const TranslationLanguagesPage({super.key});

  @override
  State<TranslationLanguagesPage> createState() =>
      _TranslationLanguagesPageState();
}

class _TranslationLanguagesPageState extends State<TranslationLanguagesPage> {
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

  void _editTarget([CustomTargetLanguage? existing]) async {
    var saved = await showDialog<bool>(
      context: App.rootContext,
      builder: (context) => _TargetLanguageEditor(existing: existing),
    );
    if (saved == true && mounted) setState(() {});
  }

  void _deleteTarget(CustomTargetLanguage language) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content:
          "Remove @name? Pages already translated into it are kept and show again if the same code is added back."
              .tlParams({'name': language.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        TranslationTargets.remove(language.code);
        if (mounted) setState(() {});
      },
    );
  }

  void _editSource([CustomSourceLanguage? existing]) async {
    var saved = await showDialog<CustomSourceLanguage>(
      context: App.rootContext,
      builder: (context) => _SourceLanguageEditor(existing: existing),
    );
    if (saved == null || !mounted) return;
    setState(() {});
    if (!saved.component.isInstalled) _confirmSource(saved);
  }

  void _deleteSource(CustomSourceLanguage language) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content:
          "Remove @name and its downloaded model? Pages already translated from it are kept."
              .tlParams({'name': language.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        TranslationSources.remove(language.code);
        if (mounted) setState(() {});
      },
    );
  }

  /// States the download size before fetching a user-supplied model, with a
  /// warning when it is large enough to matter on a phone.
  void _confirmDownload(String title, int size, VoidCallback onConfirm) {
    var content = size > 0
        ? "Download @size?".tlParams({
            'size': _TranslationModelsPageState._formatSize(size),
          })
        : "The host did not report the size. Download anyway?".tl;
    if (size > 100 << 20) {
      content +=
          "\n\n${"Large models load slower and use more memory; on phones they may be slow or run out of memory.".tl}";
    }
    showConfirmDialog(
      context: App.rootContext,
      title: title,
      content: content,
      confirmText: "Download".tl,
      onConfirm: onConfirm,
    );
  }

  void _confirmSource(CustomSourceLanguage language) => _confirmDownload(
    language.name,
    language.sizeBytes,
    () => _download(language),
  );

  void _confirmDetector(CustomDetectorModel model) => _confirmDownload(
    "Text detection model".tl,
    model.sizeBytes,
    () => _downloadDetector(model),
  );

  void _download(CustomSourceLanguage language) {
    var component = language.component;
    TranslationModelStore.instance.download(
      component,
      verify: () => checkRecognitionModel(
        component.filePath('rec.onnx'),
        component.filePath('dict.txt'),
        language.inputHeight,
      ),
    );
  }

  void _editDetector() async {
    var saved = await showDialog<CustomDetectorModel>(
      context: App.rootContext,
      builder: (context) =>
          _DetectorEditor(existing: TranslationSources.detector),
    );
    if (saved == null || !mounted) return;
    setState(() {});
    if (!saved.component.isInstalled) _confirmDetector(saved);
  }

  void _downloadDetector(CustomDetectorModel model) {
    var component = model.component;
    TranslationModelStore.instance.download(
      component,
      verify: () => checkDetectionModel(component.filePath('det.onnx')),
    );
  }

  void _resetDetector() {
    showConfirmDialog(
      context: App.rootContext,
      title: "Use built-in detector".tl,
      content: "Remove the custom detection model and its downloaded file?".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        TranslationSources.setDetector(null);
        if (mounted) setState(() {});
      },
    );
  }

  Widget _modelTrailing(ModelComponent component, VoidCallback onDownload) {
    var store = TranslationModelStore.instance;
    var state = store.stateOf(component);
    if (state.downloading) {
      return Row(
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
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: "Cancel".tl,
            onPressed: () => store.cancelDownload(component),
          ),
        ],
      );
    }
    if (component.isInstalled) {
      return Icon(Icons.check_circle, color: context.colorScheme.primary);
    }
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: "Download".tl,
      onPressed: onDownload,
    );
  }

  String _modelStatus(ModelComponent component, int sizeBytes) {
    var parts = <String>[
      if (sizeBytes > 0) _TranslationModelsPageState._formatSize(sizeBytes),
      component.isInstalled ? "Downloaded".tl : "Not downloaded".tl,
    ];
    var error = TranslationModelStore.instance.stateOf(component).error;
    var text = parts.join(' · ');
    return error == null ? text : "$text\n${"Download failed".tl}: $error";
  }

  Widget _header(
    String title,
    GuideAnchor anchor, {
    String? addTooltip,
    VoidCallback? onAdd,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: context.colorScheme.primary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: "Usage guide".tl,
            onPressed: () => GuidePage.open(context, anchor: anchor),
          ),
          if (onAdd != null)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: addTooltip,
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        text,
        style: ts.s12.copyWith(color: context.colorScheme.outline),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var targets = TranslationTargets.custom;
    var sources = TranslationSources.custom;
    final detector = TranslationSources.detector;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text("Custom languages".tl)),
          _header(
            "Target languages".tl,
            GuideAnchor.translationTarget,
            addTooltip: "Add target language".tl,
            onAdd: _editTarget,
          ).toSliver(),
          if (targets.isEmpty)
            _note(
              "No custom languages yet. Tap + to add a language that is not in the list."
                  .tl,
            ).toSliver(),
          for (var language in targets)
            ListTile(
              title: Text(language.name),
              subtitle: Text(language.code),
              onTap: () => _editTarget(language),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete".tl,
                onPressed: () => _deleteTarget(language),
              ),
            ).toSliver(),
          _header(
            "Source languages".tl,
            GuideAnchor.translationSource,
            addTooltip: "Add source language".tl,
            onAdd: _editSource,
          ).toSliver(),
          _note(
            "Built-in source languages download their recognition models under Translation models. Add a language here with a recognition model of your own."
                .tl,
          ).toSliver(),
          for (var language in sources)
            ListTile(
              title: Text(language.name),
              subtitle: Text(
                "${language.code} · ${_modelStatus(language.component, language.sizeBytes)}",
              ),
              isThreeLine:
                  TranslationModelStore.instance
                      .stateOf(language.component)
                      .error !=
                  null,
              onTap: () => _editSource(language),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _modelTrailing(
                    language.component,
                    () => _confirmSource(language),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: "Delete".tl,
                    onPressed: () => _deleteSource(language),
                  ),
                ],
              ),
            ).toSliver(),
          _header(
            "Text detection model".tl,
            GuideAnchor.translationSource,
          ).toSliver(),
          if (detector == null)
            ListTile(
              title: Text("Built-in (PP-OCRv4 mobile)".tl),
              subtitle: Text("Tap to use a detection model of your own".tl),
              onTap: _editDetector,
            ).toSliver()
          else
            ListTile(
              title: Text(detector.url, maxLines: 2),
              subtitle: Text(
                detector.component.isInstalled
                    ? _modelStatus(detector.component, detector.sizeBytes)
                    : "${_modelStatus(detector.component, detector.sizeBytes)}\n${"The built-in detector is used until this one is downloaded.".tl}",
              ),
              isThreeLine: true,
              onTap: _editDetector,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _modelTrailing(
                    detector.component,
                    () => _confirmDetector(detector),
                  ),
                  IconButton(
                    icon: const Icon(Icons.restore),
                    tooltip: "Use built-in detector".tl,
                    onPressed: _resetDetector,
                  ),
                ],
              ),
            ).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }
}

/// Add/rename dialog; saves on confirm and pops `true`. The code field is only
/// editable for a new entry.
class _TargetLanguageEditor extends StatefulWidget {
  const _TargetLanguageEditor({this.existing});

  final CustomTargetLanguage? existing;

  @override
  State<_TargetLanguageEditor> createState() => _TargetLanguageEditorState();
}

class _TargetLanguageEditorState extends State<_TargetLanguageEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _code = TextEditingController(text: widget.existing?.code ?? '');

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    var name = _name.text.trim();
    if (name.isEmpty) {
      context.showMessage(message: "Enter a language name".tl);
      return;
    }
    var code = widget.existing?.code;
    if (code == null) {
      code = TranslationTargets.normalizeCode(_code.text);
      if (code == null) {
        context.showMessage(message: "Enter a valid language code".tl);
        return;
      }
      if (TranslationTargets.isTaken(code)) {
        context.showMessage(message: "This language is already in the list".tl);
        return;
      }
    }
    TranslationTargets.save(CustomTargetLanguage(code: code, name: name));
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    var editing = widget.existing != null;
    return ContentDialog(
      title: editing ? "Edit language".tl : "Add language".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: InputDecoration(
                  labelText: "Language name".tl,
                  hintText: "e.g. ไทย, Bahasa Indonesia".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !editing,
                decoration: InputDecoration(
                  labelText: "Language code".tl,
                  hintText: "e.g. th, id, pt-BR".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                (editing
                        ? "The code cannot be changed: translations are stored under it."
                        : "The name is what the AI model translates into; write it in that language. The code is sent to Google Translate and translation scripts; use the one your service expects.")
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(onPressed: _submit, child: Text("Save".tl)),
      ],
    );
  }
}

const _rapidOcrBase =
    'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master';

/// Recognition models known to load and match their dictionary. Name and code
/// stay the user's to fill in.
const _recognitionPresets = [
  ('Latin script (French, German, Spanish...)', 'latin', 7.9),
  ('Cyrillic (Russian, Ukrainian...)', 'cyrillic', 8.1),
  ('Thai', 'th', 7.9),
];

const _detectorPresets = [
  ('PP-OCRv5 mobile', 'onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx', 4.8),
  ('PP-OCRv6 small', 'onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx', 9.9),
];

/// Add/edit dialog for a source language; probes the download size on save
/// and pops the saved entry.
class _SourceLanguageEditor extends StatefulWidget {
  const _SourceLanguageEditor({this.existing});

  final CustomSourceLanguage? existing;

  @override
  State<_SourceLanguageEditor> createState() => _SourceLanguageEditorState();
}

class _SourceLanguageEditorState extends State<_SourceLanguageEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _model = TextEditingController(
    text: widget.existing?.modelUrl ?? '',
  );
  late final _dict = TextEditingController(
    text: widget.existing?.dictUrl ?? '',
  );
  late var _height = widget.existing?.inputHeight ?? 48;
  var _checking = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _model.dispose();
    _dict.dispose();
    super.dispose();
  }

  void _applyPreset(String key) {
    setState(() {
      _model.text =
          '$_rapidOcrBase/onnx/PP-OCRv5/rec/${key}_PP-OCRv5_rec_mobile.onnx';
      _dict.text =
          '$_rapidOcrBase/paddle/PP-OCRv5/rec/${key}_PP-OCRv5_rec_mobile/ppocrv5_${key}_dict.txt';
      _height = 48;
    });
  }

  Future<void> _submit() async {
    var name = _name.text.trim();
    if (name.isEmpty) {
      context.showMessage(message: "Enter a language name".tl);
      return;
    }
    var code = widget.existing?.code;
    if (code == null) {
      code = TranslationTargets.normalizeCode(_code.text);
      if (code == null) {
        context.showMessage(message: "Enter a valid language code".tl);
        return;
      }
      if (TranslationSources.isTaken(code)) {
        context.showMessage(message: "This language is already in the list".tl);
        return;
      }
    }
    var model = _model.text.trim();
    var dict = _dict.text.trim();
    if (!TranslationSources.isValidUrl(model) ||
        !TranslationSources.isValidUrl(dict)) {
      context.showMessage(message: "Enter http(s) links for both files".tl);
      return;
    }
    setState(() => _checking = true);
    var store = TranslationModelStore.instance;
    var sizes = await Future.wait([
      store.probeSize(model),
      store.probeSize(dict),
    ]);
    if (!mounted) return;
    var language = CustomSourceLanguage(
      code: code,
      name: name,
      modelUrl: model,
      dictUrl: dict,
      inputHeight: _height,
      sizeBytes: sizes.contains(null) ? 0 : sizes[0]! + sizes[1]!,
    );
    TranslationSources.save(language);
    context.pop(language);
  }

  @override
  Widget build(BuildContext context) {
    var editing = widget.existing != null;
    InputDecoration field(String label, [String? hint]) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
    );
    return ContentDialog(
      title: editing ? "Edit source language".tl : "Add source language".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: field("Language name".tl, "e.g. Français, ไทย".tl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !editing,
                decoration: field("Language code".tl, "e.g. fr, ru, th".tl),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text("Fill in a tested model:".tl, style: ts.s12),
                  for (var p in _recognitionPresets)
                    ActionChip(
                      label: Text("${p.$1.tl} · ${p.$3} MB"),
                      onPressed: () => _applyPreset(p.$2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                decoration: field("Recognition model link (.onnx)".tl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _dict,
                decoration: field("Character dictionary link (.txt)".tl),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text("Input height".tl)),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 48, label: Text('48')),
                      ButtonSegment(value: 32, label: Text('32')),
                    ],
                    selected: {_height},
                    onSelectionChanged: (v) =>
                        setState(() => _height = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "Supported: PP-OCR text recognition models in ONNX format, with the character dictionary they were trained with. Paddle, MNN or PyTorch files and other model types do not work. Input height is 48 for PP-OCRv3 and later, 32 for older models. The model is checked after download and removed if it does not fit. Larger models are more accurate but load slower and use more memory."
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(
          isLoading: _checking,
          onPressed: _submit,
          child: Text("Save".tl),
        ),
      ],
    );
  }
}

/// Dialog for the custom text detection model link.
class _DetectorEditor extends StatefulWidget {
  const _DetectorEditor({this.existing});

  final CustomDetectorModel? existing;

  @override
  State<_DetectorEditor> createState() => _DetectorEditorState();
}

class _DetectorEditorState extends State<_DetectorEditor> {
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  var _checking = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var url = _url.text.trim();
    if (!TranslationSources.isValidUrl(url)) {
      context.showMessage(message: "Enter an http(s) link".tl);
      return;
    }
    setState(() => _checking = true);
    var size = await TranslationModelStore.instance.probeSize(url);
    if (!mounted) return;
    var model = CustomDetectorModel(url: url, sizeBytes: size ?? 0);
    TranslationSources.setDetector(model);
    context.pop(model);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Text detection model".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text("Fill in a tested model:".tl, style: ts.s12),
                  for (var p in _detectorPresets)
                    ActionChip(
                      label: Text("${p.$1} · ${p.$3} MB"),
                      onPressed: () =>
                          setState(() => _url.text = '$_rapidOcrBase/${p.$2}'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: "Detection model link (.onnx)".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Supported: PP-OCR text detection models (DBNet) in ONNX format. It replaces the built-in detector for every language. A larger detector finds small or stylized lettering more reliably but is slower on every page."
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(
          isLoading: _checking,
          onPressed: _submit,
          child: Text("Save".tl),
        ),
      ],
    );
  }
}
